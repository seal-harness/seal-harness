{-# LANGUAGE OverloadedStrings #-}
module Seal.Config.MachinesSpec (spec) where

import Data.Map.Strict qualified as Map
import qualified Data.Text as T
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Test.QuickCheck

import Seal.Config.Machines
import Seal.Tools.Exec.Types (SshConfig (..), getSshHost)
import Seal.Config.Paths (SealPaths (..), machinesFilePath)
import Seal.Config.Templates (ensureConfigTemplates, machinesTomlTemplate)

spec :: Spec
spec = describe "Seal.Config.Machines" $ do
  machinesSpec
  specIO

machinesSpec :: SpecWith ()
machinesSpec = do

  describe "mkMachineName" $ do
    it "accepts a normal name" $
      mkMachineName "linux-builder" `shouldSatisfy` isRight

    it "accepts underscores and dots" $
      mkMachineName "mac_mini.lan" `shouldSatisfy` isRight

    it "rejects the reserved name local" $
      mkMachineName "local" `shouldBe` Left "machine name \"local\" is reserved for the harness machine"

    it "rejects an empty name" $
      mkMachineName "" `shouldSatisfy` isLeft

    it "rejects a leading dash (option injection)" $
      mkMachineName "-oProxyCommand=x" `shouldSatisfy` isLeft

    it "rejects a leading dot" $
      mkMachineName ".hidden" `shouldSatisfy` isLeft

    it "rejects bare . and .." $ do
      mkMachineName "." `shouldSatisfy` isLeft
      mkMachineName ".." `shouldSatisfy` isLeft

    it "rejects names longer than 64 characters" $
      mkMachineName (T.replicate 65 "a") `shouldSatisfy` isLeft

    it "rejects spaces, slashes and control characters" $
      mapM_ (\n -> mkMachineName n `shouldSatisfy` isLeft)
        ["a b", "a/b", "a\tb", "a\nb"]

    it "accepts exactly 64 characters" $
      mkMachineName (T.replicate 64 "a") `shouldSatisfy` isRight

  describe "isLoopbackHost" $ do
    it "rejects the literal loopback forms" $
      mapM_ (\h -> isLoopbackHost h `shouldBe` True)
        ["localhost", "127.0.0.1", "127.1.2.3", "::1", "[::1]"]

    it "rejects unspecified/wildcard addresses" $
      mapM_ (\h -> isLoopbackHost h `shouldBe` True) ["0.0.0.0", "::"]

    it "does not reject a normal host" $
      mapM_ (\h -> isLoopbackHost h `shouldBe` False)
        ["builder.example.com", "mac-mini.lan", "10.0.0.5"]

  describe "resolveMachines" $ do

    let paths = SealPaths
          { spHome = "/home/_testseal"
          , spConfig = "/home/_testseal/config"
          , spState = "/home/_testseal/state"
          , spKeys = "/home/_testseal/keys"
          , spCache = "/home/_testseal/cache"
          }

        goodMachine = MachineFileConfig
          { mfcHost = Just "builder.example.com"
          , mfcUser = Just "seal"
          , mfcPort = Just 22
          , mfcIdentity = Nothing
          , mfcWorkspace = Just "/srv/seal/workspace"
          }

        cfgWith defaultName machines = MachinesConfig
          { mcDefault = defaultName
          , mcMachines = Map.fromList machines
          }

    it "injects local iff allow_localhost" $ do
      let on = resolveMachines True paths nullMachines
          off = resolveMachines False paths nullMachines
      Map.member localMachineName (regMachines on) `shouldBe` True
      Map.member localMachineName (regMachines off) `shouldBe` False

    it "always injects local when the flag is on, even with no machines configured" $ do
      let reg = resolveMachines True paths nullMachines
      Map.size (regMachines reg) `shouldBe` 1
      Map.member localMachineName (regMachines reg) `shouldBe` True

    it "resolves a well-formed machine to MtSsh" $ do
      let reg = resolveMachines True paths
                  (cfgWith (Just "builder") [("builder", goodMachine)])
      Map.lookup (machineName "builder") (regMachines reg) `shouldSatisfy` maybe False isMtSsh
      regDefault reg `shouldBe` Just (machineName "builder")

    -- The loopback guard must run BEFORE host validation, or the operator gets
    -- mkSshHost's generic "invalid characters" instead of "is this machine".
    it "reports RrLoopbackHost carrying the configured host, before host validation" $ do
      let loop = goodMachine { mfcHost = Just "localhost" }
          reg = resolveMachines True paths (cfgWith Nothing [("loop", loop)])
      Map.lookup (machineName "loop") (regRejected reg)
        `shouldBe` Just (RrLoopbackHost "localhost")

    it "does not hardcode localhost — a 127.0.0.1 machine reports 127.0.0.1" $ do
      let loop = goodMachine { mfcHost = Just "127.0.0.1" }
          reg = resolveMachines True paths (cfgWith Nothing [("loop", loop)])
      Map.lookup (machineName "loop") (regRejected reg)
        `shouldBe` Just (RrLoopbackHost "127.0.0.1")

    it "rejects a machine missing workspace with RrMissingField" $ do
      let broken = goodMachine { mfcWorkspace = Nothing }
          reg = resolveMachines True paths (cfgWith Nothing [("broken", broken)])
      Map.lookup (machineName "broken") (regRejected reg)
        `shouldBe` Just (RrMissingField MissingWorkspace)

    it "rejects a machine missing host, user, or port out of range" $ do
      let cases :: [(T.Text, MachineFileConfig, RejectReason)]
          cases =
            [ ("nohost", goodMachine { mfcHost = Nothing }, RrMissingField MissingHost)
            , ("nouser", goodMachine { mfcUser = Nothing }, RrMissingField MissingUser)
            , ("badport", goodMachine { mfcPort = Just 70000 }, RrInvalidPort)
            ]
      mapM_ (\(n, m, want) ->
               -- MachineName's constructor is deliberately unexported, so read
               -- the single-entry map's value rather than constructing a key.
               Map.elems (regRejected (resolveMachines True paths
                                          (cfgWith Nothing [(n, m)])))
                 `shouldBe` [want]) cases

    -- A [machines.local] table is ignored (declined as a load error), but local
    -- stays implicit, and the operator is told via regWarnings.
    it "ignores a [machines.local] table, keeps the implicit local, and reports it" $ do
      let reg = resolveMachines True paths (cfgWith Nothing [("local", goodMachine)])
      Map.lookup localMachineName (regMachines reg) `shouldBe` Just MtLocal
      any ("local" `T.isInfixOf`) (regWarnings reg) `shouldBe` True

    it "drops a default naming no resolved machine, and reports it" $ do
      let reg = resolveMachines True paths
                  (cfgWith (Just "ghost") [("builder", goodMachine)])
      regDefault reg `shouldBe` Nothing
      any ("ghost" `T.isInfixOf`) (regWarnings reg) `shouldBe` True

    it "accepts a default naming a resolved machine with no warning about it" $ do
      let reg = resolveMachines True paths
                  (cfgWith (Just "builder") [("builder", goodMachine)])
      regDefault reg `shouldBe` Just (machineName "builder")

    it "leaves a rejected machine out of regMachines" $ do
      let broken = goodMachine { mfcWorkspace = Nothing }
          reg = resolveMachines True paths (cfgWith Nothing [("broken", broken)])
      Map.member (machineName "broken") (regMachines reg) `shouldBe` False
      Map.member (machineName "broken") (regRejected reg) `shouldBe` True

    -- MachineSlot identity: the name lives in the map key, never in MtSsh.
    it "MtSsh carries no machine name (the map key does)" $ do
      let reg = resolveMachines True paths
                  (cfgWith Nothing [("builder", goodMachine)])
      case Map.lookup (machineName "builder") (regMachines reg) of
        Just (MtSsh _) -> pure ()
        other -> expectationFailure ("expected MtSsh, got " <> show other)

  describe "resolveMachines properties" $ do
    it "every resolved MtSsh has a non-loopback host" $
      property $ \(Positive (n :: Int)) ->
        let host = "host" <> T.pack (show (n `mod` 1000)) <> ".example.com"
            m = MachineFileConfig (Just host) (Just "u") (Just 22) Nothing (Just "/w")
            reg = resolveMachines True testPaths
                    (MachinesConfig Nothing (Map.fromList [("m", m)]))
        in case Map.lookup (machineName "m") (regMachines reg) of
             Just (MtSsh c) -> not (isLoopbackHost (getSshHost (scHost c)))
             _              -> True

    it "local is present iff allow_localhost, over both flag values" $
      property $ \(flag :: Bool) ->
        let reg = resolveMachines flag testPaths nullMachines
        in Map.member localMachineName (regMachines reg) === flag

    it "a rejected machine never appears in regMachines" $
      property $ \(bad :: String) ->
        let h = T.pack (take 40 bad)
            m = MachineFileConfig (Just h) (Just "u") (Just 22) Nothing Nothing
            reg = resolveMachines True testPaths
                    (MachinesConfig Nothing (Map.fromList [("m", m)]))
        in Map.member (machineName "m") (regMachines reg) === not (Map.member (machineName "m") (regRejected reg))

-- Helpers -----------------------------------------------------------------

-- | Test-only: build a 'MachineName' from a literal, panicking on an invalid
-- one. The production constructor is deliberately unexported; this helper keeps
-- the specs readable without adding an 'IsString' instance that would let any
-- literal bypass validation.
machineName :: T.Text -> MachineName
machineName t = case mkMachineName t of
  Right n -> n
  Left e  -> error ("MachinesSpec: invalid test machine name " <> show t <> ": " <> T.unpack e)

testPaths :: SealPaths
testPaths = SealPaths "/h" "/h/config" "/h/state" "/h/keys" "/h/cache"

nullMachines :: MachinesConfig
nullMachines = MachinesConfig Nothing Map.empty

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight _         = False

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _        = False

isMtSsh :: MachineTarget -> Bool
isMtSsh (MtSsh _) = True
isMtSsh MtLocal   = False

-- WU-7: file IO, the template, and the boot entry point ---------------------

specIO :: SpecWith ()
specIO = describe "Seal.Config.Machines (file IO)" $ do

  around withTempSealPaths $ do

    describe "loadMachinesConfig" $ do

      it "a missing file is an empty configuration, not an error" $ \paths -> do
        loaded <- loadMachinesConfig paths
        loaded `shouldBe` Right defaultMachinesConfig

      -- Regression: the idiomatic hand-written style writes only
      -- [machines.<name>] sub-tables and never a bare [machines] header.
      -- tomland's tableMap silently returned an EMPTY map for that shape, so a
      -- file full of correct machines decoded as "no machines configured" —
      -- which, with allow_localhost = false, is the state that refuses to run
      -- anything.
      it "decodes [machines.<name>] sub-tables with no bare [machines] header" $ \paths -> do
        writeFile (machinesFilePath paths) $ unlines
          [ "default = \"builder\""
          , "[machines.builder]"
          , "host = \"exec.internal\""
          , "user = \"agent\""
          , "workspace = \"/srv/agent-workspace\""
          ]
        loaded <- loadMachinesConfig paths
        case loaded of
          Right cfg -> do
            Map.keys (mcMachines cfg) `shouldBe` ["builder"]
            mcDefault cfg `shouldBe` Just "builder"
          Left err -> expectationFailure ("decode failed: " <> T.unpack err)

      it "a malformed file is Left naming the file" $ \paths -> do
        writeFile (machinesFilePath paths) "default = 5\n[[["
        loaded <- loadMachinesConfig paths
        case loaded of
          Left err -> err `shouldSatisfy` T.isInfixOf "machines.toml"
          Right _  -> expectationFailure "expected Left for a malformed file"

      it "round-trips through saveMachinesConfig" $ \paths -> do
        let cfg = defaultMachinesConfig
                    { mcDefault = Just "builder"
                    , mcMachines = Map.fromList
                        [ ("builder", MachineFileConfig (Just "b.example.com")
                                        (Just "seal") (Just 22) Nothing (Just "/srv/w")) ]
                    }
        saved <- saveMachinesConfig paths cfg
        saved `shouldBe` Right ()
        loaded <- loadMachinesConfig paths
        case loaded of
          Right back -> Map.keys (mcMachines back) `shouldBe` ["builder"]
          Left err   -> expectationFailure ("reload failed: " <> T.unpack err)

    describe "resolveMachinesForBoot" $ do

      it "an install with no machines.toml yields exactly one selectable machine" $ \paths -> do
        resolved <- resolveMachinesForBoot paths True
        case resolved of
          Right reg -> do
            Map.size (regMachines reg) `shouldBe` 1
            Map.member localMachineName (regMachines reg) `shouldBe` True
          Left err -> expectationFailure ("boot resolve failed: " <> T.unpack err)

      it "a malformed machines.toml fail-closes the boot" $ \paths -> do
        writeFile (machinesFilePath paths) "not = [valid"
        resolved <- resolveMachinesForBoot paths True
        case resolved of
          Left err -> err `shouldSatisfy` T.isInfixOf "machines.toml"
          Right _  -> expectationFailure "expected a boot failure for a malformed file"

    describe "the shipped template" $ do

      it "declares no live machine and no live default" $ \_ -> do
        -- The template must ship commented out: a live example machine plus a
        -- default would give a fresh install two selectable machines, a prompt,
        -- and a default pointing at an example host.
        let decoded = decodeMachinesConfig machinesTomlTemplate
        case decoded of
          Right cfg -> do
            mcMachines cfg `shouldBe` Map.empty
            mcDefault cfg `shouldBe` Nothing
          Left err -> expectationFailure ("template does not parse: " <> show err)

      it "is seeded on first run and never overwritten" $ \paths -> do
        _ <- ensureConfigTemplates paths
        exists <- doesFileExist (machinesFilePath paths)
        exists `shouldBe` True
        -- second call must not clobber
        writeFile (machinesFilePath paths) "# operator edit\n"
        _ <- ensureConfigTemplates paths
        contents <- readFile (machinesFilePath paths)
        contents `shouldBe` "# operator edit\n"

withTempSealPaths :: (SealPaths -> IO ()) -> IO ()
withTempSealPaths act = withSystemTempDirectory "seal-machines" $ \tmp ->
  act SealPaths
    { spHome = tmp
    , spConfig = tmp </> "config"
    , spState = tmp </> "state"
    , spKeys = tmp </> "keys"
    , spCache = tmp </> "cache"
    }
