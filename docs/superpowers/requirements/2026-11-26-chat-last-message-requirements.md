# `/last` — Requirements

**Status**: approved 2026-11-26, amended 2026-11-26 (see Amendments below).
**Branch**: `channels/last-message-requirements`
**Scope**: Signal and Telegram chat channels only.

> **What this document is.** This is the operator's review surface: the complete
> user-facing behaviour of the feature, and nothing else. It is the baseline every
> later design and plan is measured against. If implementation detail is not
> visible to a person using `/last`, it does not belong here — it belongs in the
> design.
>
> **Review cost**: ~2 minutes. That is the point.

---

## Behaviour

```
/last                   Show the focused tab's last message.
/last <tab>             Show tab <tab>'s last message.
/last <tab> <n>         Show the last <n> messages (n = 1-5, default 1).
```

`<tab>` is the same single character the rest of the chat grammar uses
(`0-9a-z`, as in `/N` and `/tab focus N`). The **first argument is always the
tab**, so `/last 3` means *tab 3*, not *three messages*. Every reply names the
tab it came from, so a user who meant something else sees it immediately.

## What the user sees

**A normal reply** — headed with the tab it came from, so the user always knows
which tab they read:

```
📔 Tab b (fix the flaky test) — last message:

All 412 tests pass.
```

**A turn that produced no text**, because it ended on a tool call. The reply
names what ran instead of being empty:

```
📔 Tab b (fix the flaky test) — last message:

💻 SHELL_EXEC (failed) — no reply text. /last b 5 for more.
```

Tool lines use the same glyph per opcode that the live progress bubble already
uses, so a user who watched the turn recognises what they are seeing.

**A tab waiting on a question** — `/last` shows the question and its options.
The user answers with `/N <answer>` (`/b 1`, `/b yes`, `/b your own text`),
which delivers to *that tab's* session without changing focus. (Amended: A2.)

**A tab still working** — the reply says so rather than implying the tab
finished:

```
📔 Tab b (fix the flaky test) — still working:

last completed: 💻 SHELL_EXEC
```

**A tab with no messages yet** — says so plainly; it is not an error.

**A `/<tab>` focus** — `/b` ends with the same rendered last-message block that
`/last b` gives, instead of today's bare text.

**Errors** name what failed and what to do next:

```
last failed: no such tab z — /tab list
last failed: tab b has no session (harness tab)
last failed: no current tab
last failed: couldn't read tab b's transcript — try again in a moment
```

**The watch notification** gains the same courtesy. When a watched tab finishes
with no text, the notification names the last tool rather than sending a bare
`📔 Tab b (...) finished thinking` with nothing after it. When it has text, it
behaves as it does today.

## Constraints

- **`/last` never changes which tab the user is focused on.** It is a read. A
  user can look at tab `b` from tab `a` and stay on `a`.
- **`/last` never sends anything the assistant did not author.** Assistant text,
  opcode *names*, and — for a tab currently blocked on a question — that
  question's text and options (see Amendments, A1). Never a *historical* tool
  input, tool result, file content, or secret.
- **Works on both Telegram and Signal**, with the message splitting each
  platform already does for long messages.
- **A watched tab that ends with no text never produces a notification with no
  body.** It names the last tool instead.

## Out of scope

These are **pre-existing gaps, tracked separately**. `/last` neither fixes nor
worsens them, and findings here are not defects in this feature:

- Command rate limiting (applies to every command, not just `/last`).
- `allow_from` enforcement on chat channels.
- Transcript redaction of tool-call arguments on disk or over the web socket.
- Cross-conversation message routing.
- The web frontend (the transcript is already on screen there, so the command
  has no meaning).

## Done when

1. `/last`, `/last b`, and `/last b 3` each return the right tab's messages, on
   both Telegram and Signal.
2. A tab whose last turn produced no text shows the opcode name and its
   pass/fail, not an empty body.
3. A bodyless `/watch` notification names the last tool.
4. `/last` does not change the focused tab.
5. A tab waiting on a question, a tab still working, and a tab with no messages
   each render their own distinct message — none of them silently shows
   nothing or the wrong state.

---

## Notes for the design phase

Not requirements — recorded so the design does not have to rediscover them.

- `conversation.jsonl` holds one `Message` per line, with `conversation.idx` as
  a byte-offset index, so "the last n messages" is a tail seek
  (`convLineCount` → `readConvLines`), not a full read.
- `CbThinking` blocks must be excluded from rendered text; they are model
  reasoning, not the assistant's message to the user.
- The transcript route already reads through the conversation index; the count
  cap belongs server-side.
- Two defects found while reviewing the earlier design are worth their own
  issues and are **not** part of this work: tool-call arguments reach web
  clients unredacted, and `allow_from` is parsed but never enforced.

---

## Amendments

Operator decisions, given verbally during plan review on 2026-11-26 and
transcribed here by the implementing agent so the baseline stays truthful. Each
one resolves a contradiction the original document could not settle on its own.
**The operator should read these and correct any mis-transcription** — this
document is human-authored prose, and the agent's job here is recording, not
writing.

**A1 — Constraint 2 and question text.** `/last` MAY send a pending question's
text and options, including the confirmation-gate prompt, which embeds the tool
call being confirmed:

```
Allow SHELL_EXEC {"command":"curl -H 'Authorization: ...' ..."}? [y/N]
```

The operator accepted this (2026-11-26) because the same text is already
delivered to the same chat conversation when the prompt fires; `/last` repeats
it on request rather than introducing it. Scope of the exception: a question
that is **currently pending** on that tab, and nothing else. Fixing the prompt
so it stops embedding arguments is tracked separately and is the proper root
fix.

**A2 — How a question is answered.** The original text said "with a number or
plain text". That is not true for a tab the conversation is not focused on: a
plain reply is routed to the *focused* tab (and can answer a different question
there). The answer path is therefore `/N <answer>`, which targets the named
tab's session. `/last` never changes the focused tab.

**A3 — Hint wording.** The "for more" hint reads `/last <tab> 5 for more`,
exactly as the example in this document shows. It does not scale the suggested
count.

**A4 — Out-of-scope surface touched.** One optional work unit changes how an
unrecognised transcript block type is rendered by the web frontend (it currently
surfaces as raw JSON; afterwards it is dropped). The operator approved this as
part of the work despite the web frontend being out of scope.

**A5 — Tab title in the heading.** The heading shows the tab's display title,
which may be a user message snippet rather than assistant text. This is
consistent with the examples in this document and with `/tab list`.
