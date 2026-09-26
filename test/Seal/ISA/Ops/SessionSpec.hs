{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.SessionSpec (spec) where

import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Config.Paths
  ( SealPaths (..), agentSessionDir, sessionConversationPath, sessionDir )
import Seal.Core.Types (SessionId, mkSessionId, sessionIdText)
import Seal.ISA.Opcode
import Seal.ISA.Ops.Session
import Seal.Providers.Class (ContentBlock (..), Message (..), Role (..), ToolResultPart (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (newSession, saveSessionMeta)
import Seal.Session.Search (inMemorySessionSearchBackend)
import Seal.Transcript.Conv (ConvLine (..), encodeConvLine)
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

-- | Mint a fixed, valid SessionId from a literal text (for tests that need
-- deterministic child ids without going through 'newSession').
fixedSessionId :: Text -> SessionId
fixedSessionId t = fromRight (error "invalid fixed session id") (mkSessionId t)

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
            op = sessionSearchOp paths inMemorySessionSearchBackend
        r <- runTestApp (opRun op localBackend (object ["query" .= ("anything" :: Text)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> t `shouldBe` "(no sessions found)"
          _ -> expectationFailure "expected a single text part"

    it "errors on missing query" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
            op = sessionSearchOp paths inMemorySessionSearchBackend
        r <- runTestApp (opRun op localBackend (object []))
        orIsError r `shouldBe` True

    it "errors on empty query" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
            op = sessionSearchOp paths inMemorySessionSearchBackend
        r <- runTestApp (opRun op localBackend (object ["query" .= ("" :: Text)]))
        orIsError r `shouldBe` True

    it "finds sessions by description match" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        saveSessionMeta paths (meta { smDescription = Just "debug the auth flow" })
        let op = sessionSearchOp paths inMemorySessionSearchBackend
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
        let op = sessionSearchOp paths inMemorySessionSearchBackend
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
        let op = sessionSearchOp paths inMemorySessionSearchBackend
        r <- runTestApp (opRun op localBackend (object ["query" .= ("kubernetes" :: Text)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> t `shouldBe` "(no sessions found)"
          _ -> expectationFailure "expected a single text part"

  describe "SESSION_GET" $ do
    it "errors on missing session id" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
            op = sessionGetOp paths
        r <- runTestApp (opRun op localBackend (object []))
        orIsError r `shouldBe` True

    it "errors on non-existent session" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
            op = sessionGetOp paths
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
        let op = sessionGetOp paths
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
        let op = sessionGetOp paths
        r <- runTestApp (opRun op localBackend
          (object
            [ "session_id" .= sessionIdText (smId meta)
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

    it "returns metadata header for the session" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        saveSessionMeta paths (meta { smDescription = Just "my test session" })
        seedConversation paths (smId meta) [ userMsg "hi" ]
        let op = sessionGetOp paths
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
        let op = sessionGetOp paths
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
              op = sessionManageOp paths inMemorySessionSearchBackend
          r <- runTestApp (opRun op localBackend (object ["action" .= ("new" :: Text)]))
          orIsError r `shouldBe` False
          case orParts r of
            [TrpText t] -> T.null t `shouldBe` False
            _ -> expectationFailure "expected a single text part"

      it "accepts optional provider/model/description" $ do
        withSystemTempDirectory "seal-session-spec" $ \tmp -> do
          let paths = mkPaths tmp
              op = sessionManageOp paths inMemorySessionSearchBackend
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
              op = sessionManageOp paths inMemorySessionSearchBackend
          r <- runTestApp (opRun op localBackend (object ["action" .= ("list" :: Text)]))
          orIsError r `shouldBe` False
          case orParts r of
            [TrpText t] -> t `shouldBe` "(no sessions found)"
            _ -> expectationFailure "expected a single text part"

      it "lists existing sessions" $ do
        withSystemTempDirectory "seal-session-spec" $ \tmp -> do
          let paths = mkPaths tmp
          _ <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
          let op = sessionManageOp paths inMemorySessionSearchBackend
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
          let op = sessionManageOp paths inMemorySessionSearchBackend
          r <- runTestApp (opRun op localBackend
            (object ["action" .= ("search" :: Text), "query" .= ("auth" :: Text)]))
          orIsError r `shouldBe` False
          case orParts r of
            [TrpText t] -> T.isInfixOf "auth" t `shouldBe` True
            _ -> expectationFailure "expected a single text part"

      it "errors on missing query" $ do
        withSystemTempDirectory "seal-session-spec" $ \tmp -> do
          let paths = mkPaths tmp
              op = sessionManageOp paths inMemorySessionSearchBackend
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
          let op = sessionManageOp paths inMemorySessionSearchBackend
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

      it "errors on missing session_id" $ do
        withSystemTempDirectory "seal-session-spec" $ \tmp -> do
          let paths = mkPaths tmp
              op = sessionManageOp paths inMemorySessionSearchBackend
          r <- runTestApp (opRun op localBackend (object ["action" .= ("get" :: Text)]))
          orIsError r `shouldBe` True

    describe "authorize gate" $ do
      it "accepts new with no extra fields" $
        opAuthorize (sessionManageOp undefined inMemorySessionSearchBackend)
          (object ["action" .= ("new" :: Text)])
          `shouldBe` Right ()

      it "accepts list with no extra fields" $
        opAuthorize (sessionManageOp undefined inMemorySessionSearchBackend)
          (object ["action" .= ("list" :: Text)])
          `shouldBe` Right ()

      it "rejects search without query" $
        opAuthorize (sessionManageOp undefined inMemorySessionSearchBackend)
          (object ["action" .= ("search" :: Text)])
          `shouldBe` Left "search requires {query:string}"

      it "rejects get without session_id" $
        opAuthorize (sessionManageOp undefined inMemorySessionSearchBackend)
          (object ["action" .= ("get" :: Text)])
          `shouldBe` Left "get requires {session_id:string}"

      it "rejects unknown action" $
        opAuthorize (sessionManageOp undefined inMemorySessionSearchBackend)
          (object ["action" .= ("frobnicate" :: Text)])
          `shouldBe` Left "unknown session action: frobnicate"

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
        let op = sessionGetOp paths
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
        let op = sessionSearchOp paths inMemorySessionSearchBackend
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
