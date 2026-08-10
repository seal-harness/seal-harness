# Repo-Local Agent Defs in the Session Setup Dropdown

**Date**: 2026-08-09 · **Status**: revised (round 2, post-review-gate) · **Branch**: `feat/repo-agents-dropdown` (base: `feat/repo-discovery`, PR #87) · **Issue**: #89

## Design review gate (round 1 → round 2)

Round 1 ran 5 reviewers (PM, Architect, Designer, Security, CTO) in parallel.
Architect: APPROVED WITH MINOR REVISIONS; PM/Designer/Security/CTO:
NEEDS_REVISION. Resolutions:

- **PR #87 dependency unstated** (Architect B1, CTO B2) — the branch must
  rebase on `feat/repo-discovery` (PR #87, OPEN), not `main`; `workdirAgentDefBackend`/`unionAgentDefBackend`/`RepoDiscoverySpec` only exist there. Added §0 Prerequisites.
- **Missing merge points** (CTO B1) — W1 must wire `seal-harness.cabal` + `test/Main.hs` for the new/extended spec. Added to W1 file scope.
- **SETUP_REPO re-fetch race** (Architect B2, Designer B2) — the async clone lands after `useSessionAgents(sid)` first fetches, so the dropdown is stale. Resolution: the backend broadcasts `broadcastAgentDefsChanged` when `SETUP_REPO` completes (the opcode handler already runs in the control plane); `useSessionAgents` re-fetches on `onAgentDefsChanged` (the existing invalidation path). Added §3.6.
- **`fetchDefaultAgent()` vs session-scoped `isDefault`** (Designer B1) — App.tsx's default-resolution effect calls `fetchDefaultAgent()` (→ `GET /api/agents/default`, the user-configured default only), which never sees the repo default. Resolution: when a session is focused, App.tsx reads `isDefault` from the session-scoped list (dropping the `fetchDefaultAgent()` call in that branch); the global branch is unchanged. Added §3.7.
- **Rules-of-hooks hazard** (Designer B3) — `useSessionAgents(sessionId)` must be called unconditionally. Resolution: signature `useSessionAgents(sessionId: string | null)` — internally fetches `/api/sessions/:id/agents` when `sessionId` is non-null, `/api/agents` when null. One hook, one fetch. Added §3.5.
- **Symlink escape / SafePath confinement** (Security B1) — discovery reads via raw `System.Directory` follow symlinks; bytes flow to the LLM + transcript. Resolution: every file open in the protocol scan goes through `mkSafePath` against a `WorkspaceRoot` anchored at the repo's `.agents/` dir; reject symlinks escaping that root. Added §3.8 + §5.
- **Size cap on `agent.md` reads** (Security B2) — inherit `maxBootstrapFileBytes` (1MB) + `truncateSection`. Added to W1 DoD.
- **`enabled` absent vs `false`** (Security Q2, CTO B4) — the protocol defaults `enabled` to true when absent. Resolution: absent `enabled` → enabled (appears); explicit `enabled: false` → skipped. Fixed §3.3 + §5.
- **No use cases / success metrics** (PM B1, B2) — added §1.0 + §1.1.
- **`agents-md` display name leakage** (PM Q3, Architect S2, CTO Q3) — the dropdown shows the synthetic id when frontmatter `name` is absent. Resolution: `adName` for `agents-md` falls back to `"Project (agents.md)"` (a friendly display), not the raw id. Added §3.1.
- **Dispatch predicate for protocol vs legacy** (CTO B3) — added §3.3 detection rule.
- **QuickCheck property for id derivation** (CTO B5) — added to W1 DoD.
  Round-2 CTO review caught the original "never equals a valid subdir id"
  property as unsound (`"agents-md"` is itself a valid subdir id per
  `isValidAgentDefId`; §3.1 concedes collision is possible and handled by
  flat-wins). Resolved by rewording the property to assert the **suffix-shape
  invariant** (the actual invariant the `-md` suffix buys): `deriveAgentsMdId`
  always produces a value that passes `isValidAgentDefId` and ends in the
  literal suffix `"-md"`. Collision-freedom is NOT claimed — flat-wins is the
  real guard (§3.1).
- **`AgentInfo` narrowing defeats the friendly display name** (Designer round-2 B1) —
  §3.1 sets `adName` to `"Project (agents.md)"` so the synthetic id never
  leaks, but §3.5 narrowed the hook to `AgentInfo` (`{name, isDefault}` — no
  `displayName`), and `SessionSetup` renders `a.name` (the id). Resolved:
  widen `AgentInfo` to include `displayName?: string` (W3 file scope already
  includes `types.ts` + `ChatArea.tsx`); `SessionSetup` renders
  `{a.displayName ?? a.name}`. The `agentInfoJson` backend already emits
  `displayName` (`API.hs:1616`), so no backend change.

## 0. Prerequisites

This branch **rebases on `feat/repo-discovery` (PR #87, OPEN)**, not `main`.
PR #87 introduces `workdirAgentDefBackend`, `unionAgentDefBackend`,
`workdirAgentDefConventions`, `listWorkdirAgentDefs`, and
`test/Seal/RepoDiscoverySpec.hs`. None exist on `main`. The PR body must
note the stacked dependency on #87 (or #87 merges first). CI for a stacked
PR runs against #87's HEAD; `make check` is the gate.

## 1. Problem

### 1.0 User stories

1. **Developer cloning a repo** (WHO) — when they clone a repo via
   `SETUP_REPO` (WHEN) — wants to start a session with the project's intended
   agent persona (WANTS-TO) — so they get the behavior the repo author
   designed without manually importing agent defs into their global store
   (SO-THAT).
2. **Repo author shipping `.agents/`** (WHO) — when they publish a repo
   (WHEN) — wants their defined sub-agents discoverable to any clone
   (WANTS-TO) — so collaborators get the right tooling persona out-of-the-box
   (SO-THAT).

### 1.1 Success metrics (user-focused, measurable)

- When a session is focused on a repo that ships `.agents/`, the Agent
  dropdown shows ≥1 repo-local def within 1 render of session focus (no
  manual refresh), including after async `SETUP_REPO` completion.
- For a repo conformant to the `.agents Protocol`, zero bogus empty-prompt
  agents (`agents`, `skills`) appear in the dropdown (regression of the
  discovery bug described below).
- The repo default (`agents-md`) is pre-selected (dropdown highlight, not
  auto-bind) for sessions on conformant repos where the user has no
  `default_agent` configured.
- Binding a repo-local agent id via the dropdown results in the correct
  system prompt on the first turn (no silent fallback to a different agent).

### 1.2 Discovery gap — `.agents Protocol` is not understood

The repo's own `.agents/` (post commit `24eb5cb`) conforms to the [.agents
Protocol][protocol]:

```
.agents/
├── agents.md            # kind: agents frontmatter — project instructions
└── agents/
    └── <id>/
        └── agent.md     # sub-agent profile (frontmatter id/name/description/role/enabled + body)
```

`workdirAgentDefBackend` (PR #87) treats each convention dir (`.agents/`,
`.seal/agents/`, `agents/`) as a *seal* agent-def directory and calls
`listAgentDefs`, which does hybrid flat + DirScheme discovery:

- **Flat** (`collectFlat`): `*.md` files → `decodeAgentDef`, which requires
  frontmatter `id`. `.agents/agents.md` has `kind: agents` and **no `id`** →
  returns `Nothing` → **dropped**. The project AGENTS.md never surfaces.
- **Dir** (`collectDirs`): subdirectories whose name passes
  `isValidAgentDefId` → `loadDirAgentDef`, which composes the system prompt
  from bootstrap files `SOUL.md`/`AGENTS.md`/... (fixed list; `agent.md` is
  NOT in `sectionFileName`). So `.agents/agents/<id>/` becomes an `AgentDef`
  with id `agents` and an **empty** system prompt; the real `<id>/agent.md`
  is never read. Same for `.agents/skills/<id>/` → bogus id `skills`.

Net: a conformant repo yields two bogus empty-prompt agents (`agents`,
`skills`) and misses every real sub-agent plus the project AGENTS.md.

### 1.3 Exposure gap — no session-scoped agent-defs endpoint

`SessionSetup` (frontend) populates `useAgents()` → `GET /api/agents` — the
**global** user store. The workdir-aware `unionAgentDefBackend` (workdir ⊕
user, workdir-wins) is constructed only at turn-dispatch time (`Send.hs:448`,
`Loop.hs:742`, `Cli.hs:550`) and is never exposed over REST. So even with
correct discovery, the dropdown can't show repo-local defs.

[protocol]: https://dotagentsprotocol.com

## 2. Goals / Non-Goals

**Goals:**
1. Discover `.agents/agents/<id>/agent.md` as an `AgentDef` (id = subdir name;
   system = `agent.md` body after frontmatter; frontmatter
   `name`/`provider`/`model` honored).
2. Discover `.agents/agents.md` (the project AGENTS.md, `kind: agents`) as an
   `AgentDef` and treat it as the **repo default**.
3. Expose the session-scoped union (workdir ⊕ user) via
   `GET /api/sessions/:id/agents`.
4. The Session setup dropdown populates from that endpoint and pre-selects
   the repo default when present (highlight only — **not** an auto-bind).

**Non-Goals:**
- `.agents/mcp.json`, `.agents/tasks/`, `.agents/memories/`.
- Writing repo-local agent defs (immutable, per PR #87).
- Changing global `/api/agents` semantics.
- CLI channel (CLI resolves the union at turn time already).
- Auto-binding the repo default to `smAgent` (the user must explicitly pick;
  the dropdown only pre-selects/highlights).

## 3. Design decisions

### 3.1 `.agents/agents.md` becomes an `AgentDef` with id `agents-md`

**Decision**: `.agents/agents.md` decodes to an `AgentDef` whose **id is
`agents-md`** (stable, valid per `isValidAgentDefId`). The **system prompt
is the `agents.md` body** (frontmatter stripped). Frontmatter `name` (if
present) becomes `adName`; absent → `adName = "Project (agents.md)"` (a
friendly display name — the synthetic id never leaks to the UI).

**Collision policy**: if a repo *also* ships `.agents/agents/agents-md/` (a
subdir named `agents-md`) or a sub-agent whose frontmatter `id` is
`agents-md`, the flat `agents.md` wins per the existing flat-wins-on-conflict
rule (`readAgentDef`). The `-md` suffix merely makes accidental collision
unlikely (subdirs are bare ids); it does not guarantee impossibility — the
flat-wins rule is the real guard.

### 3.2 The repo default is `agents-md`, surfaced via the session endpoint only

**Decision**: `GET /api/sessions/:id/agents` sets `isDefault = true` per this
precedence: **user-configured `default_agent` (when it resolves to a def in
the union) > repo `agents.md` (`agents-md` in the union) > none**. If the
user's `default_agent` is configured but its id is NOT in the union, the
repo default gets `isDefault = true` (fallback). If neither exists, no
entry is marked default.

**Algorithm** (W2 DoD pins this):
1. Read `mDefId <- adDefaultAgent deps` (the raw config string).
2. `unionBackend = unionAgentDefBackend (workdirAgentDefBackend wd) (adAgentDefs deps)`.
3. `defs <- adbList unionBackend`.
4. If `mDefId` resolves (`mkAgentDefId` succeeds AND `adbRead unionBackend`
   returns `Just`) → that def's `isDefault = true`.
5. Else if `agents-md` ∈ defs → `agents-md`'s `isDefault = true`.
6. Else none.

**Precedence rationale**: the user's explicit config should win over an
implicit repo convention; but a repo that ships `agents.md` should provide a
sensible default for users who haven't configured one. The repo default is
signaled **only** on the session-scoped endpoint (the global `/api/agents` is
unaffected — it never sees workdir defs).

**Auto-bind vs pre-select**: the repo default is **pre-selected (dropdown
highlight) only**, NOT auto-bound to `smAgent`. This matches the existing
`fetchDefaultAgent()` path in App.tsx (which only calls `setSelectedAgent`,
not `setSessionAgent`) and preserves the "user explicitly picks" trust
model. The user must click to bind.

### 3.3 Backend discovery — protocol root detection + allow-list scan

**Decision**: extend `listWorkdirAgentDefs` (and *only* the workdir path —
the user store keeps pure DirScheme/flat) with a **protocol-root detection
predicate**:

**Detection rule** (`isProtocolRoot repoDir`): a convention dir `.agents/`
is treated as a protocol root **iff** it contains `.agents/agents.md` OR a
`.agents/agents/` subdirectory. Otherwise (a repo using `.agents/<id>/SOUL.md`
legacy layout, as PR #87's `RepoDiscoverySpec` fixture does) it falls back to
the legacy `listAgentDefs` (DirScheme with `SOUL.md`/`AGENTS.md` bootstrap
files). `.seal/agents` and `agents` always use the legacy `listAgentDefs`
(back-compat — they never carry the protocol).

**Protocol scan** (when `isProtocolRoot`):
1. **Allow-list**: scan only `.agents/agents/` (sub-agent dirs) +
   `.agents/agents.md` (project def). Skip everything else (`skills/`,
   `tasks/`, `memories/`, `mcp.json`, any future protocol additions) — this
   is an **allow-list**, not a skip-list.
2. **Sub-agents**: for each `.agents/agents/<id>/` subdir (where `<id>`
   passes `isValidAgentDefId`), read `<id>/agent.md`. The **id** is the
   subdir name, UNLESS frontmatter `id` is present and valid (then frontmatter
   `id` overrides; invalid frontmatter `id` → fall back to subdir name +
   emit a warning). The **system prompt** is the `agent.md` body (frontmatter
   stripped). Frontmatter `name`/`provider`/`model` honored when present.
   **`enabled`**: absent → enabled (appears); explicit `enabled: false` →
   skipped (per the protocol's default-true convention).
3. **Project def**: `.agents/agents.md` → `AgentDef` id `agents-md`
   (§3.1). Frontmatter `kind: agents` is recognized (not required — its
   absence doesn't drop the file; presence of other `kind` values like
   `kind: task` would, but `.agents/agents.md` is the canonical project
   instructions file).

**`agent.md` decoding** uses a new `decodeProtocolAgentMd :: Text -> Maybe
AgentDef` (the existing `decodeAgentDef` reads `id`/`name`/`provider`/
`model`/`tools`/timestamps but NOT `enabled`/`role`/`description`; the
protocol's frontmatter is a different shape). The new decoder reads
`id`/`name`/`description`/`provider`/`model`/`tools`/`enabled`; `role` is
ignored; `description` is ignored for now (could surface in a future tooltip).

### 3.4 The session endpoint resolves the workdir from `SessionRuntime`

**Decision**: `GET /api/sessions/:id/agents` computes
`sessionWorkdir (srPaths (adSessionRuntime deps)) sid` (the same path the
untrusted plane uses), builds `workdirAgentDefBackend wd ⊕ adAgentDefs`,
lists, and marks the default per §3.2. **No new `ApiDeps` field** —
everything needed (`adSessionRuntime`, `adAgentDefs`, `adDefaultAgent`) is
already on `ApiDeps`. The only new import in `API.hs` is
`workdirAgentDefBackend`/`unionAgentDefBackend` from
`Seal.Agent.Def.Backend`.

**404 vs empty-list**: unknown session id (fails `isValidSessionId` or no
`session.json`) → 404. Known session with empty/missing workdir → 200 + the
user-store-only list (workdir contributes `[]`). Known session with `.agents/`
→ 200 + the union. No caching (workdirs are small; `adbList` scans on every
call, same as the turn-time path).

### 3.5 Frontend — one unconditional hook, session-scoped or global

**Decision**: a new `useSessionAgents(sessionId: string | null)` hook.
Called **unconditionally** by `App.tsx` (no rules-of-hooks violation). When
`sessionId` is non-null, it fetches `GET /api/sessions/:id/agents`; when
null, it fetches `GET /api/agents` (the global list, same as `useAgents()`
today). Returns `{ agents: AgentInfo[] }`.

**`AgentInfo` is widened** to include `displayName?: string` (the backend
`agentInfoJson` already emits `displayName` at `API.hs:1616`, so no backend
change). `SessionSetup` renders `{a.displayName ?? a.name}` so `agents-md`
shows as "Project (agents.md)" (§3.1) rather than the synthetic id leaking
to the UI. The existing `useAgents()` hook also picks up `displayName`
harmlessly (it's optional).

**AbortController** on `sessionId` change prevents a stale fetch from a
previous session overwriting state after a rapid tab switch (mirrors the
existing `cancelled` flag in App.tsx's default-resolution effect).

### 3.6 SETUP_REPO completion triggers a re-fetch

**Decision**: when the `SETUP_REPO` opcode completes (in the control plane),
the handler calls `broadcastAgentDefsChanged (adBroker deps)` (the existing
WS invalidation — `StreamBroker.hs:140`). `useSessionAgents` subscribes to
`onAgentDefsChanged` (the existing `streamClient` event) and re-fetches. This
makes the session endpoint behave like the global one (which already
re-fetches on user-store agent-def mutations). No new WS event type is
needed.

This resolves the async-clone race: user creates session →
`useSessionAgents(sid)` fetches (workdir empty → user defs only) →
`SETUP_REPO` clone lands → `broadcastAgentDefsChanged` fires →
`useSessionAgents` re-fetches → repo-local defs + repo default appear.

### 3.7 App.tsx default-resolution — reads `isDefault` from the active list

**Decision**: the existing default-resolution effect in App.tsx (lines
~338-348) is updated. When a session is focused (`currentSessionId` non-null
AND `useSessionAgents` returned the session-scoped list), the effect reads
`isDefault` from that list (the entry with `isDefault === true`) and calls
`setSelectedAgent` — it does NOT call `fetchDefaultAgent()` in this branch.
When no session is focused (the global branch), the existing
`fetchDefaultAgent()` path is unchanged.

The repo default is **pre-selected (highlight) only** — `setSelectedAgent`
sets local state; it does NOT call `setSessionAgent` (no `smAgent` write).
The user must click to bind. This matches the existing global-default
behavior.

### 3.8 SafePath confinement on the protocol scan

**Decision**: every file open in the protocol scan (§3.3) goes through
`mkSafePath` against a `WorkspaceRoot` anchored at the repo's `.agents/`
dir. `mkSafePath` canonicalizes (follows symlinks) then checks containment;
a symlink escaping `.agents/` is rejected (`Left PathError`). This is the
project's existing filesystem-confinement proof type (`Seal.Security.Path`).
Applied to: `.agents/agents.md`, `.agents/agents/<id>/agent.md`. The legacy
`listAgentDefs` path (for `.seal/agents`/`agents`/non-protocol `.agents/`) is
unchanged (it reads trusted user-content, not cloned-repo content).

**Size cap**: the protocol scan reads cap at `maxBootstrapFileBytes` (1MB)
and apply `truncateSection`, mirroring `readSection` — defense-in-depth even
with SafePath.

## 4. API contract

### `GET /api/sessions/:id/agents`
- **200** → `AgentInfo[]` (the same shape as `GET /api/agents`: `name`,
  `isDefault`, plus the full `AgentDefInfo` fields — the frontend hook
  narrows to `AgentInfo`). The union (workdir ⊕ user), workdir-wins on id
  collision. `isDefault` per §3.2.
- **404** → unknown session id.

No new write endpoints. Agent binding continues via the existing
`PUT /api/sessions/:id/agent`, which validates the id **syntactically** via
`mkAgentDefId` (`parseAgentBinding`, `API.hs:790`) — not by existence in the
global store. So binding a repo-local id (e.g. `agents-md` or a sub-agent
id) persists successfully, and the turn-time `unionAgentDefBackend` resolves
it. **No change to `PUT .../agent` is needed.** (If the bound id later
becomes unresolvable — e.g. branch switch removes the repo — the turn-time
path falls back to no-agent, which is the existing behavior for any
unresolvable bound agent.)

## 5. Security considerations

| Concern | Mitigation |
|---|---|
| Path traversal / symlink escape via repo `.agents/` | `mkSafePath` against a `WorkspaceRoot` anchored at `.agents/` on every protocol-scan file open (§3.8). Rejects symlinks escaping the protocol root. The id charset (`[A-Za-z0-9_-]+`, no leading dot) is validated by `mkAgentDefId` separately. |
| Unbounded read / OOM | `maxBootstrapFileBytes` (1MB) cap + `truncateSection` on every protocol-scan read, mirroring `readSection`. |
| Disabled agents in dropdown | Absent `enabled` → enabled (appears); explicit `enabled: false` → skipped (per the protocol's default-true). |
| Repo default auto-binding | No auto-bind. The repo default is pre-selected (highlight) only; the user must explicitly click to bind. Preserves the "user explicitly picks the agent" trust model. |
| Repo default overriding user config | User `default_agent` wins (§3.2). The repo default is a convenience for unconfigured users, never an override. |
| Workdir-wins id shadowing | A repo can shadow a user agent id in the dropdown. Mitigation: a future `source` field (`"user"`/`"workdir"`) on `AgentInfo` so the dropdown can badge repo-local entries (v1.1 — not blocking; the explicit-pick trust model holds without it). |
| Untrusted content in system prompts | Repo `agent.md` bodies become system prompts sent to the LLM — but the user **explicitly cloned** the repo and **explicitly picks** the agent (no auto-bind). Same trust model as the existing DirScheme discovery (PR #87) and the one-off file upload. No new trust boundary. |
| No secrets in agent defs | `agent.md` frontmatter fields are limited to `id`/`name`/`description`/`provider`/`model`/`tools`/`role`/`enabled`. No vault keys, no env. Frontmatter field sizes bounded (truncate at 4KB per field, defense-in-depth). |
| `provider` routing to attacker endpoint | `adProvider` selects the provider. Validating `provider` against `Seal.Providers.Registry`'s known set (rejecting unknown values) is cheap defense-in-depth — noted as a v1.1 candidate; the explicit-pick trust model covers it for v1. |
| Listing-path exfil | `adbList` (called by the endpoint) JSON-encodes def bodies over HTTP to the browser. With SafePath (§3.8) the body can't be a symlinked secret, so listing is safe. |

## 6. TDD work units

### W1 — `.agents Protocol` discovery (backend)
**DoD:**
- `listWorkdirAgentDefs` recognizes `.agents/` as a protocol root per the
  detection rule (§3.3): `isProtocolRoot` = contains `.agents/agents.md` OR
  `.agents/agents/` subdir.
- Protocol scan (allow-list): `.agents/agents/<id>/agent.md` (id from subdir
  or frontmatter `id`; system = body after frontmatter; honor
  `enabled`/`name`/`provider`/`model`) + `.agents/agents.md` (id `agents-md`;
  `adName` fallback `"Project (agents.md)"`). Skip everything else.
- Every protocol-scan file open via `mkSafePath` (§3.8); reads capped at
  `maxBootstrapFileBytes` + `truncateSection`.
- New `decodeProtocolAgentMd :: Text -> Maybe AgentDef` (reads
  `id`/`name`/`provider`/`model`/`tools`/`enabled`; `enabled` absent →
  enabled; `enabled: false` → `Nothing`).
- `.seal/agents` + `agents` + non-protocol `.agents/` keep legacy
  `listAgentDefs`.
- No bogus `agents`/`skills` empty-prompt entries for a conformant repo.
- **QuickCheck property**: `deriveAgentsMdId` (the pure id-derivation for the
  project def) always produces a value that passes `isValidAgentDefId` AND
  ends in the literal suffix `"-md"` (the suffix-shape invariant — the actual
  invariant the `-md` suffix buys; collision-freedom is NOT claimed, flat-wins
  is the real guard per §3.1). Bounded generator over `isValidAgentDefId`
  strings (max length ~16, charset `[A-Za-z0-9_-]`).
- **Wiring**: `seal-harness.cabal` (if `RepoDiscoverySpec` is new — it's
  already on PR #87, verify it's wired) + `test/Main.hs` (import +
  `RepoDiscoverySpec.spec` — verify it's wired on the base branch).
**RED**: `RepoDiscoverySpec` — a fixture repo with `.agents/agents.md` +
  `.agents/agents/foo-agent/agent.md` (frontmatter + body) +
  `.agents/skills/x/SKILL.md` yields exactly 2 defs (`agents-md`,
  `foo-agent`) with correct systems; `enabled: false` sub-agent is skipped;
  frontmatter `id` overrides subdir name; a symlinked `agent.md` escaping
  `.agents/` is rejected (SafePath); a legacy `.agents/<id>/SOUL.md` repo
  (no `agents.md`/`agents/` subdir) still resolves via DirScheme.
**File scope**: `src/Seal/Agent/Def/Backend.hs`, `test/Seal/RepoDiscoverySpec.hs`,
  `seal-harness.cabal` (verify wiring), `test/Main.hs` (verify wiring).

### W2 — Session-scoped endpoint (backend)
**DoD:**
- `GET /api/sessions/:id/agents` → 200 + unioned `AgentInfo[]` (workdir ⊕
  `adAgentDefs`, workdir-wins); `isDefault` per §3.2 algorithm; 404 unknown
  session; 200 + user-only for a known session with empty workdir.
- No new `ApiDeps` field (uses `adSessionRuntime`/`adAgentDefs`/`adDefaultAgent`).
- `SETUP_REPO` opcode handler calls `broadcastAgentDefsChanged` on completion
  (§3.6) so the frontend re-fetches.
- Reuses `agentInfoJson` shape.
**RED**: `ApiSpec` — three §3.2 precedence cases pinned: (a) user
  `default_agent` set + repo `agents.md` present → user def `isDefault=true`,
  `agents-md` `false`; (b) no user default + repo `agents.md` → `agents-md`
  `isDefault=true`; (c) neither → no `isDefault=true`. Plus: workdir-wins on
  collision; known session with empty workdir → 200 + user-only; unknown
  session → 404.
**File scope**: `src/Seal/Gateway/API.hs`, `src/Seal/Gateway/Send.hs` (the
  `SETUP_REPO` broadcast site — verify the handler location),
  `test/Seal/Gateway/ApiSpec.hs`.

### W3 — Frontend dropdown wiring
**DoD:**
- `useSessionAgents(sessionId: string | null)` hook (one unconditional call;
  fetches `/api/sessions/:id/agents` when non-null, `/api/agents` when null;
  `AbortController` on `sessionId` change; re-fetches on
  `onAgentDefsChanged`).
- `AgentInfo` widened to include `displayName?: string` (the backend
  `agentInfoJson` already emits `displayName`); `SessionSetup` renders
  `{a.displayName ?? a.name}` so `agents-md` shows as "Project (agents.md)".
- `App.tsx` calls `useSessionAgents(currentSessionId)` unconditionally;
  default-resolution effect reads `isDefault` from the active list (drops
  `fetchDefaultAgent()` in the session-scoped branch; global branch
  unchanged). Pre-selects (highlight) — no auto-bind.
**RED**: `useApi.test.ts` — `fetchSessionAgents` GETs
  `/api/sessions/:id/agents`; `useSessionAgents` fetches session-scoped when
  id non-null, global when null; re-fetches on `onAgentDefsChanged`.
  `ChatArea.test.tsx` — the dropdown renders repo-local agent names +
  pre-selects the repo default (case b: no user default + repo `agents.md`).
  `App`-level test — the default-resolution effect reads `isDefault` from
  the session-scoped list (not `fetchDefaultAgent()`) when a session is
  focused.
**File scope**: `frontend/src/hooks/useApi.ts`, `frontend/src/types.ts`,
  `frontend/src/App.tsx`, `frontend/src/components/ChatArea.tsx`,
  `frontend/src/hooks/__tests__/useApi.test.ts`,
  `frontend/src/components/__tests__/ChatArea.test.tsx`.

### W4 — Gate
`make check` + `npm run build` + `npm test` + `tsc --noEmit` green.

## 7. Human checkpoints
1. After this design doc (review-gate round 2) — confirm §3.1 (`agents-md`
   id + friendly display name), §3.2 (repo-default precedence), §3.6
   (SETUP_REPO broadcast), §3.8 (SafePath) before implementation.
2. After W2 (backend endpoint) — review the endpoint shape + the SETUP_REPO
   broadcast site before W3.

## 8. Alternatives considered

- **Make `.agents/agents.md` the default via `default_agent` config**: would
  require writing to `config.toml` on repo clone, polluting global user
  config with a per-repo value. Rejected — the repo default is a property of
  the session's workdir, not the user's global config.
- **A single `agent.md` bootstrap file added to `SectionKind`**: would
  conflate the protocol's `agent.md` (a complete profile) with the DirScheme
  bootstrap composition. Rejected — `agent.md` is the *whole* def in the
  protocol, not one section of a composed prompt.
- **Frontend merges `/api/agents` + a new repo-only endpoint**: two round
  trips + client-side merge. Rejected — the union is already a backend
  concept (`unionAgentDefBackend`); one endpoint returning the union is
  simpler and matches the turn-time semantics.
- **Auto-bind the repo default to `smAgent` on session focus**: rejected —
  breaks the "user explicitly picks the agent" trust model (§5). Pre-select
  (highlight) only.
- **Re-fetch on `setupRepo()` resolution in the composer**: rejected in
  favor of the backend `broadcastAgentDefsChanged` on `SETUP_REPO` completion
  (§3.6) — consistent with the existing invalidation architecture and works
  regardless of which entry point (composer, CLI, WS) triggered the clone.