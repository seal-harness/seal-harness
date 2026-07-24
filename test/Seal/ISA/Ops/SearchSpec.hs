{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.SearchSpec (spec) where

import Data.Aeson (object, (.=))
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Set qualified as Set
import Test.Hspec

import Seal.Core.AllowList (AllowList (..))
import Seal.ISA.Opcode (OpResult (..), uoRun, uoAuthorize)
import Seal.ISA.Ops.Search
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Security.Policy (SecurityPolicy (..), AutonomyLevel (..))
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Tools.Args (textSearchPattern)
import Seal.Tools.Exec.UntrustedIO
  ( UntrustedIO (..), mkRemoteUntrustedIOStub )
import Seal.Types.App
import Seal.Types.Config
import Seal.Types.Env

runTestApp :: App a -> IO a
runTestApp act = do env <- mkEnv defaultConfig; runApp env act

-- | A fake 'UntrustedIO' whose 'uioSearchFiles' records the pattern + path
-- and returns canned output.
fakeUio :: IORef [Text] -> Text -> UntrustedIO
fakeUio seen canned = mkRemoteUntrustedIOStub
  { uioSearchFiles = \pat _mPath _limit -> do
      modifyIORef' seen (++ ["rg -n -- " <> textSearchPattern pat <> " ."])
      pure (Right canned)
  }

spec :: Spec
spec = describe "Seal.ISA.Ops.Search" $ do

  describe "SEARCH_FILES" $ do

    it "runs a search via rg and returns matching lines" $ do
      seen <- newIORef []
      let uio = fakeUio seen "src/Foo.hs:1:hello\nsrc/Bar.hs:3:world\n"
          op = searchFilesOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) 100
      r <- runTestApp (uoRun op uio (object
        [ "pattern" .= ("hello" :: String)
        , "path" .= ("src" :: String)
        ]))
      orIsError r `shouldBe` False
      orParts r `shouldSatisfy` \case [TrpText t] -> "hello" `T.isInfixOf` t; _ -> False

    it "rejects a pattern starting with dash (option injection)" $ do
      let op = searchFilesOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) 100
      uoAuthorize op (object ["pattern" .= ("--flag" :: String), "path" .= ("." :: String)])
        `shouldBe` Left "SEARCH_FILES: pattern must not start with '-' (option injection)"

    it "missing pattern field -> error" $ do
      let op = searchFilesOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) 100
      uoAuthorize op (object ["path" .= ("." :: String)])
        `shouldBe` Left "SEARCH_FILES requires {pattern:string}"

    it "orRecorded captures pattern + path + result count (secret-free)" $ do
      seen <- newIORef []
      let uio = fakeUio seen "a.hs:1:foo\nb.hs:2:bar\n"
          op = searchFilesOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) 100
      r <- runTestApp (uoRun op uio (object
        [ "pattern" .= ("foo" :: String)
        , "path" .= ("." :: String)
        ]))
      orRecorded r `shouldBe` object
        [ "pattern" .= ("foo" :: String)
        , "path" .= ("." :: String)
        , "result_count" .= (2 :: Int)
        ]

    it "Deny policy -> Denied" $ do
      let op = searchFilesOp (WorkspaceRoot "/ws") (SecurityPolicy (AllowOnly Set.empty) Deny) 100
      uoAuthorize op (object ["pattern" .= ("x" :: String), "path" .= ("." :: String)])
        `shouldBe` Left "SEARCH_FILES denied by autonomy policy"

    it "result count is bounded by the operator ceiling" $ do
      seen <- newIORef []
      let uio = fakeUio seen "a:1:x\nb:2:x\nc:3:x\n"  -- 3 results
          op = searchFilesOp (WorkspaceRoot "/ws") (SecurityPolicy AllowAll Full) 2
      r <- runTestApp (uoRun op uio (object
        [ "pattern" .= ("x" :: String)
        , "path" .= ("." :: String)
        ]))
      orRecorded r `shouldBe` object
        [ "pattern" .= ("x" :: String)
        , "path" .= ("." :: String)
        , "result_count" .= (2 :: Int)
        ]