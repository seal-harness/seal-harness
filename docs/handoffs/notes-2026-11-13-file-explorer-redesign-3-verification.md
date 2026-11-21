# Verification notes — file explorer redesign 3 (resume)

**Date**: 2026-11-13 · **Branch**: `files/explorer2` @ `362bc73` · **Author**: Coder Agent
**Status**: **No file-explorer code written.** Blocked on 3 operator decisions
(channel failure — see §5). Separately, the CI failure reported on this branch
was diagnosed and fixed — see §7.
**Tree**: only `SendSpec.hs` modified (§7); no file-explorer source touched.

> **After §7**: `df96b6b` committed and pushed; CI **green on both**
> x86_64-linux and aarch64-darwin (run 43562881061).

This document records what I verified in the code. Everything below was checked
against the repo, not carried over from the handoff or the design doc. Where I
disagree with the design doc, I say so and say why.

---

## 1. Baseline / environment, verified

| Fact | Verified by |
|---|---|
| Branch is `files/explorer2` @ `362bc73`, tree clean | `git status --short` |
| `files/explorer` **is** an ancestor of HEAD | `merge-base --is-ancestor` → true |
| HEAD is **0** commits behind `origin/main` | `git rev-list --count HEAD..origin/main` → 0 |
| `files/explorer` has 10 commits not in `main` | `rev-list --count main..files/explorer` |
| HEAD adds 9 commits beyond `files/explorer` | `rev-list --count files/explorer..HEAD` |
| PR **#308** `files/explorer` → `main` is **DRAFT** | `gh pr list --json isDraft` |
| `files/explorer2` has **no PR** | `gh pr list` (8 open, none named explorer2) |
| nix + cabal + ghc available | `which` → cabal 3.16.1.0, ghc 9.12.4 |
| `dist-newstyle` **absent** (cold build) | `ls -d dist-newstyle` |
| `frontend/node_modules` **absent** (cold) | `ls -d frontend/node_modules` |

**Shallow-clone trap reproduced.** Before `git fetch --unshallow`,
`git rev-list --count HEAD..origin/main` reported **348** commits behind and
`merge-base --is-ancestor origin/files/explorer HEAD` failed with
`Not a valid object name`. After unshallow, both corrected to the values above.
The handoff's warning is accurate and cost ~4 calls to work around. **Never
trust `git log`/`rev-list` on a shallow graft.**

---

## 2. The four defects — all confirmed, with current line numbers

| # | Defect | Location (HEAD) | Confirmed |
|---|---|---|---|
| 1.1.1 | one `ceilingBytes` feeds viewer **and** download | `FileExplorer.hs:215-219` (`feReadFile` + `feReadFileBytes` both take `ceilingBytes`); `:424-430` remote ditto | yes |
| 1.1.2 | `readBoundedFile` reads whole file, returns prefix | `FileExplorer.hs:226-233`: `bs <- BS.readFile path` then `BS.take maxBytes bs` | yes |
| 1.1.3 | banner hardcodes "128 KiB" | `FilesView.tsx:276` | yes |
| 1.1.4 | truncated file saved as if complete | `useApi.ts:1853-1868` — `a.click()` unconditional on `truncated` | yes |

Also confirmed: `localReadFile` computes `length (T.lines content)`
(`FileExplorer.hs:356`), which is the boxed-list cost the design warns about —
so raising the shared ceiling really would hurt the **viewer** worst. And
`Serve.hs:514,517` passes the compiled-in `maxScanBytes`, while
`retrievalMaxScanBytes` reaches only `TurnEngine.hs:683,1091` — so no config
value affects the download limit today. Both design-doc claims hold.

**Defect 1.1.1 is a two-integer change.** `mkLocalFileExplorer :: Int ->
FileExplorerHandle` → `Int -> Int ->`. Confirmed as small as §11.1 claims.

---

## 3. FINDING A — the design doc's branching recommendation is impossible as written

This is the most consequential thing I found, and it contradicts §11.4.

§11.4 states the options are "**A.** Land #308, then branch off `main`",
"**B.** Branch off `main` now, rebase once — **recommended for Slice 1**", or
"**C.** Stack". All three assume `main` contains the Files feature, so that a
Slice-1 branch off `main` would be a small delta.

**It does not.** `main` has *no Files feature at all*:

```
git ls-tree -r --name-only origin/main | grep -i fileexplorer   → (nothing)
git cat-file -e origin/main:src/Seal/Tools/Exec/FileExplorer.hs → ABSENT
git ls-tree -r --name-only origin/main -- frontend/src/components | grep -iE "files|tree"
                                                                → only JsonTree.tsx
git grep -rn "files/download" origin/main                       → (nothing)
git grep -in "download" origin/main -- frontend/src             → (nothing)
```

Corroborating: `Route.hs` on `main` has no `files` route, and
`expectedRouteCount` is **70 on main vs 73 on HEAD** — the 3 extra are the
Files routes.

So a Slice-1 branch "off `main`" would have to *re-introduce the entire Files
feature* (≈8,789 insertions / 49 files) to have anything to fix. That is not
"one conflict instead of three"; it is re-landing PR #308.

### Why this matters

The whole premise of Slice 1 is that it is **small and independently
landable**. Off `main` it is neither:
- the 4 defects live in code that exists only on the feature branches
  (`FileExplorer.hs`, `FilesView.tsx` absent from main);
- only one of the four files (`useApi.ts`) even exists on `main`, and it has
  no `downloadFile` there.

### What this changes

The real options are:

| Option | Reality |
|---|---|
| **A′.** Land PR #308 → `main` first, then Slice 1 off `main` | The *only* way "off main" is genuinely small. Requires #308 to merge (it is a DRAFT). |
| **B′.** Slice 1 as a commit **on top of `files/explorer2`** | What is actually feasible today. Keeps momentum, no re-landing. Contradicts "off main" but matches the tree. |
| **C′.** Slice 1 on a branch off `files/explorer` (PR #308), not explorer2 | Possible, but `files/explorer2` adds the tree rail + batched listings that `FilesView.tsx` on explorer2 now assumes — so Slice 1's FilesView edits would conflict. |

**Recommendation: B′ now, A′ once #308 lands.** Slice 1 on `files/explorer2`
as-is; when #308 merges, the Slice-1 commits ride along into `main` with the
rest of the feature. This needs the operator's call because it is a *process*
decision and the design doc's stated plan does not work.

---

## 4. FINDING B — O-7 can be answered from your own config, and the answer is currently "no"

The design asks whether remote (SSH) mode is live, and notes a third of the
remaining design exists only for it. On this machine the answer is observable:

```
~/.seal/security.toml  →  keys present:
  vault_identity, vault_key_type, vault_recipient, vault_unlock
  [access_control] mode, origin
  [gateway] allowed_origins, host, port, tls, tls_cert, tls_key, tls_hosts
```

**No `[untrusted_execution]` block.** Per `Serve.hs:512-517`, that means:

```haskell
case untrustedExecConfigFromSecurity secCfg of
  Nothing    -> pure (mkLocalFileExplorer maxScanBytes)          -- ← taken today
  Just uec   -> case uecRemote uec of
    Nothing    -> pure mkFailClosedFileExplorer
    Just sshCfg-> mkRemoteFileExplorer sshCfg mkRealRemoteRunner maxScanBytes
```

So this install runs **local**. Remote is implemented and wired but not
configured here. `config/templates/security.toml:44-58` ships the remote block
**commented out**.

Counter-evidence for "remote is live" that the design cites: commit `d93a8d6`
("batch rail listings into one remote operation"). I checked it — it is real
but it exists **only on `files/explorer2`**, not in `main`
(`git merge-base --is-ancestor d93a8d6 origin/main` → **NO**). So it proves the
author *cared* about remote latency on this branch; it does not prove remote is
in production use for you.

**This is still your call** (you may run remote elsewhere), but the evidence
now points one way rather than being absent. If remote is not live, deferring
the remote arm of Slice 2 is justified — and note Slice 1's remote work is
only the ceiling split + formatter, which is cheap either way.

Test-surface cost if the remote arm *is* kept: `RemoteRunner` appears in **28
files** (13 src, 15 test). Adding a field makes every fake partial under
`-Werror`. §5.4a claims that cost; it is accurate, and it is why the architect
deleted `runRemoteStream` in §12.

---

## 5. BLOCKED — the decision channel does not work

`ASK_HUMAN` returned **empty** on 8 consecutive attempts:
1. option-description-length rejection (my error, fixed)
2. four-option scope question
3. three-option scope question
4. bare open-ended "reply 1/2/3"
5. minimal one-line "which scope?"
6. bare "Ping — reply OK"
7. single-option "Channel test"
8. final consolidated 3-decision question

`SHOW_HUMAN` also returned empty. I did not fabricate answers, and I have
written no code, because all three decisions change the file list and the test
surface and the design gate explicitly requires them answered first.

**What I need, in one reply:**

1. **Scope** — (1) Slice 1 [recommended: split ceilings, `readBoundedFile`
   fix, `.partial` naming, stat route, confirm dialog; no chunking], (2) full
   chunked downloader, or (3) backend fixes + `.partial` naming only.
2. **O-7 remote** — yes/no. Is SSH remote mode live for you? Evidence above
   says this machine is local-only.
3. **O-6 resume** — yes/no. Cross-reload resume (survives a page reload)?
   Costs an IndexedDB store + a browser-side plaintext cache; not in your
   original words. `indexedDB` is `undefined` under jsdom and
   `fake-indexeddb` is not a dependency (re-verified today:
   `node -e "typeof indexedDB"` → `undefined`), so it also adds a devDependency
   and a `test-setup.ts` import.
4. **Branching** — Finding A invalidates the design's recommendation. My
   recommendation is **B′**: Slice 1 as commits on `files/explorer2`, folded
   into #308's eventual merge.

---

## 6. Ready-to-go once answered

Nothing is written. When unblocked, the first Slice-1 test (RED) is:

- `readBoundedFile` reads at most N bytes **without** allocating the whole
  file — assertable by size probe on a large sparse file, plus the existing
  truncation semantics preserved;
- the viewer ceiling and download ceiling are **independent** — a
  `mkLocalFileExplorer` with a small read ceiling and a large download ceiling
  must let the viewer truncate while the download does not.

Gates to run at the end: `make check` (build + `cabal test` + `hlint` +
`npm test`). Baseline to compare against: 4294 examples / 0 failures /
41 pending; 1030 frontend tests / 43 files.

---

## 7. CI failure on this branch — diagnosed and fixed (`df96b6b`)

### 7.1 It was not a Files-branch regression

`SendSpec.hs`, `Send.hs`, `TurnEngine.hs` and `Transcript.hs` are
**byte-identical to `origin/main`** (`git diff --stat origin/main HEAD` →
empty), and the failing test exists verbatim on `main`. The branch inherits
the defect; it does not introduce it.

### 7.2 What the failure actually said

```
test/Seal/Gateway/SendSpec.hs:1455:12
  expected: 3   but got: 2
```

Line 1455 is `n1 \`shouldBe\` n2`, so hspec printed expected = `n2` = 3 and
got = `n1` = 2. **The turn count grew from 2 to 3 inside the 200 ms window.**
Nothing was stranded: the follow-up wake-up turn did run. The assertion fired
mid-chain.

`unchangedAfter` was unsound by construction — "two equal samples 200 ms
apart" shows only that the chain did not move in that window, not that it had
finished. Reproduced directly: with a value that reaches 3 at 400 ms, the old
helper yields `n1=2 n2=2`, calls it stable, and the next assertion reports
`expected: 3, but got: 2` — CI's exact message.

### 7.3 Why only Linux CI

The wake chain runs inside the parent turn's release action, so its duration
tracks machine speed. CI runs `cabal test --enable-coverage`; HPC
instrumentation plus Linux made the slow tail exceed 200 ms. Evidence, same
commit `362bc73`: **x86_64-linux FAILED, aarch64-darwin PASSED** (4294 / 0
failures there). Locally the test passed 25/25 isolated, 15/15 with all 14
CPUs saturated, and the full suite passed with CI's seed 1886131818 — so it
could not be caught by load alone, only by instrumentation on Linux.

### 7.4 The fix

`unchangedAfter` deleted. Replaced with helpers that use information the test
already has — **the expected value**:

| Helper | Contract |
|---|---|
| `awaitValue` | poll until the value equals `want`, then require it to hold 300 ms |
| `awaitStable` | poll until the value holds still (bound-only sites, final count unknown) |
| `settlesTo` | the assertion form, 5 s deadline |

Waiting for a *known-expected* value is sound where waiting for "two equal
samples" is not: a genuinely stranded completion — the failure the suite
exists to catch — still fails, at the deadline instead of on the first
sample. The trailing hold catches a chain that overshoots by one turn.

All five `unchangedAfter` sites converted (1454, 1487, 1528, 1571, 1589).
Three regression tests pin the helper's contract: late-arriving value (the CI
shape), value never reached, value overshoots.

### 7.5 Verification

| Gate | Result |
|---|---|
| `cabal test --seed 1886131818` | 4297 / 0 failures / 42 pending |
| `cabal test --enable-coverage` (CI's command) | 4297 / 0 failures / 41 pending |
| `hlint src/ test/` | No hints |
| `npm test` | 1030 tests / 43 files |
| GitHub CI run 43562881061 | **x86_64-linux success, aarch64-darwin success** |

### 7.6 Trap that cost time

Running a coverage build and a plain build into the same `dist-newstyle`
concurrently produced `renameFile: ... does not exist` — the race handoff §6
warns about, met from the other side. It is not a code failure; check for a
concurrent build before believing a red gate.

Also: `setsid` does not exist on this macOS box, so `setsid nohup … &`
silently launches nothing. Use `nohup script.sh &`.
