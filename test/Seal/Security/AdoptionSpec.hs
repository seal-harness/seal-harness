{-# LANGUAGE OverloadedStrings #-}
module Seal.Security.AdoptionSpec (spec) where

import Test.Hspec

import Seal.Security.Adoption

spec :: Spec
spec = describe "Seal.Security.Adoption.authorizeAdoption" $ do
  it "(Just CcCli, True) => Right ()" $
    authorizeAdoption (Just CcCli) True `shouldBe` Right ()
  it "(Just CcSignal, True) => Right ()" $
    authorizeAdoption (Just CcSignal) True `shouldBe` Right ()
  it "(Nothing, _) => Left AeHeadlessNoConsent" $
    authorizeAdoption Nothing True `shouldBe` Left AeHeadlessNoConsent
  it "(Just CcWeb, False) => Left AeConsentMissing" $
    authorizeAdoption (Just CcWeb) False `shouldBe` Left AeConsentMissing
  it "(Nothing, False) => Left AeHeadlessNoConsent (headless wins)" $
    authorizeAdoption Nothing False `shouldBe` Left AeHeadlessNoConsent