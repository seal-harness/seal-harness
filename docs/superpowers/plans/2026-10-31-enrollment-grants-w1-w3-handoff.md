# Handoff — enrollment grants, implementation progress (W1 → W3)

**Date**: 2026-10-31
**Branch**: `gateway/passkey-access-control` (PR #289, draft)
**Design**: `docs/superpowers/specs/2026-10-31-passkey-enrollment-grants-design.md` (rev 5)
**Plan**: `docs/superpowers/plans/2026-10-31-passkey-enrollment-grants-plan.md`
**Previous handoff**: `docs/superpowers/plans/2026-10-31-passkey-enrollment-grants-handoff.md`

This document covers what has landed since the previous handoff, what a fresh
session cannot infer from the code, and what to do next. Read the plan first,
then design §3–§7; this file only carries what those two cannot.

---

## 1. State

`make check` green at every commit: **3602 examples, 0 failures**, `hlint: No
hints`, **728 vitest tests**. Working tree clean.

| Commit | Step | What |
|---|---|---|
| `6364786` | 1.1 | `credentials.toml` codec + atomic `0600` store |
| `1abd4f0` | 1.2 | idiomatic `[credentials.<id>]`-only file decodes non-empty |
| `be55cfd` | 1.3 | writer refusal semantics (`O_EXCL`, never-empty, round-trip check) |
| `a71bdc3` | 1.4 | `CredentialAvailability` (3 values, not a boolean) |
| `686c3d3` | 1.5 | legacy-layout detection |
| `d03ebb6` | 1.6 | `WriteMode` chokepoint — no write may drop legacy credentials |
| `d328312` | 1.7 | **fix**: dotted-key sections were silently dropped by every rewrite |
| `6a23f9d` | 1.8 | `preflight` / `bootPlan` — the §10 table as a pure total function |
| `38a18d0` | 1.9 | handle built from `BootPlan`; `acfcCredentials` removed; writers rewired |
| `a9fca5b` | 1.10 | `access-control migrate-credentials` |
| `a362f67` | W2 | `rp_mismatch` derived from the map, not stored |
| `c94e360` | 3.1–3.2 | grant record + codec + `findAuthority` (B-1) |
| `304e792` | 3.3 | `enrollmentAuthority`, total over 36 combinations (B-2) |
| `696aaa5` | 3.1 | grant file store (`state/enrollment-grant.json`) |
| `e161915` | 3.4 | exclusive claims, deadline rule, challenge binding |
| `e1d8736` | 3.9 | `enrollCredential`: raise + write under one lock |

Both gate-round-4 high-severity findings (**B-1**, **B-2**) are closed with
named tests.

### Not done

- **3.5** cross-process freshness — needs a consumer; belongs with W4.
- **3.6** boot does not clobber an outstanding grant — needs the mint path (3.7).
- **3.7** `enroll` CLI, **3.8** `serve.lock` — both blocked on the `ExitCode` seam.
- **W1 1.11 / 1.12 named tests** — behaviour landed in 1.9; the tests need
  endpoint access (see §5).
- **W4–W7** — endpoints/banner, audit, frontend, docs.

---

## 2. Module map (what now lives where)

**New**: `Seal.Config.Credentials`, `Seal.Config.BootPlan`,
`Seal.Security.EnrollmentGrant`, plus specs
`test/Seal/Config/CredentialsSpec.hs`, `test/Seal/Config/BootPlanSpec.hs`,
`test/Seal/Security/EnrollmentGrantSpec.hs`.

**Deleted** (do not resurrect): `resolveAccessControl`, `ResolvedAccessControl`,
`BootDecision` / `bootDecision` / `bootDecisionMessage`, `acfcCredentials`.

**Key signatures** (all landed and tested):

```haskell
-- Seal.Config.Security
saveSecurityConfig :: FilePath -> SecurityConfig -> WriteMode -> IO (Either Text ())
data WriteMode = PreserveCredentials | DropCredentials
hasLegacyLayout     :: Text -> Bool
readLegacyCredentials :: Text -> Either Text (Map Text CredentialFileConfig)
tomlKeyPaths        :: Toml.TOML -> [[Toml.Piece]]     -- value-bearing paths only
decodeSecurityConfig :: Text -> Either Text SecurityConfig
securityWriteLock   :: MVar ()                        -- exported, NON-REENTRANT
data ModeRaise                                       -- constructor not exported
raiseMode   :: FilePath -> IO (Either Text ModeRaise)      -- caller holds the lock
restoreMode :: FilePath -> ModeRaise -> IO (Either Text ()) -- caller holds the lock

-- Seal.Config.Credentials
loadCredentials  :: FilePath -> IO (Either Text (Maybe CredentialsFile))
createCredentialsFile / updateCredentialsFile          -- take the lock
createCredentialsFileUnlocked / updateCredentialsFileUnlocked  -- do not
migrateLegacyCredentials :: FilePath -> FilePath -> Bool -> IO (Either Text MigrationOutcome)
enrollCredential :: FilePath -> FilePath -> Map Text CredentialFileConfig -> IO (Either Text ())

-- Seal.Config.BootPlan
preflight :: SealPaths -> IO (Either BootRefusal BootInputs)
bootPlan  :: BindCoordinates -> BootInputs -> Either BootRefusal BootPlan
bootRefusalMessage :: BootRefusal -> Text

-- Seal.Security.EnrollmentGrant
findAuthority       :: Maybe Text -> Maybe Grant -> Maybe Grant -> Bool -> Either GrantDenied Grant
enrollmentAuthority :: GrantContext -> Either GrantDenied EnrollmentAuthority
claimExclusively    :: FilePath -> GrantClaim -> IO Bool
releaseClaim        :: FilePath -> ChallengeId -> IO ()      -- compare-and-delete
effectiveDeadline   :: Grant -> UTCTime -> NominalDiffTime -> UTCTime
grantRedeems        :: ChallengeId -> Grant -> Bool
loadGrantFile / saveGrantFile / deleteGrantFile / loadClaimFile / grantLiveAt / claimLiveAt
```

**Paths added**: `credentialsFilePath` (`<home>/credentials.toml`),
`enrollmentGrantPath` (`<state>/enrollment-grant.json`),
`enrollmentClaimPath` (`<state>/enrollment-grant.claimed-<id>`).

---

## 3. Empirical facts — measured this session, do not re-litigate

**3.1 tomland flattens dotted keys into ONE flat pair.** `credentials.<id>.x = v`
under `[access_control]` becomes the single pair key
`("credentials" :| ["<id>","x"])`. No prefix-tree node exists for
`credentials`, so **no codec can see it** — `Toml.tableMap` returns an empty
map. `expandDottedKeys` (private, in `Seal.Config.Security`) builds the nesting;
`Toml.Type.TOML.insertKeyAnyVal` does **not** (it stores the value at the full
multi-piece key, i.e. exactly where it already was). This is why 1.5's detection
is a key-path walk and why 1.10's reader is codec-based *only after*
`expandDottedKeys` has run.

**3.2 An explicit table header keeps the path in the node's `Pref`.** For
`[access_control.credentials.<id>]` the parse tree has HashMap key
`"access_control"` mapping to
`Leaf ("access_control" :| ["credentials","<id>"])`. Any AST walk must use the
node's own prefix, not the map key, or it loses path segments.

**3.3 A file that mixes both spellings in one document does not migrate
correctly** (only one credential is found). Real files use one style; the two
tests run one spelling each. This is a known limitation, not a bug report.

**3.4 `passkey` + zero credentials is now `unconfigured`, not a boot refusal.**
That resolves the plan/design issue 7 and deliberately removes
`bootDecision`'s "refuse" row. Do not add it back.

**3.5 The previous handoff's two "withdrawn findings" still hold** — lowercase
hex tokens, and `migrateSecurityConfig` not being a threat. Nothing changed.

---

## 4. Traps that cost time

- **`cabal build tests` is ambiguous.** Use `cabal build test:tests`.
- **The dev-shell tools are already on `PATH`** (ghc 9.12.4, cabal 3.16, node,
  npm, hlint), so `nix develop --command …` in the Makefile is unnecessary
  overhead. The gate can be run directly: `cabal build all && cabal test &&
  hlint src/ test/ && (cd frontend && npm test)`. Always redirect to a file —
  never pipe `cabal`/`hlint` through `head`/`tail` (SIGPIPE hang).
- **`-Werror` details that bit**:
  - unused *top-level* bindings (`-Wunused-top-binds` is in `-Wall`) — a helper
    left behind by an edit is a build failure;
  - shadowing hspec's hooks: `before`, `after`, `context` are all in scope;
  - `-Wpartial-fields`: a record on one constructor of a sum type is rejected —
    use a positional field (`AcMigrateCredentials !Bool`);
  - `-Wtype-defaults`: a local `where` helper with numeric literals needs a
    signature;
  - `foldl'` is in `Prelude` on base 4.18+ — importing it is a redundant import.
- **hlint specifics**: `when (not x)` → `unless`; redundant `pure ()` at the end
  of a `do`; `\x -> f x` → `f`; `m >>= pure . f` → `f <$> m`.
- **When inserting a `describe` block by text replacement**, make sure the
  anchor is inside `spec`'s `do` block. Inserting before a top-level comment
  silently puts the block at top level and produces a parse error far away.

---

## 5. Testing notes for whoever continues

- **`test/Seal/Gateway/AccessControlSpec.hs` has `bootHandle paths mSection creds`.**
  It writes `credentials.toml` when `creds` is non-empty, runs `bootPlan`, then
  builds the handle. Use it for every new handle fixture.
- `credMap` hardcodes `rp_id = "localhost"` (i.e. usable). For an unusable
  credential use `orphanCred`.
- **Credential-admin endpoints still require `X-Seal-Setup-Token` even in `open`
  mode** — `CredentialAdmin = AdminOpen` is W4 work. Tests that delete a
  credential must pass the setup code.
- **W1 1.11 / 1.12 tests are blocked on access, not code.** `persistSignCount`
  and `deleteCredential` are not exported, so their tests must go through the
  endpoints; `loginVerify` needs a full signed assertion (copy the existing
  ceremony test). Land them with W4's endpoint matrix, which §16.11 already
  scopes that way.
- **The registration direction of `rp_mismatch` recomputation is untested.** It
  needs an attestation bound to a challenge the server just issued, and the
  committed fixture's attestation is bound to a *fixed* challenge, so a
  random-challenge handle cannot verify it. Build a registration attestation
  in-test when you do W4.
- **3.9's concurrency test asserts the end state** of two real concurrent
  enrollments, not every interleaving. It is a regression guard, not a proof.
- Unrelated pre-existing flake seen once: `Agent.Runtime.Registry`'s "records
  Crashed when the worker throws" fails under full-suite load and passes in
  isolation.

---

## 6. Deviations from the plan (all deliberate, all documented in commits)

| Plan said | Done instead | Why |
|---|---|---|
| 1.4 tests in `test/Seal/Security/AccessControlSpec.hs` (existing file) | added to `SecurityAccessControlSpec` | that file does not exist; the module's pure tests live in the other |
| 1.5 GREEN: retained `LegacyAccessControlFileConfig` codec | key-path walk (`hasLegacyLayout`) | a codec cannot see dotted keys (§3.1) |
| 1.5 test via `preflight` | tested `hasLegacyLayout` directly | `preflight` did not exist yet (1.8) |
| 1.8 `preflight :: SealPaths -> BindCoordinates -> …`; `GrantContext` has `gcNow` | no coordinates arg; no clock | preflight does no coordinate work; a grant's expiry is decided where it is read, so a clock here would suggest otherwise |
| 1.8 `resolveAccessControl` loses mode-defaulting and credential decoding | deleted outright | `bootPlan` supersedes it; a second copy is how they drift |
| 1.9 `enablePasskeyMode` / `restorePreviousMode` (locked) | `raiseMode` / `restoreMode` (unlocked, caller holds the lock) | only `enrollCredential` needs them, and it must hold the lock once |
| 3.1 load/save inside step 3.1 | landed later, as its own commit | it is the substrate for 3.4/3.5/3.6 |

---

## 7. Next, in order

1. **The `ExitCode` seam (design §12).** `runAccessControl` is `IO ()`; make it
   return `ExitCode` with `exitWith` left at the `AppMain.hs` call site. This is
   the blocker for 3.7 and 3.8 and for testing "exit codes 0/1/2" in-process.
2. **3.7 `enroll` CLI** — `AcEnroll` / `AcDisable`, `enrollGrant`, token to
   stdout / hints to stderr, `state/enrollment-token` off-TTY only, the
   `--ttl` / `--no-token` / `--force` / `--cancel` matrix, the three
   `--no-token` refusals.
3. **3.8 `serve.lock`** — `serveLockPath`, `flock LOCK_EX` held by `serve` for
   its lifetime, probed by `disable` / `reset` / `migrate-credentials`.
4. **3.6 boot does not clobber** — mint only when no unexpired grant is
   outstanding; banner prints `minted_via` + remaining TTL.
5. **W4 endpoints + banner** — `enroll/*`, `waive` removal, `CredentialAdmin`
   (`AdminOpen`), `printAccessControlBannerTo` moved out of `Command.Serve`.
   W4 is where **3.5 (cross-process freshness)** and the deferred **W1 1.11 /
   1.12** tests become reachable.
6. **W5** audit, **W6** frontend, **W7** docs.

### Behaviour changes to state in PR #289

Beyond the previous handoff's list:

- `POST /api/auth/waive` removal is still pending (W4) — the endpoint and
  `updateAccessControlSection`'s `mode = "none"` path both still exist.
- `acfcCredentials` is gone; credentials live in `~/.seal/credentials.toml`.
  A legacy layout makes `seal serve` refuse, naming
  `seal access-control migrate-credentials`.
- `passkey` with zero credentials is now `unconfigured` (grant-gated bootstrap),
  not exit 1.
- `rp_mismatch` is derived: false with zero credentials, false if any credential
  is usable, true only when all are orphaned. It now clears.
- `emptyAccessControl` no longer defaults `mode` to `none`; any write to a
  section-less file leaves the mode unstated.

---

## 8. Open questions for the next session

1. **Does `flock` exist in the pinned `unix`?** GHC's `unix` package exposes
   `fileLock` from 2.8; confirm before writing 3.8, and prefer an advisory
   kernel-released lock over an fcntl record lock (the design wants "a crashed
   daemon does not leave a false refusal").
2. **Where should `enrollGrant` live** — `Seal.Security.EnrollmentGrant` (it is
   grant logic) or `Seal.Command.AccessControl` (it is CLI)? It needs `SealPaths`
   and the token file, so probably a new `Seal.Security.EnrollmentGrant.Cli` or
   the command module with a thin, testable core.
3. **Does the banner's off-TTY path write `state/enrollment-token`, or is the
   token printed to stdout by `enroll` only?** Design §6.3 and §11 both describe
   it; reconcile before implementing.
