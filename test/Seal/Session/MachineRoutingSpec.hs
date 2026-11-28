{-# LANGUAGE OverloadedStrings #-}
-- | WU-5 — the session's routing table must reach the dispatcher.
--
-- 'mkSessionRoutingFor' existed and was unit-tested, but nothing called it: a
-- real 'mkSessionExec'/'mkSessionExecFor' built a SINGLETON routing table, so a
-- tool call naming any machine other than the session's own failed with
-- 'MachineUnknown' regardless of what @machines.toml@ said. Done-when 11 ("a
-- second call naming a different machine runs on that one") passed only
-- because 'Seal.ISA.DispatchMachineSpec' injects multi-machine routing
-- directly, bypassing the constructor every production caller uses.
--
-- So these tests drive 'mkSessionExecFor' — the production path — and assert
-- what a caller can actually see: the routing table inside 'seUIOEnv'.
module Seal.Session.MachineRoutingSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Config.Machines
  ( MachineName, MachineRegistry (..), mkMachineName, resolveRegistryForSecurity )
import Seal.Config.Paths (SealPaths (..), machinesFilePath)
import Seal.Config.Security
  ( SecurityConfig (..), UntrustedExecFileConfig (..), defaultSecurityConfig )
import Seal.Core.Types (mkSystemSessionId)
import Seal.Session.Workdir
  ( mkSessionExecFor, seUIOEnv )
import Seal.SourceControl.Clone (stubCloneDeps)
import Seal.Tools.Exec.Machine (rtSelectable, rtSession)
import Seal.Tools.Exec.Remote (mkFakeRemoteRunner)
import Seal.Tools.Exec.UIO.Internal (uieMachines)

spec :: Spec
spec = describe "WU-5 the session's routing reaches the dispatcher" $ do

  it "a session on machine A can name machine B" $
    withTwoMachines $ \paths secCfg -> do
      exec <- mkSessionExecFor paths secCfg (mkSystemSessionId "s-route-1")
                 stubCloneDeps (mkFakeRemoteRunner (Right "")) Nothing
                 (Just (machine "alpha"))
      let routing = uieMachines (seUIOEnv exec)
      -- The recorded machine is the session machine...
      rtSession routing `shouldBe` machine "alpha"
      -- ...and beta is offered, which is exactly what lets a call name it.
      -- Before this unit the selectable list held only the session machine,
      -- so `machine: "beta"` was unreachable no matter the config.
      show (rtSelectable routing) `shouldContain` "beta"

  it "the selectable set is the registry's, not a singleton" $
    withTwoMachines $ \paths secCfg -> do
      eReg <- resolveRegistryForSecurity paths secCfg
      reg <- case eReg of
        Left e   -> expectationFailure ("fixture: " <> T.unpack e) >> error "unreachable"
        Right r  -> pure r
      exec <- mkSessionExecFor paths secCfg (mkSystemSessionId "s-route-2")
                 stubCloneDeps (mkFakeRemoteRunner (Right "")) Nothing
                 (Just (machine "alpha"))
      let routing = uieMachines (seUIOEnv exec)
      -- One entry per selectable machine: alpha and beta here.
      length (rtSelectable routing) `shouldBe` Map.size (regMachines reg)

  it "a session whose machine is local still sees the configured machines" $
    withTwoMachinesLocal $ \paths secCfg -> do
      exec <- mkSessionExecFor paths secCfg (mkSystemSessionId "s-route-3")
                 stubCloneDeps (mkFakeRemoteRunner (Right "")) Nothing
                 (Just (machine "alpha"))
      let routing = uieMachines (seUIOEnv exec)
      rtSession routing `shouldBe` machine "alpha"
      -- Under allow_localhost = true, `local` joins the selectable set.
      show (rtSelectable routing) `shouldContain` "local"

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

-- | A temp home with a two-machine @machines.toml@ and @allow_localhost =
-- false@, so both machines must come from the file.
withTwoMachines :: (SealPaths -> SecurityConfig -> IO ()) -> IO ()
withTwoMachines = withMachinesToml twoMachinesToml
  (defaultSecurityConfig { scUntrustedExec = Just (UntrustedExecFileConfig False) })

-- | The same machines with @allow_localhost = true@.
withTwoMachinesLocal :: (SealPaths -> SecurityConfig -> IO ()) -> IO ()
withTwoMachinesLocal = withMachinesToml twoMachinesToml
  (defaultSecurityConfig { scUntrustedExec = Just (UntrustedExecFileConfig True) })

withMachinesToml :: Text -> SecurityConfig
                 -> (SealPaths -> SecurityConfig -> IO ()) -> IO ()
withMachinesToml toml secCfg body = withSystemTempDirectory "seal-wu5" $ \tmp -> do
  let paths = SealPaths
        { spHome = tmp, spState = tmp </> "state", spConfig = tmp </> "config"
        , spKeys = tmp </> "keys", spCache = tmp </> "cache" }
  createDirectoryIfMissing True (spCache paths)
  createDirectoryIfMissing True (spConfig paths)
  writeFile (machinesFilePath paths) (T.unpack toml)
  body paths secCfg

twoMachinesToml :: Text
twoMachinesToml = T.unlines
  [ "default = \"alpha\""
  , ""
  , "[machines.alpha]"
  , "host = \"alpha.invalid\""
  , "user = \"seal\""
  , "workspace = \"/srv/alpha\""
  , ""
  , "[machines.beta]"
  , "host = \"beta.invalid\""
  , "user = \"seal\""
  , "workspace = \"/srv/beta\""
  ]

-- | Behind a helper because 'MachineName''s constructor is deliberately
-- unexported and 'mkMachineName' refuses the reserved @local@ by design.
machine :: Text -> MachineName
machine t = case mkMachineName t of
  Right n -> n
  Left e  -> error ("fixture: mkMachineName " <> T.unpack t <> ": " <> T.unpack e)
