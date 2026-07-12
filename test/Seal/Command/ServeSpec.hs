{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.ServeSpec (spec) where

import Options.Applicative (defaultPrefs, execParserPure, ParserResult(..), info, progDesc, renderFailure)
import Data.Text qualified as T
import Test.Hspec

import Seal.Types.Command (Command(..), pCommand)
import Seal.Security.Policy (AutonomyLevel (..))

spec :: Spec
spec = describe "Seal.Command.Serve" $ do
  let cmdInfo = info pCommand (progDesc "seal subcommand")
  it "parses 'serve' as CommandServe Supervised" $
    case execParserPure defaultPrefs cmdInfo ["serve"] of
      Success cmd -> cmd `shouldBe` CommandServe Supervised
      other       -> expectationFailure ("expected CommandServe Supervised, got: " <> show other)

  it "parses 'serve --yolo' as CommandServe Full" $
    case execParserPure defaultPrefs cmdInfo ["serve", "--yolo"] of
      Success cmd -> cmd `shouldBe` CommandServe Full
      other       -> expectationFailure ("expected CommandServe Full, got: " <> show other)

  it "renders --help for the serve subcommand" $
    case execParserPure defaultPrefs cmdInfo ["serve", "--help"] of
      Failure f -> T.unpack (T.pack (fst (renderFailure f "seal"))) `shouldContain` "serve"
      other     -> expectationFailure ("expected Failure for --help, got: " <> show other)