{-# LANGUAGE OverloadedStrings #-}
module Seal.Security.VaultSpec (spec) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.MVar (MVar)
import Data.Bits (xor)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft, isRight)
import Data.List (sort)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import System.Directory (doesFileExist, findExecutable)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process.Typed (proc, readProcess)
import Test.Hspec

import Seal.Security.Vault
import Seal.Security.Vault.Age

-- | Build a mock encryptor using XOR with the given mask.
mockXor :: Word8 -> VaultEncryptor
mockXor mask = VaultEncryptor
  { veEncrypt = pure . Right . BS.map (`xor` mask)
  , veDecrypt = pure . Right . BS.map (`xor` mask)
  }

-- | Open a vault in a temp directory using the mock encryptor, init, unlock.
withVault :: UnlockMode -> (VaultHandle -> IO a) -> IO a
withVault mode k =
  withSystemTempDirectory "seal-vault" $ \dir -> do
    let cfg = VaultConfig (dir </> "vault.age") "mock" mode
    h <- openVault cfg mkMockEncryptor
    _ <- vhInit h
    _ <- vhUnlock h
    k h

spec :: Spec
spec = describe "Seal.Security.Vault" $ do

  -- Baseline tests (from brief, verbatim)

  it "put then get round-trips a secret" $ withVault UnlockStartup $ \h -> do
    _ <- vhPut h "ANTHROPIC_API_KEY" "sk-123"
    vhGet h "ANTHROPIC_API_KEY" `shouldReturn` Right "sk-123"

  it "lists key names but not values" $ withVault UnlockStartup $ \h -> do
    _ <- vhPut h "a" "1"
    _ <- vhPut h "b" "2"
    fmap (fmap sort) (vhList h) `shouldReturn` Right ["a", "b"]

  it "delete removes a key" $ withVault UnlockStartup $ \h -> do
    _ <- vhPut h "k" "v"
    _ <- vhDelete h "k"
    vhGet h "k" `shouldReturn` Left (VaultKeyNotFound "k")

  it "init twice reports VaultAlreadyExists" $ withVault UnlockStartup $ \h ->
    vhInit h `shouldReturn` Left VaultAlreadyExists

  it "reports locked status before unlock" $
    withSystemTempDirectory "seal-vault" $ \dir -> do
      let cfg = VaultConfig (dir </> "v.age") "mock" UnlockStartup
      h <- openVault cfg mkMockEncryptor
      _ <- vhInit h
      st <- vhStatus h
      vsLocked st `shouldBe` True

  it "get on a locked startup vault returns VaultLocked" $
    withSystemTempDirectory "seal-vault" $ \dir -> do
      let cfg = VaultConfig (dir </> "v.age") "mock" UnlockStartup
      h <- openVault cfg mkMockEncryptor
      _ <- vhInit h
      vhGet h "anything" `shouldReturn` Left VaultLocked

  it "per-access mode reads without an explicit unlock" $
    withSystemTempDirectory "seal-vault" $ \dir -> do
      let cfg = VaultConfig (dir </> "v.age") "mock" UnlockPerAccess
      h <- openVault cfg mkMockEncryptor
      _ <- vhInit h
      _ <- vhPut h "k" "v"
      vhGet h "k" `shouldReturn` Right "v"

  it "rekey re-encrypts and verifies before replacing" $ withVault UnlockStartup $ \h -> do
    _ <- vhPut h "k" "v"
    res <- vhRekey h mkMockEncryptor "mock2" (const (pure True))
    res `shouldBe` Right ()
    vhGet h "k" `shouldReturn` Right "v"

  -- Enrichment tests

  it "init creates the vault file on disk" $
    withSystemTempDirectory "seal-vault" $ \dir -> do
      let path = dir </> "vault.age"
          cfg = VaultConfig path "mock" UnlockStartup
      h <- openVault cfg mkMockEncryptor
      _ <- vhInit h
      exists <- doesFileExist path
      exists `shouldBe` True
      contents <- BS.readFile path
      BS.length contents `shouldSatisfy` (> 0)

  it "get on a missing key returns VaultKeyNotFound" $ withVault UnlockStartup $ \h -> do
    result <- vhGet h "nonexistent"
    result `shouldBe` Left (VaultKeyNotFound "nonexistent")

  it "list returns empty list on a fresh vault" $ withVault UnlockStartup $ \h -> do
    result <- vhList h
    result `shouldBe` Right []

  it "delete on a missing key returns VaultKeyNotFound" $ withVault UnlockStartup $ \h -> do
    result <- vhDelete h "missing"
    result `shouldBe` Left (VaultKeyNotFound "missing")

  it "lock then unlock cycle preserves data" $ withVault UnlockStartup $ \h -> do
    _ <- vhPut h "secret" "secretvalue"
    vhLock h
    _ <- vhUnlock h
    vhGet h "secret" `shouldReturn` Right "secretvalue"

  it "UnlockOnDemand: get auto-unlocks after explicit lock" $
    withSystemTempDirectory "seal-vault" $ \dir -> do
      let cfg = VaultConfig (dir </> "vault.age") "mock" UnlockOnDemand
      h <- openVault cfg mkMockEncryptor
      _ <- vhInit h
      _ <- vhUnlock h
      _ <- vhPut h "k" "v"
      vhLock h
      vhGet h "k" `shouldReturn` Right "v"

  it "UnlockPerAccess: list works without explicit unlock" $
    withSystemTempDirectory "seal-vault" $ \dir -> do
      let cfg = VaultConfig (dir </> "vault.age") "mock" UnlockPerAccess
      h <- openVault cfg mkMockEncryptor
      _ <- vhInit h
      _ <- vhPut h "pa" "1"
      _ <- vhPut h "pb" "2"
      result <- vhList h
      fmap sort result `shouldBe` Right ["pa", "pb"]

  it "status: vsLocked is False after unlock" $
    withSystemTempDirectory "seal-vault" $ \dir -> do
      let cfg = VaultConfig (dir </> "v.age") "mock" UnlockStartup
      h <- openVault cfg mkMockEncryptor
      _ <- vhInit h
      _ <- vhUnlock h
      st <- vhStatus h
      vsLocked st `shouldBe` False

  it "status: vsSecretCount equals number of puts" $ withVault UnlockStartup $ \h -> do
    _ <- vhPut h "a" "1"
    _ <- vhPut h "b" "2"
    st <- vhStatus h
    vsSecretCount st `shouldBe` 2

  it "status: vsKeyType reflects configured key type" $
    withSystemTempDirectory "seal-vault" $ \dir -> do
      let cfg = VaultConfig (dir </> "v.age") "x25519" UnlockStartup
      h <- openVault cfg mkMockEncryptor
      _ <- vhInit h
      st <- vhStatus h
      vsKeyType st `shouldBe` "x25519"

  it "concurrent puts both persist under MVar lock" $ withVault UnlockStartup $ \h -> do
    done1 <- newEmptyMVar :: IO (MVar ())
    done2 <- newEmptyMVar :: IO (MVar ())
    _ <- forkIO $ do
      _ <- vhPut h "concurrent1" "val1"
      putMVar done1 ()
    _ <- forkIO $ do
      _ <- vhPut h "concurrent2" "val2"
      putMVar done2 ()
    takeMVar done1
    takeMVar done2
    r1 <- vhGet h "concurrent1"
    r2 <- vhGet h "concurrent2"
    r1 `shouldSatisfy` isRight
    r2 `shouldSatisfy` isRight

  it "vhUnlock returns VaultNotFound when file does not exist" $
    withSystemTempDirectory "seal-vault" $ \dir -> do
      let cfg = VaultConfig (dir </> "nonexistent.vault") "mock" UnlockStartup
      h <- openVault cfg mkMockEncryptor
      result <- vhUnlock h
      result `shouldBe` Left VaultNotFound

  describe "rekey" $ do
    it "preserves all secrets when rekeying to a different encryptor" $ withVault UnlockStartup $ \h -> do
      _ <- vhPut h "secret1" "value1"
      _ <- vhPut h "secret2" "value2"
      _ <- vhPut h "secret3" "value3"
      let newEnc = mockXor 0xCD
      result <- vhRekey h newEnc "alt-mock" (const (pure True))
      result `shouldBe` Right ()
      vhGet h "secret1" `shouldReturn` Right "value1"
      vhGet h "secret2" `shouldReturn` Right "value2"
      vhGet h "secret3" `shouldReturn` Right "value3"

    it "updates vsKeyType in status after rekey" $ withVault UnlockStartup $ \h -> do
      _ <- vhPut h "k" "v"
      let newEnc = mockXor 0xCD
      _ <- vhRekey h newEnc "new-key-type" (const (pure True))
      st <- vhStatus h
      vsKeyType st `shouldBe` "new-key-type"

    it "verification failure when decrypt returns invalid JSON" $ withVault UnlockStartup $ \h -> do
      _ <- vhPut h "k" "v"
      let badEnc = VaultEncryptor
            { veEncrypt = pure . Right . BS.map (`xor` 0xCD)
            , veDecrypt = \_ -> pure (Right "not valid json")
            }
      result <- vhRekey h badEnc "bad" (const (pure True))
      result `shouldSatisfy` isLeft
      case result of
        Left (VaultBackendError _) -> pure ()
        other -> expectationFailure $ "Expected VaultBackendError, got: " ++ show other

    it "cancelled rekey leaves vault intact with original key type" $ withVault UnlockStartup $ \h -> do
      _ <- vhPut h "mykey" "myval"
      let newEnc = mockXor 0xCD
      result <- vhRekey h newEnc "new-type" (const (pure False))
      result `shouldSatisfy` isLeft
      case result of
        Left (VaultBackendError _) -> pure ()
        other -> expectationFailure $ "Expected VaultBackendError, got: " ++ show other
      vhGet h "mykey" `shouldReturn` Right "myval"
      st <- vhStatus h
      vsKeyType st `shouldBe` "mock"

  describe "real-age integration" $ do
    it "round-trips put/get/list with the real age binary" $ do
      ageExe <- findExecutable "age"
      agekeygenExe <- findExecutable "age-keygen"
      case (ageExe, agekeygenExe) of
        (Nothing, _) -> pendingWith "age not installed"
        (_, Nothing) -> pendingWith "age-keygen not installed"
        _ -> withSystemTempDirectory "seal-vault-age" $ \dir -> do
          (_, identityBs, stderrBs) <- readProcess (proc "age-keygen" [])
          let identityContent = BL.toStrict identityBs
              stderrText = TE.decodeUtf8Lenient (BL.toStrict stderrBs)
              pubKeyLines = filter (T.isPrefixOf "Public key: ") (T.lines stderrText)
          case pubKeyLines of
            [] -> pendingWith "age-keygen output format not recognised"
            (line:_) -> do
              let pubKey = T.drop (T.length "Public key: ") line
                  identityPath = dir </> "identity.age"
              BS.writeFile identityPath identityContent
              encResult <- mkAgeEncryptor (AgeRecipient pubKey) (AgeIdentity (T.pack identityPath))
              case encResult of
                Left e -> expectationFailure $ "mkAgeEncryptor failed: " ++ show e
                Right enc -> do
                  let cfg = VaultConfig (dir </> "vault.age") "age-x25519" UnlockStartup
                  h <- openVault cfg enc
                  _ <- vhInit h
                  _ <- vhUnlock h
                  _ <- vhPut h "api-key" "s3cr3t"
                  vhGet h "api-key" `shouldReturn` Right "s3cr3t"
                  keys <- vhList h
                  keys `shouldBe` Right ["api-key"]
