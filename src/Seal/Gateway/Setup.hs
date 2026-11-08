{-# LANGUAGE OverloadedStrings #-}
-- | The setup endpoints: status, vault creation, vault reopen, and the
-- provider Test-connection ping.
--
-- == Trust boundary (read this before changing anything here)
--
-- These are human-driven admin endpoints on the local control plane, in the
-- same class as @\/vault setup@ and @POST \/api\/secrets@. They add no opcode,
-- no 'UntrustedIO', and no ISA path. Two protections apply, both already in
-- place before this module is reached:
--
-- * the mutation origin guard in 'Seal.Gateway.API.apiApp' (cross-origin
--   requests are refused before dispatch, so a hostile page cannot drive a
--   vault creation);
-- * the passkey middleware in "Seal.Gateway.AccessControl", which is
--   default-deny — every route here answers @403 access_control_required@
--   until access control is configured, and @401@ without a session or
--   service token.
--
-- Residual classes, stated rather than hidden: holders of the per-run service
-- token, an explicit @mode = "none"@ waiver, and same-UID local processes.
-- The last is not a widening: such a process can already write
-- @~\/.seal\/security.toml@ or run @\/vault setup@ in @seal tui@.
--
-- Nothing here ever returns key material. Creation and reopen responses carry
-- the public recipient and the key-type label; errors carry a fixed reason and
-- an actionable hint ('Seal.Vault.Provision.renderProvisionError').
--
-- This module never imports 'Seal.Gateway.API' (that module imports this one),
-- so the helpers and handlers are self-contained.
module Seal.Gateway.Setup
  ( maxSetupBodyBytes
  , collectBodyLimited
  , setupJson
  , setupJsonNoStore
  , setupErr
  , SetupDeps (..)
  , stubSetupDeps
  , SetupEnv (..)
  , handleSetupState
  , handleVaultCreate
  , handleVaultReopen
  , handleProviderTest
  ) where

import Control.Monad (void, when)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.CaseInsensitive qualified as CI
import Data.IORef (IORef, readIORef, writeIORef)
import Data.Either (fromRight)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Types
  ( Header, HeaderName, Status, hContentType, status200, status201, status400
  , status409, status413, status415, status422, status500 )
import Network.Wai (Request, Response, getRequestBodyChunk, requestHeaders, responseLBS)
import System.Directory (doesFileExist)
import System.FilePath (takeDirectory)

import Seal.Config.File
  ( RuntimeConfig (..), defaultRuntimeConfig, loadRuntimeConfig
  , providerDefaultModel )
import Seal.Config.Paths (SealPaths (..), vaultFilePath)
import Seal.Config.Security
  ( SecurityConfig (..), defaultSecurityConfig, loadSecurityConfig )
import Seal.Core.Types (ModelId (..))
import Seal.Providers.Class (SomeProvider)
import Seal.Providers.Registry
  ( KnownProvider, defaultModelFor, parseProvider, providerLabel )
import Seal.Security.Vault
  ( UnlockMode (UnlockStartup), VaultConfig (..), VaultHandle (..), openVault )
import Seal.Security.Vault.Age
  ( AgeIdentity (..), AgeRecipient (..), VaultError (..) )
import Seal.Setup.State
  ( ProviderCard (..), SetupInputs (..), SetupState (..), SetupStep (..)
  , StepStatus (..), deriveSetupState )
import Seal.Vault.Backend (parseUnlockMode)
import Seal.Vault.Provision
  ( ProvisionDeps (..), ProvisionError (..), ProvisionOutcome (..)
  , SetupEncryptor (..), SetupKeygen (..), parseVaultSpec, provisionVault
  , renderProvisionError, withSetupLock )

-- | The setup endpoints' injected dependencies.
--
-- Two seams, both injected rather than imported so the handlers stay testable
-- and so "Test connection" pings what is on disk now, not what was there at
-- boot: the provisioning core (which shells out to @age-keygen@ /
-- @age-plugin-yubikey@ / @age@) and the provider resolver (which needs a
-- 'Network.HTTP.Client.Manager' and a vault handle).
data SetupDeps = SetupDeps
  { sdProvision       :: ProvisionDeps
  , sdResolveProvider :: KnownProvider -> ModelId -> IO (Either Text SomeProvider)
    -- ^ Re-reads @config.toml@ and the vault handle on every call, so a
    -- provider saved during setup (including a new ollama base URL) is what
    -- "Test connection" actually pings.
  }

-- | Everything the handlers need from the running gateway. Built at the
-- dispatch site from 'Seal.Gateway.API.ApiDeps'.
data SetupEnv = SetupEnv
  { sePaths        :: SealPaths
  , seHandleRef    :: IORef (Maybe VaultHandle)
    -- ^ The vault runtime's ref. Never 'VaultRuntime.vrPaths' — that field is
    -- a test stub, and the state model needs the real 'SealPaths'.
  , seConfigPath   :: FilePath
  , seSecurityPath :: FilePath
  , seProviders    :: IO [KnownProvider]
  , seDeps         :: SetupDeps
  }

-- | Inert dependencies for the 'ApiDeps' literals in tests that do not
-- exercise the setup endpoints. Every seam fails closed with a message that
-- names the stub, so a test that accidentally reaches one says so.
stubSetupDeps :: SetupDeps
stubSetupDeps = SetupDeps
  { sdProvision = ProvisionDeps
      { pdKeygen = SetupKeygen
          { skLocal = pure (Left stubError)
          , skYubi  = \_ _ _ -> pure (Left stubError)
          , skUser  = \_ _ -> Left "stub setup deps"
          }
      , pdEncryptor = SetupEncryptor
          { seMk     = \_ _ -> pure (Left (VaultBackendError "stub setup deps"))
          , seVerify = \_ -> pure (Left "stub setup deps")
          }
      , pdWriteConfig = \_ -> pure (Left "stub setup deps")
      -- A path that cannot exist: a stub must never take a real setup lock.
      , pdLockPath = "/nonexistent/seal-stub-setup.lock"
      }
  , sdResolveProvider = \_ _ -> pure (Left "stub setup deps")
  }
  where
    stubError = ProvisionInvalidInput "stub setup deps"

-- ---------------------------------------------------------------------------
-- GET /api/setup
-- ---------------------------------------------------------------------------

-- | The wizard's state. Never fails: a missing file degrades to "nothing
-- configured", and an unparseable one becomes the V0 blocked row.
handleSetupState :: SetupEnv -> IO Response
handleSetupState env = do
  security <- loadSecurityConfig (seSecurityPath env)
  runtime <- loadRuntimeConfig (seConfigPath env)
  mhandle <- readIORef (seHandleRef env)
  let sec = fromRight defaultSecurityConfig security
      rt = fromRight defaultRuntimeConfig runtime
      vaultPath = maybe (vaultFilePath (sePaths env)) T.unpack (scVaultPath sec)
  vaultExists <- doesFileExist vaultPath
  identityReadable <- case scVaultIdentity sec of
    Nothing -> pure Nothing
    Just raw -> Just <$> doesFileExist (T.unpack raw)
  state <- deriveSetupState SetupInputs
    { siPaths = sePaths env
    , siRuntime = rt
    , siSecurity = sec
    , siSecurityProblem = either (Just . summariseConfigProblem) (const Nothing) security
    , siHandle = mhandle
    , siVaultFileExists = vaultExists
    , siIdentityReadable = identityReadable
    , siConfiguredProviders = seProviders env
    -- The seal home's parent is the user's home for the default ~/.seal
    -- layout, which is what the tilde form in a detail is measured from.
    , siHome = takeDirectory (spHome (sePaths env))
    }
  pure (setupJsonNoStore status200 (setupStateJson state))

setupStateJson :: SetupState -> Value
setupStateJson state = object
  [ "required_complete" .= ssRequiredComplete state
  , "steps" .= map stepJson (ssSteps state)
  , "providers" .= map cardJson (ssProviders state)
  ]
  where
    stepJson step = object
      [ "id" .= stId step
      , "required" .= stRequired step
      , "status" .= statusText (stStatus step)
      , "detail" .= stDetail step
      , "actions" .= stActions step
      ]
    cardJson card = object
      [ "id" .= pcId card
      , "label" .= pcLabel card
      , "configured" .= pcConfigured card
      , "isDefault" .= pcIsDefault card
      , "default_model" .= pcDefaultModel card
      ]

statusText :: StepStatus -> Text
statusText status = case status of
  StepReady -> "ready"
  StepPending -> "pending"
  StepBlocked -> "blocked"

-- | A config diagnostic is summarised to its first line and capped: the raw
-- tomland rendering is multi-line, and a detail row is one sentence.
summariseConfigProblem :: Text -> Text
summariseConfigProblem raw =
  let firstLine = case T.lines raw of
        [] -> "unparseable"
        (line:_) -> line
  in T.take 200 (T.strip firstLine)

-- ---------------------------------------------------------------------------
-- POST /api/setup/vault
-- ---------------------------------------------------------------------------

handleVaultCreate :: SetupEnv -> Request -> IO Response
handleVaultCreate env req
  | not (isJsonRequest req) =
      pure (setupErr status415 "content type must be application/json" Nothing)
  | otherwise = do
      body <- collectBodyLimited maxSetupBodyBytes req
      case body of
        Left () -> pure (setupErr status413 "request body exceeds 8 KiB" Nothing)
        Right raw -> case A.eitherDecodeStrict' raw of
          Left _ -> pure (setupErr status400 "request body is not valid JSON" Nothing)
          Right value -> do
            parsed <- parseVaultSpec value
            case parsed of
              Left err -> pure (provisionErrorResponse err)
              Right spec -> do
                outcome <- provisionVault
                  (sePaths env) (seHandleRef env) (sdProvision (seDeps env)) spec
                pure $ case outcome of
                  Left err -> provisionErrorResponse err
                  Right done -> setupJsonNoStore status201 (object
                    [ "recipient" .= poRecipient done
                    , "key_type" .= poKeyType done
                    ])

-- | The status mapping the design fixes (§9.2). 409 for "someone else already
-- holds this state", 422 for "your environment cannot do this", 500 for "we
-- could not write it".
provisionErrorResponse :: ProvisionError -> Response
provisionErrorResponse err =
  let (reason, mHint) = renderProvisionError err
  in setupErr (statusForProvisionError err) reason mHint

statusForProvisionError :: ProvisionError -> Status
statusForProvisionError err = case err of
  ProvisionInvalidInput _      -> status400
  ProvisionAlreadyExists       -> status409
  ProvisionInProgress          -> status409
  ProvisionKeygenMissing _     -> status422
  ProvisionNeedsTty _          -> status422
  ProvisionRoundTripFailed _   -> status422
  ProvisionKeygenFailed _      -> status422
  ProvisionVaultInitFailed     -> status500
  ProvisionVaultUnreadable     -> status500
  ProvisionConfigWriteFailed _ -> status500

-- ---------------------------------------------------------------------------
-- POST /api/setup/vault/reopen
-- ---------------------------------------------------------------------------

-- | Open (and, in @startup@ mode, unlock) the vault that is already configured
-- on disk, under the same setup lock provisioning uses — a reopen racing a
-- create would otherwise open a half-written file.
--
-- It cannot call @Seal.Command.Serve@'s @tryOpenVault@ (import cycle), so this
-- is the same short composition spelled out: load → resolveEncryptor →
-- openVault → vhUnlock (startup) → writeIORef.
handleVaultReopen :: SetupEnv -> IO Response
handleVaultReopen env = do
  let lockPath = pdLockPath (sdProvision (seDeps env))
  result <- withSetupLock lockPath (reopenAction env)
  pure (either provisionErrorResponse id result)

reopenAction :: SetupEnv -> IO (Either ProvisionError Response)
reopenAction env = do
  security <- loadSecurityConfig (seSecurityPath env)
  case security of
    Left _ ->
      pure (Left (ProvisionConfigWriteFailed "security.toml could not be read"))
    Right sec -> case (scVaultRecipient sec, scVaultIdentity sec) of
      (Just recipient, Just identity) ->
        reopenConfigured env sec recipient identity
      _ -> pure (Right (setupErr status409
        "no vault key is recorded"
        (Just "run /vault setup in `seal tui`, then Re-check")))

reopenConfigured
  :: SetupEnv -> SecurityConfig -> Text -> Text
  -> IO (Either ProvisionError Response)
reopenConfigured env sec recipient identity = do
  let vaultPath = maybe (vaultFilePath (sePaths env)) T.unpack (scVaultPath sec)
      keyType = fromMaybe "unknown" (scVaultKeyType sec)
      mode = parseUnlockMode (scVaultUnlock sec)
  exists <- doesFileExist vaultPath
  if not exists
    then pure (Right (setupErr status409
      "the vault file does not exist yet"
      (Just "use the \"resume\" backend to create it")))
    else do
      -- The same seam production resolves through ('mkAgeEncryptor'): it
      -- validates both credentials and stays injectable in tests.
      encryptor <- seMk (pdEncryptor (sdProvision (seDeps env)))
        (AgeRecipient recipient) (AgeIdentity identity)
      case encryptor of
        Left _ -> pure (Right (setupErr status422
          "the recorded vault key cannot be loaded"
          (Just "restore the identity file named in ~/.seal/security.toml, or re-run /vault setup in `seal tui`")))
        Right enc -> do
          handle <- openVault
            (VaultConfig { vcPath = vaultPath, vcKeyType = keyType, vcUnlock = mode })
            enc
          -- startup mode is the only one that is genuinely locked in-process.
          when (mode == UnlockStartup) (void (vhUnlock handle))
          listResult <- vhList handle
          case listResult of
            Left _ -> pure (Right (setupErr status422
              "the vault file cannot be opened with the recorded key"
              (Just "if it holds no secrets yet: mv ~/.seal/config/vault/vault.age \
                    \~/.seal/config/vault/vault.age.bak, then Re-check; otherwise \
                    \restore the matching identity file")))
            Right _ -> do
              writeIORef (seHandleRef env) (Just handle)
              pure (Right (setupJson status200 (object
                [ "opened" .= True
                , "key_type" .= keyType
                , "locked" .= (False :: Bool)
                ])))

-- ---------------------------------------------------------------------------
-- POST /api/providers/:name/test
-- ---------------------------------------------------------------------------

-- | Ping the provider's *stored* configuration. A failed ping is not an HTTP
-- error (the browser renders it next to the field); only an unknown provider
-- (400) or a vault that is not open (500) is.
handleProviderTest :: SetupEnv -> Text -> Request -> IO Response
handleProviderTest env rawName req =
  case parseProvider rawName of
    Nothing -> pure (setupErr status400
      ("unknown provider: " <> rawName)
      (Just "known providers: anthropic, openrouter, ollama"))
    Just known -> do
      mhandle <- readIORef (seHandleRef env)
      case mhandle of
        -- The design decides the vault-unavailable case by reading the handle
        -- first, never by matching on the resolver's error text.
        Nothing -> pure (setupErr status500
          "the vault is not open"
          (Just "create the vault (or reopen it) before testing a provider"))
        Just _ -> do
          model <- testModel env known req
          result <- sdResolveProvider (seDeps env) known model
          pure $ case result of
            Left err -> setupJson status200 (object
              [ "ok" .= False
              , "error" .= err
              ])
            Right _ -> setupJson status200 (object
              [ "ok" .= True
              , "detail" .= ("reachable" :: Text)
              ])

-- | The model the ping uses: the request's @model@ when given, else what a new
-- session would use (global default, then the provider's configured default,
-- then the provider's hardcoded default).
testModel :: SetupEnv -> KnownProvider -> Request -> IO ModelId
testModel env known req = do
  raw <- collectBodyLimited maxSetupBodyBytes req
  let fromBody = case raw of
        Right bytes -> case A.eitherDecodeStrict' bytes of
          Right (A.Object o) -> case KeyMap.lookup (Key.fromText "model") o of
            Just (A.String m) | not (T.null (T.strip m)) -> Just (T.strip m)
            _ -> Nothing
          _ -> Nothing
        Left () -> Nothing
  case fromBody of
    Just m -> pure (ModelId m)
    Nothing -> do
      runtime <- loadRuntimeConfig (seConfigPath env)
      let cfg = fromRight defaultRuntimeConfig runtime
          label = providerLabel known
      pure $ ModelId $ fromMaybe
        (modelText (defaultModelFor known))
        (rcDefaultModel cfg <> providerDefaultModel cfg label)

modelText :: ModelId -> Text
modelText (ModelId m) = m

-- ---------------------------------------------------------------------------
-- Plumbing
-- ---------------------------------------------------------------------------

-- | Setup request bodies are small JSON documents (a backend tag, a recipient,
-- a path). 8 KiB is two orders of magnitude above the largest legitimate body
-- and keeps a hostile peer from buffering a gigabyte.
maxSetupBodyBytes :: Int
maxSetupBodyBytes = 8192

-- | Read a request body, counting bytes as they arrive.
--
-- 'Left' means the body exceeded the limit; the caller answers @413@. Reading
-- stops at the cap, so the excess is never buffered (the reason to prefer this
-- over a @Content-Length@ check alone, which a chunked request can omit).
collectBodyLimited :: Int -> Request -> IO (Either () ByteString)
collectBodyLimited limit req = go 0 []
  where
    go !bytes acc = do
      chunk <- getRequestBodyChunk req
      if BC.null chunk
        then pure (Right (BS.concat (reverse acc)))
        else
          let bytes' = bytes + BS.length chunk
          in if bytes' > limit
               then pure (Left ())
               else go bytes' (chunk : acc)

isJsonRequest :: Request -> Bool
isJsonRequest req = case lookup hContentType (requestHeaders req) of
  Nothing -> False
  Just raw ->
    let mediaType = T.toCaseFold (T.strip (T.takeWhile (/= ';') (decodeHeader raw)))
    in mediaType == "application/json"
  where
    decodeHeader = TE.decodeUtf8Lenient

-- | A JSON response for a setup handler (no CORS grant, matching the rest of
-- the mutation surface after the guard landed).
setupJson :: Status -> Value -> Response
setupJson st = responseLBS st [jsonHeader] . A.encode

-- | A JSON response that must never be cached, and never sniffed: the wizard's
-- state describes system configuration, and a stale copy would tell the user to
-- redo a finished step.
setupJsonNoStore :: Status -> Value -> Response
setupJsonNoStore st =
  responseLBS st [jsonHeader, noStoreHeader, noSniffHeader] . A.encode

-- | The shared error envelope: @{"error": …, "hint": …?}@. The hint is a
-- copy-pasteable next step (a command, a path to repair); it never carries key
-- material or an identity file's contents.
setupErr :: Status -> Text -> Maybe Text -> Response
setupErr st err mHint = setupJson st $ object $
  ["error" .= err] <> maybe [] (\h -> ["hint" .= h]) mHint

jsonHeader :: Header
jsonHeader = (mkHN "Content-Type", "application/json")

noStoreHeader :: Header
noStoreHeader = (mkHN "Cache-Control", "no-store")

noSniffHeader :: Header
noSniffHeader = (mkHN "X-Content-Type-Options", "nosniff")

mkHN :: String -> HeaderName
mkHN = CI.mk . BC.pack
