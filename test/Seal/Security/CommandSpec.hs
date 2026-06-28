{-# LANGUAGE OverloadedStrings #-}
module Seal.Security.CommandSpec (spec) where

import Data.Set qualified as Set
import Test.Hspec
import Test.Hspec.QuickCheck (prop)

import Seal.Security.Command
import Seal.Security.Policy

gitPolicy :: SecurityPolicy
gitPolicy = SecurityPolicy (AllowOnly (Set.fromList [CommandName "git"])) Full

shellPolicy :: SecurityPolicy
shellPolicy = SecurityPolicy (AllowOnly (Set.fromList [CommandName "shell"])) Full

spec :: Spec
spec = describe "Seal.Security.Command" $ do

  it "authorizes an allowed program" $
    fmap authorizedProgram (authorize gitPolicy "/usr/bin/git" ["status"])
      `shouldBe` Right ("/usr/bin/git", ["status"])

  it "rejects a disallowed program" $
    authorize gitPolicy "/bin/rm" ["-rf", "/"]
      `shouldBe` Left (CommandNotAllowed "rm")

  it "rejects everything under Deny autonomy" $
    authorize (SecurityPolicy AllowAll Deny) "/usr/bin/git" ["status"]
      `shouldBe` Left CommandInAutonomyDeny

  it "basename matching preserves full program path" $
    fmap authorizedProgram (authorize gitPolicy "/usr/bin/git" ["log"])
      `shouldBe` Right ("/usr/bin/git", ["log"])

  prop "AllowAll Full policy allows any program" $
    \(prog :: String) ->
      let p = SecurityPolicy AllowAll Full
      in case authorize p prog [] of
           Right _ -> True
           Left _  -> False

  it "authorizeShell when shell is allowed returns /bin/sh -c" $ do
    let cmd = "echo hello"
    fmap authorizedProgram (authorizeShell shellPolicy cmd)
      `shouldBe` Right ("/bin/sh", ["-c", cmd])

  it "authorizeShell when shell is not allowed returns CommandNotAllowed" $
    authorizeShell gitPolicy "echo hello"
      `shouldBe` Left (CommandNotAllowed "shell")

  it "authorizeShell under Deny autonomy returns CommandInAutonomyDeny" $
    authorizeShell (SecurityPolicy AllowAll Deny) "echo hello"
      `shouldBe` Left CommandInAutonomyDeny
