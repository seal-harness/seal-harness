{-# LANGUAGE OverloadedStrings #-}
-- | Watch-state persistence — the per-conversation watch-all-tabs map
-- survives a @seal serve@ restart. Written atomically (0600) to
-- @\<state\>\/watch_state.json@ on every watch-mode mutation via
-- 'Seal.Util.AtomicJson.saveJsonAtomic'; loaded at boot by 'loadWatchMap'
-- so a conversation's watch mode is restored instead of reset to off.
--
-- The map is encoded as a JSON array of
-- @{"key": {"channel": "...", "conv": "..."}, "enabled": true}@ pairs.
-- 'ConversationKey' is a record, not a JSON-string-keyable type, so the
-- map is serialized as a list of wire objects (mirroring
-- 'Seal.Channels.Cursor.Persist.CursorWire').
module Seal.Channels.Chat.WatchPersist
  ( saveWatchMap
  , loadWatchMap
  ) where

import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import System.Directory (doesFileExist)

import Katip (Severity (..))
import Seal.Channels.Chat.Types (ConversationKey (..))
import Seal.Logging.Global (globalLogIO)
import Seal.Util.AtomicJson (saveJsonAtomic)
import Seal.Util.StrictIO (decodeFileStrict)

-- | The on-disk wire type: a key/enabled pair. The map is converted to/from
-- this list on save/load.
data WatchWire = WatchWire
  { wwKey     :: ConversationKey
  , wwEnabled :: Bool
  }

instance A.ToJSON WatchWire where
  toJSON w = A.object
    [ "key"     A..= ckToJSON (wwKey w)
    , "enabled" A..= wwEnabled w
    ]
    where
      ckToJSON (ConversationKey ch cv) = A.object
        [ "channel" A..= ch
        , "conv"    A..= cv
        ]

instance A.FromJSON WatchWire where
  parseJSON = A.withObject "WatchWire" $ \o -> do
    keyVal <- o A..: "key"
    enabled <- o A..: "enabled"
    case keyVal of
      A.Object ko ->
        case (asText (KeyMap.lookup (Key.fromText "channel") ko),
              asText (KeyMap.lookup (Key.fromText "conv") ko)) of
          (Just ch, Just cv) -> pure (WatchWire (ConversationKey ch cv) enabled)
          _ -> fail "missing channel or conv field"
      _ -> fail "key is not an object"
    where
      asText (Just (A.String t)) = Just t
      asText _ = Nothing

-- | Save a watch-state map to @path@ atomically (0600, MVar-serialized via
-- 'saveJsonAtomic'). Never throws; a write failure is the caller's
-- responsibility to 'catch' (the persisting watch state does so and logs
-- a warning, matching the cursor-store pattern).
saveWatchMap :: FilePath -> Map ConversationKey Bool -> IO ()
saveWatchMap path m =
  saveJsonAtomic path (A.encode (map (uncurry WatchWire) (Map.toList m)))

-- | Load the watch-state map from @path@. Missing file -> 'Nothing' (fresh
-- empty store). Corrupt JSON -> 'Nothing' + a stderr warning (no
-- conversation content in the file — just channel/conversation ids + a
-- boolean). Entries with a missing or malformed key are dropped
-- (defense-in-depth against a tampered file), mirroring
-- 'Seal.Channels.Cursor.Persist.filterValid'.
loadWatchMap :: FilePath -> IO (Maybe (Map ConversationKey Bool))
loadWatchMap path = do
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      mWires <- decodeFileStrict path :: IO (Maybe [WatchWire])
      case mWires of
        Nothing -> do
          globalLogIO WarningS "could not parse watch_state.json; using empty watch state"
          pure Nothing
        Just ws ->
          pure (Just (Map.fromList [ (wwKey w, wwEnabled w) | w <- ws ]))