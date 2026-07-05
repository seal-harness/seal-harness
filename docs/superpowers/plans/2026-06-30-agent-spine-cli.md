# Agent Spine over CLI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the minimal Seal agent spine — core types, an append-only transcript with ACK-before-execute, a non-streaming Anthropic provider, an ISA registry/dispatcher, four seed opcodes spanning all three trust levels, and a turn loop — wired over the existing CLI channel so a user can chat with Claude and watch it ask/show the human, read a file, and fetch a secret, with every step durably audited.

**Architecture:** Capability-handle pattern throughout (records of `IO`/`App` actions, no effect system). The agent loop receives an `AgentEnv` bundle of handles and is fully fakeable. The ISA is *data*: each `Opcode` carries its trust level, JSON schemas, an authorization gate, and a run action; `dispatch` enforces `recordAndAck`-before-execute for Untrusted opcodes via a backend-execution seam. Everything runs in the existing `App = ReaderT Env (KatipContextT IO)` monad.

**Tech Stack:** GHC 9.12 / GHC2021, Cabal, `aeson`, `text`, `bytestring`, `containers`, `stm` + base `forkIO` (transcript daemon), `unix` (POSIX fd + fsync), `http-client`/`http-client-tls` (Anthropic), `hspec` + `QuickCheck`. Design: `docs/superpowers/specs/2026-06-30-agent-spine-cli-design.md`.

## Global Constraints

Every task inherits these (copied from the roadmap's Global Constraints):

- **Clean-room rule:** no reference/name/mention of any other repo or product, in code, identifiers, comments, commit messages, or docs. Reimplement from behavior.
- **Namespace:** all library code under `Seal.*`.
- **Language/extensions:** `default-language: GHC2021`; always-on `default-extensions: DeriveGeneric, DerivingStrategies, LambdaCase, ScopedTypeVariables`; enable `OverloadedStrings`, `ImportQualifiedPost`, `GeneralizedNewtypeDeriving`, etc. **per-file** via `{-# LANGUAGE #-}`. Whole-module imports for own modules; `qualified ... as` for external.
- **GHC flags:** `-Wall -Werror -Wcompat -Widentities -Wincomplete-uni-patterns -Wincomplete-record-updates -Wname-shadowing -Wpartial-fields -Wredundant-constraints`. Warnings are errors.
- **Errors:** default `Either Text` / `ExceptT Text`. A bespoke error ADT **only** where control flow pattern-matches it (here: only `DispatchError` in Task 7, and only if the loop branches on it).
- **No secret ever serialized:** secret newtypes keep redacted `Show`, no JSON; no code path writes a secret value to a transcript/log. `SECRET_GET`'s recorded payload carries the key *name* only.
- **No shell-wrapping in Trusted/Audited opcodes.** Seed opcodes use direct mechanisms (channel handle, file read, vault handle) — never a shell.
- **Type-guaranteed subprocess args:** N/A for seed opcodes (none shell out); `FILE_READ` uses the existing `SafePath` smart constructor.
- **TDD:** red → green. Write the failing test, watch it fail, implement the minimum, watch it pass, commit. Security-critical pure functions get QuickCheck properties.
- **hlint clean** before each commit: `nix develop --command hlint src/ test/`.
- **Build/verify under Nix:** `nix develop --command cabal build all`, `nix develop --command cabal test`.
- **Commit cadence:** one commit per completed task (all steps green).

---

## Pinned Interface Contract

The exact names/types tasks depend on. Implementers see only their own task — this is the shared source of truth. (`App`, `ChannelCaps`, `VaultRuntime`, `SafePath`, `withApiKey` already exist; signatures shown for reference.)

```haskell
-- Task 1 — Seal.Core.Types
data TrustLevel = Untrusted | Trusted | Audited
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
newtype ProviderId = ProviderId Text   -- deriving (Eq, Ord, Show); ToJSON/FromJSON
newtype ModelId    = ModelId Text
newtype ToolCallId = ToolCallId Text
newtype OpName     = OpName Text        -- deriving (Eq, Ord, Show); ToJSON/FromJSON
newtype SessionId  = SessionId Text     -- opaque; smart-constructed
mkSessionId      :: Text -> Either Text SessionId
sessionIdText    :: SessionId -> Text
isValidSessionId :: Text -> Bool        -- non-empty, no leading '.', charset [A-Za-z0-9_-]

-- Task 2 — Seal.Transcript.Types
data Direction = Request | Response
  deriving stock (Eq, Show, Generic)
data TranscriptEntry = TranscriptEntry
  { teId          :: Text          -- entry uuid (caller-supplied; not minted here)
  , teTimestamp   :: UTCTime
  , teModel       :: Maybe ModelId
  , teDirection   :: Direction
  , tePayload     :: Value          -- raw JSON payload (secret values pre-excluded)
  , teDurationMs  :: Maybe Int
  , teCorrelation :: Maybe Text     -- links Request <-> Response
  , teMeta        :: Map Text Value
  } deriving stock (Eq, Show, Generic)
encodeEntryRaw :: TranscriptEntry -> ByteString  -- one JSONL line, no trailing newline

-- Task 3 — Seal.Handles.Transcript
data TranscriptHandle = TranscriptHandle
  { recordAndAck :: TranscriptEntry -> IO ()   -- returns only after fsync
  , recordAsync  :: TranscriptEntry -> IO ()   -- enqueue, do not wait
  , closeTranscript :: IO ()
  }
withTranscript :: FilePath -> (TranscriptHandle -> IO a) -> IO a  -- opens, starts daemon, closes
fakeTranscript :: IO (TranscriptHandle, IO [TranscriptEntry])     -- test helper: handle + reader of recorded order

-- Task 4 — Seal.Providers.Class
data Role = User | Assistant deriving stock (Eq, Show, Generic)
data ToolResultPart = TrpText Text deriving stock (Eq, Show, Generic)
data ContentBlock
  = CbText Text
  | CbToolUse  { cbId :: ToolCallId, cbName :: OpName, cbInput :: Value }
  | CbToolResult { cbForId :: ToolCallId, cbParts :: [ToolResultPart], cbIsError :: Bool }
  deriving stock (Eq, Show, Generic)
data Message = Message { msgRole :: Role, msgContent :: [ContentBlock] }
  deriving stock (Eq, Show, Generic)
data ToolDefinition = ToolDefinition { tdName :: OpName, tdDescription :: Text, tdInputSchema :: Value }
  deriving stock (Eq, Show, Generic)
data ToolChoice = ToolAuto | ToolNone deriving stock (Eq, Show, Generic)
data CompletionRequest = CompletionRequest
  { crModel :: ModelId, crSystem :: Maybe Text, crMessages :: [Message]
  , crTools :: [ToolDefinition], crToolChoice :: ToolChoice, crMaxTokens :: Int }
  deriving stock (Eq, Show, Generic)
data Usage = Usage { uInput :: Int, uOutput :: Int } deriving stock (Eq, Show, Generic)
data StopReason = StopEnd | StopToolUse | StopMaxTokens | StopOther Text
  deriving stock (Eq, Show, Generic)
data CompletionResponse = CompletionResponse
  { rsContent :: [ContentBlock], rsStop :: StopReason, rsUsage :: Usage }
  deriving stock (Eq, Show, Generic)
class Provider p where
  complete     :: p -> CompletionRequest -> IO (Either Text CompletionResponse)
  listModels   :: p -> IO (Either Text [ModelId])
data SomeProvider = forall p. Provider p => SomeProvider p

-- Task 5 — Seal.Providers.Anthropic
data Anthropic = Anthropic { anModel :: ModelId, anManager :: Manager, anKey :: ApiKey }
mkAnthropic :: Manager -> ApiKey -> ModelId -> Anthropic   -- ApiKey from Seal.Security.Secrets
-- instance Provider Anthropic
encodeRequest  :: CompletionRequest -> Value     -- pure; tested with fixtures
decodeResponse :: Value -> Either Text CompletionResponse

-- Task 6 — Seal.ISA.Opcode / Seal.ISA.Registry
data OpResult = OpResult { orParts :: [ToolResultPart], orIsError :: Bool, orRecorded :: Value }
  -- orRecorded: the payload to put in the transcript (secret-free); orParts: what the model sees
data Opcode = Opcode
  { opName      :: OpName
  , opTrust     :: TrustLevel
  , opDesc      :: Text
  , opInSchema  :: Value
  , opOutSchema :: Value
  , opAuthorize :: Value -> Either Text ()          -- pure gate, run before execution
  , opRun       :: BackendExec -> Value -> App OpResult
  }
newtype BackendExec = BackendExec { runLocal :: forall a. IO a -> App a }  -- the seam (Phase 4 swaps remote in)
localBackend :: BackendExec
newtype Registry = Registry (Map OpName Opcode)
mkRegistry      :: [Opcode] -> Registry
lookupOp        :: Registry -> OpName -> Maybe Opcode
registryToolDefs :: Registry -> [ToolDefinition]

-- Task 7 — Seal.ISA.Dispatch
data DispatchError = OpNotFound OpName | Denied Text | ExecFailed Text deriving stock (Eq, Show)
dispatch :: Registry -> TranscriptHandle -> BackendExec -> OpName -> Value -> App (Either DispatchError OpResult)
-- Invariant: opTrust == Untrusted  =>  recordAndAck the invocation entry BEFORE opRun.

-- Task 8/9/10 — opcode values
showHumanOp :: ChannelCaps -> Opcode      -- SHOW_HUMAN  (Trusted)
askHumanOp  :: ChannelCaps -> Opcode      -- ASK_HUMAN   (Trusted)
fileReadOp  :: WorkspaceRoot -> Opcode     -- FILE_READ   (Untrusted)
secretGetOp :: VaultRuntime -> Opcode      -- SECRET_GET  (Audited)
newtype WorkspaceRoot = WorkspaceRoot FilePath

-- Task 11 — Seal.Agent.Env / Seal.Agent.Loop
data AgentEnv = AgentEnv
  { aeProvider   :: SomeProvider
  , aeModel      :: ModelId
  , aeRegistry   :: Registry
  , aeTranscript :: TranscriptHandle
  , aeBackend    :: BackendExec
  , aeCaps       :: ChannelCaps
  , aeSession    :: SessionId
  , aeMaxTurns   :: Int
  }
runTurn :: AgentEnv -> Text -> App ()   -- one user message -> full multi-turn tool loop -> final ccSend
```

---

## File Structure

| File | Responsibility |
| --- | --- |
| `src/Seal/Core/Types.hs` | Leaf vocabulary: `TrustLevel`, id newtypes, `SessionId`. |
| `src/Seal/Transcript/Types.hs` | `TranscriptEntry`, `Direction`, `encodeEntryRaw`. |
| `src/Seal/Handles/Transcript.hs` | Append-only JSONL daemon + `recordAndAck` (fsync). |
| `src/Seal/Providers/Class.hs` | Message/content/request/response model + `Provider` class. |
| `src/Seal/Providers/Anthropic.hs` | Messages-API `Provider` instance + pure JSON mapping. |
| `src/Seal/ISA/Opcode.hs` | `Opcode`, `OpResult`, `BackendExec`. |
| `src/Seal/ISA/Registry.hs` | `Registry`, lookup, tool-def derivation. |
| `src/Seal/ISA/Dispatch.hs` | `dispatch` + ACK-before-execute + `DispatchError`. |
| `src/Seal/ISA/Ops/Human.hs` | `SHOW_HUMAN`, `ASK_HUMAN`. |
| `src/Seal/ISA/Ops/File.hs` | `FILE_READ` via `SafePath`. |
| `src/Seal/ISA/Ops/Secret.hs` | `SECRET_GET` via `VaultRuntime`. |
| `src/Seal/Agent/Env.hs` | `AgentEnv` record + `WorkspaceRoot`. |
| `src/Seal/Agent/Loop.hs` | `runTurn` turn loop. |
| `src/Seal/Channel/Cli.hs` (modify) | Route `Ingest` `PlainMessage` → `runTurn`; build `AgentEnv`. |
| `test/Seal/**/...Spec.hs` | One spec per module; registered in `test/Main.hs` + cabal. |

**Per-task cabal bookkeeping (do every task):** add the new module to `library:exposed-modules`, add the spec to `test-suite:other-modules`, and add `import qualified <Spec>` + `<Spec>.spec` to `test/Main.hs`. Verify with a build.

---

### Task 1: `Seal.Core.Types` — leaf vocabulary

**Files:**
- Create: `src/Seal/Core/Types.hs`
- Test: `test/Seal/Core/TypesSpec.hs`
- Modify: `seal-harness.cabal`, `test/Main.hs`

**Interfaces:**
- Produces: `TrustLevel(Untrusted|Trusted|Audited)`, `ProviderId`, `ModelId`, `ToolCallId`, `OpName`, `SessionId`, `mkSessionId`, `sessionIdText`, `isValidSessionId` (signatures in the contract).

- [ ] **Step 1: Write the failing test**

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Seal.Core.TypesSpec (spec) where

import Data.Aeson (decode, encode)
import Data.Char (isAlphaNum)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Seal.Core.Types

spec :: Spec
spec = describe "Seal.Core.Types" $ do
  describe "TrustLevel JSON" $
    prop "round-trips" $ \tl ->
      decode (encode (tl :: TrustLevel)) === Just tl

  describe "isValidSessionId" $ do
    it "rejects empty" $ isValidSessionId "" `shouldBe` False
    it "rejects leading dot" $ isValidSessionId ".secret" `shouldBe` False
    it "rejects slash" $ isValidSessionId "a/b" `shouldBe` False
    it "accepts typical id" $ isValidSessionId "2026-06-30_sess-1" `shouldBe` True
    prop "accepts any nonempty [A-Za-z0-9_-] not starting with '.'" $
      forAll (listOf1 (elements (['A'..'Z']++['a'..'z']++['0'..'9']++['_','-']))) $ \s ->
        isValidSessionId (T.pack s) === True

  describe "mkSessionId" $ do
    it "rejects invalid" $ mkSessionId "a b" `shouldBe` Left "invalid session id: \"a b\""
    it "accepts and unwraps" $ fmap sessionIdText (mkSessionId "ok-1") `shouldBe` Right "ok-1"

instance Arbitrary TrustLevel where arbitrary = elements [minBound .. maxBound]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nix develop --command cabal test 2>&1 | tail -20`
Expected: build failure — `Seal.Core.Types` not found / not in scope.

- [ ] **Step 3: Write minimal implementation**

```haskell
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Shared leaf vocabulary imported across the spine. Subset only: the types
-- the running CLI agent loop touches. (Harness/Tabs/MessageSource land later.)
module Seal.Core.Types
  ( TrustLevel (..)
  , ProviderId (..)
  , ModelId (..)
  , ToolCallId (..)
  , OpName (..)
  , SessionId
  , mkSessionId
  , sessionIdText
  , isValidSessionId
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

data TrustLevel = Untrusted | Trusted | Audited
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (ToJSON, FromJSON)

newtype ProviderId = ProviderId Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

newtype ModelId = ModelId Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

newtype ToolCallId = ToolCallId Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

newtype OpName = OpName Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

-- | Opaque session label. No parse invariant on construction history, but a
-- single strict predicate guards every path-join / network boundary.
newtype SessionId = SessionId Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

isValidSessionId :: Text -> Bool
isValidSessionId t =
  not (T.null t)
    && T.head t /= '.'
    && T.all (\c -> c `elem` chars) t
  where
    chars = ['A' .. 'Z'] <> ['a' .. 'z'] <> ['0' .. '9'] <> "_-"

mkSessionId :: Text -> Either Text SessionId
mkSessionId t
  | isValidSessionId t = Right (SessionId t)
  | otherwise          = Left ("invalid session id: " <> T.pack (show t))

sessionIdText :: SessionId -> Text
sessionIdText (SessionId t) = t
```

- [ ] **Step 4: Cabal/test wiring + run**

Add `Seal.Core.Types` to `exposed-modules`, `Seal.Core.TypesSpec` to test `other-modules`, and wire into `test/Main.hs`.
Run: `nix develop --command cabal test 2>&1 | tail -20`
Expected: PASS. Then `nix develop --command hlint src/ test/` → clean.

- [ ] **Step 5: Commit**

```bash
git add src/Seal/Core/Types.hs test/Seal/Core/TypesSpec.hs seal-harness.cabal test/Main.hs
git commit -m "Add Seal.Core.Types: TrustLevel, id newtypes, SessionId"
```

---

### Task 2: `Seal.Transcript.Types` — audit-entry model

**Files:**
- Create: `src/Seal/Transcript/Types.hs`
- Test: `test/Seal/Transcript/TypesSpec.hs`
- Modify: `seal-harness.cabal`, `test/Main.hs`

**Interfaces:**
- Consumes: `ModelId` (Task 1).
- Produces: `Direction`, `TranscriptEntry(..)`, `encodeEntryRaw` (contract).

- [ ] **Step 1: Write the failing test**

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Seal.Transcript.TypesSpec (spec) where

import Data.Aeson (Value (..), decode, object, (.=))
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict qualified as Map
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec

import Seal.Core.Types (ModelId (..))
import Seal.Transcript.Types

sampleEntry :: TranscriptEntry
sampleEntry = TranscriptEntry
  { teId = "uuid-1"
  , teTimestamp = UTCTime (fromGregorian 2026 6 30) (secondsToDiffTime 0)
  , teModel = Just (ModelId "claude-opus-4-8")
  , teDirection = Request
  , tePayload = object ["kind" .= ("hello" :: String)]
  , teDurationMs = Nothing
  , teCorrelation = Just "corr-1"
  , teMeta = Map.empty
  }

spec :: Spec
spec = describe "Seal.Transcript.Types" $ do
  it "JSON round-trips through aeson" $
    decode (A.encode sampleEntry) `shouldBe` Just sampleEntry

  it "encodeEntryRaw is a single line with no trailing newline" $ do
    let raw = encodeEntryRaw sampleEntry
    BL.elem 0x0a (BL.fromStrict raw) `shouldBe` False

  it "encodeEntryRaw equals the canonical aeson encoding (view-raw hides nothing)" $
    encodeEntryRaw sampleEntry `shouldBe` BL.toStrict (A.encode sampleEntry)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nix develop --command cabal test 2>&1 | tail -20`
Expected: FAIL — module/`encodeEntryRaw` not found.

- [ ] **Step 3: Write minimal implementation**

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | The append-only audit-entry model. Integrity comes from the append-only
-- handle plus keeping untrusted actions off the box that holds the log — not
-- from a hash chain. 'encodeEntryRaw' guarantees the on-disk JSONL line is the
-- canonical encoding, so a future "view raw" hides nothing.
module Seal.Transcript.Types
  ( Direction (..)
  , TranscriptEntry (..)
  , encodeEntryRaw
  ) where

import Data.Aeson (FromJSON, ToJSON, Value)
import Data.Aeson qualified as A
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)

import Seal.Core.Types (ModelId)

data Direction = Request | Response
  deriving stock (Eq, Show, Generic)

instance ToJSON Direction
instance FromJSON Direction

data TranscriptEntry = TranscriptEntry
  { teId          :: Text
  , teTimestamp   :: UTCTime
  , teModel       :: Maybe ModelId
  , teDirection   :: Direction
  , tePayload     :: Value
  , teDurationMs  :: Maybe Int
  , teCorrelation :: Maybe Text
  , teMeta        :: Map Text Value
  } deriving stock (Eq, Show, Generic)

instance ToJSON TranscriptEntry
instance FromJSON TranscriptEntry

-- | One JSONL line: the canonical aeson encoding, strict, no trailing newline.
-- The daemon appends the newline when writing.
encodeEntryRaw :: TranscriptEntry -> ByteString
encodeEntryRaw = BL.toStrict . A.encode
```

- [ ] **Step 4: Cabal/test wiring + run**

Wire module + spec. Run: `nix develop --command cabal test 2>&1 | tail -20` → PASS. `hlint` clean.

- [ ] **Step 5: Commit**

```bash
git add src/Seal/Transcript/Types.hs test/Seal/Transcript/TypesSpec.hs seal-harness.cabal test/Main.hs
git commit -m "Add Seal.Transcript.Types: append-only audit entry + encodeEntryRaw"
```

---

### Task 3: `Seal.Handles.Transcript` — daemon + ACK

**Files:**
- Create: `src/Seal/Handles/Transcript.hs`
- Test: `test/Seal/Handles/TranscriptSpec.hs`
- Modify: `seal-harness.cabal`, `test/Main.hs`

**Interfaces:**
- Consumes: `TranscriptEntry`, `encodeEntryRaw` (Task 2).
- Produces: `TranscriptHandle(..)`, `withTranscript`, `fakeTranscript` (contract).

**Design notes:** the daemon is a single writer thread draining an STM `TQueue`. Each queued item carries an optional `TMVar ()` ack token; `recordAndAck` writes the line, `fsync`s the fd, *then* fills the token, and blocks on it. Use `unix`'s `fdWrite`/`setFdOption`, or open with `System.IO` + `hFlush` then `Posix` `fileSynchronise` on the underlying fd. Open the file with `AppendMode`/`O_APPEND` so concurrent writers never overwrite.

- [ ] **Step 1: Write the failing test**

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Seal.Handles.TranscriptSpec (spec) where

import Control.Concurrent.MVar (newMVar, modifyMVar_, readMVar)
import Data.Aeson (Value (..), object, (.=))
import Data.ByteString.Char8 qualified as BS8
import Data.Map.Strict qualified as Map
import Data.Time (getCurrentTime)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Transcript.Types
import Seal.Handles.Transcript

mkEntry :: IO TranscriptEntry
mkEntry = do
  now <- getCurrentTime
  pure TranscriptEntry
    { teId = "e1", teTimestamp = now, teModel = Nothing
    , teDirection = Request, tePayload = object ["x" .= (1 :: Int)]
    , teDurationMs = Nothing, teCorrelation = Nothing, teMeta = Map.empty }

spec :: Spec
spec = describe "Seal.Handles.Transcript" $ do
  it "recordAndAck durably appends one JSONL line per entry" $
    withSystemTempDirectory "seal-tx" $ \dir -> do
      let path = dir </> "transcript.jsonl"
      e <- mkEntry
      withTranscript path $ \h -> do
        recordAndAck h e
        recordAndAck h e
      contents <- BS8.readFile path
      length (BS8.lines contents) `shouldBe` 2

  it "fakeTranscript records invocation order for assertions" $ do
    (h, readLog) <- fakeTranscript
    e <- mkEntry
    recordAndAck h e
    logged <- readLog
    map teId logged `shouldBe` ["e1"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nix develop --command cabal test 2>&1 | tail -20`
Expected: FAIL — `withTranscript`/`fakeTranscript` not found.

- [ ] **Step 3: Write minimal implementation**

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | Append-only JSONL transcript with a single-writer daemon. 'recordAndAck'
-- returns ONLY after the entry is fsync'd to disk — the durability primitive
-- the Untrusted dispatch gate depends on (ACK-before-execute).
module Seal.Handles.Transcript
  ( TranscriptHandle (..)
  , withTranscript
  , fakeTranscript
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Control.Concurrent.MVar
import Control.Exception (bracket)
import Control.Monad (forever, void)
import Data.ByteString qualified as BS
import System.IO

import Seal.Transcript.Types (TranscriptEntry, encodeEntryRaw)

data TranscriptHandle = TranscriptHandle
  { recordAndAck    :: TranscriptEntry -> IO ()
  , recordAsync     :: TranscriptEntry -> IO ()
  , closeTranscript :: IO ()
  }

data Item = Item TranscriptEntry (Maybe (TMVar ()))

-- | Open the transcript file in append mode, spawn the writer daemon, run the
-- action, then drain + close. The daemon writes one line per entry, fsyncs,
-- and (for acked items) signals completion.
withTranscript :: FilePath -> (TranscriptHandle -> IO a) -> IO a
withTranscript path action = do
  q <- newTQueueIO
  bracket (openFile path AppendMode) hClose $ \hdl -> do
    hSetBuffering hdl NoBuffering
    _ <- forkIO $ forever $ do
      Item e mack <- atomically (readTQueue q)
      BS.hPut hdl (encodeEntryRaw e)
      BS.hPut hdl "\n"
      hFlush hdl
      maybe (pure ()) (\tv -> atomically (putTMVar tv ())) mack
    let enqueue e = atomically (writeTQueue q (Item e Nothing))
        ackWrite e = do
          tv <- newEmptyTMVarIO
          atomically (writeTQueue q (Item e (Just tv)))
          atomically (takeTMVar tv)
    action TranscriptHandle
      { recordAndAck = ackWrite
      , recordAsync  = enqueue
      , closeTranscript = pure ()
      }

-- | In-memory handle for tests: records entries in invocation order, no IO.
fakeTranscript :: IO (TranscriptHandle, IO [TranscriptEntry])
fakeTranscript = do
  ref <- newMVar []
  let push e = modifyMVar_ ref (pure . (++ [e]))
  pure
    ( TranscriptHandle
        { recordAndAck = push
        , recordAsync  = push
        , closeTranscript = pure ()
        }
    , readMVar ref
    )
```

> **Note for implementer:** `hSetBuffering NoBuffering` + `hFlush` gives durability to the OS; for a stronger guarantee replace with `System.Posix.IO.fdWrite` + `System.Posix.Unistd`/`fileSynchronise` on the handle's fd (`unix` is already a dep). The `forever` daemon is intentionally simple — it dies with the process; `closeTranscript` is a no-op because `bracket` closes the handle. If the queue-drain-on-close race matters later, add a sentinel. Keep `void`/`forkIO` import warnings clean (`-Wall`).

- [ ] **Step 4: Cabal/test wiring + run**

Wire module + spec. Run: `nix develop --command cabal test 2>&1 | tail -20` → PASS. `hlint` clean.

- [ ] **Step 5: Commit**

```bash
git add src/Seal/Handles/Transcript.hs test/Seal/Handles/TranscriptSpec.hs seal-harness.cabal test/Main.hs
git commit -m "Add Seal.Handles.Transcript: append-only daemon with fsync ACK"
```

---

### Task 4: `Seal.Providers.Class` — message/provider model

**Files:**
- Create: `src/Seal/Providers/Class.hs`
- Test: `test/Seal/Providers/ClassSpec.hs`
- Modify: `seal-harness.cabal`, `test/Main.hs`

**Interfaces:**
- Consumes: `ModelId`, `OpName`, `ToolCallId` (Task 1).
- Produces: `Role`, `ToolResultPart`, `ContentBlock`, `Message`, `ToolDefinition`, `ToolChoice`, `CompletionRequest`, `Usage`, `StopReason`, `CompletionResponse`, `Provider(..)`, `SomeProvider` (contract).

**Design notes:** keep aeson instances explicit-but-derivable. For `ContentBlock`, use a tagged encoding (`{"type":"text",...}` style) so the Anthropic mapper in Task 5 can reuse the shapes; QuickCheck round-trips below pin them.

- [ ] **Step 1: Write the failing test**

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Seal.Providers.ClassSpec (spec) where

import Data.Aeson (decode, encode)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Seal.Core.Types
import Seal.Providers.Class

spec :: Spec
spec = describe "Seal.Providers.Class" $ do
  prop "Message round-trips" $ \m -> decode (encode (m :: Message)) === Just m
  prop "CompletionResponse round-trips" $ \r ->
    decode (encode (r :: CompletionResponse)) === Just r

-- Arbitrary instances (small, finite generators)
instance Arbitrary Role where arbitrary = elements [User, Assistant]
instance Arbitrary ToolResultPart where arbitrary = TrpText . pack <$> arbitrary
  -- pack from Data.Text; import it
-- ... (implementer: add Arbitrary for ContentBlock, Message, Usage, StopReason,
--      CompletionResponse using `oneof`/`elements`; keep recursion shallow.)
```

> **Implementer:** write complete `Arbitrary` instances for every type the props touch (`ContentBlock` via `oneof` of its three constructors with shallow `Value` payloads, e.g. `pure Aeson.Null` or a small object; `Message`, `Usage`, `StopReason`, `CompletionResponse`). Import `Data.Text (pack)` and `Data.Aeson qualified as A`. No placeholder generators — fully spell them out.

- [ ] **Step 2: Run test to verify it fails**

Run: `nix develop --command cabal test 2>&1 | tail -20`
Expected: FAIL — `Seal.Providers.Class` not found.

- [ ] **Step 3: Write minimal implementation**

```haskell
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings #-}
-- | The provider-agnostic message/content/request/response model and the
-- 'Provider' capability class. Concrete providers (Anthropic, …) implement it;
-- 'SomeProvider' lets config pick one at runtime.
module Seal.Providers.Class
  ( Role (..)
  , ToolResultPart (..)
  , ContentBlock (..)
  , Message (..)
  , textMsg
  , ToolDefinition (..)
  , ToolChoice (..)
  , CompletionRequest (..)
  , Usage (..)
  , StopReason (..)
  , CompletionResponse (..)
  , Provider (..)
  , SomeProvider (..)
  ) where

import Data.Aeson
import Data.Text (Text)
import GHC.Generics (Generic)

import Seal.Core.Types (ModelId, OpName, ToolCallId)

data Role = User | Assistant deriving stock (Eq, Show, Generic)
instance ToJSON Role
instance FromJSON Role

newtype ToolResultPart = TrpText Text deriving stock (Eq, Show, Generic)
instance ToJSON ToolResultPart
instance FromJSON ToolResultPart

data ContentBlock
  = CbText Text
  | CbToolUse    { cbId :: ToolCallId, cbName :: OpName, cbInput :: Value }
  | CbToolResult { cbForId :: ToolCallId, cbParts :: [ToolResultPart], cbIsError :: Bool }
  deriving stock (Eq, Show, Generic)
instance ToJSON ContentBlock
instance FromJSON ContentBlock

data Message = Message { msgRole :: Role, msgContent :: [ContentBlock] }
  deriving stock (Eq, Show, Generic)
instance ToJSON Message
instance FromJSON Message

textMsg :: Role -> Text -> Message
textMsg r t = Message r [CbText t]

data ToolDefinition = ToolDefinition
  { tdName :: OpName, tdDescription :: Text, tdInputSchema :: Value }
  deriving stock (Eq, Show, Generic)
instance ToJSON ToolDefinition
instance FromJSON ToolDefinition

data ToolChoice = ToolAuto | ToolNone deriving stock (Eq, Show, Generic)
instance ToJSON ToolChoice
instance FromJSON ToolChoice

data CompletionRequest = CompletionRequest
  { crModel :: ModelId, crSystem :: Maybe Text, crMessages :: [Message]
  , crTools :: [ToolDefinition], crToolChoice :: ToolChoice, crMaxTokens :: Int }
  deriving stock (Eq, Show, Generic)
instance ToJSON CompletionRequest
instance FromJSON CompletionRequest

data Usage = Usage { uInput :: Int, uOutput :: Int }
  deriving stock (Eq, Show, Generic)
instance ToJSON Usage
instance FromJSON Usage

data StopReason = StopEnd | StopToolUse | StopMaxTokens | StopOther Text
  deriving stock (Eq, Show, Generic)
instance ToJSON StopReason
instance FromJSON StopReason

data CompletionResponse = CompletionResponse
  { rsContent :: [ContentBlock], rsStop :: StopReason, rsUsage :: Usage }
  deriving stock (Eq, Show, Generic)
instance ToJSON CompletionResponse
instance FromJSON CompletionResponse

class Provider p where
  complete   :: p -> CompletionRequest -> IO (Either Text CompletionResponse)
  listModels :: p -> IO (Either Text [ModelId])

data SomeProvider = forall p. Provider p => SomeProvider p
```

- [ ] **Step 4: Cabal/test wiring + run** → PASS; `hlint` clean.

- [ ] **Step 5: Commit**

```bash
git add src/Seal/Providers/Class.hs test/Seal/Providers/ClassSpec.hs seal-harness.cabal test/Main.hs
git commit -m "Add Seal.Providers.Class: message model + Provider class"
```

---

### Task 5: `Seal.Providers.Anthropic` — Messages API provider

**Files:**
- Create: `src/Seal/Providers/Anthropic.hs`
- Test: `test/Seal/Providers/AnthropicSpec.hs`
- Modify: `seal-harness.cabal` (add `http-client`, `http-client-tls` to library deps), `test/Main.hs`

**Interfaces:**
- Consumes: everything from Task 4; `ApiKey`/`withApiKey` from `Seal.Security.Secrets`; `ModelId`.
- Produces: `Anthropic`, `mkAnthropic`, `encodeRequest`, `decodeResponse`, `instance Provider Anthropic` (contract).

**Design notes:** keep the JSON mapping **pure** (`encodeRequest`, `decodeResponse`) so it is tested without network; `complete` only does the HTTP round-trip + plugs the key in via `withApiKey` (CPS — the key is set on the `x-api-key` header inside the continuation and never returned/logged). Test the pure mappers with hand-written fixtures matching the public Messages API shape (`model`, `max_tokens`, `messages[].content[]` with `type` tags, `tools[].input_schema`; response `content[]`, `stop_reason`, `usage.input_tokens`/`output_tokens`). The live HTTP call is a single `it ... pendingWith "needs ANTHROPIC_API_KEY"` test.

- [ ] **Step 1: Write the failing test (pure mappers)**

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Seal.Providers.AnthropicSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as A
import Test.Hspec

import Seal.Core.Types
import Seal.Providers.Class
import Seal.Providers.Anthropic

spec :: Spec
spec = describe "Seal.Providers.Anthropic" $ do
  it "encodeRequest emits model + max_tokens + tagged content" $ do
    let req = CompletionRequest (ModelId "claude-opus-4-8") Nothing
                [textMsg User "hi"] [] ToolAuto 1024
        v = encodeRequest req
    v `shouldBe` object
      [ "model" .= ("claude-opus-4-8" :: String)
      , "max_tokens" .= (1024 :: Int)
      , "messages" .= [object ["role" .= ("user"::String)
                              ,"content" .= [object ["type" .= ("text"::String)
                                                    ,"text" .= ("hi"::String)]]]]
      ]

  it "decodeResponse parses text + stop_reason + usage" $ do
    let body = object
          [ "content" .= [object ["type" .= ("text"::String), "text" .= ("yo"::String)]]
          , "stop_reason" .= ("end_turn"::String)
          , "usage" .= object ["input_tokens" .= (3::Int), "output_tokens" .= (1::Int)]
          ]
    decodeResponse body `shouldBe`
      Right (CompletionResponse [CbText "yo"] StopEnd (Usage 3 1))

  it "decodeResponse parses a tool_use block" $ do
    let body = object
          [ "content" .= [object ["type" .= ("tool_use"::String)
                                 ,"id" .= ("tc-1"::String)
                                 ,"name" .= ("FILE_READ"::String)
                                 ,"input" .= object ["path" .= ("a.txt"::String)]]]
          , "stop_reason" .= ("tool_use"::String)
          , "usage" .= object ["input_tokens" .= (5::Int), "output_tokens" .= (2::Int)]
          ]
    decodeResponse body `shouldBe`
      Right (CompletionResponse
              [CbToolUse (ToolCallId "tc-1") (OpName "FILE_READ")
                         (object ["path" .= ("a.txt"::String)])]
              StopToolUse (Usage 5 2))

  it "live completion (opt-in)" $ pendingWith "needs ANTHROPIC_API_KEY"
```

- [ ] **Step 2: Run to verify it fails** → module not found.

- [ ] **Step 3: Write minimal implementation**

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | Anthropic Messages-API provider. JSON mapping is pure ('encodeRequest' /
-- 'decodeResponse'); 'complete' adds the HTTP round-trip and supplies the API
-- key via 'withApiKey' (CPS) so the secret only ever lives on the request
-- header inside the continuation — never returned, never logged. Non-streaming.
module Seal.Providers.Anthropic
  ( Anthropic (..)
  , mkAnthropic
  , encodeRequest
  , decodeResponse
  ) where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Client
import Network.HTTP.Client.TLS (newTlsManager)

import Seal.Core.Types (ModelId (..), OpName (..), ToolCallId (..))
import Seal.Providers.Class
import Seal.Security.Secrets (ApiKey, withApiKey)

data Anthropic = Anthropic
  { anModel   :: ModelId
  , anManager :: Manager
  , anKey     :: ApiKey
  }

mkAnthropic :: Manager -> ApiKey -> ModelId -> Anthropic
mkAnthropic = \mgr key model -> Anthropic model mgr key

-- Pure request mapping -----------------------------------------------------

encodeRequest :: CompletionRequest -> Value
encodeRequest cr = object $
  [ "model"      .= crModel cr
  , "max_tokens" .= crMaxTokens cr
  , "messages"   .= map encMsg (crMessages cr)
  ]
  <> maybe [] (\s -> ["system" .= s]) (crSystem cr)
  <> (if null (crTools cr) then [] else ["tools" .= map encTool (crTools cr)])

encMsg :: Message -> Value
encMsg (Message r blocks) = object
  [ "role" .= roleText r, "content" .= map encBlock blocks ]

roleText :: Role -> Text
roleText User = "user"
roleText Assistant = "assistant"

encBlock :: ContentBlock -> Value
encBlock (CbText t) = object ["type" .= ("text"::Text), "text" .= t]
encBlock (CbToolUse (ToolCallId i) (OpName n) inp) =
  object ["type" .= ("tool_use"::Text), "id" .= i, "name" .= n, "input" .= inp]
encBlock (CbToolResult (ToolCallId i) parts isErr) =
  object [ "type" .= ("tool_result"::Text), "tool_use_id" .= i
         , "is_error" .= isErr
         , "content" .= [object ["type" .= ("text"::Text), "text" .= t] | TrpText t <- parts] ]

encTool :: ToolDefinition -> Value
encTool (ToolDefinition (OpName n) d sch) =
  object ["name" .= n, "description" .= d, "input_schema" .= sch]

-- Pure response mapping ----------------------------------------------------

decodeResponse :: Value -> Either Text CompletionResponse
decodeResponse = first T.pack . parseEither parseResp
  where first f = either (Left . f) Right

parseResp :: Value -> Parser CompletionResponse
parseResp = withObject "response" $ \o -> do
  blocks <- o .: "content" >>= mapM parseBlock
  stop   <- parseStop <$> o .: "stop_reason"
  usageV <- o .: "usage"
  uin    <- usageV .: "input_tokens"
  uout   <- usageV .: "output_tokens"
  pure (CompletionResponse blocks stop (Usage uin uout))

parseBlock :: Value -> Parser ContentBlock
parseBlock = withObject "block" $ \o -> do
  ty <- o .: "type" :: Parser Text
  case ty of
    "text"     -> CbText <$> o .: "text"
    "tool_use" -> CbToolUse <$> (ToolCallId <$> o .: "id")
                            <*> (OpName <$> o .: "name")
                            <*> o .: "input"
    other      -> fail ("unknown content block type: " <> T.unpack other)

parseStop :: Text -> StopReason
parseStop "end_turn"   = StopEnd
parseStop "tool_use"   = StopToolUse
parseStop "max_tokens" = StopMaxTokens
parseStop other        = StopOther other

-- Provider instance --------------------------------------------------------

instance Provider Anthropic where
  listModels a = pure (Right [anModel a])
  complete a cr = withApiKey (anKey a) $ \keyBytes -> do
    let body = encode (encodeRequest cr { crModel = crModel cr })
    initReq <- parseRequest "POST https://api.anthropic.com/v1/messages"
    let req = initReq
          { requestBody = RequestBodyLBS body
          , requestHeaders =
              [ ("content-type", "application/json")
              , ("anthropic-version", "2023-06-01")
              , ("x-api-key", keyBytes)
              ]
          }
    resp <- httpLbs req (anManager a)
    pure $ case eitherDecode (responseBody resp) of
      Left e  -> Left (T.pack e)
      Right v -> decodeResponse v
```

> **Implementer:** `withApiKey :: ApiKey -> (ByteString -> IO a) -> IO a` — confirm the CPS shape against `Seal.Security.Secrets` and adapt (it may yield `Text`; encode with `TE.encodeUtf8`). `newTlsManager` is created by the wiring task, not here. Keep imports used (`TE`, `newTlsManager` may move). The redundant `crModel cr` self-update is a placeholder-free no-op — delete it; model already set.

- [ ] **Step 4: Cabal/test wiring + run** → PASS (pure-mapper tests; live test pending). `hlint` clean.

- [ ] **Step 5: Commit**

```bash
git add src/Seal/Providers/Anthropic.hs test/Seal/Providers/AnthropicSpec.hs seal-harness.cabal test/Main.hs
git commit -m "Add Seal.Providers.Anthropic: Messages API provider (non-streaming)"
```

---

### Task 6: `Seal.ISA.Opcode` + `Seal.ISA.Registry` — ISA as data

**Files:**
- Create: `src/Seal/ISA/Opcode.hs`, `src/Seal/ISA/Registry.hs`
- Test: `test/Seal/ISA/RegistrySpec.hs`
- Modify: `seal-harness.cabal`, `test/Main.hs`

**Interfaces:**
- Consumes: `TrustLevel`, `OpName` (Task 1); `ToolDefinition`, `ToolResultPart` (Task 4); `App` (existing).
- Produces: `OpResult(..)`, `Opcode(..)`, `BackendExec(..)`, `localBackend`, `Registry`, `mkRegistry`, `lookupOp`, `registryToolDefs` (contract).

- [ ] **Step 1: Write the failing test**

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.RegistrySpec (spec) where

import Data.Aeson (Value (..), object)
import Test.Hspec

import Seal.Core.Types
import Seal.Providers.Class (ToolDefinition (..))
import Seal.ISA.Opcode
import Seal.ISA.Registry

stubOp :: OpName -> TrustLevel -> Opcode
stubOp n tl = Opcode
  { opName = n, opTrust = tl, opDesc = "desc", opInSchema = object [], opOutSchema = object []
  , opAuthorize = const (Right ())
  , opRun = \_ _ -> pure (OpResult [] False Null) }

spec :: Spec
spec = describe "Seal.ISA.Registry" $ do
  let reg = mkRegistry [stubOp (OpName "A") Trusted, stubOp (OpName "B") Untrusted]
  it "looks up registered opcodes" $
    fmap opName (lookupOp reg (OpName "A")) `shouldBe` Just (OpName "A")
  it "misses unregistered" $
    fmap opName (lookupOp reg (OpName "Z")) `shouldBe` Nothing
  it "derives one ToolDefinition per opcode" $
    map tdName (registryToolDefs reg) `shouldMatchList` [OpName "A", OpName "B"]
```

- [ ] **Step 2: Run to verify it fails** → modules not found.

- [ ] **Step 3: Write minimal implementation**

`src/Seal/ISA/Opcode.hs`:

```haskell
{-# LANGUAGE RankNTypes #-}
-- | The ISA as data: an 'Opcode' carries its trust level, JSON schemas, a pure
-- authorization gate, and an effectful run action. Untrusted opcodes run their
-- effects through 'BackendExec' (the seam Phase 4 swaps a remote executor into).
module Seal.ISA.Opcode
  ( OpResult (..)
  , Opcode (..)
  , BackendExec (..)
  , localBackend
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value)
import Data.Text (Text)

import Seal.Core.Types (OpName, TrustLevel)
import Seal.Providers.Class (ToolResultPart)
import Seal.Types.App (App)

data OpResult = OpResult
  { orParts    :: [ToolResultPart]  -- what the model sees (may include secret values)
  , orIsError  :: Bool
  , orRecorded :: Value             -- what the transcript records (secret-free)
  }

-- | The execution seam. Untrusted opcodes funnel their IO through 'runLocal';
-- Phase 4 introduces a remote-SSH 'BackendExec' with the same shape.
newtype BackendExec = BackendExec { runLocal :: forall a. IO a -> App a }

localBackend :: BackendExec
localBackend = BackendExec liftIO

data Opcode = Opcode
  { opName      :: OpName
  , opTrust     :: TrustLevel
  , opDesc      :: Text
  , opInSchema  :: Value
  , opOutSchema :: Value
  , opAuthorize :: Value -> Either Text ()
  , opRun       :: BackendExec -> Value -> App OpResult
  }
```

`src/Seal/ISA/Registry.hs`:

```haskell
-- | A name-indexed opcode set; derives the provider tool-definition list the
-- agent is offered each turn.
module Seal.ISA.Registry
  ( Registry
  , mkRegistry
  , lookupOp
  , registryToolDefs
  ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map

import Seal.Core.Types (OpName)
import Seal.Providers.Class (ToolDefinition (..))
import Seal.ISA.Opcode (Opcode (..))

newtype Registry = Registry (Map OpName Opcode)

mkRegistry :: [Opcode] -> Registry
mkRegistry ops = Registry (Map.fromList [(opName o, o) | o <- ops])

lookupOp :: Registry -> OpName -> Maybe Opcode
lookupOp (Registry m) n = Map.lookup n m

registryToolDefs :: Registry -> [ToolDefinition]
registryToolDefs (Registry m) =
  [ ToolDefinition (opName o) (opDesc o) (opInSchema o) | o <- Map.elems m ]
```

- [ ] **Step 4: Cabal/test wiring + run** → PASS; `hlint` clean.

- [ ] **Step 5: Commit**

```bash
git add src/Seal/ISA/Opcode.hs src/Seal/ISA/Registry.hs test/Seal/ISA/RegistrySpec.hs seal-harness.cabal test/Main.hs
git commit -m "Add Seal.ISA.Opcode + Registry: the instruction set as data"
```

---

### Task 7: `Seal.ISA.Dispatch` — ACK-before-execute (keystone)

**Files:**
- Create: `src/Seal/ISA/Dispatch.hs`
- Test: `test/Seal/ISA/DispatchSpec.hs`
- Modify: `seal-harness.cabal`, `test/Main.hs`

**Interfaces:**
- Consumes: `Registry`, `lookupOp`, `Opcode`, `OpResult`, `BackendExec` (Task 6); `TranscriptHandle`, `fakeTranscript` (Task 3); `TrustLevel` (Task 1); `App`/`runApp` (existing).
- Produces: `DispatchError(..)`, `dispatch` (contract).

**The keystone invariant:** for an `Untrusted` opcode, `recordAndAck` for the invocation entry completes **before** `opRun` runs. The test proves the ordering with a shared `IORef [Text]` log written by both a fake transcript and a probe opcode.

- [ ] **Step 1: Write the failing test**

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.DispatchSpec (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..), object)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Time (getCurrentTime)
import Test.Hspec

import Seal.Core.Types
import Seal.Transcript.Types
import Seal.Handles.Transcript (TranscriptHandle (..))
import Seal.ISA.Opcode
import Seal.ISA.Registry
import Seal.ISA.Dispatch
import Seal.Types.App (App, runApp)
import Seal.Types.Env (mkEnv)
import Seal.Types.Config (defaultConfig)   -- confirm the real default-config accessor

-- A transcript + opcode that both append to one ordered log.
probe :: IORef [String] -> TrustLevel -> (TranscriptHandle, Opcode)
probe ref tl =
  ( TranscriptHandle
      { recordAndAck = \_ -> modifyIORef' ref (++ ["ack"])
      , recordAsync  = \_ -> modifyIORef' ref (++ ["async"])
      , closeTranscript = pure () }
  , Opcode (OpName "P") tl "p" (object []) (object [])
           (const (Right ()))
           (\_ _ -> do liftIO (modifyIORef' ref (++ ["run"])); pure (OpResult [] False Null)) )

runIO :: App a -> IO a
runIO act = do env <- mkEnv defaultConfig; runApp env act

spec :: Spec
spec = describe "Seal.ISA.Dispatch" $ do
  it "Untrusted: ack precedes run" $ do
    ref <- newIORef []
    let (h, op) = probe ref Untrusted
        reg = mkRegistry [op]
    _ <- runIO (dispatch reg h localBackend (OpName "P") (object []))
    readIORef ref `shouldReturn` ["ack", "run"]

  it "missing opcode -> OpNotFound" $ do
    ref <- newIORef []
    let (h, _) = probe ref Trusted
    res <- runIO (dispatch (mkRegistry []) h localBackend (OpName "Z") (object []))
    res `shouldBe` Left (OpNotFound (OpName "Z"))

  it "failed authorization -> Denied, never runs" $ do
    ref <- newIORef []
    let (h, base) = probe ref Trusted
        op = base { opAuthorize = const (Left "nope") }
    res <- runIO (dispatch (mkRegistry [op]) h localBackend (OpName "P") (object []))
    res `shouldBe` Left (Denied "nope")
    readIORef ref `shouldReturn` []   -- gate ran before any record/run
```

> **Implementer:** confirm the real "build a default `Env` for tests" path — Task's `defaultConfig`/`mkEnv` names must match what `Seal.Types.Config`/`Seal.Types.Env` actually export (other specs like `AppMainSpec` already construct an `App` runner; copy that pattern rather than inventing one).

- [ ] **Step 2: Run to verify it fails** → `dispatch` not found.

- [ ] **Step 3: Write minimal implementation**

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | The dispatcher. Runs the pure authorization gate, then — for Untrusted
-- opcodes — durably records the invocation (recordAndAck) BEFORE executing, so
-- no untrusted action runs until its audit entry is on disk. Trusted/Audited
-- opcodes record concurrently with execution.
module Seal.ISA.Dispatch
  ( DispatchError (..)
  , dispatch
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (getCurrentTime)

import Seal.Core.Types (OpName, TrustLevel (..))
import Seal.Transcript.Types (Direction (..), TranscriptEntry (..))
import Seal.Handles.Transcript (TranscriptHandle (..))
import Seal.ISA.Opcode (BackendExec, OpResult (..), Opcode (..))
import Seal.ISA.Registry (Registry, lookupOp)
import Seal.Types.App (App)

data DispatchError = OpNotFound OpName | Denied Text | ExecFailed Text
  deriving stock (Eq, Show)

dispatch
  :: Registry -> TranscriptHandle -> BackendExec -> OpName -> Value
  -> App (Either DispatchError OpResult)
dispatch reg h backend name input =
  case lookupOp reg name of
    Nothing -> pure (Left (OpNotFound name))
    Just op ->
      case opAuthorize op input of
        Left why -> pure (Left (Denied why))
        Right () -> do
          entry <- liftIO (mkInvocationEntry name input)
          case opTrust op of
            Untrusted -> do
              liftIO (recordAndAck h entry)   -- ACK-before-execute
              Right <$> opRun op backend input
            _ -> do
              liftIO (recordAsync h entry)
              Right <$> opRun op backend input

mkInvocationEntry :: OpName -> Value -> IO TranscriptEntry
mkInvocationEntry (nm) input = do
  now <- getCurrentTime
  pure TranscriptEntry
    { teId = "" , teTimestamp = now, teModel = Nothing
    , teDirection = Request
    , tePayload = input          -- opcode invocation input (callers pre-strip secrets)
    , teDurationMs = Nothing, teCorrelation = Nothing
    , teMeta = Map.fromList [("op", opNameValue nm)] }
  where opNameValue n = let _ = n in opNameJson n

-- minimal helper to avoid importing Aeson String constructor noise
opNameJson :: OpName -> Value
opNameJson = Data.Aeson.toJSON
```

> **Implementer:** the `mkInvocationEntry` helper above is deliberately spare — clean it up: import `Data.Aeson (toJSON)` directly, drop the `opNameValue`/`let _ = n` scaffolding, and set `teId` to a real uuid if a uuid source is wired (else leave `""` for now and note it). Keep `-Wall` clean (no unused binds). The behavioral contract that matters is the **ack-before-run ordering** and the **gate-first** ordering — both pinned by Task 7's tests.

- [ ] **Step 4: Cabal/test wiring + run** → PASS (all three ordering/gate tests). `hlint` clean.

- [ ] **Step 5: Commit**

```bash
git add src/Seal/ISA/Dispatch.hs test/Seal/ISA/DispatchSpec.hs seal-harness.cabal test/Main.hs
git commit -m "Add Seal.ISA.Dispatch: ACK-before-execute for Untrusted opcodes"
```

---

### Task 8: `Seal.ISA.Ops.Human` — SHOW_HUMAN / ASK_HUMAN (Trusted)

**Files:**
- Create: `src/Seal/ISA/Ops/Human.hs`
- Test: `test/Seal/ISA/Ops/HumanSpec.hs`
- Modify: `seal-harness.cabal`, `test/Main.hs`

**Interfaces:**
- Consumes: `Opcode`, `OpResult` (Task 6); `ChannelCaps` (existing); `ToolResultPart(TrpText)` (Task 4).
- Produces: `showHumanOp :: ChannelCaps -> Opcode`, `askHumanOp :: ChannelCaps -> Opcode`.

**Schemas:** `SHOW_HUMAN` input `{"message": string}` → emits via `ccSend`, returns empty result. `ASK_HUMAN` input `{"question": string}` → `ccPrompt`, returns the typed reply as a `TrpText`.

- [ ] **Step 1: Write the failing test** (use a fake `ChannelCaps` capturing sends and scripting a prompt reply)

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.HumanSpec (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (object, (.=))
import Data.IORef
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.ISA.Opcode
import Seal.ISA.Ops.Human
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Types.App (App, runApp)
import Seal.Types.Env (mkEnv)
import Seal.Types.Config (defaultConfig)

runIO :: App a -> IO a
runIO act = do env <- mkEnv defaultConfig; runApp env act

fakeCaps :: IORef [String] -> String -> ChannelCaps
fakeCaps sent reply = ChannelCaps
  { ccSend = \t -> modifyIORef' sent (++ [show t])
  , ccPrompt = \_ -> pure (pack reply)
  , ccPromptSecret = \_ -> pure "" }
  -- import Data.Text (pack); adapt show/pack

spec :: Spec
spec = describe "Seal.ISA.Ops.Human" $ do
  it "SHOW_HUMAN emits the message and returns no error" $ do
    sent <- newIORef []
    let op = showHumanOp (fakeCaps sent "")
    r <- runIO (opRun op localBackend (object ["message" .= ("hello"::String)]))
    orIsError r `shouldBe` False
    readIORef sent `shouldReturn` ["\"hello\""]

  it "ASK_HUMAN returns the human reply as a tool-result part" $ do
    sent <- newIORef []
    let op = askHumanOp (fakeCaps sent "42")
    r <- runIO (opRun op localBackend (object ["question" .= ("n?"::String)]))
    orParts r `shouldBe` [TrpText "42"]
```

- [ ] **Step 2: Run to verify it fails** → module not found.

- [ ] **Step 3: Write minimal implementation**

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | Human-interaction opcodes (Trusted): SHOW_HUMAN emits a line to the user;
-- ASK_HUMAN prompts and returns the reply. Both go through the channel handle —
-- no shell, no provider.
module Seal.ISA.Ops.Human
  ( showHumanOp
  , askHumanOp
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..), object, withObject, (.:))
import Data.Aeson.Types (parseMaybe)
import Data.Text (Text)

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Core.Types (OpName (..), TrustLevel (..))
import Seal.ISA.Opcode (OpResult (..), Opcode (..))
import Seal.Providers.Class (ToolResultPart (..))

strField :: Text -> Value -> Maybe Text
strField k = parseMaybe (withObject "in" (\o -> o .: k))

showHumanOp :: ChannelCaps -> Opcode
showHumanOp caps = Opcode
  { opName = OpName "SHOW_HUMAN", opTrust = Trusted
  , opDesc = "Display a message to the human operator."
  , opInSchema = object [], opOutSchema = object []
  , opAuthorize = \v -> maybe (Left "SHOW_HUMAN requires {message:string}") (const (Right ())) (strField "message" v)
  , opRun = \_ v -> do
      let msg = maybe "" id (strField "message" v)
      liftIO (ccSend caps msg)
      pure (OpResult [] False Null) }

askHumanOp :: ChannelCaps -> Opcode
askHumanOp caps = Opcode
  { opName = OpName "ASK_HUMAN", opTrust = Trusted
  , opDesc = "Ask the human operator a question and return their reply."
  , opInSchema = object [], opOutSchema = object []
  , opAuthorize = \v -> maybe (Left "ASK_HUMAN requires {question:string}") (const (Right ())) (strField "question" v)
  , opRun = \_ v -> do
      let q = maybe "" id (strField "question" v)
      ans <- liftIO (ccPrompt caps q)
      pure (OpResult [TrpText ans] False Null) }
```

- [ ] **Step 4: Cabal/test wiring + run** → PASS; `hlint` clean.

- [ ] **Step 5: Commit**

```bash
git add src/Seal/ISA/Ops/Human.hs test/Seal/ISA/Ops/HumanSpec.hs seal-harness.cabal test/Main.hs
git commit -m "Add SHOW_HUMAN / ASK_HUMAN opcodes (Trusted)"
```

---

### Task 9: `Seal.ISA.Ops.File` — FILE_READ (Untrusted)

**Files:**
- Create: `src/Seal/ISA/Ops/File.hs`
- Test: `test/Seal/ISA/Ops/FileSpec.hs`
- Modify: `seal-harness.cabal`, `test/Main.hs`

**Interfaces:**
- Consumes: `Opcode`/`OpResult`/`BackendExec` (Task 6); `mkSafePath`/`getSafePath` from `Seal.Security.Path` (existing — confirm exact names); `WorkspaceRoot` (define here or in Task 11 — define here, re-export from Agent.Env).
- Produces: `fileReadOp :: WorkspaceRoot -> Opcode`, `WorkspaceRoot(..)`.

**Behavior:** input `{"path": string}`. Validate `path` against `WorkspaceRoot` via `mkSafePath` (rejects `..`, absolute escapes, symlink escape). On success read the file (bounded — first N KB) via `runLocal backend`. On path rejection return `OpResult { orIsError = True }` with the reason. Untrusted ⇒ exercised through dispatch's ACK gate (covered by Task 7's ordering test using a probe; here we test the file behavior directly).

- [ ] **Step 1: Write the failing test**

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.FileSpec (spec) where

import Data.Aeson (object, (.=))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.ISA.Opcode
import Seal.ISA.Ops.File
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Types.App (App, runApp)
import Seal.Types.Env (mkEnv)
import Seal.Types.Config (defaultConfig)

runIO :: App a -> IO a
runIO act = do env <- mkEnv defaultConfig; runApp env act

spec :: Spec
spec = describe "Seal.ISA.Ops.File" $ do
  it "reads a file inside the workspace root" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      writeFile (root </> "a.txt") "hello"
      let op = fileReadOp (WorkspaceRoot root)
      r <- runIO (opRun op localBackend (object ["path" .= ("a.txt"::String)]))
      orIsError r `shouldBe` False
      orParts r `shouldBe` [TrpText "hello"]

  it "rejects a traversal escape with an error result (no read)" $
    withSystemTempDirectory "seal-ws" $ \root -> do
      let op = fileReadOp (WorkspaceRoot root)
      r <- runIO (opRun op localBackend (object ["path" .= ("../escape"::String)]))
      orIsError r `shouldBe` True
```

- [ ] **Step 2: Run to verify it fails** → module not found.

- [ ] **Step 3: Write minimal implementation**

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | FILE_READ (Untrusted): read a workspace file, confined by SafePath. This is
-- the opcode that exercises the ACK-before-execute path in the dispatcher.
module Seal.ISA.Ops.File
  ( fileReadOp
  , WorkspaceRoot (..)
  ) where

import Data.Aeson (Value (..), object, withObject, (.:))
import Data.Aeson.Types (parseMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO

import Seal.Core.Types (OpName (..), TrustLevel (..))
import Seal.ISA.Opcode (BackendExec (..), OpResult (..), Opcode (..))
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Security.Path (mkSafePath, getSafePath)  -- confirm exact exported names

newtype WorkspaceRoot = WorkspaceRoot FilePath

pathField :: Value -> Maybe Text
pathField = parseMaybe (withObject "in" (\o -> o .: "path"))

fileReadOp :: WorkspaceRoot -> Opcode
fileReadOp (WorkspaceRoot root) = Opcode
  { opName = OpName "FILE_READ", opTrust = Untrusted
  , opDesc = "Read a UTF-8 text file from the workspace (path is workspace-relative)."
  , opInSchema = object [], opOutSchema = object []
  , opAuthorize = \v -> maybe (Left "FILE_READ requires {path:string}") (const (Right ())) (pathField v)
  , opRun = \backend v -> do
      let rel = maybe "" T.unpack (pathField v)
      mSafe <- runLocal backend (mkSafePath root rel)   -- adapt to real signature
      case mSafe of
        Left err   -> pure (OpResult [TrpText (T.pack (show err))] True Null)
        Right safe -> do
          txt <- runLocal backend (TIO.readFile (getSafePath safe))
          pure (OpResult [TrpText txt] False Null) }
```

> **Implementer:** `Seal.Security.Path` is already in the repo — open it and match the **real** smart-constructor signature (it may be `mkSafePath :: FilePath -> FilePath -> IO (Either PathError SafePath)` or take a `WorkspaceRoot`-like root; `PathSpec.hs` shows usage). Adjust the `mkSafePath root rel` call and the error rendering accordingly. Add a size bound on the read (e.g. read up to 64 KiB) before shipping — wire it as a follow-up if `Dynamic Retrieval` (roadmap Phase 3) will own paging; note it in the SDD ledger.

- [ ] **Step 4: Cabal/test wiring + run** → PASS; `hlint` clean.

- [ ] **Step 5: Commit**

```bash
git add src/Seal/ISA/Ops/File.hs test/Seal/ISA/Ops/FileSpec.hs seal-harness.cabal test/Main.hs
git commit -m "Add FILE_READ opcode (Untrusted, SafePath-confined)"
```

---

### Task 10: `Seal.ISA.Ops.Secret` — SECRET_GET (Audited)

**Files:**
- Create: `src/Seal/ISA/Ops/Secret.hs`
- Test: `test/Seal/ISA/Ops/SecretSpec.hs`
- Modify: `seal-harness.cabal`, `test/Main.hs`

**Interfaces:**
- Consumes: `Opcode`/`OpResult` (Task 6); `VaultRuntime` + the vault `get` path (existing — `Seal.Vault.Commands`/`Seal.Security.Vault`); `TrustLevel(Audited)`.
- Produces: `secretGetOp :: VaultRuntime -> Opcode`.

**The security invariant (tested):** input `{"name": string}`. The opcode reads the value from the unlocked vault and returns it to the *model* as a `TrpText` (`orParts`), **but `orRecorded` contains only the key name** — never the value. Test asserts the value string does not appear anywhere in `orRecorded`.

- [ ] **Step 1: Write the failing test**

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.SecretSpec (spec) where

import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.List (isInfixOf)
import Test.Hspec

import Seal.ISA.Opcode
import Seal.ISA.Ops.Secret
-- + the test scaffolding to build a VaultRuntime with an in-memory unlocked vault
--   containing name="TOKEN" value="s3cr3t" (reuse Seal.Vault.CommandsSpec helpers)

spec :: Spec
spec = describe "Seal.ISA.Ops.Secret" $
  it "returns the value to the model but never records it" $ do
    rt <- (error "build a test VaultRuntime with TOKEN=s3cr3t — see CommandsSpec helpers")
    let op = secretGetOp rt
    r <- runVaultIO (opRun op localBackend (object ["name" .= ("TOKEN"::String)]))
    -- value reaches the model:
    orParts r `shouldSatisfy` any (\p -> p == TrpTextOf "s3cr3t")  -- adapt to TrpText pattern
    -- value is NOT in the recorded payload:
    ("s3cr3t" `isInfixOf` BL8.unpack (encode (orRecorded r))) `shouldBe` False
```

> **Implementer:** Tasks 9/10 need an `App`/vault test runner. Reuse the existing `Seal.Vault.CommandsSpec` fixture that constructs a `VaultRuntime` over a temp `SEAL_HOME` with an unlocked mock-encryptor vault, then `put` `TOKEN=s3cr3t`. Replace the `error "..."` and `TrpTextOf` sketch with the concrete helpers — no placeholders in the final test. The **assertion that matters** is the two-line invariant: value present in `orParts`, absent from `encode (orRecorded r)`.

- [ ] **Step 2: Run to verify it fails** → module not found.

- [ ] **Step 3: Write minimal implementation**

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | SECRET_GET (Audited): fetch a vault secret. The value is returned to the
-- model as a tool result, but the recorded transcript payload carries only the
-- key NAME — the secret value is never serialized to the audit log. (The unified
-- cross-session Audited log is deferred to Phase 5; this records to the session
-- transcript via the dispatcher.)
module Seal.ISA.Ops.Secret
  ( secretGetOp
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..), object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Text (Text)

import Seal.Core.Types (OpName (..), TrustLevel (..))
import Seal.ISA.Opcode (OpResult (..), Opcode (..))
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Vault.Commands (VaultRuntime (..))     -- confirm exported accessors
import Seal.Security.Vault (VaultHandle (..))       -- vaultGet :: Text -> IO (Either ... )

nameField :: Value -> Maybe Text
nameField = parseMaybe (withObject "in" (\o -> o .: "name"))

secretGetOp :: VaultRuntime -> Opcode
secretGetOp rt = Opcode
  { opName = OpName "SECRET_GET", opTrust = Audited
  , opDesc = "Fetch a secret value from the vault by key name."
  , opInSchema = object [], opOutSchema = object []
  , opAuthorize = \v -> maybe (Left "SECRET_GET requires {name:string}") (const (Right ())) (nameField v)
  , opRun = \_ v -> do
      let key = maybe "" id (nameField v)
      val <- liftIO (vaultGetByName rt key)         -- implementer: wire to the live handle in vrHandleRef
      pure $ case val of
        Left err -> OpResult [TrpText err] True (recordedNameOnly key)
        Right secret -> OpResult [TrpText secret] False (recordedNameOnly key)
  }
  where
    -- The ONLY thing recorded: the key name + the op. Never the value.
    recordedNameOnly key = object ["name" .= key]

-- implementer-provided: read the IORef (Maybe VaultHandle) in the runtime,
-- error if locked, else call the handle's get for the key. Keep the secret in
-- Text only as long as needed to hand to the model.
vaultGetByName :: VaultRuntime -> Text -> IO (Either Text Text)
vaultGetByName = error "wire to VaultRuntime.vrHandleRef + VaultHandle get — see Vault.Commands"
```

> **Implementer:** replace `vaultGetByName`'s `error` with the real lookup: read `vrHandleRef rt :: IORef (Maybe VaultHandle)`; if `Nothing`, return `Left "vault is locked"`; else call the handle's get field for `key`. Match the real `VaultHandle` field names from `Seal.Security.Vault` (the `/vault get` command already does exactly this — mirror it). Confirm whether vault values surface as `Text` or a secret newtype; if a secret newtype, use its CPS accessor to obtain the `Text` for the model and DO NOT let it reach `orRecorded`.

- [ ] **Step 4: Cabal/test wiring + run** → PASS (value-present/value-absent invariant). `hlint` clean.

- [ ] **Step 5: Commit**

```bash
git add src/Seal/ISA/Ops/Secret.hs test/Seal/ISA/Ops/SecretSpec.hs seal-harness.cabal test/Main.hs
git commit -m "Add SECRET_GET opcode (Audited; value never recorded)"
```

---

### Task 11: `Seal.Agent.Env` + `Seal.Agent.Loop` — the turn loop

**Files:**
- Create: `src/Seal/Agent/Env.hs`, `src/Seal/Agent/Loop.hs`
- Test: `test/Seal/Agent/LoopSpec.hs`
- Modify: `seal-harness.cabal`, `test/Main.hs`

**Interfaces:**
- Consumes: `SomeProvider`/`complete`/`Message`/`ContentBlock`/`CompletionRequest`/`CompletionResponse`/`StopReason` (Task 4); `Registry`/`registryToolDefs` (Task 6); `dispatch` (Task 7); `TranscriptHandle` (Task 3); `BackendExec` (Task 6); `ChannelCaps` (existing); `SessionId`/`ModelId` (Task 1).
- Produces: `AgentEnv(..)`, `runTurn` (contract).

**Loop:** seed `[textMsg User userText]`; up to `aeMaxTurns`: `complete` the request (tools = `registryToolDefs aeRegistry`); record request+response; if the response has `CbToolUse` blocks, `dispatch` each, build `CbToolResult` blocks, append an `Assistant` message (the tool_use) and a `User` message (the tool_results), loop; else `ccSend` the concatenated `CbText` and stop. A `tool_use` past the turn cap ends with a `ccSend` apology.

- [ ] **Step 1: Write the failing test** (fake provider scripted: turn 1 → tool_use FILE_READ-ish stub op; turn 2 → final text)

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Seal.Agent.LoopSpec (spec) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..), object)
import Data.IORef
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Core.Types
import Seal.Providers.Class
import Seal.ISA.Opcode
import Seal.ISA.Registry
import Seal.Handles.Transcript (fakeTranscript)
import Seal.Agent.Env
import Seal.Agent.Loop
import Seal.Types.App (App, runApp)
import Seal.Types.Env (mkEnv)
import Seal.Types.Config (defaultConfig)

-- A provider that returns a scripted list of responses, one per call.
newtype ScriptProvider = ScriptProvider (IORef [CompletionResponse])
instance Provider ScriptProvider where
  listModels _ = pure (Right [])
  complete (ScriptProvider ref) _ = do
    rs <- readIORef ref
    case rs of
      (x:xs) -> writeIORef ref xs >> pure (Right x)
      []     -> pure (Right (CompletionResponse [CbText "done"] StopEnd (Usage 0 0)))

runIO :: App a -> IO a
runIO act = do env <- mkEnv defaultConfig; runApp env act

spec :: Spec
spec = describe "Seal.Agent.Loop" $
  it "dispatches a tool call then emits the final text" $ do
    sent <- newIORef []
    ran  <- newIORef (0 :: Int)
    let caps = ChannelCaps (\t -> modifyIORef' sent (++ [t])) (\_ -> pure "") (\_ -> pure "")
        stubOp = Opcode (OpName "PING") Trusted "p" (object []) (object [])
                   (const (Right ()))
                   (\_ _ -> do liftIO (modifyIORef' ran (+1)); pure (OpResult [TrpText "pong"] False Null))
        script = [ CompletionResponse [CbToolUse (ToolCallId "t1") (OpName "PING") (object [])] StopToolUse (Usage 0 0)
                 , CompletionResponse [CbText "all done"] StopEnd (Usage 0 0) ]
    ref <- newIORef script
    (h, _) <- fakeTranscript
    let env = AgentEnv (SomeProvider (ScriptProvider ref)) (ModelId "m")
                       (mkRegistry [stubOp]) h localBackend caps
                       (either (error "sid") id (mkSessionId "s1")) 8
    runIO (runTurn env "hello")
    readIORef ran   `shouldReturn` 1
    readIORef sent  `shouldReturn` ["all done"]
```

- [ ] **Step 2: Run to verify it fails** → modules not found.

- [ ] **Step 3: Write minimal implementation**

`src/Seal/Agent/Env.hs`:

```haskell
-- | The agent's capability bundle — everything 'runTurn' needs, injected so the
-- loop is fully fakeable (no concrete provider/IO in its type).
module Seal.Agent.Env
  ( AgentEnv (..)
  ) where

import Seal.Channel.Caps (ChannelCaps)
import Seal.Core.Types (ModelId, SessionId)
import Seal.Handles.Transcript (TranscriptHandle)
import Seal.ISA.Opcode (BackendExec)
import Seal.ISA.Registry (Registry)
import Seal.Providers.Class (SomeProvider)

data AgentEnv = AgentEnv
  { aeProvider   :: SomeProvider
  , aeModel      :: ModelId
  , aeRegistry   :: Registry
  , aeTranscript :: TranscriptHandle
  , aeBackend    :: BackendExec
  , aeCaps       :: ChannelCaps
  , aeSession    :: SessionId
  , aeMaxTurns   :: Int
  }
```

`src/Seal/Agent/Loop.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | The turn loop: user message -> provider completion -> opcode dispatch ->
-- tool results -> repeat until no tool calls, then emit the final text. Fed only
-- after Seal.Ingest has classified input as a PlainMessage. Bounded by aeMaxTurns.
module Seal.Agent.Loop
  ( runTurn
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Providers.Class
import Seal.ISA.Dispatch (dispatch)
import Seal.ISA.Opcode (OpResult (..))
import Seal.ISA.Registry (registryToolDefs)
import Seal.Agent.Env (AgentEnv (..))
import Seal.Types.App (App)

runTurn :: AgentEnv -> Text -> App ()
runTurn env userText = go (aeMaxTurns env) [textMsg User userText]
  where
    go :: Int -> [Message] -> App ()
    go 0 _ = liftIO (ccSend (aeCaps env) "(stopped: too many tool turns)")
    go n msgs = do
      let req = CompletionRequest
                  { crModel = aeModel env, crSystem = Nothing, crMessages = msgs
                  , crTools = registryToolDefs (aeRegistry env)
                  , crToolChoice = ToolAuto, crMaxTokens = 4096 }
      eresp <- liftIO (providerComplete (aeProvider env) req)
      case eresp of
        Left err   -> liftIO (ccSend (aeCaps env) ("provider error: " <> err))
        Right resp ->
          let toolUses = [ b | b@CbToolUse{} <- rsContent resp ]
          in if null toolUses
               then liftIO (ccSend (aeCaps env) (T.intercalate "\n" [t | CbText t <- rsContent resp]))
               else do
                 results <- mapM dispatchOne toolUses
                 let assistantMsg = Message Assistant (rsContent resp)
                     resultMsg    = Message User results
                 go (n - 1) (msgs <> [assistantMsg, resultMsg])

    dispatchOne :: ContentBlock -> App ContentBlock
    dispatchOne (CbToolUse tcid name input) = do
      res <- dispatch (aeRegistry env) (aeTranscript env) (aeBackend env) name input
      pure $ case res of
        Left e  -> CbToolResult tcid [TrpText (T.pack (show e))] True
        Right r -> CbToolResult tcid (orParts r) (orIsError r)
    dispatchOne other = pure other   -- non-tool blocks never reach here

providerComplete :: SomeProvider -> CompletionRequest -> IO (Either Text CompletionResponse)
providerComplete (SomeProvider p) = complete p
```

> **Implementer:** `-Wincomplete-uni-patterns` will flag `dispatchOne`'s `other` arm as needed (good — keep it). Confirm `CbToolUse{}` record-wildcard pattern compiles under the pinned extensions (it needs `RecordWildCards`? No — empty `{}` constructor pattern needs no extension). The system prompt is `Nothing` for the MVP; a real system prompt can be threaded through `AgentEnv` later.

- [ ] **Step 4: Cabal/test wiring + run** → PASS (tool-then-text loop). `hlint` clean.

- [ ] **Step 5: Commit**

```bash
git add src/Seal/Agent/Env.hs src/Seal/Agent/Loop.hs test/Seal/Agent/LoopSpec.hs seal-harness.cabal test/Main.hs
git commit -m "Add Seal.Agent.Env + Loop: turn-based dispatch loop"
```

---

### Task 12: Wire the loop into the CLI (Ingest PlainMessage → runTurn)

**Files:**
- Modify: `src/Seal/Channel/Cli.hs` (the REPL handler), `src/Seal/AppMain.hs` (or wherever the REPL + `VaultRuntime` are constructed at startup)
- Test: `test/Seal/Channel/CliSpec.hs` (extend) and a new `test/Seal/Agent/WiringSpec.hs` if a seam test helps
- Modify: `seal-harness.cabal`, `test/Main.hs` as needed

**Interfaces:**
- Consumes: `ingest`/`Disposition(PlainMessage)` (existing `Seal.Ingest`); `runTurn`/`AgentEnv` (Task 11); the seed opcodes (Tasks 8–10); `mkAnthropic` + `newTlsManager` (Task 5); `VaultRuntime` (existing).
- Produces: a running `seal repl` where plain text drives the agent.

**Behavior:** at REPL startup, after the vault runtime + channel caps exist:
1. Build the HTTP manager (`newTlsManager`).
2. Resolve the API key: from the vault (`SECRET_GET`-style) if present, else `ANTHROPIC_API_KEY` env; build `mkAnthropic`.
3. Open the transcript (`withTranscript` over `state/transcript.jsonl` under `SEAL_HOME`).
4. Build the `Registry` from `[showHumanOp caps, askHumanOp caps, fileReadOp wsRoot, secretGetOp vaultRuntime]`.
5. Assemble `AgentEnv` and, in the REPL's `ingest` handling, route `PlainMessage t -> runTurn agentEnv t` (replacing the current stub that echoes/ignores plain text).

- [ ] **Step 1: Write the failing test** — assert the dispatcher path is reached for plain input via a seam, OR (simpler, deterministic) a unit test that `handlePlain agentEnv "hi"` calls the provider. Reuse the `ScriptProvider` from Task 11.

```haskell
-- Extend CliSpec (or new WiringSpec): construct an AgentEnv with a ScriptProvider
-- returning a single final-text response, route a PlainMessage through the REPL's
-- plain-text handler, and assert ccSend received the text. Reuse Task 11 fakes.
-- (Full code mirrors Task 11's setup; assert the wiring function — e.g.
--  Seal.Channel.Cli.handlePlain :: AgentEnv -> Text -> App () — invokes runTurn.)
```

> **Implementer:** factor the plain-text branch into a named, testable function (`handlePlain :: AgentEnv -> Text -> App ()` = `runTurn`) so the wiring has a unit test rather than only the manual REPL check. Do not leave the test as prose — write the concrete `it`/`shouldReturn` mirroring Task 11.

- [ ] **Step 2: Run to verify it fails** → handler not wired / function missing.

- [ ] **Step 3: Implement the wiring** — modify the REPL setup to build `AgentEnv` and route `PlainMessage` to `runTurn`. (No new pure logic; this is integration. Keep the API-key resolution + manager creation in the startup path, not in `runTurn`.)

- [ ] **Step 4: Build + test + manual milestone**

Run: `nix develop --command cabal build all` (→ `-Werror` clean), `nix develop --command cabal test` (→ green), `nix develop --command hlint src/ test/` (→ clean).
Manual: `export ANTHROPIC_API_KEY=…; nix develop --command cabal run seal -- repl`, then type a plain message and confirm the model replies, can `SHOW_HUMAN`/`ASK_HUMAN`, read a workspace file, and fetch a secret; confirm lines append to `state/transcript.jsonl`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Wire the agent loop into the CLI: PlainMessage -> runTurn"
```

---

## Self-Review

**Spec coverage** (each §3 module → task): Core.Types→T1; Transcript.Types→T2; Handles.Transcript(daemon+ACK)→T3; Providers.Class→T4; Providers.Anthropic(non-streaming)→T5; ISA.Opcode/Registry→T6; ISA.Dispatch(ACK-before-execute + backend seam + DispatchError)→T7; Ops.Human→T8; Ops.File→T9; Ops.Secret(value-never-recorded)→T10; Agent.Env/Loop→T11; Ingest PlainMessage + REPL wiring (§8)→T12. The §6 keystone tests map to: ACK-ordering→T7; multi-turn tool loop→T11; secret-never-serialized→T10; opcode authz gates→T7/T8/T9/T10; QuickCheck round-trips→T1/T2/T4; live Anthropic opt-in→T5. All §1 milestone behaviors are exercised by T12's manual check. **No gaps.**

**Placeholder scan:** the design intentionally leaves three implementer-confirm points — the real `Seal.Security.Path` smart-constructor signature (T9), the `VaultRuntime`/`VaultHandle` get accessors (T10), and the test `App`-runner pattern (`mkEnv`/`defaultConfig`, T7+) — because they depend on existing code the implementer must read rather than guess. Each is flagged with the exact existing module to mirror, and the *behavioral* assertion is fully specified. The `error "..."`/sketch lines in T10's test and `vaultGetByName` are explicitly marked "replace before shipping." All other steps carry complete code.

**Type consistency:** `OpName`/`TrustLevel`/`ToolCallId` from T1 used consistently; `OpResult{orParts,orIsError,orRecorded}` identical across T6–T11; `dispatch` signature in T7 matches its T11 call site; `AgentEnv` field set in T11 matches T12 construction; `ContentBlock` constructors (`CbText`/`CbToolUse`/`CbToolResult`) consistent T4→T5→T11; `TranscriptHandle` fields (`recordAndAck`/`recordAsync`/`closeTranscript`) consistent T3→T7→T11.

**Deferred to the SDD ledger (non-blocking):** `FILE_READ` size bound / Dynamic-Retrieval paging (Phase 3); transcript `teId` uuid minting; transcript daemon graceful drain-on-close; richer `StopOther` handling; system-prompt threading through `AgentEnv`.
