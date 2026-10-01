{-# LANGUAGE OverloadedStrings #-}
-- | SECRET_MANAGE (Audited): full CRUD for vault secrets via a single
-- action-based opcode. Actions: @get@ (read a secret), @put@ (create or
-- update a secret — upsert), @delete@ (remove a secret, ALWAYS with human
-- approval), @list@ (enumerate key names only).
--
-- Security: secret values returned by @get@ are passed to the model via
-- 'orParts' but NEVER appear in 'orRecorded' (the transcript payload).
-- The @put@ action likewise never records the value. The @delete@ action
-- prompts the human operator via 'ChannelCaps.ccPrompt' before proceeding;
-- if the human denies, the secret is left intact and an error result is
-- returned. The @list@ action returns only key names, never values.
module Seal.ISA.Ops.Secret
  ( secretManageOp
  , vaultGetByName
  , vaultPutByName
  , vaultDeleteByName
  , vaultListNames
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

import Seal.Channel.Caps (AskPrompt (..), ChannelCaps (..))
import Seal.Core.Types
import Seal.ISA.Opcode
import Seal.Providers.Class
import Seal.Security.Vault
import Seal.Types.App (App)
import Seal.Vault.Commands

-- ---------------------------------------------------------------------------
-- Action enum
-- ---------------------------------------------------------------------------

data SecretAction
  = SecretGet
  | SecretPut
  | SecretDelete
  | SecretList

parseSecretAction :: Value -> Either Text SecretAction
parseSecretAction v =
  case parseMaybe (withObject "in" (.: "action")) v of
    Just t -> case t :: Text of
      "get"    -> Right SecretGet
      "put"    -> Right SecretPut
      "delete" -> Right SecretDelete
      "list"   -> Right SecretList
      other    -> Left ("unknown secret action: " <> other)
    Nothing -> Left "missing or invalid action field"

-- ---------------------------------------------------------------------------
-- Field extractors
-- ---------------------------------------------------------------------------

nameField :: Value -> Maybe Text
nameField = parseMaybe (withObject "in" (.: "name"))

valueField :: Value -> Maybe Text
valueField = parseMaybe (withObject "in" (.: "value"))

-- ---------------------------------------------------------------------------
-- Vault helpers
-- ---------------------------------------------------------------------------

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
        Left e  -> Left (T.pack (show e))
        Right bs -> Right (TE.decodeUtf8Lenient bs)

-- | Store a secret value under the given key (upsert). Returns 'Left' on
-- vault errors. The value is never included in the returned 'Text'.
vaultPutByName :: VaultRuntime -> Text -> Text -> IO (Either Text ())
vaultPutByName rt key val = do
  mh <- readIORef (vrHandleRef rt)
  case mh of
    Nothing -> pure (Left "vault not configured — run /vault setup")
    Just h -> do
      r <- vhPut h key (TE.encodeUtf8 val)
      pure $ case r of
        Left e  -> Left (T.pack (show e))
        Right _ -> Right ()

-- | Delete a secret by key. Returns 'Left' if the vault is unconfigured or
-- the key is absent.
vaultDeleteByName :: VaultRuntime -> Text -> IO (Either Text ())
vaultDeleteByName rt key = do
  mh <- readIORef (vrHandleRef rt)
  case mh of
    Nothing -> pure (Left "vault not configured — run /vault setup")
    Just h -> do
      r <- vhDelete h key
      pure $ case r of
        Left e  -> Left (T.pack (show e))
        Right _ -> Right ()

-- | List all secret key names in the vault. Values are never returned.
vaultListNames :: VaultRuntime -> IO (Either Text [Text])
vaultListNames rt = do
  mh <- readIORef (vrHandleRef rt)
  case mh of
    Nothing -> pure (Left "vault not configured — run /vault setup")
    Just h -> do
      r <- vhList h
      pure $ case r of
        Left e   -> Left (T.pack (show e))
        Right ks -> Right ks

-- ---------------------------------------------------------------------------
-- Authorization
-- ---------------------------------------------------------------------------

authorizeGet :: Value -> Either Text ()
authorizeGet v =
  maybe (Left "get requires {name:string}") (const (Right ())) (nameField v)

authorizePut :: Value -> Either Text ()
authorizePut v =
  case nameField v of
    Nothing -> Left "put requires {name:string}"
    Just _ -> case valueField v of
      Nothing -> Left "put requires {value:string}"
      Just val | T.null val -> Left "put requires non-empty value"
               | otherwise  -> Right ()

authorizeDelete :: Value -> Either Text ()
authorizeDelete v =
  maybe (Left "delete requires {name:string}") (const (Right ())) (nameField v)

authorizeList :: Value -> Either Text ()
authorizeList _ = Right ()

-- | Authorize gate for SECRET_MANAGE — dispatches per-action validation.
authorizeManage :: Value -> Either Text ()
authorizeManage v =
  case parseSecretAction v of
    Left e        -> Left e
    Right action  -> case action of
      SecretGet    -> authorizeGet v
      SecretPut    -> authorizePut v
      SecretDelete -> authorizeDelete v
      SecretList   -> authorizeList v

-- ---------------------------------------------------------------------------
-- Handlers
-- ---------------------------------------------------------------------------

handleGet :: VaultRuntime -> Value -> App OpResult
handleGet rt v = do
  let key = fromMaybe "" (nameField v)
  result <- liftIO (vaultGetByName rt key)
  pure $ case result of
    Left err ->
      OpResult [TrpText err] True (object ["name" .= key])
    Right secret ->
      OpResult [TrpText secret] False (object ["name" .= key])

handlePut :: VaultRuntime -> Value -> App OpResult
handlePut rt v = do
  let key = fromMaybe "" (nameField v)
      val = fromMaybe "" (valueField v)
  result <- liftIO (vaultPutByName rt key val)
  pure $ case result of
    Left err ->
      OpResult [TrpText err] True (object ["name" .= key])
    Right _ ->
      OpResult [TrpText "stored"] False (object ["name" .= key])

handleDelete :: VaultRuntime -> ChannelCaps -> Value -> App OpResult
handleDelete rt caps v = do
  let key = fromMaybe "" (nameField v)
      prompt = "Delete vault secret \"" <> key <> "\"? This cannot be undone."
  ans <- liftIO (ccPrompt caps (AskPrompt prompt []))
  -- The confirmation gate (web UI) returns "once"/"for_session"/"always"
  -- for approval and "rejected" for denial. The CLI returns typed text.
  -- Treat any non-empty, non-rejection response as approval.
  if T.toLower (T.strip ans) `elem` ["rejected", "", "no", "n", "cancel", "denied"]
    then pure (OpResult [TrpText "delete denied by operator"] True (object ["name" .= key]))
    else do
      result <- liftIO (vaultDeleteByName rt key)
      pure $ case result of
        Left err ->
          OpResult [TrpText err] True (object ["name" .= key])
        Right _ ->
          OpResult [TrpText "deleted"] False (object ["name" .= key])

handleList :: VaultRuntime -> Value -> App OpResult
handleList rt _v = do
  result <- liftIO (vaultListNames rt)
  pure $ case result of
    Left err ->
      OpResult [TrpText err] True (object ["count" .= (0 :: Int)])
    Right [] ->
      OpResult [TrpText "No secrets."] False (object ["count" .= (0 :: Int)])
    Right keys -> do
      let rendered = T.intercalate "\n" keys
            <> "\n---\n" <> T.pack (show (length keys)) <> " secrets"
      OpResult [TrpText rendered] False (object ["count" .= length keys])

-- ---------------------------------------------------------------------------
-- Consolidated opcode: SECRET_MANAGE
-- ---------------------------------------------------------------------------

-- | SECRET_MANAGE: action-based entry point for all vault secret operations.
-- The @action@ field discriminates between @get@, @put@, @delete@, and
-- @list@. The @delete@ action ALWAYS prompts the human operator for
-- approval before proceeding — it is a blocking opcode.
secretManageOp :: VaultRuntime -> ChannelCaps -> Opcode
secretManageOp rt caps = TrustedOpcode
  { toName = OpName "SECRET_MANAGE"
  , toTrust = Trusted
  , toDesc = "Manage vault secrets. Use action to select: get (fetch a secret value by key name), put (create or update a secret — upsert), delete (remove a secret — ALWAYS prompts for human approval), list (enumerate key names only)."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "action" .= object
              [ "type" .= ("string" :: Text)
              , "enum" .= (["get", "put", "delete", "list"] :: [Text])
              , "description" .= ("Operation to perform." :: Text)
              ]
          , fromText "name" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("The vault key name of the secret (get, put, delete)." :: Text)
              ]
          , fromText "value" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("The secret value to store (put only). Never recorded in the transcript." :: Text)
              ]
          ]
      , "required" .= (["action"] :: [Text])
      ]
  , toOutSchema = object []
  , toAuthorize = authorizeManage
  , toBlocking = True
  , toRun = \_ v ->
      case parseSecretAction v of
        Left e -> pure (OpResult [TrpText e] True (object []))
        Right action -> case action of
          SecretGet    -> handleGet rt v
          SecretPut    -> handlePut rt v
          SecretDelete -> handleDelete rt caps v
          SecretList   -> handleList rt v
  }
