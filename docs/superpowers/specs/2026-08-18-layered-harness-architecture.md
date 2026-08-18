# Layered Harness Architecture — Consolidated Design

> **Status:** Draft rev 2 (post review-gate round 1; CTO APPROVED, 4
> NEEDS_REVISION — blockers addressed). **Branch**: `refactor/layered-harness`.
> **Supersedes**: `2026-08-18-trasa-gateway-design.md` (rev 3) and the
> layered-harness brainstorm doc.
> **Mission**: Establish a three-layer architecture — Core Harness, REST API,
> Channel Adapters — where all channels communicate through the gateway API,
> and the API is a declarative `trasa` spec. Two invariants are structurally
> guaranteed by the layering.

## Revision log

### Rev 2 (round 1 resolutions)

CTO APPROVED. 4 NEEDS_REVISION. Resolutions:

- **Architect B1 / Designer B1 (`TurnDeps` missing `ProviderRuntime`):**
  added `tdProvider :: ProviderRuntime` and `tdResolve :: SessionMeta -> IO
  (Either Text (SomeProvider, ModelId))` (the injection seam for tests) to
  `TurnDeps` (§5.1).
- **Architect B2 / Designer B2 (`tdSecurityConfig` per-turn reload):**
  changed `tdSecurityConfig` from `Either Text SecurityConfig` (startup-once)
  to `IO (Either Text SecurityConfig)` (re-read per turn, matching the
  current `loadSecurityConfig` call in all three paths). Added `tdConfig ::
  IO RuntimeConfig` for the same reason (§5.1).
- **Architect B3 (`autoBindRepoAgent` omitted):** added as an explicit step
  in the `runSessionTurn` sketch (§5.2 step 3b). The unified engine calls
  `autoBindRepoAgent` for all surfaces (currently web-only — channels/CLI
  gain it, which is the desired behavioral convergence).
- **Architect B4 (`MessageSource` dropped):** added `Maybe MessageSource` to
  the `runSessionTurn` signature (§5.2). `ChannelCaps` is the response seam;
  `MessageSource` is inbound provenance — they are separate concerns.
- **Architect B5 (omitted turn steps):** expanded the step list to include
  `broadcastHarnessStatus`, `replyFanoutMessage`, `replySubscribe`,
  `ensureTabForSession`, `saveSessionMeta`, and the `aeOnUserMessage` hook.
  Added a step table marking each as **engine** or **adapter** responsibility
  (§5.2).
- **Architect B6 (lock scope):** decided — lock is **outside** the transcript
  bracket (serializes the entire turn, matching the channel path). Documented
  in the sketch (§5.2 step 3).
- **Security B1 (body-size DoS claim overstated):** narrowed the §8 claim
  from "closed" to "POST-to-non-body-route vector closed; body-size cap on
  body-bearing routes is future work". Added a suggestion for a follow-up
  `maxRequestBodyBytes` cap with 413 on overflow.
- **PM B1/B2/B3 (user-focused framing):** added §0.1 (user personas) and
  reframed the problem + success metrics in user-facing terms (§12). Phase 2
  (trasa) is now justified on routing-maintainability grounds (the manual
  router is 1,975 lines of opaque `case` matching), not on deferred OpenAPI
  generation.
- **CTO suggestions:** added test-file disposition to §9 (SendSpec deleted,
  TurnEngineSpec added); W1 DoD strengthened with a parity test; W6
  `ApiRouteSpec` asserts the 404-no-CORS quirk; §4.4 `routeNeedsBody`
  enumerates body-bearing routes.

## 0. The Two Invariants (the driving requirement)

### Invariant 1: Channel consistency

All communication channels (Web, TUI, Telegram, Signal) have the same
behavior. Small medium-specific differences are permitted (Telegram buttons,
web multi-tab, CLI single-tab), but the vast majority of behavior is
**structurally guaranteed** to be consistent — by type, by construction, not
by convention or test.

### Invariant 2: Local/remote execution consistency

Behavior is the same regardless of whether untrusted opcode execution is
local or remote. The local/remote choice is a wiring-time decision,
transparent to the opcodes and the turn engine.

### How the architecture guarantees them

- **Invariant 1**: all channels call the same API handler functions, which
  call the same turn engine. There is exactly one implementation of the turn
  body, the ISA registry builder, the system-prompt resolver, the call
  dispatcher, and the start-wiring builder. The only per-channel variation
  is `ChannelCaps` — the medium-specific I/O seam (how the agent sends
  messages, prompts the human, reads secrets). A new opcode added to the
  single ISA registry builder is available on all four surfaces with zero
  additional wiring per surface.
- **Invariant 2**: the single turn engine calls `mkSessionExec` (which
  abstracts local/remote via `UntrustedIO` + `WorkdirFs`). There is one
  `mkSessionExec` call site, not three. The opcodes call capability methods
  on `UntrustedIO`, never raw IO — enforced by the compile-fail fixture
  `Seal.Tools.Exec.CapabilityScopingFail`. The local/remote choice is made
  once at wiring time and threaded into the single turn engine.

## 0.1 User Personas & Use Cases

### Personas

- **Developer (CLI/TUI)**: power user working in the terminal. Uses `seal`
  directly via Haskeline. Needs the same opcodes as the web agent (web search,
  harness control) — today the CLI is missing 5 opcodes (`Cli.hs:512-549`).
- **Operator (Web SPA)**: primary interactive surface. Uses the React frontend
  via the REST API. Multi-tab. Already an API consumer — the refactor removes
  its privileged "web path" through `Send.hs`.
- **Mobile user (Telegram)**: async, on-the-go. Uses Telegram inline
  keyboard buttons for multiple-choice ASK_HUMAN. Single-tab (multiplexed
  over one conversation).
- **Mobile user (Signal)**: minimal, text-only. No buttons. Single-tab.

### Use Cases

1. **Developer asks the agent to search the web from the CLI** — *As* a
   developer working in the terminal, *I want* to ask the agent to search
   the web during a session, *so that* I don't have to context-switch to a
   browser, *when* I'm mid-turn. **Today this fails silently because
   `WEB_SEARCH` is absent from `cliIsaReg` (`Cli.hs:512-549` vs
   `Send.hs:585-586`).** After the refactor, the single
   `buildSessionRegistry` includes all opcodes for all surfaces.
2. **Developer starts a delegated agent on the CLI** — *As* a developer,
   *I want* delegated agents (AGENT_START) to have the same tool set as the
   parent, *so that* delegation doesn't silently cripple the child, *when*
   I use `/call` or the agent delegates. **Today the CLI child registry
   (`cliChildRegistryBuilder`, `Cli.hs:434-469`) also lacks web/harness ops.**
3. **Contributor adds a new opcode** — *As* a contributor, *I want* to add
   a new opcode to one place and have it available on all four surfaces,
   *so that* I don't have to thread it through 3+ files, *when* the ISA
   grows. **Today this requires touching `buildWebRegistry` +
   `buildIsaRegistry` + `cliIsaReg` + the three child registries.** After
   the refactor, one `buildSessionRegistry` + one `buildChildRegistry`.
4. **Operator switches from web to Telegram mid-session** — *As* an
   operator, *I want* the same session to behave identically whether I turn
   it from the web or from Telegram, *so that* I can switch surfaces without
   surprise, *when* I'm on the go. **Today the three turn paths have
   subtle differences in system prompt resolution, broadcast timing, and
   reply fan-out.** After the refactor, one `runSessionTurn` — the behavior
   is structurally identical.
5. **Contributor adds a new REST route** — *As* a contributor, *I want* the
   routing to be declarative so I can add a route by writing one
   `SealRoute` constructor + one `Meta` arm, *so that* I don't hand-write
   path matching + body parsing + CORS in a 1,975-line `case` statement,
   *when* the frontend grows a new surface. (Phase 2 — the manual router
   is opaque to tooling and a maintenance burden.)

## 1. The Problem

Seal Harness has **three independently-implemented turn paths** that each
reconstruct the same machinery from scratch:

| Path | File | Turn Function | ISA Registry Builder |
|---|---|---|---|
| **Web** | `Gateway/Send.hs` | `plainTurn` / `plainTurnWithCaps` | `buildWebRegistry` |
| **Channels** | `Channels/Loop.hs` | `runTurnOnSession` | `buildIsaRegistry` |
| **CLI** | `Channel/Cli.hs` | `withCliTurn` / `handlePlain` | `cliIsaReg` (inline) |

Each path independently: loads session meta, resolves provider+model, opens a
transcript bracket, builds `mkSessionExec`, constructs workdir-aware backends,
resolves the system prompt, builds the ISA registry, wires `AgentStartWiring`,
constructs `ChannelCaps`, builds `AgentEnv`, calls `runTurn`, broadcasts
transcript entries, fans out replies, auto-tabs the session.

The code comments explicitly acknowledge the problem: `buildIsaRegistry`
(`Loop.hs:1010`) is documented as "Mirrors `Seal.Gateway.Send.buildWebRegistry`
so channels have the SAME tool set as the web and CLI paths." But they are
**copy-pasted**, not shared. Every new opcode, every new config flag, every
new security knob must be threaded through three sites. Miss one → silent
behavioral divergence.

### Specific divergence vectors (the bugs)

- **CLI `cliIsaReg`** (`Cli.hs:512-549`) lacks `webFetchOp`, `webSearchOp`,
  `harnessListOp`, `harnessStartOp`, `harnessStopOp`. The CLI agent literally
  has fewer tools than the web agent.
- **CLI child registry** (`cliChildRegistryBuilder`, `Cli.hs:434-469`) also
  lacks web/harness ops. Delegated agents on CLI are even more crippled.
- **`buildWebRegistry`** (`Send.hs:539-631`) and **`buildIsaRegistry`**
  (`Loop.hs:1013-1087`) are line-for-line identical except for the function
  name — ~115 lines of pure duplication.
- **System prompt resolution** is implemented three times:
  `resolveSystemPrompt` (`Send.hs:385-413`, honors `smSystemOverride`),
  inline in `runTurnOnSession` (`Loop.hs:806-818`, does NOT honor
  `smSystemOverride`), `resolveSystem` (`Cli.hs:561-577`, does NOT honor
  `smSystemOverride`, re-reads config per turn). Each does the same
  `injectStaticGuidance → injectAutoloadSkill → injectAvailableSkills`
  pipeline but with subtle ordering and config-reading differences.
- **`ChannelCaps` construction** is three completely different constructions
  (`webAskCaps` / `mkHandleCaps` / inline Haskeline), reflecting three
  different transport models (async HTTP / inbox / synchronous TTY).
- **Session resolution** is three completely different strategies (URL path
  `sid` / per-conversation cursor / `srActive` IORef).
- **Call dispatchers** (`webCallDispatcher` / `channelCallDispatcher` / CLI
  inline) are three copies of the same dispatch logic, differing only in the
  sid source.
- **Start wiring** (`webStartWiring` / `channelStartWiring` / `cliStartWiring`)
  is three copies of the same `AgentStartWiring` builder.
- **Worker builders** (`webMkWorker` / `channelMkWorker` / CLI inline) are
  three copies of the `mkDelegateWorker` wiring.
- **Clone deps** (`mkCloneDepsFromSend` / `mkCloneDepsFromChannel` / CLI
  inline) are three copies of the same `CloneDeps` builder.

Simultaneously, the REST API surface (`Gateway/API.hs`, 1,975 lines) is a
manual `case (requestMethod, pathInfo)` router — opaque to tooling, with no
declarative spec from which to generate clients or API docs.

## 2. The Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 3: Channel Adapters (thin)                            │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐    │
│  │ Web SPA  │  │  TUI     │  │ Telegram │  │ Signal   │    │
│  │(React)   │  │(Haskeline)│  │(Telethon)│  │(signal-cli)│   │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘    │
│       │ HTTP/WS     │ in-proc   │ in-proc   │ in-proc    │
└───────┼─────────────┼──────────┼──────────┼───────────────┘
        │             │          │          │
        ▼             ▼          ▼          ▼
┌─────────────────────────────────────────────────────────────┐
│  Layer 2: REST API (declarative trasa spec)                  │
│                                                               │
│  SealRoute GADT + Meta table → parsePathWith → handler fns    │
│  POST /api/sessions/:id/send       ← the single turn entry   │
│  POST /api/sessions/:id/stop                                    │
│  GET  /api/sessions/:id/transcript                              │
│  GET  /api/sessions/:id/questions                               │
│  POST /api/sessions/:id/questions/:qid/answer                   │
│  GET  /api/tabs / POST /api/tabs / CRUD / etc.                 │
│  WS   /stream                  ← live transcript + tab updates │
│                                                               │
│  *** ONE implementation of every operation ***                 │
│  (trasa-openapi-hs can generate OpenAPI 3.1 from this spec)   │
└───────────────────────┬───────────────────────────────────────┘
                        │ (in-process: direct function calls)
                        ▼
┌─────────────────────────────────────────────────────────────┐
│  Layer 1: Core Harness (the unified turn engine)              │
│                                                               │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────────┐     │
│  │ Turn Engine │  │ ISA Registry  │  │ Session Manager  │     │
│  │ (runTurn)   │  │ (ONE builder) │  │ (meta + lock)    │     │
│  └─────────────┘  └──────────────┘  └──────────────────┘     │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────────┐     │
│  │ Transcript  │  │ System Prompt │  │ Provider Resolve │     │
│  │ (two-file)  │  │ (ONE resolver)│  │ (vault-backed)   │     │
│  └─────────────┘  └──────────────┘  └──────────────────┘     │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────────┐     │
│  │ Skill/Agent/│  │ Call Dispatch │  │ Start Wiring     │     │
│  │ Memory Back │  │ (ONE dispatch)│  │ (ONE builder)    │     │
│  └─────────────┘  └──────────────┘  └──────────────────┘     │
│  ┌──────────────────────────────────────────────────────┐    │
│  │ mkSessionExec (local/remote abstraction)              │    │
│  │ → UntrustedIO + WorkdirFs + WorkspaceRoot              │    │
│  └──────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

### 2.1 Layer 1: Core Harness

The unified turn engine. One implementation of each operation. The entry
point is a single `runSessionTurn` function parameterized by `ChannelCaps` +
`SessionId` + `Text` (the user message):

```haskell
runSessionTurn :: TurnDeps -> ChannelCaps -> SessionId -> Maybe MessageSource -> Text -> IO TurnOutcome
```

`TurnDeps` is the unified wiring record (replaces `SendDeps` + `ChannelDeps`
+ CLI's `where`-block closures). It carries everything the turn body needs:
paths, vault, repo registry, provider resolver, session runtime, backends,
config repo, preprocess, autonomy level, broker, harness registry, tmux
runner, HTTP manager, ask-reply store, approvals, replies, locks, abort
registry, tabs handle, logger, remote flag.

`runSessionTurn` does the 12 steps from the layered-harness doc §3.1:
1. Load session meta (one implementation)
2. Resolve provider + model (one implementation)
3. Open transcript bracket (one implementation)
4. Build `mkSessionExec` (one implementation — the local/remote abstraction)
5. Construct workdir-aware backends (one implementation)
6. Resolve system prompt (one implementation — honors `smSystemOverride`)
7. Build ISA registry (one builder — the union of all opcodes)
8. Wire `AGENT_START` (one implementation)
9. Construct `AgentEnv` (one `mkSessionAgentEnv` call)
10. Run `runTurn` or `dispatch`
11. Broadcast new transcript entries (one canonical sequence)
12. Fan out replies to subscribed channels (one implementation)

`ChannelCaps` is the **only** medium-specific piece — passed in by the
caller (the channel adapter). The turn engine is caps-agnostic.

### 2.2 Layer 2: REST API (declarative trasa spec)

The API is the **contract**, not the transport. The same handler functions
serve both HTTP requests (from the web frontend) and in-process calls (from
the CLI, Telegram adapter). The TUI doesn't make HTTP calls to itself — it
calls the handler function directly. HTTP is one serialization; in-process is
another.

The API is declaratively specified via `trasa`:
- `Seal.Gateway.Route` — the `SealRoute` GADT (one constructor per route),
  the `Meta` table, `allRoutes`, `sealRouter`.
- `Seal.Gateway.API` — the hand-rolled `Application` that calls
  `Trasa.Core.parsePathWith` (not `serveWith` — see §4) + the handler
  functions. CORS is centralised in the wrapper. The 404 not-found fallback
  preserves the legacy no-CORS quirk.

The handler functions (e.g. `handleSend`, `handleTranscript`,
`handleAgentGet`) call into the Core Harness (Layer 1). They are the
integration point between Layer 2 and Layer 1.

`trasa-openapi-hs` can generate an OpenAPI 3.1 document from the `SealRoute`
spec — enabling client generation, API docs, and contract testing. This is
the §1a UC3 follow-up (out of scope for the initial refactor, but the spec
makes it possible).

### 2.3 Layer 3: Channel Adapters

Each surface becomes a thin adapter that translates its medium-specific input
to API calls and API responses to medium-specific output. The adapter
constructs its `ChannelCaps` and calls `runSessionTurn` (via the API handler
functions).

**Per-channel differences (explicitly permitted):**
- **Web**: multi-tab (no `/1`, `/2` routing needed); `ccSend` is a no-op
  (the SPA polls the transcript); `ccPrompt` uses the `AskReplyStore` + WS
  broker (async, HTTP-driven).
- **TUI**: single-tab (needs `/1`, `/2` routing); `ccSend` = `putStrLn`;
  `ccPrompt` = Haskeline `getInputLine` (synchronous TTY); `ccPromptSecret`
  = Haskeline `getPassword`.
- **Telegram**: single-tab (multiplexed over one conversation); `ccSend` =
  Telethon send; `ccPrompt` = inline keyboard buttons (multiple-choice UI);
  `ccStreaming = False`.
- **Signal**: single-tab; `ccSend` = signal-cli send; `ccPrompt` = text-only
  (no buttons); `ccStreaming = False`.

**What is structurally guaranteed to be the same:**
- The ISA registry (one builder → all channels get the same opcodes).
- The system prompt resolution (one resolver → all channels get the same
  prompt for the same session+agent+config).
- The turn execution (one `runSessionTurn` → same transcript, same lock
  semantics, same broadcast timing).
- The call dispatcher (one dispatcher → same `/call` behavior).
- The start wiring (one builder → same `AGENT_START` delegation).
- The local/remote abstraction (one `mkSessionExec` → same behavior
  regardless of execution mode).

## 3. The Current REST Contract (the oracle for the trasa refactor)

[This section is the full route table from the trasa design rev 3 §3.2,
unchanged. It is the complete surface `apiApp` serves today — 54 routes.
Every entry must be served identically by the `trasa` router. The regression
oracle is the existing `Seal.Gateway.ApiSpec` (3,584 lines, 100+ examples)
and `Seal.Gateway.ServerSpec`.]

### 3.1 Conventions

- **CORS**: every response (success and error) carries `corsHeaders`, except
  the 404 not-found fallback (which has no CORS — the legacy quirk,
  preserved). The wrapper centralises CORS; handler helpers stop emitting
  `corsHeaders` themselves.
- **OPTIONS preflight**: `OPTIONS /api/*` → `200` with `corsHeaders` + empty
  body.
- **404 fallback**: unmatched `/api/*` → `404 {"error":"not found"}` with
  `Content-Type: application/json` and no CORS.
- **Error bodies**: `{"error":"<message>"}` JSON.
- **Status codes**: 200, 201, 204, 400, 403, 404, 500, 501. (405 is emitted
  by `parsePathWith` for method-mismatch — see §4.5; 406/415 cannot occur
  because the wrapper parses the body itself and controls response encoding.)

### 3.2 Route table

[The full 54-row table from the trasa design rev 3 §3.2, verbatim. Key rows
for the layered architecture: `POST /api/sessions/:id/send` (the single turn
entry), `POST /api/sessions/:id/stop`, `GET /api/sessions/:id/transcript`,
`GET /api/sessions/:id/questions`, `POST /api/sessions/:id/questions/:qid/answer`,
`POST /api/sessions/:id/questions/:qid/cancel`, `POST /api/sessions/:id/setup-repo`,
`POST /api/sessions/new`, `POST /api/sessions/:id/new`, `POST /api/tabs/new`,
`POST /api/tabs/:idx/close`, plus CRUD for agents/skills/repos/providers.]

### 3.3 Path-parameter encoding

Path captures use `CaptureCodec`s with the always-succeed pattern (§4.3):
`SessionIdOrErr`, `AgentDefIdOrErr`, `SkillIdOrErr`, `RepoIdOrErr`,
`TabIndexOrErr` — the codec never returns `Nothing`, so trasa's path-not-found
interception (§4.5) is never triggered by a capture decode failure. The
handler pattern-matches via `withSessionId` (§4.3) to emit the exact legacy
`400 "invalid session id: <e>"` message.

### 3.4 Route ordering

trasa's `parsePathWith` tries literal matches before captures at each
segment, so `"default"` beats `:aid`, `"archived"` beats `:sid`, and `"new"`
beats `:idx`/`:sid` regardless of `allRoutes` ordering.

## 4. The trasa API Layer (consolidated from rev 3)

### 4.1 Module layout

- **`Seal.Gateway.Route`** (new) — the `SealRoute` GADT, `routeMeta`,
  `allRoutes`, `sealRouter`. Pure: no `IO`, no `ApiDeps`.
- **`Seal.Gateway.Route.Codec`** (new) — `aesonBodyCodec`, `CaptureCodec`
  helpers, `SessionIdOrErr`/etc., `AnswerReq` sum.
- **`Seal.Gateway.API`** (rewritten) — keeps `ApiDeps` + `apiApp :: ApiDeps
  -> Application`. The body: the hand-rolled `Application` (§4.4), the CORS +
  404 + OPTIONS wrapper (§4.5), and the handler functions (which call into
  Layer 1's `runSessionTurn`).
- **`Seal.Gateway.Server`** (unchanged) — `gatewayApp` calls `apiApp` for
  `/api/*` and falls back to static serving.

### 4.2 The `SealRoute` GADT

One constructor per route. Captures are typed (`SessionIdOrErr`, etc. for
validated captures; `Text` for unvalidated). Response types: newtypes for
non-trivial shapes (`HealthResp`, `SendResp`, `TranscriptResp`, `AnswerReq`);
bare lists/resources for the rest. All current routes are queryless
(`qrys = '[]`).

### 4.3 The `Meta` table + capture decode-failure preservation

`routeMeta :: SealRoute caps qrys req resp -> Meta CaptureCodec CaptureCodec BodyCodec BodyCodec caps qrys req resp`
— one arm per constructor, using `./` for path building. The `BodyCodec`
declares `["application/json"]` but the wrapper parses the body itself
(ignoring `Content-Type`), so a POST with no `Content-Type` (the ApiSpec
helper pattern) still decodes.

The always-succeed capture pattern + `withSessionId` helper:
```haskell
newtype SessionIdOrErr = SessionIdOrErr (Either Text SessionId)
sessionIdCapture = CaptureCodec
  { captureCodecEncode = \(SessionIdOrErr e) -> either (const "") sessionIdText e
  , captureCodecDecode = Just . SessionIdOrErr . mkSessionId
  }
withSessionId :: (SessionId -> IO Response) -> SessionIdOrErr -> IO Response
withSessionId k (SessionIdOrErr (Right sid)) = k sid
withSessionId _ (SessionIdOrErr (Left e)) =
  pure (errJson status400 ("invalid session id: " <> e))
```
Analogous helpers for `AgentDefId`, `SkillId`, `RepoId`, `TabIndex`. Runs in
`IO` (not `TrasaT`) — matches the existing handler convention and AGENTS.md
"no `ExceptT` in the stack".

### 4.4 The hand-rolled `Application` (not `serveWith`)

`serveWith` hardcodes `status200` for success (breaking 201/204), consumes
the body before the handler runs (breaking POST/PUT handlers), and has no
escape hatch for custom headers. Instead, `apiApp` calls **only**
`Trasa.Core.parsePathWith` inside a hand-rolled `Application`:

```haskell
apiApp :: ApiDeps -> Application
apiApp deps req respond =
  case (requestMethod req, pathInfo req) of
    (m, "api" : _) | m == methodOptions ->
      respond (responseLBS status200 corsHeaders "")
    (m, "api" : _) -> do
      let method = decodeMethod (decodeUtf8 m)
      case parsePathWith sealRouter method (pathInfo req) of
        Left (TrasaErr st "") | st == status400 ->
          respond (responseLBS status404 [jsonHeader] "{\"error\":\"not found\"}")
        Left (TrasaErr st body) ->
          respond (responseLBS st (corsHeaders <> [jsonHeader]) body)
        Right (Pathed route caps) -> do
          mBody <- if routeNeedsBody route
                     then Just <$> collectBody req
                     else pure Nothing
          resp <- runHandler deps route caps mBody
          respond (addCors resp)
    _ -> respond (responseLBS status404 [jsonHeader] "{\"error\":\"not found\"}")
```

Key points:
- **Only `parsePathWith` is used** — not `dispatchWith` (which would
  re-introduce body consumption via `decodeRequestBody` and force
  `encodeResponseBody`'s 406/415 path).
- **`collectBody` is gated on `routeNeedsBody`** (a per-constructor function
  returning `True` for `'Body _` routes) — runs **after** `parsePathWith`,
  so a POST with a huge body to a GET route / 404 / OPTIONS is not buffered
  (closes the body-size DoS vector).
- **`HandlerResp`** is a `newtype HandlerResp = HandlerResp Response` — the
  handler's full `Response` (status + headers + body) is emitted verbatim;
  `addCors` appends CORS headers. No decode-roundtrip.
- **CORS centralised**: handler helpers (`jsonOk`/`jsonLBS`/`errJson`/
  `jsonCreated`/`noContent`) stop emitting `corsHeaders`; the wrapper's
  `addCors` is the sole CORS emitter. Avoids duplicate
  `Access-Control-Allow-Origin`.

### 4.5 Status-code behavior

- `parsePathWith` returns `Left (TrasaErr status400 "")` for unknown paths
  → intercepted to `404 {"error":"not found"}` (no CORS, §3.4).
- `parsePathWith` returns `Left (TrasaErr status405 "")` for method-mismatch
  on a known path → emitted with CORS. This is the one accepted behavioural
  delta (was `404` under the manual router; more correct; untested).
- 406/415-from-accept cannot occur (`dispatchWith`/`encodeResponseBody` is
  not called).
- 415-from-content-type cannot occur (the wrapper parses the body itself,
  ignoring `Content-Type`).
- The handler's `Response` carries the status (200/201/204/400/403/404/500/
  501) — preserved verbatim.

### 4.6 `Server-Timing` on `/api/sessions/:sid/transcript`

The `handleTranscript` handler builds the full `Response` including the
`Server-Timing` header. The wrapper passes it through verbatim (`addCors`
only appends CORS). No special case.

## 5. The Unified Turn Engine (Layer 1)

### 5.1 `TurnDeps` — the unified wiring record

Replaces `SendDeps` + `ChannelDeps` + CLI's `where`-block closures. One
record, carrying everything the turn body needs. Constructed once at
startup (or per-`seal serve` / `seal telegram` / `seal signal` invocation)
and threaded into every turn.

```haskell
data TurnDeps = TurnDeps
  { tdPaths         :: SealPaths
  , tdVault         :: VaultRuntime
  , tdProvider      :: ProviderRuntime    -- prConfigPath, prVault, prManager
  , tdResolve       :: SessionMeta -> IO (Either Text (SomeProvider, ModelId))
      -- ^ Injection seam for provider resolution (defaults to
      -- 'resolveSessionProvider tdProvider'). Tests fake this.
  , tdRepoRegistry  :: RepoRegistryHandle
  , tdConfigRepo    :: ConfigRepo
  , tdPreprocess     :: Text -> IO Text
  , tdAutonomy       :: AutonomyLevel
  , tdBroker         :: Maybe StreamBroker
  , tdHarnessReg     :: HarnessRegistry
  , tdTmuxRunner     :: TmuxRunner
  , tdHttpManager    :: HTTPManager
  , tdAskReply       :: AskReplyStore
  , tdApprovals       :: ApprovalCache
  , tdReplies         :: ReplyRegistry
  , tdLocks          :: SessionLocks
  , tdAbortReg       :: SessionAbortRegistry
  , tdTabsHandle     :: TabsHandle
  , tdLogger         :: Logger
  , tdIsRemote       :: Bool
  , tdSecurityConfig :: IO (Either Text SecurityConfig)
      -- ^ Re-read per turn (matches the current 'loadSecurityConfig' call
      -- in all three paths). Preserves the live-config-reload behavior.
  , tdConfig         :: IO RuntimeConfig
      -- ^ Re-read per turn (matches 'ChannelDeps.cdConfig'). Preserves
      -- live config changes without a restart.
  , tdBaseBackends   :: Backends       -- user ⊕ builtin (never mutated per-turn)
  , tdRemoteRunner   :: RemoteRunner   -- SSH transport for remote untrusted exec
  , tdCloneDeps      :: CloneDeps
  }
```

**Adapter-owned state** (NOT in `TurnDeps`): the slash-command `Registry`
(used by `ingest` before the turn), `CursorStore` (per-conversation tab
state), conversation→`SessionId` resolution. These stay in the channel
adapter — they're medium-specific routing, not turn-engine concerns.

### 5.2 `runSessionTurn` — the single turn body

```haskell
runSessionTurn :: TurnDeps -> ChannelCaps -> SessionId -> Maybe MessageSource -> Text -> IO TurnOutcome
runSessionTurn td caps sid mSrc msg = do
  -- 1. [engine] Load session meta
  meta <- loadSessionMeta (tdPaths td) sid
  -- 2. [engine] Resolve provider + model (via tdResolve seam)
  eProv <- tdResolve td meta
  -- 3. [engine] Acquire session lock (OUTSIDE the transcript bracket —
  --    serializes the entire turn, matching the channel path)
  withSessionLock (tdLocks td) sid $ do
    -- 3b. [engine] autoBindRepoAgent (currently web-only; unifying means
    --     channels/CLI gain it — desired behavioral convergence)
    meta' <- autoBindRepoAgent (seWorkdirFs <$> ...) (tdPaths td) sid >> loadSessionMeta (tdPaths td) sid
    -- 4. [engine] Open transcript bracket
    withTwoFileTranscript (tdPaths td) sid model $ \tHandle -> do
      -- 5. [engine] Re-read security config + runtime config (per-turn)
      eSecCfg <- tdSecurityConfig td
      cfg <- tdConfig td
      -- 6. [engine] Build mkSessionExec (the local/remote abstraction)
      exec <- either (const (failClosedSessionExec (tdCloneDeps td)))
                     (mkSessionExec (tdPaths td) secCfg sid (tdCloneDeps td) (tdRemoteRunner td))
                     eSecCfg
      -- 7. [engine] Construct workdir-aware backends (per-turn merge;
      --    tdBaseBackends is the base, never mutated)
      let sessionSkills = workdirAwareSkills (seWorkdirFs exec) (tdBaseBackends td)
          sessionAgentDefs = workdirAwareAgentDefs (seWorkdirFs exec) (tdBaseBackends td)
      -- 8. [engine] Resolve system prompt (honors smSystemOverride)
      mSystem <- resolveSystemPrompt sessionAgentDefs sessionSkills (autoloadFlags cfg) meta'
      -- 9. [engine] Build ISA registry (ONE builder — all opcodes)
      let isaReg = buildSessionRegistry eSecCfg (seUIOEnv exec)
                      (tdHarnessReg td) (tdTmuxRunner td) sessionSkills sessionAgentDefs
                      (tdBaseBackends td) caps (tdAskReply td) ...
      -- 10. [engine] Wire AGENT_START (ONE builder)
      let startWiring = buildStartWiring td caps sid mSrc exec isaReg
      -- 11. [engine] Construct AgentEnv (one mkSessionAgentEnv call)
      env <- mkSessionAgentEnv ... (22 args, all from td + caps + exec + isaReg + mSrc)
      -- 12. [engine] Broadcast "thinking" status
      broadcastHarnessStatus (tdBroker td) sid "thinking"
      -- 13. [engine] Reply subscribe (for inbox-driven channels; no-op for web/CLI)
      -- 14. [engine] Run turn
      runApp env (runTurn env (mkText msg))
      -- 15. [engine] Broadcast "idle" status + new transcript entries
      broadcastHarnessStatus (tdBroker td) sid "idle"
      broadcastNewEntries (tdBroker td) sid tHandle
      -- 16. [engine] Cross-channel reply fan-out (if mSrc is Just)
      maybe (pure ()) (replyFanoutMessage (tdReplies td) sid) mSrc
      -- 17. [engine] Auto-tab (ensureTabForSession, gated by shouldAutoTab)
      ensureTabForSession (tdTabsHandle td) sid mSrc
      -- 18. [engine] Save session meta
      saveSessionMeta (tdPaths td) meta'
      pure turnOutcome
```

**Step responsibility table:**

| Step | Engine | Adapter | Notes |
|---|---|---|---|
| 1. Load session meta | ✓ | | |
| 2. Resolve provider | ✓ | | Via `tdResolve` seam |
| 3. Acquire lock | ✓ | | Outside transcript bracket |
| 3b. autoBindRepoAgent | ✓ | | Currently web-only; unified → all surfaces |
| 4. Transcript bracket | ✓ | | |
| 5. Re-read config | ✓ | | `IO` actions, per-turn |
| 6. mkSessionExec | ✓ | | The local/remote abstraction |
| 7. Workdir-aware backends | ✓ | | Per-turn merge over `tdBaseBackends` |
| 8. System prompt | ✓ | | Honors `smSystemOverride` |
| 9. ISA registry | ✓ | | One `buildSessionRegistry` |
| 10. Start wiring | ✓ | | One `buildStartWiring` |
| 11. AgentEnv | ✓ | | One `mkSessionAgentEnv` |
| 12. Broadcast "thinking" | ✓ | | |
| 13. Reply subscribe | ✓ | | No-op for web/CLI |
| 14. Run turn | ✓ | | |
| 15. Broadcast "idle" + entries | ✓ | | One canonical sequence |
| 16. Reply fan-out | ✓ | | Gated on `Maybe MessageSource` |
| 17. Auto-tab | ✓ | | `shouldAutoTab` gates `/bg` |
| 18. Save meta | ✓ | | |
| — Ingest (slash-command routing) | | ✓ | Adapter runs `ingest` before calling `runSessionTurn` |
| — Conversation→SessionId resolution | | ✓ | Adapter resolves via cursor / URL path / tab focus |
| — ChannelCaps construction | | ✓ | The only medium-specific seam |
| — `ChannelHandle` inbox loop | | ✓ | Transport for inbox-driven channels |

### 5.3 What dies (the consolidation)

- `buildWebRegistry` + `buildIsaRegistry` + `cliIsaReg` → **one**
  `buildSessionRegistry` (the union of all opcodes — web/harness ops included).
- `buildChildRegistry` (Send.hs) + `buildChildRegistry` (Loop.hs) +
  `cliChildRegistryBuilder` → **one** `buildChildRegistry`.
- `resolveSystemPrompt` (Send.hs) + inline (Loop.hs) + `resolveSystem`
  (Cli.hs) → **one** `resolveSystemPrompt` (honors `smSystemOverride`, takes
  flags as explicit args).
- `webCallDispatcher` + `channelCallDispatcher` + CLI inline → **one**
  `callDispatcher` (takes explicit `SessionId`).
- `webStartWiring` + `channelStartWiring` + `cliStartWiring` → **one**
  `buildStartWiring`.
- `webMkWorker` + `channelMkWorker` + CLI inline → **one** `buildWorker`.
- `mkCloneDepsFromSend` + `mkCloneDepsFromChannel` + CLI inline → **one**
  `CloneDeps` builder (in `TurnDeps`).
- `webAskCaps` + `mkHandleCaps` + CLI inline → kept as per-adapter
  `ChannelCaps` factories (the only medium-specific seam), but they all
  call the same `runSessionTurn`.
- `SendDeps` + `ChannelDeps` + CLI closures → **one** `TurnDeps`.

### 5.4 What stays

- `ChannelCaps` — medium-specific I/O, uniform interface.
- `ChannelHandle` / `Channel` class — the transport abstraction for
  inbox-driven channels (Telegram, Signal). The CLI and web construct
  `ChannelCaps` directly (they're request/response, not inbox-driven).
- `Route.route` — the terse `/N` grammar parser (used by CLI + chat channels
  for tab multiplexing; not needed by web which is natively multi-tab).
- `Ingest.ingest` — the slash-command preprocessor.
- `StreamBroker` / WS — the web frontend's live-update channel.
- `ReplyRegistry` — cross-channel reply fan-out (still needed for
  multi-medium sessions).
- `mkSessionExec` / `SessionExec` / `UntrustedIO` / `WorkdirFs` — the
  local/remote abstraction (unchanged; the single turn engine calls it).

### 5.5 Session resolution convergence

The three session-resolution strategies converge on **explicit `SessionId`
parameter, no global mutable state**:
- The web's `srActive` swap bracket is eliminated — `handleSend` takes the
  `sid` from the URL path (it already does); the call dispatcher takes an
  explicit `SessionId` (not `srActive`).
- The channel's per-conversation cursor is preserved (it's the adapter's
  job to resolve the conversation → `SessionId` before calling
  `runSessionTurn`).
- The CLI's `srActive` IORef is eliminated — the CLI resolves the active
  session once (from the tab focus or `/tab focus`) and passes the explicit
  `SessionId` to `runSessionTurn`.

## 6. Implementation Plan

The refactor is sequenced to **never break the web frontend** (the primary
dev surface) and to land the structural guarantees as early as possible.

### Phase 0: Vendor deps (DONE)

- `cabal.project` pins `mightybyte/quantification@37aee18`,
  `mightybyte/trasa@08a2403`, `mightybyte/trasa-openapi-hs@9648496`,
  `shinzui/openapi-hs@06fc117` via `source-repository-package`.
- `seal-harness.cabal` depends on `trasa`, `trasa-server`, `trasa-openapi-hs`,
  `openapi-hs`, `http-media`.
- `Seal.Gateway.TrasaSpike` (throwaway) proves the toolchain builds.
- **DoD**: `nix develop --command cabal build lib:seal-harness` succeeds.

### Phase 1: Unify the Core (the turn engine consolidation)

This is the highest-value phase — it establishes Invariant 1 (channel
consistency) by collapsing the three turn paths into one.

#### W1: Unify the ISA registry (mechanical)

- Merge `buildWebRegistry` + `buildIsaRegistry` + `cliIsaReg` into a single
  `buildSessionRegistry`. The CLI's version is missing web/harness ops — add
  them. This alone fixes the "CLI agent has fewer tools" bug.
- Merge the three `buildChildRegistry` variants into one.
- **DoD**: existing test suite green; verify CLI agent can call
  `WEB_SEARCH`, `HARNESS_LIST` (new test).

#### W2: Unify system prompt resolution

- Merge `resolveSystemPrompt` (Send.hs) + inline (Loop.hs) + `resolveSystem`
  (Cli.hs) into one `resolveSystemPrompt` that honors `smSystemOverride` and
  takes flags as explicit args.
- **DoD**: test that system prompts are byte-identical across all three
  surfaces for the same session + agent + config.

#### W3: Unify the turn body

- Extract the shared turn body (steps 1-12) into `runSessionTurn` parameterized
  by `TurnDeps` + `ChannelCaps` + `SessionId` + `Text`.
- Build `TurnDeps` (the unified wiring record).
- The three `plainTurn` variants become one-liners that construct caps and
  call `runSessionTurn`.
- **DoD**: integration tests for each surface; existing test suite green.

#### W4: Unify call dispatchers + start wiring

- Merge the three `*CallDispatcher` functions into one `callDispatcher`
  (takes explicit `SessionId`).
- Merge the three `*StartWiring` builders into one `buildStartWiring`.
- Merge the three `*MkWorker` builders into one `buildWorker`.
- Merge the three `mkCloneDepsFrom*` into one `CloneDeps` builder.
- **DoD**: `/call` + `/skill load` from each surface, verify transcript
  entry lands on the correct session.

#### W5: Eliminate `srActive` swap

- The web's `srActive` swap bracket is removed — `handleSend` and the call
  dispatcher take explicit `SessionId` from the URL path.
- The CLI's `srActive` IORef is removed — the CLI resolves the active session
  once and passes the explicit `SessionId`.
- **DoD**: multi-session web tests green; CLI `/tab focus` + turn green.

### Phase 2: Declarative API via trasa

This phase makes the API declarative — the `trasa` route spec. It proceeds
independently of Phase 1 (it's a routing-layer change, not a turn-engine
change), but it's sequenced after Phase 1 so the handler functions already
call the unified `runSessionTurn`.

#### W6: `Seal.Gateway.Route` skeleton + `ApiRouteSpec` (TDD red-green)

- Write `test/Seal/Gateway/ApiRouteSpec.hs` asserting `allRoutes` matches
  the §3.2 route table (count + method + path shape + literal/capture
  overlap). Fails because `Seal.Gateway.Route` doesn't exist.
- Write `Seal.Gateway.Route` with the full `SealRoute` GADT, `routeMeta`,
  `allRoutes`, `sealRouter`.
- Write `Seal.Gateway.Route.Codec` with `aesonBodyCodec`, `SessionIdOrErr`/
  etc., `AnswerReq` sum.
- Rewrite `apiApp` to the §4.4 wrapper (`parsePathWith` + hand-rolled
  dispatch + CORS + 404 + OPTIONS). Only `RouteHealth` is ported; the rest
  fall through to the legacy `case` (kept inline during W6-W10).
- Centralise CORS: refactor `jsonOk`/`jsonLBS`/`errJson`/`jsonCreated`/
  `noContent` to stop emitting `corsHeaders`; the wrapper's `addCors` is the
  sole CORS emitter.
- Delete `TrasaSpike.hs`.
- **DoD**: `ApiRouteSpec` green; all existing `ApiSpec` tests green; `make
  check` green.

#### W7-W10: Port routes to trasa (refactor increments)

- W7: GET routes (no captures).
- W8: GET routes with captures (introduce `sessionIdCapture` +
  `withSessionId`).
- W9: POST/PUT/DELETE routes (body-accepting handlers get `bodyBytes`).
- W10: Delete the legacy `case`; all routing is trasa.
- **DoD**: all `ApiSpec` tests green at every commit; `make check` green.

### Phase 3: Channel adapters slim down

With the unified turn engine (Phase 1) and the declarative API (Phase 2),
the channel files shrink to transport + caps construction.

#### W11: CLI becomes API client

- `Seal.Channel.Cli` shrinks to ~200 lines: Haskeline loop →
  `runSessionTurn` (in-process, via the handler function, not HTTP).
  Slash commands → API calls. ASK_HUMAN → stdin prompt.
- **DoD**: CLI tests green; CLI agent has the same opcodes as web.

#### W12: Telegram/Signal adapters slim down

- `Seal.Channels.Telegram` / `Seal.Channels.Signal` shrink to ~150 lines:
  inbox loop → `runSessionTurn` (in-process). Tab/focus routing via
  `Route.route` → API calls. ASK_HUMAN → inline keyboard (Telegram) /
  text-only (Signal).
- `Seal.Channels.Loop` simplifies to a thin loop calling `runSessionTurn`.
- **DoD**: channel tests green.

### Phase 4: OpenAPI generation (future, out of scope)

- `trasa-openapi-hs` generates an OpenAPI 3.1 document from the `SealRoute`
  spec. Enable client generation, API docs, contract testing.
- Triggered by a concrete downstream request (§1a UC3).

## 7. The Structural Guarantees (how the invariants are enforced)

### 7.1 Invariant 1: Channel consistency

**Guarantee mechanism**: there is one `runSessionTurn`, one
`buildSessionRegistry`, one `resolveSystemPrompt`, one `callDispatcher`, one
`buildStartWiring`. All channel adapters call `runSessionTurn` (via the API
handler functions). The only per-channel variation is `ChannelCaps`, which is
passed in by the adapter.

**Compile-time enforcement**: a new opcode is added to
`buildSessionRegistry` (one function). It is immediately available to all
channels because they all use the same registry. There is no per-channel
registry to forget to update. The CLI's missing-opcodes bug is structurally
impossible — there is no `cliIsaReg` anymore.

**Test enforcement**: `ApiRouteSpec` asserts the route list matches the
§3.2 table. A new test (W1) asserts the CLI agent can call `WEB_SEARCH` and
`HARNESS_LIST`. The existing `ApiSpec` (100+ examples) is the regression
oracle for the web path.

### 7.2 Invariant 2: Local/remote execution consistency

**Guarantee mechanism**: there is one `mkSessionExec` call site (in
`runSessionTurn`). `mkSessionExec` returns a `SessionExec` carrying
`UntrustedIO` + `WorkdirFs` + `WorkspaceRoot`. The opcodes call capability
methods on `UntrustedIO`, never raw IO. The local/remote choice is made
inside `mkSessionExec` based on `SecurityConfig`, transparent to the opcodes
and the turn engine.

**Compile-time enforcement**: the `Seal.Tools.Exec.CapabilityScopingFail`
compile-fail fixture asserts that a Trusted opcode that shells out fails to
compile (no `UntrustedIO` in scope). The opcodes call `UntrustedIO` methods,
not `System.Process`/`System.Directory`/`System.Posix`. This is unchanged by
the refactor — the single turn engine uses the same `mkSessionExec` that all
three paths already use.

**Fail-closed invariant**: on ANY workdir-creation failure, `mkSessionExec`
returns `failClosedSessionExec` (all stubs — never a mix of real + stub).
This is unchanged.

## 8. Security

- **No new attack surface.** The refactor consolidates three turn paths into
  one and makes the API declarative. The handlers, the `ApiDeps` seams, the
  trust classification, and the loopback-only bind guard are unchanged.
- **No new dependencies on untrusted code.** The vendored `trasa` family is
  build-time-only; `parsePathWith` parses HTTP requests and dispatches into
  our handlers. trasa never interprets agent output, never touches opcodes,
  never constructs subprocess argv.
- **CORS preserved.** The `Access-Control-Allow-Origin: *` policy is
  preserved. The 404 no-CORS quirk is preserved. CORS is centralised in the
  wrapper (no duplication).
- **No secret handling change.** No route touches the vault; the deploy-key
  routes still go through the unchanged handlers.
- **Body-size DoS partially mitigated.** `collectBody` is gated on
  `routeNeedsBody` (runs after `parsePathWith`, only for body-bearing routes)
  — this closes the POST-with-huge-body-to-GET/404/OPTIONS vector. A
  body-bearing route (e.g. `POST /api/sessions/:id/send`) still buffers
  the full body with no byte cap. A follow-up (out of scope for this
  refactor) should add a `maxRequestBodyBytes` cap with `413 Payload Too
  Large` on overflow. The loopback-only bind guard limits the risk today.
- **Vendor provenance.** `source-repository-package` pins record the fork
  commit hashes. The fork patches are GHC 9.12 build fixes only (prim-op
  arity, import relocation, bound bumps) — no logic changes. Once both
  upstreams land GHC 9.12 fixes and cut releases, the source pins are
  dropped in favour of Hackage deps.

## 9. File Scope

| File | Change |
|---|---|
| `cabal.project` | `source-repository-package` pins for quantification/topaz/trasa/trasa-server/trasa-openapi-hs/openapi-hs |
| `seal-harness.cabal` | Library deps: `trasa`, `trasa-server`, `trasa-openapi-hs`, `openapi-hs`, `http-media`. New modules: `Seal.Gateway.Route`, `Seal.Gateway.Route.Codec`, `Seal.Core.TurnEngine` (the unified `runSessionTurn` + `TurnDeps`). New test: `Seal.Gateway.ApiRouteSpec`. |
| `src/Seal/Core/TurnEngine.hs` | NEW — `TurnDeps`, `runSessionTurn`, `buildSessionRegistry`, `buildChildRegistry`, `resolveSystemPrompt`, `callDispatcher`, `buildStartWiring`, `buildWorker`. The unified core. |
| `src/Seal/Gateway/Route.hs` | NEW — `SealRoute` GADT, `routeMeta`, `allRoutes`, `sealRouter` |
| `src/Seal/Gateway/Route/Codec.hs` | NEW — `aesonBodyCodec`, `CaptureCodec` helpers, `SessionIdOrErr`/etc., `AnswerReq` |
| `src/Seal/Gateway/API.hs` | Rewritten — `apiApp` becomes the trasa wrapper; handler functions call `runSessionTurn` |
| `src/Seal/Gateway/Send.hs` | Deleted (merged into `TurnEngine` + `API`) |
| `src/Seal/Channels/Loop.hs` | Slimmed — thin loop calling `runSessionTurn` |
| `src/Seal/Channel/Cli.hs` | Slimmed — Haskeline loop calling `runSessionTurn` |
| `src/Seal/Gateway/Server.hs` | Unchanged |
| `test/Seal/Gateway/ApiRouteSpec.hs` | NEW — route-list parity + overlap assertions + 404-no-CORS quirk |
| `test/Seal/Core/TurnEngineSpec.hs` | NEW — unified turn engine tests (parity, system prompt, call dispatcher) |
| `test/Seal/Gateway/SendSpec.hs` | DELETED (Send.hs deleted; tests move to TurnEngineSpec) |
| `test/Main.hs` | Import + run `ApiRouteSpec` + `TurnEngineSpec`; remove `SendSpec` |

## 10. Human Checkpoints

1. **After W1** (unified ISA registry) — verify the CLI agent now has
   web/harness ops (the primary bug fix).
2. **After W3** (unified turn body) — review `runSessionTurn` for the
   broadcast timing + lock scope decisions (the open questions from the
   layered-harness doc §7).
3. **After W6** (trasa wrapper + `ApiRouteSpec`) — review the 404
   interception and CORS centralisation.
4. **After W10** (full trasa parity) — review the known behavioural deltas
   (405 for method-mismatch).
5. **After W12** (channel adapters slimmed) — verify all four surfaces
   produce the same transcript for the same session + message.

## 11. Open Questions

1. **Session resolution for the call dispatcher.** The web's `srActive` swap
   is eliminated (W5); the call dispatcher takes an explicit `SessionId`.
   The channel's cursor-based resolution is preserved (the adapter resolves
   the conversation → `SessionId` before calling `runSessionTurn`). The CLI's
   `srActive` IORef is eliminated (the CLI resolves the active session from
   the tab focus). Is there any remaining case where the call dispatcher
   needs a different sid than the turn's sid? (The `/call` slash command
   runs *inside* a turn — it should use the same sid.)
2. **Broadcast timing.** The three paths call `broadcastNewEntries` at
   slightly different points (before vs after the turn, with vs without
   `broadcastHarnessStatus`). The shared path needs one canonical broadcast
   sequence. (Probably: after the turn completes, before reply fan-out.)
3. **Lock scope.** The web path acquires `withSessionLock` inside the
   transcript bracket. The channel path acquires it outside. Pick one
   (probably outside — the lock protects the turn, not just the transcript
   write).
4. **Standalone mode.** `seal telegram` and `seal signal` run without the
   web gateway. They still need the turn engine. `TurnDeps` must work without
   a `StreamBroker` (already handled via `Maybe StreamBroker`).
5. **Child agent registries.** The three `buildChildRegistry` variants also
   differ (CLI's missing web/harness ops). This needs the same consolidation
   as the parent registry (W1).

## 12. Success Metrics

### Developer-facing (structural)

> A new opcode added to the ISA registry is available on all four surfaces
> (Web, TUI, Telegram, Signal) with zero additional wiring per surface.

Today this requires touching 3+ files. After the refactor, it requires
touching 1 (`buildSessionRegistry` in `Seal.Core.TurnEngine`).

> The behavior of a turn is identical regardless of whether untrusted
> execution is local or remote.

Today this is true by construction (`mkSessionExec` abstracts it), but the
three turn paths mean three `mkSessionExec` call sites that could diverge.
After the refactor, there is one call site — the invariant is structurally
guaranteed.

### User-facing (outcome-based)

> A CLI user can complete a `WEB_SEARCH`-augmented turn that previously
> failed silently.

Today: invocation count of `WEB_SEARCH`/`HARNESS_LIST` on CLI = 0
(structurally impossible — the opcodes are absent from `cliIsaReg`).
After: > 0 (the opcodes are in the unified `buildSessionRegistry`).
**Evaluation point:** W1 DoD — a new test asserts the CLI agent can call
`WEB_SEARCH` and `HARNESS_LIST`.

> A delegated agent spawned on any surface has the same tool set as the
> parent.

Today: the CLI child registry (`cliChildRegistryBuilder`) lacks web/harness
ops. After: the unified `buildChildRegistry` includes all non-blocklisted
ops for all surfaces. **Evaluation point:** W1 DoD — a parity test asserts
the child registry's opcode set matches across surfaces.

> An operator switching from web to Telegram mid-session sees identical
> behavior (same system prompt, same opcodes, same transcript semantics).

Today: the three turn paths have subtle differences in system prompt
resolution (the channel path doesn't honor `smSystemOverride`), broadcast
timing, and reply fan-out. After: one `runSessionTurn` — behavior is
structurally identical. **Evaluation point:** W3 DoD — integration tests
for each surface produce the same transcript for the same session +
message.

### Failure / revert criteria

- If `ApiSpec` or `ServerSpec` go red in a way that can't be fixed without
  changing the on-the-wire contract (§3), the refactor has failed — revert.
- If the unified `buildSessionRegistry` drops an opcode that was present in
  any of the three prior builders, the parity guarantee is violated — revert
  (caught by the W1 parity test).
- If the vendored `source-repository-package` upstreams stall past 6 months
  without a GHC 9.12 release, re-evaluate: re-pin to the latest fork HEAD,
  or abandon `trasa` and fall back to the manual router.

---

> End of consolidated design. Submitted to the design-review-gate.