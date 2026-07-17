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

data Role = User | Assistant deriving stock (Eq, Show, Generic)
instance ToJSON Role
instance FromJSON Role

newtype ToolResultPart = TrpText Text deriving stock (Eq, Show, Generic)
instance ToJSON ToolResultPart
instance FromJSON ToolResultPart

-- | A single block of content in a message.
--
-- __Partial field selectors warning:__ The record fields 'cbId', 'cbName',
-- 'cbInput', 'cbForId', 'cbParts', and 'cbIsError' are only defined on their
-- respective constructors ('CbToolUse' and 'CbToolResult'). They are partial
-- across the full type and will throw a runtime error if applied to the wrong
-- constructor. Always access them inside a constructor-specific pattern match;
-- never use them as bare accessor functions.
data ContentBlock
  = CbText Text
  | CbToolUse    { cbId :: ToolCallId, cbName :: OpName, cbInput :: Value }
  | CbToolResult { cbForId :: ToolCallId, cbParts :: [ToolResultPart], cbIsError :: Bool }
  deriving stock (Eq, Show, Generic)
instance ToJSON ContentBlock
instance FromJSON ContentBlock

data Message = Message { msgRole :: Role, msgContent :: [ContentBlock] }
  deriving stock (Eq, Show, Generic)
instance ToJSON Message
instance FromJSON Message

textMsg :: Role -> Text -> Message
textMsg r t = Message r [CbText t]

data ToolDefinition = ToolDefinition
  { tdName :: OpName, tdDescription :: Text, tdInputSchema :: Value }
  deriving stock (Eq, Show, Generic)

-- | Custom 'ToJSON': emits @tdName@ + @tdDescription@ always, and
-- @tdInputSchema@ only when it differs from 'stubSchema'. The keys match
-- the derived instance's field names so 'FromJSON' (still derived) round-
-- trips. This keeps the on-disk transcript envelope (@edTools@) and the
-- debug @requests.jsonl@ consistent with the provider encoders (which also
-- omit the field for stubs) so no @input_schema@ token cost leaks in
-- on-demand mode through the generic derived instance. The provider
-- 'encTool's still control the exact on-the-wire shape (@input_schema@ for
-- Anthropic, @function.parameters@ for Ollama); this instance governs the
-- provider-agnostic transcript view.
instance ToJSON ToolDefinition where
  toJSON (ToolDefinition n d sch) =
    if sch == stubSchema
      then object ["tdName" .= n, "tdDescription" .= d]
      else object ["tdName" .= n, "tdDescription" .= d, "tdInputSchema" .= sch]

-- | Custom 'FromJSON': @tdName@ + @tdDescription@ required; @tdInputSchema@
-- OPTIONAL, defaulting to 'stubSchema' when the key is ABSENT. The 'ToJSON'
-- instance omits @tdInputSchema@ for stub tools, so the derived instance
-- (which treats every field as required) would reject those rows and —
-- worse — take down the whole 'EnvelopeDelta' parse (aeson's 'parseJSON' is
-- sequential), losing the system prompt from the reconstructed envelope.
-- Key PRESENCE (not value null-ness) distinguishes "stored stub, omitted by
-- ToJSON" from "explicitly null": an absent key defaults to 'stubSchema'
-- (closing the stub round-trip), while a present 'null' stays 'Null' (so
-- the arbitrary-data round-trip property still holds).
instance FromJSON ToolDefinition where
  parseJSON = withObject "ToolDefinition" $ \o -> ToolDefinition
    <$> o .: "tdName"
    <*> o .: "tdDescription"
    <*> pure (fromMaybe stubSchema (KeyMap.lookup (fromString "tdInputSchema") o))

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
instance ToJSON ToolChoice
instance FromJSON ToolChoice

data CompletionRequest = CompletionRequest
  { crModel :: ModelId, crSystem :: Maybe Text, crMessages :: [Message]
  , crTools :: [ToolDefinition], crToolChoice :: ToolChoice, crMaxTokens :: Int }
  deriving stock (Eq, Show, Generic)
instance ToJSON CompletionRequest
instance FromJSON CompletionRequest

data Usage = Usage { uInput :: Int, uOutput :: Int }
  deriving stock (Eq, Show, Generic)
instance ToJSON Usage
instance FromJSON Usage

data StopReason = StopEnd | StopToolUse | StopMaxTokens | StopOther Text
  deriving stock (Eq, Show, Generic)
instance ToJSON StopReason
instance FromJSON StopReason

data CompletionResponse = CompletionResponse
  { rsContent :: [ContentBlock], rsStop :: StopReason, rsUsage :: Usage }
  deriving stock (Eq, Show, Generic)
instance ToJSON CompletionResponse
instance FromJSON CompletionResponse

class Provider p where
  complete   :: p -> CompletionRequest -> IO (Either Text CompletionResponse)
  listModels :: p -> IO (Either Text [ModelId])

data SomeProvider = forall p. Provider p => SomeProvider p
