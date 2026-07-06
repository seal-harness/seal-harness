{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Consent-gated adoption of an external tmux window. A discovered window
-- requires @consent_confirmed@ from an interactive channel; a headless run
-- cannot confirm, so adoption fail-closes (the user must confirm via an
-- interactive channel).
module Seal.Security.Adoption
  ( ConsentChannel (..)
  , AdoptError (..)
  , AdoptedHarness (..)
  , authorizeAdoption
  ) where

import Data.Text (Text)
import GHC.Generics (Generic)

import Seal.Harness.Id (HarnessId)

-- | The interactive channels that can confirm an adoption.
data ConsentChannel = CcCli | CcSignal | CcWeb
  deriving stock (Eq, Show)

-- | The adoption error type. Matched on to drive control flow.
data AdoptError
  = AeHeadlessNoConsent       -- ^ cannot confirm consent in a headless run
  | AeConsentMissing          -- ^ the channel is interactive but consent was not given
  | AeAlreadyManaged HarnessId  -- ^ the window already has a seal_id
  deriving stock (Eq, Show)

-- | An adopted harness: the discovered window's coord + the minted id.
data AdoptedHarness = AdoptedHarness
  { ahCoord :: Text
  , ahId    :: HarnessId
  } deriving stock (Eq, Show, Generic)

-- | Authorize an adoption: requires @consent_confirmed@ from an
-- interactive 'ConsentChannel'. A headless run (@Nothing@ channel)
-- fail-closes with 'AeHeadlessNoConsent'; an interactive channel with
-- @consent_confirmed = False@ fail-closes with 'AeConsentMissing'.
authorizeAdoption :: Maybe ConsentChannel -> Bool -> Either AdoptError ()
authorizeAdoption Nothing _ = Left AeHeadlessNoConsent
authorizeAdoption (Just _) False = Left AeConsentMissing
authorizeAdoption (Just _) True = Right ()