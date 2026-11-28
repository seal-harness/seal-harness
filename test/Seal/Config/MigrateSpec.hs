{-# LANGUAGE OverloadedStrings #-}
module Seal.Config.MigrateSpec (spec) where

import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Data.Map.Strict qualified as Map
import Seal.Config.File (RuntimeConfig (..), loadRuntimeConfig)
import Seal.Config.Machines
  ( MachineFileConfig (..), MachinesConfig (..), loadMachinesConfig )
import Seal.Config.Migrate (migrateSecurityConfig)
import Seal.Config.Paths
  ( SealPaths (..), configFilePath, machinesFilePath, securityFilePath )
import Seal.Config.Security
  ( SecurityConfig (..), UntrustedExecFileConfig (..), loadSecurityConfig )
import Seal.Gateway.Config (PartialGatewayConfig (..))

-- | Helper: check if a Maybe UntrustedExecFileConfig is Just.
isJustUexec :: Maybe UntrustedExecFileConfig -> Bool
isJustUexec = \case Just _ -> True; Nothing -> False

spec :: Spec
spec = describe "Seal.Config.Migrate" $ do
  specExecutionMachines

  let makePaths tmp = SealPaths
        { spHome   = tmp
        , spConfig = tmp </> "config"
        , spState  = tmp </> "state"
        , spKeys   = tmp </> "keys"
        , spCache  = tmp </> "cache"
        }

  describe "Case 1: security.toml absent, config.toml has legacy fields" $ do
    it "migrates [untrusted_execution] and vault_* from config.toml to security.toml" $
      withSystemTempDirectory "seal-migrate" $ \tmp -> do
        let paths = makePaths tmp
            cfgPath = configFilePath paths
            secPath = securityFilePath paths
        createDirectoryIfMissing True (tmp </> "config")
        TIO.writeFile cfgPath $ T.unlines
          [ "vault_path = \"/tmp/vault.age\""
          , "vault_recipient = \"age1abc\""
          , "vault_key_type = \"x25519\""
          , "default_provider = \"anthropic\""
          , "[untrusted_execution]"
          , "mode = \"remote\""
          ]
        migrateSecurityConfig paths
        secResult <- loadSecurityConfig secPath
        case secResult of
          Right sec -> do
            scVaultRecipient sec `shouldBe` Just "age1abc"
            scUntrustedExec sec `shouldSatisfy` isJustUexec
          Left _ -> expectationFailure "security.toml failed to load after migration"
        cfgResult <- loadRuntimeConfig cfgPath
        case cfgResult of
          Right cfg -> rcDefaultProvider cfg `shouldBe` Just "anthropic"
          Left _ -> expectationFailure "config.toml failed to load after migration"
        rawCfg <- TIO.readFile cfgPath
        rawCfg `shouldSatisfy` not . T.isInfixOf "vault_recipient"
        rawCfg `shouldSatisfy` not . T.isInfixOf "[untrusted_execution]"

  describe "Case 2: both present, config.toml has stale legacy fields" $ do
    it "security.toml wins; stale fields cleaned from config.toml" $
      withSystemTempDirectory "seal-migrate" $ \tmp -> do
        let paths = makePaths tmp
            cfgPath = configFilePath paths
            secPath = securityFilePath paths
        createDirectoryIfMissing True (tmp </> "config")
        TIO.writeFile secPath "vault_recipient = \"age1fromsecurity\"\n"
        TIO.writeFile cfgPath $ T.unlines
          [ "vault_recipient = \"age1stale\""
          , "default_provider = \"ollama\""
          ]
        migrateSecurityConfig paths
        secResult <- loadSecurityConfig secPath
        case secResult of
          Right sec -> scVaultRecipient sec `shouldBe` Just "age1fromsecurity"
          Left _ -> expectationFailure "security.toml failed to load"
        rawCfg <- TIO.readFile cfgPath
        rawCfg `shouldSatisfy` not . T.isInfixOf "vault_recipient"
        rawCfg `shouldSatisfy` T.isInfixOf "default_provider"

  describe "Case 3: security.toml exists, config.toml clean" $ do
    it "is a no-op (idempotent)" $
      withSystemTempDirectory "seal-migrate" $ \tmp -> do
        let paths = makePaths tmp
            cfgPath = configFilePath paths
            secPath = securityFilePath paths
        createDirectoryIfMissing True (tmp </> "config")
        let originalSec = "vault_recipient = \"age1abc\"\n"
            originalCfg = "default_provider = \"ollama\"\n"
        TIO.writeFile secPath originalSec
        TIO.writeFile cfgPath originalCfg
        migrateSecurityConfig paths
        secContents <- TIO.readFile secPath
        cfgContents <- TIO.readFile cfgPath
        secContents `shouldBe` originalSec
        cfgContents `shouldBe` originalCfg

  describe "Case 4: neither exists" $ do
    it "is a no-op" $
      withSystemTempDirectory "seal-migrate" $ \tmp -> do
        let paths = makePaths tmp
        migrateSecurityConfig paths
        secExists <- doesFileExist (securityFilePath paths)
        secExists `shouldBe` False

  describe "Idempotency" $ do
    it "running migration twice does not duplicate or error" $
      withSystemTempDirectory "seal-migrate" $ \tmp -> do
        let paths = makePaths tmp
            cfgPath = configFilePath paths
            secPath = securityFilePath paths
        createDirectoryIfMissing True (tmp </> "config")
        TIO.writeFile cfgPath $ T.unlines
          [ "vault_recipient = \"age1abc\""
          , "default_provider = \"ollama\""
          ]
        migrateSecurityConfig paths
        Right sec1 <- loadSecurityConfig secPath
        scVaultRecipient sec1 `shouldBe` Just "age1abc"
        migrateSecurityConfig paths
        Right sec2 <- loadSecurityConfig secPath
        scVaultRecipient sec2 `shouldBe` Just "age1abc"

  describe "Corrupted [untrusted_execution] input (migration is a move, not validation)" $ do
    it "preserves mode=local with no remote block as-is" $
      withSystemTempDirectory "seal-migrate" $ \tmp -> do
        let paths = makePaths tmp
            cfgPath = configFilePath paths
            secPath = securityFilePath paths
        createDirectoryIfMissing True (tmp </> "config")
        TIO.writeFile cfgPath $ T.unlines
          [ "[untrusted_execution]"
          , "allow_localhost = false"
          ]
        migrateSecurityConfig paths
        Right sec <- loadSecurityConfig secPath
        -- The migrated flag is preserved, not re-derived from a mode string.
        fmap uefcAllowLocalhost (scUntrustedExec sec) `shouldBe` Just False

  describe "[gateway] moves like the other boot-only sections" $ do
    it "moves the table into a new security.toml and strips it from config.toml" $
      withSystemTempDirectory "seal-migrate" $ \tmp -> do
        let paths = makePaths tmp
            cfgPath = configFilePath paths
            secPath = securityFilePath paths
        createDirectoryIfMissing True (tmp </> "config")
        TIO.writeFile cfgPath $ T.unlines
          [ "default_provider = \"anthropic\""
          , "[gateway]"
          , "host = \"0.0.0.0\""
          , "port = 8443"
          ]
        migrateSecurityConfig paths
        Right sec <- loadSecurityConfig secPath
        fmap pgcHost (scGateway sec) `shouldBe` Just (Just "0.0.0.0")
        fmap pgcPort (scGateway sec) `shouldBe` Just (Just 8443)
        rawCfg <- TIO.readFile cfgPath
        rawCfg `shouldSatisfy` not . T.isInfixOf "[gateway]"
        rawCfg `shouldSatisfy` T.isInfixOf "default_provider"

    -- The upgrade case that matters: security.toml exists (it is seeded on first
    -- run) but has never carried a [gateway] table, so "security wins" would
    -- reset every operator's bind address to loopback.
    it "merges the table into an existing security.toml that has none" $
      withSystemTempDirectory "seal-migrate" $ \tmp -> do
        let paths = makePaths tmp
            cfgPath = configFilePath paths
            secPath = securityFilePath paths
        createDirectoryIfMissing True (tmp </> "config")
        TIO.writeFile secPath "vault_recipient = \"age1keep\"\n"
        TIO.writeFile cfgPath $ T.unlines
          [ "[gateway]"
          , "host = \"10.0.0.5\""
          , "port = 9443"
          ]
        migrateSecurityConfig paths
        Right sec <- loadSecurityConfig secPath
        -- The merge must not clobber what security.toml already owned.
        scVaultRecipient sec `shouldBe` Just "age1keep"
        fmap pgcHost (scGateway sec) `shouldBe` Just (Just "10.0.0.5")
        fmap pgcPort (scGateway sec) `shouldBe` Just (Just 9443)
        rawCfg <- TIO.readFile cfgPath
        rawCfg `shouldSatisfy` not . T.isInfixOf "[gateway]"

    it "keeps security.toml's table when both files carry one" $
      withSystemTempDirectory "seal-migrate" $ \tmp -> do
        let paths = makePaths tmp
            cfgPath = configFilePath paths
            secPath = securityFilePath paths
        createDirectoryIfMissing True (tmp </> "config")
        TIO.writeFile secPath "[gateway]\nhost = \"10.0.0.5\"\n"
        TIO.writeFile cfgPath "[gateway]\nhost = \"0.0.0.0\"\n"
        migrateSecurityConfig paths
        Right sec <- loadSecurityConfig secPath
        fmap pgcHost (scGateway sec) `shouldBe` Just (Just "10.0.0.5")
        rawCfg <- TIO.readFile cfgPath
        rawCfg `shouldSatisfy` not . T.isInfixOf "[gateway]"

    it "is idempotent: the second run leaves both files byte-identical" $
      withSystemTempDirectory "seal-migrate" $ \tmp -> do
        let paths = makePaths tmp
            cfgPath = configFilePath paths
            secPath = securityFilePath paths
        createDirectoryIfMissing True (tmp </> "config")
        TIO.writeFile secPath "vault_recipient = \"age1keep\"\n"
        TIO.writeFile cfgPath "[gateway]\nhost = \"10.0.0.5\"\n"
        migrateSecurityConfig paths
        firstSec <- TIO.readFile secPath
        firstCfg <- TIO.readFile cfgPath
        migrateSecurityConfig paths
        TIO.readFile secPath `shouldReturn` firstSec
        TIO.readFile cfgPath `shouldReturn` firstCfg

    it "never rewrites an unparseable security.toml, and never strips config.toml" $
      withSystemTempDirectory "seal-migrate" $ \tmp -> do
        let paths = makePaths tmp
            cfgPath = configFilePath paths
            secPath = securityFilePath paths
        createDirectoryIfMissing True (tmp </> "config")
        TIO.writeFile secPath "vault_path = [not valid toml"
        TIO.writeFile cfgPath "[gateway]\nhost = \"0.0.0.0\"\n"
        migrateSecurityConfig paths
        TIO.readFile secPath `shouldReturn` "vault_path = [not valid toml"
        rawCfg <- TIO.readFile cfgPath
        rawCfg `shouldSatisfy` T.isInfixOf "[gateway]"

    -- saveSecurityConfig refuses to rewrite a document that still holds the
    -- pre-split credential tables. That refusal must not cost the operator the
    -- only copy of their bind address.
    it "leaves config.toml alone when the security write is refused" $
      withSystemTempDirectory "seal-migrate" $ \tmp -> do
        let paths = makePaths tmp
            cfgPath = configFilePath paths
            secPath = securityFilePath paths
        createDirectoryIfMissing True (tmp </> "config")
        TIO.writeFile secPath $ T.unlines
          [ "[access_control.credentials.AAAAAAAAAAAAAAAAAAAAAA]"
          , "public_key = \"not-a-real-key\""
          ]
        TIO.writeFile cfgPath "[gateway]\nhost = \"0.0.0.0\"\n"
        migrateSecurityConfig paths
        rawCfg <- TIO.readFile cfgPath
        rawCfg `shouldSatisfy` T.isInfixOf "[gateway]"
        rawSec <- TIO.readFile secPath
        rawSec `shouldSatisfy` T.isInfixOf "credentials"

    -- A document that cannot be read must not be half-moved: the migration is a
    -- move, not a validation. (A wrong *value* is a different matter: every
    -- section here is decoded through 'Toml.dioptional', which demotes a type
    -- mismatch to "absent" — pre-existing behaviour for every optional field,
    -- not something this change introduces. Only a document that does not parse
    -- reaches this branch.)
    it "moves nothing when the document does not parse, and leaves it in place" $
      withSystemTempDirectory "seal-migrate" $ \tmp -> do
        let paths = makePaths tmp
            cfgPath = configFilePath paths
            secPath = securityFilePath paths
        createDirectoryIfMissing True (tmp </> "config")
        TIO.writeFile cfgPath $ T.unlines
          [ "[gateway]"
          , "host = \"0.0.0.0\""
          , "[untrusted_execution"
          ]
        migrateSecurityConfig paths
        doesFileExist secPath `shouldReturn` False
        rawCfg <- TIO.readFile cfgPath
        rawCfg `shouldSatisfy` T.isInfixOf "[gateway]"
        rawCfg `shouldSatisfy` T.isInfixOf "[untrusted_execution"

    it "does not treat a commented-out header as a setting" $
      withSystemTempDirectory "seal-migrate" $ \tmp -> do
        let paths = makePaths tmp
            cfgPath = configFilePath paths
            secPath = securityFilePath paths
        createDirectoryIfMissing True (tmp </> "config")
        TIO.writeFile cfgPath "# [gateway]\n# host = \"0.0.0.0\"\ndefault_provider = \"ollama\"\n"
        migrateSecurityConfig paths
        Right sec <- loadSecurityConfig secPath
        scGateway sec `shouldBe` Nothing
        -- The second run is a no-op, so the comment cannot cause churn either.
        firstCfg <- TIO.readFile cfgPath
        migrateSecurityConfig paths
        TIO.readFile cfgPath `shouldReturn` firstCfg

    -- Every gateway key is optional at the codec layer and `Toml.dioptional`
    -- demotes a type mismatch to "absent", so a quoted port reads as no port at
    -- all. Moving that would drop the value; stripping it would destroy the
    -- table. Do neither.
    it "leaves a [gateway] whose value does not read in place (no security.toml)" $
      withSystemTempDirectory "seal-migrate" $ \tmp -> do
        let paths = makePaths tmp
            cfgPath = configFilePath paths
            secPath = securityFilePath paths
        createDirectoryIfMissing True (tmp </> "config")
        TIO.writeFile cfgPath "[gateway]\nport = \"8443\"\n"
        migrateSecurityConfig paths
        doesFileExist secPath `shouldReturn` False
        TIO.readFile cfgPath `shouldReturn` "[gateway]\nport = \"8443\"\n"

    it "leaves both files alone when an existing security.toml meets an unreadable table" $
      withSystemTempDirectory "seal-migrate" $ \tmp -> do
        let paths = makePaths tmp
            cfgPath = configFilePath paths
            secPath = securityFilePath paths
        createDirectoryIfMissing True (tmp </> "config")
        TIO.writeFile secPath "vault_recipient = \"age1keep\"\n"
        TIO.writeFile cfgPath "[gateway]\nport = \"8443\"\n"
        migrateSecurityConfig paths
        TIO.readFile secPath `shouldReturn` "vault_recipient = \"age1keep\"\n"
        TIO.readFile cfgPath `shouldReturn` "[gateway]\nport = \"8443\"\n"

-- ---------------------------------------------------------------------------
-- WU-8: migrateExecutionMachines
--
-- The execution-machine migration, run from 'migrateSecurityConfig' so it needs
-- no separate boot call. Every row of design §4, plus the failure row.
-- ---------------------------------------------------------------------------

specExecutionMachines :: Spec
specExecutionMachines = describe "execution-machine migration (WU-8)" $ do

  let mkPaths tmp = SealPaths
        { spHome   = tmp
        , spConfig = tmp </> "config"
        , spState  = tmp </> "state"
        , spKeys   = tmp </> "keys"
        , spCache  = tmp </> "cache"
        }

  -- The legacy remote block, as an operator's security.toml would carry it.
  let legacyRemoteBlock =
        [ "[untrusted_execution]"
        , "mode = \"remote\""
        , "[untrusted_execution.remote]"
        , "host = \"builder.example.com\""
        , "user = \"seal\""
        , "port = 2222"
        , "identity = \"/home/seal/.ssh/id_ed25519\""
        , "known_hosts = \"/home/seal/.ssh/known_hosts\""
        , "workspace = \"/srv/seal/workspace\""
        ]

  -- T-MIG-1 + the pinning clause: the remote table becomes a machine named
  -- "default", is named as the default, and the flag turns local execution off.
  it "mode=remote + a complete remote block becomes machine \"default\" with allow_localhost = false" $
    withSystemTempDirectory "seal-mig-em" $ \tmp -> do
      let paths = mkPaths tmp
          secPath = securityFilePath paths
      createDirectoryIfMissing True (tmp </> "config")
      TIO.writeFile secPath (T.unlines legacyRemoteBlock)
      migrateSecurityConfig paths

      Right mc <- loadMachinesConfig paths
      Map.keys (mcMachines mc) `shouldBe` ["default"]
      mcDefault mc `shouldBe` Just "default"
      case Map.lookup "default" (mcMachines mc) of
        Nothing -> expectationFailure "the migrated machine is missing"
        Just m -> do
          mfcHost m `shouldBe` Just "builder.example.com"
          mfcUser m `shouldBe` Just "seal"
          mfcPort m `shouldBe` Just 2222
          mfcIdentity m `shouldBe` Just "/home/seal/.ssh/id_ed25519"
          mfcWorkspace m `shouldBe` Just "/srv/seal/workspace"

      Right sec <- loadSecurityConfig secPath
      fmap uefcAllowLocalhost (scUntrustedExec sec) `shouldBe` Just False

  -- "Drops known_hosts": the pin file is harness-owned now, so carrying the
  -- operator's path across would be a field nothing reads.
  it "drops the operator's known_hosts path rather than migrating it" $
    withSystemTempDirectory "seal-mig-em" $ \tmp -> do
      let paths = mkPaths tmp
      createDirectoryIfMissing True (tmp </> "config")
      TIO.writeFile (securityFilePath paths) (T.unlines legacyRemoteBlock)
      migrateSecurityConfig paths
      Right mc <- loadMachinesConfig paths
      (mfcIdentity =<< Map.lookup "default" (mcMachines mc))
        `shouldBe` Just "/home/seal/.ssh/id_ed25519"
      -- and the migrated machines.toml must not mention it at all
      raw <- TIO.readFile (machinesFilePath paths)
      raw `shouldSatisfy` (not . T.isInfixOf "known_hosts")

  -- DW-2: the old block is gone, not retained for rollback convenience.
  it "removes the old [untrusted_execution] block on the migration boot" $
    withSystemTempDirectory "seal-mig-em" $ \tmp -> do
      let paths = mkPaths tmp
          secPath = securityFilePath paths
      createDirectoryIfMissing True (tmp </> "config")
      TIO.writeFile secPath (T.unlines legacyRemoteBlock)
      migrateSecurityConfig paths
      raw <- TIO.readFile secPath
      raw `shouldSatisfy` (not . T.isInfixOf "[untrusted_execution.remote]")
      raw `shouldSatisfy` (not . T.isInfixOf "mode")

  -- The incomplete-block row: the flag is set, but NO machine is written. A
  -- half-populated machine would resolve to nothing useful, and writing it
  -- would make `default` point at something unusable.
  it "mode=remote with an incomplete block sets the flag and writes no machine" $
    withSystemTempDirectory "seal-mig-em" $ \tmp -> do
      let paths = mkPaths tmp
          secPath = securityFilePath paths
      createDirectoryIfMissing True (tmp </> "config")
      TIO.writeFile secPath $ T.unlines
        [ "[untrusted_execution]"
        , "mode = \"remote\""
        , ""
        , "[untrusted_execution.remote]"
        , "host = \"builder.example.com\""
        ]
      migrateSecurityConfig paths
      Right sec <- loadSecurityConfig secPath
      fmap uefcAllowLocalhost (scUntrustedExec sec) `shouldBe` Just False
      -- No machine written: the file may not exist at all, or be empty.
      eMc <- loadMachinesConfig paths
      case eMc of
        Right mc -> mcMachines mc `shouldBe` Map.empty
        Left _   -> pure ()

  -- Row 4.
  it "mode=local becomes allow_localhost = true" $
    withSystemTempDirectory "seal-mig-em" $ \tmp -> do
      let paths = mkPaths tmp
          secPath = securityFilePath paths
      createDirectoryIfMissing True (tmp </> "config")
      TIO.writeFile secPath $ T.unlines
        [ "[untrusted_execution]"
        , "mode = \"local\""
        ]
      migrateSecurityConfig paths
      Right sec <- loadSecurityConfig secPath
      fmap uefcAllowLocalhost (scUntrustedExec sec) `shouldBe` Just True

  -- Row 5: an existing machines.toml wins. Only the strip happens, so an
  -- operator who already wrote machines by hand keeps them.
  it "an existing machines.toml wins; only the old block is stripped" $
    withSystemTempDirectory "seal-mig-em" $ \tmp -> do
      let paths = mkPaths tmp
          secPath = securityFilePath paths
      createDirectoryIfMissing True (tmp </> "config")
      TIO.writeFile (machinesFilePath paths) $ T.unlines
        [ "default = \"mine\""
        , "[machines.mine]"
        , "host = \"mine.example.com\""
        , "user = \"me\""
        , "workspace = \"/srv/mine\""
        ]
      TIO.writeFile secPath (T.unlines legacyRemoteBlock)
      migrateSecurityConfig paths
      Right mc <- loadMachinesConfig paths
      Map.keys (mcMachines mc) `shouldBe` ["mine"]
      mcDefault mc `shouldBe` Just "mine"
      -- and security.toml still records that local execution is off
      Right sec <- loadSecurityConfig secPath
      fmap uefcAllowLocalhost (scUntrustedExec sec) `shouldBe` Just False

  it "is idempotent: a second run changes nothing" $
    withSystemTempDirectory "seal-mig-em" $ \tmp -> do
      let paths = mkPaths tmp
          secPath = securityFilePath paths
          machPath = machinesFilePath paths
      createDirectoryIfMissing True (tmp </> "config")
      TIO.writeFile secPath (T.unlines legacyRemoteBlock)
      migrateSecurityConfig paths
      sec1 <- TIO.readFile secPath
      mach1 <- TIO.readFile machPath
      migrateSecurityConfig paths
      sec2 <- TIO.readFile secPath
      mach2 <- TIO.readFile machPath
      sec2 `shouldBe` sec1
      mach2 `shouldBe` mach1

  -- T-MIG-5: a failed write must not leave the install permissive. The flag is
  -- set first and the machine written second, so a failure after the flag write
  -- leaves "allow_localhost = false, no machine" — which refuses to run anything
  -- rather than silently running locally.
  it "a failed machines.toml write does not downgrade the install" $
    withSystemTempDirectory "seal-mig-em" $ \tmp -> do
      let paths = mkPaths tmp
          secPath = securityFilePath paths
      createDirectoryIfMissing True (tmp </> "config")
      TIO.writeFile secPath (T.unlines legacyRemoteBlock)
      -- Make machines.toml unwritable by putting a DIRECTORY where the file goes.
      createDirectoryIfMissing True (machinesFilePath paths </> "blocker")
      migrateSecurityConfig paths
      Right sec <- loadSecurityConfig secPath
      fmap uefcAllowLocalhost (scUntrustedExec sec) `shouldBe` Just False

  -- The absent-section row: no [untrusted_execution] at all ⇒ the flag is left
  -- absent, which resolves to True. That is today's behaviour and must not be
  -- written out (an explicit `true` would look like a decision the operator made).
  it "no [untrusted_execution] section leaves allow_localhost absent" $
    withSystemTempDirectory "seal-mig-em" $ \tmp -> do
      let paths = mkPaths tmp
          secPath = securityFilePath paths
      createDirectoryIfMissing True (tmp </> "config")
      TIO.writeFile secPath "vault_recipient = \"age1abc\"\n"
      migrateSecurityConfig paths
      Right sec <- loadSecurityConfig secPath
      scUntrustedExec sec `shouldBe` Nothing
