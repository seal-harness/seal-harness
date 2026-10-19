{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The @/provider@ command group: configure, list, test, and remove model
-- providers. Credentials live in the vault; this module never holds key bytes
-- beyond handing them to the vault or to 'mkApiKey'.
module Seal.Command.Provider
  ( pingRequest
  , formatTestResult
  , AddPlan (..)
  , BaseUrlPrompt (..)
  , KeyPrompt (..)
  , addPlanFor
  , ProviderRuntime (..)
  , providerCommandSpec
  , resolveSessionProvider
  , resolveDefProvider
  ) where

import Control.Exception (SomeException, try)
import Data.Either (fromRight)
import Data.IORef (IORef, readIORef)
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Client (Manager)
import Options.Applicative
import System.Info (os)
import System.Process (callProcess)

import Seal.Channel.Caps (AskPrompt (..), ChannelCaps (..))
import Seal.Providers.Anthropic.OAuth
  ( buildAuthorizeUrl, exchangeCode, newPkce, parsePastedCode, serializeTokens )
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..), commandAction
  , CommandName (..), CommandSpec (..) )
import Seal.Config.File
  ( RuntimeConfig (..), ProviderConfig (..), defaultRuntimeConfig, loadRuntimeConfig
  , providerDefaultModel, updateRuntimeConfig, upsertProvider )
import Seal.Core.Types (ModelId (..))
import Seal.Providers.Class (CompletionRequest (..), CompletionResponse (..), Role (..), SomeProvider, ToolChoice (..), Usage (..), textMsg)
import Seal.Providers.Ollama (defaultOllamaBaseUrl)
import Seal.Providers.OpenAICompat (OpenAICompatSpec (..), validateBaseUrl)
import Seal.Providers.Registry
  ( KnownProvider (..), completeSome, defaultModelFor, knownLabelList
  , knownProviders, legacyProviderHint, parseProvider, providerAuthStatus
  , providerBaseUrlFor, providerDisplayName, providerLabel, resolveDefaultModel
  , resolveProvider, vaultErrText, vaultKeyName )
import Seal.Security.Vault (VaultHandle, vhDelete, vhPut)
import Seal.Security.Vault.Age (VaultError (..))
import Seal.Session.Meta (SessionMeta (..))
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
-- The @prCallCounter@ is a process-lifetime monotonic counter shared across
-- every Ollama provider instance built by 'Seal.Providers.Registry.resolveProvider'.
-- Ollama tool-call responses carry no id, so Seal synthesizes @call_<i>@;
-- the counter must outlive any single 'Ollama' value (which is rebuilt each
-- turn) so ids stay unique across a whole session.
data ProviderRuntime = ProviderRuntime
  { prConfigPath  :: FilePath
  , prVault       :: VaultRuntime
  , prManager     :: Manager
  , prCallCounter :: IORef Int
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
  <> command "default"
       (info (defaultCmd pr <$> provArg)
             (progDesc "Set the default provider for new sessions"))
  <> command "remove"
       (info (removeCmd pr <$> provArg)
             (progDesc "Remove a provider's stored credential"))
  <> metavar "COMMAND"
  )

provArg :: Parser Text
provArg = T.pack <$> strArgument
  ( metavar "PROVIDER"
  <> help ("Provider id (one of: " <> T.unpack (T.intercalate ", " (map providerLabel knownProviders)) <> ")")
  )

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

-- | Seed the default provider (if unset) and, only if that provider's
-- section has no default model yet, seed its @[providers.<label>]@
-- @default_model@. Never touches the global @default_model@ key, so a
-- later @/model default@ isn't shadowed by a stale global value.
seedProviderDefaults :: KnownProvider -> RuntimeConfig -> RuntimeConfig
seedProviderDefaults kp fc0 =
  let fc1 = fc0 { rcDefaultProvider = rcDefaultProvider fc0 <|> Just (providerLabel kp) }
      lbl = providerLabel kp
  in if isJust (providerDefaultModel fc1 lbl)
       then fc1
       else case defaultModelFor kp of
              -- The generic row has no default model: never seed an empty one.
              Nothing -> fc1
              Just m  -> upsertProvider lbl (\p -> p { pcDefaultModel = Just (modelText m) }) fc1

-- | What the add flow asks for, derived from the provider (never from a
-- hardcoded id). Exported for tests.
data BaseUrlPrompt
  = NoBaseUrl                 -- ^ the endpoint is fixed (anthropic, presets)
  | OptionalBaseUrl Text      -- ^ a default is offered (ollama)
  | RequiredBaseUrl           -- ^ the user must supply one (generic family)
  deriving stock (Eq, Show)

data KeyPrompt = NoKey | OptionalKey | RequiredKey
  deriving stock (Eq, Show)

data AddPlan = AddPlan
  { apBaseUrl :: BaseUrlPrompt
  , apKey     :: KeyPrompt
  , apModel   :: Maybe ModelId   -- ^ 'Just' ⇒ built in, 'Nothing' ⇒ prompt
  } deriving stock (Eq, Show)

-- | The add-flow plan for a provider. Further OpenAI-compatible vendors need
-- no change here: their row supplies the key policy and model.
addPlanFor :: KnownProvider -> AddPlan
addPlanFor AnthropicProvider =
  AddPlan NoBaseUrl RequiredKey (defaultModelFor AnthropicProvider)
addPlanFor OllamaProvider =
  AddPlan (OptionalBaseUrl defaultOllamaBaseUrl) OptionalKey (defaultModelFor OllamaProvider)
addPlanFor (OpenAICompatProvider spec) =
  AddPlan (maybe RequiredBaseUrl (const NoBaseUrl) (ocsBuiltinBaseUrl spec))
          (if ocsKeyRequired spec then RequiredKey else OptionalKey)
          (ocsDefaultModel spec)

-- | The web channel's cancel sentinel (a typed "cancel" button).
cancelSentinel :: Text
cancelSentinel = "rejected"

-- | Prompt until a valid value arrives (max 3 tries), then 'Nothing'. A blank
-- answer or the cancel sentinel never becomes a stored value.
promptRequired
  :: ChannelCaps -> Text -> (Text -> Either Text a) -> (Text -> Text) -> IO (Maybe a)
promptRequired caps label parse onError = go (3 :: Int)
  where
    go 0 = pure Nothing
    go n = do
      raw <- ccPrompt caps (AskPrompt label [])
      case T.strip raw of
        s | s == cancelSentinel -> pure Nothing
        "" -> go (n - 1)
        v  -> case parse v of
                Left reason -> ccSend caps (onError reason) >> go (n - 1)
                Right x     -> pure (Just x)

-- | Prompt for a required secret (max 3 tries). The value never echoes.
promptRequiredSecret :: ChannelCaps -> Text -> IO (Maybe Text)
promptRequiredSecret caps label = go (3 :: Int)
  where
    go 0 = pure Nothing
    go n = do
      raw <- ccPromptSecret caps label
      let v = T.strip raw
      if T.null v || v == cancelSentinel then go (n - 1) else pure (Just v)

-- | Store-then-configure. The vault is only touched when a non-empty key is
-- actually being stored, so a keyless local endpoint needs no vault at all.
addCmd :: ProviderRuntime -> Text -> CommandAction
addCmd pr lbl = commandAction $ \caps ->
  withProvider caps lbl $ \kp -> do
    let plan = addPlanFor kp
        nm   = providerDisplayName kp
    mUrl <- case apBaseUrl plan of
      NoBaseUrl -> pure (Just Nothing)
      OptionalBaseUrl def -> do
        raw <- ccPrompt caps
                 (AskPrompt (nm <> " base URL [" <> def <> "] (blank = keep): ") [])
        case T.strip raw of
          s | s == cancelSentinel -> pure Nothing
          "" -> pure (Just Nothing)          -- keep whatever is configured
          v  -> case validateBaseUrl v of
                  Left reason -> ccSend caps (invalidBaseUrlCliMsg kp reason) >> pure Nothing
                  Right u     -> pure (Just (Just u))
      RequiredBaseUrl -> do
        r <- promptRequired caps
               (nm <> " base URL (full URL including the API path, e.g. https://host/v1): ")
               validateBaseUrl
               (invalidBaseUrlCliMsg kp)
        pure (fmap Just r)
    case mUrl of
      Nothing -> ccSend caps (abortedMsg kp)
      Just mUrlVal -> do
        mModel <- case apModel plan of
          Just m  -> pure (Just m)
          Nothing -> promptRequired caps
            (nm <> " model id (e.g. qwen2.5-7b-instruct; for keyed endpoints see"
               <> " your provider's docs): ")
            (Right . ModelId)
            id
        case mModel of
          Nothing -> ccSend caps (abortedMsg kp)
          Just model -> do
            mKey <- case apKey plan of
              NoKey -> pure (Just "")
              OptionalKey -> do
                raw <- ccPromptSecret caps
                         (nm <> " API key (blank for a keyless endpoint): ")
                pure (if T.strip raw == cancelSentinel then Nothing else Just raw)
              RequiredKey -> promptRequiredSecret caps (nm <> " API key: ")
            case mKey of
              Nothing -> ccSend caps (abortedMsg kp)
              Just key -> completeAdd pr caps kp mUrlVal model key

-- | The tail of the add flow: optional cleartext warning, vault write, config
-- write (vault first, so a locked vault aborts before anything is persisted),
-- then the confirmation.
completeAdd
  :: ProviderRuntime -> ChannelCaps -> KnownProvider
  -> Maybe Text -> ModelId -> Text -> IO ()
completeAdd pr caps kp mUrl model key = do
  let nm = providerDisplayName kp
      keyTxt = T.strip key
  case mUrl of
    Just u | not (T.null keyTxt), not (secureOrLoopback u) ->
      ccSend caps
        (nm <> " base URL is http, not https — the API key will be sent"
           <> " unencrypted (continuing)")
    _ -> pure ()
  keyRes <-
    if T.null keyTxt
      then pure (Right ())
      else do
        mh <- readIORef (vrHandleRef (prVault pr))
        case mh of
          Nothing -> pure (Left (nm <> " needs an API key — run /vault setup"))
          Just vh -> do
            r <- vhPut vh (vaultKeyName kp) (TE.encodeUtf8 keyTxt)
            pure $ case r of
              Left e   -> Left (vaultErrText e)
              Right () -> Right ()
  case keyRes of
    Left e -> ccSend caps e
    Right () -> do
      _ <- updateRuntimeConfig (prConfigPath pr) (\fc ->
             let fc1 = seedProviderDefaults kp fc
                 fc2 = seedModel kp model fc1
             in case mUrl of
                  Just u  -> upsertProvider (providerLabel kp)
                               (\p -> p { pcBaseUrl = Just u }) fc2
                  Nothing -> fc2)
      ccSend caps (configuredMsg kp mUrl model)

-- | Seed the provider's @default_model@ (a user-supplied model always wins).
seedModel :: KnownProvider -> ModelId -> RuntimeConfig -> RuntimeConfig
seedModel kp model =
  upsertProvider (providerLabel kp) (\p -> p { pcDefaultModel = Just (modelText model) })

-- | Should a URL be treated as safe for a bearer token? https anywhere, or
-- http on loopback / a private host.
secureOrLoopback :: Text -> Bool
secureOrLoopback u
  | "https://" `T.isPrefixOf` u = True
  | "http://" `T.isPrefixOf` u =
      let host = T.takeWhile (\c -> c /= '/' && c /= ':') (T.drop 7 u)
      in host == "localhost"
           || "127." `T.isPrefixOf` host
           || host == "[::1]"
           || "192.168." `T.isPrefixOf` host
           || "10." `T.isPrefixOf` host
  | otherwise = False

configuredMsg :: KnownProvider -> Maybe Text -> ModelId -> Text
configuredMsg kp mUrl (ModelId model) =
  "Configured " <> providerLabel kp
    <> maybe "" (\u -> " (" <> u <> ", model " <> model <> ")") mUrl
    <> ". Run /provider test " <> providerLabel kp <> " to verify."

abortedMsg :: KnownProvider -> Text
abortedMsg kp = "nothing was saved — run /provider add " <> providerLabel kp <> " again"

invalidBaseUrlCliMsg :: KnownProvider -> Text -> Text
invalidBaseUrlCliMsg kp reason =
  providerDisplayName kp <> " base URL is not usable (" <> reason <> ") — it must"
    <> " be an http(s) URL like https://host/v1"

-- | Set the default provider for new sessions (writes @default_provider@).
-- Only a valid provider label is accepted; no credential or vault is required,
-- so a keyless local provider can be made the default before any key exists.
-- Unlike the @<|>@ seeding on @/provider add@, this reassigns an existing
-- default. The confirmation echoes the provider's resolved default model so it
-- is clear what new sessions will start with.
defaultCmd :: ProviderRuntime -> Text -> CommandAction
defaultCmd pr lbl = commandAction $ \caps ->
  withProvider caps lbl $ \kp -> do
    let plabel = providerLabel kp
    res <- updateRuntimeConfig (prConfigPath pr)
             (\fc -> fc { rcDefaultProvider = Just plabel })
    case res of
      Left e   -> ccSend caps e
      Right () -> do
        eCfg <- loadRuntimeConfig (prConfigPath pr)
        let rModel = resolveDefaultModel
                       (either (const Nothing) (`providerDefaultModel` plabel) eCfg)
                       plabel
        ccSend caps
          ("default provider set to " <> plabel <> case rModel of
             Just (ModelId m) -> " (model: " <> m <> ")"
             Nothing -> " (no default model — set one with /model use "
                          <> plabel <> " <model-id>)")

-- | List every known provider with the shared status derivation (the same one
-- the gateway uses) and the URL Seal will actually talk to.
listCmd :: ProviderRuntime -> CommandAction
listCmd pr = commandAction $ \caps -> do
  eCfg <- loadRuntimeConfig (prConfigPath pr)
  let cfg = fromRight defaultRuntimeConfig eCfg
      def = rcDefaultProvider cfg
  mh <- readIORef (vrHandleRef (prVault pr))
  mapM_ (reportOne caps cfg def mh) knownProviders
  where
    reportOne caps cfg def mh kp = do
      st <- providerAuthStatus mh cfg kp
      let url = case providerBaseUrlFor cfg kp of
                  Right u -> u
                  Left _  -> "not set"
          mark = if Just (providerLabel kp) == def then " (default)" else ""
      ccSend caps (providerLabel kp <> mark <> " — auth: " <> statusLabel st
                     <> ", base URL: " <> url)
    statusLabel = \case
      "api-key"      -> "api-key"
      "keyless"      -> "keyless"
      "oauth"        -> "oauth"
      "vault-locked" -> "vault locked"
      _              -> "none"

-- | OAuth login flow. Anthropic-only for this milestone. Prints the authorize
-- URL, best-effort opens the browser, reads the pasted CODE#STATE, exchanges
-- it for tokens, and stores them in the vault. Tokens are never echoed.
-- | OAuth login flow. Anthropic-only for this milestone. Prints the authorize
-- URL, best-effort opens the browser, reads the pasted CODE#STATE, exchanges
-- it for tokens, and stores them in the vault. Tokens are never echoed.
loginCmd :: ProviderRuntime -> Text -> CommandAction
loginCmd pr lbl = commandAction $ \caps ->
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
        pasted <- ccPrompt caps (AskPrompt "code: " [])
        let (code, state) = parsePastedCode pasted
        eTokens <- exchangeCode (prManager pr) pkce code state
        case eTokens of
          Left e       -> ccSend caps ("login failed: " <> e)
          Right tokens -> do
            res <- vhPut vh anthropicOAuthKey (serializeTokens tokens)
            case res of
              Left e   -> ccSend caps (vaultErrText e)
              Right () -> do
                _ <- updateRuntimeConfig (prConfigPath pr) (seedProviderDefaults kp)
                ccSend caps ("Logged in to " <> providerLabel kp <> " via OAuth.")

-- | Best-effort browser open; failure is silently ignored (headless-friendly).
openBrowser :: Text -> IO ()
openBrowser url = do
  let opener = if os == "darwin" then "open" else "xdg-open"
  _ <- try @SomeException (callProcess opener [T.unpack url])
  pure ()

testCmd :: ProviderRuntime -> Text -> CommandAction
testCmd pr lbl = commandAction $ \caps ->
  withProvider caps lbl $ \kp -> do
    eCfg <- loadRuntimeConfig (prConfigPath pr)
    let cfg     = fromRight defaultRuntimeConfig eCfg
        canonLbl = providerLabel kp
        model = fromMaybe (ModelId "") $ case eCfg of
          Right c -> resolveDefaultModel (providerDefaultModel c canonLbl) canonLbl
          Left _  -> defaultModelFor kp
    mh <- readIORef (vrHandleRef (prVault pr))
    eProv <- resolveProvider mh (prManager pr) cfg kp model (prCallCounter pr)
    case eProv of
      Left e   -> ccSend caps (formatTestResult (providerLabel kp) (Left e))
      Right sp -> do
        r <- completeSome sp (pingRequest model) :: IO (Either Text CompletionResponse)
        ccSend caps (formatTestResult (providerLabel kp) r)

-- | Remove a provider's credential(s) and deconfigure it: the vault key (when
-- there is one), the Anthropic OAuth blob (anthropic only — never for another
-- provider), a family row's base URL (so a keyless provider can actually be
-- removed), and the default pointers when it was the default. Works with no
-- vault configured.
removeCmd :: ProviderRuntime -> Text -> CommandAction
removeCmd pr lbl = commandAction $ \caps ->
  withProvider caps lbl $ \kp -> do
    mh <- readIORef (vrHandleRef (prVault pr))
    keyRes <- case mh of
      Nothing -> pure (Right ())
      Just vh -> deleteIfPresent vh (vaultKeyName kp)
    oauthRes <- case (mh, kp) of
      (Just vh, AnthropicProvider) -> deleteIfPresent vh anthropicOAuthKey
      _                            -> pure (Right ())
    case (keyRes, oauthRes) of
      (Left e, _) -> ccSend caps (vaultErrText e)
      (_, Left e) -> ccSend caps (vaultErrText e)
      _           -> do
        _ <- updateRuntimeConfig (prConfigPath pr) (deconfigure kp)
        ccSend caps ("Removed " <> providerDisplayName kp <> ".")
  where
    -- | Delete a key; a missing key is not an error.
    deleteIfPresent vh k = do
      res <- vhDelete vh k
      pure $ case res of
        Left (VaultKeyNotFound _) -> Right ()
        other                     -> other
    deconfigure kp fc =
      let fc1 = case kp of
                  OpenAICompatProvider spec | isNothing (ocsBuiltinBaseUrl spec) ->
                    upsertProvider (providerLabel kp) (\p -> p { pcBaseUrl = Nothing }) fc
                  _ -> fc
          fc2 = if rcDefaultProvider fc1 == Just (providerLabel kp)
                  then fc1 { rcDefaultProvider = Nothing, rcDefaultModel = Nothing }
                  else fc1
      in fc2

modelText :: ModelId -> Text
modelText (ModelId t) = t

-- | Resolve the active session's provider from the vault, or explain why
-- not. Key bytes never surface: 'resolveProvider' returns an opaque
-- 'SomeProvider'. Reads the session's 'smProvider'/'smModel'; the base URL is
-- resolved per-provider inside 'resolveProvider' from the runtime config (each
-- provider reads its OWN @[providers.&lt;label&gt;]@ section).
resolveSessionProvider
  :: ProviderRuntime -> SessionMeta -> IO (Either Text (SomeProvider, ModelId))
resolveSessionProvider pr meta =
  case parseProvider (smProvider meta) of
    Nothing -> pure (Left (unknownSessionProviderMsg (smProvider meta)))
    Just kp -> do
      eCfg <- loadRuntimeConfig (prConfigPath pr)
      let cfg   = fromRight defaultRuntimeConfig eCfg
          model = ModelId (smModel meta)
      mh <- readIORef (vrHandleRef (prVault pr))
      fmap (fmap (, model)) (resolveProvider mh (prManager pr) cfg kp model (prCallCounter pr))

-- | Resolve a provider+model from explicit labels (for AGENT_START, which
-- builds a fresh AgentEnv from a def rather than the active session).
resolveDefProvider
  :: ProviderRuntime -> Text -> ModelId -> IO (Either Text (SomeProvider, ModelId))
resolveDefProvider pr providerLabel' model =
  case parseProvider providerLabel' of
    Nothing -> pure (Left (unknownAgentDefProviderMsg providerLabel'))
    Just kp -> do
      eCfg <- loadRuntimeConfig (prConfigPath pr)
      let cfg = fromRight defaultRuntimeConfig eCfg
      mh <- readIORef (vrHandleRef (prVault pr))
      fmap (fmap (, model)) (resolveProvider mh (prManager pr) cfg kp model (prCallCounter pr))

-- | The "unknown provider in session" message, with rename guidance when the
-- id is a legacy one.
unknownSessionProviderMsg :: Text -> Text
unknownSessionProviderMsg p = case legacyProviderHint p of
  Just h  -> "unknown provider in session: " <> p <> " \x2014 " <> h
               <> "; first run /provider add openai-compat, then /model use"
               <> " openai-compat <model-id>"
  Nothing -> "unknown provider in session: " <> p <> " (known: " <> knownLabelList <> ")"

-- | The "unknown provider in agent def" message, with rename guidance.
unknownAgentDefProviderMsg :: Text -> Text
unknownAgentDefProviderMsg p = case legacyProviderHint p of
  Just h  -> "unknown provider in agent def: " <> p <> " \x2014 " <> h
               <> "; edit the def's provider line to openai-compat"
  Nothing -> "unknown provider in agent def: " <> p <> " (known: " <> knownLabelList <> ")"
