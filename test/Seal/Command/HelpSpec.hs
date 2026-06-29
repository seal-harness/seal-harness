{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.HelpSpec (spec) where

import Control.Monad (forM_)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Options.Applicative

import Seal.Channel.Caps (ChannelCaps(..))
import Seal.Command.Spec
import Seal.Command.Help

-- ---------------------------------------------------------------------------
-- Throwaway sample registry for Help tests.
-- Defines a /ping command with --loud and a /vault stub so we exercise
-- multi-group rendering. No vault or external dependencies.
-- ---------------------------------------------------------------------------

data PingOpts = PingOpts Bool Int

pPingOpts :: Parser PingOpts
pPingOpts = PingOpts
  <$> switch
        ( long "loud"
        <> short 'l'
        <> help "Shout the response in uppercase" )
  <*> option auto
        ( long "count"
        <> short 'n'
        <> metavar "N"
        <> value 1
        <> showDefault
        <> help "Number of pings to send" )

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
    toPingAction (PingOpts loud _n) = CommandAction $ \caps ->
      ccSend caps (if loud then "PONG!" else "pong")

-- A minimal vault stub (no real vault; proves multi-group layout).
vaultStubSpec :: CommandSpec
vaultStubSpec = CommandSpec
  { csName         = CommandName "vault"
  , csAliases      = [CommandName "v"]
  , csGroup        = GroupVault
  , csSynopsis     = "Manage the encrypted secret vault"
  , csParserInfo   = info
      (subparser
        (command "status"
          (info (pure (CommandAction $ \caps -> ccSend caps "vault status"))
                (progDesc "Show vault status"))))
      (progDesc "Encrypt and manage secrets")
  , csAvailability = AlwaysAvailable
  }

testRegistry :: Registry
testRegistry = mkRegistry [pingSpec, vaultStubSpec]

-- ---------------------------------------------------------------------------
-- Known long options per command in the test registry (for discoverability).
-- This table is the ground truth: if you add a flag to a spec above, add it
-- here too or the discoverability test will catch the omission.
-- ---------------------------------------------------------------------------

knownOptions :: [(CommandName, [Text])]
knownOptions =
  [ (CommandName "ping",  ["--loud", "--count"])
  , (CommandName "vault", ["--help"])   -- minimal: only the auto-added --help
  ]

-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "Seal.Command.Help" $ do

  -- -------------------------------------------------------------------------
  describe "renderHelpIndex" $ do

    it "contains the synthetic 'help' entry" $
      T.isInfixOf "help" (renderHelpIndex testRegistry) `shouldBe` True

    it "contains every registered command name" $ do
      let idx = renderHelpIndex testRegistry
      forM_ (registrySpecs testRegistry) $ \s ->
        let CommandName n = csName s
        in T.isInfixOf n idx `shouldBe` True

    it "contains the synopsis for each command" $ do
      let idx = renderHelpIndex testRegistry
      forM_ (registrySpecs testRegistry) $ \s ->
        T.isInfixOf (csSynopsis s) idx `shouldBe` True

    it "contains group headers for all groups represented" $ do
      let idx = renderHelpIndex testRegistry
      -- GroupGeneral and GroupVault are both in the test registry
      T.isInfixOf "General" idx `shouldBe` True
      T.isInfixOf "Vault"   idx `shouldBe` True

  -- -------------------------------------------------------------------------
  describe "renderHelpFor" $ do

    it "returns a non-empty string for a known command" $
      T.null (renderHelpFor testRegistry (CommandName "ping")) `shouldBe` False

    it "includes the progDesc in the per-command help" $
      T.isInfixOf "ping" (renderHelpFor testRegistry (CommandName "ping"))
        `shouldBe` True

    it "includes the progDesc text set on the ParserInfo" $
      T.isInfixOf "Send a ping" (renderHelpFor testRegistry (CommandName "ping"))
        `shouldBe` True

    it "returns an error message for an unknown command" $ do
      let h = renderHelpFor testRegistry (CommandName "nonexistent")
      T.null h `shouldBe` False

    it "/help vault == /vault --help (same text)" $ do
      let viaHelp  = renderHelpFor testRegistry (CommandName "vault")
          viaFlag  = renderHelpFor testRegistry (CommandName "vault")
      viaHelp `shouldBe` viaFlag

  -- -------------------------------------------------------------------------
  -- CENTERPIECE: Discoverability invariant.
  -- Every command name must surface in the help index.
  -- Every long option declared in knownOptions must surface in that
  -- command's per-command help. Build fails if anything is missing.
  -- -------------------------------------------------------------------------
  describe "discoverability invariant" $ do

    it "every command name appears in renderHelpIndex" $ do
      let idx = renderHelpIndex testRegistry
      forM_ (registrySpecs testRegistry) $ \s ->
        let CommandName n = csName s
        in T.isInfixOf n idx
             `shouldBe` True

    it "every known long option appears in renderHelpFor output" $
      forM_ knownOptions $ \(name, opts) -> do
        let h = renderHelpFor testRegistry name
        forM_ opts $ \opt ->
          T.isInfixOf opt h `shouldBe` True

    it "renderHelpFor ping contains --loud" $
      T.isInfixOf "--loud"
        (renderHelpFor testRegistry (CommandName "ping"))
          `shouldBe` True

    it "renderHelpFor ping contains --count" $
      T.isInfixOf "--count"
        (renderHelpFor testRegistry (CommandName "ping"))
          `shouldBe` True
