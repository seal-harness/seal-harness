{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.ServeSpec (spec) where

import Options.Applicative (defaultPrefs, execParserPure, ParserResult(..), info, progDesc, renderFailure)
import Data.Text qualified as T
import Test.Hspec

import Seal.Types.Command (Command(..), pCommand)

spec :: Spec
spec = describe "Seal.Command.Serve" $ do
  let cmdInfo = info pCommand (progDesc "seal subcommand")
  it "parses 'serve' as CommandServe" $
    case execParserPure defaultPrefs cmdInfo ["serve"] of
      Success cmd -> cmd `shouldBe` CommandServe
      other       -> expectationFailure ("expected CommandServe, got: " <> show other)

  it "renders --help for the serve subcommand" $
    case execParserPure defaultPrefs cmdInfo ["serve", "--help"] of
      Failure f -> T.unpack (T.pack (fst (renderFailure f "seal"))) `shouldContain` "serve"
      other     -> expectationFailure ("expected Failure for --help, got: " <> show other)