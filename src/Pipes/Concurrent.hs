-- | Asynchronous communication between pipes

{-# LANGUAGE CPP, RankNTypes#-}

#if __GLASGOW_HASKELL__ >= 702
{-# LANGUAGE Trustworthy #-}
#endif
{- 'unsafeIOToSTM' requires the Trustworthy annotation.

    I use 'unsafeIOToSTM' to touch IORefs to mark them as still alive. This
    action satisfies the necessary safety requirements because:

    * You can safely repeat it if the transaction rolls back

    * It does not acquire any resources

    * It does not leak any inconsistent view of memory to the outside world

    It appears to be unnecessary to read the IORef to keep it from being garbage
    collected, but I wanted to be absolutely certain since I cannot be sure that
    GHC won't optimize away the reference to the IORef.

    The other alternative was to make 'send' and 'recv' use the 'IO' monad
    instead of 'STM', but I felt that it was important to preserve the ability
    to combine them into larger transactions.
-}

module Pipes.Concurrent (
    -- * Inputs and Outputs
    Input(..),
    Output(..),

    -- * Pipe utilities
    fromInput,
    toOutput,

    -- * Actors
    spawn,
    spawn',
    Buffer(..),

    -- * Re-exports
    -- $reexport
    module Control.Concurrent,
    module Control.Concurrent.STM,
    module System.Mem
    ) where

import Control.Applicative (
    Alternative(empty, (<|>)), Applicative(pure, (<*>)), (<*), (<$>) )
import Control.Concurrent (forkIO)
import Control.Concurrent.STM (atomically, STM)
import qualified Control.Concurrent.STM as S
import Control.Monad (when)
import Data.IORef (newIORef, readIORef, mkWeakIORef)
import Data.Monoid (Monoid(mempty, mappend))
import GHC.Conc.Sync (unsafeIOToSTM)
import Pipes (MonadIO(liftIO), yield, await, Producer', Consumer')
import System.Mem (performGC)

{-| An exhaustible source of values

    'recv' returns 'Nothing' if the source is exhausted
-}
newtype Input a = Input {
    recv :: S.STM (Maybe a) }

instance Functor Input where
    fmap f m = Input (fmap (fmap f) (recv m))

instance Applicative Input where
    pure r    = Input (pure (pure r))
    mf <*> mx = Input ((<*>) <$> recv mf <*> recv mx)

instance Monad Input where
    return r = Input (return (return r))
    m >>= f  = Input $ do
        ma <- recv m
        case ma of
            Nothing -> return Nothing
            Just a  -> recv (f a)

-- Deriving 'Alternative'
instance Alternative Input where
    empty   = Input empty
    x <|> y = Input (recv x <|> recv y)

instance Monoid (Input a) where
    mempty = empty
    mappend = (<|>)

{-| An exhaustible sink of values

    'send' returns 'False' if the sink is exhausted
-}
newtype Output a = Output {
    send :: a -> S.STM Bool }

instance Monoid (Output a) where
    mempty  = Output (\_ -> return False)
    mappend i1 i2 = Output (\a -> (||) <$> send i1 a <*> send i2 a)

{-| Convert an 'Output' to a 'Pipes.Consumer'

    'toOutput' terminates when the 'Output' is exhausted.
-}
toOutput :: (MonadIO m) => Output a -> Consumer' a m ()
toOutput output = loop
  where
    loop = do
        a     <- await
        alive <- liftIO $ S.atomically $ send output a
        when alive loop
{-# INLINABLE toOutput #-}

{-| Convert an 'Input' to a 'Pipes.Producer'

    'fromInput' terminates when the 'Input' is exhausted.
-}
fromInput :: (MonadIO m) => Input a -> Producer' a m ()
fromInput input = loop
  where
    loop = do
        ma <- liftIO $ S.atomically $ recv input
        case ma of
            Nothing -> return ()
            Just a  -> do
                yield a
                loop
{-# INLINABLE fromInput #-}

{-| Spawn a mailbox using the specified 'Buffer' to store messages

    Using 'send' on the 'Output'

        * fails and returns 'False' if the 'Input' has been garbage collected
          (even if the mailbox is not full), otherwise it:

        * retries if the mailbox is full, or:

        * adds a message to the mailbox and returns 'True'.

    Using 'recv' on the 'Input':

        * retrieves a message from the mailbox wrapped in 'Just' if the mailbox
          is not empty, otherwise it:

        * retries if the 'Output' has not been garbage collected, or:

        * fails if the 'Output' has been garbage collected and returns
          'Nothing'.
-}
spawn :: Buffer a -> IO (Output a, Input a)
spawn buffer = fmap simplify (spawn' buffer)
  where
    simplify (output, input, _) = (output, input)
{-# INLINABLE spawn #-}

{-| Like 'spawn', but also returns an action to finalize the mailbox, preventing
    new values from being added:

> (output, input, finalize) <- spawn' buffer
> ...

    Use the finalizer to allow early cleanup of readers and listeners to the
    mailbox.
-}
spawn' :: Buffer a -> IO (Output a, Input a, STM ())
spawn' buffer = do
    (read, write) <- case buffer of
        Bounded n -> do
            q <- S.newTBQueueIO n
            return (S.readTBQueue q, S.writeTBQueue q)
        Unbounded -> do
            q <- S.newTQueueIO
            return (S.readTQueue q, S.writeTQueue q)
        Single    -> do
            m <- S.newEmptyTMVarIO
            return (S.takeTMVar m, S.putTMVar m)
        Latest a  -> do
            t <- S.newTVarIO a
            return (S.readTVar t, S.writeTVar t)

    doneSend <- S.newTVarIO False
    let noMoreSends = S.writeTVar doneSend True
    {- Use an IORef to keep track of whether the 'Output' has been garbage
       collected and run a finalizer when the collection occurs
    -}
    rSend <- newIORef ()
    mkWeakIORef rSend (S.atomically noMoreSends)

    doneRecv <- S.newTVarIO False
    let noMoreRecvs = S.writeTVar doneRecv True
    {- Use an IORef to keep track of whether the 'Input' has been garbage
       collected and run a finalizer when the collection occurs
    -}
    rRecv <- newIORef ()
    mkWeakIORef rRecv (S.atomically noMoreRecvs)

    let sendOrEnd a = do
            b <- S.readTVar doneRecv
            if b
                then return False
                else do
                    write a
                    return True
        {- The '_send' action aborts without writing a value to the 'Buffer' if
           the 'Output' has been garbage collected, since there is no point
           wasting memory if nothing can empty the mailbox.  This protects
           against careless users not checking send's return value, especially
           if they use a mailbox of 'Unbounded' size.
        -}
        readOrEnd = (Just <$> read) <|> (do
            b <- S.readTVar doneSend
            S.check b
            return Nothing )
        _send a = sendOrEnd a <* unsafeIOToSTM (readIORef rSend)
        _recv   = readOrEnd   <* unsafeIOToSTM (readIORef rRecv)
    return (Output _send, Input _recv, noMoreRecvs >> noMoreSends)
{-# INLINABLE spawn' #-}

-- | 'Buffer' specifies how to buffer messages stored within the mailbox
data Buffer a
    -- | Store an 'Unbounded' number of messages in a FIFO queue
    = Unbounded
    -- | Store a 'Bounded' number of messages, specified by the 'Int' argument
    | Bounded Int
    -- | Store a 'Single' message (like @Bounded 1@, but more efficient)
    | Single
    {-| Only store the 'Latest' message, beginning with an initial value

        'Latest' is never empty nor full.
    -}
    | Latest a

{- $reexport
    @Control.Concurrent@ re-exports 'forkIO', although I recommend using the
    @async@ library instead.

    @Control.Concurrent.STM@ re-exports 'atomically' and 'STM'.

    @System.Mem@ re-exports 'performGC'.
-}
