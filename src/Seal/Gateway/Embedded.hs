{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
-- | The web frontend's build output (frontend/dist), embedded into the
-- binary at compile time so @seal serve@ needs no on-disk static dir and
-- no config. Same philosophy as "Seal.Skills.Builtins": the UI is always
-- the version the binary shipped with — self-contained, no first-run
-- materialization, no install-layout dependency, no staleness across
-- upgrades.
module Seal.Gateway.Embedded
  ( embeddedAssets
  , embeddedAssetCount
  , distManifest
  ) where

import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir, embedOneStringFileOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Language.Haskell.TH.Syntax (runIO)
import System.Directory (doesDirectoryExist)

-- | Frontend bytes keyed by forward-slash path relative to the dist root
-- (e.g. @"index.html"@, @"assets\/index-De3F1a.js"@).
--
-- @embedDir@ properties (verified in file-embed source):
--   * Recursive, sorted output.
--   * Dot-prefixed entries skipped (so @.seal-manifest@ never appears).
--   * Every embedded file registered with @qAddDependentFile@ (called
--     inside @pairToExp@ in file-embed's @embedDir@ implementation).
--   * Keys are relative paths joined with @System.FilePath.(<\/>)@ — which
--     uses @\"\/\"@ on Unix (verified: @fileList'@ builds keys via
--     @top <\/> filename@ where @top@ starts as @\"\"@). This matches the
--     @T.intercalate \"\/\"@ lookup in 'Seal.Gateway.Server.serveEmbedded'.
--     Target platforms are Unix-only (nix, macOS, Linux).
embeddedAssets :: Map FilePath ByteString
embeddedAssets = Map.fromList
  $(do exists <- runIO (doesDirectoryExist "frontend/dist")
       if exists
         then embedDir "frontend/dist"
         else [| [] |]
  )

-- | Sentinel written by @make frontend-build@ (a hash over the dist tree).
-- Changes on every UI build, forcing this module to recompile so the
-- @embedDir@ splice re-runs. This closes file-embed's documented caveat
-- that /newly added/ files don't reliably retrigger recompilation — which
-- is the default case for us, since Vite emits new hash-named files each
-- build. Fallback file (committed) keeps @cabal build@ working from a
-- clean checkout with no dist.
--
-- Exported (not just a side-effect splice) to avoid @-Wunused-top-binds@
-- under @-Wall -Werror@. Also useful for debugging: the manifest hash
-- identifies which UI build is embedded in a running binary.
distManifest :: String
distManifest = $(embedOneStringFileOf
  [ "frontend/dist/.seal-manifest"
  , "config/frontend-dist-absent.txt"
  ])

-- | Number of embedded assets. Equal to 'Map.size' of 'embeddedAssets'.
embeddedAssetCount :: Int
embeddedAssetCount = Map.size embeddedAssets
