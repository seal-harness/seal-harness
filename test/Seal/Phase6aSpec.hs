{-# LANGUAGE OverloadedStrings #-}
-- | Phase 6a capstone: the harness backend works end-to-end — a fake
-- harness driven through HARNESS_START → liveness → HARNESS_STOP →
-- orphan-eviction. The 6a milestone gate.
module Seal.Phase6aSpec (spec) where

import Control.Concurrent.STM (atomically)
import Data.Aeson (Value, object, (.=))
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Test.Hspec

import Seal.Handles.Harness (HarnessError (..))
import Seal.Handles.Transcript (TwoFileHandle, fakeTwoFileTranscript)
import Seal.Harness.Id
import Seal.Harness.Reconcile
import Seal.Harness.Registry
import Seal.Harness.Tmux
import Seal.ISA.Dispatch (DispatchError, dispatch)
import Seal.ISA.Opcode (Opcode, OpResult, localBackend, opName)
import Seal.Tools.Exec.Types (ExecBackend (..), mkLocalExecHandlePlaceholder)
import Seal.ISA.Ops.Harness
import Seal.ISA.Registry qualified as Registry
import Seal.Session.Kind (HarnessFlavour (..))
import Seal.Types.App (App, runApp)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (mkEnv)

-- A fake TmuxRunner that records argv + returns scripted stdout (LIFO).
mkFakeRunner :: [Text] -> IO (TmuxRunner, IO [[String]])
mkFakeRunner scripted = do
  queueRef <- newIORef scripted
  argsRef <- newIORef []
  let runner = TmuxRunner $ \argv -> do
        modifyIORef' argsRef (argv :)
        qs <- readIORef queueRef
        case qs of
          [] -> pure (Right "")
          (q:rest) -> do
            writeIORef queueRef rest
            if q == "__EXIT__127__"
              then pure (Left HeTmuxMissing)
              else pure (Right q)
      getArgs = reverse <$> readIORef argsRef
  pure (runner, getArgs)

spec :: Spec
spec = describe "Seal.Phase6aSpec" $ do
  it "HARNESS_START → registry has one entry → reconcileTick classifies Thinking → HARNESS_LIST sees it → HARNESS_STOP marks Exited" $ do
    reg <- newHarnessRegistry
    (runner, getArgs) <- mkFakeRunner
      [ "ok"                      -- new-session
      , "ok"                      -- new-window
      , "ok"                      -- set-option @seal_id
      ]
    let session = right (mkTmuxIdent "seal")
        window  = right (mkTmuxIdent "claude-1")
        mintId = newHarnessId
        startOp = harnessStartOp reg runner session window HfClaudeCode mintId
        listOp  = harnessListOp reg
    appEnv <- mkEnv defaultConfig
    (tHandle, _) <- fakeTwoFileTranscript

    -- 1. HARNESS_START
    r1 <- runApp appEnv (dispatchReg tHandle startOp)
    r1 `shouldSatisfy` isRight

    -- capture the minted id from the registry for the reconcile + stop
    snap0 <- snapshot reg
    let hid = heId (headSafe snap0)
    -- re-script the runner for the reconcile: it must return the seal_id
    -- marker matching the minted id + a "Thinking…" capture. We need a
    -- fresh runner with the new scripted queue.
    (runner2, _) <- mkFakeRunner
      [ "@seal_id \"" <> harnessIdToText hid <> "\"\n"  -- show-options
      , "some output\nThinking…"                        -- capture-pane
      , "ok"                                            -- kill-window (stop)
      ]
    let stopOp2 = harnessStopOp reg runner2

    -- 2. registry has one entry, OriginSpawned, LvIdle
    snap1 <- snapshot reg
    length snap1 `shouldBe` 1
    fmap heOrigin snap1 `shouldBe` [HoSpawned]
    fmap heLiveness snap1 `shouldBe` [LvIdle]

    -- 3. reconcileTick classifies the scripted "Thinking…" capture
    snap2 <- reconcileTick reg runner2 session HfClaudeCode defaultOrphanGraceTicks
    length snap2 `shouldBe` 1
    fmap heLiveness snap2 `shouldBe` [LvThinking]

    -- 4. HARNESS_LIST sees the entry with LvThinking
    _r2 <- runApp appEnv (dispatchReg tHandle listOp)
    _r2 `shouldSatisfy` isRight

    -- 5. HARNESS_STOP marks the entry LvExited
    r3 <- runApp appEnv (dispatchOp tHandle stopOp2 (object ["id" .= harnessIdToText hid]))
    r3 `shouldSatisfy` isRight
    snap3 <- snapshot reg
    fmap heLiveness snap3 `shouldBe` [LvExited]

    -- 6. the first fake runner captured the start argv; the second captured
    --    the stop argv (kill-window). Check the first.
    args <- getArgs
    args `shouldSatisfy` any ("new-session" `elem`)
    args `shouldSatisfy` any ("new-window" `elem`)
    args `shouldSatisfy` any ("@seal_id" `elem`)

  it "orphan grace evicts after defaultOrphanGraceTicks + 1 ticks" $ do
    reg <- newHarnessRegistry
    hid <- newHarnessId
    atomically (insert reg (testEntry hid) { heLiveness = LvIdle, heOrphanTicks = 0 })
    _ <- atomically (tickOrphans reg mempty defaultOrphanGraceTicks)  -- tick 1
    _ <- atomically (tickOrphans reg mempty defaultOrphanGraceTicks)  -- tick 2
    _ <- atomically (tickOrphans reg mempty defaultOrphanGraceTicks)  -- tick 3 (== grace, not evicted)
    snap3 <- snapshot reg
    length snap3 `shouldBe` 1
    evicted <- atomically (tickOrphans reg mempty defaultOrphanGraceTicks)  -- tick 4 (> grace, evicted)
    length evicted `shouldBe` 1
    snap4 <- snapshot reg
    snap4 `shouldBe` []

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Dispatch one opcode via a one-op registry against a fake transcript.
dispatchReg :: TwoFileHandle -> Opcode -> App (Either DispatchError OpResult)
dispatchReg h op = dispatch (Registry.mkRegistry [op]) h localBackend (EbLocal mkLocalExecHandlePlaceholder) (opName op) (object [])

dispatchOp :: TwoFileHandle -> Opcode -> Value -> App (Either DispatchError OpResult)
dispatchOp h op = dispatch (Registry.mkRegistry [op]) h localBackend (EbLocal mkLocalExecHandlePlaceholder) (opName op)

testEntry :: HarnessId -> HarnessEntry
testEntry hid = HarnessEntry
  { heId = hid
  , heLabel = "test"
  , heOrigin = HoSpawned
  , heLiveness = LvIdle
  , heTmuxCoord = Just "seal:claude-1"
  , heFlavour = Just "claude-code"
  , heOrphanTicks = 0
  }

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight (Left _)  = False

headSafe :: [a] -> a
headSafe (x:_) = x
headSafe []    = error "headSafe: empty"

right :: Show e => Either e a -> a
right (Right x) = x
right (Left e)  = error ("expected Right, got Left: " <> show e)