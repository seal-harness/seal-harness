# Design Review Gate — Round 1 Triage

**Design**: `docs/superpowers/specs/2026-11-27-turn-failure-visibility-design.md`
**Requirements** (frozen): `docs/superpowers/requirements/2026-11-27-turn-failure-visibility-requirements.md`
**Status**: Round 1 — security review returned NEEDS_REVISION. 4 other reviewers
still running.

---

## Triage table

| # | Finding | Reviewer | Bucket | Action |
|---|---------|----------|--------|--------|
| 1 | `redactCause` strips against a "secret-value set" that does not exist — `redactMessages` is provenance-based, `itwSetSecretOps` holds opcode NAMES, no value scrubber exists in `src/` | Security | **IN SCOPE — design defect** | **Fixed.** `tfCause` redesigned from `show e` free text to a closed `FailureCause` enum + curated field. Leaks now structurally impossible rather than scrubbed. §3.1 rewritten |
| 2 | `show e` reaches `conversation.jsonl`, `entries.jsonl`, web UI, and Telegram/Signal with no scrubbing; violates constraint 1; chat egress is irreversible | Security | **IN SCOPE — design defect** | **Fixed.** Same as #1, plus per-surface scoping: chat payload carries headline + ref only, no cause (§3.1, §3.2) |
| 3 | `harnessPayload` projects only `op`/`input`/`result`/`channel`/`approval`, so `kind`/`headline`/`cause`/`ref` never reach the frontend — feature renders empty | Security (Architect also asked to verify) | **IN SCOPE — design defect** | **Fixed.** §3.2 now names TWO gates: projection (`harnessPayload`) + filter (`reconEntryToFrontend`). T5 asserts both |
| 4 | `try @TranscriptError` insufficient — `IOException`/`ErrorCall` from the write path would abort before broadcast/fanout, breaking constraint 2 | Security | **IN SCOPE — design defect** | **Fixed.** §3.6 each duty independently guarded with `try @SomeException`; T7b added |
| 5 | `appendSessionLog` writes `msg` raw — newline injection forges `seal.log` lines | Security | **IN SCOPE (small)** | **Fixed.** §3.6 commits to a `Text -> Text` escaping sibling + T11 |
| 6 | Chat payload with raw cause is a needless irreversible egress; requirement 6 only asks that a phone user learns it failed | Security (suggestion) | **IN SCOPE — design choice** | **Adopted.** Headline + ref on chat; cause stays local |
| 7 | Durable record is best-effort on the dead-writer path; requirement 1's "persists" is not met there | Security (suggestion) | **IN SCOPE — needs stating** | **Adopted.** §3.6 states this explicitly rather than glossing |
| 8 | Tab-status is a strict 3-state function; "tab strip indicates a problem" underestimated the work | Self (during prep) | **IN SCOPE — design defect** | **Fixed.** §3.4 enumerates the 5 files + sort placement that an error state touches |

## Round 1b — Product Manager review (NEEDS_REVISION, 6 blockers)

| # | Finding | Bucket | Action |
|---|---------|--------|--------|
| 9 | `broadcastNewEntries` runs only on the `Right` branch, so the durable entry never reaches the live client — banner now, entry only on reload | **IN SCOPE** | **Fixed.** §3.5 adds a `push` duty on the failure path; T4c asserts live delivery |
| 10 | `classify`'s signature is incoherent — called with a `Text` after the exception is consumed, yet claims to consult an `IO`; `tfRef` cannot match the log id because `withExceptionLogging` never returns it | **IN SCOPE** | **Fixed.** `mkTurnFailure :: Handle -> SomeException -> IO` plus pure `classify mInner e ref`; `withExceptionLoggingRef` returns the id; T4d asserts correlation |
| 11 | §3.5 mislabels the choke point as "the release action's `Left errMsg`" — no such thing exists there; an implementer would double-report on every success | **IN SCOPE** | **Fixed.** §2.1 names `runTurnBody`'s `Left` branch and explains why body-vs-cleanup is load-bearing |
| 12 | T2/T3 and the §5 risk row are stale against the revised §3.1 (`TranscriptError ts (Just inner)` rejected; `redactCause` deleted) — the RED tests are unwritable | **IN SCOPE — hygiene** | **Fixed.** T2 rewritten around `itwLastFailure`; T3 around the closed enum; §5 row replaced |
| 13 | Constraints 3 and 4 never addressed by name. Concrete C3 violation: a *stuck* writer blocks `idle` up to 30s (`defaultAckTimeoutUs`) | **IN SCOPE** | **Fixed.** §3.5 bounds the failure-path write (~2s), adds T7c; C4 gets T4b |
| 14 | Design contradicts itself on the cause line (§3.4 says `UnicodeException in readBounded`, §3.1 says structurally impossible) | **IN SCOPE** | **Fixed.** §3.4 now has an explicit rendered-string table per constructor |

PM suggestions adopted: (1) rendered-string-per-constructor table; (2) tab-flag
lifecycle; (3) `FailProvider` dropped as CONSTRAINT CORRECTION — no
`ProviderError` type exists and provider failures are recorded as `EKResponse`
and never throw (`Loop.hs:376-395`); (4) CLI citation corrected to the live
path `Cli.hs:351-352`, with the `turn failed: ` prefix noted as *being added*;
(5) D3 sweep flagged for possible PR split; (6) `renderFailure` renamed to
`renderForUser`/`ForChat`/`ForLog` (collides with Options.Applicative).

## Round 1c — CTO review (NEEDS_REVISION, 6 blockers)

| # | Finding | Bucket | Action |
|---|---------|--------|--------|
| 15 | T9 targets `transcriptToMessages`, but production renders via `processEntry` (`useTranscriptMessages.ts:90`); the branch would land in parity-only dead code | **IN SCOPE** | **Fixed.** T9 retargeted to `processEntry`; §6 names the file; parity assertion kept |
| 16 | `forkIOLogged` "re-raises nothing" would log `ThreadKilled` as an error on every shutdown, contradicting §3.7 and the `withExceptionLogging` precedent | **IN SCOPE** | **Fixed.** §3.8 rethrows `AsyncException`; T8 asserts both halves |
| 17 | Accepted decision 1 is unimplementable: `erConvLen` unspecified, and at `0` (like all `EKHarness` entries) the model never sees the failure | **IN SCOPE — most consequential** | **Fixed.** §3.2 specifies `erConvLen = 1` + `renderForModel`, matching `recordSetupRepoResult`; T4e asserts the model sees it |
| 18 | Done-when 2, 5, 6 have no tests (rendered cause, CLI text, chat fan-out) | **IN SCOPE — hygiene** | **Fixed.** T12 (CLI), T13 (chat, exactly one), T14 (rendered cause table) |
| 19 | `FailureKind`↔`FailureCause` mapping undefined and partly redundant; AGENTS.md discourages a second ADT with no pattern-match consumer | **IN SCOPE** | **Fixed.** `FailureKind` dropped; `FailureCause` is the single taxonomy; headline via `headlineFor` |
| 20 | `CauseProvider Text` unreachable — the same defect `FailProvider` was removed for | **IN SCOPE** | **Fixed.** Replaced with payload-free `CauseProviderUnresolved` for CP2 |

CTO suggestions adopted: (1) module moved `Session/` → `Transcript/` to avoid
layering inversion; (2) strict-field convention *not* applied — matches local
practice (`EntryRecord` has none), noted for a separate fix; (3) §3.7 reworded
to "per `runTurnBody`"; (4) cleanup-overwrite added to §5 risks; (5) T3 marked
near-vacuous with T3b load-bearing; (7) integration test placed in
`SendSpec.hs`; (8) `ToJSON FailureCause` + `formatLogLine` escaping noted.

**Also found independently while verifying (in no review):** a **second choke
point** — provider resolution returns `TurnOutcome (Just err)` before the
bracket is entered (`TurnEngine.hs:548-554`), throwing nothing, so §3.5's choke
point never fires and a bad model name / missing vault key would still fail
silently. Added as CP2 (§2.2).

**Delivery split adopted (CTO):** 3 PRs — core → feature → D3 sweep (§6.1).

## Round 1d — Designer review (NEEDS_REVISION, 5 blockers)

| # | Finding | Bucket | Action |
|---|---------|--------|--------|
| 21 | Wire shape self-contradicts: round-1c dropped `FailureKind` from the type but left `"kind": "decode"` in the §3.2 example **and** the gate-1 projection list — `harnessPayload` would project an always-absent key | **IN SCOPE** | **Fixed.** Field set is `{harness, cause, ref, headline}` in all three places; wire values for `FailureCause` tabulated |
| 22 | `Message` has no `kind` field; `agentName`/`agentStatus` are required and unspecified. And `processEntry` is a verbatim copy of `transcriptToMessages` guarded by `expectFullParity` — my §3.4 and T9 contradicted each other about which gets the branch | **IN SCOPE** | **Fixed.** `kind?`, `agentName='Turn failed'`, `agentStatus='idle'`, explicit `testId`; **both** renderers get the branch + a parity fixture; T15 |
| 23 | Two live signals for one failure with no rule: banner and entry both render the full block ~a screen apart in the same scroll region | **IN SCOPE** | **Fixed.** All three signals justified against a requirement sentence; banner degrades to a one-line pointer when the entry is in-window; T16 |
| 24 | The body sentence ("The tool call above did not return a result") is hard-coded from one incident and **false** for ≥3 of 6 causes (CP2 has no tool; transcript-dead can fire on turn 1; disk-full may hit the check itself) | **IN SCOPE** | **Fixed.** Cause-neutral body by default, per-cause only where true |
| 25 | Accessibility unspecified: `role="alert"` on a virtualized row re-announces on scroll; `kindLabel`/`kindIcon` are exhaustive `Record`s that won't compile with a 4th state, and `kindLabel` feeds `aria-label` — the only not-focused surface | **IN SCOPE** | **Fixed.** Banner owns `role="alert"` once; entry is static text; glyph `aria-hidden`; `kindLabel`/`kindIcon` added to the checklist; T17, T18 |

Designer suggestions adopted: (1) unify `turn-failure`/`turn-error` vocabulary —
`rg turn-failure` must hit both halves; (2) test ids named
(`turn-failure-entry`, `turn-failure-banner`); (4) unknown `cause` renders the
raw string (forward compatibility); (5) `rawJson` carried so "View raw JSON"
works — the payload is secret-free by construction; (6) tab-flag clearing on
focus stated as a deliberate choice.

## Round 1e — Architect review (NEEDS_REVISION, 8 blockers)

| # | Finding | Bucket | Action |
|---|---------|--------|--------|
| 26 | "Single choke point" doesn't cover the named classes: provider-resolution returns before the bracket (CP2); and everything in `runTurnBody` **before** line 826 (`mkEnv`, config loads, `cachedWorkdirScan`, registry build) is unprotected — §3.7's "once per `runSessionTurn`" was false | **IN SCOPE** | **Fixed.** §2.3 adds CP3: the `withExceptionLoggingRef` wrap moves to cover the whole of `runTurnBody` from its first statement |
| 27 | `classify` unbuildable: (a) only `Text` survives the handler; (b) declared pure yet "consults" an `IO`; (c) `ProviderError` does not exist; (d) `ENOSPC`/`EMFILE` tokens never appear in `show ioError` so both probes are dead | **IN SCOPE** | **Fixed.** (a) `withExceptionLoggingRef` returns the exception; (b) `mkTurnFailure` (IO) + pure `classify`; (c) dropped earlier; (d) probes now match `"No space left on device"`/`"Too many open files"`, case-insensitive |
| 28 | **The rendering route cannot work:** `reconEntryToFrontend` hardcodes `"harness" .= Nothing` (`Transcript.hs:774`) and `rewritePayload` never passes `harness` (`:841-867`), so the frontend gets `harness: null`. Four other reviewers missed this | **IN SCOPE — most serious** | **Fixed.** §3.2 now documents **FOUR** gates; the frontend keys on a new `turnFailure` payload field (option b), avoiding the `e.harness` label-fallback collision. T5 asserts the field value, not mere presence |
| 29 | Constraint 1's mitigation rests on `redactCause` + a secret-value set that does not exist | **IN SCOPE** | Already fixed in round 1a (closed enum). Verified `redactCause` no longer appears in the design |
| 30 | §5's alignment mitigation is vacuous: `checkAlignment` short-circuits **both** checks for harness entries (`tooShort`/`tailMismatch` gated on `not isHarness`, `:446,452`) | **IN SCOPE** | **Fixed.** §5 states the real invariant: harness `erConvLen` is a delta and must equal the messages passed (*1*, with `renderForModel` present); T5 extended to assert later entries' cursors |
| 31 | Decision 4 unmet for delegation workers: `Worker.hs:299` calls `runTurn` **directly**, `catchChildSync` discards the exception. Also §3.8 duplicated `/bg` reporting (constraint 5) | **IN SCOPE** | **Fixed.** §2.3 adds `Worker.hs` `reportTurnFailure` in its own bracket; `/bg` gets **only** `forkIOLogged`, no second `recordFailure` |
| 32 | Live signal sequenced **behind** the durable write, so a stuck writer delays it up to 30s — on the motivating scenario | **IN SCOPE** | **Fixed.** `broadcastTurnFailure` runs **first**; all duties individually guarded |
| 33 | CLI requirement stated against a test-only path (`handlePlain`, `Cli.hs:120`); the live path (`:351-352`) has no prefix | **IN SCOPE** | **Fixed** (also caught by PM). Live path named; prefix added; T12 |

Architect suggestions adopted: (1) unlisted `forkIO` sites in `Serve.hs`
documented as excluded (the requirements' list is explicitly non-binding);
(2) `DispatchSpec.hs` added to file scope (two hand-built handle records break);
(4) cron `Left` also carries `renderForUser` so run history matches; (5) T5
cursor-invariance assertion; (6) `itwLastFailure` write order stated as **new**
code (fault-TVar *then* `aliveRef`; today neither exists and the handler flips
`aliveRef` first); (7) constraint-3 test must account for idle being suppressed
when children are running (`TurnEngine.hs:585-593`).

**One Architect claim I checked and rejected:** blocker 5's assertion that a
non-zero harness `erConvLen` "silently corrupts every subsequent entry's
cursor". `Reconstruct.hs:127-137` documents a harness `erConvLen` as a delta and
notes "1 for a skill-load or setup-repo result, which append a message" — so
non-zero is *supported*, provided the message is appended (which §3.2 now
does). The real invariant is `erConvLen == length (itwMessages write)`, which is
what the revised §5 states.

## Constraint tension — needs your decision (NOT a design defect)

Security flagged this as a **baseline assumption that is factually false**, and
I agree it should not be scored against the design:

> Requirements constraint 1 says "the existing redaction rules apply to failure
> entries exactly as they apply to tool results", while decision 2 and
> requirement 3 demand the cause line be **raw** (`UnicodeException in
> readBounded`). Those are jointly unsatisfiable for arbitrary `show e`: the
> existing rules are opcode-provenance based and have nothing to say about an
> exception string.

The requirements implicitly assumed a value-based scrubber exists. It does not.

**I have already resolved this in the design** by choosing the security
reviewer's option (a): `tfCause` is a closed enum + curated field
(`CauseUnicode`, `CauseNoSpace`, `CauseProvider status`, `CauseOther typeName`),
never `show e`. This satisfies "the cause line tells a disk-full from a provider
outage from a code bug" — decision 2's stated intent — while making leaks
impossible.

**What this costs you:** the cause line will read `invalid UTF-8 in tool output`
or `no space left on device` rather than a raw Haskell exception dump. Full raw
detail stays in `seal.log`, reachable by the reference id. I believe this is
what you actually wanted (you asked for "a better idea what happened", not for
raw `show e` on your phone) — but it does narrow decision 2, so I'm flagging it.

## Reviewer status

| Reviewer | Verdict |
|---|---|
| Security Design | **NEEDS_REVISION** — 4 blockers, all addressed above |
| Product Manager | running |
| Architect | running |
| Designer | running |
| CTO | running |
