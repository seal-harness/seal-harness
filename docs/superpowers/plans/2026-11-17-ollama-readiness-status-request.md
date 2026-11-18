# Request — Ollama provider readiness status

<!-- This file is the authoritative statement of the work for the plan review gate. -->

## User's request, verbatim

> Start work on the design doc that was just committed to this branch.

The branch is `providers/ollama-readiness-status`. The "design doc that was
just committed" is the single commit on that branch:

```
6f535a9 docs: design for Ollama provider readiness status
```

which adds exactly one relevant file:

```
docs/superpowers/specs/2026-11-17-ollama-readiness-status-design.md
```

## What the design doc is

An **approved** design (`Status: approved (design review gate — 5/5 reviewers,
7 rounds)`). It is the fixed statement of what to build. The task is therefore
to **implement the approved design**, not to re-litigate it.

## The underlying bug (issue #334)

A keyless local Ollama is reported as Configured/Keyless purely by config
inspection. `configuredProviders` (`src/Seal/Providers/Registry.hs:357`) returns
`True` whenever `ollamaNeedsKey baseUrl` is false, and `ollamaNeedsKey`
(`src/Seal/Providers/Ollama.hs:97`) is only a substring test for `ollama.com`.
The machine is never consulted. So on any machine — daemon absent, uninstalled,
or holding no models — `configured` is `True`, and that value feeds four
user-visible surfaces (three dropdowns, the Providers CRUD badge, the first-run
setup wizard card, and the TUI `/provider list`).

The consequential surface is the blocking setup gate: the operator finishes a
green wizard, then their first message fails with
`could not reach Ollama at http://localhost:11434`.

## Acceptance criteria

The canonical acceptance list is issue #334's **Definition of Done** (read it
with `gh issue view 334`) together with the approved design's 'Test plan (RED
first)' (tests 1–44, including 14b, 14c, 33b), 'Work units' (WU-A, WU-B), and
'Files touched' sections.

Reproduced here for convenience — every item must be satisfied:

- `configured` semantics unchanged; the blocking setup gate does not flap on
  daemon restart
- `readiness` emitted for Ollama on `/api/providers`, `/api/providers/all`
  (+ POST/PUT mutation responses) and `/api/setup`
- All four surfaces render it: three option lists, Providers list + editor pill,
  setup wizard card, TUI `/provider list`
- Probe is keyless (never attaches the vault key) and uses `adHttpManager`, not
  `gatewayManager`
- SSRF floor rejects `169.254.169.254`, `http://x@169.254.169.254/`, and
  `[fd00:ec2::254]`
- `RdUnknown` split from `RdPending` so a cold start never shows
  `Status Unknown`
- WU-A (probe states, all four surfaces) alone closes the report; WU-B adds the
  advisory RAM judgement
- `make check` green

## Hard constraints from AGENTS.md that the plan must respect

- TDD: failing test first, then minimal implementation.
- No `--no-verify`, no force-push.
- No opcode or agent-driven code path may read or write `~/.seal/`.
- No shell-wrapping (`sh -c`, constructed command strings) in Trusted/Audited
  opcodes.
- `Text` not `String`; no partial functions; `-Wall -Werror` clean;
  `hlint src/ test/` must report "No hints".

## The plan under review

`docs/superpowers/plans/2026-11-17-ollama-readiness-status-plan.md`

## Out of scope (declared, so scope creep can be judged)

Follow-ups the design files but this work must NOT do:

1. Readiness for custom OpenAI-compatible localhost instances.
2. Fixing `ollamaNeedsKey`'s substring check (a credential-exfiltration
   primitive). This PR routes *around* it; it does not close it.
3. A DNS-resolving companion to the `UrlSafety` floor (rebinding). Only the
   bracket-aware / userinfo half ships here.
4. Trimming `baseUrl` from `providerDetailJsonFor`.

Also out of scope: any change to `configuredProviders` /
`src/Seal/Providers/Registry.hs`, provider resolution, request encoding, or
`ollamaResponseTimeoutMicro`.
