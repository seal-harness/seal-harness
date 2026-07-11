{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module Seal.Tools.Exec.TypesSpec (spec) where

import Data.Either (isLeft, isRight)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck ()

import Seal.Tools.Exec.Types

import Seal.TestHelpers.Arbitrary ()  -- Arbitrary Text

isBadTargetChar :: Char -> Bool
isBadTargetChar c = c == '/' || c == '\\' || c == ':' || c < ' ' || c == '\DEL'

isBadSshNameChar :: Char -> Bool
isBadSshNameChar c = c < ' ' || c == ' ' || c == ':' || c == '\DEL'

spec :: Spec
spec = describe "Seal.Tools.Exec.Types" $ do

  describe "mkContainerTarget" $ do

    prop "never yields a Right value beginning with dash" $ \(t :: Text) ->
      case mkContainerTarget t of
        Right ct -> T.head (getContainerTarget ct) /= '-'
        Left _   -> True

    prop "Right results never contain slash, backslash, colon, or control chars and never empty" $ \(t :: Text) ->
      case mkContainerTarget t of
        Right ct -> let v = getContainerTarget ct
                    in  not (T.null v) && not (T.any isBadTargetChar v)
        Left _   -> True

    prop "round-trips safe input" $ \(t :: Text) ->
      case mkContainerTarget t of
        Right ct -> getContainerTarget ct == t
        Left _   -> True

    it "rejects --flag (option injection)" $
      mkContainerTarget "--flag" `shouldSatisfy` isLeft

    it "rejects empty" $
      mkContainerTarget "" `shouldSatisfy` isLeft

    prop "rejects any leading-dash value" $ \(t :: Text) ->
      let t' = "-" <> t
      in mkContainerTarget t' `shouldSatisfy` \case
             Right ct -> T.head (getContainerTarget ct) /= '-'
             Left _   -> True

    it "accepts a clearly-good target" $
      mkContainerTarget "ubuntu-22.04" `shouldSatisfy` isRight

    it "rejects a path separator" $
      mkContainerTarget "a/b" `shouldSatisfy` isLeft

    it "rejects a colon (option-injection / port-syntax defense)" $
      mkContainerTarget "host:port" `shouldSatisfy` isLeft

  describe "mkSshHost" $ do

    prop "rejects control, space, and colon characters" $ \(t :: Text) ->
      case mkSshHost t of
        Right h  -> not (T.any isBadSshNameChar (getSshHost h))
        Left _   -> True

    it "rejects empty" $
      mkSshHost "" `shouldSatisfy` isLeft

  describe "mkSshUser" $ do

    prop "rejects control, space, and colon characters" $ \(t :: Text) ->
      case mkSshUser t of
        Right u  -> not (T.any isBadSshNameChar (getSshUser u))
        Left _   -> True

    it "rejects empty" $
      mkSshUser "" `shouldSatisfy` isLeft

  describe "TerminalBackend" $ do

    it "constructs all four variants" $ do
      let _x1 = TbLocal
          _x2 = TbTmux TmuxConfig
          _x3 = TbSsh sshPlaceholder
          _x4 = TbContainer containerPlaceholder
      pure () :: IO ()

sshPlaceholder :: SshConfig
sshPlaceholder = SshConfig
  { scHost       = either (error "test fixture") id (mkSshHost "exec.internal")
  , scUser       = either (error "test fixture") id (mkSshUser "agent")
  , scPort       = 22
  , scIdentity   = Nothing
  , scKnownHosts = "/home/agent/.ssh/known_hosts"
  , scWorkspace  = either (error "test fixture") id (mkRemotePath "/srv/agent-workspace")
  }

containerPlaceholder :: ContainerSpec
containerPlaceholder = ContainerSpec
  { csTarget = either (error "test fixture") id (mkContainerTarget "ubuntu-22.04")
  , csImage  = "ubuntu:22.04"
  }