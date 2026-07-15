{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.ChannelSpec (spec) where

import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure)
import System.Directory qualified
import System.FilePath qualified
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Command.Channel
  ( AccountsOutcome (..), ChannelRuntime (..), GetMeOutcome (..)
  , LinkOutcome (..), RegisterOutcome (..), SignalCli (..)
  , TelegramBotApi (..), VerifyOutcome (..), channelCommandSpec )
import Seal.Command.Spec
  ( Availability (..), CommandName (..), CommandSpec (..), runCommandAction )
import Seal.Config.File (FileConfig (..), defaultFileConfig, loadFileConfig,
                          saveFileConfig)
import Seal.Core.AllowList (AllowList (..))
import Seal.Signal.Config (SignalConfig (..), defaultSignalChunkLimit)
import Seal.Telegram.Config
  ( TelegramConfig (..), defaultTelegramChunkLimit )
import Seal.TestHelpers.FakeCaps (getSent, makeFakeCaps)

-- ---------------------------------------------------------------------------
-- Mock SignalCli
-- ---------------------------------------------------------------------------

-- | A mock 'SignalCli' backed by 'IORef's so tests script the outcomes. The
-- register/verify fields assert the phone/captcha/code passed through.
mkMockCli
  :: Either Text Text
  -> LinkOutcome
  -> [(Text, Maybe Text, RegisterOutcome)]
  -> [(Text, Text, VerifyOutcome)]
  -> AccountsOutcome
  -> IO SignalCli
mkMockCli check link register verify accounts = do
  rCheck    <- newIORef check
  rLink     <- newIORef link
  rRegister <- newIORef register
  rVerify   <- newIORef verify
  rAccounts <- newIORef accounts
  pure SignalCli
    { scCheckInstalled = readIORef rCheck
    , scLink           = readIORef rLink
    , scRegister       = \phone mCaptcha -> do
        qs <- readIORef rRegister
        case qs of
          []              -> pure (RegisterFailed "no scripted register outcome")
          ((p, c, o):rest) -> do
            writeIORef rRegister rest
            (p, c) `shouldBe` (phone, mCaptcha)
            pure o
    , scVerify = \phone code -> do
        qs <- readIORef rVerify
        case qs of
          []              -> pure (VerifyFailed "no scripted verify outcome")
          ((p, c, o):rest) -> do
            writeIORef rVerify rest
            (p, c) `shouldBe` (phone, code)
            pure o
    , scListAccounts = readIORef rAccounts
    }

-- ---------------------------------------------------------------------------
-- Mock TelegramBotApi
-- ---------------------------------------------------------------------------

-- | A mock 'TelegramBotApi' that returns a scripted 'GetMeOutcome' for every
-- call. Tests script the outcome to exercise the valid-token and
-- invalid-token branches of the wizard.
mkMockTgApi :: GetMeOutcome -> IO TelegramBotApi
mkMockTgApi outcome = do
  ref <- newIORef outcome
  pure TelegramBotApi
    { tbaGetMe = \_token -> readIORef ref
    }

-- | A 'TelegramBotApi' whose 'tbaGetMe' always fails. Used for Signal-only
-- tests where the Telegram seam is never exercised.
dummyTgApi :: TelegramBotApi
dummyTgApi = TelegramBotApi { tbaGetMe = \_ -> pure (GetMeFailed "unused") }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Run /channel <args> against a mock runtime in a temp config dir.
-- Returns the messages sent via the channel, in order.
runChannel :: SignalCli -> TelegramBotApi -> [String] -> [Text] -> FilePath -> IO [Text]
runChannel cli tgApi argv inputs cfgPath = do
  (fc, caps) <- makeFakeCaps inputs
  let rt = ChannelRuntime { crConfigPath = cfgPath, crSignalCli = cli
                          , crTelegramBotApi = tgApi }
  case execParserPure defaultPrefs (csParserInfo (channelCommandSpec rt)) argv of
    Success act -> runCommandAction act caps
    _           -> expectationFailure ("parse failed: " <> show argv)
  getSent fc

-- | Sent messages joined into one block for substring assertions.
sentBlock :: [Text] -> Text
sentBlock = T.intercalate "\n"

-- | Load the signal section from a config file, failing the test if absent.
signalSection :: FilePath -> IO (Maybe SignalConfig)
signalSection cfgPath = do
  eCfg <- loadFileConfig cfgPath
  case eCfg of
    Right cfg -> pure (fcSignal cfg)
    Left _    -> expectationFailure "config failed to load" >> pure Nothing

-- | Unwrap a 'Just' produced by 'signalSection' after an 'isJust' assertion.
-- The prior 'shouldSatisfy' isJust' guards the partial match; this keeps the
-- pattern checker happy under -Wincomplete-uni-patterns.
unsafeSig :: Maybe SignalConfig -> SignalConfig
unsafeSig (Just s) = s
unsafeSig Nothing  = error "signalSection was Nothing despite isJust check"

-- | Load the telegram section from a config file, failing the test if absent.
telegramSection :: FilePath -> IO (Maybe TelegramConfig)
telegramSection cfgPath = do
  eCfg <- loadFileConfig cfgPath
  case eCfg of
    Right cfg -> pure (fcTelegram cfg)
    Left _    -> expectationFailure "config failed to load" >> pure Nothing

-- | Unwrap a 'Just' produced by 'telegramSection' after an 'isJust'
-- assertion. The prior 'shouldSatisfy' isJust' guards the partial match.
unsafeTg :: Maybe TelegramConfig -> TelegramConfig
unsafeTg (Just t) = t
unsafeTg Nothing  = error "telegramSection was Nothing despite isJust check"

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "Seal.Command.Channel" $ do

  describe "command spec metadata" $ do
    cli <- runIO (mkMockCli (Right "0.13.0") (LinkFailed "x") [] []
                        (AccountsFailed "x"))
    let rt = ChannelRuntime { crConfigPath = "/tmp/x.toml", crSignalCli = cli
                            , crTelegramBotApi = dummyTgApi }
        cs = channelCommandSpec rt
    it "name is /channel" $ csName cs `shouldBe` CommandName "channel"
    it "synopsis mentions signal" $ csSynopsis cs `shouldSatisfy` ("signal" `T.isInfixOf`)
    it "synopsis mentions telegram" $ csSynopsis cs `shouldSatisfy` ("telegram" `T.isInfixOf`)
    it "is InteractiveOnly" $ csAvailability cs `shouldBe` InteractiveOnly

  describe "/channel signal — signal-cli absent" $
    it "shows an install hint and bails" $
      withSystemTempDirectory "seal-channel" $ \tmp -> do
        let cfgPath = tmp <> "/config/config.toml"
        cli <- mkMockCli (Left "not found") (LinkFailed "x") [] []
                        (AccountsFailed "x")
        sent <- runChannel cli dummyTgApi ["signal"] [] cfgPath
        sentBlock sent `shouldSatisfy` ("signal-cli is not installed" `T.isInfixOf`)
        sentBlock sent `shouldSatisfy` ("github.com/AsamK/signal-cli" `T.isInfixOf`)

  describe "/channel signal — link flow" $
    it "links, detects the account, and writes the [signal] config" $
      withSystemTempDirectory "seal-channel" $ \tmp -> do
        let cfgPath = tmp <> "/config/config.toml"
        cli <- mkMockCli
          (Right "0.13.0")
          (LinkSucceeded "sgnl://link?enc=xyz")
          []
          []
          (AccountsFound ["+15551234567"])
        sent <- runChannel cli dummyTgApi ["signal"] ["1"] cfgPath
        sentBlock sent `shouldSatisfy` ("sgnl://link?enc=xyz" `T.isInfixOf`)
        sentBlock sent `shouldSatisfy` ("Detected account: +15551234567" `T.isInfixOf`)
        mSig <- signalSection cfgPath
        mSig `shouldSatisfy` isJust
        let sig = unsafeSig mSig
        scAccount sig `shouldBe` Just "+15551234567"
        scTextChunkLimit sig `shouldBe` Just defaultSignalChunkLimit
        scAllowFrom sig `shouldBe` AllowAll

  describe "/channel signal — link flow with undetectable account" $
    it "prompts for the phone number when listAccounts finds nothing" $
      withSystemTempDirectory "seal-channel" $ \tmp -> do
        let cfgPath = tmp <> "/config/config.toml"
        cli <- mkMockCli
          (Right "0.13.0")
          (LinkSucceeded "sgnl://link?enc=abc")
          []
          []
          (AccountsFound [])
        _sent <- runChannel cli dummyTgApi ["signal"] ["1", "+18005551234"] cfgPath
        mSig <- signalSection cfgPath
        mSig `shouldSatisfy` isJust
        let sig = unsafeSig mSig
        scAccount sig `shouldBe` Just "+18005551234"

  describe "/channel signal — register flow (no captcha)" $
    it "registers, verifies, and writes config" $
      withSystemTempDirectory "seal-channel" $ \tmp -> do
        let cfgPath = tmp <> "/config/config.toml"
        cli <- mkMockCli
          (Right "0.13.0")
          (LinkFailed "x")
          [("+15557654321", Nothing, RegisterOk)]
          [("+15557654321", "123456", VerifyOk)]
          (AccountsFound ["+15557654321"])
        sent <- runChannel cli dummyTgApi ["signal"] ["2", "+15557654321", "123456"] cfgPath
        sentBlock sent `shouldSatisfy` ("Sending verification SMS to +15557654321" `T.isInfixOf`)
        sentBlock sent `shouldSatisfy` ("Phone number verified!" `T.isInfixOf`)
        mSig <- signalSection cfgPath
        mSig `shouldSatisfy` isJust
        let sig = unsafeSig mSig
        scAccount sig `shouldBe` Just "+15557654321"

  describe "/channel signal — register flow with captcha" $
    it "loops back through register with the captcha token" $
      withSystemTempDirectory "seal-channel" $ \tmp -> do
        let cfgPath = tmp <> "/config/config.toml"
        cli <- mkMockCli
          (Right "0.13.0")
          (LinkFailed "x")
          [ ("+15551112222", Nothing, RegisterCaptchaRequired)
          , ("+15551112222", Just "tok123", RegisterOk)
          ]
          [ ("+15551112222", "999000", VerifyOk) ]
          (AccountsFound ["+15551112222"])
        sent <- runChannel cli dummyTgApi ["signal"]
                   ["2", "+15551112222", "signalcaptcha://tok123", "999000"] cfgPath
        sentBlock sent `shouldSatisfy` ("requires a captcha" `T.isInfixOf`)
        sentBlock sent `shouldSatisfy` ("Phone number verified!" `T.isInfixOf`)
        mSig <- signalSection cfgPath
        mSig `shouldSatisfy` isJust
        let sig = unsafeSig mSig
        scAccount sig `shouldBe` Just "+15551112222"

  describe "/channel signal — invalid choice" $
    it "reports the invalid choice and cancels" $
      withSystemTempDirectory "seal-channel" $ \tmp -> do
        let cfgPath = tmp <> "/config/config.toml"
        cli <- mkMockCli (Right "0.13.0") (LinkFailed "x") [] []
                        (AccountsFailed "x")
        sent <- runChannel cli dummyTgApi ["signal"] ["9"] cfgPath
        sentBlock sent `shouldSatisfy` ("Invalid choice" `T.isInfixOf`)

  describe "/channel signal — invalid phone number" $
    it "rejects a non-E.164 number before calling register" $
      withSystemTempDirectory "seal-channel" $ \tmp -> do
        let cfgPath = tmp <> "/config/config.toml"
        cli <- mkMockCli (Right "0.13.0") (LinkFailed "x") [] []
                        (AccountsFailed "x")
        sent <- runChannel cli dummyTgApi ["signal"] ["2", "5551234"] cfgPath
        sentBlock sent `shouldSatisfy` ("Invalid phone number" `T.isInfixOf`)

  describe "/channel signal — default choice is link (empty input)" $
    it "treats an empty choice as [1] link" $
      withSystemTempDirectory "seal-channel" $ \tmp -> do
        let cfgPath = tmp <> "/config/config.toml"
        cli <- mkMockCli
          (Right "0.13.0")
          (LinkSucceeded "sgnl://link?enc=dflt")
          []
          []
          (AccountsFound ["+14045551234"])
        sent <- runChannel cli dummyTgApi ["signal"] [""] cfgPath
        sentBlock sent `shouldSatisfy` ("sgnl://link?enc=dflt" `T.isInfixOf`)
        mSig <- signalSection cfgPath
        mSig `shouldSatisfy` isJust
        let sig = unsafeSig mSig
        scAccount sig `shouldBe` Just "+14045551234"

  describe "writeSignalConfig preserves existing config" $
    it "keeps unrelated keys (vault_recipient) when adding [signal]" $
      withSystemTempDirectory "seal-channel" $ \tmp -> do
        let cfgPath = tmp <> "/config/config.toml"
        System.Directory.createDirectoryIfMissing True (System.FilePath.takeDirectory cfgPath)
        let seed = defaultFileConfig { fcVaultRecipient = Just "age1xxx" }
        saveFileConfig cfgPath seed
        cli <- mkMockCli
          (Right "0.13.0")
          (LinkSucceeded "sgnl://enc")
          []
          []
          (AccountsFound ["+15550000000"])
        _sent <- runChannel cli dummyTgApi ["signal"] ["1"] cfgPath
        eCfg <- loadFileConfig cfgPath
        case eCfg of
          Right cfg -> do
            fcVaultRecipient cfg `shouldBe` Just "age1xxx"
            fcSignal cfg `shouldSatisfy` isJust
          Left _ -> expectationFailure "config failed to load"

  -- ---------------------------------------------------------------------
  -- Telegram wizard tests
  -- ---------------------------------------------------------------------

  describe "/channel telegram — valid token" $
    it "validates the token via getMe and writes the [telegram] config" $
      withSystemTempDirectory "seal-channel" $ \tmp -> do
        let cfgPath = tmp <> "/config/config.toml"
        cli <- mkMockCli (Right "0.13.0") (LinkFailed "x") [] []
                        (AccountsFailed "x")
        tgApi <- mkMockTgApi (GetMeOk "MySealBot")
        sent <- runChannel cli tgApi ["telegram"] ["123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11"] cfgPath
        sentBlock sent `shouldSatisfy` ("Validating token with Telegram" `T.isInfixOf`)
        sentBlock sent `shouldSatisfy` ("Connected! Bot username: @MySealBot" `T.isInfixOf`)
        sentBlock sent `shouldSatisfy` ("Telegram configured!" `T.isInfixOf`)
        mTg <- telegramSection cfgPath
        mTg `shouldSatisfy` isJust
        let tg = unsafeTg mTg
        tcToken tg `shouldBe` Just "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11"
        tcTextChunkLimit tg `shouldBe` Just defaultTelegramChunkLimit
        tcAllowFrom tg `shouldBe` AllowAll

  describe "/channel telegram — getMe fails" $
    it "reports the failure and does not write config" $
      withSystemTempDirectory "seal-channel" $ \tmp -> do
        let cfgPath = tmp <> "/config/config.toml"
        cli <- mkMockCli (Right "0.13.0") (LinkFailed "x") [] []
                        (AccountsFailed "x")
        tgApi <- mkMockTgApi (GetMeFailed "Unauthorized")
        sent <- runChannel cli tgApi ["telegram"] ["123456:BAD"] cfgPath
        sentBlock sent `shouldSatisfy` ("Token validation failed: Unauthorized" `T.isInfixOf`)
        mTg <- telegramSection cfgPath
        mTg `shouldBe` Nothing

  describe "/channel telegram — empty token" $
    it "rejects an empty token before calling getMe" $
      withSystemTempDirectory "seal-channel" $ \tmp -> do
        let cfgPath = tmp <> "/config/config.toml"
        cli <- mkMockCli (Right "0.13.0") (LinkFailed "x") [] []
                        (AccountsFailed "x")
        tgApi <- mkMockTgApi (GetMeOk "never")
        sent <- runChannel cli tgApi ["telegram"] [""] cfgPath
        sentBlock sent `shouldSatisfy` ("Invalid token" `T.isInfixOf`)
        mTg <- telegramSection cfgPath
        mTg `shouldBe` Nothing

  describe "/channel telegram — leading-dash token" $
    it "rejects a leading-dash token (option injection)" $
      withSystemTempDirectory "seal-channel" $ \tmp -> do
        let cfgPath = tmp <> "/config/config.toml"
        cli <- mkMockCli (Right "0.13.0") (LinkFailed "x") [] []
                        (AccountsFailed "x")
        tgApi <- mkMockTgApi (GetMeOk "never")
        sent <- runChannel cli tgApi ["telegram"] ["--version"] cfgPath
        sentBlock sent `shouldSatisfy` ("Invalid token" `T.isInfixOf`)

  describe "/channel telegram — preserves existing config" $
    it "keeps unrelated keys (vault_recipient) when adding [telegram]" $
      withSystemTempDirectory "seal-channel" $ \tmp -> do
        let cfgPath = tmp <> "/config/config.toml"
        System.Directory.createDirectoryIfMissing True (System.FilePath.takeDirectory cfgPath)
        let seed = defaultFileConfig { fcVaultRecipient = Just "age1yyy" }
        saveFileConfig cfgPath seed
        cli <- mkMockCli (Right "0.13.0") (LinkFailed "x") [] []
                        (AccountsFailed "x")
        tgApi <- mkMockTgApi (GetMeOk "SealBot")
        _sent <- runChannel cli tgApi ["telegram"] ["123456:ABC-DEF"] cfgPath
        eCfg <- loadFileConfig cfgPath
        case eCfg of
          Right cfg -> do
            fcVaultRecipient cfg `shouldBe` Just "age1yyy"
            fcTelegram cfg `shouldSatisfy` isJust
          Left _ -> expectationFailure "config failed to load"

  -- ---------------------------------------------------------------------
  -- Parser tests
  -- ---------------------------------------------------------------------

  describe "/channel — unknown subcommand" $
    it "optparse rejects /channel discord" $
      withSystemTempDirectory "seal-channel" $ \tmp -> do
        let cfgPath = tmp <> "/config/config.toml"
        cli <- mkMockCli (Right "0.13.0") (LinkFailed "x") [] []
                        (AccountsFailed "x")
        let rt = ChannelRuntime { crConfigPath = cfgPath, crSignalCli = cli
                                , crTelegramBotApi = dummyTgApi }
        case execParserPure defaultPrefs (csParserInfo (channelCommandSpec rt))
                             ["discord"] of
          Failure _       -> pure ()
          Success _       -> expectationFailure "expected /channel discord to fail"
          CompletionInvoked _ -> expectationFailure "unexpected completion"

  describe "/channel — --help renders both subcommands" $
    it "the --help text mentions signal and telegram" $
      withSystemTempDirectory "seal-channel" $ \tmp -> do
        let cfgPath = tmp <> "/config/config.toml"
        cli <- mkMockCli (Right "0.13.0") (LinkFailed "x") [] []
                        (AccountsFailed "x")
        let rt = ChannelRuntime { crConfigPath = cfgPath, crSignalCli = cli
                                , crTelegramBotApi = dummyTgApi }
        case execParserPure defaultPrefs (csParserInfo (channelCommandSpec rt))
                             ["--help"] of
          Failure _       -> pure ()  -- optparse emits help as a Failure
          Success _       -> expectationFailure "expected --help to render, not succeed"
          CompletionInvoked _ -> expectationFailure "unexpected completion"