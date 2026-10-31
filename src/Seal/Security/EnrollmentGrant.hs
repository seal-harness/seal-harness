{-# LANGUAGE OverloadedStrings #-}
-- | Enrollment grants: the authority a client presents to add a credential.
--
-- This module currently holds the shared vocabulary only. The grant record,
-- its file codec and the claim protocol land with the grant machinery; the
-- type lives here from the start because both the credential store's
-- @added_via@ and the boot plan's "should I mint a grant, and how" have to name
-- the same set of sources. Two copies of that enum would drift.
--
-- Why this is not in "Seal.Security.AccessControl": @Grant@'s phases name
-- challenge ids, which are gateway-local. Keeping the grant types out of the
-- credential-availability code is what lets the latter stay a pure function of
-- a credential map (design §7.1).
module Seal.Security.EnrollmentGrant
  ( GrantSource (..)
  , grantSourceText
  , parseGrantSource
  ) where

import Data.Text (Text)

-- | How a grant was minted — and, for an enrolled credential, how it was added
-- (@added_via@ plus @legacy@, which no grant can produce).
--
-- The distinction is load-bearing, not descriptive: a 'CliWindow' grant is
-- authority with no secret at all, so it exists only in the bootstrap state
-- (nothing enrolled, loopback bind, loopback origin). Any other combination is
-- a refusal, which is why the type flows into both the boot plan and the
-- resolver rather than being flattened to a boolean.
data GrantSource
  = CliToken
    -- ^ Minted by @seal access-control enroll@ or by boot; presented as a
    -- request header.
  | CliWindow
    -- ^ @enroll --no-token@: loopback-confined, bootstrap-only, no secret
    -- presented.
  | Assertion
    -- ^ Minted by a successful assertion from an already-enrolled credential;
    -- the authority for adding a second passkey.
  deriving stock (Eq, Show)

-- | The wire/TOML spelling (@minted_via@, @added_via@).
grantSourceText :: GrantSource -> Text
grantSourceText source = case source of
  CliToken  -> "cli_token"
  CliWindow -> "cli_window"
  Assertion -> "assertion"

-- | Parse the stored spelling. 'Nothing' for anything unrecognised — callers
-- decide whether that is a refusal (grants) or a fallback to @legacy@
-- (credentials, where claiming nothing about the enrolling authority is safe).
parseGrantSource :: Text -> Maybe GrantSource
parseGrantSource raw = case raw of
  "cli_token"  -> Just CliToken
  "cli_window" -> Just CliWindow
  "assertion"  -> Just Assertion
  _            -> Nothing
