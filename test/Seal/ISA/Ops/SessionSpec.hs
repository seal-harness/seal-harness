{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.SessionSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_)
import Data.Aeson (encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime, getCurrentTime)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Config.Paths
  ( SealPaths (..), agentSessionDir, sessionConversationPath
  , sessionConversationIndexPath, sessionDir )
import Seal.Core.Types
  ( OpName (..), SessionId, ToolCallId (..), mkSessionId, sessionIdText )
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
toolResultMsg = toolResultMsgFor (ToolCallId "call-1")

-- | A tool-result message JSON line for a specific tool-call id.
toolResultMsgFor :: ToolCallId -> Text -> Text
toolResultMsgFor tcid t = TE.decodeUtf8
  (encodeConvLine (ConvLine (Message User [CbToolResult tcid [TrpText t] False])))

-- | An assistant tool-use message JSON line for the given tool-call id and
-- opcode name (empty input object).
toolUseMsg :: ToolCallId -> Text -> Text
toolUseMsg tcid name = TE.decodeUtf8
  (encodeConvLine
    (ConvLine (Message Assistant [CbToolUse tcid (OpName name) (object [])])))

-- | @n@ conversation lines named msg0..msg(N-1), alternating user and
-- assistant roles (even indices are user messages, matching the msg0
-- convention of the existing pagination fixtures).
numberedMsgs :: Int -> [Text]
numberedMsgs n =
  [ (if even i then userMsg else assistantMsg) ("msg" <> T.pack (show i))
  | i <- [0 .. n - 1] ]

-- | Mint a fixed, valid SessionId from a literal text (for tests that need
-- deterministic child ids without going through 'newSession').
fixedSessionId :: Text -> SessionId
fixedSessionId t = fromRight (error "invalid fixed session id") (mkSessionId t)

-- | The id of the session "making the call" in tests where the current
-- session differs from the session being read.
callerSessionId :: SessionId
callerSessionId = fixedSessionId "20260101-120000-900"

-- | Fixed lineage ids for the ancestor-guard tests: a child, its parent,
-- and the session root. The lineage is ordered self (child) first.
lineageChildSid, lineageParentSid, lineageRootSid :: SessionId
lineageChildSid = fixedSessionId "20260101-130000-101"
lineageParentSid = fixedSessionId "20260101-130000-102"
lineageRootSid = fixedSessionId "20260101-130000-103"

-- | The baked lineage a child session's ops would carry: [child, parent,
-- root], self first.
testLineage :: [SessionId]
testLineage = [lineageChildSid, lineageParentSid, lineageRootSid]

-- | A minimal 'SessionMeta' for seeding search fixtures without minting
-- (deterministic ids, no millisecond-collision risk).
seedMeta :: SessionId -> UTCTime -> Maybe Text -> SessionMeta
seedMeta sid t mDesc = SessionMeta
  { smId = sid, smProvider = "anthropic", smModel = "claude-opus-4"
  , smChannel = "cli", smParent = Nothing, smAgent = Nothing
  , smSystemOverride = Nothing, smAgentName = Nothing
  , smDescription = mDesc
  , smSealFrontMatter = True
  , smRepoUrl = Nothing
  , smCreatedAt = t, smLastActive = t }

-- | The snippet content of every rendered @  snippet: @ line in a search
-- result.
snippetContents :: Text -> [Text]
snippetContents t =
  [ T.drop (T.length "  snippet: ") l | l <- T.lines t, "  snippet: " `T.isPrefixOf` l ]

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
            op = sessionSearchOp paths inMemorySessionSearchBackend [callerSessionId]
        r <- runTestApp (opRun op localBackend (object ["query" .= ("anything" :: Text)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> t `shouldBe` "(no sessions found)"
          _ -> expectationFailure "expected a single text part"

    it "errors on missing query" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
            op = sessionSearchOp paths inMemorySessionSearchBackend [callerSessionId]
        r <- runTestApp (opRun op localBackend (object []))
        orIsError r `shouldBe` True

    it "errors on empty query" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
            op = sessionSearchOp paths inMemorySessionSearchBackend [callerSessionId]
        r <- runTestApp (opRun op localBackend (object ["query" .= ("" :: Text)]))
        orIsError r `shouldBe` True

    it "finds sessions by description match" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        saveSessionMeta paths (meta { smDescription = Just "debug the auth flow" })
        let op = sessionSearchOp paths inMemorySessionSearchBackend [callerSessionId]
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
        let op = sessionSearchOp paths inMemorySessionSearchBackend [callerSessionId]
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
        let op = sessionSearchOp paths inMemorySessionSearchBackend [callerSessionId]
        r <- runTestApp (opRun op localBackend (object ["query" .= ("kubernetes" :: Text)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> t `shouldBe` "(no sessions found)"
          _ -> expectationFailure "expected a single text part"

  describe "SESSION_GET" $ do
    it "errors on missing session id" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
            op = sessionGetOp paths [callerSessionId]
        r <- runTestApp (opRun op localBackend (object []))
        orIsError r `shouldBe` True

    it "errors on non-existent session" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
            op = sessionGetOp paths [callerSessionId]
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
        let op = sessionGetOp paths [callerSessionId]
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
        let op = sessionGetOp paths [callerSessionId]
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
        let op = sessionGetOp paths [callerSessionId]
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
        let op = sessionGetOp paths [callerSessionId]
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
        let op = sessionGetOp paths [callerSessionId]
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
        let op = sessionGetOp paths [callerSessionId]
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
        let op = sessionGetOp paths [callerSessionId]
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
              op = sessionManageOp paths inMemorySessionSearchBackend [callerSessionId]
          r <- runTestApp (opRun op localBackend (object ["action" .= ("new" :: Text)]))
          orIsError r `shouldBe` False
          case orParts r of
            [TrpText t] -> T.null t `shouldBe` False
            _ -> expectationFailure "expected a single text part"

      it "accepts optional provider/model/description" $ do
        withSystemTempDirectory "seal-session-spec" $ \tmp -> do
          let paths = mkPaths tmp
              op = sessionManageOp paths inMemorySessionSearchBackend [callerSessionId]
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
              op = sessionManageOp paths inMemorySessionSearchBackend [callerSessionId]
          r <- runTestApp (opRun op localBackend (object ["action" .= ("list" :: Text)]))
          orIsError r `shouldBe` False
          case orParts r of
            [TrpText t] -> t `shouldBe` "(no sessions found)"
            _ -> expectationFailure "expected a single text part"

      it "lists existing sessions" $ do
        withSystemTempDirectory "seal-session-spec" $ \tmp -> do
          let paths = mkPaths tmp
          _ <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
          let op = sessionManageOp paths inMemorySessionSearchBackend [callerSessionId]
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
          let op = sessionManageOp paths inMemorySessionSearchBackend [callerSessionId]
          r <- runTestApp (opRun op localBackend
            (object ["action" .= ("search" :: Text), "query" .= ("auth" :: Text)]))
          orIsError r `shouldBe` False
          case orParts r of
            [TrpText t] -> T.isInfixOf "auth" t `shouldBe` True
            _ -> expectationFailure "expected a single text part"

      it "errors on missing query" $ do
        withSystemTempDirectory "seal-session-spec" $ \tmp -> do
          let paths = mkPaths tmp
              op = sessionManageOp paths inMemorySessionSearchBackend [callerSessionId]
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
          let op = sessionManageOp paths inMemorySessionSearchBackend [callerSessionId]
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
          let op = sessionManageOp paths inMemorySessionSearchBackend [callerSessionId]
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
              op = sessionManageOp paths inMemorySessionSearchBackend [callerSessionId]
          r <- runTestApp (opRun op localBackend (object ["action" .= ("get" :: Text)]))
          orIsError r `shouldBe` True

    describe "authorize gate" $ do
      it "accepts new with no extra fields" $
        opAuthorize (sessionManageOp undefined inMemorySessionSearchBackend [callerSessionId])
          (object ["action" .= ("new" :: Text)])
          `shouldBe` Right ()

      it "accepts list with no extra fields" $
        opAuthorize (sessionManageOp undefined inMemorySessionSearchBackend [callerSessionId])
          (object ["action" .= ("list" :: Text)])
          `shouldBe` Right ()

      it "rejects search without query" $
        opAuthorize (sessionManageOp undefined inMemorySessionSearchBackend [callerSessionId])
          (object ["action" .= ("search" :: Text)])
          `shouldBe` Left "search requires {query:string}"

      it "rejects get without session_id" $
        opAuthorize (sessionManageOp undefined inMemorySessionSearchBackend [callerSessionId])
          (object ["action" .= ("get" :: Text)])
          `shouldBe` Left "get requires {session_id:string}"

      it "rejects unknown action" $
        opAuthorize (sessionManageOp undefined inMemorySessionSearchBackend [callerSessionId])
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
        let op = sessionManageOp paths inMemorySessionSearchBackend [smId meta]
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
        let op = sessionGetOp paths [smId meta]
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
        let op = sessionGetOp paths [childSid]
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
        let op = sessionManageOp paths inMemorySessionSearchBackend [callerSessionId]
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
        let op = sessionGetOp paths [smId meta]
        r <- runTestApp (opRun op localBackend
          (object ["session_id" .= sessionIdText (smId meta)]))
        orIsError r `shouldBe` True
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf (sessionIdText (smId meta)) recorded `shouldBe` True
        T.isInfixOf "\"self_read\":true" recorded `shouldBe` True
        T.isInfixOf "secret-value-123" recorded `shouldBe` False

  -- -----------------------------------------------------------------------
  -- Lineage guard (a session cannot read its ancestors' transcripts)
  -- -----------------------------------------------------------------------
  describe "lineage guard" $ do
    it "SESSION_MANAGE get on an ancestor (parent) is refused" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        -- Re-save the parent meta under the fixed parent sid so the
        -- guard target has a readable session.
        saveSessionMeta paths (meta { smId = lineageParentSid })
        seedConversation paths lineageParentSid
          [ userMsg "parent secret work"
          , assistantMsg "parent answer"
          ]
        let op = sessionManageOp paths inMemorySessionSearchBackend testLineage
        r <- runTestApp (opRun op localBackend
          (object
            [ "action" .= ("get" :: Text)
            , "session_id" .= sessionIdText lineageParentSid
            ]))
        orIsError r `shouldBe` True
        case orParts r of
          [TrpText t] -> do
            T.isInfixOf "ancestor" t `shouldBe` True
            T.isInfixOf (sessionIdText lineageParentSid) t `shouldBe` True
            T.isInfixOf "parent secret work" t `shouldBe` False
          _ -> expectationFailure "expected a single text part"

    it "SESSION_GET (legacy) on an ancestor (root) is refused" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        saveSessionMeta paths (meta { smId = lineageRootSid })
        seedConversation paths lineageRootSid
          [ userMsg "root secret work"
          ]
        let op = sessionGetOp paths testLineage
        r <- runTestApp (opRun op localBackend
          (object ["session_id" .= sessionIdText lineageRootSid]))
        orIsError r `shouldBe` True
        case orParts r of
          [TrpText t] -> do
            T.isInfixOf "ancestor" t `shouldBe` True
            T.isInfixOf "root secret work" t `shouldBe` False
          _ -> expectationFailure "expected a single text part"

    it "an op with a lineage still reads unrelated sessions" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "unrelated hello world"
          ]
        let op = sessionGetOp paths testLineage
        r <- runTestApp (opRun op localBackend
          (object ["session_id" .= sessionIdText (smId meta)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> T.isInfixOf "unrelated hello world" t `shouldBe` True
          _ -> expectationFailure "expected a single text part"

    it "records ancestor-read refusals in orRecorded without transcript content" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        saveSessionMeta paths (meta { smId = lineageParentSid })
        seedConversation paths lineageParentSid
          [ userMsg "ancestor-secret-value-123"
          ]
        let op = sessionGetOp paths testLineage
        r <- runTestApp (opRun op localBackend
          (object ["session_id" .= sessionIdText lineageParentSid]))
        orIsError r `shouldBe` True
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf (sessionIdText lineageParentSid) recorded `shouldBe` True
        T.isInfixOf "\"ancestor_read\":true" recorded `shouldBe` True
        T.isInfixOf "self_read" recorded `shouldBe` False
        T.isInfixOf "ancestor-secret-value-123" recorded `shouldBe` False

    it "search excludes every lineage session while finding unrelated sessions" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        -- The parent and the root as top-level sessions matching the
        -- query by description.
        parentMeta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        saveSessionMeta paths
          (parentMeta { smId = lineageParentSid
                      , smDescription = Just "needle parent session" })
        threadDelay 2000
        rootMeta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        saveSessionMeta paths
          (rootMeta { smId = lineageRootSid
                    , smDescription = Just "needle root session" })
        threadDelay 2000
        unrelatedMeta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        saveSessionMeta paths
          (unrelatedMeta { smDescription = Just "needle unrelated session" })
        -- A child transcript nested under the parent, matching the query
        -- by its first user message (the childMatched path).
        seedChildConversation paths lineageParentSid lineageChildSid
          [ userMsg "needle child work" ]
        let op = sessionSearchOp paths inMemorySessionSearchBackend testLineage
        r <- runTestApp (opRun op localBackend
          (object ["query" .= ("needle" :: Text)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            T.isInfixOf (sessionIdText (smId unrelatedMeta)) t `shouldBe` True
            T.isInfixOf (sessionIdText lineageParentSid) t `shouldBe` False
            T.isInfixOf (sessionIdText lineageRootSid) t `shouldBe` False
            T.isInfixOf (sessionIdText lineageChildSid) t `shouldBe` False
          _ -> expectationFailure "expected a single text part"
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf (sessionIdText lineageParentSid) recorded `shouldBe` False
        T.isInfixOf (sessionIdText (smId unrelatedMeta)) recorded `shouldBe` True

  -- -----------------------------------------------------------------------
  -- Search result cap + snippet clamp
  -- -----------------------------------------------------------------------
  describe "search result cap" $ do
    it "renders at most 20 rows with a footer when matches exceed the cap" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        now <- getCurrentTime
        forM_ [0 .. 29 :: Int] $ \i ->
          saveSessionMeta paths
            (seedMeta (fixedSessionId (T.pack ("20260301-140000-" <> show (100 + i)))) now
              (Just (T.pack ("needle session " <> show i))))
        let op = sessionSearchOp paths inMemorySessionSearchBackend [callerSessionId]
        r <- runTestApp (opRun op localBackend (object ["query" .= ("needle" :: Text)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            T.count "  snippet: " t `shouldBe` 20
            T.isInfixOf "(showing 20 of 30 matches — refine your query)" t `shouldBe` True
          _ -> expectationFailure "expected a single text part"
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf "\"match_count\":20" recorded `shouldBe` True
        T.isInfixOf "\"match_total\":30" recorded `shouldBe` True

    it "renders all rows with no footer when matches are within the cap" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        now <- getCurrentTime
        forM_ [0 .. 2 :: Int] $ \i ->
          saveSessionMeta paths
            (seedMeta (fixedSessionId (T.pack ("20260302-140000-" <> show (200 + i)))) now
              (Just (T.pack ("needle session " <> show i))))
        let op = sessionSearchOp paths inMemorySessionSearchBackend [callerSessionId]
        r <- runTestApp (opRun op localBackend (object ["query" .= ("needle" :: Text)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            T.count "  snippet: " t `shouldBe` 3
            T.isInfixOf "refine your query" t `shouldBe` False
          _ -> expectationFailure "expected a single text part"

  describe "search snippet clamp" $ do
    it "clamps every rendered snippet to 120 chars of content" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        now <- getCurrentTime
        let longText = "longneedle start " <> T.replicate 40 "0123456789"
        -- A backend-matched top-level session: the in-memory backend's
        -- snippet for this would be ~200 chars before the render clamp.
        let longConvSid = fixedSessionId "20260303-140000-300"
        saveSessionMeta paths (seedMeta longConvSid now Nothing)
        seedConversation paths longConvSid [ userMsg longText ]
        -- A description-matched session: the description is the snippet
        -- fallback, unbounded before the render clamp.
        let longDescSid = fixedSessionId "20260303-140000-301"
        saveSessionMeta paths (seedMeta longDescSid now (Just longText))
        -- A child-matched session: the first user message is the snippet.
        let parentSid = fixedSessionId "20260303-140000-302"
            childSid = fixedSessionId "20260303-140000-303"
        seedChildConversation paths parentSid childSid [ userMsg longText ]
        let op = sessionSearchOp paths inMemorySessionSearchBackend [callerSessionId]
        r <- runTestApp (opRun op localBackend (object ["query" .= ("longneedle" :: Text)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            T.length longText `shouldSatisfy` (> 200)
            let snips = snippetContents t
            length snips `shouldBe` 3
            forM_ snips $ \s ->
              -- At most 120 chars of snippet content; the ellipsis
              -- marker may push the rendered length to 121.
              (T.length s <= 120 || (T.length s == 121 && "…" `T.isSuffixOf` s))
                `shouldBe` True
          _ -> expectationFailure "expected a single text part"

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
        let op = sessionManageOp paths inMemorySessionSearchBackend [smId meta]
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
        let op = sessionSearchOp paths inMemorySessionSearchBackend [smId meta]
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
        let op = sessionManageOp paths inMemorySessionSearchBackend [smId currentMeta]
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
        let op = sessionSearchOp paths inMemorySessionSearchBackend [childSid]
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
        let op = sessionGetOp paths [callerSessionId]
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
        let op = sessionSearchOp paths inMemorySessionSearchBackend [callerSessionId]
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
        let op = sessionGetOp paths [callerSessionId]
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
        let op = sessionGetOp paths [callerSessionId]
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
        let op = sessionGetOp paths [callerSessionId]
        r <- runTestApp (opRun op localBackend
          (object [ "session_id" .= sessionIdText (smId meta)
                  , "limit" .= (200 :: Int) ]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            -- getRenderBudgetBytes is 98304: the whole rendered page fits.
            BS.length (TE.encodeUtf8 t) `shouldSatisfy` (<= 98304)
            T.isInfixOf "output truncated at" t `shouldBe` True
            T.isInfixOf "narrow the window (limit / offset / around_index)" t `shouldBe` True
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
        let op = sessionGetOp paths [callerSessionId]
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
        let op = sessionGetOp paths [callerSessionId]
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
        let op = sessionGetOp paths [callerSessionId]
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
        let op = sessionGetOp paths [callerSessionId]
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
        let op = sessionGetOp paths [callerSessionId]
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

  -- -----------------------------------------------------------------------
  -- Read-path secret redaction (foreign-session get)
  -- -----------------------------------------------------------------------
  describe "read-path secret redaction" $ do
    it "redacts SECRET_MANAGE tool results in a foreign session (SESSION_MANAGE get)" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "before the secret"
          , toolUseMsg (ToolCallId "call-1") "SECRET_MANAGE"
          , toolResultMsg "super-secret-value"
          , userMsg "after the secret"
          ]
        let op = sessionManageOp paths inMemorySessionSearchBackend [callerSessionId]
        r <- runTestApp (opRun op localBackend
          (object
            [ "action" .= ("get" :: Text)
            , "session_id" .= sessionIdText (smId meta)
            ]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            T.isInfixOf "<redacted:secret>" t `shouldBe` True
            T.isInfixOf "super-secret-value" t `shouldBe` False
            T.isInfixOf "after the secret" t `shouldBe` True
          _ -> expectationFailure "expected a single text part"
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf "super-secret-value" recorded `shouldBe` False

    it "renders non-secret op tool results verbatim" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ toolUseMsg (ToolCallId "call-b") "BIN_EXEC"
          , toolResultMsgFor (ToolCallId "call-b") "harmless tool output"
          ]
        let op = sessionGetOp paths [callerSessionId]
        r <- runTestApp (opRun op localBackend
          (object ["session_id" .= sessionIdText (smId meta)]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            T.isInfixOf "harmless tool output" t `shouldBe` True
            T.isInfixOf "<redacted:secret>" t `shouldBe` False
          _ -> expectationFailure "expected a single text part"

    it "redacts a result whose tool-use message is outside the window (pre-window margin)" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "margin0"
          , toolUseMsg (ToolCallId "call-1") "SECRET_MANAGE"
          , toolResultMsg "super-secret-value"
          , userMsg "window-end"
          ]
        let op = sessionGetOp paths [callerSessionId]
        r <- runTestApp (opRun op localBackend
          (object
            [ "session_id" .= sessionIdText (smId meta)
            , "order" .= ("front-to-back" :: Text)
            , "offset" .= (2 :: Int)
            , "limit" .= (2 :: Int)
            ]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            -- The window is [tool result, window-end]; the tool-use
            -- message at index 1 is only in the scan margin.
            T.isInfixOf "<redacted:secret>" t `shouldBe` True
            T.isInfixOf "super-secret-value" t `shouldBe` False
            -- The margin supplies the scan only; it is not rendered.
            T.isInfixOf "margin0" t `shouldBe` False
            T.isInfixOf "window-end" t `shouldBe` True
          _ -> expectationFailure "expected a single text part"
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf "super-secret-value" recorded `shouldBe` False

    it "redacts a margin-supplied secret via the conversation.idx ranged path" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "margin0"
          , toolUseMsg (ToolCallId "call-1") "SECRET_MANAGE"
          , toolResultMsg "super-secret-value"
          , userMsg "window-end"
          ]
        _ <- buildIndex (sessionConversationPath paths (smId meta))
                        (sessionConversationIndexPath paths (smId meta))
        let op = sessionGetOp paths [callerSessionId]
        r <- runTestApp (opRun op localBackend
          (object
            [ "session_id" .= sessionIdText (smId meta)
            , "order" .= ("front-to-back" :: Text)
            , "offset" .= (2 :: Int)
            , "limit" .= (2 :: Int)
            ]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            T.isInfixOf "<redacted:secret>" t `shouldBe` True
            T.isInfixOf "super-secret-value" t `shouldBe` False
            T.isInfixOf "window-end" t `shouldBe` True
          _ -> expectationFailure "expected a single text part"

    it "redacts secret results on the child-resolution branch" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        parentMeta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        let childSid = fixedSessionId "20260101-120000-011"
        seedChildConversation paths (smId parentMeta) childSid
          [ toolUseMsg (ToolCallId "call-1") "SECRET_MANAGE"
          , toolResultMsg "super-secret-value"
          ]
        let op = sessionGetOp paths [callerSessionId]
        r <- runTestApp (opRun op localBackend
          (object ["session_id" .= sessionIdText childSid]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            T.isInfixOf "<redacted:secret>" t `shouldBe` True
            T.isInfixOf "super-secret-value" t `shouldBe` False
            T.isInfixOf "child session of" t `shouldBe` True
          _ -> expectationFailure "expected a single text part"
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf "super-secret-value" recorded `shouldBe` False

  -- -----------------------------------------------------------------------
  -- Anchor-based windowing (around_index)
  -- -----------------------------------------------------------------------
  describe "around_index windowing" $ do
    it "centers the window on around_index with true global #N indices (idx path)" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta) (numberedMsgs 12)
        _ <- buildIndex (sessionConversationPath paths (smId meta))
                        (sessionConversationIndexPath paths (smId meta))
        let op = sessionGetOp paths [callerSessionId]
        r <- runTestApp (opRun op localBackend
          (object
            [ "session_id" .= sessionIdText (smId meta)
            , "around_index" .= (5 :: Int)
            , "limit" .= (4 :: Int)
            ]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            -- limit=4 around 5: the window starts at 5 - 4 div 2 = 3.
            forM_ ["msg3", "msg4", "msg5", "msg6"] $ \m ->
              T.isInfixOf m t `shouldBe` True
            forM_ ["msg2", "msg7"] $ \m ->
              T.isInfixOf m t `shouldBe` False
            -- Global indices: the window starts at transcript index 3.
            forM_ ["(#3)", "(#4)", "(#5)", "(#6)"] $ \m ->
              T.isInfixOf m t `shouldBe` True
            forM_ ["(#2)", "(#7)"] $ \m ->
              T.isInfixOf m t `shouldBe` False
            -- The window renders chronologically (front-to-back).
            let posOf m = T.length (fst (T.breakOn m t))
            posOf "msg3" `shouldSatisfy` (< posOf "msg4")
            posOf "msg4" `shouldSatisfy` (< posOf "msg5")
            posOf "msg5" `shouldSatisfy` (< posOf "msg6")
            -- Footer: global range plus around_index anchors for the
            -- adjacent windows.
            T.isInfixOf "messages 4-7 of 12" t `shouldBe` True
            T.isInfixOf "3 before, 5 after" t `shouldBe` True
            T.isInfixOf "around_index=2 for an earlier window" t `shouldBe` True
            T.isInfixOf "around_index=7 for a later window" t `shouldBe` True
          _ -> expectationFailure "expected a single text part"
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf "\"offset\":3" recorded `shouldBe` True
        T.isInfixOf "\"limit\":4" recorded `shouldBe` True
        T.isInfixOf "\"around_index\":5" recorded `shouldBe` True
        T.isInfixOf "\"order\":\"front-to-back\"" recorded `shouldBe` True

    it "overrides offset when both are present" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta) (numberedMsgs 12)
        let op = sessionGetOp paths [callerSessionId]
        r <- runTestApp (opRun op localBackend
          (object
            [ "session_id" .= sessionIdText (smId meta)
            , "around_index" .= (5 :: Int)
            , "offset" .= (99 :: Int)
            , "limit" .= (4 :: Int)
            ]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            -- offset=99 is ignored: the window is the same centered
            -- [3, 7) window as around_index alone.
            forM_ ["msg3", "msg4", "msg5", "msg6"] $ \m ->
              T.isInfixOf m t `shouldBe` True
            forM_ ["msg2", "msg7"] $ \m ->
              T.isInfixOf m t `shouldBe` False
          _ -> expectationFailure "expected a single text part"
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf "\"offset\":3" recorded `shouldBe` True

    it "defaults to limit 20 in around mode" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta) (numberedMsgs 30)
        let op = sessionGetOp paths [callerSessionId]
        r <- runTestApp (opRun op localBackend
          (object
            [ "session_id" .= sessionIdText (smId meta)
            , "around_index" .= (15 :: Int)
            ]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            -- Default limit 20 around 15: window [5, 25).
            forM_ ["msg5", "msg24"] $ \m ->
              T.isInfixOf m t `shouldBe` True
            forM_ ["msg4", "msg25"] $ \m ->
              T.isInfixOf m t `shouldBe` False
            T.count "(#" t `shouldBe` 20
            T.isInfixOf "messages 6-25 of 30" t `shouldBe` True
          _ -> expectationFailure "expected a single text part"
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf "\"limit\":20" recorded `shouldBe` True
        T.isInfixOf "\"offset\":5" recorded `shouldBe` True
        T.isInfixOf "\"around_index\":15" recorded `shouldBe` True

    it "clamps a negative around_index to a window from the transcript start" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta) (numberedMsgs 12)
        let op = sessionGetOp paths [callerSessionId]
        r <- runTestApp (opRun op localBackend
          (object
            [ "session_id" .= sessionIdText (smId meta)
            , "around_index" .= (-5 :: Int)
            , "limit" .= (4 :: Int)
            ]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            -- Start clamps to 0: messages 0-3 render.
            forM_ ["msg0", "msg1", "msg2", "msg3"] $ \m ->
              T.isInfixOf m t `shouldBe` True
            forM_ ["msg4", "msg8"] $ \m ->
              T.isInfixOf m t `shouldBe` False
            T.isInfixOf "messages 1-4 of 12" t `shouldBe` True
            T.isInfixOf "8 after" t `shouldBe` True
            T.isInfixOf "around_index=4 for a later window" t `shouldBe` True
          _ -> expectationFailure "expected a single text part"
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf "\"offset\":0" recorded `shouldBe` True
        T.isInfixOf "\"around_index\":-5" recorded `shouldBe` True

    it "clamps an around_index beyond the end to a window ending at the tail" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta) (numberedMsgs 12)
        let op = sessionGetOp paths [callerSessionId]
        r <- runTestApp (opRun op localBackend
          (object
            [ "session_id" .= sessionIdText (smId meta)
            , "around_index" .= (100 :: Int)
            , "limit" .= (4 :: Int)
            ]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            -- Start clamps to 12 - 4 = 8: the window ends at the tail.
            forM_ ["msg8", "msg9", "msg10", "msg11"] $ \m ->
              T.isInfixOf m t `shouldBe` True
            forM_ ["msg6", "msg7"] $ \m ->
              T.isInfixOf m t `shouldBe` False
            T.isInfixOf "messages 9-12 of 12" t `shouldBe` True
            T.isInfixOf "8 before" t `shouldBe` True
            T.isInfixOf "around_index=7 for an earlier window" t `shouldBe` True
          _ -> expectationFailure "expected a single text part"
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf "\"offset\":8" recorded `shouldBe` True
        T.isInfixOf "\"around_index\":100" recorded `shouldBe` True

    it "anchors near the tail end the window at the newest message" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta) (numberedMsgs 12)
        let op = sessionGetOp paths [callerSessionId]
        r <- runTestApp (opRun op localBackend
          (object
            [ "session_id" .= sessionIdText (smId meta)
            , "around_index" .= (11 :: Int)
            , "limit" .= (4 :: Int)
            ]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            -- Raw start 11 - 2 = 9 clamps to 12 - 4 = 8: window [8, 12).
            forM_ ["msg8", "msg11"] $ \m ->
              T.isInfixOf m t `shouldBe` True
            T.isInfixOf "msg7" t `shouldBe` False
            T.isInfixOf "8 before - read with around_index=7 for an earlier window" t
              `shouldBe` True
          _ -> expectationFailure "expected a single text part"

    it "covers the whole transcript when the around window spans it" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta) (numberedMsgs 12)
        let op = sessionGetOp paths [callerSessionId]
        r <- runTestApp (opRun op localBackend
          (object
            [ "session_id" .= sessionIdText (smId meta)
            , "around_index" .= (6 :: Int)
            ]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            -- Default limit 20 exceeds the transcript: start clamps to 0
            -- and the window is the whole transcript.
            forM_ ["msg0", "msg11", "(#0)", "(#11)"] $ \m ->
              T.isInfixOf m t `shouldBe` True
            T.isInfixOf "messages 1-12 of 12 (whole transcript)]" t `shouldBe` True
          _ -> expectationFailure "expected a single text part"
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf "\"limit\":12" recorded `shouldBe` True
        T.isInfixOf "\"offset\":0" recorded `shouldBe` True

    it "returns the empty-transcript message without error for an around read" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        let op = sessionGetOp paths [callerSessionId]
        r <- runTestApp (opRun op localBackend
          (object
            [ "session_id" .= sessionIdText (smId meta)
            , "around_index" .= (5 :: Int)
            ]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> T.isInfixOf "(0 messages in transcript)" t `shouldBe` True
          _ -> expectationFailure "expected a single text part"

    it "applies the byte budget to around windows" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        let bigMsgs =
              [ toolResultMsg ("budget payload " <> T.pack (show i) <> " "
                  <> T.replicate 5900 "x")
              | i <- [0 .. 59 :: Int] ]
        seedConversation paths (smId meta) bigMsgs
        let op = sessionGetOp paths [callerSessionId]
        r <- runTestApp (opRun op localBackend
          (object
            [ "session_id" .= sessionIdText (smId meta)
            , "around_index" .= (30 :: Int)
            ]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            -- Default limit 20 around 30: window [20, 40), and the
            -- ~5.9KB messages blow the page budget mid-window.
            BS.length (TE.encodeUtf8 t) `shouldSatisfy` (<= 98304)
            T.isInfixOf "output truncated at" t `shouldBe` True
            T.isInfixOf "narrow the window (limit / offset / around_index)" t
              `shouldBe` True
            T.isInfixOf "budget payload 20 " t `shouldBe` True
            T.isInfixOf "budget payload 10 " t `shouldBe` False
          _ -> expectationFailure "expected a single text part"
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf "\"truncated\":true" recorded `shouldBe` True
        T.isInfixOf "payload" recorded `shouldBe` False

    it "redacts margin-adjacent secrets in around windows" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "margin0"
          , toolUseMsg (ToolCallId "call-1") "SECRET_MANAGE"
          , toolResultMsg "super-secret-value"
          , userMsg "window-end"
          , userMsg "after-tail"
          ]
        let op = sessionGetOp paths [callerSessionId]
        r <- runTestApp (opRun op localBackend
          (object
            [ "session_id" .= sessionIdText (smId meta)
            , "around_index" .= (3 :: Int)
            , "limit" .= (2 :: Int)
            ]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            -- Window [2, 4): the tool result and window-end. The
            -- tool-use at index 1 is only in the pre-window margin.
            T.isInfixOf "<redacted:secret>" t `shouldBe` True
            T.isInfixOf "super-secret-value" t `shouldBe` False
            T.isInfixOf "window-end" t `shouldBe` True
            T.isInfixOf "margin0" t `shouldBe` False
            T.isInfixOf "after-tail" t `shouldBe` False
            T.isInfixOf "messages 3-4 of 5" t `shouldBe` True
          _ -> expectationFailure "expected a single text part"
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf "super-secret-value" recorded `shouldBe` False

    it "refuses an around_index read of a lineage member with the same refusal" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        saveSessionMeta paths (meta { smId = lineageParentSid })
        seedConversation paths lineageParentSid
          [ userMsg "parent secret work"
          , assistantMsg "parent answer"
          ]
        let op = sessionManageOp paths inMemorySessionSearchBackend testLineage
        r <- runTestApp (opRun op localBackend
          (object
            [ "action" .= ("get" :: Text)
            , "session_id" .= sessionIdText lineageParentSid
            , "around_index" .= (0 :: Int)
            ]))
        orIsError r `shouldBe` True
        case orParts r of
          [TrpText t] -> do
            T.isInfixOf "ancestor" t `shouldBe` True
            T.isInfixOf (sessionIdText lineageParentSid) t `shouldBe` True
            T.isInfixOf "parent secret work" t `shouldBe` False
          _ -> expectationFailure "expected a single text part"
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf "\"ancestor_read\":true" recorded `shouldBe` True

    it "supports around_index on the child-resolution branch" $ do
      withSystemTempDirectory "seal-session-spec" $ \tmp -> do
        let paths = mkPaths tmp
        parentMeta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        let childSid = fixedSessionId "20260101-120000-012"
        seedChildConversation paths (smId parentMeta) childSid (numberedMsgs 6)
        let op = sessionGetOp paths [callerSessionId]
        r <- runTestApp (opRun op localBackend
          (object
            [ "session_id" .= sessionIdText childSid
            , "around_index" .= (4 :: Int)
            , "limit" .= (2 :: Int)
            ]))
        orIsError r `shouldBe` False
        case orParts r of
          [TrpText t] -> do
            -- limit=2 around 4: window [3, 5), chronological.
            forM_ ["msg3", "msg4", "(#3)", "(#4)"] $ \m ->
              T.isInfixOf m t `shouldBe` True
            forM_ ["msg2", "msg5"] $ \m ->
              T.isInfixOf m t `shouldBe` False
            T.isInfixOf "child session of" t `shouldBe` True
            T.isInfixOf "messages 4-5 of 6" t `shouldBe` True
          _ -> expectationFailure "expected a single text part"
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf "\"offset\":3" recorded `shouldBe` True
        T.isInfixOf "\"around_index\":4" recorded `shouldBe` True
