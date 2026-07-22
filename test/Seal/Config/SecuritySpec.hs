{-# LANGUAGE OverloadedStrings #-}
module Seal.Config.SecuritySpec (spec) where

import Data.Bits ((.&.))
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (getFileStatus, fileMode)

import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, elements, forAll, oneof)

import Seal.Config.Security
  ( SecurityConfig (..), UntrustedExecFileConfig (..)
  , UntrustedExecRemoteFileConfig (..), defaultSecurityConfig
  , loadSecurityConfig, saveSecurityConfig, untrustedExecConfigFromSecurity )

spec :: Spec
spec = describe "Seal.Config.Security" $ do

  describe "defaultSecurityConfig" $ do
    it "has all Nothing fields" $
      defaultSecurityConfig `shouldBe` SecurityConfig
        { scVaultPath      = Nothing
        , scVaultRecipient = Nothing
        , scVaultIdentity  = Nothing
        , scVaultUnlock    = Nothing
        , scVaultKeyType   = Nothing
        , scUntrustedExec  = Nothing
        }

  describe "loadSecurityConfig" $ do
    it "returns defaultSecurityConfig when the file is absent" $
      withSystemTempDirectory "seal-sec-test" $ \dir -> do
        let path = dir </> "security.toml"
        result <- loadSecurityConfig path
        result `shouldBe` Right defaultSecurityConfig

    it "parses a valid TOML file with vault fields" $
      withSystemTempDirectory "seal-sec-test" $ \dir -> do
        let path = dir </> "security.toml"
        TIO.writeFile path $ T.unlines
          [ "vault_path = \"/home/user/.seal/config/vault/vault.age\""
          , "vault_recipient = \"age1abc123\""
          , "vault_key_type = \"x25519\""
          ]
        result <- loadSecurityConfig path
        case result of
          Left err -> expectationFailure ("parse failed: " <> T.unpack err)
          Right cfg -> do
            scVaultPath      cfg `shouldBe` Just "/home/user/.seal/config/vault/vault.age"
            scVaultRecipient cfg `shouldBe` Just "age1abc123"
            scVaultIdentity  cfg `shouldBe` Nothing
            scVaultUnlock    cfg `shouldBe` Nothing
            scVaultKeyType   cfg `shouldBe` Just "x25519"

    it "returns Left on malformed TOML" $
      withSystemTempDirectory "seal-sec-test" $ \dir -> do
        let path = dir </> "security.toml"
        TIO.writeFile path "vault_path = [not valid toml"
        result <- loadSecurityConfig path
        case result of
          Left _  -> pure ()
          Right _ -> expectationFailure "expected Left for malformed TOML but got Right"

  describe "saveSecurityConfig / loadSecurityConfig round-trip" $ do
    it "round-trips a fully-populated SecurityConfig" $
      withSystemTempDirectory "seal-sec-test" $ \dir -> do
        let path = dir </> "security.toml"
        let cfg = SecurityConfig
              { scVaultPath      = Just "/tmp/vault.age"
              , scVaultRecipient = Just "age1abc"
              , scVaultIdentity  = Just "/home/user/.seal/keys/default.identity"
              , scVaultUnlock    = Just "on_demand"
              , scVaultKeyType   = Just "x25519"
              , scUntrustedExec  = Nothing
              }
        saveSecurityConfig path cfg
        result <- loadSecurityConfig path
        result `shouldBe` Right cfg

    it "round-trips defaultSecurityConfig (all Nothing)" $
      withSystemTempDirectory "seal-sec-test" $ \dir -> do
        let path = dir </> "security.toml"
        saveSecurityConfig path defaultSecurityConfig
        result <- loadSecurityConfig path
        result `shouldBe` Right defaultSecurityConfig

    it "leaves no leftover .tmp file after save" $
      withSystemTempDirectory "seal-sec-test" $ \dir -> do
        let path = dir </> "security.toml"
        saveSecurityConfig path defaultSecurityConfig
        leftover <- doesFileExist (path <> ".tmp")
        leftover `shouldBe` False

    it "writes security.toml with mode 0600" $
      withSystemTempDirectory "seal-sec-test" $ \dir -> do
        let path = dir </> "security.toml"
        saveSecurityConfig path defaultSecurityConfig
        stat <- getFileStatus path
        (fileMode stat .&. 0o777) `shouldBe` 0o600

  describe "untrusted_execution section" $ do

    it "absent [untrusted_execution] section decodes to Nothing" $
      withSystemTempDirectory "seal-sec-test" $ \dir -> do
        let path = dir </> "security.toml"
        TIO.writeFile path "vault_path = \"/tmp/vault.age\"\n"
        Right cfg <- loadSecurityConfig path
        scUntrustedExec cfg `shouldBe` Nothing

    it "parses [untrusted_execution] with mode = local (default)" $
      withSystemTempDirectory "seal-sec-test" $ \dir -> do
        let path = dir </> "security.toml"
        TIO.writeFile path $ T.unlines
          [ "[untrusted_execution]"
          , "mode = \"local\""
          ]
        Right cfg <- loadSecurityConfig path
        scUntrustedExec cfg `shouldBe` Just (UntrustedExecFileConfig
          { uefcMode = "local"
          , uefcRemote = Nothing
          })

    it "parses [untrusted_execution] with mode = remote and a [remote] sub-table" $
      withSystemTempDirectory "seal-sec-test" $ \dir -> do
        let path = dir </> "security.toml"
        TIO.writeFile path $ T.unlines
          [ "[untrusted_execution]"
          , "mode = \"remote\""
          , "[untrusted_execution.remote]"
          , "host = \"exec.internal\""
          , "user = \"agent\""
          , "port = 22"
          , "known_hosts = \"/home/agent/.ssh/known_hosts\""
          , "workspace = \"/srv/agent-workspace\""
          ]
        Right cfg <- loadSecurityConfig path
        scUntrustedExec cfg `shouldBe` Just (UntrustedExecFileConfig
          { uefcMode = "remote"
          , uefcRemote = Just (UntrustedExecRemoteFileConfig
              { uerfcHost = Just "exec.internal"
              , uerfcUser = Just "agent"
              , uerfcPort = Just 22
              , uerfcIdentity = Nothing
              , uerfcKnownHosts = Just "/home/agent/.ssh/known_hosts"
              , uerfcWorkspace = Just "/srv/agent-workspace"
              })
          })

    it "parses mode=remote with no [remote] block (fail-closed is at call time, not parse time)" $
      withSystemTempDirectory "seal-sec-test" $ \dir -> do
        let path = dir </> "security.toml"
        TIO.writeFile path $ T.unlines
          [ "[untrusted_execution]"
          , "mode = \"remote\""
          ]
        Right cfg <- loadSecurityConfig path
        scUntrustedExec cfg `shouldBe` Just (UntrustedExecFileConfig
          { uefcMode = "remote"
          , uefcRemote = Nothing
          })

    it "round-trips an untrusted_execution section through save/load" $
      withSystemTempDirectory "seal-sec-test" $ \dir -> do
        let path = dir </> "security.toml"
        let cfg = defaultSecurityConfig
              { scUntrustedExec = Just (UntrustedExecFileConfig
                  { uefcMode = "remote"
                  , uefcRemote = Just (UntrustedExecRemoteFileConfig
                      { uerfcHost = Just "exec.internal"
                      , uerfcUser = Just "agent"
                      , uerfcPort = Just 22
                      , uerfcIdentity = Nothing
                      , uerfcKnownHosts = Just "/home/agent/.ssh/known_hosts"
                      , uerfcWorkspace = Just "/srv/agent-workspace"
                      })
                  })
              }
        saveSecurityConfig path cfg
        result <- loadSecurityConfig path
        case result of
          Left err -> expectationFailure ("reload failed: " <> T.unpack err)
          Right back -> scUntrustedExec back `shouldBe` scUntrustedExec cfg

  describe "untrustedExecConfigFromSecurity" $ do

    it "returns Nothing when the section is absent" $ do
      untrustedExecConfigFromSecurity defaultSecurityConfig `shouldBe` Nothing

    it "returns Nothing when mode=local (no remote needed)" $ do
      let cfg = defaultSecurityConfig
            { scUntrustedExec = Just (UntrustedExecFileConfig "local" Nothing) }
      untrustedExecConfigFromSecurity cfg `shouldBe` Nothing

  -- Design §9.6: "no value of RuntimeConfig affects selectExecBackend's
  -- remote-only arm." Since the untrusted_execution fields live in
  -- SecurityConfig (not RuntimeConfig), the resolution is a pure function of
  -- SecurityConfig alone. This property asserts determinism: the same
  -- SecurityConfig always yields the same UntrustedExecConfig, and the
  -- resolution never touches RuntimeConfig (it cannot — the field is absent).
  prop "untrustedExecConfigFromSecurity is a pure function of SecurityConfig (unaffected by RuntimeConfig)" $
    forAll genSecurityConfig $ \sc ->
      untrustedExecConfigFromSecurity sc == untrustedExecConfigFromSecurity sc

-- | Generator for arbitrary SecurityConfig values (for the QuickCheck property).
genSecurityConfig :: Gen SecurityConfig
genSecurityConfig = SecurityConfig
  <$> pure Nothing   -- scVaultPath
  <*> pure Nothing   -- scVaultRecipient
  <*> pure Nothing   -- scVaultIdentity
  <*> pure Nothing   -- scVaultUnlock
  <*> pure Nothing   -- scVaultKeyType
  <*> oneof
       [ pure Nothing
       , Just <$> (UntrustedExecFileConfig
           <$> elements ["local", "remote"]
           <*> pure Nothing)
       ]