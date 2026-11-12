# Learnings: Session Preamble Rendering (System Prompt / Tools rows)

**Captured**: 2026-10-22 (post-implementation self-reflect)
**Issue**: #277 — `fix(web): render the session preamble once, at the top of the transcript`
**Branch**: `frontend/system-prompt-preamble-277`

Durable facts about the transcript format + the web transcript view. Future
agents/contributors should not have to rediscover them.

---

## 1. The transcript payload is a DELTA view, not a verbatim record of every request

`Seal.Transcript.Reconstruct` reconstructs each request entry's payload from
the folded envelope. `system` and `tools` are **omitted** unless they CHANGED
from the prior request (`sys = if envSystem env /= (envSystem =<< mEnv) ...`).

Consequences:

- The "View raw JSON (message)" modal shows a *delta* payload, not the exact
  bytes the provider received. Later turns have no `system`/`tools` key at all.
- The same holds for `messages`: a request entry carries only the conversation
  lines added since the prior turn, not the cumulative history.
- **Do not "fix" the backend by dropping the mid-session `system` from the
  payload** (e.g. "ship the preamble only at the session's first request").
  The `<available_agents>` integration test
  (`test/Seal/Gateway/AgentIntegrationSpec.hs`, "W3 catalog") observes the
  *mid-session* system prompt **through the transcript** — it would lose its
  only observation channel. The fix belongs in the rendering layer.

## 2. The system prompt changes mid-session — mostly spuriously

The resolved system prompt embeds the `<available_agents>` catalog, whose
truncation marker is `[...catalog truncated at 4096 chars; N more chars
elided...]`. `N` moves whenever the catalog's total size changes, so the
prompt text changes even when the *visible* catalog is byte-identical.

Measured on real sessions: 4–13 system-prompt changes per session (e.g.
`20261021-201159-490`: 613 entries, changes at entries 27 and 310). Every
change ships the full ~40KB prompt again in the transcript payload.

**Location**: `src/Seal/Agent/PromptParts.hs` (`truncateBlock`).

## 3. The preamble rows must be anchored POSITIONALLY, not content-deduped

The old frontend kept a `seenSystem` / `seenTools` set of *contents* and
rendered a row for every distinct value. A mid-session change therefore
rendered a second `System Prompt` group half-way down the session — at the
bottom of a long session, exactly where the user had just typed.

The preamble is the session's **configuration**, not a per-turn message: it
is now rendered by the first LLM request in the view and by no other entry
(`findPreambleId` in `frontend/src/components/ChatArea.tsx`, shared with the
`useTranscriptMessages` hook). Positional anchoring also removes the need for
the dedup state and the dedup-rebuild machinery.

**Location**: `frontend/src/hooks/useTranscriptMessages.ts`,
`frontend/src/components/ChatArea.tsx`.

## 4. In the reconstructed view, the first request-direction entry is often an OPCODE entry

`reconstruct` maps `EKHarness` entries to `Request` direction, and the
backend drops them from the frontend view **except** the user-surfacing ones
(`SETUP_REPO`, `/skill load`, approvals). So the first request-direction
entry in the view is frequently a `SETUP_REPO` entry, not an LLM request.

Discriminate by the payload shape: an LLM request payload never carries the
`op` / `harness` keys; an opcode entry always does.

**Location**: `src/Seal/Transcript/Reconstruct.hs` (`harnessPayload`),
`src/Seal/Gateway/Transcript.hs` (`reconEntryToFrontend`).

## 5. Entry ids are the GLOBAL entry indices — and harness entries consume one

`reconEntryToFrontend` falls back to the entry's index in the entries list
when the stored id is empty, so the frontend's ids are the global positions
in `entries.jsonl`. Dropped harness entries leave gaps in the id sequence.
Do not treat the ids as contiguous, and do not use "the lowest id" to
identify the session's first request.

## 6. Where to look when debugging a transcript bug

- Ground truth on disk: `~/.seal/state/sessions/<sid>/entries.jsonl`
  (one line per event, envelope-delta per request) + `conversation.jsonl`
  (the message lines the entry deltas point into).
- What the frontend actually sees:
  `GET /api/sessions/<sid>/transcript` on the local gateway (port 9090) —
  the same reconstructed + rewritten payload the browser gets. The
  `?limit=N` parameter is what the web frontend uses (the last N entries).
- Counting the system-prompt changes in a session: count the `entries.jsonl`
  request records whose `envelope` has a `system` key, then diff the values
  pairwise (a `difflib` diff of the two prompts shows the churn immediately).
