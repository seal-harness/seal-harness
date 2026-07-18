{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-partial-fields #-}
-- | The provider-agnostic message/content/request/response model and the
-- 'Provider' capability class. Concrete providers (Anthropic, …) implement it;
-- 'SomeProvider' lets config pick one at runtime.
module Seal.Providers.Class
  ( Role (..)
  , ToolResultPart (..)
  , ContentBlock (..)
  , Message (..)
  , textMsg
  , ToolDefinition (..)
  , stubSchema
  , ToolChoice (..)
  , CompletionRequest (..)
  , Usage (..)
  , StopReason (..)
  , CompletionResponse (..)
  , Provider (..)
  , SomeProvider (..)
  ) where

import Data.Aeson
import Data.Aeson.Key (fromString)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import GHC.Generics (Generic)

import Seal.Core.Types (ModelId, OpName, ToolCallId)
import Seal.Util.AesonUtils (stripPrefixToJSON, stripPrefixParseJSON)

data Role = User | Assistant deriving stock (Eq, Show, Generic)
instance ToJSON Role where toJSON = stripPrefixToJSON
instance FromJSON Role where parseJSON = stripPrefixParseJSON

newtype ToolResultPart = TrpText Text deriving stock (Eq, Show, Generic)
instance ToJSON ToolResultPart where toJSON = stripPrefixToJSON
instance FromJSON ToolResultPart where parseJSON = stripPrefixParseJSON

-- | A single block of content in a message.
--
-- __Partial field selectors warning:__ The record fields 'cbId', 'cbName',
-- 'cbInput', 'cbForId', 'cbParts', and 'cbIsError' are only defined on their
-- respective constructors ('CbToolUse' and 'CbToolResult'). They are partial
-- across the full type and will throw a runtime error if applied to the wrong
-- constructor. Always access them inside a constructor-specific pattern match;
-- never use them as bare accessor functions.
--
-- JSON keys (via 'stripPrefixToJSON'): @cbId@→@id@, @cbName@→@name@,
-- @cbInput@→@input@, @cbForId@→@forId@, @cbParts@→@parts@,
-- @cbIsError@→@isError@. The constructor tag (@CbText@/@CbToolUse@/
-- @CbToolResult@) is emitted by aeson's default 'TaggedObject' sum encoding
-- unchanged.
data ContentBlock
  = CbText Text
  | CbToolUse    { cbId :: ToolCallId, cbName :: OpName, cbInput :: Value }
  | CbToolResult { cbForId :: ToolCallId, cbParts :: [ToolResultPart], cbIsError :: Bool }
  deriving stock (Eq, Show, Generic)
instance ToJSON ContentBlock where toJSON = stripPrefixToJSON
instance FromJSON ContentBlock where parseJSON = stripPrefixParseJSON

data Message = Message { msgRole :: Role, msgContent :: [ContentBlock] }
  deriving stock (Eq, Show, Generic)
-- JSON keys: @msgRole@→@role@, @msgContent@→@content@.
instance ToJSON Message where toJSON = stripPrefixToJSON
instance FromJSON Message where parseJSON = stripPrefixParseJSON

textMsg :: Role -> Text -> Message
textMsg r t = Message r [CbText t]

data ToolDefinition = ToolDefinition
  { tdName :: OpName, tdDescription :: Text, tdInputSchema :: Value }
  deriving stock (Eq, Show, Generic)

-- | Custom 'ToJSON': emits @name@ + @description@ always, and
-- @input_schema@ only when it differs from 'stubSchema'. The keys follow the
-- Anthropic wire shape (the @tools@ array is an external-facing payload, so
-- the external convention applies — not the internal strip-prefix camelCase).
-- This keeps the on-disk transcript envelope (@edTools@) and the debug
-- @requests.jsonl@ consistent with the provider encoders (which also use
-- @input_schema@ / @function.parameters@). The stub is omitted entirely so
-- no @input_schema@ token cost leaks in on-demand mode.
instance ToJSON ToolDefinition where
  toJSON (ToolDefinition n d sch) =
    if sch == stubSchema
      then object ["name" .= n, "description" .= d]
      else object ["name" .= n, "description" .= d, "input_schema" .= sch]

-- | Custom 'FromJSON': @name@ + @description@ required; @input_schema@
-- OPTIONAL, defaulting to 'stubSchema' when the key is ABSENT. The 'ToJSON'
-- instance omits @input_schema@ for stub tools, so a required-field reader
-- would reject those rows and — worse — take down the whole 'EnvelopeDelta'
-- parse (aeson's 'parseJSON' is sequential), losing the system prompt from
-- the reconstructed envelope. Key PRESENCE (not value null-ness)
-- distinguishes "stored stub, omitted by ToJSON" from "explicitly null": an
-- absent key defaults to 'stubSchema' (closing the stub round-trip), while a
-- present 'null' stays 'Null' (so the arbitrary-data round-trip property
-- still holds).
instance FromJSON ToolDefinition where
  parseJSON = withObject "ToolDefinition" $ \o -> ToolDefinition
    <$> o .: "name"
    <*> o .: "description"
    <*> pure (fromMaybe stubSchema (KeyMap.lookup (fromString "input_schema") o))

-- | The minimal placeholder @input_schema@ emitted when on-demand schema
-- loading is enabled. Both Anthropic and Ollama normally require an
-- @input_schema@ / @parameters@ field on every tool definition; when a
-- 'ToolDefinition' carries this exact value, the provider encoders OMIT
-- the field entirely rather than sending it inline — saving the few tokens
-- the stub would otherwise cost on every tool, every turn. The model is
-- expected to call @OPCODE_DESCRIBE@ to retrieve a tool's real schema
-- before calling it.
stubSchema :: Value
stubSchema = object ["type" .= ("object" :: Text)]

data ToolChoice = ToolAuto | ToolNone deriving stock (Eq, Show, Generic)
instance ToJSON ToolChoice where toJSON = stripPrefixToJSON
instance FromJSON ToolChoice where parseJSON = stripPrefixParseJSON

data CompletionRequest = CompletionRequest
  { crModel :: ModelId, crSystem :: Maybe Text, crMessages :: [Message]
  , crTools :: [ToolDefinition], crToolChoice :: ToolChoice, crMaxTokens :: Int }
  deriving stock (Eq, Show, Generic)
-- JSON keys: @crModel@→@model@, @crSystem@→@system@, @crMessages@→@messages@,
-- @crTools@→@tools@, @crToolChoice@→@toolChoice@, @crMaxTokens@→@maxTokens@.
instance ToJSON CompletionRequest where toJSON = stripPrefixToJSON
instance FromJSON CompletionRequest where parseJSON = stripPrefixParseJSON

data Usage = Usage { uInput :: Int, uOutput :: Int }
  deriving stock (Eq, Show, Generic)
-- JSON keys: @uInput@→@input@, @uOutput@→@output@.
instance ToJSON Usage where toJSON = stripPrefixToJSON
instance FromJSON Usage where parseJSON = stripPrefixParseJSON

data StopReason = StopEnd | StopToolUse | StopMaxTokens | StopOther Text
  deriving stock (Eq, Show, Generic)
instance ToJSON StopReason where toJSON = stripPrefixToJSON
instance FromJSON StopReason where parseJSON = stripPrefixParseJSON

data CompletionResponse = CompletionResponse
  { rsContent :: [ContentBlock], rsStop :: StopReason, rsUsage :: Usage }
  deriving stock (Eq, Show, Generic)
-- JSON keys: @rsContent@→@content@, @rsStop@→@stop@, @rsUsage@→@usage@.
instance ToJSON CompletionResponse where toJSON = stripPrefixToJSON
instance FromJSON CompletionResponse where parseJSON = stripPrefixParseJSON

class Provider p where
  complete   :: p -> CompletionRequest -> IO (Either Text CompletionResponse)
  listModels :: p -> IO (Either Text [ModelId])

data SomeProvider = forall p. Provider p => SomeProvider p
