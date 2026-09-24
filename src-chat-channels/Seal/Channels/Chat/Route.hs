{-# LANGUAGE OverloadedStrings #-}
-- | The Layer-1 terse-grammar routing for chat channels. A pure reimplementation
-- of 'Seal.Routing.Route.route' using only 'Seal.Gateway.Types.Tab' for
-- 'TabIndex' + 'tabIndexFromChar' (no dependency on 'Seal.Handles.Tab' or
-- 'Seal.Tabs.Types').
--
-- The routing logic matches the existing 'Seal.Routing.Route.route' exactly
-- so behavior is identical between old and new channel implementations.
module Seal.Channels.Chat.Route
  ( ChatRoute (..)
  , RouteError (..)
  , route
  , parseTabFocus
  , terseSynopsis
  ) where

import Data.Char (isDigit, isAsciiLower)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Gateway.Types.Tab
  ( TabIndex, tabIndexFromChar )
import Seal.Gateway.Types.TabList
  ( TabSlashCommand (..) )

-- | A routing error (invalid tab index char).
newtype RouteError = RouteError Text
  deriving stock (Eq, Show)

-- | The Layer-1 routing decision for chat channels. Mirrors
-- 'Seal.Routing.Route.RoutingDecision' but lives in the chat-channels
-- package so it has no dependency on server internals.
data ChatRoute
  = ChatFocus TabIndex                 -- ^ /N
  | ChatInject TabIndex Text           -- ^ /N payload
  | ChatPlain Text                     -- ^ plain text to the focused session
  | ChatTabCommand TabSlashCommand     -- ^ /tab <subcommand> …
  | ChatCurrentTab                     -- ^ bare /tab — show the current tab
  | ChatNewSession Text                -- ^ /new [args] — the raw arg string
  | ChatSlash Text                     -- ^ other /commands (deferred to the HTTP API)
  deriving stock (Eq, Show)

-- | Route one inbound line. The Layer-1 terse grammar:
--
-- * @\/N@          -> 'ChatFocus' N (N is a single char 0-9a-z, at end-of-string
--                   or followed by a space)
-- * @\/N payload@  -> 'ChatInject' N payload
-- * @\/tab@        -> 'ChatCurrentTab' (show the current tab)
-- * @\/new [args]@ -> 'ChatNewSession' (the raw text after @/new @)
-- * @\/<other>…@   -> 'ChatSlash' (deferred to the HTTP API — the gateway
--                   server routes slash commands for the web frontend)
-- * anything else  -> 'ChatPlain'
route :: Text -> Either RouteError ChatRoute
route t
  | T.null t             = Right (ChatPlain t)
  | T.head t /= '/'      = Right (ChatPlain t)
  | otherwise            =
      let rest = T.drop 1 t  -- drop the leading '/'
      in case T.uncons rest of
           Nothing -> Right (ChatPlain "/")  -- a bare "/" — treat as plain
           Just (c, after)
              | isTabChar c && (T.null after || T.head after == ' ') ->
                  -- single-char /N or /N payload (the tab grammar)
                  case tabIndexFromChar c of
                    Left e -> Left (RouteError e)
                    Right idx -> Right (focusOrInject idx after)
               | rest == "tab" ->
                  Right ChatCurrentTab
               | rest == "new" || T.isPrefixOf "new " rest ->
                  Right (ChatNewSession (stripNewPrefix rest))
               | otherwise ->
                  Right (ChatSlash rest)
  where
    isTabChar c = isDigit c || isAsciiLower c

-- | Extract the argument text from the @new@ prefix. @\"new\"@ yields
-- @\"\"@; @\"new -p anthropic\"@ yields @\"-p anthropic\"@.
stripNewPrefix :: Text -> Text
stripNewPrefix rest =
  if rest == "new"
    then ""
    else T.drop 1 (snd (T.breakOn " " rest))  -- everything after the first space

-- | Given a valid tab index + the text after it: if the rest is empty (or
-- whitespace-only), it's a Focus; otherwise it's an Inject (the payload is
-- the text after the first space, preserving internal spaces verbatim).
focusOrInject :: TabIndex -> Text -> ChatRoute
focusOrInject idx after
  | T.null (T.strip after) = ChatFocus idx
  | otherwise               =
      let payload = T.drop 1 (snd (T.breakOn " " after))  -- everything after the first space
      in ChatInject idx payload

-- | Parse @\/tab focus \<N\>@ from the inbound body. Returns 'Just' the
-- 'TabIndex' if the body is @\/tab focus \<N\>@ (case-insensitive, N is a
-- single tab-index char 0-9a-z), 'Nothing' otherwise. Used by the loop to
-- intercept @\/tab focus@ locally (send a 'FocusOp' over WS, not an HTTP
-- send).
parseTabFocus :: Text -> Maybe TabIndex
parseTabFocus body =
  case route body of
    Right (ChatSlash rest) ->
      let parts = T.words (T.toCaseFold rest)
      in case parts of
           ["tab", "focus", idxStr] -> case T.uncons idxStr of
             Just (c, _) -> either (const Nothing) Just (tabIndexFromChar c)
             Nothing     -> Nothing
           _ -> Nothing
    _ -> Nothing

-- | The terse-grammar synopsis (for /help). One line.
terseSynopsis :: Text
terseSynopsis = "/N [payload]  Switch to tab N (0-9a-z), or inject payload into it"
