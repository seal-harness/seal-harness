# Handoff carries the caller's repo (`AGENT_MANAGE action=handoff`)

Status: implemented (rev 6; plan-review gate: 3/3 PASS)
Date: 2026-11-03

## Problem

`AGENT_MANAGE action=handoff` spawns a new top-level session, but the new
session does not keep the caller's repo setting:

- `Seal.Agent.Runtime.Delegation.Worker.writeHandoffMeta` hardcodes
  `smRepoUrl = Nothing` (`Worker.hs:424`) and leaves `smAgent` /
  `smAgentName` at `Nothing` (`Worker.hs:418-419`), so a resumed handoff
  session has no bound agent either.
- `handleHandoff` builds the task with `ctIsolateWorkdir = False`
  (`Ops/Agent.hs:927`), so the new session's untrusted ops run in the
  **caller's** workdir.

So the tab/sidebar (which renders `repoUrl` from `session.json`) shows no
repo, and the new "top-level" session has no workdir of its own.

## Desired behaviour (operator directive)

A handoff creates a new session the same way the gateway's "new session with
a repo" flow does: **its own workdir**, its `repo_url` recorded, and the repo
cloned with the audited `SETUP_REPO` opcode before the first turn.

- `repo` (new, optional input): a **git URL** (`https://`, `http://`,
  `git://`, `ssh://`, or `git@host:path`). Overrides the inherited value.
  (URL only — no registry-id lookup: `AGENT_MANAGE` is model-invoked and the
  model has no repo-id surface; ids stay a `/new -r` / REST convenience.)
- `repo` absent: the new session inherits the caller's `smRepoUrl`.

**One resolver, two call sites.** `handoffRepoUrl` (WU1) is the single
authority for "explicit else inherited". `handleHandoff` calls it with the
caller's `SessionMeta` (so the result text can name the repo the new session
will get); the worker calls it again with the same inputs (idempotent safety
net). No second resolution rule anywhere.

## Work units

### WU1 — a leaf `session.json` loader + the pure repo resolver

*Why:* `handleHandoff` must read the caller's meta, but the only loader today
(`Seal.Core.TurnEngine.loadSessionMeta`, `TurnEngine.hs:925`) would be an
import cycle (`TurnEngine.hs:98` imports `Seal.ISA.Ops.Agent`). Two named
private copies exist for the same reason (`Worker.hs:389-396`,
`Gateway/Send.hs:630-637`); two further *inline* guard+decode sites
(`ISA/Ops/Session.hs:484-487`, `Command/Tab.hs:124-130`) are left for a
follow-up.

`src/Seal/Session/Meta.hs` (leaf: Aeson/Text/Time + `Agent.Def.Types` +
`Core.Types`; adding `Config.Paths` + `Util.StrictIO` + `System.Directory`
keeps it acyclic — `Config.Paths` only reaches `Core.Types`/`Gateway.Types.Core`):

- New `readSessionMeta :: SealPaths -> SessionId -> IO (Maybe SessionMeta)`.
  It **must guard existence first** (`decodeFileStrict` is
  `decode <$> readFileStrict`, and `sourceFile` throws on a missing path —
  `StrictIO.hs:100-101`); identical body to the three copies:
  ```haskell
  readSessionMeta paths sid = do
    let mp = sessionMetaPath paths sid
    exists <- doesFileExist mp
    if exists then decodeFileStrict mp else pure Nothing
  ```
  Export it.
- Replace the three copies with delegations (their exported/local names stay,
  so there is no call-site churn):
  `TurnEngine.loadSessionMeta`, `Gateway.Send.loadSessionMeta`,
  `Worker.loadParentMeta`.
- **Delete the imports whose sole use was the inlined loader** (otherwise
  `-Wall -Werror` breaks): `Worker.hs` — `doesFileExist`, `sessionMetaPath`,
  `decodeFileStrict` (uses at `:396-398` only); `TurnEngine.hs` —
  `decodeFileStrict` (use at `:931` only) **and the whole
  `import System.FilePath ((</>))` line (`:45`; its only use is the qualified
  `System.FilePath.</>` at `:927`)**; `Gateway/Send.hs` — `doesFileExist`
  (`:633`), `(</>)` (`:632`), `sessionDir` (`:632`), `decodeFileStrict`
  (`:636`). `make check` proves the list is exact.
- Note in the code comment: handoff callers are always **top-level** sessions
  (`agentManageOp` is only in the session registry, `TurnEngine.hs:308`, never
  in a child `baseOps`), so `sessionMetaPath` is the right reader; child metas
  live under `agentSessionDir` and are unreachable here.

`src/Seal/Agent/Runtime/Delegation/Worker.hs`:

- New exported `handoffRepoUrl :: Maybe Text -> Maybe SessionMeta -> Maybe Text`
  — the explicit value when non-blank, else the caller's `smRepoUrl` when
  non-blank, else `Nothing`. Add it to the module's export list
  (`Worker.hs:11-22`).

Tests (`test/Seal/Agent/Runtime/Delegation/WorkerSpec.hs`): `handoffRepoUrl` —
explicit wins; inherit when absent; blank explicit treated as absent;
`Nothing` parent → `Nothing`; blank parent repo → `Nothing`; idempotent
(feeding the result back in as explicit changes nothing). `readSessionMeta` —
round-trip; missing file → `Nothing`; undecodable file → `Nothing`.

### WU2 — `ChildTask` carries the handoff repo

`src/Seal/Agent/Runtime/Delegation.hs`

- `ChildTask` gains `ctRepoUrl :: !(Maybe Text)` (documented: only read for a
  top-level/handoff spawn; `start` children pass `Nothing`).
- Update the three `src/` construction sites (`Ops/Agent.hs:633, 647, 927`)
  and the 19 positional test constructors
  (`ConcurrentSpec.hs:122,126,332,361`; `WorkerSpec.hs:141,158,187,209`;
  `AgentSpec.hs:694,716,729,743,761,775,788,835,851,860,875`) by appending
  `Nothing`. Compiler-enforced under `-Werror`.

### WU3 — `repo` input on `AGENT_MANAGE action=handoff`

`src/Seal/ISA/Ops/Agent.hs` (already imports
`Seal.Agent.Runtime.Delegation.Worker ()` at `:76` — widen it; add
`Seal.Session.Meta (readSessionMeta)`. Both acyclic; `liftIO` and
`Katip (Severity (..))` are already in scope at `:59,104`):

- `handleHandoff`:
  1. read optional `repo`; if present it must be non-blank and pass
     `validateRepoUrl` (pure; exported from `Seal.ISA.Ops.Repo`, same
     precedent as `Gateway/Send.hs:80`; brings no capability handle into
     scope). Invalid → error `OpResult`, **no spawn**.
     **Carry the value `validateRepoUrl` returns (the trimmed URL)**, never
     the raw field — `Send.hs:914` does the same (`Right cleanUrl`), and the
     clone opcode trims too (`Repo.hs:93-103`), so an untrimmed `repo_url`
     would break the DoD 1/2 equality assertions.
  2. resolve once:
     `mCallerMeta <- liftIO (readSessionMeta (aswPaths wiring) (aswParentSession wiring))`,
     `effective = handoffRepoUrl explicit mCallerMeta`.
  3. build the task with `ctIsolateWorkdir = True` and `ctRepoUrl = effective`.
  4. result text: `encodeHandoffSpawnInfos effective spawnInfos` names the
     repo (`"none"` when there is none) — one call site (`Ops/Agent.hs:956`),
     no test callers, so the arity change is free.
- Schema: new `repo` property (string; description: git URL cloned into the
  new session's own workdir via `SETUP_REPO`; default = the calling session's
  repo). `toDesc`: one clause saying the new session inherits the caller's
  repo unless `repo` is given.
- No `AgentHandoffDeps` change.

Tests (`test/Seal/ISA/Ops/AgentHandoffSpec.hs`, already wired in the cabal):
- explicit `repo` + caller repo → `ctRepoUrl` = the explicit URL, isolate `True`;
- no `repo`, caller `session.json` has a repo → `ctRepoUrl` = the caller's;
- no `repo`, caller has none → `ctRepoUrl = Nothing`, still spawns;
- invalid `repo` (bad scheme / metacharacters) → `orIsError`, worker never runs;
- result text names the repo (inherit case included);
- `AGENT_MANAGE` input schema exposes `repo`; `toDesc` mentions the inherited repo.

### WU4 — worker: own workdir, audited `SETUP_REPO` clone, agent binding

`src/Seal/Agent/Runtime/Delegation/Worker.hs`

- `writeHandoffMeta deps childSid agentDef explicitRepo` resolves the URL via
  `handoffRepoUrl` against the parent meta, writes it into `smRepoUrl`,
  stamps `smAgent = Just (adId agentDef)` and `smAgentName = Just (adName
  agentDef)` when the name is non-blank (else `Nothing`), and returns the
  effective URL.
- Call-site shape: `writeChildMeta` returns `IO ()` while `writeHandoffMeta`
  returns `IO (Maybe Text)`, so the `if topLevel then … else …` at
  `Worker.hs:259-261` becomes
  `mRepo <- if topLevel then writeHandoffMeta … else writeChildMeta … >> pure Nothing`.
- After the child `UIOEnv` and abort flag exist and **before** `runTurn`, when
  `mRepo` is `Just url`, do (the worker body is `IO`):
  ```haskell
  cloneDeps <- runUIOWithEnv childUioEnv uioCdCloneDeps   -- sanctioned accessor
  runApp (dwdAppEnv deps) $
    dispatchHandoffRepo childTHandle
      (handoffRepoRegistry cloneDeps (dwdAutonomy deps))
      childUioEnv (dwdToolTimeout deps) childAbortFlag url (Just (dwdChannel deps))
  ```
  with two new exported helpers in `Worker.hs`:
  ```haskell
  handoffRepoRegistry :: CloneDeps -> AutonomyLevel -> Registry
  handoffRepoRegistry cloneDeps autonomy = mkRegistry [setupRepoOp cloneDeps autonomy]

  -- | Dispatch SETUP_REPO into the handoff session's transcript
  -- (ACK-before-execute) and record its result for the user.
  dispatchHandoffRepo
    :: IndexedTranscriptHandle -> Registry -> UIOEnv -> ToolTimeoutConfig
    -> AbortFlag -> Text {- repo url -} -> Maybe Text {- channel label -}
    -> App ()
  ```
  `dispatchHandoffRepo` = `dispatch reg h localBackend uioEnv tt af
  (OpName "SETUP_REPO") (object ["url" .= url])`, then `liftIO
  (recordSetupRepoResult h (OpName "SETUP_REPO") (object ["url" .= url]) res
  channel)`. A `Left DispatchError` is logged
  (`liftIO (globalLogIO WarningS (ls "…"))`) and does not abort the run (the
  goal may not need files). The channel param is `Maybe Text`, not a second
  bare `Text`, so a url/channel swap cannot silently typecheck.
- **Why a dedicated one-op registry and not the child registry:**
  `applyDefAllowList` (`TurnEngine.hs:1480-1482`, called at `:1465`) intersects
  the def's `tools` allow-list into the child registry, so a def that does not
  list `SETUP_REPO` would make the checkout silently vanish. The bypass is
  limited to that allow-list; **no blocklist control is skipped**
  (`SETUP_REPO` is absent from `delegationBlocklist`, `Worker.hs:72-81`).
  Credentials match the child registry's: both resolve `cachedSessionExec` for
  the child sid.
- Export list (`Worker.hs:11-22`): add `handoffRepoUrl`, `handoffRepoRegistry`,
  `dispatchHandoffRepo`.
- Imports to add/extend in `Worker.hs`:
  `Control.Monad.IO.Class (liftIO)` (**not currently imported**),
  `Data.Aeson (object, (.=))`, `Katip (Severity (..), ls)` +
  `Seal.Logging.Global (globalLogIO)` (**no logging import today**),
  `Seal.Handles.Transcript (IndexedTranscriptHandle)` (extend the existing
  `withIndexedTranscript` import), `Seal.ISA.Dispatch (dispatch,
  recordSetupRepoResult)`, `Seal.ISA.Registry (mkRegistry)` (extend the
  existing `Registry` import), `Seal.ISA.Ops.Repo (setupRepoOp)`,
  `Seal.SourceControl.Clone (CloneDeps)`, `Seal.Tools.Exec.UIOGit
  (uioCdCloneDeps)`, `Seal.Tools.App`→`Seal.Types.App (App, runApp)` (extend
  the existing `runApp` import), `Seal.Tools.Exec.UIO.Internal
  (runUIOWithEnv)` (extend). **Do not** import `Seal.ISA.Opcode (Opcode)` — it
  would be unused (`-Werror`), and do not touch `UIOEnv`'s opacity (the
  `uioCdCloneDeps` accessor is the sanctioned route).
  No cycles: `ISA.Dispatch`, `ISA.Ops.Repo` and `UIOGit` import no
  `Seal.Agent.*` module. (`UIOGit`'s docstring mentions a CI grep guard on its
  importers; no such guard exists, and `Ops/Bin.hs:71` already imports it.)

Tests (WorkerSpec gains a top-level deps builder — `dwdTopLevel = True` — and
a fake `SETUP_REPO` op in `mkRegistry`; the existing `mkWorkerDepsIO` /
`anchorRef` seam is reused):
- handoff meta: `smParent = Nothing`, `repo_url` inherited, `smAgent` bound to
  the def, `smAgentName` = the def's name; blank def name → `Nothing`;
- explicit `ctRepoUrl` overrides the caller's;
- `dwdMkUIOEnv` receives `Nothing` for a handoff task (own workdir), and
  `Just parentWorkdir` for a plain child task (regression guard);
- **ordering:** running the full `mkDelegateWorker` for a handoff with a repo
  records the `SETUP_REPO` harness entry *before* the first user-message entry
  in the new session's transcript (DoD 4's "before the first turn"). This test
  rides the **real** `setupRepoOp` behind the existing stub `UIOEnv`
  (`WorkerSpec.hs:279-281`): the stub's `uioShellExec` fails closed, so the op
  records its ACK'd invocation and returns `CloneFailed` without a network
  clone and without forcing `stubCloneDeps`' poisoned fields — exactly the
  failure-path behaviour DoD 4 also requires;
- `dispatchHandoffRepo` with a fake `SETUP_REPO` that records its input: the
  URL is dispatched, the invocation entry appears in the transcript, and the
  result text is recorded;
- `dispatchHandoffRepo` with a fake op returning an error `OpResult`: recorded,
  returns normally (DoD 4's failure half);
- `dispatchHandoffRepo` with a registry lacking `SETUP_REPO` (`OpNotFound`):
  logs, returns normally;
- `handoffRepoRegistry` contains `SETUP_REPO` (`lookupOp`) — the allow-list
  cannot suppress the checkout.

### WU5 — drop the unused `WorkspaceRoot` parameter from `setupRepoOp`

*Land this as its own commit* (unrelated cleanup in a security-adjacent op
signature; behaviour-preserving either way).

`src/Seal/ISA/Ops/Repo.hs` — `setupRepoOp :: CloneDeps -> AutonomyLevel -> Opcode`
(the argument is already unused: `setupRepoOp deps _wsRoot autonomy`,
`Repo.hs:84-85`). Call sites: `TurnEngine.hs:314`, `:1393` (both keep `wsRoot`
for the file/shell opcodes — verified still used, so no `-Werror` unused
binding). **Also delete the now-unused
`import Seal.Security.Path (WorkspaceRoot (..))` (`Repo.hs:65`)** — its only
use is that parameter. No behaviour change.

Tests: `make check`; `handoffRepoRegistry` covers the new construction.

### WU6 — deliberate divergences from `callDispatcher`'s SETUP_REPO convergence

Recorded in the PR body, not implemented:

- `updateSessionRepoUrl`: covered — `writeHandoffMeta` writes `repo_url` at
  creation.
- `invalidateWorkdirScan`: no cached scan exists for a brand-new session; the
  handoff session's own first turn scans the fresh workdir after the clone.
- `autoBindRepoAgentWith`: **not** replicated — the handoff session is created
  for an explicit agent def (now stamped into `smAgent`); rebinding it to a
  repo `agents.md` would change the prompt the caller asked for.
- `recordPreamble`: the first turn writes a real request entry.
- `broadcastAgentDefsChanged`: no subscriber surface for a session that has
  not started; the next turn's scan is fresh.

## Definition of Done

1. Handoff without `repo` → new session's `session.json` `repo_url` equals the
   caller's (`null` when the caller had none).
2. Handoff with `repo: <git url>` → `repo_url` is that URL.
3. Invalid `repo` → op error with a clear message, no session spawned.
4. The handoff session has its own workdir (`dwdMkUIOEnv` receives `Nothing`);
   the resolved repo is cloned into it by a dispatched `SETUP_REPO` before the
   first turn (asserted by transcript entry order); invocation + result appear
   in the new session's transcript; a clone failure is recorded and does not
   abort the run; a def tool allow-list cannot suppress the clone.
5. The handoff session's `session.json` binds `smAgent`/`smAgentName` to the
   def it runs, so a resume keeps the agent.
6. The tool result text names the repo the new session got.
7. `make check` green (build `-Werror`, tests, `hlint` → "No hints").
8. No **opcode** module gains **new**
   `System.Process`/`System.Directory`/`System.Posix` imports, and the new
   worker code performs no direct IO beyond `runUIOWithEnv`/`dispatch` (so no
   new `System.*` import reaches `Worker.hs`, which already imports
   `System.Directory` for session dirs); the `repo` value is validated by
   `validateRepoUrl` before it reaches the clone. Verified by diffing
   `grep -rnE "^import +System\.(Process|Directory|Posix)" src/Seal/ISA/Ops/`
   against its pre-change output — the baseline is **not** empty
   (`ISA/Ops/Session.hs:40` imports `System.Directory`; several modules hit
   only in comments), so the gate is "no new matches", not "no matches".
   There is no automated test for import hygiene today.

## Out of scope

- Repo-id resolution (stay URL-only) and any behaviour change to `/new`, the
  CLI `/repo` command, or the REST endpoints.
- Repo-shipped skill/agent-def discovery for the handoff session's *system
  prompt*: the worker's `childSystemPrompt` runs with the caller's backends
  (`TurnEngine.hs:1308`), so the repo catalog is not re-scanned before the
  first turn. Pre-existing; tracked separately.
- Auto-binding the repo's `agents.md` def (see WU6).
- `smAgent`/`smAgentName` stamping is a drive-by fix inside the same record
  `writeHandoffMeta` already builds; it is named as such in the PR body.

## Risks / notes

- **Behaviour change:** handoff sessions no longer share the caller's
  workdir. Caller-side uncommitted files are not visible to the handoff
  session; the freshly cloned repo is the handoff channel — the operator's
  stated intent.
- Remote mode (`security.toml mode=remote`): the clone runs through the
  child's `UIOEnv`, i.e. the remote untrusted plane, exactly as a
  model-invoked `SETUP_REPO` does.
- `repo_url` is recorded at session creation (intent), so it survives a clone
  failure; the failure itself is visible in the new session's transcript.
