{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications  #-}
-- | FILE_READ (Untrusted): read a workspace file, confined by SafePath.
-- This is the opcode that exercises the ACK-before-execute path in the
-- dispatcher.
module Seal.ISA.Ops.File
  ( fileReadOp
  ) where

import Control.Exception (try)
import Data.Aeson (Value, object, withObject, (.:), (.=))
import Data.Aeson.Key (fromText)
import Data.Aeson.Types (parseMaybe)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.IO (IOMode (ReadMode), withFile)

import Seal.Core.Types
import Seal.ISA.Opcode
import Seal.Providers.Class
import Seal.Security.Path

-- | Maximum bytes to read from a workspace file in a single FILE_READ call.
-- Proper paging is a Phase-3 Dynamic-Retrieval follow-up.
maxReadBytes :: Int
maxReadBytes = 65536

-- | Build a JSON-Schema object with a single required string property.
singleStringSchema :: Text -> Text -> Value
singleStringSchema fieldName fieldDesc =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object
        [fromText fieldName .= object
           [ "type" .= ("string" :: Text)
           , "description" .= fieldDesc
           ]]
    , "required" .= ([fieldName] :: [Text])
    ]

-- | Extract the @path@ string field from a JSON object.
pathField :: Value -> Maybe Text
pathField = parseMaybe (withObject "in" (.: "path"))

-- | FILE_READ opcode: reads a UTF-8 text file at a workspace-relative path,
-- confined by 'mkSafePath'. Trust level is 'Untrusted'; all IO is funnelled
-- through the 'BackendExec' seam.
--
-- 'orRecorded' captures the requested path (secret-free metadata); file
-- contents flow only to 'orParts' (model-visible).
fileReadOp :: WorkspaceRoot -> Opcode
fileReadOp root = Opcode
  { opName = OpName "FILE_READ"
  , opTrust = Untrusted
  , opDesc = "Read a UTF-8 text file from the workspace (path is workspace-relative)."
  , opInSchema = singleStringSchema "path" "Workspace-relative path of the file to read."
  , opOutSchema = object []
  , opAuthorize =
      maybe (Left "FILE_READ requires {path:string}") (const (Right ())) . pathField
  , opRun = \backend v -> do
      let rel = maybe "" T.unpack (pathField v)
      mSafe <- runLocal backend (mkSafePath root rel)
      case mSafe of
        Left err ->
          pure $ OpResult
            [TrpText (T.pack (show err))]
            True
            (object ["path" .= rel])
        Right safe -> do
          -- Read at most 64 KiB; avoids unbounded memory use on large files.
          -- Phase-3 Dynamic-Retrieval will implement proper paging.
          -- Wrap in try to catch IOErrors (e.g. file deleted or permissions
          -- revoked between mkSafePath and withFile, or path is a directory).
          eResult <- runLocal backend $
            try @IOError $
              withFile (getSafePath safe) ReadMode $ \h -> do
                bytes <- BS.hGet h maxReadBytes
                pure (TE.decodeUtf8Lenient bytes)
          case eResult of
            Left ioErr ->
              pure $ OpResult
                [TrpText (T.pack (show ioErr))]
                True
                (object ["path" .= rel])
            Right txt ->
              pure $ OpResult
                [TrpText txt]
                False
                (object ["path" .= rel])
  }
