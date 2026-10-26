# Active Plan
<!-- approved: 2026-10-26T14:40:00Z -->
<!-- gate-iterations: 6 -->
<!-- user-approved: true -->
<!-- status: completed -->
<!-- completed: 2026-10-26 -->

## Outcome

All nine work units landed on `chat/bg-restore-279` (PR #283). Commits, oldest
first:

| WU | Commit | What landed |
|---|---|---|
| WU-1 | `0a193e2` | `NewArgs`/`parseNewArgs`/`renderNewSessionConfirmation` moved into `seal-gateway-types` |
| WU-2 | `ec2516d` | `/tab new` mints a real session (registry + CLI) |
| WU-3 | `047464a` | `/tab list` renders client-side from `GET /api/lists` |
| WU-4 | `d9396cd` | `/tab resume` golden reply + registry coverage |
| WU-5a | `cc0eef0` | REST: `tabs/:idx/rename` + tab resume (D1 reinstated) |
| WU-6 | `da4f358` | gateway: `GET /api/commands`, `sessions/:id/new` body + `rebind_error` |
| WU-7 | `eeb0807` | chat `/new`: args, one-mint rebind XOR mint, `-r`, golden line |
| WU-5 | `72e61b7` | rebuild the WS connection when a conversation is re-targeted |
| WU-8 | `7bc4c8c` | Telegram command menu from the slash registry |

Final gate: `cabal build all` clean, **3296 examples / 0 failures / 42
pending**, `hlint` clean for `src/`, `src-gateway-types/`, `test/` and
`src-chat-channels/`.

# Chat-channel slash-command parity (rev 9)

<!-- status: awaiting operator decision -->
<!-- date: 2026-10-26 -->
<!-- rev 1-3 planned against a false premise; rev 4-9 are re-scope iterations. -->

**Branch**: `chat/bg-restore-279` (folds into PR #283) · **Golden**: `99ddc53^`

---

## Correction to the handoff

The handoff's gap #1 — *"`/tab …` is rejected by the gateway"* — **is a
misdiagnosis**. `Seal.Routing.Route.route` never constructs `TabCommand`
(`Route.hs:32` is "reserved"; the only other occurrences are two pattern matches,
`Send.hs:581` and `Cli.hs:386`). So `/tab list` reaches the registry
(`Registry.hs:114`) and executes today:

```
cabal test --test-options='--match "/Seal.Command.Tab/"'  → 12 examples, 0 failures
cabal test --test-options='--match "TabCommand route"'     → 1 example, 0 failures
```

Handoff §5 forbids removing the `Send.hs:581` guard, so it and the dead
constructors are **left untouched**. **D1 (rename/resume endpoints) is withdrawn.**

---

## Problem

1. **`/tab new` creates a dead tab** — `Tab.hs:133-143` and `Cli.hs:422-427` bind
   `BoundSession "tab-session"` and mint nothing.
2. **`/tab list` can't show busy/idle or a repo for chat** — `listCmd`
   (`Tab.hs:110-124`) has no broker access; format is `renderTabLine`
   (`Tab.hs:209-214`).
3. **`/new` ignores its arguments and never rebinds** (`Loop.hs:1206`, `:1209`).
4. **The Telegram menu is never registered** (deleted in `99ddc53`).
5. **Newly found: the WS event filter is pinned to the session captured at
   connection creation.** `handleServerEvent` closes over `focusedSid`
   (`Loop.hs:707`) and `ensureWsConn` on an existing connection only sends a
   `FocusOp` (`:704`, `WsClient.hs:68`). After `/new` (or `/tab focus`) the
   callback still filters on the **old** sid, so the new session's `SeEntry`/
   `SeAsk` are dropped and replies never arrive — and a plain turn's text is
   delivered **only** over WS (`Send.hs:511`, `Loop.hs:1185-1188`). This is a
   pre-existing bug that `/new` exposes; it is in scope because `/new` is
   worthless without it.

---

## Decisions

| # | Decision |
|---|---|
| ~~D1~~ | **Withdrawn** — rename/resume already work. |
| D2 | Extend `POST /api/sessions/:id/new` with optional `provider`/`model`/`channel`; response carries `rebind_error` + `provider`/`model`. |
| D3 | Add `GET /api/commands`; the adapter appends the client-side commands. |
| D4 | `/tab new` must not change the conversation's session. |
| D5 | `/tab list` format: `<tab-id> <activity> <repo>: <name>`. |
| D6 | Fix `/tab new` on all surfaces — mint a real session. |
| **D7** | **Align `/tab resume` with the golden**: reply `tab N resumed` (not `tab N resumed <sid>`). |
| **D8** | **Align `/new` agent selection with the golden**: resolve the config-default agent, do not inherit the old session's. No caller depends on the old behaviour. |
| **D9** | **Fix the stale WS filter** (Problem 5), since `/new` otherwise cannot deliver replies. |

---

## WU-1 — shared pure code in `seal-gateway-types`

- [ ] `Seal.Gateway.Types.NewArgs`: `NewArgs`/`parseNewArgs`/`emptyNewArgs` moved
      from `Seal.Command.New` (which re-exports them unchanged, so
      `NewSpec.hs:11` passes), plus
      `renderNewSessionConfirmation :: Text -> Text -> Text -> Text -> Text`.
- [ ] `Seal.Command.New.renderNewConfirmation` delegates to it — one copy of the
      format. Acceptance: `NewSpec` passes unchanged.
- [ ] Registered in `exposed-modules` and the `Seal.Gateway.Types` umbrella
      (`Types.hs:6-24`).
- [ ] Rollback: delete the module, restore the two functions in `New.hs`.

## WU-2 — `/tab new` mints a real session (all surfaces)

- [ ] New `Seal.Command.Registry.mintTabSession :: SealPaths -> IO RuntimeConfig -> AgentDefBackend -> IO SessionMeta`
      = `cfg <- loadCfg; initSessionMeta paths cfg backend`. This **is** the new
      code, and it is what the test pins (below).
- [ ] `newCmd`: `mintTabSession …` (unsaved) → `insertTabH … KindProvider` →
      `saveSessionMeta`. A failed insert leaves **no** `session.json`.
- [ ] `tabCommandSpec :: SealPaths -> TabsHandle -> TabCloseNotifier -> IO SessionMeta -> CommandSpec`;
      `newCmd` takes the mint too. Call sites: `Registry.hs:114` ×1,
      `TabSpec` ×12, `SendSpec` ×2.
- [ ] `Cli.handleTabCommand` takes the mint; `Cli.hs:386` supplies
      `loadRuntimeConfig (prConfigPath pr) >>= \e -> mintTabSession paths (pure (fromRight defaultRuntimeConfig e)) (bAgentDefs backends)`
      (`pr :: ProviderRuntime`, `backends :: Backends`, `paths :: SealPaths`).
- [ ] Reply unchanged: `tab N created`; insert failure `tab new failed: <e>`.
- [ ] Tests — `test/Seal/Command/TabSpec.hs`:
      * `mintTabSession` with temp paths + `pure defaultRuntimeConfig` + a stub
        backend returns config-default provider/model and `smChannel == "web"`
        (**this is new code, so it fails first**);
      * `/tab new` binds a real sid with `KindProvider` and writes `session.json`;
      * a seeded full 36-slot list (`seedTabsHandle`) → `tab new failed: …` and
        **no** `session.json`;
      * no `"tab-session"` string remains.
- [ ] D4 pin — `test/Seal/Channels/Chat/LoopSpec.hs`: with a **pre-seeded**
      conversation session and a pre-seeded WS connection, `/tab new` is
      forwarded via `cccSendMessage` and `sessionLookup` still returns the
      original sid.
- [ ] Rollback: restore the placeholder bind.

## WU-3 — `/tab list` in the chat loop

- [ ] `HttpClient`: add `tjStatus :: Maybe Text` to `TabJson` (the wire already
      emits `"status"`, `SessionJson.hs:36`), `ListsJson { ljTabs :: [TabJson],
      ljTabSessions :: [Value], ljThinkingSessionIds :: [Text] }`, and
      `httpGetLists`. New `ChatChannelConfig` seam `cccGetLists`.
- [ ] `Seal.Channels.Chat.TabRender` (new): `TabListRow`, `renderTabListRow`,
      `tabListRows`.
- [ ] Row format — one `ccSend` per tab, or `no tabs`:
      `<tab-id>` = `tabIndexToChar`; `<activity>` = `busy` iff the tab's session
      is in `thinkingSessionIds`, else for a harness tab `busy` iff
      `status == "running"`, else `idle`; `<repo>` = last non-empty path segment
      of `repoUrl` after stripping a trailing `/` and `.git`, omitted when no
      repo; `<name>` = label → description → autoSummary → firstMessageSnippet →
      agent → `session:<12 chars>`, `harness` for harness tabs; a tab absent from
      `tabSessions` uses the chain minus session fields.
      Literals: `0 busy seal-harness: fix websocket reconnect`, `1 idle: my tab`,
      `3 idle: session:20261026-035`.
- [ ] Failure → `tab list failed: <e>`.
- [ ] Matching: strip the line, drop the leading `/`, `T.words`, require exactly
      `["tab","list"]`. So `/tab list`, `/TAB LIST`, `/tab list `,
      `/tab  list` match; `/tab list x` does not; **bare `/tab ` unchanged**.
- [ ] `Chat/RouteSpec.hs:66-67` inverted; new `ChatTabList` cases (case,
      collapsed whitespace, trailing space, extra args, bare `/tab `).
- [ ] Forwarded forms pinned via `cccSendMessage`: `/tab close 0`,
      `/tab close 0 --force`, `/tab rename 0 n`, `/tab resume <sid>`,
      `/tab frobnicate`, bare `/tab`.
- [ ] `ChatRouter` keeps `ChatTabCommand` untouched; `parseTabFocus` unchanged.
- [ ] Tests: `Chat/TabRenderSpec.hs` (new) for the pure rules; `Chat/LoopSpec.hs`
      for the loop behaviour and forwarding; `Chat/HttpClientSpec.hs` for
      `httpGetLists` parsing + the updated `TabJson` construction (`:93`).
- [ ] Registration: `exposed-modules` (`cabal:73-83`), `other-modules`
      (`cabal:404+`), `test/Main.hs` imports (`:96-105`) and spec list
      (`:291-300`).
- [ ] Rollback: delete `TabRender`, the seam and the route arm.

## WU-4 — registry `/tab` parity (production change for resume; tests for the rest)

- [ ] **D7**: `resumeCmd` replies `tab N resumed` (drop the appended sid);
      update the one assertion. `Tab.hs:184-193`.
- [ ] Tests in `TabSpec`: `/tab resume <sid>` → `tab N resumed` + the tab bound;
      `resume failed:` (duplicate ref / full list); `close failed:` and --force
      `force close:` (out of range); `rename failed:` (out of range).
      These are **regression pins for existing behaviour** except the resume
      text, and the plan says so (WU-8 wording updated accordingly).
- [ ] Rollback: restore the sid suffix.

## WU-5 — stale WS filter (D9)

- [ ] `wsConns` value becomes `(SessionId, WsClient, StreamingState)` — the sid
      the connection's callback was built for.
- [ ] `ensureWsConn`: same sid → `wcFocus` only; different sid (or none) →
      `wcClose` the old client, drop it, start a fresh one for the new sid, store
      it, `wcFocus`. `withStreamingState` and all `wsConns` users updated.
- [ ] Tests (`Chat/LoopSpec`): after a first turn (conn created for sid A), `/new`
      to sid B records a **second** `cccStartWs` call, closes the old client, and
      focuses the new one; an event for B dispatched through the **new** callback
      produces a `ccSend` (i.e. it is no longer filtered out).
- [ ] Rollback: revert to focus-only reuse.

## WU-6 — gateway

- [ ] `POST /api/sessions/:id/new` accepts `{provider?, model?, channel?}`;
      absent provider/model ⇒ inherit; absent channel ⇒ `"web"`; **`agent` is
      always resolved from config defaults (D8)**, matching the golden and
      `newCommandSpec`. Response: `{session_id, tab_index, rebound,
      rebind_error, provider, model}`, `tab_index` null when no tab bound.
- [ ] Rebind failure ⇒ `200` + `rebound:false` + raw `rebind_error`; pinned via an
      extracted pure `rebindNewResponse` (the branch is not reliably inducible:
      only via an out-of-range race or a same-millisecond sid collision,
      `Store.hs:71-77`).
- [ ] **Tests (`ApiSpec`)**: overrides honoured — `{provider:"x",model:"y",channel:"c"}`
      yields exactly those values (this is the headline D2 requirement and had no
      pin); absent ⇒ inherits provider/model, `agent` is the config default,
      channel `"web"`; 404 unchanged; `rebindNewResponse` unit cases.
- [ ] `GET /api/commands` → `[{"name":…,"synopsis":…}]` from `sdRegistry` (via
      `adSend`), `[]` when unwired; exact JSON pinned.
- [ ] `RouteCommands`: constructor + `routeMeta` arm + `allRoutes` entry in
      `src-gateway-types/Seal/Gateway/Types/Route.hs` (`:108`, `:187`, `:253`),
      arm in `src/Seal/Gateway/OpenApi.hs:104`, `ApiRouteSpec` 60 → 61, plus the
      `API.hs` dispatch arm (hand-written router).
- [ ] Rollback: restore `errJson status400` and drop the body parsing.

## WU-7 — chat `/new`

- [ ] Two mutually exclusive paths, **one mint each**:
      * prior session → `cccRebindNew` only;
      * no prior session → `cccNewSession` only, body `mintBody`.
- [ ] `ensureWsConn` on both paths; with WU-5 this actually re-targets delivery.
- [ ] `rebindBody :: Maybe Text -> Maybe Text -> Maybe Text -> Value` (pure,
      pinned); `channel = ccLabel chan` on the rebind path; the mint path sends
      `mintBody` (provider/model only) and records `"web"` (disclosed).
- [ ] Reply via the shared `renderNewSessionConfirmation`; no-prior-session ⇒
      `new session <sid>`.
- [ ] `rebind_error` ⇒ `warning: /new tab rebind failed: <e>` then the
      confirmation; `rebound:false` with no error ⇒ confirmation only.
- [ ] Transport failure or 404 ⇒ `new session failed: <e>`, mapping unchanged.
- [ ] `-r`: resolve a registered id via `cccGetRepos` (`T.strip`, exact id match,
      else verbatim), then `cccSetupRepo` on the new session, **both** paths, body
      `setupRepoBody url` = `{"url":…}`. Ordering: warning → repo failure →
      confirmation. Silences and repos-fetch failure as before.
- [ ] `doRequest` surfaces `{"error":…}` via `parseErrorBody` (non-JSON ⇒
      `HTTP <code>`) — needed for `repo setup failed: <err>`.
- [ ] Minting goes through `cccNewSession`, never `httpNewSession`.
- [ ] Tests (`Chat/LoopSpec`): one mint; conversation sid == rebind sid;
      subsequent message routed there; WS re-target (WU-5); warning ordering;
      no-bound-tab; 404/transport; `-r` id/URL/repos-failure/setup-failure/success;
      both warning and repo failure; no-prior-session reply.
      Pure helpers in `Chat/HttpClientSpec`.
- [ ] Rollback: restore `handleNewSession`'s current body.

## WU-8 — Telegram menu

- [ ] `HttpClient`: `CommandJson { cjName, cjSynopsis }` + `httpGetCommands`.
- [ ] `Seal.Channels.Chat.TelegramCommands` (new):
      `BotCommand`, `sanitizeTelegramName` (lowercase → `-`→`_` → keep
      `[a-z0-9_]` → collapse `__` → trim → clamp 32),
      `telegramMenuCommands :: [CommandJson] -> [BotCommand]` (help :: registry ::
      bg :: watch; drop empty-sanitised and length-1; dedupe first-wins; cap 100),
      `commandsPayload :: [BotCommand] -> Value` (pure encoder, **used by
      `tgSetCommandsViaApi`**), `registerWithRetry :: Int -> Int -> IO (Either Text
      [CommandJson]) -> ([BotCommand] -> IO (Either Text ())) -> IO (Either Text ())`
      (attempts, delay µs).
- [ ] Descriptions: help `Show available commands`; bg `Run a prompt in a
      background session`; watch `Toggle tab notifications`; registry =
      `csSynopsis` truncated to 256.
- [ ] Literals: `commandsPayload [BotCommand "help" "Show available commands"]`
      == `{"commands":[{"command":"help","description":"Show available commands"}]}`;
      `telegramMenuCommands []` == `[help, bg, watch]`.
- [ ] `tgSetCommandsViaApi :: Manager -> Text -> [BotCommand] -> IO (Either Text ())`.
- [ ] Wiring in `Serve.forkNewTelegramChatChannel`: fetch
      `httpGetCommands mgr apiBase` with `registerWithRetry 10 1000000`, forked
      (listeners start before `runGateway`).
- [ ] Tests: `Chat/TelegramCommandsSpec.hs` (new) for sanitise/menu/payload/retry
      incl. fetch-failure-never-registers. Registration as in WU-3.
- [ ] Rollback: drop the wiring call.

## WU-9 — docs + gate

- [ ] Update the handoff DoD status (gap-#1 correction, `/tab new` bug, D7/D8
      golden alignments).
- [ ] `/bg` + all tests pass; `-Wall -Werror` and `hlint` clean for `src/`,
      `test/`, `src-chat-channels/`, `src-gateway-types/`.
- [ ] New behaviour pinned red-first; behaviour this plan changes but does not add
      (the WU-4 registry pins) is labelled a regression pin.

---

## Backward compatibility / rollback

Per-WU rollback is stated in each unit. Cross-cutting changes:

* `/tab new` now mints and persists a real session (bug fix). **Visible**: the tab
  is `KindProvider`, so bare `/tab` prints `KindProvider`.
* `tabCommandSpec`/`newCmd`/`handleTabCommand` gain a parameter.
* `POST /api/sessions/:id/new`: optional body, additive response fields, rebind
  failure `400`→`200`, **and agent now resolved from config defaults** (D8; no
  frontend call site exists for this route).
* `/tab resume` reply drops the sid suffix (D7).
* `doRequest` surfaces `{"error":…}`.
* WS connection is recreated when the focused sid changes (WU-5) — the only
  behavioural fix outside the slash-command surface, required for `/new`.
* **`coreCommandSpecs` is shared by the web registry and the TUI**, so a chat or
  CLI `/tab new` now writes a session visible in the web sidebar's Recent
  Sessions. Intended (it is a real session), noted because it crosses surfaces.

---

## Known limitations

- `/tab list` uses `GET /api/lists` (not `/api/tabs`): `busy` needs
  `thinkingSessionIds`. Costs one call that builds `sessionInfoJsonWithSnippet`
  for every session.
- Three tab renderings coexist: bare `/tab`, chat `/tab list`, web/CLI `/tab list`.
- `/tab new` mints registry-side rather than via `POST /api/tabs/new` (the
  command layer has no HTTP client); same resulting state.
- `/tab new` sessions are labelled `"web"` on every surface.
- `/tab focus N` success path has no loop-level test (pre-existing; needs a
  `cccGetTabs` seam).
- A stale conversation session leaves `/new` failing with
  `new session failed: session not found`; the mapping is not cleared.
- `-r` success is silent (handoff §2 says "reports"; the golden was silent).
- `repo setup failed:` is one message, not two.
- Foreground asks stay button/web-only (unchanged from #283).
- `RoutingDecision.TabCommand` and `ChatRoute.ChatTabCommand` remain dead code
  (handoff §5 protects the guard).

---

## Verification

```bash
cabal build all
cabal test > /tmp/test.log 2>&1; tail -5 /tmp/test.log   # 3212+ examples, 0 failures
hlint src/ src-gateway-types/ test/                       # No hints
hlint src-chat-channels/                                  # No hints
```
