{-# LANGUAGE OverloadedStrings #-}
-- | Haskeline-backed CLI REPL channel.
module Seal.Channel.Cli
  ( runCliRepl
  , interpretDisposition
  ) where

import Control.Monad.IO.Class (liftIO)
import qualified Data.Text as T
import System.FilePath ((</>))
import System.Console.Haskeline
  ( InputT
  , Settings (..)
  , defaultSettings
  , getInputLine
  , getPassword
  , noCompletion
  , runInputT
  )

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Spec (CommandAction (..), Registry)
import Seal.Config.Paths (SealPaths (..))
import Seal.Ingest (Disposition (..), PreprocessChain, RawInbound (..), ingest)

-- | Map a 'Disposition' to its channel effect.
--
-- Extracted for testability: callers supply a 'ChannelCaps'; no Haskeline
-- context is required.
interpretDisposition :: ChannelCaps -> Disposition -> IO ()
interpretDisposition caps = \case
  DispatchAction a -> runCommandAction a caps
  ShowText t       -> ccSend caps t
  PlainMessage _   -> ccSend caps "(no agent configured yet)"
  Rejected msg     -> ccSend caps msg

-- | Run the Haskeline REPL loop.
--
-- History is persisted at @\<state\>\/history@.  EOF (Ctrl-D) exits.
runCliRepl :: SealPaths -> Registry -> PreprocessChain -> IO ()
runCliRepl paths registry chain =
  let histFile      = spState paths </> "history"
      innerSettings = (defaultSettings :: Settings IO) { complete = noCompletion }
      hlSettings    = innerSettings { historyFile = Just histFile }
      caps = ChannelCaps
        { ccSend         = putStrLn . T.unpack
        , ccPrompt       = \prompt ->
            runInputT innerSettings $ do
              mLine <- getInputLine (T.unpack prompt)
              pure (maybe "" T.pack mLine)
        , ccPromptSecret = \prompt ->
            runInputT innerSettings $ do
              mPass <- getPassword (Just '*') (T.unpack prompt)
              pure (maybe "" T.pack mPass)
        }
  in runInputT hlSettings (loop caps)
  where
    loop :: ChannelCaps -> InputT IO ()
    loop caps = do
      mLine <- getInputLine "> "
      case mLine of
        Nothing   -> pure ()   -- EOF / Ctrl-D
        Just line -> do
          d <- liftIO $ ingest registry chain (RawInbound (T.pack line))
          liftIO $ interpretDisposition caps d
          loop caps
