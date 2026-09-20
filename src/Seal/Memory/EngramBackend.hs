{-# LANGUAGE OverloadedStrings #-}
-- | The engram embedding backend — a subprocess-based 'EmbeddingBackend'
-- that shells out to the @engram@ CLI for semantic search. engram uses
-- SQLite-vec with ollama/nomic-embed-text embeddings under the hood.
--
-- The engram CLI uses a fixed index at @~\/.engram\/index.db@ (no custom
-- index path support). All memory files are indexed into this shared
-- index. The @indexPath@ parameter is currently unused but reserved for
-- a future engram version that supports multiple indexes.
--
-- The engram CLI commands used:
--
--   * @engram add <file>@ — index a file
--   * @engram remove <file>@ — remove a file from the index
--   * @engram search "<query>" --limit N@ — search (human-readable output)
--
-- Search output format (one result per block):
--
--   @
--    1. /path/to/file.md (dist: 0.680)
--       snippet of matching content...
--   @
--
-- All subprocess invocations use 'System.Process.proc' with fixed argv
-- (no shell). The binary path is validated at config-load time.
module Seal.Memory.EngramBackend
  ( engramEmbeddingBackend
  , resolveEmbeddingBackend
  ) where

import Data.Foldable (for_)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.ByteString qualified as BS
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.Exit (ExitCode (..))
import System.Process
  ( CreateProcess (..), StdStream (..), proc, waitForProcess
  , withCreateProcess )
import System.IO (hClose)

import Seal.Config.File (EmbeddingConfig (..))
import Seal.Memory.Embedding

-- | Construct an 'EmbeddingBackend' backed by the engram CLI.
--
-- @binaryPath@ is the absolute path to the engram binary (e.g.
-- @~\/.local\/bin\/engram@). @indexPath@ is reserved for a future engram
-- version that supports custom index paths; currently unused.
engramEmbeddingBackend :: Text -> FilePath -> EmbeddingBackend
engramEmbeddingBackend binaryPath _indexPath = EmbeddingBackend
  { ebIndex = \filePath content -> do
      -- Write content to the file so engram can index it by path.
      BS.writeFile filePath (TE.encodeUtf8 content)
      _ <- runEngram binaryPath ["add", filePath, "--no-progress"]
      pure ()
  , ebUnindex = \filePath -> do
      _ <- runEngram binaryPath ["remove", filePath]
      pure ()
  , ebSearch = \query limit -> do
      let limitStr = show limit
          queryStr = T.unpack query
      result <- runEngram binaryPath ["search", queryStr, "--limit", limitStr]
      case result of
        Left _ -> pure []
        Right output -> pure (parseEngramResults (TE.decodeUtf8Lenient output))
  , ebBackendName = "engram"
  }

-- | Run an engram command with fixed argv (no shell). Returns the stdout
-- on success, or an error message on failure. Best-effort — a failed
-- engram command returns 'Left' and the caller (the opcode) falls back
-- to substring search.
runEngram :: Text -> [String] -> IO (Either Text BS.ByteString)
runEngram binaryPath args = do
  let binStr = T.unpack binaryPath
      cp = (proc binStr args)
        { std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe }
  withCreateProcess cp $ \mIn mOut mErr ph -> do
    for_ mIn hClose
    out <- maybe (pure BS.empty) BS.hGetContents mOut
    _err <- maybe (pure BS.empty) BS.hGetContents mErr
    ec <- waitForProcess ph
    let !_ = BS.length out
    case ec of
      ExitSuccess -> pure (Right out)
      ExitFailure _ -> pure (Left ("engram command failed: " <> T.pack (unwords (binStr : args))))

-- | Parse engram's human-readable search output into a list of
-- 'SearchResult'. The expected format is:
--
-- @
--  1. /path/to/file.md (dist: 0.680)
--     snippet of matching content...
-- @
--
-- Each result starts with a line matching @N. <path> (dist: X)@, followed
-- by indented content lines. The score is @1 - dist@ (engram reports
-- distance; we invert to a relevance score where higher = better).
parseEngramResults :: Text -> [SearchResult]
parseEngramResults output =
  mapMaybe parseResult (T.lines output)
  where
    -- A result line looks like: " 1. /path/to/file.md (dist: 0.680)"
    parseResult line =
      case T.stripPrefix " " (T.dropWhile (== ' ') line) of
        Nothing -> Nothing
        Just rest ->
          case T.breakOn " " rest of
            (_num, rest') ->
              case T.stripPrefix " " rest' of
                Nothing -> Nothing
                Just pathAndDist ->
                  case T.breakOn " (dist: " pathAndDist of
                    (path, distPart) ->
                      case T.stripPrefix " (dist: " distPart of
                        Nothing -> Nothing
                        Just afterDist ->
                          case T.breakOn ")" afterDist of
                            (distStr, _) ->
                              case reads (T.unpack distStr) of
                                [(d, _)] ->
                                  let score = 1.0 - d
                                      content = T.strip line
                                  in Just SearchResult
                                       { srPath = T.strip path
                                       , srContent = content
                                       , srScore = score
                                       }
                                _ -> Nothing

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
