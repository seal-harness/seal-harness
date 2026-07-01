{-# LANGUAGE OverloadedStrings #-}
module Seal.Session.StoreSpec (spec) where

import Data.Either (fromRight)
import Data.List (isPrefixOf)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus)
import Test.Hspec

import qualified Data.Text as T
import qualified Seal.Core.Types

import Seal.Config.File (defaultFileConfig, FileConfig (..))
import Seal.Config.Paths (SealPaths (..), sessionDir, sessionMetaPath)
import Seal.Core.Types (isValidSessionId, sessionIdText)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store
  ( defaultSessionSelection, formatSessionId, initSession, listSessions
  , newSession, saveSessionMeta )

mkPaths :: FilePath -> SealPaths
mkPaths root = SealPaths
  { spHome = root, spConfig = root </> "config"
  , spState = root </> "state", spKeys = root </> "keys" }

aTime :: UTCTime
aTime = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 43200)

spec :: Spec
spec = describe "Seal.Session.Store" $ do
  describe "formatSessionId" $ do
    it "formats as YYYYMMDD-HHMMSS-mmm and is a valid session id" $ do
      let t = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 43200 + 0.042)
      formatSessionId t `shouldBe` "20260701-120000-042"
      isValidSessionId (formatSessionId t) `shouldBe` True

  describe "newSession" $
    it "creates a 0700 dir with a 0600 session.json carrying the selection" $
      withSystemTempDirectory "seal-sess" $ \root -> do
        let paths = mkPaths root
        m <- newSession paths "anthropic" "claude-opus-4-8" "cli"
        smProvider m `shouldBe` "anthropic"
        smModel m    `shouldBe` "claude-opus-4-8"
        doesFileExist (sessionMetaPath paths (smId m)) >>= (`shouldBe` True)
        dirMode  <- fileMode <$> getFileStatus (sessionDir paths (smId m))
        metaMode <- fileMode <$> getFileStatus (sessionMetaPath paths (smId m))
        (dirMode  `mod` 0o1000) `shouldBe` 0o700
        (metaMode `mod` 0o1000) `shouldBe` 0o600

  describe "listSessions" $ do
    it "returns [] when no sessions exist" $
      withSystemTempDirectory "seal-sess" $ \root ->
        listSessions (mkPaths root) >>= (`shouldBe` [])

    it "lists saved sessions sorted by last_active descending, skipping corrupt" $
      withSystemTempDirectory "seal-sess" $ \root -> do
        let paths = mkPaths root
            mk idText la = do
              let sid = fromRight (error "invalid sid") (Seal.Core.Types.mkSessionId idText)
              saveSessionMeta paths SessionMeta
                { smId = sid, smProvider = "anthropic", smModel = "m"
                , smChannel = "cli", smCreatedAt = aTime, smLastActive = la }
        mk "20260701-120000-001" aTime
        mk "20260701-120000-002" (aTime { utctDay = fromGregorian 2026 7 2 })
        -- a corrupt session dir is skipped
        let badSid = fromRight (error "invalid bad sid") (Seal.Core.Types.mkSessionId "20260701-120000-003")
        createDirectoryIfMissing True (sessionDir paths badSid)
        writeFile (sessionMetaPath paths badSid) "{ not json"
        metas <- listSessions paths
        map (sessionIdText . smId) metas
          `shouldBe` ["20260701-120000-002", "20260701-120000-001"]

  describe "defaultSessionSelection" $ do
    it "falls back to anthropic + its default model when config is empty" $
      defaultSessionSelection defaultFileConfig
        `shouldBe` ("anthropic", "claude-opus-4-8")

    it "honours configured defaults" $
      defaultSessionSelection defaultFileConfig
        { fcDefaultProvider = Just "ollama", fcDefaultModel = Just "llama3" }
        `shouldBe` ("ollama", "llama3")

  describe "initSession" $
    it "creates a session from the config defaults on the cli channel" $
      withSystemTempDirectory "seal-sess" $ \root -> do
        let paths = mkPaths root
        m <- initSession paths defaultFileConfig
        smProvider m `shouldBe` "anthropic"
        smModel m    `shouldBe` "claude-opus-4-8"
        smChannel m  `shouldBe` "cli"
        sessionIdText (smId m) `shouldSatisfy` ("2" `isPrefixOf`) . T.unpack
