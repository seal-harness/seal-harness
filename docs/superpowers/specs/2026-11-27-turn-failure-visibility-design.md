# Turn failure visibility — Design

**Requirements baseline**: `docs/superpowers/requirements/2026-11-27-turn-failure-visibility-requirements.md`
(frozen 2026-11-27; every finding is triaged against it).
**Branch**: `fix/turn-failure-visibility`
**Status**: draft — pending design review gate.

> The requirements document is the frozen baseline. A finding that contradicts a
> stated constraint or an out-of-scope item is a CONSTRAINT CORRECTION. A finding
> that would change user-facing behaviour is a NEW REQUIREMENT requiring human
> sign-off.

---

## 1. Problem statement

The harness catches turn exceptions and sanitizes them, but on the web surface
the result is discarded, so a failed turn is indistinguishable from a completed
one. Concretely, in `Gateway/Send.hs:693`:

```haskell
er <- withExceptionLogging ... "plainTurn" $ plainTurn deps meta mSrc t
case er of
  Left e         -> sdTurnComplete deps sid' (Left (T.pack (show e)))
  Right (Left e) -> sdTurnComplete deps sid' (Left e)
```

`sdTurnComplete` is cron-only (`Command/Serve.hs:383` — `Nothing -> pure ()` for
every other session). Meanwhile the turn bracket's cleanup broadcasts
`harness-status idle`, so the tab terminates exactly as it does on success.

Three defects follow, and the design must address all three:

- **D1 — dropped message.** No surface receives the failure.
- **D2 — lost cause.** `sanitizeException` collapses everything except
  `TranscriptError` into `internal error (<where>) [ref: <id>]`. The actual
  cause of the motivating incident (invalid UTF-8) sat *one layer below* the
  `TranscriptError` that was thrown, so it must be carried up, not merely
  un-sanitized.
- **D3 — silent threads.** Bare `forkIO` sites have no top-level handler, so a
  crash there reaches only stderr.

## 2. Design overview

Three pieces: a **failure descriptor** (normalizes any failure into one value),
a **durable record** (a transcript entry), and a **live signal** (an activity
event). The durable record is the source of truth; the live signal is the
nudge.

```
                         ┌──────────────────────────────┐
  exception ────────────▶│ TurnFailure                  │
  dead writer ──────────▶│  tfHeadline :: Text          │
  provider unresolved ──▶│  tfCause    :: FailureCause  │
  CP1 / CP2 (§2.2)       │  tfRef      :: Text          │
                         └───────────┬──────────────────┘
                                     │
                    ┌────────────────┴────────────────┐
                    ▼                                 ▼
        recordFailure (durable)            broadcastTurnFailure (live)
        EKHarness entry, tag=            BeActivity, kind="turn-error"
        "turn-failure"                     │
                    │                      ▼
        ┌───────────┴──────────┐      web UI banner + tab strip
        ▼                      ▼
   conversation.jsonl     chat channels (reply fan-out)
        │
        ▼
   replayed on reload / scrollback
```

### 2.1 The choke point, named precisely (revised)

The first draft said "the release action's `Left errMsg`". **There is no
`Left errMsg` in the release action** — the release action is the bracket
cleanup (`TurnEngine.hs:577-635`), which runs on success too. The `Left errMsg`
branch is in `runTurnBody`, the bracket *body* (`TurnEngine.hs:845-847`):

```haskell
  case eResult of
    Left errMsg -> pure (Just errMsg)          -- <-- the choke point
    Right _     -> do
      broadcastNewEntries ...
      pure Nothing
```

This distinction is load-bearing for §3.7: reporting lives in the *body*, not
the cleanup, which is exactly why a turn that succeeds but whose cleanup throws
cannot double-report. An implementer following the first draft literally would
have put reporting in the cleanup and double-reported on every success.

Note also the asymmetry this exposes (PM blocker 1): `broadcastNewEntries` runs
**only on the `Right` branch**. So a failure entry written on the `Left` branch
is never pushed to the focused client — the operator would see the banner now
and the transcript entry only after a reload. §3.5 fixes this by pushing the
entry on the failure path too.

### 2.2 More than one choke point (round 1c; CP3 added in 1e)

Provider resolution fails **before the bracket is entered** and returns
directly (`TurnEngine.hs:548-554`):

```haskell
case eprov of
  Left err -> do
    taPreTurn adapter sid meta t
    pure (TurnOutcome (Just err))     -- <-- second choke point, no bracket
  Right (prov, model) -> do ...
```

This path throws nothing — `eprov` is an `Either` — so `withExceptionLogging`
never sees it and §3.5's choke point is never reached. A turn that fails to
resolve a provider (bad model name, missing vault key) would therefore produce
**no failure report at all**, which is one of the exact silences this change
exists to fix.

Both choke points must report. They are unified by extracting one
`reportTurnFailure :: TurnDeps -> IndexedTranscriptHandle -> … -> IO ()` called
from each site:

- **CP1** — `runTurnBody`'s `Left (e, ref)` branch (an exception was thrown).
- **CP2** — `runSessionTurn`'s `Left err` provider-resolution branch (an
  `Either` failure, no exception). `classify` here takes a synthetic
  `ProviderResolutionFailed` probe rather than an exception.

CP2 runs *before* the transcript bracket, so it reports using the previous
turn's session directory and must tolerate a missing/short transcript. This is
the same best-effort posture as §3.6, and T12 asserts it.

### 2.3 CP3 — the unprotected prologue, and the delegation worker (round 1e)

The Architect verified two gaps the design still had.

**CP3: everything in `runTurnBody` before line 826.** `mkEnv`,
`loadRuntimeConfig`, `loadSecurityConfig`, `cachedWorkdirScan`,
`resolveSystemPrompt`, `buildSessionRegistry` (`TurnEngine.hs:682-825`) all run
*before* the `withExceptionLogging` wrap, so a throw there bypasses CP1. §3.7's
"once per `runSessionTurn`" was therefore false — it is once per turn **that
reaches line 826**. On CLI there is no outer wrap on the live path (`Cli.hs:350-352`),
so these escape into the Haskeline loop. Fix: move the `withExceptionLoggingRef`
wrap to cover the whole of `runTurnBody` from its first statement, so CP1
subsumes the prologue. CP2 stays separate because it lives in `runSessionTurn`.

**Decision 4 is not satisfied for delegation workers.** §3.5 asserted "each has
its own session and its own `runSessionTurn`". Verified **false** for the
largest fork site: `Worker.hs:299` opens its own transcript bracket and calls
`runTurn` **directly**, and `catchChildSync` (`:383-384`) discards the exception
with `\_ -> writeIORef terminalReasonRef (Just CerError)`. So a child worker that
crashes reports nothing at all — the requirement's "a crash inside a forked
worker" clause is unmet.

Fix: `Worker.hs` calls `reportTurnFailure` inside its existing
`withIndexedTranscript childDir` bracket (it already has a transcript handle and
a session id), and `Worker.hs` is added to the §6 file scope. It does **not**
re-enter `runSessionTurn` — that would create a second report for the same
failure, violating constraint 5.

**§3.8 contradicted §3.5 for `/bg` (constraint 5).** §3.8 told the `/bg` runner
to call `recordFailure` "in its own session context", but `/bg` already calls
`runSessionTurn` (`Cli.hs:260`), so CP1 records once and the §3.8 instruction
records a second time. Corrected: `/bg` gets **only** `forkIOLogged` (so a crash
is logged); it gets no extra `recordFailure`.


## 3. Component design

### 3.1 `TurnFailure` — one normalized descriptor

New module `src/Seal/Transcript/TurnFailure.hs` (see §6 for why not `Session/`).

```haskell
data TurnFailure = TurnFailure
  { tfHeadline :: !Text          -- plain language, user-facing
  , tfCause    :: FailureCause   -- closed vocabulary, never free text
  , tfRef      :: !Text          -- 8-hex correlation id, matches the log
  }
  deriving stock (Eq, Show, Generic)

-- | The cause taxonomy. This is the ONLY taxonomy.
data FailureCause
  = CauseUnicode
  | CauseNoSpace
  | CauseTooManyFiles
  | CauseTranscriptDead
  | CauseProviderUnresolved
  | CauseOther !Text          -- exception TYPE name only
  deriving stock (Eq, Show, Generic)

-- | Derived from 'FailureCause'; a function, not a second ADT.
headlineFor :: FailureCause -> Text

-- | PURE. Takes the nested cause and the correlation id by value.
-- Does NOT touch IO.
classify :: Maybe SomeException -> SomeException -> Text -> TurnFailure
```

**`FailureKind` dropped (CTO blocker 5).** `FailureCause` is a closed
vocabulary that already implies the kind, so carrying both was redundant — and
AGENTS.md is explicit that a bespoke error ADT earns its place only when the
program pattern-matches on it to drive control flow. Nothing does: the headline
and the rendered cause both derive from `FailureCause`. Dropping it also
removes the undefined kind↔cause mapping the CTO flagged (`FailResource`
splitting into `CauseNoSpace`/`CauseTooManyFiles`, with no row for the provider
case): with one taxonomy, no cross-mapping can drift.

**Signature and the correlation id (PM blocker 2, revised).** The first draft
was incoherent in two ways, both fixed here:

1. §3.5 called `classify ... errMsg` where `errMsg :: Text` — but by then the
   `SomeException` has been consumed by `withExceptionLogging`
   (`Exceptions.hs:50-70`). `classify` must be given the exception where the
   exception still exists, i.e. inside the handler.
2. §3.1 said `classify` "consults" `itwLastFailure :: IO (Maybe SomeException)`
   — impossible for a pure function.

Resolution: the nested cause is fetched by the *caller* in IO and passed in,
keeping the core pure and testable:

```haskell
mkTurnFailure :: IndexedTranscriptHandle -> SomeException -> IO TurnFailure
mkTurnFailure h e = do
  ref    <- mkCorrelationId          -- minted ONCE; exported from Exceptions
  mInner <- itwLastFailure h         -- the IO the pure core cannot do
  pure (classify mInner e ref)
```

**The reference id must be plumbed, not re-minted.** `withExceptionLogging`
mints `correlationId` locally (`Exceptions.hs:66`) and only embeds it *inside*
the returned `Text`; it never returns it. So requirement 2's promise — "the
reference is the same short id already used by the log correlation" — is
currently unkeepable. Options:

(a) extend `withExceptionLogging` to return the id (e.g. a
    `withExceptionLoggingRef` variant returning `(userMsg, refId)`), or
(b) mint once at the choke point and pass it *into* `withExceptionLogging`.

The design takes **(a)**, with `mkCorrelationId` exported. `tfRef` is then
genuinely the same id as the log line, which is what makes "full detail is in
`seal.log`" true rather than decorative.

**The exception must be captured before `withExceptionLogging` consumes it
(Architect blocker 2a).** At the choke point only `errMsg :: Text` survives; the
`SomeException` is gone. This is exactly why §3.5 uses
`withExceptionLoggingRef`, which returns the exception *and* the ref it logged
— `classify` then probes the live value. An implementation that only has the
`Text` cannot classify and must not try to re-derive a cause by parsing it.

`classify` is driven by `fromException` probes in a fixed precedence order
(most specific first):

| Probe | Kind | Headline |
|---|---|---|
| `UnicodeException` | `CauseUnicode` | `invalid UTF-8 in tool output` |
| `IOException` containing `"No space left on device"` | `CauseNoSpace` | `out of disk space` |
| `IOException` containing `"Too many open files"` | `CauseTooManyFiles` | `out of open file handles` |
| `TranscriptError _` (inner cause, if any) | `CauseTranscriptDead` / inner | `the session transcript became unavailable` |
| provider resolution failed (CP2, §2.2) | `CauseProviderUnresolved` | `the model provider could not be resolved` |
| anything else | `CauseOther typeName` | `an internal error stopped the turn` |

**The `ENOSPC`/`EMFILE` probes were dead (Architect blocker 2d).** GHC renders
those errnos as `resource exhausted (No space left on device)` and
`resource exhausted (Too many open files)` — the literal tokens `ENOSPC` and
`EMFILE` never appear in `show ioError`, so substring probes on them would
never match. The table now matches the rendered text, matched
case-insensitively since the rendering is GHC-version-dependent. The
requirements' own example string already told us this.

Also: `CauseTooManyFiles`'s headline drops the jargon "file descriptors" for
"file handles" (Designer copy note) — an operator should not need to know the
POSIX term to act.

**`FailProvider` removed (PM suggestion 3 — CONSTRAINT CORRECTION).** No
`ProviderError` type exists in `src/`, and provider failures inside a turn do
not throw: `Agent/Loop.hs:376-395` records them as an assistant `EKResponse`
and returns normally, so they never reach the choke point. The requirements
list "provider-level error categorization" as out of scope. Dropping the
constructor removes a kind that could never fire.

**Constraint 1 (no secrets) — REVISED after security review.** The first draft
claimed `tfCause` would be scrubbed by "the secret-value set already tracked by
`itwSetSecretOps`/`redactMessages`", inherited rather than re-invented. **That
claim was false on three independent counts**, and the reviewer was right to
block it:

1. `redactMessages` (`Handles/Transcript.hs:736-766`) is **provenance-based,
   not value-based**. It collects `ToolCallId`s whose `CbToolUse.cbName` is in
   `secretOpcodes` (= `{"SECRET_MANAGE"}` only, `ISA/Registry.hs:98-100`) and
   blanks only those `CbToolResult` parts. `CbText` passes through verbatim
   (`redactBlock _ other = other`, line 761).
2. `itwSetSecretOps :: Set OpName -> IO ()` stores **opcode names, not
   values**. There is no set of secret *values* anywhere in `src/`.
3. `redactMessages` operates on `[Message]`, so it never sees
   `EntryRecord.erMeta` — and for a harness entry with `erConvLen` delta 0 the
   positional slice it is applied to is empty anyway.

So there is nothing to strip against, and `T.pack (show e)` would have reached
`conversation.jsonl`, `entries.jsonl`, the web UI, **and Telegram/Signal** with
zero effective scrubbing. The chat channel is the fatal one: text sent there
sits on third-party infrastructure permanently and cannot be redacted or
deleted, whereas `seal.log` is local and the user today deliberately sees only
a generic message (`sanitizeException`, `Exceptions.hs:78-84` — generic to
user, raw to operator log; a documented split this design would have collapsed).

**Revised approach — the cause is structured, not free text.** `tfCause` is no
longer `show e`. It is the closed `FailureCause` vocabulary defined in §3.1 —
`CauseUnicode`, `CauseNoSpace`, `CauseTooManyFiles`, `CauseTranscriptDead`,
`CauseProviderUnresolved`, and `CauseOther typeName`.

`CauseOther` carries only the exception **type name** (via `typeOf`) — never a
message body, never a path, never `show e`. This makes leaks
**structurally impossible** rather than scrubbed after the fact, which is the
harness's actual invariant (`orRecorded` is documented as "what the transcript
records (secret-free)": exclusion by construction, never post-hoc redaction).

**`CauseProvider` with a payload is dropped (CTO blocker 6).** The first draft
had `CauseProvider Text` carrying an HTTP status — but provider failures inside
a turn do not throw (`Loop.hs:377-384` returns `"provider error: " <> err` as a
normal result), so nothing would ever construct it. That is the *same* defect
that got `FailProvider` removed, and a dead constructor in a vocabulary whose
whole purpose is "no free text can escape" is worse than redundant: it invites
a future implementer to feed `show e`-derived text into it. Replaced with
`CauseProviderUnresolved`, a payload-free constructor for the CP2 path (§2.2)
where provider *resolution* genuinely fails.

The full raw `show e` continues to go **only** to `seal.log` (operator, local),
joined by `tfRef`. That preserves requirement 5's "operator can find the full
detail" via the reference id without moving it off-box.

**Per-surface scoping** (security suggestion 1, adopted): the chat payload
carries headline + ref only — no cause. Requirement 6 asks only that a phone
user "learns it failed without opening a browser", which headline + ref
satisfy. Raw-ish cause stays on the local surfaces (web transcript, CLI).

**Carrying the cause up (D2).** The motivating incident threw
`TranscriptError "transcript writer daemon died during write"` while the real
cause (`UnicodeException`) had already been swallowed by the writer daemon. The
fix is at the source: `safeDaemon`'s handler (`Handles/Transcript.hs:540`)
currently only logs. It gains a `TVar (Maybe SomeException)` recording the
exception that killed it, exposed as a new handle accessor:

```haskell
itwLastFailure :: IO (Maybe SomeException)
```

`classify` then consults it: on a `TranscriptError`, the handle's recorded
fatal cause (if any) is used for `tfCause` instead of the wrapper
text. This is the difference between "transcript writer died" (useless) and
"invalid UTF-8" (actionable), which is the entire point of the change.

**Why not widen `TranscriptError`.** Making it
`TranscriptError Text (Maybe SomeException)` would break its
`deriving newtype (Eq, Show)` (no `Eq` for `SomeException`) and touch six
construction/match sites across `src/` and `test/`. A separate accessor is a
strictly smaller blast radius, keeps `TranscriptError` a newtype over `Text`,
and — because the daemon sets the TVar before it dies — is race-free for any
caller that observes the death (the `aliveRef` flip and the TVar write happen in
the same handler, TVar first).

### 3.2 The durable record

Reuses `EKHarness` rather than adding an `EntryKind` (a new constructor touches
reconstruction; a tag does not). The entry is written with
`erHarness = Just "turn-failure"` and a payload:

```json
{ "harness": "turn-failure"
, "headline": "invalid UTF-8 in tool output"
, "cause": "unicode"
, "ref": "1a2b3c4d" }
```

**The wire field set is `{harness, cause, ref, headline}` — there is no `kind`
field (Designer blocker 1).** The round-1c edit dropped `FailureKind` from the
type but left `"kind": "decode"` in this example *and* in the gate-1 projection
list, so `harnessPayload` would have projected an always-absent key forever.
Three places are now consistent: this example, gate 1 below, and `base`.

`cause` is the **serialized `FailureCause` constructor** as a lowercase
kebab-case string, matching the repo's existing wire convention:

| Constructor | Wire value |
|---|---|
| `CauseUnicode` | `unicode` |
| `CauseNoSpace` | `no-space` |
| `CauseTooManyFiles` | `too-many-files` |
| `CauseTranscriptDead` | `transcript-dead` |
| `CauseProviderUnresolved` | `provider-unresolved` |
| `CauseOther typeName` | `other:<typeName>` |

**Frontend fallback (Designer suggestion 4).** The vocabulary is closed on the
server but the client parses a string. An unknown `cause` renders the raw string
(i.e. falls into `CauseOther` rendering) rather than an empty line — this entry
type is tag-filtered and will outlive several deploys, so it must be
forward-compatible for free.

**`erConvLen` and the model-visible line (CTO blocker 3 — the most consequential
round-1c finding).** The first draft specified only `erMeta` and never said what
`erConvLen` is or whether a conversation `Message` is appended. That breaks
accepted **decision 1** ("the model sees its own prior turn failures in context
on later turns"), which risk 1 also presumed:

- Every existing `EKHarness` entry uses `erConvLen = 0`
  (`TurnEngine.hs:896`, `ISA/Dispatch.hs:153,293`), so `writeOne` appends
  nothing to `conversation.jsonl` and **the model never sees it**.
- Setting `erConvLen = 1` *also* requires actually constructing the conversation
  `Message` (as `ISA/Dispatch.hs:217` does for `SETUP_REPO`), which the first
  draft never specified.

Resolution — the design **honours decision 1** explicitly:

```haskell
-- | The model-visible line. Deliberately terse and factual, so a context
-- full of prior failures does not derail the next attempt.
renderForModel :: TurnFailure -> Message
renderForModel f = Message Assistant [CbText text]
  where text = "A previous turn failed: " <> tfHeadline f
               <> " (cause: " <> renderCause (tfCause f)
               <> ", ref " <> tfRef f <> ")"
```

`erConvLen = 1`, and `recordFailure` writes
`IndexedTranscriptWrite [renderForModel failure] entry` — the same shape
`recordSetupRepoResult` uses (`ISA/Dispatch.hs:207-218`). Consequence, now
actually realised: the model sees one short line per prior failure, as
decision 1 accepted.

The text is built **only** from `tfHeadline`/`renderCause`/`tfRef` — all closed
or harness-derived — so the model-visible line cannot carry free text either.
T4e asserts the model sees it on the next turn, making decision 1 verifiable
rather than assumed.

**Rendering route — TWO gates, not one (revised).** The first draft named only
the filter in `reconEntryToFrontend`. The security review caught that this is
necessary but **not sufficient**: the payload is rebuilt by
`harnessPayload` (`Transcript/Reconstruct.hs:233-251`), which projects **only**
`op`, `input`, `result`, `channel`, `approval` out of `erMeta` and drops
everything else. A failure entry would therefore reach the frontend carrying no
`kind`/`headline`/`cause`/`ref` and render empty — the feature would silently
do nothing. Both gates must be opened:

1. **Projection**: extend `harnessPayload` to carry `headline`, `cause`, `ref`
   (add them to `base`; **no `kind`** — see §3.2). Without this the data never
   reaches the client.
2. **Filter**: `Gateway/Transcript.hs:721` drops harness entries unless
   whitelisted by `isUserSurfacingOp` (which keys on `op.name`). Our payload
   has no `op` key, so it is filtered out *before reaching the UI*. Add an
   `isTurnFailureEntry` predicate in the same guarded position as the
   `approval` exception.

**There are FOUR gates, not two (Architect blocker 3 — the most serious
round-1e finding).** The first draft's route simply does not work. Gates 1-2
are above; gates 3-4 follow:

3. **`reconEntryToFrontend` hardcodes `"harness" .= (Nothing :: Maybe Text)`**
   on its output (`Gateway/Transcript.hs:774`). So even after the filter lets
   the entry through, the frontend receives `harness: null` — the branch never
   matches, and the feature renders nothing.
4. **`rewritePayload` does not pass `harness` through.** Its Request field
   whitelist is `system, model, tools, toolChoice, maxTokens, approval, op,
   input, result, channel, messages` (`Transcript.hs:841-867`) — no `harness`.
   Every *existing* user-surfacing entry works precisely because it keys on
   `op` or `approval`, both of which are explicitly passed. Our tag is neither.

So the design must either (a) emit and pass the tag through in both places, or
(b) key the frontend on a **new payload field** (e.g. `turnFailure: true`) that
`rewritePayload` is taught to pass. The design takes **(b)**: overloading
`harness` would also change label semantics, because the frontend already uses
`e.harness` as an agent-label fallback (`useTranscriptMessages.ts:302,313`).

Consequence: T5 must assert the field survives **all four** gates — and it must
assert the *field value*, not merely that the entry is present.

**Chat channels (requirement 6, decision 3).** `fanoutLastReply`
(`TurnEngine.hs:986`) scans the last ~50 conversation lines for the last
**assistant** message and fans that text out. The failure entry is `harness`,
not `assistant`, so it will not be picked up by that path. Rather than widen
`fanoutLastReply` (which would send failure text as if it were a reply and also
misfire `reply-delivered`), the release action calls a dedicated
`fanoutFailure replies sid failureText` after recording, reusing
`replyFanout`. It runs on the failure path only, and `failureText` is
**headline + ref only** — no cause (§3.1 per-surface scoping). This is the
irreversible egress path, so it carries the least text.

### 3.3 The live signal

`BrokerEvent` gains **no** constructor. The existing `BeActivity` envelope
carries free-form JSON keyed by `kind` (`Gateway/Broadcast.hs:84`), so a
`turn-error` activity needs only a new broadcast function and frontend
handling:

```haskell
broadcastTurnFailure :: Maybe StreamBroker -> SessionId -> TurnFailure -> IO ()
-- broadcasts BeActivity sid {"kind":"turn-error","headline":…,"ref":…}
```

Frontend `useSessionActivityStream` adds a `case 'turn-error'` arm: set a
session-level error flag (drives the tab strip marker) and surface a dismissible
banner in the focused transcript. This satisfies "live signal without reload"
(requirement 3) without new wire vocabulary.

**Two live signals for one failure need a coexistence rule (Designer blocker
3).** §3.5 now pushes the durable entry on the failure path too, so a focused
client receives **both** a `turn-error` banner and the entry at effectively the
same instant. `StreamConnectionBanner` is the first child of the transcript
scroller (`ChatArea.tsx:2998-3005`), so banner and entry land in the same scroll
region: the operator sees the identical `⚠ Turn failed …` block at the top and
again at the bottom, one of them dismissible. That reads as a rendering bug.

The three-signal layering is **correct and stays** — each is load-bearing
against a distinct requirement sentence:

| Signal | Requirement sentence |
|---|---|
| tab-strip marker | "If the tab is not focused, the tab strip indicates the session has a problem" |
| live banner | "A live signal fires immediately — without a reload" |
| durable entry | "The failure entry persists… Reloading the page still shows it" |

They are redundant only for the **focused-and-current** user, so the rule is:
when the failure entry's id is already present in the rendered window, the
banner renders a **one-line pointer** ("Turn failed — see the entry below")
rather than repeating the block. Both survive; only the duplicated copy is
suppressed. `turn-error` remains the mechanism that makes the failure visible
*when the entry is not yet in the window* (not focused, or the push has not
landed).

### 3.4 Frontend rendering

**`Message` has no `kind` field — one must be added (Designer blocker 2).**
`Message` (`frontend/src/types.ts:707-756`) is
`{id, entryId?, convLen?, agentName, agentStatus, timestamp, blocks[],
isGenerating?, streaming?, meta?, rawJson?, slashBubble?, slashBubbleLabel?}`.
So the design states the new discriminant *and* fills the two required fields
the first draft left unspecified:

- add `kind?: 'turn-failure'` (optional — existing `Message`s omit it);
- `agentName = 'Turn failed'` — drives the coloured header in `ChatMessage`,
  so it is user-visible copy, not an internal label;
- `agentStatus = 'idle'` — required; the failure is terminal;
- `testId = 'turn-failure-entry'` (named explicitly; repo convention is
  lowercase kebab, cf. `ws-connection-banner`, `slash-bubble`).

**BOTH renderers get the branch (Designer blocker 2).** `processEntry`
(`useTranscriptMessages.ts:90`) is the production path, but it is a
**near-verbatim copy** — its own header reads *"Local helpers (duplicated from
ChatArea.tsx — not exported there)"* (line 43) — and `expectFullParity`
(`transcriptRendererParity.test.ts:65`) asserts deep equality. So:

- both `processEntry` **and** `transcriptToMessages` gain the branch;
- a failure entry is added to the parity fixtures, otherwise parity silently
  passes on fixtures containing no failure entry while the copies drift;
- `rg turn-failure` must hit both, which is why the vocabulary is unified
  (§3.4.1).

The first draft said `ChatArea.tsx` was only "for the visual" while T9 said the
`transcriptToMessages` assertion was "parity only" — those contradicted.

Entry `harness === "turn-failure"` renders as:

```
⚠ Turn failed — invalid UTF-8 in tool output

The turn stopped before completing.
Cause: UnicodeException
Reference: 1a2b3c4d
```

**The body sentence is cause-neutral (Designer blocker 4).** The first draft
hard-coded *"The tool call above did not return a result."* — copied verbatim
from the requirements' example of one incident, then applied to all six cause
classes. It is **false** for at least three: `CauseProviderUnresolved` fails
before the bracket is entered (CP2) so no tool ever ran; `CauseTranscriptDead`
can fire on a turn's first write; `CauseNoSpace` may hit the disk check itself.
Telling a user to look at a tool call that does not exist is worse than silence.
The middle line is cause-neutral by default, with a per-cause sentence only
where it adds something true.

Visually distinct from assistant text and tool results, per the requirements'
rendering clause.

**Accessibility (Designer blocker 5).** The design stopped at "visually
distinct", which leaves two concrete traps:

(a) **No `role="alert"` on the entry.** The nearest precedent is `composeError`
    (`ChatArea.tsx:3029-3040`, `role="alert"`), and an implementer will copy it —
    but transcript rows render through `useVirtualWindow`, which unmounts and
    remounts them while scrolling, so `role="alert"` re-announces the failure
    every time the row re-enters the window. **Banner = `role="alert"` exactly
    once; durable entry = static text, no live role.** The ⚠ glyph is
    `aria-hidden="true"` beside a real text label, matching
    `StreamConnectionBanner`'s `<span aria-hidden="true"/>` + `<span>{label}</span>`
    pattern.

(b) **`kindLabel` and `kindIcon` are part of the tab-strip work.**
    `ActiveTabs.tsx` has `kindLabel: Record<TabStatusKind, string>` (line 193)
    read by `aria-label={kindLabel[kind]}` (line 336). Adding a 4th
    `TabStatusKind` **does not compile** without extending both records — and
    `kindLabel` is the *only* surface for the not-focused case, i.e. exactly the
    state the requirement cares about. The checklist below now names them.

**Rendered cause string per constructor (PM suggestion 1 — required for
Done-when 2 to be verifiable).** The cause line is a *fixed* string per
`FailureCause`, so "the operator can distinguish failure classes" is checkable:

| `FailureCause` | Rendered cause |
|---|---|
| `CauseUnicode` | `UnicodeException` |
| `CauseNoSpace` | `resource exhausted (No space left on device)` |
| `CauseTooManyFiles` | `resource exhausted (Too many open files)` |
| `CauseTranscriptDead` | `session transcript unavailable` |
| `CauseProviderUnresolved` | `the model provider could not be resolved` |
| `CauseOther typeName` | `<typeName>` |

These deliberately echo the requirements' own literal examples
(`UnicodeException`, `resource exhausted (No space left on device)`) while
carrying no free text — an exception *type name* is not a secret under
constraint 1, whereas its message body can be.

**The tab error flag needs a lifecycle (PM suggestion 2).** It clears when
(a) the session is focused, or (b) a subsequent turn on that session succeeds —
whichever happens first. It never clears on banner dismissal alone (that would
hide an unattended failure). A permanent marker would be new friction on top of
the fix.

**Tab-strip marker is more work than the first draft implied.** The tab status
is a strict **3-state** function:
`deriveTabStatusKind` (`frontend/src/lib/tabStatus.ts:64-75`) returns
`'thinking' | 'idle-unread' | 'idle-read'` and nothing else. Adding an error
state touches:

- `SessionActivityState` (a new `failed` flag) and the `turn-error` arm in
  `useSessionActivityStream`;
- `TabStatusKind` + `deriveTabStatusKind`;
- `BUCKET_ORDER` and `compareTabs` in `tabStatus.ts` (sort placement — an
  errored session should sort high, like unread);
- `ActiveTabs.tsx:297` and its rendering, **plus `kindIcon` (line 187) and
  `kindLabel` (line 193)** — both are `Record<TabStatusKind, …>`, so a 4th
  variant does not compile until they are extended, and `kindLabel` feeds
  `aria-label` (line 336);
- `tabStatus.test.ts` expectations.

That is a real, testable sub-task, not a one-line flag. Note the `switch` in
`useSessionActivityStream` ends with `default: return current`, so an
unhandled `turn-error` kind **silently no-ops** — which is why T10 exists.

### 3.5 Wiring the three surfaces

Single choke point: the `Left errMsg` branch of `runTurnBody` (§2.1). But the
exception no longer exists there as a value, so the reporting call must be
synthesized at the site that still has it. The clean shape is for
`withExceptionLoggingRef` (the §3.1 (a) variant) to hand back the exception
plus its ref id:

```haskell
-- withExceptionLoggingRef returns the live exception + the SAME ref it logged
eResult <- withExceptionLoggingRef (tdLogger td) mLog "turn" (runApp appEnv (runTurn env t))
case eResult of
  Left (e, ref) -> do
    failure <- mkTurnFailure tHandle e ref        -- classify mInner e ref
    -- ORDER MATTERS: the live signal goes FIRST (Architect blocker 7).
    -- recordFailure can block for defaultAckTimeoutUs = 30s on a STUCK
    -- (alive but unresponsive) writer, and requirement 3 says the live
    -- signal "fires immediately" -- on exactly the scenario that motivated
    -- this change. Sequencing it behind the durable write misses by 30s.
    runDuty "broadcast" (broadcastTurnFailure (tdBroker td) sid failure)        -- 1. live
    runDuty "record"    (recordFailure tHandle failure)                         -- 2. durable
    runDuty "push"      (broadcastNewEntries ... )                              -- 3. see below
    runDuty "fanout"    (fanoutFailure (tdReplies td) sid (renderForChat failure))
    appendSessionLog mLog "ERROR" (renderForLog failure)   -- unconditional
    pure (Just (renderForUser failure))
  Right _ -> ...
```

**Push the entry on the failure path too (PM blocker 1).** `broadcastNewEntries`
runs only on the `Right` branch (§2.1). Without an explicit push, the durable
entry appears only on reload. So `recordFailure` is followed by
`broadcastNewEntries` on the failure path as well — same call, different
branch. T4 asserts the entry reaches a subscribed broker *live*, not just that
it is on disk.

`plainTurn` continues to return `Left errMsg`; `startPlainTurn` additionally
calls `sdTurnComplete` as today (cron unaffected).

- **CLI (corrected — PM suggestion 4).** The first draft cited
  `Channel/Cli.hs:120` (`handlePlain`), which is exported for a wiring test
  (`test/Seal/Channel/WiringSpec.hs:53`) but is **not** the live TUI path. The
  live path is `Channel/Cli.hs:351-352`, which sends `errMsg` **bare, with no
  `turn failed: ` prefix**. The design changes the live path and adds the
  prefix, matching requirement 5's "in the same place and manner as today".
- **Naming (PM suggestion 6).** The renderers are `renderForUser` /
  `renderForChat` / `renderForLog`, not `renderFailure` — that name is already
  exported by `Seal.Command.Parse`/`Help` (Options.Applicative), and reusing it
  would create an import ambiguity.
- **Background / child workers** (decision 4): each has its own session and its
  own `runSessionTurn`, so they get the same treatment on their own transcript.
  No parent-side aggregation — explicitly out of scope.

**Constraint 3 — the tab never stays stuck (PM blocker 5).** The failure duties
run in the bracket *body*, before cleanup broadcasts `idle`. If
`itwRecordAndAck` hits the `daemon stuck` path it can block for
`defaultAckTimeoutUs = 30_000_000` (`Transcript.hs:288-292`), delaying `idle` by
up to 30s — the very "looks stuck" state constraint 3 forbids. Mitigation: the
failure-path write uses a **bounded wait** (a small dedicated timeout, e.g. 2s,
via the existing `timeout` mechanism) rather than the full ack budget. On
timeout the record is abandoned (logged), and the live signal + `idle` proceed.
T7c asserts `idle` is broadcast within the bound even when the writer is stuck.

**Constraint 4 — the session stays usable (PM blocker 5).** Two duties: the
next message must start a clean turn, and no half-state may persist. The
transcript bracket is per-turn, so a fresh daemon is created next turn; the
existing `checkAlignment` guards the positional diff. T4b asserts that after a
failed turn, a subsequent turn on the same session completes normally and
appends correctly. A pending `ASK_HUMAN` left by the failed turn is a
pre-existing condition (out of scope) — noted, not fixed here.

### 3.6 Constraint 2 — the bootstrap problem

The durable record is written **by the transcript writer**, which is precisely
what was dead in the motivating bug. Ordering and fallback:

**The three duties are INDEPENDENTLY guarded** (revised after security review).
The first draft guarded only `recordFailure`, and only against
`TranscriptError`. That is insufficient: `ackWrite` can also fail with
`IOException` (`writeFd`/`fileSynchronise`), and `encodeEntryRecordRaw` can
raise `ErrorCall`. Any of those would abort the `Left` branch *before*
`fanoutFailure` and `broadcastTurnFailure` ran — so failing to record the
failure would suppress the live signal, which is exactly what constraint 2
forbids. Each duty is therefore wrapped in its **own** `try @SomeException`:

```haskell
runDuty label act = act `catch` \(e :: SomeException) ->
  appendSessionLog mLog "ERROR" ("failure-reporting " <> label <> " itself failed: "
    <> T.pack (take 200 (show (typeOf e))))   -- type name only, no body

runDuty "record"    (recordFailure tHandle failure)
runDuty "broadcast" (broadcastTurnFailure (tdBroker td) sid failure)
runDuty "fanout"    (fanoutFailure (tdReplies td) sid (renderForChat failure))
appendSessionLog mLog "ERROR" (renderForLog failure)   -- unconditional
```

`recordFailure` is attempted at most once (no recursion, no retry). If the
durable write fails, the live signal still fires because it never touches the
transcript.

`appendSessionLog` is the operator fallback and runs **unconditionally**. It is
a separate `withFile … AppendMode` (`Session/Log.hs:59`), independent of the
transcript fd, so it survives a dead writer. This is what makes the incident
diagnosable even when every other mechanism is gone.

**Newline injection (security finding, adopted).** `appendSessionLog` writes
`msg` raw (`Log.hs:59-62`) with no newline escaping, so a newline in a
provider body would forge a line in `seal.log`. Two changes: the log-side
renderer for failures escapes newlines, and `appendSessionLog` itself gains
`Text`-level escaping. (`escapeNewlines` is `LogStr -> LogStr`
(`Logger.hs:163-167`); this needs a `Text -> Text` sibling rather than reusing
it.)

**Honest statement of what is best-effort.** On the dead-writer path the durable
entry is *lost from the transcript* — it is broadcast and it is in `seal.log`,
but requirement 1's "the entry persists" is not met for that specific turn.
That is the correct trade-off (the alternative is no signal at all), and it is
recorded here rather than glossed.

### 3.7 Constraint 5 — one report, one entry

Every path that can report must be reached exactly once per failed turn. The
single choke point is the `case eResult of Left` above, which runs once per
`runSessionTurn`. Additional guards:

- `withExceptionLogging` rethrows `AsyncException` after logging; it never
  returns `Left` for one, so a killed turn produces no failure entry. Correct:
  a shutdown is not a failure.
- The release action runs on both success and failure; failure reporting lives
  in the `Left` branch of the *result*, not the cleanup, so a turn that
  succeeds but whose cleanup throws cannot double-report.
- `recordFailure` is idempotent per turn by construction (called once, guarded
  by `try`).

A test drives one exception through `runSessionTurn` and asserts exactly one
entry with `harness == "turn-failure"`.

### 3.8 D3 — the bare `forkIO` sites

Sites: `Gateway/Send.hs:693`, `Channel/Cli.hs:260`,
`Agent/Runtime/Delegation.hs:606,786,802`, `Agent/Runtime/Registry.hs:139`,
`Handles/AskReply.hs:412`, and both transcript daemons.

Introduce `forkIOLogged :: SealLogger -> Text -> IO () -> IO ThreadId` in
`Seal/Logging/Exceptions.hs`. It forks, catches, logs at `ErrorS` with the
label, and returns.

**`AsyncException` MUST be rethrown (CTO blocker 2).** The first draft said
"catches `SomeException` … re-raises nothing". That would log `ThreadKilled` as
an *error* on every normal shutdown, and this repo uses `killThread` for
exactly that (`Agent/Runtime/Registry.hs:39`, `Chat/Telegram.hs:16`,
`Chat/Signal.hs:16`). It also contradicts §3.7's own rule ("a shutdown is not a
failure") and the precedent it cites: `withExceptionLogging` rethrows
`AsyncException` deliberately (`Exceptions.hs:53-64`), with a test asserting it
(`ExceptionsSpec.hs:65`). So:

```haskell
forkIOLogged logger label act = forkIO $
  act `catch` \e -> case fromException e :: Maybe AsyncException of
    Just _  -> throwIO e                     -- shutdown: propagate, do not log
    Nothing -> logIO logger ErrorS (label <> ": " <> typeNameOnly e)
```

Sites with a session context additionally call `logTurnError`. This makes the
RTS default handler unreachable while keeping shutdown silent. Sites whose
failure should *also* become a user-visible `TurnFailure` (the `/bg` runner, the
delegation worker) call `recordFailure` in their own session context — matching
decision 4. T8 asserts both halves: a synchronous throw logs, and a
`ThreadKilled` logs nothing.

## 4. Testing strategy (TDD)

Each unit is RED first, and the RED must be the *requirement*, not a proxy.

| # | Test | RED assertion (fails pre-change) |
|---|---|---|
| T1 | `TurnFailureSpec` — `classify` maps each exception to the right kind/headline | pure unit tests; none pass before the module exists |
| T2 | `classify` recovers the nested cause from `itwLastFailure` | asserts `tfCause == CauseUnicode` for a `TranscriptError` wrapping a `UnicodeException`; pre-change the accessor does not exist |
| T3 | `classify` emits no free text — `tfCause` is a closed constructor, tested over a hand-built exception whose `show` embeds a secret and a vault path | asserts the secret AND the path are absent (constraint 1) |
| T3b | **Negative egress test** — an exception whose `show` embeds a planted secret; assert absent from `conversation.jsonl`, `entries.jsonl`, the `turn-error` frame, and the chat payload | **the load-bearing security test.** T3 alone would pass while the persisted/egressed surfaces still leaked |
| T4 | `TurnEngineSpec` — one exception through `runSessionTurn` yields exactly one `turn-failure` entry | asserts the entry exists; pre-change zero entries (constraint 5, req 7) |
| T4b | After a failed turn, a **subsequent turn on the same session** completes normally and appends correctly | asserts the session is still usable (constraint 4) |
| T4c | The failure entry reaches a **subscribed broker live**, not only on disk | asserts the push on the failure path; pre-change `broadcastNewEntries` is `Right`-only (PM blocker 1) |
| T4d | The failure entry carries the **same `ref`** as the `seal.log` line for that exception | asserts `tfRef` correlation (req 2); pre-change the id is never returned |
| T5 | Replay: the entry survives a reconstruct round-trip **and still carries headline/ref** | asserts BOTH the `harnessPayload` projection and the `reconEntryToFrontend` filter; filtering alone would render blank |
| T6 | `broadcastTurnFailure` emits `activity`/`turn-error` to a subscribed broker | asserts the frame; pre-change no such broadcast |
| T7 | A failure with a dead writer still broadcasts + logs | asserts live signal + `seal.log` line (constraint 2) |
| T7b | Duties independently guarded — a `recordFailure` throwing `IOException` (not `TranscriptError`) still lets broadcast + fanout run | asserts broadcast fired despite record failing (constraint 2, security blocker 4) |
| T7c | A **stuck** (not dead) writer does not delay `idle` beyond the bound | asserts `idle` within ~2s, not 30s (constraint 3, PM blocker 5) |
| T8 | `forkIOLogged` logs a throwing action instead of dying silently | asserts a log record (D3) |
| T9 | Frontend: **`processEntry`** (`hooks/useTranscriptMessages.ts:90`, the *production* renderer) maps a failure entry to `kind:'turn-failure'`; a `transcriptToMessages` assertion is kept only for renderer parity | asserts the rendered node **on the path the app actually uses**. The first draft targeted `transcriptToMessages`, which is parity-only (`transcriptRendererParity.test.ts`) — the branch would have landed in dead code and rendered nothing (CTO blocker 1) |
| T10 | Frontend: `useSessionActivityStream` sets the error flag on `turn-error` | asserts state; pre-change `default: return current` silently no-ops |
| T11 | `appendSessionLog` escapes a newline in the message | asserts one log line, not two (log-injection) |
| T12 | CLI: a failed turn prints headline + cause + ref with the `turn failed: ` prefix on the **live** path (`Cli.hs:351-352`) | Done-when 5; pre-change that path sends `errMsg` bare |
| T13 | Chat: a failed turn fans out **exactly one** message (headline + ref, no cause) | Done-when 6 + decision 3's "one message"; pre-change `fanoutFailure` does not exist |
| T14 | The rendered cause string matches §3.4's table for each `FailureCause` | Done-when 2's "seeing `UnicodeException`"; T2 checks classification only, not the string |
| T4e | The **model** sees the failure line on the next turn | decision 1; pre-change `erConvLen = 0` appends nothing (CTO blocker 3) |
| T15 | Parity: a failure entry in the fixture produces **identical** output from `processEntry` and `transcriptToMessages` | `expectFullParity`; pre-change neither renders it, and adding only one drifts (Designer blocker 2) |
| T16 | Banner shows a **pointer**, not a duplicate block, when the entry is already in the window | Designer blocker 3; asserts one full block, not two |
| T17 | The ⚠ entry carries **no live-region role**; the banner carries `role="alert"` once | Designer blocker 5(a); asserts the virtualized row does not re-announce |
| T18 | A 4th `TabStatusKind` compiles and `kindLabel`/`kindIcon` cover it | Designer blocker 5(b); pre-change the `Record` types are exhaustive over 3 |

Integration: extend **`test/Seal/Gateway/SendSpec.hs`** (it already imports
`runSessionTurn`/`TurnDeps`/`TurnAdapter`, line 46) rather than building a new
harness. It forces a real `UnicodeException` — the original bug, still
reproducible via a non-UTF-8 fixture — through the web send path and asserts the
durable entry, the activity frame, **and** the rendered cause string.

## 5. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Failure entries pollute the model's context and it over-reacts to old failures (accepted decision 1) | Entry text is factual and short — a closed-vocabulary headline, no free text |
| A failure entry desyncs the writer's positional diff or the replay cursor | **Corrected (Architect blocker 5): the first draft's mitigation was vacuous.** `checkAlignment` short-circuits *both* checks for harness entries — `tooShort` and `tailMismatch` are each gated on `not isHarness` (`Handles/Transcript.hs:446,452`) — so it gives zero protection here. The actual invariant is arithmetic, not checked: a harness `erConvLen` is a **delta** (`Reconstruct.hs:127-137`) and `writeOne` appends exactly `take erConvLen (drop writtenLen msgs)` (`:352-366`). So `erConvLen` MUST equal the number of messages actually passed in `IndexedTranscriptWrite`, i.e. **1 with the `renderForModel` message present**. A mismatch silently corrupts every later entry's cursor. T5 is extended to assert that entries *after* a failure entry keep their `convLen` — the real failure mode |
| Chat channel flood during an outage (accepted decision 3) | One message per failed turn; no retry loop added. Documented in requirements |
| Re-entrancy: reporting a failure fails | §3.6 — each duty independently guarded, one attempt, independent log fallback |
| Exception text leaking a secret to any surface | **Removed as a risk class, not mitigated**: `tfCause` is a closed enum and `show e` never leaves `seal.log` (§3.1). T3 + T3b assert it |
| Failure reporting delays the `idle` broadcast (constraint 3) | See §3.6 — the transcript write is bounded below the 30s ack timeout |
| Tab-strip error flag never clears | See §3.4 — clears on focus and on the next successful turn |
| Cleanup throws *after* a good report, and `startPlainTurn`'s outer handler overwrites it with the generic `internal error (plainTurn)` | `runTurnBody` returns the rendered text in `TurnOutcome`; the outer handler fires only if the body itself throws, which is CP1. The integration test asserts the *rendered cause*, so an overwrite fails the test rather than shipping |

## 6. File scope

New:
- `src/Seal/Transcript/TurnFailure.hs` (+ `test/Seal/Transcript/TurnFailureSpec.hs`)

**Module home (CTO suggestion 1 — placement fix).** The first draft put this in
`Seal.Session.TurnFailure`, which inverts the layering: it must import
`Seal.Handles.Transcript` for `TranscriptError`, while
`Handles/Transcript.hs:81` already imports `Seal.Session.Log`, and `Session/`
is the leaf layer (only `Session/Lock.hs:50` reaches into `Handles/`, and only
for `ChannelHandle`). No cycle exists today, but "the session log wants to
record this failure" is the obvious next change and would close one.
`Transcript/` sits beside `Transcript/Entries.hs`, which already owns the entry
vocabulary. The pure `classify` lives there with no `Handles` dependency; the
IO wrapper `mkTurnFailure` stays at the choke point.

Modified:
- `src/Seal/Logging/Exceptions.hs` — `classify` integration, `forkIOLogged`
- `src/Seal/Handles/Transcript.hs` — carry the daemon's fatal exception
- `src/Seal/Core/TurnEngine.hs` — **both** choke points (CP1, CP2); `fanoutFailure`
- `src/Seal/Gateway/Broadcast.hs` — `broadcastTurnFailure`
- `src/Seal/Transcript/Reconstruct.hs` — `harnessPayload` projection (the gate
  the first draft missed)
- `src/Seal/Gateway/Transcript.hs` — filter failure entries through
- `src/Seal/Gateway/Send.hs`, `src/Seal/Channel/Cli.hs` — `forkIOLogged`
- `src/Seal/Agent/Runtime/Delegation.hs`, `.../Registry.hs`,
  `src/Seal/Handles/AskReply.hs` — `forkIOLogged`
- `src/Seal/Agent/Runtime/Delegation/Worker.hs` — `reportTurnFailure` inside its
  existing `withIndexedTranscript` bracket (§2.3)
- `test/Seal/ISA/DispatchSpec.hs` — two hand-built `IndexedTranscriptHandle`
  records break when the handle gains `itwLastFailure` (Architect suggestion 2)
- `frontend/src/types/stream.ts`, `frontend/src/hooks/useSessionActivityStream.ts`,
  **`hooks/useTranscriptMessages.ts` (`processEntry`)** — the production
  renderer — plus `components/ChatArea.tsx` for the visual, and
  `lib/tabStatus.ts` + `components/ActiveTabs.tsx` for the 3-state→4-state work
- `seal-harness.cabal`, `test/Main.hs` (merge hotspots — minimal edits)

### 6.1 Delivery: 3 PRs, not 1 (CTO recommendation, adopted)

This is three logical changes sharing one vocabulary. One PR would be ~20 files
across Haskell and TypeScript, which is not reviewable.

| PR | Contents | Why separate |
|---|---|---|
| **1 — `TurnFailure` core** | `Transcript/TurnFailure.hs` + spec + 3 wiring lines (cabal ×2, `test/Main.hs`) | Pure, no behaviour change. Must land **first**, because PR-2 tests are RED for the right reason only once the module exists |
| **2 — the feature** | CP1+CP2, `itwLastFailure`, `recordFailure`/`renderForModel`, `broadcastTurnFailure`, `harnessPayload` projection, `reconEntryToFrontend` filter, CLI live path, `fanoutFailure`, all frontend work | User-visible; Done-when 1/3/7 are observable only backend+frontend together. Internal seam available (2a backend→wire, 2b frontend) but land as one PR |
| **3 — D3 sweep** | `forkIOLogged` in `Logging/Exceptions.hs` + 6 files | Independent of PR 2; only coupling is that `Send.hs`/`Cli.hs` appear in both, so keep hunks disjoint |

Order: **1 → 2 → 3**. PR 3 may interleave. CTO blocker 3's resolution
(`renderForModel`) changes PR 1's public API, so it is settled before PR 1
starts — which it now is (§3.2).

## 7. Out of scope (from the frozen requirements)

Writer resumability, repairing damaged sessions, retry/resume, provider error
re-categorization, an in-UI log viewer, disk-headroom monitoring. Each is a real
gap; none is this change.
