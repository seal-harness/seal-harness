{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Shared leaf vocabulary imported across the spine. Subset only: the types
-- the running CLI agent loop touches. (Harness/Tabs/MessageSource land later.)
module Seal.Core.Types
  ( TrustLevel (..)
  , ProviderId (..)
  , ModelId (..)
  , ToolCallId (..)
  , OpName (..)
  , SessionId
  , mkSessionId
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

sessionIdText :: SessionId -> Text
sessionIdText (SessionId t) = t
