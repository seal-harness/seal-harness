{-# LANGUAGE OverloadedStrings #-}
-- | PROCESS_MANAGE (Untrusted): list or kill processes on the untrusted
-- plane. @list@ runs @ps -o pid=,cmd=@ (fixed argv, bounded output); @kill@
-- runs @kill <pid>@ with a validated positive-integer PID (rejects
-- negative, self-pid). All IO through the 'UntrustedIO' seam; this module
-- never imports 'System.Process'.
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
import Seal.Tools.Exec.UntrustedIO (renderUntrustedErr, uioProcessKill, uioProcessList)

-- | PROCESS_MANAGE opcode. Input: @{ action: "list" | "kill", pid?: Int }@.
processManageOp :: WorkspaceRoot -> SecurityPolicy -> Opcode
processManageOp _wsRoot policy = UntrustedOpcode
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
  , uoRun = \uio v -> do
      let act = actionField v
          mPid = pidField v
          recorded = object [ "action" .= act, "pid" .= mPid ]
      case act of
        Nothing -> pure (OpResult [TrpText "PROCESS_MANAGE: missing action"] True recorded)
        Just a
          | a == "list" -> do
              res <- liftIO (uioProcessList uio)
              pure $ case res of
                Left err   -> OpResult [TrpText (renderUntrustedErr err)] True recorded
                Right out -> OpResult [TrpText out] False recorded
          | a == "kill" -> case mPid of
              Nothing -> pure (OpResult [TrpText "PROCESS_MANAGE: missing pid"] True recorded)
              Just pid -> do
                res <- liftIO (uioProcessKill uio pid)
                pure $ case res of
                  Left err -> OpResult [TrpText (renderUntrustedErr err)] True recorded
                  Right _  -> OpResult [TrpText ("killed pid " <> T.pack (show pid))] False recorded
          | otherwise -> pure (OpResult [TrpText ("PROCESS_MANAGE: unknown action " <> a)] True recorded)
  }
  where
    checkAutonomy = case spAutonomy policy of
      Deny -> Left "PROCESS_MANAGE denied by autonomy policy"
      _   -> Right ()

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