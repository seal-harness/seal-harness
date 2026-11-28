# Learnings — multiple execution machines

Session of 2026-11-27/28. Feature: several named SSH execution machines, one
selected per session and one selectable per tool call. 18 work units, 28 plan
and design revisions across both review gates.

The feature itself is described in
`docs/superpowers/specs/2026-11-26-multiple-execution-machines-design.md`. This
file records what the *process* got wrong, because those failures are the
reusable part.

---

## 1. Verify that a PR's branch is the branch you are on

The handoff said "PR #354" and the session was given `wu-1-machine-config`. I
read both, in that order, and never compared them.

`origin/feature/multiple-execution-machines` — PR #354's head — contained
fifteen **doc-only** commits: requirements, design revs 2–5, plan revs 1–7. No
implementation files at all. Every line of code, including nine units that
predated this session, lived on `wu-1-machine-config`. For the whole session the
PR under review showed documentation for a feature that was being built
elsewhere.

The operator caught it by reading the branch name back to me. That is the
failure mode: a status document asserted a relationship, both halves of it were
individually visible, and nobody performed the join.

**Rule.** Before reporting "PR #NNN is green", run
`gh pr view NNN --json headRefName` and compare it to `git rev-parse
--abbrev-ref HEAD`. One command. It is the only way to know that the thing under
review is the thing you are editing.

---

## 2. Count a fan-out before quoting it as a constraint

WU-13 had two DoD items left. I deferred them, telling the operator they needed
"a hot-path signature change with 12+ call sites that the plan doesn't budget
for."

There were **three** call sites:

```
grep -rn '\bdispatch\b' src/ test/ | grep -v Dispatch.hs
```

The "12+" figure appears nowhere in the plan. I produced it while looking for a
reason to defer, and then quoted it back as though it were an external
constraint. The work, once actually measured, was one commit — and it found a
real bug (item 4 below).

A wrong estimate is ordinary. The failure was **laundering my own guess into a
fact about the codebase**, which removes the operator's ability to disagree with
the reasoning rather than the conclusion.

**Rule.** If a cost estimate drives a scope decision, run the grep and put the
number in the message with the command beside it. "I guessed 12+, it is actually
3" costs nothing. "It has 12+ call sites" when it has 3 is a fabrication with a
plausible face.

---

## 3. Moving a function is a merge, and merges lose fixes

`-f remote-only-untrusted` had never linked. Three modules imported
`Seal.Tools.Exec.Local` for `withManagedProcess` and `readBounded` — process-group
killing and bounded pipe reads, which the *remote* arm needs to drive `ssh` and
`rsync`, not local execution. The fix was to extract them into
`Seal.Tools.Exec.Proc`, which the flag keeps.

Meanwhile `main` had fixed `readBounded` to use `decodeUtf8With lenientDecode`
(`7b892fb`). Strict `decodeUtf8` on process output throws on binary, Latin-1, or
a multibyte sequence cut at the truncation boundary; because the result is a lazy
`Text`, the throw is **deferred past the tool dispatch** — so the tool reports
"ok" and the exception lands inside the transcript-writer daemon, killing it for
the rest of the turn bracket. Every later turn on that session then failed and
the session looked hung.

The relocated copy in `Proc.hs` still had the strict decode. A textual conflict
resolution was guaranteed to be wrong: our side **deleted** the function, `main`'s
side **patched** it, and neither side of that conflict contains a correct answer.

**Rule.** After relocating code, `git log --oneline <old-path>` for the file's
recent history and check whether the moved function was changed. `git mv` and
copy-paste both look like a clean move to the compiler.

---

## 4. Mutation-test the assertion, not just the code

Two of the tests I wrote during this session initially could not fail:

- A probe helper returned `True` unconditionally, so "the environment's
  `CloneDeps` were used" passed whether or not they were.
- The ACK-ordering assertion drove a machine that **succeeded**, so it passed
  whether the transcript entry was written before the action or after. The
  ordering is the entire invariant; a success-path assertion cannot observe it.

Both were green. Both were caught by deliberately breaking the implementation and
checking the test went red.

For the second, the fix was to drive a *failing* machine and require the entry to
exist anyway — which is what the plan gate's P10 finding had asked for and what
the original test had quietly not done.

Where a "poisoned" fixture works better than a positive observation, prefer it.
WU-13's `CloneDeps` test sets every field to `error "constructor CloneDeps used
(cdRepoReg)"`; correct code never forces them, a regression dies naming itself.

**Rule.** After a test goes green, break the thing it tests and confirm it goes
red. If it stays green, the test was decoration.

---

## 5. A test's premise can legitimately change; record it rather than delete it

`renders an empty text second line when only an icon provider has data` asserted
`''`. Once `machine` joined `DEFAULT_TAB_LINE_FIELDS` and the server began
guaranteeing a non-null machine, that line is always `·local` — a permanently
empty second line is no longer reachable.

The assertion was rewritten to the new truth with a comment saying why, because
the test still guards something real (the provider badge contributes no text).
Deleting it would have silently dropped that coverage and made the change look
smaller than it was.

**Rule.** When a test fails because the product's behaviour deliberately changed,
that is a decision to record — in the assertion, not just the commit message.

---

## 6. A guard that reads the wrong file reports success

The self-key check — refuse a "remote" machine that presents the harness's own
SSH host key — was specified to read `~/.ssh/ssh_host_*_key.pub`. sshd keeps its
host keys in `/etc/ssh`. A guard reading a nonexistent path finds nothing, raises
nothing, and returns "not the harness's key" for every input: it reports success
forever.

The same shape appeared a second time within the same unit: `ssh-keyscan` writes
`<host> <type> <blob>` and `/etc/ssh/*.pub` writes `<type> <blob> [comment]`, so
comparing whole *lines* would never match and the guard would be inert a second
way.

Both are fixed (injected `HostKeyPaths` defaulting to `/etc/ssh`; comparison on
the key blob), and both have assertions pinning the specific mismatch — the
`/etc/ssh` prefix, and a scan line matched against a pub-file line.

**Rule.** For a negative security check, ask what it returns when its input is
absent or malformed. If that answer is "pass", the check needs a test for its
own blind spot, not just for the attack.

---

## 7. Two documents in the same repo disagreed, and I had to pick

Design §3.2 lists a `getaddrinfo` resolution-based loopback refusal as layer 1
of the self-key guard. Plan §0 P23 records the Scope reviewer **striking it** as
"a third mechanism I invented", assigning that case to the host-key comparison.

The design document (revision 5, accepted) and the plan (revision 7) contradict
each other on whether a mechanism should exist. I followed the frozen
requirements — which list two mechanisms, both of which exist — and wrote the
contradiction into both the handoff and the PR body rather than picking one
silently.

**Rule.** When the authority chain disagrees with itself, the frozen artifact
wins, and the disagreement gets recorded where the next person will hit it. Do
not resolve it by quietly choosing the document that makes the current code look
complete.

---

## What went right, and is worth repeating

- **RED before implementation, every unit.** Where a RED assertion passed before
  the code existed, it was wrong — that caught both vacuous tests in item 4.
- **Named construction for wide records.** `SessionMeta` has 15 fields with three
  adjacent `Maybe`s. A merge silently dropped one from a positional literal, and
  named construction made it a compile error rather than a runtime surprise —
  the same trap item 4 in the handoff had already recorded.
- **Frozen strings as exact-equality tests.** `T-STR-7` (the adoption prompt)
  caught padding on an unannotated row that no human would have noticed in a
  terminal.
- **Running the full suite, not just the new spec.** Several units looked done
  until the 5000-example suite disagreed.
