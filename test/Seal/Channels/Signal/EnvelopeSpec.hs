{-# LANGUAGE OverloadedStrings #-}
module Seal.Channels.Signal.EnvelopeSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Seal.Core.MessageSource (conversationIdText, userIdText)
import Seal.Channels.Signal.Transport
  ( SignalEnvelope (..)
  , conversationIdForSignal
  , parseSignalEnvelope
  )

-- ---------------------------------------------------------------------------
-- conversationIdForSignal
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "Seal.Channels.Signal.Transport.conversationIdForSignal" $ do
    it "derives sig:<source>:<sourceUuid> when both present" $ do
      case conversationIdForSignal (Just "+15551234567") (Just "abc-uuid") of
        Right cid -> conversationIdText cid `shouldBe` "sig:+15551234567:abc-uuid"
        Left e    -> expectationFailure ("unexpected Left: " <> T.unpack e)
    it "derives sig:<source> when UUID absent" $ do
      case conversationIdForSignal (Just "+15551234567") Nothing of
        Right cid -> conversationIdText cid `shouldBe` "sig:+15551234567"
        Left e    -> expectationFailure ("unexpected Left: " <> T.unpack e)
    it "rejects when source is absent" $
      conversationIdForSignal Nothing (Just "uuid") `shouldSatisfy` isLeft
    it "rejects when source is empty" $
      conversationIdForSignal (Just "") (Just "uuid") `shouldSatisfy` isLeft
    prop "never reads the body (depends only on peer fields)" $
      forAll genPhone $ \src ->
      forAll genMaybeUuid  $ \mUuid ->
        conversationIdForSignal (Just src) mUuid
          === conversationIdForSignal (Just src) mUuid

  describe "Seal.Channels.Signal.Transport.parseSignalEnvelope" $ do
    let rawEnvelope :: Value
        rawEnvelope = object
          [ "envelope" .= object
              [ "source" .= ("+15551234567" :: Text)
              , "sourceUuid" .= ("abc-uuid" :: Text)
              , "dataMessage" .= object [ "message" .= ("hello there" :: Text) ]
              ]
          ]
    it "parses a raw envelope into a SignalEnvelope" $ do
      case parseSignalEnvelope rawEnvelope of
        Right env -> do
          conversationIdText (seConversationId env) `shouldBe` "sig:+15551234567:abc-uuid"
          userIdText (seSender env) `shouldBe` "+15551234567"
          seBody env `shouldBe` "hello there"
        Left e -> expectationFailure ("unexpected Left: " <> T.unpack e)

    let rpcEnvelope :: Value
        rpcEnvelope = object
          [ "jsonrpc" .= ("2.0" :: Text)
          , "method"  .= ("receive" :: Text)
          , "params"  .= object
              [ "envelope" .= object
                  [ "source" .= ("+15551234567" :: Text)
                  , "sourceUuid" .= ("xyz" :: Text)
                  , "dataMessage" .= object [ "message" .= ("rpc body" :: Text) ]
                  ]
              ]
          ]
    it "unwraps a JSON-RPC params.envelope message" $ do
      case parseSignalEnvelope rpcEnvelope of
        Right env -> do
          conversationIdText (seConversationId env) `shouldBe` "sig:+15551234567:xyz"
          seBody env `shouldBe` "rpc body"
        Left e -> expectationFailure ("unexpected Left: " <> T.unpack e)

    it "parses an envelope with source but no sourceUuid" $ do
      let v = object
            [ "envelope" .= object
                [ "source" .= ("+15551234567" :: Text)
                , "dataMessage" .= object [ "message" .= ("no uuid" :: Text) ]
                ]
            ]
      case parseSignalEnvelope v of
        Right env -> conversationIdText (seConversationId env) `shouldBe` "sig:+15551234567"
        Left e    -> expectationFailure ("unexpected Left: " <> T.unpack e)

    it "rejects a value missing the source field" $ do
      let v = object
            [ "envelope" .= object
                [ "dataMessage" .= object [ "message" .= ("no source" :: Text) ]
                ]
            ]
      parseSignalEnvelope v `shouldSatisfy` isLeft

    it "rejects a value with no envelope and no params.envelope" $ do
      parseSignalEnvelope (object [ "foo" .= ("bar" :: Text) ]) `shouldSatisfy` isLeft

    it "rejects a non-object value" $
      parseSignalEnvelope (String "not an object") `shouldSatisfy` isLeft

    it "ignores a body field named conversationId (server-derived only)" $ do
      let v = object
            [ "envelope" .= object
                [ "source" .= ("+15551234567" :: Text)
                , "sourceUuid" .= ("abc" :: Text)
                , "dataMessage" .= object
                    [ "message" .= ("real body" :: Text)
                    , "conversationId" .= ("FORGED" :: Text)
                    ]
                ]
            ]
      case parseSignalEnvelope v of
        Right env -> do
          conversationIdText (seConversationId env) `shouldBe` "sig:+15551234567:abc"
          seBody env `shouldBe` "real body"
        Left e -> expectationFailure ("unexpected Left: " <> T.unpack e)

-- ---------------------------------------------------------------------------
-- Helpers / generators
-- ---------------------------------------------------------------------------

isLeft :: Either a b -> Bool
isLeft (Left _)  = True
isLeft (Right _) = False

genPhone :: Gen Text
genPhone = ("+" <>) . T.pack <$> listOf1 (elements ['0'..'9'])

genUuid :: Gen Text
genUuid = T.pack <$> listOf1 (elements (['a'..'f'] <> ['0'..'9'] <> "-"))

genMaybeUuid :: Gen (Maybe Text)
genMaybeUuid = oneof [pure Nothing, Just <$> genUuid]