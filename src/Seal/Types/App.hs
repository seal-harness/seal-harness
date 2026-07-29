{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Seal.Types.App
  ( App(..)
  , runApp
  ) where

import Control.Monad.Catch
import Control.Monad.IO.Class
import Control.Monad.Reader

import Katip

import Seal.Logging.Logger (SealLogger (..))
import Seal.Types.Env

-- | The application monad: @ReaderT Env (KatipContextT IO)@, matching the
-- source project's application-monad shape. The 'Katip' and 'KatipContext'
-- instances are hand-written, delegating through the newtype to the underlying
-- 'KatipContextT' layer.
newtype App a = App { unApp :: ReaderT Env (KatipContextT IO) a }
  deriving newtype
    ( Functor, Applicative, Monad, MonadIO, MonadReader Env, MonadThrow )

instance Katip App where
  getLogEnv = App (lift getLogEnv)
  localLogEnv f (App m) = App (localLogEnv f m)

instance KatipContext App where
  getKatipContext = App (lift getKatipContext)
  localKatipContext f (App m) = App (localKatipContext f m)
  getKatipNamespace = App (lift getKatipNamespace)
  localKatipNamespace f (App m) = App (localKatipNamespace f m)

-- | Run an 'App' action: use the 'SealLogger' from 'Env' to set up the katip
-- context (LogEnv + LogContexts + Namespace), then run the 'ReaderT' against
-- the given 'Env'. The logger is built once at startup via 'withSealLogger'
-- and threaded through 'Env' so 'App'-level 'logMsg' calls and 'IO'-level
-- 'logIO' calls reach the same scribe.
runApp :: Env -> App a -> IO a
runApp env (App m) =
  runKatipContextT (slLogEnv logger) (slContext logger)
    (slNamespace logger) (runReaderT m env)
  where
    logger = envLogger env