{-# LANGUAGE OverloadedStrings #-}
module Seal.Security.PolicySpec (spec) where

import Data.Set qualified as Set
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (property)

import Seal.Security.Policy

spec :: Spec
spec = describe "Seal.Security.Policy" $ do

  it "defaultPolicy denies every command" $
    property $ \(s :: String) ->
      not (isCommandAllowed defaultPolicy (CommandName (T.pack s)))

  it "defaultPolicy has Deny autonomy" $
    spAutonomy defaultPolicy `shouldBe` Deny

  it "AllowOnly permits listed commands only" $ do
    let p = SecurityPolicy (AllowOnly (Set.fromList [CommandName "git"])) Full
    isCommandAllowed p (CommandName "git") `shouldBe` True
    isCommandAllowed p (CommandName "rm")  `shouldBe` False

  it "AllowAll permits any command" $
    property $ \(s :: String) ->
      isCommandAllowed (SecurityPolicy AllowAll Full) (CommandName (T.pack s))

  prop "AllowOnly membership matches Set.member exactly" $
    \(s :: String) (names :: [String]) ->
      let nameSet = Set.fromList (map (CommandName . T.pack) names)
          p       = SecurityPolicy (AllowOnly nameSet) Full
          cmd     = CommandName (T.pack s)
      in isCommandAllowed p cmd == Set.member cmd nameSet
