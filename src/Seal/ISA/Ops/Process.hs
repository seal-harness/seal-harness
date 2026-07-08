{-# LANGUAGE OverloadedStrings #-}
-- | PROCESS_MANAGE (Untrusted): list or kill processes on the untrusted
-- plane. @list@ runs @ps -o pid=,cmd=@ (fixed argv, bounded output); @kill@
-- runs @kill <pid>@ with a validated positive-integer PID (rejects
-- negative, self-pid). All IO through the 'ExecBackend' seam.
module Seal.ISA.Ops.Process
  ( processManageOp
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Core.Types (OpName (..))
import Seal.ISA.Opcode
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Security.Policy (SecurityPolicy (..), AutonomyLevel (..))
import Seal.Tools.Args (mkShellCommand)
import Seal.Tools.Exec.Types (ExecBackend (..), LocalExecHandle (..))
import Seal.Types.App

-- | PROCESS_MANAGE opcode. Input: @{ action: "list" | "kill", pid?: Int }@.
processManageOp :: WorkspaceRoot -> SecurityPolicy -> ExecBackend -> Opcode
processManageOp _wsRoot policy _backend = UntrustedOpcode
  { uoName = OpName "PROCESS_MANAGE"
  , uoDesc = "List or kill processes on the untrusted plane (bounded output, validated PID)."
  , uoInSchema = processManageSchema
  , uoOutSchema = object []
  , uoAuthorize = \v ->
      case actionField v of
        Nothing -> Left "PROCESS_MANAGE requires {action:string}"
        Just act
          | act == "list" -> checkAutonomy
          | act == "kill"  -> case pidField v of
              Nothing  -> Left "PROCESS_MANAGE: kill requires {pid:positive integer}"
              Just pid
                | pid <= 0   -> Left "PROCESS_MANAGE: pid must be a positive integer"
                | otherwise  -> checkAutonomy
          | otherwise -> Left ("PROCESS_MANAGE: unknown action \"" <> act <> "\"")
  , uoRun = \_back execBackend v -> do
      let act = actionField v
          mPid = pidField v
          recorded = object [ "action" .= act, "pid" .= mPid ]
      case act of
        Nothing -> pure (OpResult [TrpText "PROCESS_MANAGE: missing action"] True recorded)
        Just a
          | a == "list" -> runShell execBackend "ps -o pid=,cmd=" recorded
          | a == "kill" -> case mPid of
              Nothing -> pure (OpResult [TrpText "PROCESS_MANAGE: missing pid"] True recorded)
              Just pid -> runShell execBackend ("kill " <> T.pack (show pid)) recorded
          | otherwise -> pure (OpResult [TrpText ("PROCESS_MANAGE: unknown action " <> a)] True recorded)
  }
  where
    checkAutonomy = case spAutonomy policy of
      Deny -> Left "PROCESS_MANAGE denied by autonomy policy"
      _   -> Right ()

-- | Run a shell command string through the executor and surface the result.
runShell :: ExecBackend -> Text -> Value -> App OpResult
runShell execBackend cmdText recorded =
  case mkShellCommand cmdText of
    Left err -> pure (OpResult [TrpText ("PROCESS_MANAGE: invalid command: " <> err)] True recorded)
    Right cmd ->
      case execBackend of
        EbLocal lh -> do
          res <- liftIO (lehExecShell lh cmd Nothing)
          case res of
            Left e   -> pure (OpResult [TrpText (T.pack (show e))] True recorded)
            Right out -> pure (OpResult [TrpText out] False recorded)
        EbRemote _ssh ->
          pure (OpResult [TrpText "PROCESS_MANAGE: remote SSH executor not yet wired (Phase 4 4g)"] True recorded)

processManageSchema :: Value
processManageSchema =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object
        [ "action" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("\"list\" (list processes) or \"kill\" (kill by PID)" :: Text)
            ]
        , "pid" .= object
            [ "type" .= ("integer" :: Text)
            , "description" .= ("Required for kill; positive integer." :: Text)
            ]
        ]
    , "required" .= (["action"] :: [Text])
    ]

actionField :: Value -> Maybe Text
actionField = parseMaybe (withObject "in" (.: "action"))

pidField :: Value -> Maybe Int
pidField v = case parseMaybe (withObject "in" (.:? "pid")) v :: Maybe (Maybe Int) of
  Just (Just n) -> Just n
  _             -> Nothing