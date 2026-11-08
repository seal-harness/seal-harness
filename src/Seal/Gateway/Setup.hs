{-# LANGUAGE OverloadedStrings #-}
-- | Shared plumbing for the setup endpoints: the body cap, the JSON/error
-- helpers they answer with, and the injected seams the vault/provisioning
-- handlers depend on.
--
-- The handlers themselves arrive with WU5 (plan rev 3). This module exists
-- earlier because the bounded body reader is part of the mutation-guard change
-- (PR A) and because the dependency record is what 'ApiDeps' carries from WU1
-- onwards.
--
-- @Seal.Gateway.Setup@ never imports @Seal.Gateway.API@ (that module imports
-- this one), so the helpers are self-contained.
module Seal.Gateway.Setup
  ( maxSetupBodyBytes
  , collectBodyLimited
  , setupJson
  , setupErr
  , SetupDeps (..)
  , stubSetupDeps
  ) where

import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as A
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.CaseInsensitive qualified as CI
import Data.Text (Text)
import Network.HTTP.Types (Header, HeaderName, Status)
import Network.Wai (Request, Response, getRequestBodyChunk, responseLBS)

import Seal.Core.Types (ModelId)
import Seal.Providers.Class (SomeProvider)
import Seal.Providers.Registry (KnownProvider)
import Seal.Security.Vault.Age (VaultError (..))
import Seal.Vault.Provision
  ( ProvisionDeps (..), ProvisionError (ProvisionInvalidInput)
  , SetupEncryptor (..), SetupKeygen (..) )

-- | The setup endpoints' injected dependencies.
--
-- Two seams, both of which have to be injected rather than imported so the
-- handlers stay testable: the provisioning core (which shells out to
-- @age-keygen@ / @age-plugin-yubikey@ / @age@) and the provider resolver (which
-- needs a 'Network.HTTP.Client.Manager' and a vault handle).
data SetupDeps = SetupDeps
  { sdProvision       :: ProvisionDeps
  , sdResolveProvider :: KnownProvider -> ModelId -> IO (Either Text SomeProvider)
    -- ^ Re-reads @config.toml@ and the vault handle on every call, so a
    -- provider saved during setup (including a new ollama base URL) is what
    -- "Test connection" actually pings.
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

-- | A JSON response for a setup handler (no CORS grant, matching the rest of
-- the mutation surface after the guard landed).
setupJson :: Status -> Value -> Response
setupJson st = responseLBS st [jsonHeader] . A.encode

-- | The shared error envelope: @{"error": …, "hint": …?}@. The hint is a
-- copy-pasteable next step (a command, a path to repair); it never carries key
-- material or an identity file's contents.
setupErr :: Status -> Text -> Maybe Text -> Response
setupErr st err mHint = setupJson st $ object $
  ["error" .= err] <> maybe [] (\h -> ["hint" .= h]) mHint

jsonHeader :: Header
jsonHeader = (mkHN "Content-Type", "application/json")

mkHN :: String -> HeaderName
mkHN = CI.mk . BC.pack
