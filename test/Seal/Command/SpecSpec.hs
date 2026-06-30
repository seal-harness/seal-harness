{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.SpecSpec (spec) where

import Data.IORef (newIORef, readIORef, writeIORef)
import Test.Hspec
import Options.Applicative

import Seal.Channel.Caps (ChannelCaps(..))
import Seal.Command.Spec

-- ---------------------------------------------------------------------------
-- Minimal throwaway CommandSpec used only in this test module.
-- A /ping command with a --loud flag; no vault or external dependencies.
-- ---------------------------------------------------------------------------

newtype PingOpts = PingOpts Bool

pPingOpts :: Parser PingOpts
pPingOpts = PingOpts
  <$> switch (long "loud" <> short 'l' <> help "Shout the response")

pingSpec :: CommandSpec
pingSpec = CommandSpec
  { csName         = CommandName "ping"
  , csAliases      = [CommandName "p"]
  , csGroup        = GroupGeneral
  , csSynopsis     = "Check connectivity"
  , csParserInfo   = info (fmap toPingAction pPingOpts)
                          (progDesc "Send a ping and receive a pong")
  , csAvailability = AlwaysAvailable
  }
  where
    toPingAction (PingOpts loud) = CommandAction $ \caps ->
      ccSend caps (if loud then "PONG!" else "pong")

echoSpec :: CommandSpec
echoSpec = CommandSpec
  { csName         = CommandName "echo"
  , csAliases      = []
  , csGroup        = GroupGeneral
  , csSynopsis     = "Echo text back"
  , csParserInfo   = info (pure (CommandAction $ \caps -> ccSend caps "..."))
                          (progDesc "Echo the input back")
  , csAvailability = AlwaysAvailable
  }

testRegistry :: Registry
testRegistry = mkRegistry [pingSpec, echoSpec]

-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "Seal.Command.Spec" $ do

  describe "mkRegistry / registrySpecs" $ do

    it "registrySpecs round-trips through mkRegistry" $
      length (registrySpecs testRegistry) `shouldBe` 2

    it "preserves insertion order" $ do
      let names = map csName (registrySpecs testRegistry)
      names `shouldBe` [CommandName "ping", CommandName "echo"]

  describe "lookupSpec" $ do

    it "finds a spec by exact name" $
      fmap csName (lookupSpec testRegistry (CommandName "ping"))
        `shouldBe` Just (CommandName "ping")

    it "finds a spec by alias" $
      fmap csName (lookupSpec testRegistry (CommandName "p"))
        `shouldBe` Just (CommandName "ping")

    it "lookup is case-insensitive on the name" $
      fmap csName (lookupSpec testRegistry (CommandName "PING"))
        `shouldBe` Just (CommandName "ping")

    it "lookup is case-insensitive on the alias" $
      fmap csName (lookupSpec testRegistry (CommandName "P"))
        `shouldBe` Just (CommandName "ping")

    it "returns Nothing for an unknown command" $
      fmap csName (lookupSpec testRegistry (CommandName "nonexistent"))
        `shouldBe` Nothing

    it "finds the second spec when the first does not match" $
      fmap csName (lookupSpec testRegistry (CommandName "echo"))
        `shouldBe` Just (CommandName "echo")

  describe "CommandAction" $ do

    it "runCommandAction invokes the captured IO action" $ do
      ref <- newIORef ("" :: String)
      let caps = ChannelCaps
            { ccSend         = writeIORef ref . show
            , ccPrompt       = \_ -> pure ""
            , ccPromptSecret = \_ -> pure ""
            }
          act = CommandAction (`ccSend` "hello")
      runCommandAction act caps
      readIORef ref `shouldReturn` "\"hello\""
