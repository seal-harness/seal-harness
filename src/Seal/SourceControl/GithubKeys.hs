{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
-- | GitHub's published SSH host keys, pinned at compile time via
-- 'file-embed' (tamper-resistant — the bytes are baked into the binary;
-- a runtime attacker cannot swap them without rebuilding). Public data:
-- <https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints>
--
-- Used as the @UserKnownHostsFile@ content for the no-disk clone seam (W2):
-- @StrictHostKeyChecking=yes@ (NOT @accept-new@ / @/dev/null@ — §5.3: MITM
-- defense) reads these pinned keys, so a GitHub clone verifies the server
-- against a known-good host key without ever touching @~/.ssh/known_hosts@
-- and without prompting. The file is written per-op to
-- @<workdir>/.seal-known-hosts@ (public data, 0644, cleaned up after the op).
module Seal.SourceControl.GithubKeys
  ( pinnedGithubKnownHosts
  ) where

import Data.ByteString (ByteString)
import Data.FileEmbed (embedFile)

-- | The pinned GitHub host keys (RSA, ECDSA, Ed25519) in OpenSSH
-- @known_hosts@ format. Embedded at compile time.
pinnedGithubKnownHosts :: ByteString
pinnedGithubKnownHosts = $(embedFile "src/Seal/SourceControl/data/github-known-hosts")