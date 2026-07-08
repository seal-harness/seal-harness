{-# LANGUAGE OverloadedStrings #-}
-- | SHELL_EXEC (Untrusted): run a validated shell command via the
-- 'ExecBackend'. The command is a validated 'ShellCommand' (smart-
-- constructed — NUL rejected, option-injection defense at the executor's
-- @\/bin\/sh -c@ single-arg boundary). The cwd is 'SafePath'-confined to
-- the workspace root. The 'SecurityPolicy' gates the call: a 'Deny'
-- autonomy level rejects before any execution. ACK-before-execute is
-- inherited from the dispatcher (the opcode is 'UntrustedOpcode').
module Seal.ISA.Ops.Shell
  ( shellExecOp
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Core.Types (OpName (..))
import Seal.ISA.Opcode
import Seal.Security.Policy (SecurityPolicy (..), AutonomyLevel (..))
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Tools.Args (ShellCommand, mkShellCommand)
import Seal.Tools.Exec.Types (ExecBackend (..), LocalExecHandle (..), mkRemotePath)
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Types.App

-- | SHELL_EXEC opcode: run a validated shell command. Input: @{
-- command: ShellCommand, cwd?: RemotePath }@. Authorize: the
-- 'SecurityPolicy' must not be 'Deny' and the command must parse as a
-- 'ShellCommand'. Run: via 'ExecBackend'\'s 'lehExecShell' (Local or
-- Remote SSH). 'orRecorded': the command + cwd (secret-free metadata).
shellExecOp :: WorkspaceRoot -> SecurityPolicy -> ExecBackend -> Opcode
shellExecOp _wsRoot policy _backend = UntrustedOpcode
  { uoName = OpName "SHELL_EXEC"
  , uoDesc = "Run a shell command (validated, SafePath-confined, AuthorizedCommand-gated)."
  , uoInSchema = shellExecSchema
  , uoOutSchema = object []
  , uoAuthorize = \v ->
      case commandField v of
        Nothing -> Left "SHELL_EXEC requires {command:string}"
        Just cmd -> case mkShellCommand cmd of
          Left _err -> Left "SHELL_EXEC: invalid command"
          Right _ -> case spAutonomy policy of
            Deny -> Left "SHELL_EXEC denied by autonomy policy"
            _   -> Right ()
  , uoRun = \_back execBackend v -> do
      let mCmd = commandField v
          mCwd = cwdField v
          recorded = object [ "command" .= (mCmd :: Maybe Text), "cwd" .= mCwd ]
      case mCmd of
        Nothing -> pure (OpResult [TrpText "SHELL_EXEC requires {command:string}"] True recorded)
        Just cmdText ->
          case mkShellCommand cmdText of
            Left err -> pure (OpResult [TrpText ("SHELL_EXEC: invalid command: " <> err)] True recorded)
            Right cmd -> runShell execBackend cmd mCwd recorded
  }

-- | Run the validated command through the executor and surface the result.
runShell :: ExecBackend -> ShellCommand -> Maybe Text -> Value -> App OpResult
runShell execBackend cmd mCwd recorded =
  case execBackend of
    EbLocal lh -> do
      let mCwdPath = case mCwd of
            Nothing -> Nothing
            Just t -> case mkRemotePath t of
              Right rp -> Just rp
              Left _   -> Nothing
      res <- liftIO (lehExecShell lh cmd mCwdPath)
      case res of
        Left e   -> pure (OpResult [TrpText (T.pack (show e))] True recorded)
        Right out -> pure (OpResult [TrpText out] False recorded)
    EbRemote _ssh ->
      pure (OpResult [TrpText "SHELL_EXEC: remote SSH executor not yet wired (Phase 4 4g)"] True recorded)

shellExecSchema :: Value
shellExecSchema =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object
        [ "command" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("The shell command to run (passed as a single arg to /bin/sh -c)." :: Text)
            ]
        , "cwd" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("Optional cwd (workspace-relative, SafePath-confined)." :: Text)
            ]
        ]
    , "required" .= (["command"] :: [Text])
    ]

commandField :: Value -> Maybe Text
commandField = parseMaybe (withObject "in" (.: "command"))

cwdField :: Value -> Maybe Text
cwdField v = case parseMaybe (withObject "in" (.:? "cwd")) v :: Maybe (Maybe Text) of
  Just (Just t) -> Just t
  _             -> Nothing