# `/new` — start a fresh session in the current tab

**Date**: 2026-07-19 · **Status**: approved (post-review-gate) · **Branch**: `feat/new-command-v2`

## Design review gate

5 reviewers ran in parallel (architect, PM, security-design, designer, CTO).
All 5 returned APPROVE_WITH_NOTES; no rejections. Concerns that reshaped the
design (resolved with the user):

- §2.5 was under-scoped: `isaReg` (not just `tHandle`) is launch-wide and
  bakes `sid0` into `MEMORY_WRITE`/`SKILL_WRITE`/`AGENT_DEF_WRITE`. The fix
  must rebuild `isaReg` + reopen the transcript per turn (mirror
  `runTurnOnSession`). This also fixes a latent bug where CLI `/tab focus`
  doesn't switch the active session. Lands as commit 1 (latent-bug fix).
- `/new` mints the session **out-of-band** (direct `newSession` call, not
  via a `SESSION_NEW` opcode). The README's ISA table lists `SESSION_NEW`
  as Trusted but it's not yet implemented; existing session-creation paths
  (`createConversationSession`, `handleTabNew`) also skip the opcode, so
  this is consistent. **Deferral recorded**: a future `SESSION_NEW` opcode
  should retroactively cover all three creation sites.
- Inbox multi-cursor: per the user's mental model ("a tab can only have
  one session at any point in time; changes to tab N affect any channel
  pointed at tab N"), `/new` rebinds the shared tab AND migrates every
  cursor pointing at the old sid to the new sid.
- The "Recent Sessions +" button is a **distinct** operation from `/new`:
  it creates a bare session (no tab attached) and focuses it. Web-only.
- Keep the name `/new` (per user). `/help` synopsis explicitly contrasts
  with `/tab new`.
- All 4 channels ship in v1.

## 1. Problem

Today, starting a fresh conversation in an existing context requires either
spawning a new tab (`/tab new`, the "New tab" `+` button) or restarting
`seal`. There's no way to say "I'm done with this conversation; keep my
tab/workspace focus but start a clean session in it." Users on every channel
(CLI TUI, Signal, Telegram, Web) currently conflate "fresh conversation"
with "new tab," which clutters the tab list and breaks muscle memory across
channels (chat apps have a universal "new chat" affordance that *doesn't*
spawn a window).

## 2. Design

### 2.1 Semantics

`/new` starts a fresh session **in the current tab/context** — it does NOT
create a new tab. Concretely:

- A new `SessionMeta` is minted from config defaults (same path as
  `initSession`/`createConversationSession`: `defaultSessionSelection` +
  `resolveDefaultAgent`). It is persisted via `saveSessionMeta` so
  `/session list` can see it.
- The old session is **kept on disk, untouched** — still listed in
  `/session list`, still resumable with `/tab resume <id>` or by clicking
  its row in "Recent Sessions".
- The current tab/context is **rebound** to the new session's id. No new
  tab is inserted, no tab is closed, the tab's index/label/kind are
  preserved.
- After `/new`, subsequent plain turns route to the new session.

The contrast with `/tab new`: `/tab new` *inserts* a tab bound to a
placeholder session id; `/new` *rebinds* the current tab to a fresh,
persisted session id.

### 2.2 What "the current tab" means per channel

The four channels track "current" differently, so `/new` has four wiring
sites that share one pure core:

| Channel | "Current" tracker | Rebind action |
|---|---|---|
| CLI TUI | `srActive :: IORef SessionMeta` (`Session/Store.hs`) | `writeIORef srActive newMeta` + rebind the focused tab in `TabsHandle` (if any) to the new sid |
| Signal / Telegram (inbox) | per-conversation `CursorStore` key → `TabRef` (`Channels/Cursor.hs`) | `cursorSet cursors key (BoundSession newSid)` + rebind the tab in `TabsHandle` whose `TabRef` was the old cursor to the new sid |
| Web gateway | the session id the SPA is currently viewing (`/api/sessions/:id/...`) | mint new session, rebind the tab in `TabsHandle` that owns the old sid to the new sid, return the new sid; the SPA navigates to it |

### 2.3 Rebinding a tab in place

`TabsHandle` currently has `insertTabH`/`removeTabH`/`renameTabH`/`focusTabH`
but **no in-place rebind**. We add one pure operation on `TabList` and one
IO wrapper:

```haskell
-- Seal.Tabs.Types
rebindTab :: TabIndex -> TabRef -> TabList -> Either Text TabList
-- Left if index out of range or new TabRef is already bound to ANOTHER tab (I2).
-- Rebind-to-same-ref is a no-op Right (idempotent).

-- Seal.Tabs
rebindTabH :: TabsHandle -> TabIndex -> TabRef -> IO (Either Text ())
```

I2 (no two tabs share a `TabRef`) is preserved: `rebindTab` rejects if the
new ref is already bound to a *different* slot. Rebinding a tab to its own
current ref is a no-op. The slot's index, kind, label, and status are
preserved — only `tRef` changes.

Per-channel use of `rebindTab`:

- **CLI**: snapshot `TabsHandle`; find the tab (if any) whose
  `tRef == BoundSession oldSid`; `rebindTabH` it to the new sid. The CLI
  has no cursor — `srActive` is the single source of truth.
- **Inbox (Signal/Telegram)**: the issuing conversation's cursor points at
  a `TabRef`; `rebindTabH` that tab to the new sid, then **migrate every
  other cursor** in `CursorStore` pointing at the old ref to the new ref
  (per the user's model: a tab has one session at a time; all channels
  focused on the tab follow it to the new session).
- **Web `POST /api/sessions/:id/new`**: snapshot `TabsHandle`; find the
  tab (if any) whose `tRef == BoundSession oldSid`; `rebindTabH` it; return
  the new sid + tab index. If no tab is bound to the old sid (the SPA is
  viewing a "Recent Sessions" row that isn't in a tab), just return the
  new sid; the SPA navigates to it.

### 2.3.1 "Recent Sessions +" — bare new session (web-only)

Distinct from `/new`: the "Recent Sessions +" button creates a **bare**
session (no tab attached) and focuses it. New endpoint
`POST /api/sessions/new` (no `:id`):

1. Mint a `SessionMeta` via `newSession paths provider model "web" mAgent`
   (config defaults; same as `handleTabNew`'s provider branch).
2. Do NOT touch `TabsHandle`.
3. Respond `200 { session_id: <newSid> }`.

The SPA navigates to `session:<newSid>`. The WS `lists` broadcast refreshes
the sidebar; the new session appears in "Recent Sessions". This matches the
user's spec: "the new + button always creates a new session (a bare
session not attached to any tab) and sets the focus to that session."

### 2.4 Pure core: `Seal.Command.New`

A new module `Seal.Command.New` exposes a `CommandSpec`-building function
for the **CLI and web-gateway** registry paths (the inbox channels use a
loop-level route instead — see §2.6). The IO action mints a session and
calls a channel-supplied rebind callback:

```haskell
data NewDeps = NewDeps
  { ndPaths        :: SealPaths
  , ndCfg          :: IO FileConfig
  , ndBackends     :: Backends     -- for resolveDefaultAgent
  , ndChannelLabel :: Text         -- "cli" / "web"
  , ndRebind        :: SessionMeta -> SessionId -> IO ()  -- new meta, old sid
  }

newCommandSpec :: NewDeps -> CommandSpec
```

The `ndRebind` callback is the seam: it receives the new `SessionMeta`
**and the old sid** (so it can find the tab to rebind without ordering
ambiguity — architect review issue D). The spec's `CommandAction` mints
the session, calls `ndRebind`, and `ccSend`s a one-line confirmation that
**names the old session and how to resume it** (per PM/designer review):

```
new session <newSid> (provider/model) — tab <idx> rebound; prior session <oldSid> kept in /session list
```

The CLI closure's `ndRebind` reads `srActive` for the old sid, swaps it,
and rebinds the matching tab. The web closure's `ndRebind` (used by
`runSlash` when the user types `/new` in the web composer) takes the old
sid from the active session ref and rebinds the matching tab.

The **inbox channels** don't use `newCommandSpec` — they handle `/new` at
the loop level (§2.6) because the conversation key/cursor isn't available
to a registry `CommandAction`.

### 2.5 CLI wiring (`Tui.hs`, `Channel/Cli.hs`)

**Commit 1 (latent-bug fix, lands before `/new`):** `runCliTui` opens
`withTwoFileTranscript sessionDirPath` once at launch for `sid0`
(`Channel/Cli.hs:322`) and builds `isaReg` once at launch
(`Channel/Cli.hs:417-448`), baking `sid0` into `memoryWriteOp`/`skillWriteOp`/
`agentDefWriteOp` (lines 426/429/433). `plainHandler` (line 601-616) reads
`smId meta` from `srActive` per turn but **reuses the launch-captured
`isaReg` and `tHandle`** — so today, after a CLI `/tab focus` to a
different session (if it ever swaps `srActive`), a plain turn would write
the transcript + memory/skill/agent-def entries to the **old** session.
This is a latent audit-trail integrity bug independent of `/new`.

The fix mirrors `runTurnOnSession` in `Channels/Loop.hs:416-468`: move the
`isaReg` construction + `withTwoFileTranscript` bracket **inside**
`plainHandler` (per turn, using `smId meta` from `srActive`). The
`bgRunner` already opens its own bracket per `/bg` invocation, so it's
unaffected. `/call`'s `callDispatcher` (line 599-600) closes over the
launch-wide `isaReg`/`tHandle`; we rebuild them inside the dispatcher
using the current `srActive` (same pattern). File handle churn is
acceptable — the inbox loop already pays this per turn.

**Commit 2+ (the `/new` feature):** `Tui.hs` builds `NewDeps` with
`ndChannelLabel = "cli"` and an `ndRebind` that:
1. reads the old `SessionMeta` from `srActive` (old sid = `smId`);
2. `writeIORef (srActive sr) newMeta`;
3. snapshots `TabsHandle`; if any tab's `tRef == BoundSession oldSid`,
   `rebindTabH` it to the new sid.

`Channel/Cli.hs`'s loop already routes `SlashCommand` to the registry, so
registering the spec is enough — no loop change. The per-turn `plainHandler`
reads `srActive` fresh, so the next turn after `/new` uses the new session's
transcript dir + `isaReg` (rebuilt per turn by commit 1).

### 2.6 Inbox channel wiring (`Channels/Loop.hs`)

The architect review flagged that a registry `CommandAction` has no access
to the per-message conversation key/cursor (they're local to the loop
iteration in `runChannelLoop`). So `/new` on inbox channels is a
**loop-level route**, not a registry `CommandSpec` — matching the existing
pattern for `Route.Focus`/`Route.Inject`/`Route.TabCommand`.

We extend `Seal.Routing.Route` with one constructor and one parser arm:

```haskell
data RoutingDecision = ... | NewSession
route "/new" -> Right NewSession
```

(Kept minimal — no args parsed. The loop handler does all the work.)

In `runChannelLoop`, the `Right (Route.NewSession)` arm:
1. resolves the conversation's current `TabRef` from the cursor (same
   path as the plain-turn branch);
2. mints a new `SessionMeta` from config defaults via `newSession` with
   channel label = `channelKindToText (msChannelKind ms)`;
3. snapshots `TabsHandle`; finds the tab whose `tRef` matches the cursor's
   old ref; `rebindTabH` it to the new sid (if found);
4. **migrates cursors**: scan `CursorStore`, for every conversation whose
   cursor == old ref, `cursorSet` it to `BoundSession newSid`. This is the
   user's "all channels on tab N follow the rebind" semantics;
5. `ccSend`s the confirmation line (see §2.4).

The `meta` used by `plainTurn` is re-resolved per turn from the cursor, so
the next inbound message after `/new` resolves to the new session
automatically — no other loop change needed. `Signal/Run.hs` and
`Telegram/Run.hs` need no spec registration (the route is parsed before
the registry); the only wiring is the new `Route.NewSession` arm, which
lives in `Channels/Loop.hs` (shared by both channels).

### 2.7 Web gateway wiring

Two new endpoints:

**`POST /api/sessions/new`** (bare session, no tab — for the "Recent
Sessions +" button):
1. Mint a `SessionMeta` via `newSession paths provider model "web" mAgent`.
2. Do NOT touch `TabsHandle`.
3. Respond `200 { session_id: <newSid> }`.

**`POST /api/sessions/:id/new`** (rebind current tab — for a future web
`/new` invocation if the user types `/new` in the web composer; also the
endpoint a keyboard-shortcut could call):
1. `mkSessionId sid` validates the old id; 404 if it doesn't resolve to
   an on-disk session (matches `handleSessionPrompt`/`handleSessionAgent` —
   prevents orphan-session spam, per security review Q1).
2. Mint a new `SessionMeta` via `newSession paths provider model "web"
   mAgent` (config defaults).
3. Snapshot `TabsHandle`; if a tab has `tRef == BoundSession oldSid`,
   `rebindTabH` it to the new sid.
4. Respond `200 { session_id: <newSid>, tab_index: <idx|null>, rebound:
   <bool> }` (the `rebound` flag lets the SPA branch cleanly, per designer
   review note 1).

Both reuse `ApiDeps` (it has `adSessionRuntime` + `adTabsHandle` +
`adAgentDefs` for `resolveDefaultAgent`). No new deps field.

Frontend `useApi.ts` gains two helpers:
- `createBareSession(): Promise<{ session_id: string } | null>` — for the
  "+" button.
- `rebindCurrentTabToNewSession(oldSid): Promise<NewSessionResponse | null>`
  — for the typed `/new` path (invoked by sending `/new` through
  `/api/sessions/:id/send`, which already routes slash commands via
  `runSlash`; **so this helper may not be needed in v1** — verify whether
  `runSlash` already dispatches `/new` via the registry. If the web
  composer routes `/new` through `/send`, the gateway's `runSlash` needs
  the `newCommandSpec` registered too — see §2.9).

The SPA's `handleNewBareSession` (for the "+" button) navigates to
`session:<newSid>`. The WS `lists` broadcast refreshes the sidebar.

### 2.8 Frontend "Recent Sessions +" button

`Sidebar.tsx`'s `SectionHeader` for "Recent Sessions" becomes a flex row
(matching `ActiveTabs.tsx:301-320`) with a `+`-style button as a sibling of
the label. Per designer + PM review: the button uses a **distinct icon**
(a sparkle ✦ or refresh-like glyph, not a bare `+`) plus a visible "New
session" text label, so it's visually distinct from the "Active Tabs" `+`
(which keeps its bare `+` "New tab" affordance).

The button **always** creates a bare new session and focuses it (per the
user's spec — no "current selection" branching, no disabled state). It
calls a new `onNewSession` callback prop → `handleNewBareSession` in
`App.tsx` → `createBareSession()` → navigate to `session:<newSid>`.

The Active Tabs `+` keeps its existing "open the composer" behavior. The
two `+`s are now semantically and visually distinct:
- "Active Tabs +" (`+`) = new tab (composer).
- "Recent Sessions ✦" = new bare session, focused.

Accessibility: the new button gets `type="button"`, an explicit
`aria-label="New session"` (not derived from the section header), and
`title="New session"`. Backfill `type="button"` on the existing Active
Tabs `+` while we're here (designer review note 5).

### 2.9 `/help`, Telegram bot menu, and web `runSlash`

`/new` is registered as a `CommandSpec` (GroupSession,
`AlwaysAvailable`), so the CLI `/help` picks it up automatically. The
synopsis explicitly contrasts with `/tab new`:

```
/new              Start a fresh session in the current tab (vs /tab new, which opens a new tab)
```

The Telegram `tgSetCommands` registration
(`Channels/Telegram/Commands.hs`) filters by `isMenuEligible` — verify
`/new` qualifies (same as `/session`).

**Inbox channels**: `/new` is NOT in the registry passed to
`runChannelLoop` (it's a loop-level route per §2.6). The Telegram bot menu
derives from the same registry, so `/new` won't appear in BotFather's
auto-completion — that's fine; the loop-level route still handles `/new`
when typed.

**Web `runSlash`**: when the user types `/new` in the web composer, it
goes through `POST /api/sessions/:id/send` → `handleSend` → `runSlash`
(`Gateway/Send.hs:399`), which dispatches via the registry. So the web
gateway's registry (built in `Command/Serve.hs`) must include
`newCommandSpec` with an `ndRebind` that rebinds the tab in
`TabsHandle` (the web has no cursor — it tracks "current" via the
session id the SPA is viewing). The old sid comes from the active
session ref. After `runSlash`, the SPA's WS `lists` broadcast refreshes
the sidebar; the SPA re-fetches the tab list and navigates to the new
session (the `SendSlash` outcome carries the confirmation line, which
the SPA could parse, but the cleaner path is for `runSlash` to also
return the new sid — see §6 Risks).

### 2.10 Naming

Per the project's "descriptive words, not metaphors" philosophy, `/new`
is plain and self-explanatory. The `/help` synopsis (§2.9) explicitly
contrasts it with `/tab new` to dissolve the ambiguity the PM/designer
reviewers flagged. The "Recent Sessions ✦" button's `title`/`aria-label`
is "New session" — also plain.

## 3. Definition of Done

**Commit 1 — per-turn isaReg + transcript refactor (latent-bug fix):**
- [ ] `runCliTui`'s `plainHandler` rebuilds `isaReg` + opens
      `withTwoFileTranscript` per turn using `smId meta` from `srActive`,
      mirroring `runTurnOnSession`. `/call`'s `callDispatcher` rebuilds
      them the same way.
- [ ] Integration test: simulate a swap of `srActive` (e.g. via a test
      hook or by rebinding the active tab), run a turn that triggers
      `MEMORY_WRITE` (via `/call MEMORY_WRITE`), and assert the entry
      lands in the NEW session's `entries.jsonl` + memory key — not the
      old session's. (This is the single most important test — security
      review Q4.)
- [ ] Existing CLI tests still pass.

**Commit 2+ — the `/new` feature:**
- [ ] `rebindTab`/`rebindTabH` added with unit tests covering: happy path
      (preserves `tKind`/`tLabel`/`tStatus`), out-of-range index, I2
      violation (new ref already bound to a *different* tab), rebind-to-
      same-ref is a no-op `Right`, I2 check excludes the target slot.
- [ ] `Seal.Command.New` module + `newCommandSpec` with parser tests:
      `/new` mints a session, calls `ndRebind newMeta oldSid`, sends a
      confirmation line naming the old sid + resume hint.
- [ ] CLI: `/new` swaps `srActive` and rebinds the matching tab; next
      plain turn uses the new session's transcript dir + `isaReg`.
      Verified by an integration test that runs `/new` then a plain turn
      and checks the new `session.json` + transcript land under the new
      sid, and `MEMORY_WRITE` keys to the new sid.
- [ ] Inbox: `Route.NewSession` constructor + parser arm; `runChannelLoop`
      handles it: mints session, rebinds the cursor's tab, **migrates
      every other cursor** pointing at the old ref to the new ref, sends
      confirmation. Verified by a focused `Loop`-level test (or a
      channel-level test if the loop harness is too heavy).
- [ ] Web: `POST /api/sessions/new` (bare) returns the new sid, no tab
      touched. `POST /api/sessions/:id/new` (rebind) returns new sid +
      tab_index + `rebound` flag; 404 when `:id` doesn't resolve to an
      on-disk session. Both verified by `ApiSpec` tests.
- [ ] Web `runSlash` dispatches `/new` via the registry; the web
      `newCommandSpec`'s `ndRebind` rebinds the tab in `TabsHandle`.
      Verify by a `SendSpec` test or by noting the ApiSpec test covers
      the same path.
- [ ] Frontend: "Recent Sessions ✦" button (distinct icon + "New
      session" label) renders; clicking calls `createBareSession` and
      the SPA navigates to `session:<newSid>`. Verified by a `Sidebar`
      test (button renders + fires `onNewSession`) and an `App` test
      (navigation).
- [ ] `/help` index includes `/new` with the contrast-vs-`/tab new`
      synopsis.
- [ ] `make check` green (cabal test + hlint). Frontend `npm run test`
      green.
- [ ] README "Quick Start" mentions `/new` (one line).

## 4. File scope

**Commit 1 — refactor:**
- `src/Seal/Channel/Cli.hs` — move `isaReg` + `withTwoFileTranscript`
  inside `plainHandler` and `callDispatcher` (per-turn).

**Commit 2+ — feature:**
Backend:
- `src/Seal/Tabs/Types.hs` — `rebindTab`
- `src/Seal/Tabs.hs` — `rebindTabH`
- `src/Seal/Routing/Route.hs` — `NewSession` constructor + parser arm
- `src/Seal/Channels/Loop.hs` — `NewSession` arm (mint + rebind + migrate cursors)
- `src/Seal/Command/New.hs` — new module (pure core + `newCommandSpec`)
- `src/Seal/Tui.hs` — build `NewDeps`, register spec
- `src/Seal/Command/Serve.hs` — register `newCommandSpec` in the web gateway registry
- `src/Seal/Channels/Cursor.hs` — `cursorMigrateAll` (scan + update cursors pointing at old ref)
- `seal-harness.cabal` — expose `Seal.Command.New`

Tests:
- `test/Seal/TabsSpec.hs` (or `Tabs.TypesSpec.hs`) — `rebindTab`
- `test/Seal/Command/NewSpec.hs` — new
- `test/Seal/Routing/RouteSpec.hs` — `NewSession` route
- `test/Seal/Gateway/ApiSpec.hs` — both new endpoints
- existing CLI/inbox tests updated if needed

Frontend:
- `frontend/src/components/Sidebar.tsx` — "Recent Sessions ✦" button
- `frontend/src/App.tsx` — `handleNewBareSession` callback, wired into
  `Sidebar.onNewSession`
- `frontend/src/hooks/useApi.ts` — `createBareSession` (+ optional
  `rebindCurrentTabToNewSession`)
- `frontend/src/components/__tests__/Sidebar.test.tsx` — button test
- `frontend/src/__tests__/App.test.tsx` — navigation test

Docs:
- `docs/superpowers/plans/2026-07-19-new-command.md` — this plan
- README "Quick Start" — one line on `/new`

## 5. Human checkpoints

- After commit 1 (the refactor) lands + tests green: pause for user to
  sanity-check the latent-bug fix didn't regress the CLI before layering
  `/new`.
- After CLI `/new` green: pause for user to try `/new` in the TUI before
  doing the inbox + web work.
- Before commit: user reviews the diff.

## 6. Risks

- **Per-turn `isaReg` rebuild (commit 1)** is the one non-additive
  change. The fallback if it breaks: revert commit 1, defer `/new`'s CLI
  arm; inbox + web `/new` don't depend on the refactor (they already
  rebuild `isaReg` per turn / per request). The refactor is justified
  independently by the `/tab focus` latent bug.
- **Web `runSlash` returning the new sid**: `runSlash` currently returns
  `SendSlash <concatenated ccSend output>` — a string. The SPA can't
  programmatically extract the new sid to navigate. Options: (a) parse
  the sid out of the confirmation string (fragile), (b) extend
  `SendSlash` with an optional structured payload (cleaner, but a wider
  change to `SendOutcome`). v1 likely does (a) with a regex; (b) is a
  follow-up. The "Recent Sessions ✦" button does NOT have this problem
  (it uses `POST /api/sessions/new` directly, returning structured
  JSON).
- **I2 invariant under rebind**: if the new sid collides with an
  existing tab's ref (extremely unlikely — sids are timestamp-minted),
  `rebindTab` returns `Left`; the command reports the error; the old
  session stays bound. No corruption.
- **Cursor migrate race**: `cursorMigrateAll` scans `CursorStore` and
  updates each match in one STM transaction (the same `TVar` as
  `cursorSet`), so a concurrent `cursorLookup`/`cursorSet` from another
  conversation is race-safe.
- **`SESSION_NEW` opcode deferred**: recorded in §2 (design review gate).
  Consistent with `createConversationSession`/`handleTabNew` which also
  skip the opcode. A future `SESSION_NEW` opcode should cover all three
  creation sites retroactively.