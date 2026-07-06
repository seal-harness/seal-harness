{-# LANGUAGE OverloadedStrings #-}
module Seal.Agent.Def.BackendSpec (spec) where

import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Agent.Def.Backend
import Seal.Agent.Def.Types (AgentDef (..), AgentDefId (..), mkAgentDefId, agentDefIdText)
import Seal.Core.Types (ModelId (..), OpName (..), SessionId (..))
import Seal.Git.Repo (ensureConfigRepo, openConfigRepo, gitHasCommits)
import Seal.Security.Policy (AllowList (..))
import Seal.TestHelpers.Arbitrary ()

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 5) (secondsToDiffTime 0)

sampleDefId :: AgentDefId
sampleDefId = case mkAgentDefId "a1" of
  Right aid -> aid
  Left _    -> AgentDefId "fallback"

mkDef :: Text -> AgentDef
mkDef name = AgentDef
  { adId = sampleDefId
  , adName = name
  , adProvider = "ollama"
  , adModel = ModelId "llama3"
  , adSystem = Just "be nice"
  , adTools = AllowAll
  , adCreatedAt = sampleTime
  , adUpdatedAt = sampleTime
  , adSession = SessionId "s1"
  }

spec :: Spec
spec = describe "Seal.Agent.Def.Backend" $ do
  describe "encodeAgentDef / decodeAgentDef" $ do
    it "round-trips a def with AllowAll tools" $ do
      let d = mkDef "greeter"
      decodeAgentDef (encodeAgentDef d) `shouldBe` Just d

    it "round-trips a def with AllowOnly tools" $ do
      let tools = AllowOnly (Set.fromList [OpName "FILE_READ", OpName "ASK_HUMAN"])
          d = (mkDef "toolsy") { adTools = tools }
      decodeAgentDef (encodeAgentDef d) `shouldBe` Just d

    it "round-trips a def with no system prompt" $ do
      let d = (mkDef "nosys") { adSystem = Nothing }
      decodeAgentDef (encodeAgentDef d) `shouldBe` Just d

  describe "noneBackend" $ do
    it "update then read round-trips" $ do
      backend <- noneBackend
      adbUpdate backend (mkDef "greeter")
      adbRead backend sampleDefId `shouldReturn` Just (mkDef "greeter")

    it "list returns all defs" $ do
      backend <- noneBackend
      adbUpdate backend (mkDef "a")
      adbList backend `shouldReturn` [mkDef "a"]

  describe "markdownAgentDefBackend" $ do
    it "update writes a file and read reads it back" $
      withSystemTempDirectory "seal-def" $ \root -> do
        let cfgRoot = root </> "config"
            agentsDir = cfgRoot </> "agents"
        ensureConfigRepo cfgRoot
        backend <- markdownAgentDefBackend agentsDir (openConfigRepo cfgRoot)
        adbUpdate backend (mkDef "greeter")
        doesFileExist (agentsDir </> "a1.md") `shouldReturn` True
        m <- adbRead backend sampleDefId
        case m of
          Just d  -> adName d `shouldBe` "greeter"
          Nothing -> expectationFailure "def not read back"

    it "update auto-commits to the git repo" $
      withSystemTempDirectory "seal-def" $ \root -> do
        let cfgRoot = root </> "config"
            agentsDir = cfgRoot </> "agents"
        ensureConfigRepo cfgRoot
        backend <- markdownAgentDefBackend agentsDir (openConfigRepo cfgRoot)
        adbUpdate backend (mkDef "greeter")
        gitHasCommits (openConfigRepo cfgRoot) `shouldReturn` True

    it "list enumerates the directory sorted by id" $
      withSystemTempDirectory "seal-def" $ \root -> do
        let cfgRoot = root </> "config"
            agentsDir = cfgRoot </> "agents"
        ensureConfigRepo cfgRoot
        backend <- markdownAgentDefBackend agentsDir (openConfigRepo cfgRoot)
        case mkAgentDefId "zeta" of
          Right zid -> adbUpdate backend ((mkDef "z") { adId = zid })
          Left _    -> expectationFailure "invalid id"
        case mkAgentDefId "alpha" of
          Right aid -> adbUpdate backend ((mkDef "a") { adId = aid })
          Left _    -> expectationFailure "invalid id"
        defs <- adbList backend
        map (agentDefIdText . adId) defs `shouldBe` ["alpha", "zeta"]

  describe "DirScheme discovery (PureClaw-style subdirectories)" $ do
    it "discovers a zoe/ directory with SOUL.md + AGENTS.md and composes the prompt" $
      withSystemTempDirectory "seal-def" $ \root -> do
        let cfgRoot = root </> "config"
            agentsDir = cfgRoot </> "agents"
            zoeDir = agentsDir </> "zoe"
        ensureConfigRepo cfgRoot
        createDirectoryIfMissing True zoeDir
        TIO.writeFile (zoeDir </> "SOUL.md") "I am Zoe."
        TIO.writeFile (zoeDir </> "AGENTS.md") "# AGENTS\nbe helpful"
        backend <- markdownAgentDefBackend agentsDir (openConfigRepo cfgRoot)
        defs <- adbList backend
        case defs of
          [d] -> do
            agentDefIdText (adId d) `shouldBe` "zoe"
            adName d `shouldBe` "zoe"
            adProvider d `shouldBe` ""
            adModel d `shouldBe` ModelId ""
            adTools d `shouldBe` AllowAll
            adSession d `shouldBe` SessionId "manual"
            case adSystem d of
              Just prompt -> do
                prompt `shouldSatisfy` ("--- SOUL ---" `T.isInfixOf`)
                prompt `shouldSatisfy` ("I am Zoe." `T.isInfixOf`)
                prompt `shouldSatisfy` ("--- AGENTS ---" `T.isInfixOf`)
                prompt `shouldSatisfy` ("be helpful" `T.isInfixOf`)
              Nothing -> expectationFailure "expected composed prompt, got Nothing"
          _ -> expectationFailure ("expected one def, got " <> show (length defs))

    it "AGENTS.md frontmatter supplies model/provider/tools" $
      withSystemTempDirectory "seal-def" $ \root -> do
        let cfgRoot = root </> "config"
            agentsDir = cfgRoot </> "agents"
            zoeDir = agentsDir </> "zoe"
        ensureConfigRepo cfgRoot
        createDirectoryIfMissing True zoeDir
        TIO.writeFile (zoeDir </> "AGENTS.md")
          "---\nmodel = \"claude-opus-4-8\"\nprovider = \"anthropic\"\ntools = [\"FILE_READ\", \"ASK_HUMAN\"]\n---\nbody here"
        backend <- markdownAgentDefBackend agentsDir (openConfigRepo cfgRoot)
        defs <- adbList backend
        case defs of
          [d] -> do
            adProvider d `shouldBe` "anthropic"
            adModel d `shouldBe` ModelId "claude-opus-4-8"
            adTools d `shouldBe` AllowOnly (Set.fromList [OpName "FILE_READ", OpName "ASK_HUMAN"])
          _ -> expectationFailure ("expected one def, got " <> show (length defs))

    it "DirScheme agent with no bootstrap files returns adSystem = Nothing" $
      withSystemTempDirectory "seal-def" $ \root -> do
        let cfgRoot = root </> "config"
            agentsDir = cfgRoot </> "agents"
            emptyDir = agentsDir </> "empty"
        ensureConfigRepo cfgRoot
        createDirectoryIfMissing True emptyDir
        backend <- markdownAgentDefBackend agentsDir (openConfigRepo cfgRoot)
        case mkAgentDefId "empty" of
          Right eid -> do
            m <- adbRead backend eid
            case m of
              Just d  -> adSystem d `shouldBe` Nothing
              Nothing -> expectationFailure "expected a def, got Nothing"
          Left _ -> expectationFailure "invalid id"

    it "per-file truncation marker fires at the configured limit" $ do
      withSystemTempDirectory "seal-def" $ \root -> do
        let zoeDir = root </> "zoe"
        createDirectoryIfMissing True zoeDir
        let big = T.replicate 1000 "x"
        TIO.writeFile (zoeDir </> "SOUL.md") big
        out <- composeDirSystemPrompt zoeDir 100
        out `shouldSatisfy` ("[...truncated at 100 chars...]" `T.isInfixOf`)
        out `shouldSatisfy` ("--- SOUL ---" `T.isInfixOf`)

    it "oversized bootstrap file (>1MiB) is skipped" $ do
      withSystemTempDirectory "seal-def" $ \root -> do
        let zoeDir = root </> "zoe"
        createDirectoryIfMissing True zoeDir
        -- Write a 2MiB SOUL.md; only this file exists, so the composed
        -- prompt is empty (the section is skipped).
        TIO.writeFile (zoeDir </> "SOUL.md") (T.replicate (2 * 1024 * 1024) "x")
        out <- composeDirSystemPrompt zoeDir defaultSectionCharLimit
        T.null out `shouldBe` True

    it "flat file takes precedence over directory on conflict" $
      withSystemTempDirectory "seal-def" $ \root -> do
        let cfgRoot = root </> "config"
            agentsDir = cfgRoot </> "agents"
            fooDir = agentsDir </> "foo"
        ensureConfigRepo cfgRoot
        createDirectoryIfMissing True fooDir
        TIO.writeFile (fooDir </> "SOUL.md") "dir soul"
        -- Also write a flat foo.md
        case mkAgentDefId "foo" of
          Right fid -> do
            let flat = AgentDef
                  { adId = fid
                  , adName = "flat-foo"
                  , adProvider = "ollama"
                  , adModel = ModelId "llama3"
                  , adSystem = Just "flat system"
                  , adTools = AllowAll
                  , adCreatedAt = sampleTime
                  , adUpdatedAt = sampleTime
                  , adSession = SessionId "s1"
                  }
            backend <- markdownAgentDefBackend agentsDir (openConfigRepo cfgRoot)
            adbUpdate backend flat
            m <- adbRead backend fid
            case m of
              Just d -> adName d `shouldBe` "flat-foo"
              Nothing -> expectationFailure "expected flat def, got Nothing"
            -- adbList returns one (not two) for foo
            defs <- adbList backend
            length (filter (\d -> agentDefIdText (adId d) == "foo") defs) `shouldBe` 1
          Left _ -> expectationFailure "invalid id"

    it "AGENT_DEF_UPDATE on a DirScheme agent flattens it: writes foo.md and preserves the composed prompt as the body" $
      withSystemTempDirectory "seal-def" $ \root -> do
        let cfgRoot = root </> "config"
            agentsDir = cfgRoot </> "agents"
            fooDir = agentsDir </> "foo"
        ensureConfigRepo cfgRoot
        createDirectoryIfMissing True fooDir
        TIO.writeFile (fooDir </> "SOUL.md") "I am foo."
        backend <- markdownAgentDefBackend agentsDir (openConfigRepo cfgRoot)
        -- Read the dir-scheme def, then update it (write flat foo.md).
        case mkAgentDefId "foo" of
          Right fid -> do
            Just dirDef <- adbRead backend fid
            let flatDef = dirDef { adName = "flattened-foo" }
            adbUpdate backend flatDef
            doesFileExist (agentsDir </> "foo.md") `shouldReturn` True
            m <- adbRead backend fid
            case m of
              Just d -> do
                adName d `shouldBe` "flattened-foo"
                -- The composed prompt from the dir is preserved as the flat body.
                case adSystem d of
                  Just body -> body `shouldSatisfy` ("I am foo." `T.isInfixOf`)
                  Nothing   -> expectationFailure "expected composed prompt preserved in flat body"
              Nothing -> expectationFailure "expected flat def after update"
          Left _ -> expectationFailure "invalid id"