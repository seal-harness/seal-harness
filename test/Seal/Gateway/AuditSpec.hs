{-# LANGUAGE OverloadedStrings #-}
-- | Tests for the access-control audit log (design §15).
module Seal.Gateway.AuditSpec (spec) where

import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime, addUTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files
  ( createSymbolicLink, fileMode, fileSize, getFileStatus, setFileMode )
import System.Posix.Types (FileOffset)
import Test.Hspec

import Seal.Config.Paths (SealPaths (..))
import Seal.Gateway.Audit
  ( AuditEvent (..), AuditFields (..), admitRefusal, appendAudit, auditLine
  , auditLogPath, auditRefusalLogPath, emptyAuditFields, newAuditGate )
import Seal.Security.EnrollmentGrant (GrantSource (..))

spec :: Spec
spec = describe "Seal.Gateway.Audit" $ do
  describe "the field set is closed" $ do
    it "renders only the enumerated keys" $ do
      let line = auditLine epoch (emptyAuditFields CredentialAdded)
      keysOf line `shouldBe` ["ts", "event"]

    it "never renders a request-derived value, even when one is smuggled in a field" $ do
      let hostile = "passkey\n event=credential_added rp_id=evil.example"
          line = auditLine epoch (emptyAuditFields CredentialAdded)
                   { afLabel = Just hostile }
      -- The newline and the '=' are percent-encoded, so the injected text stays
      -- inside one field's value instead of becoming its own log record.
      T.count "event=" line `shouldBe` 1
      T.count "\n" line `shouldBe` 0
      T.count "=evil.example" line `shouldBe` 0

    it "renders the event vocabulary and the optional fields" $ do
      let fields = (emptyAuditFields GrantMinted)
            { afVia = Just CliToken
            , afRemainingSeconds = Just 600
            , afOrigin = Just "http://localhost:8080"
            }
          line = auditLine epoch fields
      line `shouldSatisfy` T.isInfixOf "event=grant_minted"
      line `shouldSatisfy` T.isInfixOf "via=cli_token"
      line `shouldSatisfy` T.isInfixOf "remaining_s=600"

  describe "appendAudit" $ do
    it "appends one line per event at 0600" $
      withHome $ \paths -> do
        Right () <- appendAudit paths epoch (emptyAuditFields GrantMinted)
        Right () <- appendAudit paths epoch (emptyAuditFields CredentialAdded)
        raw <- BS.readFile (auditLogPath paths)
        length (filter (== 0x0a) (BS.unpack raw)) `shouldBe` 2
        mode <- fileMode <$> getFileStatus (auditLogPath paths)
        (mode .&. 0o777) `shouldBe` 0o600

    it "sends state-changing events and refusals to different files" $
      withHome $ \paths -> do
        Right () <- appendAudit paths epoch (emptyAuditFields CredentialRemoved)
        Right () <- appendAudit paths epoch (emptyAuditFields GrantRefused)
        mainLog <- BS.readFile (auditLogPath paths)
        refusalLog <- BS.readFile (auditRefusalLogPath paths)
        TE.decodeUtf8 mainLog `shouldSatisfy` T.isInfixOf "credential_removed"
        TE.decodeUtf8 mainLog `shouldSatisfy` (not . T.isInfixOf "grant_refused")
        TE.decodeUtf8 refusalLog `shouldSatisfy` T.isInfixOf "grant_refused"

    it "refuses a symlink instead of writing through it" $
      withHome $ \paths -> do
        let target = spState paths </> "victim"
            link = auditLogPath paths
        BS.writeFile target "untouched"
        createSymbolicLink target link
        result <- appendAudit paths epoch (emptyAuditFields ModeEnabled)
        result `shouldSatisfy` isLeft
        BS.readFile target `shouldReturn` "untouched"

    it "rotates a log that exceeds the cap" $
      withHome $ \paths -> do
        let path = auditLogPath paths
        BS.writeFile path (BS.replicate (fromIntegral (auditCap + 1)) 0x2e)
        Right () <- appendAudit paths epoch (emptyAuditFields ModeDisabled)
        doesFileExist (path <> ".1") `shouldReturn` True
        rotated <- fileSizeOf (path <> ".1")
        rotated `shouldBe` auditCap + 1

  describe "admitRefusal" $ do
    it "emits once per source, then backs off" $ do
      gate <- newAuditGate
      admitRefusal gate epoch "grant_invalid" `shouldReturn` True
      -- Inside the 1 s backoff for this source: aggregated away.
      admitRefusal gate (addUTCTime 0.5 epoch) "grant_invalid" `shouldReturn` False
      -- Past the 1 s backoff for the second emission.
      admitRefusal gate (addUTCTime 5 epoch) "grant_invalid" `shouldReturn` True
      -- A different source has its own slot.
      admitRefusal gate (addUTCTime 5 epoch) "grant_required" `shouldReturn` True

    it "does not let an attacker choose the key space" $ do
      gate <- newAuditGate
      -- 400 distinct sources: the table is capped, so the tail is dropped
      -- rather than growing without bound on a pre-auth path.
      results <- mapM (admitRefusal gate epoch . T.pack . show) ([1 .. 400] :: [Int])
      length (filter id results) `shouldSatisfy` (<= 256)

-- Helpers ------------------------------------------------------------------

-- | 2026-01-01T00:00:00Z, a fixed clock so the rendering is assertable.
epoch :: UTCTime
epoch = posixSecondsToUTCTime 1767225600

keysOf :: Text -> [Text]
keysOf line = [ T.takeWhile (/= '=') piece | piece <- T.words line ]

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft (Right _) = False

fileSizeOf :: FilePath -> IO FileOffset
fileSizeOf path = fileSize <$> getFileStatus path

-- | The cap the module rotates at; kept in step with 'auditMaxBytes'.
auditCap :: FileOffset
auditCap = 4 * 1024 * 1024

withHome :: (SealPaths -> IO a) -> IO a
withHome action = withSystemTempDirectory "seal-audit" $ \dir -> do
  let paths = SealPaths { spHome = dir
                        , spState = dir </> "state"
                        , spConfig = dir </> "config"
                        , spKeys = dir </> "keys"
                        , spCache = dir </> "cache"
                        }
  createDirectoryIfMissing True (spState paths)
  setFileMode (spState paths) 0o700
  action paths
