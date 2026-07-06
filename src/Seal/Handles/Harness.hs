{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The harness capability handle — the seam the registry, reconcile loop,
-- and (Phase 6b) the tab runtime use to drive one harness. A no-op handle
-- backs the registry/reconcile tests so they need no real tmux. The
-- sanitize helpers ('stripAnsi'/'stripControl') strip escape sequences and
-- control bytes from captured screen content (a captured screen may carry
-- escape sequences that could spoof the observer or the transcript).
module Seal.Handles.Harness
  ( HarnessStatus (..)
  , HarnessError (..)
  , HarnessHandle (..)
  , noOpHarnessHandle
  , stripAnsi
  , stripControl
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Char (isControl)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

-- | The liveness states a harness can be in.
data HarnessStatus
  = HsIdle | HsThinking | HsAwaitingInput | HsExited | HsOrphaned
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The harness error type. Matched on to drive control flow (so it earns
-- being a sum type per the haskell-coder skill).
data HarnessError
  = HeSpawnFailed Text
  | HeCaptureFailed Text
  | HeStopFailed Text
  | HeNotFound Text
  | HeTmuxMissing
  deriving stock (Eq, Show)

-- | The capability record of IO actions for driving one harness. Every
-- field is an IO action so the type is uniform between real (tmux-backed)
-- and fake (no-op) variants.
data HarnessHandle = HarnessHandle
  { hhSend     :: Text -> IO (Either HarnessError ())
    -- ^ Send text (keystrokes) to the harness.
  , hhReceive  :: IO (Either HarnessError [Text])
    -- ^ Capture the current screen as sanitized lines.
  , hhSnapshot :: IO (Either HarnessError Text)
    -- ^ Full screen capture (sanitized).
  , hhStatus   :: IO (Either HarnessError HarnessStatus)
    -- ^ The current liveness.
  , hhStop     :: IO (Either HarnessError ())
    -- ^ Stop the harness (kill the tmux window).
  }

-- | A no-op handle for tests: sends succeed, receive/snapshot return empty,
-- status is HsIdle, stop succeeds.
noOpHarnessHandle :: HarnessHandle
noOpHarnessHandle = HarnessHandle
  { hhSend     = \_ -> pure (Right ())
  , hhReceive  = pure (Right [])
  , hhSnapshot = pure (Right "")
  , hhStatus   = pure (Right HsIdle)
  , hhStop     = pure (Right ())
  }

-- | Strip ANSI escape sequences (CSI: @\\x1b[\\x30-\\x3f*@\\x20-\\x2f*@\\x40-\\x7e@)
-- from a captured line. Pure.
stripAnsi :: Text -> Text
stripAnsi = T.unfoldr go
  where
    go s
      | T.null s = Nothing
      | T.head s == '\x1b' = case T.uncons s of
          Just ('\x1b', s1)
            | Just ('[', s2) <- T.uncons s1 ->
                -- CSI: ESC [ 0x30-0x3f* 0x20-0x2f* 0x40-0x7e
                let rest = dropCsi s2
                in go rest
            | otherwise -> go s1  -- drop the ESC alone
          _ -> Nothing  -- unreachable: s is non-null
      | otherwise = Just (T.head s, T.tail s)

    -- Drop the parameter + intermediate bytes + the final byte.
    dropCsi s =
      let afterParams = T.dropWhile (\c -> c >= '\x30' && c <= '\x3f') s
          afterInter  = T.dropWhile (\c -> c >= '\x20' && c <= '\x2f') afterParams
      in case T.uncons afterInter of
           Just (_final, rest) -> rest
           Nothing             -> T.empty  -- incomplete CSI; drop everything

-- | Strip ALL control characters (a superset of 'stripAnsi' — also removes
-- NUL/BEL/BS/DEL etc., not just CSI sequences). Pure.
stripControl :: Text -> Text
stripControl = T.filter (not . isControl)