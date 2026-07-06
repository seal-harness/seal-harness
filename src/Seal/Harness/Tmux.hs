{-# LANGUAGE OverloadedStrings #-}
-- | The sole chokepoint for tmux subprocesses. Every tmux invocation builds
-- its 'createProcess' config from a fixed argv (no shell, no constructed
-- command string) built by the pure functions below. The tmux
-- session/window/pane identifiers are smart-constructed 'TmuxIdent'
-- newtypes (charset predicate, no leading dash, no colon — option-injection
-- + separator defense) so an attacker-supplied label fails to compile into
-- the argv.
--
-- This module is split: the pure argv builders + 'validateTmuxIdent' +
-- 'stripAnsi' (re-exported) are here; the IO wrappers + the
-- 'TmuxRunner' seam land in T4 (same module).
module Seal.Harness.Tmux
  ( TmuxIdent (..)
  , mkTmuxIdent
  , tmuxIdentText
  , validateTmuxIdent
  -- * Pure argv builders
  , sendKeysNamedArgs
  , sendEnterNamedArgs
  , pasteBufferNamedArgs
  , captureNamedArgs
  , killWindowNamedArgs
  , renameWindowNamedArgs
  , newWindowNamedArgs
  , setWindowMarkerArgs
  , clearWindowMarkerArgs
  , setRemainOnExitArgs
  ) where

import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

-- | A validated tmux identifier (session name, window name, pane id).
-- Smart-constructed: rejects empty, leading dash, control chars, and @:@
-- (tmux's separator — a @:@ in a name would break coordinate parsing).
newtype TmuxIdent = TmuxIdent Text
  deriving stock (Eq, Show)

-- | The charset a tmux ident may contain: @A-Za-z0-9_.%@@ (no @:@ — tmux's
-- separator; no control chars; no leading dash — option injection). @%@
-- is used by tmux pane ids (@%5@).
tmuxIdentChars :: Set Char
tmuxIdentChars = Set.fromList
  $ ['A'..'Z'] <> ['a'..'z'] <> ['0'..'9'] <> "_.%-"

-- | Smart constructor for 'TmuxIdent'. 'Left' on a malformed ident.
mkTmuxIdent :: Text -> Either Text TmuxIdent
mkTmuxIdent t = case validateTmuxIdent t of
  Left err -> Left err
  Right _  -> Right (TmuxIdent t)

-- | The bare predicate: 'Right ()' if valid, 'Left' with an error otherwise.
validateTmuxIdent :: Text -> Either Text ()
validateTmuxIdent t
  | T.null t              = Left "tmux ident is empty"
  | T.head t == '-'       = Left "tmux ident must not start with '-' (option injection)"
  | T.any (== ':') t      = Left "tmux ident must not contain ':' (tmux separator)"
  | not (T.all validChar t) = Left "tmux ident has invalid characters"
  | otherwise             = Right ()
  where
    validChar c = c `Set.member` tmuxIdentChars

tmuxIdentText :: TmuxIdent -> Text
tmuxIdentText (TmuxIdent t) = t

-- ---------------------------------------------------------------------------
-- Pure argv builders — each returns the exact argv list (no shell) that the
-- IO wrapper passes to @tmux@. The target ident is rendered via
-- 'tmuxIdentText' so a 'TmuxIdent' (validated) reaches the argv, never raw
-- 'Text'.
-- ---------------------------------------------------------------------------

-- | @send-keys -t <target> -l -- <text>@ — send literal text. The @-l@ +
-- @--@ separator guards against option injection: a payload starting with
-- @-@ is sent as literal text, not interpreted as a flag. 'sendEnterNamedArgs'
-- is separate so a payload like @"Enter"@ is never parsed as the Enter key.
sendKeysNamedArgs :: TmuxIdent -> Text -> [String]
sendKeysNamedArgs target text =
  [ "send-keys", "-t", T.unpack (tmuxIdentText target), "-l", "--", T.unpack text ]

-- | @send-keys -t <target> Enter@ — send the Enter keystroke. No @-l@/@--@
-- (the key name IS the token).
sendEnterNamedArgs :: TmuxIdent -> [String]
sendEnterNamedArgs target =
  [ "send-keys", "-t", T.unpack (tmuxIdentText target), "Enter" ]

-- | @paste-buffer -t <target> -d seal-paste@ — paste the named paste buffer.
-- (The caller pre-loads the buffer via @load-buffer@; this is the paste
-- half.)
pasteBufferNamedArgs :: TmuxIdent -> Text -> [String]
pasteBufferNamedArgs target _bufName =
  [ "paste-buffer", "-t", T.unpack (tmuxIdentText target), "-d", "seal-paste" ]

-- | @capture-pane -t <target> -p@ — capture the pane content as text.
captureNamedArgs :: TmuxIdent -> [String]
captureNamedArgs target =
  [ "capture-pane", "-t", T.unpack (tmuxIdentText target), "-p" ]

-- | @kill-window -t <target>@.
killWindowNamedArgs :: TmuxIdent -> [String]
killWindowNamedArgs target =
  [ "kill-window", "-t", T.unpack (tmuxIdentText target) ]

-- | @rename-window -t <target> <newName>@.
renameWindowNamedArgs :: TmuxIdent -> TmuxIdent -> [String]
renameWindowNamedArgs target newName =
  [ "rename-window", "-t", T.unpack (tmuxIdentText target), T.unpack (tmuxIdentText newName) ]

-- | @new-window -t <target> -n <name>@.
newWindowNamedArgs :: TmuxIdent -> TmuxIdent -> [String]
newWindowNamedArgs target name =
  [ "new-window", "-t", T.unpack (tmuxIdentText target), "-n", T.unpack (tmuxIdentText name) ]

-- | @set-option -t <target> @<marker> <value>@ — stamp a tmux user option
-- (the @seal_id marker).
setWindowMarkerArgs :: TmuxIdent -> Text -> Text -> [String]
setWindowMarkerArgs target marker value =
  [ "set-option", "-t", T.unpack (tmuxIdentText target)
  , T.unpack ("@" <> marker), T.unpack value ]

-- | @set-option -t <target> -u @<marker>@ — unset (clear) a marker.
clearWindowMarkerArgs :: TmuxIdent -> Text -> [String]
clearWindowMarkerArgs target marker =
  [ "set-option", "-t", T.unpack (tmuxIdentText target), "-u", T.unpack ("@" <> marker) ]

-- | @set-option -t <target> remain-on-exit on@.
setRemainOnExitArgs :: TmuxIdent -> [String]
setRemainOnExitArgs target =
  [ "set-option", "-t", T.unpack (tmuxIdentText target), "remain-on-exit", "on" ]