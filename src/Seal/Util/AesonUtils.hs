{-# LANGUAGE FlexibleContexts #-}
-- | Aeson encoding helpers shared across Seal's JSON serializations.
--
-- Vendored from @~/code/equitek/baldr/src/AesonUtils.hs@ (kept as a
-- stand-alone utility so this repo has no cross-repo dependency). The
-- original @lensy*@ helpers target the @\\_<field>@ (underscore-prefixed)
-- lens convention; Seal's record fields use a leading-lowercase prefix
-- instead (@teId@, @crModel@, @cbInputSchema@, @msgRole@, @uInput@, …),
-- so the original helpers don't strip the prefix. The @stripPrefix*@
-- family below handles that convention: drop the leading run of
-- lowercase letters (the lens prefix) and lowercase the first remaining
-- char, yielding @id@, @model@, @inputSchema@, @role@, @input@, …
-- matching the camelCase keys the hand-written @EntryRecord@ /
-- @EnvelopeDelta@ / @SessionMeta@ instances already use.
module Seal.Util.AesonUtils
  ( -- * Original lensy helpers (underscore-prefixed convention)
    lensyLenToJSON
  , lensyLenParseJSON
  , lensyLenOptions
  , lensySnakeToJSON
  , lensySnakeParseJSON
  , lensySnakeOptions
  , lensyToJSON
  , lensyParseJSON
  , lensyOptions
  , lensyKebabToJSON
  , lensyKebabParseJSON
  , lensyKebabOptions
  , lensyFieldNameToNiceJson
  , lensyFieldNameToSnakeJson
  , lensyFieldNameToKebabJson
  , lensyConstructorToNiceJson
  , lensyLenConstructorToNiceJson
    -- * Strip-leading-lowercase-prefix helpers (Seal's convention)
  , stripPrefixToJSON
  , stripPrefixParseJSON
  , stripPrefixOptions
  , stripLensPrefixCamel
  ) where

import Data.Aeson
import Data.Aeson.Types
import Data.Char
import GHC.Generics

-- ---------------------------------------------------------------------------
-- Minimal inline of the bits of @Text.Casing@ the @lensy*Snake@/@lensy*Kebab@
-- helpers need. Vendored here so this module stays dependency-free (the
-- @text-casing@ Hackage package isn't in the pinned haskell.nix index).
-- @fromHumps@ splits @FooBarBaz@ / @fooBarBaz@ into @[Foo, Bar, Baz]@ /
-- @[foo, Bar, Baz]@; @toQuietSnake@ joins with @_@ and lowercases;
-- @toKebab@ joins with @-@ and lowercases.
-- ---------------------------------------------------------------------------

fromHumps :: String -> [String]
fromHumps = foldr go []
  where
    go c []          = [[c]]
    go c (w:ws)
      | isUpper c    = [c] : w : ws
      | otherwise    = (c:w) : ws

toQuietSnake :: [String] -> String
toQuietSnake = concatWith '_' . map (map toLower)
  where concatWith _ []       = ""
        concatWith sep (x:xs) = x <> foldr (\a acc -> sep : a <> acc) "" xs

toKebab :: [String] -> String
toKebab = concatWith '-' . map (map toLower)
  where concatWith _ []       = ""
        concatWith sep (x:xs) = x <> foldr (\a acc -> sep : a <> acc) "" xs

lensyLenToJSON
  :: (Generic a, GToJSON Zero (Rep a)) => Int -> a -> Value
lensyLenToJSON n = genericToJSON (lensyLenOptions n)

lensyLenParseJSON
  :: (Generic a, GFromJSON Zero (Rep a)) => Int -> Value -> Parser a
lensyLenParseJSON n = genericParseJSON (lensyLenOptions n)

lensyLenOptions :: Int -> Options
lensyLenOptions n = defaultOptions { fieldLabelModifier = lensyLenConstructorToNiceJson n }

lensyLenConstructorToNiceJson :: Int -> String -> String
lensyLenConstructorToNiceJson n fieldName = firstToLower $ drop n fieldName
  where
    firstToLower (c:cs) = toLower c : cs
    firstToLower _ = error $ "lensyLenConstructorToNiceJson: bad arguments: " <> show (n,fieldName)

lensySnakeToJSON
  :: (Generic a, GToJSON Zero (Rep a)) => a -> Value
lensySnakeToJSON = genericToJSON lensySnakeOptions

lensySnakeParseJSON
  :: (Generic a, GFromJSON Zero (Rep a)) => Value -> Parser a
lensySnakeParseJSON = genericParseJSON lensySnakeOptions

lensyToJSON
  :: (Generic a, GToJSON Zero (Rep a)) => a -> Value
lensyToJSON = genericToJSON lensyOptions

lensyParseJSON
  :: (Generic a, GFromJSON Zero (Rep a)) => Value -> Parser a
lensyParseJSON = genericParseJSON lensyOptions

lensyOptions :: Options
lensyOptions = defaultOptions
  { fieldLabelModifier = lensyFieldNameToNiceJson
  , constructorTagModifier = lensyConstructorToNiceJson
  }

lensySnakeOptions :: Options
lensySnakeOptions = defaultOptions { fieldLabelModifier = lensyFieldNameToSnakeJson }

lensyFieldNameToNiceJson :: String -> String
lensyFieldNameToNiceJson fieldName = dropWhile (=='_') $ dropWhile (/='_') $ dropWhile (=='_') fieldName

lensyFieldNameToSnakeJson :: String -> String
lensyFieldNameToSnakeJson fieldName = toQuietSnake $ fromHumps $ dropWhile (=='_') $ dropWhile (/='_') $ dropWhile (=='_') fieldName

lensyConstructorToNiceJson :: String -> String
lensyConstructorToNiceJson constructorName = dropWhile (=='_') $ dropWhile (/='_') constructorName

-- Kebab-case JSON serialization (e.g., "base-spread-bips")
lensyKebabToJSON
  :: (Generic a, GToJSON Zero (Rep a)) => a -> Value
lensyKebabToJSON = genericToJSON lensyKebabOptions

lensyKebabParseJSON
  :: (Generic a, GFromJSON Zero (Rep a)) => Value -> Parser a
lensyKebabParseJSON = genericParseJSON lensyKebabOptions

lensyKebabOptions :: Options
lensyKebabOptions = defaultOptions { fieldLabelModifier = lensyFieldNameToKebabJson }

lensyFieldNameToKebabJson :: String -> String
lensyFieldNameToKebabJson fieldName = toKebab $ fromHumps $ dropWhile (=='_') $ dropWhile (/='_') $ dropWhile (=='_') fieldName

-- ---------------------------------------------------------------------------
-- Strip-leading-lowercase-prefix helpers (Seal's convention)
-- ---------------------------------------------------------------------------

-- | Generic 'ToJSON' using 'stripPrefixOptions' — strips the leading run
-- of lowercase letters (the lens prefix) from each record field and
-- lowercases the first remaining char, keeping camelCase for the rest.
--   @teId → id@, @crMaxTokens → maxTokens@, @cbInputSchema → inputSchema@,
--   @msgRole → role@, @uInput → input@, @tdName → name@.
stripPrefixToJSON
  :: (Generic a, GToJSON Zero (Rep a)) => a -> Value
stripPrefixToJSON = genericToJSON stripPrefixOptions

-- | Generic 'FromJSON' using 'stripPrefixOptions'. See 'stripPrefixToJSON'.
stripPrefixParseJSON
  :: (Generic a, GFromJSON Zero (Rep a)) => Value -> Parser a
stripPrefixParseJSON = genericParseJSON stripPrefixOptions

-- | 'Options' that strip the leading lowercase lens prefix from record
-- field names (camelCase preserved). Constructor tags are left as-is
-- (Seal's enums encode as bare tags like @"User"@ / @"Request"@).
stripPrefixOptions :: Options
stripPrefixOptions = defaultOptions { fieldLabelModifier = stripLensPrefixCamel }

-- | Drop the leading run of lowercase letters, then lowercase the first
-- remaining character. Examples:
--
--   * @teId       → id@
--   * @teTimestamp → timestamp@
--   * @crMaxTokens → maxTokens@
--   * @cbInputSchema → inputSchema@
--   * @cbForId    → forId@
--   * @msgRole    → role@
--   * @uInput     → input@
--   * @tdName     → name@
--   * @rsContent  → content@
--
-- Field names with no leading lowercase run (e.g. already-@lowerCamel@
-- keys produced by hand-written instances) are returned unchanged except
-- for the (no-op) first-char lowercasing.
stripLensPrefixCamel :: String -> String
stripLensPrefixCamel fieldName =
  case dropWhile isLower fieldName of
    ""           -> fieldName
    firstUpper:rest -> toLower firstUpper : rest