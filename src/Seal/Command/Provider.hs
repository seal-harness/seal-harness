{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The @/provider@ command group: configure, list, test, and remove model
-- providers. Credentials live in the vault; this module never holds key bytes
-- beyond handing them to the vault or to 'mkApiKey'.
module Seal.Command.Provider
  ( pingRequest
  , formatTestResult
  , ProviderRuntime (..)
  , providerCommandSpec
  ) where

import Control.Exception (SomeException, try)
import Data.IORef (readIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Client (Manager)
import Options.Applicative
import System.Info (os)
import System.Process.Typed (ExitCode (..), proc, runProcess)

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Providers.Anthropic.OAuth
  ( buildAuthorizeUrl, exchangeCode, newPkce, parsePastedCode, serializeTokens )
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..)
  , CommandName (..), CommandSpec (..) )
import Seal.Config.File
  ( FileConfig (..), loadFileConfig, updateFileConfig )
import Seal.Core.Types (ModelId (..))
import Seal.Providers.Class (CompletionRequest (..), CompletionResponse (..), Role (..), ToolChoice (..), Usage (..), textMsg)
import Seal.Providers.Ollama (defaultOllamaBaseUrl)
import Seal.Providers.Registry
  ( KnownProvider, completeSome, defaultModelFor, knownProviders
  , parseProvider, providerLabel, resolveProvider, vaultErrText, vaultKeyName )
import Seal.Security.Vault (VaultHandle, vhDelete, vhGet, vhPut)
import Seal.Security.Vault.Age (VaultError (..))
import Seal.Vault.Commands (VaultRuntime (..))

-- | The vault key under which Anthropic OAuth tokens are stored.
-- Kept local so this module needs no registry dep beyond the label vocabulary
-- it already imports.
anthropicOAuthKey :: Text
anthropicOAuthKey = "ANTHROPIC_OAUTH_TOKENS"

-- | A minimal completion used to prove a provider responds.
pingRequest :: ModelId -> CompletionRequest
pingRequest m = CompletionRequest
  { crModel      = m
  , crSystem     = Nothing
  , crMessages   = [textMsg User "ping"]
  , crTools      = []
  , crToolChoice = ToolNone
  , crMaxTokens  = 16
  }

-- | Render the outcome of @/provider test@ for a provider labelled @label@.
formatTestResult :: Text -> Either Text CompletionResponse -> Text
formatTestResult label = \case
  Left e  -> label <> " test FAILED: " <> e
  Right r ->
    label <> " OK — model responded ("
      <> T.pack (show (uOutput (rsUsage r))) <> " output tokens, stop="
      <> T.pack (show (rsStop r)) <> ")"

-- | Everything the @/provider@ handlers need: where config lives, the vault
-- (for credentials), and an HTTP manager (for the live @test@ round-trip).
data ProviderRuntime = ProviderRuntime
  { prConfigPath :: FilePath
  , prVault      :: VaultRuntime
  , prManager    :: Manager
  }

providerCommandSpec :: ProviderRuntime -> CommandSpec
providerCommandSpec pr = CommandSpec
  { csName         = CommandName "provider"
  , csAliases      = []
  , csGroup        = GroupProvider
  , csSynopsis     = "Configure and test model providers"
  , csParserInfo   = providerParserInfo pr
  , csAvailability = InteractiveOnly
  }

providerParserInfo :: ProviderRuntime -> ParserInfo CommandAction
providerParserInfo pr =
  info (providerParser pr <**> helper)
    (  progDesc "Manage model providers (API keys stored in the vault)"
    <> header   "provider — configure and test model providers"
    )

providerParser :: ProviderRuntime -> Parser CommandAction
providerParser pr = hsubparser
  (  command "add"
       (info (addCmd pr <$> provArg)
             (progDesc "Store a provider API key (hidden prompt) in the vault"))
  <> command "login"
       (info (loginCmd pr <$> provArg)
             (progDesc "Log in via OAuth (Claude subscription) and store tokens"))
  <> command "list"
       (info (pure (listCmd pr))
             (progDesc "List known providers and their credential status"))
  <> command "test"
       (info (testCmd pr <$> provArg)
             (progDesc "Run a live round-trip to verify a provider works"))
  <> command "remove"
       (info (removeCmd pr <$> provArg)
             (progDesc "Remove a provider's stored credential"))
  <> metavar "COMMAND"
  )

provArg :: Parser Text
provArg = T.pack <$> strArgument (metavar "PROVIDER" <> help "Provider id (e.g. anthropic)")

-- Shared guards -------------------------------------------------------------

withVaultHandle :: ProviderRuntime -> ChannelCaps -> (VaultHandle -> IO ()) -> IO ()
withVaultHandle pr caps k = do
  mh <- readIORef (vrHandleRef (prVault pr))
  maybe (ccSend caps "vault not configured — run /vault setup") k mh

withProvider :: ChannelCaps -> Text -> (KnownProvider -> IO ()) -> IO ()
withProvider caps lbl k =
  maybe (ccSend caps (unknownProviderMsg lbl)) k (parseProvider lbl)

unknownProviderMsg :: Text -> Text
unknownProviderMsg lbl =
  "unknown provider: " <> lbl <> " (known: "
    <> T.intercalate ", " (map providerLabel knownProviders) <> ")"

-- Subcommand handlers -------------------------------------------------------

addCmd :: ProviderRuntime -> Text -> CommandAction
addCmd pr lbl = CommandAction $ \caps ->
  withProvider caps lbl $ \kp ->
    withVaultHandle pr caps $ \vh -> do
      val <- ccPromptSecret caps ("API key for " <> providerLabel kp <> ": ")
      res <- vhPut vh (vaultKeyName kp) (TE.encodeUtf8 val)
      case res of
        Left e   -> ccSend caps (vaultErrText e)
        Right () -> do
          _ <- updateFileConfig (prConfigPath pr) (seedDefaults kp)
          ccSend caps ("Stored API key for " <> providerLabel kp <> ".")
  where
    seedDefaults kp fc = fc
      { fcDefaultProvider = fcDefaultProvider fc <|> Just (providerLabel kp)
      , fcDefaultModel    = fcDefaultModel fc    <|> Just (modelText (defaultModelFor kp))
      }

listCmd :: ProviderRuntime -> CommandAction
listCmd pr = CommandAction $ \caps ->
  withVaultHandle pr caps $ \vh -> do
    eCfg <- loadFileConfig (prConfigPath pr)
    let def = either (const Nothing) fcDefaultProvider eCfg
    mapM_ (reportOne caps vh def) knownProviders
  where
    reportOne caps vh def kp = do
      eOAuth <- vhGet vh anthropicOAuthKey
      eKey   <- vhGet vh (vaultKeyName kp)
      let auth = case (eOAuth, eKey) of
            (Right _, _)          -> "auth: oauth"
            (_, Right _)          -> "auth: api-key"
            (Left VaultLocked, _) -> "auth: (vault locked)"
            _                     -> "auth: none"
          mark = if Just (providerLabel kp) == def then " (default)" else ""
      ccSend caps (providerLabel kp <> mark <> " — " <> auth)

-- | OAuth login flow. Anthropic-only for this milestone. Prints the authorize
-- URL, best-effort opens the browser, reads the pasted CODE#STATE, exchanges
-- it for tokens, and stores them in the vault. Tokens are never echoed.
loginCmd :: ProviderRuntime -> Text -> CommandAction
loginCmd pr lbl = CommandAction $ \caps ->
  withProvider caps lbl $ \kp ->
    if providerLabel kp /= "anthropic"
      then ccSend caps
             ("OAuth login is only supported for anthropic (got: " <> providerLabel kp <> ")")
      else withVaultHandle pr caps $ \vh -> do
        pkce <- newPkce
        let url = buildAuthorizeUrl pkce
        ccSend caps "Open this URL, approve access, then paste the code shown:"
        ccSend caps url
        openBrowser url
        pasted <- ccPrompt caps "code: "
        let (code, state) = parsePastedCode pasted
        eTokens <- exchangeCode (prManager pr) pkce code state
        case eTokens of
          Left e       -> ccSend caps ("login failed: " <> e)
          Right tokens -> do
            res <- vhPut vh anthropicOAuthKey (serializeTokens tokens)
            case res of
              Left e   -> ccSend caps (vaultErrText e)
              Right () -> do
                _ <- updateFileConfig (prConfigPath pr) (seedDefaults kp)
                ccSend caps ("Logged in to " <> providerLabel kp <> " via OAuth.")
  where
    seedDefaults kp fc = fc
      { fcDefaultProvider = fcDefaultProvider fc <|> Just (providerLabel kp)
      , fcDefaultModel    = fcDefaultModel fc    <|> Just (modelText (defaultModelFor kp))
      }

-- | Best-effort browser open; failure is silently ignored (headless-friendly).
openBrowser :: Text -> IO ()
openBrowser url = do
  let opener = if os == "darwin" then "open" else "xdg-open"
  _ <- try (runProcess (proc opener [T.unpack url]))
         :: IO (Either SomeException ExitCode)
  pure ()

testCmd :: ProviderRuntime -> Text -> CommandAction
testCmd pr lbl = CommandAction $ \caps ->
  withProvider caps lbl $ \kp ->
    withVaultHandle pr caps $ \vh -> do
      eCfg <- loadFileConfig (prConfigPath pr)
      let model = case eCfg of
            Right c | Just m <- fcDefaultModel c -> ModelId m
            _                                    -> defaultModelFor kp
          baseUrl = fromMaybe defaultOllamaBaseUrl
                      (either (const Nothing) fcOllamaBaseUrl eCfg)
      eProv <- resolveProvider vh (prManager pr) baseUrl kp model
      case eProv of
        Left e   -> ccSend caps (formatTestResult (providerLabel kp) (Left e))
        Right sp -> do
          r <- completeSome sp (pingRequest model) :: IO (Either Text CompletionResponse)
          ccSend caps (formatTestResult (providerLabel kp) r)

removeCmd :: ProviderRuntime -> Text -> CommandAction
removeCmd pr lbl = CommandAction $ \caps ->
  withProvider caps lbl $ \kp ->
    withVaultHandle pr caps $ \vh -> do
      r1 <- deleteIfPresent vh (vaultKeyName kp)
      r2 <- deleteIfPresent vh anthropicOAuthKey
      case (r1, r2) of
        (Left e, _) -> ccSend caps (vaultErrText e)
        (_, Left e) -> ccSend caps (vaultErrText e)
        _           -> do
          _ <- updateFileConfig (prConfigPath pr) (clearDefault kp)
          ccSend caps ("Removed credentials for " <> providerLabel kp <> ".")
  where
    -- | Delete a key; a missing key is not an error.
    deleteIfPresent vh k = do
      res <- vhDelete vh k
      pure $ case res of
        Left (VaultKeyNotFound _) -> Right ()
        other                     -> other
    clearDefault kp fc
      | fcDefaultProvider fc == Just (providerLabel kp) =
          fc { fcDefaultProvider = Nothing, fcDefaultModel = Nothing }
      | otherwise = fc

modelText :: ModelId -> Text
modelText (ModelId t) = t
