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
  it "parses 'serve' as CommandServe Supervised Nothing" $
    case execParserPure defaultPrefs cmdInfo ["serve"] of
      Success cmd -> cmd `shouldBe` CommandServe Supervised Nothing
      other       -> expectationFailure ("expected CommandServe Supervised Nothing, got: " <> show other)

  it "parses 'serve --yolo' as CommandServe Full Nothing" $
    case execParserPure defaultPrefs cmdInfo ["serve", "--yolo"] of
      Success cmd -> cmd `shouldBe` CommandServe Full Nothing
      other       -> expectationFailure ("expected CommandServe Full Nothing, got: " <> show other)

  it "parses 'serve --static-dir /path/to/dist' as CommandServe Supervised (Just ...)" $
    case execParserPure defaultPrefs cmdInfo ["serve", "--static-dir", "/path/to/dist"] of
      Success cmd -> cmd `shouldBe` CommandServe Supervised (Just "/path/to/dist")
      other       -> expectationFailure ("expected CommandServe Supervised (Just \"/path/to/dist\"), got: " <> show other)

  it "parses 'serve --yolo --static-dir frontend/dist' as CommandServe Full (Just ...)" $
    case execParserPure defaultPrefs cmdInfo ["serve", "--yolo", "--static-dir", "frontend/dist"] of
      Success cmd -> cmd `shouldBe` CommandServe Full (Just "frontend/dist")
      other       -> expectationFailure ("expected CommandServe Full (Just \"frontend/dist\"), got: " <> show other)

  it "renders --help for the serve subcommand" $
    case execParserPure defaultPrefs cmdInfo ["serve", "--help"] of
      Failure f -> T.unpack (T.pack (fst (renderFailure f "seal"))) `shouldContain` "serve"
      other     -> expectationFailure ("expected Failure for --help, got: " <> show other)