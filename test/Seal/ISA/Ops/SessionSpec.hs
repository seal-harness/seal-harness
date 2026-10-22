{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.SessionSpec (spec) where

import Control.Concurrent (threadDelay)
import Data.Aeson (encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Config.Paths
  ( SealPaths (..), agentSessionDir, sessionConversationPath
  , sessionConversationIndexPath, sessionDir )
import Seal.Core.Types (SessionId, ToolCallId (..), mkSessionId, sessionIdText)
import Seal.ISA.Opcode
import Seal.ISA.Ops.Session
import Seal.Providers.Class (ContentBlock (..), Message (..), Role (..), ToolResultPart (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (newSession, saveSessionMeta)
import Seal.Session.Search (inMemorySessionSearchBackend)
import Seal.Transcript.Conv (ConvLine (..), encodeConvLine)
import Seal.Transcript.ConvIndex (buildIndex)
import Seal.Types.App (App, runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (mkEnv)
import Seal.Logging.Logger (testSealLogger)

import Data.Either (fromRight)

runTestApp :: App a -> IO a
runTestApp act = do
  logger <- testSealLogger
  env <- mkEnv logger defaultConfig
  runApp env act

-- | Build a SealPaths rooted at the given temp directory.
mkPaths :: FilePath -> SealPaths
mkPaths root = SealPaths
  { spHome = root, spConfig = root </> "config"
  , spState = root </> "state", spKeys = root </> "keys"
  , spCache = root </> "cache"
  }

-- | Write a conversation.jsonl with the given lines (each line is a raw JSON
-- message string).
seedConversation :: SealPaths -> SessionId -> [Text] -> IO ()
seedConversation paths sid msgLines = do
  let dir = sessionDir paths sid
  createDirectoryIfMissing True dir
  writeFile (sessionConversationPath paths sid) $
    T.unpack (T.intercalate "\n" msgLines <> "\n")

-- | A user message JSON line (proper encoding via encodeConvLine).
userMsg :: Text -> Text
userMsg t = TE.decodeUtf8 (encodeConvLine (ConvLine (Message User [CbText t])))

-- | An assistant message JSON line (proper encoding via encodeConvLine).
assistantMsg :: Text -> Text
assistantMsg t = TE.decodeUtf8 (encodeConvLine (ConvLine (Message Assistant [CbText t])))

-- | A tool-result message JSON line (proper encoding via encodeConvLine).
toolResultMsg :: Text -> Text
toolResultMsg t = TE.decodeUtf8
  (encodeConvLine (ConvLine (Message User [CbToolResult (ToolCallId "call-1") [TrpText t] False])))

-- | Mint a fixed, valid SessionId from a literal text (for tests that need
-- deterministic child ids without going through 'newSession').
fixedSessionId :: Text -> SessionId
fixedSessionId t = fromRight (error "invalid fixed session id") (mkSessionId t)

-- | The id of the session "making the call" in tests where the current
-- session differs from the session being read.
callerSessionId :: SessionId
callerSessionId = fixedSessionId "20260101-120000-900"

-- | Write a conversation.jsonl into a child (sub-agent) transcript dir
-- nested under a parent session: @sessions\/\<parent\>\/agents\/\<child\>@.
seedChildConversation :: SealPaths -> SessionId -> SessionId -> [Text] -> IO ()
seedChildConversation paths parentSid childSid msgLines = do
  let dir = agentSessionDir paths parentSid childSid
  createDirectoryIfMissing True dir
  writeFile (dir </> "conversation.jsonl") $
    T.unpack (T.intercalate "\n" msgLines <> "\n")

spec :: Spec
spec = describe "Seal.ISA.Ops.Session" $ do
  describe "SESSION_NEW" $ do
    it "creates a new session and returns its id + metadata" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
            op = sessionNewOp paths
        r <- runTestApp (opRun op localBackend (object []))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] ->
            -- The text should be non-empty (contains session id)
            T.null t `shouldBe` False
          _ -> expectationFailure "expected a single text part"

    it "accepts optional provider/model/description" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
            op = sessionNewOp paths
        r <- runTestApp (opRun op localBackend
          (object
            [ "provider" .= ("ollama" :: Text)
            , "model" .= ("llama3" :: Text)
            , "description" .= ("test session" :: Text)
            ]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> T.isInfixOf "ollama" t `shouldBe` True
          _ -> expectationFailure "expected a single text part"

  describe "SESSION_LIST" $ do
    it "returns an empty message when no sessions exist" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
            op = sessionListOp paths
        r <- runTestApp (opRun op localBackend (object []))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> t `shouldBe` "(no sessions found)"
          _ -> expectationFailure "expected a single text part"

    it "lists existing sessions with id, provider, model" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        _ <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        let op = sessionListOp paths
        r <- runTestApp (opRun op localBackend (object []))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            T.isInfixOf "claude-opus-4" t `shouldBe` True
            T.isInfixOf "anthropic" t `shouldBe` True
          _ -> expectationFailure "expected a single text part"

  describe "SESSION_SEARCH" $ do
    it "returns no matches for an empty session store" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
            op = sessionSearchOp paths inMemorySessionSearchBackend callerSessionId
        r <- runTestApp (opRun op localBackend (object ["query" .= ("anything" :: Text)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> t `shouldBe` "(no sessions found)"
          _ -> expectationFailure "expected a single text part"

    it "errors on missing query" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
            op = sessionSearchOp paths inMemorySessionSearchBackend callerSessionId
        r <- runTestApp (opRun op localBackend (object []))
        orIsError r `shouldBe` True

    it "errors on empty query" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
            op = sessionSearchOp paths inMemorySessionSearchBackend callerSessionId
        r <- runTestApp (opRun op localBackend (object ["query" .= ("" :: Text)]))
        orIsError r `shouldBe` True

    it "finds sessions by description match" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        saveSessionMeta paths (meta { smDescription = Just "debug the auth flow" })
        let op = sessionSearchOp paths inMemorySessionSearchBackend callerSessionId
        r <- runTestApp (opRun op localBackend (object ["query" .= ("auth" :: Text)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> T.isInfixOf "auth" t `shouldBe` True
          _ -> expectationFailure "expected a single text part"

    it "finds sessions by first user message snippet" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "How do I fix the database connection pool?"
          , assistantMsg "Let me look into that."
          ]
        let op = sessionSearchOp paths inMemorySessionSearchBackend callerSessionId
        r <- runTestApp (opRun op localBackend (object ["query" .= ("database" :: Text)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> T.isInfixOf "database" t `shouldBe` True
          _ -> expectationFailure "expected a single text part"

    it "does not match non-existent query" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        saveSessionMeta paths (meta { smDescription = Just "debug the auth flow" })
        let op = sessionSearchOp paths inMemorySessionSearchBackend callerSessionId
        r <- runTestApp (opRun op localBackend (object ["query" .= ("kubernetes" :: Text)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> t `shouldBe` "(no sessions found)"
          _ -> expectationFailure "expected a single text part"

  describe "SESSION_GET" $ do
    it "errors on missing session id" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
            op = sessionGetOp paths callerSessionId
        r <- runTestApp (opRun op localBackend (object []))
        orIsError r `shouldBe` True

    it "errors on non-existent session" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
            op = sessionGetOp paths callerSessionId
        r <- runTestApp (opRun op localBackend (object ["session_id" .= ("20260101-120000-000" :: Text)]))
        orIsError r `shouldBe` True

    it "returns transcript entries for a session with conversation" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "Hello world"
          , assistantMsg "Hi there"
          ]
        let op = sessionGetOp paths callerSessionId
        r <- runTestApp (opRun op localBackend
          (object ["session_id" .= sessionIdText (smId meta)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            T.isInfixOf "Hello world" t `shouldBe` True
            T.isInfixOf "Hi there" t `shouldBe` True
            -- Should have a pagination footer
            T.isInfixOf "messages" t `shouldBe` True
          _ -> expectationFailure "expected a single text part"

    it "paginates with offset" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "msg0"
          , assistantMsg "msg1"
          , userMsg "msg2"
          , assistantMsg "msg3"
          , userMsg "msg4"
          , assistantMsg "msg5"
          ]
        let op = sessionGetOp paths callerSessionId
        r <- runTestApp (opRun op localBackend
          (object
            [ "order" .= ("front-to-back" :: Text)
            , "session_id" .= sessionIdText (smId meta)
            , "offset" .= (4 :: Int)
            , "limit" .= (2 :: Int)
            ]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            T.isInfixOf "msg4" t `shouldBe` True
            T.isInfixOf "msg5" t `shouldBe` True
            T.isInfixOf "msg0" t `shouldBe` False
          _ -> expectationFailure "expected a single text part"

    it "defaults to back-to-front (last messages first)" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "msg0"
          , assistantMsg "msg1"
          , userMsg "msg2"
          , assistantMsg "msg3"
          , userMsg "msg4"
          , assistantMsg "msg5"
          ]
        let op = sessionGetOp paths callerSessionId
        r <- runTestApp (opRun op localBackend
          (object
            [ "session_id" .= sessionIdText (smId meta)
            , "limit" .= (2 :: Int)
            ]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            -- Default order is back-to-front, so we get the last 2 messages.
            T.isInfixOf "msg4" t `shouldBe` True
            T.isInfixOf "msg5" t `shouldBe` True
            T.isInfixOf "msg0" t `shouldBe` False
            T.isInfixOf "msg1" t `shouldBe` False
          _ -> expectationFailure "expected a single text part"

    it "back-to-front paginates from the end with offset" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "msg0"
          , assistantMsg "msg1"
          , userMsg "msg2"
          , assistantMsg "msg3"
          , userMsg "msg4"
          , assistantMsg "msg5"
          ]
        let op = sessionGetOp paths callerSessionId
        r <- runTestApp (opRun op localBackend
          (object
            [ "session_id" .= sessionIdText (smId meta)
            , "order" .= ("back-to-front" :: Text)
            , "offset" .= (2 :: Int)
            , "limit" .= (2 :: Int)
            ]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            -- offset=2 from end skips msg4/msg5, returns msg2/msg3.
            T.isInfixOf "msg2" t `shouldBe` True
            T.isInfixOf "msg3" t `shouldBe` True
            T.isInfixOf "msg4" t `shouldBe` False
            T.isInfixOf "msg5" t `shouldBe` False
            T.isInfixOf "msg0" t `shouldBe` False
          _ -> expectationFailure "expected a single text part"

    it "back-to-front renders messages in chronological order within window" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "alpha"
          , assistantMsg "beta"
          , userMsg "gamma"
          ]
        let op = sessionGetOp paths callerSessionId
        r <- runTestApp (opRun op localBackend
          (object
            [ "session_id" .= sessionIdText (smId meta)
            , "order" .= ("back-to-front" :: Text)
            , "limit" .= (2 :: Int)
            ]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            -- Window is messages 2-3 (beta, gamma), in that order.
            let betaPos = T.length (fst (T.breakOn "beta" t))
                gammaPos = T.length (fst (T.breakOn "gamma" t))
            -- beta should appear before gamma in the rendered text.
            betaPos `shouldSatisfy` (< gammaPos)
          _ -> expectationFailure "expected a single text part"

    it "returns metadata header for the session" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        saveSessionMeta paths (meta { smDescription = Just "my test session" })
        seedConversation paths (smId meta) [ userMsg "hi" ]
        let op = sessionGetOp paths callerSessionId
        r <- runTestApp (opRun op localBackend
          (object ["session_id" .= sessionIdText (smId meta)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> T.isInfixOf "my test session" t `shouldBe` True
          _ -> expectationFailure "expected a single text part"

  describe "secret discipline" $ do
    it "orRecorded never contains transcript content" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "secret-value-123"
          ]
        let op = sessionGetOp paths callerSessionId
        r <- runTestApp (opRun op localBackend
          (object ["session_id" .= sessionIdText (smId meta)]))
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf "secret-value-123" recorded `shouldBe` False

  -- -----------------------------------------------------------------------
  -- SESSION_MANAGE (consolidated opcode)
  -- -----------------------------------------------------------------------
  describe "SESSION_MANAGE" $ do
    describe "action = new" $ do
      it "creates a new session and returns its id + metadata" $ do
        withSystemTempDirectory "seal-session-spec" $ \tmp -> do
          let paths = mkPaths tmp
              op = sessionManageOp paths inMemorySessionSearchBackend callerSessionId
          r <- runTestApp (opRun op localBackend (object ["action" .= ("new" :: Text)]))
          orIsError r `shouldBe` False
          case orParts r of
            [TrpText t] -> T.null t `shouldBe` False
            _ -> expectationFailure "expected a single text part"

      it "accepts optional provider/model/description" $ do
        withSystemTempDirectory "seal-session-spec" $ \tmp -> do
          let paths = mkPaths tmp
              op = sessionManageOp paths inMemorySessionSearchBackend callerSessionId
          r <- runTestApp (opRun op localBackend
            (object
              [ "action" .= ("new" :: Text)
              , "provider" .= ("ollama" :: Text)
              , "model" .= ("llama3" :: Text)
              , "description" .= ("test session" :: Text)
              ]))
          orIsError r `shouldBe` False
          case orParts r of
            [TrpText t] -> T.isInfixOf "ollama" t `shouldBe` True
            _ -> expectationFailure "expected a single text part"

    describe "action = list" $ do
      it "returns an empty message when no sessions exist" $ do
        withSystemTempDirectory "seal-session-spec" $ \tmp -> do
          let paths = mkPaths tmp
              op = sessionManageOp paths inMemorySessionSearchBackend callerSessionId
          r <- runTestApp (opRun op localBackend (object ["action" .= ("list" :: Text)]))
          orIsError r `shouldBe` False
          case orParts r of
            [TrpText t] -> t `shouldBe` "(no sessions found)"
            _ -> expectationFailure "expected a single text part"

      it "lists existing sessions" $ do
        withSystemTempDirectory "seal-session-spec" $ \tmp -> do
          let paths = mkPaths tmp
          _ <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
          let op = sessionManageOp paths inMemorySessionSearchBackend callerSessionId
          r <- runTestApp (opRun op localBackend (object ["action" .= ("list" :: Text)]))
          orIsError r `shouldBe` False
          case orParts r of
            [TrpText t] -> do
              T.isInfixOf "claude-opus-4" t `shouldBe` True
              T.isInfixOf "anthropic" t `shouldBe` True
            _ -> expectationFailure "expected a single text part"

    describe "action = search" $ do
      it "finds sessions by description match" $ do
        withSystemTempDirectory "seal-session-spec" $ \tmp -> do
          let paths = mkPaths tmp
          meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
          saveSessionMeta paths (meta { smDescription = Just "debug the auth flow" })
          let op = sessionManageOp paths inMemorySessionSearchBackend callerSessionId
          r <- runTestApp (opRun op localBackend
            (object ["action" .= ("search" :: Text), "query" .= ("auth" :: Text)]))
          orIsError r `shouldBe` False
          case orParts r of
            [TrpText t] -> T.isInfixOf "auth" t `shouldBe` True
            _ -> expectationFailure "expected a single text part"

      it "errors on missing query" $ do
        withSystemTempDirectory "seal-session-spec" $ \tmp -> do
          let paths = mkPaths tmp
              op = sessionManageOp paths inMemorySessionSearchBackend callerSessionId
          r <- runTestApp (opRun op localBackend (object ["action" .= ("search" :: Text)]))
          orIsError r `shouldBe` True

    describe "action = get" $ do
      it "returns transcript entries for a session with conversation" $ do
        withSystemTempDirectory "seal-session-spec" $ \tmp -> do
          let paths = mkPaths tmp
          meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
          seedConversation paths (smId meta)
            [ userMsg "Hello world"
            , assistantMsg "Hi there"
            ]
          let op = sessionManageOp paths inMemorySessionSearchBackend callerSessionId
          r <- runTestApp (opRun op localBackend
            (object
              [ "action" .= ("get" :: Text)
              , "session_id" .= sessionIdText (smId meta)
              ]))
          orIsError r `shouldBe` False
          case orParts r of
            [TrpText t] -> do
              T.isInfixOf "Hello world" t `shouldBe` True
              T.isInfixOf "Hi there" t `shouldBe` True
            _ -> expectationFailure "expected a single text part"

      it "respects order=back-to-front" $ do
        withSystemTempDirectory "seal-session-spec" $ \tmp -> do
          let paths = mkPaths tmp
          meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
          seedConversation paths (smId meta)
            [ userMsg "msg0"
            , assistantMsg "msg1"
            , userMsg "msg2"
            , assistantMsg "msg3"
            , userMsg "msg4"
            , assistantMsg "msg5"
            ]
          let op = sessionManageOp paths inMemorySessionSearchBackend callerSessionId
          r <- runTestApp (opRun op localBackend
            (object
              [ "action" .= ("get" :: Text)
              , "session_id" .= sessionIdText (smId meta)
              , "order" .= ("back-to-front" :: Text)
              , "limit" .= (2 :: Int)
              ]))
          orIsError r `shouldBe` False
          case orParts r of
            [TrpText t] -> do
              T.isInfixOf "msg4" t `shouldBe` True
              T.isInfixOf "msg5" t `shouldBe` True
              T.isInfixOf "msg0" t `shouldBe` False
            _ -> expectationFailure "expected a single text part"

      it "errors on missing session_id" $ do
        withSystemTempDirectory "seal-session-spec" $ \tmp -> do
          let paths = mkPaths tmp
              op = sessionManageOp paths inMemorySessionSearchBackend callerSessionId
          r <- runTestApp (opRun op localBackend (object ["action" .= ("get" :: Text)]))
          orIsError r `shouldBe` True

    describe "authorize gate" $ do
      it "accepts new with no extra fields" $
        opAuthorize (sessionManageOp undefined inMemorySessionSearchBackend callerSessionId)
          (object ["action" .= ("new" :: Text)])
          `shouldBe` Right ()

      it "accepts list with no extra fields" $
        opAuthorize (sessionManageOp undefined inMemorySessionSearchBackend callerSessionId)
          (object ["action" .= ("list" :: Text)])
          `shouldBe` Right ()

      it "rejects search without query" $
        opAuthorize (sessionManageOp undefined inMemorySessionSearchBackend callerSessionId)
          (object ["action" .= ("search" :: Text)])
          `shouldBe` Left "search requires {query:string}"

      it "rejects get without session_id" $
        opAuthorize (sessionManageOp undefined inMemorySessionSearchBackend callerSessionId)
          (object ["action" .= ("get" :: Text)])
          `shouldBe` Left "get requires {session_id:string}"

      it "rejects unknown action" $
        opAuthorize (sessionManageOp undefined inMemorySessionSearchBackend callerSessionId)
          (object ["action" .= ("frobnicate" :: Text)])
          `shouldBe` Left "unknown session action: frobnicate"

  -- -----------------------------------------------------------------------
  -- Self-read guard (a session cannot read its own transcript)
  -- -----------------------------------------------------------------------
  describe "self-read guard" $ do
    it "SESSION_MANAGE get on the current session is refused" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "Hello world"
          , assistantMsg "Hi there"
          ]
        let op = sessionManageOp paths inMemorySessionSearchBackend (smId meta)
        r <- runTestApp (opRun op localBackend
          (object
            [ "action" .= ("get" :: Text)
            , "session_id" .= sessionIdText (smId meta)
            ]))
        orIsError r `shouldBe` True
        case orParts r of
          [TrpText t] -> do
            T.isInfixOf "current session" t `shouldBe` True
            T.isInfixOf "Hello world" t `shouldBe` False
            T.isInfixOf "Hi there" t `shouldBe` False
          _ -> expectationFailure "expected a single text part"

    it "SESSION_GET (legacy) on the current session is refused" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "Hello world"
          , assistantMsg "Hi there"
          ]
        let op = sessionGetOp paths (smId meta)
        r <- runTestApp (opRun op localBackend
          (object ["session_id" .= sessionIdText (smId meta)]))
        orIsError r `shouldBe` True
        case orParts r of
          [TrpText t] -> do
            T.isInfixOf "current session" t `shouldBe` True
            T.isInfixOf "Hello world" t `shouldBe` False
          _ -> expectationFailure "expected a single text part"

    it "a child agent reading its own transcript is refused" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        parentMeta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        let childSid = fixedSessionId "20260101-120000-005"
        seedChildConversation paths (smId parentMeta) childSid
          [ userMsg "child hello world"
          , assistantMsg "child response"
          ]
        -- The child's own registry is built with the child's session id.
        let op = sessionGetOp paths childSid
        r <- runTestApp (opRun op localBackend
          (object ["session_id" .= sessionIdText childSid]))
        orIsError r `shouldBe` True
        case orParts r of
          [TrpText t] -> do
            T.isInfixOf "current session" t `shouldBe` True
            T.isInfixOf "child hello world" t `shouldBe` False
          _ -> expectationFailure "expected a single text part"

    it "get on a different session still succeeds" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "Hello world"
          , assistantMsg "Hi there"
          ]
        let op = sessionManageOp paths inMemorySessionSearchBackend callerSessionId
        r <- runTestApp (opRun op localBackend
          (object
            [ "action" .= ("get" :: Text)
            , "session_id" .= sessionIdText (smId meta)
            ]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> T.isInfixOf "Hello world" t `shouldBe` True
          _ -> expectationFailure "expected a single text part"

    it "records self-read refusals in orRecorded without transcript content" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "secret-value-123"
          ]
        let op = sessionGetOp paths (smId meta)
        r <- runTestApp (opRun op localBackend
          (object ["session_id" .= sessionIdText (smId meta)]))
        orIsError r `shouldBe` True
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf (sessionIdText (smId meta)) recorded `shouldBe` True
        T.isInfixOf "\"self_read\":true" recorded `shouldBe` True
        T.isInfixOf "secret-value-123" recorded `shouldBe` False

  -- -----------------------------------------------------------------------
  -- Search self-exclusion (a session never sees itself in search results)
  -- -----------------------------------------------------------------------
  describe "search self-exclusion" $ do
    it "SESSION_MANAGE search does not include the current session in results" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "How do I fix the database connection pool?"
          , assistantMsg "Let me look into that."
          ]
        let op = sessionManageOp paths inMemorySessionSearchBackend (smId meta)
        r <- runTestApp (opRun op localBackend
          (object
            [ "action" .= ("search" :: Text)
            , "query" .= ("database" :: Text)
            ]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            t `shouldBe` "(no sessions found)"
            T.isInfixOf (sessionIdText (smId meta)) t `shouldBe` False
          _ -> expectationFailure "expected a single text part"
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf (sessionIdText (smId meta)) recorded `shouldBe` False

    it "SESSION_SEARCH (legacy) does not include the current session in results" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "How do I fix the database connection pool?"
          , assistantMsg "Let me look into that."
          ]
        let op = sessionSearchOp paths inMemorySessionSearchBackend (smId meta)
        r <- runTestApp (opRun op localBackend
          (object ["query" .= ("database" :: Text)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            t `shouldBe` "(no sessions found)"
            T.isInfixOf (sessionIdText (smId meta)) t `shouldBe` False
          _ -> expectationFailure "expected a single text part"

    it "search finds other sessions while excluding the current session" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        currentMeta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        -- Session ids are millisecond-resolution timestamps; two
        -- back-to-back newSession calls can mint the same id (a
        -- pre-existing flake). Sleep past the boundary so the ids
        -- are guaranteed distinct.
        threadDelay 2000
        otherMeta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId currentMeta)
          [ userMsg "database connection pool question" ]
        seedConversation paths (smId otherMeta)
          [ userMsg "database connection pool answer" ]
        let op = sessionManageOp paths inMemorySessionSearchBackend (smId currentMeta)
        r <- runTestApp (opRun op localBackend
          (object
            [ "action" .= ("search" :: Text)
            , "query" .= ("database" :: Text)
            ]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            T.isInfixOf (sessionIdText (smId otherMeta)) t `shouldBe` True
            T.isInfixOf (sessionIdText (smId currentMeta)) t `shouldBe` False
          _ -> expectationFailure "expected a single text part"
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf (sessionIdText (smId otherMeta)) recorded `shouldBe` True
        T.isInfixOf (sessionIdText (smId currentMeta)) recorded `shouldBe` False

    it "a child agent's own transcript is excluded from search results" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        parentMeta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        let childSid = fixedSessionId "20260101-120000-006"
        seedChildConversation paths (smId parentMeta) childSid
          [ userMsg "debug the subagent database pool"
          ]
        let op = sessionSearchOp paths inMemorySessionSearchBackend childSid
        r <- runTestApp (opRun op localBackend
          (object ["query" .= ("database" :: Text)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            t `shouldBe` "(no sessions found)"
            T.isInfixOf (sessionIdText childSid) t `shouldBe` False
          _ -> expectationFailure "expected a single text part"

  -- -----------------------------------------------------------------------
  -- Child (sub-agent) session visibility
  -- -----------------------------------------------------------------------
  describe "child session visibility" $ do
    it "SESSION_GET returns the child's messages for a child session id" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        parentMeta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        let childSid = fixedSessionId "20260101-120000-001"
        seedChildConversation paths (smId parentMeta) childSid
          [ userMsg "child hello world"
          , assistantMsg "child response"
          ]
        let op = sessionGetOp paths callerSessionId
        r <- runTestApp (opRun op localBackend
          (object ["session_id" .= sessionIdText childSid]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            T.isInfixOf "child hello world" t `shouldBe` True
            T.isInfixOf "child response" t `shouldBe` True
            T.isInfixOf "child session of" t `shouldBe` True
            T.isInfixOf (sessionIdText (smId parentMeta)) t `shouldBe` True
          _ -> expectationFailure "expected a single text part"

    it "SESSION_SEARCH finds child transcript content" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        parentMeta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        let childSid = fixedSessionId "20260101-120000-002"
        seedChildConversation paths (smId parentMeta) childSid
          [ userMsg "debug the subagent grpc pool"
          ]
        let op = sessionSearchOp paths inMemorySessionSearchBackend callerSessionId
        r <- runTestApp (opRun op localBackend
          (object ["query" .= ("grpc" :: Text)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            T.isInfixOf "grpc" t `shouldBe` True
            T.isInfixOf "child of" t `shouldBe` True
            T.isInfixOf (sessionIdText (smId parentMeta)) t `shouldBe` True
          _ -> expectationFailure "expected a single text part"

    it "SESSION_LIST with include_children=true shows the child with attribution" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        parentMeta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        let childSid = fixedSessionId "20260101-120000-003"
        seedChildConversation paths (smId parentMeta) childSid
          [ userMsg "child work"
          ]
        let op = sessionListOp paths
        r <- runTestApp (opRun op localBackend
          (object ["include_children" .= True]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            T.isInfixOf "child of" t `shouldBe` True
            T.isInfixOf (sessionIdText childSid) t `shouldBe` True
            T.isInfixOf (sessionIdText (smId parentMeta)) t `shouldBe` True
          _ -> expectationFailure "expected a single text part"

    it "SESSION_LIST without include_children omits child sessions" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        parentMeta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        let childSid = fixedSessionId "20260101-120000-004"
        seedChildConversation paths (smId parentMeta) childSid
          [ userMsg "child work"
          ]
        let op = sessionListOp paths
        r <- runTestApp (opRun op localBackend (object []))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            T.isInfixOf (sessionIdText childSid) t `shouldBe` False
            T.isInfixOf (sessionIdText (smId parentMeta)) t `shouldBe` True
          _ -> expectationFailure "expected a single text part"

  -- -----------------------------------------------------------------------
  -- Byte budget + conversation.idx windowed reads
  -- -----------------------------------------------------------------------
  describe "byte budget and conversation.idx reads" $ do
    it "reads the same window via conversation.idx as via the whole-file path" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "msg0"
          , assistantMsg "msg1"
          , userMsg "msg2"
          , assistantMsg "msg3"
          , userMsg "msg4"
          , assistantMsg "msg5"
          ]
        let op = sessionGetOp paths callerSessionId
            readVia args = runTestApp (opRun op localBackend
              (object ([ "session_id" .= sessionIdText (smId meta) ] <> args)))
            argsAsc = [ "order" .= ("front-to-back" :: Text)
                      , "offset" .= (4 :: Int), "limit" .= (2 :: Int) ]
            argsDesc = [ "order" .= ("back-to-front" :: Text)
                       , "offset" .= (2 :: Int), "limit" .= (2 :: Int) ]
            argsPast = [ "order" .= ("front-to-back" :: Text)
                       , "offset" .= (50 :: Int), "limit" .= (2 :: Int) ]
        asc1 <- readVia argsAsc
        desc1 <- readVia argsDesc
        past1 <- readVia argsPast
        _ <- buildIndex (sessionConversationPath paths (smId meta))
                        (sessionConversationIndexPath paths (smId meta))
        asc2 <- readVia argsAsc
        desc2 <- readVia argsDesc
        past2 <- readVia argsPast
        (asc2, desc2, past2) `shouldBe` (asc1, desc1, past1)
        orIsError asc2 `shouldBe` False
        case orParts asc2 of
          [TrpText t] -> do
            T.isInfixOf "msg4" t `shouldBe` True
            T.isInfixOf "msg5" t `shouldBe` True
            T.isInfixOf "msg0" t `shouldBe` False
            -- Small transcripts are never cut: no markers, no notice.
            T.isInfixOf "[content truncated]" t `shouldBe` False
            T.isInfixOf "output truncated at" t `shouldBe` False
          _ -> expectationFailure "expected a single text part"
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded asc2)))
        T.isInfixOf "\"truncated\":false" recorded `shouldBe` True
        case orParts desc2 of
          [TrpText t] -> do
            T.isInfixOf "msg2" t `shouldBe` True
            T.isInfixOf "msg3" t `shouldBe` True
            T.isInfixOf "msg4" t `shouldBe` False
          _ -> expectationFailure "expected a single text part"

    it "uses the idx line count as total when the index is present" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "ok alpha"
          , "{not a json message line"
          , userMsg "ok beta"
          ]
        let op = sessionGetOp paths callerSessionId
            args = object ["session_id" .= sessionIdText (smId meta)]
        beforeIdx <- runTestApp (opRun op localBackend args)
        _ <- buildIndex (sessionConversationPath paths (smId meta))
                        (sessionConversationIndexPath paths (smId meta))
        afterIdx <- runTestApp (opRun op localBackend args)
        orIsError afterIdx `shouldBe` False
        case orParts afterIdx of
          [TrpText t] -> do
            T.isInfixOf "ok alpha" t `shouldBe` True
            T.isInfixOf "ok beta" t `shouldBe` True
            T.isInfixOf "of 3" t `shouldBe` True
          _ -> expectationFailure "expected a single text part"
        let recordedBefore = TE.decodeUtf8 (BL.toStrict (encode (orRecorded beforeIdx)))
            recordedAfter = TE.decodeUtf8 (BL.toStrict (encode (orRecorded afterIdx)))
        T.isInfixOf "\"total_messages\":2" recordedBefore `shouldBe` True
        T.isInfixOf "\"total_messages\":3" recordedAfter `shouldBe` True

    it "bounds the rendered page to the byte budget on a large transcript (idx path)" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        let bigMsgs =
              [ toolResultMsg ("budget payload " <> T.pack (show i) <> " "
                  <> T.replicate 1200 "x")
              | i <- [0 .. 199 :: Int] ]
        seedConversation paths (smId meta) bigMsgs
        _ <- buildIndex (sessionConversationPath paths (smId meta))
                        (sessionConversationIndexPath paths (smId meta))
        let op = sessionGetOp paths callerSessionId
        r <- runTestApp (opRun op localBackend
          (object [ "session_id" .= sessionIdText (smId meta)
                  , "limit" .= (200 :: Int) ]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            -- getRenderBudgetBytes is 98304: the whole rendered page fits.
            BS.length (TE.encodeUtf8 t) `shouldSatisfy` (<= 98304)
            T.isInfixOf "output truncated at" t `shouldBe` True
            T.isInfixOf "narrow the window (limit / offset)" t `shouldBe` True
            T.isInfixOf "[content truncated]" t `shouldBe` False
            T.isInfixOf "messages 1-200 of 200" t `shouldBe` True
            T.isInfixOf "budget payload 0 " t `shouldBe` True
            T.isInfixOf "budget payload 199 " t `shouldBe` False
          _ -> expectationFailure "expected a single text part"
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf "\"truncated\":true" recorded `shouldBe` True
        T.isInfixOf "payload" recorded `shouldBe` False

    it "bounds the rendered page to the byte budget without an index (fallback)" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        let bigMsgs =
              [ toolResultMsg ("budget payload " <> T.pack (show i) <> " "
                  <> T.replicate 1200 "x")
              | i <- [0 .. 199 :: Int] ]
        seedConversation paths (smId meta) bigMsgs
        let op = sessionGetOp paths callerSessionId
        r <- runTestApp (opRun op localBackend
          (object [ "session_id" .= sessionIdText (smId meta)
                  , "limit" .= (200 :: Int) ]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            BS.length (TE.encodeUtf8 t) `shouldSatisfy` (<= 98304)
            T.isInfixOf "output truncated at" t `shouldBe` True
            T.isInfixOf "budget payload 0 " t `shouldBe` True
            T.isInfixOf "budget payload 199 " t `shouldBe` False
          _ -> expectationFailure "expected a single text part"
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf "\"truncated\":true" recorded `shouldBe` True

    it "truncates a single huge message to the per-message cap with a visible marker" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        let bigText = "permsg-head-marker "
                      <> T.replicate 10000 "0123456789"
                      <> " permsg-tail-marker-xyzzy"
        seedConversation paths (smId meta) [ userMsg bigText ]
        let op = sessionGetOp paths callerSessionId
        r <- runTestApp (opRun op localBackend
          (object [ "session_id" .= sessionIdText (smId meta)
                  , "limit" .= (1 :: Int) ]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            T.isInfixOf "[content truncated]" t `shouldBe` True
            T.isInfixOf "permsg-head-marker" t `shouldBe` True
            T.isInfixOf "permsg-tail-marker-xyzzy" t `shouldBe` False
            T.isInfixOf "output truncated at" t `shouldBe` False
            BS.length (TE.encodeUtf8 t) `shouldSatisfy` (< 20000)
          _ -> expectationFailure "expected a single text part"
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf "\"truncated\":true" recorded `shouldBe` True
        T.isInfixOf "permsg" recorded `shouldBe` False

    it "reads a child session window identically via conversation.idx" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        parentMeta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        let childSid = fixedSessionId "20260101-120000-007"
        seedChildConversation paths (smId parentMeta) childSid
          [ userMsg "child alpha"
          , assistantMsg "child beta"
          , userMsg "child gamma"
          ]
        let op = sessionGetOp paths callerSessionId
            args = object
              [ "session_id" .= sessionIdText childSid
              , "limit" .= (2 :: Int)
              ]
        beforeIdx <- runTestApp (opRun op localBackend args)
        let childDir = agentSessionDir paths (smId parentMeta) childSid
        _ <- buildIndex (childDir </> "conversation.jsonl") (childDir </> "conversation.idx")
        afterIdx <- runTestApp (opRun op localBackend args)
        orIsError afterIdx `shouldBe` False
        afterIdx `shouldBe` beforeIdx
        case orParts afterIdx of
          [TrpText t] -> do
            T.isInfixOf "child beta" t `shouldBe` True
            T.isInfixOf "child gamma" t `shouldBe` True
            T.isInfixOf "child alpha" t `shouldBe` False
            T.isInfixOf "child session of" t `shouldBe` True
          _ -> expectationFailure "expected a single text part"

    it "caps an oversized session-meta header to the header byte budget" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        saveSessionMeta paths
          (meta { smDescription = Just (T.replicate 65536 "d") })
        seedConversation paths (smId meta)
          [ userMsg "tiny body alpha", assistantMsg "tiny body beta" ]
        let op = sessionGetOp paths callerSessionId
        r <- runTestApp (opRun op localBackend
          (object ["session_id" .= sessionIdText (smId meta)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            -- getRenderHeaderBytes is 2048: the header line (which embeds
            -- the session description verbatim) is cut at the cap even
            -- though the description alone is 64 KiB.
            let headerLine = T.takeWhile (/= '\n') t
            BS.length (TE.encodeUtf8 headerLine) `shouldSatisfy` (<= 2048)
            T.isInfixOf "[content truncated]" t `shouldBe` True
            -- The transcript itself is tiny: the body survives whole and
            -- the page budget (not the header cap) did no further cutting.
            T.isInfixOf "tiny body alpha" t `shouldBe` True
            T.isInfixOf "tiny body beta" t `shouldBe` True
            T.isInfixOf "output truncated at" t `shouldBe` False
            -- getRenderBudgetBytes is 98304: the whole rendered page fits.
            BS.length (TE.encodeUtf8 t) `shouldSatisfy` (<= 98304)
          _ -> expectationFailure "expected a single text part"
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf "\"truncated\":true" recorded `shouldBe` True
        T.isInfixOf "dddd" recorded `shouldBe` False

    it "leaves a short session description header whole (no marker, not truncated)" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        saveSessionMeta paths
          (meta { smDescription = Just "short description" })
        seedConversation paths (smId meta) [ userMsg "tiny body alpha" ]
        let op = sessionGetOp paths callerSessionId
        r <- runTestApp (opRun op localBackend
          (object ["session_id" .= sessionIdText (smId meta)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            T.isInfixOf "short description" t `shouldBe` True
            T.isInfixOf "[content truncated]" t `shouldBe` False
            T.isInfixOf "output truncated at" t `shouldBe` False
            BS.length (TE.encodeUtf8 t) `shouldSatisfy` (<= 98304)
          _ -> expectationFailure "expected a single text part"
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf "\"truncated\":false" recorded `shouldBe` True
