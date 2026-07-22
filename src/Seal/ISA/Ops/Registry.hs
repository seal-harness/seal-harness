{-# LANGUAGE OverloadedStrings #-}
-- | The Registry introspection opcode group: OPCODE_DESCRIBE and
-- OPCODE_LIST. These are trusted, read-only opcodes that let the model
-- discover an opcode's full input/output JSON Schema on demand. They are
-- registered (alongside stub @input_schema@s emitted by
-- 'Seal.ISA.Registry.registryToolDefs'') only when the
-- @on_demand_schemas@ config flag is set, so sessions that keep full
-- schemas inline never see them.
--
-- 'OPCODE_DESCRIBE' mirrors the 'SKILL_LOAD' pattern: take an opcode
-- name, render name + description + input schema + output schema as
-- Markdown-ish text the model can read into its context before calling
-- the tool. 'OPCODE_LIST' mirrors 'SKILL_LIST': a cheap name +
-- description summary of every registered opcode (no schema bodies),
-- so the model can pick which opcode to describe without burning the
-- full schema set up front.
module Seal.ISA.Ops.Registry
  ( opcodeDescribeOp
  , opcodeListOp
  ) where

import Data.Aeson
  ( Value, encode, object, withObject, (.:), (.=) )
import Data.Aeson.Key (fromText)
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Core.Types (OpName (..), TrustLevel (..))
import Seal.ISA.Opcode
import Seal.ISA.Registry (Registry, lookupOp, registryToolDefs')
import Seal.Providers.Class (ToolDefinition (..), ToolResultPart (..))

-- | The full schema rendering used by 'OPCODE_DESCRIBE': a compact,
-- model-readable block with the opcode's name, description, and the
-- compact JSON input/output Schemas. The schemas are encoded as compact
-- JSON (no trailing newline) so the block is easy for the model to parse
-- and small to carry in-context.
describeText :: Opcode -> Text
describeText op =
  let OpName n = opName op
      d = opDesc op
      inJson  = encode (opInSchema op)
      outJson = encode (opOutSchema op)
  in T.intercalate "\n"
       [ "# " <> n
       , ""
       , d
       , ""
       , "input_schema:"
       , T.pack (BLC.unpack inJson)
       , ""
       , "output_schema:"
       , T.pack (BLC.unpack outJson)
       ]

-- | OPCODE_DESCRIBE: return one opcode's full name, description, and
-- input/output JSON Schemas by name. Trusted — introspection is a
-- read-only control-plane action. The result is a 'TrpText' the model
-- reads before calling the described tool. 'orRecorded' carries the
-- secret-free name + a flag for whether the opcode was found.
opcodeDescribeOp :: Registry -> Opcode
opcodeDescribeOp reg = TrustedOpcode
  { toName = OpName "OPCODE_DESCRIBE"
  , toTrust = Trusted
  , toDesc = "Retrieve the full input/output JSON Schema for one opcode by name. Call this before invoking a tool when its input schema was not included inline."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "name" .= object
              [ "type" .= ("string" :: Text)
              , "description" .= ("The opcode name (e.g. FILE_READ)." :: Text)
              ]
          ]
      , "required" .= (["name"] :: [Text])
      ]
  , toOutSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object
          [ fromText "name" .= object ["type" .= ("string" :: Text)]
          , fromText "description" .= object ["type" .= ("string" :: Text)]
          , fromText "input_schema" .= object []
          , fromText "output_schema" .= object []
          ]
      ]
  , toAuthorize = maybe (Left "OPCODE_DESCRIBE requires {name:string}") (const (Right ())) . nameField
  , toRun = \_ v -> do
      let mName = nameField v
      case mName of
        Nothing -> pure (OpResult [TrpText "missing name"] True (object []))
        Just nm -> case lookupOp reg (OpName nm) of
          Nothing -> pure
            ( OpResult [TrpText ("opcode not found: " <> nm)] True
            (object ["name" .= nm, "found" .= False]) )
          Just op -> do
            let rendered = describeText op
                OpName n = opName op
                recorded = object
                  [ "name" .= n
                  , "found" .= True
                  ]
            pure (OpResult [TrpText rendered] False recorded)
  }

-- | OPCODE_LIST: enumerate every registered opcode's name + description
-- (no schema bodies). Cheap summary so the model can decide which
-- opcode to describe with 'OPCODE_DESCRIBE' without loading all
-- schemas. Trusted and read-only.
opcodeListOp :: Registry -> Opcode
opcodeListOp reg = TrustedOpcode
  { toName = OpName "OPCODE_LIST"
  , toTrust = Trusted
  , toDesc = "List all registered opcodes with their names and one-line descriptions (no schemas). Use OPCODE_DESCRIBE to fetch a specific opcode's full schema."
  , toInSchema = object
      [ "type" .= ("object" :: Text)
      , "properties" .= object []
      ]
  , toOutSchema = object
      [ "type" .= ("array" :: Text)
      , "items" .= object
          [ "type" .= ("object" :: Text)
          , "properties" .= object
              [ fromText "name" .= object ["type" .= ("string" :: Text)]
              , fromText "description" .= object ["type" .= ("string" :: Text)]
              ]
          ]
      ]
  , toAuthorize = const (Right ())
  , toRun = \_ _ -> do
      let defs = registryToolDefs' False reg
          rendered = case defs of
            [] -> "(no opcodes registered)"
            _  -> T.intercalate "\n"
                    [ let OpName n = tdName d in n <> ": " <> tdDescription d
                    | d <- defs
                    ]
          recorded = object
            [ "count" .= length defs
            , "names" .= [ let OpName n = tdName d in n | d <- defs ]
            ]
      pure (OpResult [TrpText rendered] False recorded)
  }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Extract the @name@ string field from a JSON object.
nameField :: Value -> Maybe Text
nameField = parseMaybe (withObject "in" (.: "name"))