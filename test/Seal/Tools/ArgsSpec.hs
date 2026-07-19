{-# LANGUAGE OverloadedStrings #-}
module Seal.Tools.ArgsSpec (spec) where

import Data.Either (isLeft, isRight)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)

import Seal.Tools.Args
import Seal.TestHelpers.Arbitrary ()  -- Arbitrary Text

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