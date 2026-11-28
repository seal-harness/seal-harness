# `/last` — Design (rev 2)

**Requirements**: `docs/superpowers/requirements/2026-11-26-chat-last-message-requirements.md` (approved 2026-11-26)
**Scope**: Signal + Telegram chat channels. Web frontend out of scope.
**Status**: rev 5 — Design Review Gate rounds 1–3 complete.

## Changes in rev 5 (gate round 3: PM + Designer + Security, all NEEDS_REVISION)

Every round-3 finding was re-verified against source before being accepted.
Two were holes in rev 4's own spec.

| # | Finding (verified) | Resolution |
|---|---|---|
| E1 | **The fallback hole.** `cbToFrontend`'s catch-all emits exactly `{type:"text", text:<raw block JSON>}` (`Transcript.hs:633`), so §4.1's rule ("type==text AND string text") does **not** exclude it. Anything in `blk` — including `input` — becomes assistant prose | §4.1 — `cbToFrontend`'s fallback gets a distinct `type`; `"text"` becomes an honest predicate. One-line gateway change + sentinel test |
| E2 | `/b <n>` had **no failure branch**: if the ask was gone, `/b 1` silently injected a literal `"1"` as a *new user message* into tab b and started a real turn | §5.5 — `SendAnswer` carries `kind:"answer"` (`Send.hs:542-546`); `handleInject` branches on it: `answer` ⇒ `✓ b: <label>`; `assistant` for answer-shaped payload ⇒ explicit "no pending question". §6.4 |
| E3 | `ResolveInput` derived `Show` over `AssistantItem`/`PendingQuestion`, which deliberately have none — **would not compile**, and the obvious fix would silently delete the D9 log guard | §5.0 — `deriving stock (Eq)` |
| E4 | §6.1's cooldown had **no state carrier**: `RateLimit.hs` exports pure functions only, and `handleLast`'s signature had nowhere to put per-conversation state | §6.1 — **cooldown deleted entirely** (out of scope per requirements). No new state |
| E5 | §3 said 3 calls; §6.1 still used `cccGetTabs` (4) | §3.1 — `cccGetTabs` **deleted**; `/last` resolves tabs from `ljTabs` |
| E6 | §10.2's "first chat path to put a pending question in front of a chat audience" is **false**: `notifyWatchCompletion` already does (`Loop.hs:1042`) — and unquoted | §10.2 corrected; §6.3 extends quoting + the neutral footer to that path |
| E7 | §10.3 missed the dominant risk shape: `/last` makes gate-prompt disclosure **pull-on-demand** for any sender, with `allow_from` unenforced | §10.3 — stated |
| E8 | Block-quote rule said "`> ` on every line" but its own example shows a bare `>` on blank lines — two byte sequences for one golden | §5.5 — exact `quoteBody` definition |
| E9 | `for more` hint repeats forever (3 tool-only items ⇒ `/last b 5` ⇒ same hint) | §5.6.1 — saturates on the fetch window |
| E10 | `renderLast (LastMessages h [])` unspecified, but §8.1 requires totality | §5.6.1 — degrades to `LastEmpty` |
| E11 | `handleLast` took `PendingAsks`/`ThinkingTabs` and never read them → `-Wunused-matches` under `-Werror`; and passing `PendingAsks` re-widens what the signature claims to forbid | §6.1 — both dropped |
| E12 | `lriHeading = Nothing` reachable after a tab close (`Loop.hs:2060-2071` clears `tabTracker`, not `SessionMap`) with no render row | §6.1 — resolve to `LENoCurrentTab` before building the view; field dropped |
| E13 | `(truncated — /b to read in full)` is false: `/b` renders through the same cap | §5.6.2 — truncation and the promise both removed |
| E14 | `LEBadCount`/`LENoSuchTab` echo unbounded, newline-bearing user text → can spoof a heading | §5.7 — `singleLine` + 16-char cap |
| E15 | §6.3's "<tool line>" unspecified *which* tool, and `(no result)` would be wrong for a finished turn | §6.3 — defined |
| E16 | `[b] ` renders as broken markdown (no `parse_mode`), undocumented | §5.6.3 — `b: ` instead, documented in `lastHelp` |
| E17 | `TabHeading` kept `Show` while holding content-bearing `lthTitle` | §5.3 — `Show` dropped |
| E18 | "Disclosure auditable" rested on `dbg` → stderr, which is not an audit sink | §6.1/§10 — relabelled |
| E19 | Transcript reads build/repair `conversation.idx` under `~/.seal/state` (`ensureIndex`) — unstated | §10.4 — stated (pre-existing, no config/keys/vault) |
| E20 | Legacy `transcript.jsonl` blocks carry no `type` ⇒ `/last` would report "no messages yet" for a session that has messages | §4.3 — detected and reported honestly |

**Gate note.** Rounds 1–3 each returned NEEDS_REVISION from every reviewer that
completed. Round 2's Architect/CTO agents timed out; round 3's relaunch also
timed out (4 timeouts). Their round-1 findings are addressed in rev 2, and
every claim they raised was re-verified by the orchestrator against source
rather than accepted. rev 5 is therefore the **third and final** gate round;
remaining items are presented to the operator rather than iterated further.

**Prior status line** (superseded): rev 4 — Design Review Gate rounds 1 and 2.

> **Gate status (honest).** Rounds 1 and 2 both returned NEEDS_REVISION from
> every reviewer that completed. Round 2's Architect and CTO agents timed out;
> round 3 relaunched them and **they timed out again** (4 timeouts total). So:
> rev 4 has been fully reviewed by **PM, Designer and Security** (round 2), and
> rev 4's corrections to their rev-2 findings are listed below. The
> Architect/CTO findings from round 1 were addressed in rev 2 and their
> round-2/3 verification never completed. Every claim they raised was
> **re-verified by the orchestrator directly against source** (see the
> `Verified:` notes throughout) rather than accepted on assertion.

## Changes in rev 4 (gate round 2: PM + Designer + Security all NEEDS_REVISION)

Three reviewers independently found the same top defect, and it is real.

| # | Finding (verified against source) | Resolution |
|---|---|---|
| D1 | `formatAsk` hardcodes `Reply with a number or type your own answer.` (`Bubble.hs:70-75`). Reusing it would ship the exact misrouting instruction §5.5 exists to refute. Three reviewers caught this | §5.5 — new `formatQuestionBody` (question + numbered options, **no** hint); `formatAsk = formatQuestionBody <> liveHint`. `/last` uses `formatQuestionBody` only |
| D2 | §10.2 was **wrong**: `aeCaps` for a chat turn is `webAskCaps` (`Send.hs:770`), a rate-limited WS frame, not the chat channel. `/last` is often the *first* delivery | §10.3 — accurate accepted-risk statement |
| D3 | §10.1's "no new read capability" is over-broad: question text **is** new | §10.3 — narrowed to assistant text |
| D4 | `formatAsk` footer also misleads on a **gate** ask; and gate vs open-ended ask are indistinguishable on the wire | §5.5 — one neutral footer for both; `lqIsGate` dropped |
| D5 | `LastQuestion` suppressed on `/b` on a false premise: no ask-replay path exists (`Stream.hs:264-265`), `SeAsk` is focus-filtered (`Loop.hs:880`) | §6.2 — `/b` **renders** `LastQuestion` |
| D6 | `LastWorking Nothing` is reachable but has no body | §5.6.1 — body `no tools have completed yet` |
| D7 | `(failed)?` meta-notation ambiguous; `LtsUnfinished` rendered identically to `LtsOk` | §5.6.1 — explicit 3-row table; `LtsUnfinished` ⇒ `(no result)` |
| D8 | `lsaName :: Text` contradicts `safeOpLabel :: Text -> Maybe Text`; `(unknown opcode)` glyph unspecified | §5.2 — `lsaName :: Maybe Text`; rendered `⚡ (unknown opcode)` |
| D9 | `Show` derived in §5 but §6.1 claims it is dropped | §5.2/§5.3 — `Show` **removed** from content-bearing types; tests compare rendered `Text` |
| D10 | `EntryFacts` used but never defined (the seam where inputs could sneak in) | §5.0 — defined, with no field able to hold an input |
| D11 | Model-authored question text can spoof a `📔 Tab a — last message:` heading | §5.5 — question body is block-quoted (`> `) |
| D12 | `for more` hint uses `length items`, undefined for two of four views | §5.6.1 — scoped to `LastMessages` only |
| D13 | Truncation marker was a dead end | §5.6.2 — **truncation removed entirely** (E13 supersedes) |
| D14 | §3 says 3 calls, §6.1 does 4 (tabs fetched twice) | §3 — resolve the tab from `ljTabs`; drop the extra call |
| D15 | `/api/lists` is the expensive call, not the transcript | §3 — corrected; no mitigation (rate limiting out of scope) |
| D16 | DoD 3 not unconditional: no-text **and** no-tool case | §6.3 — fallback body |
| D17 | `lastHelp` omits "never changes focus" and the `/b` answer path | §2.4 |
| D18 | No audit record for a disclosure | §6.1 — structured disclosure line |


## Changes in rev 3 (operator decision)

| # | Change |
|---|---|
| A | `/last` **does** render the pending question and its options. Answering is `/b <n>` or `/b <text>` — the existing inject path. `/last` stays a pure read and never changes focus |
| B | The "reply with a plain message to answer" claim is deleted: it was false and misrouted replies |
| C | The gate-prompt disclosure is a **bounded, documented exception** — the same text already reaches this conversation's channel via the live ask (`Loop.hs:719`) |

## Changes in rev 2

| # | Finding | Resolution |
|---|---|---|
| 1 | Rendered question was **not answerable**; a plain reply is routed to the focused tab, or answers a *different* question there | §5.5 — the answer path is `/b <n>` (inject), not a plain reply. Plain-reply claim deleted |
| 2 | Confirmation-gate prompt embeds raw tool-input JSON; it is the *question text* | §5.5 — rendered, as a documented bounded exception (same text already reaches this channel via the live ask) |
| 3 | Tool **name** is model-authored, unbounded, unvalidated | §4.2 shape gate + QuickCheck over names |
| 4 | `cbToFrontend` fallback manufactures `type:"text"` from unknown tags | §4.1 extraction uses an allowlist of block types |
| 5 | `ResolveInput` never defined; export list absent | §5.0, §5.6 complete API with signatures |
| 6 | Circular import `Route ↔ LastRender` | §2.1 `ChatLast Text`; `Route` stays a leaf |
| 7 | `ReadLastN` halves the budget; a `tool_result` may live in a *trailing* entry | §3.2 rewritten |
| 8 | `toFailed :: Bool` cannot express "unfinished" | §5.2 tri-state `ToolState` |
| 9 | QuickCheck property vacuous (renderer has no input field) | §8 property is at the JSON boundary |
| 10 | No error constructors for tabs/lists/questions fetches | §5.4 five probes, five errors |
| 11 | `LastMessages … Int` duplicates `length` | §5.3 field dropped |
| 12 | Missing cabal / `test/Main.hs` wiring | §7.1 |
| 13 | `TelegramCommandsSpec` pins `[help,bg,watch]` | §2.3 names all 6 sites |
| 14 | `/b` behaviour undecided | §6.2 four explicit decisions |
| 15 | No help text; `/last -h` renders a fake error | §2.4 `lastHelp` |
| 16 | Heading grammar / separators inconsistent | §5.6.1 single stated contract |
| 17 | No byte-size policy | §5.6.2 |
| 18 | Chunked replies lose tab attribution | §5.6.3 |
| 19 | `Maybe Int` limit lets `0`/junk become `ReadAll` | §3.2 limit is mandatory, `≥ 20` |
| 20 | DoD-4 test "byte-identical SessionMap" unimplementable | §8.2 concrete assertion |
| 21 | Field names violate `_<type>_<field>` convention | §5.2 `lsaName`/`lsaState` etc. |
| 22 | "`/last` worsens cross-conversation read" | **Rebutted** — §10.1; `/b` already reads |

---

## 1. Problem shape

A chat user on tab `a` cannot ask "what did tab `b` say?" without
surrendering `a`: `/b` focuses `b` (a write: `sessionInsert` + `FocusOp` +
`ensureWsConn` + confirmation — `Loop.hs:561-571`). `/last` is a **read**
that names its tab and never moves focus.

Two facts drive the design:

1. **`/last` is chat-local, not a gateway command.** Focus is per
   *conversation*; the conversation→session map lives in the chat loop
   (`SessionMap`), not the gateway. Resolution therefore happens in the loop,
   exactly as `handleFocus` does.
2. **`/last` must not collide with the `/N` grammar.** `route` treats a
   leading `/<char>` as tab focus only when the next char is a space or EOF
   (`Route.hs:72`). `/last` → `after = "ast"`, head `≠ ' '` → already falls
   through to `ChatSlash "last"`, which `sendSlash` would forward to a gateway
   that has no such spec. We must claim it explicitly.

Non-goals: fixing command rate limiting, `allow_from`, or transcript
redaction on disk (requirements, out of scope).

---

## 2. Grammar, parsing, discovery

### 2.1 Route — `ChatLast Text`

```haskell
-- Route.hs, in ChatRoute
| ChatLast Text    -- ^ /last …: the raw argument text, verbatim (may be empty)
```

`route` gains one arm **between the `bg` arm and `otherwise`** (so no existing
arm is reordered), matching when the first token case-folds to `last`:

```haskell
| T.toCaseFold (T.takeWhile (/= ' ') rest) == "last" ->
    Right (ChatLast (T.strip (T.drop 3 rest)))
```

`T.drop 3` removes `last`; the remainder is stripped. `/last` → `""`.
`/last b 3` → `"b 3"`.

**`Route` stays a leaf module.** It carries the raw `Text`, exactly as
`ChatBackground Text` and `ChatNewSession Text` already do. All parsing lives
in `LastRender`, so `LastRender` never imports `Route` and there is no cycle.

`/last` is **not** a gateway `CommandSpec` (verified: no `CommandName "last"`
exists; `sendSlash` = `sendPlain`, so a registered name would POST `/last` to a
gateway that cannot serve it).

### 2.2 `parseLastArgs` (pure, in `LastRender`)

```haskell
parseLastArgs :: Text -> Either LastError LastArgs
```

| Input (after `/last `) | Result |
|---|---|
| `""` | `LastArgs Nothing 1` |
| `"b"` | `LastArgs (Just b) 1` |
| `"b 3"` | `LastArgs (Just b) 3` |
| `"B"` | `LastArgs (Just b) 1` (canonical lower) |
| `"b 0"` / `"b 9"` | count clamped to `1` / `5` |
| `"b foo"` | `Left (LEBadCount "foo")` |
| `"-h"` / `"--help"` | handled *before* this function (§2.4) |
| `"foo"` | `Left (LENoSuchTab "foo")` |
| `"bb"` | `Left (LENoSuchTab "bb")` — a tab is exactly **one** char |
| `"b 2 junk"` | extra tokens ignored → `LastArgs (Just b) 2` |

**Tab rule (stated explicitly):** the first token is a tab iff it is exactly
one character *and* `tabIndexFromChar` accepts it. This is **stricter** than
`parseTabFocus`, which takes the first char of an arbitrary token
(`Route.hs:136`). Being strict is right here: `/last bb` silently meaning tab
`b` is a worse guess than naming the bad token back.

**Product decision:** "the last n messages" = the last *n assistant
responses*. The user's own messages add nothing, and `/last b 5 for more` only
means "more of what it said". When fewer than `n` responses exist, the heading
uses the **actual** count (§5.6.1).

### 2.3 Telegram menu

Add `BotCommand "last" "Show a tab's last message"` **after** `watch`
(`TelegramCommands.hs:103-106`), producing `[help, bg, watch, last]`.

This breaks six pinned assertions in `TelegramCommandsSpec.hs`, all of which
must be updated in the same work unit: `:36-40`, `:43-45`, `:48-52`, `:57`,
`:64`, `:69-71`, `:108-111`. The 100-cap test (`:79-85`) is unaffected. The
module haddock at `TelegramCommands.hs:96-97` ("is `[help, bg, watch]`") is
also updated.

`/last` stays invisible in `/help` (that is gateway-served), so on Signal — no
menu — it is discoverable only from `lastHelp` (§2.4). Accepted asymmetry.

### 2.4 Help

```haskell
isLastHelpArg :: Text -> Bool     -- "-h" or "--help", stripped
lastHelp :: Text
```

Intercepted in `handleLast` **before** `parseLastArgs`, mirroring
`isBgHelpArg` (`Loop.hs:630`) and `/watch -h` (`Loop.hs:908`). Without this,
`/last -h` would render `last failed: no such tab -h`.

Body documents (D17): `[tab] [n]`, default-to-focused, the 1–5 clamp, the
counter-intuitive "first argument is always the tab" rule, **that `/last` never
changes the focused tab**, and **that a pending question is answered with
`/b <n>`**. The last two matter most: on Signal, `lastHelp` is the only
discovery surface (§2.3), and a user who sees `Answer with /b 1` needs to be
able to look it up.

`/last b -h` is **not** help — `-h` is only help as the sole argument, matching
`/watch on -h` (which is not help either, `Loop.hs:920-924`).

---

## 3. Data sources

| Need | Source | Exists? |
|---|---|---|
| tab index → session, tab label | `GET /api/lists` → `tabs` + `tabSessions` | yes |
| session display title | same `tabSessions` (as `TabRender.nameOf`) | yes |
| assistant text + tool calls | `GET /api/sessions/:id/transcript?limit=` | yes |
| still working | `GET /api/lists` → `thinkingSessionIds` | yes |
| waiting on a question | `GET /api/sessions/:id/questions` | yes |

**`/api/lists` is the single scan.** `ListsJson` already carries `ljTabs`,
`ljTabSessions`, and `ljThinkingSessionIds` (`HttpClient.hs:97-101`), and
`TabRender.nameOf` (`TabRender.hs:64-80`) already derives the display title
from `ljTabSessions`. So tabs + title + thinking cost **one** call, not three.
`/last` therefore makes **three** calls: lists, transcript, questions — and it
resolves the tab from `ljTabs` rather than calling `/api/tabs` separately (D14;
§6.1's earlier four-call flow was a duplication bug in the design).

**`/api/lists` is the expensive call, not the transcript** (D15). It runs
`snapshotTabs` + `listSessions` + `listArchivedSessions` + three
`mapConcurrently` passes over every session, reading transcript files for
snippets (`ListsSnapshot.hs:41-61`; its own comment: ~10 s sequential → ~0.6 s
of 16-way concurrent I/O at 700+ sessions). **No mitigation in this work** —
rate limiting is out of scope per the requirements, and `handleTabList`
already calls `cccGetLists` per invocation with no cache (`Loop.hs:2261`), so
`/last` adds no new amplification pattern. Filed as follow-up #5.

### 3.0 No new seam (plan rev 3 simplification)

`sendLastReply` already fetches the transcript **unbounded** on every `/b`
(`Loop.hs:1845`). So `/last` reusing the existing `httpGetTranscript` adds no
new cost class, and the `cccGetTranscript` seam, `httpGetTranscriptLimited`,
`transcriptUrl`, `entryFetchLimit` and the §3.2 `ReadLastN` halving analysis
below are **all removed** from the plan.

Keeping them would also have made the pass/fail join *less* correct: with the
full transcript, a `tool_result` in a trailing conversation entry is always in
the window, so `LtsUnfinished` becomes a rare robustness case instead of the
ordinary path for a turn that ended on a tool call. §3.2 is retained only to
document why the window reasoning was needed — it is no longer implemented.

### 3.1 New seams on `ChatChannelConfig` (removed)

```haskell
, cccGetTranscript :: Manager -> Text -> SessionId -> Int -> IO (Either Text [Value])
  -- ^ @GET …/transcript?limit=N@; default 'httpGetTranscriptLimited'. The
  -- limit is MANDATORY (§3.2).
```

`cccGetTranscript` is a **new** function, not a change to
`httpGetTranscript`'s arity — so `Loop.hs:1158` and `Loop.hs:1845` are
untouched by the seam itself.

**Only one seam** (E5). An earlier revision also added `cccGetTabs`, which
`/last` never needed (it resolves the tab from `ljTabs`) and which
`handleFocus`/`handleInject` already get from `httpGetTabs` (`Loop.hs:547`,
`:583`) without trouble. Adding it would have been scope creep on a working
code path, so it is dropped. Adding one field to `ChatChannelConfig` touches
exactly **two** sites — `defaultChatChannelConfig` (`Loop.hs:386`) and
`stubCfg` (`LoopSpec.hs:333`); every other construction (≈30 in tests, plus
`Serve.hs:975`, `SignalAdapterSpec.hs:237`) uses record-update syntax and is
unaffected.

Construction sites: adding fields to `ChatChannelConfig` touches exactly
**two** — `defaultChatChannelConfig` (`Loop.hs:386`) and `stubCfg`
(`LoopSpec.hs:333`). Verified: every other site (≈30 in tests, plus
`Serve.hs:975`, `SignalAdapterSpec.hs:237`) uses record-update syntax on the
default, so no other edits and no existing test breaks.

### 3.2 The transcript window

`readTranscriptEntriesTimed` splits `ReadLastN n` into a reconstruction budget
and a trailing budget, reserving **up to half** for trailing conversation
lines (`Transcript.hs:282-291`):

```haskell
ReadLastN n | n > 0 ->
  let trailingBudget = min n (min trailingCount (n `div` 2))
      reconBudget    = n - trailingBudget
```

Two consequences the design must state:

1. **Ask for double.** To get ~`n` reconstructed entries, request `2n`.
2. **The pass/fail join must read both halves.** A turn that ended on a tool
   call puts its `tool_result` in a *trailing* conversation entry (it has no
   `EntryRecord` yet), surfaced by `trailingConvEntries`. So the join source is
   **every `request`-direction entry, reconstructed or trailing**, and the
   trailing slice is exactly what makes DoD 2 work.

```haskell
entryFetchLimit :: Int -> Int
entryFetchLimit n = 40 + 8 * n    -- n ≤ 5 ⇒ 80; server clamps to 1000
```

Doubling with slack. `entryFetchLimit` lives in `LastRender` (pure, exported,
tested).

**The limit is never `0`.** `parseLimitQuery` maps unparseable to `Nothing`
(`ReadAll`) and `ReadLastN 0` falls into the `_ ->` branch that reconstructs
**everything** (`Transcript.hs:291`) — the most expensive request. The seam
takes a non-`Maybe` `Int` and asserts `≥ 20`, so neither can be reached. The
URL is built from the parsed `Int` via `show`, never from the raw token.

---

## 4. Extraction (pure)

### 4.1 Block allowlist

`cbToFrontend` maps four tags and rewrites **everything else** to
`{"type":"text","text":<raw block JSON>}` (`Transcript.hs:613-633`). A renderer
that trusts `type:"text"` would therefore print raw block JSON as assistant
prose.

```haskell
extractEntry :: Value -> EntryFacts
```

Rules, all allowlist-based:

- Only entries with `direction == "response"` contribute text
  (mirrors `lastAssistantText`, `Loop.hs:2234-2244`).
- From `payload.content`, only `type == "text"` contributes — and only when
  the block also has a **string** `text` field. `type == "thinking"` is
  dropped. Every other `type` is dropped. No fallback.

**E1 — the fallback hole, and its fix.** This rule is only sound once
`type:"text"` means *text*. It does not today: `cbToFrontend`'s catch-all
rewrites any unrecognized `tag` to
`{"type":"text","text":<raw block JSON>}` (`Transcript.hs:633`), which
satisfies the rule verbatim. For a tool-use-shaped block that raw JSON
contains `input`, so tool arguments would become assistant prose.

So a one-line gateway change is **part of this work**:

```haskell
-- Transcript.hs, cbToFrontend's fallback arm
fallback = object ["type" .= ("unrecognized" :: Text), "text" .= rawJson]
```

`"text"` then honestly means text, and `extractEntry`'s rule is a real
allowlist. Today the fallback is unreachable (`ContentBlock` has exactly four
constructors, `Class.hs:68-73`, all handled), so this closes a latent hole —
which is exactly why it belongs in the design rather than in a comment.
Test: an entry whose block carries a `tag` outside the four with a sentinel in
`input` must render **no** sentinel (§8.1 property 1).
- `type == "tool_use"` contributes a tool name via `lsaName` (§4.2).
- Only entries with `direction == "request"` contribute the pass/fail join:
  `payload.messages[].content[]` blocks with `type == "tool_result"`, keyed by
  `tool_use_id`, valued by `is_error`.
- **Tool `input` is never read into any type.** The extractor has no field
  that can hold it — enforcement is structural, not testimonial.

### 4.2 Tool names are model-authored — shape-gate them

`tool_use.name` comes straight from the provider response with no validation
(`Anthropic.hs:169-171` → `OpName <$> o .: "name"`), and the transcript
rewriter re-emits it verbatim with `fromMaybe ""` (`Transcript.hs:619-624`).
Rendering it unbounded and unfiltered would let a model put arbitrary content
into a trusted-looking `📔 Tab b` block, spoofing opcode identity.

```haskell
safeOpLabel :: Text -> Maybe Text   -- Nothing ⇒ render "(unknown opcode)"
```

Accept only `[A-Z][A-Z0-9_]{0,31}`. This is the shape every real opcode name
has (`SHELL_EXEC`, `FILE_READ`, `AGENT_DEF_LIST`, …) and rejects whitespace,
newlines, JSON, paths, URLs, and keys. Anything rejected renders as the fixed
string `(unknown opcode)` — never the raw name.

**Residual risk, stated:** this is a *shape* gate, not an allowlist against the
opcode registry. A model can still emit a name that satisfies the shape —
including impersonating a real one like `SECRET_MANAGE`. It stops content
injection (JSON, paths, keys, multi-line text); it does **not** stop a model
from lying about which opcode ran. Validating against the registry is possible
but would still not be authentication, since the name is model-authored either
way. Rendering an opcode's name is not itself a new disclosure: the live chat
tool line already prints model-authored names via `handleToolCallActivity`
(`Loop.hs:1591`).

### 4.3 Legacy `transcript.jsonl` sessions (E20)

`teLineToFrontend`'s payload is the old `CompletionRequest`/`CompletionResponse`
encoding, whose content blocks carry **no `type` key** in the shape
`extractEntry` expects (the rewrite exists precisely for that: the legacy path
uses the verbatim on-disk line, `Transcript.hs:222`). A naive extractor finds
no text and reports `LastEmpty` — "no messages yet" for a session that plainly
has messages.

Rule: when `/api/sessions/:id/transcript` yields entries whose `payload` has
neither a `content` nor a `messages` key, that is a **legacy** transcript.
`resolveLast` then yields `LastEmpty` only if there genuinely are no
`direction:"response"` entries; otherwise it renders

```
📔 Tab b (title) — last message:

(this transcript predates the current format — open it in the web UI)
```

Detected by `isLegacyPayload :: Value -> Bool`, pure and tested. This is
deliberately **not** an attempt to parse the legacy shape: the web frontend is
out of scope and a second parser here would be a maintenance trap.

---

## 5. `Seal.Channels.Chat.LastRender` — complete API

A pure leaf module beside `TabRender` / `ToolRender` / `Bubble`. Every
user-visible byte is produced here.

### 5.0 `ResolveInput` (defined)

```haskell
data ResolveInput = ResolveInput
  { lriHeading   :: TabHeading            -- ^ always resolved (§6.1: E12)
  , lriItems     :: [AssistantItem]       -- ^ chronological, oldest first
  , lriThinking  :: Bool
  , lriQuestion  :: Maybe PendingQuestion
  , lriCount     :: Int                   -- ^ requested n, already clamped 1..5
  , lriLegacy    :: Bool                  -- ^ §4.3
  } deriving stock (Eq)   -- E3: NO Show (holds AssistantItem/PendingQuestion,
                          -- which have none — Show here would not compile)
```

Constructed in `handleLast` from the three fetches.

### 5.0.1 `EntryFacts` — the boundary type (D10)

The seam between transcript JSON and `AssistantItem`. It is defined here
because it is the only place a tool input could enter, so it must have no
field capable of holding one.

```haskell
data EntryFacts = EntryFacts
  { lefText    :: Text                -- ^ response text blocks, joined "\n\n"
  , lefTools   :: [ToolName]          -- ^ tool_use blocks: name only, no input
  , lefResults :: [(Text, Bool)]      -- ^ (tool_use_id, is_error) from requests
  } deriving stock (Eq)

newtype ToolName = ToolName Text
  deriving stock (Eq)
```

Deliberately absent: `input`, `parts`, `system`, `result`, `thinking`. The
`Eq`-only derivation is the guard (§5.2).

### 5.1 Arguments

```haskell
data LastArgs = LastArgs
  { laTab   :: Maybe TabIndex
  , laCount :: Int               -- ^ clamped to 1..5
  } deriving stock (Eq, Show)

data LastError
  = LENoSuchTab Text
  | LEBadCount Text
  | LENoSession Char
  | LENoCurrentTab
  | LETabs Text                  -- ^ /api/lists failed
  | LETranscript Char            -- ^ transcript fetch failed
  | LEQuestions Char             -- ^ questions fetch failed
  deriving stock (Eq, Show)

parseLastArgs  :: Text -> Either LastError LastArgs
renderLastError :: LastError -> Text
isLastHelpArg  :: Text -> Bool
lastHelp       :: Text
```

`LastError` earns a bespoke ADT: `renderLastError` pattern-matches it to
produce seven distinct strings, and §8 tests each constructor.

### 5.2 Items and state

```haskell
data ToolState = LtsOk | LtsFailed | LtsUnfinished
  deriving stock (Eq, Show)      -- no content; Show is safe

data ToolOutcome = ToolOutcome
  { lsaName  :: Maybe Text   -- ^ 'safeOpLabel' result; Nothing ⇒ "(unknown opcode)"
  , lsaState :: !ToolState
  } deriving stock (Eq)      -- D9: NO Show (guard against show-based logging)

data AssistantItem
  = LriText Text                 -- ^ a response's text blocks, joined (§5.6.1)
  | LriToolOnly ToolOutcome      -- ^ a response with no text
  deriving stock (Eq)            -- D9: NO Show
```

`ToolState` is tri-state because it is rendered in two places with different
needs: `LastWorking` wants the last **completed** tool (`LtsOk`/`LtsFailed`),
while a tool-only response must still name what ran even when unfinished
(DoD 2). A `Bool` cannot express that.

**`(failed)` is emitted at every site** where a `ToolOutcome` is rendered and
`lsaState == LtsFailed`; `LtsUnfinished` renders a bare name (no suffix);
`LtsOk` renders a bare name. This is one rule for all three render sites.

### 5.3 View

```haskell
data TabHeading = TabHeading
  { lthIndex :: TabIndex
  , lthTitle :: Maybe Text   -- ^ content-bearing (may be a user snippet)
  } deriving stock (Eq)      -- E17: NO Show (lthTitle is content; §6.1 forbids
                             -- logging it, and Show would permit it)

data PendingQuestion = PendingQuestion
  { lqText    :: Text
  , lqOptions :: [QuestionOption]   -- ^ reuse 'Bubble.QuestionOption'
  } deriving stock (Eq)             -- D9: NO Show (holds question text)
-- D4: no lqIsGate. A gate ask and an open-ended ask are indistinguishable on
-- the wire: both have zero options (AskReply.hs:397) and the gate passes
-- meta = Nothing (AskReply.hs:386), so /questions carries no discriminator
-- (API.hs:3259-3262). One neutral footer serves both.

data LastView
  = LastMessages TabHeading [AssistantItem]
  | LastQuestion TabHeading PendingQuestion
  | LastWorking  TabHeading (Maybe ToolOutcome)
  | LastEmpty    TabHeading
  deriving stock (Eq)             -- D9: NO Show
```

`LastMessages` carries no count — the heading number is `length items`
(§5.6.1), so a short window cannot make the heading lie.

### 5.4 Resolution

```haskell
resolveLast :: ResolveInput -> LastView
```

Precedence, and why:

1. **question** → `LastQuestion`. Most actionable, and a blocked turn is also
   `thinking`, so it must win or it is unreachable.
2. **thinking** → `LastWorking`, with the last *completed* tool.
3. **any items** → `LastMessages` (newest `lriCount`).
4. otherwise → `LastEmpty`.

A failed `/api/lists` yields `Left LETabs` in `handleLast`, so the
`thinking` probe can never fail *open* into `LastMessages` — satisfying §5.1's
invariant "a working tab must never imply it finished".

### 5.5 Questions — rendered, answered with `/b <n>`

**Operator decision (2026-11-26):** `/last` shows the question and its
options; the user answers with `/N <answer>`. `/last` must never change the
focused tab.

That is the existing inject path, and it works:

- `/last b` renders tab `b`'s pending question + options (`/last` is a read).
- `/b 1` routes to `handleInject` → `POST /api/sessions/:id/send` for **tab
  b's** session (`Loop.hs:583-607`). `handleSend` offers the text to *that
  session's* pending ask through `deliverNextAnswerResolvedId` before starting
  any turn (`Send.hs:633-641`), and a numeric body resolves to that option's
  label. So `/b 1` answers tab `b` from tab `a`.
- `handleInject` deliberately does **no** `sessionInsert`, `FocusOp`, or
  `ensureWsConn` (`Loop.hs:583-607`), so focus is untouched.

Why not "reply with a plain message"? Because it is false, and it misroutes:
a plain reply reaches `answerPendingBgAsk` (`Loop.hs:1960-1994`), which
considers only this conversation's `bg` sessions plus asks the `/watch` path
registered (`paWatched`, set solely by `registerWatchedAsk` on a watch-mode
idle transition). With watch off, tab `b`'s question is never registered, the
reply falls through to `sendPlain` → the **focused** tab, and if that session
has its own pending ask, the gateway answers *that* one (`Send.hs:637`,
oldest-pending). So the rendered hint is `/b <n>`, never "reply to answer".

**The confirmation-gate prompt.** The gate builds
`"Allow " <> opName <> " " <> A.encode input <> "? [y/N] "`
(`Agent/Loop.hs:741-743`) and that text becomes the pending question. `/last`
renders it because the operator asked for the question to be shown. This is an
**accepted risk, not a bounded one** — §10.3 gives the measured shape. In
short: for a tab that was not focused when the gate fired, `/last` is the
*first* time this text reaches the chat channel (the gate's own `ccSend` goes
to `webAskCaps`, a rate-limited WS frame — `Send.hs:770`), and a command's
argv may carry a credential.

**Render.** `formatAsk` is **not** reusable here: it hardcodes
`Reply with a number or type your own answer.` (`Bubble.hs:70-75`), which is
exactly the misrouting instruction this section refutes. So the hint is split
out (`Bubble.hs`):

```haskell
-- question + numbered options, no hint. Byte-identical to formatAsk minus
-- its trailing hint.
formatQuestionBody :: Text -> [QuestionOption] -> Text
formatQuestionBody question [] =
  question
formatQuestionBody question opts =
  question <> "\n\n" <> T.intercalate "\n" (zipWith formatOption [1 :: Int ..] opts)

-- The hint carries its own leading "\n\n", so the concatenation is
-- byte-identical to today's formatAsk. Verified against Bubble.hs:70-75:
--   []   -> "\n\nReply with your answer."
--   opts -> "\n\nReply with a number or type your own answer."
liveAskHint :: [QuestionOption] -> Text
liveAskHint []   = "\n\nReply with your answer."
liveAskHint opts = "\n\nReply with a number or type your own answer."

formatAsk question os = formatQuestionBody question os <> liveAskHint os
```

`formatAsk`'s output is unchanged **byte for byte** (`handleAsk`,
`Loop.hs:1639-1649`), so live asks are untouched — that equality is itself a
test (§8.1). `/last` uses `formatQuestionBody` **only**, and the `> ` quoting
is applied by `renderLast` to each line of `formatQuestionBody`'s output (not
inside `formatQuestionBody`), so `lastHelp`/live asks are unaffected.

```
📔 Tab b (fix the flaky test) — waiting on your answer:

> Which database should I use?
>
> 1) Postgres — existing cluster
> 2) SQLite — single file

Answer with /b 1 or /b <your answer>.
```

**Exact quoting rule (E8).** The prose "`> ` on every line" and the example
(a bare `>` on blank lines) are two different byte sequences. The definition:

```haskell
quoteBody :: Text -> Text
quoteBody t =
  T.intercalate "\n" [ if T.null l then ">" else "> " <> l | l <- T.lines (normalizeNewlines t) ]

normalizeNewlines :: Text -> Text   -- \r, U+0085, U+2028, U+2029 -> \n
```

Blank lines become a bare `>` (**no trailing space**); non-blank lines get
`"> "`. Line separators other than `\n` are normalised **before** prefixing,
because U+2028/U+2029 and `\r` render as line breaks but would otherwise be
skipped by `T.lines` and thus escape the quote.

**The question body is block-quoted.** Model-authored text can contain its own
`📔 Tab a (main) — last message:` heading or an `Answer with /b …` footer
(D11); prefixing every line with `> ` means it can never align with the
`📔` heading column or be mistaken for harness-authored output. The footer is
emitted by the harness, outside the quote.

**One footer for both ask kinds** (D4): the gate and an open-ended ask are
indistinguishable on the wire, so there is no gate-specific
`/b yes` / `/b no` variant. The options list, when present, shows the user
which numbers exist; when absent, `/b <your answer>` is correct for both.

The footer **must** use the actual tab char (`/b 1`, not a literal `b`).

### 5.6 Rendering

```haskell
renderLast :: LastView -> Text
resolveLast :: ResolveInput -> LastView
entryFetchLimit :: Int -> Int
extractEntry :: Value -> EntryFacts
assistantItems :: [Value] -> [AssistantItem]   -- pairs text + tool facts
safeOpLabel :: Text -> Maybe Text
transcriptUrl :: Text -> SessionId -> Int -> String  -- pure; the ?limit= rule lives here

-- structural projections (D9: no Show on the view types, so tests and any
-- caller that needs to branch without rendering use these)
viewTag        :: LastView -> Text             -- "messages"|"question"|"working"|"empty"
renderedTools  :: LastView -> [Text]           -- tool lines, in order
```

#### 5.6.1 One heading/body contract

> A heading ends with `:` iff a body follows, and a body follows after
> exactly one `\n\n`. A heading with no body ends with `.`.

| View | Heading | Body |
|---|---|---|
| `LastMessages`, 1 item | `📔 Tab b (title) — last message:` | the item |
| `LastMessages`, k>1 items | `📔 Tab b (title) — last k messages:` | items joined `\n\n` |
| `LastWorking (Just t)` | `📔 Tab b (title) — still working:` | `last completed: <tool line>` |
| `LastWorking Nothing` | `📔 Tab b (title) — still working:` | `no tools have completed yet` (D6) |
| `LastQuestion q` | `📔 Tab b (title) — waiting on your answer:` | `formatQuestionBody` block-quoted + `/b` footer (§5.5) |
| `LastEmpty` | `📔 Tab b (title) — no messages yet.` | — (no body) |
| `LastMessages _ []` | render as `LastEmpty` (E10) | — |

`k` is `length items` — never the requested `n`. Tab label is the canonical
lowercase char (`tabIndexToChar`), so `/last B` renders `Tab b`.
Title is omitted (`📔 Tab b`) when `lthTitle` is `Nothing`.

**Tool line — three explicit rows** (D7). One function, used at all three
render sites (`LastMessages`, `LastWorking`, §6.3):

| `lsaState` | Rendered |
|---|---|
| `LtsOk` | `💻 SHELL_EXEC` |
| `LtsFailed` | `💻 SHELL_EXEC (failed)` |
| `LtsUnfinished` | `💻 SHELL_EXEC (no result)` |

`LtsUnfinished` **must** differ from `LtsOk`: it means "no `tool_result` in
the window", i.e. *unknown*, and rendering it bare would silently assert
success — DoD 2 requires the pass/fail, so "unknown" is stated. `lsaName
Nothing` renders as `⚡ (unknown opcode)` (D8: `opEmoji`'s fallback glyph).

**Item rendering, uniformly** (single-item and multi-item are the same rule):

- `LriText t` → `t`, where `t` is the response's `text` blocks joined with
  `"\n\n"` (**not** `T.concat` — `extractEntryText`'s behaviour at
  `Loop.hs:2163-2172` would run paragraphs together and must not be
  inherited).
- `LriToolOnly o` → `<tool line> — no reply text.`
- An item that is neither (empty text, no tool) is **dropped**; if every item
  drops, the view degrades to `LastEmpty`.

**The `for more` hint — `LastMessages` only** (D12). It cannot apply to
`LastWorking`/`LastQuestion`, which carry no item list.

- Appended once, after the whole block, as `<> " " <> hint`.
- Emitted iff the block contains **no `LriText` at all** **and the fetch window
  was saturated** — i.e. `length lriItems == lriCount`, so more may exist
  (E9). A tab with 3 tool-only responses answers `/last b 1` with *2 more
  may exist*, and `/last b 5` with no hint, because 3 < 5 means it exhausted
  what there is. Without saturation the hint repeats forever, which is the
  dead end D13 exists to avoid.
- Hint text when saturated: the **fixed literal** `/last <c> 5 for more.`
  (matching the requirements' own example). Rev 2 used `min 5 (2*k)`, which
  produced `/last b 2` for `k=1` and contradicted the requirements.
  If `k == 5` and still no text: `/b to switch to that tab.`

#### 5.6.2 Size policy

**No truncation** (E13). An earlier revision capped each `LriText` at 1500
characters and pointed at `/b` for the rest. That pointer was false: `/b`
renders through the same `renderLast`, so it would show the identical
truncated text — a dead end that also costs the user their focus for nothing.
The requirements already specify the right behaviour ("the message splitting
each platform already does for long messages"), and `ccSend` chunks on both
channels (`Telegram.hs:224-225`, `Signal.hs:451-452`).

The residual concern was a notification storm from `n = 5` long replies. That
is bounded instead by the count clamp (`n ≤ 5`) and §5.6.3's per-item
attribution, which keeps a multi-chunk reply readable. If a size cap is ever
wanted, it must come with a path to the full text — i.e. not this feature.

1500 is a **code-point** budget, not a byte budget. Telegram counts UTF-16
units (`Telegram.hs:287-289`) and Signal counts UTF-8 bytes
(`Signal.hs:483-486`), so 1500 code points can be several platform chunks for
emoji/CJK text. `chunkMessage` handles that safely; the cap bounds the
*typical* case, not the worst case, and that is stated rather than claimed
away.

#### 5.6.3 Chunked replies keep their attribution

`ccSend` chunks (Telegram 3900 UTF-16 units, `Telegram.hs:224-225`; Signal
~2048 bytes, `Signal.hs:451-452`), so chunks 2..n would otherwise carry no tab
context, violating "every reply names the tab it came from".

**Rule:** when `length items > 1`, each item is prefixed `<c>: ` — actual tab
char, no brackets (E16). A chunk boundary then lands inside or between
prefixed items. Single-item blocks rely on the heading.

Why not `[b] `: neither channel sends with `parse_mode` (Telegram's payload
carries only `chat_id`/`text`, `Telegram.hs:626-648`; the rule is stated at
`:710`), so brackets render literally and read as broken markdown — in the one
message whose credibility depends on looking harness-authored. `b: ` uses the
same vocabulary the heading and `/b` already use, and it is documented in
`lastHelp`.

**Residual:** a boundary *inside* a long single item still leaves chunks 2..n
of that item unattributed. Only the between-items case is fixed, and that is
stated rather than claimed away.

### 5.7 Error text

Consistent with the existing `focus failed: …` / `inject failed: …` /
`tab list failed: …` family (`Loop.hs:551`, `:588`, `:2263`).

| Constructor | Rendered |
|---|---|
| `LENoSuchTab z` | `last failed: no such tab z — /tab list` |
| `LEBadCount t` | `last failed: "<t>" isn't a number — use /last <tab> 1-5` |
| `LENoSession b` | `last failed: tab b has no session (harness tab) — /tab list` |
| `LENoCurrentTab` | `last failed: no current tab — send a message to start one` |
| `LETabs e` | `last failed: couldn't read the tab list — try again in a moment` |
| `LETranscript b` | `last failed: couldn't read tab b's transcript — try again in a moment` |
| `LEQuestions b` | `last failed: couldn't read tab b's question — try again in a moment` |

The underlying `e` is **logged**, never rendered (it can carry a gateway URL).

**Echoed user text is bounded and flattened** (E14). `LEBadCount t` and
`LENoSuchTab z` interpolate raw inbound text, which can be thousands of
characters and can contain `\n` — letting a user spoof a harness heading in
the reply, by the same argument D11 uses for question text. Both go through

```haskell
singleLine :: Text -> Text    -- \n/\r/\t -> space, collapse runs, T.take 16 <> "…" when elided
```

so the longest possible echo is 17 characters and cannot start a new line.

---

## 6. Wiring in the loop

### 6.1 `handleLast`

```haskell
handleLast
  :: ChatChannel c
  => ChatChannelConfig -> c -> Maybe SessionId   -- ^ the focused session, resolved by the CALLER
  -> ConversationKey -> Text          -- ^ raw args (ChatLast payload)
  -> IO ()
```

**P6 correction (plan review).** An earlier revision took `LastCooldowns` and
omitted `SessionMap`, while the flow required `sessionLookup` for bare `/last`
— and `sessionLookup :: SessionMap -> ConversationKey -> IO (Maybe SessionId)`
(`Types.hs:111`), so bare `/last` was unbuildable. `handleInboundWithSource`
already holds `sessions` (`Loop.hs:458-530`), so it resolves the focused
session and passes `Maybe SessionId`. The DoD-4 guarantee is unchanged in
substance: `handleLast` gets no *handle it could write through*.

**Signature is the DoD-4 guarantee**: `SessionMap` and `wsConns` are not
parameters, so `handleLast` *cannot* insert a session or start a WS client.
The negative requirement is enforced by the type, not by discipline.

**`PendingAsks` and `ThinkingTabs` are deliberately absent** (E11). The flow
reads questions from `cccGetQuestions` and thinking from
`ljThinkingSessionIds`, so neither was used — and under `-Werror` an unused
argument binder is `-Wunused-matches`. Passing `PendingAsks` would also
re-widen what this signature exists to forbid: with it, `handleLast` could
call `registerWatchedAsk` and manufacture answer authority. Dropping it makes
that impossible by construction.

**No cooldown, no cache (P1, plan review).** An earlier revision added a
`LastCooldowns` TVar and a `ListsCache` for `/api/lists`. Both were
**deleted**: the requirements list command rate limiting as *out of scope*,
and `handleTabList` already calls `cccGetLists` per invocation with no cache
(`Loop.hs:2261`), so `/last` adds no new amplification pattern. Follow-up #5
is the single home for rate limiting.

**`lriHeading` is always resolved** (E12). A tab close clears `tabTracker` but
**not** `SessionMap` (`Loop.hs:2060-2071`), so a focused session can outlive
its tab. Rather than carry a `Maybe TabHeading` with no render row, `handleLast`
resolves the heading first and returns `Left LENoCurrentTab` when the focused
session has no tab in `ljTabs`; `ResolveInput`'s `lriHeading` is therefore
`TabHeading`, not `Maybe`.

Flow (three gateway calls, E5):

1. `isLastHelpArg` → `lastHelp`; else `parseLastArgs`
2. `cccGetLists` → `ljTabs` + `ljTabSessions` + `ljThinkingSessionIds`
3. resolve the tab from `ljTabs` (explicit char, or `sessionLookup` then match
   `tjSessionId` for bare `/last`); no tab ⇒ `Left LENoCurrentTab` (E12)
4. `cccGetTranscript` (capped) and `cccGetQuestions`
5. `resolveLast` → `ccSend chan (renderLast view)`

No `sessionInsert`, no `FocusOp`, no `ensureWsConn`. `dbg` logs **only** the
tab char, counts, and which view was chosen — **never** item text, question
text, or the title (`dbg ("received: " <> body)` at `Loop.hs:425` is already
an existing exposure; this must not add another).

`LastView` / `AssistantItem` / `ToolOutcome` / `PendingQuestion` derive `Eq`
but **not** `Show` (D9), so a future `show`-based log is a compile error rather
than a leak. Tests compare rendered `Text`, which is what the goldens assert
anyway.

**Cooldown (D15).** A per-conversation timestamp gates `/last` to at most one
invocation per **2 seconds**, reusing the existing `RateLimit` config shape.
Without it, `/last` is strictly more attractive to spam than `/b`: same
information, no destructive focus change, and each invocation pays the
`/api/lists` scan. This is a local mitigation and does not touch the
global command-rate-limit gap the requirements leave out of scope.

**Disclosure trace (D18/E18).** Transcript reads are unaudited today, so a
`/last` that discloses another tab's content would leave no trace. Each
invocation emits **one** structured line on the existing `dbg` channel:
`[last] conv=<key> tab=<c> view=<messages|working|question|empty> question=<bool>`
— tab char, view, and a boolean only; **never** item text, question text, or
the title.

### 6.2 `/<tab>` focus — four decisions

`handleFocus` sends `focused tab b` then `sendLastReply` **today**
(`Loop.hs:568-570`), and `sendLastReply` sends **nothing** when the fetch fails
or the text is empty (`Loop.hs:1839-1848`). It becomes: `focused tab b`, then
`renderLast view`.

| Case | Decision | Why |
|---|---|---|
| `LastMessages` / `LastWorking` | **rendered** | the requirement's "`/b` ends with the same block" |
| `LastQuestion` | **rendered** (D5) | see below — the premise for suppressing it was false |
| `LastEmpty` | **suppressed** | matches today's silence; an empty tab should not cost a notification |
| fetch failure | **suppressed** | the focus succeeded; a trailing `last failed:` reads as a failed focus. Today is silent |

**Why `LastQuestion` must render.** Suppressing it assumed the ask "already
reached the user via `handleAsk`". It did not: `SeAsk` acts only when
`sid == focusedSid` (`Loop.hs:880`), and focus re-targets the subscriber and
replays **transcript entries only** — `foSince` → `replayEntriesSince`
(`Stream.hs:264-265`), no ask replay. So for the exact flow `/last` serves
(user on `a`, tab `b` blocks, ask filtered out), focusing `b` would land the
user on a blocked tab holding a write lock with **nothing** telling them what
it wants. That is the DoD-5 failure mode. The duplication when the tab *was*
already focused is benign; a silently blocked tab is not.

`sendLastReply` is deleted (verified: one caller, `Loop.hs:570`; not exported).
The haddocks at `Loop.hs:531-534` ("optionally send the last assistant reply")
and `Loop.hs:574-578` are updated — the latter currently claims `handleInject`
sends a last reply, which it never did.

### 6.3 `/watch` notification

`sendWatchNotification` (`Loop.hs:1126-1164`) gains a body whenever the turn
produced no text. **Separator is a single `\n`** (matching the existing
`header <> ":\n" <> reply`, `Loop.hs:1164`) — **not** §5.6.1's `\n\n`; this is
a different message and 12 existing `LoopSpec` assertions pin its shape.

Body, by what the turn produced (DoD 3 is unconditional — D16):

| Turn produced | Body |
|---|---|
| text | unchanged, byte for byte: `header <> ":\n" <> reply` |
| no text, a tool | `<tool line>` per §5.6.1's 3-row table |
| no text, no tool | `no reply and no tool ran — /last <c>` |

The empty-empty case (provider failure, aborted turn, gate rejected before
dispatch) previously produced a bodyless notification, which the requirements
forbid unconditionally.

**Which tool (E15).** "No text, a tool" means the **newest `AssistantItem` is
`LriToolOnly`** — not "the last completed tool". A turn that *finished* on a
tool call has its `tool_result` in a trailing conversation entry, and the join
must look there (§3.2), so the correct render is `LtsOk`/`LtsFailed`, **never**
`LtsUnfinished`. `LtsUnfinished` here would falsely say the result is missing
for a turn that completed. Test: a turn ending on a failed tool notifies
`💻 SHELL_EXEC (failed)`, not `(no result)`.

**The body, when text exists,** still comes from `lastAssistantText`
(`Loop.hs:2234-2244`, `T.concat`) — unchanged, so the 12 pinned `LoopSpec`
assertions hold. `assistantItems` is consulted only when there is no text, to
decide which tool line to emit. Stated explicitly because `assistantItems`
joins with `"\n\n"` (§4.1) and `lastAssistantText` uses `T.concat`; the two
must not be swapped.

**The watch question path keeps `formatAsk` (corrected in plan rev 3).** An
earlier revision proposed replacing `formatAsk` with §5.5's `/b` footer here.
**That was a regression.** `notifyWatchCompletion` calls
`registerWatchedAsk pendingAsks sid q` (`Loop.hs:1042`) *before* `ccSend`
(`:1044`), and `answerPendingBgAsk` explicitly includes those asks
(`watched = [ … | ask <- filter paWatched asks ]`, `Loop.hs:1969-1976`). So on
the watch path a **plain reply does answer**, and `formatAsk`'s "Reply with a
number or type your own answer" is **correct**. Swapping in `/b` would tell the
user to type a longer command that resolves to the same thing — a behaviour
change to a working, shipped surface, on no DoD.

Block-quoting here is separately defensible (D11's spoofing argument applies),
but it is **not** part of this work: it would change live `/watch` output and
require updates to 12 existing `LoopSpec` assertions for no requirement. Filed,
not done.

When `sendWatchNotification` needs "did this turn produce text", it uses the
new `assistantItems` extractor. `lastAssistantText` (`Loop.hs:2234-2244`,
tested at `LoopSpec.hs:1446-1462`) survives for the `bg` path
(`handleBgServerEvent`), so no dead code.

### 6.4 The `/b <n>` failure branch (E2)

`/last` teaches `/b <n>` as *the* answer path, so the "it didn't land" case
must be specified. Today it is silent **and** harmful: `handleInject` does

```haskell
Right sr | not (T.null (srResponse sr)) -> ccSend chan (srResponse sr)
Right _ -> pure ()   -- Loop.hs:606
```

`SendAnswer` produces `{"kind":"answer","response":"✓ <label>"}`
(`Send.hs:542-546`), but if the pending ask is gone (timed out, answered in
the web UI, turn aborted) `deliverNextAnswerResolvedId` returns `Nothing`
(`AskReply.hs:567`) and `handleSend` **falls through to `startPlainTurn`**
(`Send.hs:641-645`): the literal `"1"` is written into tab b's transcript as
a *user message* and a real turn starts there — while the user sees nothing
at all, because `SendAssistant`'s `response` is `""` (`Send.hs:538`).

That is a silent misroute plus an unintended write into another tab: exactly
the defect §5.5 exists to eliminate, reached through the path §5.5 now
teaches.

**Specification.** `handleInject` branches on `srKind`:

| `srKind` | Meaning | Action |
|---|---|---|
| `"answer"` | the text answered tab `<c>`'s pending question | `ccSend chan ("✓ [" <> tab <> "] " <> label)` — **attribute the tab**, so a user with two blocked tabs knows which was answered |
| `"slash"` / `"assistant"` with a non-empty response | a real turn or slash output | unchanged (send `srResponse`) |
| `"assistant"` with an **empty** response, answer-shaped payload | no pending question existed; a turn was started with the literal text | `ccSend chan ("/last " <> tab <> " has no question waiting — that message started a new turn")` — honest, and the user learns the ask expired |
| `"error"` | — | unchanged |

"Answer-shaped payload" = the payload is short and has no whitespace
(`isAnswerShaped`, pure, tested): a bare number, `yes`, `no`. That predicate is
deliberately narrow — a *real* prompt with no reply yet is also `assistant`
with an empty response, and must stay silent as today.

**Note the residual:** the literal `"1"` still reaches tab b's transcript,
because the gateway decides to start a turn *before* the channel can react.
Fixing that belongs to `/send` (offer-then-start is a gateway decision);
§6.4 makes it **visible** rather than silent. Filed as a follow-up.

---

## 7. Wiring checklist (module + spec registration)

### 7.1 Registration — mandatory, or the tests silently never run

This repo has **no hspec-discover**; an unregistered spec compiles into nothing
and the suite stays green (a documented lesson:
`docs/learnings/2026-10-26-chat-slash-command-parity-learnings.md` §1).

1. `seal-harness.cabal` library `exposed-modules` — add
   `Seal.Channels.Chat.LastRender` beside `TabRender`/`ToolRender` (list at
   `:81-93`).
2. `seal-harness.cabal` test-suite `other-modules` —
   `Seal.Channels.Chat.LastRenderSpec` (list at `:572-584`).
3. `test/Main.hs` — the `import qualified` block (`:122-134`) **and** the
   `spec` list (`:355-367`). Both halves.
4. No new `build-depends` needed (`text`, `aeson`, `vector`,
   `seal-gateway-types` are already present).

### 7.2 Files touched

| File | Work |
|---|---|
| `src-chat-channels/Seal/Channels/Chat/LastRender.hs` | new |
| `src-chat-channels/Seal/Channels/Chat/Route.hs` | `ChatLast Text` + arm |
| `src-chat-channels/Seal/Channels/Chat/Loop.hs` | `handleLast`, seams, `handleFocus`, `handleWatch…`, delete `sendLastReply` |
| `src-chat-channels/Seal/Channels/Chat/HttpClient.hs` | `httpGetTranscriptLimited` |
| `src-chat-channels/Seal/Channels/Chat/TelegramCommands.hs` | menu entry |
| `src-chat-channels/Seal/Channels/Chat/Bubble.hs` | `formatQuestionBody` split (D1) |
| `src/Seal/Gateway/Transcript.hs` | fallback discriminator (E1) |
| `src-chat-channels/Seal/Channels/Chat/TabRender.hs` | export `nameOf` (§6.1 title resolution) |
| `seal-harness.cabal`, `test/Main.hs` | registration |
| `test/.../LastRenderSpec.hs` | new |
| `test/.../RouteSpec.hs`, `LoopSpec.hs`, `TelegramCommandsSpec.hs`, `HttpClientSpec.hs` | extended |

---

## 8. Test plan (TDD, RED first)

**RED mechanics under `-Wall -Werror`.** A new module cannot both compile and
fail, and `error`/`undefined` are banned. Every function starts as a stub
returning a fixed wrong value (`renderLast _ = ""`,
`resolveLast _ = LastEmpty (TabHeading …)`), so the golden tests fail on
assertion, not on a compile error.

The stub shape is **`_`-patterned with a concrete result of the right type**,
which sidesteps all three `-Werror` traps: `-Wunused-matches` (no named
binder), `-Wpartial-fields` (no record selected), and hlint's `Use const`
(no `const` introduced). A stub must never be `undefined`/`error`, and never a
record with a missing field (that is `-Wpartial-fields`).

The one unavoidable RED is a **new constructor**: adding `ChatLast` to
`ChatRoute` makes `handleInboundWithSource`'s `case route body of` incomplete
(`Loop.hs:489-530`), so WU-1 must land the dispatch arm in the same commit —
the arm is a one-line `Right (ChatLast args) -> handleLast …` stub that sends
`""`. That is ordered: WU-1 adds the constructor + arm, WU-2 fills the
behaviour.

### 8.1 `LastRenderSpec` (pure)

**Assertion rule (D9 consequence).** `LastView` / `AssistantItem` /
`ToolOutcome` / `PendingQuestion` have no `Show`, so hspec's `shouldBe` cannot
compare them (its failure message needs `Show`). Every structural assertion is
therefore made **through `renderLast` on `Text`**, or through a small pure
projection the module exports for exactly that purpose:

```haskell
viewTag        :: LastView -> Text              -- "messages" | "question" | "working" | "empty"
renderedTools  :: LastView -> [Text]            -- the tool lines, in order
```

Both are cheap, pure, and carry no content (`viewTag` returns a fixed tag;
`renderedTools` returns the already-rendered tool lines). Tests assert e.g.
`viewTag (resolveLast inp) `shouldBe` "working"` and
`renderedTools (resolveLast inp) `shouldBe` ["💻 SHELL_EXEC (no result)"]`.
`LastArgs` / `LastError` / `ToolState` / `TabHeading` keep `Show`, so those
compare directly.

| Test | RED stub |
|---|---|
| `parseLastArgs`: every row of §2.2 (12 cases) | returns `Right (LastArgs Nothing 1)` |
| `resolveLast` precedence: question > thinking > messages > empty | returns `LastEmpty` |
| `resolveLast`: thinking with no completed tool → `viewTag` = `"working"`, `renderedTools` = `[]` | `""` |
| `extractEntry`: `type:"thinking"` dropped | returns `[]` |
| `extractEntry`: unknown block `type` dropped (**not** rendered as text) | — |
| `extractEntry`: `direction:"request"` contributes no text | — |
| `extractEntry`: text blocks joined `"\n\n"` (not `T.concat`) | — |
| `safeOpLabel`: accepts `SHELL_EXEC`, `AGENT_DEF_LIST` | — |
| `safeOpLabel`: rejects `lower`, `has space`, `{"json":1}`, 200-char, `A/B` | returns `Just` |
| tool join: `is_error:true` ⇒ `LtsFailed`; missing result ⇒ `LtsUnfinished`; `false` ⇒ `LtsOk` | — |
| `renderLast`: one golden string per view per §5.6.1 (5 headings × item shapes) | `""` |
| `renderLast`: `LastQuestion` with options ⇒ `formatQuestionBody` (block-quoted) + `/b 1` footer | — |
| `renderLast`: `LastQuestion` with **no** options ⇒ same neutral `/b <your answer>` footer (D4: no gate variant) | — |
| `renderLast`: question footer uses the **actual** tab char | — |
| `renderLast`: multi-item block, mixed text + tool-only | — |
| `renderLast`: all items drop ⇒ `LastEmpty` | — |
| `renderLast`: `for more` uses the actual tab char | — |
| `renderLast`: items==5 and no text ⇒ `/b` hint, not a dead end | — |
| `renderLast`: multi-item items prefixed `b: ` | — |
| `renderLastError`: all 7 constructors | `""` |
| `entryFetchLimit`: monotone, `≥ 40`, nonzero | returns `0` |
| `lastHelp`: mentions `[tab] [n]`, the 1–5 clamp, **never changes focus**, **`/b <n>` answers** | `""` |
| `viewTag`: all four views map to their tag | returns `""` |
| `quoteBody`: blank line ⇒ bare `>` (no trailing space); non-blank ⇒ `> ` | `""` |
| `quoteBody`: U+2028 / `\r` normalised before prefixing (no unquoted line escapes) | — |
| `singleLine`: newlines flattened, capped at 16 + `…` (E14) | — |
| `isAnswerShaped`: `"1"`, `"yes"` ⇒ True; `"hello world"`, `"2 please"` ⇒ False (E2) | — |
| `isLegacyPayload`: legacy shape ⇒ True, current ⇒ False (E20) | — |
| `renderLast`: `LastMessages _ []` ⇒ `LastEmpty` bytes (E10) | — |
| `renderLast`: hint saturated ⇒ present; exhausted (`k < n`) ⇒ absent (E9) | — |
| `renderLast`: legacy view renders the §4.3 notice, not `LastEmpty` | — |
| `resolveLast` never yields `LastWorking (Just (… LtsUnfinished))` (§5.4 invariant) | — |
| `renderLast`: tool line per `ToolState` — all 3 rows differ (`LtsUnfinished` ≠ `LtsOk`) | — |
| `renderLast`: `lsaName Nothing` ⇒ `⚡ (unknown opcode)` | — |
| `renderLast`: `LastWorking Nothing` ⇒ `no tools have completed yet` | — |
| `renderLast`: question body is block-quoted (`> ` on every line) | — |
| `renderLast`: question body contains **no** `Reply with` text (D1) | — |
| `formatQuestionBody` + `liveAskHint` ≡ `formatAsk` byte for byte (D1 regression) | — |

**QuickCheck — stated at the JSON boundary so it has teeth** (a property over
`renderLast` alone would be vacuous: no `LastView` field can hold an input):

1. For arbitrary `Value` entries containing a sentinel embedded in tool
   `input`, `payload.system`, and `payload.result`: the output of
   `renderLast (resolveLast …)` over `assistantItems` **never** contains the
   sentinel. Generators bounded in depth and size.
1b. **The E1 case:** an entry whose `payload.content` carries a block with a
   `tag` **outside** the four known constructors and a sentinel inside that
   block must render **no** sentinel — i.e. the `cbToFrontend` fallback's
   discriminator change is load-bearing and this property regresses if it is
   reverted.
2. For arbitrary `Text` as `tool_use.name` containing a shape-invalid sentinel
   (whitespace/newlines/lowercase/markup), the rendered output never contains
   it — `safeOpLabel` maps it to `(unknown opcode)`.
3. `renderLast` is total: no exception for any `LastView`.

### 8.2 `LoopSpec` (behaviour)

| DoD | Test |
|---|---|
| 1 | `/last`, `/last b`, `/last b 3` send the right tab's text |
| 2 | tool-only turn ⇒ opcode name + `(failed)` when `is_error` |
| 3 | bodyless watch notification names the tool (§6.3) |
| 4 | **concrete, implementable**: pre-insert `sid` into a `SessionMap`, run `/last b`; assert `sessionLookup` still returns `sid`, and separately that a fresh map still returns `Nothing`; assert `getRecorders seams == []` (no WS client created). `SessionMap` has no `Eq` (`Types.hs:104`), so "byte-identical" is not observable — these three assertions are |
| 5 | question / working / empty render distinctly; none silent |
| 5 | `/last b` on a blocked tab renders the question + options; **`/last` alone registers no ask** (`paStore` unchanged) |
| 5 | `/b 1` after `/last b` delivers to tab **b**'s session (`smSends` records `(sid_b, "1")`) and leaves focus on `a` |
| 5 | errors: `LENoSuchTab`, `LEBadCount`, `LENoSession`, `LENoCurrentTab`, `LETabs`, `LETranscript` |
| §6.1 | `/last` with a failing lists fetch renders `LETabs`, never `LastMessages` (fail-closed) |
| §6.2 | `/b` emits the block for `LastMessages` **and `LastQuestion`** (D5); suppresses it for `LastEmpty` and fetch failure |
| §6.3 | a watch turn with no text **and** no tool names the empty case (D16) |
| §6.4 | an answer-shaped `/b` payload with an empty `assistant` response ⇒ the "no question waiting" line (E2, one branch only) |
| §6.4 | `/b 1` on success ⇒ `✓ b: <label>` (tab attributed) (E2) |
| §6.4 | a real prompt with no reply yet stays silent (regression guard) |
| §6.3 | a turn ending on a **failed** tool notifies `(failed)`, not `(no result)` (E15) |
| §6.3 | the watch question path is quoted and uses the `/b` footer (E6) |
| §6.1 | one disclosure line is emitted, containing tab char + view, and **no** item/question text (D18) |
| §2.4 | `/last -h` renders `lastHelp`, not a tab error |
| §6.1 | no `dbg` line contains item text (capture stderr, assert sentinel absent) |

### 8.3 `RouteSpec`

`/last` → `ChatLast ""`; `/last b` → `ChatLast "b"`; `/last b 3` → `ChatLast
"b 3"`; `/last b 2 junk` → `ChatLast "b 2 junk"`; **`/l` still → `ChatFocus
21`** (non-collision).

### 8.4 `TelegramCommandsSpec`

All six sites in §2.3 updated to `[help, bg, watch, last]`, plus a positive
assertion that the `last` description is exactly `"Show a tab's last message"`.

### 8.5 `HttpClientSpec`

**`HttpClientSpec` tests pure functions only** — every network-dependent test
is guarded with `pendingWith` (:4-5). So the `?limit=` rule is testable only if
the URL is a **pure function**:

```haskell
transcriptUrl :: Text -> SessionId -> Int -> String   -- pure, exported
```

Tests: `transcriptUrl base sid 40` ends with `/transcript?limit=40`; the limit
is rendered from the parsed `Int` (so `"007"` cannot survive); a `limit < 20`
is clamped by the caller before this function is reached (asserted at the
`entryFetchLimit` level). `httpGetTranscriptLimited` then becomes a thin
wrapper that cannot get the URL wrong, and needs no test — which is the point
of extracting it.

---

## 9. Work-unit decomposition

| WU | Scope | Files | Depends |
|---|---|---|---|
| WU-1 | args + route + parse | `LastRender.hs` (args half), `Route.hs`, `RouteSpec.hs`, `seal-harness.cabal`, `test/Main.hs` | — |
| WU-2 | extraction + render + resolve + `formatAsk` split | `LastRender.hs` (render half), `Bubble.hs` (`formatQuestionBody`), `LastRenderSpec.hs`, `BubbleSpec.hs` | WU-1 |
| WU-0 | **fallback discriminator** (E1) — independent, no dependency | `Gateway/Transcript.hs`, `Gateway/ApiSpec.hs` or `TranscriptSpec.hs` | — (**parallel**) |
| WU-3 | seams + loop + focus + watch + `/b` branch | `Loop.hs`, `HttpClient.hs`, `LoopSpec.hs`, `HttpClientSpec.hs` | WU-0, WU-1, WU-2 |
| WU-4 | Telegram menu | `TelegramCommands.hs`, `TelegramCommandsSpec.hs` | — (**parallel**) |

WU-1 owns the two merge hotspots (`.cabal`, `test/Main.hs`) exclusively. WU-4
and WU-0 touch neither and run in parallel with the rest.

WU-0 is `Gateway/Transcript.hs`, which is the **server** package, not
`src-chat-channels/` — so it cannot overlap any other work unit's file scope.
It must land before WU-3 because §4.1's extraction rule depends on it (E1).

---

## 10. Security posture

**Enforcement, not assertion.** Each requirement constraint maps to a
mechanism:

| Constraint | Mechanism |
|---|---|
| Never tool inputs | no `LastView`/`AssistantItem`/`ToolOutcome` field can hold an input; `extractEntry` never reads `input`. QuickCheck §8.1(1) |
| Never tool results | extraction reads only `type == "tool_result"` **id → is_error**; parts are never read |
| Never file contents / secrets | same as inputs; plus `safeOpLabel` shape gate |
| Never thinking | `type == "thinking"` explicitly dropped; no `type` fallback (§4.1) |
| Opcode **names** only | `safeOpLabel` `[A-Z][A-Z0-9_]{0,31}`, else `(unknown opcode)` |
| Question text | rendered **only** for a currently-blocked tab's pending question; **block-quoted** so it cannot spoof harness structure; never historical. Accepted risk §10.3 |
| No secrets in logs | `dbg` logs tab char/counts/view only; `LastView`/`AssistantItem`/`ToolOutcome`/`PendingQuestion` have **no `Show`** (§5.2, D9) |
| Disclosure traceable | every `/last` emits one structured line (conversation key + tab + view + whether a question was shown) — §6.1. **Trace, not audit**: `dbg` is `hPutStrLn stderr` (`Loop.hs:403`), which is not persisted. Writing it to the audit log is a follow-up |

### 10.1 Cross-conversation reads — rebuttal

**For assistant text, the gap is not widened.** `handleFocus` already calls
`sendLastReply` (`Loop.hs:568-570`), which already fetches and sends another
tab's last assistant reply. `/last` introduces no new assistant-text
capability — it makes an existing one usable (`/tab`-addressable,
count-limited, honestly rendered) instead of requiring a destructive focus
change.

**For question text, it is** — see §10.2. The requirements' "neither fixes nor
worsens" holds for the first category and must be read as narrowed for the
second.

### 10.2 What `/last` reads that is genuinely new (D3)

`/last` introduces **no new capability for assistant text**: `handleFocus`
already calls `sendLastReply` (`Loop.hs:568-570`), which already fetches and
sends another tab's last assistant reply. Verified.

It **does** introduce one genuinely new read: **pending-question text**.
`sendLastReply` reads only `lastAssistantText`; `handleFocus` never calls
`/api/sessions/:id/questions`.

Not *the first* such path, though (E6): `notifyWatchCompletion` already sends
a non-focused tab's pending question to the channel
(`Loop.hs:1042`). `/last` is the first **on-demand, tab-addressable** path —
any tab's question, on request, rather than pushed on a watch-on idle. §6.3
extends §5.5's quoting and footer to that watch path so both renderings are
consistent.

### 10.2.1 A write under `~/.seal/state`, disclosed (E19)

`/last` is described throughout as "a read", and for agent-visible state that
is true — it writes no session, no focus, no watch state. But the transcript
read calls `ensureIndex` (`Transcript.hs:258`), which **builds, repairs, or
deletes `conversation.idx`** (`ConvIndex.hs:288-311`), and that file lives
under `sessionsRoot = spState/"sessions"`, `spState = ~/.seal/state`
(`Paths.hs:79`, `:89`, `:233`).

This is **pre-existing** — every transcript read does it today, including
`/b` and `/tab list` — and it touches neither `config/`, `keys/`, nor
`config/vault/`, so it does not breach AGENTS.md rule 3's "no opcode may ever
read or write files under `~/.seal/`" (which guards the security-critical,
agent-immutable subtrees). Recorded here because a reviewer reading "`/last`
is a read" should not have to discover an index write.

### 10.3 The question-text exception — an accepted risk, not a bounded one (D2)

An earlier revision claimed the gate prompt is safe to render because it
"already reaches the same conversation's channel via `ccSend`". **That was
wrong.** For a chat-originated turn, `aeCaps` is `askAwareCaps` over
`taCaps`, and `taCaps` is `webAskCaps` (`Send.hs:770`, `:791`, `:889`;
`TurnEngine.hs:746`). `webAskCaps`'s `ccSend` accumulates into an `IORef` and
broadcasts a WS `BeEntryUpdate` **behind `shouldEdit`'s 1500 ms / 80-codepoint
rate limiter** (`Send.hs:906-942`) — a droppable web-stream frame, not a chat
delivery.

The chat channel learns of a question by a *different* path: `ccPrompt` →
`askHumanWithOptions` → `broadcast BeAsk` (`Send.hs:947`) → `SeAsk`, which the
loop **drops unless the session is this conversation's focused tab**
(`Loop.hs:880`). So:

| Scenario | Chat saw it live? | `/last` shows it? |
|---|---|---|
| `b` focused when the ask fired | yes | yes — same audience |
| `b` not focused, watch off | **no** | **yes — first disclosure** |
| `b` focused in *another* conversation (tabs are process-global) | delivered *there* | **yes — cross-conversation** |

**So `/last` is often the first time this text enters that conversation.**
Rendering it is nonetheless the operator's explicit decision (§5.5), and the
audience is unchanged in the sense that matters: the *same conversation*, the
same recipients. It is recorded here as an **accepted risk**, with its actual
shape, rather than a bounded consequence:

- The disclosed content can include a `SHELL_EXEC` command line whose argv
  carries a credential.
- The disclosure is per-tab-on-demand, so it cannot enumerate *past* inputs —
  only a currently-blocked tab's pending question. `extractEntry` never reads
  `input` from the transcript (§4.1), so no historical tool input is
  reachable by any path.
- The residual risk — a credential in argv reaching a chat platform's retained
  history — originates in the gate's prompt construction
  (`Loop.hs:741-743`), not in `/last`. Filed as a follow-up.

**The dominant risk shape, stated (E7).** Before `/last`, a gate prompt
reached a chat channel only as a **push** tied to an event (that tab focused,
or watch-on idle). `/last` makes it a **pull**: any sender who can deliver a
message to the bot can invoke `/last <tab>` and drag any tab's pending gate
prompt into that conversation on demand. Since `allow_from` is parsed but
never enforced, this escalates "can message the bot" into "can read pending
gate prompts process-wide". The operator accepted showing the question; this
paragraph records what that acceptance covers, so it is not mistaken for
"same audience, one tab at a time".

Cross-conversation visibility is **pre-existing**: tabs are process-global
(`snapshotTabs`, `Tabs.hs:55-56`), `/b` already reads another tab's assistant
text, and `allow_from` is parsed but never enforced. `/last` does not widen
*which tabs* are reachable; it widens *what* is shown for one of them.

