{-# LANGUAGE OverloadedStrings #-}
module Seal.Tools.Exec.MachineSpec (spec) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text qualified as T
import Test.Hspec

import Seal.Config.Machines (MachineName, Selectable (..), mkMachineName)
import Seal.SourceControl.Clone (stubCloneDeps)
import Seal.Tools.Exec.Machine
import Seal.Tools.Exec.UntrustedIO (mkRemoteUntrustedIOStub)

spec :: Spec
spec = describe "Seal.Tools.Exec.Machine" $ do

  describe "rtResolve" $ do

    it "returns the seeded handle and deps for a seeded machine" $ do
      counter <- newIORef (0 :: Int)
      routing <- mkRouting ["a"] counter
      res <- rtResolve routing (name "a")
      case res of
        Right (_uio, _deps) -> pure ()
        Left e -> expectationFailure ("expected Right, got " <> show e)

    it "caches a success — the bootstrap runs once, not once per call" $ do
      counter <- newIORef (0 :: Int)
      routing <- mkRouting ["a"] counter
      _ <- rtResolve routing (name "a")
      _ <- rtResolve routing (name "a")
      _ <- rtResolve routing (name "a")
      readIORef counter `shouldReturn` 1

    it "caches a failure — a dead machine costs one attempt per session" $ do
      counter <- newIORef (0 :: Int)
      routing <- mkRoutingFailing ["dead"] counter
      _ <- rtResolve routing (name "dead")
      _ <- rtResolve routing (name "dead")
      readIORef counter `shouldReturn` 1

    it "a failed machine keeps returning the same error, not a stub reason" $ do
      counter <- newIORef (0 :: Int)
      routing <- mkRoutingFailing ["dead"] counter
      r1 <- rtResolve routing (name "dead")
      r2 <- rtResolve routing (name "dead")
      -- Compare the error payloads: the Right arm holds an UntrustedIO, which
      -- has no Eq.
      either Just (const Nothing) r1 `shouldBe` either Just (const Nothing) r2
      case r1 of
        Left (MachineUnreachable n UrConnectFailed) -> n `shouldBe` name "dead"
        Left other -> expectationFailure ("expected MachineUnreachable, got " <> show other)
        Right _    -> expectationFailure "expected MachineUnreachable, got a handle"

    it "resolves two machines independently" $ do
      counter <- newIORef (0 :: Int)
      routing <- mkRouting ["a", "b"] counter
      ra <- rtResolve routing (name "a")
      rb <- rtResolve routing (name "b")
      isRight ra `shouldBe` True
      isRight rb `shouldBe` True
      readIORef counter `shouldReturn` 2

  describe "rtSession / rtSelectable" $ do

    it "reports the session machine" $ do
      counter <- newIORef (0 :: Int)
      routing <- mkRoutingWithSession "sessionbox" ["a"] counter
      rtSession routing `shouldBe` name "sessionbox"

    it "reports the selectable set it was built with" $ do
      counter <- newIORef (0 :: Int)
      routing <- mkRoutingWithSession "sessionbox" ["a"] counter
      rtSelectable routing `shouldBe` [SelMachine (name "a")]

  describe "seedRouting" $ do

    it "seeds several machines so each is immediately resolvable" $ do
      counter <- newIORef (0 :: Int)
      routing <- mkRouting [] counter
      seeded <- seedRouting routing
        [ (name "a", mkRemoteUntrustedIOStub, stubCloneDeps)
        , (name "b", mkRemoteUntrustedIOStub, stubCloneDeps)
        ]
      ra <- rtResolve seeded (name "a")
      rb <- rtResolve seeded (name "b")
      isRight ra `shouldBe` True
      isRight rb `shouldBe` True
      -- seeding never invokes the bootstrap
      readIORef counter `shouldReturn` 0

  describe "MachineSlot Show" $ do

    it "never renders the handle" $ do
      show (SlotReady mkRemoteUntrustedIOStub stubCloneDeps)
        `shouldBe` "SlotReady <handle> <deps>"

  describe "UnreachableReason" $ do

    it "carries no free text — every reason is nullary" $ do
      -- A type-level guarantee expressed as a smoke test: the renderings differ.
      map renderUnreachableReason
        [UrConnectFailed, UrBootstrapFailed, UrHostKeyUnknown]
        `shouldBe` ["could not connect", "could not prepare the workspace",
                    "its host key is not yet known"]

-- Helpers -----------------------------------------------------------------

name :: String -> MachineName
name s = case mkMachineName (T.pack s) of
  Right n -> n
  Left e  -> error ("MachineSpec: invalid test machine name: " <> show e)

-- | A routing table whose bootstrap succeeds for any name, counting calls.
mkRouting :: [String] -> IORef Int -> IO MachineRouting
mkRouting = mkRoutingWithSession "session"

mkRoutingWithSession :: String -> [String] -> IORef Int -> IO MachineRouting
mkRoutingWithSession sessionName names counter =
  mkMachineRouting (name sessionName) [SelMachine (name n) | n <- names]
    (\_n deps -> do
        modifyIORef' counter (+ 1)
        pure (Right (mkRemoteUntrustedIOStub, deps)))
    stubCloneDeps

-- | A routing table whose bootstrap always fails, counting calls.
mkRoutingFailing :: [String] -> IORef Int -> IO MachineRouting
mkRoutingFailing names counter =
  mkMachineRouting (name "session") [SelMachine (name n) | n <- names]
    (\n _deps -> do
        modifyIORef' counter (+ 1)
        pure (Left (MachineUnreachable n UrConnectFailed)))
    stubCloneDeps

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight _         = False
