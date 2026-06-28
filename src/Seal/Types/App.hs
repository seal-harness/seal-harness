{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
module Seal.Types.App
  ( App(..)
  , runApp
  , withKatip
  ) where

import Control.Monad.Catch
import Control.Monad.IO.Class
import Control.Monad.Reader
import Data.Maybe
import Data.Text (Text)

import Katip
import System.IO

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

-- | Run an 'App' action: build the katip environment via 'withKatip' and run
-- the 'ReaderT' against the given 'Env'.
runApp :: Env -> App a -> IO a
runApp env (App m) = withKatip (envLogLevel env) $ \le ->
  runKatipContextT le () "seal-harness" (runReaderT m env)

-- | Bracket the lifetime of a 'LogEnv' with a single stderr scribe using a
-- compact bracket formatter. The minimum 'Severity' is derived from the
-- config (via @--log-level@, defaulting to @InfoS@).
withKatip :: Text -> (LogEnv -> IO a) -> IO a
withKatip logLevel = bracket makeLogEnv closeScribes
  where
    makeLogEnv = do
      let sev = fromMaybe InfoS (textToSeverity logLevel)
      scribe <- mkHandleScribeWithFormatter bracketFormat
        ColorIfTerminal stderr (permitItem sev) V2
      registerScribe "stderr" scribe defaultScribeSettings
        =<< initLogEnv "seal-harness" "production"