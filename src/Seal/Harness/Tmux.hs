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
  -- * IO seam + wrappers
  , TmuxRunner (..)
  , mkRealTmuxRunner
  , startTmuxSessionStatus
  , addHarnessWindowNamed
  , sendToWindowNamed
  , captureWindowNamed
  , stopHarnessWindowNamed
  , renameWindowNamed
  , readMarkers
  , setWindowMarker
  , clearWindowMarker
  , setRemainOnExit
  , checkTmuxCapabilities
  ) where

import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Exit (ExitCode (..))
import System.Process
  ( CreateProcess (..), StdStream (..), proc, waitForProcess, withCreateProcess )

import Seal.Handles.Harness (HarnessError (..))
import Seal.Harness.Id (HarnessId, harnessIdToText)

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

-- ---------------------------------------------------------------------------
-- IO seam + wrappers
-- ---------------------------------------------------------------------------

-- | The process-execution seam: a function that runs @tmux@ with a given
-- argv and returns its stdout. The real implementation uses
-- "System.Process" (no stdin, capture stdout); tests supply a fake that
-- records the argv and returns scripted output.
newtype TmuxRunner = TmuxRunner { runTmux :: [String] -> IO (Either HarnessError Text) }

-- | The real tmux runner via System.Process. Preflight @tmux --version@
-- (fail-closes with 'HeTmuxMissing' if absent).
mkRealTmuxRunner :: IO TmuxRunner
mkRealTmuxRunner = do
  ok <- probeTmux
  pure (TmuxRunner (if ok then runReal else const (pure (Left HeTmuxMissing))))
  where
    runReal args = do
      res <- try @IOException (readTmuxNoInput args)
      case res of
        Right (ExitSuccess, out, _err) -> pure (Right (TE.decodeUtf8Lenient out))
        Right (ExitFailure 127, _, _) -> pure (Left HeTmuxMissing)
        Right (ExitFailure n, _, err) -> pure (Left (HeCaptureFailed ("tmux exited " <> T.pack (show n) <> ": " <> TE.decodeUtf8Lenient err)))
        Left _e                        -> pure (Left HeTmuxMissing)  -- launch failure = not on PATH

-- | Run tmux with no stdin, capturing stdout/stderr as strict ByteStrings.
readTmuxNoInput :: [String] -> IO (ExitCode, BS.ByteString, BS.ByteString)
readTmuxNoInput args =
  withCreateProcess
    ( (proc "tmux" args)
        { std_in = NoStream, std_out = CreatePipe, std_err = CreatePipe }
    ) $ \_ mOut mErr ph -> do
      (hOut, hErr) <- case (mOut, mErr) of
        (Just a, Just b) -> pure (a, b)
        _ -> error "readTmuxNoInput: pipe creation failed (unreachable)"
      out <- BS.hGetContents hOut
      err <- BS.hGetContents hErr
      ec  <- waitForProcess ph
      let !_ = BS.length out
          !_ = BS.length err
      pure (ec, out, err)

-- | Preflight @tmux --version@.
probeTmux :: IO Bool
probeTmux = do
  r <- try @IOException (readTmuxNoInput ["--version"])
  case r of
    Right (ExitSuccess, _, _) -> pure True
    _                         -> pure False

-- | Run a tmux command that's expected to produce no useful stdout (just
-- succeed/fail). Uses the pure argv builder supplied.
runVoid :: TmuxRunner -> [String] -> IO (Either HarnessError ())
runVoid runner args = either Left (const (Right ())) <$> runTmux runner args

-- | Start a tmux session (if absent) — @tmux new-session -d -s <name>@.
startTmuxSessionStatus :: TmuxRunner -> TmuxIdent -> IO (Either HarnessError ())
startTmuxSessionStatus runner session =
  runVoid runner ["new-session", "-d", "-s", T.unpack (tmuxIdentText session)]

-- | Add a harness window to a session, stamp the @seal_id marker.
-- @new-window -t <session> -n <name>@ then @set-option -t <target> @seal_id <id>@.
addHarnessWindowNamed
  :: TmuxRunner -> TmuxIdent -> TmuxIdent -> HarnessId -> IO (Either HarnessError ())
addHarnessWindowNamed runner session name hid = do
  r1 <- runVoid runner (newWindowNamedArgs session name)
  case r1 of
    Left e -> pure (Left e)
    Right _ -> runVoid runner (setWindowMarkerArgs name "seal_id" (harnessIdToText hid))

-- | Send literal text to a window.
sendToWindowNamed :: TmuxRunner -> TmuxIdent -> Text -> IO (Either HarnessError ())
sendToWindowNamed runner target text =
  runVoid runner (sendKeysNamedArgs target text)

-- | Capture the window's pane content as sanitized lines.
captureWindowNamed :: TmuxRunner -> TmuxIdent -> IO (Either HarnessError [Text])
captureWindowNamed runner target = do
  r <- runTmux runner (captureNamedArgs target)
  pure $ case r of
    Left e  -> Left e
    Right t -> Right (filter (not . T.null) (T.lines (T.strip t)))

-- | Stop a harness window (kill-window).
stopHarnessWindowNamed :: TmuxRunner -> TmuxIdent -> IO (Either HarnessError ())
stopHarnessWindowNamed runner target =
  runVoid runner (killWindowNamedArgs target)

-- | Rename a window.
renameWindowNamed :: TmuxRunner -> TmuxIdent -> TmuxIdent -> IO (Either HarnessError ())
renameWindowNamed runner target newName =
  runVoid runner (renameWindowNamedArgs target newName)

-- | Read the tmux user options (markers) for a window.
-- @show-options -t <target>@ → parse @@"key" "value"@ lines into a map.
readMarkers :: TmuxRunner -> TmuxIdent -> IO (Either HarnessError (Map Text Text))
readMarkers runner target = do
  r <- runTmux runner ["show-options", "-t", T.unpack (tmuxIdentText target)]
  pure $ case r of
    Left e  -> Left e
    Right t -> Right (parseMarkers t)

-- | Parse tmux @show-options@ output: lines like @@"seal_id" "abc-uuid"@.
-- Strip the leading @@, unquote the key + value.
parseMarkers :: Text -> Map Text Text
parseMarkers = Map.fromList . mapMaybe parseLine . T.lines
  where
    parseLine ln =
      case T.words ln of
        [k, v] -> case T.uncons k of
          Just ('@', rest) -> Just (rest, unquote v)
          _                -> Nothing
        _ -> Nothing
    unquote v = fromMaybe v (T.stripSuffix "\"" (fromMaybe v (T.stripPrefix "\"" v)))

-- | Stamp a tmux user option (the @seal_id marker).
setWindowMarker :: TmuxRunner -> TmuxIdent -> Text -> Text -> IO (Either HarnessError ())
setWindowMarker runner target marker value =
  runVoid runner (setWindowMarkerArgs target marker value)

-- | Clear a tmux user option.
clearWindowMarker :: TmuxRunner -> TmuxIdent -> Text -> IO (Either HarnessError ())
clearWindowMarker runner target marker =
  runVoid runner (clearWindowMarkerArgs target marker)

-- | Set remain-on-exit on a window.
setRemainOnExit :: TmuxRunner -> TmuxIdent -> IO (Either HarnessError ())
setRemainOnExit runner target =
  runVoid runner (setRemainOnExitArgs target)

-- | Probe tmux capabilities: @seal_id marker support + pane_dead. Returns
-- 'False' if tmux is too old (the show-options call fails).
checkTmuxCapabilities :: TmuxRunner -> IO Bool
checkTmuxCapabilities runner = do
  r <- runTmux runner ["show-options", "-g"]
  case r of
    Right _ -> pure True
    Left _  -> pure False

-- | A fromMaybe that's imported here to avoid an extra import line.
fromMaybe :: a -> Maybe a -> a
fromMaybe d Nothing  = d
fromMaybe _ (Just x) = x

-- | A mapMaybe (local — avoids a Data.Maybe import for one helper).
mapMaybe :: (a -> Maybe b) -> [a] -> [b]
mapMaybe _ []     = []
mapMaybe f (x:xs) = case f x of
  Just y  -> y : mapMaybe f xs
  Nothing -> mapMaybe f xs