# Handoff repo inheritance — learnings (2026-11-03)

Short retro for the `AGENT_MANAGE action=handoff` repo-carries-over change
(`handoff/repo-setting`). Written by the implementing agent, for whoever
picks up the next delegation work.

## What the bug actually was

Two independent gaps, not one:

1. `writeHandoffMeta` hardcoded `smRepoUrl = Nothing` — the *setting* was
   lost (that is what the tab/sidebar renders, `session.json`'s `repo_url`).
2. `handleHandoff` built the task with `ctIsolateWorkdir = False`, so a
   "top-level peer" session silently shared the caller's workdir. Two peers
   with one workdir is not a shape the rest of the system expects: the
   worker's `UIOEnv` was parent-keyed while the child's *registry* was
   child-keyed (`buildChildRegistryAdapter` resolves `cachedSessionExec`
   for the child sid), i.e. the two halves of the same session disagreed
   about where files live.

The operator's framing — "create a new session with a fresh workdir and
clone the repo using SETUP_REPO" — is also the invariant: a top-level
session owns its workdir.

## Where the seam belongs

- The clone must be **audited**: dispatch `SETUP_REPO`, do not call
  `cloneRepoIO` directly. `Gateway/Send.hs:handleSetupRepo` already says why
  in a comment ("unaudited — a side channel that never appears in the
  transcript").
- Dispatching through the session's own (def-narrowed) registry is a trap:
  `applyDefAllowList` intersects a def's `tools` list, so a def without
  `SETUP_REPO` silently skips the checkout. A dedicated one-op registry
  (`handoffRepoRegistry`) bypasses the allow-list and *nothing else* —
  `SETUP_REPO` is not on `delegationBlocklist`.
- Ordering matters and is testable: the worker writes meta → dispatches the
  clone → runs the turn. Assert it from the transcript (SETUP_REPO harness
  entry index < first `EKRequest` index) rather than trusting the code
  shape.
- `UIOEnv`'s `CloneDeps` field is deceptively accessible (`UIOEnv (..)` is
  exported by the internal module) — use `runUIOWithEnv env uioCdCloneDeps`
  instead, so the opaque type stays opaque.

## Session metadata: a lesson in copy-paste

Three modules each carried their own "guarded read + `decodeFileStrict`"
for `session.json` because `Seal.Core.TurnEngine` sits above the opcodes
and importing it from them is a cycle. The leaf home was obvious once
looked for: `Seal.Session.Meta` (the record's own module). Two more inline
copies remain (`ISA/Ops/Session.hs`, `Command/Tab.hs`) as follow-up.

Watch the guard: `decodeFileStrict` reads via `sourceFile`, which *throws*
on a missing path — the `doesFileExist` check is load-bearing, not
defensive noise. A "shared reader" that drops it turns every "no
session.json" path into an exception.

## What a handoff session should carry (beyond the repo)

`writeHandoffMeta` also left `smAgent`/`smAgentName` at `Nothing`, so
resuming a handoff session lost its agent. Stamp the def the session runs.
Recorded as a drive-by in the PR body rather than smuggled in silently.

Deliberately **not** replicated from `callDispatcher`'s SETUP_REPO
convergence: scan invalidation (no scan exists yet), `autoBindRepoAgentWith`
(the handoff def is explicit), the preamble entry (the first turn writes a
real request), the agent-defs broadcast (no subscriber). Each is listed in
the plan doc, WU6, so the next reader does not "fix" them by accident.

## Process note

The plan-review gate earned its cost here: the first two rounds caught a
real import-cycle blocker (`loadSessionMeta` unreachable from the opcode),
an unused-`WorkspaceRoot`-argument hazard, four missing `-Werror` import
deletions, and the "fake SETUP_REPO op is not injectable" problem. Cheap
prose fixes; expensive compile cycles avoided.

Flaky-under-load: `Registry.agentStatus > records Crashed` and
`Phase7aSpec > WS client connects` both failed once in a ~97s full run and
passed in isolation and on re-run. Timing-sensitive; unrelated to this
change, but worth knowing before blaming a diff.

## Follow-up: repo *and* branch

`SETUP_REPO` grew an optional `branch` (#301) after this change landed, and
the handoff had to inherit it. The lesson: **a clone argument that is not
persisted cannot be inherited.** `session.json` recorded `repo_url` but not
the branch, so "same repo and branch as the creating session" needed a new
field (`smRepoBranch`) and a writer in the SETUP_REPO convergence — the
handoff then just replays `{url, branch}` through the same opcode.

Two details worth remembering: record the *request* (a branch, or nothing for
the remote default), not a resolved ref — resolving it would mean querying
git in the trusted plane; and parse the persisted values with the opcode's own
`parseSetupRepoInput`, so what is written down is exactly what was cloned.
