{-# LANGUAGE OverloadedStrings #-}
-- | The engram embedding backend — a subprocess-based 'EmbeddingBackend'
-- that shells out to the @engram@ CLI for semantic search. engram uses
-- SQLite-vec with ollama/nomic-embed-text embeddings under the hood.
--
-- The memory system uses a separate engram index (e.g.
-- @~\/.seal\/memory\/engram.db@) from the KB index (@~\/.engram\/index.db@)
-- via engram's @--index@ flag.
--
-- The engram CLI commands used:
--
--   * @engram add <file> --index <path> --no-progress@ — index a file
--   * @engram remove <file> --index <path>@ — remove a file from the index
--   * @engram search "<query>" --limit N --index <path> --json@ — search (JSON output)
--
-- JSON search output format:
--
-- @
-- [
--   { "path": "\/path\/to\/file.md", "snippet": "...", "distance": 0.68 }
-- ]
-- @
--
-- The @distance@ is converted to a relevance score via @1 - distance@.
module Seal.Memory.EngramBackend
  ( engramEmbeddingBackend
  , resolveEmbeddingBackend
  ) where

import Data.Aeson (FromJSON (..), decode, withObject, (.:))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (for_)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose)
import System.Process
  ( CreateProcess (..), StdStream (..), proc, waitForProcess
  , withCreateProcess )

import Seal.Config.File (EmbeddingConfig (..))
import Seal.Memory.Embedding

-- | Construct an 'EmbeddingBackend' backed by the engram CLI.
--
-- @binaryPath@ is the absolute path to the engram binary (e.g.
-- @~\/.local\/bin\/engram@). @indexPath@ is the path to the SQLite index
-- file (e.g. @~\/.seal\/memory\/engram.db@). The index is created on first
-- use by engram itself.
engramEmbeddingBackend :: Text -> FilePath -> EmbeddingBackend
engramEmbeddingBackend binaryPath indexPath = EmbeddingBackend
  { ebIndex = \filePath content -> do
      -- Write content to the file so engram can index it by path.
      BS.writeFile filePath (TE.encodeUtf8 content)
      _ <- runEngram binaryPath indexPath ["add", filePath, "--no-progress"]
      pure ()
  , ebUnindex = \filePath -> do
      _ <- runEngram binaryPath indexPath ["remove", filePath]
      pure ()
  , ebSearch = \query limit -> do
      let limitStr = show limit
          queryStr = T.unpack query
      result <- runEngram binaryPath indexPath
        ["search", queryStr, "--limit", limitStr, "--json"]
      case result of
        Left _ -> pure []
        Right output -> pure (parseEngramResults output)
  , ebBackendName = "engram"
  }

-- | Run an engram command with fixed argv (no shell). Returns the stdout
-- on success, or an error message on failure. Best-effort — a failed
-- engram command returns 'Left' and the caller (the opcode) falls back
-- to substring search.
runEngram :: Text -> FilePath -> [String] -> IO (Either Text BS.ByteString)
runEngram binaryPath indexPath args = do
  let binStr = T.unpack binaryPath
      fullArgs = args <> ["--index", indexPath]
      cp = (proc binStr fullArgs)
        { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe }
  withCreateProcess cp $ \mIn mOut mErr ph -> do
    for_ mIn hClose
    out <- maybe (pure BS.empty) BS.hGetContents mOut
    _err <- maybe (pure BS.empty) BS.hGetContents mErr
    ec <- waitForProcess ph
    let !_ = BS.length out
    case ec of
      ExitSuccess -> pure (Right out)
      ExitFailure _ -> pure (Left ("engram command failed: " <> T.pack (unwords (binStr : fullArgs))))

-- | The JSON shape of one engram search result (from @engram search --json@).
data EngramResult = EngramResult
  { erPath     :: Text
  , erSnippet  :: Text
  , erDistance :: Double
  }

instance FromJSON EngramResult where
  parseJSON = withObject "EngramResult" $ \o ->
    EngramResult
      <$> o .: "path"
      <*> o .: "snippet"
      <*> o .: "distance"

-- | Parse engram's @--json@ search output into a list of 'SearchResult'.
-- The @distance@ is converted to a relevance score via @1 - distance@
-- (engram reports distance; we invert so higher score = more relevant).
-- Malformed entries are skipped (defensive parsing).
parseEngramResults :: BS.ByteString -> [SearchResult]
parseEngramResults output =
  case decode (BL.fromStrict output) :: Maybe [EngramResult] of
    Just results -> mapMaybe toSearchResult results
    Nothing      -> []
  where
    toSearchResult er =
      Just SearchResult
        { srPath = erPath er
        , srContent = erSnippet er
        , srScore = 1.0 - erDistance er
        }

-- | Resolve an 'EmbeddingBackend' from the optional config and seal paths.
-- If the config is absent or @backend@ is @"null"@ (or absent), returns
-- 'nullEmbeddingBackend'. If @backend@ is @"engram"@, constructs an
-- 'engramEmbeddingBackend' with the configured (or default) binary path
-- and index path.
resolveEmbeddingBackend
  :: Maybe EmbeddingConfig
  -> FilePath
  -> IO EmbeddingBackend
resolveEmbeddingBackend mCfg sealHome =
  case mCfg of
    Nothing -> pure nullEmbeddingBackend
    Just cfg -> case ecBackend cfg of
      Just b | b == "engram" -> do
        let binPath = maybe "~/.local/bin/engram" T.unpack (ecBinaryPath cfg)
            indexPath = maybe (sealHome </> "memory" </> "engram.db")
                             T.unpack (ecIndexPath cfg)
        exists <- doesFileExist binPath
        if exists
          then pure (engramEmbeddingBackend (T.pack binPath) indexPath)
          else pure nullEmbeddingBackend
      _ -> pure nullEmbeddingBackend