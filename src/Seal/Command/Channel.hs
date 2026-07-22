{-# LANGUAGE OverloadedStrings #-}
-- | The @\/channel@ command: interactive setup for chat channels. Currently
-- Signal and Telegram are supported. The Signal wizard checks for
-- @signal-cli@, offers a @link@ (secondary device) or @register@ (primary
-- device) flow, walks the user through it via 'ChannelCaps' prompts, and
-- writes the resolved account into the @[signal]@ section of @config.toml@.
-- The Telegram wizard prompts for a BotFather token, validates it via the
-- Bot API @getMe@ endpoint, and writes the @[telegram]@ section. Mirrors
-- PureClaw's @\/channel signal@ wizard; adapted to Seal's 'ChannelCaps' +
-- 'RuntimeConfig' + 'SealPaths' shape.
module Seal.Command.Channel
  ( channelCommandSpec
  , ChannelRuntime (..)
  , SignalCli (..)
  , mkRealSignalCli
  , TelegramBotApi (..)
  , mkRealTelegramBotApi
  , VaultStore (..)
  , mkRealVaultStore
  , noVaultStore
  , GetMeOutcome (..)
  , LinkOutcome (..)
  , RegisterOutcome (..)
  , VerifyOutcome (..)
  , AccountsOutcome (..)
  ) where

import Control.Exception (IOException, SomeException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Either (fromRight)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8With)
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Network.HTTP.Client (Manager, httpLbs, parseRequest, responseBody,
                            responseStatus)
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types (statusCode)
import Options.Applicative
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory)
import System.IO (BufferMode (..), Handle, hGetLine, hSetBuffering)
import System.Process
  ( CreateProcess (..), StdStream (..), proc, waitForProcess,
    withCreateProcess )

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..)
  , CommandName (..), CommandSpec (..) )
import Seal.Config.File (RuntimeConfig (..), defaultRuntimeConfig, loadRuntimeConfig,
                         saveRuntimeConfig)
import Seal.Core.AllowList (AllowList (..))
import Seal.Security.Vault qualified as Vault
import Seal.Signal.Config (SignalConfig (..), defaultSignalChunkLimit)
import Seal.Telegram.Config
  ( TelegramConfig (..), defaultTelegramChunkLimit, mkTelegramToken
  , telegramTokenText, telegramVaultKey )

-- ---------------------------------------------------------------------------
-- Runtime + testability seam
-- ---------------------------------------------------------------------------

-- | The runtime the @\/channel@ command closes over: where to find the
-- config file (so the wizard can read-modify-write @config.toml@), a
-- 'SignalCli' seam for shelling out to @signal-cli@, a 'TelegramBotApi'
-- seam for the Telegram Bot API, and a 'VaultStore' seam for storing
-- channel secrets in the vault. Tests inject mock seams so @cabal test@
-- never needs the binary, network, or vault.
data ChannelRuntime = ChannelRuntime
  { crConfigPath    :: FilePath
  , crSignalCli     :: SignalCli
  , crTelegramBotApi :: TelegramBotApi
  , crVaultStore    :: VaultStore
  }

-- | A seam over the vault for storing channel secrets (like the Telegram
-- bot token). The wizard writes the token to the vault (not @config.toml@)
-- so it is never stored in cleartext. 'vsStore' stores a key+value;
-- 'vsAvailable' checks whether the vault is open and ready.
data VaultStore = VaultStore
  { vsStore     :: Text -> ByteString -> IO (Either Text ())
    -- ^ Store a secret under a key. 'Right ()' on success; 'Left' diagnostic.
  , vsAvailable :: IO Bool
    -- ^ Is the vault open and ready to accept writes?
  }

-- | A small seam over the @signal-cli@ binary. Each field is one subprocess
-- operation the wizard needs. 'mkRealSignalCli' shells out; tests supply an
-- in-memory 'SignalCli'. The seam keeps the wizard logic pure with respect
-- to the binary and makes the interactive flow unit-testable.
data SignalCli = SignalCli
  { scCheckInstalled :: IO (Either Text Text)
    -- ^ @signal-cli --version@. Right version-string on success; Left
    -- diagnostic if absent or failing.
  , scLink           :: IO LinkOutcome
    -- ^ @signal-cli link -n Seal@. Streams the @sgnl:\/\/@ URI; blocks until
    -- the user scans it. See 'LinkOutcome'.
  , scRegister       :: Text -> Maybe Text -> IO RegisterOutcome
    -- ^ @signal-cli -u <phone> register [--captcha <token>]@.
  , scVerify         :: Text -> Text -> IO VerifyOutcome
    -- ^ @signal-cli -u <phone> verify <code>@.
  , scListAccounts   :: IO AccountsOutcome
    -- ^ @signal-cli listAccounts@. Used to detect the linked account.
  }

-- | Outcome of @signal-cli link@: the @sgnl:\/\/@ URI to show the user (or a
-- failure), then the exit status after the user scans. The URI is emitted
-- before blocking, so the wizard can show it immediately.
data LinkOutcome
  = LinkFailed Text
  | LinkSucceeded Text
    -- ^ The @sgnl:\/\/@ URI; the scan completed with @ExitSuccess@.

-- | Outcome of @signal-cli -u <phone> register@.
data RegisterOutcome
  = RegisterOk
  | RegisterCaptchaRequired
  | RegisterFailed Text

-- | Outcome of @signal-cli -u <phone> verify <code>@.
data VerifyOutcome
  = VerifyOk
  | VerifyFailed Text

-- | Outcome of @signal-cli listAccounts@.
data AccountsOutcome
  = AccountsFailed Text
  | AccountsFound [Text]
    -- ^ The detected @+…@ phone numbers (E.164).

-- ---------------------------------------------------------------------------
-- TelegramBotApi — seam over the Telegram Bot API
-- ---------------------------------------------------------------------------

-- | A small seam over the Telegram Bot API. The wizard needs only one
-- operation: validate a bot token via @getMe@. 'mkRealTelegramBotApi'
-- performs an HTTPS request to the Bot API; tests supply an in-memory
-- 'TelegramBotApi'. The seam keeps the wizard logic pure with respect to
-- the network and makes the interactive flow unit-testable.
newtype TelegramBotApi = TelegramBotApi
  { tbaGetMe :: Text -> IO GetMeOutcome
    -- ^ Call @GET \/bot<token>\/getMe@. 'Right' username on success; 'Left'
    -- diagnostic if the token is invalid or the request fails.
  }

-- | Outcome of the Bot API @getMe@ call.
data GetMeOutcome
  = GetMeOk Text
    -- ^ The bot's username (without the leading @).
  | GetMeFailed Text

-- ---------------------------------------------------------------------------
-- CommandSpec
-- ---------------------------------------------------------------------------

-- | The @\/channel@ command spec. Subcommands: @signal@, @telegram@.
-- Interactive only (the wizard prompts the user; non-interactive channels
-- defer prompts, so the wizard is meaningful on the CLI TUI and equivalent
-- interactive surfaces). The 'ChannelRuntime' carries the config path +
-- 'SignalCli' + 'TelegramBotApi' seams.
channelCommandSpec :: ChannelRuntime -> CommandSpec
channelCommandSpec rt = CommandSpec
  { csName         = CommandName "channel"
  , csAliases      = []
  , csGroup        = GroupGeneral
  , csSynopsis     = "Set up a chat channel (signal, telegram)"
  , csParserInfo   = channelParserInfo rt
  , csAvailability = InteractiveOnly
  }

channelParserInfo :: ChannelRuntime -> ParserInfo CommandAction
channelParserInfo rt =
  info (channelParser rt <**> helper)
    (  progDesc "Set up a chat channel"
    <> header   "channel — interactive channel setup (signal, telegram)"
    )

channelParser :: ChannelRuntime -> Parser CommandAction
channelParser rt = hsubparser
  $  command "signal"
       (info (pure (signalSetupCmd rt)) (progDesc "Set up the Signal channel"))
  <> command "telegram"
       (info (pure (telegramSetupCmd rt)) (progDesc "Set up the Telegram channel"))
  <> metavar "CHANNEL"

-- ---------------------------------------------------------------------------
-- Wizard
-- ---------------------------------------------------------------------------

-- | Run the Signal setup wizard. Checks @signal-cli@, offers link or
-- register, walks the chosen flow, writes config. All interaction goes
-- through 'ChannelCaps' (sends + prompts) so the wizard works on the CLI
-- TUI and any interactive channel.
signalSetupCmd :: ChannelRuntime -> CommandAction
signalSetupCmd rt = CommandAction $ \caps -> do
  let cli = crSignalCli rt
  -- Step 1: Check signal-cli is installed.
  eVer <- scCheckInstalled cli
  case eVer of
    Left _ -> ccSend caps $ T.intercalate "\n"
      [ "signal-cli is not installed."
      , ""
      , "Install it first:"
      , "  macOS:  brew install signal-cli"
      , "  Nix:    nix-env -i signal-cli"
      , "  Other:  https://github.com/AsamK/signal-cli"
      , ""
      , "Then run /channel signal again."
      ]
    Right version -> do
      ccSend caps ("Found signal-cli " <> version)
      -- Step 2: Offer link or register.
      ccSend caps $ T.intercalate "\n"
        [ ""
        , "How would you like to connect?"
        , "  [1] Link to an existing Signal account (adds Seal as secondary device)"
        , "  [2] Register with a phone number (becomes primary device for that number)"
        , ""
        , "Note: Option 2 will take over the number from any existing Signal registration."
        ]
      choice <- T.strip <$> ccPrompt caps "Choice [1]: "
      let effectiveChoice = if T.null choice then "1" else choice
      case effectiveChoice of
        "1" -> signalLinkFlow rt caps
        "2" -> signalRegisterFlow rt caps
        _   -> ccSend caps "Invalid choice. Setup cancelled."

-- | Link to an existing Signal account by scanning a @sgnl:\/\/@ URI.
signalLinkFlow :: ChannelRuntime -> ChannelCaps -> IO ()
signalLinkFlow rt caps = do
  ccSend caps "Generating link... (this may take a moment)"
  outcome <- scLink (crSignalCli rt)
  case outcome of
    LinkFailed err -> ccSend caps ("signal-cli link failed: " <> err)
    LinkSucceeded uri -> do
      ccSend caps $ T.intercalate "\n"
        [ "Open Signal on your phone:"
        , "  Settings \x2192 Linked Devices \x2192 Link New Device"
        , ""
        , "Scan this link (or paste into a QR code generator):"
        , ""
        , "  " <> uri
        , ""
        , "Waiting for you to scan... (this will complete automatically)"
        ]
      detectAndWriteSignalConfig rt caps

-- | Register a new phone number (primary device). Prompts for the E.164
-- number, calls @signal-cli register@ (handling a captcha challenge if
-- required), then @verify@.
signalRegisterFlow :: ChannelRuntime -> ChannelCaps -> IO ()
signalRegisterFlow rt caps = do
  phoneNumber <- T.strip <$> ccPrompt caps "Phone number (E.164 format, e.g. +15555550123): "
  if T.null phoneNumber || not ("+" `T.isPrefixOf` phoneNumber)
    then ccSend caps "Invalid phone number. Must start with + (E.164 format)."
    else signalRegister rt caps phoneNumber Nothing

-- | Attempt @signal-cli -u <phone> register@, handling the captcha loop.
signalRegister :: ChannelRuntime -> ChannelCaps -> Text -> Maybe Text -> IO ()
signalRegister rt caps phoneNumber mCaptcha = do
  let cli = crSignalCli rt
  ccSend caps ("Sending verification SMS to " <> phoneNumber <> "...")
  result <- scRegister cli phoneNumber mCaptcha
  case result of
    RegisterOk -> signalVerify rt caps phoneNumber
    RegisterCaptchaRequired -> do
      ccSend caps $ T.intercalate "\n"
        [ "Signal requires a captcha before sending the SMS."
        , ""
        , "1. Open this URL in a browser:"
        , "   https://signalcaptchas.org/registration/generate.html"
        , "2. Solve the captcha"
        , "3. Open DevTools (F12), go to Network tab"
        , "4. Click \"Open Signal\" \x2014 find the signalcaptcha:// URL in the Network tab"
        , "5. Copy and paste the full URL here (starts with signalcaptcha://)"
        ]
      captchaInput <- T.strip <$> ccPrompt caps "Captcha token: "
      let token = T.strip (T.replace "signalcaptcha://" "" captchaInput)
      if T.null token
        then ccSend caps "No captcha provided. Setup cancelled."
        else signalRegister rt caps phoneNumber (Just token)
    RegisterFailed err -> ccSend caps ("Registration failed: " <> err)

-- | Verify a phone number after the registration SMS was sent.
signalVerify :: ChannelRuntime -> ChannelCaps -> Text -> IO ()
signalVerify rt caps phoneNumber = do
  ccSend caps "Verification code sent! Check your SMS."
  code <- T.strip <$> ccPrompt caps "Verification code: "
  result <- scVerify (crSignalCli rt) phoneNumber code
  case result of
    VerifyOk -> do
      ccSend caps "Phone number verified!"
      writeSignalConfig rt caps phoneNumber
    VerifyFailed err -> ccSend caps ("Verification failed: " <> err)

-- | Detect the linked account number via @signal-cli listAccounts@, then
-- write config. Falls back to prompting if detection fails.
detectAndWriteSignalConfig :: ChannelRuntime -> ChannelCaps -> IO ()
detectAndWriteSignalConfig rt caps = do
  result <- scListAccounts (crSignalCli rt)
  case result of
    AccountsFailed _ -> do
      phoneNumber <- T.strip <$> ccPrompt caps "What phone number was linked? (E.164 format): "
      writeSignalConfig rt caps phoneNumber
    AccountsFound (phone : _) -> do
      ccSend caps ("Detected account: " <> phone)
      writeSignalConfig rt caps phone
    AccountsFound [] -> do
      phoneNumber <- T.strip <$> ccPrompt caps "Could not detect account. Phone number (E.164 format): "
      writeSignalConfig rt caps phoneNumber

-- | Write the @[signal]@ section into @config.toml@ and confirm. Preserves
-- all other config; sets the account and a permissive default DM policy
-- (@AllowAll@), which the user can tighten later by editing @allow_from@.
writeSignalConfig :: ChannelRuntime -> ChannelCaps -> Text -> IO ()
writeSignalConfig rt caps phoneNumber = do
  let cfgPath = crConfigPath rt
  createDirectoryIfMissing True (takeDirectory cfgPath)
  existing <- loadRuntimeConfig cfgPath
  let baseCfg = fromRight defaultRuntimeConfig existing
      updated = baseCfg
        { rcSignal = Just SignalConfig
            { scAccount        = Just phoneNumber
            , scTextChunkLimit = Just defaultSignalChunkLimit
            , scAllowFrom      = AllowAll
            }
        }
  saveRuntimeConfig cfgPath updated
  ccSend caps $ T.intercalate "\n"
    [ ""
    , "Signal configured!"
    , "  Account: " <> phoneNumber
    , "  DM policy: open (accepts messages from anyone)"
    , ""
    , "To start chatting:"
    , "  1. Restart Seal (or run: seal signal)"
    , "  2. Open Signal on your phone"
    , "  3. Send a message to " <> phoneNumber
    , ""
    , "To restrict access later, edit " <> T.pack cfgPath <> ":"
    , "  [signal]"
    , "  allow_from = [\"<your-phone-or-uuid>\"]"
    , ""
    , "Your UUID will appear in the logs on first message."
    ]

-- ---------------------------------------------------------------------------
-- Telegram wizard
-- ---------------------------------------------------------------------------

-- | Run the Telegram setup wizard. Prompts for a BotFather token, validates
-- it via the Bot API @getMe@ (so a typo is caught here, not at runtime),
-- stores the token in the vault (NOT in @config.toml@), and writes the
-- @[telegram]@ config section with the non-secret fields. All interaction
-- goes through 'ChannelCaps' (sends + prompts) so the wizard works on the
-- CLI TUI and any interactive channel.
telegramSetupCmd :: ChannelRuntime -> CommandAction
telegramSetupCmd rt = CommandAction $ \caps -> do
  ccSend caps $ T.intercalate "\n"
    [ "Setting up the Telegram channel."
    , ""
    , "You need a bot token from BotFather (@BotFather on Telegram):"
    , "  1. Open a chat with @BotFather"
    , "  2. Send /newbot and follow the prompts"
    , "  3. Copy the token it gives you (looks like 123456:ABC-DEF...)"
    ]
  tokenInput <- T.strip <$> ccPrompt caps "Bot token: "
  case mkTelegramToken tokenInput of
    Left err -> ccSend caps ("Invalid token: " <> err)
    Right token -> do
      ccSend caps "Validating token with Telegram..."
      result <- tbaGetMe (crTelegramBotApi rt) (telegramTokenText token)
      case result of
        GetMeFailed err -> ccSend caps ("Token validation failed: " <> err)
        GetMeOk username -> do
          ccSend caps ("Connected! Bot username: @" <> username)
          storeTelegramToken rt caps (telegramTokenText token) username

-- | Store the token in the vault and write the @[telegram]@ config section
-- (without the token — only non-secret fields). If the vault is not
-- available, warns the user to set up the vault first.
storeTelegramToken :: ChannelRuntime -> ChannelCaps -> Text -> Text -> IO ()
storeTelegramToken rt caps token username = do
  let store = crVaultStore rt
  available <- vsAvailable store
  if not available
    then ccSend caps $ T.intercalate "\n"
      [ ""
      , "Vault is not set up or not unlocked."
      , "The Telegram bot token is a secret and must be stored in the vault."
      , ""
      , "Run /vault setup first, then /channel telegram again."
      ]
    else do
      result <- vsStore store telegramVaultKey (TE.encodeUtf8 token)
      case result of
        Left err -> ccSend caps ("Failed to store token in vault: " <> err)
        Right () -> writeTelegramConfig rt caps username

-- | Write the @[telegram]@ section into @config.toml@ (without the token)
-- and confirm. The token is stored in the vault, not the config file.
-- Preserves all other config; sets a permissive default DM policy
-- (@AllowAll@), which the user can tighten later by editing @allow_from@.
writeTelegramConfig :: ChannelRuntime -> ChannelCaps -> Text -> IO ()
writeTelegramConfig rt caps username = do
  let cfgPath = crConfigPath rt
  createDirectoryIfMissing True (takeDirectory cfgPath)
  existing <- loadRuntimeConfig cfgPath
  let baseCfg = fromRight defaultRuntimeConfig existing
      updated = baseCfg
        { rcTelegram = Just TelegramConfig
            { tcToken         = Nothing  -- token lives in the vault, not config
            , tcTextChunkLimit = Just defaultTelegramChunkLimit
            , tcAllowFrom      = AllowAll
            }
        }
  saveRuntimeConfig cfgPath updated
  ccSend caps $ T.intercalate "\n"
    [ ""
    , "Telegram configured!"
    , "  Bot: @" <> username
    , "  Token: stored in vault (key: " <> telegramVaultKey <> ")"
    , "  DM policy: open (accepts messages from anyone)"
    , ""
    , "To start chatting:"
    , "  1. Restart Seal (or run: seal telegram)"
    , "  2. Open Telegram and DM @" <> username
    , ""
    , "To restrict access later, edit " <> T.pack cfgPath <> ":"
    , "  [telegram]"
    , "  allow_from = [\"<your-telegram-user-id>\"]"
    , ""
    , "Your Telegram user id will appear in the logs on first message."
    ]

-- ---------------------------------------------------------------------------
-- Real SignalCli — shells out to signal-cli
-- ---------------------------------------------------------------------------

-- | The real 'SignalCli': every field shells out to the @signal-cli@ binary
-- via "System.Process". Returned by 'mkRealSignalCli'. If @signal-cli@ is
-- absent the fields surface a clear 'Left' (the wizard shows an install
-- hint and bails).
mkRealSignalCli :: IO SignalCli
mkRealSignalCli = pure SignalCli
  { scCheckInstalled = do
      (ec, out, _err) <- readProcessNoInput "signal-cli" ["--version"]
      pure $ case ec of
        ExitSuccess ->
          Right (T.strip (decodeUtf8 out))
        _ -> Left "signal-cli not installed or not on PATH"
  , scLink = runLink
  , scRegister = \phone mCaptcha ->
      let captchaArgs = maybe [] (\c -> ["--captcha", T.unpack c]) mCaptcha
          args = ["-u", T.unpack phone, "register"] <> captchaArgs
      in do
        (ec, _out, err) <- readProcessNoInput "signal-cli" args
        let errText = T.strip (decodeUtf8 err)
        pure $ case ec of
          ExitSuccess -> RegisterOk
          _ | "captcha" `T.isInfixOf` T.toLower errText -> RegisterCaptchaRequired
            | otherwise -> RegisterFailed errText
  , scVerify = \phone code -> do
      (ec, _out, err) <- readProcessNoInput "signal-cli"
        ["-u", T.unpack phone, "verify", T.unpack code]
      let errText = T.strip (decodeUtf8 err)
      pure $ case ec of
        ExitSuccess -> VerifyOk
        _ -> VerifyFailed errText
  , scListAccounts = do
      (ec, out, _err) <- readProcessNoInput "signal-cli" ["listAccounts"]
      pure $ case ec of
        ExitSuccess ->
          let phones = filter ("+" `T.isPrefixOf`)
                         (map T.strip (T.lines (decodeUtf8 out)))
          in AccountsFound phones
        _ -> AccountsFailed "signal-cli listAccounts failed"
  }

-- ---------------------------------------------------------------------------
-- Real TelegramBotApi — calls the Telegram Bot API over HTTPS
-- ---------------------------------------------------------------------------

-- | The real 'TelegramBotApi': validates a bot token via a GET request to
-- @https:\/\/api.telegram.org\/bot<token>\/getMe@. Uses a shared TLS manager.
-- On a non-200 response or a network error the wizard surfaces a clear
-- 'GetMeFailed'. The bot's username is extracted from the JSON response body
-- (the @\"result\": {\"username\": \"...\"}@ field). We avoid pulling in a
-- full JSON parser dependency by extracting the username via a lightweight
-- text scan — the Bot API response shape for getMe is stable.
mkRealTelegramBotApi :: IO TelegramBotApi
mkRealTelegramBotApi = do
  mgr <- newTlsManager
  pure TelegramBotApi
    { tbaGetMe = validateToken mgr
    }

-- ---------------------------------------------------------------------------
-- VaultStore — seam over the vault for storing channel secrets
-- ---------------------------------------------------------------------------

-- | Build a 'VaultStore' from a 'VaultHandle'. 'vsStore' encodes the text
-- to a ByteString and calls 'vhPut'; 'vsAvailable' checks that the vault
-- is open (not locked) by calling 'vhStatus'.
mkRealVaultStore :: Maybe Vault.VaultHandle -> IO VaultStore
mkRealVaultStore mVh = pure $ case mVh of
  Nothing -> noVaultStore
  Just vh -> VaultStore
    { vsStore = \key val -> do
        r <- Vault.vhPut vh key val
        pure $ case r of
          Right () -> Right ()
          Left err -> Left (T.pack (show err))
    , vsAvailable = do
        st <- Vault.vhStatus vh
        pure (not (Vault.vsLocked st))
    }

-- | A 'VaultStore' that is never available (no vault configured). The
-- wizard shows a "set up the vault first" message when this is used.
noVaultStore :: VaultStore
noVaultStore = VaultStore
  { vsStore = \_ _ -> pure (Left "vault not configured")
  , vsAvailable = pure False
  }

-- | Perform the @getMe@ request and extract the bot username. Returns
-- 'GetMeOk' with the username (without the leading @) on success,
-- 'GetMeFailed' with a diagnostic otherwise.
validateToken :: Manager -> Text -> IO GetMeOutcome
validateToken mgr token = do
  let url = "https://api.telegram.org/bot" <> T.unpack token <> "/getMe"
  eReq <- try @SomeException (parseRequest url)
  case eReq of
    Left ex -> pure (GetMeFailed ("request error: " <> T.pack (show ex)))
    Right req -> do
      eResp <- try @SomeException (httpLbs req mgr)
      case eResp of
        Left ex -> pure (GetMeFailed ("network error: " <> T.pack (show ex)))
        Right resp ->
          let code = statusCode (responseStatus resp)
              body = decodeUtf8 (BL.toStrict (responseBody resp))
          in if code == 200
               then case extractUsername body of
                 Just u  -> pure (GetMeOk u)
                 Nothing -> pure (GetMeFailed "could not parse username from getMe response")
               else pure (GetMeFailed ("getMe returned HTTP " <> T.pack (show code) <> ": " <> body))

-- | Extract the @\"username\"@ field value from a getMe JSON response body
-- via a lightweight text scan: find @\"username\"@ then the next quoted
-- string. The Bot API response shape is stable: @{"ok":true,"result":{"id":...,"is_bot":true,"first_name":"...","username":"..."}}@.
-- Returns the username without the leading @.
extractUsername :: Text -> Maybe Text
extractUsername body = do
  let key = "\"username\""
      afterKey = T.dropWhile (`notElem` ("\"" :: String))
                   (T.drop (T.length key)
                           (snd (T.breakOn key body)))
  -- afterKey starts with "username-value"..., drop the leading quote
  case T.uncons (T.drop 1 afterKey) of
    Just (_, rest) ->
      let val = T.takeWhile (/= '"') rest
      in if T.null val then Nothing else Just val
    Nothing -> Nothing

-- ---------------------------------------------------------------------------
-- runLink — signal-cli link subprocess
-- ---------------------------------------------------------------------------
runLink :: IO LinkOutcome
runLink =
  withCreateProcess
    ( (proc "signal-cli" ["link", "-n", "Seal"])
        { std_out = CreatePipe, std_err = CreatePipe }
    ) $ \_ mOut mErr ph -> do
      let stderrH = fromMaybe (error "runLink: no stderr handle") mErr
          stdoutH = fromMaybe (error "runLink: no stdout handle") mOut
      hSetBuffering stderrH LineBuffering
      hSetBuffering stdoutH LineBuffering
      mUri <- readUntilLink stderrH stdoutH
      case mUri of
        Nothing -> do
          _ <- waitForProcess ph
          pure (LinkFailed "no sgnl:// URI found in signal-cli link output")
        Just uri -> do
          ec <- waitForProcess ph
          case ec of
            ExitSuccess -> pure (LinkSucceeded uri)
            _ -> pure (LinkFailed ("signal-cli link exited " <> T.pack (show ec)))

-- | Read lines from stderr then stdout looking for a @sgnl:\/\/@ URI. Max
-- 50 lines to prevent an infinite loop on a misbehaving signal-cli.
readUntilLink :: Handle -> Handle -> IO (Maybe Text)
readUntilLink stderrH stdoutH = go (50 :: Int)
  where
    go 0 = pure Nothing
    go n = do
      lineResult <- try @IOException (hGetLine stderrH)
      case lineResult of
        Right line ->
          let t = T.pack line
          in if "sgnl://" `T.isInfixOf` t
             then pure (Just (T.strip t))
             else go (n - 1)
        Left _ -> do
          outResult <- try @IOException (hGetLine stdoutH)
          case outResult of
            Right line ->
              let t = T.pack line
              in if "sgnl://" `T.isInfixOf` t
                 then pure (Just (T.strip t))
                 else go (n - 1)
            Left _ -> pure Nothing

-- | Read a process's stdout/stderr as 'ByteString' and wait for it. Mirrors
-- 'Seal.Vault.Backend.readProcessNoInput' (kept local to avoid a cross-
-- module dependency for one helper).
readProcessNoInput :: FilePath -> [String] -> IO (ExitCode, ByteString, ByteString)
readProcessNoInput cmdPath args =
  withCreateProcess
    ( (proc cmdPath args)
        { std_in = NoStream, std_out = CreatePipe, std_err = CreatePipe }
    ) $ \_ mOut mErr ph -> do
      (hOut, hErr) <- case (mOut, mErr) of
        (Just a, Just b) -> pure (a, b)
        _ -> error "readProcessNoInput: pipe creation failed (unreachable)"
      out <- BS.hGetContents hOut
      err <- BS.hGetContents hErr
      ec  <- waitForProcess ph
      let !_ = BS.length out
          !_ = BS.length err
      pure (ec, out, err)

decodeUtf8 :: ByteString -> Text
decodeUtf8 = decodeUtf8With lenientDecode