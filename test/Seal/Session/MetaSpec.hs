{-# LANGUAGE OverloadedStrings #-}
module Seal.Session.MetaSpec (spec) where

import Data.Aeson (ToJSON (..), Value (..), decode, encode, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Key qualified as K
import Data.Either (fromRight)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import Test.Hspec

import Seal.Agent.Def.Types (mkAgentDefId)
import Seal.Core.Types (mkSessionId, sessionIdText)
import Seal.Execution.Types (mkMachineName)
import Seal.Session.Meta (SessionMeta (..), defaultSessionMeta, setExecMachine)

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 43200)

sampleMeta :: SessionMeta
sampleMeta =
  let sid = fromRight (error "bad id") (mkSessionId "20260701-120000-042")
  in (let base = defaultSessionMeta sid sampleTime in base) { smModel = "claude-opus-4-8" }

-- | Render a meta to its JSON object, failing loudly if it is not one.
metaObject :: SessionMeta -> KM.KeyMap Value
metaObject m = case toJSON m of
  Object o -> o
  other    -> error ("expected a JSON object, got " <> show other)

spec :: Spec
spec = describe "Seal.Session.Meta" $ do
  it "round-trips through JSON" $
    decode (encode sampleMeta) `shouldBe` Just sampleMeta

  it "uses snake_case keys and preserves the id text" $ do
    let m2 = decode (encode sampleMeta)
    fmap (sessionIdText . smId) m2 `shouldBe` Just "20260701-120000-042"

  it "defaults channel to \"cli\" when absent" $ do
    let j = object
              [ "id" .= ("20260701-120000-042" :: String)
              , "provider" .= ("anthropic" :: String)
              , "model" .= ("claude-opus-4-8" :: String)
              , "created_at" .= sampleTime
              , "last_active" .= sampleTime ]
    fmap smChannel (decode (encode j)) `shouldBe` Just "cli"

  it "defaults agent to Nothing when absent (backwards-compat)" $ do
    let j = object
              [ "id" .= ("20260701-120000-042" :: String)
              , "provider" .= ("anthropic" :: String)
              , "model" .= ("claude-opus-4-8" :: String)
              , "created_at" .= sampleTime
              , "last_active" .= sampleTime ]
    fmap smAgent (decode (encode j)) `shouldBe` Just Nothing

  it "round-trips smAgent = Just aid" $ do
    let aid = fromRight (error "bad agent id") (mkAgentDefId "zoe")
        m = sampleMeta { smAgent = Just aid }
    fmap smAgent (decode (encode m)) `shouldBe` Just (Just aid)

  it "round-trips smSystemOverride = Just t" $ do
    let m = sampleMeta { smSystemOverride = Just "be concise" }
    fmap smSystemOverride (decode (encode m)) `shouldBe` Just (Just "be concise")

  it "defaults smSystemOverride to Nothing when absent (backwards-compat)" $ do
    let j = object
              [ "id" .= ("20260701-120000-042" :: String)
              , "provider" .= ("anthropic" :: String)
              , "model" .= ("claude-opus-4-8" :: String)
              , "created_at" .= sampleTime
              , "last_active" .= sampleTime ]
    fmap smSystemOverride (decode (encode j)) `shouldBe` Just Nothing

  it "round-trips smAgentName = Just t" $ do
    let m = sampleMeta { smAgentName = Just "zoe" }
    fmap smAgentName (decode (encode m)) `shouldBe` Just (Just "zoe")

  it "defaults smAgentName to Nothing when absent (backwards-compat)" $ do
    let j = object
              [ "id" .= ("20260701-120000-042" :: String)
              , "provider" .= ("anthropic" :: String)
              , "model" .= ("claude-opus-4-8" :: String)
              , "created_at" .= sampleTime
              , "last_active" .= sampleTime ]
    fmap smAgentName (decode (encode j)) `shouldBe` Just Nothing

  it "round-trips smDescription = Just t" $ do
    let m = sampleMeta { smDescription = Just "my tab name" }
    fmap smDescription (decode (encode m)) `shouldBe` Just (Just "my tab name")

  it "defaults smDescription to Nothing when absent (backwards-compat)" $ do
    let j = object
              [ "id" .= ("20260701-120000-042" :: String)
              , "provider" .= ("anthropic" :: String)
              , "model" .= ("claude-opus-4-8" :: String)
              , "created_at" .= sampleTime
              , "last_active" .= sampleTime ]
    fmap smDescription (decode (encode j)) `shouldBe` Just Nothing

  it "round-trips smRepoUrl = Just t" $ do
    let m = sampleMeta { smRepoUrl = Just "https://github.com/seal-harness/seal-harness.git" }
    fmap smRepoUrl (decode (encode m)) `shouldBe` Just (Just "https://github.com/seal-harness/seal-harness.git")

  it "defaults smRepoUrl to Nothing when absent (backwards-compat)" $ do
    let j = object
              [ "id" .= ("20260701-120000-042" :: String)
              , "provider" .= ("anthropic" :: String)
              , "model" .= ("claude-opus-4-8" :: String)
              , "created_at" .= sampleTime
              , "last_active" .= sampleTime ]
    fmap smRepoUrl (decode (encode j)) `shouldBe` Just Nothing

  it "round-trips smRepoBranch = Just t" $ do
    let m = sampleMeta { smRepoBranch = Just "release/1.2" }
    fmap smRepoBranch (decode (encode m)) `shouldBe` Just (Just "release/1.2")

  it "defaults smRepoBranch to Nothing when absent (backwards-compat)" $ do
    let j = object
              [ "id" .= ("20260701-120000-042" :: String)
              , "provider" .= ("anthropic" :: String)
              , "model" .= ("claude-opus-4-8" :: String)
              , "repo_url" .= ("https://github.com/seal-harness/seal-harness.git" :: String)
              , "created_at" .= sampleTime
              , "last_active" .= sampleTime ]
    fmap smRepoBranch (decode (encode j)) `shouldBe` Just Nothing

  it "round-trips smSealFrontMatter = False" $ do
    let m = sampleMeta { smSealFrontMatter = False }
    fmap smSealFrontMatter (decode (encode m)) `shouldBe` Just False

  it "defaults smSealFrontMatter to True when absent (backwards-compat)" $ do
    -- A session.json written before the toggle existed has no
    -- 'seal_front_matter' key — it must load with the front matter ON.
    let j = object
              [ "id" .= ("20260701-120000-042" :: String)
              , "provider" .= ("anthropic" :: String)
              , "model" .= ("claude-opus-4-8" :: String)
              , "created_at" .= sampleTime
              , "last_active" .= sampleTime ]
    fmap smSealFrontMatter (decode (encode j)) `shouldBe` Just True

  it "defaults smParent to Nothing when absent (backwards-compat)" $ do
    -- A session.json written before the parent link existed has no
    -- 'parent' key — it must load as a top-level session.
    let j = object
              [ "id" .= ("20260701-120000-042" :: String)
              , "provider" .= ("anthropic" :: String)
              , "model" .= ("claude-opus-4-8" :: String)
              , "created_at" .= sampleTime
              , "last_active" .= sampleTime ]
    fmap smParent (decode (encode j)) `shouldBe` Just Nothing

  it "round-trips smParent = Just sid" $ do
    let sid = fromRight (error "bad id") (mkSessionId "20260601-120000-009")
        m = sampleMeta { smParent = Just sid }
    fmap smParent (decode (encode m)) `shouldBe` Just (Just sid)

  describe "smExecMachine (the per-session pin)" $ do

    it "an absent key decodes to Nothing — every legacy session" $ do
      let j = object
                [ "id" .= ("20260701-120000-042" :: String)
                , "provider" .= ("anthropic" :: String)
                , "model" .= ("claude-opus-4-8" :: String)
                , "created_at" .= sampleTime
                , "last_active" .= sampleTime ]
      fmap smExecMachine (decode (encode j) :: Maybe SessionMeta) `shouldBe` Just Nothing

    it "a present valid key round-trips" $ do
      let name = fromRight (error "bad name") (mkMachineName "builder")
          m = setExecMachine name sampleMeta
      fmap smExecMachine (decode (encode m) :: Maybe SessionMeta)
        `shouldBe` Just (Just name)

    it "a malformed key decodes to Nothing, not a decode failure" $ do
      -- A hand-edited session must stay readable. §5 row 0 fail-closes the
      -- case that matters (a VALID pin naming a removed machine).
      let j = object
                [ "id" .= ("20260701-120000-042" :: String)
                , "provider" .= ("anthropic" :: String)
                , "model" .= ("claude-opus-4-8" :: String)
                , "exec_machine" .= ("-oProxyCommand=x" :: String)
                , "created_at" .= sampleTime
                , "last_active" .= sampleTime ]
      fmap smExecMachine (decode (encode j) :: Maybe SessionMeta) `shouldBe` Just Nothing

    it "ToJSON OMITS exec_machine when Nothing — it must not emit null" $ do
      -- Meta.hs's house style is `"repo_url" .= smRepoUrl m` (Maybe -> null).
      -- Copying that here would put a PRESENT exec_machine key on every
      -- post-deploy session, and §9's "a present key means a deliberate
      -- choice" would be false on exactly the population it measures.
      KM.member (K.fromText "exec_machine") (metaObject sampleMeta) `shouldBe` False

    it "ToJSON emits the key when Just" $ do
      let name = fromRight (error "bad name") (mkMachineName "builder")
      KM.lookup (K.fromText "exec_machine") (metaObject (setExecMachine name sampleMeta))
        `shouldBe` Just (String "builder")

    it "repo_url, by contrast, is still written as null — the house style" $ do
      KM.lookup (K.fromText "repo_url") (metaObject sampleMeta) `shouldBe` Just Null

    it "setExecMachine is total and replaces an existing pin" $ do
      let a = fromRight (error "bad") (mkMachineName "a")
          b = fromRight (error "bad") (mkMachineName "b")
      smExecMachine (setExecMachine b (setExecMachine a sampleMeta))
        `shouldBe` Just b

    it "defaultSessionMeta is unpinned" $
      smExecMachine sampleMeta `shouldBe` Nothing

  describe "the opcode cannot set the pin (design §4.3)" $ do
    -- A grep test: SESSION_MANAGE action=new mints via newSessionMeta, which
    -- takes no machine argument, so it resolves unpinned (= the effective
    -- default). The guarantee is that no opcode can PIN a session, so an
    -- agent cannot move its own untrusted code to a machine it chose.
    it "no opcode module writes smExecMachine" $ do
      hits <- grepSources "src/Seal/ISA" "smExecMachine"
      hits `shouldBe` []
    it "no opcode module imports setExecMachine" $ do
      hits <- grepSources "src/Seal/ISA" "setExecMachine"
      hits `shouldBe` []

-- | @rg -l@ over a source directory; empty when nothing matches.
grepSources :: FilePath -> String -> IO [FilePath]
grepSources dir needle = do
  (code, out, _err) <- readProcessWithExitCode "rg" ["-l", "--fixed-strings", needle, dir] ""
  pure (case code of
          ExitSuccess -> filter (not . null) (lines out)
          _           -> [])
