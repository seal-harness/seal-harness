{-# LANGUAGE OverloadedStrings #-}
-- | Pure rendering for the chat channel's @\/tab list@.
--
-- The registry's @\/tab list@ (@Seal.Command.Tab.listCmd@) cannot serve this
-- surface: it has no access to the broker's thinking set, so it cannot show
-- whether a tab is busy, and its format carries no repo. Chat renders from
-- @GET \/api\/lists@ instead, which carries both.
--
-- Row format (D5):
--
-- > <tab-id> <activity> <repo>: <name>     -- when the session has a repo
-- > <tab-id> <activity>: <name>            -- when it does not
--
-- @<tab-id>@ is the index as @\/tab close N@ accepts it (0-9, a-z);
-- @<activity>@ is @busy@ or @idle@.
module Seal.Channels.Chat.TabRender
  ( TabListRow (..)
  , renderTabListRow
  , tabListRows
  ) where

import Data.Aeson (Value)
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Channels.Chat.HttpClient (ListsJson (..), TabJson (..))
import Seal.Gateway.Types.Tab (mkTabIndex, tabIndexToChar)

-- | One resolved row of @\/tab list@.
data TabListRow = TabListRow
  { tlrIndex :: !Int
  , tlrBusy  :: !Bool
  , tlrRepo  :: Maybe Text
  , tlrName  :: !Text
  } deriving stock (Eq, Show)

-- | Render one row. Pure, and the single source of the wire format.
renderTabListRow :: TabListRow -> Text
renderTabListRow r =
  renderIndex (tlrIndex r) <> " " <> activity <> repoPart <> ": " <> tlrName r
  where
    activity = if tlrBusy r then "busy" else "idle"
    repoPart = maybe "" (" " <>) (tlrRepo r)

-- | Render a tab index the way the terse grammar spells it (0-9, then a-z).
-- An out-of-range index (which the server never emits) falls back to decimals.
renderIndex :: Int -> Text
renderIndex n = case mkTabIndex n of
  Right i -> T.singleton (tabIndexToChar i)
  Left _  -> T.pack (show n)

-- | Resolve every tab into a row.
tabListRows :: ListsJson -> [TabListRow]
tabListRows lj = map row (ljTabs lj)
  where
    thinking = ljThinkingSessionIds lj

    row t = TabListRow
      { tlrIndex = tjIndex t
      , tlrBusy  = isBusy t
      , tlrRepo  = mSession t >>= lookupText "repoUrl" >>= repoFromUrl
      , tlrName  = fromMaybe "harness" (nameOf t)
      }

    -- A tab is busy when its session is thinking. A harness tab has no
    -- session, so it falls back to the harness's own liveness.
    isBusy t = case tjSessionId t of
      Just sid -> sid `elem` thinking
      Nothing  -> tjStatus t == Just "running"

    -- The session info object behind a tab, when there is one.
    mSession t = tjSessionId t >>= \sid ->
      case filter (\s -> lookupText "id" s == Just sid) (ljTabSessions lj) of
        (s : _) -> Just s
        []      -> Nothing

    -- Label, then the frontend's title cascade, then a stable fallback.
    nameOf t = firstNonEmpty
      [ tjLabel t
      , mSession t >>= lookupText "description"
      , mSession t >>= lookupText "autoSummary"
      , mSession t >>= lookupText "firstMessageSnippet"
      , mSession t >>= lookupText "agent"
      , Just $ case tjSessionId t of
          Just sid -> "session:" <> T.take 12 sid
          Nothing  -> "harness"
      ]

-- | The last non-empty path segment of a repo URL, with a trailing @.git@ and
-- any trailing slash removed. @Nothing@ for an empty or segment-less URL.
repoFromUrl :: Text -> Maybe Text
repoFromUrl raw =
  case lastNonEmpty (T.splitOn "/" (T.dropWhileEnd (== '/') (T.strip raw))) of
    Nothing  -> Nothing
    Just seg -> Just (fromMaybe seg (T.stripSuffix ".git" seg))

lastNonEmpty :: [Text] -> Maybe Text
lastNonEmpty = foldl' (\acc t -> if T.null (T.strip t) then acc else Just t) Nothing

-- | The first non-empty 'Just' in the list.
firstNonEmpty :: [Maybe Text] -> Maybe Text
firstNonEmpty = foldr pick Nothing
  where
    pick (Just t) _ | not (T.null (T.strip t)) = Just t
    pick _        acc                          = acc

-- | Look up a string field in a JSON object.
lookupText :: Text -> Value -> Maybe Text
lookupText k val = case val of
  A.Object o -> case KeyMap.lookup (Key.fromText k) o of
    Just (A.String t) -> Just t
    _                 -> Nothing
  _ -> Nothing
