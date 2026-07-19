{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.Parse
  ( tokenize
  , ParseOutcome(..)
  , parseSlash
  ) where

import Data.Char (isSpace)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative
  ( ParserResult(..)
  , defaultPrefs
  , execParserPure
  , renderFailure
  )

import Seal.Command.Spec
  ( CommandAction
  , CommandName(..)
  , Registry
  , csParserInfo
  , lookupSpec
  )

-- ---------------------------------------------------------------------------
-- Tokenizer
-- ---------------------------------------------------------------------------

-- Internal state for the tokenizer state machine.
data TokSt
  = Outside              -- ^ Between tokens
  | InWord  [Char]       -- ^ Inside a bare token (reversed chars accumulated)
  | InQuote [Char]       -- ^ Inside a double-quoted span (reversed chars; continues
                         --   any preceding bare chars so adjacent quoted/unquoted
                         --   sections form a single token, e.g. foo"bar" -> "foobar")

-- | Quote-aware shell-words tokenizer. Supports double-quoted tokens so that
-- @\/vault add "my key"@ correctly produces three tokens. Returns 'Left' with
-- an error message if a double-quote is never closed.
tokenize :: Text -> Either Text [Text]
tokenize input = go Outside (T.unpack input) []
  where
    -- Flush the current InWord accumulator as a completed token.
    flushWord :: [Char] -> [Text] -> [Text]
    flushWord cs acc = T.pack (reverse cs) : acc

    -- Finalize the state machine after all characters have been consumed.
    finish :: TokSt -> [Text] -> Either Text [Text]
    finish Outside     acc = Right (reverse acc)
    finish (InWord cs) acc = Right (reverse (flushWord cs acc))
    finish (InQuote _) _   = Left "unterminated double-quote"

    go :: TokSt -> [Char] -> [Text] -> Either Text [Text]
    go st          []     acc = finish st acc
    -- Outside: skip whitespace; open quote starts quoted token;
    -- any other char starts a bare word.
    go Outside     (c:cs) acc
      | c == '"'             = go (InQuote []) cs acc
      | isSpace c            = go Outside cs acc
      | otherwise            = go (InWord [c]) cs acc
    -- InWord: whitespace terminates this token; quote opens an adjacent
    -- quoted span (still building the *same* token); other chars extend.
    go (InWord ws) (c:cs) acc
      | c == '"'             = go (InQuote ws) cs acc
      | isSpace c            = go Outside cs (flushWord ws acc)
      | otherwise            = go (InWord (c:ws)) cs acc
    -- InQuote: closing quote returns to InWord (bare continuation allowed
    -- immediately after); other chars extend the quoted span.
    go (InQuote ws) (c:cs) acc
      | c == '"'             = go (InWord ws) cs acc
      | otherwise            = go (InQuote (c:ws)) cs acc

-- ---------------------------------------------------------------------------
-- ParseOutcome + parseSlash
-- ---------------------------------------------------------------------------

data ParseOutcome
  = ParsedAction CommandAction
  | ParseHelp    (Maybe CommandName)
  | ParseFailure Text

-- | Parse a full slash-command line; input MUST begin with @\/@.
--
-- Routing rules (in order):
--   1. head word == "help" (case-insensitive)     -> 'ParseHelp'
--   2. "--help"/"-h" is the command's SOLE argument -> 'ParseHelp' (Just head):
--      top-level help for the command itself.
--   3. head word found in registry                 -> 'execParserPure' -> 'ParsedAction'
--      or 'ParseFailure'. A help flag that follows a subcommand token (e.g.
--      @provider add -h@) falls through to here: 'execParserPure' handles
--      @--help@/@-h@ natively at every level (the command parsers use
--      'hsubparser', which gives each subcommand its own help), so the
--      subcommand's help is rendered — as 'ParseFailure' text, which the caller
--      echoes identically to any other help. Rule 2 is deliberately narrow so
--      it never swallows a subcommand-scoped help flag.
--   4. head word not in registry                   -> 'ParseFailure'
--
-- 'CompletionInvoked' from 'execParserPure' is reserved for future
-- shell-completion integration (seal --bash-completion-*); the TUI
-- never triggers it, so it maps to @ParseFailure ""@ (empty, not shown).
parseSlash :: Registry -> Text -> ParseOutcome
parseSlash registry fullLine =
  let line = T.drop 1 fullLine           -- strip leading '/'
  in case tokenize line of
    Left err     -> ParseFailure ("parse error: " <> err)
    Right []     -> ParseFailure "empty command"
    Right (h:rest) ->
      let headName = CommandName h
          -- case-insensitive "help" check
          isHelp   = T.toCaseFold h == "help"
          -- A help flag that is the command's SOLE argument requests the
          -- command's own (top-level) help. A help flag with other tokens
          -- present (a subcommand) is left for execParserPure to dispatch to
          -- the right subcommand — see rule 3 in the Haddock above.
          isTopLevelHelp = rest == ["--help"] || rest == ["-h"]
      in if isHelp
         then ParseHelp (case rest of
                []    -> Nothing
                (n:_) -> Just (CommandName n))
         else if isTopLevelHelp
              then ParseHelp (Just headName)
              else if T.toCaseFold h == "call" && isJust (lookupSpec registry headName)
                   then parseCallRaw registry h line
                   else case lookupSpec registry headName of
                     Nothing   -> ParseFailure ("unknown command: " <> h)
                     Just spec ->
                       -- execParserPure expects [String], not [Text]
                       let args  = map T.unpack rest
                           -- defaultPrefs: enables --help/--version, no disambiguation,
                           -- single-line error context. CompletionInvoked is reserved
                           -- (see note above).
                           prefs = defaultPrefs
                       in case execParserPure prefs (csParserInfo spec) args of
                         Success act         -> ParsedAction act
                         Failure f           ->
                           let (msg, _) = renderFailure f (T.unpack h)
                           in ParseFailure (T.pack msg)
                         CompletionInvoked _ -> ParseFailure ""

-- | Special-case parser for @/call@: the JSON payload may contain
-- double-quotes and spaces that the shell-words tokenizer would strip or
-- split. To preserve the raw JSON, we bypass the tokenizer for the JSON
-- portion: split the line (post-/@/@) into the command name, the opcode
-- name, and the raw rest-of-line as a single string. The @call@ parser
-- then receives @[OP, JSON-raw]@ as its argv.
parseCallRaw :: Registry -> Text -> Text -> ParseOutcome
parseCallRaw registry h line =
  -- line is the full command minus the leading '/'. Drop the command name
  -- ("call") to reach "OP JSON-raw".
  let afterCall = T.dropWhile (== ' ') (T.drop (T.length h) line)
      -- Split into OP and the raw JSON rest on the first run of whitespace.
      (opText, jsonRest) = T.break isSpace afterCall
      jsonRest' = T.dropWhile isSpace jsonRest
      mSpec = lookupSpec registry (CommandName h)
      args = case T.null jsonRest' of
               True  -> [T.unpack opText]                 -- /call OP
               False -> [T.unpack opText, T.unpack jsonRest']  -- /call OP {json...}
  in case mSpec of
       Nothing   -> ParseFailure ("unknown command: " <> h)
       Just spec ->
         case execParserPure defaultPrefs (csParserInfo spec) args of
           Success act         -> ParsedAction act
           Failure f           ->
             let (msg, _) = renderFailure f (T.unpack h)
             in ParseFailure (T.pack msg)
           CompletionInvoked _ -> ParseFailure ""
