# Telegram notification policy — learnings

Branch `channels/telegram-notification-policy`, stacked on the Signal work
(PR #328). Task: make Telegram behave like Signal — tool progress edits one
message in place, and only things needing input (the answer before idle,
`ASK_HUMAN`) notify.

## The design that survived, and the one that did not

The first design replaced `ccEditMessage`'s `Bool` with a three-way
`EditOutcome` across 11 sites in both transports, so the loop could tell a
transient refusal (429 flood control) from a permanent one (message deleted) and
would not answer "slow down" by sending a fresh notifying message.

The plan gate killed it, correctly. Reading the code showed the whole
classification was unnecessary:

- `updateBubble` is reachable only from `PsSingleBubble` call sites.
- The bubble holds tool progress only; the answer is a separate `ccSend`.
- `ssSplices`/`ssAccumulated` are written only by the tool-call and entry
  handlers, never by an edit.

So a failed edit loses nothing a later event cannot re-render, and the
duplicate-notification amplifier disappears by **not sending** — one branch in
one file, no type migration. Generalisation worth keeping: before adding a
classification, check whether the *action* the classification would select is
one you can simply stop taking.

## Three bugs found by reading, not by testing

1. **`void (ccSendWithId chan content)` discarded the new message id.** The
   fallback comment assumed "one duplicate". Because the id was thrown away,
   `ssMsgId` kept naming the dead message, so *every later tool call* re-failed
   and re-sent the whole body — unbounded, and each send notifying. Signal never
   surfaced it because signal-cli edits rarely fail; Telegram returns non-200
   for 429 flood control, which is transient by definition.
2. **The `PsSingleBubble` frame path had no gate at all.** Not the 80-codepoint
   branch, no interval. The gateway emits per "1500 ms OR 80 new codepoints", so
   a fast model drove 100+ edits/minute — far past Telegram's ~20/min for a
   group. The obvious-looking fix (re-gate the loop path) was a no-op for the
   *separate-messages* style only because that path already calls `shouldEdit`
   itself; the single-bubble path was the actual hole.
3. **`tccAllowList` is assigned and never read.** `readerLoop` retargets
   `tccLastChat` for any sender, and every send/edit reads it — so any party who
   can message the bot redirects the channel into their own chat. Pre-existing,
   out of scope, filed as #332. The relevant lesson is that the review prompt
   *asserted* an allow-list gate existed and it did not; verify claimed
   boundaries rather than reviewing against them.

## Two things that were almost shipped wrong

**A guard that could never pass its own test.** The over-limit fix was gated on
`ccProgressStyle == PsSingleBubble` "so Signal is untouched" — but `Signal.hs`
already sets `PsSingleBubble`, so the guard admits Signal and the accompanying
"Signal unchanged" test was unsatisfiable. Escalated to the operator, who chose
to fix Signal too. Lesson: a guard whose predicate is already true for the thing
you are trying to exclude is not a guard.

**A claimed guarantee the code does not provide.** An early revision said the
final answer "always notifies". `sendViaApi` swallowed every exception and
ignored the status code, so a 429 at that moment dropped the answer silently.
Corrected to "always *attempted*", the failure now logs a fixed classifier, and
the real fix is filed as #331.

## The requirement gap the gate found in review

Making the progress bubble silent (so tool calls notify zero times) meant a
**tools-only** turn would notify zero times overall — its last message before
idle would be a silent bubble. That directly contradicted "the last message
before idle must notify". Now a tools-only turn sends one short close notice at
idle, giving the invariant the tests pin: **every turn notifies exactly once** —
the answer when there is one, otherwise the close notice; an empty turn sends
nothing.

## Testing notes

- Writing the test first caught my own spec error three separate times in WU-3:
  I asserted "10 frames ⇒ one edit" on a path that cannot create a bubble, and
  asserted a shared-bucket outcome inconsistent with my own "a create does not
  consume the bucket" rule. The RED failures were the spec being wrong, not the
  code.
- The ask regression guard was mutation-tested: pointing `handleAsk` at
  `ccSendWithIdSilently` fails two tests. Worth doing for any guard whose
  subject is "we did NOT use the new seam".
- The mock needed `mcSilentSends` before the ask assertion meant anything — the
  class default aliases `ccSendWithId`, so without a dedicated recorder the
  check would have been vacuously true.
- `nix develop --command cabal build test:tests` — plain `cabal build tests` is
  ambiguous (`cwd:tests` vs `test:tests`), and `test:seal-harness-test` does not
  exist (the suite is named `tests`).

## Process notes

- The 5-agent design gate took five rounds and the 3-reviewer plan gate three.
  Every round after the first was worth it, but the highest-value findings all
  came from the reviewers who actually read the code rather than the design:
  every one of the four real defects above was a `file:line` claim, not a style
  opinion.
- Agent ids for the gates are `gate-feasibility` / `gate-completeness` /
  `gate-scope` and `seal-harness--<role>`, not bare role names.
