{-# LANGUAGE OverloadedStrings #-}
module Seal.Tabs.PartitionSpec (spec) where

import Data.Either (fromRight)
import Data.List (nub)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec

import Seal.Core.Types (mkSessionId, SessionId)
import Seal.Handles.Tab (TabKind (..))
import Seal.Harness.Id (HarnessId, parseHarnessId)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Tabs.Partition (PartitionedSessions (..), partitionSessions)
import Seal.Tabs.Types (TabList (..), TabRef (..), emptyTabList, insertTab)

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 43200)

mkSid :: String -> SessionId
mkSid s = fromRight (error "bad sid") (mkSessionId (T.pack s))

mkHid :: String -> HarnessId
mkHid s = fromRight (error "bad hid") (parseHarnessId (T.pack s))

mkMeta :: String -> SessionMeta
mkMeta s =
  SessionMeta
    { smId = mkSid s
    , smProvider = "ollama"
    , smModel = "llama3.2"
    , smChannel = "cli"
    , smAgent = Nothing
    , smSystemOverride = Nothing
    , smAgentName = Nothing, smRepoUrl = Nothing
    , smDescription = Nothing
    , smCreatedAt = sampleTime
    , smLastActive = sampleTime
    }

insert :: TabRef -> TabKind -> TabList -> TabList
insert ref kind tl = fromRight (error "insert failed") (insertTab ref kind Nothing tl)

spec :: Spec
spec = describe "partitionSessions" $ do
  it "empty tab list, one non-archived session -> recents" $ do
    let ps = partitionSessions emptyTabList [mkMeta "s1"] []
    psTabSessions ps `shouldBe` []
    psRecentSessions ps `shouldBe` [mkMeta "s1"]
    psArchivedSessions ps `shouldBe` []

  it "session bound to a tab -> tabSessions, not recents" $ do
    let tl = insert (BoundSession (mkSid "s1")) KindAi emptyTabList
        ps = partitionSessions tl [mkMeta "s1"] []
    psTabSessions ps `shouldBe` [mkMeta "s1"]
    psRecentSessions ps `shouldBe` []
    psArchivedSessions ps `shouldBe` []

  it "archived session with no tab -> archivedSessions" $ do
    let ps = partitionSessions emptyTabList [] [mkMeta "s1"]
    psArchivedSessions ps `shouldBe` [mkMeta "s1"]
    psRecentSessions ps `shouldBe` []
    psTabSessions ps `shouldBe` []

  it "archived + tab-bound -> tabSessions (tab wins)" $ do
    let tl = insert (BoundSession (mkSid "s1")) KindAi emptyTabList
        ps = partitionSessions tl [] [mkMeta "s1"]
    psTabSessions ps `shouldBe` [mkMeta "s1"]
    psArchivedSessions ps `shouldBe` []
    psRecentSessions ps `shouldBe` []

  it "harness tab does not pull a session into tabSessions" $ do
    let tl = insert (BoundHarness (mkHid "h1")) KindHarness emptyTabList
        ps = partitionSessions tl [mkMeta "s1"] []
    psTabSessions ps `shouldBe` []
    psRecentSessions ps `shouldBe` [mkMeta "s1"]

  it "mutual exclusion: no session id in two lists" $ do
    let tl = insert (BoundSession (mkSid "s1")) KindAi emptyTabList
        ps = partitionSessions tl [mkMeta "s1", mkMeta "s2"] [mkMeta "s3", mkMeta "s4"]
        allIds = map smId (psTabSessions ps <> psRecentSessions ps <> psArchivedSessions ps)
    allIds `shouldSatisfy` (\xs -> length xs == length (nub xs))

  it "completeness: every input session appears in exactly one output list" $ do
    let tl = insert (BoundSession (mkSid "s1")) KindAi emptyTabList
        recent = [mkMeta "s1", mkMeta "s2"]
        archived = [mkMeta "s3"]
        ps = partitionSessions tl recent archived
        allInputIds = map smId recent <> map smId archived
        allOutputIds = map smId (psTabSessions ps <> psRecentSessions ps <> psArchivedSessions ps)
    -- same set, same length (mutual exclusion guarantees no dup -> bijection)
    allOutputIds `shouldSatisfy` (\xs -> length xs == length allInputIds)
    allOutputIds `shouldSatisfy` all (`elem` allInputIds)