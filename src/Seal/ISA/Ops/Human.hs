{-# LANGUAGE OverloadedStrings #-}
-- | Human-interaction opcodes (Trusted): SHOW_HUMAN emits a line to the user;
-- ASK_HUMAN prompts and returns the reply. Both go through the channel handle —
-- no shell, no provider.
module Seal.ISA.Ops.Human
  ( showHumanOp
  , askHumanOp
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..), object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Key (Key, fromText)
import Data.Aeson.Types (parseMaybe)
import Data.Maybe (fromMaybe)
import Data.Text (Text)

import Seal.Channel.Caps
import Seal.Core.Types
import Seal.Handles.AskReply (QuestionOption (..), validateOptions)
import Seal.ISA.Opcode
import Seal.Providers.Class

-- | Extract a Text value from a JSON object by key.
-- Uses 'Key' (aeson 2.x) so string literals work directly via OverloadedStrings.
strField :: Key -> Value -> Maybe Text
strField k = parseMaybe (withObject "in" (.: k))

-- | Parse the optional @options@ array from an ASK_HUMAN input into a list
-- of 'QuestionOption's. 'Nothing' when the field is absent (open-ended);
-- 'Just opts' when present (including 'Just []', which 'validateOptions'
-- rejects).
parseOptions :: Value -> Maybe (Maybe [QuestionOption])
parseOptions = parseMaybe $ withObject "in" $ \o -> do
  mOpts <- o .:? fromText "options"
  case mOpts of
    Nothing -> pure Nothing
    Just arr -> Just <$> traverse parseOption arr
  where
    parseOption = withObject "option" $ \oo ->
      QuestionOption <$> oo .: fromText "label"
                     <*> (fromMaybe "" <$> (oo .:? fromText "description"))

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

-- | The JSON-Schema for ASK_HUMAN's input: a required @question@ string plus
-- an optional @options@ array (max 8 items, each @{label, description}@).
askHumanSchema :: Value
askHumanSchema = object
  [ "type" .= ("object" :: Text)
  , "properties" .= object
      [ fromText "question" .= object
          [ "type" .= ("string" :: Text)
          , "description" .= ("The question to present to the human operator." :: Text)
          ]
      , fromText "options" .= object
          [ "type" .= ("array" :: Text)
          , "description" .= ("Optional discrete choices. When present, channels render one button per choice plus an 'Other' free-text option. When absent, the question is open-ended." :: Text)
          , "maxItems" .= (8 :: Int)
          , "items" .= object
              [ "type" .= ("object" :: Text)
              , "properties" .= object
                  [ fromText "label" .= object
                      [ "type" .= ("string" :: Text)
                      , "description" .= ("The value returned to the agent when picked (1-5 words, concise)." :: Text)
                      ]
                  , fromText "description" .= object
                      [ "type" .= ("string" :: Text)
                      , "description" .= ("One-line explanation of the choice." :: Text)
                      ]
                  ]
              , "required" .= (["label"] :: [Text])
              ]
          ]
      ]
  , "required" .= (["question"] :: [Text])
  ]

-- | SHOW_HUMAN: emit @message@ to the human via the channel.
-- Returns an empty, non-error result; the channel itself is the side-effect.
showHumanOp :: ChannelCaps -> Opcode
showHumanOp caps = TrustedOpcode
  { toName = OpName "SHOW_HUMAN"
  , toTrust = Trusted
  , toDesc = "Display a message to the human operator."
  , toInSchema = singleStringSchema "message" "The message to display to the human operator."
  , toOutSchema = object []
  , toAuthorize =
      maybe (Left "SHOW_HUMAN requires {message:string}") (const (Right ())) . strField "message"
  , toRun = \_ v -> do
      let msg = fromMaybe "" (strField "message" v)
      liftIO (ccSend caps msg)
      pure (OpResult [] False Null)
  }

-- | ASK_HUMAN: send @question@ to the human and return their typed reply.
-- When the optional @options@ array is present, the channel renders one
-- button per choice plus an "Other" free-text option; the human's chosen
-- text (a label or a typed reply) is returned.
askHumanOp :: ChannelCaps -> Opcode
askHumanOp caps = TrustedOpcode
  { toName = OpName "ASK_HUMAN"
  , toTrust = Trusted
  , toDesc = "Ask the human operator a question and return their reply."
  , toInSchema = askHumanSchema
  , toOutSchema = object []
  , toAuthorize = \v ->
      case strField "question" v of
        Nothing -> Left "ASK_HUMAN requires {question:string}"
        Just _ -> case parseOptions v of
          -- Malformed options field (not an array of objects) → reject.
          Nothing -> Left "ASK_HUMAN: invalid 'options' field"
          -- Absent options field (Nothing inner) → open-ended (valid).
          Just Nothing -> Right ()
          -- Present options → validate.
          Just (Just opts) -> case validateOptions opts of
            Left e -> Left ("ASK_HUMAN: " <> e)
            Right _ -> Right ()
  , toRun = \_ v -> do
      let q = fromMaybe "" (strField "question" v)
          opts = case parseOptions v of
            Just (Just os) -> os
            _ -> []
      ans <- liftIO (ccPrompt caps (AskPrompt q opts))
      pure (OpResult [TrpText ans] False Null)
  }
