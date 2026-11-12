{-# LANGUAGE OverloadedStrings #-}
module Seal.Tools.ArgsSpec (spec) where

import Data.Char (isControl)
import Data.Either (isLeft, isRight)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)

import Seal.Tools.Args
import Seal.TestHelpers.Arbitrary ()  -- Arbitrary Text

-- | A character git forbids in a refname: space, @~ ^ : ? * [@, backslash, or
-- any control character (which includes NUL).
refnameBadChar :: Char -> Bool
refnameBadChar c = c `elem` (" ~^:?*[\\" :: String) || isControl c

-- | The validator must accept @t@ verbatim (trimming is a no-op here).
accepts :: Text -> Expectation
accepts t = fmap branchNameText (mkBranchName t) `shouldBe` Right t

-- | The validator must accept @raw@ and canonicalise it to @expected@.
acceptsAs :: Text -> Text -> Expectation
acceptsAs raw expected =
  fmap branchNameText (mkBranchName raw) `shouldBe` Right expected

-- | The validator must reject @t@.
rejects :: Text -> Expectation
rejects t = mkBranchName t `shouldSatisfy` isLeft

spec :: Spec
spec = describe "Seal.Tools.Args" $ do

  describe "mkShellArg" $ do

    prop "never yields a Right value beginning with dash" $ \(t :: Text) ->
      case mkShellArg t of
        Right a  -> textShellArg a /= "" && T.head (textShellArg a) /= '-'
        Left _   -> True

    prop "Right results never contain NUL or newline" $ \(t :: Text) ->
      case mkShellArg t of
        Right a  -> not (T.any (\c -> c == '\0' || c == '\n') (textShellArg a))
        Left _   -> True

    prop "round-trips safe input" $ \(t :: Text) ->
      case mkShellArg t of
        Right a  -> textShellArg a == t
        Left _   -> True

    it "rejects empty" $
      mkShellArg "" `shouldSatisfy` isLeft

    it "rejects a leading dash" $
      mkShellArg "--evil" `shouldSatisfy` isLeft

    it "rejects NUL" $
      mkShellArg "foo\0bar" `shouldSatisfy` isLeft

    it "rejects a newline" $
      mkShellArg "foo\nbar" `shouldSatisfy` isLeft

    it "accepts a clearly-good arg" $
      mkShellArg "hello.txt" `shouldSatisfy` isRight

  describe "mkShellCommand" $ do

    prop "Right results never contain NUL" $ \(t :: Text) ->
      case mkShellCommand t of
        Right c  -> not (T.any (== '\0') (textShellCommand c))
        Left _   -> True

    it "rejects empty" $
      mkShellCommand "" `shouldSatisfy` isLeft

    it "rejects NUL" $
      mkShellCommand "echo\0whoami" `shouldSatisfy` isLeft

    it "accepts a simple command" $
      mkShellCommand "echo hello" `shouldSatisfy` isRight

  describe "mkBinName" $ do

    prop "Right results never contain NUL and are never empty" $ \(t :: Text) ->
      case mkBinName t of
        Right n  -> let v = textBinName n
                    in not (T.null v) && not (T.any (== '\0') v)
        Left _   -> True

    it "rejects empty" $
      mkBinName "" `shouldSatisfy` isLeft

    it "rejects NUL" $
      mkBinName "py\0thon" `shouldSatisfy` isLeft

    it "accepts a clearly-good name" $
      mkBinName "python3" `shouldSatisfy` isRight

    it "accepts a leading-dash name (no shell, so no option injection)" $
      mkBinName "-weird-name" `shouldSatisfy` isRight

    it "accepts a path (the executor uses RawCommand, paths are allowed)" $
      mkBinName "/usr/bin/python3" `shouldSatisfy` isRight

  describe "mkBinArg" $ do

    prop "Right results never contain NUL and are never empty" $ \(t :: Text) ->
      case mkBinArg t of
        Right a  -> let v = textBinArg a
                    in not (T.null v) && not (T.any (== '\0') v)
        Left _   -> True

    it "rejects empty" $
      mkBinArg "" `shouldSatisfy` isLeft

    it "rejects NUL" $
      mkBinArg "foo\0bar" `shouldSatisfy` isLeft

    it "accepts a leading-dash arg (a flag for the binary, not option injection)" $
      mkBinArg "--flag" `shouldSatisfy` isRight

  describe "mkBranchName" $ do

    prop "Right results are non-empty and never start with '-'" $ \(t :: Text) ->
      case mkBranchName t of
        Right b -> let v = branchNameText b
                   in not (T.null v) && T.head v /= '-'
        Left _  -> True

    prop "Right results contain no refname-invalid character or sequence" $ \(t :: Text) ->
      case mkBranchName t of
        Right b -> let v = branchNameText b
                   in not (T.any refnameBadChar v)
                      && not (".." `T.isInfixOf` v)
                      && not ("@{" `T.isInfixOf` v)
                      && not ("/" `T.isPrefixOf` v)
                      && not ("/" `T.isSuffixOf` v)
                      && not ("//" `T.isInfixOf` v)
                      && not ("." `T.isSuffixOf` v)
                      && not (".lock" `T.isSuffixOf` v)
        Left _  -> True

    prop "Right results round-trip through branchNameText as the trimmed input" $ \(t :: Text) ->
      case mkBranchName t of
        Right b -> branchNameText b == T.strip t
        Left _  -> True

    -- Accepted names (verbatim; trimming is a no-op).
    it "accepts \"main\"" $ accepts "main"
    it "accepts a namespaced branch" $ accepts "feature/foo-bar"
    it "accepts a release branch" $ accepts "release-1.2"
    it "accepts a version tag-like name" $ accepts "v1.0.0"

    -- Trimming.
    it "trims surrounding spaces" $ acceptsAs "  dev  " "dev"
    it "trims surrounding tabs and newlines" $ acceptsAs "\tdev\n" "dev"

    -- Rejections: emptiness / ambiguity / option injection.
    it "rejects the empty string" $ rejects ""
    it "rejects a whitespace-only name" $ rejects "   "
    it "rejects HEAD (it names a commit, not a branch)" $ rejects "HEAD"
    it "names HEAD in the rejection message" $
      mkBranchName "HEAD"
        `shouldSatisfy` either (T.isInfixOf "HEAD") (const False)
    it "rejects a leading dash (option injection)" $ rejects "-x"
    it "mentions option injection for a leading dash" $
      mkBranchName "-x"
        `shouldSatisfy` either (T.isInfixOf "option injection") (const False)
    it "rejects a leading-dash long option" $ rejects "--upload-pack=x"

    -- Rejections: git refname-invalid characters.
    it "rejects a space" $ rejects "a b"
    it "rejects '~'" $ rejects "a~b"
    it "rejects '^'" $ rejects "a^b"
    it "rejects ':'" $ rejects "a:b"
    it "rejects '?'" $ rejects "a?b"
    it "rejects '*'" $ rejects "a*b"
    it "rejects '['" $ rejects "a[b"
    it "rejects a backslash" $ rejects "a\\b"
    it "rejects NUL" $ rejects "a\0b"

    -- Rejections: git refname history/sequence rules.
    it "rejects \"..\"" $ rejects "a..b"
    it "rejects \"@{\"" $ rejects "a@{b"
    it "rejects a leading '/'" $ rejects "/a"
    it "rejects a trailing '/'" $ rejects "a/"
    it "rejects \"//\"" $ rejects "a//b"
    it "rejects a trailing '.'" $ rejects "a."
    it "rejects a \".lock\" suffix" $ rejects "a.lock"
