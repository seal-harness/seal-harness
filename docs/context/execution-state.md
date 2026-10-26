# Execution State
<!-- updated: 2026-10-26 -->

Plan: `docs/plans/active-plan.md` (rev 9 of `docs/superpowers/plans/2026-10-26-chat-slash-command-parity-plan.md`)

## Current Position
- Active work unit: none (checkpoint after WU-6)
- Current phase: —
- Retry count: 0

## Work Unit Status
| WU | Title | Status | Commit | Notes |
|----|-------|--------|--------|-------|
| WU-1 | Shared NewArgs + renderNewSessionConfirmation in seal-gateway-types | DONE | `0a193e2` | NewSpec unchanged, +2 pins |
| WU-2 | /tab new mints a real session (registry + CLI) | DONE | `ec2516d` | no `tab-session` remains |
| WU-3 | /tab list renders client-side in D5 format | DONE | `047464a` | new TabRender module |
| WU-4 | /tab resume golden reply + registry coverage | DONE | `d9396cd` | |
| WU-5a | REST: /api/tabs/:idx/rename + tab resume | DONE | `cc0eef0` | D1 reinstated by operator |
| WU-5 | Stale WS filter (recreate conn on sid change) | PENDING | — | RISKY: core delivery path |
| WU-6 | Gateway: sessions/:id/new body+rebind_error, GET /api/commands | DONE | `da4f358` | route count 61 → 62 |
| WU-7 | Chat /new: args, rebind XOR mint, -r, golden line | PENDING | — | needs WU-5 + WU-6 |
| WU-8 | Telegram command menu + registerWithRetry | PENDING | — | |
| WU-9 | Docs + full gate | PENDING | — | |

## Gate status at this checkpoint
- `cabal build all` clean
- `cabal test`: **3253 examples, 0 failures, 42 pending** (3212 at WU-1 start)
- `hlint src/ src-gateway-types/ test/` and `hlint src-chat-channels/`: No hints

## Decisions taken in WU-6 (worth keeping)
- `tab_index` in the `/api/sessions/:id/new` response is `null` when no tab
  was bound, otherwise the index of the tab the rebind targeted (on failure
  it stays bound to the old session). `rebind_error` is `null` (not absent)
  when the rebind succeeded — the key is always present, so a consumer can
  read it unconditionally.
- An unparseable/absent body is treated as `{}` (matching
  `/api/sessions/new`), not a 400.
- The config default agent's provider/model overrides are deliberately NOT
  applied on the rebind path: provider/model come from the old session or the
  explicit overrides, only the agent id comes from config defaults.

## Ordering note for resuming
Resume order is WU-7 → WU-5 → WU-8 → WU-9: WU-5 (the stale WS filter) has no
user-visible effect until WU-7 makes `/new` rebind a conversation, so doing it
after WU-7 lets it be validated against a real rebind.

## Blocked / Escalated
None.
