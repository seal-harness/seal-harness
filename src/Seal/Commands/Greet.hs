{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
module Seal.Commands.Greet (greet) where

import Control.Monad.Reader

import Data.Text (Text)
import qualified Data.Text as T
import Katip

import Seal.Types.Env
import Seal.Types.App

-- | The @greet@ command: reads the greeting template/host info from 'Config'
-- and the per-command @--name@ argument, logging a structured greeting.
-- Demonstrates config-driven values + per-command optparse-applicative args +
-- katip logging.
greet :: Text -> App ()
greet name = do
  greeting <- asks envGreeting
  host <- asks envServerHost
  port <- asks envServerPort
  $(logTM) InfoS . ls $
    greeting <> ", " <> name <> "! (serving from " <> host <> ":" <> tshow port <> ")"

tshow :: Show a => a -> Text
tshow = T.pack . show