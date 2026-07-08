{-# LANGUAGE OverloadedStrings #-}
-- | CODE_EXEC (Untrusted): run a script via a named interpreter (e.g.
-- @python3@, @node@). The interpreter must be in the operator-configured
-- allow-list (else 'Denied'). The script is a validated 'ScriptArg'
-- (rejects NUL, option injection). The interpreter runs via fixed argv
-- (@<name> <script>@ — no shell interpreter). All IO through the
-- 'ExecBackend' seam.
module Seal.ISA.Ops.Code
  ( codeExecOp
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Core.Types (OpName (..))
import Seal.ISA.Opcode
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Security.Policy (SecurityPolicy (..), AutonomyLevel (..))
import Seal.Tools.Args (InterpName, ScriptArg, mkInterpName, mkScriptArg)
import Seal.Tools.Exec.Types (ExecBackend (..), LocalExecHandle (..))
import Seal.Types.App

-- | CODE_EXEC opcode. Input: @{ interpreter: InterpName, script: ScriptArg }@.
-- The interpreter must be in the operator-configured 'Set' allow-list.
codeExecOp :: WorkspaceRoot -> SecurityPolicy -> Set Text -> ExecBackend -> Opcode
codeExecOp _wsRoot policy allowList _backend = UntrustedOpcode
  { uoName = OpName "CODE_EXEC"
  , uoDesc = "Run a script via a named interpreter (allow-listed, validated, fixed-argv)."
  , uoInSchema = codeExecSchema
  , uoOutSchema = object []
  , uoAuthorize = \v ->
      case (interpField v, scriptField v) of
        (Nothing, _) -> Left "CODE_EXEC requires {interpreter:string, script:string}"
        (_, Nothing) -> Left "CODE_EXEC requires {interpreter:string, script:string}"
        (Just interpText, Just scriptText) ->
          case spAutonomy policy of
            Deny -> Left "CODE_EXEC denied by autonomy policy"
            _   -> if interpText `Set.notMember` allowList
                   then Left ("CODE_EXEC: interpreter \"" <> interpText <> "\" not in the allow-list")
                   else case mkScriptArg scriptText of
                          Left _err -> Left "CODE_EXEC: invalid script argument"
                          Right _   -> Right ()
  , uoRun = \_back execBackend v -> do
      let mInterp = interpField v
          mScript = scriptField v
          recorded = object [ "interpreter" .= mInterp, "script_length" .= fmap T.length mScript ]
      case (mInterp, mScript) of
        (Nothing, _) -> pure (OpResult [TrpText "CODE_EXEC: missing interpreter"] True recorded)
        (_, Nothing) -> pure (OpResult [TrpText "CODE_EXEC: missing script"] True recorded)
        (Just interpText, Just scriptText) ->
          case (mkInterpName interpText, mkScriptArg scriptText) of
            (Right interp, Right script) -> runCode execBackend interp [script] recorded
            (Left err, _) -> pure (OpResult [TrpText ("CODE_EXEC: invalid interpreter: " <> err)] True recorded)
            (_, Left err) -> pure (OpResult [TrpText ("CODE_EXEC: invalid script: " <> err)] True recorded)
  }

-- | Run the interpreter with the script arg through the executor.
runCode :: ExecBackend -> InterpName -> [ScriptArg] -> Value -> App OpResult
runCode execBackend interp args recorded =
  case execBackend of
    EbLocal lh -> do
      res <- liftIO (lehExecProgram lh interp args)
      case res of
        Left e   -> pure (OpResult [TrpText (T.pack (show e))] True recorded)
        Right out -> pure (OpResult [TrpText out] False recorded)
    EbRemote _ssh ->
      pure (OpResult [TrpText "CODE_EXEC: remote SSH executor not yet wired (Phase 4 4g)"] True recorded)

codeExecSchema :: Value
codeExecSchema =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object
        [ "interpreter" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("The interpreter name (must be in the operator allow-list)." :: Text)
            ]
        , "script" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("The script to run (validated, NUL-rejected)." :: Text)
            ]
        ]
    , "required" .= (["interpreter", "script"] :: [Text])
    ]

interpField :: Value -> Maybe Text
interpField = parseMaybe (withObject "in" (.: "interpreter"))

scriptField :: Value -> Maybe Text
scriptField = parseMaybe (withObject "in" (.: "script"))