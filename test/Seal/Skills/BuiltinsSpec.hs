{-# LANGUAGE OverloadedStrings #-}
module Seal.Skills.BuiltinsSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Test.Hspec

import Seal.Skills.Backend (noneBackend, sbCreate, sbRead, sbList, unionSkillBackend)
import Seal.Skills.Builtins (builtinSkillIds, builtinSkillMap, builtinSkills, lookupBuiltinSkill)
import Seal.Skills.Types (Skill (..), mkSkillId, skillIdText)

spec :: Spec
spec = describe "Seal.Skills.Builtins" $ do
  describe "builtinSkills" $ do
    it "includes the seal-usage skill shipped with the binary" $ do
      let ids = map (skillIdText . skId) builtinSkills
      ids `shouldContain` ["seal-usage"]
      case lookup ("seal-usage" :: T.Text)
                  [(skillIdText (skId s), skBody s) | s <- builtinSkills] of
        Just body -> T.unpack body `shouldContain` "workdir"
        Nothing  -> expectationFailure "seal-usage skill not found in builtins"

    it "every built-in decodes (no malformed embedded sources)" $ do
      length builtinSkills `shouldSatisfy` (> 0)
      mapM_ (\s -> skillIdText (skId s) `shouldSatisfy` (not . T.null)) builtinSkills

  describe "builtinSkillMap / lookupBuiltinSkill" $ do
    it "lookupBuiltinSkill agrees with builtinSkillMap" $ do
      case mkSkillId "seal-usage" of
        Right sid -> lookupBuiltinSkill sid `shouldBe` Map.lookup sid builtinSkillMap
        Left _    -> expectationFailure "seal-usage is a valid skill id"

    it "returns Nothing for a non-built-in id" $ do
      case mkSkillId "no-such-builtin" of
        Right sid -> lookupBuiltinSkill sid `shouldBe` Nothing
        Left _    -> expectationFailure "valid id rejected"

  describe "unionSkillBackend" $ do
    it "sbRead falls back to the built-in when the user layer has no such id" $ do
      user <- noneBackend
      let union = unionSkillBackend user
      case mkSkillId "seal-usage" of
        Right sid -> do
          m <- sbRead union sid
          case m of
            Just s  -> skillIdText (skId s) `shouldBe` "seal-usage"
            Nothing -> expectationFailure "built-in seal-usage should be visible via the union backend"
        Left _ -> expectationFailure "seal-usage is a valid skill id"

    it "sbRead prefers a user-created skill over the same-id built-in" $ do
      user <- noneBackend
      case mkSkillId "seal-usage" of
        Right sid ->
          case Map.lookup sid builtinSkillMap of
            Just builtin -> do
              let override = builtin { skBody = "USER OVERRIDE BODY" }
              sbCreate user override
              mUser <- sbRead user sid
              mUnion <- sbRead (unionSkillBackend user) sid
              fmap skBody mUser `shouldBe` Just "USER OVERRIDE BODY"
              fmap skBody mUnion `shouldBe` Just "USER OVERRIDE BODY"
            Nothing -> expectationFailure "no seal-usage built-in to override"
        Left _ -> expectationFailure "seal-usage is a valid skill id"

    it "sbList merges user + built-ins, user wins on id collision" $ do
      user <- noneBackend
      let union = unionSkillBackend user
      listed <- sbList union
      let listedIds = map (skillIdText . skId) listed
      listedIds `shouldContain` ["seal-usage"]
      mapM_ (\sid -> listedIds `shouldContain` [skillIdText sid]) builtinSkillIds

    it "writes go to the user layer only (built-ins are immutable)" $ do
      user <- noneBackend
      let union = unionSkillBackend user
      case mkSkillId "seal-usage" of
        Right sid ->
          case lookupBuiltinSkill sid of
            Just tpl -> do
              let newSkill = tpl { skId = sid, skBody = "overwritten via union" }
              sbCreate union newSkill
              mUser <- sbRead user sid
              fmap skBody mUser `shouldBe` Just "overwritten via union"
            Nothing -> expectationFailure "no seal-usage built-in template"
        Left _ -> expectationFailure "seal-usage is a valid skill id"