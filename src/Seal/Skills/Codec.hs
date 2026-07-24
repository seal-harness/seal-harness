{-# LANGUAGE OverloadedStrings #-}
-- | Pure Markdown codec for 'Skill' — frontmatter + body. Split out of
-- 'Seal.Skills.Backend' so the embedded built-in skills
-- ('Seal.Skills.Builtins') can decode their compile-time sources without
-- importing the IO-shaped backend (which would create a module cycle:
-- Backend imports Builtins for the union layer, Builtins imports the
-- codec).
module Seal.Skills.Codec
  ( encodeSkill
  , decodeSkill
  ) where

import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..))
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (secondsToDiffTime)
import Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM)

import Seal.Core.Types (mkSessionId, mkSystemSessionId, sessionIdText)
import Seal.Skills.Types (Skill (..), mkSkillId, skillIdText)
import Seal.Store.Markdown (decodeDoc, encodeDoc, fmLookup)

-- | Encode a 'Skill' as a Markdown document (frontmatter + body).
encodeSkill :: Skill -> Text
encodeSkill s = encodeDoc fm (skBody s)
  where
    fm = Map.fromList
      [ ("id", skillIdText (skId s))
      , ("description", skDescription s)
      , ("created_at", isoTime (skCreatedAt s))
      , ("updated_at", isoTime (skUpdatedAt s))
      , ("session", sessionIdText (skSession s))
      ]

-- | Decode a Markdown document into a 'Skill'. Returns 'Nothing' if the id
-- field is missing or fails 'mkSkillId'. Timestamps default to epoch 0 when
-- absent or unparseable (the file was hand-edited without them).
decodeSkill :: Text -> Maybe Skill
decodeSkill content =
  case decodeDoc content of
    (fm, body) -> do
      sidT <- fmLookup "id" fm
      sid  <- either (const Nothing) Just (mkSkillId sidT)
      Just Skill
        { skId = sid
        , skDescription = fromMaybe "" (fmLookup "description" fm)
        , skBody = body
        , skCreatedAt = parseTime (fmLookup "created_at" fm)
        , skUpdatedAt = parseTime (fmLookup "updated_at" fm)
        , skSession = either (const (mkSystemSessionId "unknown")) id (mkSessionId (fromMaybe "unknown" (fmLookup "session" fm)))
        }

-- | Render a 'UTCTime' as an ISO-8601 string (UTC, with @Z@ suffix).
isoTime :: UTCTime -> Text
isoTime = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

-- | Parse an ISO-8601 'UTCTime' from a frontmatter value. Defaults to epoch 0
-- when absent or unparseable (hand-edited files).
parseTime :: Maybe Text -> UTCTime
parseTime Nothing    = epochZero
parseTime (Just raw) = fromMaybe epochZero (parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (T.unpack raw))

-- | The epoch fallback for missing/unparseable timestamps.
epochZero :: UTCTime
epochZero = UTCTime (fromGregorian 1970 1 1) (secondsToDiffTime 0)