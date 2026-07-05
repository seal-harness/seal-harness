{-# LANGUAGE OverloadedStrings #-}
-- | Human-interaction opcodes (Trusted): SHOW_HUMAN emits a line to the user;
-- ASK_HUMAN prompts and returns the reply. Both go through the channel handle —
-- no shell, no provider.
module Seal.ISA.Ops.Human
  ( showHumanOp
  , askHumanOp
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..), object, withObject, (.:), (.=))
import Data.Aeson.Key (Key, fromText)
import Data.Aeson.Types (parseMaybe)
import Data.Maybe (fromMaybe)
import Data.Text (Text)

import Seal.Channel.Caps
import Seal.Core.Types
import Seal.ISA.Opcode
import Seal.Providers.Class

-- | Extract a Text value from a JSON object by key.
-- Uses 'Key' (aeson 2.x) so string literals work directly via OverloadedStrings.
strField :: Key -> Value -> Maybe Text
strField k = parseMaybe (withObject "in" (.: k))

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

-- | SHOW_HUMAN: emit @message@ to the human via the channel.
-- Returns an empty, non-error result; the channel itself is the side-effect.
showHumanOp :: ChannelCaps -> Opcode
showHumanOp caps = Opcode
  { opName = OpName "SHOW_HUMAN"
  , opTrust = Trusted
  , opDesc = "Display a message to the human operator."
  , opInSchema = singleStringSchema "message" "The message to display to the human operator."
  , opOutSchema = object []
  , opAuthorize =
      maybe (Left "SHOW_HUMAN requires {message:string}") (const (Right ())) . strField "message"
  , opRun = \_ v -> do
      let msg = fromMaybe "" (strField "message" v)
      liftIO (ccSend caps msg)
      pure (OpResult [] False Null)
  }

-- | ASK_HUMAN: send @question@ to the human and return their typed reply.
askHumanOp :: ChannelCaps -> Opcode
askHumanOp caps = Opcode
  { opName = OpName "ASK_HUMAN"
  , opTrust = Trusted
  , opDesc = "Ask the human operator a question and return their reply."
  , opInSchema = singleStringSchema "question" "The question to present to the human operator."
  , opOutSchema = object []
  , opAuthorize =
      maybe (Left "ASK_HUMAN requires {question:string}") (const (Right ())) . strField "question"
  , opRun = \_ v -> do
      let q = fromMaybe "" (strField "question" v)
      ans <- liftIO (ccPrompt caps q)
      pure (OpResult [TrpText ans] False Null)
  }
