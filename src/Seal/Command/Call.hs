{-# LANGUAGE OverloadedStrings #-}
-- | The @/call@ command: directly invoke a named ISA opcode with
-- user-supplied JSON arguments, bypassing the LLM. The opcode name is
-- matched case-sensitively against the active session's ISA registry
-- (the same registry the agent loop dispatches against). The argument
-- payload is parsed as JSON; missing/invalid payloads are surfaced as
-- plain-text errors.
--
-- Runs the opcode under 'Full' autonomy semantics: the operator is the
-- human approver by typing the command, so the per-call confirmation
-- gate ('Supervised' autonomy) is skipped — exactly mirroring how a
-- turn under @--yolo@ dispatches. The opcode's own authorize gate still
-- applies (e.g. BIN_EXEC's allow-list, SHELL_EXEC's policy).
module Seal.Command.Call
  ( callCommandSpec
  , CallDispatcher
  , renderOpResult
  , renderDispatchError
  ) where

import Data.Aeson (Value, eitherDecode')
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Options.Applicative

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..)
  , CommandName (..), CommandSpec (..) )
import Seal.Core.Types (OpName (..))
import Seal.ISA.Dispatch (DispatchError (..))
import Seal.ISA.Opcode (OpResult (..))
import Seal.Providers.Class (ToolResultPart (..))

-- | The channel-supplied dispatcher. Built by the wiring at each channel
-- (CLI TUI, web) with the right 'Seal.ISA.Registry.Registry',
-- 'Seal.Handles.Transcript.TwoFileHandle', 'Seal.ISA.Opcode.BackendExec',
-- 'Seal.Tools.Exec.Types.ExecBackend', and 'Seal.Types.App.Env' for the
-- active session. Returns the structured 'DispatchError' \/ 'OpResult'
-- so the command can render either outcome.
type CallDispatcher = OpName -> Value -> IO (Either DispatchError OpResult)

-- | The @/call@ command spec. Closes over the channel-supplied
-- 'CallDispatcher'. The dispatcher is per-session (it threads the active
-- session's transcript + registry); the wiring rebuilds the spec on
-- session change.
callCommandSpec :: CallDispatcher -> CommandSpec
callCommandSpec dispatcher = CommandSpec
  { csName         = CommandName "call"
  , csAliases      = []
  , csGroup        = GroupTools
  , csSynopsis     = "Invoke an ISA opcode directly with JSON args"
  , csParserInfo   = callParserInfo dispatcher
  , csAvailability = InteractiveOnly
  }

callParserInfo :: CallDispatcher -> ParserInfo CommandAction
callParserInfo dispatcher =
  info (callParser dispatcher <**> helper)
    (  progDesc "Invoke an ISA opcode directly (bypassing the LLM)"
    <> header   "call — directly dispatch an opcode with JSON args"
    )

callParser :: CallDispatcher -> Parser CommandAction
callParser dispatcher = callCmd dispatcher
  <$> opNameArg
  <*> jsonArg

-- | @/call OP NAME JSON-ARGS@ — invoke the opcode with the parsed JSON
-- value. If the JSON argument is omitted, an empty object is passed (for
-- opcodes that take no input). The command line is echoed as the first
-- line of the output so the "Command output" bubble is self-contained
-- (the web channel clears the optimistic "You" bubble on slash responses).
callCmd :: CallDispatcher -> Text -> Maybe Text -> CommandAction
callCmd dispatcher opNameText mJson = CommandAction $ \caps -> do
  ccSend caps (echoLine opNameText mJson)
  case mkOpNameText opNameText of
    Left err -> ccSend caps ("invalid opcode name: " <> err)
    Right opName ->
      case mJson of
        Nothing -> run dispatcher caps opName (Aeson.object [])
        Just raw ->
          case eitherDecode' (BL.fromStrict (TE.encodeUtf8 raw)) of
            Left err   -> ccSend caps
              ( "invalid JSON: " <> T.pack err
                <> "\nThe JSON arg must be a complete JSON value (object, array, or string)."
                <> "\nFor a bare token like a name, wrap it as a JSON object, e.g.:"
                <> "\n  /call " <> opNameText <> " {\"name\":\"" <> raw <> "\"}" )
            Right val  -> run dispatcher caps opName val

-- | Reconstruct the command line for the echo header.
echoLine :: Text -> Maybe Text -> Text
echoLine op mJson = "$ /call " <> op <> maybe "" (" " <>) mJson

-- | Validate the opcode name (only the constructor check; the lookup
-- happens in the dispatcher).
mkOpNameText :: Text -> Either Text OpName
mkOpNameText t
  | T.null t            = Left "opcode name is empty"
  | T.any (== '\0') t   = Left "opcode name contains NUL"
  | otherwise           = Right (OpName t)

run :: CallDispatcher -> ChannelCaps -> OpName -> Value -> IO ()
run dispatcher caps opName val = do
  res <- dispatcher opName val
  case res of
    Left e -> ccSend caps (renderDispatchError e)
    Right r -> mapM_ (ccSend caps) (renderOpResult r)

-- | Render a 'DispatchError' as a single line.
renderDispatchError :: DispatchError -> Text
renderDispatchError = \case
  OpNotFound (OpName n) -> "opcode not found: " <> n
  Denied why            -> "denied: " <> why
  ExecFailed why         -> "exec failed: " <> why

-- | Render an 'OpResult' as one line per text part. Non-text parts are
-- shown via their 'Show' instance. The error flag is prefixed when set
-- so the operator can tell a failed run from a successful one.
renderOpResult :: OpResult -> [Text]
renderOpResult r =
  let prefix = if orIsError r then "[error] " else ""
      body = case orParts r of
        [] -> [prefix <> "(no output)"]
        xs -> [ prefix <> t | TrpText t <- xs ]
  in if null body then [prefix <> "(no output)"] else body

-- ---------------------------------------------------------------------------
-- optparse helpers
-- ---------------------------------------------------------------------------

-- | Required opcode-name argument. The metavar @OP@ hints at the
-- opcodes' convention (e.g. @SHELL_EXEC@, @FILE_READ@).
opNameArg :: Parser Text
opNameArg = T.pack <$> strArgument
  ( metavar "OP"
  <> help "Opcode name (e.g. SHELL_EXEC, FILE_READ, BIN_EXEC)" )

-- | Optional JSON argument. Parsed by 'eitherDecode'' at dispatch time;
-- parse errors are surfaced to the user. Quoting is up to the shell
-- (the tokenizer handles double-quoted tokens).
jsonArg :: Parser (Maybe Text)
jsonArg = optional (T.pack <$> strArgument
  ( metavar "JSON"
  <> help "Opcode input as a JSON object (default: {})" ))