{-# LANGUAGE OverloadedStrings #-}
-- | One case per row of the design §10 table.
--
-- 'bootPlan' is pure, so the whole boot matrix is reachable without a socket or
-- a running server: build the inputs, assert the decision. Every refusal case
-- names the 'BootRefusal' constructor rather than asserting "it failed",
-- because two constructors are plausible for the same file and only the
-- specific one tells the operator which of two different problems they have.
module Seal.Config.BootPlanSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

import Test.Hspec

import Seal.Config.BootPlan
  ( BindCoordinates (..), BootInputs (..), BootPlan (..), BootRefusal (..)
  , CredentialsPresence (..), bootPlan, bootRefusalMessage, preflight )
import Seal.Config.Credentials (CredentialsFile (..), credentialsVersion, saveCredentials)
import Seal.Config.Paths (SealPaths (..), credentialsFilePath, securityFilePath)
import Seal.Config.Security
  ( AccessControlFileConfig (..), CredentialFileConfig (..) )
import Seal.Security.EnrollmentGrant (GrantSource (..))
import Seal.Security.WebAuthn.Types (AccessMode (..))

spec :: Spec
spec = describe "Seal.Config.BootPlan" $ do

  describe "bootPlan refusals" $ do
    it "refuses an unparseable security.toml" $
      plan localhost (inputs { biSecurityRaw = "this is not toml [[[" })
        `shouldSatisfy` isSecurityUnparseable

    it "refuses a legacy credential table" $
      plan localhost (inputs { biSecurityRaw = legacyRaw })
        `shouldBe` Left BrLegacyLayout

    it "refuses credentials.toml that does not parse" $
      plan localhost (inputs { biCredentials = CredentialsInvalid "boom" })
        `shouldBe` Left (BrCredentialsInvalid "boom")

    it "refuses a credential entry that is semantically invalid" $
      plan localhost (inputs
        { biSection     = Just passkeySection
        , biCredentials = CredentialsPresent credentialsVersion
                            (Map.singleton credId badCredential) })
        `shouldSatisfy` isCredentialsInvalid

    it "refuses an empty but present store (a corruption signal)" $
      plan localhost (inputs
        { biCredentials = CredentialsPresent credentialsVersion Map.empty })
        `shouldBe` Left BrCredentialsEmpty

    it "refuses an unknown credentials format version" $
      plan localhost (inputs { biCredentials = CredentialsPresent 99 Map.empty })
        `shouldBe` Left (BrCredentialsVersion 99)

    -- Ported from the `mode = "off"` case in SecurityAccessControlSpec, which
    -- reached this through resolveAccessControl. Dropping it there without
    -- covering it here would quietly remove the only test that a bad mode is a
    -- refusal rather than a default.
    it "refuses an invalid mode (the ported mode = \"off\" fixture)" $
      plan localhost (inputs { biSection = Just (sectionWith (Just "passkey") "off") })
        `shouldSatisfy` isModeInvalid

    it "refuses unusable coordinates (passkey on a wildcard bind)" $
      plan (BindCoordinates "0.0.0.0" 8787)
           (inputs { biSection     = Just passkeySection
                   , biCredentials = CredentialsPresent credentialsVersion usableCreds })
        `shouldSatisfy` isCoordinatesInvalid

    it "refuses passkey over plain http on a non-loopback bind (BrUnsafeBind)" $
      plan (BindCoordinates "seal.example.com" 8787)
           (inputs { biSection     = Just (sectionWith (Just "http://seal.example.com:8787") "passkey")
                   , biCredentials = CredentialsPresent credentialsVersion usableCreds })
        `shouldSatisfy` isUnsafeBind

    it "refuses a public bind with a loopback origin, distinctly from BrUnsafeBind" $
      plan (BindCoordinates "seal.example.com" 8787)
           (inputs { biSection = Just (sectionWith (Just "http://localhost:8787") "passkey") })
        `shouldBe` Left BrPublicBindWithLoopbackOrigin

  describe "bootPlan states" $ do
    it "unconfigured: no section, no credentials -> mint a token grant" $
      plan localhost inputs
        `shouldBe` Right BootPlan
          { bpMode      = AccessUnconfigured
          , bpOrigin    = Just "http://localhost:8787"
          , bpRpId      = Just "localhost"
          , bpCreds     = Map.empty
          , bpMintGrant = Just CliToken
          }

    it "open: no credentials with mode = none -> open, and mints" $
      expectPlan localhost (inputs { biSection = Just (sectionWith Nothing "none") })
        $ \bootPlan' -> do
            bpMode bootPlan' `shouldBe` AccessOpen
            bpMintGrant bootPlan' `shouldBe` Just CliToken

    it "passkey with a usable credential -> no grant" $
      expectPlan localhost (inputs
        { biSection     = Just passkeySection
        , biCredentials = CredentialsPresent credentialsVersion usableCreds })
        $ \bootPlan' -> do
            bpMode bootPlan' `shouldBe` AccessPasskey
            Map.keys (bpCreds bootPlan') `shouldBe` [credId]
            bpMintGrant bootPlan' `shouldBe` Nothing

    it "passkey with only orphaned credentials -> mints (rp_mismatch recovery)" $
      expectPlan localhost (inputs
        { biSection     = Just passkeySection
        , biCredentials = CredentialsPresent credentialsVersion orphanedCreds })
        $ \bootPlan' -> do
            bpMode bootPlan' `shouldBe` AccessPasskey
            bpMintGrant bootPlan' `shouldBe` Just CliToken

    it "present credentials with mode = none -> open, and mints" $
      expectPlan localhost (inputs
        { biSection     = Just (sectionWith Nothing "none")
        , biCredentials = CredentialsPresent credentialsVersion usableCreds })
        $ \bootPlan' -> do
            bpMode bootPlan' `shouldBe` AccessOpen
            bpMintGrant bootPlan' `shouldBe` Just CliToken

    it "passkey over https on a public bind is allowed" $
      expectPlan (BindCoordinates "seal.example.com" 8787) (inputs
        { biSection     = Just (sectionWith (Just "https://seal.example.com") "passkey")
        , biCredentials = CredentialsPresent credentialsVersion usableCreds })
        $ \bootPlan' -> do
            bpMode bootPlan' `shouldBe` AccessPasskey
            bpOrigin bootPlan' `shouldBe` Just "https://seal.example.com"
            bpRpId bootPlan' `shouldBe` Just "seal.example.com"

  describe "bootRefusalMessage" $
    it "tells the operator what to change, for every refusal" $
      mapM_ (shouldSatisfyAction . bootRefusalMessage) allRefusals

  describe "preflight" $ do
    it "reads security.toml as text and as a section" $
      withHome $ \paths -> do
        TIO.writeFile (securityFilePath paths) (T.unlines
          [ "[access_control]"
          , "mode = \"passkey\""
          , "origin = \"https://seal.example.com\""
          ])
        result <- preflight paths
        case result of
          Left refusal -> expectationFailure ("expected inputs, got " <> show refusal)
          Right bootInputs -> do
            biCredentials bootInputs `shouldBe` CredentialsAbsent
            fmap acfcOrigin (biSection bootInputs) `shouldBe` Just (Just "https://seal.example.com")
            biSecurityRaw bootInputs `shouldSatisfy` T.isInfixOf "seal.example.com"

    it "reads credentials.toml" $
      withHome $ \paths -> do
        saveCredentials (credentialsFilePath paths)
          (CredentialsFile credentialsVersion usableCreds)
        result <- preflight paths
        case result of
          Left refusal -> expectationFailure ("expected inputs, got " <> show refusal)
          Right bootInputs -> case biCredentials bootInputs of
            CredentialsPresent v creds -> do
              v `shouldBe` credentialsVersion
              Map.keys creds `shouldBe` [credId]
            other -> expectationFailure ("expected present credentials, got " <> show other)

    it "reports a legacy layout before the (necessarily) missing store" $
      withHome $ \paths -> do
        TIO.writeFile (securityFilePath paths) legacyRaw
        result <- preflight paths
        case result of
          Left refusal -> expectationFailure ("preflight should only read: " <> show refusal)
          Right bootInputs -> do
            biCredentials bootInputs `shouldBe` CredentialsAbsent
            plan localhost bootInputs `shouldBe` Left BrLegacyLayout

    it "reports an unparseable security.toml with its message" $
      withHome $ \paths -> do
        TIO.writeFile (securityFilePath paths) "this is not toml [[["
        result <- preflight paths
        case result of
          Left refusal -> expectationFailure ("preflight should only read: " <> show refusal)
          Right bootInputs ->
            plan localhost bootInputs `shouldSatisfy` isSecurityUnparseable

--------------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------------

localhost :: BindCoordinates
localhost = BindCoordinates "localhost" 8787

-- | An unconfigured boot: no file, no section, no credentials.
inputs :: BootInputs
inputs = BootInputs
  { biSecurityRaw = ""
  , biSection     = Nothing
  , biCredentials = CredentialsAbsent
  }

credId :: Text
credId = T.replicate 22 "A"

usableCreds :: Map.Map Text CredentialFileConfig
usableCreds = Map.singleton credId (credentialFor "localhost")

orphanedCreds :: Map.Map Text CredentialFileConfig
orphanedCreds = Map.singleton credId (credentialFor "old.example.com")

credentialFor :: Text -> CredentialFileConfig
credentialFor rp = CredentialFileConfig
  { cfcPublicKey = T.replicate 86 "A"
  , cfcSignCount = 0
  , cfcLabel     = "laptop"
  , cfcCreatedAt = "2026-10-30T14:00:00Z"
  , cfcRpId      = rp
  , cfcAddedVia  = Just "cli_token"
  }

badCredential :: CredentialFileConfig
badCredential = (credentialFor "localhost") { cfcPublicKey = "!!!not-base64url!!!" }

passkeySection :: AccessControlFileConfig
passkeySection = sectionWith Nothing "passkey"

sectionWith :: Maybe Text -> Text -> AccessControlFileConfig
sectionWith origin mode = AccessControlFileConfig
  { acfcMode        = Just mode
  , acfcOrigin      = origin
  , acfcRpId        = Nothing
  }

legacyRaw :: Text
legacyRaw = T.unlines
  [ "[access_control.credentials." <> credId <> "]"
  , "public_key = \"" <> T.replicate 86 "A" <> "\""
  , "sign_count = 0"
  , "label = \"laptop\""
  , "created_at = \"2026-10-30T14:00:00Z\""
  , "rp_id = \"localhost\""
  ]

plan :: BindCoordinates -> BootInputs -> Either BootRefusal BootPlan
plan = bootPlan

expectPlan
  :: BindCoordinates -> BootInputs -> (BootPlan -> Expectation) -> Expectation
expectPlan coords bootInputs check = case plan coords bootInputs of
  Left refusal    -> expectationFailure ("expected a plan, got " <> show refusal)
  Right bootPlan' -> check bootPlan'

isSecurityUnparseable :: Either BootRefusal BootPlan -> Bool
isSecurityUnparseable (Left (BrSecurityUnparseable msg)) = not (T.null msg)
isSecurityUnparseable _                                  = False

isCredentialsInvalid :: Either BootRefusal BootPlan -> Bool
isCredentialsInvalid (Left (BrCredentialsInvalid _)) = True
isCredentialsInvalid _                               = False

isModeInvalid :: Either BootRefusal BootPlan -> Bool
isModeInvalid (Left (BrModeInvalid _)) = True
isModeInvalid _                        = False

isCoordinatesInvalid :: Either BootRefusal BootPlan -> Bool
isCoordinatesInvalid (Left (BrCoordinatesInvalid _)) = True
isCoordinatesInvalid _                               = False

isUnsafeBind :: Either BootRefusal BootPlan -> Bool
isUnsafeBind (Left (BrUnsafeBind _)) = True
isUnsafeBind _                       = False

allRefusals :: [BootRefusal]
allRefusals =
  [ BrSecurityUnparseable "unexpected token"
  , BrLegacyLayout
  , BrCredentialsInvalid "unexpected token"
  , BrCredentialsEmpty
  , BrCredentialsVersion 9
  , BrModeInvalid "off"
  , BrCoordinatesInvalid "origin is not a URL"
  , BrUnsafeBind "the origin is not https"
  , BrPublicBindWithLoopbackOrigin
  ]

-- | A refusal has to say what to do, not just that something is wrong.
shouldSatisfyAction :: Text -> Expectation
shouldSatisfyAction message =
  message `shouldSatisfy` \m ->
    any (`T.isInfixOf` m) ["seal ", "Fix ", "Set ", "Use ", "Run ", "Bind ", "Upgrade "]

withHome :: (SealPaths -> IO a) -> IO a
withHome act = withSystemTempDirectory "seal-bootplan" $ \dir -> do
  let paths = SealPaths
        { spHome = dir, spConfig = dir </> "config", spState = dir </> "state"
        , spKeys = dir </> "keys", spCache = dir </> "cache" }
  act paths
