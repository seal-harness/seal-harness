{-# LANGUAGE OverloadedStrings #-}
-- | The medium-agnostic ask/reply primitive.
--
-- Synchronous channels (the CLI TUI) can block inline on a direct prompt —
-- the human is right there typing. Asynchronous channels (web, Signal,
-- Telegram, …) cannot: the agent loop is running in one request/thread, and
-- the human's answer will arrive in a *separate* future message. This module
-- provides the shared, in-process store that bridges that gap without knowing
-- anything about the transport.
--
-- The flow:
--
-- 1. The agent calls @ASK_HUMAN@, which runs @ccPrompt q@.
-- 2. The channel's @ccPrompt@ closure calls 'askHuman', which mints a fresh
--    'AskId', registers a 'PendingAsk' (with an empty answer slot) in the
--    store, fires a medium-specific @notify@ callback (web: broadcast a WS
--    event; Signal: @chSend@ the question to the peer; Telegram: send a
--    message), and **blocks** on the answer slot (an STM 'TMVar').
-- 3. The human's reply arrives through the channel's inbound path (web:
--    POST @/api/sessions/:id/questions/:qid/answer@; Signal/Telegram: the
--    next inbound message from that peer). That path calls 'deliverAnswer',
--    which fills the answer slot and unblocks the agent-loop thread.
-- 4. 'askHuman' returns the answer (or an 'AskOutcome' on timeout/cancel),
--    and @ccPrompt@ maps it to 'Text' for the opcode.
--
-- The store is keyed by 'AskId'. 'pendingForSession' lets a channel list the
-- open questions for a session (so the frontend can render them on
-- reconnect). 'cancelAsk' abandons a question (timeout, session close).
-- 'deliverAnswer' is idempotent on a given 'AskId' (a second answer is
-- rejected).
module Seal.Handles.AskReply
  ( AskReplyStore
  , AskId (..)
  , askIdText
  , parseAskId
  , PendingAsk (..)
  , AskOutcome (..)
  , AskReply (..)
  , ApprovalScope (..)
  , ApprovalCache
  , newApprovalCache
  , approvalScopeText
  , parseApprovalScope
  , newAskReplyStore
  , askHuman
  , askHumanWithMeta
  , deliverAnswer
  , deliverNextAnswer
  , deliverNextAnswerAny
  , cancelAsk
  , cancelSessionAsks
  , pendingForSession
  , lookupAsk
  , checkApproval
  , recordApproval
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM
  ( TMVar, TVar, atomically, modifyTVar', newEmptyTMVarIO, newTVarIO, readTVar, readTVarIO
  , takeTMVar, tryPutTMVar, writeTVar, tryReadTMVar )
import Control.Monad (void)
import Data.Aeson (Value, ToJSON (..))
import Data.Bits ((.&.), (.|.), complement)
import Data.IORef (IORef, newIORef, readIORef)
import Data.List (sortBy)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime)
import Data.UUID.Types qualified as U
import Data.Word (Word64)
import GHC.Generics (Generic)
import System.Random (randomIO)

import Seal.Core.Types (OpName (..), SessionId)

-- | A UUID-backed identifier for one pending question. Minted by 'askHuman';
-- | quoted in the notify event so the medium's inbound path can quote it back
-- | in 'deliverAnswer'. The text form is a canonical UUID string.
newtype AskId = AskId Text
  deriving stock (Eq, Ord, Show, Generic)

-- | The text form (a UUID string) — the value the medium carries in its
-- answer-delivery path (the web route param, the Signal reply metadata, …).
askIdText :: AskId -> Text
askIdText (AskId t) = t

-- | Parse an 'AskId' from its text form. 'Left' on malformed input.
parseAskId :: Text -> Either Text AskId
parseAskId t
  | isValidUuidText t = Right (AskId t)
  | otherwise         = Left ("invalid AskId: " <> t)

-- | True if the text is a valid UUID (8-4-4-4-12 hex, case-insensitive).
isValidUuidText :: Text -> Bool
isValidUuidText t = case U.fromString (T.unpack t) of
  Just _  -> True
  Nothing -> False

-- | Mint a fresh random 'AskId' (UUID v4). IO because it reads randomness.
newAskId :: IO AskId
newAskId = do
  w1 <- randomIO
  w2 <- randomIO
  let v1 = (w1 .&. complement 0x0000F000) .|. (0x4000 :: Word64)
      v2 = (w2 .|. 0x8000000000000000) .&. complement 0x4000000000000000
  pure (AskId (T.pack (U.toString (U.fromWords64 v1 v2))))

-- | The outcome when 'askHuman' unblocks without an answer.
data AskOutcome = AoAnswered | AoCancelled | AoTimedOut
  deriving stock (Eq, Show)

-- | The scope of a human approval for an Untrusted opcode. Determines how
-- long the approval is cached (so subsequent calls to the same opcode skip
-- the prompt). 'ScopeOnce' never caches; 'ScopeForSession' caches for the
-- session; 'ScopeAlways' caches globally; 'ScopeRejected' denies this call
-- (and, for 'ScopeForSession'/'ScopeAlways', future calls to the same opcode).
data ApprovalScope
  = ScopeOnce
  | ScopeForSession
  | ScopeAlways
  | ScopeRejected
  deriving stock (Eq, Show)

-- | The wire text for an 'ApprovalScope' (used by the API + frontend).
approvalScopeText :: ApprovalScope -> Text
approvalScopeText ScopeOnce        = "once"
approvalScopeText ScopeForSession  = "for_session"
approvalScopeText ScopeAlways      = "always"
approvalScopeText ScopeRejected    = "rejected"

-- | ToJSON for 'ApprovalScope' — encodes as the wire text (so transcript
-- evidence carries a human-readable scope, not a constructor tag).
instance ToJSON ApprovalScope where
  toJSON = toJSON . approvalScopeText

-- | Parse an 'ApprovalScope' from its wire text. 'Left' on unknown.
parseApprovalScope :: Text -> Either Text ApprovalScope
parseApprovalScope t = case T.toLower t of
  "once"        -> Right ScopeOnce
  "for_session" -> Right ScopeForSession
  "always"      -> Right ScopeAlways
  "rejected"    -> Right ScopeRejected
  _             -> Left ("unknown approval scope: " <> t)

-- | The structured reply to a pending question. For @ASK_HUMAN@, 'arScope' is
-- 'ScopeOnce' and 'arText' is the human's typed reply. For the confirmation
-- gate, 'arScope' is the chosen button and 'arText' is a display label
-- (e.g. @"yes, once"@, @"rejected"@).
data AskReply = AskReply
  { arScope :: ApprovalScope
  , arText  :: Text
  } deriving stock (Eq, Show)

-- | One pending question: the session it belongs to, the question text, the
-- timestamp it was minted, optional metadata (opcode name + input for the
-- confirmation gate), and the answer slot. The slot carries 'Left' on
-- cancel/timeout, 'Right' on a delivered answer.
data PendingAsk = PendingAsk
  { paId        :: AskId
  , paSession   :: SessionId
  , paQuestion  :: Text
  , paCreatedAt :: UTCTime
  , paMeta      :: Maybe Value  -- ^ opcode name + input (for the confirmation gate); Nothing for ASK_HUMAN
  , paSlot      :: TMVar (Either AskOutcome AskReply)
  }

-- | The shared, in-process store. STM-backed: a 'TVar' of pending questions
-- keyed by 'AskId'. The timeout (microseconds; 0 = block indefinitely) bounds
-- how long 'askHuman' waits before returning 'AoTimedOut'.
data AskReplyStore = AskReplyStore
  { arsPending   :: TVar (Map AskId PendingAsk)
  , arsTimeoutUs :: IORef Int
  }

-- | Build a new store with the given default timeout in microseconds
-- (0 = block indefinitely). The timeout bounds every 'askHuman' call.
newAskReplyStore :: Int -> IO AskReplyStore
newAskReplyStore timeoutUs =
  AskReplyStore <$> newTVarIO Map.empty <*> newIORef timeoutUs

-- | The approval cache: maps @(SessionId, OpName)@ → 'ApprovalScope' so that
-- "for this session" and "always" approvals short-circuit the prompt for
-- subsequent calls to the same opcode. 'ScopeForSession' entries are keyed
-- by session; 'ScopeAlways' entries use a synthetic global session key.
data ApprovalCache = ApprovalCache
  { acSession  :: TVar (Map (SessionId, OpName) ApprovalScope)
  , acGlobal   :: TVar (Set OpName)
  }

-- | Build a new, empty approval cache.
newApprovalCache :: IO ApprovalCache
newApprovalCache = ApprovalCache <$> newTVarIO Map.empty <*> newTVarIO Set.empty

-- | Check the approval cache for a @(SessionId, OpName)@ pair. Returns
-- 'Just ScopeRejected' if the opcode was previously rejected (for this
-- session or globally), 'Just scope' if it was approved at that scope,
-- 'Nothing' if no prior approval exists (the caller should prompt).
checkApproval :: ApprovalCache -> SessionId -> OpName -> IO (Maybe ApprovalScope)
checkApproval cache sid opName = do
  global <- readTVarIO (acGlobal cache)
  if opName `Set.member` global
    then pure (Just ScopeAlways)
    else do
      m <- readTVarIO (acSession cache)
      pure (Map.lookup (sid, opName) m)

-- | Record an approval in the cache. 'ScopeOnce' is a no-op (no caching);
-- 'ScopeForSession' inserts a session-scoped entry; 'ScopeAlways' inserts a
-- global entry; 'ScopeRejected' inserts a session-scoped rejection (so
-- subsequent calls in the same session short-circuit to denied). A
-- 'ScopeRejected' does NOT elevate to global — the human may want to allow
-- the opcode in another session.
recordApproval :: ApprovalCache -> SessionId -> OpName -> ApprovalScope -> IO ()
recordApproval cache sid opName scope =
  case scope of
    ScopeOnce       -> pure ()
    ScopeForSession -> atomically (modifyTVar' (acSession cache) (Map.insert (sid, opName) ScopeForSession))
    ScopeAlways     -> atomically (modifyTVar' (acGlobal cache) (Set.insert opName))
    ScopeRejected   -> atomically (modifyTVar' (acSession cache) (Map.insert (sid, opName) ScopeRejected))

-- | Register a pending question, fire the @notify@ callback with its 'AskId',
-- and block until the answer is delivered, the question is cancelled, or the
-- timeout elapses. Returns 'Right' the reply, or 'Left' the outcome. The
-- @notify@ callback is the medium-specific seam: the web broadcasts a WS
-- event, Signal/Telegram @chSend@ the question to the peer. It is invoked
-- /before/ blocking so the medium surfaces the question immediately. If
-- @notify@ throws, the pending question is left registered (the caller may
-- still deliver an answer); this is intentional — a flaky notify should not
-- strand the agent loop, and 'cancelSessionAsks' cleans up on session close.
askHuman
  :: AskReplyStore
  -> SessionId
  -> Text          -- ^ the question text
  -> (AskId -> IO ())  -- ^ the medium-specific notify callback
  -> IO (Either AskOutcome Text)
askHuman store sid question notify = do
  r <- askHumanWithMeta store sid question Nothing notify
  pure (case r of
    Left o   -> Left o
    Right ar -> Right (arText ar))

-- | Like 'askHuman' but carries optional metadata (opcode name + input for
-- the confirmation gate) in the 'PendingAsk'. The metadata is surfaced in the
-- WS @ask@ event so the frontend can display the opcode name + input alongside
-- the question. Returns the full 'AskReply' (scope + text).
askHumanWithMeta
  :: AskReplyStore
  -> SessionId
  -> Text          -- ^ the question text
  -> Maybe Value   -- ^ optional metadata (opcode name + input)
  -> (AskId -> IO ())  -- ^ the medium-specific notify callback
  -> IO (Either AskOutcome AskReply)
askHumanWithMeta store sid question meta notify = do
  qid <- newAskId
  slot <- newEmptyTMVarIO
  now <- getCurrentTime
  let pa = PendingAsk { paId = qid, paSession = sid, paQuestion = question
                      , paCreatedAt = now, paMeta = meta, paSlot = slot }
  atomically (modifyTVar' (arsPending store) (Map.insert qid pa))
  notify qid
  timeoutUs <- readIORef (arsTimeoutUs store)
  if timeoutUs <= 0
    then atomically (takeTMVar slot)
    else do
      _ <- forkIO $ do
        threadDelay timeoutUs
        atomically $ do
          m <- readTVar (arsPending store)
          case Map.lookup qid m of
            Nothing -> pure ()
            Just pendingPa -> void (tryPutTMVar (paSlot pendingPa) (Left AoTimedOut))
      atomically (takeTMVar slot)

-- | Deliver an answer to a pending question. Returns 'True' if the answer
-- | was accepted (the question was pending and not yet answered), 'False'
-- | otherwise (unknown id, already answered, or already cancelled). The
-- | accepted answer unblocks the waiting 'askHuman' thread. Idempotent on a
-- | given 'AskId': a second call is rejected.
deliverAnswer :: AskReplyStore -> AskId -> AskReply -> IO Bool
deliverAnswer store qid reply = do
  mPa <- atomically $ do
    m <- readTVar (arsPending store)
    case Map.lookup qid m of
      Nothing -> pure Nothing
      Just pa -> do
        let slot = paSlot pa
        won <- tryPutTMVar slot (Right reply)
        if won
          then writeTVar (arsPending store) (Map.delete qid m) >> pure (Just pa)
          else pure Nothing
  pure (case mPa of Just _ -> True; Nothing -> False)

-- | Deliver an answer to the /oldest/ pending question for a session. Used by
-- | inbox-driven async channels (Signal, Telegram) where the human's reply
-- | arrives as the next inbound message from the peer — there is no ask-id in
-- | the transport, so the FIFO queue of pending questions is matched in order.
-- | Returns 'True' if a pending question was found and answered, 'False' if
-- | the session has no pending questions (the answer is a spurious / unsolicited
-- | inbound message the caller may route as a plain turn instead).
deliverNextAnswer :: AskReplyStore -> SessionId -> Text -> IO Bool
deliverNextAnswer store sid ans = do
  let reply = AskReply ScopeOnce ans
  mQid <- atomically $ do
    m <- readTVar (arsPending store)
    let matching = filter (\pa -> paSession pa == sid)
                  $ sortByCreatedAt (Map.elems m)
    case matching of
      [] -> pure Nothing
      pa : _ ->
        let slot = paSlot pa in do
          won <- tryPutTMVar slot (Right reply)
          if won
            then writeTVar (arsPending store) (Map.delete (paId pa) m)
                 >> pure (Just (paId pa))
            else
              writeTVar (arsPending store) (Map.delete (paId pa) m)
              >> pure Nothing
  case mQid of
    Just _  -> pure True
    Nothing ->
      do
        mQid2 <- atomically $ do
          m <- readTVar (arsPending store)
          let matching = filter (\pa -> paSession pa == sid)
                        $ sortByCreatedAt (Map.elems m)
          case matching of
            [] -> pure Nothing
            pa : _ ->
              let slot = paSlot pa in do
                won <- tryPutTMVar slot (Right reply)
                if won
                  then writeTVar (arsPending store) (Map.delete (paId pa) m)
                       >> pure (Just (paId pa))
                  else writeTVar (arsPending store) (Map.delete (paId pa) m)
                       >> pure Nothing
        pure (case mQid2 of Just _ -> True; Nothing -> False)

-- | Sort pending questions oldest-first by 'paCreatedAt'. 'Map.elems' is
-- unsorted (keyed by 'AskId'), so an explicit sort is needed for FIFO
-- delivery.
sortByCreatedAt :: [PendingAsk] -> [PendingAsk]
sortByCreatedAt = sortBy (\a b -> compare (paCreatedAt a) (paCreatedAt b))

-- | Deliver an inbound line as the answer to the oldest pending question
-- across /all/ sessions (FIFO by 'paCreatedAt'). Returns 'True' if a
-- pending question was found and answered, 'False' if none exists (the
-- caller may route the line as a normal turn).
--
-- This is the session-agnostic counterpart of 'deliverNextAnswer': it serves
-- channels with a single shared input stream that may answer questions for
-- more than one session (e.g. the CLI TUI, where a @/bg@ turn forks a
-- background session whose confirmation prompts must be answerable from the
-- same @>@ prompt that serves the active session). Inbox-driven channels
-- (Signal/Telegram) use the per-session 'deliverNextAnswer' because each
-- conversation has its own inbound stream and cursor.
deliverNextAnswerAny :: AskReplyStore -> Text -> IO Bool
deliverNextAnswerAny store ans = do
  let reply = AskReply ScopeOnce ans
  mQid <- atomically $ do
    m <- readTVar (arsPending store)
    case sortByCreatedAt (Map.elems m) of
      [] -> pure Nothing
      pa : _ ->
        let slot = paSlot pa in do
          won <- tryPutTMVar slot (Right reply)
          if won
            then writeTVar (arsPending store) (Map.delete (paId pa) m)
                 >> pure (Just (paId pa))
            else
              writeTVar (arsPending store) (Map.delete (paId pa) m)
              >> pure Nothing
  pure (case mQid of Just _ -> True; Nothing -> False)

-- | 'True' if the question was pending and is now cancelled.
cancelAsk :: AskReplyStore -> AskId -> IO Bool
cancelAsk store qid = do
  mPa <- atomically $ do
    m <- readTVar (arsPending store)
    case Map.lookup qid m of
      Nothing -> pure Nothing
      Just pa -> do
        won <- tryPutTMVar (paSlot pa) (Left AoCancelled)
        if won
          then writeTVar (arsPending store) (Map.delete qid m) >> pure (Just pa)
          else pure Nothing
  pure (case mPa of Just _ -> True; Nothing -> False)

-- | Cancel every pending question for a session (e.g. on session close or
-- | agent termination). Each still-waiting 'askHuman' thread unblocks with
-- | 'AoCancelled'. Already-answered questions are unaffected.
cancelSessionAsks :: AskReplyStore -> SessionId -> IO ()
cancelSessionAsks store sid = do
  toCancel <- atomically $ do
    m <- readTVar (arsPending store)
    let matching = Map.filter (\pa -> paSession pa == sid) m
        remaining = Map.difference m matching
    writeTVar (arsPending store) remaining
    pure (Map.elems matching)
  mapM_ (\pa -> atomically (void (tryPutTMVar (paSlot pa) (Left AoCancelled)))) toCancel

-- | List the pending questions for a session, oldest-first. Used by a medium
-- | to render open questions on reconnect (the web frontend polls this via
-- | GET /api/sessions/:id/questions). Does /not/ expose the answer slot.
-- | Includes the metadata (opcode name + input) when present so the frontend
-- | can display it.
pendingForSession
  :: AskReplyStore -> SessionId
  -> IO [(AskId, Text, UTCTime, Maybe Value)]
pendingForSession store sid =
  map (\pa -> (paId pa, paQuestion pa, paCreatedAt pa, paMeta pa))
  . filter (\pa -> paSession pa == sid)
  . Map.elems <$> readTVarIO (arsPending store)

-- | Look up a single pending question by id (for the delivery path to
-- | validate). Returns 'Nothing' if the id is unknown or already answered.
lookupAsk :: AskReplyStore -> AskId -> IO (Maybe (SessionId, Text))
lookupAsk store qid = do
  m <- readTVarIO (arsPending store)
  case Map.lookup qid m of
    Nothing -> pure Nothing
    Just pa -> do
      mRes <- atomically (tryReadTMVar (paSlot pa))
      case mRes of
        Just _  -> pure Nothing
        Nothing -> pure (Just (paSession pa, paQuestion pa))