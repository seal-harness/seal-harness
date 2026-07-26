{-# LANGUAGE OverloadedStrings #-}
-- | The Layer-1 terse-grammar routing front-end. @\/N@ switches focus to
-- tab N, @\/N payload@ injects into tab N, a bare @\/tab@ or @\/tabs@ shows
-- the current tab, @\/tab \u003cargs\u003e@ is a parse error (subcommands
-- live under @\/tabs \u003csubcommand\u003e@), @\/<other>…@ is deferred to the
-- @\/@-command registry, anything else is plain text to the focused tab.
-- The grammar is a first-class synopsis entry in @\/help@ so it's
-- discoverable.
module Seal.Routing.Route
  ( ParseError (..)
  , RoutingDecision (..)
  , route
  , terseSynopsis
  ) where

import Data.Char (isDigit, isAsciiLower)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Handles.Tab (TabIndex, tabIndexFromChar)
import Seal.Tabs.Types (TabSlashCommand (..))

-- | A parse error from the routing grammar.
newtype ParseError = ParseError Text
  deriving stock (Eq, Show)

-- | The Layer-1 routing decision.
data RoutingDecision
  = Focus TabIndex                 -- ^ /N
  | Inject TabIndex Text           -- ^ /N payload
  | Plain Text                     -- ^ plain text to the focused tab
  | TabCommand TabSlashCommand     -- ^ /tabs <subcommand> … (reserved; /tabs
                                   --   is dispatched via the registry, but
                                   --   this variant is kept for future
                                   --   Layer-1 tab-command routing)
  | CurrentTab                     -- ^ bare /tab — show the current tab
  | NewSession                     -- ^ /new — start a fresh session in the current tab
  | SlashCommand Text              -- ^ other /commands (deferred to the registry)
  deriving stock (Eq, Show)

-- | Route one inbound line. The Layer-1 terse grammar:
--
-- * @\/N@          -> 'Focus' N (N is a single char 0-9a-z, at end-of-string
--                   or followed by a space)
-- * @\/N payload@  -> 'Inject' N payload
-- * @\/tab@        -> 'CurrentTab' (show the current tab)
-- * @\/tabs@       -> 'CurrentTab' (alias for @\/tab@)
-- * @\/tab \u003cargs\u003e@ -> 'ParseError' (subcommands live under @\/tabs@,
--                   which is dispatched via the registry as a 'SlashCommand')
-- * @\/new@        -> 'NewSession' (start a fresh session in the current tab)
-- * @\/<other>…@   -> 'SlashCommand' (deferred to the registry — this is
--                   multi-char commands like @\/vault@, @\/help@, @\/ping@,
--                   and @\/tabs <subcommand>@)
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
                  if T.length rest == 3
                    then Right CurrentTab
                    else Left (ParseError "/tab shows the current tab; use /tabs <subcommand> (e.g. /tabs list, /tabs close N)")
              | rest == "tabs" ->
                  Right CurrentTab
              | rest == "new" || T.isPrefixOf "new " rest ->
                  Right NewSession
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

-- | The terse-grammar synopsis (for /help). One line.
terseSynopsis :: Text
terseSynopsis = "/N [payload]  Switch to tab N (0-9a-z), or inject payload into it"