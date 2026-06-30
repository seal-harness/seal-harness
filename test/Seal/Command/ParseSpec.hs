{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.ParseSpec (spec) where

import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Options.Applicative

import Seal.Channel.Caps (ChannelCaps(..))
import Seal.Command.Spec
import Seal.Command.Parse

-- ---------------------------------------------------------------------------
-- Sample registry (same ping/echo specs as SpecSpec; kept local to this
-- module so ParseSpec has no dependency on SpecSpec).
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

testRegistry :: Registry
testRegistry = mkRegistry [pingSpec]

-- ---------------------------------------------------------------------------
-- A "word" safe for the tokenizer QuickCheck: non-empty, no spaces, no quotes.
-- ---------------------------------------------------------------------------

newtype SafeWord = SafeWord Text deriving stock (Show)

instance Arbitrary SafeWord where
  arbitrary = do
    n  <- choose (1 :: Int, 20)
    cs <- vectorOf n $
            elements (['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ ['-', '_'])
    pure (SafeWord (T.pack cs))

unSafe :: SafeWord -> Text
unSafe (SafeWord t) = t

-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "Seal.Command.Parse" $ do

  describe "tokenize" $ do

    it "empty input yields empty list" $
      tokenize "" `shouldBe` Right []

    it "single word" $
      tokenize "hello" `shouldBe` Right ["hello"]

    it "splits on spaces" $
      tokenize "foo bar baz" `shouldBe` Right ["foo", "bar", "baz"]

    it "collapses multiple spaces" $
      tokenize "foo  bar" `shouldBe` Right ["foo", "bar"]

    it "strips leading and trailing spaces" $
      tokenize "  ping  " `shouldBe` Right ["ping"]

    it "double-quoted string becomes a single token" $
      tokenize "\"hello world\"" `shouldBe` Right ["hello world"]

    it "double-quoted token adjacent to plain token concatenates" $
      tokenize "foo\"bar\"" `shouldBe` Right ["foobar"]

    it "quoted section containing spaces is one token" $
      tokenize "vault add \"my secret key\"" `shouldBe`
        Right ["vault", "add", "my secret key"]

    it "empty quoted string is a valid token" $
      tokenize "\"\"" `shouldBe` Right [""]

    it "unterminated double-quote returns Left" $
      case tokenize "\"hello" of
        Left  _ -> pure ()
        Right _ -> expectationFailure "expected Left for unterminated quote"

    it "unterminated quote mid-word returns Left" $
      case tokenize "foo \"bar" of
        Left  _ -> pure ()
        Right _ -> expectationFailure "expected Left for unterminated quote"

    prop "plain words survive a round-trip through tokenize" $
      \(NonEmpty ws) ->
        let words' = map unSafe ws
            input  = T.intercalate " " words'
        in tokenize input === Right words'

    prop "double-quoted word is a single token regardless of spaces inside" $
      \(SafeWord prefix) (SafeWord suffix) ->
        let inner = prefix <> " " <> suffix
            tok   = "\"" <> inner <> "\""
        in tokenize tok === Right [inner]

  describe "parseSlash" $ do

    it "/help -> ParseHelp Nothing" $
      case parseSlash testRegistry "/help" of
        ParseHelp Nothing -> pure ()
        other -> expectationFailure ("unexpected: " <> show (isHelp other))

    it "/help ping -> ParseHelp (Just (CommandName \"ping\"))" $
      case parseSlash testRegistry "/help ping" of
        ParseHelp (Just (CommandName "ping")) -> pure ()
        _ -> expectationFailure "expected ParseHelp (Just ping)"

    it "/HELP is case-insensitive -> ParseHelp Nothing" $
      case parseSlash testRegistry "/HELP" of
        ParseHelp Nothing -> pure ()
        _ -> expectationFailure "expected ParseHelp Nothing for /HELP"

    it "/ping --help -> ParseHelp (Just (CommandName \"ping\"))" $
      case parseSlash testRegistry "/ping --help" of
        ParseHelp (Just (CommandName "ping")) -> pure ()
        _ -> expectationFailure "expected ParseHelp (Just ping) for --help flag"

    it "/ping -h -> ParseHelp (Just (CommandName \"ping\"))" $
      case parseSlash testRegistry "/ping -h" of
        ParseHelp (Just (CommandName "ping")) -> pure ()
        _ -> expectationFailure "expected ParseHelp (Just ping) for -h flag"

    it "/unknown -> ParseFailure with the unknown command name" $
      case parseSlash testRegistry "/nosuchcmd" of
        ParseFailure msg -> T.isInfixOf "nosuchcmd" msg `shouldBe` True
        _                -> expectationFailure "expected ParseFailure"

    it "/ping (no flags) -> ParsedAction" $ do
      ref <- newIORef ("" :: Text)
      let caps = ChannelCaps
            { ccSend         = writeIORef ref
            , ccPrompt       = \_ -> pure ""
            , ccPromptSecret = \_ -> pure ""
            }
      case parseSlash testRegistry "/ping" of
        ParsedAction cmd -> do
          runCommandAction cmd caps
          readIORef ref `shouldReturn` "pong"
        other -> expectationFailure ("expected ParsedAction, got: " <> show (isHelp other))

    it "/ping --loud -> ParsedAction that sends PONG!" $ do
      ref <- newIORef ("" :: Text)
      let caps = ChannelCaps
            { ccSend         = writeIORef ref
            , ccPrompt       = \_ -> pure ""
            , ccPromptSecret = \_ -> pure ""
            }
      case parseSlash testRegistry "/ping --loud" of
        ParsedAction cmd -> do
          runCommandAction cmd caps
          readIORef ref `shouldReturn` "PONG!"
        other -> expectationFailure ("expected ParsedAction, got: " <> show (isHelp other))

    it "/p (alias) -> ParsedAction" $
      case parseSlash testRegistry "/p" of
        ParsedAction _ -> pure ()
        _              -> expectationFailure "expected ParsedAction for alias /p"

    it "unterminated quote -> ParseFailure" $
      case parseSlash testRegistry "/ping \"unterminated" of
        ParseFailure _ -> pure ()
        _              -> expectationFailure "expected ParseFailure for bad tokenize"

  where
    -- helper so show errors are informative without a Show instance on ParseOutcome
    isHelp :: ParseOutcome -> Bool
    isHelp (ParseHelp _) = True
    isHelp _             = False
