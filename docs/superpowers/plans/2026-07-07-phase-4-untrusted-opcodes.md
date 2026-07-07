# Phase 4 — Untrusted opcode breadth + isolation: Plan

> **For agentic workers:** Implement task-by-task, top to bottom. Each task is
> TDD (red → green → commit). Steps use checkbox (`- [ ]`) syntax. Do not start
> a task until the previous task's gate is green (`nix develop --command cabal
> build all` `-Werror` clean, `nix develop --command cabal test` green,
> `nix develop --command hlint src/ test/` clean — all in the Nix dev shell).
> One commit per task.

**Goal:** give agents real shell, file, web, and media access — every action an
Untrusted opcode sealed in the audit log via the existing ACK-before-execute
dispatcher — plus a deployment mode (runtime fail-closed or hardened build)
in which untrusted execution is provably confined to a separate remote machine
reached over SSH. The control plane (agent loop, transcript, vault,
Trusted/Audited opcodes) never runs agent-driven commands.

**Parent roadmap:**
`docs/superpowers/plans/2026-06-28-seal-harness-roadmap.md` § Phase 4.

**Source-of-truth spec (remote-only split):**
`docs/superpowers/specs/2026-06-28-remote-only-untrusted-execution-design.md`
(approved). This plan implements it; where the plan and the spec disagree the
spec wins.

**Why this phase:** the README's core pitch is "agents with real shell, file,
and web access, every action sealed in the audit log." Phase 1–3 stood up the
vault, the agent spine, providers, and the ISA dispatcher with one Untrusted
opcode (`FILE_READ`). Phase 4 builds the opcode breadth that makes the ISA
useful, the typed execution-backend selector (`TerminalBackend`) those
opcodes run through, and the remote-only split that lets an operator ship a
binary that *cannot* run untrusted code on the harness machine.

## Sub-phase decomposition

Phase 4 is large. It is decomposed into six sub-phases, each a self-contained
TDD milestone with its own commits and its own green gate. Sub-phases land in
order; later sub-phases depend on earlier ones.

| Sub-phase | Title | Depends on |
|---|---|---|
| **4a** | `TerminalBackend` family + `UntrustedExecBackend` + select fn | — |
| **4b** | Local untrusted executor + runtime `untrusted_execution` mode (fail-closed) + config | 4a |
| **4c** | Execution opcodes: `SHELL_EXEC`, `PROCESS_MANAGE`, `CODE_EXEC` | 4b |
| **4d** | Files opcodes: `FILE_WRITE`, `SEARCH_FILES`, `FILE_PATCH` | 4b |
| **4e** | Web & Browser opcodes: `WEB_SEARCH`, `WEB_EXTRACT`, `BROWSER_*` | 4b |
| **4f** | Media opcodes: `IMAGE_*`, `TEXT_TO_SPEECH` | 4b |
| **4g** | Remote SSH executor + `remote-only-untrusted` Cabal flag (compile-time layer) | 4a,4b |
| **4h** | Capstone + roadmap milestone verification | 4c–4g |

Sub-phases 4c–4f are independent of each other (all depend only on 4b) and may
be parallelized once 4b is green. 4g depends on 4a (the
`UntrustedExecBackend` type) and 4b (the runtime layer it hardens); it may be
developed in parallel with 4c–4f. 4h is the integration capstone.

## Tech Stack

Haskell (GHC2021), Cabal, Nix dev shell. New deps (verify availability in the
pinned nixpkgs before use; see T0a):

- **`typed-process`** — typed subprocess execution for the executor seams
  (the `process` package is already a dep; `typed-process` is the
  safer-typed wrapper the spec's "fixed argv" rule prefers). If unavailable in
  the pin, fall back to `System.Process` (the established pattern in
  `Seal.Harness.Tmux.readTmuxNoInput` / `Seal.Security.Vault.Age`).
- **`network`** — for `WEB_EXTRACT` (HTTP client). Already have
  `http-client` + `http-client-tls` as deps; reuse those instead of `network`
  where possible.
- **`http-client`** + **`http-client-tls`** — already deps; used by
  `WEB_EXTRACT` and the browser opcodes' HTTP fetches.
- **`bytestring`**, **`aeson`**, **`text`**, **`containers`** — already deps.

No new Haskell deps are strictly required for 4a/4b/4g (pure types + the
runtime config). 4c/4d/4e/4f may add small, well-scoped deps; each sub-phase's
T0a verifies the dep is available before using it.

Build/test:
```
nix develop --command cabal build all
nix develop --command cabal test
nix develop --command hlint src/ test/
nix develop --command cabal test --test-options='--match "<needle>"'
nix develop --command cabal build all -f remote-only-untrusted   # 4g only
```

## Global Constraints

Inherited from the roadmap + the remote-only spec (§6 two global invariants)
+ existing Phase 1–3 conventions:

- **Module namespace:** new library modules under `Seal.*`. New top-level
  module family: `Seal.Tools.Exec.*` (the executor split), `Seal.Tools.Args`
  (validated argv newtypes), `Seal.ISA.Ops.*` (the new opcode groups),
  `Seal.Web.*` (web/browser), `Seal.Media.*` (media).
- **Coding style (Haskell):** GHC2021; conservative always-on
  `default-extensions`; per-file `OverloadedStrings` / `ImportQualifiedPost`.
  Whole-module imports; post-positive qualified imports. Mirrors 6a/7a.
- **Errors:** `Either Text` / `ExceptT Text` default. A bespoke error ADT
  only where control flow pattern-matches it — expected: `ExecError` (4a),
  `RemoteError` (4g), `WebError` (4e), `MediaError` (4f).
- **GHC flags:** `-Wall -Werror` plus the strict set (inherited from
  `common settings`).
- **TDD:** red → green → commit. Security-critical pure functions
  (`selectUntrustedBackend`, the validated argv newtypes, `SafePath` remote
  re-anchoring, the option-injection defenses) get QuickCheck properties.
  IO-bound executor seams are tested via pure argv builders + a fake
  executor for the opcode tests (mirrors the `TmuxRunner` fake pattern in
  `Seal.Harness.Tmux`).
- **hlint clean** before each commit.
- **No shell-wrapping in Trusted/Audited opcodes (Invariant 1).** Trusted and
  Audited opcodes must NEVER wrap a shell or run an arbitrary command. The
  shell/command capability lives exclusively in the Untrusted opcode path.
  Fixed-argv invocation of a specific trusted binary (`age`, `ssh`, `tmux`)
  is permitted as infrastructure.
- **Type-guaranteed argument sanitization (Invariant 2).** Every value derived
  from user/LLM input that reaches a subprocess argv must be carried by a
  validated, smart-constructed newtype — never raw `Text`/`String`. The
  exec/subprocess wrappers accept ONLY these validated types in their
  signatures. Defense against option injection is built into the smart
  constructor (reject leading-dash, always pass a leading `--` separator
  before user-derived args). Extends the existing `SafePath` /
  `AuthorizedCommand` / `ContainerTarget` pattern.
- **No secret ever serialized.** `OpResult.orRecorded` is secret-free (the
  dispatcher already enforces this). Network opcodes redact auth headers via
  CPS (spec §4); auth material never enters `orRecorded`.
- **ACK-before-execute (inherited).** All new opcodes are `Untrusted`; the
  existing `Seal.ISA.Dispatch` dispatcher already does
  `tfwRecordAndAck` before `opRun` for `Untrusted` opcodes. New opcodes
  change NOTHING in the dispatcher — they just register more `Opcode`s.
- **BackendExec seam.** All Untrusted opcode IO is funnelled through
  `BackendExec` (the existing `runLocal :: forall a. IO a -> App a` seam,
  `Seal.ISA.Opcode`). 4b widens this so the executor behind the seam is
  selectable (Local vs Remote SSH); the opcode implementations call the same
  `runLocal backend (...)` shape regardless of where the IO actually runs.
- **Loopback-by-default + WS Origin allowlist** (inherited from 7a, unchanged
  — no network listener changes in 4e/4f; web opcodes are outbound HTTP from
  the untrusted plane, not inbound listeners).
- **Cabal registration:** new library modules in `exposed-modules`, new test
  specs in `other-modules`, both alphabetical; new specs wired into
  `test/Main.hs`.
- **Commits:** one per task.
- **Clean-room:** no prior/reference runtime named in code, comments, docs,
  or commit messages.

## Non-goals (explicitly out of scope for Phase 4)

- **No new agent-loop logic.** The turn loop, transcript format, ingress
  gate are untouched. The ISA dispatcher (`Seal.ISA.Dispatch`) IS widened
  (to thread `ExecBackend` + pattern-match the GADT) — this is required
  by spec §4 capability scoping, not new loop logic. New opcodes register
  into the existing `ISA.Registry` at the channel wiring sites
  (`Seal.Channel.Cli`, `Seal.Channels.Signal.Run`).
- **No Phase 8 channels.** Telegram, the unified CLI channel, the
  scheduler, MCP, and remaining providers are Phase 8.
- **No container/VM backend.** The spec (§2 sharpening) explicitly excludes
  local containers/VMs from "remote" — they share the harness kernel. The
  `TerminalBackend` family *includes* a `Container` constructor for
  forward-compatibility, but 4b only implements `Local`; `Tmux` is already
  the harness backend (Phase 6a) and is NOT a tool-call-execution backend;
  `Ssh` lands in 4g; `Container` is stubbed (returns `ExecError` "not
  implemented") until a future phase.
- **No browser automation engine.** `BROWSER_*` opcodes land as a thin
  abstraction over `WEB_EXTRACT` + a pluggable driver interface; the default
  driver is a no-op "browser not configured" fail-closed. A real Playwright /
  headless-Chrome driver is a future phase.
- **No media model integration.** `IMAGE_*` / `TEXT_TO_SPEECH` opcodes
  expose the tool-call surface; the actual generation is delegated to a
  provider that already exists (e.g. an Ollama model) or fail-closed with
  "no media provider configured." Wiring a real image/TTS model is a future
  phase.
- **No per-opcode rate limiting.** The spec does not require it; the
  ACK-before-execute audit + the operator-configured `SafePath` ceilings are
  the bounded-resource mechanisms in 4. Rate limiting is a future phase.
- **No changes to `seal serve` / the gateway.** The gateway's `shell`/`ssh`
  tab kinds (stubbed 501 in 7b T10) become real only when 4g lands the SSH
  executor AND a follow-up widens `/api/tabs/new` to route `shell`/`ssh`
  kinds through `UntrustedExecBackend`. That gateway widening is a small
  follow-up task at the end of 4g, NOT a separate phase.

---

## Task map

### 4a — `TerminalBackend` family + `UntrustedExecBackend`

| Task | Title | Gate |
|---|---|---|
| **4a-T0** | `TerminalBackend` ADT (`Local`/`Tmux`/`Ssh`/`Container`) + config types (`TmuxConfig` reuse, `SshConfig`, `ContainerSpec`+`ContainerTarget`) | `cabal build all` green; pure types; QuickCheck on `ContainerTarget` smart constructor (option-injection defense) |
| **4a-T1** | `UntrustedExecBackend` smart-constructed type (only from `Ssh`) + `ExecError` | `cabal test` green; QuickCheck: untrusted ⇒ Ssh-or-failure, never Local |
| **4a-T2** | `selectUntrustedBackend :: Config -> Opcode -> Either ExecError UntrustedExecBackend` (pure) | `cabal test` green; QuickCheck property: mode=remote ⇒ never Local; mode=local ⇒ Local allowed |

### 4b — Local untrusted executor + runtime `untrusted_execution` mode

| Task | Title | Gate |
|---|---|---|
| **4b-T0** | `Seal.Tools.Args` validated argv newtypes (`ShellArg`, `ShellCommand`, `RemotePath`) + smart constructors (option-injection defense) | `cabal test` green; QuickCheck: no arg begins with `-` past `--`; round-trip safe or reject |
| **4b-T1** | `Seal.Tools.Exec.Local` — the untrusted local executor behind `BackendExec` (fixed argv via `typed-process`/`System.Process`, NO shell interpreter) | `cabal test` green; pure argv-builder tests + a fake executor for opcode tests |
| **4b-T2** | Runtime config: `[untrusted_execution]` `mode = "local"\|"remote"` in `Seal.Config.File` + `Seal.Types.Config`; boot always succeeds, fail-closed at call time | `cabal test` green; `ConfigSpec` covers parse + defaults |
| **4b-T3** | Wire `untrusted_execution` mode into channel wiring sites (`Seal.Channel.Cli`, `Seal.Channels.Signal.Run`) — select executor by mode | `cabal build all` + `cabal test` green; existing specs unaffected |

### 4c — Execution opcodes

| Task | Title | Gate |
|---|---|---|
| **4c-T0** | `SHELL_EXEC` opcode (Untrusted) — run a validated `ShellCommand` via the executor; `SafePath` cwd confinement; `AuthorizedCommand` gating | `cabal test` green; `Ops.ShellSpec` covers argv, cwd confinement, deny policy |
| **4c-T1** | `PROCESS_MANAGE` opcode (Untrusted) — list/kill processes on the untrusted plane; bounded output | `cabal test` green |
| **4c-T2** | `CODE_EXEC` opcode (Untrusted) — run a named interpreter (python/node/etc.) with a validated script arg; interpreter allow-list | `cabal test` green; interpreter not in allow-list ⇒ Denied |

### 4d — Files opcodes

| Task | Title | Gate |
|---|---|---|
| **4d-T0** | `FILE_WRITE` opcode (Untrusted) — write/append, `SafePath` confinement, bounded write size | `cabal test` green |
| **4d-T1** | `SEARCH_FILES` opcode (Untrusted) — ripgrep/grep-style search, `SafePath` confinement, bounded result count | `cabal test` green |
| **4d-T2** | `FILE_PATCH` opcode (Untrusted) — apply a unified diff, `SafePath` confinement, atomic write | `cabal test` green |

### 4e — Web & Browser opcodes

| Task | Title | Gate |
|---|---|---|
| **4e-T0** | `WEB_SEARCH` opcode (Untrusted) — query a configured search endpoint; auth-redaction via CPS; allow-list of domains | `cabal test` green; `WebSpec` covers redaction + allow-list |
| **4e-T1** | `WEB_EXTRACT` opcode (Untrusted) — fetch a URL via `http-client`, bounded bytes, allow-list, auth-redaction | `cabal test` green |
| **4e-T2** | `BROWSER_OPEN`/`BROWSER_CLICK`/`BROWSER_READ` opcodes (Untrusted) — thin driver interface, default fail-closed driver | `cabal test` green |

### 4f — Media opcodes

| Task | Title | Gate |
|---|---|---|
| **4f-T0** | `IMAGE_GENERATE`/`IMAGE_DESCRIBE` opcodes (Untrusted) — provider interface, default fail-closed | `cabal test` green |
| **4f-T1** | `TEXT_TO_SPEECH` opcode (Untrusted) — provider interface, default fail-closed | `cabal test` green |

### 4g — Remote SSH executor + compile-time flag

| Task | Title | Gate |
|---|---|---|
| **4g-T0** | `Seal.Tools.Exec.Remote` — SSH executor, fixed argv to `ssh`, mandatory host-key pinning (`StrictHostKeyChecking=yes`, pinned `known_hosts`), remote `SafePath` re-anchoring | `cabal test` green; pure argv-builder tests; QuickCheck on remote path validation |
| **4g-T1** | Wire `selectUntrustedBackend` to return `Remote` when `mode=remote`; fail-closed when remote down | `cabal test` green; fail-closed integration test with a fake SSH runner |
| **4g-T2** | Cabal flag `remote-only-untrusted` — CPP-gate `Seal.Tools.Exec.Local` out of the build; force `mode=remote` at startup | `cabal build all -f remote-only-untrusted` green; CI asserts local executor absent under flag |

### 4h — Capstone + milestone

| Task | Title | Gate |
|---|---|---|
| **4h-T0** | `Seal.Phase4Spec` capstone — end-to-end: a turn that calls `SHELL_EXEC` + `FILE_WRITE`, ACK-before-execute observed, transcript records both, no local fallback under `mode=remote` | `cabal test` green |
| **4h-T1** | Roadmap milestone verification — README pitch (real shell/file/web access, audit-sealed) + remote-only deployment mode | manual + `cabal build all -f remote-only-untrusted` green |

---

## 4a — `TerminalBackend` family + `UntrustedExecBackend`

**Why:** the typed selector for *where* a tool call runs. This is the
tool-call-execution counterpart to the tmux-only harness backend fixed in
Phase 6a — distinct concern, distinct type. The spec (§4) builds on this
family. 4a is pure types + a pure select function: no IO, no executor
implementation yet (those land in 4b/4g), so 4a is heavily QuickCheck-able.

### 4a-T0 — `TerminalBackend` ADT + config types

**Modules (file scope — ALL must be listed):**
- `src/Seal/Tools/Exec/Types.hs` (NEW) — the `TerminalBackend` ADT +
  `TmuxConfig` (re-export from `Seal.Session.Kind` — do NOT duplicate),
  `SshConfig` (NEW: host, user, port, identity, known_hosts, workspace),
  `ContainerSpec` (NEW) + `ContainerTarget` (NEW, smart-constructed),
  AND `ExecError` (NEW — moved here from `Seal.Tools.Exec.Untrusted` to
  break the import cycle; see 4b-T1 DESIGN NOTE on the cycle), AND the
  `LocalExecHandle` TYPE and its CONSTRUCTOR (both must live in the same
  module per Haskell's rules — see 4b-T1). In 4a it ships as an opaque
  `data LocalExecHandle` (no exported constructors); in 4b-T1 the
  declaration is widened IN `Types.hs` to the real constructor + IO-action
  fields (the constructor does NOT move to `Seal.Tools.Exec.Local`;
  `Local.hs` instead provides a smart constructor `mkLocalExecHandle`
  that wires the real IO actions into the `Types.hs`-declared constructor).
  `ExecBackend` sum (`EbLocal LocalExecHandle | EbRemote
  UntrustedExecBackend`) ALSO lives here (4a-T2 adds it) for the same cycle
  reason: both `Untrusted.hs` and `Local.hs` import `Types.hs`, neither
  imports the other.
- `src/Seal/Session/Kind.hs` — re-export `TmuxConfig` if not already exported
  (verify; it is the harness backend config, reused here as the `Tmux`
  constructor's payload).
- `seal-harness.cabal` — add `Seal.Tools.Exec.Types` to `exposed-modules`
  (alphabetical: after `Seal.Text.LineFile`, before `Seal.Tui`).
- `test/Seal/Tools/Exec/TypesSpec.hs` (NEW) — QuickCheck on
  `ContainerTarget` smart constructor (rejects leading-dash, path separators,
  control chars, empty).
- `test/Main.hs` — wire `Seal.Tools.Exec.TypesSpec`.

### Design

```haskell
-- Seal.Tools.Exec.Types
data TerminalBackend
  = TbLocal                     -- ^ untrusted local executor (4b); absent under -f remote-only-untrusted
  | TbTmux TmuxConfig           -- ^ tmux session (already the harness backend)
  | TbSsh SshConfig             -- ^ remote SSH executor (4g)
  | TbContainer ContainerSpec   -- ^ container/VM (forward-compat; stubbed)

data SshConfig = SshConfig
  { scHost        :: SshHost        -- ^ validated newtype
  , scUser        :: SshUser        -- ^ validated newtype
  , scPort        :: Int            -- ^ 1..65535
  , scIdentity    :: Maybe FilePath -- ^ SSH key file (or ssh-agent)
  , scKnownHosts  :: FilePath       -- ^ pinned; StrictHostKeyChecking=yes
  , scWorkspace   :: RemotePath     -- ^ remote workspace root (validated)
  }
-- smart constructors: SshHost (reject control/space/colon), SshUser (reject
-- control/space/colon), RemotePath (reject leading-dash, .. escape, absolute
-- vs relative per spec §4 "remote workspace root anchors SafePath")

data ContainerSpec = ContainerSpec { csTarget :: ContainerTarget, csImage :: Text }
newtype ContainerTarget = ContainerTarget Text  -- ^ smart-constructed
-- mkContainerTarget: reject leading-dash, path separators, control chars,
-- empty, colon. Option-injection defense (Invariant 2).

-- | The error ADT for the executor layer (lives here, not in Untrusted.hs,
-- to break the import cycle with Seal.Tools.Exec.Local — see 4b-T1).
data ExecError
  = ExecNotAllowed
  | ExecLocalNotPermittedForUntrusted
  | ExecRemoteRequired
  | ExecRemoteUnreachable
  | ExecHostKeyMismatch
  | ExecNotImplemented

-- | The local-executor handle. The TYPE and its CONSTRUCTOR both live here
-- (a Haskell type and its constructors must be in the same module). 4a
-- ships an opaque placeholder (no fields) so the ExecBackend sum can
-- reference the type; 4b-T1 WIDENS this declaration to the real record of
-- IO actions (the constructor stays in Types.hs, the 4b-T1
-- Seal.Tools.Exec.Local module provides the smart constructor
-- `mkLocalExecHandle :: WorkspaceRoot -> LocalExecHandle` that wires the
-- real IO actions, and re-exports the type). Living here lets
-- Seal.Tools.Exec.Untrusted reference it in the ExecBackend sum without
-- importing Seal.Tools.Exec.Local.
data LocalExecHandle            -- 4a: opaque (no constructors exported);
                                 -- 4b-T1: a single constructor with the IO
                                 -- record fields, exported only to Local.hs.
```

### TDD steps

- [ ] **Red.** `test/Seal/Tools/Exec/TypesSpec.hs`: QuickCheck on
  `mkContainerTarget` — for any `Text`, `Right` results never begin with `-`,
  never contain `/` or `:` or control chars, never empty; `Left` otherwise.
  Round-trip: `getContainerTarget <$> mkContainerTarget t` is `Right t` when
  `Right`. Property: `mkContainerTarget "--flag"` ⇒ `Left`.
- [ ] **Red-verify.** `cabal test --match Types` fails.
- [ ] **Green.** Implement `Seal.Tools.Exec.Types`. Green.
- [ ] **Green-verify.** `cabal build all` + full suite green; hlint clean.
- [ ] **Commit.** `feat(exec): TerminalBackend family + config types`

### 4a-T1 — `UntrustedExecBackend` smart-constructed type

**Modules:**
- `src/Seal/Tools/Exec/Untrusted.hs` (NEW) — `UntrustedExecBackend`
  (smart-constructed, only from `Ssh`). Imports `ExecError` and
  `TerminalBackend`/`SshConfig` from `Seal.Tools.Exec.Types` (NOT defining
  `ExecError` here — moved to `Types.hs` in 4a-T0 to break the import cycle
  with `Seal.Tools.Exec.Local`).
- `seal-harness.cabal` — add `Seal.Tools.Exec.Untrusted`.
- `test/Seal/Tools/Exec/UntrustedSpec.hs` (NEW) — QuickCheck: the only
  constructor that yields `Right UntrustedExecBackend` is the `Ssh` one.
- `test/Main.hs` — wire.

### Design

```haskell
-- Seal.Tools.Exec.Untrusted
-- | A backend that untrusted dispatch is allowed to run through. Smart-
-- constructed so it can ONLY come from an 'Ssh' backend (spec §4). A local
-- container/VM shares the harness kernel and does NOT count as remote
-- (spec §2 sharpening), so 'Container' cannot produce this type either.
newtype UntrustedExecBackend = UntrustedExecBackend SshConfig
  deriving stock (Eq, Show)

mkUntrustedExecBackend :: TerminalBackend -> Either ExecError UntrustedExecBackend
mkUntrustedExecBackend (TbSsh cfg) = Right (UntrustedExecBackend cfg)
mkUntrustedExecBackend TbLocal    = Left ExecLocalNotPermittedForUntrusted
mkUntrustedExecBackend _           = Left ExecNotImplemented
```

### TDD steps

- [ ] **Red.** `UntrustedSpec`: property — for any `TerminalBackend`,
  `mkUntrustedExecBackend` returns `Right` ONLY when the backend is `TbSsh`;
  `TbLocal`/`TbTmux`/`TbContainer` ⇒ `Left`.
- [ ] **Green.** Implement. Green.
- [ ] **Commit.** `feat(exec): UntrustedExecBackend smart constructor`

### 4a-T2 — `selectUntrustedBackend` + `selectExecBackend` (pure)

> **Spec amendment (flagged per plan contract "spec wins"):** the approved
> spec (`2026-06-28-remote-only-untrusted-execution-design.md` §4 line 124)
> gives `selectUntrustedBackend :: Config -> Opcode -> Either ExecError
> UntrustedExecBackend`. During planning this turned out to be ambiguous for
> `mode=local`: `UntrustedExecBackend` is by construction Ssh-only (4a-T1),
> so it cannot represent the local executor. The plan therefore splits the
> spec's single function into TWO pure functions and a sum type, with a
> one-line amendment recorded in the spec doc as part of this task's commit:
>   - `ExecBackend` sum: `EbLocal LocalExecHandle | EbRemote UntrustedExecBackend`
>     (the dispatcher consumes this).
>   - `selectUntrustedBackend :: UntrustedExecConfig -> TerminalBackend ->
>     Either ExecError UntrustedExecBackend` — the spec's function, narrowed
>     to return ONLY the remote arm; `mode=remote` ⇒ `Right` only if `Ssh`
>     configured, else `Left ExecRemoteRequired`; `mode=local` ⇒ `Left
>     ExecLocalNotPermittedForUntrusted` (this fn never returns Local).
>   - `selectExecBackend :: UntrustedExecConfig -> TerminalBackend -> Either
>     ExecError ExecBackend` — the full sum the dispatcher actually wires;
>     `mode=local` + `TbLocal` ⇒ `Right (EbLocal ...)`; `mode=remote` +
>     `TbSsh` ⇒ `Right (EbRemote ...)`; `mode=remote` + no remote ⇒ `Left
>     ExecRemoteRequired`.
> This amendment is recorded in the spec doc at §4 (a new paragraph under
> the existing `selectUntrustedBackend` definition) in 4a-T2's commit, so the
> spec and the plan remain in sync. `LocalExecHandle` is a forward reference
> defined in 4b-T1; 4a-T2 uses it abstractly (the sum constructor carries an
> opaque handle — a `newtype LocalExecHandle = LocalExecHandle ()` placeholder
> in 4a, widened to the real handle in 4b-T1).

**Modules:**
- `src/Seal/Tools/Exec/Untrusted.hs` (widen) — add `ExecBackend` sum +
  `selectUntrustedBackend` + `selectExecBackend` (signatures above). Pure.
- `src/Seal/Types/Config.hs` (widen) — add `UntrustedExecConfig` (the
  `mode` + optional `SshConfig`) to the config record. Field defaults:
  `UemLocal`, no remote configured. (Full runtime parsing lands in 4b-T2.)
- `docs/superpowers/specs/2026-06-28-remote-only-untrusted-execution-design.md`
  (widen) — append the §4 amendment paragraph recording the
  two-function split, so spec and plan stay in sync (per the plan contract).
- `test/Seal/Tools/Exec/UntrustedSpec.hs` (widen) — TWO QuickCheck properties
  (spec §8): (1) `selectUntrustedBackend` with `mode=remote` ⇒ result is
  `Ssh`-or-`Left`, NEVER `Local`; with `mode=local` ⇒ always `Left` (never
  yields Local). (2) `selectExecBackend` with `mode=remote` ⇒ never `EbLocal`;
  with `mode=local` + `TbLocal` ⇒ `Right (EbLocal ...)`.

### TDD steps

- [ ] **Red.** The two properties above.
- [ ] **Green.** Implement `ExecBackend` sum + both select fns + the
  `LocalExecHandle` placeholder + `UntrustedExecConfig` type. Append the spec
  amendment paragraph. Green.
- [ ] **Commit.** `feat(exec): selectUntrustedBackend + selectExecBackend + spec amendment`

---

## 4b — Local untrusted executor + runtime mode

**Why:** the runtime layer of the two-plane split (spec §3 Layer A). Default
builds run untrusted opcodes locally (the existing `localBackend`), but the
config can switch to `remote` (fail-closed). 4b implements the local
executor as a typed handle behind `BackendExec`, the validated argv newtypes
(Invariant 2), and the config surface. The remote executor itself lands in
4g; 4b only needs the config type + fail-closed selection.

### 4b-T0 — `Seal.Tools.Args` validated argv newtypes

**Modules:**
- `src/Seal/Tools/Args.hs` (NEW) — `ShellArg`, `ShellCommand`, `RemotePath`,
  `InterpName`, `ScriptArg` newtypes + smart constructors + getters. All
  reject leading-dash (option injection), control chars, NUL, newlines.
  `ShellCommand` is a single command string (not a pipeline; the executor
  runs `/bin/sh -c` with the validated command as a SINGLE arg — fixed argv,
  no interpreter nesting). `RemotePath` reuses `SafePath`'s lexical-collapse
  logic but anchors to a remote root.
- `seal-harness.cabal` — add `Seal.Tools.Args`.
- `test/Seal/Tools/ArgsSpec.hs` (NEW) — QuickCheck: no `Right` arg begins
  with `-`; arbitrary input round-trips safely or is rejected; NUL/newline
  always rejected.
- `test/Main.hs` — wire.

### TDD steps

- [ ] **Red.** QuickCheck properties for each newtype.
- [ ] **Green.** Implement. Green.
- [ ] **Commit.** `feat(exec): validated argv newtypes (Invariant 2)`

### 4b-T1 — `Seal.Tools.Exec.Local` (untrusted local executor)

**Modules:**
- `src/Seal/Tools/Exec/Types.hs` (widen — the `LocalExecHandle`
  declaration) — 4b-T1 widens the 4a opaque `data LocalExecHandle` to its
  real form: a constructor carrying the record of IO actions
  (`execShell :: ShellCommand -> Maybe RemotePath -> IO (Either ExecError
  Text)`, `execProgram :: InterpName -> [ScriptArg] -> IO ...`, etc.). The
  TYPE and its CONSTRUCTOR both live in `Types.hs` (Haskell requires a
  type and its constructors in the same module — the 4a-T0/4b-T1 split
  that placed the type in `Types.hs` and the constructor in `Local.hs` is
  impossible; corrected here). The constructor is exported from `Types.hs`
  so `Seal.Tools.Exec.Local` can pattern-match it.
- `src/Seal/Tools/Exec/Local.hs` (NEW) — exports
  `mkLocalExecHandle :: WorkspaceRoot -> LocalExecHandle` (the smart
  constructor that wires the real `System.Process`-backed IO actions into
  the `LocalExecHandle` constructor from `Types.hs`) + re-exports the
  `LocalExecHandle` type. The real implementation uses `System.Process`
  (mirrors `Seal.Harness.Tmux.readTmuxNoInput`: fixed argv, no shell
  interpreter for the program path; `/bin/sh -c` ONLY for `SHELL_EXEC` with
  a validated `ShellCommand`). `SafePath` cwd confinement: the cwd is the
  workspace root; `..`/absolute rejected. Imports `ExecError`,
  `LocalExecHandle` (type+constructor) from `Seal.Tools.Exec.Types` — NOT
  from `Seal.Tools.Exec.Untrusted` (breaks the cycle).
- `src/Seal/Tools/Exec/Untrusted.hs` (widen) — `selectExecBackend ::
  UntrustedExecConfig -> TerminalBackend -> Either ExecError ExecBackend`
  (the full sum; `selectUntrustedBackend` is the remote-only arm). Imports
  `ExecBackend`, `LocalExecHandle`, `ExecError` from
  `Seal.Tools.Exec.Types` — NOT from `Seal.Tools.Exec.Local` (breaks the
  cycle).
- `src/Seal/ISA/Opcode.hs` (widen — CAREFUL, load-bearing change) — replace
  the single `Opcode` record with a GADT-style sum that makes the
  trust-level capability scoping type-level (spec §4 line 129 + §8
  compile-fail fixture requirement):
  ```haskell
  data Opcode
    = TrustedOpcode
        { toName, toDesc, ...         -- the existing fields
        , toAuthorize :: Value -> Either Text ()
        , toRun :: BackendExec -> Value -> App OpResult
        }
    | UntrustedOpcode
        { uoName, uoDesc, ...         -- same shape fields
        , uoAuthorize :: Value -> Either Text ()
        , uoRun :: BackendExec -> ExecBackend -> Value -> App OpResult
        }
  ```
  A Trusted opcode has NO `ExecBackend` field — a Trusted opcode that
  shells out literally cannot be constructed (it has no `ExecBackend` to
  call). This is the type-level guarantee spec §4/§8 demand, and it makes
  the compile-fail fixture (4b-T1-FX) a real, writable test: a Trusted
  opcode construction that tries to use an `ExecBackend` fails to compile.
  `opTrust`, `opName`, `opDesc`, `opInSchema`, `opOutSchema`,
  `opAuthorize` become accessor functions that pattern-match both
  constructors (so existing call sites that read these fields keep working
  with minimal changes). `FILE_READ` migrates to `UntrustedOpcode`;
  `Human`/`Harness`/`Agent`/`Secret`/`Skills`/`Memory` migrate to
  `TrustedOpcode`.
- `src/Seal/ISA/Dispatch.hs` (widen — REQUIRED) — the dispatcher currently
  calls `opRun op backend input` unconditionally for ALL trust levels
  (`Dispatch.hs:54,57,63`). Widen it to pattern-match on the `Opcode`
  GADT: `UntrustedOpcode` ⇒ call `uoRun op backend execBackend input` (with
  `ExecBackend` threaded in); `TrustedOpcode` ⇒ call `toRun op backend
  input` (unchanged). The `dispatch` signature widens to carry
  `ExecBackend`. The ACK-before-execute ordering for `Untrusted` (the
  module's central invariant) is preserved — the new call site is after
  the existing `tfwRecordAndAck`.
- `seal-harness.cabal` — add `Seal.Tools.Exec.Local`.
- `test/Seal/Tools/Exec/LocalSpec.hs` (NEW) — pure argv-builder tests + a
  fake `LocalExecHandle` for opcode tests (mirrors `TmuxRunner` fake).
- `test/Seal/Tools/Exec/CapabilityScopingFail.hs` (NEW — REQUIRED, not a
  stretch goal) — a compile-fail fixture per spec §8 line 228: a small
  Haskell module that attempts to construct a `TrustedOpcode` whose run
  action references an `ExecBackend` (i.e. shells out). Under the GADT
  split this is a TYPE ERROR (a `TrustedOpcode` has no `ExecBackend` field).
  Wired as a cabal `test-suite` of type `exitcode-stdio` that asserts the
  fixture fails to compile (via a `cabal`-level `build-depends`-gated
  approach OR a `compile-and-check-failure` test driver — DECISION: the
  simplest portable form is a `test-suite` that uses
  `ghc -fno-code -e` on the fixture source and asserts a non-zero exit +
  the expected type error in stderr; see `Seal.TestHelpers.CompileFail`
  helper added in 4b-T1). This is the spec's deliverable, not optional.

  **Opcode construction sites to update (enumerated — grep `opTrust =`,
  `Opcode (`, AND ` { opAuthorize` / record-update syntax to find them; do
  NOT grep `mkRegistry [` which finds registry lists, not record literals):**
  - `src/Seal/ISA/Ops/File.hs` (record literal — `FILE_READ` migrates to
    `UntrustedOpcode`)
  - `src/Seal/ISA/Ops/Human.hs` (record literal — Trusted → `TrustedOpcode`)
  - `src/Seal/ISA/Ops/Harness.hs` (record literal — same)
  - `src/Seal/ISA/Ops/Agent.hs` (record literal — same)
  - `src/Seal/ISA/Ops/Secret.hs` (record literal — same)
  - `src/Seal/ISA/Ops/Skills.hs` (record literal — same)
  - `src/Seal/ISA/Ops/Memory.hs` (record literal — same)
  - `test/Seal/ISA/RegistrySpec.hs` (`mkTestOp` record literal — migrate to
    the GADT; the test exercises BOTH constructors)
  - `test/Seal/ISA/DispatchSpec.hs:30` (POSITIONAL `Opcode (OpName "P") tl
    "p" ...` — 7 positional args; migrate to the GADT constructors, one
    per trust level under test)
  - `test/Seal/ISA/DispatchSpec.hs:67` (RECORD-UPDATE `op = base {
    opAuthorize = const (Left "nope") }` — GADTs do NOT support record
    update on a sum whose fields differ per constructor. MIGRATION: the
    `Opcode` module exports a helper `withAuthorize :: Opcode -> (Value ->
    Either Text ()) -> Opcode` that pattern-matches and reconstructs the
    same constructor with the new authorize fn; `DispatchSpec:67` becomes
    `op = withAuthorize base (const (Left "nope"))`. Add the helper in
    `Seal.ISA.Opcode` as part of 4b-T1. This is the only record-update site
    in the codebase (grep ` { opAuthorize` and ` { opRun` to verify), so
    one helper covers it.)
  - `test/Seal/Agent/LoopSpec.hs:48` (POSITIONAL `Opcode (OpName "PING")
    Trusted "p" ...` — migrate to `TrustedOpcode`)

  **`dispatch` callers to update (the `dispatch` signature widens with
  `ExecBackend`):**
  - `src/Seal/Agent/Loop.hs:131` (the production call site)
  - `test/Seal/Phase6aSpec.hs:128,131` (`dispatchReg`/`dispatchOp` helpers)
  - `test/Seal/Phase5Spec.hs:181,191,202` (three calls)
  - `test/Seal/Agent/LoopSpec.hs` (via the loop)
  - `test/Seal/Channels/Signal/RunSpec.hs` (via the loop)
  - `test/Seal/ISA/DispatchSpec.hs:48,55,61,68` (four calls)

  **Import-cycle resolution (the plan's module layout):** `Seal.Tools.Exec.Types`
  holds `ExecError`, `LocalExecHandle` (type AND constructor — Haskell
  requires them in the same module; the 4a placeholder is an opaque
  `data LocalExecHandle`, widened to its real constructor in 4b-T1),
  `ExecBackend` (sum), `TerminalBackend`, `SshConfig`,
  `ContainerSpec`/`ContainerTarget`. `Seal.Tools.Exec.Untrusted` imports
  `Types` (for `ExecError`, `TerminalBackend`, `ExecBackend`,
  `LocalExecHandle` type); defines `UntrustedExecBackend` +
  `selectUntrustedBackend`/`selectExecBackend`. `Seal.Tools.Exec.Local`
  imports `Types` (for `ExecError`, `LocalExecHandle` type+constructor);
  defines the smart constructor `mkLocalExecHandle` + re-exports the type.
  Neither `Untrusted` nor `Local` imports the other. NO `.hs-boot` files
  needed.

### DESIGN NOTE (resolve before green)

The cleanest seam: keep `BackendExec` for Trusted/Audited opcodes (whose IO
is local by definition — they never shell out). Untrusted opcodes get a
SEPARATE `ExecBackend` argument threaded through the dispatcher. The GADT
split above makes this a TYPE-LEVEL guarantee (spec §4 line 129: "a Trusted
opcode shelling out fails to type-check — it has no shell handle in
scope"), not just a runtime precondition. `TrustedOpcode` has no
`ExecBackend` field; `UntrustedOpcode` has it. The dispatcher pattern-matches.
This:
- preserves the existing `Trusted` opcode semantics (their `toRun` signature
  is unchanged — `BackendExec -> Value -> App OpResult`).
- makes "a Trusted opcode shells out" a COMPILE ERROR — the spec's §8
  compile-fail fixture is now a writable, real test (4b-T1's
  `CapabilityScopingFail.hs`).
- the `Maybe`-typed-field alternative from the first draft is REPLACED by
  the GADT because the spec explicitly demands the type-level guarantee +
  the compile-fail fixture.

**Decision:** `Opcode` becomes a GADT with `TrustedOpcode` (no `ExecBackend`)
and `UntrustedOpcode` (with `ExecBackend`). The dispatcher pattern-matches.
`FILE_READ` migrates to `UntrustedOpcode`; the six Trusted opcode groups
migrate to `TrustedOpcode`. The compile-fail fixture
(`CapabilityScopingFail.hs`) is a REQUIRED task deliverable, not a stretch
goal.

### TDD steps

- [ ] **Red.** Widen `DispatchSpec`: an `UntrustedOpcode`'s `uoRun` is
  called with the selected `ExecBackend`; a `TrustedOpcode`'s `toRun` is
  called (unchanged). Update `FileSpec` for `FILE_READ` as an
  `UntrustedOpcode`. Migrate `RegistrySpec`, `LoopSpec`, `Phase6aSpec`,
  `Phase5Spec`, `RunSpec` `Opcode`/`dispatch` call sites for the GADT +
  widened `dispatch` signature (red = compile failures from the record →
  GADT change).
- [ ] **Red (compile-fail fixture).** Write
  `test/Seal/Tools/Exec/CapabilityScopingFail.hs` attempting to construct a
  `TrustedOpcode` whose `toRun` field references an `ExecBackend` (i.e.
  tries to shell out). Assert it fails to compile with the expected type
  error (via the `CompileFail` helper). This is the spec §8 deliverable.
- [ ] **Green.** Implement `Seal.Tools.Exec.Local`, replace `Opcode` with
  the GADT in `Seal.ISA.Opcode`, widen `Dispatch` to pattern-match the GADT
  and thread `ExecBackend`, add the `CompileFail` test helper, update ALL
  enumerated construction/call sites. Green (the compile-fail fixture
  fails to compile as expected = the test passes).
- [ ] **Green-verify.** `cabal build all` + full suite green; hlint clean.
  Verify the enumerated file list above is complete (grep `opTrust =` and
  `Opcode (` across `src/` and `test/`; grep `dispatch ` for callers) and
  that every match is updated. Verify the compile-fail fixture fails to
  compile (the test asserts the failure).
- [ ] **Commit.** `feat(exec): local untrusted executor + GADT capability scoping`

### 4b-T2 — Runtime config: `[untrusted_execution]`

**Modules:**
- `src/Seal/Config/File.hs` (widen) — parse `[untrusted_execution]` section:
  `mode = "local"|"remote"` (default `local`), `[untrusted_execution.remote]`
  sub-table (`host`/`user`/`port`/`identity`/`known_hosts`/`workspace`).
  Startup validates the remote block when `mode=remote` but does NOT block
  boot if the host is merely unreachable (spec §5).
- `src/Seal/Types/Config.hs` (widen) — `UntrustedExecConfig` (from 4a-T2)
  wired into the `FileConfig` record.
- `test/Seal/Config/FileSpec.hs` (widen) — parse + defaults; `mode=remote`
  with no `[remote]` ⇒ parse error OR runtime fail-closed (DECISION: parse
  OK, fail-closed at call time per spec §7 row 1 — "Boot OK; untrusted
  opcodes fail closed at call time").
- `test/Seal/ConfigSpec.hs` (widen if it covers the new field).

### TDD steps

- [ ] **Red.** `FileSpec`: parse `mode=remote` + remote block; parse
  `mode=local` (default); missing remote block with `mode=remote` parses OK
  (fail-closed is at call time, not parse time).
- [ ] **Green.** Implement. Green.
- [ ] **Commit.** `feat(config): untrusted_execution runtime mode`

### 4b-T3 — Wire mode into channel wiring sites

**Modules:**
- `src/Seal/Channel/Cli.hs` (widen) — build the `ExecBackend` from config at
  startup (select Local or Remote by mode); thread it into the `ISA.Registry`
  construction so Untrusted opcodes receive it. Pass `Nothing`/local for
  `mode=local`.
- `src/Seal/Channels/Signal/Run.hs` (widen) — same.
- `test/Seal/Channel/CliSpec.hs` (widen) — assert the registry receives the
  configured `ExecBackend`.
- `test/Seal/Channels/Signal/RunSpec.hs` (widen) — same.

### TDD steps

- [ ] **Red.** Spec asserts the `ExecBackend` is threaded.
- [ ] **Green.** Wire. Green.
- [ ] **Green-verify.** `cabal build all` + full suite green; hlint clean.
- [ ] **Commit.** `feat(channel): thread ExecBackend into ISA registry`

---

## 4c — Execution opcodes

**Why:** the core Untrusted opcodes that give agents real shell/process/code
access. All Untrusted, all through `ExecBackend`, all `SafePath`-confined,
all `AuthorizedCommand`-gated where applicable.

### 4c-T0 — `SHELL_EXEC`

**Modules:**
- `src/Seal/ISA/Ops/Shell.hs` (NEW) — `shellExecOp :: WorkspaceRoot ->
  ExecBackend -> SecurityPolicy -> Opcode`. `Untrusted`. Input: `{command:
  ShellCommand, cwd?: RelativePath}`. Authorize: `authorizeShell policy
  command` (reuses `Seal.Security.Command`). Run: via `ExecBackend`'s
  `execShell` with cwd confined by `SafePath`. `orRecorded`: the command +
  cwd (secret-free).
- `src/Seal/Channel/Cli.hs` + `Seal.Channels.Signal.Run.hs` (widen) — add
  `shellExecOp` to the registry.
- `seal-harness.cabal` — add `Seal.ISA.Ops.Shell`.
- `test/Seal/ISA/Ops/ShellSpec.hs` (NEW) — argv shape, cwd confinement,
  `Deny` policy ⇒ `Denied`, output bounded, `orRecorded` secret-free.
- `test/Main.hs` — wire.

### TDD steps

- [ ] **Red.** `ShellSpec` with a fake `ExecBackend`.
- [ ] **Green.** Implement. Green.
- [ ] **Commit.** `feat(isa): SHELL_EXEC opcode`

### 4c-T1 — `PROCESS_MANAGE`

**Modules:**
- `src/Seal/ISA/Ops/Process.hs` (NEW) — `processManageOp :: ExecBackend ->
  Opcode`. Actions: `list` (bounded output), `kill {pid}` (validated `Pid`
  newtype — reject negative, reject self-pid). `Untrusted`.
- `seal-harness.cabal` — add `Seal.ISA.Ops.Process`.
- `test/Seal/ISA/Ops/ProcessSpec.hs` (NEW).
- `test/Main.hs` — wire.

### TDD steps

- [ ] **Red.** `ProcessSpec`.
- [ ] **Green.** Implement. Green.
- [ ] **Commit.** `feat(isa): PROCESS_MANAGE opcode`

### 4c-T2 — `CODE_EXEC`

**Modules:**
- `src/Seal/ISA/Ops/Code.hs` (NEW) — `codeExecOp :: WorkspaceRoot ->
  ExecBackend -> InterpreterAllowList -> Opcode`. Input: `{interpreter:
  InterpName, script: ScriptArg, args?: [ScriptArg]}`. The interpreter must
  be in the operator-configured allow-list (`InterpreterAllowList`), else
  `Denied`. Run via `ExecBackend`'s `execProgram` (fixed argv, NO shell
  interpreter for the script body — the named interpreter parses it).
- `seal-harness.cabal` — add `Seal.ISA.Ops.Code`.
- `test/Seal/ISA/Ops/CodeSpec.hs` (NEW) — interpreter not in allow-list ⇒
  `Denied`; script with NUL ⇒ `Denied` (validated `ScriptArg`).
- `test/Main.hs` — wire.

### TDD steps

- [ ] **Red.** `CodeSpec`.
- [ ] **Green.** Implement. Green.
- [ ] **Commit.** `feat(isa): CODE_EXEC opcode`

---

## 4d — Files opcodes

### 4d-T0 — `FILE_WRITE`

**Modules:**
- `src/Seal/ISA/Ops/File.hs` (widen — add `fileWriteOp`) — `Untrusted`.
  Input: `{path, content, mode?: "write"|"append"}`. `SafePath` confined.
  Bounded write size (operator-configured `max_write_bytes`, mirrors
  `FILE_READ`'s `max_scan_bytes` clamp). `orRecorded`: path + mode + byte
  count (NOT the content — content may be large; the transcript records
  metadata only).
- `test/Seal/ISA/Ops/FileSpec.hs` (widen).
- Wiring sites (`Cli`, `Signal.Run`).

### TDD steps

- [ ] **Red.** `FileSpec` for `FILE_WRITE`.
- [ ] **Green.** Implement. Green.
- [ ] **Commit.** `feat(isa): FILE_WRITE opcode`

### 4d-T1 — `SEARCH_FILES`

**Modules:**
- `src/Seal/ISA/Ops/Search.hs` (NEW) — `searchFilesOp :: WorkspaceRoot ->
  ExecBackend -> Int -> Opcode`. `Untrusted`. Input: `{pattern, path?,
  max_results?}`. Runs `rg` (fixed argv, validated `SearchPattern` newtype —
  reject leading-dash) via `ExecBackend`. `SafePath` confined. Bounded result
  count (operator ceiling, model can narrow).
- `seal-harness.cabal` — add `Seal.ISA.Ops.Search`.
- `test/Seal/ISA/Ops/SearchSpec.hs` (NEW).
- `test/Main.hs` — wire.

### TDD steps

- [ ] **Red.** `SearchSpec` (pattern injection defense, confinement, bound).
- [ ] **Green.** Implement. Green.
- [ ] **Commit.** `feat(isa): SEARCH_FILES opcode`

### 4d-T2 — `FILE_PATCH`

**Modules:**
- `src/Seal/ISA/Ops/File.hs` (widen — add `filePatchOp`) — `Untrusted`.
  Input: `{path, patch}` (unified diff). Apply via `patch` (fixed argv) OR
  pure Haskell diff-apply (PREFERRED — no subprocess; mirrors the "no
  shell-wrapping" rule for what could be Trusted logic, though this is
  Untrusted so subprocess is allowed). Atomic write (temp + rename).
  `SafePath` confined. `orRecorded`: path + patch hash + line counts.
- `test/Seal/ISA/Ops/FileSpec.hs` (widen).

### TDD steps

- [ ] **Red.** `FileSpec` for `FILE_PATCH` (apply a small diff, assert
  content; reject a patch that escapes the path).
- [ ] **Green.** Implement. Green.
- [ ] **Commit.** `feat(isa): FILE_PATCH opcode`

---

## 4e — Web & Browser opcodes

### 4e-T0 — `WEB_SEARCH`

**Modules:**
- `src/Seal/Web/Search.hs` (NEW) — `WebSearchConfig` (endpoint, allow-list,
  auth via vault key reference — NOT inline), `webSearchOp :: WebSearchConfig
  -> ExecBackend -> Opcode`. `Untrusted`. Auth redaction via CPS: the auth
  header is injected in the `http-client` request but NEVER appears in
  `orRecorded` (the redaction point is a pure function over the request
  record). Domain allow-list (operator-configured).
- `seal-harness.cabal` — add `Seal.Web.Search`.
- `test/Seal/Web/SearchSpec.hs` (NEW) — redaction property (the recorded
  value contains no auth material), allow-list enforcement.
- `test/Main.hs` — wire.

### TDD steps

- [ ] **Red.** `SearchSpec`.
- [ ] **Green.** Implement. Green.
- [ ] **Commit.** `feat(isa): WEB_SEARCH opcode`

### 4e-T1 — `WEB_EXTRACT`

**Modules:**
- `src/Seal/Web/Extract.hs` (NEW) — `webExtractOp :: WebExtractConfig ->
  ExecBackend -> Opcode`. `Untrusted`. Fetch a URL via `http-client` (the
  existing dep). Bounded bytes (operator `max_extract_bytes`). Allow-list.
  Auth redaction. `orRecorded`: URL + status + byte count (NOT the body).
- `seal-harness.cabal` — add `Seal.Web.Extract`.
- `test/Seal/Web/ExtractSpec.hs` (NEW).
- `test/Main.hs` — wire.

### TDD steps

- [ ] **Red.** `ExtractSpec` (mock `http-client` via `http-client`'s test
  patterns or a fake manager).
- [ ] **Green.** Implement. Green.
- [ ] **Commit.** `feat(isa): WEB_EXTRACT opcode`

### 4e-T2 — `BROWSER_*`

**Modules:**
- `src/Seal/Web/Browser.hs` (NEW) — a `BrowserDriver` interface (a record of
  IO actions) + `browserOpenOp`/`browserClickOp`/`browserReadOp`. Default
  driver: `noBrowserDriver` (fail-closed with `ExecNotImplemented`). A real
  Playwright/headless driver is a future phase.
- `seal-harness.cabal` — add `Seal.Web.Browser`.
- `test/Seal/Web/BrowserSpec.hs` (NEW) — default driver fail-closes.
- `test/Main.hs` — wire.

### TDD steps

- [ ] **Red.** `BrowserSpec`.
- [ ] **Green.** Implement. Green.
- [ ] **Commit.** `feat(isa): BROWSER_* opcodes (driver interface, fail-closed)`

---

## 4f — Media opcodes

### 4f-T0 — `IMAGE_*`

**Modules:**
- `src/Seal/Media/Image.hs` (NEW) — `ImageProvider` interface + `imageGenerateOp`/
  `imageDescribeOp`. Default provider: `noImageProvider` (fail-closed).
- `seal-harness.cabal` — add `Seal.Media.Image`.
- `test/Seal/Media/ImageSpec.hs` (NEW).
- `test/Main.hs` — wire.

### TDD steps

- [ ] **Red.** `ImageSpec`.
- [ ] **Green.** Implement. Green.
- [ ] **Commit.** `feat(isa): IMAGE_* opcodes (provider interface, fail-closed)`

### 4f-T1 — `TEXT_TO_SPEECH`

**Modules:**
- `src/Seal/Media/Tts.hs` (NEW) — `TtsProvider` interface + `textToSpeechOp`.
  Default fail-closed.
- `seal-harness.cabal` — add `Seal.Media.Tts`.
- `test/Seal/Media/TtsSpec.hs` (NEW).
- `test/Main.hs` — wire.

### TDD steps

- [ ] **Red.** `TtsSpec`.
- [ ] **Green.** Implement. Green.
- [ ] **Commit.** `feat(isa): TEXT_TO_SPEECH opcode (provider interface, fail-closed)`

---

## 4g — Remote SSH executor + compile-time flag

### 4g-T0 — `Seal.Tools.Exec.Remote`

**Modules:**
- `src/Seal/Tools/Exec/Remote.hs` (NEW) — `RemoteExecHandle` (the SSH
  executor behind `ExecBackend`'s `EbRemote` arm). Shells out to `ssh` via
  fixed argv (no shell interpreter) with **mandatory host-key pinning**:
  `StrictHostKeyChecking=yes`, `UserKnownHostsFile=<pinned>`, batch mode
  (`-o BatchMode=yes`). A host-key mismatch is a hard failure
  (`ExecHostKeyMismatch`), never bypassed. Remote `SafePath` re-anchoring:
  the remote workspace root (from `SshConfig.scWorkspace`) anchors `SafePath`
  for remote file opcodes.
- `src/Seal/Security/Path.hs` (widen — CAREFUL) — `mkSafePath` already takes
  a `WorkspaceRoot`; the remote case passes a `WorkspaceRoot` constructed
  from the remote path. NO change needed if the remote executor constructs a
  `WorkspaceRoot` from the remote `scWorkspace` — VERIFY this is sound (the
  path is on the remote machine; `SafePath`'s lexical checks still prevent
  `..` escape; the canonicalization step is N/A remotely — SEE DESIGN NOTE).
- `seal-harness.cabal` — add `Seal.Tools.Exec.Remote`.
- `test/Seal/Tools/Exec/RemoteSpec.hs` (NEW) — pure argv-builder tests
  (assert `StrictHostKeyChecking=yes`, `BatchMode=yes`, pinned
  `UserKnownHostsFile`, no shell interpreter), QuickCheck on remote path
  validation, AND a host-key mismatch test (spec §7 row 3 + §8): a fake SSH
  runner that returns the `ssh` exit code for a host-key mismatch (255 with
  the "Host key verification failed" stderr) ⇒ the executor returns `Left
  ExecHostKeyMismatch`, NEVER a prompt/bypass. Plus a "host-key mismatch is
  hard, not retried" assertion (a second call after a mismatch still fails,
  does not auto-accept the new key).
- `test/Main.hs` — wire.

### DESIGN NOTE (resolve before green)

`mkSafePath` does filesystem canonicalization (step 3, `canonicalizePath`).
On the remote machine, the local executor cannot canonicalize. Resolution:
add a `mkSafePathRemote :: WorkspaceRoot -> FilePath -> Either PathError
SafePath` (pure, lexical-only — steps 1, 2, 4 minus the canonical IO). The
remote executor uses `mkSafePathRemote`; the local executor keeps
`mkSafePath`. This is a pure widening of `Seal.Security.Path`, tested via
QuickCheck on the lexical invariants.

### TDD steps

- [ ] **Red.** `RemoteSpec` asserts the argv shape (host-key pinning,
  batch mode, no `-c` shell interpreter, fixed program path `ssh`) AND the
  host-key mismatch behavior (fake runner returns the mismatch exit code ⇒
  `Left ExecHostKeyMismatch`, no bypass; a second call still fails).
- [ ] **Green.** Implement `Seal.Tools.Exec.Remote` + `mkSafePathRemote`.
  Green.
- [ ] **Commit.** `feat(exec): remote SSH executor with host-key pinning`

### 4g-T1 — Wire `selectExecBackend` for `mode=remote`

**Modules:**
- `src/Seal/Tools/Exec/Untrusted.hs` (widen) — `selectExecBackend` returns
  `EbRemote (RemoteExecHandle ...)` when `mode=remote`; fail-closed
  (`Left ExecRemoteRequired`) when remote down/unconfigured.
- `src/Seal/Channel/Cli.hs` + `Seal.Channels.Signal.Run.hs` (widen) — build
  the `RemoteExecHandle` from config when `mode=remote`.
- `test/Seal/Tools/Exec/UntrustedSpec.hs` (widen) — fail-closed integration
  with a fake `RemoteExecHandle` that simulates unreachable.

### TDD steps

- [ ] **Red.** `UntrustedSpec`: `mode=remote`, no remote configured ⇒ `Left
  ExecRemoteRequired`; remote configured but unreachable (fake) ⇒ opcode
  returns structured error, no local execution, transcript records the
  refusal.
- [ ] **Green.** Implement. Green.
- [ ] **Commit.** `feat(exec): wire remote selection, fail-closed when down`

### 4g-T2 — `remote-only-untrusted` Cabal flag

**Modules:**
- `seal-harness.cabal` (widen) — add a `flag remote-only-untrusted` (default
  False). When True, CPP-gate `Seal.Tools.Exec.Local` out of
  `exposed-modules` (use `if !flag(remote-only-untrusted)` around the
  module). Add `Seal.Tools.Exec.Local` to `other-modules` guarded so it's
  not compiled under the flag. Force `mode=remote` at startup: in
  `Seal.Config.File` (or `Seal.AppMain`), when the flag is on, a `local`
  value in config is a startup error (spec §3 Layer B).
- `src/Seal/Tools/Exec/Local.hs` (widen) — add `#if
  !REMOTE_ONLY_UNTRUSTED` / `#endif` CPP guards, OR (PREFERRED) exclude the
  module from the cabal target under the flag (cabal handles it; the module
  body needs no CPP). DECISION: exclude from cabal target (cleaner).
- `src/Seal/Config/File.hs` or `Seal.AppMain.hs` (widen) — startup check:
  under the flag, `mode=local` ⇒ startup error.
- `test/Seal/Config/FileSpec.hs` (widen) — the startup check (only testable
  if the check is pure; if it's in `AppMain`, test via a small pure helper).
- `.github/workflows/ci.yml` (widen) — add a CI job that builds with `-f
  remote-only-untrusted` and asserts the local executor module is absent
  (e.g. `cabal build all -f remote-only-untrusted` succeeds; a reference
  import fails to compile under the flag — a small compile-fail fixture).

### TDD steps

- [ ] **Red.** A compile-fail fixture
  (`test/Seal/Tools/Exec/LocalAbsentSpec.hs` or a CI script) that asserts
  `Seal.Tools.Exec.Local` is not importable under the flag. The startup
  check: a pure helper `enforceRemoteOnly :: UntrustedExecConfig -> Either
  Text ()` that returns `Left` when the flag is on and `mode=local`.
- [ ] **Green.** Add the flag, exclude the module, add the startup check.
  Green. Verify `cabal build all -f remote-only-untrusted` succeeds and the
  default `cabal build all` still succeeds.
- [ ] **Green-verify.** CI job green; default build green; full suite green
  (default flag).
- [ ] **Commit.** `feat(exec): remote-only-untrusted Cabal flag (compile-time layer)`

> **Note on the gateway `shell`/`ssh` tab kinds:** the 501 stub in
> `src/Seal/Gateway/API.hs:181-182` (set by Phase 7b T10) is left in place.
> Un-stubbing it is a gateway/HTTP-API feature, not an ISA opcode or tool
> call, and is therefore out of scope for Phase 4. The SSH executor (4g-T0)
> makes the capability available to ISA opcodes; a future phase (or a
> small follow-up task after Phase 4) widens `/api/tabs/new` to route
> `shell`/`ssh` kinds through `UntrustedExecBackend`. The plan's Non-goals
> section already lists "No changes to `seal serve` / the gateway."

---

## 4h — Capstone + milestone

### 4h-T0 — `Seal.Phase4Spec`

**Modules:**
- `test/Seal/Phase4Spec.hs` (NEW) — end-to-end: a turn that calls
  `SHELL_EXEC` (echo hello) then `FILE_WRITE` (write the output to a file),
  with a fake `ExecBackend` that records calls. Assert: ACK-before-execute
  (the transcript `ack` precedes each `run`), both invocations recorded in
  the transcript, `orRecorded` secret-free, no local fallback under
  `mode=remote` with a fake-unreachable remote.
- `test/Main.hs` — wire.

### TDD steps

- [ ] **Red.** `Phase4Spec`.
- [ ] **Green.** Make it pass (likely already passes if 4a–4g are green;
  the capstone is the integration assertion).
- [ ] **Commit.** `test(phase4): capstone spec`

### 4h-T1 — Milestone verification

### Steps

- [ ] `nix develop --command cabal build all` green, `-Werror` clean.
- [ ] `nix develop --command cabal test` green including `Phase4Spec`.
- [ ] `nix develop --command hlint src/ test/` clean.
- [ ] `nix develop --command cabal build all -f remote-only-untrusted`
  green (the hardened build).
- [ ] Manual: `seal` TUI — run a turn that calls `SHELL_EXEC` (e.g.
  `!echo hello` or via the agent's tool call); verify the transcript records
  it; verify `mode=remote` with no remote fail-closes.
- [ ] README pitch verification: "agents with real shell, file, and web
  access, every action sealed in the audit log" + "a deployment mode in
  which untrusted execution is provably confined to a remote machine."
- [ ] **Commit (if doc updates).** `docs(phase4): milestone verification`

---

## Milestone (Phase 4)

**Definition of Done (whole phase):**

- [ ] `cabal build all` is `-Werror` clean (Nix dev shell).
- [ ] `cabal test` green including `Phase4Spec` + all new `Ops.*Spec`/
  `Tools.Exec.*Spec`/`Web.*Spec`/`Media.*Spec`.
- [ ] `hlint src/ test/` clean.
- [ ] `cabal build all -f remote-only-untrusted` green (hardened build).
- [ ] The `Seal.Tools.Exec.Local` module is absent under the flag (CI
  asserts it).
- [ ] `selectUntrustedBackend` QuickCheck property holds: `mode=remote` ⇒
  never `Local`.
- [ ] No `Trusted`/`Audited` opcode shells out (Invariant 1) — verified by
  the `opRun`/`opRunUntrusted` split (a Trusted opcode has no `ExecBackend`
  in scope).
- [ ] Every value derived from user/LLM input reaching a subprocess argv
  is a validated newtype (Invariant 2) — verified by the `Seal.Tools.Args`
  newtypes + the executor signatures accepting only them.
- [ ] All Untrusted opcodes go through ACK-before-execute (inherited
  dispatcher, unchanged).
- [ ] No secret ever serialized (`orRecorded` secret-free; network opcodes
  redact auth via CPS).
- [ ] `mode=remote` with remote down ⇒ untrusted opcodes fail closed, never
  local fallback; transcript records the refusal.
- [ ] Host-key mismatch ⇒ hard failure, never bypassed.
- [ ] All twenty-three tasks committed (one commit per task).

**Next:** Phase 8 — Channels (Telegram, unified CLI, scheduler, MCP,
remaining providers). The `Container`/`Browser`/`Image`/`Tts` stubs become
real in future phases.