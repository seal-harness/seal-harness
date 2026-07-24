{-# LANGUAGE OverloadedStrings #-}
module Seal.Signal.ConfigSpec (spec) where

import Data.Set qualified as Set
import Data.Text qualified as T
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Seal.Core.AllowList (AllowList (..))
import Seal.Config.File
  ( RuntimeConfig (..), defaultRuntimeConfig, loadRuntimeConfig, saveRuntimeConfig )
import Seal.Signal.Config
  ( SignalConfig (..), defaultSignalChunkLimit
  , defaultSignalConfig, mkSignalAccount, resolveSignalConfig
  , signalAccountText )

spec :: Spec
spec = do
  describe "Seal.Signal.Config.mkSignalAccount" $ do
    it "accepts a phone number" $
      case mkSignalAccount "+15551234567" of
        Right a -> signalAccountText a `shouldBe` "+15551234567"
        Left e  -> expectationFailure ("unexpected Left: " <> T.unpack e)
    it "accepts a UUID" $
      case mkSignalAccount "uuid:abcd-1234" of
        Right a -> signalAccountText a `shouldBe` "uuid:abcd-1234"
        Left e  -> expectationFailure ("unexpected Left: " <> T.unpack e)
    it "rejects empty" $ mkSignalAccount "" `shouldSatisfy` isLeft
    it "rejects leading dash (option injection)" $
      mkSignalAccount "--version" `shouldSatisfy` isLeft
    it "rejects invalid chars (spaces)" $
      mkSignalAccount "bad account" `shouldSatisfy` isLeft
    prop "accepts [A-Za-z0-9+:-] non-empty, no leading dash" $
      forAll genGoodAccount $ \t ->
        fmap signalAccountText (mkSignalAccount t) === Right t

  describe "Seal.Signal.Config.defaultSignalConfig" $ do
    it "has account=Nothing, chunk limit=default, allow=AllowAll" $ do
      scAccount defaultSignalConfig `shouldBe` Nothing
      scTextChunkLimit defaultSignalConfig `shouldBe` Just defaultSignalChunkLimit
      scAllowFrom defaultSignalConfig `shouldBe` AllowAll

  describe "Seal.Signal.Config.resolveSignalConfig" $ do
    it "resolves a config-only account" $ do
      case resolveSignalConfig (Just defaultSignalConfig { scAccount = Just "+15551234567" }) Nothing of
        Right (acct, _lim, _allow) -> signalAccountText acct `shouldBe` "+15551234567"
        Left e -> expectationFailure ("unexpected Left: " <> T.unpack e)

    it "vault-supplied account overrides config" $ do
      case resolveSignalConfig (Just defaultSignalConfig { scAccount = Just "+1-config" }) (Just "+1-vault") of
        Right (acct, _, _) -> signalAccountText acct `shouldBe` "+1-vault"
        Left e -> expectationFailure ("unexpected Left: " <> T.unpack e)

    it "rejects when account is missing (no section, no vault)" $
      resolveSignalConfig Nothing Nothing `shouldSatisfy` isLeft

    it "rejects a malformed allow_from entry" $ do
      let section = Just defaultSignalConfig
                      { scAccount = Just "+1"
                      , scAllowFrom = AllowOnly (Set.fromList ["bad account"]) }
      resolveSignalConfig section Nothing `shouldSatisfy` isLeft

    it "AllowAll passes through" $ do
      case resolveSignalConfig (Just defaultSignalConfig { scAccount = Just "+1" }) Nothing of
        Right (_, _, allow) -> allow `shouldBe` AllowAll
        Left e -> expectationFailure ("unexpected Left: " <> T.unpack e)

  describe "[signal] TOML round-trip" $ do
    it "round-trips a section with all three fields" $
      withSystemTempDirectory "seal-signal-cfg" $ \dir -> do
        let path = dir </> "config.toml"
            cfg = defaultRuntimeConfig
                    { rcSignal = Just defaultSignalConfig
                        { scAccount = Just "+15551234567"
                        , scTextChunkLimit = Just 100
                        , scAllowFrom = AllowOnly (Set.fromList
                            [ "+15551234567"
                            , "uuid:abc"
                            ])
                        }
                    }
        saveRuntimeConfig path cfg
        result <- loadRuntimeConfig path
        case result of
          Left err -> expectationFailure ("load failed: " <> T.unpack err)
          Right loaded -> do
            rcSignal loaded `shouldBe` rcSignal cfg

    it "absent section decodes as Nothing" $
      withSystemTempDirectory "seal-signal-cfg" $ \dir -> do
        let path = dir </> "config.toml"
        saveRuntimeConfig path defaultRuntimeConfig
        result <- loadRuntimeConfig path
        case result of
          Right loaded -> rcSignal loaded `shouldBe` Nothing
          Left err -> expectationFailure ("load failed: " <> T.unpack err)

-- ---------------------------------------------------------------------------
-- Helpers / generators
-- ---------------------------------------------------------------------------

isLeft :: Either a b -> Bool
isLeft (Left _)  = True
isLeft (Right _) = False

genGoodAccount :: Gen T.Text
genGoodAccount =
  T.pack <$> listOf1 (elements (['A'..'Z'] <> ['a'..'z'] <> ['0'..'9'] <> "+-:_"))
            `suchThat` nonDashHead
  where
    nonDashHead s = case s of
      (c:_) -> c /= '-'
      []    -> False