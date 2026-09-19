{-# LANGUAGE OverloadedStrings #-}
-- | The memory path model. 'MemoryPath' is a smart-constructed newtype that
-- validates directory-hierarchy paths for memory files under
-- @~\/.seal\/memory\/active\/@. Paths are relative, @\/@-separated, and use
-- the charset @[A-Za-z0-9_-]+@ per segment (the same charset as the former
-- 'MemoryId', extended to allow @\/@ as a directory separator).
--
-- The path the agent provides does NOT include the @.md@ extension — the
-- store appends it. So @"projects\/pureclaw\/architecture"@ maps to
-- @active\/projects\/pureclaw\/architecture.md@ on disk.
--
-- Validation rejects:
--   * empty paths
--   * leading or trailing slashes
--   * @..@ or @.@ segments (path traversal)
--   * segments with leading dots (e.g. @.hidden@)
--   * segments with characters outside @[A-Za-z0-9_-]+@
--   * double slashes (empty segments)
module Seal.Memory.Path
  ( MemoryPath (..)
  , mkMemoryPath
  , isValidMemoryPath
  , memoryPathText
  , memoryPathSegments
  ) where

import Data.Text (Text)
import Data.Text qualified as T

-- | Opaque memory path. Smart-constructed via 'mkMemoryPath'; the charset
-- predicate guards every segment.
newtype MemoryPath = MemoryPath Text
  deriving stock (Eq, Ord, Show)

-- | The valid character set for each path segment (same as the former
-- 'MemoryId' charset).
segmentChars :: [Char]
segmentChars = ['A' .. 'Z'] <> ['a' .. 'z'] <> ['0' .. '9'] <> "_-"

-- | Validate a segment: non-empty, no leading dot, only allowed chars.
isValidSegment :: Text -> Bool
isValidSegment seg =
  not (T.null seg)
    && T.head seg /= '.'
    && T.all (`elem` segmentChars) seg

-- | Validate a full memory path. See module docs for the rules.
isValidMemoryPath :: Text -> Bool
isValidMemoryPath t =
  not (T.null t)
    && not (T.isPrefixOf "/" t)
    && not (T.isSuffixOf "/" t)
    && not ("//" `T.isInfixOf` t)
    && all isValidSegment (T.splitOn "/" t)
    && not (any (\seg -> seg == ".." || seg == ".") (T.splitOn "/" t))

-- | Smart constructor for 'MemoryPath'.
mkMemoryPath :: Text -> Either Text MemoryPath
mkMemoryPath t
  | isValidMemoryPath t = Right (MemoryPath t)
  | otherwise           = Left ("invalid memory path: " <> t)

-- | Extract the raw 'Text' from a 'MemoryPath'.
memoryPathText :: MemoryPath -> Text
memoryPathText (MemoryPath t) = t

-- | Split a 'MemoryPath' into its directory segments.
memoryPathSegments :: MemoryPath -> [Text]
memoryPathSegments (MemoryPath t) = T.splitOn "/" t