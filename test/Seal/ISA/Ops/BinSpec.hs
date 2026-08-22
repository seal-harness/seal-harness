{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.BinSpec (spec) where
import Control.Monad.IO.Class (liftIO)
import Data.Maybe (fromMaybe)
import Seal.Tools.Exec.UIO (runUIOWithEnv)
import Seal.Tools.Exec.UIO.Internal (mkTestUIOEnv)
import Seal.SourceControl.Clone (CloneDeps, stubCloneDeps)
import Data.Aeson (Value, object, (.=))
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Set qualified as Set
import Test.Hspec
import Test.QuickCheck (property)

import Seal.Core.AllowList (AllowList (..))
import Seal.ISA.Opcode (OpResult (..), Opcode, uoRun, uoAuthorize)
import Seal.ISA.Ops.Bin
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Security.Policy (SecurityPolicy (..), AutonomyLevel (..))
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Tools.Args (textBinArg, textBinName)
import Seal.Tools.Exec.Types (getRemotePath)
import Seal.Tools.Exec.UntrustedIO
  ( UntrustedIO (..), mkRemoteUntrustedIOStub )
import Seal.Types.App
import Seal.Types.Config
import Seal.Types.Env
import Seal.Logging.Logger (testSealLogger)
import Seal.TestHelpers.Arbitrary ()  -- Arbitrary Text

-- | Local replacement for the removed uoRunLegacy: runs the opcode's uoRun
-- in a UIOEnv built from the UntrustedIO + optional CloneDeps.
runOp :: UntrustedIO -> Maybe CloneDeps -> Opcode -> Value -> App OpResult
runOp uio mDeps op input =
  liftIO (runUIOWithEnv (mkTestUIOEnv uio (fromMaybe stubCloneDeps mDeps)) (uoRun op input))
runTestApp :: App a -> IO a
runTestApp act = do logger <- testSealLogger; env <- mkEnv logger defaultConfig; runApp env act

-- | A fake 'UntrustedIO' that records the binary invocation (binary, args,
-- and the cwd 'RemotePath' the opcode resolved) and returns canned output.
-- Other methods are the fail-closed stub.
fakeUio :: IORef [(Text, [Text], Maybe Text)] -> Text -> UntrustedIO
fakeUio seen canned = mkRemoteUntrustedIOStub
  { uioBinExec = \bin args mCwd -> do
      modifyIORef' seen (++ [( textBinName bin
                             , map textBinArg args
                             , fmap getRemotePath mCwd )])
      pure (Right canned)
  }

-- | A fake 'UntrustedIO' that records the binary invocation as a flat
-- string (binary + args, no cwd) — for tests that only check the
-- command line.
fakeUioFlat :: IORef [Text] -> Text -> UntrustedIO
fakeUioFlat seen canned = mkRemoteUntrustedIOStub
  { uioBinExec = \bin args _mCwd -> do
      modifyIORef' seen (++ [textBinName bin <> " " <> T.intercalate " " (map textBinArg args)])
      pure (Right canned)
  }

spec :: Spec
spec = describe "Seal.ISA.Ops.Bin" $ do

  describe "BIN_EXEC" $ do

    it "runs a binary via an allow-listed name" $ do
      seen <- newIORef []
      let uio = fakeUioFlat seen "42\n"
          allowList = Just (Set.fromList ["python3", "node"])
          op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) allowList
      r <- runTestApp (runOp uio Nothing op (object
        [ "binary" .= ("python3" :: String)
        , "args" .= (["-c", "print(42)"] :: [String])
        ]))
      orIsError r `shouldBe` False
      orParts r `shouldBe` [TrpText "42\n"]
      readIORef seen `shouldReturn` ["python3 -c print(42)"]

    it "binary not in allow-list -> Denied" $ do
      let allowList = Just (Set.fromList ["python3"])
          op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) allowList
      uoAuthorize op (object
        [ "binary" .= ("rm" :: String)
        , "args" .= (["-rf", "/"] :: [String])
        ]) `shouldBe` Left "BIN_EXEC: binary \"rm\" not in the allow-list"

    it "missing binary field -> error" $ do
      let op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) (Just Set.empty)
      uoAuthorize op (object ["args" .= (["x"] :: [String])])
        `shouldBe` Left "BIN_EXEC requires {binary:string, args:[string]}"

    it "args field is optional (defaults to [])" $ do
      seen <- newIORef []
      let uio = fakeUioFlat seen "ok\n"
          op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      r <- runTestApp (runOp uio Nothing op (object
        [ "binary" .= ("ls" :: String)
        ]))
      orIsError r `shouldBe` False
      readIORef seen `shouldReturn` ["ls "]

    it "binary with NUL -> Denied (validated BinName rejects NUL)" $ do
      let op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      uoAuthorize op (object
        [ "binary" .= ("ev\0il" :: String)
        ]) `shouldBe` Left "BIN_EXEC: invalid binary name"

    it "arg with NUL -> Denied (validated BinArg rejects NUL)" $ do
      let op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      uoAuthorize op (object
        [ "binary" .= ("ls" :: String)
        , "args" .= ["ok\0bad" :: String]
        ]) `shouldBe` Left "BIN_EXEC: invalid arg"

    it "leading-dash arg is permitted (flag, not option injection)" $ do
      let op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) (Just (Set.fromList ["ls"]))
      uoAuthorize op (object
        [ "binary" .= ("ls" :: String)
        , "args" .= (["-l", "-a"] :: [String])
        ]) `shouldBe` Right ()

    it "Nothing allow-list permits any binary (autonomy permitting)" $ do
      let op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      uoAuthorize op (object
        [ "binary" .= ("rm" :: String)
        , "args" .= (["-rf", "/"] :: [String])
        ]) `shouldBe` Right ()

    it "orRecorded captures the binary + arg count (secret-free, not the args)" $ do
      seen <- newIORef []
      let uio = fakeUioFlat seen ""
          op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      r <- runTestApp (runOp uio Nothing op (object
        [ "binary" .= ("node" :: String)
        , "args" .= (["-e", "console.log('hi')"] :: [String])
        ]))
      orRecorded r `shouldBe` object
        [ "binary" .= ("node" :: String)
        , "arg_count" .= (2 :: Int)
        , "cwd" .= (Nothing :: Maybe String)
        ]

  describe "BIN_EXEC cwd" $ do

    it "defaults cwd to Nothing when omitted (the executor anchors it to the workdir)" $ do
      seen <- newIORef []
      let uio = fakeUio seen "ok\n"
          op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      _ <- runTestApp (runOp uio Nothing op (object
        [ "binary" .= ("pwd" :: String)
        ]))
      readIORef seen `shouldReturn` [("pwd", [], Nothing)]

    it "passes a relative cwd as a RemotePath (workspace-relative)" $ do
      seen <- newIORef []
      let uio = fakeUio seen "ok\n"
          op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      _ <- runTestApp (runOp uio Nothing op (object
        [ "binary" .= ("pwd" :: String)
        , "cwd" .= ("subdir" :: String)
        ]))
      readIORef seen `shouldReturn` [("pwd", [], Just "subdir")]

    it "passes an absolute cwd as a RemotePath (not workspace-confined)" $ do
      seen <- newIORef []
      let uio = fakeUio seen "ok\n"
          op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      _ <- runTestApp (runOp uio Nothing op (object
        [ "binary" .= ("pwd" :: String)
        , "cwd" .= ("/tmp/seal-test" :: String)
        ]))
      readIORef seen `shouldReturn` [("pwd", [], Just "/tmp/seal-test")]

    it "rejects a @..@ cwd at the authorize gate (escape before execution)" $ do
      let op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      uoAuthorize op (object
        [ "binary" .= ("ls" :: String)
        , "cwd" .= ("../escape" :: String)
        ]) `shouldBe` Left "BIN_EXEC: cwd escapes the workspace"

    it "rejects a blocked-name cwd at the authorize gate" $ do
      let op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      uoAuthorize op (object
        [ "binary" .= ("ls" :: String)
        , "cwd" .= (".ssh" :: String)
        ]) `shouldBe` Left "BIN_EXEC: cwd touches a blocked location"

    it "rejects a leading-dash cwd at the authorize gate (option injection)" $ do
      let op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      uoAuthorize op (object
        [ "binary" .= ("ls" :: String)
        , "cwd" .= ("-evil" :: String)
        ]) `shouldBe` Left "BIN_EXEC: cwd must not start with '-'"

    it "orRecorded captures the cwd (secret-free metadata)" $ do
      seen <- newIORef []
      let uio = fakeUio seen ""
          op = binExecOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) Nothing
      r <- runTestApp (runOp uio Nothing op (object
        [ "binary" .= ("pwd" :: String)
        , "cwd" .= ("subdir" :: String)
        ]))
      orRecorded r `shouldBe` object
        [ "binary" .= ("pwd" :: String)
        , "arg_count" .= (Nothing :: Maybe Int)
        , "cwd" .= ("subdir" :: String)
        ]

  describe "extractGhRepoFlag" $ do

    it "-R space-separated short: returns Just value" $
      extractGhRepoFlag ["-R", "owner/repo", "pr", "create"]
        `shouldBe` Just "owner/repo"

    it "-R joined short (-Rvalue): returns Just value" $
      extractGhRepoFlag ["-Rowner/repo", "pr", "create"]
        `shouldBe` Just "owner/repo"

    it "--repo space-separated long: returns Just value" $
      extractGhRepoFlag ["--repo", "owner/repo", "pr", "create"]
        `shouldBe` Just "owner/repo"

    it "--repo= joined long: returns Just value" $
      extractGhRepoFlag ["--repo=owner/repo", "pr", "create"]
        `shouldBe` Just "owner/repo"

    it "global flag AFTER subcommand: returns Just value" $
      extractGhRepoFlag ["pr", "create", "-R", "owner/repo"]
        `shouldBe` Just "owner/repo"

    it "no -R/--repo flag: returns Nothing" $
      extractGhRepoFlag ["pr", "create", "--title", "x"]
        `shouldBe` Nothing

    it "empty argv: returns Nothing" $
      extractGhRepoFlag [] `shouldBe` Nothing

    it "-R at end with no value: returns Nothing" $
      extractGhRepoFlag ["pr", "create", "-R"] `shouldBe` Nothing

    it "first -R value wins (when multiple -R flags)" $
      extractGhRepoFlag ["-R", "first/repo", "-R", "second/repo"]
        `shouldBe` Just "first/repo"

    it "QuickCheck: never crashes, returns Just first -R/--repo value or Nothing" $
      property $ \argv ->
        case extractGhRepoFlag argv of
          Just _  -> True
          Nothing -> not (hasAnyRepoFlag argv)
    where
      hasAnyRepoFlag :: [Text] -> Bool
      hasAnyRepoFlag = go
        where
          go [] = False
          go (x : xs)
            | x == "-R" = case xs of
                (_ : _) -> True
                []      -> False
            | "-R" `T.isPrefixOf` x
            , x /= "-R"
            = True
            | x == "--repo" = case xs of
                (_ : _) -> True
                []      -> False
            | "--repo=" `T.isPrefixOf` x
            = True
            | otherwise = go xs