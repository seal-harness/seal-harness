{-# LANGUAGE OverloadedStrings #-}
-- | SHELL_EXEC (Untrusted): run a validated shell command via the
-- 'UntrustedIO' capability. The command is a validated 'ShellCommand'
-- (smart-constructed — NUL rejected, option-injection defense at the
-- executor's @\/bin\/sh -c@ single-arg boundary). The cwd is
-- SafePath-confined to the workspace root. The 'SecurityPolicy' gates the
-- call: a 'Deny' autonomy level rejects before any execution.
-- ACK-before-execute is inherited from the dispatcher (the opcode is
-- 'UntrustedOpcode'). All side-effecting IO is funnelled through
-- 'UntrustedIO'; this module never imports 'System.Process'.
module Seal.ISA.Ops.Shell
  ( shellExecOp
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Text (Text)

import Seal.Core.Types (OpName (..))
import Seal.ISA.Opcode
import Seal.Security.Policy (SecurityPolicy (..), AutonomyLevel (..))
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Tools.Args (mkShellCommand)
import Seal.Tools.Exec.UntrustedIO (renderUntrustedErr, uioShellExec)
import Seal.Tools.Exec.Types (mkRemotePath)
import Seal.Providers.Class (ToolResultPart (..))

-- | SHELL_EXEC opcode: run a validated shell command. Input: @{
-- command: ShellCommand, cwd?: RemotePath }@. Authorize: the
-- 'SecurityPolicy' must not be 'Deny' and the command must parse as a
-- 'ShellCommand'. Run: via 'uioShellExec' (Local or Remote SSH, backend-
-- selected at wiring time). 'orRecorded': the command + cwd (secret-free
-- metadata).
shellExecOp :: WorkspaceRoot -> SecurityPolicy -> Opcode
shellExecOp _wsRoot policy = UntrustedOpcode
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
  , uoRun = \uio v -> do
      let mCmd = commandField v
          mCwd = cwdField v
          recorded = object [ "command" .= (mCmd :: Maybe Text), "cwd" .= mCwd ]
      case mCmd of
        Nothing -> pure (OpResult [TrpText "SHELL_EXEC requires {command:string}"] True recorded)
        Just cmdText ->
          case mkShellCommand cmdText of
            Left err -> pure (OpResult [TrpText ("SHELL_EXEC: invalid command: " <> err)] True recorded)
            Right cmd -> do
              let mCwdPath = case mCwd of
                    Nothing -> Nothing
                    Just t -> case mkRemotePath t of
                      Right rp -> Just rp
                      Left _   -> Nothing
              res <- liftIO (uioShellExec uio cmd mCwdPath)
              pure $ case res of
                Left err   -> OpResult [TrpText (renderUntrustedErr err)] True recorded
                Right out -> OpResult [TrpText out] False recorded
  }

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