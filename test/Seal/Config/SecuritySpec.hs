{-# LANGUAGE OverloadedStrings #-}
module Seal.Config.SecuritySpec (spec) where

import Data.Bits ((.&.))
import Data.ByteString qualified as BSC
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (getFileStatus, fileMode)
import Toml qualified

import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, elements, forAll, oneof)

import Seal.Config.Security
  ( SecurityConfig (..), UntrustedExecFileConfig (..)
  , UntrustedExecRemoteFileConfig (..), defaultSecurityConfig
  , WriteMode (..), hasLegacyLayout, loadSecurityConfig, saveSecurityConfig
  , tomlKeyPaths, untrustedExecConfigFromSecurity )

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
        , scAccessControl  = Nothing
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
              , scAccessControl  = Nothing
              }
        saveSecurityConfig path cfg PreserveCredentials `shouldReturn` Right ()
        result <- loadSecurityConfig path
        result `shouldBe` Right cfg

    it "round-trips defaultSecurityConfig (all Nothing)" $
      withSystemTempDirectory "seal-sec-test" $ \dir -> do
        let path = dir </> "security.toml"
        saveSecurityConfig path defaultSecurityConfig PreserveCredentials `shouldReturn` Right ()
        result <- loadSecurityConfig path
        result `shouldBe` Right defaultSecurityConfig

    it "leaves no leftover .tmp file after save" $
      withSystemTempDirectory "seal-sec-test" $ \dir -> do
        let path = dir </> "security.toml"
        saveSecurityConfig path defaultSecurityConfig PreserveCredentials `shouldReturn` Right ()
        leftover <- doesFileExist (path <> ".tmp")
        leftover `shouldBe` False

    it "writes security.toml with mode 0600" $
      withSystemTempDirectory "seal-sec-test" $ \dir -> do
        let path = dir </> "security.toml"
        saveSecurityConfig path defaultSecurityConfig PreserveCredentials `shouldReturn` Right ()
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
        saveSecurityConfig path cfg PreserveCredentials `shouldReturn` Right ()
        result <- loadSecurityConfig path
        case result of
          Left err -> expectationFailure ("reload failed: " <> T.unpack err)
          Right back -> scUntrustedExec back `shouldBe` scUntrustedExec cfg

  -- Design §10. The pre-split layout put credentials inside security.toml.
  -- Once the store moves out, a write that rewrites security.toml without
  -- noticing would drop every credential — silently, on a document whose next
  -- boot then reads as unconfigured. Detection has to decode, not grep: the
  -- same document has a second spelling (dotted keys under [access_control])
  -- that a substring scan for "[access_control.credentials." misses entirely.
  describe "hasLegacyLayout" $ do
    it "detects the [access_control.credentials.<id>] header spelling" $
      hasLegacyLayout headerSpellingFixture `shouldBe` True

    it "detects the dotted-key spelling under [access_control]" $
      hasLegacyLayout dottedKeyFixture `shouldBe` True

    it "is false for a file whose credentials already live elsewhere" $
      hasLegacyLayout (T.unlines
        [ "[access_control]"
        , "mode = \"passkey\""
        , "origin = \"https://seal.example.com\""
        ]) `shouldBe` False

    it "is false for a file with no [access_control] section at all" $
      hasLegacyLayout "vault_recipient = \"age1abc\"\n" `shouldBe` False

    it "is false for an unparseable file (that is a different refusal)" $
      hasLegacyLayout "[access_control.credentials.AA\npublic_key = " `shouldBe` False

  -- Design §10. The refusal lives in saveSecurityConfig, the one function every
  -- writer funnels through, so no current or future caller can forget it. It
  -- reads the file as it is on disk: the caller has already decoded the
  -- document, and decoding is precisely what loses a legacy table.
  describe "saveSecurityConfig WriteMode" $ do
    it "PreserveCredentials refuses a legacy credential table, leaving the bytes alone" $
      withSystemTempDirectory "seal-sec-test" $ \dir -> do
        let path = dir </> "security.toml"
        TIO.writeFile path headerSpellingFixture
        original <- BSC.readFile path
        refused <- saveSecurityConfig path defaultSecurityConfig PreserveCredentials
        refused `shouldSatisfy` mentionsMigrate
        BSC.readFile path `shouldReturn` original

    it "PreserveCredentials refuses the dotted-key spelling too" $
      withSystemTempDirectory "seal-sec-test" $ \dir -> do
        let path = dir </> "security.toml"
        TIO.writeFile path dottedKeyFixture
        original <- BSC.readFile path
        refused <- saveSecurityConfig path defaultSecurityConfig PreserveCredentials
        refused `shouldSatisfy` mentionsMigrate
        BSC.readFile path `shouldReturn` original

    it "DropCredentials is the --yes-gated exemption and does write" $
      withSystemTempDirectory "seal-sec-test" $ \dir -> do
        let path = dir </> "security.toml"
        TIO.writeFile path headerSpellingFixture
        saveSecurityConfig path defaultSecurityConfig DropCredentials
          `shouldReturn` Right ()
        loadSecurityConfig path `shouldReturn` Right defaultSecurityConfig

    it "PreserveCredentials writes normally when there is nothing to preserve" $
      withSystemTempDirectory "seal-sec-test" $ \dir -> do
        let path = dir </> "security.toml"
        TIO.writeFile path "vault_recipient = \"age1abc\"\n"
        saveSecurityConfig path defaultSecurityConfig PreserveCredentials
          `shouldReturn` Right ()
        loadSecurityConfig path `shouldReturn` Right defaultSecurityConfig

  -- The rewrite path is load -> modify -> encode, and the codec only knows the
  -- fields it declares. Anything else in the document survives only because the
  -- encoder re-emits what the decoder kept, so "did the round trip keep it?" is
  -- asked of the document, not of a hand-written field list.
  describe "rewrite collateral damage" $ do
    it "preserves every value-bearing path across a write (explicit tables)" $
      withSystemTempDirectory "seal-sec-test" $ \dir ->
        assertPreserved dir explicitTablesFixture

    it "preserves every value-bearing path across a write (dotted keys)" $
      withSystemTempDirectory "seal-sec-test" $ \dir ->
        assertPreserved dir dottedTablesFixture

    it "has teeth: a dropped section is detected" $
      withSystemTempDirectory "seal-sec-test" $ \dir -> do
        let path = dir </> "security.toml"
        TIO.writeFile path explicitTablesFixture
        pathsBefore <- valuePaths path
        -- Simulate the codec losing a section outright.
        TIO.writeFile path "vault_recipient = \"age1abc\"\n"
        pathsAfter <- valuePaths path
        (pathsBefore == pathsAfter) `shouldBe` False

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
genSecurityConfig = do
  uefc <- oneof
       [ pure Nothing
       , Just <$> (UntrustedExecFileConfig
           <$> elements ["local", "remote"]
           <*> pure Nothing)
       ]
  pure SecurityConfig
    { scVaultPath      = Nothing
    , scVaultRecipient = Nothing
    , scVaultIdentity  = Nothing
    , scVaultUnlock    = Nothing
    , scVaultKeyType   = Nothing
    , scUntrustedExec  = uefc
    , scAccessControl  = Nothing
    }

-- | One legacy credential, in the shape the pre-split file used.
legacyCredentialLines :: Text -> [Text]
legacyCredentialLines prefix =
  [ prefix <> "public_key = \"" <> T.replicate 86 "A" <> "\""
  , prefix <> "sign_count = 0"
  , prefix <> "label = \"laptop\""
  , prefix <> "created_at = \"2026-10-30T14:00:00Z\""
  , prefix <> "rp_id = \"localhost\""
  ]

legacyCredentialId :: Text
legacyCredentialId = T.replicate 22 "A"

headerSpellingFixture :: Text
headerSpellingFixture = T.unlines
  ([ "[access_control.credentials." <> legacyCredentialId <> "]" ]
    <> legacyCredentialLines "")

-- | The same document written with dotted keys under @[access_control]@: no
-- @[access_control.credentials.@ substring appears anywhere in it.
dottedKeyFixture :: Text
dottedKeyFixture = T.unlines
  ( [ "[access_control]"
    , "mode = \"passkey\""
    ]
    <> legacyCredentialLines ("credentials." <> legacyCredentialId <> ".") )

-- | The refusal must name the command that fixes it, or the operator is told
-- "no" with no way forward.
mentionsMigrate :: Either Text () -> Bool
mentionsMigrate (Left msg) = "migrate-credentials" `T.isInfixOf` msg
mentionsMigrate (Right ()) = False

-- | Both codec-owned sections, spelled with explicit table headers. Nothing
-- here is a credential, so a write is allowed and must be lossless.
explicitTablesFixture :: Text
explicitTablesFixture = T.unlines
  [ "[untrusted_execution]"
  , "mode = \"local\""
  , ""
  , "[access_control]"
  , "mode = \"passkey\""
  , "origin = \"https://seal.example.com\""
  ]

-- | The same data, spelled with dotted keys: @untrusted_execution.mode@ at the
-- root (one flat pair, no table node) plus the same @[access_control]@ section.
-- A rewrite normalises it into a table, which must not look like a change in
-- the document's data.
dottedTablesFixture :: Text
dottedTablesFixture = T.unlines
  [ "untrusted_execution.mode = \"local\""
  , ""
  , "[access_control]"
  , "mode = \"passkey\""
  , "origin = \"https://seal.example.com\""
  ]

-- | The document's data, as a set of value-bearing key paths.
valuePaths :: FilePath -> IO (Set.Set [Text])
valuePaths path = do
  raw <- TIO.readFile path
  pure $ case Toml.parse raw of
    Left err -> error ("fixture must parse: " <> T.unpack (Toml.unTomlParseError err))
    Right toml -> Set.fromList (map (map Toml.unPiece) (tomlKeyPaths toml))

-- | Load @fixture@ into @dir@, rewrite it through the production path, and
-- assert the document still carries exactly the same data.
assertPreserved :: FilePath -> Text -> Expectation
assertPreserved dir fixture = do
  let path = dir </> "security.toml"
  TIO.writeFile path fixture
  pathsBefore <- valuePaths path
  loaded <- loadSecurityConfig path
  case loaded of
    Left err -> expectationFailure ("fixture must decode: " <> T.unpack err)
    Right cfg -> do
      saveSecurityConfig path cfg PreserveCredentials `shouldReturn` Right ()
      pathsAfter <- valuePaths path
      pathsAfter `shouldBe` pathsBefore
