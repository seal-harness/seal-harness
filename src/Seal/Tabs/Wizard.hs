{-# LANGUAGE OverloadedStrings #-}
-- | The @/tab new harness@ (or @/tab resume@) attach-wizard state machine:
-- snapshot the running harnesses + recent sessions, number them @[1-9a-z]@,
-- @0@ cancels, a @\/@-prefixed reply cancels and runs that command instead.
module Seal.Tabs.Wizard
  ( AttachTarget (..)
  , WizardState (..)
  , WizardReply (..)
  , buildWizard
  , handleReply
  ) where

import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Handles.Tab (TabKind, TabIndex, mkTabIndex, tabIndexToInt)
import Seal.Tabs.Types (TabRef)

-- | One attachable target (a running harness or a recent session).
data AttachTarget = AttachTarget
  { atLabel :: Text
  , atRef   :: TabRef
  } deriving stock (Eq, Show)

-- | The wizard state: a numbered list of targets + the pending tab kind.
-- Targets are numbered 1..n (slot 0 is reserved for "cancel").
data WizardState = WizardState
  { wsTargets :: [(TabIndex, AttachTarget)]
  , wsKind    :: TabKind
  } deriving stock (Eq, Show)

-- | The wizard reply: attach to a ref, cancel, or run a /-prefixed command
-- instead.
data WizardReply
  = WizardAttach TabRef
  | WizardCancel
  | WizardSlash Text   -- ^ a /-prefixed reply: cancel + run this command
  deriving stock (Eq, Show)

-- | Build the wizard state from the running harnesses + recent sessions.
-- Numbers the targets 1..n (slot 0 is reserved for "cancel").
buildWizard :: TabKind -> [AttachTarget] -> WizardState
buildWizard kind targets =
  WizardState
    { wsTargets = zipWith (,) (map mkIdx [1..]) targets
    , wsKind    = kind
    }
  where
    mkIdx n = case mkTabIndex n of
      Right i -> i
      Left _  -> error ("buildWizard: target index out of range (n=" <> show n <> ")")

-- | Handle one reply. 'Right WizardReply' on success; 'Left Text' on a
-- malformed reply (out-of-range number, non-numeric, empty).
handleReply :: WizardState -> Text -> Either Text WizardReply
handleReply ws reply
  | T.null reply             = Left "empty reply"
  | T.head reply == '/'      = Right (WizardSlash (T.drop 1 reply))
  | T.all isDigit reply &&
    T.length reply <= 2      =
      case mkTabIndex (read (T.unpack reply)) of
        Right idx
          | tabIndexToInt idx == 0 -> Right WizardCancel
          | otherwise -> case lookup idx (wsTargets ws) of
              Just t  -> Right (WizardAttach (atRef t))
              Nothing -> Left "no such target"
        Left _ -> Left "no such target"
  | otherwise                = Left "not a number (or '/command')"