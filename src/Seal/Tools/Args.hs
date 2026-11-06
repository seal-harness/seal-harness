{-# LANGUAGE OverloadedStrings #-}
-- | Validated argv newtypes (Invariant 2 — type-guaranteed argument
-- sanitization). Every value derived from user/LLM input that reaches a
-- subprocess argv must be carried by one of these validated,
-- smart-constructed newtypes — never raw 'Text'/'String'. The exec
-- wrappers accept ONLY these types in their signatures, so passing
-- unsanitized input fails to compile.
--
-- Defense against option injection is built into every smart constructor:
-- reject leading-dash values and always pass a leading @--@ separator
-- before user-derived arguments at the call site. Reject NUL, newlines
-- (where they would break argv token boundaries), and control chars.
module Seal.Tools.Args
  ( ShellArg (..)
  , mkShellArg
  , textShellArg
  , ShellCommand (..)
  , mkShellCommand
  , textShellCommand
  , BinName (..)
  , mkBinName
  , textBinName
  , BinArg (..)
  , mkBinArg
  , textBinArg
  , SearchPattern (..)
  , mkSearchPattern
  , textSearchPattern
  , BranchName
  , mkBranchName
  , branchNameText
  ) where

import Data.Char (isControl)
import Data.Text (Text)
import Data.Text qualified as T

-- | A single argv token (a program argument). Rejects leading-dash (option
-- injection), NUL, newlines, and control chars.
newtype ShellArg = ShellArg Text
  deriving stock (Eq, Show)

mkShellArg :: Text -> Either Text ShellArg
mkShellArg t
  | T.null t            = Left "shell arg is empty"
  | T.head t == '-'     = Left "shell arg must not start with '-' (option injection)"
  | T.any isArgBad t    = Left "shell arg contains NUL, newline, or control char"
  | otherwise           = Right (ShellArg t)
  where
    isArgBad c = c == '\0' || c == '\n' || isControl c

textShellArg :: ShellArg -> Text
textShellArg (ShellArg t) = t

-- | A shell command string — the single argument passed to @\/bin\/sh -c@.
-- Rejects NUL (which would terminate the C-string early). Does NOT reject
-- leading dash (a command may begin with @-@; the executor passes it as a
-- single arg to @-c@, not as a flag). Does NOT reject newlines (a shell
-- command legitimately spans lines).
newtype ShellCommand = ShellCommand Text
  deriving stock (Eq, Show)

mkShellCommand :: Text -> Either Text ShellCommand
mkShellCommand t
  | T.null t            = Left "shell command is empty"
  | T.any (== '\0') t   = Left "shell command contains NUL"
  | otherwise           = Right (ShellCommand t)

textShellCommand :: ShellCommand -> Text
textShellCommand (ShellCommand t) = t

-- | A binary name (e.g. @python3@, @node@, @ls@). The executor resolves
-- it on PATH via 'System.Process.proc' (RawCommand — no shell), so the
-- value never passes through a shell. Minimal validation: reject empty
-- and NUL (which would truncate the C-string). Leading dashes are
-- permitted (a binary *may* legitimately begin with @-@), and the
-- argv-passing model means leading-dash args are passed as argv tokens,
-- not flags to a shell. Path separators are permitted (the binary may be
-- an absolute or relative path). Control chars other than NUL are
-- permitted (the executor passes them verbatim through argv).
newtype BinName = BinName Text
  deriving stock (Eq, Show)

mkBinName :: Text -> Either Text BinName
mkBinName t
  | T.null t          = Left "binary name is empty"
  | T.any (== '\0') t = Left "binary name contains NUL"
  | otherwise         = Right (BinName t)

textBinName :: BinName -> Text
textBinName (BinName t) = t

-- | A single argv token passed to a binary. The executor uses
-- 'System.Process.proc' (RawCommand), so the value is never interpreted
-- by a shell — it is passed verbatim as one argv entry. Minimal
-- validation: reject empty and NUL. Leading dashes are permitted (a
-- leading-dash arg is a flag for the binary, not option injection — the
-- caller explicitly chose to pass it).
newtype BinArg = BinArg Text
  deriving stock (Eq, Show)

mkBinArg :: Text -> Either Text BinArg
mkBinArg t
  | T.null t          = Left "bin arg is empty"
  | T.any (== '\0') t = Left "bin arg contains NUL"
  | otherwise         = Right (BinArg t)

textBinArg :: BinArg -> Text
textBinArg (BinArg t) = t

-- | A search pattern passed to a search tool (e.g. @rg@). Smart-constructed:
-- rejects empty and leading-dash (option-injection defense at the search
-- tool's argv boundary). NUL/newlines rejected so the pattern cannot break
-- out of its single argv token. The validated newtype is what the
-- 'UntrustedIO' search methods accept; the caller never passes raw 'Text'.
newtype SearchPattern = SearchPattern Text
  deriving stock (Eq, Show)

mkSearchPattern :: Text -> Either Text SearchPattern
mkSearchPattern t
  | T.null t          = Left "search pattern is empty"
  | T.head t == '-'   = Left "search pattern must not start with '-' (option injection)"
  | T.any isArgBad t  = Left "search pattern contains NUL, newline, or control char"
  | otherwise         = Right (SearchPattern t)
  where
    isArgBad c = c == '\0' || c == '\n' || isControl c

textSearchPattern :: SearchPattern -> Text
textSearchPattern (SearchPattern t) = t

-- | A git branch name destined for a subprocess argv — typically
-- @git clone --branch=<b>@ or @git fetch origin <b>:refs\/heads\/<b>@.
--
-- The constructor is deliberately NOT exported (the same shape as
-- 'Seal.Core.Types.SessionId'): a 'BranchName' can only be produced by
-- 'mkBranchName', so unvalidated 'Text' cannot reach the exec wrappers.
--
-- Validation runs on the input with surrounding whitespace stripped (so
-- @\"  dev  \"@ becomes @\"dev\"@) and rejects:
--
--   * the empty name;
--   * @HEAD@, which names a commit rather than a branch;
--   * a leading @-@ (option injection, as in 'mkShellArg');
--   * characters git forbids in a refname (space, @~@, @^@, @:@, @?@, @*@,
--     @[@, backslash) and any control character or NUL;
--   * @..@ and @{@-sequences, a leading or trailing @\/@, @\/\/@, a trailing
--     @.@, and a @.lock@ suffix.
--
-- Error messages are distinct per rule; callers prefix them with
-- @\"invalid branch: \"@.
newtype BranchName = BranchName Text
  deriving stock (Eq, Show)

mkBranchName :: Text -> Either Text BranchName
mkBranchName raw
  | T.null t = Left "branch name is empty"
  | t == "HEAD" = Left "branch name must not be HEAD (HEAD names a commit, not a branch)"
  | T.head t == '-' = Left "branch name must not start with '-' (option injection)"
  | T.any isRefnameBad t = Left "branch name contains a character git forbids in refnames (space, ~, ^, :, ?, *, [, backslash, control char, or NUL)"
  | ".." `T.isInfixOf` t = Left "branch name must not contain '..'"
  | "@{" `T.isInfixOf` t = Left "branch name must not contain '@{'"
  | "/" `T.isPrefixOf` t = Left "branch name must not start with '/'"
  | "/" `T.isSuffixOf` t = Left "branch name must not end with '/'"
  | "//" `T.isInfixOf` t = Left "branch name must not contain '//'"
  | "." `T.isSuffixOf` t = Left "branch name must not end with '.'"
  | ".lock" `T.isSuffixOf` t = Left "branch name must not end with '.lock'"
  | otherwise = Right (BranchName t)
  where
    t = T.strip raw
    isRefnameBad c =
      c `elem` (" ~^:?*[\\" :: String) || c == '\0' || isControl c

branchNameText :: BranchName -> Text
branchNameText (BranchName t) = t
