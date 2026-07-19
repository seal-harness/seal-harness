{-# LANGUAGE OverloadedStrings #-}
-- | BIN_EXEC (Untrusted): run a named binary with a list of argv
-- arguments, via 'System.Process.proc' (RawCommand — no shell
-- interpreter). The binary name and args are validated 'BinName' /
-- 'BinArg' (reject empty, NUL). An optional operator-configured
-- allow-list (a 'Set' of permitted binary names) gates the binary;
-- when the allow-list is 'Nothing' the binary is permitted by the gate
-- (the autonomy policy still applies). All IO through the 'ExecBackend'
-- seam.
module Seal.ISA.Ops.Bin
  ( binExecOp
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Core.Types (OpName (..))
import Seal.ISA.Opcode
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Security.Policy (SecurityPolicy (..), AutonomyLevel (..))
import Seal.Tools.Args (BinName, BinArg, mkBinName, mkBinArg)
import Seal.Tools.Exec.Types (ExecBackend (..), LocalExecHandle (..))
import Seal.Types.App

-- | BIN_EXEC opcode. Input: @{ binary: BinName, args: [BinArg, ...] }@.
-- The @args@ field is optional (defaults to @[]@); the @binary@ field is
-- required. When 'sbAllowList' is 'Nothing', any 'BinName' passes the
-- authorize gate (the autonomy policy still applies); when it is
-- @'Just' set@, the binary must be in @set@ or the gate returns 'Denied'.
binExecOp
  :: WorkspaceRoot
  -> SecurityPolicy
  -> Maybe (Set Text)
  -> ExecBackend
  -> Opcode
binExecOp _wsRoot policy mAllowList _backend = UntrustedOpcode
  { uoName = OpName "BIN_EXEC"
  , uoDesc = "Run a named binary with argv args (no shell, optional allow-list)."
  , uoInSchema = binExecSchema
  , uoOutSchema = object []
  , uoAuthorize = \v ->
      case (binaryField v, argsField v) of
        (Nothing, _) -> Left "BIN_EXEC requires {binary:string, args:[string]}"
        (Just binText, mArgsText) ->
          case spAutonomy policy of
            Deny -> Left "BIN_EXEC denied by autonomy policy"
            _    -> case mAllowList of
              Just allowList
                | binText `Set.notMember` allowList ->
                  Left ("BIN_EXEC: binary \"" <> binText <> "\" not in the allow-list")
              _ -> case mkBinName binText of
                     Left _err -> Left "BIN_EXEC: invalid binary name"
                     Right _   -> case traverse mkBinArg <$> mArgsText of
                                    Just (Left _err) -> Left "BIN_EXEC: invalid arg"
                                    _                -> Right ()
  , uoRun = \_back execBackend v -> do
      let mBin  = binaryField v
          mArgs = argsField v
          recorded = object
            [ "binary" .= mBin
            , "arg_count" .= (fmap length mArgs :: Maybe Int)
            ]
      case mBin of
        Nothing -> pure (OpResult [TrpText "BIN_EXEC: missing binary"] True recorded)
        Just binText ->
          case mkBinName binText of
            Left err -> pure (OpResult [TrpText ("BIN_EXEC: invalid binary: " <> err)] True recorded)
            Right bin ->
              case traverse mkBinArg (fromMaybe [] mArgs) of
                   Left err -> pure (OpResult [TrpText ("BIN_EXEC: invalid arg: " <> err)] True recorded)
                   Right args -> runBin execBackend bin args recorded
  }

-- | Run the binary with the args through the executor.
runBin :: ExecBackend -> BinName -> [BinArg] -> Value -> App OpResult
runBin execBackend bin args recorded =
  case execBackend of
    EbLocal lh -> do
      res <- liftIO (lehExecBin lh bin args)
      case res of
        Left e   -> pure (OpResult [TrpText (T.pack (show e))] True recorded)
        Right out -> pure (OpResult [TrpText out] False recorded)
    EbRemote _ssh ->
      pure (OpResult [TrpText "BIN_EXEC: remote SSH executor not yet wired (Phase 4 4g)"] True recorded)

binExecSchema :: Value
binExecSchema =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object
        [ "binary" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("The binary name (PATH lookup) or path. Must be in the operator allow-list when one is configured." :: Text)
            ]
        , "args" .= object
            [ "type" .= ("array" :: Text)
            , "items" .= object [ "type" .= ("string" :: Text) ]
            , "description" .= ("Argv tokens passed verbatim to the binary (no shell interpretation)." :: Text)
            ]
        ]
    , "required" .= (["binary"] :: [Text])
    ]

binaryField :: Value -> Maybe Text
binaryField = parseMaybe (withObject "in" (.: "binary"))

-- | Extract the optional @args@ array. Returns 'Nothing' when the field
-- is absent; returns @'Just' []@ when present-but-empty.
argsField :: Value -> Maybe [Text]
argsField = parseMaybe (withObject "in" (.: "args"))