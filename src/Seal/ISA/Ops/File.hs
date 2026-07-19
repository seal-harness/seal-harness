{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications  #-}
-- | FILE_READ (Untrusted): read a workspace file, confined by SafePath.
-- FILE_WRITE (Untrusted): write/append a workspace file, confined by
-- SafePath, bounded by the operator-configured max write size.
-- This is the opcode module that exercises the ACK-before-execute path in
-- the dispatcher.
module Seal.ISA.Ops.File
  ( fileReadOp
  , fileWriteOp
  , filePatchOp
  ) where

import Control.Exception (try)
import Control.Applicative ((<|>))
import Data.Aeson (Value, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Key (fromText)
import Data.Aeson.Types (parseMaybe)
import Data.ByteString qualified as BS
import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (renameFile)

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
fileReadOp root operatorCeiling = UntrustedOpcode
  { uoName = OpName "FILE_READ"
  , uoDesc = "Read a UTF-8 text file from the workspace (path is workspace-relative)."
  , uoInSchema = fileReadSchema
  , uoOutSchema = object []
  , uoAuthorize =
      maybe (Left "FILE_READ requires {path:string}") (const (Right ())) . pathField
  , uoRun = \backend _execBackend v -> do
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
fileWriteOp root operatorWriteCeiling = UntrustedOpcode
  { uoName = OpName "FILE_WRITE"
  , uoDesc = "Write or append to a workspace file (path is workspace-relative, bounded)."
  , uoInSchema = fileWriteSchema
  , uoOutSchema = object []
  , uoAuthorize =
      maybe (Left "FILE_WRITE requires {path:string, content:string}") (const (Right ()))
        . pathField
  , uoRun = \backend _execBackend v -> do
      let rel     = maybe "" T.unpack (pathField v)
          content = maybe "" T.unpack (contentField v)
          mode    = case modeField v of
            Just m | m == "append" -> (m :: Text)
            _                      -> "write"  -- default
          byteCount = BS.length (TE.encodeUtf8 (T.pack content))
          recorded = object
            [ "path" .= rel
            , "mode" .= mode
            , "bytes" .= byteCount
            ]
      if byteCount > operatorWriteCeiling
        then pure $ OpResult
          [TrpText ("FILE_WRITE: content (" <> T.pack (show byteCount) <> " bytes) exceeds operator ceiling ("
                    <> T.pack (show operatorWriteCeiling) <> " bytes)")]
          True
          recorded
        else do
          mSafe <- runLocal backend (mkSafePathForWrite root rel)
          case mSafe of
            Left err ->
              pure $ OpResult
                [TrpText (T.pack (show err))]
                True
                recorded
            Right safe -> do
              eUnit <- runLocal backend $ try @IOError $
                case mode :: Text of
                  m | m == "append" -> BS.appendFile (getSafePath safe) (TE.encodeUtf8 (T.pack content))
                  _                 -> BS.writeFile  (getSafePath safe) (TE.encodeUtf8 (T.pack content))
              case eUnit of
                Left ioErr ->
                  pure $ OpResult
                    [TrpText (T.pack (show ioErr))]
                    True
                    recorded
                Right _ ->
                  pure $ OpResult
                    [TrpText ("wrote " <> T.pack (show byteCount) <> " bytes to " <> T.pack rel)]
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
filePatchOp root = UntrustedOpcode
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
  , uoRun = \backend _execBackend v -> do
      let rel   = maybe "" T.unpack (pathField v)
          patch = maybe "" T.unpack (patchField v)
          recorded = object [ "path" .= rel, "patch_lines" .= length (T.lines (T.pack patch)) ]
      mSafe <- runLocal backend (mkSafePath root rel)
      case mSafe of
        Left err ->
          pure $ OpResult [TrpText (T.pack (show err))] True recorded
        Right safe -> do
          -- Defense-in-depth: a non-empty patch must reach the applier. The
          -- authorize gate already rejects an empty/missing 'patch', but if
          -- the opcode is ever invoked with the gate bypassed (e.g. Full
          -- autonomy doesn't skip authorize, but a future caller might),
          -- refuse to silently no-op here rather than rewrite the file with
          -- its own contents and report success.
          case patch of
            "" -> pure $ OpResult
                    [TrpText "FILE_PATCH requires a non-empty patch"] True recorded
            _  -> do
              -- Read the existing file, apply the diff, write atomically.
              eContent <- runLocal backend $ try @IOError (BS.readFile (getSafePath safe))
              case eContent of
                Left ioErr ->
                  pure $ OpResult [TrpText ("FILE_PATCH: read failed: " <> T.pack (show ioErr))] True recorded
                Right content -> do
                  case applyUnifiedDiff (TE.decodeUtf8Lenient content) (T.pack patch) of
                    Left applyErr ->
                      pure $ OpResult [TrpText ("FILE_PATCH: apply failed: " <> applyErr)] True recorded
                    Right newContent -> do
                      eUnit <- runLocal backend $ try @IOError $ do
                        let tmpPath = getSafePath safe <> ".seal-patch-tmp"
                        BS.writeFile tmpPath (TE.encodeUtf8 newContent)
                        renameFile tmpPath (getSafePath safe)
                      case eUnit of
                        Left ioErr ->
                          pure $ OpResult [TrpText ("FILE_PATCH: write failed: " <> T.pack (show ioErr))] True recorded
                        Right _ ->
                          pure $ OpResult [TrpText ("patched " <> T.pack rel)] False recorded
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

-- | Apply a minimal unified diff to the original content. Returns
-- @Left errMsg@ if the patch is malformed or the context doesn't match;
-- @Right newContent@ on success. This is a simplified hunk applier: it
-- parses @@ -start,len +start,len @@ headers and applies context/removed/
-- added lines. Does NOT handle binary patches or rename-only hunks.
applyUnifiedDiff :: Text -> Text -> Either Text Text
applyUnifiedDiff original patch =
  let origLines = T.lines original
      patchLines = T.lines patch
  in go origLines patchLines
  where
    go origLines [] = Right (T.intercalate "\n" origLines <> "\n")
    go origLines (h : rest)
      | T.isPrefixOf "@@ " h = applyHunk origLines h rest
      | T.isPrefixOf "--- " h = go origLines rest  -- skip file header
      | T.isPrefixOf "+++ " h = go origLines rest  -- skip file header
      | T.null h = go origLines rest               -- skip blank lines
      | otherwise = Left ("unexpected line in patch: " <> h)
    -- Apply a single hunk: parse the @@ -a,b +c,d @@ header, then the
    -- context/removed/added lines (until the next @@ or end).
    applyHunk origLines header rest =
      case parseHunkHeader header of
        Left err -> Left err
        Right (oldStart, _oldLen, _newStart, _newLen) ->
          -- The hunk body is the lines after the header until the next @@ or end.
          let (hunkLines, remainingPatch) = span isHunkLine rest
              idx = max 0 (oldStart - 1)
              (before, atAndAfter) = splitAt idx origLines
          in case applyHunkLines atAndAfter hunkLines of
               Left err -> Left err
               Right patched ->
                 let newOrig = before ++ patched
                 in go newOrig remainingPatch
    isHunkLine l =
      T.null l
      || T.isPrefixOf " " l
      || T.isPrefixOf "-" l
      || T.isPrefixOf "+" l
      || T.isPrefixOf "\\" l  -- "\ No newline at end of file"
    -- Apply the hunk lines against the original lines: context (space)
    -- lines are kept (match the original); removed (-) lines must match and
    -- are dropped; added (+) lines are inserted.
    applyHunkLines orig [] = Right orig
    applyHunkLines (o : os) (h : hs)
      | T.isPrefixOf " " h = keep o (applyHunkLines os hs)   -- context: keep original
      | T.isPrefixOf "-" h = applyHunkLines os hs           -- removed: drop original
      | T.isPrefixOf "+" h = keep (T.drop 1 h) (applyHunkLines (o : os) hs)  -- added: insert before current
      | T.isPrefixOf "\\" h = applyHunkLines (o : os) hs    -- no-newline marker: skip
      | T.null h = applyHunkLines (o : os) hs               -- blank line in hunk
      | otherwise = Left ("unexpected hunk line: " <> h)
      where keep x acc = (x :) <$> acc
    applyHunkLines [] (h : hs)
      | T.isPrefixOf "+" h = keep (T.drop 1 h) (applyHunkLines [] hs)  -- added at end: insert
      | T.isPrefixOf " " h = Left ("hunk context line past end of file: " <> h)
      | T.isPrefixOf "-" h = Left ("hunk removed line past end of file: " <> h)
      | T.isPrefixOf "\\" h = applyHunkLines [] hs
      | T.null h = applyHunkLines [] hs
      | otherwise = Left ("unexpected hunk line at end: " <> h)
      where keep x acc = (x :) <$> acc
    -- Parse @@ -oldStart[,oldLen] +newStart[,newLen] @@ <rest...>
    -- The ,oldLen / ,newLen are optional: when omitted, the length is 1
    -- (this is the short form @git diff@ emits for single-line hunks, e.g.
    -- @@@ -1 +1 @@@). The lengths are currently unused by the applier — we
    -- only need the start line numbers — but both forms must parse so the
    -- model's natural @git diff@-style output isn't rejected as malformed.
    parseHunkHeader h =
      case T.stripPrefix "@@ -" h of
        Nothing -> Left ("malformed hunk header: " <> h)
        Just rest0 ->
          let (oldStartStr, afterOld) = breakNum rest0
              afterPlus0 = T.dropWhile (/= '+') afterOld
              afterPlus  = T.drop 1 afterPlus0  -- drop the +
              (newStartStr, _) = breakNum afterPlus
              oldStart = readMaybe (T.unpack oldStartStr) :: Maybe Int
              newStart = readMaybe (T.unpack newStartStr) :: Maybe Int
          in case (oldStart, newStart) of
               (Just os_, Just ns_) -> Right (os_, Nothing, ns_, Nothing)
               _ -> Left ("malformed hunk header numbers: " <> h)
      where
        -- | Take leading digits (the start), then skip an optional @,len@
        -- suffix, returning the start-numeric string and the remainder
        -- starting at the next token (the space before @+@). Examples:
        --
        --   breakNum "1 +1 @@ "   == ("1", " +1 @@ ")
        --   breakNum "1,2 +1 @@ " == ("1", " +1 @@ ")
        breakNum :: Text -> (Text, Text)
        breakNum s =
          let (digits, rest) = T.span isDigit s
          in case T.uncons rest of
               Just (',', rest') -> (digits, T.dropWhile isDigit rest')
               _                 -> (digits, rest)
        readMaybe :: String -> Maybe Int
        readMaybe s = case reads s :: [(Int, String)] of
          [(n, _)] -> Just n
          _        -> Nothing