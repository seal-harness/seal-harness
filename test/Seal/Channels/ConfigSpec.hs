{-# LANGUAGE OverloadedStrings #-}
{-# HLINT ignore "Use record patterns" #-}
module Seal.Channels.ConfigSpec (spec) where

import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck hiding (Failure, Success)

import Toml qualified
import Validation (Validation (..))

import Seal.Core.AllowList (AllowList (..))
import Seal.Core.ChannelKind (ChannelKind (..))
import Seal.Signal.Config (SignalConfig (..), defaultSignalConfig)
import Seal.Telegram.Config (TelegramConfig (..), defaultTelegramConfig)
import Seal.Channels.Config

spec :: Spec
spec = do
  describe "Seal.Channels.Config.mkChannelId" $ do
    it "accepts a valid id" $
      mkChannelId "work-signal" `shouldBe` Right (ChannelId "work-signal")

    it "accepts underscores, hyphens, alphanumerics" $
      mkChannelId "prod_bot-1" `shouldBe` Right (ChannelId "prod_bot-1")

    it "rejects empty" $
      mkChannelId "" `shouldSatisfy` isLeft

    it "rejects leading dash (option injection)" $
      mkChannelId "-bad" `shouldSatisfy` isLeft

    it "rejects spaces" $
      mkChannelId "bad id" `shouldSatisfy` isLeft

    it "rejects special chars (slash)" $
      mkChannelId "bad/id" `shouldSatisfy` isLeft

    it "rejects special chars (dot)" $
      mkChannelId "bad.id" `shouldSatisfy` isLeft

    prop "round-trips: mkChannelId (channelIdText cid) === Right cid" $
      forAll genGoodChannelId $ \t ->
        fmap channelIdText (mkChannelId t) === Right t

  describe "Seal.Channels.Config.telegramVaultKeyFor" $ do
    it "legacy id maps to unsuffixed key" $
      telegramVaultKeyFor (ChannelId "telegram") `shouldBe` "TELEGRAM_BOT_TOKEN"

    it "other ids use suffixed key" $
      telegramVaultKeyFor (ChannelId "dev-bot") `shouldBe` "TELEGRAM_BOT_TOKEN_dev-bot"

    it "id with underscores uses suffixed key" $
      telegramVaultKeyFor (ChannelId "prod_bot") `shouldBe` "TELEGRAM_BOT_TOKEN_prod_bot"

  describe "Seal.Channels.Config.channelConfigCodec" $ do
    it "round-trips a Signal channel" $ do
      let cfg = ChannelConfig
            { ccKind = Signal
            , ccLabel = Just "Work Signal"
            , ccAccount = Just "+15555550123"
            , ccToken = Nothing
            , ccTextChunkLimit = Just 1998
            , ccAllowFrom = AllowAll
            }
      roundTripCodec cfg `shouldBe` Success cfg

    it "round-trips a Telegram channel with token" $ do
      let cfg = ChannelConfig
            { ccKind = Telegram
            , ccLabel = Just "Dev Bot"
            , ccAccount = Nothing
            , ccToken = Just "123456:ABCdef"
            , ccTextChunkLimit = Just 3900
            , ccAllowFrom = AllowAll
            }
      roundTripCodec cfg `shouldBe` Success cfg

    it "round-trips with AllowOnly allow_from" $ do
      let cfg = ChannelConfig
            { ccKind = Signal
            , ccLabel = Nothing
            , ccAccount = Just "+1555"
            , ccToken = Nothing
            , ccTextChunkLimit = Nothing
            , ccAllowFrom = AllowOnly (Set.fromList ["+1555", "uuid:abc"])
            }
      roundTripCodec cfg `shouldBe` Success cfg

    it "round-trips with absent label (Nothing)" $ do
      let cfg = ChannelConfig
            { ccKind = Signal
            , ccLabel = Nothing
            , ccAccount = Just "+1555"
            , ccToken = Nothing
            , ccTextChunkLimit = Nothing
            , ccAllowFrom = AllowAll
            }
      roundTripCodec cfg `shouldBe` Success cfg

    it "round-trips with absent token (Nothing)" $ do
      let cfg = ChannelConfig
            { ccKind = Telegram
            , ccLabel = Nothing
            , ccAccount = Nothing
            , ccToken = Nothing
            , ccTextChunkLimit = Nothing
            , ccAllowFrom = AllowAll
            }
      roundTripCodec cfg `shouldBe` Success cfg

    it "rejects kind=cli" $
      decodeChannelConfig "kind = \"cli\"" `shouldSatisfy` isFailure

    it "rejects kind=web" $
      decodeChannelConfig "kind = \"web\"" `shouldSatisfy` isFailure

    it "rejects kind=background" $
      decodeChannelConfig "kind = \"background\"" `shouldSatisfy` isFailure

    it "rejects kind=other" $
      decodeChannelConfig "kind = \"other\"" `shouldSatisfy` isFailure

    it "rejects unknown kind" $
      decodeChannelConfig "kind = \"slack\"" `shouldSatisfy` isFailure

    it "rejects missing kind" $
      decodeChannelConfig "label = \"no kind\"" `shouldSatisfy` isFailure

  describe "Seal.Channels.Config.resolveChannelConfig" $ do
    let sigCfg = ChannelConfig
          { ccKind = Signal
          , ccLabel = Nothing
          , ccAccount = Just "+15551234567"
          , ccToken = Nothing
          , ccTextChunkLimit = Nothing
          , ccAllowFrom = AllowAll
          }
        sigCfgNoAccount = sigCfg { ccAccount = Nothing }
        tgCfg = ChannelConfig
          { ccKind = Telegram
          , ccLabel = Nothing
          , ccAccount = Nothing
          , ccToken = Just "config-tok"
          , ccTextChunkLimit = Nothing
          , ccAllowFrom = AllowAll
          }
        tgCfgNoToken = tgCfg { ccToken = Nothing }
        cid = ChannelId "test"

    it "Signal: resolves with account + defaults" $
      case resolveChannelConfig cid sigCfg Nothing of
        Right (ResolvedSignal acct _ _) ->
          show acct `shouldContain` "15551234567"
        Right (ResolvedTelegram _ _ _) ->
          expectationFailure "expected ResolvedSignal, got ResolvedTelegram"
        Left e -> expectationFailure ("unexpected Left: " <> T.unpack e)

    it "Signal: fails without account" $
      resolveChannelConfig cid sigCfgNoAccount Nothing `shouldSatisfy` isLeft

    it "Telegram: vault token takes precedence over ccToken" $
      case resolveChannelConfig cid tgCfg (Just "vault-tok") of
        Right (ResolvedTelegram token _ _) ->
          show token `shouldContain` "vault-tok"
        Right (ResolvedSignal _ _ _) ->
          expectationFailure "expected ResolvedTelegram, got ResolvedSignal"
        Left e -> expectationFailure ("unexpected Left: " <> T.unpack e)

    it "Telegram: falls back to ccToken when vault absent" $
      case resolveChannelConfig cid tgCfg Nothing of
        Right (ResolvedTelegram token _ _) ->
          show token `shouldContain` "config-tok"
        Right (ResolvedSignal _ _ _) ->
          expectationFailure "expected ResolvedTelegram, got ResolvedSignal"
        Left e -> expectationFailure ("unexpected Left: " <> T.unpack e)

    it "Telegram: fails when neither vault nor ccToken" $
      resolveChannelConfig cid tgCfgNoToken Nothing `shouldSatisfy` isLeft

    it "rejects unsupported kind (Cli)" $
      let badCfg = sigCfg { ccKind = Cli }
      in resolveChannelConfig cid badCfg Nothing `shouldSatisfy` isLeft

  describe "Seal.Channels.Config.fromSignalConfig" $ do
    it "maps account, chunk limit, and allow_from" $ do
      let sc = defaultSignalConfig
            { scAccount = Just "+1555"
            , scTextChunkLimit = Just 500
            , scAllowFrom = AllowOnly (Set.fromList ["+1555"])
            }
          cc = fromSignalConfig sc
      ccKind cc `shouldBe` Signal
      ccAccount cc `shouldBe` Just "+1555"
      ccToken cc `shouldBe` Nothing
      ccTextChunkLimit cc `shouldBe` Just 500
      ccAllowFrom cc `shouldBe` AllowOnly (Set.fromList ["+1555"])

  describe "Seal.Channels.Config.fromTelegramConfig" $ do
    it "maps token, chunk limit, and allow_from (preserves tcToken)" $ do
      let tc = defaultTelegramConfig
            { tcToken = Just "tok"
            , tcTextChunkLimit = Just 400
            , tcAllowFrom = AllowOnly (Set.fromList ["123"])
            }
          cc = fromTelegramConfig tc
      ccKind cc `shouldBe` Telegram
      ccToken cc `shouldBe` Just "tok"
      ccAccount cc `shouldBe` Nothing
      ccTextChunkLimit cc `shouldBe` Just 400
      ccAllowFrom cc `shouldBe` AllowOnly (Set.fromList ["123"])

    it "ccToken is Nothing when tcToken is Nothing" $ do
      let cc = fromTelegramConfig defaultTelegramConfig
      ccToken cc `shouldBe` Nothing

-- ---------------------------------------------------------------------------
-- Helpers / generators
-- ---------------------------------------------------------------------------

isLeft :: Either a b -> Bool
isLeft (Left _)  = True
isLeft (Right _) = False

isFailure :: Validation e a -> Bool
isFailure (Failure _) = True
isFailure (Success _) = False

-- | Round-trip a ChannelConfig through encode → parse → decode.
roundTripCodec :: ChannelConfig -> Validation [Toml.TomlDecodeError] ChannelConfig
roundTripCodec cfg =
  let encoded = Toml.encode channelConfigCodec cfg
  in case Toml.parse encoded of
       Left err   -> Failure [Toml.ParseError err]
       Right toml -> Toml.runTomlCodec channelConfigCodec toml

-- | Decode a raw TOML text as a ChannelConfig.
decodeChannelConfig :: Text -> Validation [Toml.TomlDecodeError] ChannelConfig
decodeChannelConfig txt =
  case Toml.parse txt of
    Left err   -> Failure [Toml.ParseError err]
    Right toml -> Toml.runTomlCodec channelConfigCodec toml

genGoodChannelId :: Gen Text
genGoodChannelId =
  T.pack <$> listOf1 (elements (['A'..'Z'] <> ['a'..'z'] <> ['0'..'9'] <> "_-"))
            `suchThat` nonDashHead
  where
    nonDashHead s = case s of
      (c:_) -> c /= '-'
      []    -> False
