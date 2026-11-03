{-# LANGUAGE OverloadedStrings #-}
module Seal.Session.DerivedSpec (spec) where

import Control.Concurrent.Async (mapConcurrently)
import Control.Monad (forM_, void)
import Data.Aeson qualified as A
import Data.ByteString qualified as BS
import Data.Int (Int64)
import Data.List (isInfixOf, sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, defaultTimeLocale, parseTimeOrError)
import Data.Word (Word8)
import System.Directory
  ( createDirectory, createDirectoryIfMissing, doesDirectoryExist, listDirectory )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus, intersectFileModes)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)

import Seal.Config.Paths (SealPaths (..), sessionDerivedPath, sessionDir, sessionEntriesPath)
import Seal.Core.Types (SessionId, mkSessionId)
import Seal.Session.Derived
import Seal.Transcript.Entries (EntryKind (..), EntryRecord (..))

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

fakePaths :: FilePath -> SealPaths
fakePaths root = SealPaths
  { spHome   = root
  , spConfig = root </> "config"
  , spState  = root </> "state"
  , spKeys   = root </> "keys"
  , spCache  = root </> "cache"
  }

testSid :: SessionId
testSid = case mkSessionId "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" of
  Right s -> s
  Left e  -> error ("DerivedSpec: bad session id: " <> T.unpack e)

tm :: String -> UTCTime
tm = parseTimeOrError True defaultTimeLocale "%Y-%m-%dT%H:%M:%S"

-- | A minimal but real 'EntryRecord' — only four fields are non-optional.
mkEntry :: Text -> EntryKind -> UTCTime -> EntryRecord
mkEntry i k t = EntryRecord
  { erId          = i
  , erTimestamp   = t
  , erKind        = k
  , erConvLen     = 0
  , erEnvelope    = Nothing
  , erUsage       = Nothing
  , erStop        = Nothing
  , erDurationMs  = Nothing
  , erHarness     = Nothing
  , erCorrelation = Nothing
  , erMeta        = Map.empty
  }

seedEntries :: SealPaths -> [EntryRecord] -> IO ()
seedEntries paths es = do
  createDirectoryIfMissing True (sessionDir paths testSid)
  BS.writeFile (sessionEntriesPath paths testSid)
    (BS.concat [ BS.toStrict (A.encode e) <> "\n" | e <- es ])

seedBytes :: SealPaths -> BS.ByteString -> IO ()
seedBytes paths bs = do
  createDirectoryIfMissing True (sessionDir paths testSid)
  BS.writeFile (sessionEntriesPath paths testSid) bs

tempLeftovers :: SealPaths -> IO [FilePath]
tempLeftovers paths = do
  entries <- listDirectory (sessionDir paths testSid)
  pure (sort (filter (".tmp" `isInfixOf`) entries))

-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "Seal.Session.Derived" $ do

  it "sessionDerivedPath is <sessionDir>/derived.json" $
    withSystemTempDirectory "seal-derived" $ \root -> do
      let paths = fakePaths root
      sessionDerivedPath paths testSid
        `shouldBe` sessionDir paths testSid </> "derived.json"

  it "renderIso renders milliseconds + Z (the shape ApiSpec pins)" $
    renderIso (tm "2026-07-01T12:00:05") `shouldBe` "2026-07-01T12:00:05.000Z"

  describe "readDerived" $ do
    it "returns Nothing when the file is absent" $
      withSystemTempDirectory "seal-derived" $ \root ->
        readDerived (fakePaths root) testSid `shouldReturn` Nothing

    it "writes exactly version/last_user_message_at/entries_bytes, version 1" $
      withSystemTempDirectory "seal-derived" $ \root -> do
        let paths = fakePaths root
        createDirectoryIfMissing True (sessionDir paths testSid)
        -- deliberately pass a bogus version: the writer must still emit 1
        writeDerived paths testSid (DerivedMeta 99 (Just "t") 7) `shouldReturn` True
        raw <- BS.readFile (sessionDerivedPath paths testSid)
        raw `shouldBe`
          "{\"entries_bytes\":7,\"last_user_message_at\":\"t\",\"version\":1}"

    it "round-trips a written value" $
      withSystemTempDirectory "seal-derived" $ \root -> do
        let paths = fakePaths root
            m = DerivedMeta derivedVersion (Just "2026-07-01T12:00:05.000Z") 42
        createDirectoryIfMissing True (sessionDir paths testSid)
        writeDerived paths testSid m `shouldReturn` True
        readDerived paths testSid `shouldReturn` Just m

    it "returns Nothing for malformed JSON, and never throws" $
      withSystemTempDirectory "seal-derived" $ \root -> do
        let paths = fakePaths root
        createDirectoryIfMissing True (sessionDir paths testSid)
        BS.writeFile (sessionDerivedPath paths testSid) "{not json"
        readDerived paths testSid `shouldReturn` Nothing

    it "returns Nothing for a non-object value" $
      withSystemTempDirectory "seal-derived" $ \root -> do
        let paths = fakePaths root
        createDirectoryIfMissing True (sessionDir paths testSid)
        BS.writeFile (sessionDerivedPath paths testSid) "[1,2,3]"
        readDerived paths testSid `shouldReturn` Nothing

    it "returns Nothing for a future version" $
      withSystemTempDirectory "seal-derived" $ \root -> do
        let paths = fakePaths root
        createDirectoryIfMissing True (sessionDir paths testSid)
        BS.writeFile (sessionDerivedPath paths testSid)
          "{\"version\":2,\"last_user_message_at\":null,\"entries_bytes\":0}"
        readDerived paths testSid `shouldReturn` Nothing

  describe "entriesSize" $ do
    it "is Nothing when entries.jsonl is absent" $
      withSystemTempDirectory "seal-derived" $ \root ->
        entriesSize (fakePaths root) testSid `shouldReturn` Nothing

    it "is Just 0 for a zero-byte file" $
      withSystemTempDirectory "seal-derived" $ \root -> do
        let paths = fakePaths root
        seedBytes paths BS.empty
        entriesSize paths testSid `shouldReturn` Just 0

    it "is the byte length otherwise" $
      withSystemTempDirectory "seal-derived" $ \root -> do
        let paths = fakePaths root
        seedBytes paths "0123456789"
        entriesSize paths testSid `shouldReturn` Just 10

  describe "derivedIsFresh" $ do
    it "is False when entries.jsonl is absent (even with a sidecar present)" $
      withSystemTempDirectory "seal-derived" $ \root -> do
        let paths = fakePaths root
        createDirectoryIfMissing True (sessionDir paths testSid)
        void (writeDerived paths testSid (DerivedMeta derivedVersion Nothing 0))
        derivedIsFresh paths testSid `shouldReturn` False

    it "is False when no sidecar exists" $
      withSystemTempDirectory "seal-derived" $ \root -> do
        let paths = fakePaths root
        seedBytes paths "0123456789"
        derivedIsFresh paths testSid `shouldReturn` False

    it "matches only on an exact byte count (smaller and larger are stale)" $
      withSystemTempDirectory "seal-derived" $ \root -> do
        let paths = fakePaths root
        seedBytes paths "0123456789"
        forM_ [(10 :: Int64, True), (9, False), (11, False)] $ \(n, want) -> do
          void (writeDerived paths testSid (DerivedMeta derivedVersion Nothing n))
          derivedIsFresh paths testSid `shouldReturn` want

  describe "writeDerived" $ do
    it "returns False and creates nothing when the session dir is absent" $
      withSystemTempDirectory "seal-derived" $ \root -> do
        let paths = fakePaths root
        writeDerived paths testSid (DerivedMeta derivedVersion Nothing 0)
          `shouldReturn` False
        doesDirectoryExist (sessionDir paths testSid) `shouldReturn` False

    it "writes mode 0600" $
      withSystemTempDirectory "seal-derived" $ \root -> do
        let paths = fakePaths root
        createDirectoryIfMissing True (sessionDir paths testSid)
        writeDerived paths testSid (DerivedMeta derivedVersion Nothing 3)
          `shouldReturn` True
        st <- getFileStatus (sessionDerivedPath paths testSid)
        fileMode st `intersectFileModes` 0o777 `shouldBe` 0o600

    it "returns False and leaves no temp file when the rename cannot land" $
      withSystemTempDirectory "seal-derived" $ \root -> do
        let paths = fakePaths root
        createDirectoryIfMissing True (sessionDir paths testSid)
        -- derived.json exists as a DIRECTORY, so renameFile must fail.
        createDirectory (sessionDerivedPath paths testSid)
        writeDerived paths testSid (DerivedMeta derivedVersion Nothing 0)
          `shouldReturn` False
        tempLeftovers paths `shouldReturn` []

  describe "mkDerived (the stat -> read -> stat rule)" $ do
    it "records a value when the pre and post sizes agree" $
      mkDerived 10 10 (Just "t") `shouldBe` Just (DerivedMeta derivedVersion (Just "t") 10)

    it "discards the value when an append lands during the read" $
      mkDerived 10 11 (Just "t") `shouldBe` Nothing

    it "discards the value when the file shrinks during the read" $
      mkDerived 10 9 (Just "t") `shouldBe` Nothing

  describe "computeDerived" $ do
    it "returns Nothing when entries.jsonl is absent" $
      withSystemTempDirectory "seal-derived" $ \root ->
        computeDerived (fakePaths root) testSid `shouldReturn` Nothing

    it "takes the LAST request timestamp and skips non-request entries" $
      withSystemTempDirectory "seal-derived" $ \root -> do
        let paths = fakePaths root
        seedEntries paths
          [ mkEntry "1" EKRequest  (tm "2026-07-01T12:00:05")
          , mkEntry "2" EKResponse (tm "2026-07-01T12:00:09")
          , mkEntry "3" EKRequest  (tm "2026-07-01T12:00:11")
          , mkEntry "4" EKResponse (tm "2026-07-01T12:00:12")
          ]
        sz <- entriesSize paths testSid
        m <- computeDerived paths testSid
        m `shouldBe` (DerivedMeta derivedVersion
                       (Just "2026-07-01T12:00:11.000Z") <$> sz)

    it "yields Nothing for the timestamp when there is no request entry" $
      withSystemTempDirectory "seal-derived" $ \root -> do
        let paths = fakePaths root
        seedEntries paths [mkEntry "1" EKResponse (tm "2026-07-01T12:00:09")]
        m <- computeDerived paths testSid
        fmap dmLastUserMessageAt m `shouldBe` Just Nothing

    it "produces a value that derivedIsFresh then trusts" $
      withSystemTempDirectory "seal-derived" $ \root -> do
        let paths = fakePaths root
        seedEntries paths [mkEntry "1" EKRequest (tm "2026-07-01T12:00:05")]
        m <- computeDerived paths testSid
        case m of
          Nothing -> expectationFailure "expected a computed value"
          Just d -> do
            writeDerived paths testSid d `shouldReturn` True
            derivedIsFresh paths testSid `shouldReturn` True

  describe "concurrency" $
    it "20 concurrent writes leave a decodable file and no temp files" $
      withSystemTempDirectory "seal-derived" $ \root -> do
        let paths = fakePaths root
        createDirectoryIfMissing True (sessionDir paths testSid)
        results <- mapConcurrently
          (\i -> writeDerived paths testSid
                   (DerivedMeta derivedVersion (Just (T.pack (show i))) i))
          [1 .. 20 :: Int64]
        results `shouldSatisfy` and
        m <- readDerived paths testSid
        m `shouldSatisfy` (/= Nothing)
        tempLeftovers paths `shouldReturn` []

  describe "serialization" $ do
    prop "encode/decode round-trips" $ \(n :: Int64) ->
      let m = DerivedMeta derivedVersion (Just "2026-07-01T12:00:05.000Z") n
      in (A.decode (A.encode m) :: Maybe DerivedMeta) == Just m

    prop "arbitrary bytes decode to the value or to Nothing, never a crash" $ \(ws :: [Word8]) ->
      case A.decodeStrict (BS.pack (take 64 ws)) :: Maybe DerivedMeta of
        Nothing -> True
        Just d  -> dmVersion d == derivedVersion
