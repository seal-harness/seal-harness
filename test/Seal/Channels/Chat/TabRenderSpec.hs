{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.Channels.Chat.TabRender' — the pure @\/tab list@
-- rendering rules (D5): @\<tab-id\> \<activity\> \<repo\>: \<name\>@.
module Seal.Channels.Chat.TabRenderSpec (spec) where

import Data.Aeson ((.=))
import Data.Aeson qualified as A
import Test.Hspec (Spec, describe, it, shouldBe)

import Seal.Channels.Chat.HttpClient (ListsJson (..), TabJson (..))
import Seal.Channels.Chat.TabRender
  ( TabListRow (..), renderTabListRow, tabListRows )

spec :: Spec
spec = do
  describe "renderTabListRow" $ do
    it "renders <id> <activity> <repo>: <name> when a repo is present" $
      renderTabListRow (TabListRow 0 True (Just "seal-harness") "fix websocket reconnect")
        `shouldBe` "0 busy seal-harness: fix websocket reconnect"

    it "renders <id> <activity>: <name> when there is no repo" $
      renderTabListRow (TabListRow 1 False Nothing "my tab")
        `shouldBe` "1 idle: my tab"

    it "renders indices above 9 as the terse-grammar letter" $
      renderTabListRow (TabListRow 10 False Nothing "x")
        `shouldBe` "a idle: x"

  describe "tabListRows" $ do
    it "marks a tab busy when its session is thinking" $
      let lj = ListsJson
            { ljTabs = [TabJson 0 (Just "s1") "session:ai" Nothing Nothing]
            , ljTabSessions = [A.object ["id" .= ("s1" :: String), "description" .= ("t" :: String)]]
            , ljThinkingSessionIds = ["s1"]
            }
      in map tlrBusy (tabListRows lj) `shouldBe` [True]

    it "marks a tab idle when its session is not thinking" $
      let lj = ListsJson
            { ljTabs = [TabJson 0 (Just "s1") "session:ai" Nothing Nothing]
            , ljTabSessions = []
            , ljThinkingSessionIds = []
            }
      in map tlrBusy (tabListRows lj) `shouldBe` [False]

    it "treats a running harness tab as busy" $
      let lj = ListsJson
            { ljTabs = [TabJson 2 Nothing "harness" Nothing (Just "running")]
            , ljTabSessions = []
            , ljThinkingSessionIds = []
            }
      in map tlrBusy (tabListRows lj) `shouldBe` [True]

    it "treats an exited harness tab as idle" $
      let lj = ListsJson
            { ljTabs = [TabJson 2 Nothing "harness" Nothing (Just "exited")]
            , ljTabSessions = []
            , ljThinkingSessionIds = []
            }
      in map tlrBusy (tabListRows lj) `shouldBe` [False]

    it "derives the repo from the session's repoUrl" $
      let lj = ListsJson
            { ljTabs = [TabJson 0 (Just "s1") "session:ai" Nothing Nothing]
            , ljTabSessions =
                [ A.object
                    [ "id" .= ("s1" :: String)
                    , "repoUrl" .= ("git@github.com:o/seal-harness.git" :: String)
                    ]
                ]
            , ljThinkingSessionIds = []
            }
      in map tlrRepo (tabListRows lj) `shouldBe` [Just "seal-harness"]

    it "omits the repo for a session with no repoUrl" $
      let lj = ListsJson
            { ljTabs = [TabJson 0 (Just "s1") "session:ai" Nothing Nothing]
            , ljTabSessions = [A.object ["id" .= ("s1" :: String)]]
            , ljThinkingSessionIds = []
            }
      in map tlrRepo (tabListRows lj) `shouldBe` [Nothing]

    it "prefers the tab label over the session description" $
      let lj = ListsJson
            { ljTabs = [TabJson 0 (Just "s1") "session:ai" (Just "Label") Nothing]
            , ljTabSessions =
                [ A.object
                    [ "id" .= ("s1" :: String)
                    , "description" .= ("Desc" :: String)
                    , "firstMessageSnippet" .= ("Snippet" :: String)
                    ]
                ]
            , ljThinkingSessionIds = []
            }
      in map tlrName (tabListRows lj) `shouldBe` ["Label"]

    it "falls back to the session id when nothing else is available" $
      let lj = ListsJson
            { ljTabs = [TabJson 0 (Just "20260719-120000-001") "session:ai" Nothing Nothing]
            , ljTabSessions = []
            , ljThinkingSessionIds = []
            }
      in map tlrName (tabListRows lj) `shouldBe` ["session:20260719-120"]

    it "names a harness tab 'harness' when it has no label" $
      let lj = ListsJson
            { ljTabs = [TabJson 1 Nothing "harness" Nothing (Just "running")]
            , ljTabSessions = []
            , ljThinkingSessionIds = []
            }
      in map tlrName (tabListRows lj) `shouldBe` ["harness"]
