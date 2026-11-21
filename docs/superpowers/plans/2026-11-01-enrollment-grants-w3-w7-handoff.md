# Handoff — enrollment grants, W3 remainder → W7

**Date**: 2026-11-01
**Branch**: `gateway/passkey-access-control` (PR #289, draft)
**Design**: `docs/superpowers/specs/2026-10-31-passkey-enrollment-grants-design.md` (rev 5)
**Plan**: `docs/superpowers/plans/2026-10-31-passkey-enrollment-grants-plan.md`
**Previous handoff**: `docs/superpowers/plans/2026-10-31-enrollment-grants-w1-w3-handoff.md`

Read the previous handoff first; this file only carries what changed.

## 1. State

`make check` green at every commit: **3653 examples, 0 failures**, `hlint: No
hints`, **734 vitest tests**, `tsc --noEmit` clean.

| Commit | Step | What |
|---|---|---|
| `6dd47f8` | §12 | `runAccessControl` returns `ExitCode`; refusals to stderr |
| `1028cbc` | 3.8 | `state/serve.lock`, fcntl record lock, probed by reset/migrate |
| `56fc388` | 3.7 | `enroll` / `disable` CLI, `parseTtl`, `enrollGrant`, `cancelGrant` |
| `0712c12` | 3.6 | boot preserves an outstanding grant; `NewAccess.naGrant` |
| `7093288` | W4 | grant-gated endpoints, `enroll/*`, `waive` removed, `CredentialAdmin`, banner |
| `ceae355` | W5 | `Seal.Gateway.Audit` + wiring |
| `594cbb6` | W6 | frontend: one status payload, token field, step-up, no waive |
| `252be8f` | W7 | README + CHANGELOG |

## 2. What a fresh session cannot infer from the code

- **`unix` 2.8.8.0 has no `fileLock`.** `System.Posix.IO` here exposes only
  `getLock`/`setLock`/`waitToSetLock`, and `FileLock` is a *type synonym* for
  `(LockRequest, SeekMode, FileOffset, FileOffset)`, with `SeekMode` coming from
  `GHC.IO.Device`, not from `System.Posix.IO`. `openFd` takes
  `FilePath -> OpenMode -> OpenFileFlags -> IO Fd` (the mode lives in
  `creat`). `Seal.Security.DaemonLock` documents all of this.
- **POSIX record locks do not conflict within a process**, so `daemonHoldsLock`
  cannot see a lock the *same* process holds. Both lock specs fork a child.
- **The claim protocol lives in `registerOptions`**, not in `enroll/options`:
  only the file-backed grant is bound to a challenge (`bindGrant`), because an
  assertion grant is already single-use through the challenge and the session.
- **`GrantMinted` is both a phase and an audit event.** The gateway imports
  `Seal.Gateway.Audit qualified as Audit` for that reason.
- **The audit `ts` field is hand-rolled** (`civilFromDays`) rather than
  `formatTime`, so the hot path stays allocation-light; it is UTC, second
  resolution, `Z`-suffixed.

## 3. Deliberate deviations from the plan

| Plan said | Done instead | Why |
|---|---|---|
| `runAccessControl :: AccessControlCmd -> ChannelCaps -> SealPaths -> IO ExitCode` | `AccessControlAction -> IO ExitCode`, plus `runAccessControlWith :: SealPaths -> …` | nothing in the CLI prompts, so `ChannelCaps` would be dead weight; the explicit-paths variant is what makes the spec hermetic |
| `printAccessControlBannerTo :: ChannelCaps -> Bool -> (Text -> IO ()) -> …` | `printAccessControlBannerTo :: Bool -> (Text -> IO ()) -> …` | same reason — the sink is the interface |
| `NewAccess.naSetupCode` | `naToken` (+ `naGrant :: Maybe GrantBanner`) | the setup code is gone; the field is now "the token minted at this boot" |
| `enrollGrant :: SealPaths -> GrantSource -> NominalDiffTime -> IO (Either Text MintedGrant)` | … `-> Bool {- force -} -> …` | `--force` is the mint-time decision; passing it keeps the refusal message (remaining TTL) in one place |
| `credentialAvailability`-based delete guard "inside the writer" | guard inside the writer, closing over `acsRpId` from the handle | the callback sees `Map Text CredentialFileConfig`, which has no notion of the boot's rpId |

## 4. Not done / next

1. **`--no-token`'s "unresolvable origin" refusal is only reachable through
   `bootPlan`'s `BrCoordinatesInvalid`** — covered indirectly (the refusal
   message embeds it), not by a dedicated spec. The other two `--no-token`
   refusals (non-loopback bind, non-empty store) have named tests.
2. **3.5 cross-process freshness** — `resolveEnrollment` and
   `accessControlStatusJson` re-read the grant file per request, so the
   *behaviour* is there, but the named regression test ("honours a grant written
   by another process") is still missing. It is a two-process test like
   `DaemonLockSpec`'s.
3. **W1 1.11 / 1.12 named tests** — 1.11 (persist-then-mint ordering) is now
   exercised indirectly by the login ceremony spec; 1.12 (last-usable delete)
   has a named test in `AccessControlSpec`. Both could be sharpened.
4. **The claim protocol has no concurrency test.** `bindGrant`'s `O_EXCL` and
   `grantPermits`' deadline are unit-covered through the endpoint tests (one
   binder, one winner), but two racing verifies with one grant are not
   exercised; plan 3.4's exemplar still stands as the model.
5. **W5's "backoff before emit" is tested on `admitRefusal` only**, not through
   a request flood.
6. **The SPA does not yet render `grant_invalid` as a distinct message on
   `/access`** (the gate does); the Access view shows the server's prose.

## 5. Behaviour changes to state in PR #289

Beyond the previous two handoffs' lists:

- `POST /api/auth/waive` is gone; `disable --yes` is the only way off.
- `X-Seal-Setup-Token` → `X-Seal-Enroll-Token`; `#setup=` → `#enroll=`.
- `seal access-control status` exits 1 when the boot plan refuses.
- `reset --yes` also deletes `credentials.toml`, the grant, its claims and the
  token file, and refuses while `seal serve` runs.
- `serve` refuses to start when another daemon holds `state/serve.lock`.
- A healthy `passkey` boot mints nothing; a preserved grant is reported with
  `minted_via` and remaining TTL instead of being replaced.
- `GET /api/auth/status` gained `enrollment_via`, `usable_credentials`,
  `orphaned_credentials`; `GET /api/auth/credentials` returns `added_via`.
- Deleting the last **usable** credential is refused in every mode (an orphan
  is still removable).
