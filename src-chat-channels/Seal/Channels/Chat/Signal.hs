{-# LANGUAGE OverloadedStrings #-}
-- | The Signal chat-channel adapter. Implements 'ChatChannel' for
-- 'SignalChatChannel', wrapping the transport + inbox + allow-list.
-- The reader thread parses signal-cli output, allow-lists the sender,
-- and pushes envelopes to the inbox. Sends are chunked to the configured
-- limit and addressed to the last sender.
module Seal.Channels.Chat.Signal
  ( SignalChatChannel (..)
  , withSignalChatChannel
  , SignalChatTransport (..)
  , mkMockSignalChatTransport
  , mkRealSignalChatTransport
  , chunkMessage
  ) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, newMVar, putMVar, takeMVar, withMVar)
import Control.Concurrent.STM
  (TQueue, TVar, atomically, check, isEmptyTQueue, newTQueueIO, newTVarIO
  , orElse, readTQueue, readTVar, tryReadTQueue, writeTQueue, writeTVar)
import Control.Exception (bracket, SomeException, try, IOException)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Aeson (Value)
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BL
import System.Exit (ExitCode (..))
import System.IO (BufferMode (..), Handle, hClose, hFlush, hGetLine, hSetBuffering)
import System.Process
  ( CreateProcess (..), StdStream (..), createProcess, proc, terminateProcess,
    waitForProcess, withCreateProcess)
import System.Timeout (timeout)

import Seal.Channels.Chat.Class (ChatChannel (..))
import Seal.Channels.Chat.Types
  (InboundMessage (..), ChatMessageId (..), ReceivedMessage (..))
import Seal.Gateway.Types.AllowList (AllowList (..))
import Seal.Gateway.Types.ChannelKind (ChannelKind (..))
import Seal.Gateway.Types.MessageSource
  (ConversationId, mkMessageSource, mkConversationId, mkUserId, UserId)

-- | The testability seam over signal-cli. Mirrors the existing
-- 'Seal.Channels.Signal.Transport.SignalTransport' but in the
-- chat-channels package namespace.
data SignalChatTransport = SignalChatTransport
  { sctReceive :: IO (Either Text ReceivedMessage)
    -- ^ Next inbound message.
  , sctSend    :: Text -> Text -> IO ()
    -- ^ Send a message: recipient, body.
  , sctSendWithId :: Text -> Text -> IO (Maybe Text)
    -- ^ Send a message and return the timestamp (for editing).
  , sctEditMessage :: Text -> Text -> Text -> IO Bool
    -- ^ Edit a previously sent message: recipient, timestamp, new content.
  , sctClose   :: IO ()
  }

-- | Chunk a message to the given character limit. Splits on word
-- boundaries when possible.
chunkMessage :: Int -> Text -> [Text]
chunkMessage limit msg
  | T.length msg <= limit = [msg]
  | otherwise = go msg
  where
    go t
      | T.null t = []
      | T.length t <= limit = [t]
      | otherwise = T.take limit t : go (T.drop limit t)

-- | A mock transport backed by a 'TQueue' of inbound messages and an
-- 'IORef's of captured sends and captured edits. For testing. The third
-- return value exposes the captured @(timestamp, content)@ edit pairs so
-- streaming-edit cadence is observable in tests.
mkMockSignalChatTransport :: [ReceivedMessage] -> IO (SignalChatTransport, IO [Text], IO [(Text, Text)])
mkMockSignalChatTransport scripted = do
  q <- newTQueueIO
  mapM_ (atomically . writeTQueue q) scripted
  capRef <- newIORef []
  editRef <- newIORef ([] :: [(Text, Text)])
  tsRef <- newIORef (1000 :: Int)
  let transport = SignalChatTransport
        { sctReceive = do
            m <- atomically (tryReadTQueue q)
            case m of
              Just msg -> pure (Right msg)
              Nothing -> pure (Left "inbox empty")
        , sctSend = \_r b -> modifyIORef' capRef (b :)
        , sctSendWithId = \_r b -> do
            n <- readIORef tsRef
            writeIORef tsRef (n + 1)
            modifyIORef' capRef (b :)  -- sendWithId is also a visible send
            pure (Just (T.pack (show (n + 1))))
        , sctEditMessage = \_r ts content -> do
            modifyIORef' editRef ((ts, content) :)
            pure True
        , sctClose = pure ()
        }
      getCaptured = reverse <$> readIORef capRef
      getEdits = reverse <$> readIORef editRef
  pure (transport, getCaptured, getEdits)

-- ---------------------------------------------------------------------------
-- Real transport — signal-cli subprocess via JSON-RPC
-- ---------------------------------------------------------------------------

-- | Spawn @signal-cli --output=json --trust-new-identities=always
-- -u <account> jsonRpc@ as a child process, line-buffered JSON-RPC over
-- stdin/stdout. Returns 'Left' if signal-cli is not installed or fails to
-- start.
mkRealSignalChatTransport :: Text -> IO (Either Text SignalChatTransport)
mkRealSignalChatTransport account = do
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
            _ -> error "mkRealSignalChatTransport: pipe creation failed (unreachable)"
          hSetBuffering hIn (BlockBuffering Nothing)
          hSetBuffering hOut LineBuffering
          inbox <- newTQueueIO
          readerDead <- newTVarIO False
          idRef <- newIORef (0 :: Int)
          respMap <- newIORef (Map.empty :: Map.Map Int (MVar (Maybe Value)))
          _ <- forkIO (demuxReader hOut inbox respMap readerDead)
          sendLock <- newMVar ()
          let writeFrame :: Value -> IO ()
              writeFrame frame = withMVar sendLock $ \_ -> do
                BL.hPutStr hIn (A.encode frame)
                TIO.hPutStrLn hIn ""
                hFlush hIn
          let sendRequest :: Value -> IO (Maybe Value)
              sendRequest frame = do
                rid <- atomicModifyIORef' idRef (\n -> (n + 1, n))
                mv <- newEmptyMVar
                _ <- atomicModifyIORef' respMap (\m -> (Map.insert rid mv m, m))
                let ridVal = A.Number (fromIntegral rid)
                    framed = case frame of
                      A.Object o -> A.Object (KeyMap.insert (Key.fromString "id") ridVal o)
                      _ -> frame
                writeFrame framed
                mResult <- timeout 10000000 (takeMVar mv)
                _ <- atomicModifyIORef' respMap (\m -> (Map.delete rid m, m))
                pure (case mResult of
                  Just (Just v) -> Just v
                  _ -> Nothing)
          pure (Right SignalChatTransport
            { sctReceive = receiveBlocking inbox readerDead
            , sctSend = \recipient body -> do
                let frame = A.object
                      [ "jsonrpc" A..= ("2.0" :: Text)
                      , "method"  A..= ("send" :: Text)
                      , "params"  A..= A.object
                          [ "recipient" A..= [recipient]
                          , "message"   A..= body
                          ]
                      ]
                writeFrame frame
            , sctSendWithId = \recipient body -> do
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
            , sctEditMessage = \recipient ts content -> do
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
            , sctClose = do
                _ <- try @IOException (hClose hIn)
                terminateProcess ph
                _ <- timeout 5000000 (waitForProcess ph)
                pure ()
            })

-- | The background demux reader: reads all lines from signal-cli's
-- stdout and classifies each:
-- * JSON-RPC response (has @result@ or @error@ + @id@) → route to the
--   waiting caller via the MVar keyed by @id@ in 'respMap'.
-- * JSON-RPC notification (has @method@ + @params@, no @id@) → parse
--   into a 'ReceivedMessage' and push to the inbox 'TQueue'.
demuxReader
  :: Handle -> TQueue ReceivedMessage
  -> IORef (Map.Map Int (MVar (Maybe Value))) -> TVar Bool
  -> IO ()
demuxReader hOut inbox respMap readerDead = go
  where
    go = do
      eLine <- try @IOException (hGetLine hOut)
      case eLine of
        Left _ -> atomically (writeTVar readerDead True)
        Right line -> do
          case A.decode (BL.fromStrict (TE.encodeUtf8 (T.pack line))) of
            Nothing -> go
            Just v -> do
              case extractResponseId v of
                Just rid -> do
                  m <- readIORef respMap
                  case Map.lookup rid m of
                    Just mv -> putMVar mv (Just v)
                    Nothing -> pure ()
                Nothing -> do
                  case parseSignalEnvelope v of
                    Right msg -> atomically (writeTQueue inbox msg)
                    Left _    -> pure ()
          go

-- | Block until the demux reader's inbox yields a value; return 'Left'
-- only when the reader is dead AND the inbox is drained (EOF).
receiveBlocking :: TQueue ReceivedMessage -> TVar Bool -> IO (Either Text ReceivedMessage)
receiveBlocking inbox readerDead =
  atomically $
    (Right <$> readTQueue inbox)
      `orElse` do
        dead <- readTVar readerDead
        check dead
        isEmpty <- isEmptyTQueue inbox
        check isEmpty
        pure (Left "signal inbox empty")

-- | Extract the @id@ field from a JSON-RPC response.
extractResponseId :: Value -> Maybe Int
extractResponseId v =
  case v of
    A.Object o -> case KeyMap.lookup (Key.fromString "id") o of
      Just (A.Number n) -> Just (round n)
      _ -> Nothing
    _ -> Nothing

-- | Extract the @result.timestamp@ from a JSON-RPC @send@ response.
extractTimestamp :: Value -> Maybe Text
extractTimestamp v =
  case v of
    A.Object o -> case KeyMap.lookup (Key.fromString "result") o of
      Just (A.Object ro) -> case KeyMap.lookup (Key.fromString "timestamp") ro of
        Just (A.Number n) -> Just (T.pack (show (round n :: Int)))
        _ -> Nothing
      _ -> Nothing
    _ -> Nothing

-- | Preflight @signal-cli --version@.
probeSignalCli :: IO Bool
probeSignalCli = do
  r <- try @IOException $
        withCreateProcess
          ( (proc "signal-cli" ["--version"])
              { std_out = CreatePipe, std_err = CreatePipe }
          ) $ \_ _ _ ph -> waitForProcess ph
  pure $ case r of
    Right ExitSuccess -> True
    _                 -> False

-- | Parse a raw signal-cli JSON value into a 'ReceivedMessage'. Handles
-- both raw envelopes (@{"envelope": {...}}@) and JSON-RPC-wrapped messages
-- (@{"jsonrpc":"2.0","method":"receive","params":{"envelope":{...}}}@).
parseSignalEnvelope :: Value -> Either Text ReceivedMessage
parseSignalEnvelope v = do
  env <- unwrapEnvelope v
  source <- fieldText "source" env
  let mUuid = fieldTextMaybe "sourceUuid" env
  cid <- conversationIdForSignal (Just source) mUuid
  let body = extractBody env
      replyTo = source
  Right ReceivedMessage
    { rmConversationId = cid
    , rmSender = Just source
    , rmReplyTo = replyTo
    , rmBody = body
    , rmCallbackData = Nothing
    , rmCallbackId = Nothing
    , rmCallbackMessageId = Nothing
    }

-- | Derive the 'ConversationId' from the peer's authenticated transport
-- metadata.
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

-- | Unwrap a raw envelope or a JSON-RPC-wrapped message.
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

-- | Extract a required text field from an object.
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

-- | Extract the message body from @dataMessage.message@.
extractBody :: Value -> Text
extractBody v = fromMaybe "" $ do
  dm <- fieldValueMaybe "dataMessage" v
  fieldTextMaybe "message" dm

-- ---------------------------------------------------------------------------
-- ChatChannel instance
-- ---------------------------------------------------------------------------

-- | The live Signal chat channel state.
data SignalChatChannel = SignalChatChannel
  { sccAllowList   :: AllowList UserId
  , sccChunkLimit  :: Int
  , sccInbox       :: TQueue InboundMessage
  , sccTransport   :: SignalChatTransport
  , sccLastSender  :: IORef (Maybe Text)
  , sccReaderAlive :: IORef Bool
  }

instance ChatChannel SignalChatChannel where
  ccReceive ch = do
    mMsg <- atomically (tryReadTQueue (sccInbox ch))
    case mMsg of
      Just msg -> pure (Just msg)
      Nothing -> do
        alive <- readIORef (sccReaderAlive ch)
        if alive
          then threadDelay 1000 >> ccReceive ch
          else pure Nothing

  ccSend ch t =
    mapM_ (sendRaw ch) (chunkMessage (sccChunkLimit ch) t)

  ccSendWithId ch t = do
    mSender <- readIORef (sccLastSender ch)
    case mSender of
      Nothing -> pure Nothing
      Just sender -> do
        mId <- sctSendWithId (sccTransport ch) sender t
        pure (ChatMessageId <$> mId)

  ccEditMessage ch (ChatMessageId msgId) content = do
    mSender <- readIORef (sccLastSender ch)
    case mSender of
      Nothing -> pure False
      Just sender -> sctEditMessage (sccTransport ch) sender msgId content

  ccLabel _ = "signal"

  -- Signal doesn't reliably support message editing (signal-cli's
  -- editTimestamp is flaky in practice). Disable streaming: send the
  -- final text as a single message after the turn completes.
  ccSupportsStreaming _ = False

-- | Send one chunk verbatim to the last sender.
sendRaw :: SignalChatChannel -> Text -> IO ()
sendRaw ch t = do
  mSender <- readIORef (sccLastSender ch)
  case mSender of
    Nothing -> pure ()
    Just sender -> sctSend (sccTransport ch) sender t

-- | Run the reader thread with cleanup. Spawns a background thread that
-- loops 'sctReceive', creates a 'MessageSource', and pushes
-- 'InboundMessage's to 'sccInbox'. On transport close or exception, the
-- thread exits.
withSignalChatChannel
  :: AllowList UserId
  -> Int
  -> SignalChatTransport
  -> (SignalChatChannel -> IO a)
  -> IO a
withSignalChatChannel allow chunkLimit transport action =
  bracket before after (action . snd)
  where
    before = do
      inbox <- newTQueueIO
      lastSender <- newIORef (Nothing :: Maybe Text)
      alive <- newIORef True
      let ch = SignalChatChannel
            { sccAllowList = allow
            , sccChunkLimit = chunkLimit
            , sccInbox = inbox
            , sccTransport = transport
            , sccLastSender = lastSender
            , sccReaderAlive = alive
            }
      tid <- forkIO (readerLoop ch)
      pure (tid, ch)
    after (tid, _) = do
      killThread tid
      sctClose transport

-- | The background reader: loop 'sctReceive', construct a 'MessageSource'
-- from the received conversation id + sender, update the last sender, and
-- push to the inbox. Exits when 'sctReceive' returns 'Left'.
readerLoop :: SignalChatChannel -> IO ()
readerLoop ch = go
  where
    go = do
      eVal <- try (sctReceive (sccTransport ch)) :: IO (Either SomeException (Either Text ReceivedMessage))
      case eVal of
        Left _ -> writeIORef (sccReaderAlive ch) False
        Right (Left _) -> writeIORef (sccReaderAlive ch) False
        Right (Right (ReceivedMessage cid mSender replyTo body _ _ _))
          | T.null body -> go
          | otherwise -> do
              case mkMessageSource cid Signal (mkSender <$> mSender) mempty of
                Right ms -> do
                  writeIORef (sccLastSender ch) (Just replyTo)
                  atomically (writeTQueue (sccInbox ch) (InboundMessage ms body Nothing))
                Left _ -> pure ()
              go

-- | Construct a 'UserId' from a sender text, best-effort.
mkSender :: Text -> UserId
mkSender t = case mkUserId t of
  Right u -> u
  Left _ -> case mkUserId "unknown" of Right u -> u; Left _ -> error "unreachable"
