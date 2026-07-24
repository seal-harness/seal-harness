{-# LANGUAGE OverloadedStrings #-}
-- | The security-scoping compile-fail fixture (design §9.1).
-- Proves the type-level guarantee from Approach E: a handler typed
-- @RuntimeConfig -> RuntimeConfig@ (the signature a future CONFIG_UPDATE
-- opcode would have) physically cannot reference @scUntrustedExec@ or any
-- other 'SecurityConfig' field — the field is not in the type, so the code
-- does not compile. This test feeds the compiler a source string that
-- attempts it and asserts the failure, mirroring the capability-scoping
-- fixture at 'Seal.Tools.Exec.CapabilityScopingFailSpec'.
module Seal.Config.SecurityScopingFailSpec (spec) where

import Test.Hspec

import Seal.TestHelpers.CompileFail

spec :: Spec
spec = describe "Security scoping (design §9.1 compile-fail fixture)" $ do

  it "a RuntimeConfig handler that tries to reference scUntrustedExec fails to compile" $ do
    let src = unlines
          [ "{-# LANGUAGE OverloadedStrings #-}"
          , "module Probe where"
          , "import Seal.Config.File (RuntimeConfig (..))"
          , "import Seal.Config.Security (SecurityConfig (..))"
          , "-- A future CONFIG_UPDATE opcode would have this signature."
          , "handler :: RuntimeConfig -> RuntimeConfig"
          , "handler cfg = cfg { scUntrustedExec = Nothing }"
          ]
        -- The field scUntrustedExec is not in RuntimeConfig (it's in
        -- SecurityConfig), so GHC rejects the record update.
    assertCompileFail "config_update_cannot_touch_security" "Not in scope" src

  it "an updateRuntimeConfig lambda that tries to set a SecurityConfig field fails to compile" $ do
    let src = unlines
          [ "{-# LANGUAGE OverloadedStrings #-}"
          , "module Probe where"
          , "import Seal.Config.File (RuntimeConfig (..), updateRuntimeConfig)"
          , "import Seal.Config.Security (SecurityConfig (..))"
          , "-- The HTTP Gateway calls updateRuntimeConfig; this simulates"
          , "-- a handler that tries to flip untrusted_execution."
          , "gatewayBad :: FilePath -> IO (Either String ())"
          , "gatewayBad path = do"
          , "  let f cfg = cfg { scUntrustedExec = Nothing }"
          , "  r <- updateRuntimeConfig path f"
          , "  pure (case r of Left e -> Left (\"err: \" ++ T.unpack e); Right () -> Right ())"
          ]
        -- Same root cause: scUntrustedExec is not a field of RuntimeConfig.
    assertCompileFail "gateway_cannot_touch_security" "Not in scope" src