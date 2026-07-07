{-# LANGUAGE OverloadedStrings #-}
module Seal.Tools.ArgsSpec (spec) where

import Data.Either (isLeft, isRight)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)

import Seal.Tools.Args
import Seal.TestHelpers.Arbitrary ()  -- Arbitrary Text

isControlOrNul :: Char -> Bool
isControlOrNul c = c < ' ' || c == '\DEL'

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

  describe "mkInterpName" $ do

    prop "rejects control chars, path separators, leading dash, empty" $ \(t :: Text) ->
      let isBad c = c == '/' || c == '\\' || isControlOrNul c
      in case mkInterpName t of
           Right n  -> let v = textInterpName n
                       in not (T.null v) && T.head v /= '-' && not (T.any isBad v)
           Left _   -> True

    it "rejects a path separator (interpreter must be a name, not a path)" $
      mkInterpName "python3.11/bin/python3" `shouldSatisfy` isLeft

    it "rejects empty" $
      mkInterpName "" `shouldSatisfy` isLeft

    it "accepts a clearly-good name" $
      mkInterpName "python3" `shouldSatisfy` isRight

  describe "mkScriptArg" $ do

    prop "Right results never contain NUL and never begin with dash" $ \(t :: Text) ->
      case mkScriptArg t of
        Right a  -> let v = textScriptArg a
                    in not (T.null v) && T.head v /= '-' && not (T.any (== '\0') v)
        Left _   -> True

    it "rejects empty" $
      mkScriptArg "" `shouldSatisfy` isLeft

    it "rejects a leading dash" $
      mkScriptArg "--flag" `shouldSatisfy` isLeft