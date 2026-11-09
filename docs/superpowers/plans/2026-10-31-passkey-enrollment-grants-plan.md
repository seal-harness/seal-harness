Title: Passkey enrollment grants — implementation plan (TDD)
Status: ready
Date: 2026-10-31
Design: `docs/superpowers/specs/2026-10-31-passkey-enrollment-grants-design.md` (rev 5)
Branch: `gateway/passkey-access-control`

Every step is RED → GREEN → REFACTOR, in order. A step is done when the named
test fails for the stated reason, then passes, and `make check` is green before
the commit. Do not batch steps into one commit.

## Preconditions

- Baseline: `make check` green on the current branch (`5428e08` is W0, already
  landed).
- Run a focused test (never pipe a Haskell binary through `head`/`tail` —
  SIGPIPE; always redirect):

  ```
  nix develop --command cabal test --test-options='--match "<name>"' > t.log 2>&1
  echo "EXIT=$?"; grep -nE "FAILED|examples, " t.log
  ```

- **Merge hotspots** — keep edits minimal, rebase before opening the PR:
  `seal-harness.cabal` (`exposed-modules:`, test-suite `other-modules:`),
  `test/Main.hs`.
- New module ⇒ wire it in those three places **before** writing its test.
- No `--no-verify`, no force-push, no partial functions (`head`, `fromJust`,
  `!!`), `Either Text` by default; a bespoke ADT only where the caller
  pattern-matches it (`BootRefusal`, `GrantDenied`, `CredentialAdmin`,
  `ModeRaise`).

---

## W1 — credential store split (fixes design §1.4, §1.7)

`acfcCredentials` must **not** be removed until step 1.9 is green. Until then the
gateway still reads credentials out of `security.toml`, so removing the field
earlier silently downgrades every migrated install to `unconfigured`.

### 1.1 `credentials.toml` codec round-trips

- **Test** `test/Seal/Config/CredentialsSpec.hs`
  `it "round-trips a credential map"` — QuickCheck property
  `decode (encode c) == Right c` over `Map Text CredentialFileConfig` with
  base64url keys and bounded text, `Arbitrary` newtype-wrapped.
- **GREEN** new `src/Seal/Config/Credentials.hs`: `credentialsCodec`,
  `loadCredentials`, `saveCredentials`, `credentialsFilePath` use. Export
  `fixNode` from `Seal.Config.Security` and reuse it (do not duplicate).
- **Verify** match `credentials.toml`.

### 1.2 An idiomatic file decodes non-empty

- **Test** `it "decodes a hand-written [credentials.<id>]-only file"` with a
  literal TOML fixture (a bare `version = 1` plus one table, **no** explicit
  `[credentials]` header). Not `Toml.encode` output — the encoder always writes
  the header and hides the implicit-node bug (learnings 2026-10-30 §4).
- **RED reason** must be "decoded as empty", not a parse error.
- **GREEN** a root-`credentials` normaliser.

### 1.3 Writer refusal semantics

- **Test** `it "create refuses an existing file, update refuses a missing one,
  both refuse an empty result"` — three assertions on bytes.
- **GREEN** `createCredentialsFile` (`O_EXCL`) and `updateCredentialsFile`
  (`Either` in the callback) in `Seal.Config.Credentials`, behind a unique temp
  name and `securityWriteLock`.

### 1.4 `CredentialAvailability`

- **Test** in `test/Seal/Security/AccessControlSpec.hs` (existing file), 5 cases:
  0 creds / all orphaned / mixed / all matching / `Nothing` rpId.
- **GREEN** `CredentialAvailability` + `credentialAvailability` in
  `Seal.Security.AccessControl` (it must not depend on `Grant`).

### 1.5 Legacy layout is a refusal, not a silent drop

- **Test** `test/Seal/Config/MigrateSpec.hs` or a new `CredentialsSpec` case:
  a raw `security.toml` containing `[access_control.credentials.<id>]` ⇒
  `preflight` returns `Left BrLegacyLayout`. Include the **dotted-key** spelling
  (`[access_control]` + `credentials.<id>.public_key = …`), which a header grep
  misses.
- **GREEN** a retained `LegacyAccessControlFileConfig` codec; `preflight`
  decodes `biSecurityRaw` with it.

### 1.6 The chokepoint refuses to drop credentials

- **Test** `it "PreserveCredentials refuses a legacy credential table"` —
  `saveSecurityConfig … PreserveCredentials` returns `Left` and the file bytes are
  unchanged.
- **GREEN** `WriteMode` + `saveSecurityConfig :: … -> WriteMode -> IO (Either Text ())`;
  thread `PreserveCredentials` through `updateSecurityConfig`,
  `updateAccessControlSection` and `clearAccessControlSection`. Flatten
  `Migrate.hs:123`'s `try @SomeException` (now `Either SomeException (Either Text ())`).

### 1.7 No collateral damage on rewrite

- **Test** `it "preserves every top-level table across a write"` — compare the
  **recursively walked table-path set** (`Toml.parse` + `Toml.tomlTables`) before
  and after, on both an explicit and a dotted-key credential-free fixture. Keep
  the fixture to codec-owned tables (`untrusted_execution`, `access_control`).
- **GREEN** no change expected; if it fails, the codec is dropping a section —
  fix that, not the test.

### 1.8 `bootPlan` is total

- **Test** `test/Seal/Config/BootPlanSpec.hs`, one case per row of design §10,
  asserting the `BootRefusal` **constructor** (and message where two constructors
  could both fire). Includes `BrModeInvalid` from the `mode = "off"` fixture
  currently covered by `SecurityAccessControlSpec.hs:173-177` — **port** that
  test, do not delete it.
- **GREEN** `BootInputs`, `CredentialsPresence`, `BootRefusal`, `BootPlan`,
  `preflight`, `bootPlan`; `resolveAccessControl` loses mode-defaulting and
  credential decoding.

### 1.9 The handle consumes `BootPlan`

- **Test** `it "serves a credential that is absent from disk"` — build a
  `BootPlan` naming a credential, point paths at a directory with no
  `credentials.toml`, assert the handle authorizes it. Then mutate the file and
  assert the handle is unaffected (proves it did not re-read).
- **GREEN** `newAccessControlHandle` takes `BootPlan`. **Now** remove
  `acfcCredentials` and rewire `persistRegistration`, `claimSignCount`,
  `deleteCredential`.

### 1.10 `migrate-credentials`

- **Test** `it "moves every credential and removes the table"` — ids, labels,
  counters, `created_at`, `rp_id` preserved, `added_via = "legacy"`; idempotent;
  refuses without `--yes`; refuses an existing `credentials.toml` without
  `--force`; **never overwrites** an existing file even with `--force`.
- **GREEN** `AcMigrateCredentials` + `runAccessControl` branch (W1 owns only this
  constructor).

### 1.11 Sign-count persistence moves and fails loudly

- **Test** `it "a failed credential write does not mint a session"` and
  `it "a successful login persists the counter before the session"`.
- **GREEN** `persistSignCount` → `updateCredentialsFile`; surface the `Either`.

### 1.12 Last-usable delete guard lives inside the writer

- **Test** `it "refuses the last usable credential"`, `it "removes an orphan
  while one usable remains"`, `it "applies in open mode"`, and a concurrency
  case (two deletes cannot reach zero).
- **GREEN** the guard inside `updateCredentialsFile`'s callback; `Nothing` rpId ⇒
  every credential usable.

---

## W2 — `rp_mismatch` (fixes design §1.6)

### 2.1 Quantifier

- **Test** `it "is false with zero credentials"`, `it "is false when any
  credential is usable"`, `it "is true only when all are orphaned"`.
- **GREEN** `rpMismatch = credentialAvailability rpId creds == UnusableOnly`.

### 2.2 Recomputation

- **Test** `it "recomputes after a registration"` and `it "recomputes after a
  deletion"` — assert the flag flips both directions within one handle lifetime.
- **GREEN** derive on every mutation; delete the hardcoded `acsRpMismatch =
  False`.

---

## W3 — grants (design §7)

### 3.1 Grant record and codec

- **Test** `test/Seal/Security/EnrollmentGrantSpec.hs` — grant JSON round trip,
  unknown/missing fields ⇒ treated as absent (not a boot refusal), `CliWindow`
  has `token_sha256 = Nothing`.
- **GREEN** `Seal.Security.EnrollmentGrant` types + load/save.

### 3.2 `findAuthority` — including the B-1 regression

- **Test** one case per row of design §7.2 (36 combinations, driven by a table),
  plus: match, mismatch, absent, **session-mismatch**, and
  `Nothing` + non-window ⇒ denied. The named regression:
  `it "a cookie-only client with no header cannot redeem a live assertion grant"`
  — assert `Left StepUpRequired` and that no credential is created.
- **RED reason** for the regression: rev 4's semantics would return `Assertion`.
- **GREEN** `findAuthority`.

### 3.3 `enrollmentAuthority` is total

- **Test** the 11-row matrix over all 36 inputs; the `cli_window` +
  `UnusableOnly` case must be `Left GrantRequired` (B-2).
- **GREEN** `enrollmentAuthority` with `GrantContext`.

### 3.4 Claim exclusivity and rebinding

- **Test** two concurrent verifies with one grant ⇒ one credential and one
  `grant_invalid`; a failed verify compare-and-deletes only its own claim, and
  the next `options` rebinds; a 500 `write_failed` also rebinds; a grant bound to
  challenge A cannot redeem B; 119 s / 119.5 s / −1 s boundaries.
- **GREEN** `O_CREAT|O_EXCL` claim record, `effective_deadline`, conditional
  grant write-back keyed on `grant_id`. Concurrency exemplars:
  `RegistrySpec.hs:127`, `VaultSpec.hs:164`.

### 3.5 Cross-process freshness

- **Test** `it "honours a grant written by another process"` — construct a
  handle, write a grant file **outside** it, assert the next `options` succeeds
  with no restart. This is the test that would have caught a cached grant.
- **GREEN** read the grant file per request; never cache it in `achState`.

### 3.6 Boot does not clobber

- **Test** `it "preserves an unexpired grant at startup"` — mint one, boot, assert
  the file is unchanged and the banner reports its `minted_via` + TTL rather than
  printing a new token.
- **GREEN** mint only when no unexpired grant is outstanding.

### 3.7 `enroll` CLI

- **Test** via `runAccessControl` returning `ExitCode`: token to stdout, hints to
  stderr; 0600 files; second outstanding grant refused without `--force` with the
  remaining-TTL message; `--cancel` removes grant + claim + token file; `--ttl`
  rejects a bare number; the full flag matrix; exit codes 0/1/2; `--no-token`
  refuses on a non-loopback **bind**, an unresolvable origin, and a
  non-`NoCredentials` store.
- **GREEN** `AcEnroll`/`AcDisable`, `enrollGrant :: SealPaths -> GrantSource ->
  NominalDiffTime -> IO (Either Text MintedGrant)`.

### 3.8 Daemon liveness lock

- **Test** `it "disable --yes refuses while serve holds the lock"` and
  `it "a crashed daemon does not leave a false refusal"` (advisory `flock`, so
  the kernel releases it).
- **GREEN** `serveLockPath` in `Seal.Config.Paths`; `serve` takes
  `flock LOCK_EX` for its lifetime; `disable`/`reset`/`migrate-credentials` probe
  it.

### 3.9 `enrollCredential` atomicity

- **Test** `it "a failed credential write restores the mode"` and
  `it "two interleaved ceremonies cannot leave mode=none beside a credential"`.
- **GREEN** `enrollCredential` under one `securityWriteLock`, `ModeRaise`
  witness, CAS restore.

---

## W4 — endpoints and banner (fixes design §1.1, §1.2, §1.3, §1.5)

### 4.1 `enroll/*`

- **Test** `enroll/options` returns the `login/options` shape with
  `allowCredentials` restricted to **usable** credentials; refuses in
  `unconfigured`/`open`/`UnusableOnly`; `enroll/verify` requires an unconsumed
  `stepup` challenge for that session and a verified assertion against a usable
  credential; no failure body carries `grant_token`/`grant_expires_at`; an
  orphaned or unknown credential ⇒ `grant_invalid`.
- **GREEN** `enroll/*`, with a `Maybe` session-key field on `Challenge` (today it
  has only `chIssuedAt` and `chKind`) and kind as an ADT
  (`ChallengeCreate | ChallengeGet | ChallengeStepUp`).

### 4.2 Endpoint matrix and B-1 negative case

- **Test** `test/Seal/Gateway/AccessControlSpec.hs` (the harness — **not**
  `ApiTestHarness`, which wraps `apiApp`; auth routes are applied outside it at
  `Server.hs:68`). Every §7.2 row × the four admin/enroll endpoints, plus
  cookie-only / malformed / unknown-credential / orphaned-credential assertions.
  Fresh handle per case (`challengeBurst` is 20); one helper to seed
  `credentials.toml`.
- **GREEN** endpoint wiring; confirm `credentials/*` reaches the handler (the
  middleware short-circuits all `/api/auth/*` to `authApp`).

### 4.3 `waive` removal

- **Test** `it "has no waive endpoint"` ⇒ 404; `it "no HTTP path lowers the mode"`.
- **GREEN** delete the route, the dead `["api","auth","waive"]` allowlist entry,
  `disable --yes`.

### 4.4 Banner

- **Test** with the injected sink: `UnusableOnly` mints and prints; healthy
  `passkey` prints neither; off-TTY prints the **path** and not the token;
  `mode = "none"` enrollment raises then writes, and a failed write restores.
- **GREEN** `printAccessControlBannerTo` with `ChannelCaps`, a TTY `Bool` and a
  `Text -> IO ()` sink, moved out of `Seal.Command.Serve`.

### 4.5 `CredentialAdmin`

- **Test** `GET`/`DELETE` in `open` mode succeed unauthenticated; in `passkey`
  with no session and no token ⇒ `403 grant_required`; a window or assertion grant
  is refused.
- **GREEN** the predicate + wiring.

---

## W5 — audit

- **Test** closed field set (a table-driven case asserting no request-derived
  value appears); `grant_invalid` aggregated per `(event, source, minute)`;
  backoff before emit; log opened 0600, refusing a symlink; state-changing events
  in a separate sink.
- **GREEN** `Seal.Gateway.Audit`.

## W6 — frontend

One shared status hook consumed by both `AccessGate` and `AccessView`.

- `createPasskey` target (`bootstrap`/`add`); callers `AccessGate.tsx:92`,
  `AccessView.tsx:42`.
- `step_up_required` restart-the-ceremony, branched on `authenticated`.
- `grant_required` keeps the field where it helps + "Check again"; `grant_invalid`
  keeps the text and stops sending the token.
- Gate re-check + focus re-fetch.
- `open`-mode `/access`; Remove disabled on the last usable.
- Delete the waive button, `waive()`, styles; branch `CapabilityNote` copy by
  surface; lost-device notes name `enroll` before `reset`.
- Two distinct prompts.
- vitest cases for each; `AccessGate.test.tsx` and `SignOutButton.test.tsx`
  fixtures gain the new status fields.

## W7 — docs

`README.md` (including "enroll before exposing the port", design §4 R1),
`CHANGELOG.md` ("Upgrading": boot-grant TTL, removed `waive`, migration),
commented `security.toml` / `credentials.toml` examples.

---

## Finish

1. `make check` green (build + test + lint + frontend-test).
2. Rebase on `main`; keep the `.cabal` / `test/Main.hs` diff minimal.
3. `self-reflect`, commit the knowledge-base update.
4. Draft PR, body `Closes #NN`, one logical change per commit.

**Known deviations to state in the PR:** `--no-token` is loopback-bind-only with
no override; `POST /api/auth/waive` is removed (CLI-only `disable --yes`); the
boot grant gains a 10-minute TTL.
