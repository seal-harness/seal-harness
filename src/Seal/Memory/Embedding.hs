{-# LANGUAGE OverloadedStrings #-}
-- | The embedding backend capability — a record-of-functions (consistent
-- with the project's 'MemoryBackend' / 'SkillBackend' convention) rather
-- than a typeclass, per CONTRIBUTING.md: "capability-handle records of IO
-- functions over type classes".
--
-- The embedding backend is a top-level Seal Harness concern, not specific
-- to memory. The same backend can be used for memory search, session
-- search, and any future feature that needs semantic retrieval.
--
-- Ships with 'nullEmbeddingBackend' (no search, returns empty results).
-- The engram backend (subprocess to the engram CLI) is a follow-up.
module Seal.Memory.Embedding
  ( EmbeddingBackend (..)
  , SearchResult (..)
  , nullEmbeddingBackend
  ) where

import Data.Text (Text)

-- | A single search result from the embedding backend.
data SearchResult = SearchResult
  { srPath    :: Text
    -- ^ The memory path (relative to active/ or archived/).
  , srContent :: Text
    -- ^ The memory file content.
  , srScore   :: Double
    -- ^ Relevance score (higher = more relevant).
  } deriving stock (Eq, Show)

-- | The embedding backend capability. Each operation is IO — the engram
-- backend shells out to the engram CLI; the null backend is a no-op.
data EmbeddingBackend = EmbeddingBackend
  { ebIndex       :: FilePath -> Text -> IO ()
    -- ^ Add a file to the search index.
  , ebUnindex     :: FilePath -> IO ()
    -- ^ Remove a file from the search index.
  , ebSearch      :: Text -> Int -> IO [SearchResult]
    -- ^ Semantic search: query + limit, returns ranked results.
  , ebBackendName :: Text
    -- ^ Human-readable backend name (e.g. "null", "engram").
  }

-- | The null backend: no indexing, no search. Returns empty results.
-- For development without ollama/engram installed.
nullEmbeddingBackend :: EmbeddingBackend
nullEmbeddingBackend = EmbeddingBackend
  { ebIndex       = \_ _ -> pure ()
  , ebUnindex     = \_   -> pure ()
  , ebSearch      = \_ _ -> pure []
  , ebBackendName = "null"
  }