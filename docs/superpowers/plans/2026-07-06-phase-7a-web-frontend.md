# Phase 7a — Gateway + WS Broker + Minimal Chat Shell: Plan

> **For agentic workers:** Implement task-by-task, top to bottom. Each task is
> TDD (red → green → commit). Steps use checkbox (`- [ ]`) syntax. Do not start
> a task until the previous task's gate is green (`cabal build all` `-Werror`
> clean, `cabal test` green, `hlint src/ test/` clean, all in the Nix dev shell).
> One commit per task.

**Goal:** The `seal serve` subcommand opens a Warp/WAI HTTP server on
`127.0.0.1:8080`, serves a minimal React/TS/Vite/Tailwind chat shell, exposes
a WebSocket broker that streams transcript events live, and a REST API the
SPA calls — enough to close the end-to-end loop over the web channel. The
gateway reuses the existing tab/harness/session surface (Phases 6a/6b); no
new agent-loop logic lands here. The full UI is 7b; 7a ships the minimal
chat shell.

**Parent roadmap:**
`docs/superpowers/plans/2026-06-28-seal-harness-roadmap.md` § Phase 7 (7a).

**Why this sub-phase:** the web frontend is the close duplication of the
reference's UI, built **last** over an architecture that already works
textually over CLI and Signal. The gateway + WS broker expose the existing
tab/harness/session surface; the React SPA is a graphical view over the
same ground truth.

## Tech Stack

Haskell (GHC2021), Cabal, Nix dev shell. **New deps** (added to the library
`build-depends`): `wai`, `warp`, `websockets` (via `wai-websockets` or the
raw `websockets` + a hand-rolled WAI upgrade — decide based on what's
available in the nix shell; prefer `wai-app-websockets` if present, else
`warp` + raw `Network.Websockets` + `wai`'s `ResponseRaw` for the upgrade).
Also reuse `aeson`, `http-types` (already present). Frontend: React 18 +
TypeScript + Vite + Tailwind (a `frontend/` directory, built to
`frontend/dist/`); the Nix dev shell should provide `node` + `npm`.

**Decision on the WS upgrade path:** the repo has `wai`/`warp`/`websockets`
available via cabal (they'll be added as deps). The cleanest WAI-WS bridge is
`wai-app-websockets` (a small adapter that turns a WAI app into a
`websockets` handler). If that package isn't available in the nix shell's
Hackage snapshot, fall back to `warp`'s raw `ResponseRaw` + the
`websockets` package directly (the reference uses this path). **T0's first
step is to verify which packages are available + add them to cabal.**

Build/test via `nix develop --command cabal build all`, `… cabal test`,
`… hlint src/ test/`. The frontend builds via
`nix develop --command bash -c 'cd frontend && npm install && npm run build'`
(produces `frontend/dist/`); the gateway serves it statically. **The test
suite does NOT require the frontend to be built** — the Haskell-side tests
exercise the gateway + broker with a fake WS client; the frontend is built
only for the manual `seal serve` smoke test.

## Global Constraints

Inherited from the roadmap verbatim where the spec is exact:

- **Module namespace:** all library code under `Seal.*`. New modules:
  `Seal.Gateway.Server`, `Seal.Gateway.Stream`, `Seal.Gateway.StreamBroker`,
  `Seal.Gateway.API`, `Seal.Gateway.Config`. (The frontend is under
  `frontend/`, not `Seal.*` — it's TypeScript.)
- **Coding style:** GHC2021; conservative always-on `default-extensions`;
  per-file `OverloadedStrings` / `ImportQualifiedPost`. Whole-module imports;
  post-positive qualified imports.
- **Errors:** `Either Text` / `ExceptT Text` default. No bespoke error ADT
  expected in 7a — the gateway returns HTTP error codes + JSON bodies.
- **GHC flags:** `-Wall -Werror` plus the strict set.
- **TDD:** red → green → commit. The gateway + broker are tested via a fake
  WS client (the `websockets` package's `runClient` against a test server on
  a random port) + `wai-extra`'s `testSession` if available (else a manual
  `Network.HTTP.Client` request to the test server). The REST API is tested
  via `http-client` requests.
- **hlint clean** before each commit.
- **No secret ever serialized.** The gateway NEVER returns a vault secret;
  `/api/sessions/:id/send` routes through `Seal.Ingest` (same as the CLI/
  Signal channels), so the no-secret invariant is inherited from the agent
  loop.
- **Loopback-by-default.** The server binds `127.0.0.1:8080` by default. A
  non-loopback bind emits a stderr warning (the full slash-command surface —
  including local code execution — is reachable by anything that can reach
  the address).
- **WS Origin allowlist.** Every WS upgrade is gated by an exact-match Origin
  allowlist (the configured allowed origins). A non-allowed Origin is
  rejected (403) before the upgrade.
- **Cabal registration:** new library modules in `exposed-modules`, new test
  specs in `other-modules`, both alphabetical; new specs wired into
  `test/Main.hs`.
- **Commits:** one per task.
- **Build/verify:** `nix develop --command cabal build all`,
  `nix develop --command cabal test`,
  `nix develop --command cabal test --test-options='--match "<needle>"'`,
  `nix develop --command hlint src/ test/`.
- **Clean-room:** no prior/reference runtime named in code, comments, docs,
  or commit messages.

## Non-goals (explicitly out of scope for 7a)

- **No full UI.** The Sidebar/ChatArea/HarnessControls/NewTabComposer/TopBar/
  BottomBar/StatusDot/JsonTree components + the 5 hooks + streamClient +
  types are 7b. 7a ships a deliberately minimal chat shell (transcript view
  + send box + live WS + `/help` + terse `/N` driving).
- **No `Phase7Spec` capstone.** The capstone is 7b (it needs the full UI +
  Playwright). 7a's gate is the gateway + broker specs + a manual smoke test.
- **No Telegram.** Phase 8.
- **No off-box transcript mirroring.** Phase 8.
- **No pairing/multi-device hardening.** Phase 8. The gateway is single-user
  loopback in 7a; pairing lands in Phase 8.
- **No harness adoption via the web.** The `/api/harnesses/discover` endpoint
  + the `adoptWindow with consent_confirmed` flow are 7b (the consent gate
  needs the full UI). 7a's API surface is the read paths + send + tab CRUD.

---

## Task map

| Task | Title | Gate |
|---|---|---|
| **T0** | Deps + `Seal.Gateway.Config` — the `[gateway]` config section | `cabal build all` green; `wai`/`warp`/`websockets` resolve; config round-trips |
| **T1** | `Seal.Gateway.StreamBroker` — the in-process broker | `cabal test` green; broker fans events to subscribers; per-session filtering |
| **T2** | `Seal.Gateway.Stream` — the WS endpoint (upgrade + Origin allowlist + frame bounds + hello + focus/replay) | `cabal test` green; fake WS client upgrades, receives `hello`, sends `focus`, gets events |
| **T3** | `Seal.Gateway.API` — the REST surface (sessions/tabs/agents/providers) | `cabal test` green; GET/POST over a test server |
| **T4** | `Seal.Gateway.Server` — the Warp app (CORS + static + SPA fallback + connection cap + setTimeout) | `cabal build all` green; the assembled app serves a static file + an API route |
| **T5** | `Seal.Command.Serve` + `CommandServe` — the `seal serve` subcommand + wiring | `cabal build all` green; `seal serve --help` works; the wiring builds the gateway + broker + API from the existing startup |
| **T6** | Minimal frontend chat shell + `Seal.Phase7aSpec` capstone (Haskell-side, no Playwright) | `cabal test` green; a fake WS client drives the full loop: connect, receive hello, POST /api/sessions/:id/send, receive the transcript event over WS |

---

## T0 — Deps + `Seal.Gateway.Config`

**Why:** add the web deps to cabal + write the `[gateway]` config section
(port, bind host, static dir, allowed origins) that the server reads.

**Module:** `src/Seal/Gateway/Config.hs`

### Steps

- [ ] **Verify deps.** In the Nix dev shell, check `ghc-pkg list wai warp
  websockets wai-app-websockets wai-extra`. If `wai-app-websockets` is
  present, prefer it; else fall back to raw `websockets` + `warp`'s
  `ResponseRaw`. Add the resolved deps to the library `build-depends` (and
  `wai-extra`/`http-client` to the test `build-depends` if needed for the
  fake-client tests).
- [ ] **Red.** Write `test/Seal/Gateway/ConfigSpec.hs`:
  - `defaultGatewayConfig` has port 8080, host "127.0.0.1".
  - A `[gateway]` TOML section round-trips through `loadFileConfig`/
    `saveFileConfig`.
  - A non-loopback host (e.g. "0.0.0.0") is accepted (the warning is at
    runtime, not config-load time).
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Implement `src/Seal/Gateway/Config.hs` (the
  `GatewayConfig` record + TOML codec, mirroring `Seal.Signal.Config`).
  Extend `Seal.Config.File.FileConfig` with `fcGateway :: Maybe
  GatewayConfig` + the codec line. Register `Seal.Gateway.Config` in
  `exposed-modules`.
- [ ] **Green-verify.** Build + the **full** suite green (the FileConfig
  shape change must not break `Config.FileSpec`). hlint clean.
- [ ] **Commit.** `feat(gateway): deps + [gateway] config section`

---

## T1 — `Seal.Gateway.StreamBroker` — the in-process broker

**Why:** the broker is the fan-out hub. Subscribers (WS connections) register
with a focused session id; the broker fans `BrokerEvent`s
(`EntryRecorded`/`SaHarnessStatus`/`ListsSnapshot`) to each subscriber,
filtering by their focused session. `broadcastLists` pushes a refreshed
tab/session snapshot to every connection.

**Module:** `src/Seal/Gateway/StreamBroker.hs`

### Design

```haskell
-- | One event the broker fans out to subscribers.
data BrokerEvent
  = BeEntryRecorded SessionId Value   -- ^ a transcript entry (the JSON the WS peer receives)
  | BeHarnessStatus HarnessId Value  -- ^ a harness liveness change
  | BeListsSnapshot Value            -- ^ a refreshed tab/session snapshot
  deriving stock (Eq, Show)

-- | The per-subscriber state: the focused session + a send action.
data Subscriber = Subscriber
  { subSession :: SessionId
  , subSend :: BrokerEvent -> IO ()
  }

-- | The in-process broker. STM-backed: a TVar of subscribers + a global cap.
data StreamBroker = StreamBroker
  { sbSubs :: TVar [Subscriber]
  , sbCap :: Int
  }

newStreamBroker :: Int -> IO StreamBroker
subscribe :: StreamBroker -> SessionId -> (BrokerEvent -> IO ()) -> IO ()
broadcast :: StreamBroker -> BrokerEvent -> IO ()
broadcastLists :: StreamBroker -> Value -> IO ()
```

### TDD steps

- [ ] **Red.** Write `test/Seal/Gateway/StreamBrokerSpec.hs`:
  - Two subscribers (one focused on session A, one on B): broadcasting
    `BeEntryRecorded A entry` delivers to subscriber A only.
  - `broadcastLists` delivers to both.
  - The global cap rejects a subscribe over the limit.
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Implement `src/Seal/Gateway/StreamBroker.hs`. Register.
- [ ] **Green-verify.** Build + test + hlint clean.
- [ ] **Commit.** `feat(gateway): in-process StreamBroker (fan-out + per-session filter)`

---

## T2 — `Seal.Gateway.Stream` — the WS endpoint

**Why:** the WS endpoint at `/api/stream`. Every upgrade is gated by the
Origin allowlist + per-origin + global caps. Inbound frames are bounded at
4 KB; malformed JSON returns an in-band error without closing. The wire
protocol: a one-shot `hello` on upgrade; then a reader/writer race forwards
`BrokerEvent`s to the peer while accepting `focus` ops.

**Module:** `src/Seal/Gateway/Stream.hs`

### Design

```haskell
-- | The WS upgrade handler. Takes the broker + the Origin allowlist + the
-- caps. Returns a WAI response (the upgrade) or a 403.
streamHandler :: StreamBroker -> [Text] -> Int -> Int -> Application

-- | The per-connection guard (Origin + per-origin cap + global cap).
data StreamGuard = StreamGuard
  { sgAllowedOrigins :: [Text]
  , sgPerOriginCap :: Int
  , sgGlobalCap :: Int
  }
```

### TDD steps

- [ ] **Red.** Write `test/Seal/Gateway/StreamSpec.hs` using the
  `websockets` test client (`runClient "127.0.0.1" port "/" $ \conn -> …`)
  against a test server:
  - A connect with an allowed Origin succeeds; receives `hello`.
  - A connect with a disallowed Origin is rejected (the upgrade fails / the
    connection is closed).
  - A `focus` op changes which session the client receives events for.
  - A broadcast to the focused session is received; a broadcast to a
    different session is not.
  - An oversized frame (>4 KB) is rejected in-band (not closed).
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Implement `src/Seal/Gateway/Stream.hs` using
  `wai-app-websockets` (or the raw fallback). Register.
- [ ] **Green-verify.** Build + test + hlint clean.
- [ ] **Commit.** `feat(gateway): WS endpoint (Origin allowlist + hello + focus/replay)`

---

## T3 — `Seal.Gateway.API` — the REST surface

**Why:** the REST API the SPA calls: sessions/tabs/agents/providers + send.

**Module:** `src/Seal/Gateway/API.hs`

### Design

```haskell
-- | The REST API as a WAI Application. Takes the session runtime + the
-- tabs handle + the harness registry + the backends.
apiApp :: SessionRuntime -> TabsHandle -> HarnessRegistry -> Backends -> Application

-- Routes (a manual router — no servant/scotty dep):
-- GET  /api/sessions/:id/transcript
-- POST /api/sessions/:id/send
-- GET  /api/sessions
-- GET  /api/tabs
-- POST /api/tabs/new
-- POST /api/tabs/:index/close
-- GET  /api/agents
-- GET  /api/providers
-- GET  /api/harnesses/discover
```

### TDD steps

- [ ] **Red.** Write `test/Seal/Gateway/ApiSpec.hs` using `http-client`
  against a test server:
  - `GET /api/sessions` returns a JSON array.
  - `POST /api/sessions/:id/send` with a body routes through `Seal.Ingest`
    + returns `{ kind: "slash" | "assistant", response? }`.
  - `GET /api/tabs` returns the `TabSnapshot` (the TabsHandle snapshot as
    JSON).
  - `GET /api/agents` returns the agent defs from the backends.
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Implement `src/Seal/Gateway/API.hs` (a manual path router
  using `http-types`'s `methodGet`/`methodPost` + `pathInfo`). Register.
- [ ] **Green-verify.** Build + test + hlint clean.
- [ ] **Commit.** `feat(gateway): REST API (sessions/tabs/agents/providers)`

---

## T4 — `Seal.Gateway.Server` — the Warp app

**Why:** the assembled Warp application: CORS middleware + static file
serving with SPA fallback + the WS route + the API routes + an
accept-side connection cap + `setTimeout 30` on non-WS routes + the
non-loopback bind warning.

**Module:** `src/Seal/Gateway/Server.hs`

### Design

```haskell
-- | The assembled WAI application. Takes the config + the broker + the
-- runtime handles.
gatewayApp :: GatewayConfig -> StreamBroker -> SessionRuntime -> TabsHandle -> HarnessRegistry -> Backends -> Application

-- | Run the Warp server. Emits the non-loopback warning if the host isn't
-- 127.0.0.1/::1.
runGateway :: GatewayConfig -> StreamBroker -> SessionRuntime -> TabsHandle -> HarnessRegistry -> Backends -> IO ()
```

### TDD steps

- [ ] **Red.** Write `test/Seal/Gateway/ServerSpec.hs`:
  - The assembled app serves a static file from the configured static dir.
  - A non-WS route has `setTimeout 30` (assert via the response timeout
    header, or via a slow-handler test — keep it simple).
  - The connection cap rejects the 1025th concurrent connection (test with a
    fake — keep it simple, maybe just assert the cap is configured).
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Implement `src/Seal/Gateway/Server.hs`. Register.
- [ ] **Green-verify.** Build + test + hlint clean.
- [ ] **Commit.** `feat(gateway): Warp server (CORS + static + SPA fallback + cap)`

---

## T5 — `Seal.Command.Serve` + `CommandServe` — the `seal serve` subcommand

**Why:** the `seal serve` subcommand builds the gateway + broker + API from
the existing startup (paths → config → vault → session → backends →
tabsHandle → broker → gateway). Parallel to `seal tui` and `seal signal`.

**Modules:** `src/Seal/Command/Serve.hs`, `src/Seal/Types/Command.hs`
(add `CommandServe`), `src/Seal/AppMain.hs` (dispatch arm).

### TDD steps

- [ ] **Red.** Write `test/Seal/Command/ServeSpec.hs`:
  - `pCommand` parses `serve` as `CommandServe`.
  - `seal serve --help` renders.
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Add `CommandServe` to `Seal.Types.Command`. Implement
  `Seal.Command.Serve.runServeMain` (mirrors `Seal.Tui.runTui`: paths →
  config → vault → session → backends → tabsHandle → broker →
  `runGateway`). Add the dispatch arm to `AppMain`. Register
  `Seal.Command.Serve` in `exposed-modules`.
- [ ] **Green-verify.** Build + the **full** suite green. hlint clean.
- [ ] **Commit.** `feat(gateway): seal serve subcommand + wiring`

---

## T6 — Minimal frontend chat shell + `Seal.Phase7aSpec` capstone (Haskell-side)

**Why:** the minimal React/TS/Vite/Tailwind chat shell + the Haskell-side
capstone (a fake WS client drives the full loop: connect, receive hello,
POST `/api/sessions/:id/send`, receive the transcript event over WS). The
frontend is built only for the manual smoke test; the capstone is
Haskell-side (no Playwright — that's 7b).

**Modules:** `frontend/` (the Vite project), `test/Seal/Phase7aSpec.hs`.

### Frontend (minimal)

A `frontend/` directory with `package.json` (React 18 + TypeScript + Vite +
Tailwind), `index.html`, `src/main.tsx`, `src/App.tsx`. The App:
- A chat/transcript view (renders the entries from the WS stream).
- A send box (POST `/api/sessions/:id/send`).
- A WS connection (`ws://localhost:8080/api/stream`), with a `focus` op on
  connect.
- `/help` + the terse `/N` grammar (just send them as messages; the gateway
  routes them).

Keep it deliberately minimal — one file, ~150 LOC. The full UI is 7b.

### Capstone (`Seal.Phase7aSpec`)

- [ ] **Red.** Write `test/Seal/Phase7aSpec.hs`:
  - Start a test gateway on a random port (the broker + a fake session
    runtime + a TabsHandle).
  - Connect a fake WS client; receive `hello`.
  - `POST /api/sessions/:id/send` with body `{ "message": "/help" }` → the
    response is `{ kind: "slash", response: <help text> }`.
  - `POST /api/sessions/:id/send` with body `{ "message": "hello" }` → the
    response is `{ kind: "assistant" }` + the WS client receives a
    `BeEntryRecorded` event for the focused session.
  - `POST /api/tabs/new` → the TabsHandle reflects the new tab; `GET
    /api/tabs` returns it.
- [ ] **Red-verify.** Fails.
- [ ] **Green.** Make it pass. (The frontend is NOT built for the test —
  only the Haskell-side loop is exercised.)
- [ ] **Green-verify.** `cabal test --match "Phase 7a capstone"` green;
  full suite green; hlint clean.
- [ ] **Commit.** `feat(gateway): minimal frontend + Phase 7a capstone`

---

## Milestone (7a)

**Definition of Done (whole sub-phase):**

- [ ] `cabal build all` is `-Werror` clean (Nix dev shell).
- [ ] `cabal test` green including the gateway + broker + stream + API specs
      and the `Seal.Phase7aSpec` capstone.
- [ ] `hlint src/ test/` clean.
- [ ] `seal serve` (Nix dev shell, with `frontend/dist` built) opens the web
      UI on `http://localhost:8080`; the user can chat with a model, see the
      transcript stream live over WS, run `/help`, and drive tabs via the
      terse grammar — every inbound message passing the ingress
      preprocessing chain, every step landing in the append-only transcript.
- [ ] All six tasks committed (one commit per task).

**Manual smoke test:**
```
nix develop --command bash -c 'cd frontend && npm install && npm run build'
nix develop --command cabal run seal -- serve
# open http://localhost:8080 → chat, run /help, /tab new, /1 hello
```

**Next:** Phase 7b — full frontend close-duplication (the 10 components + 5
hooks + streamClient + types + the Playwright capstone).