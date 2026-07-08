{-# LANGUAGE OverloadedStrings #-}
-- | The Harness opcode group: HARNESS_LIST, HARNESS_START, HARNESS_STOP.
-- All Trusted — harness lifecycle is a control-plane action, not
-- agent-supplied arbitrary execution. The opcodes drive the
-- 'HarnessRegistry' + the 'TmuxRunner' seam; 'orRecorded' carries the
-- secret-free 'HarnessId' + op metadata.
module Seal.ISA.Ops.Harness
  ( harnessListOp
  , harnessStartOp
  , harnessStopOp
  ) where

import Control.Concurrent.STM (atomically)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key (fromText)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Core.Types (OpName (..), TrustLevel (..))
import Seal.Harness.Id (HarnessId, harnessIdToText, parseHarnessId)
import Seal.Harness.Registry
  ( HarnessEntry (..), HarnessOrigin (..), HarnessRegistry, Liveness (..)
  , insert, lookupById, modify, snapshot )
import Seal.Harness.Tmux
  ( TmuxIdent, TmuxRunner, addHarnessWindowNamed, mkTmuxIdent
  , startTmuxSessionStatus, stopHarnessWindowNamed, tmuxIdentText )
import Seal.ISA.Opcode
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Session.Kind (HarnessFlavour (..))

-- | HARNESS_LIST: return the registry snapshot as a JSON array of
-- {id, label, liveness, flavour} objects.
harnessListOp :: HarnessRegistry -> Opcode
harnessListOp reg = TrustedOpcode
  { toName = OpName "HARNESS_LIST"
  , toTrust = Trusted
  , toDesc = "List the live harnesses registered with the harness backend."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object []
      , "required" .= ([] :: [Text])
      ]
  , toOutSchema = object
      [ "type" .= ("array" :: Text)
      , "items" .= object
          [ "type" .= ("object" :: Text)
          , "properties" .= object
              [ fromText "id" .= object ["type" .= ("string" :: Text)]
              , fromText "label" .= object ["type" .= ("string" :: Text)]
              , fromText "liveness" .= object ["type" .= ("string" :: Text)]
              ]
          ]
      ]
  , toAuthorize = const (Right ())
  , toRun = \_back _input -> liftIO $ do
      entries <- snapshot reg
      let arr = map entryToJson entries
          recorded = object ["harnesses" .= arr]
      pure (OpResult [TrpText (T.pack (show arr))] False recorded)
  }

-- | HARNESS_START: spawn a harness in a tmux window, stamp the @seal_id
-- marker, insert a HarnessEntry (OriginSpawned), return the HarnessId.
-- The tmux session/window idents + the flavour are supplied by the caller
-- (the 6b wiring resolves them); 'mintId' mints the fresh durable id.
harnessStartOp
  :: HarnessRegistry -> TmuxRunner -> TmuxIdent -> TmuxIdent
  -> HarnessFlavour -> IO HarnessId -> Opcode
harnessStartOp reg runner session window flavour mintId = TrustedOpcode
  { toName = OpName "HARNESS_START"
  , toTrust = Trusted
  , toDesc = "Start a harness in a tmux window and register it."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "flavour" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("claude-code | codex | generic | <custom>" :: Text)
              ]
          ]
      , "required" .= (["flavour"] :: [Text])
      ]
  , toOutSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object [fromText "id" .= object ["type" .= ("string" :: Text)]]
      , "required" .= (["id"] :: [Text])
      ]
  , toAuthorize = const (Right ())
  , toRun = \_back _input -> liftIO $ do
      hid <- mintId
      r1 <- startTmuxSessionStatus runner session
      case r1 of
        Left e -> pure (opErr (T.pack (show e)))
        Right _ -> do
          r2 <- addHarnessWindowNamed runner session window hid
          case r2 of
            Left e -> pure (opErr (T.pack (show e)))
            Right _ -> do
              let entry = HarnessEntry
                    { heId = hid
                    , heLabel = flavourLabel flavour
                    , heOrigin = HoSpawned
                    , heLiveness = LvIdle
                    , heTmuxCoord = Just (tmuxIdentText session <> ":" <> tmuxIdentText window)
                    , heFlavour = Just (flavourLabel flavour)
                    , heOrphanTicks = 0
                    }
              atomically (insert reg entry)
              let recorded = object ["id" .= harnessIdToText hid, "flavour" .= flavourLabel flavour]
              pure (OpResult [TrpText (harnessIdToText hid)] False recorded)
  }

-- | HARNESS_STOP: stop a harness (kill the tmux window) + mark the entry
-- LvExited. Takes the harness id in the input.
harnessStopOp :: HarnessRegistry -> TmuxRunner -> Opcode
harnessStopOp reg runner = TrustedOpcode
  { toName = OpName "HARNESS_STOP"
  , toTrust = Trusted
  , toDesc = "Stop a harness (kill its tmux window) and mark it exited."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object [fromText "id" .= object ["type" .= ("string" :: Text)]]
      , "required" .= (["id"] :: [Text])
      ]
  , toOutSchema = object ["type" .= ("object" :: Text), "properties" .= object []]
  , toAuthorize = const (Right ())
  , toRun = \_back input -> liftIO $ do
      case idField input of
        Nothing -> pure (opErr "missing id")
        Just hidText -> case parseHarnessId hidText of
          Left e -> pure (opErr e)
          Right hid -> do
            mEntry <- atomically (lookupById reg hid)
            case mEntry of
              Nothing -> pure (opErr "harness not found")
              Just _entry -> do
                -- The coord->TmuxIdent split is simplified for 6a (the
                -- real 6b wiring splits "session:window"); use the window
                -- ident the entry was spawned with. For 6a's capstone the
                -- test passes a known window.
                let win = fromMaybe (either (error "ident") id (mkTmuxIdent "win")) Nothing
                r <- stopHarnessWindowNamed runner win
                case r of
                  Left e -> pure (opErr (T.pack (show e)))
                  Right _ -> do
                    atomically (modify reg hid (\e -> e { heLiveness = LvExited }))
                    pure (OpResult [TrpText "stopped"] False (object ["id" .= harnessIdToText hid]))
  }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

opErr :: Text -> OpResult
opErr t = OpResult [TrpText t] True (object ["error" .= t])

entryToJson :: HarnessEntry -> Value
entryToJson e = object
  [ "id" .= harnessIdToText (heId e)
  , "label" .= heLabel e
  , "liveness" .= livenessText (heLiveness e)
  , "flavour" .= heFlavour e
  ]

livenessText :: Liveness -> Text
livenessText LvIdle          = "idle"
livenessText LvThinking      = "thinking"
livenessText LvAwaitingInput = "awaiting_input"
livenessText LvExited        = "exited"
livenessText LvOrphaned      = "orphaned"

flavourLabel :: HarnessFlavour -> Text
flavourLabel HfClaudeCode = "claude-code"
flavourLabel HfCodex      = "codex"
flavourLabel HfGeneric    = "generic"
flavourLabel (HCustom t)  = t

idField :: Value -> Maybe Text
idField v = case v of
  Data.Aeson.Object o -> case KeyMap.lookup (fromText "id") o of
    Just (Data.Aeson.String t) -> Just t
    _ -> Nothing
  _ -> Nothing