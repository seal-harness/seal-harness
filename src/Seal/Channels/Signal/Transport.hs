{-# LANGUAGE OverloadedStrings #-}
-- | The testability seam over signal-cli. The real implementation spawns
-- @signal-cli --output=json --trust-new-identities=always -u <account> jsonRpc@
-- as a child process (via "System.Process") and talks JSON-RPC over
-- stdin/stdout; the mock implementation backs the test suite, so no
-- signal-cli binary is needed for @cabal test@.
module Seal.Channels.Signal.Transport
  ( SignalTransport (..)
  , mkMockSignalTransport
  , mkRealSignalTransport
  , receiveBlocking
  , chunkMessage
  , SignalEnvelope (..)
  , parseSignalEnvelope
  , conversationIdForSignal
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM
  ( TQueue, TVar, atomically, check, isEmptyTQueue, newTQueueIO, newTVarIO
  , orElse, readTQueue, readTVar, tryReadTQueue, writeTQueue, writeTVar )
import Control.Exception (IOException, try)
import Data.Aeson (Value)
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BL
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import System.Exit (ExitCode (..))
import System.IO (BufferMode (..), Handle, hClose, hFlush, hGetLine, hSetBuffering)
import System.Process
  ( CreateProcess (..), StdStream (..), createProcess, proc, terminateProcess,
    waitForProcess, withCreateProcess )
import System.Timeout (timeout)

import Seal.Core.MessageSource (ConversationId (..), UserId (..), mkConversationId, mkUserId)

-- | The testability seam over signal-cli.
data SignalTransport = SignalTransport
  { stReceive :: IO (Either Text Value)
    -- ^ Next inbound JSON value (one line from signal-cli's stdout).
  , stSend    :: Text -> Text -> IO ()
    -- ^ Send a message: recipient, body. Writes a JSON-RPC @send@ frame
    -- (fire-and-forget notification — no response is read).
  , stSendWithId :: Text -> Text -> IO (Maybe Text)
    -- ^ Send a message and return the timestamp from the JSON-RPC
    -- response. Blocks until the matching response arrives (with a
    -- timeout). 'Nothing' on failure or timeout. The timestamp is the
    -- message's identity in the Signal protocol — pass it to
    -- 'stEditMessage' to edit or 'stDeleteMessage' to delete.
  , stEditMessage :: Text -> Text -> Text -> IO Bool
    -- ^ Edit a previously sent message: recipient, timestamp, new
    -- content. Sends a JSON-RPC @send@ with @editTimestamp@ set. Returns
    -- 'True' on success.
  , stDeleteMessage :: Text -> Text -> IO Bool
    -- ^ Delete a previously sent message: recipient, timestamp. Calls
    -- the JSON-RPC @remoteDelete@ method. Returns 'True' on success.
  , stClose   :: IO ()
  }

-- | A mock transport backed by a 'TQueue' of inbound 'Value's and an 'IORef'
-- of captured sends. 'stReceive' pops the next inbound (or returns
-- @Left "inbox empty"@); 'stSend' appends @(recipient, body)@ to the
-- capture; 'stClose' is a no-op (idempotent).
mkMockSignalTransport :: [Value] -> IO (SignalTransport, IO [(Text, Text)])
mkMockSignalTransport scripted = do
  q <- newTQueueIO
  mapM_ (atomically . writeTQueue q) scripted
  capRef <- newIORef []
  tsRef <- newIORef (1000 :: Int)
  let transport = SignalTransport
        { stReceive = do
            m <- atomically (tryReadTQueue q)
            case m of
              Just v  -> pure (Right v)
              Nothing -> pure (Left "signal inbox empty")
        , stSend = \r b -> modifyIORef' capRef ((r, b) :)
        , stSendWithId = \_r _b -> do
            n <- readIORef tsRef
            let n' = n + 1
            writeIORef tsRef n'
            pure (Just (T.pack (show n')))
        , stEditMessage = \_r _ts _content -> pure True
        , stDeleteMessage = \_r _ts -> pure True
        , stClose = pure ()
        }
      getCaptured = reverse <$> readIORef capRef
  pure (transport, getCaptured)

-- | Spawn @signal-cli --output=json --trust-new-identities=always
-- -u <account> jsonRpc@ as a child process via "System.Process", line-
-- buffered JSON-RPC over stdin/stdout. 'stReceive' reads one line from
-- stdout and decodes it; 'stSend' writes a JSON-RPC @send@ frame to stdin;
-- 'stClose' terminates the child (with a 5s graceful wait). A preflight
-- @signal-cli --version@ probe fails fast if the binary is absent.
--
-- The '<account>' is the smart-constructed validated 'SignalAccount' from
-- "Seal.Signal.Config" — option injection fails to compile. This module
-- takes it as 'Text' here to avoid a cycle (Signal.Config imports nothing
-- from this module; the constructor is enforced at the call site).
mkRealSignalTransport :: Text -> IO (Either Text SignalTransport)
mkRealSignalTransport account = do
  versionOk <- probeSignalCli
  if not versionOk
    then pure (Left "signal-cli not installed or on PATH")
    else do
      eStarted <- try @IOException $
        createProcess
          ( (proc "signal-cli"
              [ "--output=json"
              , "--trust-new-identities=always"
              , "-u", T.unpack account
              , "jsonRpc"
              ])
              { std_in = CreatePipe, std_out = CreatePipe, std_err = Inherit }
          )
      case eStarted of
        Left e -> pure (Left ("signal-cli launch failed: " <> T.pack (show e)))
        Right (mIn, mOut, _err, ph) -> do
          (hIn, hOut) <- case (mIn, mOut) of
            (Just a, Just b) -> pure (a, b)
            _ -> error "mkRealSignalTransport: pipe creation failed (unreachable)"
          hSetBuffering hIn (BlockBuffering Nothing)
          hSetBuffering hOut LineBuffering
          inbox <- newTQueueIO
          readerDead <- newTVarIO False
          idRef <- newIORef (0 :: Int)
          respMap <- newIORef (Map.empty :: Map.Map Int (MVar (Maybe Value)))
          -- Spawn the demux reader thread: reads all stdout lines and
          -- routes responses (have id) to waiting callers via MVars,
          -- notifications (no id) to the inbox TQueue.
          _ <- forkIO (demuxReader hOut inbox respMap readerDead)
          let sendRequest :: Value -> IO (Maybe Value)
              sendRequest frame = do
                rid <- atomicModifyIORef' idRef (\n -> (n + 1, n))
                mv <- newEmptyMVar
                _ <- atomicModifyIORef' respMap (\m -> (Map.insert rid mv m, m))
                let ridVal = A.Number (fromIntegral rid)
                    -- Merge the id into the frame object (frame is always
                    -- an A.object, so we use KeyMap.insert).
                    framed = case frame of
                      A.Object o -> A.Object (KeyMap.insert (Key.fromString "id") ridVal o)
                      _ -> frame
                BL.hPutStr hIn (A.encode framed)
                TIO.hPutStrLn hIn ""
                hFlush hIn
                mResult <- timeout 10000000 (takeMVar mv)
                _ <- atomicModifyIORef' respMap (\m -> (Map.delete rid m, m))
                pure (case mResult of
                  Just (Just v) -> Just v
                  _ -> Nothing)
          pure (Right SignalTransport
            { stReceive = receiveBlocking inbox readerDead
            , stSend = \recipient body -> do
                let frame = A.object
                      [ "jsonrpc" A..= ("2.0" :: Text)
                      , "method"  A..= ("send" :: Text)
                      , "params"  A..= A.object
                          [ "recipient" A..= [recipient]
                          , "message"   A..= body
                          ]
                      ]
                BL.hPutStr hIn (A.encode frame)
                TIO.hPutStrLn hIn ""
                hFlush hIn
            , stSendWithId = \recipient body -> do
                let frame = A.object
                      [ "jsonrpc" A..= ("2.0" :: Text)
                      , "method"  A..= ("send" :: Text)
                      , "params"  A..= A.object
                          [ "recipient" A..= [recipient]
                          , "message"   A..= body
                          ]
                      ]
                mResp <- sendRequest frame
                pure (extractTimestamp =<< mResp)
            , stEditMessage = \recipient ts content -> do
                let frame = A.object
                      [ "jsonrpc" A..= ("2.0" :: Text)
                      , "method"  A..= ("send" :: Text)
                      , "params"  A..= A.object
                          [ "recipient" A..= [recipient]
                          , "message"   A..= content
                          , "editTimestamp" A..= (read (T.unpack ts) :: Int)
                          ]
                      ]
                mResp <- sendRequest frame
                pure (case mResp of
                  Just _  -> True
                  Nothing -> False)
            , stDeleteMessage = \recipient ts -> do
                let frame = A.object
                      [ "jsonrpc" A..= ("2.0" :: Text)
                      , "method"  A..= ("remoteDelete" :: Text)
                      , "params"  A..= A.object
                          [ "recipient" A..= [recipient]
                          , "targetTimestamp" A..= (read (T.unpack ts) :: Int)
                          ]
                      ]
                mResp <- sendRequest frame
                pure (case mResp of
                  Just _  -> True
                  Nothing -> False)
            , stClose = do
                _ <- try @IOException (hClose hIn)
                terminateProcess ph
                _ <- timeout 5000000 (waitForProcess ph)
                pure ()
            })

-- | The background demux reader: reads all lines from signal-cli's
-- stdout and classifies each:
-- * JSON-RPC response (has @result@ or @error@ + @id@) → route to the
--   waiting caller via the MVar keyed by @id@ in 'respMap'.
-- * JSON-RPC notification (has @method@ + @params@, no @id@) → push to
--   the inbox 'TQueue' (picked up by 'stReceive').
-- On a read error or EOF, the reader sets @readerDead@ and exits (the
-- transport is closing).
demuxReader
  :: Handle -> TQueue Value
  -> IORef (Map.Map Int (MVar (Maybe Value))) -> TVar Bool
  -> IO ()
demuxReader hOut inbox respMap readerDead = go
  where
    go = do
      eLine <- try @IOException (hGetLine hOut)
      case eLine of
        Left _ -> atomically (writeTVar readerDead True)  -- EOF or error
        Right line -> do
          case A.decode (BL.fromStrict (TE.encodeUtf8 (T.pack line))) of
            Nothing -> go  -- malformed line: skip
            Just v -> do
              case extractResponseId v of
                Just rid -> do
                  -- JSON-RPC response: deliver to the waiting MVar
                  m <- readIORef respMap
                  case Map.lookup rid m of
                    Just mv -> putMVar mv (Just v)
                    Nothing -> pure ()  -- stale: no waiting caller
                Nothing -> do
                  -- JSON-RPC notification: push to inbox
                  atomically (writeTQueue inbox v)
          go

-- | Block until the demux reader's inbox yields a value; return 'Left'
-- only when the reader is dead AND the inbox is drained (EOF). The
-- channel's reader loop treats any 'Left' as fatal, so this must NOT
-- return 'Left' while signal-cli is merely slow to emit — the pre-fix
-- non-blocking variant returned @Left "signal inbox empty"@ the instant
-- the inbox was momentarily empty, killing the channel at startup.
-- Implemented as an STM orElse: @readTQueue@ (blocks while empty) racing
-- the EOF check (@readerDead@ + queue empty → 'Left'). A live reader
-- therefore blocks forever until an envelope arrives; a dead reader
-- delivers any remaining envelopes first, then EOF.
receiveBlocking :: TQueue Value -> TVar Bool -> IO (Either Text Value)
receiveBlocking inbox readerDead =
  atomically $
    (Right <$> readTQueue inbox)
      `orElse` do
        dead <- readTVar readerDead
        check dead
        isEmpty <- isEmptyTQueue inbox
        check isEmpty
        pure (Left "signal inbox empty")

-- | Extract the @id@ field from a JSON-RPC response. Returns 'Nothing' for
-- notifications (which have no @id@). Pure.
extractResponseId :: Value -> Maybe Int
extractResponseId v =
  case v of
    A.Object o -> case KeyMap.lookup (Key.fromString "id") o of
      Just (A.Number n) -> Just (round n)
      _ -> Nothing
    _ -> Nothing

-- | Extract the @result.timestamp@ from a JSON-RPC @send@ response. Returns
-- 'Nothing' if the response is malformed or the field is absent. Pure.
extractTimestamp :: Value -> Maybe Text
extractTimestamp v =
  case v of
    A.Object o -> case KeyMap.lookup (Key.fromString "result") o of
      Just (A.Object ro) -> case KeyMap.lookup (Key.fromString "timestamp") ro of
        Just (A.Number n) -> Just (T.pack (show (round n :: Int)))
        _ -> Nothing
      _ -> Nothing
    _ -> Nothing

-- | Preflight @signal-cli --version@. Returns 'True' if the binary is on
-- PATH and exits successfully. Mirrors 'Seal.Security.Vault.Age's
-- @age --version@ preflight.
probeSignalCli :: IO Bool
probeSignalCli = do
  r <- try @IOException $
        withCreateProcess
          ( (proc "signal-cli" ["--version"])
              { std_out = NoStream, std_err = NoStream }
          ) $ \_ _ _ ph -> waitForProcess ph
  pure $ case r of
    Right ExitSuccess -> True
    _                 -> False

-- ---------------------------------------------------------------------------
-- chunkMessage
-- ---------------------------------------------------------------------------

-- | Split a message into chunks of at most 'limit' characters, preferring
-- paragraph boundaries (@\\n\\n@), then line boundaries (@\\n@), hard-cut
-- as a last resort. **Chunks carry their trailing separator** (except the
-- last chunk, which has none), so 'T.concat' of the chunks is identity:
--
-- > T.concat (chunkMessage limit t) == t
--
-- This makes the chunks the literal bytes to send, in order — the receiver
-- concatenates and sees the original text. Pure.
chunkMessage :: Int -> Text -> [Text]
chunkMessage limit t
  | limit < 1 = error "chunkMessage: limit must be >= 1"
  | T.null t  = []
  | otherwise = go t
  where
    go s
      | T.null s       = []
      | T.length s <= limit = [s]
      | otherwise =
          let (chunk, rest) = nextChunk limit s
          in chunk : if T.null rest then [] else go rest

-- | Extract the next chunk (with its trailing separator) and the remaining
-- text. Prefers a paragraph boundary (@\\n\\n@) within the limit, then a
-- line boundary (@\\n@), then a hard cut at the limit.
nextChunk :: Int -> Text -> (Text, Text)
nextChunk limit s =
  case findParagraphBreak limit s of
    Just n -> T.splitAt n s
    Nothing -> case findLineBreak limit s of
      Just n -> T.splitAt n s
      Nothing -> T.splitAt limit s

-- | The 1-based cut position (inclusive of the @\\n\\n@ separator) of the
-- last @\\n\\n@ within the first 'limit' characters, or 'Nothing' if there
-- is none. The chunk will then be @take n s@ (which ends in @\\n\\n@).
findParagraphBreak :: Int -> Text -> Maybe Int
findParagraphBreak limit s =
  -- Search the first `limit` characters for the rightmost "\n\n".
  let window = T.take limit s
  in case T.breakOnEnd "\n\n" window of
       (pre, _post) | not (T.null pre) -> Just (T.length pre)
       _ -> Nothing

-- | The 1-based cut position (inclusive of the @\\n@ separator) of the last
-- @\\n@ within the first 'limit' characters, or 'Nothing' if there is none.
findLineBreak :: Int -> Text -> Maybe Int
findLineBreak limit s =
  let window = T.take limit s
  in case T.breakOnEnd "\n" window of
       (pre, _post) | not (T.null pre) -> Just (T.length pre)
       _ -> Nothing

-- ---------------------------------------------------------------------------
-- SignalEnvelope — parsed inbound envelope + server-derived conversation id
-- ---------------------------------------------------------------------------

-- | A parsed inbound signal-cli envelope: the peer-derived conversation id,
-- the sender's user id, and the message body. The conversation id is
-- **server-derived from authenticated transport metadata** (the peer's
-- phone number + UUID), never read from the message body — enforced
-- structurally by 'conversationIdForSignal' taking only the peer fields.
data SignalEnvelope = SignalEnvelope
  { seConversationId :: ConversationId
  , seSender         :: UserId
  , seBody           :: Text
  } deriving stock (Eq, Show)

-- | Derive the server-side 'ConversationId' from the peer's authenticated
-- transport metadata. signal-cli envelopes carry both a phone number
-- (@source@) and a UUID (@sourceUuid@); the conversation id is
-- @sig:<source>:<sourceUuid>@ (or @sig:<source>@ when the UUID is absent).
-- Never reads the message body. A missing or empty @source@ is rejected
-- (a peer phone number is required).
conversationIdForSignal :: Maybe Text -> Maybe Text -> Either Text ConversationId
conversationIdForSignal mSource mUuid =
  case mSource of
    Nothing        -> Left "signal envelope missing source (peer phone number)"
    Just src
      | T.null src -> Left "signal envelope source is empty"
      | otherwise  -> mkConversationId full
      where
        full = case mUuid of
          Nothing   -> "sig:" <> src
          Just uuid -> "sig:" <> src <> ":" <> uuid

-- | Parse a raw signal-cli JSON value into a 'SignalEnvelope'. Handles both
-- raw envelopes (@{"envelope": {...}}@) and JSON-RPC-wrapped messages
-- (@{"jsonrpc":"2.0","method":"receive","params":{"envelope":{...}}}@).
-- Returns 'Left' on a malformed value, a missing peer field, or a
-- conversation-id smart-constructor failure. The body is taken from the
-- envelope's @dataMessage.message@; a @conversationId@ key in the body is
-- IGNORED (the conversation id is always server-derived via
-- 'conversationIdForSignal').
parseSignalEnvelope :: Value -> Either Text SignalEnvelope
parseSignalEnvelope v = do
  env <- unwrapEnvelope v
  source <- fieldText "source" env
  let mUuid = fieldTextMaybe "sourceUuid" env
  cid <- conversationIdForSignal (Just source) mUuid
  uid <- case mkUserId source of
    Right u  -> Right u
    Left err -> Left ("signal sender not a valid UserId: " <> err)
  let body = extractBody env
  Right SignalEnvelope
    { seConversationId = cid
    , seSender         = uid
    , seBody           = body
    }

-- | Unwrap a raw envelope (@{"envelope": {...}}@) or a JSON-RPC-wrapped
-- message (@{"params": {"envelope": {...}}}@) to the inner envelope object.
-- Returns 'Left' if neither shape is present or the value is not an object.
unwrapEnvelope :: Value -> Either Text Value
unwrapEnvelope v =
  case v of
    A.Object o ->
      case KeyMap.lookup (Key.fromString "envelope") o of
        Just env -> Right env
        Nothing -> case KeyMap.lookup (Key.fromString "params") o of
          Just (A.Object p) -> case KeyMap.lookup (Key.fromString "envelope") p of
            Just env -> Right env
            Nothing  -> Left "signal envelope: no envelope in params"
          _ -> Left "signal envelope: no envelope and no params"
    _ -> Left "signal envelope: not an object"

-- | Extract a required text field from an object, failing on absence or
-- non-text value.
fieldText :: Text -> Value -> Either Text Text
fieldText key v =
  case v of
    A.Object o -> case KeyMap.lookup (Key.fromString (T.unpack key)) o of
      Just (A.String t) -> Right t
      _ -> Left ("signal envelope missing or non-text field: " <> key)
    _ -> Left ("signal envelope field " <> key <> ": not an object")

-- | Extract an optional text field from an object.
fieldTextMaybe :: Text -> Value -> Maybe Text
fieldTextMaybe key v = do
  inner <- fieldValueMaybe key v
  case inner of
    A.String t -> Just t
    _ -> Nothing

-- | Extract an optional sub-value from an object.
fieldValueMaybe :: Text -> Value -> Maybe Value
fieldValueMaybe key v =
  case v of
    A.Object o -> KeyMap.lookup (Key.fromString (T.unpack key)) o
    _ -> Nothing

-- | Extract the message body from @dataMessage.message@. Empty when absent
-- (a non-data envelope, e.g. a receipt — the caller drops these).
extractBody :: Value -> Text
extractBody v = fromMaybe "" $ do
  dm <- fieldValueMaybe "dataMessage" v
  fieldTextMaybe "message" dm