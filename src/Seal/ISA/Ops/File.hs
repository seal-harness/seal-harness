{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications  #-}
-- | FILE_READ (Untrusted): read a workspace file, confined by SafePath.
-- This is the opcode that exercises the ACK-before-execute path in the
-- dispatcher.
module Seal.ISA.Ops.File
  ( fileReadOp
  ) where

import Control.Exception (try)
import Data.Aeson (Value, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Key (fromText)
import Data.Aeson.Types (parseMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Core.Paging (defaultPageParams)
import Seal.Core.Types
import Seal.ISA.Opcode
import Seal.Providers.Class
import Seal.Security.Path
import Seal.Text.LineFile

-- | Local schema for FILE_READ: required @path@ plus optional integer @offset@,
-- @limit@, and @max_scan_bytes@. (A shared single-string schema helper cannot
-- express optional fields, so a small local builder is preferred over
-- prematurely sharing one here.)
fileReadSchema :: Value
fileReadSchema =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object
        [ fromText "path" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("Workspace-relative path of the file to read." :: Text)
            ]
        , fromText "offset" .= object
            [ "type" .= ("integer" :: Text)
            , "description" .=
                ("0-based line index; the line displayed as N is offset N-1. \
                 \Defaults to 0. Out-of-range or malformed values fall back to 0." :: Text)
            ]
        , fromText "limit" .= object
            [ "type" .= ("integer" :: Text)
            , "description" .=
                ("Maximum number of lines to return (clamped to the pager ceiling). \
                 \Defaults to a pager-computed window size. Out-of-range or malformed \
                 \values fall back to the default." :: Text)
            ]
        , fromText "max_scan_bytes" .= object
            [ "type" .= ("integer" :: Text)
            , "description" .=
                ("Per-call ceiling on the number of bytes scanned from the file, \
                 \clamped to the operator-configured upper bound. Defaults to that \
                 \operator bound. Out-of-range or malformed values fall back to the \
                 \default; values above the operator bound are silently clamped down. \
                 \A smaller value narrows the scan window but never widens the memory \
                 \bound." :: Text)
            ]
        ]
    , "required" .= (["path"] :: [Text])
    ]

-- | Extract the @path@ string field from a JSON object.
pathField :: Value -> Maybe Text
pathField = parseMaybe (withObject "in" (.: "path"))

-- | Leniently parse the optional @offset@ integer field. Missing, malformed,
-- or negative values fall back to the default (0); the pager's clamp is the
-- second line of defense.
offsetField :: Value -> Int
offsetField v =
  case parseMaybe (withObject "in" (.:? "offset")) v :: Maybe (Maybe Int) of
    Just (Just n) | n >= 0 -> n
    _                      -> 0

-- | Leniently parse the optional @limit@ integer field. Missing, malformed, or
-- negative values fall back to the pager-computed default; the pager's clamp is
-- the second line of defense.
limitField :: Value -> Maybe Int
limitField v =
  case parseMaybe (withObject "in" (.:? "limit")) v :: Maybe (Maybe Int) of
    Just (Just n) | n >= 0 -> Just n
    _                      -> Nothing

-- | Leniently parse the optional @max_scan_bytes@ integer field. Missing,
-- malformed, or negative values fall back to the operator-configured ceiling;
-- the clamp in 'opRun' is the second line of defense. Returns 'Nothing' when
-- the model did not supply a usable value.
scanBytesField :: Value -> Maybe Int
scanBytesField v =
  case parseMaybe (withObject "in" (.:? "max_scan_bytes")) v :: Maybe (Maybe Int) of
    Just (Just n) | n >= 1 -> Just n
    _                      -> Nothing

-- | FILE_READ opcode: reads a UTF-8 text file at a workspace-relative path,
-- confined by 'mkSafePath', returning a bounded window of lines. Trust level
-- is 'Untrusted'; all IO is funnelled through the 'BackendExec' seam.
--
-- The @operatorCeiling@ argument is the operator-configured upper bound on
-- bytes scanned per call (resolved from the @[retrieval]@ config section by
-- the wiring site). The model's per-call @max_scan_bytes@ request is clamped
-- to @[1, operatorCeiling]@ — it can narrow the scan but can never widen the
-- memory bound above what the operator configured.
--
-- 'orRecorded' captures the requested path / offset / limit / resolved
-- max_scan_bytes (secret-free metadata); file contents flow only to 'orParts'
-- (model-visible).
fileReadOp :: WorkspaceRoot -> Int -> Opcode
fileReadOp root operatorCeiling = Opcode
  { opName = OpName "FILE_READ"
  , opTrust = Untrusted
  , opDesc = "Read a UTF-8 text file from the workspace (path is workspace-relative)."
  , opInSchema = fileReadSchema
  , opOutSchema = object []
  , opAuthorize =
      maybe (Left "FILE_READ requires {path:string}") (const (Right ())) . pathField
  , opRun = \backend v -> do
      let rel       = maybe "" T.unpack (pathField v)
          offset    = offsetField v
          mLimit    = limitField v
          scanBytes = clampScanBytes operatorCeiling (scanBytesField v)
      mSafe <- runLocal backend (mkSafePath root rel)
      -- Uniform orRecorded shape in both branches: path + offset + limit +
      -- resolved max_scan_bytes, all non-secret request metadata.
      let recorded = object
            [ "path" .= rel
            , "offset" .= offset
            , "limit" .= mLimit
            , "max_scan_bytes" .= scanBytes
            ]
      case mSafe of
        Left err ->
          pure $ OpResult
            [TrpText (T.pack (show err))]
            True
            recorded
        Right safe -> do
          -- Bounded read via the LineFile seam. Wrapped in try to catch
          -- IOErrors (e.g. file deleted or permissions revoked between
          -- mkSafePath and the read, or the path is a directory). Memory
          -- stays bounded (scanBytes <= operatorCeiling).
          eWin <- runLocal backend $
            try @IOError (readLineWindow defaultPageParams offset mLimit scanBytes safe)
          case eWin of
            Left ioErr ->
              pure $ OpResult
                [TrpText (T.pack (show ioErr))]
                True
                recorded
            Right win ->
              pure $ OpResult
                [TrpText (renderWindow win)]
                False
                recorded
  }

-- | Resolve the per-call scan byte ceiling. The model's request (if any) is
-- clamped to @[1, operatorCeiling]@; missing/malformed requests fall back to
-- the operator ceiling. The operator's configured bound is a hard upper
-- bound — the model can only narrow the scan, never widen it.
clampScanBytes :: Int -> Maybe Int -> Int
clampScanBytes operatorCeiling mReq =
  case mReq of
    Nothing  -> operatorCeiling
    Just req -> max 1 (min operatorCeiling req)