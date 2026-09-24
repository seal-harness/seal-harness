{-# LANGUAGE OverloadedStrings #-}
-- | Tests for Seal.Session.Search — the session search capability with
-- three tiers: engram (semantic), ripgrep (literal subprocess), and
-- in-memory (full-transcript Haskell scan).
module Seal.Session.SearchSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Control.Concurrent (threadDelay)
import System.Directory (createDirectoryIfMissing, findExecutable)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Config.Paths (SealPaths (..), sessionConversationPath, sessionDir)
import Seal.Memory.Embedding (EmbeddingBackend (..), nullEmbeddingBackend)
import Seal.Providers.Class (ContentBlock (..), Message (..), Role (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Search
import Seal.Session.Store (newSession, saveSessionMeta)
import Seal.Transcript.Conv (ConvLine (..), encodeConvLine)

import Seal.Core.Types (OpName (..), SessionId, sessionIdText, ToolCallId (..))
import Data.Aeson (Value (..))
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

-- | A user message JSON line.
userMsg :: Text -> Text
userMsg t = TE.decodeUtf8 (encodeConvLine (ConvLine (Message User [CbText t])))

-- | An assistant message JSON line.
assistantMsg :: Text -> Text
assistantMsg t = TE.decodeUtf8 (encodeConvLine (ConvLine (Message Assistant [CbText t])))

-- | A tool-use message JSON line (assistant role with a tool call block).
toolUseMsg :: Text -> Text
toolUseMsg name = TE.decodeUtf8 (encodeConvLine (ConvLine (Message Assistant [CbToolUse (ToolCallId "test-id") (OpName name) (Object mempty)])))

spec :: Spec
spec = describe "Seal.Session.Search" $ do

  describe "inMemorySessionSearch" $ do
    let backend = inMemorySessionSearchBackend

    it "finds sessions by description match" $ do
      withSystemTempDirectory "seal-search" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        saveSessionMeta paths (meta { smDescription = Just "debug the auth flow" })
        results <- ssbSearch backend paths "auth" False
        length results `shouldBe` 1
        case results of
          (m, _) : _ -> sessionIdText (smId m) `shouldBe` sessionIdText (smId meta)
          []          -> expectationFailure "expected at least one result"

    it "finds sessions by first user message" $ do
      withSystemTempDirectory "seal-search" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "How do I fix the database connection pool?"
          , assistantMsg "Let me look into that."
          ]
        results <- ssbSearch backend paths "database" False
        length results `shouldBe` 1

    it "finds sessions by assistant message (full-transcript scan)" $ do
      withSystemTempDirectory "seal-search" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "Can you help me?"
          , assistantMsg "Sure, let me check the AGENT_START opcode for you."
          ]
        results <- ssbSearch backend paths "AGENT_START" False
        length results `shouldBe` 1

    it "finds sessions by tool call name" $ do
      withSystemTempDirectory "seal-search" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "Run a search"
          , toolUseMsg "SEARCH_FILES"
          ]
        results <- ssbSearch backend paths "SEARCH_FILES" False
        length results `shouldBe` 1

    it "finds sessions by later user message (not just the first)" $ do
      withSystemTempDirectory "seal-search" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "First message about cats"
          , assistantMsg "Cats are great."
          , userMsg "Now let us talk about kubernetes deployment"
          , assistantMsg "Sure, here is a kubernetes guide."
          ]
        results <- ssbSearch backend paths "kubernetes" False
        length results `shouldBe` 1

    it "does not match non-existent query" $ do
      withSystemTempDirectory "seal-search" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        saveSessionMeta paths (meta { smDescription = Just "debug the auth flow" })
        results <- ssbSearch backend paths "kubernetes" False
        results `shouldBe` []

    it "returns an empty list when no sessions exist" $ do
      withSystemTempDirectory "seal-search" $ \tmp -> do
        let paths = mkPaths tmp
        results <- ssbSearch backend paths "anything" False
        results `shouldBe` []

    it "case-insensitive match" $ do
      withSystemTempDirectory "seal-search" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "The QuIcK brown fox"
          ]
        results <- ssbSearch backend paths "quick" False
        length results `shouldBe` 1

    it "snippet contains the match context" $ do
      withSystemTempDirectory "seal-search" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "Hello"
          , assistantMsg "The config file is at /etc/app.conf"
          ]
        results <- ssbSearch backend paths "config" False
        case results of
          [(_, snip)] -> T.isInfixOf "config" (T.toCaseFold snip) `shouldBe` True
          _           -> expectationFailure "expected one result with snippet"

    it "respects the archived flag" $ do
      withSystemTempDirectory "seal-search" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        saveSessionMeta paths (meta { smDescription = Just "archived session about auth" })
        -- Create archived marker
        let marker = sessionDir paths (smId meta) </> "archived"
        writeFile marker ""
        -- Search active sessions — should not find archived
        active <- ssbSearch backend paths "auth" False
        active `shouldBe` []
        -- Search archived sessions — should find it
        archived <- ssbSearch backend paths "auth" True
        length archived `shouldBe` 1

  describe "ripgrepSessionSearch" $ do
    -- Ripgrep tests are guarded on `rg` being available.
    it "finds sessions by content across all message types" $ do
      mRg <- findExecutable "rg"
      case mRg of
        Nothing -> pendingWith "rg binary not found on PATH"
        Just _ -> withSystemTempDirectory "seal-search" $ \tmp -> do
          let paths = mkPaths tmp
          meta1 <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
          seedConversation paths (smId meta1)
            [ userMsg "Can you help me?"
            , assistantMsg "Sure, let me check the AGENT_START opcode for you."
            ]
          threadDelay 1100000  -- 1.1s — ensure different session ID (ms resolution)
          meta2 <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
          seedConversation paths (smId meta2)
            [ userMsg "Something completely unrelated"
            , assistantMsg "About cats and dogs."
            ]
          results <- ssbSearch ripgrepSessionSearchBackend paths "AGENT_START" False
          length results `shouldBe` 1
          case results of
            (m, _) : _ -> sessionIdText (smId m) `shouldBe` sessionIdText (smId meta1)
            []          -> expectationFailure "expected at least one result"

    it "finds sessions by description match" $ do
      mRg <- findExecutable "rg"
      case mRg of
        Nothing -> pendingWith "rg binary not found on PATH"
        Just _ -> withSystemTempDirectory "seal-search" $ \tmp -> do
          let paths = mkPaths tmp
          meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
          saveSessionMeta paths (meta { smDescription = Just "debug the auth flow" })
          results <- ssbSearch ripgrepSessionSearchBackend paths "auth" False
          length results `shouldBe` 1

    it "returns empty for no matches" $ do
      mRg <- findExecutable "rg"
      case mRg of
        Nothing -> pendingWith "rg binary not found on PATH"
        Just _ -> withSystemTempDirectory "seal-search" $ \tmp -> do
          let paths = mkPaths tmp
          meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
          seedConversation paths (smId meta)
            [ userMsg "Hello world"
            ]
          results <- ssbSearch ripgrepSessionSearchBackend paths "nonexistent_query_xyz" False
          results `shouldBe` []

    it "respects the archived flag" $ do
      mRg <- findExecutable "rg"
      case mRg of
        Nothing -> pendingWith "rg binary not found on PATH"
        Just _ -> withSystemTempDirectory "seal-search" $ \tmp -> do
          let paths = mkPaths tmp
          meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
          saveSessionMeta paths (meta { smDescription = Just "archived session about auth" })
          seedConversation paths (smId meta)
            [ userMsg "auth content"
            ]
          let marker = sessionDir paths (smId meta) </> "archived"
          writeFile marker ""
          active <- ssbSearch ripgrepSessionSearchBackend paths "auth" False
          active `shouldBe` []
          archived <- ssbSearch ripgrepSessionSearchBackend paths "auth" True
          length archived `shouldBe` 1

  describe "resolveSessionSearchBackend" $ do
    it "returns in-memory backend when embedding is null and rg is unavailable" $ do
      withSystemTempDirectory "seal-search" $ \tmp -> do
        let paths = mkPaths tmp
        backend <- resolveSessionSearchBackend nullEmbeddingBackend paths (const (pure Nothing))
        ssbBackendName backend `shouldBe` "in-memory"

    it "returns ripgrep backend when embedding is null but rg is available" $ do
      mRg <- findExecutable "rg"
      case mRg of
        Nothing -> pendingWith "rg binary not found on PATH"
        Just _ -> withSystemTempDirectory "seal-search" $ \tmp -> do
          let paths = mkPaths tmp
          backend <- resolveSessionSearchBackend nullEmbeddingBackend paths (const (pure (Just "/usr/bin/rg")))
          ssbBackendName backend `shouldBe` "ripgrep"

    it "returns engram backend when embedding is non-null" $ do
      withSystemTempDirectory "seal-search" $ \tmp -> do
        let paths = mkPaths tmp
            -- A non-null embedding backend (use a fake name to distinguish)
            fakeEmb = nullEmbeddingBackend { ebBackendName = "engram" }
        backend <- resolveSessionSearchBackend fakeEmb paths (const (pure (Just "/usr/bin/engram")))
        ssbBackendName backend `shouldBe` "engram"

  describe "engramSessionSearch" $ do
    -- Engram tests are guarded on the `engram` binary being available.
    it "backend name is engram" $ do
      mEngram <- findExecutable "engram"
      case mEngram of
        Nothing -> pendingWith "engram binary not found on PATH"
        Just _ -> pure ()
      ssbBackendName engramSessionSearchBackend `shouldBe` "engram"

    it "falls back to in-memory when engram binary is not available" $ do
      withSystemTempDirectory "seal-search" $ \tmp -> do
        let paths = mkPaths tmp
        meta <- newSession paths "anthropic" "claude-opus-4" "cli" Nothing
        seedConversation paths (smId meta)
          [ userMsg "The AGENT_START opcode is broken"
          ]
        -- engramSessionSearch with null embedding should still find results
        -- via its in-memory fallback
        results <- ssbSearch engramSessionSearchBackend paths "AGENT_START" False
        length results `shouldBe` 1
