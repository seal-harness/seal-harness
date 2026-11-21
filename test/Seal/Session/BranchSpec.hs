{-# LANGUAGE OverloadedStrings #-}
module Seal.Session.BranchSpec (spec) where

import Control.Monad (when)
import Data.Aeson (object, (.=))
import Data.Aeson qualified as A
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import System.Directory
  ( createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Config.Paths
  ( SealPaths (..), sessionConversationPath, sessionDir, sessionEntriesPath
  , sessionMetaPath )
import Seal.Core.Types (SessionId, mkSessionId)
import Seal.Session.Branch
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (saveSessionMeta)
import Seal.Transcript.Entries
  ( EntryKind (..), EntryRecord (..), encodeEntryRecordRaw )

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 11 17) (secondsToDiffTime 0)

mkPaths :: FilePath -> SealPaths
mkPaths root = SealPaths
  { spHome = root
  , spConfig = root </> "config"
  , spState = root </> "state"
  , spKeys = root </> "keys"
  , spCache = root </> "cache"
  }

parentId, childId :: SessionId
parentId = either (error . T.unpack) id (mkSessionId "20261117-100000-000")
childId  = either (error . T.unpack) id (mkSessionId "20261117-110000-000")

entry :: EntryKind -> Int -> EntryRecord
entry kind convLen = EntryRecord
  { erId = ""
  , erTimestamp = sampleTime
  , erKind = kind
  , erConvLen = convLen
  , erEnvelope = Nothing
  , erUsage = Nothing
  , erStop = Nothing
  , erDurationMs = Nothing
  , erHarness = Nothing
  , erCorrelation = Nothing
  , erMeta = Map.empty
  }

-- | Write a parent session with the given conversation lines and entries.
seedParent :: SealPaths -> [BS.ByteString] -> [EntryRecord] -> IO ()
seedParent paths convLines entries = do
  let dir = sessionDir paths parentId
  createDirectoryIfMissing True dir
  saveSessionMeta paths SessionMeta
    { smId = parentId
    , smProvider = "ollama"
    , smModel = "llama3"
    , smChannel = "web"
    , smParent = Nothing
    , smAgent = Nothing
    , smSystemOverride = Nothing
    , smAgentName = Nothing
    , smDescription = Nothing
    , smSealFrontMatter = True
    , smRepoUrl = Nothing
    , smRepoBranch = Nothing
    , smCreatedAt = sampleTime
    , smLastActive = sampleTime
    , smAllowedSecrets = mempty
    }
  BS.writeFile (sessionConversationPath paths parentId) (BS.concat convLines)
  BS.writeFile (sessionEntriesPath paths parentId)
    (BS.concat (map (\e -> encodeEntryRecordRaw e <> "\n") entries))

convLine :: T.Text -> BS.ByteString
convLine t = BL.toStrict (A.encode (object ["role" .= ("user" :: T.Text), "content" .= t])) <> "\n"

spec :: Spec
spec = describe "Seal.Session.Branch" $ do
  describe "clampBranchLen" $ do
    it "clamps negative to 0" $ clampBranchLen 10 (-5) `shouldBe` 0
    it "clamps above the parent length" $ clampBranchLen 3 99 `shouldBe` 3
    it "passes an in-range value through" $ clampBranchLen 10 4 `shouldBe` 4

  describe "foldEntryPrefix" $ do
    it "selects nothing for N = 0" $
      foldEntryPrefix 0 [entry EKRequest 1] `shouldBe` []

    it "keeps request/response entries whose absolute convLen <= N" $
      let es = [entry EKRequest 1, entry EKResponse 2, entry EKRequest 3]
      in map erConvLen (foldEntryPrefix 2 es) `shouldBe` [1, 2]

    it "treats a harness convLen as a DELTA" $
      -- request(1), harness(+1 => 2), response(3): at N=2 the response is out.
      let es = [entry EKRequest 1, entry EKHarness 1, entry EKResponse 3]
      in map erKind (foldEntryPrefix 2 es) `shouldBe` [EKRequest, EKHarness]

    it "includes a harness delta of 0 without advancing the cursor" $
      let es = [entry EKRequest 1, entry EKHarness 0, entry EKResponse 2]
      in length (foldEntryPrefix 2 es) `shouldBe` 3

    it "excludes a harness entry whose delta straddles N" $
      let es = [entry EKRequest 2, entry EKHarness 1, entry EKResponse 4]
      in length (foldEntryPrefix 2 es) `shouldBe` 1

  describe "branchSession" $ do
    it "copies the first N conversation lines BYTE-identically" $
      withSystemTempDirectory "seal-branch" $ \root -> do
        let paths = mkPaths root
        seedParent paths [convLine "a", convLine "b", convLine "c"]
                         [entry EKRequest 1, entry EKResponse 2, entry EKRequest 3]
        r <- branchSession paths parentId childId 2
        r `shouldBe` Right ()
        child <- BS.readFile (sessionConversationPath paths childId)
        let parentBs = BS.concat [convLine "a", convLine "b"]
        child `shouldBe` parentBs

    it "copies the matching entries prefix" $
      withSystemTempDirectory "seal-branch" $ \root -> do
        let paths = mkPaths root
        seedParent paths [convLine "a", convLine "b"]
                         [entry EKRequest 1, entry EKResponse 2]
        r <- branchSession paths parentId childId 1
        r `shouldBe` Right ()
        raw <- BS.readFile (sessionEntriesPath paths childId)
        length (filter (not . BS.null) (BS.split 0x0a raw)) `shouldBe` 1

    it "writes no session.json (the caller does that last)" $
      withSystemTempDirectory "seal-branch" $ \root -> do
        let paths = mkPaths root
        seedParent paths [convLine "a"] [entry EKRequest 1]
        _ <- branchSession paths parentId childId 1
        doesFileExist (sessionMetaPath paths childId) `shouldReturn` False

    it "clamps an out-of-range N rather than failing" $
      withSystemTempDirectory "seal-branch" $ \root -> do
        let paths = mkPaths root
        seedParent paths [convLine "a", convLine "b"] [entry EKRequest 1, entry EKResponse 2]
        r <- branchSession paths parentId childId 99
        r `shouldBe` Right ()
        child <- BS.readFile (sessionConversationPath paths childId)
        BS.split 0x0a child `shouldBe` BS.split 0x0a (BS.concat [convLine "a", convLine "b"])

    it "succeeds with N = 0 and produces NO conversation file or index (like a fresh session)" $
      withSystemTempDirectory "seal-branch" $ \root -> do
        let paths = mkPaths root
        seedParent paths [convLine "a"] [entry EKRequest 1]
        r <- branchSession paths parentId childId 0
        r `shouldBe` Right ()
        doesFileExist (sessionConversationPath paths childId) `shouldReturn` False
        doesFileExist (sessionDir paths childId </> "conversation.idx") `shouldReturn` False

    it "succeeds when the parent has NO conversation.jsonl (brand-new parent)" $
      withSystemTempDirectory "seal-branch" $ \root -> do
        let paths = mkPaths root
            dir = sessionDir paths parentId
        createDirectoryIfMissing True dir
        saveSessionMeta paths SessionMeta
          { smId = parentId, smProvider = "ollama", smModel = "llama3"
          , smChannel = "web", smParent = Nothing, smAgent = Nothing
          , smSystemOverride = Nothing, smAgentName = Nothing
          , smDescription = Nothing, smSealFrontMatter = True
          , smRepoUrl = Nothing, smRepoBranch = Nothing
          , smCreatedAt = sampleTime, smLastActive = sampleTime
          , smAllowedSecrets = mempty
          }
        r <- branchSession paths parentId childId 5
        r `shouldBe` Right ()

    it "drops a torn trailing line (in-flight write) instead of copying it" $
      withSystemTempDirectory "seal-branch" $ \root -> do
        let paths = mkPaths root
            dir = sessionDir paths parentId
        createDirectoryIfMissing True dir
        saveSessionMeta paths SessionMeta
          { smId = parentId, smProvider = "ollama", smModel = "llama3"
          , smChannel = "web", smParent = Nothing, smAgent = Nothing
          , smSystemOverride = Nothing, smAgentName = Nothing
          , smDescription = Nothing, smSealFrontMatter = True
          , smRepoUrl = Nothing, smRepoBranch = Nothing
          , smCreatedAt = sampleTime, smLastActive = sampleTime
          , smAllowedSecrets = mempty
          }
        -- two complete lines plus a partial third with no newline
        BS.writeFile (sessionConversationPath paths parentId)
          (BS.concat [convLine "a", convLine "b", "{\"role\":\"user\",\"conte"])
        r <- branchSession paths parentId childId 99
        r `shouldBe` Right ()
        child <- BS.readFile (sessionConversationPath paths childId)
        child `shouldBe` BS.concat [convLine "a", convLine "b"]

    it "returns Left and creates no child directory when the parent is missing" $
      withSystemTempDirectory "seal-branch" $ \root -> do
        let paths = mkPaths root
        r <- branchSession paths parentId childId 1
        case r of
          Left _  -> pure ()
          Right _ -> expectationFailure "expected Left for a missing parent"
        doesDirectoryExist (sessionDir paths childId) `shouldReturn` False

    it "leaves the child WORKDIR absent/empty (operator decision: no copy)" $
      withSystemTempDirectory "seal-branch" $ \root -> do
        let paths = mkPaths root
        seedParent paths [convLine "a"] [entry EKRequest 1]
        _ <- branchSession paths parentId childId 1
        -- branchSession must never create cache/workdirs/<sid>
        let wdRoot = spCache paths </> "workdirs"
        exists <- doesDirectoryExist wdRoot
        when exists $ do
          entries <- listDirectory wdRoot
          entries `shouldBe` []
