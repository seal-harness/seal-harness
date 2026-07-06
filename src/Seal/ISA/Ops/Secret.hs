{-# LANGUAGE OverloadedStrings #-}
-- | SECRET_GET (Audited): fetch a vault secret. The value is returned to the
-- model as a tool result, but the recorded transcript payload carries only the
-- key NAME — the secret value is never serialized to the audit log. (The unified
-- cross-session Audited log is deferred to Phase 5; this records to the session
-- transcript via the dispatcher.)
module Seal.ISA.Ops.Secret
  ( secretGetOp
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, object, withObject, (.:), (.=))
import Data.Aeson.Key (fromText)
import Data.Aeson.Types (parseMaybe)
import Data.IORef (readIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import Seal.Core.Types
import Seal.ISA.Opcode
import Seal.Providers.Class
import Seal.Security.Vault
import Seal.Vault.Commands

-- | Build a JSON-Schema object with a single required string property.
singleStringSchema :: Text -> Text -> Value
singleStringSchema fieldName fieldDesc =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object
        [fromText fieldName .= object
           [ "type" .= ("string" :: Text)
           , "description" .= fieldDesc
           ]]
    , "required" .= ([fieldName] :: [Text])
    ]

-- | Extract the @name@ string field from a JSON object.
nameField :: Value -> Maybe Text
nameField = parseMaybe (withObject "in" (.: "name"))

-- | SECRET_GET opcode: reads a named secret from the unlocked vault and
-- returns the value to the model. The recorded payload carries only the key
-- name — never the secret value.
secretGetOp :: VaultRuntime -> Opcode
secretGetOp rt = Opcode
  { opName = OpName "SECRET_GET"
  , opTrust = Trusted
  , opDesc = "Fetch a secret value from the vault by key name."
  , opInSchema = singleStringSchema "name" "The vault key name of the secret to fetch."
  , opOutSchema = object []
  , opAuthorize =
      maybe (Left "SECRET_GET requires {name:string}") (const (Right ())) . nameField
  , opRun = \_ v -> do
      let key = fromMaybe "" (nameField v)
      val <- liftIO (vaultGetByName rt key)
      pure $ case val of
        Left err ->
          OpResult [TrpText err] True (object ["name" .= key])
        Right secret ->
          OpResult [TrpText secret] False (object ["name" .= key])
  }

-- | Look up a secret by name from the vault handle in the runtime.
-- Returns 'Left' with a human-readable message if the vault is unconfigured
-- or the key is absent; 'Right' with the UTF-8-decoded value otherwise.
-- The decoded 'Text' is passed directly to 'orParts' and must not reach
-- 'orRecorded'.
vaultGetByName :: VaultRuntime -> Text -> IO (Either Text Text)
vaultGetByName rt key = do
  mh <- readIORef (vrHandleRef rt)
  case mh of
    Nothing -> pure (Left "vault not configured — run /vault setup")
    Just h -> do
      r <- vhGet h key
      pure $ case r of
        Left e -> Left (T.pack (show e))
        Right bs -> Right (TE.decodeUtf8Lenient bs)
