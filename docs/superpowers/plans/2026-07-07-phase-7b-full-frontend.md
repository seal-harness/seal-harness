# Phase 7b — Full Frontend Close-Duplication: Plan

> **For agentic workers:** Implement task-by-task, top to bottom. Each task is
> TDD (red → green → commit). Steps use checkbox (`- [ ]`) syntax. Do not start
> a task until the previous task's gate is green (`cabal build all` `-Werror`
> clean, `cabal test` green, `hlint src/ test/` clean, `npm run build` green,
> `npm run test` green where applicable — all in the Nix dev shell).
> One commit per task.

**Goal:** The Seal Harness web frontend close-duplicates the reference UI's
behavior and appearance. The visual layer (HTML shell, design tokens, Tailwind
config, App.css, component layout, animations) is copied **verbatim** from the
reference's `frontend/` build assets. The data layer (the `src/` TypeScript —
types, hooks, `streamClient`, components' data wiring) is **rebuilt** against
Seal Harness's own abstractions: Seal's gateway REST surface, Seal's
`StreamBroker` events, Seal's `Tab`/`SessionMeta`/`TranscriptEntry` types. The
Haskell gateway is widened so the SPA has every endpoint the reference SPA
calls. A Playwright E2E capstone drives the full loop.

**Parent roadmap:**
`docs/superpowers/plans/2026-06-28-seal-harness-roadmap.md` § Phase 7 (7b).

**Why this sub-phase:** 7a shipped the gateway + WS broker + a deliberately
minimal chat shell. 7b is the bulk of the SPA — Sidebar (active tabs, running
harnesses, recent + archived sessions), ChatArea (transcript → messages with
branch-from-here, per-session model dropdown, raw JSON modals, slash-command
bubbles, session stats), HarnessControls, NewTabComposer (provider/branch/
attach), TopBar/BottomBar/StatusDot/JsonTree, the five hooks, `streamClient`,
and the Seal-flavored types. The Haskell gateway gains the matching REST
endpoints (sessions archive/prompt/description, harnesses discover, tabs
new/close/dismiss/acknowledge/release/destroy, adopt). The tabs abstraction is
**the same across all channels** — what the user has open over CLI/Signal is
what they see in the web sidebar.

**Clean-room scope (user-directed, 2026-07-07):** the clean-room rule applies
primarily to the Haskell codebase. For the frontend, the visual layer (HTML,
CSS, design tokens, Tailwind config, build config) is copied verbatim from
the reference; the TypeScript data layer is rebuilt against Seal's types and
naming. No reference to "PureClaw" or any other product name appears in the
Seal repo (the `index.html` title becomes "Seal Harness"; the package name
becomes `seal-harness-frontend`).

## Tech Stack

Frontend: React 18 + TypeScript + Vite 5 + Tailwind 3 + Vitest 4 (mirrors the
reference's `frontend/package.json`). New dev deps for the Playwright capstone:
`@playwright/test` + `playwright` (a `playwright.config.ts` + a `e2e/`
directory; the Nix dev shell should provide `npx playwright install chromium`
or the CI provides a headed browser). The Playwright capstone runs against
`seal serve` on a random port — it does NOT run in the Haskell `cabal test`
suite; it runs via `npm run test:e2e` (a separate script in
`frontend/package.json`) and is gated separately from the Haskell test gate.

Backend: Haskell (GHC2021). New modules under `Seal.Gateway.*` widen the REST
surface. Reuse `wai`/`warp`/`websockets`/`aeson`/`http-types` from 7a. No new
Haskell deps expected.

Build/test:
```
nix develop --command cabal build all
nix develop --command cabal test
nix develop --command hlint src/ test/
nix develop --command bash -c 'cd frontend && npm install && npm run build'
nix develop --command bash -c 'cd frontend && npm run test'        # vitest unit
nix develop --command bash -c 'cd frontend && npm run test:e2e'    # playwright (seal serve must be runnable; the script starts it)
```

**Nix dev-shell precondition (T0b lands this):** the current `flake.nix`
`shell.tools` provides only `cabal`/`ghcid`/`hlint` — it does NOT provide
`node`/`npm`/`playwright`/a browser. The frontend dev/build currently works only
because `node`/`npm` happen to be on the user's global PATH. The Playwright
capstone (T13) needs `npx playwright install chromium` to download a browser
binary, which in turn needs system libs (libnss3, etc.) that the Nix shell
does not currently guarantee. T0b (below) extends `flake.nix` via the
haskell-nix `shell.buildInputs` / `shell.nativeBuildInputs` passthroughs (the
mkShell-backed mechanism for arbitrary nixpkgs packages — NOT `shell.tools`,
which is haskell-nix's attrset for Hackage Haskell tools only) so
`npm run build` / `npm run test` / `npm run test:e2e` all work inside
`nix develop` without relying on the user's global PATH. Until T0b lands, the
frontend tasks (T0–T9) may run against a system `node` if the user prefers,
but T13 MUST NOT be gated on an unverified assumption.

## Global Constraints

Inherited from the roadmap + 7a:

- **Module namespace:** new library modules under `Seal.*` (Haskell).
  Frontend is under `frontend/`, not `Seal.*`.
- **Coding style (Haskell):** GHC2021; conservative always-on
  `default-extensions`; per-file `OverloadedStrings` / `ImportQualifiedPost`.
  Whole-module imports; post-positive qualified imports.
- **Coding style (TypeScript):** strict, `noUnusedLocals`,
  `noUnusedParameters`, `noFallthroughCasesInSwitch`, `noUncheckedIndexedAccess`
  (mirrors the reference's `tsconfig.json`). Component/hook file structure
  mirrors the reference (one component per file under `src/components/`, one
  hook per file under `src/hooks/`, `src/lib/streamClient.ts`, `src/types.ts`).
- **Errors (Haskell):** `Either Text` / `ExceptT Text` default. The gateway
  returns HTTP error codes + JSON bodies.
- **Errors (TypeScript):** hooks surface `{ data, error, loading }`-style
  state; `streamClient` tracks `lastError`. No throwing across render.
- **GHC flags:** `-Wall -Werror` plus the strict set.
- **TDD (Haskell):** red → green → commit. The gateway widening is tested via
  `http-client` against a test server (mirrors 7a's `ApiSpec`).
- **TDD (TypeScript):** red → green → commit. Components + hooks get Vitest +
  React Testing Library specs mirroring the reference's `__tests__/`
  structure. The Playwright E2E is the capstone (a single `e2e/capstone.spec.ts`).
- **hlint clean** before each Haskell commit.
- **`tsc --noEmit` clean** before each frontend commit (the `build` script
  runs `tsc && vite build`; both must pass).
- **No secret ever serialized.** The gateway never returns a vault secret.
  `/api/sessions/:id/send` routes through `Seal.Ingest`, so the no-secret
  invariant is inherited from the agent loop. Session/channel user ids are NOT
  secrets (they are transport metadata — the same the CLI/Signal channels
  put in the transcript's `_te_metadata`).
- **Loopback-by-default** + WS Origin allowlist (inherited from 7a, unchanged).
- **Cabal registration:** new library modules in `exposed-modules`, new test
  specs in `other-modules`, both alphabetical; new specs wired into
  `test/Main.hs`.
- **Commits:** one per task.
- **Clean-room (frontend, scoped):** HTML + CSS + Tailwind/PostCSS/Vite/Vitest
  config + `design-tokens.css` + `App.css` + component *layout/structure*
  copied verbatim. TypeScript data wiring (types, fetch URLs, hook state
  shapes, `streamClient` event mapping) rebuilt against Seal's gateway + types.
  No "PureClaw" / reference product name in the Seal repo.

## Non-goals (explicitly out of scope for 7b)

- **No Phase 4 untrusted opcodes.** `SHELL_EXEC`/`FILE_WRITE`/etc. land in
  Phase 4. 7b's `/api/tabs/new` may take a `kind` of `provider`/`harness`/
  `branch`/`attach` (matching the reference), but the `shell`/`ssh` tab kinds
  that would route to Untrusted execution are stubbed (return 501) until
  Phase 4 wires the executor.
- **No Phase 8 channels.** Telegram, the unified CLI channel, the scheduler,
  MCP, and remaining providers are Phase 8. 7b's sidebar shows the channels
  that already exist (CLI via `/tabs`, Signal from Phase 2, Web from 7a).
- **No new agent-loop logic.** The gateway reuses the existing
  tab/harness/session surface; 7b only widens the REST endpoints + builds the
  SPA. The agent loop, transcript format, ISA dispatch, and ingress gate are
  untouched.
- **No pairing/multi-device hardening.** Phase 8. The gateway stays
  single-user loopback in 7b.
- **No `Audited` `TrustLevel` changes.** Inherited as-is from Phase 5.

---

## Task map

| Task | Title | Gate |
|---|---|---|
| **T0** | Copy visual layer verbatim + rename to Seal Harness + `tsc`/`build` green | `npm run build` green; `index.html` title is "Seal Harness"; no reference product name anywhere in the repo |
| **T0b** | Extend `flake.nix` `shell.buildInputs` with `node` + `chromium` (Playwright prereq) | `nix develop --command bash -c 'node --version && npx playwright --version'` green; `nix develop --command cabal build all` still green |
| **T1** | Seal-flavored types (`src/types.ts`) against the gateway's actual JSON | `npm run build` green; types match a snapshot of the 7a API JSON; Vitest unit on `sessionDisplayTitle`/`tabDisplayLabel`/`findSession` parity |
| **T2** | `streamClient` rebuilt against Seal's `StreamBroker` wire protocol | Vitest green; client connects to a fake WS, sends `focus`, receives `hello` + events, tracks `lastError` |
| **T3** | `useApi` hook against Seal's widened REST surface | Vitest green; every fetch mocked; the hook exposes the same shape the reference's components consume |
| **T4** | `useListsStream` + `useTranscriptStream` + `useSessionActivityStream` + `useNewTabSpec` | Vitest green per hook |
| **T5** | `StatusDot` + `TopBar` + `BottomBar` + `JsonTree` (chrome) | Vitest green per component |
| **T6** | `Sidebar` + `ActiveTabs` + `RunningHarnesses` (recent + archived sessions) | Vitest green |
| **T7** | `ChatArea` (transcript → messages, branch-from-here, raw JSON modal, slash bubbles, session stats) | Vitest green |
| **T8** | `HarnessControls` + `NewTabComposer` (provider/branch/attach) | Vitest green |
| **T9** | `App.tsx` composition + `App.css` final wiring | `npm run build` green; the app renders against a mock backend in Vitest |
| **T10** | Gateway widening — sessions archive/prompt/description + harnesses discover + tabs new/close/dismiss/acknowledge/release/destroy + adopt | `cabal test` green; `ApiSpec` covers every new route |
| **T11** | Gateway widening — `/api/agents` + `/api/providers` + `/api/providers/:p/models` | `cabal test` green |
| **T12** | Wire the rebuilt SPA to the widened gateway end-to-end (manual smoke + `npm run build`) | `seal serve` manual smoke: sidebar, chat, branch, harness, archive all work |
| **T13** | Playwright E2E capstone (`e2e/capstone.spec.ts`) | `npm run test:e2e` green against a running `seal serve` |

---

## T0 — Copy visual layer verbatim + rename to Seal Harness

**Why:** land the visual foundation (HTML shell, design tokens, Tailwind/PostCSS
config, build config, App.css skeleton) by copying the reference's frontend
build assets wholesale, then rename every reference-product string to "Seal
Harness". The TypeScript data layer is stubbed to a no-op `App.tsx` for this
task — the real components land in T5–T9.

**Files (copy verbatim from the reference `frontend/`):**
- `index.html` (then change `<title>` to "Seal Harness")
- `package.json` (then change `name` to `seal-harness-frontend`; add
  `@playwright/test` + `playwright` dev deps + the `test:e2e` script — the
  script will be filled in T13)
- `tailwind.config.js`, `postcss.config.js`, `tsconfig.json`,
  `vite.config.ts`, `vitest.config.ts`
- `design-tokens.css` (verbatim — the design system)
- `src/App.css` (verbatim — the global styles + animations)
- `src/main.tsx` (verbatim — the React root mount)
- `src/test-setup.ts` (verbatim — the Vitest setup)
- `src/vite-env.d.ts` (verbatim)
- `assets/` (verbatim — logo SVGs; reference to "PureClaw" in any SVG title
  → "Seal Harness")

**Files (write fresh, minimal):**
- `src/App.tsx` — a placeholder that imports `App.css` and renders the brand
  name + an empty layout shell. ~30 LOC. Replaced in T9.

**Files (do NOT copy yet):** `src/components/`, `src/hooks/`, `src/lib/`,
`src/types.ts`, `src/data/`, `src/__tests__/`. These land in T1–T9 (rebuilt
against Seal types).

### Steps

- [ ] Copy the eight config/style files verbatim into `frontend/`.
- [ ] Rename: `index.html` `<title>`, `package.json` `name`, any SVG title
  attribute. Grep the whole `frontend/` for the reference product name —
  there must be zero matches.
- [ ] Write the minimal `src/App.tsx` placeholder.
- [ ] `nix develop --command bash -c 'cd frontend && npm install && npm run build'`
  → green. `tsc --noEmit` green.
- [ ] `nix develop --command bash -c 'cd frontend && npm run test'` → green
  (passWithNoTests).
- [ ] Grep `frontend/` for any reference product name — must be empty.
- [ ] **Commit.** `feat(frontend): copy visual layer + rename to Seal Harness`

---

## T0b — Extend `flake.nix` with node + Playwright for the dev shell

**Why:** the Playwright capstone (T13) needs `node`/`npm`/`npx` + a browser
binary + system libs available inside `nix develop`. The current
`flake.nix:44-48` `shell.tools` provides only `cabal`/`ghcid`/`hlint`. The
frontend dev/build currently works only because `node`/`npm` happen to be on
the user's global PATH — this is an unstated assumption the gate caught. T0b
makes the dev shell self-contained for the frontend toolchain so `npm run
build` / `npm run test` / `npm run test:e2e` work inside `nix develop` without
relying on the host PATH.

**Module:** `flake.nix`

### Design

The haskell-nix `shell` argument (and `shellFor`) accepts **`buildInputs`**
and **`nativeBuildInputs`** lists, which are passed through to `mkShell`
(verified against the haskell-nix reference docs: "Passed to mkDerivation via
mkShell"). These are the correct mechanism for arbitrary nixpkgs packages —
**NOT `shell.tools`** (which is an attrset of Hackage Haskell tools like
`cabal`/`hlint`/`hoogle`, documented as `{ cabal = "3.2.0.0"; }` and built from
Hackage). The current `flake.nix:44-48` uses `shell.tools = { cabal = ...;
ghcid = ...; hlint = ... }` for the Haskell tools; T0b ADDS a
`shell.buildInputs` (or `shell.nativeBuildInputs`) sibling for the frontend
toolchain, leaving `shell.tools` untouched.

Add to the `sealHarnessProject` `cabalProject'` call (sibling to `shell.tools`):

```nix
shell.tools = { cabal = { }; ghcid = { }; hlint = { }; };
shell.buildInputs = with pkgs; [
  nodejs_22           # provides node + npm + npx
  chromium            # the browser Playwright drives (system-libs-included)
];
# The @playwright/test npm package (installed via `npm install` in T0) provides
# the driver; `PLAYWRIGHT_BROWSERS_PATH` points it at the nix-provided chromium
# so `npx playwright install` is a no-op (or set `--with-deps` if needed).
```

Two viable approaches for the driver:
- (a) `pkgs.nodePackages.playwright` — the npm package wrapped by nixpkgs
  (if available in the nixpkgs-unstable pin). Adds the driver to the shell
  PATH; the `@playwright/test` npm dep still installs the driver into
  `frontend/node_modules`, but the nix wrapper handles the system-lib
  bootstrap.
- (b) Rely on `@playwright/test` from `npm install` (T0's `package.json`)
  + add `pkgs.chromium` to `shell.buildInputs` for the browser binary, and
  set `PLAYWRIGHT_BROWSERS_PATH` in `shellHook` to point at the nix-provided
  chromium so `npx playwright install chromium` is a no-op. Preferred (simpler
  + no nixpkgs-wrapping needed).

If neither `nodejs_22` nor `chromium` is available in the pinned
nixpkgs-unstable, fall back to: provide `nodejs` (any LTS) via
`shell.buildInputs` and document that
`nix develop --command bash -c 'cd frontend && npx playwright install
chromium'` must run once on first use (the npm `@playwright/test` package
installs the driver; the browser download is the one-time step). In that
fallback, the CI workflow (`.github/workflows/ci.yml`) must run the
`playwright install` step before `npm run test:e2e`.

### TDD steps

- [ ] **Verify availability.** In the Nix dev shell, check
  `nix-env -qaP 'nodejs_22'` / `nix-env -qaP 'chromium'` against the pinned
  nixpkgs. Pick approach (a) or (b) based on what's available.
- [ ] **Red.** Before the flake change, run
  `nix develop --command bash -c 'command -v node && command -v npx && npx playwright --version'`
  — the playwright version is expected to fail (no `@playwright/test`
  installed yet, but the driver binary should resolve once T0 copies the
  reference `package.json` + `npm install` runs). The flake change should
  make `node`/`npm`/`npx` available on the shell PATH regardless of the
  host PATH.
- [ ] **Green.** Add `shell.buildInputs = [ nodejs_22 chromium ]` (sibling to
  `shell.tools`, NOT inside it) to the `cabalProject'` call in `flake.nix`.
  Add a `shell.shellHook` exporting `PLAYWRIGHT_BROWSERS_PATH` if using
  approach (b). Re-enter `nix develop`. Verify
  `command -v node && command -v npm && command -v npx` all resolve to
  Nix-store paths (not `/Users/zoe/...` global PATH).
- [ ] **Green-verify.**
  - `nix develop --command cabal build all` green (the Haskell build must not
    regress — `node`/`chromium` in the shell is additive).
  - `nix develop --command cabal test` green.
  - `nix develop --command bash -c 'cd frontend && npm install && npm run build'`
    green (after T0's `package.json` is in place; or stub the frontend build
    with an empty `dist/` if T0 hasn't landed — the gate is the flake change,
    not the frontend build).
  - `nix develop --command bash -c 'npx playwright --version'` resolves.
- [ ] **Commit.** `feat(nix): add node + playwright to dev shell for frontend toolchain`

---

## T1 — Seal-flavored types (`src/types.ts`)

**Why:** the SPA's data vocabulary, rebuilt against Seal's actual gateway JSON
shape (not the reference's). The reference's `types.ts` is the structural
template; the field names + semantics are Seal's.

**Module:** `frontend/src/types.ts`

### Design

Mirror the reference's exports, but every type matches Seal's JSON:

- `AgentStatus`, `Agent` — Seal agent defs come from `/api/agents` (the
  `Seal.Agent.Def.Backend` shape: `name`, `isDefault`).
- `HarnessActivity`, `HarnessInfo` — Seal harness registry liveness
  (`Idle`/`Thinking`/`AwaitingInput`/`Exited`/`Orphaned`) mapped to the
  reference's `'thinking' | 'idle' | 'needs-input' | 'stopped'` vocabulary.
- `SessionInfo` — Seal `SessionMeta` + the channel provenance fields
  (`channel: string | null`, `channelUserId: string | null`) from
  `MessageSource` (Phase 2a). `id`/`agent`/`runtime`/`model`/`lastActive`/
  `createdAt`/`description`/`autoSummary`/`firstMessageSnippet`.
- `TabInfo` — Seal `Tab` (the `tlTabs` JSON the gateway already emits in 7a's
  `/api/tabs`, widened in T10 with `status`/`origin`/`extModified`/`stale`/
  `attachCommand`). `index` (number), `kind` (string), `label` (string|null),
  `session_id` (string|null).
- `TabStatus`, `TabOrigin` — Seal's `Liveness` → UI vocab; `HarnessOrigin`
  (`Spawned`/`Discovered`/`Adopted`) → UI vocab.
- `DiscoverableWindow` — Seal `Harness.Discovery` shape.
- `AgentInfo`, `ProviderInfo` — Seal agent defs + `Seal.Providers.Registry`.
- `TranscriptEntry` — Seal's two-file transcript JSONL line (the verbatim
  `raw` field), with `id`/`timestamp`/`direction`/`payload`/`harness`/`model`/
  `streaming`. The `raw` field is required (everything visible — inherited
  principle).
- `CodeSpan`, `ToolCallInfo`, `MessageContent`, `Message` — the message
  derivation types (text/code/list/collapsed system/thinking/raw JSON/tool
  call). Structural mirror of the reference; field names unchanged (these are
  UI-internal, not wire types).
- Helpers: `sessionDisplayTitle`, `shortenModel`, `sessionSubtitle`,
  `tabDisplayLabel`, `findSession`. Same semantics; "PureClaw" string
  literals → "Seal Harness" where present (e.g. the `pureclaw tui` channel
  label → the equivalent Seal channel label).

### TDD steps

- [ ] **Red.** Write `frontend/src/__tests__/types.test.ts` (Vitest):
  - `sessionDisplayTitle` cascade: description → autoSummary → snippet →
    agent → id prefix → "New session".
  - `tabDisplayLabel` resolves via the backing session, else `tab.label`,
    else "…".
  - `findSession` searches recents ∪ archived ∪ tabSessions.
  - `shortenModel` strips the model date suffix.
  - `sessionSubtitle` formats "agent · channel:userId".
- [ ] **Red-verify.** `npm run test` fails.
- [ ] **Green.** Implement `src/types.ts`. Make the tests pass.
- [ ] **Green-verify.** `npm run build` green; `npm run test` green; hlint
  unaffected (Haskell task).
- [ ] **Commit.** `feat(frontend): Seal-flavored types + helpers`

---

## T2 — `streamClient` rebuilt against Seal's `StreamBroker`

**Why:** the singleton WS client. Seal's broker (7a's `StreamBroker`) emits
`BrokerEvent`s (`BeEntryRecorded`/`BeHarnessStatus`/`BeListsSnapshot`); the
client sends `focus` ops. The reference's `streamClient` is the structural
template; the event-type strings + the `hello` handshake match Seal's wire
protocol (7a's `Seal.Gateway.Stream`).

**Module:** `frontend/src/lib/streamClient.ts`

### Design

- `StreamClient` singleton: open a WS to `ws://<host>:<ws_port>/` (Seal 7a
  uses a separate WS port — `8081` by default; the client reads it from a
  config constant or `import.meta.env.VITE_WS_PORT`).
- On open: receive `hello` (Seal's one-shot hello on upgrade).
- `focus(sessionId, since?)` — send a `focus` op; `since` triggers replay
  mode (7a's replay-failed fallback).
- Event subscription: callbacks for `entry`, `harness-status`, `lists` (the
  three `BrokerEvent` variants).
- `lastError` tracking; auto-reconnect with backoff (mirror the reference).
- Origin normalization (`http:` → `ws:`, `https:` → `wss:`).

### TDD steps

- [ ] **Red.** Write `frontend/src/lib/__tests__/streamClient.test.ts`:
  - Use a fake WS (the `ws` npm package or a mock) on a random port.
  - Client connects, receives `hello`, sends `focus`, receives an `entry`
    event for the focused session, does NOT receive an event for a different
    session.
  - `lastError` is set on a malformed frame and cleared on a good one.
  - Reconnect with backoff after a close.
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Implement `streamClient.ts`. Green.
- [ ] **Commit.** `feat(frontend): streamClient against Seal broker`

---

## T3 — `useApi` hook against Seal's widened REST surface

**Why:** the data-fetching hook the components consume. Mirrors the reference's
`useApi` shape (a `useEffect`-driven initial fetch + imperative mutators),
but every URL points at Seal's gateway (the widened surface from T10/T11).

**Module:** `frontend/src/hooks/useApi.ts`

### Endpoints (the contract T10/T11 must implement):

```
GET  /api/sessions                          -> SessionInfo[]   (recent, non-archived, non-open-tab)
GET  /api/sessions/archived                 -> SessionInfo[]
GET  /api/sessions/:id/transcript           -> TranscriptEntry[]
POST /api/sessions/:id/send                 -> { kind: "assistant" | "slash", response? }
PUT  /api/sessions/:id/description          (body: { description: string })
PUT  /api/sessions/:id/archived             (body: { archived: boolean })
PUT  /api/sessions/:id/prompt               (body: { prompt: string })
GET  /api/tabs                              -> TabInfo[] (wire: snake_case)
POST /api/tabs/new                          (body: { kind, provider?, model?, agent?, branch_from?, harness_id? })
POST /api/tabs/:index/close
POST /api/tabs/:index/dismiss
POST /api/tabs/:index/acknowledge
POST /api/tabs/:index/release
POST /api/tabs/:index/destroy
GET  /api/agents                            -> AgentInfo[]
GET  /api/providers                         -> ProviderInfo[]
GET  /api/providers/:p/models               -> string[]
GET  /api/harnesses                         -> HarnessInfo[]
GET  /api/harnesses/discover               -> DiscoverableWindow[]
POST /api/adopt                             (body: { window..., consent_confirmed: true })
```

### TDD steps

- [ ] **Red.** Write `frontend/src/hooks/__tests__/useApi.test.ts`:
  - Mock `fetch` for every endpoint; assert the hook exposes the right state
    shape (`sessions`, `archivedSessions`, `tabs`, `agents`, `providers`,
    `harnesses`, `discoverable` + the mutator functions).
  - `sendSessionMessage` returns the `{ kind, response? }` body.
  - `createTab` POSTs the right body; `closeTab`/`dismissTab`/etc. hit the
    right URLs.
  - `setSessionDescription`/`archiveSession`/`setSessionPrompt` PUT.
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Implement `useApi.ts`. Green.
- [ ] **Commit.** `feat(frontend): useApi hook against Seal gateway`

---

## T4 — `useListsStream` + `useTranscriptStream` + `useSessionActivityStream` + `useNewTabSpec`

**Why:** the four streaming/composer hooks. `useListsStream` consumes
`BeListsSnapshot`; `useTranscriptStream` seeds via HTTP + tails via
`BeEntryRecorded` (deduped by entry id, sorted by timestamp); the composer
state machine drives `NewTabComposer`.

**Modules:** `frontend/src/hooks/{useListsStream,useTranscriptStream,useSessionActivityStream,useNewTabSpec}.ts`

### TDD steps

- [ ] **Red.** Write one Vitest spec per hook (`__tests__/<hook>.test.ts`):
  - `useListsStream`: receives a `lists` event, updates state.
  - `useTranscriptStream`: seeds from HTTP, dedupes WS entries by id, sorts
    by timestamp, sets `streaming` on `entry-update`.
  - `useSessionActivityStream`: per-session thinking/idle state.
  - `useNewTabSpec`: the composer state machine — provider select → model
    select → branch toggle → attach toggle; lazy backend session create on
    first send; consent_confirmed gate for adopt.
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Implement each hook. Green per hook.
- [ ] **Commit.** `feat(frontend): lists/transcript/activity/composer hooks`

---

## T5 — `StatusDot` + `TopBar` + `BottomBar` + `JsonTree` (chrome)

**Why:** the four chrome components. Layout/CSS copied from the reference;
props/state rebuilt against Seal types.

**Modules:** `frontend/src/components/{StatusDot,TopBar,BottomBar,JsonTree}.tsx`

### TDD steps

- [ ] **Red.** One Vitest + React Testing Library spec per component:
  - `StatusDot`: renders the right color/animation per `AgentStatus`.
  - `TopBar`: brand name "Seal Harness", the logo.
  - `BottomBar`: the status footer.
  - `JsonTree`: renders a nested JSON object; toggleable expand/collapse.
- [ ] **Green.** Implement. Green.
- [ ] **Commit.** `feat(frontend): chrome components (StatusDot/TopBar/BottomBar/JsonTree)`

---

## T6 — `Sidebar` + `ActiveTabs` + `RunningHarnesses` (recent + archived sessions)

**Why:** the left pane. Active tabs bind to sessions/harnesses (Seal's
`TabInfo`/`SessionInfo`/`HarnessInfo`); running harnesses from the registry;
recent + archived sessions with per-session activity dots, unread counts, age
pills, archive/unarchive buttons.

**Modules:** `frontend/src/components/{Sidebar,ActiveTabs,RunningHarnesses}.tsx`

### TDD steps

- [ ] **Red.** One spec per component:
  - `ActiveTabs`: renders the tab list, highlights the focused tab, click
    focuses.
  - `RunningHarnesses`: renders `HarnessInfo[]` with activity dots.
  - `Sidebar`: composes the three; recent sessions section, archived section,
    archive/unarchive buttons call the `useApi` mutators.
- [ ] **Green.** Implement. Green.
- [ ] **Commit.** `feat(frontend): sidebar (active tabs + harnesses + sessions)`

---

## T7 — `ChatArea` (transcript → messages, branch-from-here, raw JSON, slash bubbles, stats)

**Why:** the central pane. `transcriptToMessages` maps Seal `TranscriptEntry[]`
→ `Message[]` (text/code/list/collapsed system/thinking/raw JSON/tool calls +
matched results). Branch-from-here opens `NewTabComposer` with a
`branch_from`. Per-session model dropdown. In-place description edit.
Optimistic pending-thinking + remote-thinking. Slash-command output bubbles
(transient — not persisted). Session stats (tokens used / context window) —
the **context window denominator** comes from
`GET /api/providers/:p/models/:m/context` (T11), looked up by the session's
provider + model. A tooltip shows the full context window + max output tokens.

**Module:** `frontend/src/components/ChatArea.tsx`

### TDD steps

- [ ] **Red.** `frontend/src/components/__tests__/ChatArea.test.tsx`:
  - Renders a 3-message transcript (user / assistant-with-tool-call / system).
  - Branch-from-here on a user row triggers the composer callback with the
    entry id.
  - Raw JSON modal toggles.
  - Slash bubble renders transiently.
  - Per-session model dropdown changes call `useApi`.
- [ ] **Green.** Implement. Green.
- [ ] **Commit.** `feat(frontend): ChatArea (transcript → messages + branch + raw JSON)`

---

## T8 — `HarnessControls` + `NewTabComposer`

**Why:** the right pane + the inline new-tab form. Harness controls: status,
backing session, release (adopted only), destroy (gated confirmation).
NewTabComposer: provider/model/agent select, branch-from-here, existing-harness
attach (adopt with `consent_confirmed`).

**Modules:** `frontend/src/components/{HarnessControls,NewTabComposer}.tsx`

### TDD steps

- [ ] **Red.** One spec per component:
  - `HarnessControls`: renders status; release button hidden for non-adopted;
    destroy shows confirmation.
  - `NewTabComposer`: provider select populates models; branch toggle;
    attach flow with consent gate.
- [ ] **Green.** Implement. Green.
- [ ] **Commit.** `feat(frontend): HarnessControls + NewTabComposer`

---

## T9 — `App.tsx` composition + `App.css` final wiring

**Why:** wire the components together with the hooks + `streamClient` into the
full layout (Sidebar | ChatArea | HarnessControls, with TopBar/BottomBar chrome
and the NewTabComposer overlay). Replace the T0 placeholder.

**Module:** `frontend/src/App.tsx`

### TDD steps

- [ ] **Red.** `frontend/src/__tests__/App.test.tsx`:
  - Renders the full layout against a mocked `useApi` + mocked `streamClient`.
  - Clicking a session in the sidebar focuses the chat area.
  - Sending a message calls `useApi.sendSessionMessage` + optimistic pending.
- [ ] **Green.** Implement `App.tsx` (composition only — no new logic). Green.
- [ ] **Green-verify.** `npm run build` green (tsc + vite). `npm run test` green.
- [ ] **Commit.** `feat(frontend): App composition + full layout`

---

## T10 — Gateway widening: tabs CRUD + harnesses + adopt

**Why:** the SPA's tab/harness/adopt endpoints. 7a's `apiApp` only handles
`/api/health`, `/api/tabs` (GET), `/api/sessions` (GET). T10 adds the POST
mutators + the harness discover + adopt.

**Modules (file scope — ALL must be listed; widening `ApiDeps` cascades):**
- `src/Seal/Gateway/API.hs` — widen `ApiDeps` (add `adHarnessRegistry`,
  `adAdoptionAuthority`) + the new routes + `tabToJson` widened with
  `status`/`origin`/`extModified`/`stale`/`attachCommand`/`session_id`
  (derived from `tRef`).
- `src/Seal/Gateway/Server.hs` — `gatewayApp`/`runGateway` signatures widen to
  carry the new `ApiDeps` fields (passthrough only — no construction here).
- `src/Seal/Command/Serve.hs` — the production construction site (line 66);
  must build a `HarnessRegistry` (currently absent from `runServeMain`),
  thread it + the adoption authority into the widened `ApiDeps`. This is the
  load-bearing wiring change the gate flagged.
- `test/Seal/Gateway/ApiSpec.hs` — widen with the new route tests.
- `test/Seal/Gateway/ServerSpec.hs:38-43` — `mkDeps` constructs `ApiDeps`
  with only two fields today; must add the new fields (a fake/empty
  `HarnessRegistry` + a no-op adoption authority) or it will fail to compile
  after the `ApiDeps` record widens.
- `test/Seal/Phase7aSpec.hs:52,81` — both `ApiDeps { ... }` constructions
  must add the new fields (same fake/empty values) or fail to compile.

> **Why so many files:** Haskell record-construction syntax requires every
> field. Widening `ApiDeps` is a breaking change to every call site. The
> first-review gate caught that the original draft omitted `Serve.hs` +
> `ServerSpec.hs` + `Phase7aSpec.hs`; all three must change in lockstep with
> `API.hs`.

### New routes

```
POST /api/tabs/new                          -> { index: number }
POST /api/tabs/:index/close                  -> 204
POST /api/tabs/:index/dismiss                -> 204
POST /api/tabs/:index/acknowledge            -> 204
POST /api/tabs/:index/release                -> 204
POST /api/tabs/:index/destroy                -> 204
GET  /api/harnesses                          -> HarnessInfo[]
GET  /api/harnesses/discover                 -> DiscoverableWindow[]
POST /api/adopt                              -> { ok: true, id: string } | { error: string }
```

`/api/tabs/new` accepts `{ kind, provider?, model?, agent?, branch_from?, harness_id? }`
and routes through the existing `TabsHandle` (Phase 6b). `shell`/`ssh` kinds
return 501 until Phase 4. `/api/adopt` requires `consent_confirmed: true`
else 400 (mirrors `Seal.Security.Adoption`).

### TDD steps

- [ ] **Red.** Widen `ApiSpec`:
  - `POST /api/tabs/new` with `{ kind: "provider", provider: "anthropic",
    model: "claude-sonnet-4" }` → `{ index: 0 }`; `GET /api/tabs` reflects it.
  - `POST /api/tabs/0/close` → 204; `GET /api/tabs` is empty.
  - `POST /api/tabs/new` with `{ kind: "shell" }` → 501.
  - `GET /api/harnesses` returns the registry snapshot.
  - `POST /api/adopt` without `consent_confirmed` → 400; with it → 200.
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Widen `API.hs`; wire the harness registry + adoption into
  `ApiDeps`. Green.
- [ ] **Green-verify.** `cabal build all` + full suite green; hlint clean.
- [ ] **Commit.** `feat(gateway): tabs CRUD + harnesses + adopt endpoints`

---

## T11 — Gateway widening: sessions + agents + providers (+ model context window)

**Why:** the session archive/description/prompt + agents + providers + models
endpoints. Includes the **model context window lookup** the roadmap § 7b
deliverable 7 names explicitly (the denominator of "tokens / context window"
session stats — the source was missing in the first draft, flagged by the
gate).

**Modules (file scope — same cascade as T10):**
- `src/Seal/Gateway/API.hs` — widen `ApiDeps` further (add `adAgentDefs` from
  `Backends`, `adProviderRegistry`, `adSessionStore`) + the new routes.
- `src/Seal/Gateway/Server.hs` — passthrough of the widened `ApiDeps`.
- `src/Seal/Command/Serve.hs` — thread `bAgentDefs backends` +
  `Seal.Providers.Registry` + the session store into `ApiDeps`.
- `test/Seal/Gateway/ApiSpec.hs` — widen.
- `test/Seal/Gateway/ServerSpec.hs` + `test/Seal/Phase7aSpec.hs` — add the
  new fields to the `ApiDeps` constructions.

### New routes

```
GET  /api/sessions                          -> SessionInfo[]   (recent, dedupes open-tab sessions)
GET  /api/sessions/archived                 -> SessionInfo[]
GET  /api/sessions/:id/transcript           -> TranscriptEntry[]
POST /api/sessions/:id/send                 -> { kind, response? }
PUT  /api/sessions/:id/description
PUT  /api/sessions/:id/archived
PUT  /api/sessions/:id/prompt
GET  /api/agents                            -> AgentInfo[]
GET  /api/providers                         -> ProviderInfo[]
GET  /api/providers/:p/models               -> { name: string, contextWindow: number }[]
GET  /api/providers/:p/models/:m/context    -> { contextWindow: number, maxOutputTokens: number }
```

`/api/sessions/:id/send` routes through `Seal.Ingest` (the same path CLI/Signal
use) — no new agent loop. The session list dedupes sessions backing open tabs
(so the sidebar doesn't show a duplicate row for an open tab's session).

**Model context window lookup:** `GET /api/providers/:p/models` is widened
to return `{ name, contextWindow }[]` (not bare `string[]`) so the frontend
can render the "X / Y tokens" stat per session with a real denominator. A
dedicated `GET /api/providers/:p/models/:m/context` returns the full context
window + max output tokens (for the session-stats tooltip). The
`contextWindow` value comes from a static per-model table maintained in
`Seal.Providers.Registry` (or a new `Seal.Providers.ContextWindow` module) —
the known-models table is keyed by model id prefix (e.g. `claude-sonnet-*` →
200000; `gpt-4o-*` → 128000; `llama3-*` → 8192). Unknown models default to
0 (the frontend shows "—"). This is a pure lookup, no LLM call.

### TDD steps

- [ ] **Red.** Widen `ApiSpec` for every new route. Cover the
  `/api/sessions/:id/send` → `Seal.Ingest` routing with a fake ingest (return
  a canned `{ kind: "slash", response: "/help text" }` for input "/help").
- [ ] **Green.** Implement. Green.
- [ ] **Green-verify.** `cabal build all` + full suite green; hlint clean.
- [ ] **Commit.** `feat(gateway): sessions + agents + providers endpoints`

---

## T12 — Wire the rebuilt SPA to the widened gateway (manual smoke)

**Why:** end-to-end manual verification before the automated Playwright
capstone. Catches wiring mismatches the unit tests miss (CORS, WS port, JSON
field-name drift).

### Steps

- [ ] `nix develop --command bash -c 'cd frontend && npm run build'` →
  `frontend/dist/` produced.
- [ ] `nix develop --command cabal run seal -- serve` → opens on
  `http://localhost:8080`.
- [ ] Manual: open the UI, sidebar renders, start a new tab (provider), chat,
  see the transcript stream over WS, branch from a row, start a harness tab,
  see it in the sidebar, destroy it, archive a session, unarchive it.
- [ ] If any drift: fix the SPA ↔ gateway field names; re-verify.
- [ ] **Commit (if fixes).** `fix(frontend): SPA ↔ gateway field alignment`

---

## T13 — Playwright E2E capstone

**Why:** the automated capstone (roadmap § 7b milestone). A single
`e2e/capstone.spec.ts` drives the full loop against a running `seal serve`.

**Modules:** `frontend/playwright.config.ts`, `frontend/e2e/capstone.spec.ts`,
`frontend/package.json` (`test:e2e` script).

### The spec

```typescript
// e2e/capstone.spec.ts
import { test, expect } from '@playwright/test'

test('Phase 7b capstone — full loop', async ({ page }) => {
  await page.goto('http://localhost:8080')
  await expect(page).toHaveTitle('Seal Harness')
  // Sidebar visible
  await expect(page.getByText('Recent')).toBeVisible()
  // New tab → provider
  await page.getByRole('button', { name: /new tab/i }).click()
  await page.getByLabelText(/provider/i).selectOption({ label: /anthropic/i })
  await page.getByRole('button', { name: /create/i }).click()
  // Chat
  await page.getByPlaceholder(/type a message/i).fill('hello')
  await page.keyboard.press('Enter')
  // Transcript streams
  await expect(page.getByText('hello')).toBeVisible()
  // Branch from the first user row
  await page.getByRole('button', { name: /branch from here/i }).first().click()
  // Harness tab (skipped if no tmux in CI — gated)
  // Archive a session
  await page.getByRole('button', { name: /archive/i }).first().click()
  // Unarchive
  await page.getByRole('button', { name: /archived/i }).click()
  await page.getByRole('button', { name: /unarchive/i }).first().click()
})
```

The `test:e2e` script starts `seal serve` on a random port, waits for the
health endpoint, runs Playwright, tears down. (A `e2e/global-setup.ts`
spawns `seal serve` as a child process; `global-teardown.ts` kills it.)

### Steps

- [ ] **Red.** Write `playwright.config.ts` + `e2e/capstone.spec.ts` +
  `e2e/global-setup.ts` + `e2e/global-teardown.ts` + the `test:e2e` script.
  Run `npm run test:e2e` — fails (no `seal serve` running, or the spec
  mismatches the UI).
- [ ] **Green.** Make it pass against a real `seal serve` (Nix dev shell,
  with `frontend/dist` built). The harness-tab part of the spec is gated on
  `tmux` being available — skip if not (CI may not have tmux).
- [ ] **Green-verify.** `npm run test:e2e` green locally.
- [ ] **Commit.** `test(frontend): Playwright E2E capstone (Phase 7b)`

---

## Milestone (7b)

**Definition of Done (whole sub-phase):**

- [ ] `cabal build all` is `-Werror` clean (Nix dev shell).
- [ ] `cabal test` green including the widened `ApiSpec`.
- [ ] `hlint src/ test/` clean.
- [ ] `npm run build` green (`tsc --noEmit` + `vite build`).
- [ ] `npm run test` green (Vitest unit + component specs).
- [ ] `npm run test:e2e` green (Playwright capstone, with tmux-dependent
      parts skipped when tmux is absent).
- [ ] The web UI close-duplicates the reference's behavior and appearance —
      sidebar with tabs + recent/archived sessions, chat area with
      branch-from-here + per-session model + raw JSON modals, harness
      controls, new-tab composer (provider/branch/attach), live WS
      streaming, slash-command output bubbles.
- [ ] The tabs abstraction is the same across all channels — what the user
      has open over CLI/Signal is what they see in the web sidebar
      (verified by the shared `TabsHandle` + the capstone).
- [ ] No reference product name anywhere in the Seal repo (grep clean).
- [ ] All fourteen tasks committed (one commit per task).

**Manual smoke test:**
```
nix develop --command bash -c 'cd frontend && npm install && npm run build'
nix develop --command cabal run seal -- serve
# open http://localhost:8080 → full UI works
```

**Next:** Phase 4 — Untrusted opcode breadth + isolation (the
`TerminalBackend` family + `SHELL_EXEC`/`FILE_WRITE`/etc. + the remote-only
split). The `shell`/`ssh` tab kinds stubbed in T10 become real in Phase 4.