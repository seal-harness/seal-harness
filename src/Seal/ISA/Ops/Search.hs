{-# LANGUAGE OverloadedStrings #-}
-- | SEARCH_FILES (Untrusted): search workspace files for a pattern. Runs
-- @rg -n -- <pattern> <path>@ via the 'UntrustedIO' capability (fixed
-- argv, no shell interpreter — the validated 'SearchPattern' newtype
-- guards against option injection). 'SafePath'-confined. Bounded result
-- count (operator-configured ceiling; the model can narrow via
-- @max_results@). This module never imports 'System.Process'.
module Seal.ISA.Ops.Search
  ( searchFilesOp
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Core.Types (OpName (..))
import Seal.ISA.Opcode
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.Security.Policy (SecurityPolicy (..), AutonomyLevel (..))
import Seal.Tools.Args (mkSearchPattern)
import Seal.Tools.Exec.UntrustedIO (renderUntrustedErr, uioSearchFiles)
import Seal.Tools.Exec.Types (mkRemotePath)

-- | SEARCH_FILES opcode. Input: @{ pattern: Text, path?: Text, max_results?:
-- Int }@. The pattern must not start with @-@ (option injection). The
-- @path@ defaults to @.@ (the workspace root). The result count is bounded
-- by the operator-configured @maxResults@ ceiling; the model's
-- @max_results@ request can only narrow it.
searchFilesOp :: WorkspaceRoot -> SecurityPolicy -> Int -> Opcode
searchFilesOp _wsRoot policy maxResults = UntrustedOpcode
  { uoName = OpName "SEARCH_FILES"
  , uoDesc = "Search workspace files for a pattern (rg, SafePath-confined, bounded)."
  , uoInSchema = searchFilesSchema
  , uoOutSchema = object []
  , uoAuthorize = \v ->
      case patternField v of
        Nothing -> Left "SEARCH_FILES requires {pattern:string}"
        Just p
          | T.null p -> Left "SEARCH_FILES: pattern is empty"
          | T.head p == '-' -> Left "SEARCH_FILES: pattern must not start with '-' (option injection)"
          | otherwise -> case spAutonomy policy of
              Deny -> Left "SEARCH_FILES denied by autonomy policy"
              _   -> Right ()
  , uoRun = \uio v -> do
      let pat    = fromMaybe "" (patternField v)
          pth    = fromMaybe "." (pathField v)
          limit  = clampResults maxResults (resultsField v)
      case mkSearchPattern pat of
        Left err -> pure (OpResult [TrpText ("SEARCH_FILES: " <> err)] True
                           (object ["pattern" .= pat, "path" .= pth]))
        Right pat' -> do
          let mPath = case mkRemotePath pth of
                Right rp -> Just rp
                Left _   -> Nothing
          res <- liftIO (uioSearchFiles uio pat' mPath limit)
          case res of
            Left err -> pure (OpResult [TrpText (renderUntrustedErr err)] True
                              (object ["pattern" .= pat, "path" .= pth]))
            Right out -> do
              let ls = take limit (T.lines out)
                  count = length ls
              pure (OpResult [TrpText (T.intercalate "\n" ls)] False
                     (object ["pattern" .= pat, "path" .= pth, "result_count" .= count]))
  }

searchFilesSchema :: Value
searchFilesSchema =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object
        [ "pattern" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("The search pattern (must not start with '-')." :: Text)
            ]
        , "path" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("Optional workspace-relative path (defaults to '.')." :: Text)
            ]
        , "max_results" .= object
            [ "type" .= ("integer" :: Text)
            , "description" .= ("Max results to return (clamped to the operator ceiling)." :: Text)
            ]
        ]
    , "required" .= (["pattern"] :: [Text])
    ]

patternField :: Value -> Maybe Text
patternField = parseMaybe (withObject "in" (.: "pattern"))

pathField :: Value -> Maybe Text
pathField v = case parseMaybe (withObject "in" (.:? "path")) v :: Maybe (Maybe Text) of
  Just (Just t) -> Just t
  _             -> Nothing

resultsField :: Value -> Maybe Int
resultsField v = case parseMaybe (withObject "in" (.:? "max_results")) v :: Maybe (Maybe Int) of
  Just (Just n) | n >= 0 -> Just n
  _                      -> Nothing

clampResults :: Int -> Maybe Int -> Int
clampResults ceiling' mReq =
  case mReq of
    Nothing  -> ceiling'
    Just req -> max 1 (min ceiling' req)