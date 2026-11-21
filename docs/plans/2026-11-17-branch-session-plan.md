# Branch session from transcript — implementation plan

<!-- branch: fix/web-branch-session (final name when the issue number exists) -->
<!-- base: main -->
<!-- status: draft — design review complete, awaiting implementation -->

## Traps this plan already resolves

Each of these was found the hard way; they are stated up front because a
plausible implementation that misses any one of them ships a
working-looking fix for the wrong thing.

1. **The branch anchor is a render index, not a session id.**
   `App.handleBranch` (`App.tsx:852`) stores only the row's `entryId`,
   every writer sets `erId = ""` so `reconEntryToFrontend`
   (`Gateway/Transcript.hs:734`) substitutes `show idx`, and the two
   render paths use different coordinate systems
   (`convLineToFrontend` uses the conversation-line index, reconstruction
   uses the entry index). `branch_from` must therefore carry the **parent
   session id**, and the anchor must be an explicit conversation length.
2. **Digits are valid session ids.** `isValidSessionId` accepts
   `A-Za-z0-9_-` (`Core.hs:57-63`), so a render index like `"12"` passes
   `mkSessionId` and then 404s. A `branch_from`-only or index-shaped
   request must fail **loudly** — see WU-4's three cases.
3. **`transcriptToMessages` is test-only.** The app renders via
   `useTranscriptMessages` (`App.tsx:624`). Touching only `ChatArea.tsx`
   leaves `convLen` undefined in production, silently reproducing the
   reported bug.
4. **`NewTabComposer` auto-clones.** It dispatches `SETUP_REPO` with no
   dirty-check whenever `spec.repo` is non-empty (`:78-80`), and
   `useNewTabSpec` restores a last-used repo (`:177`). Prefilling the
   repo without guarding that path would clone into the branch's workdir
   — see WU-5's default-OFF toggle.
5. **`teConvLen` must be tolerant on decode.** `TranscriptEntry` is
   actually parsed from JSON at `Gateway/Transcript.hs:1006` (legacy
   title snippet); a required `Int` would drop titles for old sessions.
6. **`erConvLen` is per-kind, and reconstruction gets it wrong three
   ways.** It is a delta for `EKHarness` and absolute otherwise
   (`Handles/Transcript.hs:360-366`), but streaming, paged (`go` +
   `foldToStart`) and pure `reconstruct` all misuse it — see WU-2.

## Problem

The web frontend's "branch session from here" button opens the new-tab
composer with a `Branch From` field pre-filled, but the resulting session
inherits **nothing**. Reproduced by the operator: branching from a session
produced `20261117-141521-785` with `"parent": null` and a 1-line
`conversation.jsonl` (only the `SETUP_REPO` clone result).

Two independent defects:

### Defect 1 — the backend never implemented branching

`handleTabNew` (`src/Seal/Gateway/API.hs:1251`) dispatches on `kind`:

| kind | line | behaviour |
|---|---|---|
| `shell`/`ssh`/`attach` | 1254–1256 | 501 stub |
| `provider` | 1258 | `newSessionMeta` → brand-new **empty** session |
| `harness` | 1281 | inserts harness tab |
| `resume` | 1283 | binds an existing session |
| anything else | 1301 | 400 `unknown 'kind' field` |

There is no `branch` arm. `rg 'branch_from' src/ src-gateway-types/
src-chat-channels/` returns **zero hits**. The frontend sets
`body.branch_from = branchFrom` (`NewTabComposer.tsx:69`) and declares the
field (`useApi.ts:1007`), so the request lands on the `Just "provider"`
arm and the field is silently discarded.

### Defect 2 — the branch anchor on the wire is unusable

`branchFrom` is the frontend's `entryId`, but every writer site sets
`erId = ""` (`Agent/Loop.hs:164,241,351,398,430,456,533,556,723`,
`ISA/Dispatch.hs:150,214,261,290`, `Command/Stop.hs:81`,
`Command/Model.hs:89`, `Core/TurnEngine.hs:892`). `reconEntryToFrontend`
(`Gateway/Transcript.hs:734`) therefore substitutes a **render index**:

```haskell
entryId = let raw = teId te in if T.null raw then T.pack (show idx) else raw
```

Worse, the two render paths use **different coordinate systems**:
`convLineToFrontend` (`:571`) uses the conversation-line index, while the
reconstruction path uses the entry index. The operator's own
`entries.jsonl` confirms it:

```
EMPTY harness 0 / EMPTY harness 1 / EMPTY request 0
```

An index is not a durable branch boundary. The branch point must become an
explicit **conversation length** — the unit that seeds a new
`conversation.jsonl`.

### Operator decisions already made

- **Workdir: fresh and empty, always.** `sessionWorkdir` is keyed by
  session id (`Config/Paths.hs:372`) and `ensureSessionWorkdir` is an
  idempotent `mkdir -p` (`Session/Workdir.hs:66`), so a new session id gets
  an empty directory *for free*. No copy must ever be added: the
  transcript records tool inputs/outputs, never filesystem snapshots, so a
  historical workdir is unreconstructable. Copying the current one would
  be a lie that diverges the moment the user branches from further back.
- **Repo metadata: NOT inherited.** `smRepoUrl` is documented as "the
  repository cloned into the session's workdir" (`Session/Meta.hs:80`).
  Setting it while the workdir is empty would make `session.json` lie.
  The composer's "Set up repo" box is left **empty** in branch mode: the
  user pastes a URL if they want a re-clone. Pressing "Branch" yields an
  empty workdir and no `repo_url`, by construction.
- **Fidelity: conversation prefix + matching entries prefix.** Preserves
  full render fidelity for inherited rows (tool-call boxes, thinking
  blocks, per-entry model labels).
- **Fold in the latent `EKHarness` absolute-vs-delta reconstruction bug**
  (see WU-2), since the truncation logic must decode `erConvLen`
  correctly anyway.

## Design

### The anchor

Add `convLen` — the conversation length **after** this row — to the
frontend `TranscriptEntry` wire shape. Additive JSON: existing consumers
ignore it.

- conv-only path (`convLineToFrontend`): `convLen = idx + 1`.
- reconstruction path: the fold cursor after the entry. For
  `EKRequest`/`EKResponse`/`EKCompaction` that is `erConvLen e`
  (absolute); for `EKHarness` it is `start + erConvLen e` (delta).

Carried on the wire via a new `teConvLen` field on `TranscriptEntry`
(`src-gateway-types/Seal/Gateway/Types/Transcript.hs`), which is the
cleanest way to thread the position from `Reconstruct` (which knows it)
to `reconEntryToFrontend` (which renders it).

### The request

Extend the **existing** `provider` arm — no new `kind`. The composer
already sends a `provider` body with `branch_from` attached, and its kind
locking (`NewTabComposer.tsx:41`) exists to keep branching on the provider
path. Adding a `branch` kind would require rewriting that locking for no
behavioural gain.

```
POST /api/tabs/new
{ kind: "provider", provider, model,
  branch_from?: "<parent session id>",
  branch_conv_len?: <int> }
```

Three cases, spelled out in WU-4: **neither** field ⇒ today's behaviour
exactly (byte-identical request for every non-branching client);
`branch_from` **without** `branch_conv_len` ⇒ a loud 400 (never a silent
empty session); **both** ⇒ seed from the parent.

### The seeding

New module `src/Seal/Session/Branch.hs`:

```haskell
branchSession
  :: SealPaths -> SessionId -> SessionId -> Int -> IO (Either Text ())
```

`parent` → `child`, copying the first `N = branch_conv_len` conversation
lines:

1. **Clamp `N`** to `[0, parent conversation line count]`, where the
   count is the number of **newline-terminated** lines actually present —
   not the index's line count. The value is client-supplied and therefore
   untrusted; clamping (never rejecting) makes a stale frontend harmless.
   Counting newlines rather than trusting the index also makes a **torn
   trailing line** harmless: the writer appends `line <> "\n"` per message
   (`Handles/Transcript.hs:369-378`), so an in-flight turn can leave a
   partial final line with no newline. That line never counts toward `N`,
   so it is never copied, and the child always ends on a complete message.
   Branching from a session mid-turn therefore yields a valid transcript
   truncated at the last complete message rather than a corrupt one.
2. **Copy `conversation.jsonl` byte-exactly**: read the parent file, take
   the first `N` newline-terminated lines, write them verbatim to the
   child. Byte-copy (not decode/re-encode) keeps the copied lines
   identical to the parent's.
3. **Copy the `entries.jsonl` prefix** selected by folding conversation
   positions, re-encoded through `encodeEntryRecordRaw` (canonical by
   contract — the module documents that the JSONL line *is* the canonical
   encoding). Fold, replicating the **writer's** convention
   (`Handles/Transcript.hs:360-364`), which is *not* uniform per kind:

   | kind | cursor after entry |
   |---|---|
   | `EKRequest` | `erConvLen e` (absolute) |
   | `EKResponse` | `erConvLen e` (absolute) |
   | `EKCompaction` | `erConvLen e` (absolute) |
   | `EKHarness` | `start + erConvLen e` (**delta**) |

   Include an entry iff its cursor-after is `<= N`. Entries are
   append-ordered, so stop at the first entry that overflows.
4. **Build `conversation.idx`** via `ensureIndex`
   (`Transcript/ConvIndex.hs:288`) — but **only when `N > 0`**. With
   `N = 0` create *neither* `conversation.jsonl` nor `conversation.idx`,
   because that is exactly what a fresh session looks like:
   `withIndexedTranscript` creates no conversation file for a new session
   and `ensureIndex` returns `Right` when no conversation file exists
   (`ConvIndex.hs:291-296`). Writing an empty conversation file plus a
   single-`[0]` index would instead produce a file that `validateIndex`
   rejects as `IndexCorrupt` — it requires ≥2 offsets
   (`ConvIndex.hs:327-328`) — so a zero-length branch would leave behind
   an index the reader treats as corrupt. Skipping both at `N = 0` makes
   "branch with no history" indistinguishable from "new session", which
   is the honest equivalence.
5. **Write `session.json` last.**

**Parent with no `conversation.jsonl`.** A brand-new parent (tab opened,
nothing sent yet) has no conversation file. This is **not an error**:
there is nothing to inherit, so `N` clamps to `0` and the child is seeded
with an empty conversation — the same shape as an ordinary new session.
Branching from a fresh session is legitimate (if pointless) and must not
400, so the `Left` cases in WU-3 are *I/O* failures only (missing or
unreadable `session.json`, write failure), never "nothing to copy".

**Archived parents are allowed.** Archiving is a pure UI hint: it
creates an `archived` marker file and deliberately leaves `session.json`
and the transcript untouched (`Session/Store.hs:219-234`). So the WU-4
existence guard cannot and should not reject it, and the branch button
remains available on archived sessions (they resolve as
`selectedSession` at `App.tsx:1136`). Branching an archived session is
therefore permitted and copies its transcript normally — the child is a
new, unarchived session. This is stated as a decision rather than left
implicit, because "archived" reads like "gone" and a reader could
reasonably expect a refusal.

**Legacy parents: a known, accepted limitation.** The read path prefers
`transcript.jsonl` *whenever it exists*, unconditionally
(`Gateway/Transcript.hs:212-215`), and the writer deliberately creates
`conversation.jsonl` **alongside** an existing legacy file
(`Handles/Transcript.hs:331-333`). So a migrated-then-continued session
can have both files yet still be rendered from the legacy one, whose rows
carry no conversation position we can trust.

Consequence: such sessions offer **no branch button** after this change,
although they offer one today (legacy rows do carry `id`, so
`ChatArea.tsx:1545`'s `entryId` gate is satisfied). That is a **narrow
regression, accepted deliberately** rather than a claim that no
conversation file exists — the earlier draft's stated rationale was
simply wrong. The alternatives were worse: guessing a position from a
legacy row index would produce a silently truncated or misaligned
branch, which is exactly the failure class this plan exists to remove.

Follow-up (out of scope here): teach `teLineToFrontend` to map legacy
rows onto `conversation.jsonl` positions when both files exist, or make
the read path prefer `conversation.jsonl` when it is present. Tracked as
a separate issue so this fix stays one logical change.

Ordering in `handleTabNew`: seed (steps 1–4, which leave no
`session.json`) → `insertTabH` → `saveSessionMeta` → `triggerBroadcast
deps` (matching the existing provider arm at `API.hs:1274-1276`; without
it the new tab does not appear in the sidebar until an unrelated event). A failed seed
therefore leaves no visible session *and* no dangling tab, because
`listSessions` only scans dirs containing `session.json`
(`Session/Store.hs:159`). On failure, remove the partial child directory.

### Why the copy is a valid writer baseline

`withIndexedTranscript` initializes `itsWritten` from any existing
`conversation.jsonl` (`Handles/Transcript.hs:511-532`), so:

- `prior = itwReadConversation` = the `N` copied messages;
- `turn0 = prior <> [userMsg]`, `erConvLen = N + 1`;
- writer computes `newLen = (N+1) - N = 1`, `new = take 1 (drop N turn0)`
  = `[userMsg]`.

The append is exactly correct — no duplication, no desync. Because
`itsPriorEnv` starts `Nothing`, the child's first new request entry emits
a **full** envelope delta, giving reconstruction a fresh baseline.

### Security review

- No new trust boundary: the caller is an already-authenticated web user
  who can read any session transcript via `SESSION_MANAGE get`. Copying a
  transcript to a new session the same user owns grants no new access.
- `branch_from` is validated as a `SessionId` via `mkSessionId` and the
  parent's `session.json` must exist — no path traversal
  (`isValidSessionId` permits only `A-Za-z0-9_-` and rejects a leading
  `.`, so `/` and `..` cannot appear; `sessionWorkdir` already
  `error`s on an invalid id).
- Nothing here touches `~/.seal/` security-critical state
  (`security.toml`, `exec-known-hosts`, `keys/`, `config/vault/`,
  `ssh-mux/`). Session transcripts live under `state/sessions/`.
- This is a gateway API route (human-driven), not an opcode — the
  "no opcode may read/write `~/.seal/`" rule is not engaged.

## Work units

Each WU ends with a compiling, green tree (`make check`).

### WU-1 — `teConvLen` on the transcript wire

**Files:** `src-gateway-types/Seal/Gateway/Types/Transcript.hs`,
`src/Seal/Transcript/Reconstruct.hs`, `src/Seal/Gateway/Transcript.hs`,
`frontend/src/types.ts`

- Add `teConvLen :: !(Maybe Int)` to `TranscriptEntry`, encoded as
  `convLen`. **`Maybe`, not a required `Int`** — see the hazard below.
- `toEntry` takes the cursor-after and sets it.

**Why `Maybe Int` and not `Int`.** `TranscriptEntry`'s `FromJSON` is the
generic `stripPrefixParseJSON`, and the type *is* parsed from JSON in one
place: `matchFirstLegacyUserMsg` (`Gateway/Transcript.hs:1006`) decodes a
line as `TranscriptEntry` to extract the first user message snippet (the
sidebar session title). A required `convLen` would fail that parse for
every legacy transcript lacking the key, silently returning `Nothing` and
dropping the title for old sessions. `Maybe` costs one `fromMaybe` at each
render site and removes the regression entirely. `Nothing` means "no
anchor", and WU-5's gate then offers no branch button for that row — so
the backend is never asked to guess a position.
- `reconstructStreaming`: pass `erConvLen e` for request/response/
  compaction; `start + erConvLen e` for harness (see WU-2).
- `reconEntryToFrontend`: emit `convLen`.
- `convLineToFrontend`: emit `convLen = idx + 1`.
- `teLineToFrontend` (legacy path): emit **no** `convLen`. Legacy
  transcript lines carry no positional information we can trust, and the
  branch button is gated on `convLen` (WU-5), so a legacy-only session
  simply offers no branch button — there is no `conversation.jsonl` to
  copy a prefix from anyway.

**DoD**
- [ ] `TranscriptEntry` round-trips `convLen` (`TranscriptSpec`).
- [ ] **Backward compatibility:** a legacy transcript line with **no**
      `convLen` key still decodes, so `firstUserMessageSnippet` and
      `firstUserMessageSnippetFast` (`Gateway/Transcript.hs:1006,418`)
      keep returning the first user message. This is the test that
      catches an `Int`-instead-of-`Maybe Int` mistake; a round-trip test
      cannot.
- [ ] `convLineToFrontend` sets `convLen = idx + 1` (unit test).
- [ ] `reconEntryToFrontend` emits `convLen` from `teConvLen` (unit test).
- [ ] Every existing `TranscriptEntry` constructor in `test/` compiles
      (field addition is a compile-time sweep — expect churn).
- [ ] `make check` green.

### WU-2 — Fix `EKHarness` delta semantics in reconstruction

The writer treats `erConvLen` as a **delta** for harness entries
(`Handles/Transcript.hs:360-364`) but `reconstructStreaming`
(`Reconstruct.hs:313-317`) treats it as an **absolute** end:

```haskell
EKHarness -> do
  eMsgs <- readMsgsH hs lc (capStart start (erConvLen e)) (erConvLen e)
  ...
  rest <- go hs lc start mEnv es   -- also fails to advance `start`
```

With `start > 0` this reads the wrong range and drops the harness entry's
conversation messages. It rarely bites today because full reads use
`start = 0`. `recordSkillLoadResult` and `recordSetupRepoResult` both set
`erConvLen = length convMsgs` (a delta); `mkInvocationEntry` sets `0`.

**Files:** `src/Seal/Transcript/Reconstruct.hs`

- `reconstructStreaming`: `end = start + erConvLen e`; read
  `[capStart start end, end)`; recurse with `end`.
- `reconstructStreamingPage`: same fix in its `go`, and in `foldToStart`
  advance `start + erConvLen e` for `EKHarness` (currently leaves `start`
  unchanged).
- `reconstruct` (pure, `:128-136`): the slice is already delta-shaped, but
  it recurses with `start` unchanged and the adjacent comment falsely
  claims harness entries always carry `erConvLen = 0`. Recurse with
  `start + erConvLen e` and correct the comment. Note: this pure variant
  has **no production caller** (`Gateway/Transcript.hs:61` imports only
  the streaming pair); it is fixed anyway because it is the parity
  reference in `ReconstructSpec.hs` and leaves three copies of the bug
  otherwise.

**DoD**
- [ ] QuickCheck/unit property: for a synthetic entries list mixing
      request/response/harness with harness deltas `0` and `1`, the
      reconstructed conversation slices concatenate to the full
      conversation, for every `start` offset.
- [ ] Regression test: a harness entry with `erConvLen = 1` at
      `start = 5` yields its conversation message (fails before, passes
      after).
- [ ] `make check` green.

### WU-3 — `Seal.Session.Branch` seeding module

**Files:** new `src/Seal/Session/Branch.hs`; new
`test/Seal/Session/BranchSpec.hs`; wire into library
`exposed-modules:`, test-suite `other-modules:`, `test/Main.hs`

- `clampBranchLen :: Int -> Int -> Int` — pure, `clamp 0 parentLen n`.
- `foldEntryPrefix :: Int -> [EntryRecord] -> [EntryRecord]` — pure, the
  per-kind cursor table above; stop at the first entry exceeding `N`.
- `branchSession :: SealPaths -> SessionId -> SessionId -> Int -> IO (Either Text ())`
  — clamp, byte-copy conversation prefix, re-encode entries prefix,
  `ensureIndex` (build-if-missing, matching `withIndexedTranscript`),
  clean up the child dir on any failure.
- Returns `Left` only on I/O failure: missing/unreadable parent
  `session.json`, an unreadable-but-present conversation file, or a write
  failure. An **absent or empty** conversation is `Right` (empty child),
  per the Design decision above.

**DoD**
- [ ] `foldEntryPrefix` property: for any entries list and `0 <= N <=
      total`, the fold is a prefix (never reorders), the sum of harness
      deltas + final absolute position equals the copied line count, and
      no included entry's cursor-after exceeds `N`.
- [ ] `foldEntryPrefix` unit tests: `N = 0` ⇒ `[]`; all-request list ⇒
      entries with `erConvLen <= N`; harness delta `0` included when
      `start <= N`; harness delta `1` straddling `N` excluded.
- [ ] `branchSession` end-to-end in a temp dir: parent with 3 conversation
      lines and 2 entries, `N = 2` ⇒ child `conversation.jsonl` has
      exactly the first 2 lines **byte-identical**, child `entries.jsonl`
      holds only the entry whose cursor-after `<= 2`, and
      `conversation.idx` exists and reports 2 lines.
- [ ] `branchSession` clamps out-of-range `N` (negative ⇒ 0; `> total` ⇒
      total) rather than failing.
- [ ] `branchSession` on a missing parent returns `Left` and creates no
      child directory.
- [ ] `branchSession` on a parent with **no** `conversation.jsonl`
      (or an empty one) succeeds — not `Left`.
- [ ] **`N = 0` produces no `conversation.jsonl` and no
      `conversation.idx`,** matching a fresh session exactly. Reading the
      child back (`readTranscriptEntries`) returns `[]` without any
      `IndexCorrupt`, and the first subsequent turn writes a coherent
      conversation + index (the writer's own fresh-session path).
- [ ] **Torn trailing line**: a parent whose last line lacks a trailing
      newline (mid-turn write) yields a child ending at the last
      *complete* line, and clamping counts only newline-terminated lines.
      The child must never end mid-line.
- [ ] **Workdir assertion**: after `branchSession`, the child workdir is
      absent/empty (documents the operator decision; guards against a
      future "helpful" copy).
- [ ] `make check` green.

### WU-4 — Gateway wiring: branch handling in the `provider` arm

**Files:** `src/Seal/Gateway/API.hs`; `test/Seal/Gateway/APISpec.hs`
(extend existing `handleTabNew` coverage)

- `parseBranchFrom :: A.Value -> Maybe SessionId` — `branch_from` via
  `mkSessionId`.
- `parseBranchConvLen :: A.Value -> Maybe Int` — `branch_conv_len`,
  non-negative; absent/invalid ⇒ `Nothing`.
- Provider arm, three cases:
  - **Neither field present** ⇒ today's behaviour exactly (a plain
    provider session; the request is byte-identical to a non-branching
    client's).
  - **`branch_from` present, `branch_conv_len` absent** ⇒ **400** with a
    message naming the missing field. Do *not* fall through to a plain
    session: a client that sends `branch_from` is by definition
    branching, and silently handing it an empty session is precisely the
    silent-discard bug this plan exists to fix (`:90-95`). This is
    reachable from a stale cached bundle, since a render index like
    `"12"` is a *valid* `SessionId` — so it must be a loud error, not a
    quiet empty session.
  - **Both present** ⇒ require the parent `session.json` to exist (else
    404 `session not found`), `branchSession` (else 400 with the error
    text), then `insertTabH` → `saveSessionMeta`.

**DoD**
- [ ] Branch request seeds the child transcript and returns
      `{tab_index, session_id, kind:"session:provider"}` — end-to-end
      against a temp `SealPaths`.
- [ ] The branch path calls `triggerBroadcast` after `saveSessionMeta`
      (sidebar updates immediately; same as the existing provider arm).
- [ ] Unknown `branch_from` ⇒ 404, no session directory, no tab.
- [ ] **Archived parent** ⇒ succeeds (archiving is a UI hint; the
      transcript is intact), child is unarchived.
- [ ] **Neither** field ⇒ plain provider session (no history); request
      body identical to today's — the non-branching client is unaffected.
- [ ] `branch_from` present but `branch_conv_len` absent ⇒ **400**, not a
      silent empty session; no tab, no `session.json`.
- [ ] A failed seed leaves no tab and no `session.json`.
- [ ] `make check` green.

### WU-5 — Frontend: send a real anchor

**Files:** `frontend/src/types.ts`,
`frontend/src/hooks/useTranscriptMessages.ts` (**the production
renderer**), `frontend/src/components/ChatArea.tsx`,
`frontend/src/App.tsx`, `frontend/src/components/NewTabComposer.tsx`,
`frontend/src/hooks/useNewTabSpec.ts`, `frontend/src/hooks/useApi.ts`,
plus their `__tests__`

**The renderer trap.** `transcriptToMessages` (`ChatArea.tsx:1996`) is
imported **only by tests**; the app renders from
`useTranscriptMessages(entries, currentSessionId)` (`App.tsx:624`), whose
`processEntry` sets `entryId: e.id` at
`useTranscriptMessages.ts:119,157,227,247,296`. Targeting `ChatArea.tsx`
alone would leave `convLen` undefined in production, so no
`branch_conv_len` would be sent and the branch request would be rejected
by WU-4's one-field 400 — the feature would be visibly broken rather than
silently wrong, but still broken. Both renderers must change together,
because `transcriptRendererParity.test.ts:66` deep-compares them.

- **`branch_from` carries the PARENT SESSION id, not the entry id.**
  This is the second half of Defect 2 and the reason the button cannot
  work today: `handleBranch` (`App.tsx:852`) currently stores only the
  row's `entryId`, and WU-4 requires a parent `SessionId`. Because
  `isValidSessionId` accepts digits (`Core.hs:57-63`), a render index
  like `"12"` would pass `mkSessionId` and then 404 — a green build with
  a still-broken button. So:
  - **The row cannot supply the session id, so App curries it.** The
    invocation is inside the ChatArea row (`ChatArea.tsx:1546-1548`),
    where only `message` is in scope — there is no session id there. So
    the row callback stays `(entryId: string, convLen: number) => void`
    (both declarations: `ChatArea.tsx:1446` and `:2529`), and **App's
    prop construction** supplies the parent:
    `onBranch={currentSessionId ? (entryId, convLen) => handleBranch(currentSessionId, entryId, convLen) : undefined}`
    at `App.tsx:1136` (which already gates on
    `selectedSession?.runtime.startsWith('session:')`). `handleBranch`
    then stores all three. No session id is ever threaded into the row.
  - `NewTabComposer` sends `body.branch_from = <the parent session id
    App curried in>` and `body.branch_conv_len = convLen`.
  - The entry id remains a **UI-only** reconciliation key (for the
    optimistic branch-draft row); it never goes on the wire. If it is
    not needed there, drop it rather than carry dead state.
- `Message` gains `convLen?: number`; `TranscriptEntry` gains
  `convLen?: number`.
- `useTranscriptMessages.processEntry` sets `convLen: e.convLen` at
  **every** site that sets `entryId` (`:119,157,227,247,296`), and
  `transcriptToMessages` sets the matching field so parity holds.
- **Gate the button on `convLen`, not `entryId`.** `ChatArea.tsx:1545`
  currently gates on `message.entryId !== undefined`. That is both too
  loose and the wrong key: `entryId` is a render index, while `convLen`
  is the actual anchor. Gate on `message.convLen !== undefined` and pass
  `convLen` as a definite `number` at the one call site.
  Note this makes **harness rows (SKILL_LOAD, SETUP_REPO, approval)
  branchable**, because WU-1 legitimately gives every `EKHarness` entry a
  `convLen` (`start + erConvLen e`). That is correct, not a leak: those
  rows *are* conversation positions, and branching at a skill-load or
  clone row is a meaningful thing to do. The earlier draft tried to
  exclude them, which contradicted WU-1 — an unsatisfiable gate. Rows
  with genuinely no anchor are exactly those from the legacy path, which
  emit no `convLen` at all.
- `App.handleBranch` passes `branchMode = true` to `useNewTabSpec` when
  opening the branch composer, solely so `persistOnSubmit` will not
  record a repo (see the repo bullet below).
- **Repo: leave the box EMPTY in branch mode. No prefill.**
  The requirement is that the user can *explicitly* re-clone; the
  composer's existing "Set up repo" box already is that path — an empty
  box means no clone, and pasting a URL means one. Prefilling it was
  unnecessary machinery, and it fought the code: `NewTabComposer`
  dispatches `SETUP_REPO` with no dirty-check whenever `spec.repo` is
  non-empty (`:78-80`), and `useNewTabSpec` is a **single shared
  instance** created at App mount (`App.tsx:320`) with a run-once restore
  effect (`:159-177`). A prefilled value would therefore (a) clone into
  the branch workdir on submit, and (b) survive a cancel into the next
  ordinary "New tab", since `handleNewTab`/`handleComposerCancel` reset
  only `branchFrom` (`App.tsx:841-849`). Leaving the box empty satisfies
  decision (b) by construction and needs **no** new toggle, no
  `initialRepo`, and no `branchMode` plumbing in the hook.
- `useNewTabSpec` needs **one** change, not a redesign: its
  `persistOnSubmit` must not record `repo` when the composer was opened
  in branch mode (`:311-345`), so a branch can never rewrite the
  last-used repo for later tabs. Pass a single `branchMode?: boolean`
  argument for that purpose only.
- Branch-mode hint: one line of text stating how many messages are
  inherited and that **the workdir starts empty** — the one fact a user
  cannot infer and would otherwise be misled by.
- `NewTabComposer`: in branch mode set BOTH fields from the branch
  draft — `body.branch_from = <parent session id>` and
  `body.branch_conv_len = convLen` — instead of today's
  `body.branch_from = <row's entry id>`. Submit is otherwise unchanged;
  with an empty repo box no `SETUP_REPO` fires.
- `CreateTabBody` gains `branch_conv_len?: number`.
- Branch-mode hint: replace the read-only `Branch From` box with text
  stating the inherited history length and that **the workdir starts
  empty** — the one thing a user cannot infer and would otherwise be
  misled by.
- **Surface the new 400/404 to the user — otherwise they are invisible.**
  `createTab` discards every non-2xx body (`useApi.ts:1022-1027`,
  `if (!res.ok) return null`), and `NewTabComposer`'s failure branch only
  re-enables the form (`:88-91`), so a stale-bundle 400 or a deleted-parent
  404 would render as "nothing happened". Required:
  - `createTab` returns `{ ok: false, error: string }` (parsing the
    gateway's `{error}` body) instead of bare `null`, keeping the existing
    `null` only for network/timeout failures.
  - `NewTabComposer` renders that message. The channel already exists:
    `createTab`'s failure path sets a local error state, and branch-mode
    failures set `repoWarning`-style inline text (the composer's existing
    inline-error pattern at `:300-306`).
  Do **not** add a new `composeError` prop to `ChatArea` — that prop
  (`ChatArea.tsx:2537`) is for the *composer input*, is never passed by
  `App`, and is unrelated to tab creation.

**DoD**
- [ ] **Production path:** `useTranscriptMessages` emits `convLen` on the
      user and assistant rows of a real transcript fixture
      (`useTranscriptMessages.test.ts`). This is the regression guard
      for the reported bug — the assertion is on the *live* renderer,
      not the test-only one.
- [ ] Both renderers agree on `convLen` — the existing
      `transcriptRendererParity.test.ts` parity assertions still pass
      with the new field.
- [ ] A branchable row invokes the row callback with
      `(entryId, convLen)`; **App** supplies the parent, so the request
      carries `branch_from = <parent session id>` — never the row's index
      (`ChatArea.test.tsx` for the row callback, `App.test.tsx` for the
      curried wiring).
- [ ] A row with `entryId` but **no** `convLen` (SKILL_LOAD, SETUP_REPO,
      approval) renders **no** branch button.
- [ ] A non-string/non-number `convLen` from untrusted transcript JSON
      never throws and yields no branch button.
- [ ] **`branch_from` is the parent session id, not the entry id.**
      Branching from a row of session `20260101-000000-000` POSTs
      `branch_from: "20260101-000000-000"` (never the row's index).
      This is the regression guard for the second half of Defect 2.
- [ ] `NewTabComposer` with a parent sid + `convLen` POSTs
      `{kind:'provider', branch_from, branch_conv_len}` (`useApi.test.ts`
      + `NewTabComposer.test.tsx`).
- [ ] **Branch mode does NOT restore `last_options.repo`** (seed
      `last_options` with a repo URL, branch, assert `spec.repo` is
      empty).
- [ ] **Branch mode leaves the repo box empty**, so pressing "Branch"
      dispatches **no** `SETUP_REPO`: the child workdir stays empty and
      `session.json` gains no `repo_url` (the invariant, by construction).
- [ ] A user who types a URL into the box still gets the existing
      explicit re-clone path (unchanged behaviour).
- [ ] Branch mode does NOT restore `last_options.repo`, and
      `persistOnSubmit` does not record it — so a branch never rewrites
      the last-used repo for later tabs (`useNewTabSpec.test.ts`).
- [ ] Cancelling a branch and then opening an ordinary "New tab" leaves
      `repo` empty (no parent URL leaks across composer openings).
- [ ] Non-branch submit body is byte-identical to today's — **negative**
      test asserting `branch_conv_len` is absent.
- [ ] **A rejected branch request is visible**: a 400 (`branch_conv_len`
      missing) and a 404 (unknown parent) each render a message in the
      composer rather than silently re-enabling the form
      (`useApi.test.ts` asserts the parsed error surfaces from
      `createTab`; `NewTabComposer.test.tsx` asserts it is rendered).
- [ ] Branch-mode `persistOnSubmit` does not rewrite `last_options.repo`
      nor append the parent's URL to repo history (`useNewTabSpec.test.ts`).
- [ ] `npm test` green; `npm run build` green.

### WU-6 — Docs + full gate

**Files:** `CHANGELOG.md`; `README.md` (it promises "branching from any
point" at `:78` and `:112` — add the two user-surprising semantics:
branching inherits the transcript **up to that row**, and the new session
starts with an **empty workdir** and no repo)

- [ ] Document the branch flow, the anchor, and the explicit
      empty-workdir / no-repo-inheritance semantics.
- [ ] `make check` green; frontend `npm test` + `npm run build` green.

## Verification: the operator's repro

Branch from the middle of an existing session and confirm:

1. The child's `conversation.jsonl` ends exactly at the chosen row.
2. The inherited rows render with tool-call boxes intact (the WU-1/WU-3
   fidelity payoff).
3. `~/.seal/cache/workdirs/<child>/` is empty.
4. `session.json` carries **no** `repo_url` (repo metadata is not
   inherited).
5. Sending a message appends cleanly — no duplicate user lines, no
   `[transcript-diag] DESYNC` in `seal.log`.

## Out of scope

- Workdir snapshots or any filesystem history reproduction.
- Auto-cloning the parent's repo into the branch.
- A `/branch` CLI command (the existing plan review gate can gate it
  separately).
- Session lineage / branch-tree metadata (a `branched_from` field).
  Nothing reads it: the branch-tree UI is out of scope, so persisting it
  would be unrequested state with no consumer.
- `branch` as a distinct tab `kind`.

## Risks

| Risk | Mitigation |
|---|---|
| `teConvLen` field addition churns many test constructors | Compile-time sweep; mechanical |
| A branch landing on a **user** row yields two consecutive `user` messages on the next turn | No alternation enforcement exists in the codebase; Anthropic merges consecutive same-role turns. WU-1 test: branch at a user row, then assert the next turn's message list is accepted (unit-level on `encodeRequest`). Operator-visible, not an error. |
| Copied entries' `erConvLen` referring to parent positions | Identical positions — the prefix is byte-identical, so they remain correct |
| Legacy `transcript.jsonl`-only parent | Rows carry no `convLen`, so WU-5's gate offers no branch button — the request never reaches `branchSession`. Handled in the frontend, not as a server error. |

## Rollback

Every change is additive on the wire, so a revert is safe at any point
and no migration is needed:

- **`convLen` / `branch_conv_len`** — new optional wire fields. Old
  readers ignore unknown keys; reverting the `TranscriptEntry` field
  restores the previous shape with no data rewrite, because `convLen` is
  never persisted to disk.
- **`Seal.Session.Branch`** — a new module with one caller
  (`handleTabNew`); deleting it plus its cabal entries is a clean revert.
- **Already-branched sessions** keep their copied `conversation.jsonl`
  and remain ordinary readable sessions after a revert. `session.json`
  gains no new key, so nothing needs cleanup.
- **WU-2 (reconstruction fix)** is an independent bug fix. It should be
  kept even if the branch feature is reverted, which is why it is a
  separate work unit that can land alone.
