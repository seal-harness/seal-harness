{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Shared leaf vocabulary for the gateway API contract. These types are
-- the wire-protocol primitives: 'SessionId', 'TrustLevel', 'ProviderId',
-- 'ModelId', 'ToolCallId', 'OpName'. They have no internal Seal
-- dependencies — only external packages (aeson, text).
--
-- Both the server ('seal-server') and channel clients ('seal-chat-channels')
-- import these. This module is the canonical home; 'Seal.Core.Types' in the
-- server re-exports from here.
module Seal.Gateway.Types.Core
  ( TrustLevel (..)
  , ProviderId (..)
  , ModelId (..)
  , ToolCallId (..)
  , OpName (..)
  , SessionId
  , mkSessionId
  , mkSystemSessionId
  , sessionIdText
  , isValidSessionId
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

data TrustLevel = Untrusted | Trusted | Audited
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (ToJSON, FromJSON)

newtype ProviderId = ProviderId Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

newtype ModelId = ModelId Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

newtype ToolCallId = ToolCallId Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

newtype OpName = OpName Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

-- | Opaque session label. No parse invariant on construction history, but a
-- single strict predicate guards every path-join / network boundary.
newtype SessionId = SessionId Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

isValidSessionId :: Text -> Bool
isValidSessionId t =
  not (T.null t)
    && T.head t /= '.'
    && T.all (`elem` chars) t
  where
    chars = ['A' .. 'Z'] <> ['a' .. 'z'] <> ['0' .. '9'] <> "_-"

mkSessionId :: Text -> Either Text SessionId
mkSessionId t
  | isValidSessionId t = Right (SessionId t)
  | otherwise          = Left ("invalid session id: " <> T.pack (show t))

-- | Total constructor for known-safe system strings (e.g. @"web"@,
-- @"manual"@). Calls 'isValidSessionId' internally and errors on
-- failure — it does NOT bypass validation. Use only for compile-time-
-- known literals; runtime-derived strings should use 'mkSessionId' (the
-- 'Either'-returning variant).
mkSystemSessionId :: Text -> SessionId
mkSystemSessionId t
  | isValidSessionId t = SessionId t
  | otherwise          = error ("mkSystemSessionId: invalid session id: " <> T.unpack t)

sessionIdText :: SessionId -> Text
sessionIdText (SessionId t) = t