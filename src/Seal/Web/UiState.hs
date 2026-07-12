{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
-- | Persistent UI state for the web gateway: the last-chosen "new tab" form
-- options and the user's accumulated custom-model id history. Persisted as a
-- single JSON file under @\<state\>\/ui_state.json@ so it survives server
-- restarts.
--
-- The store is a small, atomic-write JSON file (not TOML) because the shape
-- is frontend-owned and may evolve quickly, and it carries no secrets —
-- it's plain model ids + a kind tag.
module Seal.Web.UiState
  ( UiState (..)
  , LastOptions (..)
  , UiStateHandle
  , newUiStateHandle
  , getUiState
  , setLastOptions
  , addCustomModel
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, readMVar)
import Data.Aeson
  ( FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.!=), (.=) )
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import System.Directory
  ( createDirectoryIfMissing, doesFileExist, renameFile )
import System.FilePath ((</>), takeDirectory)
import System.IO (hPutStrLn, stderr)

import Seal.Config.Paths (SealPaths (..))

-- | The persisted UI state. Both fields are optional so a missing/empty
-- file decodes to the empty state (the frontend treats that as "use the
-- defaults").
data UiState = UiState
  { usLastOptions  :: Maybe LastOptions
    -- ^ The last-chosen "new tab" form selection.
  , usCustomModels :: [Text]
    -- ^ Custom model ids the user has typed before, most-recent first,
    -- deduped. Kept small (capped at 'maxCustomModels') by 'addCustomModel'.
  } deriving stock (Eq, Show, Generic)

-- | The last-chosen "new tab" form selection. Mirrors the frontend's
-- @useNewTabSpec@ shape; only the user-selectable fields are persisted (the
-- transiently-computed model list + validation state are NOT).
data LastOptions = LastOptions
  { loKind          :: Text
    -- ^ @\"provider\"@ | @\"harness\"@ | @\"attach\"@
  , loProvider      :: Text
  , loModel         :: Text
  , loUseCustomModel :: Bool
  , loAgent         :: Text
  , loFlavour       :: Text
  , loCustomBinary  :: Text
  , loAttachSession :: Text
  , loAttachWindow  :: Text
  , loAttachManual  :: Bool
  } deriving stock (Eq, Show, Generic)

instance ToJSON UiState where
  toJSON s = object
    [ "last_options"  .= usLastOptions s
    , "custom_models" .= usCustomModels s
    ]

instance FromJSON UiState where
  parseJSON = withObject "UiState" $ \o -> UiState
    <$> o .:? "last_options"
    <*> o .:? "custom_models" .!= []

instance ToJSON LastOptions where
  toJSON o = object
    [ "kind"           .= loKind o
    , "provider"       .= loProvider o
    , "model"          .= loModel o
    , "useCustomModel" .= loUseCustomModel o
    , "agent"          .= loAgent o
    , "flavour"        .= loFlavour o
    , "customBinary"   .= loCustomBinary o
    , "attachSession"  .= loAttachSession o
    , "attachWindow"   .= loAttachWindow o
    , "attachManual"   .= loAttachManual o
    ]

instance FromJSON LastOptions where
  parseJSON = withObject "LastOptions" $ \o -> LastOptions
    <$> o .:  "kind"
    <*> o .:? "provider"       .!= ""
    <*> o .:? "model"          .!= ""
    <*> o .:? "useCustomModel" .!= False
    <*> o .:? "agent"          .!= ""
    <*> o .:? "flavour"        .!= "claude-code"
    <*> o .:? "customBinary"   .!= ""
    <*> o .:? "attachSession"  .!= ""
    <*> o .:? "attachWindow"   .!= ""
    <*> o .:? "attachManual"   .!= False

-- | The maximum number of custom model ids retained. Keeps the combobox
-- list bounded — the user is unlikely to type more than 32 unique ids over
-- time, and the list is for fast recall, not an audit log.
maxCustomModels :: Int
maxCustomModels = 32

-- | A handle holding the in-memory copy + the on-disk path. The MVar
-- serializes writes so concurrent PUTs don't interleave file writes.
data UiStateHandle = UiStateHandle
  { uhPath  :: FilePath
  , uhState :: MVar UiState
  }

-- | Create a 'UiStateHandle' by loading the file at
-- @\<state\>\/ui_state.json@. Missing/unparseable file → empty state (a
-- warning is emitted to stderr on a parse error so the operator knows).
newUiStateHandle :: SealPaths -> IO UiStateHandle
newUiStateHandle paths = do
  let path = spState paths </> "ui_state.json"
  mState <- loadUiState path
  ref <- newMVar mState
  pure UiStateHandle { uhPath = path, uhState = ref }

-- | Read the current 'UiState'. Cheap — reads the in-memory copy.
getUiState :: UiStateHandle -> IO UiState
getUiState h = readMVar (uhState h)

-- | Replace the last-chosen form selection. Persists atomically; never
-- throws (a write failure logs to stderr and keeps the in-memory copy so
-- the UI still works within the session).
setLastOptions :: UiStateHandle -> LastOptions -> IO ()
setLastOptions h opts =
  modifyMVar_ (uhState h) $ \s -> do
    let next = s { usLastOptions = Just opts }
    persistUiState (uhPath h) next
    pure next

-- | Add a custom model id to the history. Dedupes, trims, caps at
-- 'maxCustomModels' (most-recent first), and persists atomically. A blank
-- id is a no-op. Never throws.
addCustomModel :: UiStateHandle -> Text -> IO ()
addCustomModel h raw =
  modifyMVar_ (uhState h) $ \s -> do
    let trimmed = T.strip raw
        next = if T.null trimmed
                 then s
                 else s { usCustomModels = dedupe trimmed (usCustomModels s) }
    persistUiState (uhPath h) next
    pure next
  where
    -- Move @x@ to the front, drop any earlier occurrence, cap the tail.
    dedupe x xs = take maxCustomModels (x : filter (/= x) xs)

-- ── Internal: load/persist ─────────────────────────────────────────────

-- | The empty state: no last options, no custom models.
emptyUiState :: UiState
emptyUiState = UiState { usLastOptions = Nothing, usCustomModels = [] }

-- | Load the state file. Missing file → empty state. Unparseable → empty
-- state + a stderr warning (the file is replaced on the next successful
-- write, so corruption self-heals).
loadUiState :: FilePath -> IO UiState
loadUiState path = do
  exists <- doesFileExist path
  if not exists
    then pure emptyUiState
    else do
      bs <- BL.readFile path
      case A.decode bs :: Maybe UiState of
        Just s  -> pure s
        Nothing -> do
          hPutStrLn stderr "Warning: could not parse ui_state.json; using empty UI state"
          pure emptyUiState

-- | Persist the state atomically: write @.tmp@, rename over the target.
-- Creates the parent dir (it exists under @\<state\>@, but the call is
-- idempotent). On any IO error, logs to stderr and continues (the
-- in-memory copy stays; the UI still works within the session).
persistUiState :: FilePath -> UiState -> IO ()
persistUiState path s = do
  createDirectoryIfMissing True (takeDirectory path)
  let tmp = path <> ".tmp"
  BL.writeFile tmp (A.encode s)
  renameFile tmp path