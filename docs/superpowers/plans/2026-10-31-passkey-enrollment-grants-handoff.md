# Handoff — passkey enrollment grants

**Date**: 2026-10-31
**Branch**: `gateway/passkey-access-control`
**Design**: `docs/superpowers/specs/2026-10-31-passkey-enrollment-grants-design.md` (rev 5)
**Plan**: `docs/superpowers/plans/2026-10-31-passkey-enrollment-grants-plan.md`
**Status**: design settled, plan written, **no implementation started** (W0 excepted)

Read the plan first, then the design §3–§7. This document only carries the
context you cannot get from either.

---

## 1. Where things stand

| Commit | What |
|---|---|
| `08b0da9` | test: pins the setup-code form the browser actually sends (regression guard) |
| `5428e08` | **fix(security)**: `mkSafePath*AllowAbs` rejected a blocked name only on the requested path, so a symlink into `~/.seal` resolved to `Right`. Fixed + two tests |
| `94f0c6a` | docs: design rev 4 (superseded) |
| `9eee205` | docs: design **rev 5** (current) |
| `4658862` | docs: **TDD plan** (current) |
| `*` | handoff (this file) |

Only `08b0da9` and `5428e08` change code. `make check` was green after both.

Work units W1–W7 are unimplemented. W0 (the path fix) is done.

## 2. Start here

1. `make check` to confirm a green baseline.
2. Read the plan's **Preconditions** and **W1**.
3. The plan's W1 is large (store split + `WriteMode` + `BootPlan` + legacy codec
   + migration). A split into **W1a** (codec, writers, `CredentialAvailability`,
   no boot changes) and **W1b** (`preflight`/`BootPlan`, handle rewire,
   `acfcCredentials` removal) was proposed but **not decided**. Decide before
   starting; W1a/W1b keeps every commit shippable and the hotspot diff small.

## 3. Do not get these wrong

**3.1 Authority is always presented.** Design §5 invariant 2 / §7.2. An earlier
revision let an *absent* `X-Seal-Enroll-Token` fall through to a session-held
grant, which meant a stolen cookie could redeem the victim's live 120 s
assertion grant by omitting a header. `findAuthority` must return
`Left StepUpRequired` for `Nothing` unless the live grant is `CliWindow`. The
regression test in plan step 3.2 is the guard.

**3.2 `CliWindow` exists only in `NoCredentials`.** Not in `UnusableOnly` — that
is the state an attacker who can change `origin`/`rp_id` aims to create.

**3.3 Do not remove `acfcCredentials` before plan step 1.9.** Until the handle
consumes a `BootPlan`, the gateway still reads credentials from
`security.toml`; removing the field first silently downgrades every migrated
install to `unconfigured` (setup screen, all passkeys ignored).

**3.4 `emptyAccessControl` defaults to `acfcMode = Just "none"`**
(`Config/Security.hs:367-373`). Any write to a section-less file therefore
records an *implicit* "off". It must become `Nothing` (plan 1.6). This is the
single easiest way to violate invariant 1.

**3.5 The bootstrap race is an accepted risk, not a bug.** Design §4 R1. It was
reviewed, argued, and accepted by the product owner with stated reasoning:
narrow (token or local access), loud (grant consumed by the first success),
reversible (`reset --yes`). Do not "fix" it by adding a token requirement to the
first enrollment — that reintroduces the friction the feature exists to remove.
If you think it should change, raise it; do not ship it.

## 4. Empirical facts — verified in this session, do not re-litigate

**4.1 `generateToken` emits lowercase hex.** Three independent reviewers
asserted it was uppercase, which would have meant every browser-entered setup
code failed. A test disproved it: presenting `T.toUpper token` returns **403**,
`T.toLower` returns **200**. The design keeps a `T.toLower` comparison as a
harmless safety net and a regression guard pins the contract. If you see a
review comment claiming the casing is broken, point at `08b0da9`.

**4.2 The auth allowlists do not gate HTTP auth routes.**
`accessControlMiddleware` routes **every** `/api/auth/*` path to `authApp` before
consulting `unconfiguredAllow`/`passkeyAllow` (`isAuthPath` short-circuit).
Those lists only affect the WebSocket handshake and non-auth paths. So "the
handler is the sole gate" is already true, and adding `credentials/*` to an
allowlist does nothing.

**4.3 `ApiTestHarness` cannot reach auth routes** — it wraps `apiApp`, and the
auth middleware is applied outside it (`Gateway/Server.hs:68`). Use
`test/Seal/Gateway/AccessControlSpec.hs` (`withHome`, `gated`, `runApp`,
`postReq`, `jsonField`). Each case needs a fresh handle: `challengeBurst` is 20
per handle.

**4.4 `migrateSecurityConfig` is not a threat.** An earlier review round claimed
it could destroy a legacy credential layout; it cannot. It writes
`security.toml` only when the file is *absent* (its Case 1), which cannot
coexist with legacy credentials. The writer that matters is `saveSecurityConfig`
— the chokepoint the design uses.

**4.5 `blockedNames` includes `.seal` and now checks the *canonical* path** for
the four local `mkSafePath*` variants (`5428e08`). The two pure
`mkSafePathRemote*` variants cannot canonicalise a remote path and are out of
scope. `SHELL_EXEC` is unaffected (unrestricted `/bin/sh -c`) — see design §4 R2.

## 5. Traps that cost time here

- **SIGPIPE.** Never pipe `cabal`/`hlint`/`ghcid` through `head`/`tail`; the RTS
  ignores SIGPIPE and the writer hangs. Redirect to a file, then read it.
- **Focused test run**: `nix develop --command cabal test --test-options='--match "X"' > t.log 2>&1`.
- **Merge hotspots**: `seal-harness.cabal` (`exposed-modules:`, test-suite
  `other-modules:`) and `test/Main.hs`. New module ⇒ wire in all three places
  *before* writing its test, or it will not compile.
- **tomland implicit tables** (learnings 2026-10-30 §4): `[credentials.<id>]`
  with no explicit `[credentials]` header decodes as **empty**. Test with a
  hand-written fixture, never `Toml.encode` output — the encoder always writes
  the header and hides the bug. Same for `[access_control.credentials.<id>]`.
- **`writeSecretFile` truncates** — it cannot be reused for the append-only audit
  log.
- **`securityWriteLock` is an in-process `MVar`**, not cross-process. Cross-process
  safety rests on unique temp names + atomic rename + `O_EXCL`. Also: it is
  non-reentrant, so `enrollCredential` must take it **once** (design §6.1); calling
  the two writers from inside a lock you already hold self-deadlocks.
- **GHC flags are `-Werror`.** An unused top-level binding (e.g. a helper left
  behind by a refactor) is a build failure, not a warning.

## 6. Review history — what was argued and settled

Four gate rounds, five reviewers each. No round reached unanimous approval; the
fifth was waived by decision after rev 5 fixed the two high-severity items.
Round-4 resolutions are tabulated in design §17; rounds 1–3 are summarised there
too.

Two findings were **withdrawn** after checking the code: the base16 casing
asymmetry (§4.1 above) and `migrateSecurityConfig` being a threat (§4.4). Both
had been stated confidently and in detail by reviewers. Verify factual claims
from review against the code or a test before acting on them.

## 7. Open questions (design §20)

1. Should `disable`/`reset` signal a running daemon rather than refuse?
2. `label` is hardcoded `"passkey"`, so `/access` shows N identical rows.
3. `registerOptions` mints a fresh random user handle per ceremony (`:621`); a
   stable operator handle would let a synced passkey update rather than
   accumulate.
4. `enrollment_via` is a snapshot; a push frame would remove the "Check again"
   action.
5. **Undecided**: the W1a/W1b split (§2 above).

## 8. Behaviour changes to state in the PR

- `--no-token` is confined to a loopback **bind** + loopback origin +
  `NoCredentials`, with no override (`--allow-remote-enrollment` does not exist).
- `POST /api/auth/waive` is **removed**; `seal access-control disable --yes` is
  the only way to turn access control off, and it is CLI-only.
- The boot-minted grant gains a **10-minute TTL** (previously process lifetime).
  Booting and enrolling a week later now needs one
  `seal access-control enroll`.
- Credentials move from `security.toml` to `~/.seal/credentials.toml`; a legacy
  layout makes `seal serve` exit 1 naming `seal access-control
  migrate-credentials`.
- `rp_mismatch` changes from "some credential differs" to "no credential is
  usable", so it clears after a successful re-enrollment.
