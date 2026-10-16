# Handoff: Context Window Overflow — Session `20261003-052042-936` Post-Mortem

**Date**: 2026-10-03 · **Session**: `20261003-052042-936` (`ollama/glm-5.2:cloud`) · **Severity**: session-killing (unrecoverable without new session) · **Status**: root cause identified, fix not yet implemented

## 1. Objective

Diagnose why session `20261003-052042-936` produces a persistent HTTP 400 error on every turn:

```
provider error: Ollama API returned HTTP 400:
{"error":"The prompt is too long: 2066518, model maximum context length:
1048576 (ref: 5e93a95e-19cd-4771-822f-558c01993975)"}
```

The prompt is ~2M characters; the model (`glm-5.2:cloud` via Ollama Cloud)
accepts at most ~1M. The error is permanent — every subsequent turn sends
the same oversized prompt.

## 2. Root Cause

**The harness has no context window management.** The agent loop sends the
entire conversation history as the prompt every turn, with no truncation,
no sliding window, no token counting, and no context-limit enforcement.

### The code path

`src/Seal/Agent/Loop.hs`, `runTurn` / `go`:

```haskell
prior <- liftIO (tfwReadConversation (aeTranscript env))  -- full history from disk
let userMsg = textMsg User userText
    turn0   = prior <> [userMsg]                           -- grows every turn
...
go (aeMaxTurns env) 0 turn0
  where
    go n lenContinue msgs = do
      let req = CompletionRequest
                  { crModel = aeModel env
                  , crSystem = aeSystem env
                  , crMessages = msgs      -- ← ENTIRE conversation, no limit
                  , crTools = ...
                  , crMaxTokens = defaultMaxTokens
                  }
      -- ... send to provider, process tool calls, append results to msgs ...
      go (n - 1) (lenContinue + 1) (msgs <> toolResults <> assistantMsg)
```

`crMessages = msgs` is the full, untruncated conversation. Each tool-call
iteration appends more messages and re-sends the entire list. There is no
mechanism anywhere in this path to drop old messages when the total
approaches the model's context limit.

### ContextWindow.hs is not used for truncation

`src/Seal/Providers/ContextWindow.hs` is a static lookup table for model
context windows:

```haskell
modelContextWindow :: Text -> Int
modelContextWindow m
  | "claude-sonnet-" `isPrefixOf` m = 200000
  | "claude-opus-"   `isPrefixOf` m = 200000
  | ...
  | otherwise                          = 0   -- ← unknown models return 0
```

It is imported only by `Seal.Gateway.API` for the
`GET /api/providers/:p/models/:m/context` endpoint (displaying context
window info to the frontend). **The agent loop never consults it.** And
even if it did, `glm-5.2` is not in the table — it would return `0`,
meaning "unknown," so no limit would be enforced.

## 3. What Filled the 2M Characters

The session was performing a **design review** for a "GitHub PR Status
Indicator" feature. Over 908 messages, it accumulated:

### 3.1 Large file reads (the bulk)

The agent and its 5 subagent reviewers each read full source files to
verify the design's claims against the codebase:

| File | Lines | Approx chars |
|------|-------|-------------|
| `ActiveTabs.tsx` | 558 | ~25K |
| `Sidebar.tsx` | 412 | ~18K |
| `types.ts` | 520+ | ~25K |
| `TurnEngine.hs` (callDispatcher) | 1333 | ~60K |
| `Store.hs` | 479 | ~22K |
| `SecurityConfig.hs` | 236 | ~12K |
| `Meta.hs` | 83 | ~4K |
| `SessionJson.hs` | 105 | ~5K |
| `RunningHarnesses.tsx` | 108 | ~5K |
| Design doc (`pr-status-indicator-design.md`) | 377 | ~15K |

Each file was read by the parent session AND independently by each
subagent. The subagent transcripts are separate sessions (not inlined
into the parent), but the parent did its own equivalent work.

### 3.2 Massive SEARCH_FILES results

Searches like `smRepoUrl`, `Spec.hs`, `sessionInfoJson`, or `updateSessionRepoUrl`
returned hundreds of matches across dozens of files. Each result block
was 20K–50K+ characters. Multiple such searches were performed.

### 3.3 Enormous thinking blocks

The design review analysis generated thinking blocks of thousands of
words each. The 5 subagent reviews (inlined back into the parent as
tool-result messages) each contained a full JSON verdict with detailed
blockers/suggestions/questions — easily 10K+ chars per review.

### 3.4 Truncation death spiral (messages #896–#905)

The end of the session shows a feedback loop that made the problem worse:

```
#896  [System: Your previous response was truncated by the output length
       limit. Continue exactly where you left off...]
#897  [Assistant: (attempts to continue — generates more content)]
#898  [System: Your previous response was truncated...]
#899  [Assistant: (empty)]
#900  [System: Your previous response was truncated...]
#901  [Assistant: (empty)]
#902  [User: continue]
#903  [Assistant: provider error: prompt too long: 2066438]
#904  [User: Try again. See if you can figure out how we got a too-long prompt.]
#905  [Assistant: provider error: prompt too long: 2066518]
```

Each "Continue" system prompt and each attempted continuation added to
the transcript, increasing the prompt size for the next attempt. The two
error attempts (#903, #905) differ by 80 chars — the transcript grew
between them because the error messages themselves were appended.

### 3.5 The math

908 messages × ~2,300 chars/message average = ~2.1M chars. This session's
messages were far larger than average (file reads, search results,
thinking blocks), so it hit the limit well before 908 messages. The
prompt crossed 1M characters somewhere mid-session; every subsequent
turn just made it worse.

## 4. Why It's Not "Individual Lines Too Long"

The Ollama error reports the **total prompt size** (2,066,518 chars), not
any individual message. While individual messages were large (file reads
of 25K+ chars, search results of 50K+ chars, thinking blocks of 10K+
chars), the problem is cumulative: ALL 908 messages are sent together as
one prompt. Even if every message were only 2K chars, 908 messages would
still be ~1.8M — over the limit.

The issue is the absence of **any** context window management, not the
size of any single message.

## 5. The Subagent Angle

The session spawned 5 subagent children for the design review gate:

```
[child of 20261003-052042-936] 20261003-053954-222-f64c
[child of 20261003-052042-936] 20261003-053954-222-fa9d
[child of 20261003-052042-936] 20261003-053954-222-b25a
[child of 20261003-052042-936] 20261003-053954-222-b632
[child of 20261003-052042-936] 20261003-053954-222-e95e
```

Each subagent independently read the same large source files and design
doc, produced enormous thinking blocks, and returned detailed review
verdicts. The subagent transcripts are **separate sessions** — their
full content is NOT inlined into the parent. The parent only receives a
child-session reference + the final result (the review verdict).

However, the parent session **also did its own file reads and analysis**
(in parallel with the subagents), so the parent's transcript accumulated
equivalent content independently. The 5 review verdicts inlined back
into the parent were each ~10K chars, adding ~50K total — a contributor,
but not the dominant factor.

## 6. Fix

### 6.1 Context window management in the agent loop

**File**: `src/Seal/Agent/Loop.hs` — the `go` function.

Before building the `CompletionRequest`, the loop should:

1. **Look up the model's context window** — extend
   `Seal.Providers.ContextWindow` to include `glm-5.2` and other Ollama
   Cloud models, or query the Ollama API (`/api/show`) for the model's
   `num_context` parameter.

2. **Estimate the token count** of the accumulated messages (system +
   tools + messages). A rough character-based estimate (chars / 4) is
   sufficient for a first cut; a proper tokenizer is better but not
   required for MVP.

3. **Truncate oldest messages** when the estimated total approaches the
   limit. Strategy:
   - Always keep the system prompt and tool definitions.
   - Always keep the most recent N messages (the "active context").
   - Drop oldest messages from the middle (tool results, old file reads,
     old thinking blocks) first — these are the largest and least
     relevant to the current turn.
   - Insert a synthetic "system" message noting that older context was
     truncated, so the model knows history is missing.

4. **Guard against the truncation death spiral**: when a turn fails with
   a "prompt too long" error, do NOT append the error and retry — the
   retry will be even longer. Instead, truncate aggressively (e.g., keep
   only the last 5 messages) and retry once.

### 6.2 Extend ContextWindow.hs

```haskell
modelContextWindow :: Text -> Int
modelContextWindow m
  | ...existing entries...
  | "glm-5"     `isPrefixOf` m = 1048576   -- glm-5.2:cloud, 1M context
  | otherwise                     = 0
```

Also consider adding an Ollama-specific path that queries `/api/show` for
the model's actual `num_context` at session startup, caching the result.

### 6.3 Prevent the truncation death spiral

In `Loop.hs`, the `StopMaxTokens` branch (which generates the "Your
previous response was truncated" system prompt) should check whether the
conversation is already near the context limit before appending more
messages. If it is, the loop should stop with a clear error rather than
looping.

The "continue" prompt injection (messages #896–#901 in the transcript)
repeatedly added content to an already-oversized transcript. A
pre-flight check — "is this prompt going to exceed the context window?" —
before sending would catch this.

### 6.4 Subagent result size

When 5 subagents each return a 10K+ char review verdict, the parent
accumulates 50K+ chars of tool results in one turn. Consider summarizing
or truncating subagent results before inlining them into the parent
transcript, especially when multiple subagents run in parallel.

## 7. Definition of Done

1. `ContextWindow.hs` has an entry for `glm-5.2` (and other Ollama Cloud
   models) returning the correct context window.
2. `Loop.hs` truncates the message list before building the
   `CompletionRequest` when the estimated token count exceeds the
   model's context window.
3. The truncation strategy preserves system prompt + tools + recent
   context, drops oldest/largest messages first.
4. The "prompt too long" error from the provider triggers a
   truncation-and-retry (once), not an append-and-retry loop.
5. A session that would have hit the 2M-char prompt error now continues
   working (with potentially degraded context quality, but no crash).
6. `make check` passes.

## 8. Related

- `ContextWindow.hs` — the static lookup table (needs extending)
- `Loop.hs` `runTurn` / `go` — the agent loop (needs truncation)
- `Ollama.hs` `encodeRequest` — the provider request builder (no
  truncation here; it faithfully encodes whatever it's given)
- The `StopMaxTokens` handling in `Loop.hs` — the truncation-prompt
  injection that caused the death spiral
- The subagent result inlining path — large parallel results can
  accelerate context overflow

## 9. Session Disposition

Session `20261003-052042-936` is **unrecoverable** — its transcript is
permanently oversized. The only resolution is to start a new session. The
design review work (the PR Status Indicator design doc and the 5 reviewer
verdicts) is preserved on disk in:
- `docs/superpowers/specs/2026-10-03-pr-status-indicator-design.md`
- The 5 child session transcripts under `~/.seal/cache/sessions/20261003-052042-936/agents/`