{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Channels.Chat.LastRender' — the pure @\/last@ helpers.
--
-- WU-A covers argument parsing, error text, and help. The render half is
-- added by WU-B.
module Seal.Channels.Chat.LastRenderSpec (spec) where

import Data.Text qualified as T
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

import Data.Aeson ((.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap

import Seal.Channels.Chat.Class (QuestionOption (..))
import Seal.Channels.Chat.LastRender
  ( AssistantItem (..)
  , EntryFacts (..)
  , LastArgs (..)
  , LastError (..)
  , LastView (..)
  , PendingQuestion (..)
  , ResolveInput (..)
  , TabHeading (..)
  , ToolName (..)
  , ToolOutcome (..)
  , ToolState (..)
  , assistantItems
  , extractEntry
  , isLastHelpArg
  , lastHelp
  , parseLastArgs
  , quoteBody
  , renderLast
  , renderLastError
  , renderedTools
  , resolveLast
  , safeOpLabel
  , viewTag
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

  describe "safeOpLabel" $ do
    it "accepts real opcode names" $ do
      safeOpLabel "SHELL_EXEC" `shouldBe` Just "SHELL_EXEC"
      safeOpLabel "AGENT_DEF_LIST" `shouldBe` Just "AGENT_DEF_LIST"
      safeOpLabel "A" `shouldBe` Just "A"

    it "rejects lowercase, lowercase-first, and mixed" $ do
      safeOpLabel "shell_exec" `shouldBe` Nothing
      safeOpLabel "Shell" `shouldBe` Nothing

    it "rejects whitespace, JSON, paths and keys" $ do
      safeOpLabel "HAS SPACE" `shouldBe` Nothing
      safeOpLabel "{\"json\":1}" `shouldBe` Nothing
      safeOpLabel "A/B" `shouldBe` Nothing
      safeOpLabel "sk-live-abc" `shouldBe` Nothing

    it "rejects an over-long name" $
      safeOpLabel (T.replicate 33 "A") `shouldBe` Nothing

    it "rejects the empty name" $
      safeOpLabel "" `shouldBe` Nothing

  describe "extractEntry" $ do
    it "drops thinking blocks" $
      lefText (extractEntry (respEntry
        [ blk "thinking" [("thinking", "secret reasoning")] ])) `shouldBe` ""

    it "drops an unknown block type rather than rendering it as text" $
      lefText (extractEntry (respEntry
        [ blk "unrecognized" [("text", "{\"tag\":\"CbX\"}")] ])) `shouldBe` ""

    it "joins text blocks with a blank line, not by concatenation" $
      lefText (extractEntry (respEntry
        [ blk "text" [("text", "para one")]
        , blk "text" [("text", "para two")] ])) `shouldBe` "para one\n\npara two"

    it "contributes no text from a request entry" $
      lefText (extractEntry (reqEntry [] [blk "text" [("text", "user text")]]))
        `shouldBe` ""

    it "collects tool_use names from a response without their inputs" $
      map tnName (lefTools (extractEntry (respEntry
        [ blk "tool_use" [("id", "t1"), ("name", "SHELL_EXEC"), ("input", "{\"cmd\":\"ls\"}")] ])))
        `shouldBe` [Just "SHELL_EXEC"]

    it "collects (id, is_error) from a request, and nothing else" $
      lefResults (extractEntry (reqEntry
        [ blk "tool_result" [("tool_use_id", "t1"), ("is_error", "true")] ] []))
        `shouldBe` [("t1", True)]

    it "does not carry a tool input anywhere" $ do
      let f = extractEntry (respEntry
            [ blk "tool_use" [("id", "t1"), ("name", "SHELL_EXEC"), ("input", "SENTINEL")] ])
      -- The sentinel lives in the tool input; it must reach no field at all.
      T.intercalate "|" (lefText f : map tnId (lefTools f))
        `shouldSatisfy` (not . T.isInfixOf "SENTINEL")

  describe "assistantItems" $ do
    it "joins tool_use to its result: failed" $
      outcomes (assistantItems
        [ reqEntry [ blk "tool_result" [("tool_use_id", "t1"), ("is_error", "true")] ] []
        , respEntry [ blk "tool_use" [("id", "t1"), ("name", "SHELL_EXEC")] ] ])
        `shouldBe` [ (Just "SHELL_EXEC", LtsFailed) ]

    it "joins tool_use to its result: ok" $
      outcomes (assistantItems
        [ reqEntry [ blk "tool_result" [("tool_use_id", "t1"), ("is_error", "false")] ] []
        , respEntry [ blk "tool_use" [("id", "t1"), ("name", "BIN_EXEC")] ] ])
        `shouldBe` [ (Just "BIN_EXEC", LtsOk) ]

    it "reports unfinished when no result is in the window" $
      outcomes (assistantItems [ respEntry [ blk "tool_use" [("id", "t9"), ("name", "FILE_READ")] ] ])
        `shouldBe` [ (Just "FILE_READ", LtsUnfinished) ]

    it "prefers text over a tool when a response has both" $
      texts (assistantItems [ respEntry
        [ blk "text" [("text", "done")]
        , blk "tool_use" [("id", "t1"), ("name", "SHELL_EXEC")] ] ])
        `shouldBe` ["done"]

    it "maps a shape-invalid tool name to Nothing" $
      outcomes (assistantItems [ respEntry [ blk "tool_use" [("id", "t1"), ("name", "bad name")] ] ])
        `shouldBe` [ (Nothing, LtsUnfinished) ]

  describe "resolveLast" $ do
    let hd = TabHeading (mkIdx 'b') (Just "fix the flaky test")
        base = ResolveInput hd [] False Nothing 1 False

    it "prefers a pending question over everything" $
      viewTag (resolveLast base { lriQuestion = Just (PendingQuestion "Q?" [])
                                , lriThinking = True
                                , lriItems = [LriText "hi"] })
        `shouldBe` "question"

    it "reports still working with no completed tool" $ do
      let v = resolveLast base { lriThinking = True }
      viewTag v `shouldBe` "working"
      renderedTools v `shouldBe` []

    it "reports the last completed tool while working" $ do
      let v = resolveLast base
            { lriThinking = True
            , lriItems = [ LriToolOnly (ToolOutcome (Just "SHELL_EXEC") LtsFailed) ] }
      renderedTools v `shouldBe` ["\128187 SHELL_EXEC (failed)"]

    it "never reports an unfinished tool as the last completed one" $ do
      let v = resolveLast base
            { lriThinking = True
            , lriItems = [ LriToolOnly (ToolOutcome (Just "SHELL_EXEC") LtsUnfinished) ] }
      renderedTools v `shouldBe` []

    it "is empty with no items" $
      viewTag (resolveLast base) `shouldBe` "empty"

    it "is messages when there are items and it is not working" $
      viewTag (resolveLast base { lriItems = [LriText "hi"] }) `shouldBe` "messages"

  describe "renderLast" $ do
    let hd = TabHeading (mkIdx 'b') (Just "fix the flaky test")
        hdNoTitle = TabHeading (mkIdx 'b') Nothing
        em = "\8212"

    it "renders a single message" $
      renderLast (LastMessages hd [LriText "All 412 tests pass."])
        `shouldBe` "\128212 Tab b (fix the flaky test) " <> em
                   <> " last message:\n\nAll 412 tests pass."

    it "omits the title when there is none" $
      renderLast (LastEmpty hdNoTitle)
        `shouldBe` "\128212 Tab b " <> em <> " no messages yet."

    it "renders two messages with per-item attribution and a count" $
      renderLast (LastMessages hd [LriText "one", LriText "two"])
        `shouldBe` "\128212 Tab b (fix the flaky test) " <> em
                   <> " last 2 messages:\n\nb: one\n\nb: two"

    it "renders a tool-only item with the failed flag and no reply text" $
      renderLast (LastMessages hd
        [LriToolOnly (ToolOutcome (Just "SHELL_EXEC") LtsFailed)])
        `shouldBe` "\128212 Tab b (fix the flaky test) " <> em
                   <> " last message:\n\n\128187 SHELL_EXEC (failed) "
                   <> em <> " no reply text. /last b 5 for more."

    it "renders unfinished distinctly from ok" $ do
      let ok = renderLast (LastMessages hd
                 [LriToolOnly (ToolOutcome (Just "SHELL_EXEC") LtsOk)])
          un = renderLast (LastMessages hd
                 [LriToolOnly (ToolOutcome (Just "SHELL_EXEC") LtsUnfinished)])
      ok `shouldSatisfy` not . T.isInfixOf "(no result)"
      un `shouldSatisfy` T.isInfixOf "(no result)"

    it "renders an unknown opcode with the fallback glyph" $
      renderLast (LastMessages hd [LriToolOnly (ToolOutcome Nothing LtsOk)])
        `shouldSatisfy` T.isInfixOf "\9889 (unknown opcode)"

    it "renders still working with a completed tool" $
      renderLast (LastWorking hd (Just (ToolOutcome (Just "SHELL_EXEC") LtsFailed)))
        `shouldBe` "\128212 Tab b (fix the flaky test) " <> em
                   <> " still working:\n\nlast completed: \128187 SHELL_EXEC (failed)"

    it "renders still working with no completed tool" $
      renderLast (LastWorking hd Nothing)
        `shouldBe` "\128212 Tab b (fix the flaky test) " <> em
                   <> " still working:\n\nno tools have completed yet"

    it "renders a question block-quoted with the answer footer" $
      renderLast (LastQuestion hd (PendingQuestion "Which database?"
        [QuestionOption "Postgres" "existing cluster", QuestionOption "SQLite" "single file"]))
        `shouldSatisfy` T.isInfixOf ("> Which database?\n>\n> 1) Postgres " <> em
                                     <> " existing cluster\n> 2) SQLite " <> em <> " single file")

    it "names the answer path with the actual tab char" $
      renderLast (LastQuestion hd (PendingQuestion "Q?" []))
        `shouldSatisfy` T.isInfixOf "Answer with /b <your answer>."

    it "never emits the live-ask reply hint on the /last path" $
      renderLast (LastQuestion hd (PendingQuestion "Q?" [QuestionOption "y" ""]))
        `shouldSatisfy` not . T.isInfixOf "Reply with"

    it "degrades an empty message list to the empty view" $
      renderLast (LastMessages hd []) `shouldBe` renderLast (LastEmpty hd)

  describe "quoteBody" $ do
    it "prefixes non-blank lines and leaves a bare > on blank lines" $
      quoteBody "a\n\nb" `shouldBe` "> a\n>\n> b"

    it "normalises other line separators before quoting" $ do
      let q = quoteBody "a\r\nb\x2028\&c"
      q `shouldBe` "> a\n> b\n> c"

    it "makes it impossible to start a line at column zero" $ do
      let q = quoteBody "\128212 Tab a (main) \8212 last message:"
      q `shouldSatisfy` T.isPrefixOf "> "

-- Test-only projections -----------------------------------------------------
-- 'AssistantItem'/'ToolOutcome' deliberately have no 'Show' (the renderer's
-- content-bearing types must not be printable), so assertions go through these.

-- | The tool outcomes in a list of items.
outcomes :: [AssistantItem] -> [(Maybe T.Text, ToolState)]
outcomes items = [ (lsaName o, lsaState o) | LriToolOnly o <- items ]

-- | The text payloads in a list of items.
texts :: [AssistantItem] -> [T.Text]
texts items = [ t | LriText t <- items ]

-- Test-only JSON helpers -----------------------------------------------------

-- | A content block.
blk :: T.Text -> [(T.Text, T.Text)] -> A.Value
blk ty kvs = A.object $
  ("type" .= ty) : [ Key.fromText k .= v | (k, v) <- kvs ]

-- | A response-direction transcript entry with the given content blocks.
respEntry :: [A.Value] -> A.Value
respEntry blocks = A.object
  [ "direction" .= ("response" :: T.Text)
  , "payload"   .= A.object [ "content" .= blocks ]
  ]

-- | A request-direction entry: tool-result blocks live under messages[].content.
reqEntry :: [A.Value] -> [A.Value] -> A.Value
reqEntry toolResults _extra = A.object
  [ "direction" .= ("request" :: T.Text)
  , "payload"   .= A.object
      [ "messages" .= [ A.object
          [ "role"    .= ("user" :: T.Text)
          , "content" .= map fixErr toolResults
          ] ] ]
  ]
  where
    -- 'is_error' arrives as a string from 'blk'; make it a real Bool.
    fixErr (A.Object o) = case KeyMap.lookup (Key.fromText "is_error") o of
      Just (A.String "true")  -> A.Object (KeyMap.insert (Key.fromText "is_error") (A.Bool True) o)
      Just (A.String "false") -> A.Object (KeyMap.insert (Key.fromText "is_error") (A.Bool False) o)
      _ -> A.Object o
    fixErr v = v
