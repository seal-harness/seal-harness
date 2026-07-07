{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The session-kind enumeration: a session is either a provider-backed chat
-- or a harness-backed external-tool drive. 'HarnessSpec' carries its
-- 'TmuxConfig' coordinates directly (a harness backend has exactly one
-- viable form — tmux — so 'HarnessSpec' hard-codes it; a tool-call
-- execution backend is genuinely plural and is modelled by the
-- 'TerminalBackend' family in Phase 4, not here).
module Seal.Session.Kind
  ( HarnessFlavour (..)
  , mkHCustom
  , HarnessSpec (..)
  , ProviderSpec (..)
  , SessionKind (..)
  , inferProviderId
  ) where

import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

import Seal.Core.Types (ProviderId (..))
import Seal.Harness.Id (HarnessId)
import Seal.Harness.Tmux (TmuxIdent)

-- | The known harness flavours + a smart-constructed 'HCustom' that rejects
-- path separators (a custom-tool launch command must not smuggle a path).
data HarnessFlavour
  = HfClaudeCode
  | HfCodex
  | HfGeneric
  | HCustom Text
  deriving stock (Eq, Show, Generic)

-- | Smart-construct an 'HCustom' flavour: non-empty, no path separators
-- (@/@ @\\@ — argv injection defense for a custom-tool launch command),
-- no control chars, no leading dash.
mkHCustom :: Text -> Either Text HarnessFlavour
mkHCustom t
  | T.null t              = Left "custom harness flavour is empty"
  | T.head t == '-'       = Left "custom harness flavour must not start with '-'"
  | T.any isPathSep t     = Left "custom harness flavour must not contain path separators"
  | not (T.all validChar t) = Left "custom harness flavour has invalid characters"
  | otherwise             = Right (HCustom t)
  where
    isPathSep c = c == '/' || c == '\\'
    validChar c = c `Set.member` flavourChars
    flavourChars = Set.fromList
      $ ['A'..'Z'] <> ['a'..'z'] <> ['0'..'9'] <> "_.-+:@"

-- | A harness spec: the flavour + the tmux coordinates + the launch args.
data HarnessSpec = HarnessSpec
  { hsFlavour     :: HarnessFlavour
  , hsTmuxSession :: TmuxIdent          -- ^ the tmux session the harness lives in
  , hsCwd         :: Maybe FilePath
  , hsArgs        :: [Text]
  , hsDurableId   :: Maybe HarnessId    -- ^ adopt an existing id (re-attach)
  } deriving stock (Eq, Show)

-- | A provider-backed chat session spec (provider label + model).
data ProviderSpec = ProviderSpec
  { psProvider :: Text
  , psModel    :: Text
  } deriving stock (Eq, Show)

-- | The session-kind enumeration.
data SessionKind
  = SkProvider ProviderSpec
  | SkHarness HarnessSpec
  deriving stock (Eq, Show)

-- | Infer a 'ProviderId' from a model-prefix heuristic (e.g.
-- @claude-…@ -> @anthropic@). A minimal table; the real resolution lives
-- in 'Seal.Providers.Registry'.
inferProviderId :: Text -> Maybe ProviderId
inferProviderId model
  | "claude"  `T.isPrefixOf` model = Just (ProviderId "anthropic")
  | "gpt"     `T.isPrefixOf` model = Just (ProviderId "openai")
  | "llama"   `T.isPrefixOf` model = Just (ProviderId "ollama")
  | "gemini"  `T.isPrefixOf` model = Just (ProviderId "google")
  | otherwise                      = Nothing