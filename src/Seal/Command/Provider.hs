{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The @/provider@ command group: configure, list, test, and remove model
-- provider **instances**.
--
-- A provider is a named instance of a type (issue #273): @/provider add
-- openai-compat local@ creates @[providers.local] type = "openai-compat"@.
-- Every other subcommand addresses an instance by that name, so several
-- instances of one type (two Anthropic keys, two Ollama servers, several
-- OpenAI-compatible endpoints) coexist.
--
-- Credentials live in the vault; this module never holds key bytes beyond
-- handing them to the vault or to 'mkApiKey'.
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
import Data.Maybe (fromMaybe)
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
  ( ProviderConfig (..), RuntimeConfig (..), defaultRuntimeConfig
  , deleteProviderSection, loadRuntimeConfig
  , updateRuntimeConfig, upsertProvider )
import Seal.Core.Types (ModelId (..))
import Seal.Providers.Class
  ( CompletionRequest (..), CompletionResponse (..), Role (..)
  , SomeProvider, ToolChoice (..), Usage (..), textMsg )
import Seal.Providers.Name
  ( apiKeyNameFor, checkNameForType, mkProviderName, providerNameExample
  , providerNameRule )
import Seal.Providers.Ollama (defaultOllamaBaseUrl)
import Seal.Providers.OpenAICompat (OpenAICompatSpec (..), validateBaseUrl)
import Seal.Providers.Registry
  ( ProviderCredentials (..), ProviderInstance (..), ProviderType (..)
  , completeSome, findInstance, instanceAuthStatus, instanceCredentials
  , instanceLabelList, isConfiguredInstance, legacyProviderHint
  , providerInstances
  , providerBaseUrlForInstance, providerTypeLabel, providerTypes, resolveInstance
  , resolveDefaultModelFor, typeId, vaultErrText )
import Seal.Security.Vault (VaultHandle, vhDelete, vhPut)
import Seal.Security.Vault.Age (VaultError (..))
import Seal.Session.Meta (SessionMeta (..))
import Seal.Vault.Commands (VaultRuntime (..))

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

-- | Render the outcome of @/provider test <instance>@.
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
-- every Ollama provider instance built by 'resolveInstance': Ollama responses
-- carry no tool-call ids, so Seal synthesizes @call_<i>@ and the counter must
-- outlive any single provider value.
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
    (  progDesc "Manage provider instances (credentials stored in the vault)"
    <> header   "provider — configure and test provider instances"
    )

providerParser :: ProviderRuntime -> Parser CommandAction
providerParser pr = hsubparser
  (  command "add"
       (info (addCmd pr <$> typeArg <*> optional nameArg)
             (progDesc "Create or update a provider instance (type, name, credentials)"))
  <> command "login"
       (info (loginCmd pr <$> instArg)
             (progDesc "Log in via OAuth (anthropic instances only)"))
  <> command "list"
       (info (pure (listCmd pr))
             (progDesc "List provider instances and their credential status"))
  <> command "test"
       (info (testCmd pr <$> instArg)
             (progDesc "Run a live round-trip to verify an instance works"))
  <> command "default"
       (info (defaultCmd pr <$> instArg)
             (progDesc "Set the default instance for new sessions"))
  <> command "remove"
       (info (removeCmd pr <$> instArg)
             (progDesc "Remove a provider instance's credentials"))
  <> metavar "COMMAND"
  )

typeArg :: Parser Text
typeArg = T.pack <$> strArgument
  ( metavar "TYPE"
  <> help ("Provider type (one of: " <> T.unpack (T.intercalate ", " (map typeId providerTypes))
             <> "). The name defaults to the type id; pass NAME to add another.")
  )

nameArg :: Parser Text
nameArg = T.pack <$> strArgument
  ( metavar "NAME"
  <> help ("Instance name (" <> T.unpack providerNameRule <> "), e.g. "
             <> T.unpack providerNameExample)
  )

instArg :: Parser Text
instArg = T.pack <$> strArgument
  ( metavar "NAME"
  <> help "Instance name — see /provider list"
  )

-- Shared guards -------------------------------------------------------------

withVaultHandle :: ProviderRuntime -> ChannelCaps -> (VaultHandle -> IO ()) -> IO ()
withVaultHandle pr caps k = do
  mh <- readIORef (vrHandleRef (prVault pr))
  maybe (ccSend caps "vault not configured — run /vault setup") k mh

withType :: ChannelCaps -> Text -> (ProviderType -> IO ()) -> IO ()
withType caps raw k =
  case [ t | t <- providerTypes, T.toCaseFold (T.strip raw) == T.toCaseFold (typeId t) ] of
    (t : _) -> k t
    []      -> ccSend caps (notATypeMsg raw)

-- | Run an action against the instance named @raw@, or explain why not. The
-- config is re-read each call, so a freshly added instance is visible.
withInstance :: ProviderRuntime -> ChannelCaps -> Text -> (RuntimeConfig -> ProviderInstance -> IO ()) -> IO ()
withInstance pr caps raw k = do
  eCfg <- loadRuntimeConfig (prConfigPath pr)
  let cfg = fromRight defaultRuntimeConfig eCfg
  case findInstance cfg (T.strip raw) of
    Just inst -> k cfg inst
    Nothing   -> ccSend caps (unknownInstanceMsg cfg (T.strip raw))

-- Copy ----------------------------------------------------------------------

notATypeMsg :: Text -> Text
notATypeMsg raw =
  "unknown provider type: " <> raw <> " (types: "
    <> T.intercalate ", " (map typeId providerTypes) <> ")"
    <> " — to work with an instance, run /provider list"

unknownInstanceMsg :: RuntimeConfig -> Text -> Text
unknownInstanceMsg cfg raw =
  "unknown provider: " <> raw <> " (known: " <> instanceLabelList cfg <> ")"
    <> maybe "" (" — " <>) (legacyProviderHint raw)

invalidNameMsg :: Text -> Text
invalidNameMsg reason =
  "instance names are " <> providerNameRule <> " (" <> reason <> "); e.g. "
    <> providerNameExample

nameConflictMsg :: Text -> Text -> Text
nameConflictMsg name otherType =
  "\"" <> name <> "\" already exists as a " <> otherType <> " instance — remove it"
    <> " first, or choose another name"

-- Subcommand handlers -------------------------------------------------------

-- | What the add flow asks for, derived from the **type** (never from a
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

addPlanFor :: ProviderType -> AddPlan
addPlanFor AnthropicType =
  AddPlan NoBaseUrl RequiredKey (Just (ModelId "claude-opus-4-8"))
addPlanFor OllamaType =
  AddPlan (OptionalBaseUrl defaultOllamaBaseUrl) OptionalKey (Just (ModelId "llama3.2"))
addPlanFor (OpenAICompatType spec) =
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

-- | Create (or update) an instance of @typeRaw@.
addCmd :: ProviderRuntime -> Text -> Maybe Text -> CommandAction
addCmd pr typeRaw mName = commandAction $ \caps ->
  withType caps typeRaw $ \t -> do
    let plan = addPlanFor t
        tid  = typeId t
        tLab = providerTypeLabel t
    mNameIn <- case mName of
      Just n  -> pure (Just (T.strip n))
      Nothing -> do
        raw <- ccPrompt caps (AskPrompt ("Instance name [" <> tid <> "]: ") [])
        pure $ case T.strip raw of
          s | s == cancelSentinel -> Nothing
          "" -> Just tid
          v  -> Just v
    case mNameIn of
      Nothing -> ccSend caps (abortedMsg tid)
      Just nameRaw -> case mkProviderName nameRaw of
        Left reason -> ccSend caps (invalidNameMsg reason)
        Right name -> case checkNameForType (map typeId providerTypes) name tid of
          Left _ ->
            ccSend caps ("\"" <> nameRaw <> "\" is a provider type id — choose"
                           <> " another name, e.g. " <> nameRaw <> "-personal")
          Right () -> do
            eCfg <- loadRuntimeConfig (prConfigPath pr)
            let cfg = fromRight defaultRuntimeConfig eCfg
            case findInstance cfg nameRaw of
              Just existing
                | Just otherT <- piType existing, typeId otherT /= tid ->
                    ccSend caps (nameConflictMsg nameRaw (providerTypeLabel otherT))
              existingInst -> do
                mh <- readIORef (vrHandleRef (prVault pr))
                reconfiguring <- case existingInst of
                  Just i  -> isConfiguredInstance mh cfg i
                  Nothing -> pure False
                ccSend caps ((if reconfiguring then "Updating " else "Configuring ")
                               <> nameRaw <> " (" <> tLab <> ").")
                mUrl <- case apBaseUrl plan of
                  NoBaseUrl -> pure (Just Nothing)
                  OptionalBaseUrl def -> do
                    raw <- ccPrompt caps
                             (AskPrompt (nameRaw <> " base URL [" <> def
                                          <> "] (blank = keep): ") [])
                    case T.strip raw of
                      s | s == cancelSentinel -> pure Nothing
                      "" -> pure (Just Nothing)
                      v  -> case validateBaseUrl v of
                              Left reason ->
                                ccSend caps (invalidBaseUrlCliMsg nameRaw reason)
                                  >> pure Nothing
                              Right u -> pure (Just (Just u))
                  RequiredBaseUrl -> fmap (fmap Just) (promptRequired caps
                    (nameRaw <> " base URL (full URL including the API path,"
                       <> " e.g. https://api.openai.com/v1 or http://localhost:8000/v1): ")
                    validateBaseUrl
                    (invalidBaseUrlCliMsg nameRaw))
                case mUrl of
                  Nothing -> ccSend caps (abortedMsg tid)
                  Just mUrlVal -> do
                    mModel <- case apModel plan of
                      Just m  -> pure (Just m)
                      Nothing -> promptRequired caps
                        (nameRaw <> " model id (e.g. qwen2.5-7b-instruct; for keyed"
                           <> " endpoints see your provider's docs): ")
                        (Right . ModelId)
                        id
                    case mModel of
                      Nothing -> ccSend caps (abortedMsg tid)
                      Just model -> do
                        mKey <- case apKey plan of
                          NoKey -> pure (Just "")
                          OptionalKey -> do
                            raw <- ccPromptSecret caps
                                     (nameRaw <> " API key (blank for a keyless"
                                        <> " endpoint): ")
                            pure (if T.strip raw == cancelSentinel then Nothing else Just raw)
                          RequiredKey -> promptRequiredSecret caps (nameRaw <> " API key: ")
                        case mKey of
                          Nothing -> ccSend caps (abortedMsg tid)
                          Just key -> completeAdd pr caps t nameRaw mUrlVal model key

-- | Optional cleartext warning, vault write, config write (vault first so a
-- locked vault aborts before anything is persisted), then the confirmation.
completeAdd
  :: ProviderRuntime -> ChannelCaps -> ProviderType -> Text
  -> Maybe Text -> ModelId -> Text -> IO ()
completeAdd pr caps t name mUrl model key = do
  let tid = typeId t
      keyTxt = T.strip key
  case mUrl of
    Just u | not (T.null keyTxt), not (secureOrLoopback u) ->
      ccSend caps
        (name <> " base URL is http, not https — the API key will be sent"
           <> " unencrypted (continuing)")
    _ -> pure ()
  keyRes <-
    if T.null keyTxt
      then pure (Right ())
      else do
        mh <- readIORef (vrHandleRef (prVault pr))
        case mh of
          Nothing -> pure (Left (name <> " needs an API key — run /vault setup"))
          Just vh -> do
            r <- vhPut vh (instanceKeyName t name) (TE.encodeUtf8 keyTxt)
            pure $ case r of
              Left e   -> Left (vaultErrText e)
              Right () -> Right ()
  case keyRes of
    Left e -> ccSend caps e
    Right () -> do
      _ <- updateRuntimeConfig (prConfigPath pr) (\fc ->
             let fc1 = case rcDefaultProvider fc of
                         Nothing -> fc { rcDefaultProvider = Just name }
                         Just _  -> fc
                 fc2 = upsertProvider name (\p -> p { pcType = Just tid
                                                    , pcDefaultModel = Just (modelText model) }) fc1
             in case mUrl of
                  Just u  -> upsertProvider name (\p -> p { pcBaseUrl = Just u }) fc2
                  Nothing -> fc2)
      ccSend caps (configuredMsg name t mUrl model)

-- | The vault key an instance's API key is stored under, computed without a
-- full 'ProviderInstance' (the add flow runs before the section exists).
instanceKeyName :: ProviderType -> Text -> Text
instanceKeyName t name = case mkProviderName name of
  Right n -> apiKeyNameFor (legacyKeyForType t) n (typeId t)
  Left _  -> ""   -- unreachable: the name was validated before this point

legacyKeyForType :: ProviderType -> Maybe Text
legacyKeyForType AnthropicType           = Just "ANTHROPIC_API_KEY"
legacyKeyForType OllamaType              = Just "OLLAMA_API_KEY"
legacyKeyForType (OpenAICompatType spec) = Just (ocsVaultKey spec)

-- | Is this URL safe to send a bearer token to? https anywhere, or http on
-- loopback / a private host.
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

configuredMsg :: Text -> ProviderType -> Maybe Text -> ModelId -> Text
configuredMsg name t mUrl (ModelId model) =
  "Configured " <> name <> " (" <> providerTypeLabel t
    <> maybe "" (\u -> ", " <> u <> ", model " <> model) mUrl
    <> "). Run /provider test " <> name <> " to verify."

abortedMsg :: Text -> Text
abortedMsg tid = "nothing was saved — run /provider add " <> tid <> " again"

invalidBaseUrlCliMsg :: Text -> Text -> Text
invalidBaseUrlCliMsg name reason =
  name <> " base URL is not usable (" <> reason <> ") — it must be an http(s)"
    <> " URL like https://host/v1"

-- | Set the default instance for new sessions (writes @default_provider@).
defaultCmd :: ProviderRuntime -> Text -> CommandAction
defaultCmd pr name = commandAction $ \caps ->
  withInstance pr caps name $ \cfg inst -> do
    let n = piName inst
    res <- updateRuntimeConfig (prConfigPath pr)
             (\fc -> fc { rcDefaultProvider = Just n })
    case res of
      Left e   -> ccSend caps e
      Right () -> do
        let rModel = resolveDefaultModelFor cfg n
        ccSend caps
          ("default provider set to " <> n <> case rModel of
             Just (ModelId m) -> " (model: " <> m <> ")"
             Nothing -> " (no default model — set one with /model use "
                          <> n <> " <model-id>)")

-- | List every instance (implicit, explicit and unusable) with the shared
-- status derivation and the URL Seal will actually talk to.
listCmd :: ProviderRuntime -> CommandAction
listCmd pr = commandAction $ \caps -> do
  eCfg <- loadRuntimeConfig (prConfigPath pr)
  let cfg = fromRight defaultRuntimeConfig eCfg
      def = rcDefaultProvider cfg
  mh <- readIORef (vrHandleRef (prVault pr))
  mapM_ (reportOne caps cfg def mh) (providerInstances cfg)
  where
    reportOne caps cfg def mh inst = do
      st <- instanceAuthStatus mh cfg inst
      let url = case providerBaseUrlForInstance cfg inst of
                  Right u -> u
                  Left _  -> "not set"
          mark = if Just (piName inst) == def then " (default)" else ""
          typeBit = case piType inst of
                      Just t  -> " (" <> providerTypeLabel t <> ")"
                      Nothing -> ""
          problemBit = case piProblem inst of
                         Just p  -> " — problem: " <> p
                                      <> " (fix or delete the section in config.toml)"
                         Nothing -> ""
      ccSend caps (piName inst <> typeBit <> mark <> " — auth: " <> statusLabel st
                     <> ", base URL: " <> url <> problemBit)
    statusLabel = \case
      "api-key"      -> "api-key"
      "keyless"      -> "keyless"
      "oauth"        -> "oauth"
      "vault-locked" -> "vault locked"
      _              -> "none"

-- | OAuth login flow, anthropic instances only. Prints the authorize URL,
-- best-effort opens the browser, reads the pasted CODE#STATE, exchanges it for
-- tokens, and stores them under **that instance's** OAuth key.
loginCmd :: ProviderRuntime -> Text -> CommandAction
loginCmd pr name = commandAction $ \caps ->
  withInstance pr caps name $ \_ inst -> case (piType inst, instanceCredentials inst) of
    (Just AnthropicType, Just creds) ->
      case pcOauthKeyName creds of
        Nothing -> ccSend caps (oauthUnsupportedMsg inst)
        Just oauthKey -> withVaultHandle pr caps $ \vh -> do
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
              res <- vhPut vh oauthKey (serializeTokens tokens)
              case res of
                Left e   -> ccSend caps (vaultErrText e)
                Right () -> do
                  _ <- updateRuntimeConfig (prConfigPath pr) (\fc ->
                         case rcDefaultProvider fc of
                           Nothing -> fc { rcDefaultProvider = Just (piName inst) }
                           Just _  -> fc)
                  ccSend caps ("Logged in to " <> piName inst <> " via OAuth.")
    _ -> ccSend caps (oauthUnsupportedMsg inst)

oauthUnsupportedMsg :: ProviderInstance -> Text
oauthUnsupportedMsg inst =
  "OAuth login is only supported for anthropic instances (got: "
    <> piName inst <> maybe "" (\t -> ", " <> providerTypeLabel t) (piType inst) <> ")"

-- | Best-effort browser open; failure is silently ignored (headless-friendly).
openBrowser :: Text -> IO ()
openBrowser url = do
  let opener = if os == "darwin" then "open" else "xdg-open"
  _ <- try @SomeException (callProcess opener [T.unpack url])
  pure ()

testCmd :: ProviderRuntime -> Text -> CommandAction
testCmd pr name = commandAction $ \caps ->
  withInstance pr caps name $ \cfg inst -> do
    let n = piName inst
        model = fromMaybe (ModelId "") (resolveDefaultModelFor cfg n)
    mh <- readIORef (vrHandleRef (prVault pr))
    eProv <- resolveInstance mh (prManager pr) cfg inst model (prCallCounter pr)
    case eProv of
      Left e   -> ccSend caps (formatTestResult n (Left e))
      Right sp -> do
        r <- completeSome sp (pingRequest model) :: IO (Either Text CompletionResponse)
        ccSend caps (formatTestResult n r)

-- | Remove an instance's credentials and deconfigure it. Two axes (design
-- §11.1): whether the instance has a section, and whether it has credentials at
-- all. A row with an unknown type or a problem has **no** credentials, so its
-- delete removes only the section and never touches a key it cannot name.
removeCmd :: ProviderRuntime -> Text -> CommandAction
removeCmd pr name = commandAction $ \caps ->
  withInstance pr caps name $ \_ inst -> do
    mh <- readIORef (vrHandleRef (prVault pr))
    let mCreds = instanceCredentials inst
    keyRes <- case (mh, mCreds) of
      (Just vh, Just creds) -> deleteIfPresent vh (pcApiKeyName creds)
      _                     -> pure (Right ())
    oauthRes <- case (mh, mCreds >>= pcOauthKeyName) of
      (Just vh, Just k) -> deleteIfPresent vh k
      _                 -> pure (Right ())
    case (keyRes, oauthRes) of
      (Left e, _) -> ccSend caps (vaultErrText e)
      (_, Left e) -> ccSend caps (vaultErrText e)
      _           -> do
        _ <- updateRuntimeConfig (prConfigPath pr) (deconfigure inst)
        ccSend caps (removedMsg inst)
  where
    deleteIfPresent vh k = do
      res <- vhDelete vh k
      pure $ case res of
        Left (VaultKeyNotFound _) -> Right ()
        other                     -> other
    deconfigure inst fc =
      let fc1 = if piHasSection inst then deleteProviderSection (piName inst) fc else fc
          fc2 = if rcDefaultProvider fc1 == Just (piName inst)
                  then fc1 { rcDefaultProvider = Nothing, rcDefaultModel = Nothing }
                  else fc1
      in fc2
    removedMsg inst = case (piHasSection inst, instanceCredentials inst) of
      (True, Just _) -> "Removed " <> piName inst <> "."
      (False, Just _) ->
        "Cleared the credential for " <> piName inst
          <> " — the instance stays in the list, not configured."
      (True, Nothing) ->
        "Removed the config.toml section for " <> piName inst
          <> "; any credential stored for it was left untouched (its type is"
          <> " unknown) — use /vault delete if needed."
      (False, Nothing) -> "Removed " <> piName inst <> "."

modelText :: ModelId -> Text
modelText (ModelId t) = t

-- | Resolve the active session's provider instance. Key bytes never surface:
-- 'resolveInstance' returns an opaque 'SomeProvider'. The instance's own
-- section supplies the base URL, model default and credentials.
resolveSessionProvider
  :: ProviderRuntime -> SessionMeta -> IO (Either Text (SomeProvider, ModelId))
resolveSessionProvider pr meta = do
  eCfg <- loadRuntimeConfig (prConfigPath pr)
  let cfg   = fromRight defaultRuntimeConfig eCfg
      raw   = smProvider meta
      model = ModelId (smModel meta)
  case findInstance cfg raw of
    Nothing -> pure (Left (unknownSessionProviderMsg cfg raw))
    Just inst -> do
      mh <- readIORef (vrHandleRef (prVault pr))
      fmap (fmap (, model)) (resolveInstance mh (prManager pr) cfg inst model (prCallCounter pr))

-- | Resolve a provider+model from an explicit instance name (for AGENT_START,
-- which builds a fresh AgentEnv from a def rather than the active session).
resolveDefProvider
  :: ProviderRuntime -> Text -> ModelId -> IO (Either Text (SomeProvider, ModelId))
resolveDefProvider pr name model = do
  eCfg <- loadRuntimeConfig (prConfigPath pr)
  let cfg = fromRight defaultRuntimeConfig eCfg
  case findInstance cfg name of
    Nothing -> pure (Left (unknownAgentDefProviderMsg cfg name))
    Just inst -> do
      mh <- readIORef (vrHandleRef (prVault pr))
      fmap (fmap (, model)) (resolveInstance mh (prManager pr) cfg inst model (prCallCounter pr))

-- | The "unknown provider in session" message, with rename guidance when the
-- id is a legacy one.
unknownSessionProviderMsg :: RuntimeConfig -> Text -> Text
unknownSessionProviderMsg cfg p =
  "unknown provider in session: " <> p <> " (known: " <> instanceLabelList cfg <> ")"
    <> maybe "" (" — " <>) (legacyProviderHint p)
    <> "; set a provider with /model use <instance> <model-id>, or start a new session"

-- | The "unknown provider in agent def" message, with rename guidance.
unknownAgentDefProviderMsg :: RuntimeConfig -> Text -> Text
unknownAgentDefProviderMsg cfg p =
  "unknown provider in agent def: " <> p <> " (known: " <> instanceLabelList cfg <> ")"
    <> maybe "" (" — " <>) (legacyProviderHint p)
    <> "; set the Provider field in the Agents view, or re-create it"
