{-# LANGUAGE OverloadedStrings #-}
module Seal.Tabs.PersistSpec (spec) where

import Control.Exception (evaluate)
import Data.Text qualified as T
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Core.Types (mkSessionId, SessionId)
import Seal.Handles.Tab (TabKind (KindAi, KindProvider, KindHarness))
import Seal.Harness.Id (parseHarnessId)
import Seal.Tabs (newTabsHandle, insertTabH, snapshotTabs, newPersistingTabsHandle)
import Seal.Tabs.Persist (saveTabList, loadTabList)
import Seal.Tabs.Types (TabRef (BoundSession, BoundHarness), tlTabs)

mkSid :: String -> SessionId
mkSid s = case mkSessionId (T.pack s) of
  Right x -> x
  Left _  -> error ("bad sid: " <> s)

-- | Strict readFile (avoid the lazy-handle ResourceBusy on the rewrite:
-- force the contents so the handle closes before the next writeFile).
readFileStrict :: FilePath -> IO String
readFileStrict path = do
  s <- readFile path
  _ <- evaluate (length s)
  pure s

spec :: Spec
spec = describe "Seal.Tabs.Persist" $ do
  describe "saveTabList/loadTabList round-trip" $ do
    it "save then load returns the tab list" $
      withSystemTempDirectory "seal-persist" $ \dir -> do
        let path = dir </> "tabs.json"
        h <- newTabsHandle
        _ <- insertTabH h (BoundSession (mkSid "20260701-120000-001")) KindAi Nothing
        tl <- snapshotTabs h
        saveTabList path tl
        mLoaded <- loadTabList path
        mLoaded `shouldSatisfy` \case
          Just tl' -> length (tlTabs tl') == 1
          Nothing -> False

    it "missing file -> Nothing" $
      withSystemTempDirectory "seal-persist" $ \dir -> do
        let path = dir </> "nonexistent.json"
        m <- loadTabList path
        m `shouldBe` Nothing

    it "corrupt JSON -> Nothing (does not throw)" $
      withSystemTempDirectory "seal-persist" $ \dir -> do
        let path = dir </> "tabs.json"
        writeFile path "not valid json {{{"
        m <- loadTabList path
        m `shouldBe` Nothing

  describe "auto-save-on-mutation (persisting handle)" $ do
    it "insertTabH via newPersistingTabsHandle triggers a save (loadTabList returns the new tab)" $
      withSystemTempDirectory "seal-persist" $ \dir -> do
        let path = dir </> "tabs.json"
        h <- newPersistingTabsHandle path
        _ <- insertTabH h (BoundSession (mkSid "20260701-120000-002")) KindProvider Nothing
        mLoaded <- loadTabList path
        mLoaded `shouldSatisfy` \case
          Just tl -> length (tlTabs tl) == 1
          Nothing -> False

    it "a second insert is persisted alongside the first" $
      withSystemTempDirectory "seal-persist" $ \dir -> do
        let path = dir </> "tabs.json"
        h <- newPersistingTabsHandle path
        _ <- insertTabH h (BoundSession (mkSid "20260701-120000-003")) KindAi Nothing
        _ <- insertTabH h (BoundSession (mkSid "20260701-120000-004")) KindAi Nothing
        mLoaded <- loadTabList path
        mLoaded `shouldSatisfy` \case
          Just tl -> length (tlTabs tl) == 2
          Nothing -> False

  describe "id-validation on load" $ do
    it "skips a tab with an unparseable SessionId (does not error)" $
      withSystemTempDirectory "seal-persist" $ \dir -> do
        let path = dir </> "tabs.json"
        -- Write a valid TabList, then corrupt the sid text on disk so it
        -- fails re-parse. The validator (filterValidTabs) drops the tab.
        h <- newTabsHandle
        _ <- insertTabH h (BoundSession (mkSid "20260701-120000-005")) KindAi Nothing
        tl <- snapshotTabs h
        saveTabList path tl
        -- Corrupt: replace the valid sid with an invalid one in the file.
        -- Read strictly (sodb) so the handle closes before the write.
        bytes <- readFileStrict path
        -- Corrupt: replace the valid sid with one starting with '.' (rejected by isValidSessionId).
        writeFile path (T.unpack (T.replace "20260701-120000-005" ".invalid.sid" (T.pack bytes)))
        m <- loadTabList path
        m `shouldSatisfy` \case
          Just tl' -> null (tlTabs tl')  -- the corrupted-sid tab dropped
          Nothing -> False

    it "skips a tab with an unparseable HarnessId (does not error)" $
      withSystemTempDirectory "seal-persist" $ \dir -> do
        let path = dir </> "tabs.json"
        h <- newTabsHandle
        -- Insert a BoundHarness tab with a valid UUID, then corrupt it.
        let validUuid = "12345678-1234-4234-8234-123456789012"
        _ <- insertTabH h (BoundHarness (either (error "hid") id (parseHarnessId (T.pack validUuid)))) KindHarness Nothing
        tl <- snapshotTabs h
        saveTabList path tl
        bytes <- readFileStrict path
        -- Corrupt: replace the valid UUID with an empty string (parseHarnessId rejects empty).
        writeFile path (T.unpack (T.replace (T.pack validUuid) "" (T.pack bytes)))
        m <- loadTabList path
        m `shouldSatisfy` \case
          Just tl' -> null (tlTabs tl')
          Nothing -> False