# Learnings: Chat-channel slash-command parity (PR #283, WU-6 → WU-9)

**Captured**: 2026-10-26 (post-implementation self-reflect)
**Branch**: `chat/bg-restore-279` · **Plan**: `docs/plans/active-plan.md` (rev 9)
**Scope of the session**: finishing WU-6 (gateway), WU-7 (chat `/new`), WU-5
(stale WS filter), WU-8 (Telegram menu), WU-9 (docs + gate).

Durable facts a future agent would otherwise rediscover the hard way.

---

## 1. `hspec --match` that matches nothing passes

`cabal test --test-options='--match "TelegramCommands"'` printed **`0 examples,
0 failures`** and **exited 0**: the new spec had no `describe` with that word,
so nothing ran. Always read the example count; a run that is too fast (or
reports fewer examples than the previous baseline) matched nothing.

Corollary for this repo: `test/Main.hs` has **no hspec-discover**. A new spec
file that is not added to `other-modules` *and* to both lists in `test/Main.hs`
(the `import qualified` list and the `spec` list) silently never runs — and the
suite count stays green.

## 2. `git commit -am` silently omits new files

The WU-8 commit reported "5 files changed" while the two *new* files (the module
and its spec) were still untracked. The build was green locally, so nothing
flagged it. For a work unit that adds a module: `git add` the new paths, then
`git commit --amend --no-edit`. `git status --short` is the check.

## 3. The chat loop's WS connection cannot be re-targeted by a FocusOp

`handleServerEvent` closes over the focused `SessionId` **by value**
(`Loop.hs`, `ensureWsConn`). An existing connection therefore keeps filtering
for the session it was built for, no matter how many `FocusOp`s arrive. After
`/new` (or `/tab focus N`) the new session's `SeEntry`/`SeAsk` events were
dropped — and a plain turn's text is delivered **only** over WS, so the rebound
session produced no visible replies or asks at all.

The connection map now carries the bound session:
`TVar (Map ConversationKey WsConn)` with
`type WsConn = (SessionId, WsClient, StreamingState)`; `ensureWsConn` reuses a
connection only when that session matches, and otherwise closes the client,
drops the entry and rebuilds the callback.

**Test trap**: asserting "a focus was recorded on the new sid" **passes while
the bug persists** (the FocusOp is sent either way). The pin must be: a second
`cccStartWs`, the old client closed, and an entry for the new session delivered
through the **new** callback producing a `ccSend`. Verified by mutating
`ensureWsConn` back to focus-only reuse — the pin goes red.

## 4. Two seams in the loop were bypassed, and it made tests lie (or take 5s)

- `ensureWsConn` called `startWsClient` directly instead of `cccStartWs`, so
  every `/new` test dialled `127.0.0.1:8081` and waited out the 5s WS connect
  timeout (8 tests → 35s). It now goes through the seam; production default is
  unchanged.
- `resolveSession` calls `httpNewSession` directly instead of `cccNewSession`,
  so the first-message mint **cannot** be scripted through the seams. Tests
  that need an existing session must seed `sessionInsert` or the connection map
  rather than "run a plain message first".

## 5. `-Werror` plus a total `\case` is the OpenAPI safety net

Adding `RouteCommands` to the `SealRoute` GADT broke the build in
`routeMeta`/`allRoutes` (`src-gateway-types`) until the arms existed, and in
`openApiMeta` (`src/Seal/Gateway/OpenApi.hs`) — all totals. A route added to the
spec cannot silently miss its OpenAPI documentation, so that needs no test. The
hand-written router in `API.hs` is *not* total over the GADT, so a missing
dispatch arm **is** silent: `/api/commands` needed an explicit
`(m', ["api","commands"])` case and its own request test.

## 6. `A.Value` equality is the cheapest JSON pin in the repo

`A.decode body \`shouldBe\` Just (A.object ["name" .= ("alpha" :: Text)])` pins
the entire response shape — key order included — with no helper. Use it for
"the exact JSON the client sees" (the `/api/commands` menu, `commandsPayload`,
`rebindNewResponse`) instead of field-by-field lookups; use field-by-field only
when the object has volatile members (timestamps, ids).

## 7. Why `/api/sessions/:id/new` answers 200 with `rebound: false`

The handler **mints before it rebinds**. A 4xx on rebind failure would discard
the new session id — exactly what the caller needs both for the warning line
(`warning: /new tab rebind failed: <e>`) and the confirmation
(`new session <sid> (<prov>/<model>) — prior session <oldSid> kept in
/session list`). That branch is only reachable via an out-of-range race or a
same-millisecond sid collision, so it is pinned through the extracted pure
`rebindNewResponse`, not through HTTP.

Related: sid minting is **millisecond** precision (`formatSessionId`), so a test
that mints twice back-to-back must `threadDelay 5000` or the ids collide.

## 8. Telegram keeps the menu server-side

Nothing in the tree called `setMyCommands` for months, yet the bot's menu looked
right — it was a stale registration from an older bot build. "The menu looks
right" is therefore not a verification; pin the `setMyCommands` **request body**
(`commandsPayload`) and the menu builder separately.

`registerWithRetry` exists because the chat listeners are forked *before*
`runGateway` binds the HTTP port: an immediate `GET /api/commands` always races
the bind. A failed fetch must never fall through to registering an empty menu
(it would wipe the bot's commands) — that is now a pin.
