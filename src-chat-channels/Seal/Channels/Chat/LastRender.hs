{-# LANGUAGE OverloadedStrings #-}
-- | Pure helpers for the chat channel's @\/last@ command: argument parsing,
-- error text, and help.
--
-- This module is a leaf — it imports no chat-loop module, so
-- "Seal.Channels.Chat.Route" can carry the raw argument text
-- ('Seal.Channels.Chat.Route.ChatLast') without a module cycle.
--
-- The render half (extraction, resolution, and the user-visible strings) is
-- added by WU-B; this module currently holds only what WU-A needs.
module Seal.Channels.Chat.LastRender
  ( lastHelp
  , isLastHelpArg
  , LastArgs (..)
  , LastError (..)
  , parseLastArgs
  , renderLastError
  ) where

import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Gateway.Types.Tab
  ( TabIndex, tabIndexFromChar )

-- | Parsed @\/last@ arguments.
data LastArgs = LastArgs
  { laTab   :: Maybe TabIndex  -- ^ 'Nothing' means the focused tab.
  , laCount :: Int             -- ^ Always clamped to @1..5@.
  } deriving stock (Eq, Show)

-- | Everything @\/last@ can tell the user went wrong.
--
-- A bespoke ADT rather than @Either Text@ because 'renderLastError' matches on
-- the constructor to build a distinct string for each, and the tests assert
-- every constructor.
data LastError
  = LENoSuchTab Text      -- ^ the token was not a tab index
  | LEBadCount Text       -- ^ the second token was not a number
  | LENoSession Char      -- ^ the tab is a harness tab (no session)
  | LENoCurrentTab        -- ^ no focused tab to default to
  | LETabs                -- ^ @GET \/api\/lists@ failed
  | LETranscript Char     -- ^ the transcript fetch failed
  | LEQuestions Char      -- ^ the pending-questions fetch failed
  deriving stock (Eq, Show)

-- | Parse the raw argument text carried by
-- 'Seal.Channels.Chat.Route.ChatLast'.
--
-- The first token is a tab iff it is exactly one character AND
-- 'tabIndexFromChar' accepts it. That is stricter than 'parseTabFocus' (which
-- takes the first character of an arbitrary token): @\/last bb@ naming a bad
-- token back is better than silently meaning tab @b@.
parseLastArgs :: Text -> Either LastError LastArgs
parseLastArgs raw =
  case T.words (T.strip raw) of
    [] -> Right (LastArgs Nothing 1)
    [tabTok] -> LastArgs <$> (Just <$> tabOf tabTok) <*> pure 1
    (tabTok : countTok : _) ->
      LastArgs <$> (Just <$> tabOf tabTok) <*> countOf countTok
  where
    tabOf tok = case T.uncons tok of
      Just (c, rest)
        | T.null rest -> either (const (Left (LENoSuchTab tok))) Right (tabIndexFromChar c)
      _ -> Left (LENoSuchTab tok)

    countOf tok
      | T.null t || not (T.all isDigit t) = Left (LEBadCount tok)
      | otherwise = Right (clamp (T.foldl' step 0 t))
      where
        t = T.strip tok
        step acc c = acc * 10 + (fromEnum c - fromEnum '0')

-- | Clamp a requested count into the supported @1..5@ range.
clamp :: Int -> Int
clamp = max 1 . min 5

-- | Is this @\/last@'s help flag? Only as the sole argument, matching
-- @\/watch -h@ (which is not help either — see @handleWatchToggle@).
isLastHelpArg :: Text -> Bool
isLastHelpArg raw = T.strip raw `elem` ["-h", "--help"]

-- | The @\/last@ help text, in the same @T.unlines@ shape as @bgHelp@ and
-- @watchHelp@.
lastHelp :: Text
lastHelp = T.unlines
  [ "Show a tab's last message without switching to it"
  , ""
  , "Usage: /last [tab] [n]"
  , ""
  , "  tab     A tab (0-9a-z). Defaults to the tab you are on."
  , "  n       How many messages, 1-5. Defaults to 1."
  , ""
  , "The first argument is always the tab, so /last 3 means tab 3, not"
  , "three messages."
  , ""
  , "/last never changes the tab you are focused on."
  , ""
  , "If the tab is waiting on a question, /last shows it. Answer it with"
  , "/N <answer> - for example /b 1 or /b yes - which goes to that tab"
  , "without switching to it."
  , ""
  , "Options:"
  , "  -h, --help  Show this help"
  ]

-- | Render an error for display on the channel.
--
-- The four strings the requirements specify are used verbatim; errors the
-- requirements do not cover follow the same @last failed:@ shape as the
-- existing @focus failed:@ / @inject failed:@ / @tab list failed:@ family.
renderLastError :: LastError -> Text
renderLastError err = case err of
  LENoSuchTab t   -> "last failed: no such tab " <> singleLine t <> " \8212 /tab list"
  LEBadCount t    -> "last failed: \"" <> singleLine t
                     <> "\" isn't a number \8212 use /last <tab> 1-5"
  LENoSession c   -> "last failed: tab " <> T.singleton c
                     <> " has no session (harness tab)"
  LENoCurrentTab  -> "last failed: no current tab"
  LETabs          -> "last failed: couldn't read the tab list \8212 try again in a moment"
  LETranscript c  -> "last failed: couldn't read tab " <> T.singleton c
                     <> "'s transcript \8212 try again in a moment"
  LEQuestions c   -> "last failed: couldn't read tab " <> T.singleton c
                     <> "'s question \8212 try again in a moment"

-- | Flatten and bound text that came from the user, before it is echoed back.
--
-- Without this an inbound message of arbitrary length could be echoed into the
-- chat, and its newlines would let a user spoof a harness-authored line (the
-- same argument that motivates block-quoting a question). 16 characters is
-- enough to show which token was rejected.
singleLine :: Text -> Text
singleLine t =
  let flattened = T.unwords (T.words (T.map newlineToSpace t))
  in if T.length flattened > 16
       then T.take 16 flattened <> "\8230"
       else flattened
  where
    newlineToSpace c = if c == '\n' || c == '\r' || c == '\t' then ' ' else c
