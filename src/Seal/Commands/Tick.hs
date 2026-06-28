{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
module Seal.Commands.Tick (tick) where

import Control.Monad.IO.Class
import Control.Monad.Reader
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import Katip

import Seal.Types.Env
import Seal.Types.App

-- | The @tick@ command: takes @--count N@, increments the 'IORef' counter in
-- 'Env' that many times, logging the running total each step. Demonstrates
-- IORef-based mutable state inside the 'ReaderT' monad.
tick :: Int -> App ()
tick n
  | n <= 0 = $(logTM) InfoS "tick: nothing to do"
  | otherwise = do
      counter <- asks envCounter
      mapM_ (step counter) [1 .. n]
  where
    step :: IORef Int -> Int -> App ()
    step counter i = do
      total <- liftIO $ atomicModifyIORef' counter (\x -> (x + 1, x + 1))
      $(logTM) InfoS . ls $
        "tick " <> tshow i <> "/" <> tshow n <> " — total: " <> tshow total

tshow :: Show a => a -> Text
tshow = T.pack . show