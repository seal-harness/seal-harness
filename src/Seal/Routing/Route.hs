{-# LANGUAGE OverloadedStrings #-}
-- | The Layer-1 terse-grammar routing front-end. @\/N@ switches focus to
-- tab N, @\/N payload@ injects into tab N, a bare @\/tab …@ parses to the
-- 'TabSlashCommand' family, @\/<other>…@ is deferred to the @\/@-command
-- registry, anything else is plain text to the focused tab. The grammar is
-- a first-class synopsis entry in @\/help@ so it's discoverable.
module Seal.Routing.Route
  ( ParseError (..)
  , RoutingDecision (..)
  , route
  , terseSynopsis
  ) where

import Data.Char (isDigit, isAsciiLower)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Core.Types (mkSessionId)
import Seal.Handles.Tab (TabIndex, tabIndexFromChar)
import Seal.Tabs.Types
  ( ForceMode (..), TabKindArg (..), TabSlashCommand (..) )

-- | A parse error from the routing grammar.
newtype ParseError = ParseError Text
  deriving stock (Eq, Show)

-- | The Layer-1 routing decision.
data RoutingDecision
  = Focus TabIndex                 -- ^ /N
  | Inject TabIndex Text           -- ^ /N payload
  | Plain Text                     -- ^ plain text to the focused tab
  | TabCommand TabSlashCommand     -- ^ /tab …
  | SlashCommand Text              -- ^ other /commands (deferred to the registry)
  deriving stock (Eq, Show)

-- | Route one inbound line. The Layer-1 terse grammar:
--
-- * @\/N@          -> 'Focus' N (N is a single char 0-9a-z, at end-of-string
--                   or followed by a space)
-- * @\/N payload@  -> 'Inject' N payload
-- * @\/tab …@      -> 'TabCommand' (parsed via the /tab command ADT)
-- * @\/<other>…@   -> 'SlashCommand' (deferred to the registry — this is
--                   multi-char commands like @\/vault@, @\/help@, @\/ping@)
-- * anything else  -> 'Plain'
--
-- The disambiguator: a single tab-char @\/N@ is the tab grammar ONLY when N
-- is alone (end-of-string or followed by a space). @\/vault@ (no space after
-- @v@) is a 'SlashCommand', not @Inject v ault@. A @\/@ followed by a
-- non-tab, non-tab-command char is a 'SlashCommand'.
route :: Text -> Either ParseError RoutingDecision
route t
  | T.null t             = Right (Plain t)
  | T.head t /= '/'      = Right (Plain t)
  | otherwise            =
      let rest = T.drop 1 t  -- drop the leading '/'
      in case T.uncons rest of
           Nothing -> Right (Plain "/")  -- a bare "/" — treat as plain
           Just (c, after)
             | isTabChar c && (T.null after || T.head after == ' ') ->
                 -- single-char /N or /N payload (the tab grammar)
                 case tabIndexFromChar c of
                   Left e -> Left (ParseError e)
                   Right idx -> Right (focusOrInject idx after)
             | T.isPrefixOf "tab" rest && (T.length rest == 3 || T.head (T.drop 3 rest) == ' ') ->
                 Right (TabCommand (parseTabCmd (T.drop 3 rest)))
             | otherwise ->
                 Right (SlashCommand rest)
  where
    isTabChar c = isDigit c || isAsciiLower c

-- | Given a valid tab index + the text after it: if the rest is empty (or
-- whitespace-only), it's a Focus; otherwise it's an Inject (the payload is
-- the text after the first space, preserving internal spaces verbatim).
focusOrInject :: TabIndex -> Text -> RoutingDecision
focusOrInject idx after
  | T.null (T.strip after) = Focus idx
  | otherwise               =
      let payload = T.drop 1 (snd (T.breakOn " " after))  -- everything after the first space
      in Inject idx payload

-- | Parse the /tab subcommand family. 'rest' is the text after "/tab"
-- (with the leading space if any).
parseTabCmd :: Text -> TabSlashCommand
parseTabCmd rest =
  let words' = T.words (T.strip rest)
  in case words' of
       []                   -> TabListCmd
       ("list" : _)         -> TabListCmd
       ("new" : kindArgs)   -> TabNewCmd (parseKindArg kindArgs)
       ("close" : idxArgs)  -> parseClose idxArgs
       ("focus" : idxArgs)  -> case idxArgs of
         (idxStr : _) -> case tabIndexFromChar (T.head idxStr) of
           Right i  -> TabFocusCmd i
           Left _   -> TabListCmd  -- malformed; fall back
         []          -> TabListCmd
       ("resume" : sidArgs) -> case sidArgs of
         (sidStr : _) -> case mkSessionId sidStr of
           Right s  -> TabResumeCmd s
           Left _   -> TabListCmd  -- malformed; fall back
         []          -> TabListCmd
       ("rename" : idxStr : nameParts) -> case tabIndexFromChar (T.head idxStr) of
         Right i  -> TabRenameCmd i (T.intercalate " " nameParts)
         Left _   -> TabListCmd
       ("rename" : _)       -> TabListCmd
       _                    -> TabListCmd  -- unknown /tab subcommand → list

-- | Parse the kind arg from the "new" subcommand's args.
parseKindArg :: [Text] -> Maybe TabKindArg
parseKindArg [] = Nothing
parseKindArg (k : _) = case k of
  "ai"       -> Just TkaAi
  "provider" -> Just TkaProvider
  "harness"  -> Just TkaHarness
  "shell"    -> Just TkaShell
  "ssh"      -> Just TkaSsh
  "tmux"     -> Just TkaTmux
  _          -> Nothing

-- | Parse the close subcommand: "close <N> [--force]".
parseClose :: [Text] -> TabSlashCommand
parseClose idxArgs =
  case idxArgs of
    (idxStr : restArgs) -> case tabIndexFromChar (T.head idxStr) of
      Right i  -> TabCloseCmd i (if "--force" `elem` restArgs then Force else NoForce)
      Left _   -> TabListCmd
    [] -> TabListCmd

-- | The terse-grammar synopsis (for /help). One line.
terseSynopsis :: Text
terseSynopsis = "/N [payload]  Switch to tab N (0-9a-z), or inject payload into it"