{-# LANGUAGE OverloadedStrings #-}
-- | Shared Markdown frontmatter codec for the file-backed evolutionary stores
-- (skills, agent defs, memory). Format:
--
-- @
-- ---
-- id: greet
-- description: greeting skill
-- tags: ["a", "b"]
-- updated_at: 2026-07-05T13:39:00Z
-- ---
--
-- body line one
-- @
--
-- The frontmatter is flat @key: value@ lines (one per line). Values are
-- either bare scalars (rendered as-is) or JSON literals (for lists / nulls /
-- bools), parsed permissively. This is a hand-rolled minimal codec — not full
-- YAML — to avoid adding a YAML dependency. The body is everything after the
-- closing @---@ fence.
module Seal.Store.Markdown
  ( Frontmatter
  , parseFrontmatter
  , renderFrontmatter
  , fmLookup
  , fmLookupList
  , splitFrontmatter
  , splitFrontmatterRaw
  , encodeDoc
  , decodeDoc
  , renderValue
  ) where

import Data.Aeson (Value (..), decode, encode)
import Data.Foldable (toList)
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

-- | A flat frontmatter map (key -> raw value text, as written in the file).
type Frontmatter = Map Text Text

-- | Split a document into (frontmatter, body). The frontmatter is the text
-- between the opening and closing @---@ fences (exclusive); the body is
-- everything after the closing fence, with one leading blank line stripped.
-- A document with no frontmatter returns @('Map.empty', body)@.
splitFrontmatter :: Text -> (Frontmatter, Text)
splitFrontmatter content =
  case T.stripPrefix "---" (T.dropWhile (== '\r') content) of
    Nothing -> (Map.empty, content)
    Just afterOpen ->
      case T.uncons afterOpen of
        Just ('\n', rest) -> goBody rest
        Just ('\r', rest) -> goBody (T.drop 1 rest)
        _                 -> (Map.empty, content)
  where
    goBody rest =
      case T.breakOn "\n---" rest of
        (fmRaw, afterBreak) ->
          let fm = parseFrontmatter fmRaw
              body = case T.stripPrefix "\n---" afterBreak of
                Nothing   -> afterBreak  -- malformed; keep as-is
                Just after -> T.dropWhile (== '\n') after
          in (fm, body)

-- | Split a frontmatter fence off the front of a document, returning the
-- **raw** inner block (unparsed) and the body after the closing fence.
-- Mirrors PureClaw's @extractFrontmatter@: recognizes a leading @"---\\n"@
-- and a terminating @"\\n---\\n"@. Returns @('Nothing', originalInput)@ when
-- the document does not start with a fence or the fence is not closed. Use
-- this when the frontmatter is a non-YAML-ish dialect (e.g. TOML, as in
-- PureClaw-style @AGENTS.md@) and the caller wants to decode the inner
-- block with a dedicated codec rather than 'parseFrontmatter'.
splitFrontmatterRaw :: Text -> (Maybe Text, Text)
splitFrontmatterRaw input =
  case T.stripPrefix "---\n" input of
    Nothing -> (Nothing, input)
    Just rest ->
      case T.breakOn "\n---\n" rest of
        (_, "") -> (Nothing, input)  -- no closing fence
        (inner, afterBreak) ->
          let body = T.drop (T.length ("\n---\n" :: Text)) afterBreak
          in (Just inner, body)

-- | Parse a block of @key: value@ lines into a 'Frontmatter' map. Blank lines
-- and lines starting with @#@ are skipped.
parseFrontmatter :: Text -> Frontmatter
parseFrontmatter block =
  Map.fromList
    [ (T.strip k, T.strip v)
    | line <- T.lines block
    , not (T.null (T.strip line))
    , not ("#" `T.isPrefixOf` T.strip line)
    , let (k, v) = case T.breakOn ": " line of
            (kk, vv) | T.null vv -> (kk, "")
                     | otherwise -> (kk, T.drop 2 vv)
    ]

-- | Render a 'Frontmatter' map as @---\\nkey: value\\n...\\n---@. Keys are
-- emitted in 'Map.toAscList' order (deterministic for stable git diffs).
renderFrontmatter :: Frontmatter -> Text
renderFrontmatter fm =
  T.unlines (["---"] <> [k <> ": " <> v | (k, v) <- Map.toAscList fm] <> ["---"])

-- | Look up a scalar value by key.
fmLookup :: Text -> Frontmatter -> Maybe Text
fmLookup = Map.lookup

-- | Look up a JSON-array value by key, returning the list of string elements.
-- A value of @[\"a\", \"b\"]@ yields @["a","b"]@. Non-array values yield
-- 'Nothing'.
fmLookupList :: Text -> Frontmatter -> Maybe [Text]
fmLookupList key fm = case Map.lookup key fm of
  Nothing  -> Nothing
  Just raw -> case decode (BL.fromStrict (TE.encodeUtf8 raw)) of
    Just (Array xs) -> Just [ t | String t <- toList xs ]
    _               -> Nothing

-- | Encode a document: render the frontmatter fence, a blank line, then the
-- body.
encodeDoc :: Frontmatter -> Text -> Text
encodeDoc fm body = renderFrontmatter fm <> "\n" <> body

-- | Decode a document: split into frontmatter + body.
decodeDoc :: Text -> (Frontmatter, Text)
decodeDoc = splitFrontmatter

-- | Render a 'Value' as a compact one-line JSON string (for embedding in a
-- frontmatter value line). Used by the encoders for list/optional fields.
renderValue :: Value -> Text
renderValue = TE.decodeUtf8 . BL.toStrict . encode