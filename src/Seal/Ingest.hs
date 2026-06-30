{-# LANGUAGE OverloadedStrings #-}
-- | Single-door ingest chokepoint: preprocess chain → Disposition classifier.
module Seal.Ingest
  ( RawInbound (..)
  , PreprocessStage
  , PreprocessChain (..)
  , emptyChain
  , runChain
  , Disposition (..)
  , ingest
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Seal.Command.Help (renderHelpFor, renderHelpIndex)
import Seal.Command.Parse (ParseOutcome (..), parseSlash)
import Seal.Command.Spec (CommandAction, Registry)

-- ---------------------------------------------------------------------------
-- Raw input
-- ---------------------------------------------------------------------------

newtype RawInbound = RawInbound Text
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Preprocess chain
-- ---------------------------------------------------------------------------

-- | A single preprocess stage. 'Left' aborts the chain with a rejection message.
type PreprocessStage = RawInbound -> IO (Either Text RawInbound)

-- | An ordered sequence of 'PreprocessStage's run before classification.
newtype PreprocessChain = PreprocessChain [PreprocessStage]

-- | The empty chain: all input passes through unchanged.
emptyChain :: PreprocessChain
emptyChain = PreprocessChain []

-- | Run every stage in order, short-circuiting on the first 'Left'.
runChain :: PreprocessChain -> RawInbound -> IO (Either Text RawInbound)
runChain (PreprocessChain stages) = go stages
  where
    go []       r = pure (Right r)
    go (s : ss) r = s r >>= \case
      Left err -> pure (Left err)
      Right r' -> go ss r'

-- ---------------------------------------------------------------------------
-- Disposition
-- ---------------------------------------------------------------------------

data Disposition
  = DispatchAction CommandAction  -- ^ a parsed command to run
  | ShowText Text                 -- ^ help text or parse error to echo
  | PlainMessage Text             -- ^ non-slash input (MVP stub)
  | Rejected Text                 -- ^ preprocess chain rejected the input

-- | Classify one inbound line. The chain runs FIRST; if it rejects the
-- input the result is 'Rejected' regardless of content.
--
-- Classification (after chain passes):
--
-- * Leading @\/@  → 'parseSlash' → 'DispatchAction' | 'ShowText'
-- * Otherwise     → 'PlainMessage'
ingest :: Registry -> PreprocessChain -> RawInbound -> IO Disposition
ingest registry chain raw = do
  chainResult <- runChain chain raw
  case chainResult of
    Left msg             -> pure (Rejected msg)
    Right (RawInbound t) ->
      if T.isPrefixOf "/" t
        then pure $ case parseSlash registry t of
          ParsedAction a     -> DispatchAction a
          ParseHelp Nothing  -> ShowText (renderHelpIndex registry)
          ParseHelp (Just n) -> ShowText (renderHelpFor registry n)
          ParseFailure txt   -> ShowText txt
        else pure (PlainMessage t)
