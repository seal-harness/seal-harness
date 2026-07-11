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
  , InterpName (..)
  , mkInterpName
  , textInterpName
  , ScriptArg (..)
  , mkScriptArg
  , textScriptArg
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

-- | An interpreter name (e.g. @python3@, @node@). Rejects path separators
-- (the interpreter must be a name resolvable on PATH, not a path — the
-- executor looks it up via a fixed-argv @<name> <script>@, never a
-- constructed path), leading-dash (option injection), control chars, NUL,
-- empty.
newtype InterpName = InterpName Text
  deriving stock (Eq, Show)

mkInterpName :: Text -> Either Text InterpName
mkInterpName t
  | T.null t            = Left "interpreter name is empty"
  | T.head t == '-'     = Left "interpreter name must not start with '-' (option injection)"
  | T.any isNameBad t   = Left "interpreter name has invalid characters"
  | otherwise           = Right (InterpName t)
  where
    isNameBad c = c == '/' || c == '\\' || isControl c

textInterpName :: InterpName -> Text
textInterpName (InterpName t) = t

-- | A script argument to an interpreter. Rejects leading-dash (option
-- injection against the interpreter), NUL, empty.
newtype ScriptArg = ScriptArg Text
  deriving stock (Eq, Show)

mkScriptArg :: Text -> Either Text ScriptArg
mkScriptArg t
  | T.null t            = Left "script arg is empty"
  | T.head t == '-'     = Left "script arg must not start with '-' (option injection)"
  | T.any (== '\0') t   = Left "script arg contains NUL"
  | otherwise           = Right (ScriptArg t)

textScriptArg :: ScriptArg -> Text
textScriptArg (ScriptArg t) = t