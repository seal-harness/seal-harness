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
  , chunkMessage
  ) where

import Control.Concurrent.STM (atomically, newTQueueIO, tryReadTQueue, writeTQueue)
import Control.Exception (IOException, try)
import Data.Aeson (Value)
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as BL
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import System.Exit (ExitCode (..))
import System.IO (BufferMode (..), hClose, hFlush, hGetLine, hSetBuffering)
import System.Process
  ( CreateProcess (..), StdStream (..), proc, terminateProcess, waitForProcess
  , withCreateProcess )
import System.Timeout (timeout)

-- | The testability seam over signal-cli.
data SignalTransport = SignalTransport
  { stReceive :: IO (Either Text Value)
    -- ^ Next inbound JSON value (one line from signal-cli's stdout).
  , stSend    :: Text -> Text -> IO ()
    -- ^ Send a message: recipient, body. Writes a JSON-RPC @send@ frame.
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
  let transport = SignalTransport
        { stReceive = do
            m <- atomically (tryReadTQueue q)
            case m of
              Just v  -> pure (Right v)
              Nothing -> pure (Left "signal inbox empty")
        , stSend = \r b -> modifyIORef' capRef ((r, b) :)
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
    then pure (Left "signal-cli not installed or not on PATH")
    else do
      eStarted <- try @IOException $
        withCreateProcess
          ( (proc "signal-cli"
              [ "--output=json"
              , "--trust-new-identities=always"
              , "-u", T.unpack account
              , "jsonRpc"
              ])
              { std_in = CreatePipe, std_out = CreatePipe, std_err = Inherit }
          ) $ \mIn mOut _err ph -> do
            (hIn, hOut) <- case (mIn, mOut) of
              (Just a, Just b) -> pure (a, b)
              _ -> error "mkRealSignalTransport: pipe creation failed (unreachable)"
            hSetBuffering hIn (BlockBuffering Nothing)
            hSetBuffering hOut LineBuffering
            pure (hIn, hOut, ph)
      case eStarted of
        Left e -> pure (Left ("signal-cli launch failed: " <> T.pack (show e)))
        Right (hIn, hOut, ph) ->
          pure (Right SignalTransport
            { stReceive = do
                line <- hGetLine hOut
                pure $ case A.decode (BL.fromStrict (TE.encodeUtf8 (T.pack line))) of
                  Just v  -> Right v
                  Nothing -> Left ("signal-cli: malformed JSON line: " <> T.pack line)
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
            , stClose = do
                _ <- try @IOException (hClose hIn)
                terminateProcess ph
                _ <- timeout 5000000 (waitForProcess ph)
                pure ()
            })

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