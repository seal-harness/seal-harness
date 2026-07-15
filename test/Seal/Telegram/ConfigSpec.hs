{-# LANGUAGE OverloadedStrings #-}
module Seal.Telegram.ConfigSpec (spec) where

import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Seal.Core.AllowList (AllowList (..))
import Seal.Config.File
  ( FileConfig (..), defaultFileConfig, loadFileConfig, saveFileConfig )
import Seal.Telegram.Config
  ( TelegramConfig (..), defaultTelegramChunkLimit
  , defaultTelegramConfig, mkTelegramToken, resolveTelegramConfig
  , telegramTokenText )

spec :: Spec
spec = do
  describe "Seal.Telegram.Config.mkTelegramToken" $ do
    it "accepts a BotFather token" $
      case mkTelegramToken "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11" of
        Right a -> telegramTokenText a `shouldBe` "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11"
        Left e  -> expectationFailure ("unexpected Left: " <> T.unpack e)
    it "rejects empty" $ mkTelegramToken "" `shouldSatisfy` isLeft
    it "rejects leading dash (option injection)" $
      mkTelegramToken "--version" `shouldSatisfy` isLeft
    it "rejects invalid chars (spaces)" $
      mkTelegramToken "bad token" `shouldSatisfy` isLeft
    prop "accepts [A-Za-z0-9+:-_] non-empty, no leading dash" $
      forAll genGoodToken $ \t ->
        fmap telegramTokenText (mkTelegramToken t) === Right t

  describe "Seal.Telegram.Config.defaultTelegramConfig" $ do
    it "has token=Nothing, chunk limit=default, allow=AllowAll" $ do
      tcToken defaultTelegramConfig `shouldBe` Nothing
      tcTextChunkLimit defaultTelegramConfig `shouldBe` Just defaultTelegramChunkLimit
      tcAllowFrom defaultTelegramConfig `shouldBe` AllowAll

  describe "Seal.Telegram.Config.resolveTelegramConfig" $ do
    it "resolves a config-only token" $ do
      let section = Just defaultTelegramConfig
                      { tcToken = Just "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11" }
      case resolveTelegramConfig section Nothing of
        Right (tok, _lim, _allow) ->
          telegramTokenText tok `shouldBe` "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11"
        Left e -> expectationFailure ("unexpected Left: " <> T.unpack e)

    it "vault-supplied token overrides config" $ do
      let section = Just defaultTelegramConfig { tcToken = Just "111:config-token" }
      case resolveTelegramConfig section (Just "222:vault-token") of
        Right (tok, _, _) -> telegramTokenText tok `shouldBe` "222:vault-token"
        Left e -> expectationFailure ("unexpected Left: " <> T.unpack e)

    it "rejects when token is missing (no section, no vault)" $
      resolveTelegramConfig Nothing Nothing `shouldSatisfy` isLeft

    it "rejects a malformed allow_from entry" $ do
      let section = Just defaultTelegramConfig
                      { tcToken = Just "123456:ABC"
                      , tcAllowFrom = AllowOnly (Set.fromList ["bad user id"])
                      }
      resolveTelegramConfig section Nothing `shouldSatisfy` isLeft

    it "AllowAll passes through" $ do
      let section = Just defaultTelegramConfig { tcToken = Just "123456:ABC" }
      case resolveTelegramConfig section Nothing of
        Right (_, _, allow) -> allow `shouldBe` AllowAll
        Left e -> expectationFailure ("unexpected Left: " <> T.unpack e)

  describe "[telegram] TOML round-trip" $ do
    it "round-trips a section with all three fields" $
      withSystemTempDirectory "seal-telegram-cfg" $ \dir -> do
        let path = dir </> "config.toml"
            cfg = defaultFileConfig
                    { fcTelegram = Just defaultTelegramConfig
                        { tcToken = Just "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11"
                        , tcTextChunkLimit = Just 500
                        , tcAllowFrom = AllowOnly (Set.fromList
                            [ "123456789"
                            , "987654321"
                            ])
                        }
                    }
        saveFileConfig path cfg
        result <- loadFileConfig path
        case result of
          Left err -> expectationFailure ("load failed: " <> T.unpack err)
          Right loaded -> do
            fcTelegram loaded `shouldBe` fcTelegram cfg

    it "absent section decodes as Nothing" $
      withSystemTempDirectory "seal-telegram-cfg" $ \dir -> do
        let path = dir </> "config.toml"
        saveFileConfig path defaultFileConfig
        result <- loadFileConfig path
        case result of
          Right loaded -> fcTelegram loaded `shouldBe` Nothing
          Left err -> expectationFailure ("load failed: " <> T.unpack err)

-- ---------------------------------------------------------------------------
-- Helpers / generators
-- ---------------------------------------------------------------------------

isLeft :: Either a b -> Bool
isLeft (Left _)  = True
isLeft (Right _) = False

genGoodToken :: Gen Text
genGoodToken =
  T.pack <$> listOf1 (elements (['A'..'Z'] <> ['a'..'z'] <> ['0'..'9'] <> "+-:_"))
            `suchThat` nonDashHead
  where
    nonDashHead s = case s of
      (c:_) -> c /= '-'
      []    -> False