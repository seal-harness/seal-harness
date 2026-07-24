{-# LANGUAGE OverloadedStrings #-}
-- | TEXT_TO_SPEECH (Untrusted): a thin abstraction over a pluggable TTS
-- provider (a real TTS model in a future phase). The default provider is
-- fail-closed (@noTtsProvider@).
module Seal.Media.Tts
  ( textToSpeechOp
  , TtsProvider (..)
  , noTtsProvider
  ) where

import Data.Aeson (Value, object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Core.Types (OpName (..))
import Seal.ISA.Opcode
import Seal.Providers.Class (ToolResultPart (..))

-- | The TTS-provider interface.
data TtsProvider = TtsProvider
  { tpSynthesize :: Text -> IO (Either Text Text)   -- ^ text → audio data (base64 or URL)
  }

-- | The fail-closed default provider.
noTtsProvider :: TtsProvider
noTtsProvider = TtsProvider
  { tpSynthesize = \_ -> pure (Left "TEXT_TO_SPEECH: no TTS provider configured") }

-- | TEXT_TO_SPEECH opcode. Input: @{ text: Text }@.
textToSpeechOp :: TtsProvider -> Opcode
textToSpeechOp _prov = UntrustedOpcode
  { uoName = OpName "TEXT_TO_SPEECH"
  , uoDesc = "Synthesize speech from text (provider-pluggable, fail-closed default)."
  , uoInSchema = ttsSchema
  , uoOutSchema = object []
  , uoAuthorize = \v ->
      case textField v of
        Nothing -> Left "TEXT_TO_SPEECH requires {text:string}"
        Just t | T.null t -> Left "TEXT_TO_SPEECH: text is empty"
               | otherwise -> Right ()
  , uoRun = \_uio v -> do
      let t = fromMaybe "" (textField v)
          recorded = object [ "text" .= t ]
      pure (OpResult [TrpText "TEXT_TO_SPEECH: no TTS provider configured"] True recorded)
  }

ttsSchema :: Value
ttsSchema =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object
        [ "text" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("The text to synthesize." :: Text)
            ]
        ]
    , "required" .= (["text"] :: [Text])
    ]

textField :: Value -> Maybe Text
textField = parseMaybe (withObject "in" (.: "text"))