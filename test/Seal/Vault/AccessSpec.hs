{-# LANGUAGE OverloadedStrings #-}
module Seal.Vault.AccessSpec (spec) where

import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Seal.Security.Vault.Age (VaultError (..))
import Seal.TestHelpers.FakeVault (makeFakeVaultRuntime)
import Seal.TestHelpers.Arbitrary ()  -- Arbitrary Text
import Seal.Vault.Access

spec :: Spec
spec = describe "Seal.Vault.Access" $ do

  -- -----------------------------------------------------------------------
  -- Smart constructors
  -- -----------------------------------------------------------------------

  describe "noVaultAccess" $ do
    it "creates a VaultAccess with an empty allow-list" $ do
      rt <- makeFakeVaultRuntime [("TOKEN", "s3cr3t")]
      vaAllowedSet (noVaultAccess rt) `shouldBe` Set.empty

    it "vaGet with noVaultAccess denies any key" $ do
      rt <- makeFakeVaultRuntime [("TOKEN", "s3cr3t")]
      r <- vaGet (noVaultAccess rt) "TOKEN"
      r `shouldBe` Left (VaultAccessDenied "TOKEN")

    it "vaList with noVaultAccess returns empty list without touching vault" $ do
      rt <- makeFakeVaultRuntime [("TOKEN", "s3cr3t")]
      r <- vaList (noVaultAccess rt)
      r `shouldBe` Right []

  describe "vaultAccess" $ do
    it "creates a VaultAccess with the given allow-list" $ do
      rt <- makeFakeVaultRuntime [("A", "1"), ("B", "2")]
      vaAllowedSet (vaultAccess rt (Set.fromList ["A", "B"])) `shouldBe` Set.fromList ["A", "B"]

  -- -----------------------------------------------------------------------
  -- vaGet
  -- -----------------------------------------------------------------------

  describe "vaGet" $ do
    it "returns the secret value for an allowed key" $ do
      rt <- makeFakeVaultRuntime [("TOKEN", "s3cr3t")]
      r <- vaGet (vaultAccess rt (Set.fromList ["TOKEN"])) "TOKEN"
      r `shouldBe` Right "s3cr3t"

    it "returns VaultAccessDenied for a disallowed key" $ do
      rt <- makeFakeVaultRuntime [("TOKEN", "s3cr3t")]
      r <- vaGet (vaultAccess rt (Set.fromList ["OTHER"])) "TOKEN"
      r `shouldBe` Left (VaultAccessDenied "TOKEN")

    it "returns VaultAccessDenied for an allowed-but-missing key (vault returns VaultKeyNotFound)" $ do
      rt <- makeFakeVaultRuntime []
      r <- vaGet (vaultAccess rt (Set.fromList ["MISSING"])) "MISSING"
      r `shouldBe` Left (VaultKeyNotFound "MISSING")

    prop "allowed key is never VaultAccessDenied" $ \(keys :: [Text]) (val :: Text) ->
      not (null keys) ==>
      forAll (elements keys) $ \key ->
      ioProperty $ do
        rt <- makeFakeVaultRuntime [(key, TE.encodeUtf8 val)]
        r <- vaGet (vaultAccess rt (Set.fromList keys)) key
        pure (r /= Left (VaultAccessDenied key))

    prop "disallowed key is always VaultAccessDenied" $ \(allowedKeys :: [Text]) (key :: Text) ->
      notElem key allowedKeys ==>
      ioProperty $ do
        rt <- makeFakeVaultRuntime [(key, "val")]
        r <- vaGet (vaultAccess rt (Set.fromList allowedKeys)) key
        pure (r === Left (VaultAccessDenied key))

  -- -----------------------------------------------------------------------
  -- vaPut
  -- -----------------------------------------------------------------------

  describe "vaPut" $ do
    it "stores a secret for an allowed key" $ do
      rt <- makeFakeVaultRuntime []
      let va = vaultAccess rt (Set.fromList ["NEW"])
      r <- vaPut va "NEW" "value"
      r `shouldBe` Right ()

    it "returns VaultAccessDenied for a disallowed key" $ do
      rt <- makeFakeVaultRuntime []
      r <- vaPut (vaultAccess rt (Set.fromList ["OTHER"])) "NEW" "value"
      r `shouldBe` Left (VaultAccessDenied "NEW")

  -- -----------------------------------------------------------------------
  -- vaDelete
  -- -----------------------------------------------------------------------

  describe "vaDelete" $ do
    it "deletes a secret for an allowed key" $ do
      rt <- makeFakeVaultRuntime [("TOKEN", "s3cr3t")]
      r <- vaDelete (vaultAccess rt (Set.fromList ["TOKEN"])) "TOKEN"
      r `shouldBe` Right ()

    it "returns VaultAccessDenied for a disallowed key" $ do
      rt <- makeFakeVaultRuntime [("TOKEN", "s3cr3t")]
      r <- vaDelete (vaultAccess rt (Set.fromList ["OTHER"])) "TOKEN"
      r `shouldBe` Left (VaultAccessDenied "TOKEN")

  -- -----------------------------------------------------------------------
  -- vaList
  -- -----------------------------------------------------------------------

  describe "vaList" $ do
    it "returns only allowed keys from the vault" $ do
      rt <- makeFakeVaultRuntime [("A", "1"), ("B", "2"), ("C", "3")]
      r <- vaList (vaultAccess rt (Set.fromList ["A", "C"]))
      r `shouldBe` Right ["A", "C"]

    it "returns all keys when all are allowed" $ do
      rt <- makeFakeVaultRuntime [("A", "1"), ("B", "2")]
      r <- vaList (vaultAccess rt (Set.fromList ["A", "B"]))
      r `shouldSatisfy` \case
        Right ks -> Set.fromList ks == Set.fromList ["A", "B"]
        Left _  -> False

    it "short-circuits to Right [] for empty allow-list without touching vault" $ do
      rt <- makeFakeVaultRuntime [("SECRET", "val")]
      r <- vaList (noVaultAccess rt)
      r `shouldBe` Right []

    prop "filtered keys are subset of allowed set" $ \(vaultKeys :: [Text]) (allowedKeys :: [Text]) ->
      not (null vaultKeys) && not (null allowedKeys) ==>
      ioProperty $ do
        let vaultData = [(k, TE.encodeUtf8 k) | k <- vaultKeys]
        rt <- makeFakeVaultRuntime vaultData
        r <- vaList (vaultAccess rt (Set.fromList allowedKeys))
        case r of
          Right ks -> pure (Set.fromList ks `Set.isSubsetOf` Set.fromList allowedKeys)
          Left _   -> pure False

  -- -----------------------------------------------------------------------
  -- unrestrictedVaultAccess
  -- -----------------------------------------------------------------------

  describe "unrestrictedVaultAccess" $ do
    it "creates a VaultAccess with all vault keys" $ do
      rt <- makeFakeVaultRuntime [("A", "1"), ("B", "2"), ("C", "3")]
      va <- unrestrictedVaultAccess rt
      vaAllowedSet va `shouldBe` Set.fromList ["A", "B", "C"]

    it "allows getting any key" $ do
      rt <- makeFakeVaultRuntime [("TOKEN", "s3cr3t")]
      va <- unrestrictedVaultAccess rt
      r <- vaGet va "TOKEN"
      r `shouldBe` Right "s3cr3t"
