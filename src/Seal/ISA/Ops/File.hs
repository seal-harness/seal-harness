{-# LANGUAGE OverloadedStrings #-}
-- | FILE_READ (Untrusted): read a workspace file, confined by SafePath.
-- FILE_WRITE (Untrusted): write/append a workspace file, confined by
-- SafePath, bounded by the operator-configured max write size.
-- This is the opcode module that exercises the ACK-before-execute path in
-- the dispatcher. All side-effecting IO is funnelled through the
-- 'UntrustedIO' capability handle; this module never imports
-- 'System.Process', 'System.Directory', or 'System.Posix'.
module Seal.ISA.Ops.File
  ( fileReadOp
  , fileWriteOp
  , filePatchOp
  ) where

import Control.Applicative ((<|>))
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Key (fromText)
import Data.Aeson.Types (parseMaybe)
import Data.ByteString qualified as BS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import Seal.Core.Paging (defaultPageParams)
import Seal.Core.Types
import Seal.ISA.Opcode
import Seal.Providers.Class
import Seal.Security.Path
import Seal.Text.LineFile (lwLines, lwTotal, lwTruncated, lwEnd, lwHasMore, renderWindow, windowLines)
import Seal.Tools.Exec.UntrustedIO
import Seal.Tools.Exec.Types (mkRemotePath)

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
-- is 'Untrusted'; all IO is funnelled through the 'UntrustedIO' capability
-- handle.
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
fileReadOp _root operatorCeiling = UntrustedOpcode
  { uoName = OpName "FILE_READ"
  , uoDesc = "Read a UTF-8 text file from the workspace (path is workspace-relative)."
  , uoInSchema = fileReadSchema
  , uoOutSchema = object []
  , uoAuthorize =
      maybe (Left "FILE_READ requires {path:string}") (const (Right ())) . pathField
  , uoRun = \uio v -> do
      let rel       = maybe "" T.unpack (pathField v)
          offset    = offsetField v
          mLimit    = limitField v
          scanBytes = clampScanBytes operatorCeiling (scanBytesField v)
      let recorded = object
            [ "path" .= rel
            , "offset" .= offset
            , "limit" .= mLimit
            , "max_scan_bytes" .= scanBytes
            ]
      case mkRemotePath (T.pack rel) of
        Left _ ->
          -- An empty/invalid path: surface as an error (the authorize gate
          -- already rejects a missing path, but a malformed one falls here).
          pure $ OpResult
            [TrpText "FILE_READ: invalid path"]
            True
            recorded
        Right rp -> do
          res <- liftIO (uioReadFile uio rp scanBytes)
          case res of
            Left err ->
              pure $ OpResult
                [TrpText (renderUntrustedErr err)]
                True
                recorded
            Right fullWin -> do
              -- Apply the offset/limit windowing purely (the capability
              -- returned a dynamic-page-sized window; the opcode re-windows
              -- to the requested offset/limit). Preserve the total + truncated
              -- flags from the capability's bounded read (so the footer
              -- reflects the true file size + byte ceiling).
              let win = windowLines defaultPageParams offset mLimit (lwLines fullWin)
                  win' = win { lwTotal     = lwTotal fullWin
                             , lwHasMore   = lwEnd win < lwTotal fullWin
                                          || lwTruncated fullWin
                             , lwTruncated = lwTruncated fullWin
                             }
              pure $ OpResult
                [TrpText (renderWindow win')]
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

-- ---------------------------------------------------------------------------
-- FILE_WRITE
-- ---------------------------------------------------------------------------

-- | FILE_WRITE opcode: write or append content to a workspace-relative file,
-- confined by 'mkSafePath'. The @operatorWriteCeiling@ is the hard upper
-- bound on bytes written per call; content exceeding it is rejected
-- (bounded write, mirrors FILE_READ's @max_scan_bytes@ clamp). The
-- @mode@ field is @\"write\"@ (default, truncate + create) or @\"append\"@.
-- 'orRecorded' captures the path + mode + byte count (NOT the content —
-- content may be large; the transcript records metadata only).
fileWriteOp :: WorkspaceRoot -> Int -> Opcode
fileWriteOp _root operatorWriteCeiling = UntrustedOpcode
  { uoName = OpName "FILE_WRITE"
  , uoDesc = "Write or append to a workspace file (path is workspace-relative, bounded)."
  , uoInSchema = fileWriteSchema
  , uoOutSchema = object []
  , uoAuthorize =
      maybe (Left "FILE_WRITE requires {path:string, content:string}") (const (Right ()))
        . pathField
  , uoRun = \uio v -> do
      let rel     = maybe "" T.unpack (pathField v)
          content = fromMaybe "" (contentField v)
          mode    = case modeField v of
            Just m | m == "append" -> WMAppend
            _                     -> WMWrite
          byteCount = BS.length (TE.encodeUtf8 content)  -- capability re-measures; this is the recorded estimate
          recorded = object
            [ "path" .= rel
            , "mode" .= (case mode of WMAppend -> ("append" :: Text); WMWrite -> "write")
            , "bytes" .= byteCount
            ]
      if byteCount > operatorWriteCeiling
        then pure $ OpResult
          [TrpText ("FILE_WRITE: content (" <> T.pack (show byteCount) <> " bytes) exceeds operator ceiling ("
                    <> T.pack (show operatorWriteCeiling) <> " bytes)")]
          True
          recorded
        else case mkRemotePath (T.pack rel) of
          Left _ ->
            pure $ OpResult
              [TrpText "FILE_WRITE: invalid path"]
              True
              recorded
          Right rp -> do
            res <- liftIO (uioWriteFile uio rp content mode operatorWriteCeiling)
            pure $ case res of
              Left err ->
                OpResult
                  [TrpText (renderUntrustedErr err)]
                  True
                  recorded
              Right n ->
                OpResult
                  [TrpText ("wrote " <> T.pack (show n) <> " bytes to " <> T.pack rel)]
                  False
                  recorded
  }

fileWriteSchema :: Value
fileWriteSchema =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object
        [ fromText "path" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("Workspace-relative path of the file to write." :: Text)
            ]
        , fromText "content" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("The content to write (bounded by the operator ceiling)." :: Text)
            ]
        , fromText "mode" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("\"write\" (default, truncate+create) or \"append\"." :: Text)
            ]
        ]
    , "required" .= (["path", "content"] :: [Text])
    ]

contentField :: Value -> Maybe Text
contentField = parseMaybe (withObject "in" (.: "content"))

modeField :: Value -> Maybe Text
modeField v = case parseMaybe (withObject "in" (.:? "mode")) v :: Maybe (Maybe Text) of
  Just (Just m) -> Just m
  _             -> Nothing

-- ---------------------------------------------------------------------------
-- FILE_PATCH
-- ---------------------------------------------------------------------------

-- | FILE_PATCH opcode: apply a unified diff to a workspace-relative file,
-- confined by 'SafePath'. The patch is applied via a pure Haskell diff-
-- apply (no subprocess — the patch is parsed and applied in-process; an
-- atomic temp+rename write lands the result). 'orRecorded' captures the
-- path + patch line count + applied flag (NOT the patch body — it may be
-- large; the transcript records metadata only).
filePatchOp :: WorkspaceRoot -> Opcode
filePatchOp _root = UntrustedOpcode
  { uoName = OpName "FILE_PATCH"
  , uoDesc = "Apply a unified diff to a workspace file (SafePath-confined, atomic write). \
             \Input fields are {path: string, patch: string} — the patch field is named \
             \'patch' (not 'diff'). The patch is a standard unified diff as @git diff@ \
             \would emit; both the long hunk header form (@@@ -1,2 +1,2 @@@) and the \
             \short form (@@@ -1 +1 @@@, length 1 implied) are accepted. No shell is \
             \invoked — the diff is parsed and applied in-process."
  , uoInSchema = filePatchSchema
  , uoOutSchema = object []
  , uoAuthorize = \v ->
      case (pathField v, patchField v) of
        (Nothing, _)      -> Left "FILE_PATCH requires {path:string, patch:string}"
        (_, Nothing)      -> Left "FILE_PATCH requires {path:string, patch:string}"
        (_, Just p)
          | T.null p      -> Left "FILE_PATCH requires a non-empty patch"
          | otherwise     -> Right ()
  , uoRun = \uio v -> do
      let rel   = maybe "" T.unpack (pathField v)
          patch = fromMaybe "" (patchField v)
          recorded = object [ "path" .= rel, "patch_lines" .= length (T.lines patch) ]
      case mkRemotePath (T.pack rel) of
        Left _ -> pure $ OpResult [TrpText "FILE_PATCH: invalid path"] True recorded
        Right rp -> do
          -- Defense-in-depth: a non-empty patch must reach the applier. The
          -- authorize gate already rejects an empty/missing 'patch', but if
          -- the opcode is ever invoked with the gate bypassed, refuse to
          -- silently no-op here rather than rewrite the file with its own
          -- contents and report success.
          if T.null patch
            then pure $ OpResult
                   [TrpText "FILE_PATCH requires a non-empty patch"] True recorded
            else do
              res <- liftIO (uioPatchFile uio rp patch)
              pure $ case res of
                Left err ->
                  OpResult [TrpText ("FILE_PATCH: " <> renderUntrustedErr err)] True recorded
                Right _  ->
                  OpResult [TrpText ("patched " <> T.pack rel)] False recorded
  }

filePatchSchema :: Value
filePatchSchema =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object
        [ fromText "path" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("Workspace-relative path of the file to patch." :: Text)
            ]
        , fromText "patch" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("The unified diff to apply, named 'patch' (NOT 'diff'). \
                                \Standard @git diff@ output; both @@ -1,2 +1,2 @@ and \
                                \@@ -1 +1 @@ hunk headers are accepted. Applied in-process, no shell." :: Text)
            ]
        ]
    , "required" .= (["path", "patch"] :: [Text])
    ]

patchField :: Value -> Maybe Text
-- | Accept the canonical 'patch' field, falling back to 'diff' (a name the
-- model frequently guesses first). Both map to the same unified-diff payload;
-- preferring 'patch' preserves the schema contract, while the 'diff' alias
-- avoids a round-trip through OPCODE_DESCRIBE just to learn the field name.
patchField v = parseMaybe (withObject "in" (.: "patch")) v
           <|> parseMaybe (withObject "in" (.: "diff")) v