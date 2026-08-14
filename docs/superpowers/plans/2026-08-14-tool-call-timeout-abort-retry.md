# Tool Call Timeout, Abort, and Retry — Implementation Plan

> **Status:** Draft for review
> **Date:** 2026-08-14
> **Scope:** Every opcode invocation via `Seal.ISA.Dispatch.dispatch` gets timeout + abort + retry protection, following the OpenCode / Claude Code model.

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

2. **Timeout is per-call, configurable.** The LLM can pass a `timeout` field in the tool input. If absent, use the configured default. Hard cap prevents absurd values.

3. **Abort is session-scoped.** An `IORef Bool` (or `TVar Bool`) on `AgentEnv` — the user/channel sets it to abort, the dispatch loop checks it. No per-thread signaling complexity (we're single-threaded per session in the agent loop).

4. **Retry with exponential backoff.** Only on transient failures: timeout, IO exceptions. Not on authorization denials, not on `ExecError` (host-key mismatch, not-implemented, etc.). 3 attempts max, base delay 2s, factor 2x.

5. **Process-group killing.** Shell commands spawn children. Kill the whole process group, not just the immediate child. SIGTERM → grace period → SIGKILL.

6. **No background execution.** Explicitly out of scope. If the model needs to run something long, it passes a larger timeout. This is the Claude Code / OpenCode philosophy.

### Architecture

```
AgentEnv
  +-- aeAbortFlag :: IORef Bool          (NEW — session abort signal)
  +-- aeToolTimeout :: ToolTimeoutConfig  (NEW — default + max + retry config)

Seal.ISA.Dispatch.dispatch
  → checkAbort                              (NEW — fail-fast if already aborted)
  → recordAndAck (for Untrusted)
  → runWithTimeoutAbortRetry                (NEW — the wrapper)
    → attempt N:
      → raceNext: opcodeRun  vs  timeoutDelay  vs  abortSignal
      → on timeout: killProcessGroup, mark transient, retry
      → on abort: killProcessGroup, return Aborted
      → on normal exit: return result
      → on IO exception: mark transient, retry
    → on retry: sleep (base * factor^attempt), loop
  → return result
```

### Detailed Design

#### 1. `Seal.Tools.Timeout` (new module)

Pure config types + the retry logic skeleton.

```haskell
-- | Configuration for tool call timeout/retry behavior.
data ToolTimeoutConfig = ToolTimeoutConfig
  { ttcDefaultMicros  :: Int    -- ^ default per-call timeout (default: 120_000_000 = 120s)
  , ttcMaxMicros      :: Int    -- ^ hard cap (default: 600_000_000 = 600s)
  , ttcRetryMax       :: Int    -- ^ max retry attempts (default: 3)
  , ttcRetryBaseMicros :: Int   -- ^ base delay between retries (default: 2_000_000 = 2s)
  , ttcRetryFactor    :: Double -- ^ backoff multiplier (default: 2.0)
  , ttcKillGraceMicros :: Int   -- ^ SIGTERM→SIGKILL grace period (default: 5_000_000 = 5s)
  }
```

Configurable via `config.toml` under `[tool_timeout]`. The per-call `timeout` field in the tool input JSON overrides the default, clamped to `ttcMaxMicros`.

#### 2. `Seal.Tools.Exec.Abort` (new module)

The abort signal type and helpers.

```haskell
-- | A session-scoped abort flag. Set by the channel/user to cancel
-- in-flight tool calls. Checked by the dispatch wrapper.
newtype AbortFlag = AbortFlag (IORef Bool)

newAbortFlag :: IO AbortFlag
isAborted :: AbortFlag -> IO Bool
setAbort :: AbortFlag -> IO ()
clearAbort :: AbortFlag -> IO ()
```

Wired into `AgentEnv` as `aeAbortFlag`. The channel layer (Signal, CLI, Web) calls `setAbort` when the user sends a stop/interrupt. The dispatch wrapper polls `isAborted` during the race.

#### 3. The race: `runWithTimeoutAbortRetry` (in `Seal.ISA.Dispatch` or a new `Seal.Tools.Exec.Timeout` module)

The core three-way race, implemented with `System.Timeout` + `async`:

```haskell
runWithTimeoutAbortRetry
  :: ToolTimeoutConfig
  -> AbortFlag
  -> Int               -- ^ per-call timeout (microseconds, already clamped)
  -> IO (Either ToolError OpResult)   -- ^ the opcode action
  -> IO (Either ToolError OpResult)
```

**Per-attempt logic:**

1. Check `isAborted` → if true, return `Left ToolAborted` immediately.
2. Spawn the opcode action in a worker thread (`async`).
3. Race three `IO` actions:
   - `wait worker` → normal completion
   - `threadDelay timeout` → timeout
   - `waitForAbort flag` → abort (polls every 100ms)
4. On normal completion: return the result.
5. On timeout: kill the worker (which kills the process group — see below), return `Left (ToolTimeout timeout)`.
6. On abort: kill the worker, return `Left ToolAborted`.
7. On IO exception caught inside the worker: return `Left (ToolIOError msg)`.

**Retry logic:**

- Retry only on `ToolTimeout` and `ToolIOError`.
- Do NOT retry on `ToolAborted` (user cancelled — respect it immediately).
- Do NOT retry on `Right` results (success is success, even if the opcode returned an error result — that's a semantic error, not a transport failure).
- Between retries: `threadDelay (base * factor^attempt)`. So delays are 2s, 4s for 3 retries.
- After max retries: return the last error.

**The `ToolError` type:**

```haskell
data ToolError
  = ToolTimeout Int          -- ^ microseconds (the timeout that was in effect)
  | ToolAborted              -- ^ user/session cancellation
  | ToolIOError Text         -- ^ transient IO failure
  | ToolRetriesExhausted ToolError  -- ^ wrapper after max retries
  deriving stock (Eq, Show)
```

#### 4. Process-group killing (in `Seal.Tools.Exec.Local` and `Seal.Tools.Exec.UntrustedIO`)

**Current problem:** `withCreateProcess` + `waitForProcess` blocks forever. Even if we race a timeout against it, the child process keeps running after we give up on waiting.

**Fix:** Change the process spawning to use process groups, and add a kill helper:

```haskell
-- In runLocalFixedArgv / runFixedArgv:
-- Add: create_group = True to the CreateProcess
-- This puts the child in its own process group (POSIX setpgid).

-- New helper:
killProcessGroup :: Int -> Int -> IO ()
-- ^ SIGTERM the process group, wait grace period, SIGKILL if still alive.
-- Uses System.Posix.Process (getProcessGroupIDOf, signalProcessGroup).
```

The `withCreateProcess` pattern needs to change to a bracket that:
1. Spawns the process with `create_group = True`.
2. Captures the PID.
3. Runs the action (read stdout/stderr, wait for exit).
4. On normal exit: return result.
5. On timeout/abort (the thread is killed by `async`'s `cancel`): kill the process group before cleaning up.

This is the tricky part. The `withCreateProcess` bracket guarantees cleanup, but it doesn't kill children — it only closes handles. We need a custom bracket:

```haskell
withManagedProcess :: CreateProcess -> (ProcessHandle -> IO a) -> IO a
withManagedProcess cp action = bracket create cleanup (action . snd)
  where
    create = do
      (_, mOut, mErr, ph) <- createProcess cp { create_group = True }
      pure (ph, mOut, mErr)   -- also return handles
    cleanup (ph, mOut, mErr) = do
      -- Kill the process group first (SIGTERM → grace → SIGKILL).
      pid <- processHandleToPid ph
      traverse_ (\p -> killProcessGroup p 5_000_000) pid
      -- Then close handles.
      traverse_ hClose mOut
      traverse_ hClose mErr
      -- Reap the zombie.
      void (waitForProcess ph) `catch` \(_ :: IOException) -> pure ()
```

When the `async` worker thread is cancelled (on timeout/abort), the bracket's cleanup runs, which kills the process group. This is the key mechanism — **killing the Haskell thread cascades to killing the OS process group**.

**For the remote SSH arm:** the same pattern applies, but "process group" is the SSH process. Killing it closes the SSH channel, which terminates the remote command. The remote arm already uses `runRemoteShellText` which spawns an `ssh` process — we wrap that with the same `create_group` + kill pattern.

#### 5. Wiring into the dispatcher

The `dispatch` function in `Seal.ISA.Dispatch` gets a thin wrapper. Two options:

**Option A (preferred): Wrap inside `dispatch`.** The dispatcher receives the `ToolTimeoutConfig` and `AbortFlag` from `AgentEnv` (passed through). The wrapping happens between the ACK-before-execute and the `uoRun`/`toRun` call. This keeps the ACK-before-execute ordering intact (the audit entry is written before any execution attempt, including retries).

**Option B: Wrap in `AgentLoop.dispatchOne`.** The loop wraps the `dispatch` call. Less ideal because it separates the timeout from the ACK logic.

Going with Option A. The `dispatch` signature gains two parameters:

```haskell
dispatch
  :: Registry -> TwoFileHandle -> BackendExec -> UntrustedIO
  -> ToolTimeoutConfig    -- NEW
  -> AbortFlag            -- NEW
  -> OpName -> Value
  -> App (Either DispatchError OpResult)
```

The per-call timeout is extracted from the input JSON's optional `timeout` field (in microseconds), clamped to `ttcMaxMicros`. If absent, `ttcDefaultMicros`.

#### 6. Wiring into `AgentEnv`

```haskell
data AgentEnv = AgentEnv
  { ...existing fields...
  , aeAbortFlag     :: AbortFlag           -- NEW
  , aeToolTimeout   :: ToolTimeoutConfig   -- NEW
  }
```

The `ToolTimeoutConfig` is loaded from `config.toml` `[tool_timeout]` at startup. The `AbortFlag` is created fresh per session.

#### 7. Channel abort wiring

- **CLI (`Seal.Channel.Cli`):** Ctrl+C handler calls `setAbort`. The haskeline interrupt already exists — hook into it.
- **Signal (`Seal.Channels.Signal`):** a special message (e.g. `/stop`) calls `setAbort`.
- **Web (`Seal.Gateway`):** a `POST /api/sessions/:id/stop` calls `setAbort` on that session's flag.

All three are thin — one line `setAbort (aeAbortFlag env)`.

#### 8. Model-visible error messages

When a tool call times out or is aborted, the model sees a clear message:

- Timeout: `"SHELL_EXEC timed out after 120s. If this command is expected to take longer, retry with a larger timeout value."`
- Aborted: `"SHELL_EXEC was aborted by the user."`
- Retries exhausted: `"SHELL_EXEC failed after 3 retries (last error: timed out after 120s)."`

These go into `OpResult` with `orIsError = True`. The `orRecorded` metadata includes the timeout value, retry count, and final error class — for the audit trail.

#### 9. Output bounding (defense against verbose builds)

Currently `runLocalFixedArgv` reads stdout/stderr with `BS.hGetContents` (lazy, unbounded). A command that spews 10GB of output will OOM the harness.

**Fix:** Bounded capture. Read at most `ttcMaxOutputBytes` (default 50KB) using `BS.hGetSome` in a loop, keeping a head/tail window. This mirrors Hermes' `bounded_capture` pattern. The final result tells the model: `[output truncated at 50KB — full output not captured]`.

This is a natural companion to the timeout work — both are about bounding resource consumption of untrusted commands.

## Step-by-Step Plan

### Task 1: `Seal.Tools.Timeout` — config types + pure retry logic

**Files:**
- `src/Seal/Tools/Timeout.hs` (new)
- `test/Seal/Tools/TimeoutSpec.hs` (new)

**Deliverables:**
- `ToolTimeoutConfig` record with defaults.
- `ToolError` ADT.
- `defaultToolTimeoutConfig` value.
- `extractPerCallTimeout :: Value -> ToolTimeoutConfig -> Int` — pull the optional `timeout` field from JSON, clamp to max.
- `computeRetryDelay :: ToolTimeoutConfig -> Int -> Int` — `base * factor^attempt`, pure.
- `shouldRetry :: ToolError -> Bool` — `ToolTimeout`/`ToolIOError` → yes; `ToolAborted`/`ToolRetriesExhausted` → no.
- QuickCheck: `computeRetryDelay` is always positive and monotonically increasing.
- QuickCheck: `extractPerCallTimeout` never exceeds `ttcMaxMicros`.

### Task 2: `Seal.Tools.Exec.Abort` — the abort flag

**Files:**
- `src/Seal/Tools/Exec/Abort.hs` (new)
- `test/Seal/Tools/Exec/AbortSpec.hs` (new)

**Deliverables:**
- `AbortFlag` newtype wrapping `IORef Bool`.
- `newAbortFlag`, `isAborted`, `setAbort`, `clearAbort`.
- `waitForAbort :: AbortFlag -> Int -> IO Bool` — polls `isAborted` every N microseconds, returns True if aborted. Used as the third race participant.
- Spec: set → isAborted returns True; clear → False; waitForAbort returns True after set.

### Task 3: Process-group spawning + kill helper

**Files:**
- `src/Seal/Tools/Exec/Local.hs` (modify)
- `src/Seal/Tools/Exec/UntrustedIO.hs` (modify)
- `test/Seal/Tools/Exec/LocalSpec.hs` (new or extend)

**Deliverables:**
- `killProcessGroup :: Int -> Int -> IO ()` — POSIX: `signalProcessGroup sigTERM pgid` → `threadDelay grace` → check `getProcessGroupIDOf` / `kill -0` → `signalProcessGroup sigKILL pgid` if still alive. Windows: `taskkill /PID /T /F`.
- `withManagedProcess :: CreateProcess -> (ProcessHandle -> Handle -> Handle -> IO a) -> IO a` — the bracket that spawns with `create_group = True` and kills the group on cleanup.
- Modify `runLocalFixedArgv` and `runFixedArgv` to use `withManagedProcess` instead of `withCreateProcess`.
- Integration test: spawn `sleep 30`, kill the worker thread, verify the child is dead (no orphan).

### Task 4: Bounded output capture

**Files:**
- `src/Seal/Tools/Exec/Local.hs` (modify)
- `src/Seal/Tools/Exec/UntrustedIO.hs` (modify)

**Deliverables:**
- `readBounded :: Handle -> Int -> IO (Text, Bool)` — reads at most N bytes, returns (content, wasTruncated). Head/tail window optional for v1; simple cap is sufficient.
- Wire into `withManagedProcess` action: read stdout/stderr with `readBounded` instead of `hGetContents`.
- Truncation marker in output: `"\n[output truncated at N bytes]"`.
- Test: spawn `seq 1 100000`, verify output is bounded + truncation marker present.

### Task 5: The three-way race + retry wrapper

**Files:**
- `src/Seal/Tools/Exec/Timeout.hs` (new — the IO-level race logic)
- `test/Seal/Tools/Exec/TimeoutSpec.hs` (new)

**Deliverables:**
- `runWithTimeoutAbortRetry :: ToolTimeoutConfig -> AbortFlag -> Int -> IO (Either ToolError a) -> IO (Either ToolError a)`
- Uses `Control.Concurrent.Async.race` or a custom `Selectable` to race: the worker action vs. `threadDelay timeout` vs. `waitForAbort flag pollInterval`.
- On timeout/abort: `cancel` the worker thread (which triggers the bracket cleanup → process-group kill).
- Retry loop: up to `ttcRetryMax` attempts, `computeRetryDelay` between attempts, only retry if `shouldRetry`.
- Tests:
  - Fast-completing action returns result immediately.
  - Hanging action (`threadDelay maxBound`) times out and returns `ToolTimeout`.
  - Aborted action returns `ToolAborted`.
  - Transient IO error retried 3 times then `ToolRetriesExhausted`.
  - Successful action not retried.

### Task 6: Wire into the dispatcher

**Files:**
- `src/Seal/ISA/Dispatch.hs` (modify)
- `src/Seal/Agent/Env.hs` (modify)
- `src/Seal/Agent/Loop.hs` (modify)
- `src/Seal/Types/Config.hs` (modify — add `[tool_timeout]` section)
- `test/Seal/ISA/DispatchSpec.hs` (extend)

**Deliverables:**
- Add `aeAbortFlag :: AbortFlag` and `aeToolTimeout :: ToolTimeoutConfig` to `AgentEnv`.
- Add `ToolTimeoutConfig` parsing from `config.toml` `[tool_timeout]`.
- Modify `dispatch` signature to accept `ToolTimeoutConfig` + `AbortFlag`.
- Wrap the `uoRun` / `toRun` call in `runWithTimeoutAbortRetry`.
- Extract per-call timeout from input JSON via `extractPerCallTimeout`.
- On `Left ToolError`: return `Left (ExecFailed (renderToolError name err))`.
- Update all `dispatch` call sites (AgentLoop, Call command, integration tests).
- Spec: a hanging shell command times out and returns an error result to the model.

### Task 7: Channel abort wiring

**Files:**
- `src/Seal/Channel/Cli.hs` (modify)
- `src/Seal/Channels/Signal.hs` (modify — `/stop` command)
- `src/Seal/Gateway/API.hs` (modify — `POST /api/sessions/:id/stop`)

**Deliverables:**
- CLI: Ctrl+C → `setAbort (aeAbortFlag env)`.
- Signal: `/stop` slash command → `setAbort`.
- Web: new `POST /api/sessions/:id/stop` endpoint → `setAbort`.
- Clear abort flag at the start of each new turn (`runTurn`).
- Test: abort flag is set, in-flight dispatch returns `ToolAborted`.

### Task 8: Model-facing error messages + transcript metadata

**Files:**
- `src/Seal/ISA/Dispatch.hs` (modify — error rendering)
- `test/Seal/ISA/DispatchSpec.hs` (extend)

**Deliverables:**
- `renderToolError :: OpName -> ToolError -> Text` — user/model-visible messages.
- Transcript entry metadata: timeout value, retry count, error class, duration.
- `orRecorded` includes: `{"timeout_us": N, "retries": M, "error": "timeout|aborted|io"}`.
- Spec: timeout error message includes the timeout value and the opcode name.

## Files Likely to Change

| File | Change |
|---|---|
| `src/Seal/Tools/Timeout.hs` | **NEW** — config types, pure retry logic |
| `src/Seal/Tools/Exec/Abort.hs` | **NEW** — abort flag |
| `src/Seal/Tools/Exec/Timeout.hs` | **NEW** — three-way race + retry wrapper |
| `src/Seal/Tools/Exec/Local.hs` | Process-group spawning, bounded capture, `withManagedProcess` |
| `src/Seal/Tools/Exec/UntrustedIO.hs` | Bounded capture, process-group kill in remote arm |
| `src/Seal/ISA/Dispatch.hs` | Wrap dispatch in timeout/abort/retry |
| `src/Seal/Agent/Env.hs` | Add `aeAbortFlag`, `aeToolTimeout` |
| `src/Seal/Agent/Loop.hs` | Pass new env fields to dispatch, clear abort per turn |
| `src/Seal/Types/Config.hs` | `[tool_timeout]` config section |
| `src/Seal/Channel/Cli.hs` | Ctrl-C abort wiring |
| `src/Seal/Channels/Signal.hs` | `/stop` command |
| `src/Seal/Gateway/API.hs` | `POST /api/sessions/:id/stop` |
| `src/Seal/Tools/Exec/Types.hs` | `ExecError` may gain a `ExecTimeout` constructor (or use `ToolError` directly) |
| `seal-harness.cabal` | New modules, `async` dependency (likely already present) |

## Risks and Trade-offs

1. **`async` dependency.** The `async` package is lightweight and likely already in the dependency closure (it ships with GHC). If not, it's one addition. The alternative — manual `forkIO` + `MVar` — is more error-prone and gains nothing.

2. **Process-group killing on the remote SSH arm.** Killing the local `ssh` process closes the SSH channel, which *usually* terminates the remote command. But if the remote command has backgrounded a child (`setsid ... &`), that child survives. This is an acceptable limitation for v1 — the remote execution plane is disposable, and a leaked orphan can't reach the harness. Hermes' more elaborate orphaned-pipe detection is not needed here.

3. **Bounded output changes semantics.** Currently `hGetContents` returns everything. Capping at 50KB means the model might miss important output from a build. The truncation marker + the model's ability to retry with a redirect to a file (`build 2>&1 | tee build.log`) mitigates this. The model can then `FILE_READ` the log with pagination.

4. **Retry can mask real problems.** If a command consistently times out, retrying just burns time. The retry max is 3 — after that, the error is surfaced. The model can decide to increase the timeout or change approach. This is better than no retry (transient SSH blips fail a whole turn) and better than infinite retry (hangs forever).

5. **Per-call timeout extraction from JSON.** Not all opcodes have a `timeout` field in their schema. The extraction is generic — it looks for a top-level `timeout` key in the input `Value`. If absent, the default is used. This means the model can pass a timeout to *any* tool, even ones that don't declare it. That's fine — it's a harness-level concern, not an opcode-level one. The tool schema descriptions should mention the optional `timeout` parameter for tools where it's most relevant (SHELL_EXEC, BIN_EXEC, WEB_EXTRACT).

6. **The `config_group = True` change affects all process spawning.** This is a behavior change — children are now in their own process group. This is strictly better (we can kill them), but any code that relies on signal inheritance from the harness to the child will break. I don't see any such code in the current codebase, but it's worth flagging.

## Open Questions

1. **Should the timeout wrapper be in `App` or `IO`?** The dispatch runs in `App` (`ReaderT AppEnv IO`). The timeout race is fundamentally `IO`-level. The wrapper should be `IO` — the `App` context is only needed to read the config, which can be extracted before the race. This keeps the timeout logic testable without a full `AppEnv`.

2. **Should `ToolError` be added to `DispatchError` or kept separate?** I lean separate — `DispatchError` is about the dispatch decision (op not found, denied, exec failed), while `ToolError` is about the execution lifecycle (timeout, abort, retry). The dispatcher maps `ToolError` → `DispatchError (ExecFailed ...)` at the boundary.

3. **Per-opcode timeout defaults?** A `FILE_READ` is fast; a `SHELL_EXEC` running `nix build` is slow. Should the default be per-opcode or global? I lean global (120s) with the model passing per-call overrides. Per-opcode defaults add configuration complexity for marginal benefit — the model can see the timeout in the error message and adjust.

## Verification

- `nix develop --command cabal build all` — green
- `nix develop --command cabal test` — green, including new specs
- `nix develop --command hlint src/ test/` — clean
- Manual: `seal tui`, ask the model to run `sleep 999`, verify it times out after 120s and the session is not hung.
- Manual: `seal tui`, start a long build, Ctrl+C, verify the session recovers immediately.
- Manual: `seal tui`, ask the model to run a command that fails with a transient IO error, verify it retries 3 times before surfacing the error.