{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.SecretSpec (spec) where

import Data.Aeson (encode, object, (.=))
import Data.ByteString (ByteString)
import Data.Char (isAlphaNum)
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Data.IORef (newIORef)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Seal.Config.Paths
import Seal.ISA.Opcode
import Seal.ISA.Ops.Secret
import Seal.Providers.Class
import Seal.Security.Vault
import Seal.Security.Vault.Age
import Seal.TestHelpers.FakeCaps
import Seal.TestHelpers.Arbitrary ()  -- Arbitrary Text
import Seal.Types.App
import Seal.Types.Config
import Seal.Types.Env
import Seal.Logging.Logger (testSealLogger)
import Seal.Vault.Commands

runTestApp :: App a -> IO a
runTestApp act = do logger <- testSealLogger; env <- mkEnv logger defaultConfig; runApp env act

-- | Set up a vault with an optional initial secret, returning the
-- 'VaultRuntime' and the 'VaultHandle'.
withVaultRuntime
  :: FilePath
  -> Maybe (Text, ByteString)
  -> IO (VaultRuntime, VaultHandle)
withVaultRuntime tmpDir initialSecret = do
  let vaultDir  = tmpDir </> "config" </> "vault"
      vaultPath = vaultDir </> "vault.age"
      paths     = SealPaths
        { spHome   = tmpDir
        , spConfig = tmpDir </> "config"
        , spState  = tmpDir </> "state"
        , spKeys   = tmpDir </> "keys"
        , spCache  = tmpDir </> "cache"
        }
  createDirectoryIfMissing True vaultDir
  let vaultCfg = VaultConfig
        { vcPath    = vaultPath
        , vcKeyType = "mock"
        , vcUnlock  = UnlockOnDemand
        }
  h <- openVault vaultCfg mkMockEncryptor
  _ <- vhInit h
  _ <- vhUnlock h
  _ <- case initialSecret of
    Just (k, v) -> vhPut h k v
    Nothing     -> pure (Right ())
  ref <- newIORef (Just h)
  let rt = VaultRuntime
        { vrPaths      = paths
        , vrConfigPath = tmpDir </> "config" </> "config.toml"
        , vrHandleRef  = ref
        }
  pure (rt, h)

-- | Generator for non-empty 'Text' drawn from the valid secret-name alphabet
-- (alphanumeric, underscore, hyphen). Keeps the property sub-second.
genValidNameChars :: Gen Text
genValidNameChars = do
  c  <- elements (['a'..'z'] <> ['A'..'Z'] <> ['0'..'9'])
  cs <- listOf (elements (['a'..'z'] <> ['A'..'Z'] <> ['0'..'9'] <> "_-"))
  pure (T.pack (c : cs))

spec :: Spec
spec = describe "Seal.ISA.Ops.Secret" $ do

  -- -----------------------------------------------------------------------
  -- Pure helpers
  -- -----------------------------------------------------------------------

  describe "filterSecretList" $ do
    it "Nothing returns input unchanged" $
      filterSecretList Nothing ["a", "b", "c"] `shouldBe` ["a", "b", "c"]

    it "Just allowed filters to only keys in the set" $ do
      let allowed = Set.fromList ["a", "c"]
      filterSecretList (Just allowed) ["a", "b", "c", "d"] `shouldBe` ["a", "c"]

    it "Just empty-set filters out everything" $
      filterSecretList (Just Set.empty) ["a", "b"] `shouldBe` ([] :: [Text])

    it "Nothing on empty list returns empty list" $
      filterSecretList Nothing ([] :: [Text]) `shouldBe` []

    it "preserves order of the original list" $ do
      let allowed = Set.fromList ["x", "y"]
      filterSecretList (Just allowed) ["y", "z", "x"] `shouldBe` ["y", "x"]

    prop "Nothing is identity" $ \(xs :: [Text]) ->
      filterSecretList Nothing xs == xs

    prop "Just allowed keeps only members, preserving order" $ \(xs :: [Text]) (allowed :: Set Text) ->
      filterSecretList (Just allowed) xs == filter (`Set.member` allowed) xs

  describe "isSecretAllowed" $ do
    it "Nothing returns True for any key" $ do
      isSecretAllowed Nothing "anything" `shouldBe` True
      isSecretAllowed Nothing "" `shouldBe` True

    it "Just allowed returns True for members" $ do
      let allowed = Set.fromList ["TOKEN", "API_KEY"]
      isSecretAllowed (Just allowed) "TOKEN" `shouldBe` True
      isSecretAllowed (Just allowed) "API_KEY" `shouldBe` True

    it "Just allowed returns False for non-members" $ do
      let allowed = Set.fromList ["TOKEN"]
      isSecretAllowed (Just allowed) "SECRET" `shouldBe` False

    it "Just empty-set returns False for everything" $
      isSecretAllowed (Just Set.empty) "any" `shouldBe` False

    prop "Nothing always True" $ \(k :: Text) ->
      isSecretAllowed Nothing k

    prop "Just allowed is Set.member" $ \(k :: Text) (allowed :: Set Text) ->
      isSecretAllowed (Just allowed) k == Set.member k allowed

  describe "isValidSecretName" $ do
    it "accepts alphanumeric names" $ do
      isValidSecretName "abc123" `shouldBe` True
      isValidSecretName "ABC" `shouldBe` True
      isValidSecretName "X9" `shouldBe` True

    it "accepts underscores and hyphens" $ do
      isValidSecretName "api_key" `shouldBe` True
      isValidSecretName "my-secret" `shouldBe` True
      isValidSecretName "a_b-c" `shouldBe` True

    it "rejects empty string" $
      isValidSecretName "" `shouldBe` False

    it "rejects spaces" $
      isValidSecretName "my secret" `shouldBe` False

    it "rejects special characters" $ do
      isValidSecretName "key!" `shouldBe` False
      isValidSecretName "key/path" `shouldBe` False
      isValidSecretName "key@v2" `shouldBe` False

    it "rejects dots" $
      isValidSecretName "config.toml" `shouldBe` False

    prop "matches spec: non-empty && all alnum/underscore/hyphen" $ \(t :: Text) ->
      isValidSecretName t == (not (T.null t) && T.all (\c -> isAlphaNum c || c == '_' || c == '-') t)

    prop "valid alphabet always accepted" $
      forAll genValidNameChars $ \t -> isValidSecretName t

  -- -----------------------------------------------------------------------
  -- GET
  -- -----------------------------------------------------------------------

  describe "SECRET_MANAGE action=get" $ do

    it "returns the secret value to the model but never serialises it into orRecorded" $
      withSystemTempDirectory "seal-secret-op" $ \tmpDir -> do
        (rt, _) <- withVaultRuntime tmpDir (Just ("TOKEN", "s3cr3t"))
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt Nothing caps
        r <- runTestApp (opRun op localBackend (object
          [ "action" .= ("get" :: String)
          , "name"   .= ("TOKEN" :: String)
          ]))
        orParts r `shouldBe` [TrpText "s3cr3t"]
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf "s3cr3t" recorded `shouldBe` False
        orIsError r `shouldBe` False

    it "missing key sets orIsError=True and orRecorded contains only the key name" $
      withSystemTempDirectory "seal-secret-op-missing" $ \tmpDir -> do
        (rt, _) <- withVaultRuntime tmpDir Nothing
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt Nothing caps
        r <- runTestApp (opRun op localBackend (object
          [ "action" .= ("get" :: String)
          , "name"   .= ("NOPE" :: String)
          ]))
        orIsError r `shouldBe` True
        orRecorded r `shouldBe` object ["name" .= ("NOPE" :: String)]

  -- -----------------------------------------------------------------------
  -- PUT
  -- -----------------------------------------------------------------------

  describe "SECRET_MANAGE action=put" $ do

    it "stores a new secret and never records the value in orRecorded" $
      withSystemTempDirectory "seal-secret-put" $ \tmpDir -> do
        (rt, h) <- withVaultRuntime tmpDir Nothing
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt Nothing caps
        r <- runTestApp (opRun op localBackend (object
          [ "action" .= ("put" :: String)
          , "name"   .= ("API_KEY" :: String)
          , "value"  .= ("sk-abc123" :: String)
          ]))
        orIsError r `shouldBe` False
        let recorded = TE.decodeUtf8 (BL.toStrict (encode (orRecorded r)))
        T.isInfixOf "sk-abc123" recorded `shouldBe` False
        stored <- vhGet h "API_KEY"
        stored `shouldBe` Right "sk-abc123"

    it "updates an existing secret (upsert semantics)" $
      withSystemTempDirectory "seal-secret-put-update" $ \tmpDir -> do
        (rt, h) <- withVaultRuntime tmpDir (Just ("TOKEN", "old-value"))
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt Nothing caps
        _ <- runTestApp (opRun op localBackend (object
          [ "action" .= ("put" :: String)
          , "name"   .= ("TOKEN" :: String)
          , "value"  .= ("new-value" :: String)
          ]))
        stored <- vhGet h "TOKEN"
        stored `shouldBe` Right "new-value"

    it "rejects put with empty value at authorize gate" $
      withSystemTempDirectory "seal-secret-put-empty" $ \tmpDir -> do
        (rt, _) <- withVaultRuntime tmpDir Nothing
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt Nothing caps
        case opAuthorize op (object
          [ "action" .= ("put" :: String)
          , "name"   .= ("KEY" :: String)
          , "value"  .= ("" :: String)
          ]) of
          Left _  -> pure ()
          Right _ -> expectationFailure "expected authorize to reject empty value"

  -- -----------------------------------------------------------------------
  -- DELETE
  -- -----------------------------------------------------------------------

  describe "SECRET_MANAGE action=delete" $ do

    it "deletes the secret when the human approves" $
      withSystemTempDirectory "seal-secret-delete-yes" $ \tmpDir -> do
        (rt, h) <- withVaultRuntime tmpDir (Just ("TOKEN", "s3cr3t"))
        (_fc, caps) <- makeFakeCaps ["once"]
        let op = secretManageOp rt Nothing caps
        r <- runTestApp (opRun op localBackend (object
          [ "action" .= ("delete" :: String)
          , "name"   .= ("TOKEN" :: String)
          ]))
        orIsError r `shouldBe` False
        result <- vhGet h "TOKEN"
        result `shouldSatisfy` isLeft

    it "does NOT delete the secret when the human denies" $
      withSystemTempDirectory "seal-secret-delete-no" $ \tmpDir -> do
        (rt, h) <- withVaultRuntime tmpDir (Just ("TOKEN", "s3cr3t"))
        (_fc, caps) <- makeFakeCaps ["rejected"]
        let op = secretManageOp rt Nothing caps
        r <- runTestApp (opRun op localBackend (object
          [ "action" .= ("delete" :: String)
          , "name"   .= ("TOKEN" :: String)
          ]))
        orIsError r `shouldBe` True
        result <- vhGet h "TOKEN"
        result `shouldBe` Right "s3cr3t"

    it "is a blocking opcode (toBlocking = True)" $
      withSystemTempDirectory "seal-secret-delete-blocking" $ \tmpDir -> do
        (rt, _) <- withVaultRuntime tmpDir Nothing
        (_fc, caps) <- makeFakeCaps ["once"]
        let op = secretManageOp rt Nothing caps
        opBlocking op `shouldBe` True

    it "does NOT delete when the human sends an empty response" $
      withSystemTempDirectory "seal-secret-delete-empty" $ \tmpDir -> do
        (rt, h) <- withVaultRuntime tmpDir (Just ("TOKEN", "s3cr3t"))
        (_fc, caps) <- makeFakeCaps [""]
        let op = secretManageOp rt Nothing caps
        r <- runTestApp (opRun op localBackend (object
          [ "action" .= ("delete" :: String)
          , "name"   .= ("TOKEN" :: String)
          ]))
        orIsError r `shouldBe` True
        result <- vhGet h "TOKEN"
        result `shouldBe` Right "s3cr3t"

  -- -----------------------------------------------------------------------
  -- LIST
  -- -----------------------------------------------------------------------

  describe "SECRET_MANAGE action=list" $ do

    it "lists all secret names without revealing values" $
      withSystemTempDirectory "seal-secret-list" $ \tmpDir -> do
        (rt, h) <- withVaultRuntime tmpDir (Just ("TOKEN", "s3cr3t"))
        _ <- vhPut h "API_KEY" "sk-xyz"
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt Nothing caps
        r <- runTestApp (opRun op localBackend (object
          [ "action" .= ("list" :: String)
          ]))
        orIsError r `shouldBe` False
        let text = case orParts r of [TrpText t] -> t; _ -> ""
        T.isInfixOf "TOKEN" text `shouldBe` True
        T.isInfixOf "API_KEY" text `shouldBe` True
        T.isInfixOf "s3cr3t" text `shouldBe` False
        T.isInfixOf "sk-xyz" text `shouldBe` False

  -- -----------------------------------------------------------------------
  -- Authorization
  -- -----------------------------------------------------------------------

  describe "SECRET_MANAGE authorize gate" $ do

    it "rejects unknown action" $
      withSystemTempDirectory "seal-auth" $ \tmpDir -> do
        (rt, _) <- withVaultRuntime tmpDir Nothing
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt Nothing caps
        case opAuthorize op (object ["action" .= ("bogus" :: String)]) of
          Left _  -> pure ()
          Right _ -> expectationFailure "expected authorize to reject unknown action"

    it "rejects get without name" $
      withSystemTempDirectory "seal-auth" $ \tmpDir -> do
        (rt, _) <- withVaultRuntime tmpDir Nothing
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt Nothing caps
        case opAuthorize op (object ["action" .= ("get" :: String)]) of
          Left _  -> pure ()
          Right _ -> expectationFailure "expected authorize to reject get without name"

    it "rejects put without value" $
      withSystemTempDirectory "seal-auth" $ \tmpDir -> do
        (rt, _) <- withVaultRuntime tmpDir Nothing
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt Nothing caps
        case opAuthorize op (object
          [ "action" .= ("put" :: String)
          , "name"   .= ("KEY" :: String)
          ]) of
          Left _  -> pure ()
          Right _ -> expectationFailure "expected authorize to reject put without value"

    it "rejects delete without name" $
      withSystemTempDirectory "seal-auth" $ \tmpDir -> do
        (rt, _) <- withVaultRuntime tmpDir Nothing
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt Nothing caps
        case opAuthorize op (object ["action" .= ("delete" :: String)]) of
          Left _  -> pure ()
          Right _ -> expectationFailure "expected authorize to reject delete without name"

    it "accepts list with no extra fields" $
      withSystemTempDirectory "seal-auth" $ \tmpDir -> do
        (rt, _) <- withVaultRuntime tmpDir Nothing
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt Nothing caps
        case opAuthorize op (object ["action" .= ("list" :: String)]) of
          Left e  -> expectationFailure ("expected authorize to accept list: " <> T.unpack e)
          Right _ -> pure ()

  -- -----------------------------------------------------------------------
  -- Allow-list enforcement
  -- -----------------------------------------------------------------------

  describe "allow-list enforcement" $ do

    -- ---------------------------------------------------------------------
    -- GET with allow-list
    -- ---------------------------------------------------------------------

    it "get with allowed key succeeds" $
      withSystemTempDirectory "seal-allow-get-ok" $ \tmpDir -> do
        (rt, _) <- withVaultRuntime tmpDir (Just ("TOKEN", "s3cr3t"))
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt (Just (Set.fromList ["TOKEN"])) caps
        r <- runTestApp (opRun op localBackend (object
          [ "action" .= ("get" :: String)
          , "name"   .= ("TOKEN" :: String)
          ]))
        orIsError r `shouldBe` False
        orParts r `shouldBe` [TrpText "s3cr3t"]

    it "get with disallowed key fails at authorize gate" $
      withSystemTempDirectory "seal-allow-get-deny" $ \tmpDir -> do
        (rt, _) <- withVaultRuntime tmpDir (Just ("TOKEN", "s3cr3t"))
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt (Just (Set.fromList ["OTHER"])) caps
        case opAuthorize op (object
          [ "action" .= ("get" :: String)
          , "name"   .= ("TOKEN" :: String)
          ]) of
          Left e  -> e `shouldBe` "secret not available in this session"
          Right _ -> expectationFailure "expected authorize to reject disallowed get"

    -- ---------------------------------------------------------------------
    -- LIST with allow-list
    -- ---------------------------------------------------------------------

    it "list with allow-list filters to only allowed keys" $
      withSystemTempDirectory "seal-allow-list-filter" $ \tmpDir -> do
        (rt, h) <- withVaultRuntime tmpDir (Just ("TOKEN", "s3cr3t"))
        _ <- vhPut h "API_KEY" "sk-xyz"
        _ <- vhPut h "DB_PASSWORD" "hunter2"
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt (Just (Set.fromList ["TOKEN", "API_KEY"])) caps
        r <- runTestApp (opRun op localBackend (object
          [ "action" .= ("list" :: String)
          ]))
        orIsError r `shouldBe` False
        let text = case orParts r of [TrpText t] -> t; _ -> ""
        T.isInfixOf "TOKEN" text `shouldBe` True
        T.isInfixOf "API_KEY" text `shouldBe` True
        T.isInfixOf "DB_PASSWORD" text `shouldBe` False
        orRecorded r `shouldBe` object ["count" .= (2 :: Int)]

    it "list with Nothing allow-list shows all keys (backward compat)" $
      withSystemTempDirectory "seal-allow-list-none" $ \tmpDir -> do
        (rt, h) <- withVaultRuntime tmpDir (Just ("TOKEN", "s3cr3t"))
        _ <- vhPut h "API_KEY" "sk-xyz"
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt Nothing caps
        r <- runTestApp (opRun op localBackend (object
          [ "action" .= ("list" :: String)
          ]))
        orIsError r `shouldBe` False
        let text = case orParts r of [TrpText t] -> t; _ -> ""
        T.isInfixOf "TOKEN" text `shouldBe` True
        T.isInfixOf "API_KEY" text `shouldBe` True
        orRecorded r `shouldBe` object ["count" .= (2 :: Int)]

    it "list with allow-list where all keys filtered out shows No secrets" $
      withSystemTempDirectory "seal-allow-list-empty" $ \tmpDir -> do
        (rt, h) <- withVaultRuntime tmpDir (Just ("TOKEN", "s3cr3t"))
        _ <- vhPut h "API_KEY" "sk-xyz"
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt (Just (Set.fromList ["NONEXISTENT"])) caps
        r <- runTestApp (opRun op localBackend (object
          [ "action" .= ("list" :: String)
          ]))
        orIsError r `shouldBe` False
        orParts r `shouldBe` [TrpText "No secrets."]
        orRecorded r `shouldBe` object ["count" .= (0 :: Int)]

    -- ---------------------------------------------------------------------
    -- PUT with allow-list
    -- ---------------------------------------------------------------------

    it "put with disallowed key fails at authorize gate" $
      withSystemTempDirectory "seal-allow-put-deny" $ \tmpDir -> do
        (rt, _) <- withVaultRuntime tmpDir Nothing
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt (Just (Set.fromList ["OTHER"])) caps
        case opAuthorize op (object
          [ "action" .= ("put" :: String)
          , "name"   .= ("TOKEN" :: String)
          , "value"  .= ("val" :: String)
          ]) of
          Left e  -> e `shouldBe` "secret not available in this session"
          Right _ -> expectationFailure "expected authorize to reject disallowed put"

    it "put with allowed key succeeds" $
      withSystemTempDirectory "seal-allow-put-ok" $ \tmpDir -> do
        (rt, h) <- withVaultRuntime tmpDir Nothing
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt (Just (Set.fromList ["API_KEY"])) caps
        r <- runTestApp (opRun op localBackend (object
          [ "action" .= ("put" :: String)
          , "name"   .= ("API_KEY" :: String)
          , "value"  .= ("sk-abc" :: String)
          ]))
        orIsError r `shouldBe` False
        stored <- vhGet h "API_KEY"
        stored `shouldBe` Right "sk-abc"

    -- ---------------------------------------------------------------------
    -- DELETE with allow-list (before prompt)
    -- ---------------------------------------------------------------------

    it "delete with disallowed key fails at authorize gate BEFORE prompting" $
      withSystemTempDirectory "seal-allow-delete-deny" $ \tmpDir -> do
        (rt, _) <- withVaultRuntime tmpDir (Just ("TOKEN", "s3cr3t"))
        -- The fake caps queue is empty — if the prompt is triggered,
        -- ccPrompt will return "" (denial). But we're testing the
        -- authorize gate, which runs before toRun/prompt.
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt (Just (Set.fromList ["OTHER"])) caps
        case opAuthorize op (object
          [ "action" .= ("delete" :: String)
          , "name"   .= ("TOKEN" :: String)
          ]) of
          Left e  -> e `shouldBe` "secret not available in this session"
          Right _ -> expectationFailure "expected authorize to reject disallowed delete"

    it "delete with allowed key proceeds to prompt (human denies)" $
      withSystemTempDirectory "seal-allow-delete-prompt" $ \tmpDir -> do
        (rt, h) <- withVaultRuntime tmpDir (Just ("TOKEN", "s3cr3t"))
        (_fc, caps) <- makeFakeCaps ["rejected"]
        let op = secretManageOp rt (Just (Set.fromList ["TOKEN"])) caps
        -- authorize should pass (key is allowed)
        case opAuthorize op (object
          [ "action" .= ("delete" :: String)
          , "name"   .= ("TOKEN" :: String)
          ]) of
          Left e  -> expectationFailure ("expected authorize to accept allowed delete: " <> T.unpack e)
          Right _ -> do
            -- toRun proceeds to prompt, human denies
            r <- runTestApp (opRun op localBackend (object
              [ "action" .= ("delete" :: String)
              , "name"   .= ("TOKEN" :: String)
              ]))
            orIsError r `shouldBe` True
            result <- vhGet h "TOKEN"
            result `shouldBe` Right "s3cr3t"

    -- ---------------------------------------------------------------------
    -- Nothing allow-list backward compat (all ops behave as before)
    -- ---------------------------------------------------------------------

    it "Nothing allow-list: get authorize accepts any key" $
      withSystemTempDirectory "seal-none-auth" $ \tmpDir -> do
        (rt, _) <- withVaultRuntime tmpDir Nothing
        (_fc, caps) <- makeFakeCaps []
        let op = secretManageOp rt Nothing caps
        case opAuthorize op (object
          [ "action" .= ("get" :: String)
          , "name"   .= ("ANYTHING" :: String)
          ]) of
          Left e  -> expectationFailure ("expected authorize to accept with Nothing: " <> T.unpack e)
          Right _ -> pure ()
