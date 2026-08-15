# Tool Call Timeout, Abort, and Retry — Implementation Plan

> **Status:** Draft for review (round 2 — revised after design-gate round 1)
> **Date:** 2026-08-14
> **Scope:** Every opcode invocation via `Seal.ISA.Dispatch.dispatch` gets timeout + abort + retry protection, following the OpenCode / Claude Code model.

## Design-Gate Round 1 Results (all 5 reviewers NEEDS_REVISION)

Round 1 surfaced 14 blockers (all verified against the codebase). This
revision addresses each; a `Blocker Resolution` note follows the section
that resolves each. The blockers, in summary:

1. **`App`/`IO` bridging unspecified** — `App` is `ReaderT Env (KatipContextT IO)` (Types/App.hs:20), not `ReaderT AppEnv IO`. The wrapper takes `IO`, the opcode runs in `App`. (Architect B1)
2. **Web `/stop` has no path to `AbortFlag`** — `ApiDeps` has no `AgentEnv`; it's per-turn. Need a per-session registry. (Designer B1)
3. **Per-call `timeout` in microseconds — wrong unit for LLM** — JSON wire unit must be seconds. (Designer B2)
4. **Schema advertisement of `timeout` unspecified** — model can't discover the override. (PM B1)
5. **`extractPerCallTimeout` validation underspecified** — no property for non-negative / integer rejection. (Security B1)
6. **`AbortFlag` constructor export status unspecified** — must be unexported. (Security B2)
7. **`async` is NOT in library `build-depends`** — only in test-suite (cabal:275). (CTO B1)
8. **Wrong config module named** — plan said `Seal.Types.Config.hs` (configuration-tools, no TOML); actual TOML config is `Seal.Config.File.hs` (`RuntimeConfig` + `runtimeConfigCodec`). (CTO B2)
9. **Dispatch call sites not fully enumerated** — 4 production + 9 test sites; plan missed 3 of 4 production callers. (CTO B3)
10. **AgentEnv construction blast radius not enumerated** — 27 test constructions + `mkSessionAgentEnv` (Cli.hs:238, 20-param) + Worker. (CTO B4)
11. **Cabal + test/Main.hs merge points not enumerated.** (CTO B5)
12. **Tmux/vault bypass process-group kill** — `readTmuxNoInput` (Tmux.hs:187) + vault `age` (Backend.hs:53) use `withCreateProcess` directly. (Architect S1)
13. **`orRecorded` must carry only error class, not full IO error text** — add a test. (Security mitigation)
14. **`opAuthorize` interaction with generic `timeout` field** — verified: authorize functions use `parseMaybe`-based field extraction (e.g. Shell.hs:42 `commandField`, File.hs:146 `pathField`), so extra `timeout` fields are tolerated. No blocker — resolved by codebase verification.

## Goal

Prevent any tool call from hanging the agent session indefinitely. Every opcode dispatch — Trusted or Untrusted, shell or file read or web fetch — gets:

1. **Timeout**: a per-call deadline. If the opcode doesn't return before it expires, the process is killed and a structured error is returned to the model.
2. **Abort**: a session-level cancellation signal. When the user stops the run (or the session is reset), in-flight tool calls are killed immediately.
3. **Retry**: on transient failures (timeout, IO exception), the dispatch is retried with exponential backoff. Up to 3 attempts.

This is the OpenCode / Claude Code approach: simple, foreground-only, no background process registry. Every tool call is synchronous from the agent's perspective.

## Current State (What's Broken)

**No timeout exists anywhere.** The execution path is:

```
AgentLoop.dispatchOne
  → Seal.ISA.Dispatch.dispatch
    → uoRun op untrustedIO input          (Untrusted)
    → toRun op backend input              (Trusted)
      → uioShellExec / uioBinExec / etc.
        → runLocalFixedArgv / runFixedArgv
          → withCreateProcess + waitForProcess   ← BLOCKS FOREVER
```

`waitForProcess` has no timeout. A command like `nix develop --command cabal build` that hangs, a server the model accidentally starts, a `cat` on a named pipe that blocks for input — any of these will hang the entire session permanently. The model can't cancel it. The user can't cancel it (short of killing the whole process).

There is also no retry. A transient SSH blip or a one-off IO error fails the tool call immediately and the model has to decide whether to retry manually.

## Proposed Approach

### Design Principles

1. **Wrap at the dispatch boundary, not at each opcode.** `Seal.ISA.Dispatch.dispatch` is the single chokepoint — every tool call goes through it. Wrap there. Individual opcodes don't need to know about timeout/abort/retry.

2. **Timeout is per-call, configurable.** The LLM can pass a `timeout` field (**in seconds** — see Blocker Resolution #3) in the tool input. If absent, use the configured default. Hard cap prevents absurd values.

3. **Abort is session-scoped.** A per-session `AbortFlag` (`IORef Bool`) keyed by `SessionId` in a `SessionAbortRegistry` (mirrors `SessionLocks` at Seal.Session.Lock:56 — see Blocker Resolution #2). The channel/user sets it to abort; the dispatch loop checks it. No per-thread signaling complexity (we're single-threaded per session in the agent loop).

4. **Retry with exponential backoff.** Only on transient failures: timeout, IO exceptions. Not on authorization denials, not on `ExecError` (host-key mismatch, not-implemented, etc.). 3 attempts max, base delay 2s, factor 2x.

5. **Process-group killing (exec arms only).** Shell commands spawn children. Kill the whole process group, not just the immediate child. SIGTERM → grace period → SIGKILL. **Scope note (Blocker Resolution #12):** the `Tmux` and vault `age` subprocess paths bypass the Local/Remote exec arms and use `withCreateProcess` directly (Tmux.hs:187, Backend.hs:53). They get the dispatch-level timeout (the wrapper is around `toRun`) but NOT process-group killing — on cancel, their bracket only closes handles. A timed-out `tmux`/`age` child leaks until it exits on its own. This is an accepted v1 limitation (documented in Risks §); Task 3 optionally extends `withManagedProcess` to `Seal.Harness.Tmux` if the leak risk is deemed unacceptable.

6. **No background execution.** Explicitly out of scope. If the model needs to run something long, it passes a larger timeout. This is the Claude Code / OpenCode philosophy. (Future work: a background job registry — noted as Open Question §4.)

### Architecture

```
AgentEnv
  +-- aeAbortFlag :: AbortFlag          (NEW — per-session abort signal; from SessionAbortRegistry)
  +-- aeToolTimeout :: ToolTimeoutConfig  (NEW — default + max + retry config)

SessionAbortRegistry (NEW — mirrors SessionLocks at Seal.Session.Lock:56)
  +-- TVar (Map SessionId AbortFlag)     (lazily created per session)

Seal.ISA.Dispatch.dispatch
  → checkAbort                              (NEW — fail-fast if already aborted)
  → recordAndAck (for Untrusted)
  → runWithTimeoutAbortRetry                (NEW — the wrapper, IO-level)
    → attempt N:
      → raceNext: runApp env (opcodeRun)  vs  timeoutDelay  vs  abortSignal
      → on timeout: killProcessGroup, mark transient, retry
      → on abort: killProcessGroup, return Aborted
      → on normal exit: return result
      → on IO exception: mark transient, retry
    → on retry: sleep (base * factor^attempt), loop
  → return result
```

### Blocker Resolution #1: `App`/`IO` bridging

**The problem (Architect B1):** `App` is `ReaderT Env (KatipContextT IO)` (Types/App.hs:20). The opcode run functions `uoRun`/`toRun` return `App OpResult` (Dispatch.hs:68,73,79). The proposed wrapper `runWithTimeoutAbortRetry :: ... -> IO (Either ToolError a) -> IO (Either ToolError a)` takes an `IO` action — an `App` action cannot be passed directly.

**The fix:** The wrapper takes an `IO (Either ToolError OpResult)` action. At the dispatch call site (inside `App`), we capture the current `Env` via `ask`, then re-enter `App` inside the worker thread using `runApp env (...)`:

```haskell
-- Inside dispatch (which runs in App):
env <- ask
let ioAction :: IO (Either ToolError OpResult)
    ioAction = do
      r <- runApp env (uoRun op untrustedIO input)   -- re-enter App in the worker
      pure (Right r)   -- OpResult semantic errors are NOT ToolErrors
runWithTimeoutAbortRetry cfg flag timeout ioAction
```

**Katip context caveat:** `runApp` (Types/App.hs:40) constructs a fresh `KatipContextT` from `envLogger`. The worker thread does NOT inherit the calling thread's Katip logging context (LogContexts/Namespace are rebuilt from `slContext`/`slNamespace`). This means: log statements inside the opcode run in the worker thread use the *base* namespace, not any `katipAddContext`/`localKatipNamespace` overlays from the caller. This is acceptable — the dispatch path does not rely on thread-local Katip context for correctness (the session id is carried in `AgentEnv`, not in Katip context). Documented in the `Seal.Tools.Exec.Timeout` module header.

**The wrapper signature is `IO`-level** (not `MonadUnliftIO`-polymorphic) to keep it testable without a full `AppEnv` (the race logic is pure IO; only the action being raced needs `App`). The `App`-vs-`IO` boundary is at the call site, not inside the wrapper.

### Blocker Resolution #2: Web `/stop` path to `AbortFlag`

**The problem (Designer B1):** `ApiDeps` (API.hs:99) has no `AgentEnv` — it's constructed per-turn inside `handleSend` (Send.hs:259). `ApiDeps` cannot reach `aeAbortFlag`.

**The fix:** Introduce `SessionAbortRegistry`, mirroring `SessionLocks` (Seal.Session.Lock:56 — a `TVar (Map SessionId (MVar ()))` lazily created per session):

```haskell
-- In Seal.Tools.Exec.Abort (Task 2):
newtype SessionAbortRegistry = SessionAbortRegistry (TVar (Map SessionId AbortFlag))

newSessionAbortRegistry :: IO SessionAbortRegistry
lookupOrCreateAbortFlag :: SessionAbortRegistry -> SessionId -> IO AbortFlag
setSessionAbort :: SessionAbortRegistry -> SessionId -> IO ()
clearSessionAbort :: SessionAbortRegistry -> SessionId -> IO ()
```

**Wiring:**
- `ApiDeps` gains `adAbortReg :: SessionAbortRegistry` (API.hs:99). The `POST /api/sessions/:id/stop` handler calls `setSessionAbort (adAbortReg deps) sid` — no `AgentEnv` needed.
- `SendDeps` gains `sdAbortReg :: SessionAbortRegistry` (Send.hs:148, alongside the existing `sdLocks :: SessionLocks` at Send.hs:193). The `handleSend` path looks up the per-session `AbortFlag` via `lookupOrCreateAbortFlag (sdAbortReg deps) sid` and passes it into `mkSessionAgentEnv` as `aeAbortFlag`.
- `ChannelDeps` (Channels/Loop.hs:169) gains `cdAbortReg :: SessionAbortRegistry` for the inbox-channel path.
- The CLI (`mkSessionAgentEnv` at Cli.hs:238) receives the `AbortFlag` directly (the CLI owns one session).
- `Serve.hs` constructs one `SessionAbortRegistry` at startup and threads it into `ApiDeps` + `SendDeps` + `ChannelDeps`.

This mirrors the existing `SessionLocks`/`ReplyRegistry` threading exactly (those are already on `SendDeps`/`ApiDeps`).

### Blocker Resolution #3: `timeout` field unit

**The problem (Designer B2):** Microseconds in the LLM-facing JSON is error-prone (`{"timeout": 120000000}` — off-by-three-zeros mistakes).

**The fix:** The JSON wire unit is **seconds**. Internally, `ToolTimeoutConfig` stores microseconds (to match `System.Timeout`). The conversion is hidden inside `extractPerCallTimeout`:

```haskell
-- The JSON field "timeout" is in SECONDS (an integer).
-- extractPerCallTimeout converts to microseconds internally.
extractPerCallTimeout :: Value -> ToolTimeoutConfig -> Microseconds
-- reads "timeout" as an Int (seconds), rejects non-int/negative/zero (→ default),
-- clamps to max, multiplies by 1_000_000 to get microseconds.
```

A `newtype Microseconds = Microseconds Int` carries the unit in the type, preventing micros/seconds confusion across the boundary. The model-facing error message renders the timeout in seconds ("timed out after 120s"), not microseconds.

### Blocker Resolution #4: Schema advertisement

**The problem (PM B1):** The model can't discover the `timeout` field — no task owns updating `uoInSchema`.

**The fix:** Task 8 (renamed "Model-facing error messages + schema advertisement + transcript metadata") adds a deliverable: update `uoInSchema` for `SHELL_EXEC`, `BIN_EXEC`, and `WEB_EXTRACT` to declare the optional `timeout` field (in seconds, with a description like "Per-call timeout in seconds; if the tool doesn't finish in this time, it's killed. Default 120, max 600."). A spec asserts the field is present in those three opcodes' schemas. Other opcodes may add it incrementally; the three named are where it's most relevant.

### Detailed Design

#### 1. `Seal.Tools.Timeout` (new module — pure config + retry logic)

Pure config types + the retry logic skeleton. **No IO.** No dependency on `App`/`Env`.

```haskell
-- | A timeout value in microseconds. Carries the unit in the type to prevent
-- micros/seconds confusion across the JSON boundary (Blocker Resolution #3).
newtype Microseconds = Microseconds Int
  deriving stock (Eq, Ord, Show)
  deriving newtype (Num)

-- | Configuration for tool call timeout/retry behavior.
data ToolTimeoutConfig = ToolTimeoutConfig
  { ttcDefaultSeconds  :: Int    -- ^ default per-call timeout (default: 120)
  , ttcMaxSeconds      :: Int    -- ^ hard cap (default: 600)
  , ttcRetryMax        :: Int    -- ^ max retry attempts (default: 3)
  , ttcRetryBaseMicros :: Int   -- ^ base delay between retries (default: 2_000_000 = 2s)
  , ttcRetryFactor     :: Double -- ^ backoff multiplier (default: 2.0)
  , ttcKillGraceMicros :: Int   -- ^ SIGTERM→SIGKILL grace period (default: 5_000_000 = 5s)
  , ttcMaxOutputBytes  :: Int    -- ^ bounded output cap (default: 50_000)
  }
```

Configurable via `config.toml` under `[tool_timeout]` (in `Seal.Config.File.hs` — see Blocker Resolution #8). The per-call `timeout` field in the tool input JSON is **in seconds**, clamped to `ttcMaxSeconds`.

**`ToolError` ADT:**

```haskell
data ToolError
  = ToolTimeout Int          -- ^ the timeout that was in effect (seconds, for display)
  | ToolAborted              -- ^ user/session cancellation
  | ToolIOError Text          -- ^ transient IO failure (error CLASS only — see Blocker Resolution #13)
  | ToolRetriesExhausted ToolError  -- ^ wrapper after max retries
  deriving stock (Eq, Show)
```

**Pure functions:**

```haskell
defaultToolTimeoutConfig :: ToolTimeoutConfig

-- | Extract the per-call timeout from the tool input JSON. The "timeout" field
-- is in SECONDS (Blocker Resolution #3). Validation (Blocker Resolution #5):
--   - absent / null / non-integer → default
--   - negative / zero → default
--   - positive > max → clamp to max
--   - positive in [1, max] → as-is
-- Returns microseconds (via Microseconds newtype).
extractPerCallTimeout :: Value -> ToolTimeoutConfig -> Microseconds

-- | Compute the retry delay: base * factor^attempt. Pure. Overflow-safe
-- (guards against Int overflow at large attempt counts — see CTO S3).
computeRetryDelay :: ToolTimeoutConfig -> Int -> Microseconds

-- | Whether to retry on a given ToolError.
--   ToolTimeout → yes; ToolIOError → yes;
--   ToolAborted → no (user cancelled — respect immediately);
--   ToolRetriesExhausted → no (already exhausted);
--   (Right _ is not a ToolError — semantic errors aren't retried.)
shouldRetry :: ToolError -> Bool

-- | Render the error class for the audit log (Blocker Resolution #13).
-- Returns ONLY the class string: "timeout" | "aborted" | "io" | "retries_exhausted".
-- NEVER the full ToolIOError Text payload.
errorClass :: ToolError -> Text
```

**QuickCheck properties (Task 1):**
- `extractPerCallTimeout` output is always in `[Microseconds 1, Microseconds (ttcMaxSeconds * 1_000_000)]` — never negative, never zero, never exceeds max (Blocker Resolution #5).
- `extractPerCallTimeout` absent field → default; non-integer (string, float, null) → default; negative → default; zero → default.
- `computeRetryDelay` is always positive and monotonically increasing in the attempt number (for `factor >= 1.0`).
- `computeRetryDelay` overflow-safety: for `attempt < 30` and `base < 10^7`, the result fits in `Int` (no wraparound to negative).

#### 2. `Seal.Tools.Exec.Abort` (new module — abort flag + registry)

The abort signal type, helpers, and the per-session registry (Blocker Resolution #2).

```haskell
-- | A session-scoped abort flag. Set by the channel/user to cancel
-- in-flight tool calls. Checked by the dispatch wrapper.
-- Blocker Resolution #6: the constructor is NOT exported — only the
-- smart constructors and accessors below (mirrors UntrustedIO).
newtype AbortFlag = AbortFlag (IORef Bool)
  -- constructor NOT in the export list

newAbortFlag :: IO AbortFlag
isAborted :: AbortFlag -> IO Bool
setAbort :: AbortFlag -> IO ()
clearAbort :: AbortFlag -> IO ()

-- | Poll isAborted every N microseconds, returns True if aborted.
-- Used as the third race participant.
waitForAbort :: AbortFlag -> Int -> IO Bool

-- | Per-session abort registry (mirrors SessionLocks at Seal.Session.Lock:56).
-- Blocker Resolution #2.
newtype SessionAbortRegistry = SessionAbortRegistry (TVar (Map SessionId AbortFlag))

newSessionAbortRegistry :: IO SessionAbortRegistry
lookupOrCreateAbortFlag :: SessionAbortRegistry -> SessionId -> IO AbortFlag
setSessionAbort :: SessionAbortRegistry -> SessionId -> IO ()
clearSessionAbort :: SessionAbortRegistry -> SessionId -> IO ()
```

**Module export list (Task 2) — constructor excluded (Blocker Resolution #6):**

```haskell
module Seal.Tools.Exec.Abort
  ( AbortFlag
  , newAbortFlag
  , isAborted
  , setAbort
  , clearAbort
  , waitForAbort
  , SessionAbortRegistry
  , newSessionAbortRegistry
  , lookupOrCreateAbortFlag
  , setSessionAbort
  , clearSessionAbort
  ) where
```

Wired into `AgentEnv` as `aeAbortFlag` (looked up from `SessionAbortRegistry` per session). The channel layer (Signal, CLI, Web) calls `setAbort` / `setSessionAbort` when the user sends a stop/interrupt. The dispatch wrapper polls `isAborted` during the race. `clearAbort` fires once at `runTurn` entry (before any tool call) — a mid-turn abort keeps the flag set until the next turn begins.

**Tests (Task 2):**
- set → `isAborted` returns True; clear → False; `waitForAbort` returns True after set.
- `SessionAbortRegistry`: `lookupOrCreateAbortFlag` twice for the same `SessionId` returns the same flag; `setSessionAbort` makes `isAborted` True for that session; `clearSessionAbort` resets it; different sessions are independent.

#### 3. Process-group spawning + kill helper

**Files:**
- `src/Seal/Tools/Exec/Local.hs` (modify)
- `src/Seal/Tools/Exec/Remote.hs` (modify — the SSH arm)
- `src/Seal/Tools/Exec/UntrustedIO.hs` (modify)
- `src/Seal/Harness/Tmux.hs` (optionally modify — see Blocker Resolution #12)
- `test/Seal/Tools/Exec/LocalSpec.hs` (new or extend)

**Deliverables:**
- `killProcessGroup :: Int -> Int -> IO ()` — POSIX: `signalProcessGroup sigTERM pgid` → `threadDelay grace` → check `getProcessGroupIDOf` / `kill -0` → `signalProcessGroup sigKILL pgid` if still alive. Windows: `taskkill /PID /T /F`.
- `withManagedProcess :: CreateProcess -> (ProcessHandle -> Handle -> Handle -> IO a) -> IO a` — the bracket that spawns with `create_group = True` and kills the group on cleanup.
- Modify `runLocalFixedArgv` and `runFixedArgv` to use `withManagedProcess` instead of `withCreateProcess`. **Preserve the existing `try @IOError` error handling** (Local.hs:105-115 maps IOError → `Left ExecNotImplemented` — the 127-vs-IOError distinction; CTO S5).
- **Bounded reap (Architect S4):** the cleanup's `waitForProcess` (to reap the zombie) is bounded — a non-blocking `getProcessExitCode` poll loop with a small deadline (1s), not an unbounded `waitForProcess`. If the child doesn't die within 1s of SIGKILL, log a warning and move on (the zombie is reaped by the OS init process eventually).
- Integration test: spawn `sleep 30`, kill the worker thread, verify the child is dead (no orphan). Bound the test with a hspec `timeout` (CTO S4) — reduce the sleep to `sleep 2` and a 5s test timeout.

**Blocker Resolution #12 (Tmux/vault):** The `Tmux.hs:187` and `Vault/Backend.hs:53` subprocess paths use `withCreateProcess` directly and bypass `withManagedProcess`. They get the dispatch-level timeout (the wrapper is around `toRun`) but NOT process-group killing. On cancel, their bracket only closes handles — a timed-out `tmux`/`age` child leaks. **v1 decision:** document this as an accepted limitation (Risks §). Task 3 adds an *optional* deliverable: extend `withManagedProcess` to `Seal.Harness.Tmux` if the leak risk is deemed unacceptable during implementation. The vault `age` path is left as-is (age invocations are short-lived crypto operations unlikely to hang; the timeout wrapper still fires).

#### 4. Bounded output capture

**Files:**
- `src/Seal/Tools/Exec/Local.hs` (modify)
- `src/Seal/Tools/Exec/Remote.hs` (modify)
- `src/Seal/Tools/Exec/UntrustedIO.hs` (modify)

**Deliverables:**
- `readBounded :: Handle -> Int -> IO (Text, Bool)` — reads at most N bytes, returns `(content, wasTruncated)`. Simple cap for v1 (head/tail window is a future improvement — the truncation marker + the redirect-to-file recovery pattern mitigates).
- Wire into `withManagedProcess` action: read stdout/stderr with `readBounded` instead of `hGetContents`.
- Truncation marker in output: `"\n[output truncated at N bytes — redirect to a file and FILE_READ with pagination for full output]"` (PM suggestion: hint at the recovery workflow so the model learns the pattern).
- Test: spawn `seq 1 100000`, verify output is bounded + truncation marker present. Bound the test (CTO S4) — `seq 1 10000` is enough to exceed 50KB and completes fast.

#### 5. The three-way race + retry wrapper

**Files:**
- `src/Seal/Tools/Exec/Timeout.hs` (new — the IO-level race logic)
- `test/Seal/Tools/Exec/TimeoutSpec.hs` (new)

**Blocker Resolution #1 (App/IO bridging):** The wrapper is `IO`-level. The `App`-vs-`IO` boundary is at the dispatch call site (inside `App`), where `runApp env (uoRun ...)` re-enters `App` in the worker thread. The wrapper itself never imports `Seal.Types.App` (no `App` dependency — keeps it testable).

**Deliverables:**

```haskell
-- | The three-way race + retry wrapper. IO-level (Blocker Resolution #1).
-- The action being raced is `IO (Either ToolError a)` — the call site
-- bridges from `App` via `runApp env (...)`.
runWithTimeoutAbortRetry
  :: ToolTimeoutConfig
  -> AbortFlag
  -> Microseconds          -- ^ per-call timeout (already clamped)
  -> IO (Either ToolError a)   -- ^ the opcode action (bridged from App at the call site)
  -> IO (Either ToolError a)
```

**Three-way race mechanics (Architect S5):** `Control.Concurrent.Async` provides two-way `race`. A three-way race is implemented as nested `race`:

```haskell
-- Nesting order: (worker vs timeout) vs abort.
-- On abort: cancel the inner race (which cancels the worker → bracket cleanup).
-- On timeout: cancel the worker (bracket cleanup → process-group kill).
-- On worker completion: cancel the timeout + abort pollers.
race3 :: IO a -> IO b -> IO c -> IO (Either3 a b c)
```

`cancel` (ThreadKilled) on the worker triggers the `withManagedProcess` bracket cleanup (bracket is mask-on-cleanup, so async exceptions during cleanup are masked — correct). The nesting order ensures abort wins over timeout (user intent > resource limit).

**Per-attempt logic:**
1. Check `isAborted` → if true, return `Left ToolAborted` immediately.
2. Spawn the opcode action in a worker thread (`async`).
3. Race: `(wait worker vs timeoutDelay) vs waitForAbort flag pollInterval`.
4. On normal completion: return the result.
5. On timeout: cancel the worker (which kills the process group via bracket), return `Left (ToolTimeout seconds)`.
6. On abort: cancel the worker, return `Left ToolAborted`.
7. On IO exception caught inside the worker: return `Left (ToolIOError errorClass)` — **only the error class, not the full text** (Blocker Resolution #13).

**Retry logic:**
- Retry only on `ToolTimeout` and `ToolIOError` (`shouldRetry`).
- Do NOT retry on `ToolAborted` (user cancelled — respect it immediately).
- Do NOT retry on `Right` results (success is success, even if the opcode returned an error result — that's a semantic error, not a transport failure).
- Between retries: `threadDelay (computeRetryDelay cfg attempt)`. So delays are 2s, 4s for 3 retries.
- **Abort during retry sleep (PM question):** the retry loop checks `isAborted` *before* sleeping and *after* sleeping (before the next attempt). A `threadDelay` is not interruptible, so an abort during the 2-4s sleep delays recovery by at most the remaining sleep. This is acceptable (the alternative — interruptible sleep via `race (threadDelay d) (waitForAbort flag d)` — adds complexity for a 2-4s window; v1 uses the simple check-before-sleep).
- After max retries: return `Left (ToolRetriesExhausted lastError)`.

**The poll interval (Designer question):** `waitForAbort` polls every 100ms. This is **configurable** via `ToolTimeoutConfig` (add `ttcAbortPollMicros :: Int`, default 100_000) so tests can use a smaller interval (avoid slow specs).

**Tests (Task 5):**
- Fast-completing action returns result immediately.
- Hanging action (`threadDelay maxBound`) times out and returns `ToolTimeout`.
- Aborted action returns `ToolAborted`.
- Transient IO error retried 3 times then `ToolRetriesExhausted`.
- Successful action not retried.
- Abort during retry sleep: abort is detected before the next attempt (check-before-sleep).

#### 6. Wire into the dispatcher + AgentEnv + config

**Files:**
- `src/Seal/ISA/Dispatch.hs` (modify)
- `src/Seal/Agent/Env.hs` (modify — add fields)
- `src/Seal/Agent/Loop.hs` (modify — pass new env fields, clear abort per turn)
- `src/Seal/Channel/Cli.hs` (modify — `mkSessionAgentEnv` signature + call sites)
- `src/Seal/Channels/Loop.hs` (modify — dispatch call site + `ChannelDeps`)
- `src/Seal/Gateway/Send.hs` (modify — dispatch call site + `SendDeps`)
- `src/Seal/Gateway/API.hs` (modify — `ApiDeps` + `/stop` endpoint)
- `src/Seal/Config/File.hs` (modify — `[tool_timeout]` section; Blocker Resolution #8)
- `src/Seal/Agent/Runtime/Delegation/Worker.hs` (modify — AgentEnv construction; CTO B4)
- Test files (dispatch call sites): `test/Seal/ISA/DispatchSpec.hs`, `test/Seal/ISA/IntegrationSpec.hs`, `test/Seal/Phase4Spec.hs`, `test/Seal/Phase5Spec.hs`, + 6 files with direct `AgentEnv { }` constructions (Blocker Resolution #10) + `test/Seal/Channel/CliSpec.hs` (indirect via `mkSessionAgentEnv`) (CTO B4)

**Blocker Resolution #8 (config module):** The plan originally said `src/Seal/Types/Config.hs` — that's wrong. `Seal.Types.Config` uses `configuration-tools` (JSON/lens style, Types/Config.hs:36-97) and has no TOML codec. The actual `config.toml` runtime config is `src/Seal/Config/File.hs` (`RuntimeConfig` at Config/File.hs:71, `runtimeConfigCodec` at Config/File.hs:344, using `Toml.dioptional`/`Toml.table`). **Corrected:** add `rcToolTimeout :: Maybe ToolTimeoutConfig` to `RuntimeConfig` (Config/File.hs:71) + a tomland `toolTimeoutConfigCodec` (Config/File.hs:344, using `Toml.table`). Update `defaultRuntimeConfig` (Config/File.hs:218) + `runtimeConfigCodec` (Config/File.hs:344).

**Blocker Resolution #9 (dispatch call sites — fully enumerated):**

The `dispatch` signature gains two parameters:

```haskell
dispatch
  :: Registry -> TwoFileHandle -> BackendExec -> UntrustedIO
  -> ToolTimeoutConfig    -- NEW
  -> AbortFlag            -- NEW
  -> OpName -> Value
  -> App (Either DispatchError OpResult)
```

**All 4 production call sites (verified):**
| File | Line | Current call |
|---|---|---|
| `src/Seal/Agent/Loop.hs` | 374 | `dispatch (aeRegistry env) (aeTranscript env) (aeBackend env) (aeUntrustedIO env) name input` |
| `src/Seal/Channels/Loop.hs` | 992 | `runApp appEnv (dispatch isaReg tHandle localBackend untrustedIO callOpName val)` |
| `src/Seal/Channel/Cli.hs` | 679 | `runApp appEnv (dispatch isaReg tHandle localBackend callUio callOpName val)` |
| `src/Seal/Gateway/Send.hs` | 787 | `runApp appEnv (dispatch isaReg tHandle localBackend untrustedIO callOpName val)` |

Each gains `(aeToolTimeout env)` + `(aeAbortFlag env)` (or the equivalent from the in-scope `env`/`appEnv`).

**All 9 test call sites (verified — round 2 CTO review caught 2 missed DispatchSpec sites):**
| File | Lines | Current call |
|---|---|---|
| `test/Seal/ISA/DispatchSpec.hs` | 73, 80 | `dispatch reg h localBackend testUntrustedIO (OpName "P") (object [])` |
| `test/Seal/ISA/DispatchSpec.hs` | 86, 93 | `dispatch (mkRegistry []) h localBackend testUntrustedIO (OpName "Z") (object [])` / `dispatch (mkRegistry [op]) h localBackend testUntrustedIO (OpName "P") (object [])` |
| `test/Seal/ISA/IntegrationSpec.hs` | 155 | `dispatch reg h localBackend uio name input` |
| `test/Seal/Phase4Spec.hs` | 62, 65 | `dispatch reg h localBackend uio (OpName "SHELL_EXEC") ...` |
| `test/Seal/Phase5Spec.hs` | 226, 237 | `dispatch reg tHandle localBackend mkRemoteUntrustedIOStub (OpName "AGENT_DEF_WRITE") ...` |

Each test site adds `defaultToolTimeoutConfig` + a test `AbortFlag` (`newAbortFlag`). A test helper `testAbortFlag <- newAbortFlag` can be shared.

**Blocker Resolution #10 (AgentEnv construction blast radius — fully enumerated):**

Adding `aeAbortFlag :: AbortFlag` + `aeToolTimeout :: ToolTimeoutConfig` to `AgentEnv` (Env.hs:20) breaks every `AgentEnv { ... }` construction. **Verified sites:**

**Production:**
- `mkSessionAgentEnv` (Cli.hs:238) — the central constructor, 20 positional args, imported by `Channels/Loop.hs:78` + `Gateway/Send.hs:51`. **Signature change:** add two params (`AbortFlag` + `ToolTimeoutConfig`). Call sites:
  - `src/Seal/Channel/Cli.hs:647` (bg path)
  - `src/Seal/Channel/Cli.hs:693` (main path)
  - `src/Seal/Gateway/Send.hs:486`
  - `src/Seal/Gateway/Send.hs:732`
  - `src/Seal/Channels/Loop.hs:841`
- `Seal.Agent.Runtime.Delegation.Worker:162` — the subagent worker constructs an `AgentEnv` for delegation **via record-literal syntax** (not `mkSessionAgentEnv`), so it needs `aeAbortFlag` + `aeToolTimeout` fields added directly (not a `TurnAbort` param). The worker gets a fresh `AbortFlag` + the parent's `ToolTimeoutConfig`.

**Test (27 `AgentEnv { }` constructions across 6 files — verified via grep; round 2 CTO review corrected the file count from 12 to 6 — the other 6 listed files don't construct `AgentEnv` directly):**
- `test/Seal/Agent/LoopSpec.hs` (22 constructions)
- `test/Seal/Channels/Signal/RunSpec.hs`
- `test/Seal/Phase2bSpec.hs`
- `test/Seal/Phase5Spec.hs`
- `test/Seal/Channel/WiringSpec.hs`
- `test/Seal/ISA/IntegrationSpec.hs`

(`test/Seal/ISA/Ops/RepoSpec.hs`, `test/Seal/ISA/Ops/GitSpec.hs`, `test/Seal/SourceControl/CloneSpec.hs`, `test/Seal/ISA/DispatchSpec.hs` do NOT construct `AgentEnv` directly — they use `runTestApp` with a separate env. `test/Seal/SourceControl/AgentRegistrySpec.hs` constructs `SshAgentEnv` (a different type). `test/Seal/Channel/CliSpec.hs` uses `mkSessionAgentEnv` — tracked separately below.)

Each test adds `aeAbortFlag = testAbortFlag` + `aeToolTimeout = defaultToolTimeoutConfig`. A shared helper `testAgentEnvDefaults :: IO (AbortFlag, ToolTimeoutConfig)` = `(,) <$> newAbortFlag <*> pure defaultToolTimeoutConfig` reduces boilerplate.

**`mkSessionAgentEnv` signature strategy:** rather than adding two more positional args to the already-20-param function, bundle the new fields into a small record `TurnAbort = TurnAbort { taFlag :: AbortFlag, taTimeout :: ToolTimeoutConfig }` and add a single `TurnAbort` param. This keeps the positional count at 21 (not 22) and makes future additions (e.g. a per-turn deadline) a one-field change. The 5 call sites each build `TurnAbort (lookupOrCreateAbortFlag reg sid) cfg`.

**Blocker Resolution #11 (cabal + test/Main.hs merge points — fully enumerated):**

**`seal-harness.cabal` library `exposed-modules:` (after line 67, alphabetical):**
- `Seal.Tools.Exec.Abort`
- `Seal.Tools.Exec.Timeout`
- `Seal.Tools.Timeout`

**`seal-harness.cabal` test-suite `other-modules:` (alphabetical):**
- `Seal.Tools.Exec.AbortSpec`
- `Seal.Tools.Exec.TimeoutSpec`
- `Seal.Tools.TimeoutSpec`

**`seal-harness.cabal` library `build-depends:` (Blocker Resolution #7 — CTO B1):**
- Add `async` (currently only in test-suite at cabal:275; the new `Seal.Tools.Exec.Timeout` imports `Control.Concurrent.Async` from library code → build fails without it).

**`test/Main.hs` (3 new imports + 3 new `spec` calls):**
- After the last `import qualified` (around test/Main.hs:151), add:
  ```haskell
  import qualified Seal.Tools.TimeoutSpec
  import qualified Seal.Tools.Exec.AbortSpec
  import qualified Seal.Tools.Exec.TimeoutSpec
  ```
- After the last `spec` call (around test/Main.hs:301), add:
  ```haskell
  , Seal.Tools.TimeoutSpec.spec
  , Seal.Tools.Exec.AbortSpec.spec
  , Seal.Tools.Exec.TimeoutSpec.spec
  ```

**Dispatcher wiring (Option A — wrap inside dispatch, after ACK):**

The `dispatch` function wraps the `uoRun`/`toRun` call in `runWithTimeoutAbortRetry` **after** the ACK-before-execute (preserving the audit invariant — the entry is on disk before any execution attempt, including retries). The per-call timeout is extracted from the input JSON via `extractPerCallTimeout` (in seconds → `Microseconds`). On `Left ToolError`: map to `Left (ExecFailed (renderToolError name err))` and the `orRecorded` metadata carries the error class (Blocker Resolution #13).

**Abort flag lifecycle:** `clearAbort (aeAbortFlag env)` fires once at `runTurn` entry (before any tool call). A mid-turn abort keeps the flag set until the next turn begins (Architect Q2 — confirmed: `clearAbort` fires once at `runTurn` entry, not between tool calls).

**Retry + ACK (Architect Q3):** The single pre-run ACK (`tfwRecordAndAck` at Dispatch.hs:67, fires for all Untrusted opcodes) covers all retry attempts. Retries re-execute `uoRun`/`toRun` but do NOT re-ACK. The `orRecorded` metadata carries the retry count so the audit trail shows how many attempts occurred behind the single ACK.

#### 7. Channel abort wiring

**Files:**
- `src/Seal/Channel/Cli.hs` (modify — Ctrl+C → setAbort)
- `src/Seal/Channels/Signal.hs` (modify — `/stop` command → `setSessionAbort`)
- `src/Seal/Gateway/API.hs` (modify — `POST /api/sessions/:id/stop` → `setSessionAbort`)
- `src/Seal/Gateway/Server.hs` (modify — thread `SessionAbortRegistry` into `ApiDeps`)
- `src/Seal/Command/Serve.hs` (modify — construct `SessionAbortRegistry` + thread into `SendDeps`/`ChannelDeps`/`ApiDeps`)

**Deliverables:**
- CLI: Ctrl+C → `setAbort (aeAbortFlag env)`. The haskeline interrupt already exists — hook into it.
- Signal: `/stop` slash command → `setSessionAbort reg sid`.
- Web: new `POST /api/sessions/:id/stop` endpoint → `setSessionAbort (adAbortReg deps) sid`. **Blocker Resolution #2:** `ApiDeps` gains `adAbortReg :: SessionAbortRegistry`. The endpoint follows the existing `POST /api/sessions/:id/<action>` convention (e.g. `send` at API.hs:168, `setup-repo` at API.hs:187). **Security (Security suggestion):** the endpoint inherits the existing unauthenticated-loopback API model (Server.hs:74 loopback-only) — any local process can abort any session. This matches `/api/repos`; documented as the intentional trust boundary.
- **`/stop` semantics (Designer question):** `/stop` aborts the currently-running turn's in-flight tool call AND any future tool call until the next turn starts (`clearAbort` at `runTurn` entry resets). If `/stop` arrives between turns (no tool call in flight), it returns `200 {aborted: true, pending: true}` — the flag is set; the next `runTurn` will `clearAbort` it at entry (so it has no effect if no turn is in flight). This is the simplest correct semantics. **`pending` computation (Designer round 2 question):** to determine whether a turn is in flight, the handler does a non-blocking `tryReadMVar` on the session's lock MVar (from `SessionLocks`, Lock.hs:56) — `tryReadMVar` returns `Just ()` if the MVar is full (no turn in flight → `pending: true`) or `Nothing` if empty (turn in flight → `pending: false`). This avoids blocking on the lock. (If the session has no lock MVar yet — first turn not started — `pending: true`.)
- Clear abort flag at the start of each new turn (`runTurn`).
- Test: abort flag is set, in-flight dispatch returns `ToolAborted`.

#### 8. Model-facing error messages + schema advertisement + transcript metadata

**Files:**
- `src/Seal/ISA/Dispatch.hs` (modify — error rendering)
- `src/Seal/ISA/Ops/Shell.hs` (modify — `uoInSchema` gains `timeout`)
- `src/Seal/ISA/Ops/Bin.hs` (modify — `uoInSchema` gains `timeout`)
- `src/Seal/ISA/Ops/Web.hs` (modify — `uoInSchema` gains `timeout` for `WEB_EXTRACT`)
- `test/Seal/ISA/DispatchSpec.hs` (extend)

**Deliverables:**
- `renderToolError :: OpName -> ToolError -> Text` — user/model-visible messages (timeout value rendered in seconds, not microseconds):
  - Timeout: `"SHELL_EXEC timed out after 120s. If this command is expected to take longer, retry with a larger timeout value."`
  - Aborted: `"SHELL_EXEC was aborted by the user."`
  - Retries exhausted: `"SHELL_EXEC failed after 3 retries (last error: timed out after 120s)."`
- **Blocker Resolution #4 (schema advertisement):** update `uoInSchema` for `SHELL_EXEC`, `BIN_EXEC`, and `WEB_EXTRACT` to declare the optional `timeout` field (in seconds, with a description). A spec asserts the field is present.
- Transcript entry metadata: timeout value, retry count, error class, duration.
- **Blocker Resolution #13 (`orRecorded` secret-free):** `orRecorded` includes only the error CLASS string (`"timeout"|"aborted"|"io"|"retries_exhausted"`), NEVER the full `ToolIOError Text` payload (which could contain paths/host info from an IO error). Add a test asserting no arbitrary IO error text reaches the audit log. The metadata: `{"timeout_us": N, "retries": M, "error": "timeout|aborted|io"}`.
- Spec: timeout error message includes the timeout value (in seconds) and the opcode name.

## Step-by-Step Plan

### Task 1: `Seal.Tools.Timeout` — config types + pure retry logic

**Files:**
- `src/Seal/Tools/Timeout.hs` (new)
- `test/Seal/Tools/TimeoutSpec.hs` (new)
- `seal-harness.cabal` (library `exposed-modules:` + `async` dep + test `other-modules:`)
- `test/Main.hs` (import + spec)

**Deliverables:**
- `Microseconds` newtype.
- `ToolTimeoutConfig` record with defaults.
- `ToolError` ADT.
- `defaultToolTimeoutConfig` value.
- `extractPerCallTimeout :: Value -> ToolTimeoutConfig -> Microseconds` — pull the optional `timeout` field (in **seconds**) from JSON, validate (Blocker Resolution #5: non-int/negative/zero → default; > max → clamp), convert to microseconds.
- `computeRetryDelay :: ToolTimeoutConfig -> Int -> Microseconds` — `base * factor^attempt`, pure, overflow-safe.
- `shouldRetry :: ToolError -> Bool`.
- `errorClass :: ToolError -> Text` — returns ONLY the class string (Blocker Resolution #13).
- `renderToolError :: OpName -> ToolError -> Text` — model-visible messages.

**RED:** `TimeoutSpec` failing tests:
- `extractPerCallTimeout` absent → default; non-integer (string, float, null) → default; negative → default; zero → default; positive > max → clamp to max; positive in range → as-is (× 1_000_000).
- `computeRetryDelay` attempt 0 → base; attempt 1 → base * factor; monotonically increasing.
- `shouldRetry` per constructor: `ToolTimeout` yes, `ToolIOError` yes, `ToolAborted` no, `ToolRetriesExhausted` no.
- `errorClass` per constructor returns the class string only.
- `renderToolError` includes the opcode name + timeout in seconds.
- QuickCheck: `extractPerCallTimeout` output always in `[1, max*1_000_000]`.
- QuickCheck: `computeRetryDelay` always positive + monotonically increasing (factor >= 1.0).
- QuickCheck: `computeRetryDelay` overflow-safe for `attempt < 30`, `base < 10^7`.

**GREEN:** all functions.

**REFACTOR:** none expected.

**File scope:** `src/Seal/Tools/Timeout.hs`, `test/Seal/Tools/TimeoutSpec.hs`, `seal-harness.cabal`, `test/Main.hs`. (4 files.)

### Task 2: `Seal.Tools.Exec.Abort` — abort flag + SessionAbortRegistry

**Files:**
- `src/Seal/Tools/Exec/Abort.hs` (new)
- `test/Seal/Tools/Exec/AbortSpec.hs` (new)
- `seal-harness.cabal` + `test/Main.hs`

**Deliverables:**
- `AbortFlag` newtype wrapping `IORef Bool` — **constructor NOT exported** (Blocker Resolution #6).
- `newAbortFlag`, `isAborted`, `setAbort`, `clearAbort`, `waitForAbort`.
- `SessionAbortRegistry` (TVar (Map SessionId AbortFlag)) — Blocker Resolution #2.
- `newSessionAbortRegistry`, `lookupOrCreateAbortFlag`, `setSessionAbort`, `clearSessionAbort`.

**RED:** `AbortSpec` failing tests:
- set → isAborted True; clear → False; waitForAbort returns True after set.
- `SessionAbortRegistry`: `lookupOrCreateAbortFlag` twice same sid → same flag; `setSessionAbort` → isAborted True for that session; `clearSessionAbort` → reset; different sessions independent.

**GREEN:** the implementations.

**REFACTOR:** none.

**File scope:** `src/Seal/Tools/Exec/Abort.hs`, `test/Seal/Tools/Exec/AbortSpec.hs`, `seal-harness.cabal`, `test/Main.hs`. (4 files.)

### Task 3: Process-group spawning + kill helper

**Files:**
- `src/Seal/Tools/Exec/Local.hs` (modify)
- `src/Seal/Tools/Exec/Remote.hs` (modify)
- `src/Seal/Tools/Exec/UntrustedIO.hs` (modify)
- `test/Seal/Tools/Exec/LocalSpec.hs` (new or extend)
- `src/Seal/Harness/Tmux.hs` (optional — Blocker Resolution #12)

**Deliverables:**
- `killProcessGroup :: Int -> Int -> IO ()` — SIGTERM → grace → SIGKILL.
- `withManagedProcess :: CreateProcess -> (ProcessHandle -> Handle -> Handle -> IO a) -> IO a` — bracket with `create_group = True` + bounded reap (Architect S4 — non-blocking `getProcessExitCode` poll with 1s deadline).
- Modify `runLocalFixedArgv` and `runFixedArgv` to use `withManagedProcess`. **Preserve `try @IOError` handling** (CTO S5).
- Integration test: spawn `sleep 2`, kill the worker thread, verify no orphan. Bound with hspec `timeout` 5s (CTO S4).

**RED:** `LocalSpec` failing test — no orphan after kill.

**GREEN:** `withManagedProcess` + process-group kill.

**REFACTOR:** factor `withManagedProcess` to a shared helper used by Local + Remote.

**File scope:** `src/Seal/Tools/Exec/Local.hs`, `src/Seal/Tools/Exec/Remote.hs`, `src/Seal/Tools/Exec/UntrustedIO.hs`, `test/Seal/Tools/Exec/LocalSpec.hs`. (4 files; Tmux optional.)

### Task 4: Bounded output capture

**Files:**
- `src/Seal/Tools/Exec/Local.hs` (modify)
- `src/Seal/Tools/Exec/Remote.hs` (modify)
- `src/Seal/Tools/Exec/UntrustedIO.hs` (modify)

**Deliverables:**
- `readBounded :: Handle -> Int -> IO (Text, Bool)` — reads at most N bytes, returns `(content, wasTruncated)`.
- Wire into `withManagedProcess` action.
- Truncation marker: `"\n[output truncated at N bytes — redirect to a file and FILE_READ with pagination for full output]"`.
- Test: spawn `seq 1 10000`, verify bounded + marker. Bound (CTO S4).

**RED:** `LocalSpec` failing test — bounded output + marker.

**GREEN:** `readBounded` + wiring.

**REFACTOR:** none.

**File scope:** `src/Seal/Tools/Exec/Local.hs`, `src/Seal/Tools/Exec/Remote.hs`, `src/Seal/Tools/Exec/UntrustedIO.hs`. (3 files.)

### Task 5: The three-way race + retry wrapper

**Files:**
- `src/Seal/Tools/Exec/Timeout.hs` (new)
- `test/Seal/Tools/Exec/TimeoutSpec.hs` (new)
- `seal-harness.cabal` + `test/Main.hs`

**Deliverables:**
- `runWithTimeoutAbortRetry :: ToolTimeoutConfig -> AbortFlag -> Microseconds -> IO (Either ToolError a) -> IO (Either ToolError a)`.
- Three-way race via nested `race` (Architect S5): `(worker vs timeout) vs abort`. Abort wins over timeout.
- Retry loop: up to `ttcRetryMax` attempts, `computeRetryDelay` between attempts, only retry if `shouldRetry`. Check-before-sleep + check-after-sleep (PM question).
- The poll interval is configurable (`ttcAbortPollMicros`, default 100ms) for testability (Designer question).

**RED:** `TimeoutSpec` failing tests:
- Fast-completing action returns result immediately.
- Hanging action times out → `ToolTimeout`.
- Aborted action → `ToolAborted`.
- Transient IO error retried 3x → `ToolRetriesExhausted`.
- Successful action not retried.
- Abort during retry sleep: detected before next attempt.

**GREEN:** the wrapper.

**REFACTOR:** factor `race3` if reusable.

**File scope:** `src/Seal/Tools/Exec/Timeout.hs`, `test/Seal/Tools/Exec/TimeoutSpec.hs`, `seal-harness.cabal`, `test/Main.hs`. (4 files.)

### Task 6: Wire into the dispatcher + AgentEnv + config

**Files (fully enumerated — Blocker Resolutions #8, #9, #10, #11):**
- `src/Seal/Config/File.hs` (modify — `[tool_timeout]` section, `rcToolTimeout`, `toolTimeoutConfigCodec`)
- `src/Seal/Agent/Env.hs` (modify — add `aeAbortFlag`, `aeToolTimeout`)
- `src/Seal/ISA/Dispatch.hs` (modify — signature + wrapper)
- `src/Seal/Agent/Loop.hs` (modify — pass new env fields, clear abort per turn, dispatch call site at line 374)
- `src/Seal/Channel/Cli.hs` (modify — `mkSessionAgentEnv` signature + 2 call sites at 647, 693; dispatch call site at 679)
- `src/Seal/Channels/Loop.hs` (modify — `ChannelDeps` + dispatch call site at 992; `mkSessionAgentEnv` call at 841)
- `src/Seal/Gateway/Send.hs` (modify — `SendDeps` + dispatch call site at 787; `mkSessionAgentEnv` calls at 486, 732)
- `src/Seal/Gateway/API.hs` (modify — `ApiDeps` gains `adAbortReg`)
- `src/Seal/Gateway/Server.hs` (modify — thread `SessionAbortRegistry` into `ApiDeps`)
- `src/Seal/Command/Serve.hs` (modify — construct `SessionAbortRegistry`, thread into `SendDeps`/`ChannelDeps`/`ApiDeps`)
- `src/Seal/Agent/Runtime/Delegation/Worker.hs` (modify — AgentEnv construction; CTO B4)
- `src/Seal/Channels/Signal/Run.hs` (modify — `newChannelDeps` call, thread `SessionAbortRegistry`)
- `src/Seal/Channels/Telegram/Run.hs` (modify — `newChannelDeps` call, thread `SessionAbortRegistry`)
- Test files (6 — direct `AgentEnv` record-literal constructions; per Blocker Resolution #10 correction): `test/Seal/Agent/LoopSpec.hs`, `test/Seal/Channels/Signal/RunSpec.hs`, `test/Seal/Phase2bSpec.hs`, `test/Seal/Phase5Spec.hs`, `test/Seal/Channel/WiringSpec.hs`, `test/Seal/ISA/IntegrationSpec.hs`
- Test files (indirect — via `mkSessionAgentEnv`): `test/Seal/Channel/CliSpec.hs` (tracked via the `mkSessionAgentEnv` call sites above)
- Test files (dispatch call sites): `test/Seal/ISA/DispatchSpec.hs` (lines 73, 80, 86, 93), `test/Seal/ISA/IntegrationSpec.hs` (line 155), `test/Seal/Phase4Spec.hs` (lines 62, 65), `test/Seal/Phase5Spec.hs` (lines 226, 237)

**Deliverables:**
- Add `rcToolTimeout :: Maybe ToolTimeoutConfig` to `RuntimeConfig` (Config/File.hs:71) + `toolTimeoutConfigCodec` (Config/File.hs:344, tomland `Toml.table`). Update `defaultRuntimeConfig` + `runtimeConfigCodec`.
- Add `aeAbortFlag :: AbortFlag` and `aeToolTimeout :: ToolTimeoutConfig` to `AgentEnv` (Env.hs:20). Use a `TurnAbort` record (Blocker Resolution #10) to keep `mkSessionAgentEnv` positional count at 21.
- Add `adAbortReg :: SessionAbortRegistry` to `ApiDeps` (API.hs:99). Add `sdAbortReg :: SessionAbortRegistry` to `SendDeps` (Send.hs:148). Add `cdAbortReg :: SessionAbortRegistry` to `ChannelDeps` (Channels/Loop.hs:169).
- Modify `dispatch` signature (2 new params: `ToolTimeoutConfig` + `AbortFlag`). Wrap `uoRun`/`toRun` in `runWithTimeoutAbortRetry` (Blocker Resolution #1: bridge `App`→`IO` via `runApp env (...)` at the call site). Extract per-call timeout via `extractPerCallTimeout`. On `Left ToolError`: `Left (ExecFailed (renderToolError name err))` + `orRecorded` with error class only (Blocker Resolution #13).
- Update all 4 production + 9 test dispatch call sites (Blocker Resolution #9).
- Update all `AgentEnv`/`mkSessionAgentEnv` construction sites (Blocker Resolution #10).
- `clearAbort (aeAbortFlag env)` at `runTurn` entry.
- Add `async` to library `build-depends` (Blocker Resolution #7).
- Wire the 3 new modules into cabal `exposed-modules` + test `other-modules` + `test/Main.hs` (Blocker Resolution #11).

**RED:** `DispatchSpec` failing test — a hanging shell command times out and returns an error result to the model.

**GREEN:** the wiring.

**REFACTOR:** share a `TurnAbort`-building helper across the 5 `mkSessionAgentEnv` call sites; share a `testAbortFlag` helper across the test files.

**File scope:** 13 production + 10 test files (6 direct AgentEnv + CliSpec via mkSessionAgentEnv + DispatchSpec/Phase4Spec/Phase5Spec dispatch sites; IntegrationSpec overlaps both categories). (This is the largest task; it could split into 6a (config + Env + cabal) + 6b (dispatcher + call sites + test ripples) if it spills.)

### Task 7: Channel abort wiring

**Files:**
- `src/Seal/Channel/Cli.hs` (modify — Ctrl+C)
- `src/Seal/Channels/Signal.hs` (modify — `/stop`)
- `src/Seal/Gateway/API.hs` (modify — `POST /api/sessions/:id/stop`)

**Deliverables:**
- CLI: Ctrl+C → `setAbort (aeAbortFlag env)`.
- Signal: `/stop` → `setSessionAbort reg sid`.
- Web: `POST /api/sessions/:id/stop` → `setSessionAbort (adAbortReg deps) sid`. Returns `200 {aborted: true, pending: true/false}` (Designer question — `pending: true` if no turn in flight; the flag is set either way; `clearAbort` at next `runTurn` entry resets).
- Test: abort flag set, in-flight dispatch returns `ToolAborted`.

**RED:** failing test for each channel.

**GREEN:** the wirings.

**REFACTOR:** none.

**File scope:** 3 files.

### Task 8: Model-facing error messages + schema advertisement + transcript metadata

**Files:**
- `src/Seal/ISA/Dispatch.hs` (modify — error rendering, `orRecorded` metadata)
- `src/Seal/ISA/Ops/Shell.hs` (modify — `uoInSchema` gains `timeout`)
- `src/Seal/ISA/Ops/Bin.hs` (modify — `uoInSchema` gains `timeout`)
- `src/Seal/ISA/Ops/Web.hs` (modify — `uoInSchema` gains `timeout` for `WEB_EXTRACT`)
- `test/Seal/ISA/DispatchSpec.hs` (extend)

**Deliverables:**
- `renderToolError :: OpName -> ToolError -> Text` (already in Task 1; wired here).
- Schema advertisement (Blocker Resolution #4): `uoInSchema` for `SHELL_EXEC`, `BIN_EXEC`, `WEB_EXTRACT` declares the optional `timeout` field (in seconds, with description). Spec asserts presence.
- Transcript metadata: `orRecorded` includes `{"timeout_s": N, "retries": M, "error": "timeout|aborted|io"}`. Error class only (Blocker Resolution #13).
- Spec: timeout error message includes timeout value (seconds) + opcode name; `orRecorded` carries the class string only (no full IO error text — Blocker Resolution #13 test).

**RED:** `DispatchSpec` failing tests.

**GREEN:** the rendering + schemas + metadata.

**REFACTOR:** none.

**File scope:** 5 files.

## Files Likely to Change (fully enumerated — Blocker Resolution #9, #10, #11)

| File | Change |
|---|---|
| `src/Seal/Tools/Timeout.hs` | **NEW** — config types, pure retry logic, `Microseconds`, `ToolError`, `renderToolError` |
| `src/Seal/Tools/Exec/Abort.hs` | **NEW** — `AbortFlag` (unexported constructor), `SessionAbortRegistry` |
| `src/Seal/Tools/Exec/Timeout.hs` | **NEW** — three-way race + retry wrapper (IO-level) |
| `src/Seal/Tools/Exec/Local.hs` | Process-group spawning, bounded capture, `withManagedProcess` |
| `src/Seal/Tools/Exec/Remote.hs` | Process-group spawning, bounded capture |
| `src/Seal/Tools/Exec/UntrustedIO.hs` | Bounded capture, process-group kill in remote arm |
| `src/Seal/Harness/Tmux.hs` | (Optional — Blocker Resolution #12) `withManagedProcess` if the leak risk is unacceptable |
| `src/Seal/ISA/Dispatch.hs` | Wrap dispatch in timeout/abort/retry; `renderToolError`; `orRecorded` metadata |
| `src/Seal/Agent/Env.hs` | Add `aeAbortFlag`, `aeToolTimeout` |
| `src/Seal/Agent/Loop.hs` | Pass new env fields, clear abort per turn, dispatch call site (line 374) |
| `src/Seal/Channel/Cli.hs` | `mkSessionAgentEnv` signature (TurnAbort) + 2 call sites (647, 693) + dispatch call site (679) + Ctrl+C abort |
| `src/Seal/Channels/Loop.hs` | `ChannelDeps` gains `cdAbortReg`; dispatch call site (992); `mkSessionAgentEnv` call (841) |
| `src/Seal/Gateway/Send.hs` | `SendDeps` gains `sdAbortReg`; dispatch call site (787); `mkSessionAgentEnv` calls (486, 732) |
| `src/Seal/Gateway/API.hs` | `ApiDeps` gains `adAbortReg`; `POST /api/sessions/:id/stop` |
| `src/Seal/Gateway/Server.hs` | Thread `SessionAbortRegistry` into `ApiDeps` |
| `src/Seal/Command/Serve.hs` | Construct `SessionAbortRegistry`, thread into `SendDeps`/`ChannelDeps`/`ApiDeps` |
| `src/Seal/Agent/Runtime/Delegation/Worker.hs` | AgentEnv construction (CTO B4) |
| `src/Seal/Channels/Signal/Run.hs` | `newChannelDeps` call — thread `SessionAbortRegistry` |
| `src/Seal/Channels/Telegram/Run.hs` | `newChannelDeps` call — thread `SessionAbortRegistry` |
| `src/Seal/Config/File.hs` | `[tool_timeout]` section (`rcToolTimeout`, `toolTimeoutConfigCodec`) — Blocker Resolution #8 |
| `src/Seal/Channels/Signal.hs` | `/stop` command |
| `src/Seal/ISA/Ops/Shell.hs` | `uoInSchema` gains `timeout` (Blocker Resolution #4) |
| `src/Seal/ISA/Ops/Bin.hs` | `uoInSchema` gains `timeout` (Blocker Resolution #4) |
| `src/Seal/ISA/Ops/Web.hs` | `uoInSchema` gains `timeout` for `WEB_EXTRACT` (Blocker Resolution #4) |
| `src/Seal/Tools/Exec/Types.hs` | `ExecError` unchanged — `ToolError` is separate (Open Q §2 resolved: kept separate, mapped at boundary) |
| `seal-harness.cabal` | 3 new library `exposed-modules` + 3 new test `other-modules` + `async` to library `build-depends` (Blocker Resolution #7) |
| `test/Main.hs` | 3 new imports + 3 new `spec` calls (Blocker Resolution #11) |
| `test/Seal/ISA/DispatchSpec.hs` | Extend (dispatch call sites at 73, 80, 86, 93 + new tests) |
| `test/Seal/ISA/IntegrationSpec.hs` | Dispatch call site at 155 |
| `test/Seal/Phase4Spec.hs` | Dispatch call sites at 62, 65 |
| `test/Seal/Phase5Spec.hs` | Dispatch call sites at 226, 237 + AgentEnv construction |
| `test/Seal/Agent/LoopSpec.hs` | AgentEnv construction (direct; 22 constructions) |
| `test/Seal/Channels/Signal/RunSpec.hs` | AgentEnv construction (direct) |
| `test/Seal/Phase2bSpec.hs` | AgentEnv construction (direct) |
| `test/Seal/Channel/WiringSpec.hs` | AgentEnv construction (direct) |
| `test/Seal/ISA/IntegrationSpec.hs` | Dispatch call site at 155 + AgentEnv construction (direct) |
| `test/Seal/Channel/CliSpec.hs` | Indirect — via `mkSessionAgentEnv` (tracked via the `mkSessionAgentEnv` call sites in the production rows above) |

## Risks and Trade-offs

1. **`async` dependency (Blocker Resolution #7).** `async` is already in the test-suite deps (cabal:275) but NOT the library deps. Task 6 adds it to the library `build-depends`. The alternative — manual `forkIO` + `MVar` — is more error-prone and gains nothing. The `retry` package (cabal:246, already a library dep) is an alternative for the retry loop, but the hand-rolled loop is simpler for the three-way race case (CTO S8 — the retry package doesn't handle the race; we use it only for the sleep loop if at all).

2. **Process-group killing on the remote SSH arm.** Killing the local `ssh` process closes the SSH channel, which *usually* terminates the remote command. But if the remote command has backgrounded a child (`setsid ... &`), that child survives. This is an accepted limitation for v1 — the remote execution plane is disposable, and a leaked orphan can't reach the harness.

3. **Tmux/vault bypass (Blocker Resolution #12).** `readTmuxNoInput` (Tmux.hs:187) and vault `age` (Backend.hs:53) use `withCreateProcess` directly — they get the dispatch-level timeout but NOT process-group killing. A timed-out `tmux`/`age` child leaks until it exits on its own. v1 accepts this (age invocations are short-lived; tmux leaks are bounded by the tmux server's own lifecycle). Task 3 optionally extends `withManagedProcess` to Tmux if deemed necessary.

4. **Bounded output changes semantics.** Currently `hGetContents` returns everything. Capping at 50KB means the model might miss important output from a build. The truncation marker (which hints at the redirect-to-file recovery pattern) + the model's ability to retry with `build 2>&1 | tee build.log` then `FILE_READ` the log mitigates this. Existing tests that assert on full command output (CTO Q3) may need updating if their fixtures exceed 50KB — verify during Task 4 implementation.

5. **Retry can mask real problems.** If a command consistently times out, retrying just burns time. The retry max is 3 — after that, the error is surfaced. The model can decide to increase the timeout or change approach.

6. **Per-call timeout extraction from JSON (generic).** The extraction looks for a top-level `timeout` key in the input `Value` (in seconds). Verified (Blocker Resolution #14): the authorize functions use `parseMaybe`-based field extraction (e.g. Shell.hs:42 `commandField`, File.hs:146 `pathField`), so extra `timeout` fields are tolerated — the auth gate does NOT reject unknown fields. No per-opcode schema update is needed for the *extraction* to work; the schema advertisement (Task 8) is for *model discoverability* only.

7. **The `create_group = True` change affects all process spawning** (exec arms). This is a behavior change — children are now in their own process group. This is strictly better (we can kill them), but any code that relies on signal inheritance from the harness to the child will break. Verified: no such code in the current codebase (the Tmux/vault paths are separately scoped per Blocker Resolution #12).

8. **`App`→`IO` Katip context (Blocker Resolution #1).** The worker thread does NOT inherit the calling thread's Katip logging context. Log statements inside the opcode run in the worker use the base namespace. Acceptable — the dispatch path does not rely on thread-local Katip context for correctness.

9. **AgentEnv construction blast radius (Blocker Resolution #10).** Adding two fields to `AgentEnv` breaks 27 test constructions + `mkSessionAgentEnv` + the Worker. The `TurnAbort` record bundling keeps the positional count manageable. The mechanical test-site update is unavoidable; a shared `testAgentEnvDefaults` helper reduces boilerplate.

10. **120s default vs. cold builds (PM question).** A `nix develop --command cabal build` cold build can exceed 120s. The model will see a timeout error after 120s + 2 retries (360s+ burned). Mitigations: (a) the error message tells the model to retry with a larger timeout; (b) the model can redirect to a file and FILE_READ; (c) the operator can raise the default via `[tool_timeout]` in config.toml. A per-opcode default (Open Q §3 — rejected for v1) would help but adds config complexity. The global default + per-call override is the v1 trade-off.

## Open Questions

1. **Should the timeout wrapper be in `App` or `IO`?** Resolved (Blocker Resolution #1): `IO`-level. The `App`→`IO` bridge is at the dispatch call site via `runApp env (...)`. The wrapper itself never imports `Seal.Types.App`.

2. **Should `ToolError` be added to `DispatchError` or kept separate?** Resolved: kept separate (Open Q §2). `DispatchError` is about the dispatch decision (op not found, denied, exec failed); `ToolError` is about the execution lifecycle (timeout, abort, retry). The dispatcher maps `ToolError` → `DispatchError (ExecFailed (renderToolError ...))` at the boundary. The `orRecorded` metadata carries the error class for the audit trail (so the frontend can distinguish abort from timeout — Designer suggestion, folded into Task 8).

3. **Per-opcode timeout defaults?** Rejected for v1 (global 120s default + per-call override). The model can see the timeout in the error message and adjust. Per-opcode defaults add config complexity for marginal benefit. Future work if the 120s default proves wrong for a class of opcodes.

4. **Background execution?** Explicitly out of scope for v1. Future work: a background job registry (the Claude Code / OpenCode model is foreground-only; long commands use a larger timeout or redirect-to-file).

## Verification

**Automated:**
- `nix develop --command cabal build all` — green (`-Werror` clean)
- `nix develop --command cabal test` — green, including new specs (TimeoutSpec, AbortSpec, LocalSpec, TimeoutSpec)
- `nix develop --command hlint src/ test/` — clean
- `make check` (the full local gate — build + test + lint)

**Manual (reproducible):**
- `seal tui`, ask the model to run `sleep 999`, verify it times out after 120s and the session is not hung.
- `seal tui`, start a long build, Ctrl+C, verify the session recovers immediately (within the 100ms abort poll + SIGTERM→SIGKILL grace window of 5s).
- `seal tui`, ask the model to run `seq 1 100000`, verify output is capped at 50KB with a truncation marker and the session does not OOM.
- `seal tui`, ask the model to run a command with an explicit `timeout=300`, verify it runs longer than the 120s default without timing out (validates the per-call override path end-to-end — PM suggestion).
- `seal tui`, ask the model to run a command that fails with a transient IO error, verify it retries 3 times before surfacing the error.

**Failure criteria (PM suggestion):**
- FAIL if any tool call can still hang the session indefinitely.
- FAIL if Ctrl+C does not recover within the SIGTERM→SIGKILL grace window (5s).
- FAIL if the `orRecorded` audit metadata contains full IO error text (not just the class string — Blocker Resolution #13).
- FAIL if `extractPerCallTimeout` can return a negative or zero value (Blocker Resolution #5).

## Constructed Dependency DAG

```
Task 1 (Timeout: pure) ──┐
                          ├──→ Task 5 (race+retry) ──→ Task 6 (wire) ──→ Task 7 (channels) ──→ Task 8 (errors+schemas)
Task 2 (Abort: IORef) ────┘                      ↑
                                                 │
Task 3 (process-group) ──→ Task 4 (bounded) ─────┘
```

Tasks 1 + 2 are independent and can run in parallel (CTO S7 — no shared types). Task 3 + 4 are independent of 1 + 2. Task 5 depends on 1 + 2. Task 6 depends on 5 + 4. Task 7 depends on 6. Task 8 depends on 6.