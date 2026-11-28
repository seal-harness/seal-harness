{-# LANGUAGE OverloadedStrings #-}
module Seal.Tools.Exec.HostKeyAdoptionSpec (spec) where

import Data.List (isInfixOf)
import Data.Text (Text)
import Data.Text qualified as T
import System.IO.Temp (withSystemTempDirectory)
import System.Directory (doesFileExist)
import Test.Hspec

import Seal.Tools.Exec.HostKeyAdoption
import Seal.Config.Machines (MachineName, mkMachineName)
import Seal.Tools.Exec.Types
  ( SshConfig (..), mkSshHost, mkSshUser, mkRemotePath
  )

spec :: Spec
spec = describe "Seal.Tools.Exec.HostKeyAdoption" $ do

  describe "mkHostKeyAdoptionWithProbe (injected probe)" $ do

    it "adopts the key when the human approves" $
      withSystemTempDirectory "seal-known-hosts" $ \tmp -> do
        let knownHosts = tmp <> "/known_hosts"
            keyLineT = "192.168.0.104 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkeydata" :: Text
            probe _ = pure (Right HostKeyInfo
              { hkiMachine = Nothing
            , hkiHost = "zoe@192.168.0.104"
              , hkiKeyType = "ssh-ed25519"
              , hkiKeyLine = keyLineT
              , hkiFingerprint = "SHA256:TestFingerprint1234"
              })
            confirm _ = pure True
            hka = mkHostKeyAdoptionWithProbe probe confirm
        result <- hkaAdopt hka (machine "alpha") (sshCfg knownHosts)
        result `shouldBe` Right ()
        exists <- doesFileExist knownHosts
        exists `shouldBe` True
        content <- readFile knownHosts
        content `shouldSatisfy` ("AAAAC3NzaC1lZDI1NTE5AAAAItestkeydata" `isInfixOf`)

    it "returns Left when the human rejects" $
      withSystemTempDirectory "seal-known-hosts" $ \tmp -> do
        let knownHosts = tmp <> "/known_hosts"
            keyLineT = "192.168.0.104 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkeydata" :: Text
            probe _ = pure (Right HostKeyInfo
              { hkiMachine = Nothing
            , hkiHost = "zoe@192.168.0.104"
              , hkiKeyType = "ssh-ed25519"
              , hkiKeyLine = keyLineT
              , hkiFingerprint = "SHA256:TestFingerprint1234"
              })
            confirm _ = pure False
            hka = mkHostKeyAdoptionWithProbe probe confirm
        result <- hkaAdopt hka (machine "alpha") (sshCfg knownHosts)
        result `shouldSatisfy` \case
          Left msg -> "rejected" `T.isInfixOf` msg
          _        -> False
        exists <- doesFileExist knownHosts
        exists `shouldBe` False

    it "returns Left when the probe fails" $ do
      let probe _ = pure (Left "ssh-keyscan failed: connection refused")
          confirm _ = pure True
          hka = mkHostKeyAdoptionWithProbe probe confirm
      result <- hkaAdopt hka (machine "alpha") (sshCfg "/tmp/irrelevant")
      result `shouldSatisfy` \case
        Left msg -> "ssh-keyscan failed" `T.isInfixOf` msg
        _        -> False

    it "does not duplicate the key if already present" $
      withSystemTempDirectory "seal-known-hosts" $ \tmp -> do
        let knownHosts = tmp <> "/known_hosts"
            keyLineS = "192.168.0.104 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkeydata"
            keyLineT = T.pack keyLineS :: Text
        writeFile knownHosts (keyLineS <> "\n")
        let probe _ = pure (Right HostKeyInfo
              { hkiMachine = Nothing
            , hkiHost = "zoe@192.168.0.104"
              , hkiKeyType = "ssh-ed25519"
              , hkiKeyLine = keyLineT
              , hkiFingerprint = "SHA256:TestFingerprint1234"
              })
            confirm _ = pure True
            hka = mkHostKeyAdoptionWithProbe probe confirm
        result <- hkaAdopt hka (machine "alpha") (sshCfg knownHosts)
        result `shouldBe` Right ()
        content <- readFile knownHosts
        countOccurrences keyLineS content `shouldBe` 1

    it "appends to an existing known_hosts file without losing entries" $
      withSystemTempDirectory "seal-known-hosts" $ \tmp -> do
        let knownHosts = tmp <> "/known_hosts"
            existingKey = "10.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexistingkey"
            newKeyT = "192.168.0.104 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAInewkeydata" :: Text
        writeFile knownHosts (existingKey <> "\n")
        let probe _ = pure (Right HostKeyInfo
              { hkiMachine = Nothing
            , hkiHost = "zoe@192.168.0.104"
              , hkiKeyType = "ssh-ed25519"
              , hkiKeyLine = newKeyT
              , hkiFingerprint = "SHA256:NewFingerprint"
              })
            confirm _ = pure True
            hka = mkHostKeyAdoptionWithProbe probe confirm
        result <- hkaAdopt hka (machine "alpha") (sshCfg knownHosts)
        result `shouldBe` Right ()
        content <- readFile knownHosts
        content `shouldSatisfy` ("Iexistingkey" `isInfixOf`)
        content `shouldSatisfy` ("Inewkeydata" `isInfixOf`)

  describe "mkHostKeyAdoptionStub" $ do

    it "always returns Left 'not available'" $ do
      let hka = mkHostKeyAdoptionStub
      result <- hkaAdopt hka (machine "alpha") (sshCfg "/tmp/irrelevant")
      result `shouldSatisfy` \case
        Left msg -> "not available" `T.isInfixOf` msg
        _        -> False

  describe "extractFirstKeyLine" $ do

    it "extracts the first key line from ssh-keyscan output" $ do
      let output = "# 192.168.0.104:22 SSH-2.0-OpenSSH_9.9\n\
                   \192.168.0.104 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkeydata\n"
      extractFirstKeyLine output
        `shouldBe` Just ("ssh-ed25519",
                          "192.168.0.104 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkeydata")

    it "returns Nothing for empty output" $
      extractFirstKeyLine "" `shouldBe` Nothing

    it "skips comment lines" $ do
      let output = "# comment line\n\
                   \# another comment\n\
                   \192.168.0.104 ssh-rsa AAAAB3NzaC1yc2Etest\n"
      extractFirstKeyLine output
        `shouldBe` Just ("ssh-rsa",
                          "192.168.0.104 ssh-rsa AAAAB3NzaC1yc2Etest")

  describe "buildAdoptionPrompt" $ do

    it "T-STR-7: renders the frozen four lines exactly" $ do
      -- Frozen copy from the requirements, §5.5 row 7. Asserted as EXACT
      -- equality on the joined single-line form, including the two-space
      -- indent and the `key:  ` padding that aligns the values — the design
      -- §3.4 calls that padding out as part of the string, not formatting.
      let info = HostKeyInfo
            { hkiMachine = Just (machine "mac-mini")
            , hkiHost = "mac-mini.lan"
            , hkiKeyType = "ssh-ed25519"
            , hkiKeyLine = "mac-mini.lan ssh-ed25519 AAAA..."
            , hkiFingerprint = "SHA256:9xQ7fA"
            }
      buildAdoptionPrompt info `shouldBe` T.unlines
        [ "machine \"mac-mini\" is not yet known."
        , "  host: mac-mini.lan"
        , "  key:  ssh-ed25519 SHA256:9xQ7fA"
        , "Trust this key? [y/N]"
        ]

    it "names the machine, so a key prompt cannot be confused across machines" $ do
      -- Two machines answering the same host string must produce distinct
      -- prompts; otherwise a human confirming one is confirming both.
      let infoFor nm = HostKeyInfo
            { hkiMachine = Just (machine nm)
            , hkiHost = "shared-host.lan"
            , hkiKeyType = "ssh-ed25519"
            , hkiKeyLine = "shared-host.lan ssh-ed25519 AAAA..."
            , hkiFingerprint = "SHA256:same"
            }
      buildAdoptionPrompt (infoFor "alpha")
        `shouldNotBe` buildAdoptionPrompt (infoFor "beta")

    it "includes the host, key type, and fingerprint" $ do
      let info = HostKeyInfo
            { hkiMachine = Nothing
            , hkiHost = "zoe@192.168.0.104"
            , hkiKeyType = "ssh-ed25519"
            , hkiKeyLine = "192.168.0.104 ssh-ed25519 AAAA..."
            , hkiFingerprint = "SHA256:AbCdEf1234"
            }
          prompt = buildAdoptionPrompt info
      prompt `shouldSatisfy` ("zoe@192.168.0.104" `T.isInfixOf`)
      prompt `shouldSatisfy` ("ssh-ed25519" `T.isInfixOf`)
      prompt `shouldSatisfy` ("SHA256:AbCdEf1234" `T.isInfixOf`)
      -- Superseded by the frozen copy (T-STR-7); kept as the
      -- "all three facts are present" check.
      prompt `shouldSatisfy` ("Trust this key? [y/N]" `T.isInfixOf`)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

sshCfg :: FilePath -> SshConfig
sshCfg knownHosts = SshConfig
  { scHost       = either (error "fixture") id (mkSshHost "192.168.0.104")
  , scUser       = either (error "fixture") id (mkSshUser "zoe")
  , scPort       = 22
  , scIdentity   = Nothing
  , scKnownHosts = knownHosts
  , scWorkspace  = either (error "fixture") id (mkRemotePath "/Users/zoe/sandbox")
  }

countOccurrences :: String -> String -> Int
countOccurrences needle haystack =
  length [ () | i <- [0 .. length haystack - 1]
         , needle `isPrefixOf'` drop i haystack
         ]
  where
    isPrefixOf' [] _ = True
    isPrefixOf' _ [] = False
    isPrefixOf' (x:xs) (y:ys) = x == y && isPrefixOf' xs ys

-- | 'mkMachineName' behind a helper: the constructor is deliberately
-- unexported, and the reserved @local@ is refused by design.
machine :: Text -> MachineName
machine t = case mkMachineName t of
  Right n -> n
  Left e  -> error ("fixture: mkMachineName " <> T.unpack t <> ": " <> T.unpack e)
