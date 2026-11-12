{-# LANGUAGE OverloadedStrings #-}
-- | Opacity compile-fail fixture for 'Seal.Vault.IdentityPath' (plan WU1,
-- implementation order item 7; design §7.5).
--
-- The invariant is type-level: the ONLY way to obtain a 'VaultIdentityPath' is
-- 'mkVaultIdentityPath', which is the function that stat()s the file, rejects
-- a leading @-@ and rejects control characters. If the constructor were
-- exported, any code path could hand @age@ an unvalidated path through
-- @--identity=\<path\>@. This test feeds the compiler a module that tries it
-- and asserts the failure, mirroring
-- 'Seal.Config.SecurityScopingFailSpec' and the capability-scoping fixture.
module Seal.Vault.IdentityPathScopingFailSpec (spec) where

import Test.Hspec

import Seal.TestHelpers.CompileFail

spec :: Spec
spec = describe "VaultIdentityPath opacity (design §7.5 compile-fail fixture)" $ do

  it "the VaultIdentityPath constructor cannot be used outside its module" $ do
    let src = unlines
          [ "{-# LANGUAGE OverloadedStrings #-}"
          , "module Probe where"
          , "import Seal.Vault.IdentityPath (VaultIdentityPath (..))"
          , "-- The shape a bypass would take: a raw path wrapped with no checks."
          , "bypass :: VaultIdentityPath"
          , "bypass = VaultIdentityPath \"-/tmp/not-validated\""
          ]
    assertCompileFail "vault_identity_path_constructor_hidden" "Not in scope" src

  it "a raw FilePath is not a VaultIdentityPath" $ do
    let src = unlines
          [ "{-# LANGUAGE OverloadedStrings #-}"
          , "module Probe where"
          , "import Seal.Vault.IdentityPath (VaultIdentityPath)"
          , "-- Even without naming the constructor, no coercion may exist."
          , "coerceUp :: FilePath -> VaultIdentityPath"
          , "coerceUp p = p"
          ]
    assertCompileFail "vault_identity_path_no_coercion" "Couldn't match" src
