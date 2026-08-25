{-# LANGUAGE OverloadedStrings #-}
-- | Cursor-map persistence — the 'CursorStore''s @ConversationKey → TabRef@
-- map survives a @seal serve@ (or standalone @seal telegram@ / @seal
-- signal@) restart. Written atomically (0600) to @\<state\>\/cursors.json@
-- on every cursor mutation via 'Seal.Util.AtomicJson.saveJsonAtomic';
-- loaded at boot by 'loadCursorMap' so a conversation re-resolves to its
-- prior session (carrying the user's @\/model use@ choice) instead of a
-- fresh default session.
--
-- The map is encoded as a JSON array of @{"key": [...], "ref": {...}}@
-- pairs (JSON object keys must be strings, and 'ConversationKey' is a
-- '(Text, Text)' tuple, so it cannot key a JSON object directly). Every
-- 'TabRef' id is re-validated on load ('mkSessionId' / 'parseHarnessId')
-- and entries whose id fails to re-parse are dropped (defense-in-depth
-- against a tampered file), mirroring 'Seal.Tabs.Persist.filterValidTabs'.
module Seal.Channels.Cursor.Persist
  ( saveCursorMap
  , loadCursorMap
  ) where

import Data.Aeson qualified as A
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import System.Directory (doesFileExist)

import Katip (Severity (..))
import Seal.Core.Types (mkSessionId, sessionIdText)
import Seal.Harness.Id (parseHarnessId, harnessIdToText)
import Seal.Logging.Global (globalLogIO)
import Seal.Tabs.Types (TabRef (..))
import Seal.Util.AtomicJson (saveJsonAtomic)
import Seal.Util.StrictIO (decodeFileStrict)

-- | The on-disk wire type: a list of key/ref pairs. The map is converted
-- to/from this list on save/load. 'ConversationKey' is a '(Text, Text)'
-- tuple; aeson encodes a tuple as a JSON array, so 'cwKey' serializes as
-- @["telegram","12345"]@. 'TabRef' already has 'ToJSON'/''FromJSON'
-- instances (used by @tabs.json@); reused here.
data CursorWire = CursorWire
  { cwKey :: (Text, Text)
  , cwRef :: TabRef
  }

-- Aeson derives the tuple and TabRef codecs via their existing instances.
-- We hand-write the 'CursorWire' codec (not derive) to control field
-- names and keep the on-disk shape explicit.

instance A.ToJSON CursorWire where
  toJSON cw = A.object
    [ "key" A..= cwKey cw
    , "ref" A..= cwRef cw
    ]

instance A.FromJSON CursorWire where
  parseJSON = A.withObject "CursorWire" $ \o -> CursorWire
    <$> o A..: "key"
    <*> o A..: "ref"

-- | Save a cursor map to @path@ atomically (0600, MVar-serialized via
-- 'saveJsonAtomic'). Never throws; a write failure is the caller's
-- responsibility to 'catch' (the persisting cursor store does so and logs
-- a warning, matching the tab-list pattern).
saveCursorMap :: FilePath -> Map (Text, Text) TabRef -> IO ()
saveCursorMap path m =
  saveJsonAtomic path (A.encode (map (uncurry CursorWire) (Map.toList m)))

-- | Load the cursor map from @path@. Missing file -> 'Nothing' (fresh
-- empty store). Corrupt JSON -> 'Nothing' + a stderr warning (ids + error
-- type only — no conversation content). Every 'TabRef' id is re-validated;
-- entries with an unparseable id are dropped (defense-in-depth against a
-- tampered @cursors.json@).
loadCursorMap :: FilePath -> IO (Maybe (Map (Text, Text) TabRef))
loadCursorMap path = do
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      mWires <- decodeFileStrict path :: IO (Maybe [CursorWire])
      case mWires of
        Nothing -> do
          globalLogIO WarningS "could not parse cursors.json; using empty cursor store"
          pure Nothing
        Just ws -> pure (Just (filterValid (Map.fromList [ (cwKey w, cwRef w) | w <- ws ])))

-- | Drop entries whose 'TabRef' id fails to re-parse. The on-disk ids were
-- validated when written, so a parse failure here means the file was
-- tampered or written by a future/incompatible version — skip rather than
-- error so a corrupt file self-heals on the next save. Mirrors
-- 'Seal.Tabs.Persist.filterValidTabs'.
filterValid :: Map (Text, Text) TabRef -> Map (Text, Text) TabRef
filterValid = Map.filter validRef
  where
    validRef (BoundSession sid) = case mkSessionId (sessionIdText sid) of Right _ -> True; Left _ -> False
    validRef (BoundHarness hid) = case parseHarnessId (harnessIdToText hid) of Right _ -> True; Left _ -> False