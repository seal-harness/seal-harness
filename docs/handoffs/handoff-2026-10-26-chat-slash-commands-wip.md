# Handoff: finish the chat-channel slash-command work (WU-6 onward)

**Date**: 2026-10-26 · **Branch**: `chat/bg-restore-279` · **PR**: #283 (draft, same branch)
**Predecessor**: `docs/handoffs/handoff-2026-10-25-1345.md`
**Approved plan**: `docs/plans/active-plan.md` (rev 9 of `docs/superpowers/plans/2026-10-26-chat-slash-command-parity-plan.md`)
**Live state**: `docs/context/execution-state.md`

---

## 0. TL;DR

Five of nine work units are **done, gated and committed**. The branch is green:
`cabal build all` clean, **3246 examples / 0 failures / 42 pending**, `hlint`
clean for `src/`, `test/`, `src-chat-channels/`.

**Pick up at WU-6.** Suggested order for the rest:

```
WU-6  →  WU-7  →  WU-5  →  WU-8  →  WU-9
```

This differs from the plan's numbering: WU-5 (the stale WebSocket filter) has no
observable effect until WU-7 makes `/new` rebind a conversation, so doing WU-5
*after* WU-7 lets it be validated against a real rebind instead of a synthetic one.

---

## 1. Read this first: the handoff's gap #1 was wrong

The predecessor handoff said chat `/tab …` commands are "rejected by the
gateway" with `(tab commands are not supported over the web send endpoint)`.
**That is false**, and three plan revisions were spent building an entire
client-side `/tab` implementation on it before it was caught.

The truth:

* `Seal.Routing.Route.route` **never constructs `TabCommand`**. The constructor
  is documented *"reserved; /tab is dispatched via the registry"*
  (`src/Seal/Routing/Route.hs:32`). A repo-wide search finds the declaration and
  exactly two pattern matches of that type (`Send.hs:581`, `Cli.hs:386`).
* Therefore `Send.hs:581` is **unreachable dead code**, and so is the chat loop's
  mirror at `Loop.hs:436` and the CLI's at `Cli.hs:386`.
* `/tab list|new|close|rename|resume` route to `SlashCommand "tab list"` etc.,
  reach `runSlash` → the registry → `tabCommandSpec` (`Registry.hs:114`), and
  execute against the live `TabsHandle`. They already worked.

Verify it yourself before touching `/tab`:

```bash
cabal test --test-options='--match "/Seal.Command.Tab/"'   # 12 examples, 0 failures
cabal test --test-options='--match "TabCommand route"'      # 1 example, 0 failures
```

Consequences baked into the current tree:

* `RoutingDecision.TabCommand`, `ChatRoute.ChatTabCommand` and their arms are
  **left in place** — handoff §5 says *"do not remove the `Send.hs:581` guard"*.
  Do not "clean them up" without re-reading §5.
* `/tab new`, `/tab close`, `/tab rename`, `/tab resume` from chat are still
  **forwarded verbatim** to `/send`. Chat only intercepts bare `/tab`,
  `/tab list` and `/tab focus`.

---

## 2. Done (do not redo)

| Commit | Unit | What landed |
|---|---|---|
| `ae8a17a` | docs | Approved plan (rev 9) + `docs/plans/active-plan.md` |
| `0a193e2` | **WU-1** | `NewArgs`/`parseNewArgs`/`emptyNewArgs` + `renderNewSessionConfirmation` moved into `src-gateway-types/Seal/Gateway/Types/NewArgs.hs`. `Seal.Command.New` re-exports them; `renderNewConfirmation` delegates. `NewSpec` unchanged and still green. |
| `ec2516d` | **WU-2** | `/tab new` mints a **real** session. Was binding the literal id `"tab-session"` and writing nothing — a dead tab on web, CLI **and** chat. Now `mintTabSession` (→ `initSessionMeta`) → `insertTabH … KindProvider` → `saveSessionMeta`, so a failed insert leaves no orphan `session.json`. Mint injected as `IO SessionMeta`; `Registry` ×1, `Cli` ×1, `TabSpec` ×12, `SendSpec` ×2 call sites updated. |
| `047464a` | **WU-3** | `/tab list` rendered client-side from `GET /api/lists` in the D5 format. New module `Seal.Channels.Chat.TabRender`; `cccGetLists` seam; `TabJson` gained `tjStatus`; `RouteSpec`'s `/tab list` case inverted + 5 matching cases. |
| `d9396cd` | **WU-4** | `/tab resume` replies the golden `tab N resumed` (was `tab N resumed <sid>`). Added registry tests that never existed: resume, `close failed`, `force close`, `rename failed`. |
| `cc0eef0` | **WU-5a** | `POST /api/tabs/:idx/rename {label}` and resume via `POST /api/tabs/new {kind:"resume", session_id}`. One new route (`RouteTabsRename`); `ApiRouteSpec` **60 → 61**. Resume 404s when the sid has no `session.json` (mirrors `handleSessionRebindNew`, because `insertTabH` does not check existence). |
| `1f98067`, `182c8ce` | docs | Execution state checkpoints |

### Decision changes since the plan was approved

* **D1 was reinstated** by the operator after the plan withdrew it: the two
  `/tab` REST endpoints now exist for *other* clients. Chat still uses the
  registry and is unaffected. **Consequence: the route count is now 61, not 60.**
  WU-6's `RouteCommands` takes it to **62**, not 61.

---

## 3. Remaining work

### WU-6 — gateway: `GET /api/commands` + `sessions/:id/new` body

* [ ] `GET /api/commands` → `[{"name": <csName>, "synopsis": <csSynopsis>}]` from
      `sdRegistry` (`SendDeps.sdRegistry:128`, reachable **only** via
      `ApiDeps.adSend:140`); `[]` when `adSend` is `Nothing`. Canonical names
      only, no aliases. Pin the exact JSON for a two-spec registry.
* [ ] `RouteCommands` in `src-gateway-types/Seal/Gateway/Types/Route.hs`
      (constructor + `routeMeta` arm + `allRoutes` entry) — `routeMeta` and
      `allRoutes` are total, `-Werror` will find them.
* [ ] An arm in `src/Seal/Gateway/OpenApi.hs` (also a total `\case`).
* [ ] `ApiRouteSpec.expectedRouteCount` **61 → 62**.
* [ ] A dispatch arm in `API.hs`'s hand-written router:
      `(m', ["api","commands"]) | m' == methodGet -> …`.
* [ ] `POST /api/sessions/:id/new` accepts an optional body
      `{provider?, model?, channel?}` and returns
      `{session_id, tab_index, rebound, rebind_error, provider, model}`.
      Absent provider/model ⇒ inherit; absent channel ⇒ `"web"`;
      **`agent` always resolves from config defaults** (golden parity — the
      golden deliberately did *not* inherit the old session's agent).
* [ ] Rebind failure ⇒ **`200` with `rebound:false` + raw `rebind_error`**, not
      `400`. The session is minted before the rebind (`API.hs:908`), so the old
      `400` discarded the id the caller needs to print the golden warning *and*
      the confirmation line.
* [ ] Because that branch is **not reliably inducible** (only an out-of-range
      race or a same-millisecond sid collision), pin it by extracting a pure
      `rebindNewResponse :: Text -> Maybe Int -> Bool -> Maybe Text -> Text -> Text -> Value`
      and unit-testing that; the handler calls it.
* [ ] `404 "session not found"` behaviour is unchanged and already pinned
      (`ApiSpec.hs:559`).

**WU-6 must be red-first.** The headline D2 requirement — that the endpoint
*actually honours* `provider`/`model`/`channel` — currently has **no test**; a
handler that ignored the fields would leave the suite green.

### WU-7 — chat `/new`

* [ ] **Exactly one mint per `/new`**, two mutually exclusive paths:
  * prior session exists → `cccRebindNew` only. `POST /api/sessions/:id/new`
    mints *and* rebinds in one call; its `session_id` is the new session.
    **`cccNewSession` must not be called.**
  * no prior session → `cccNewSession` only, body
    `mintBody :: Maybe Text -> Maybe Text -> Value`.
  * Do **not** mint and then rebind — that produces two sessions and reproduces
    the exact bug this work exists to fix.
* [ ] `rebindBody :: Maybe Text -> Maybe Text -> Maybe Text -> Value` (pure,
      pinned; absent keys omitted, never `null`); chat sends `channel = ccLabel chan`.
* [ ] Reply via the shared `renderNewSessionConfirmation`:
      `new session <sid> (<prov>/<model>) — prior session <oldSid> kept in /session list`.
* [ ] `rebind_error` present ⇒ `warning: /new tab rebind failed: <e>` **then** the
      confirmation. `rebound:false` with no error ⇒ confirmation only.
* [ ] Transport failure or 404 ⇒ `new session failed: <e>` (keep today's text).
* [ ] `-r <repo>`: resolve a registered id via `cccGetRepos` (`T.strip`, exact id
      match, else verbatim), then `cccSetupRepo` on the **new** session, on
      **both** paths, body `setupRepoBody url` = `{"url": …}`.
* [ ] Ordering when several apply: **rebind warning → repo failure →
      confirmation**. `-r` success is silent. A `GET /api/repos` failure ⇒ use
      the value verbatim, no error.
* [ ] No prior session ⇒ reply `new session <sid>` only.
* [ ] `doRequest` should surface `{"error": …}` (via a pure
      `parseErrorBody :: Int -> BL.ByteString -> Text`, non-JSON falling back to
      `HTTP <code>`) so `repo setup failed: <e>` carries the real reason. No test
      pins the current `HTTP nnn` text (the one match, `LoopSpec.hs:1730`,
      injects a fake through a seam).
* [ ] `ensureWsConn` must run on both paths (see WU-5).
* [ ] Pinned: exactly one of the two mint seams called; the sid the conversation
      subsequently uses **equals** the rebind response's `session_id`; a
      subsequent message reaches it through `cccSendMessage`.

### WU-5 — stale WebSocket filter (RISKY — read carefully)

**This is a pre-existing bug, not something these changes introduced.**

`handleServerEvent` closes over the focused session id **by value**, captured
when the connection was created (`Loop.hs:707`), and compares against it at
`:729-735`. `ensureWsConn` on an *existing* connection only sends a `FocusOp`
(`Loop.hs:704`, `WsClient.hs:68`) — it does not rebuild the callback. So after
`/new` (or `/tab focus N`) the filter still drops the **new** session's
`SeEntry`/`SeAsk`, and a plain turn's text is delivered **only** over WS
(`Send.hs:511`, `Loop.hs:1185-1188`). The result: the rebound session produces
no visible replies or asks.

A naive pin ("assert the WS seam recorded a focus on the new sid") **passes while
the bug persists**. Do not write that test.

Suggested fix: carry the sid the connection was built for alongside the client —
`TVar (Map ConversationKey (SessionId, WsClient, StreamingState))` — and have
`ensureWsConn` close and recreate the connection when the target sid differs.
Update `withStreamingState` and every `wsConns` user.

Tests: after a first turn (conn for sid A), `/new` to sid B records a **second**
`cccStartWs`, closes the old client, and focuses the new one; an event for B
dispatched through the **new** callback produces a `ccSend` (i.e. is no longer
filtered out).

### WU-8 — Telegram command menu

* [ ] `HttpClient`: `CommandJson { cjName, cjSynopsis }` + `httpGetCommands`.
* [ ] `Seal.Channels.Chat.TelegramCommands` (new): `BotCommand`,
      `sanitizeTelegramName` (lowercase → `-`→`_` → keep `[a-z0-9_]` → collapse
      `__` → trim → clamp 32), `telegramMenuCommands`, `commandsPayload`
      (pure encoder, **used by** `tgSetCommandsViaApi`), `registerWithRetry`
      (attempts, **injected delay in µs**, fetch thunk, register thunk).
* [ ] Menu order: `help` :: registry :: `bg` :: `watch`; sanitise; **drop names
      empty after sanitising and names of length 1** (the terse `/0`–`/z`
      grammar — `terseGrammarSpec` is `"N"` and *is* in `coreCommandSpecs`,
      `Registry.hs:116`; a single-character menu entry shadows the grammar);
      dedupe first-wins; cap 100 by truncating the tail.
* [ ] Literal pin: `commandsPayload [BotCommand "help" "Show available commands"]`
      == `{"commands":[{"command":"help","description":"Show available commands"}]}`.
      `telegramMenuCommands []` == `[help, bg, watch]` — the encoder does **not**
      append, the builder does. (An earlier draft made these two bullets
      contradict each other; keep the split.)
* [ ] Descriptions: `help` `Show available commands`; `bg` `Run a prompt in a
      background session`; `watch` `Toggle tab notifications`; registry =
      `csSynopsis` truncated to 256.
* [ ] `tgSetCommandsViaApi :: Manager -> Text -> [BotCommand] -> IO (Either Text ())`.
* [ ] Wire in `Serve.forkNewTelegramChatChannel` — the list must be fetched
      **there** (the transport factory `Telegram.hs:138` has only token+manager;
      the fork site has `apiBase` at `Serve.hs:535` and the transport at `:542`).
      Fork it with a bounded retry: the listeners are forked at `:389-390`
      *before* the blocking `runGateway` at `:397`, so an immediate fetch always
      races the HTTP bind.
* [ ] Note: there is **no** `setMyCommands` anywhere in the tree today, yet the
      menu users see looks right — it is a **stale server-side registration**
      from the pre-`99ddc53` bot. So "does the menu look right" is not a
      verification. Test the request body.

### WU-9 — docs + final gate

* [ ] Update the predecessor handoff's DoD status (gap-#1 correction, the
      `/tab new` bug, the D1 reinstatement).
* [ ] Full gate including `hlint src-gateway-types/`.
* [ ] Then `/self-reflect`, commit knowledge-base updates, `gh pr ready`.

---

## 4. Facts that cost time to establish — reuse, don't rediscover

* **Package graph.** `seal-chat-channels` depends only on `seal-gateway-types`
  (`cabal:99`); the main library depends on `seal-chat-channels` (`cabal:344`).
  So the chat package **cannot** import `Seal.Command.New` — anything shared must
  live in `src-gateway-types`. That is why WU-1 moved `NewArgs` down rather than
  duplicating it.
* **`initSessionMeta :: SealPaths -> RuntimeConfig -> AgentDefBackend -> IO SessionMeta`**
  (`Store.hs:271-278`) resolves config defaults and **does not persist**. It is
  the right primitive for a mint; `newSession` does persist.
* **`insertTabH` does not check that the session exists** — it only rejects a
  duplicate ref or a full list (36 slots). Any "open a tab on session X" path
  must existence-check itself.
* **The CLI's `/tab` entry point is unreachable.** `Cli.handleTabCommand` is
  called only from the `Route.TabCommand` arm at `Cli.hs:386`, which `route`
  never produces. It is fixed (WU-2) but is effectively dead code.
* **A failed tab insert must not persist the session.** `handleTabNew`
  (`API.hs:816-833`) documents the mint-unsaved → insert → save ordering that
  prevents orphan sessions surfacing in Recent Sessions. `newCmd` now follows it.
* **`seedTabsHandle :: TabsHandle -> TabList -> IO ()`** (`Tabs.hs:9,62`) is
  exported — it is how to force a full 36-slot list in a test.
* **`GET /api/lists`** carries `tabs`, `tabSessions` and `thinkingSessionIds` in
  one payload. `GET /api/tabs` cannot show `busy`, because `statusWire` returns
  `idle` for every live session tab.
* **`pr` is a `ProviderRuntime`, not a `RuntimeConfig`.** To build a mint at a
  CLI call site you need
  `loadRuntimeConfig (prConfigPath pr)` then `initSessionMeta paths cfg (bAgentDefs backends)`.
* **`errJson` emits `{"error": msg}`** (`API.hs:2451-2453`) — that is the shape
  `parseErrorBody` should look for.

---

## 5. Verification

```bash
cd seal-harness
cabal build all
cabal test > /tmp/test.log 2>&1; tail -5 /tmp/test.log   # expect 3246+ examples, 0 failures
hlint src/ src-gateway-types/ test/                       # No hints
hlint src-chat-channels/                                  # No hints
```

Sandbox caveats (unchanged from the predecessor handoff):

* `nix` is **not** installed — run the four commands directly; `make check`
  fails at the `nix develop` wrapper.
* **Never** pipe a Haskell binary through `head`/`tail`; the RTS ignores
  `SIGPIPE` and the command hangs. Redirect to a file first.
* `cabal build tests` is ambiguous — use `cabal build test:tests`.
* A too-narrow `--match` silently matches **0 examples and exits 0**. Always
  check the example count. Match on a describe path substring, e.g.
  `--match "/Seal.Command.Tab/"`.

---

## 6. Working tree / tooling notes

* `docs/plans/active-plan.md`, `docs/context/execution-state.md` and
  `docs/context/project-context.md` are working documents. Mark the active plan
  `status: completed` and archive the execution state when the PR is ready.
* `seal-harness.cabal` and `test/Main.hs` are merge hotspots (AGENTS.md): keep
  edits minimal and rebase on `main` before opening the PR.
* New modules need registering in **three** places: `exposed-modules`
  (`cabal:40-53` for `seal-gateway-types`, `:73-83` for `seal-chat-channels`),
  `other-modules` for specs (`cabal:404+`), and `test/Main.hs` — both the
  `import qualified` list (`:96-105`) and the `spec` list (`:291-300`). There is
  no hspec-discover; an unregistered spec silently never runs.

---

## 7. Next action

Start **WU-6**. Write the two failing tests first:

1. `GET /api/commands` returns the exact JSON for a two-spec registry, and `[]`
   when `adSend` is `Nothing`.
2. `POST /api/sessions/:id/new` with `{provider:"x",model:"y",channel:"c"}`
   produces a session with exactly those values (this is the D2 requirement and
   currently has no coverage), and with no body inherits provider/model, resolves
   the **config-default** agent, and labels the session `"web"`.

Then implement. Do not move to WU-7 until the whole suite is green.
