{-# LANGUAGE OverloadedStrings #-}
-- | IMAGE_* opcodes (Untrusted): a thin abstraction over a pluggable image
-- provider (a real image-generation model in a future phase). The default
-- provider is fail-closed (@noImageProvider@).
module Seal.Media.Image
  ( imageGenerateOp
  , imageDescribeOp
  , ImageProvider (..)
  , noImageProvider
  ) where

import Data.Aeson (Value, object, withObject, (.:), (.=))
import Data.Aeson.Key (fromText)
import Data.Aeson.Types (parseMaybe)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Core.Types (OpName (..))
import Seal.ISA.Opcode
import Seal.Providers.Class (ToolResultPart (..))

-- | The image-provider interface.
data ImageProvider = ImageProvider
  { ipGenerate :: Text -> IO (Either Text Text)   -- ^ prompt → image data (base64 or URL)
  , ipDescribe :: Text -> IO (Either Text Text)   -- ^ image ref → description
  }

-- | The fail-closed default provider.
noImageProvider :: ImageProvider
noImageProvider = ImageProvider
  { ipGenerate = \_ -> pure (Left "IMAGE_GENERATE: no image provider configured")
  , ipDescribe = \_ -> pure (Left "IMAGE_DESCRIBE: no image provider configured")
  }

-- | IMAGE_GENERATE opcode. Input: @{ prompt: Text }@.
imageGenerateOp :: ImageProvider -> Opcode
imageGenerateOp _prov = UntrustedOpcode
  { uoName = OpName "IMAGE_GENERATE"
  , uoDesc = "Generate an image from a prompt (provider-pluggable, fail-closed default)."
  , uoInSchema = imageSchema "prompt" "The image generation prompt."
  , uoOutSchema = object []
  , uoAuthorize = \v ->
      case promptField v of
        Nothing -> Left "IMAGE_GENERATE requires {prompt:string}"
        Just p | T.null p -> Left "IMAGE_GENERATE: prompt is empty"
               | otherwise -> Right ()
  , uoRun = \_back _execBackend v -> do
      let p = fromMaybe "" (promptField v)
          recorded = object [ "prompt" .= p ]
      pure (OpResult [TrpText "IMAGE_GENERATE: no image provider configured"] True recorded)
  }

-- | IMAGE_DESCRIBE opcode. Input: @{ image: Text }@.
imageDescribeOp :: ImageProvider -> Opcode
imageDescribeOp _prov = UntrustedOpcode
  { uoName = OpName "IMAGE_DESCRIBE"
  , uoDesc = "Describe an image (provider-pluggable, fail-closed default)."
  , uoInSchema = imageSchema "image" "The image reference (URL or base64)."
  , uoOutSchema = object []
  , uoAuthorize = \v ->
      case imageField v of
        Nothing -> Left "IMAGE_DESCRIBE requires {image:string}"
        Just i | T.null i -> Left "IMAGE_DESCRIBE: image is empty"
               | otherwise -> Right ()
  , uoRun = \_back _execBackend v -> do
      let i = fromMaybe "" (imageField v)
          recorded = object [ "image" .= i ]
      pure (OpResult [TrpText "IMAGE_DESCRIBE: no image provider configured"] True recorded)
  }

imageSchema :: Text -> Text -> Value
imageSchema fieldName desc =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object
        [ fromText fieldName .= object
            [ "type" .= ("string" :: Text)
            , "description" .= desc
            ]
        ]
    , "required" .= [fieldName]
    ]

promptField :: Value -> Maybe Text
promptField = parseMaybe (withObject "in" (.: "prompt"))

imageField :: Value -> Maybe Text
imageField = parseMaybe (withObject "in" (.: "image"))