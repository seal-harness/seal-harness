# `/last` — Requirements

**Status**: awaiting human approval.
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

**A tab waiting on a question** — `/last` shows the question and its options,
and the user answers the same way they already answer one: with a number or
plain text.

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
- **`/last` never sends anything the assistant did not author.** Assistant text
  and opcode *names* only — never tool inputs, never tool results, never file
  contents, never secrets.
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
