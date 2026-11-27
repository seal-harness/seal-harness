{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Channels.Chat.LastRender' — the pure @\/last@ helpers.
--
-- WU-A covers argument parsing, error text, and help. The render half is
-- added by WU-B.
module Seal.Channels.Chat.LastRenderSpec (spec) where

import Data.Text qualified as T
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

import Seal.Channels.Chat.LastRender
  ( LastArgs (..)
  , LastError (..)
  , isLastHelpArg
  , lastHelp
  , parseLastArgs
  , renderLastError
  )
import Seal.Gateway.Types.Tab (TabIndex, tabIndexFromChar)

-- | The tab index a single character denotes (test-only; crashes on invalid).
mkIdx :: Char -> TabIndex
mkIdx c = either (error . T.unpack) id (tabIndexFromChar c)

spec :: Spec
spec = do
  describe "parseLastArgs" $ do
    it "defaults to the focused tab and one message" $
      parseLastArgs "" `shouldBe` Right (LastArgs Nothing 1)

    it "parses a bare tab" $
      parseLastArgs "b" `shouldBe` Right (LastArgs (Just (mkIdx 'b')) 1)

    it "parses a tab and a count" $
      parseLastArgs "b 3" `shouldBe` Right (LastArgs (Just (mkIdx 'b')) 3)

    it "accepts an upper-case tab and canonicalises it" $
      parseLastArgs "B" `shouldBe` Right (LastArgs (Just (mkIdx 'b')) 1)

    it "treats a single digit as a tab, not a count" $
      parseLastArgs "3" `shouldBe` Right (LastArgs (Just (mkIdx '3')) 1)

    it "clamps a count of 0 up to 1" $
      parseLastArgs "b 0" `shouldBe` Right (LastArgs (Just (mkIdx 'b')) 1)

    it "clamps a large count down to 5" $
      parseLastArgs "b 9" `shouldBe` Right (LastArgs (Just (mkIdx 'b')) 5)

    it "rejects a non-numeric count" $
      parseLastArgs "b foo" `shouldBe` Left (LEBadCount "foo")

    it "rejects a multi-character tab token" $
      parseLastArgs "bb" `shouldBe` Left (LENoSuchTab "bb")

    it "rejects a tab token that is not a tab char" $
      parseLastArgs "foo" `shouldBe` Left (LENoSuchTab "foo")

    it "ignores tokens past the count" $
      parseLastArgs "b 2 junk" `shouldBe` Right (LastArgs (Just (mkIdx 'b')) 2)

  describe "renderLastError" $ do
    it "names the bad tab and points at /tab list" $
      renderLastError (LENoSuchTab "z")
        `shouldBe` "last failed: no such tab z \8212 /tab list"

    it "quotes the bad count and shows the range" $
      renderLastError (LEBadCount "foo")
        `shouldBe` "last failed: \"foo\" isn't a number \8212 use /last <tab> 1-5"

    it "explains a harness tab" $
      renderLastError (LENoSession 'b')
        `shouldBe` "last failed: tab b has no session (harness tab)"

    it "reports no current tab" $
      renderLastError LENoCurrentTab
        `shouldBe` "last failed: no current tab"

    it "reports a tab-list fetch failure" $
      renderLastError LETabs `shouldSatisfy` T.isInfixOf "couldn't read the tab list"

    it "names the tab whose transcript failed" $
      renderLastError (LETranscript 'b')
        `shouldSatisfy` T.isInfixOf "couldn't read tab b's transcript"

    it "names the tab whose question failed" $
      renderLastError (LEQuestions 'b')
        `shouldSatisfy` T.isInfixOf "couldn't read tab b's question"

    it "flattens newlines in echoed user text (no heading spoofing)" $ do
      let rendered = renderLastError (LENoSuchTab "x\n\n\128212 Tab a \8212 hi")
      rendered `shouldSatisfy` (not . T.isInfixOf "\n")

    it "bounds the length of echoed user text" $ do
      let rendered = renderLastError (LEBadCount (T.replicate 500 "9"))
      T.length rendered `shouldSatisfy` (< 120)

  describe "isLastHelpArg" $ do
    it "accepts -h and --help" $ do
      isLastHelpArg "-h" `shouldBe` True
      isLastHelpArg "--help" `shouldBe` True

    it "rejects a tab argument" $
      isLastHelpArg "b" `shouldBe` False

    it "rejects help after another argument" $
      isLastHelpArg "b -h" `shouldBe` False

  describe "lastHelp" $ do
    it "documents the tab argument and the count range" $ do
      lastHelp `shouldSatisfy` T.isInfixOf "[tab] [n]"
      lastHelp `shouldSatisfy` T.isInfixOf "1-5"

    it "says it never changes the focused tab" $
      lastHelp `shouldSatisfy` T.isInfixOf "never changes the tab you are focused on"

    it "documents the answer path" $
      lastHelp `shouldSatisfy` T.isInfixOf "/N <answer>"

    it "warns that the first argument is always the tab" $
      lastHelp `shouldSatisfy` T.isInfixOf "always the tab"

    it "renders the tab char 3 as tab 3, not three messages" $
      lastHelp `shouldSatisfy` T.isInfixOf "/last 3 means tab 3"
