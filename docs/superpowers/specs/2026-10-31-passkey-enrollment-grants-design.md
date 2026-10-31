Title: Passkey enrollment grants — design
Status: proposed
Date: 2026-10-31
Rev: 5 — fixes the two high-severity findings of gate round 4 (B-1, B-2), records
the bootstrap race as an accepted risk (§4), and folds in the twelve
specification items. §17 maps every round-4 item to its resolution. No fifth
gate round: the remaining disagreement is settled here.

Follows `2026-10-30-passkey-access-control-design.md` (rev 3). Does not revisit
that design's verification core; replaces its enrollment authorization model and
splits credentials out of `security.toml`. Supersedes two of its items:
`POST /api/auth/waive` is removed (§8.1), and `[access_control] mode` may be
written by a one-way writer (§6.1).

## 1. Problem

Seven issues, in the order a user meets them.

1. **Adding a second passkey dead-ends.** `/access` → "Add a passkey" calls
   `POST /api/auth/register/options` — the first-run, setup-code gate
   (`frontend/src/lib/auth.ts:189-193`). A healthy `passkey` boot mints no setup
   code, so the operator gets `setup_code_required` with "no setup code is
   active; restart `seal serve` to get one" (`Gateway/AccessControl.hs:589`) —
   and no restart can produce one. `credentials/options` exists, is
   session-gated, and nothing calls it.
2. **A live session can mint a permanent credential.** `credentials/*`
   authorizes on a bare session cookie (`withSessionAuthorization`, `:571`).
3. **The only scalable enrollment authority is a boot-time bearer code with no
   expiry**, mintable only by restarting the process.
4. **Credential churn rewrites the boot-critical document.** `persistSignCount`
   (`:813`) rewrites all of `security.toml` on every successful login.
5. **`rp_mismatch` recovery is unreachable.** The `AccessPasskey` banner branch
   (`Command/Serve.hs:655-657`) never prints the code an orphaned boot mints.
6. **`rp_mismatch` uses the wrong quantifier** (`:192-193`: "some credential
   differs"), so the flag never clears and every boot mints another grant.
7. **Spec and implementation disagree on `passkey` + zero credentials.**
   Predecessor §10 says exit 1; `resolveAccessControl` downgrades to
   `AccessUnconfigured` first (`Security/AccessControl.hs:87-93`).

## 2. Non-goals

- Multi-user accounts. One operator, N credentials.
- Removing the ability to run without access control — but disabling it becomes
  CLI-only (§8.1).
- Attestation verification (§3 states the constraint; not an oversight).
- Per-credential policy. A credential count cap.
- TTLs or windows as **config**; they are CLI flags.
- Recovery without local access. Sessions surviving a `seal serve` restart.
- Defending against same-uid code, including the agent (§4 R2).

## 3. The constraint that shapes everything: registration is not authenticated

With `attestation: "none"` and no statement inspection, the verifier checks
*internal consistency* only: the challenge matches one it issued,
`authData.rpIdHash == SHA-256(rpId)`, the flags are set, `rawId` agrees with the
attested id, the COSE key is a valid P-256 point. Every one of those is
client-produced, and `clientDataJSON.origin` is the **browser's own claim**.

> A client holding a valid challenge can generate its own P-256 keypair and a
> self-consistent `clientDataJSON` + `authData`, and `verifyRegistration` will
> accept it.

So the origin check is a browser-honesty control, and **the enrollment grant is
the only real gate on a privilege that survives forever.** Three consequences:

1. Authority must be a **secret the client presents on the request** — never
   something ambient to a cookie.
2. It must be short-lived and purpose-scoped.
3. No authority may be secret-free once a credential exists.

## 4. Accepted risks

Stated explicitly so they are decisions rather than gaps.

**R1 — the first-enrollment race.** During bootstrap an authorized-but-wrong
client can win the only enrollment slot by racing the operator. Accepted, for
three reasons:

- *It is narrow.* Authority for bootstrap is either the setup token (so the
  racer is effectively authorized) or local access; the `--no-token` window is
  confined to a loopback **bind** and a loopback origin (§7.1), and is available
  only in the `NoCredentials` state (§7.3). What remains is the same-uid and
  multi-user-local exposure the project already excludes (R2).
- *It is loud.* Enrollment consumes the grant on the first success, so the
  operator's own attempt fails with `grant_invalid`/`grant_required` and they
  learn immediately. Recovery is `seal access-control reset --yes`.
- *The harm is bounded and reversible.* Before the first credential is enrolled
  there is nothing to *escalate to* — `unconfigured` already exposes nothing but
  the setup screen. Note the honest caveat: "bootstrap" is not "fresh harness".
  The common path is an existing installation enabling access control for the
  first time (predecessor §10's migration note), which already holds
  transcripts, vault secrets and repo credentials; and once the racer wins, they
  hold the full agent surface — arbitrary tool execution as the operator's uid —
  until the operator runs `reset --yes`. Mitigation, documented in README:
  enroll *before* exposing the port.

**R2 — same-uid code, including the agent.** The harness runs as the operator.
Anything running as that uid can run `seal access-control enroll` itself and
complete a ceremony from its own HTTP client, so the passkey gate constrains
remote principals and other local uids only. The control is OS-level (separate
accounts, sandboxing), out of scope here.

**R3 — no server-side revocation of an assertion grant** before its 120 s TTL.
Accepted: 120 s is shorter than any practical revocation loop, and a stolen
cookie cannot mint one (§7.2).

**R4 — a loopback bind is not the same as unreachable.** Same-host reverse
proxies, `ssh -L`, and shared network namespaces can reach it. The window keeps
requiring `NoCredentials` plus a loopback bind, which bounds what a reachable
attacker can do to "win the first enrollment" — R1.

## 5. The model, as invariants

1. A passkey is required unless `mode = "none"` is **written** in
   `security.toml`. Absence never means "off".
2. Authority is always **a secret presented on the request** — except the
   loopback-confined `CliWindow`, which exists only in the `NoCredentials`
   (bootstrap) state.
3. No usable credential → a **CLI-minted token** grant only.
4. `rp_mismatch` (no usable credential) → CLI token only. Not a window.
5. Usable credentials → a grant minted by a **fresh assertion** from an enrolled
   credential, or by a **CLI token**.
6. Every grant is one-shot and TTL-bounded. The TTL is an upper bound, never a
   quota.
7. **Disabling access control is CLI-only.** No HTTP endpoint can turn it off;
   enrolling can only turn it *on*.
8. Deletion stays at session-or-CLI-token level, is audited, and can never
   remove the last **usable** credential.

Invariant 2 is the fix for gate round 4's B-1: rev 4 let an *absent* token fall
through to a session-held grant, which meant a stolen cookie could redeem the
victim's live grant by simply omitting a header. There is now no path from a
cookie alone to enrollment authority.

## 6. Configuration

### 6.1 `~/.seal/security.toml`

```toml
[access_control]
# Absent, or "passkey" = a passkey is required (the default).
# "none" is the ONLY way to disable access control, and must be written.
# mode = "none"

# Optional; derived from the bind address otherwise. Changing the host
# invalidates every enrolled passkey (predecessor §3).
# origin = "https://seal.example.com"
# rp_id  = "seal.example.com"
```

`AccessControlFileConfig` **loses** `acfcCredentials`. Three corrections:

- `emptyAccessControl` currently defaults to `acfcMode = Just "none"`
  (`Config/Security.hs:367-373`), so any write to a section-less file records an
  *implicit* off. It becomes `acfcMode = Nothing`.
- `POST /api/auth/waive` is removed (§8.1).
- Enrollment in `mode = "none"` must still turn access control on. Since the
  credentials writer cannot name `mode`, a narrow writer exists:

```haskell
data ModeRaise = AlreadyRaised | RaisedFrom (Maybe Text)   -- witness, ctor unexported
enablePasskeyMode :: FilePath -> IO (Either Text ModeRaise)
```

  `RaisedFrom` is the only value `restorePreviousMode` accepts, so **the web path
  cannot lower the mode** — a type fact, not a convention:

```haskell
restorePreviousMode :: FilePath -> ModeRaise -> IO (Either Text ())
```

  Raise and credential write are **one locked operation**, so a failed credential
  write cannot interleave with a second ceremony and leave `mode = "none"` beside
  an enrolled credential:

```haskell
enrollCredential
  :: FilePath -> FilePath          -- security.toml, credentials.toml
  -> Map Text CredentialFileConfig -- the entry to add
  -> IO (Either Text ())
```

  It takes `securityWriteLock` once, raises the mode, writes the credential, and
  on failure restores the previous mode via compare-and-swap (restore only if the
  on-disk mode is still the value the raise wrote). Mode-first ordering: a crash
  between the steps leaves `passkey` + absent credentials, which resolves to the
  grant-gated `unconfigured` bootstrap and is loud. Credential-first would leave
  a credential on a still-open gateway — silent non-enforcement.

Testable invariant: **the web UI can change which credentials are enrolled and
can turn access control on; it can never turn it off, change `origin`/`rp_id`, or
alter how enrollment is authorized.**

### 6.2 `~/.seal/credentials.toml` — new, gateway-owned

Sibling of `security.toml`, not under `config/`. 0600 via `writeSecretFile` plus
atomic rename.

```toml
version = 1

[credentials.<credential-id-base64url>]
public_key = "<base64url, 64-byte x||y>"
sign_count = 0
label      = "passkey"
created_at = "2026-10-30T14:00:00Z"
rp_id      = "localhost"
added_via  = "cli_token"   # "cli_token" | "cli_window" | "assertion" | "legacy"
```

`added_via` shares its vocabulary with the grant's `minted_via` plus `legacy`; it
is a field on `CredentialFileConfig`, and the runtime `Credential` gains
`credAddedVia`. Unknown `version` ⇒ boot refusal; unknown `added_via` ⇒
`legacy`; a semantic failure inside one credential ⇒ boot refusal, not a dropped
entry.

### 6.3 `~/.seal/state/` — ephemeral (dir 0700)

| File | Contents | When |
|---|---|---|
| `enrollment-grant.json` | `{grant_id, minted_via, expires_at, created_at, token_sha256?, bound_challenge?}` | a grant is outstanding |
| `enrollment-grant.claimed-<grant_id>` | `{grant_id, challenge_id, deadline}` | a ceremony is in flight |
| `enrollment-token` | the plaintext token, 0600 | minted **and** stderr is not a TTY |
| `serve.lock` | empty; `flock LOCK_EX` held by `serve` | a daemon owns this `SEAL_HOME` |

`token_sha256` is `null` only for `CliWindow`. A grant file that fails to parse
is treated as absent, deleted and logged — never a boot refusal; absent is never
more permissive than present (§7.3).

The plaintext token file is written only off-TTY, and **the token is never
printed to stderr** — off a TTY the banner prints the path. Claim markers and a
stale `enrollment-token` are reaped by the boot sweep and by `--cancel`.

`state/` is currently umask-governed (`ensureSealDirs` hardens only `keys/`);
this design sets it to 0700 and creates the audit log 0600 at open time.

## 7. Grants

### 7.1 Types

New module `Seal.Security.EnrollmentGrant` (`Session`/`AuthErr` are
gateway-local, so it cannot live in `Seal.Security.AccessControl`).
`CredentialAvailability` does **not** live here — it goes in
`Seal.Security.AccessControl`, which already has `Credential`/`AccessMode` and
must not depend on `Grant` (§19 W1).

```haskell
data GrantSource = CliToken | CliWindow | Assertion
data GrantPhase  = GrantMinted | GrantBound ChallengeId
newtype GrantId     = GrantId Text
newtype ChallengeId = ChallengeId Text   -- the challenge text, i.e. the map key
data Grant = Grant
  { grId :: !GrantId, grExpiresAt :: !UTCTime, grSource :: !GrantSource
  , grPhase :: !GrantPhase, grTokenSha :: !(Maybe ByteString)
  }
type EnrollmentAuthority = GrantSource
data GrantDenied = GrantRequired | StepUpRequired | GrantInvalid
```

| Source | Presented as | Storage | TTL | Consumed |
|---|---|---|---|---|
| `CliToken` (`enroll`, boot) | `X-Seal-Enroll-Token` | `state/` digest | 10 min | successful registration |
| `CliWindow` (`enroll --no-token`) | nothing | `state/` file | 5 min | successful registration |
| `Assertion` (`enroll/verify`) | `X-Seal-Enroll-Token` ← response body | session: digest | 120 s | at bind |

**Authority is presented, not inherited.** An `Assertion` grant is a
`grant_token` returned in the `enroll/verify` response body; the server stores
only its digest in that session, and `credentials/*` require the token **and** a
matching session. A cookie alone authorizes nothing (invariant 2, R3).

`CliWindow` is confined to a loopback **bind** *and* a loopback resolved origin
(testing the origin alone is not enough: `host = "0.0.0.0"` with
`origin = "https://localhost:8787"` passes while the socket is
internet-reachable), **and** to the `NoCredentials` state (§7.3). There is no
`--allow-remote-enrollment` override, and boot refuses `BrUnsafeBind` for a
non-loopback bind with a loopback-literal origin.

**Token form.** `generateToken` emits lowercase hex (verified: `T.toUpper token`
⇒ 403, `T.toLower` ⇒ 200). The SPA's `normaliseCode` lowercases typed input and
fragments (`auth.ts:58-59`). The server compares on `T.toLower presented` — a
no-op today that keeps the browser working if the formatter's case changes.
`#enroll=` parsing is **new code**: `normaliseCode` strips `^#?setup=` only.

### 7.2 The authority resolver

```haskell
findAuthority
  :: Maybe Text          -- presented token
  -> Maybe Grant         -- file-backed grant
  -> Maybe Grant         -- session-carried grant
  -> Bool                -- the requesting session matches the session grant
  -> Either GrantDenied Grant
```

Order: a presented token is matched against the file grant's digest, then the
session grant's digest (requiring the session match). A mismatch is
`GrantInvalid` **and is a pure read** — no rebind, no consumption, no TTL
extension — even when another grant is live, so a stale token is never silently
ignored and cannot shadow a live one. `Nothing` is only acceptable for
`CliWindow`.

Then:

```haskell
data CredentialAvailability = NoCredentials | UnusableOnly | Usable
credentialAvailability :: Maybe Text -> Map Text Credential -> CredentialAvailability
credentialAvailability _      creds | Map.null creds = NoCredentials
credentialAvailability Nothing creds                = Usable          -- wildcard bind
credentialAvailability (Just rp) creds
  | any ((== Just rp) . Just . credRpId) (Map.elems creds) = Usable
  | otherwise                                              = UnusableOnly

data GrantContext = GrantContext
  { gcNow :: !UTCTime, gcMode :: !AccessMode
  , gcAvailability :: !CredentialAvailability
  , gcAuthorized :: Maybe EnrollmentAuthority   -- from findAuthority
  , gcHasSession :: !Bool
  }

enrollmentAuthority :: GrantContext -> Either GrantDenied EnrollmentAuthority
```

Total matrix — 3 modes × 3 availabilities × 4 authorities = 36 combinations,
covered by 11 rows:

| Mode | Availability | Presented authority | Verdict |
|---|---|---|---|
| any | `NoCredentials` | `cli_token` | `CliToken` |
| any | `NoCredentials` | `cli_window` | `CliWindow` |
| any | `NoCredentials` | none / `assertion` | `Left GrantRequired` |
| `open` | `UnusableOnly` / `Usable` | `cli_token` | `CliToken` |
| `open` | `UnusableOnly` / `Usable` | none / `cli_window` / `assertion` | `Left GrantRequired` |
| `passkey` | `UnusableOnly` | `cli_token` | `CliToken` |
| `passkey` | `UnusableOnly` | none / `cli_window` / `assertion` | `Left GrantRequired` |
| `passkey` | `Usable` | `cli_token` | `CliToken` |
| `passkey` | `Usable` | `assertion` | `Assertion` |
| `passkey` | `Usable` | none, session present | `Left StepUpRequired` |
| `passkey` | `Usable` | none, no session | `Left GrantRequired` |

`unconfigured` implies `NoCredentials` by construction (§10), so row 1–3 cover
it. The window is **not** available in `UnusableOnly` — the state an attacker who
can change `origin`/`rp_id` would aim to create (gate round 4, B-2).

Precedence when several authorities are live: `CliToken` > `CliWindow` >
`Assertion`. On success every outstanding grant is cleared (file and session);
clearing never touches sessions. `cli_window` presented outside `NoCredentials`
is `GrantRequired`, not `GrantInvalid` — the token is well-formed, the state no
longer permits it.

`GrantDenied` constructors select HTTP status, wire code and UI branch, which is
why an ADT is warranted over `Either Text`.

### 7.3 Lifecycle

```
Minted --options--> Bound(c) --verify success--> Consumed
   |                    |
   +------ TTL --------+------ TTL -----------> Expired (reaped)
```

- **One deadline rule.** Binding stores
  `effective_deadline = min(grant expiry, now + challengeTtl)` in the claim
  record; `verify` re-checks it.
- **Exactly-once via an exclusive claim.** `enrollment-grant.claimed-<grant_id>`
  is created `O_CREAT|O_EXCL` holding `{grant_id, challenge_id, deadline}`. The
  `create` result — not a prior read — decides the winner.
- **Rebinding after failure.** A failed verify deletes the claim **iff it still
  carries the same `challenge_id`** (compare-and-delete), so the next `options`
  rebinds and an aborted prompt does not burn a CLI grant for its TTL. A 500
  `write_failed` does the same.
- **Conditional grant write-back**, keyed on `grant_id`, through temp+rename, so
  a concurrent `--cancel`/`--force` is not resurrected.
- **Grant state is read from disk on every enrollment request and every status
  computation; only the reaper unlinks.** Never cached in the handle — the CLI
  mints while the daemon runs, so a cached copy would be invisible until
  restart. The handle caches only *session* grants.
- **Reaping** happens on enrollment paths, on minting, at boot, and on
  `--cancel`. Never on `GET /api/auth/status`, which is public and polled.
- **Boot never clobbers.** `serve` mints only when no unexpired grant is
  outstanding; otherwise it preserves it and the banner prints `minted_via` +
  remaining TTL + "paste the token you were given, or run `seal access-control
  enroll --force`".
- A failed verify leaves a CLI grant live and unbound and an assertion grant
  consumed.

### 7.4 Ordering and crash outcome

1. Claim (`O_EXCL`; the loser gets `grant_invalid`).
2. `enrollCredential` (§6.1) — one locked raise+write.
3. Delete the grant file, the claim marker and `state/enrollment-token`.

A crash between 1 and 2 loses the grant and adds no credential — the safe
direction. **Lock order: `achState` is never held while acquiring
`securityWriteLock`.** `securityWriteLock` is process-local, so cross-process
safety rests on unique temp names, atomic rename, digest comparison and the
`O_EXCL` claim. `credentials.toml.tmp` and `security.toml.tmp`
(`Config/Security.hs:280`) both become unique.

## 8. HTTP API

### 8.1 Endpoints

| Endpoint | Gate |
|---|---|
| `POST /api/auth/register/{options,verify}` | `findAuthority` + `enrollmentAuthority` |
| `POST /api/auth/credentials/{options,verify}` | `findAuthority` + `enrollmentAuthority` |
| `POST /api/auth/enroll/options` | live session **and** `Usable` |
| `POST /api/auth/enroll/verify` | live session **and** a verified assertion from a usable credential |
| `POST /api/auth/login/{options,verify}` | none (unchanged) |
| `GET /api/auth/status` | none (unchanged, additive fields §8.3) |
| `GET /api/auth/credentials` | `CredentialAdmin` |
| `DELETE /api/auth/credentials/:id` | `CredentialAdmin` |
| ~~`POST /api/auth/waive`~~ | **removed** |

**`enroll/*` wire format:**

- `enroll/options` issues a single-use `stepup` challenge bound to the calling
  session and returns the `login/options` shape — `{challenge, rpId, timeout,
  userVerification, allowCredentials}` — with `allowCredentials` **restricted to
  usable credentials**. Refuses in `unconfigured`/`open` and when
  `UnusableOnly`: a mode+availability gate, not a session-presence gate.
- `enroll/verify` accepts the `login/verify` body (`clientDataJSON`,
  `authenticatorData`, `signature`, `rawId`), requires an unconsumed `stepup`
  challenge belonging to that session, and runs `verifyAssertion` against the
  named credential, which must be usable. On success it returns
  `{ok, grant_token, grant_expires_at}` and stores the digest; **no failure body
  carries either field**. An assertion naming an orphaned or unknown credential
  returns `grant_invalid` (the picker never offers one, so that is forged or
  racing).

**Credential administration:**

```haskell
data CredentialAdmin = AdminSession | AdminCliToken | AdminOpen
                     | AdminDenied
```

`open` mode is already fully open, so it administers credentials
unauthenticated (matching `authenticated == open`); this is what lets `/access`
work there at all. `window` and `assertion` grants are enrollment-only.
`AdminDenied` maps to `403 grant_required`.

**`waive` is removed.** Invariant 7 says no HTTP request may disable access
control, so `seal access-control disable --yes` replaces it. That removes the
"one token enrolls and disables" blast radius and makes the invariant structural.
The setup screen's affordance becomes instruction text; `AccessGate`'s waive
button, `auth.ts`'s `waive()` and its styles are deleted.

`accessControlMiddleware` routes every `/api/auth/*` path to `authApp` **before**
consulting `unconfiguredAllow`/`passkeyAllow` (`isAuthPath` short-circuit), so
those lists never gate auth routes: the handler is the sole gate. The now-dead
`["api","auth","waive"]` entry is deleted.

### 8.2 Transport

- Header `X-Seal-Enroll-Token`; `X-Seal-Setup-Token` retired.
- Fragment `#enroll=<token>`: accept a bare token **or** a pasted full URL (take
  its hash), strip `^#?(enroll)?=`, lowercase, assert 32 chars.
- Client lifecycle: `seal.enroll-token` is cleared after success; on
  `grant_invalid` the browser **stops sending** it (the input keeps the typed
  text so the operator can correct it and retry).
- Wire errors: `grant_required`, `grant_invalid`, `step_up_required`,
  `write_failed` (500).

### 8.3 Status

```json
{ "enrollment_via": "cli_token|cli_window|assertion|none",
  "usable_credentials": 1,
  "orphaned_credentials": 2 }
```

Computed for the requesting session, preferring the file grant. `enrollment_via`
is a timing signal ("authority is armed"); with `cli_window` confined to a
loopback bind and `NoCredentials`, the residual is local-only (§4 R4). No
`enrollment_available` boolean — it duplicated `enrollment_via` and rev 3 keyed a
button on the wrong one. `setup_required` keeps its meaning for compatibility;
the SPA stops using it as a predicate.

## 9. Credential store

### 9.1 Writers

```haskell
createCredentialsFile :: FilePath -> Map Text CredentialFileConfig -> IO (Either Text ())
updateCredentialsFile :: FilePath
                      -> (Map Text CredentialFileConfig
                            -> Either Text (Map Text CredentialFileConfig))
                      -> IO (Either Text ())
```

`Either` in the callback so the last-usable rule is enforced **inside** the lock
rather than by a read-then-write in the handler. Round-trip verified before
rename. Serialized behind `securityWriteLock`.

Refusal rules: `updateCredentialsFile` refuses a missing file (enrollment
creates, later mutations require it — this kills the `Map.empty` seed and silent
external deletion); the resulting map may never be empty. `reset --yes` deletes
the file and requires the daemon stopped.

`persistSignCount` moves here and its failure is surfaced: persist, then mint the
session. `claimSignCount` still bumps memory first, so a persist failure leaves
memory ahead of disk; that direction is tolerated and self-healing (verify needs
presented ≥ stored), and is stated rather than hidden.

### 9.2 The store is never empty

Enforced by §9.1 and §9.4 plus `reset`, which is what makes "present but empty ⇒
refuse to boot" a corruption signal rather than a lockout.

### 9.3 Codec

`credentialsCodec` needs its own root-`credentials` normalisation — learnings
2026-10-30 §4 nests per `tableMap` level, and a bare `version` key does not make
the node explicit. `fixNode` is already root-parameterised and is exported rather
than duplicated.

### 9.4 Deletion

`CredentialAdmin`-gated. The guard is evaluated on the freshly loaded map inside
the writer's callback: refuse if the deletion leaves zero **usable** credentials;
applies in every mode; `racRpId == Nothing` counts every credential as usable;
concurrent deletes cannot reach zero.

## 10. Boot

`preflight` runs immediately after `ensureSealDirs`, before every writer.

```haskell
data BootInputs = BootInputs
  { biSecurityRaw :: !Text
  , biSection     :: Maybe AccessControlFileConfig   -- Nothing = absent/no section
  , biCredentials :: !CredentialsPresence }

data CredentialsPresence
  = CredentialsAbsent | CredentialsPresent Int (Map Text CredentialFileConfig)
  | CredentialsInvalid Text

data BootRefusal
  = BrSecurityUnparseable Text | BrLegacyLayout | BrCredentialsInvalid Text
  | BrCredentialsEmpty | BrCredentialsVersion Int | BrModeInvalid Text
  | BrCoordinatesInvalid Text | BrUnsafeBind Text | BrPublicBindWithLoopbackOrigin

data BootPlan = BootPlan
  { bpMode :: !AccessMode, bpOrigin :: !(Maybe Text), bpRpId :: !(Maybe Text)
  , bpCreds :: Map Text Credential, bpMintGrant :: !(Maybe GrantSource) }

preflight :: SealPaths -> BindCoordinates -> IO (Either BootRefusal BootInputs)
bootPlan  :: BindCoordinates -> BootInputs -> Either BootRefusal BootPlan
```

`BrModeInvalid` covers `parseAccessMode`'s `Left` (`Types.hs:48`), which has a
live test today (`SecurityAccessControlSpec.hs:173-177`) that §19 must **port**,
not delete. `BrPublicBindWithLoopbackOrigin` is separate from `BrUnsafeBind` so
the two distinct §7.1 checks are distinguishable by constructor.

`newAccessControlHandle` takes a `BootPlan` and never re-reads
`credentials.toml`. `resolveAccessControl` loses mode-defaulting and credential
decoding; presence and mode resolution live in `bootPlan` alone.

| Condition | Refusal / action |
|---|---|
| raw `security.toml` unparseable | `BrSecurityUnparseable` — exit 1 |
| legacy credential tables present | `BrLegacyLayout` — exit 1 naming `migrate-credentials` |
| `credentials.toml` unreadable / invalid entry | `BrCredentialsInvalid` |
| present with zero entries | `BrCredentialsEmpty` |
| unknown `version` | `BrCredentialsVersion` |
| invalid `mode` | `BrModeInvalid` |
| origin/rp_id unresolvable | `BrCoordinatesInvalid` |
| absent credentials + `mode` absent or `passkey` | `unconfigured`; mint grant |
| absent credentials + `mode = "none"` | `open`; mint grant |
| **present and usable** | `passkey`; **no** grant |
| **present, `UnusableOnly`** | `passkey`, `rp_mismatch`; **mint grant** |
| present, `mode = "none"` | `open`; mint grant |
| `passkey`, non-loopback bind, origin not `https` | `BrUnsafeBind` |
| non-loopback bind + loopback-literal origin | `BrPublicBindWithLoopbackOrigin` |

**Legacy detection decodes, it does not grep.** A substring scan for
`[access_control.credentials.` misses the dotted-key spelling — the same TOML
document — and the next web write drops every table. `preflight` decodes
`biSecurityRaw` with a retained `LegacyAccessControlFileConfig` codec.

**The guard needs a chokepoint with an explicit exemption.** `security.toml` is
rewritten by `updateAccessControlSection`, `updateSecurityConfig`
(`Vault/Commands.hs:227,289`) and `clearAccessControlSection`; all call
`saveSecurityConfig`, so the refusal lives there:

```haskell
data WriteMode = PreserveCredentials | DropCredentials
saveSecurityConfig :: FilePath -> SecurityConfig -> WriteMode -> IO (Either Text ())
```

`DropCredentials` is accepted only from `migrate-credentials` and `reset --yes`
(both `--yes`-gated, CLI-only); everything else gets `Left` when the raw file
still holds a credential table. `clearAccessControlSection` threads the mode so
its single caller (`Command/AccessControl.hs:75`) is auditable.

`migrateSecurityConfig` is not a threat: it writes `security.toml` only when the
file is absent (its Case 1), which cannot coexist with legacy credentials.

## 11. Boot banner

- `unconfigured`, `open` and `passkey`+`UnusableOnly` all mint a grant; all three
  print it on a TTY, and off a TTY print the **path** plus a note, never the
  token.
- Reports absolute and relative expiry and names `seal access-control enroll`.
- A healthy `passkey` boot prints neither token nor URL.
- `open`: the grant stops a network client from enrolling its own credential and
  flipping `open` into locked-with-my-key. Stated, not implied.
- Sink and TTY decision are arguments, so the behaviour is testable:

```haskell
printAccessControlBannerTo
  :: ChannelCaps -> Bool{-stderrIsTTY-} -> (Text -> IO ()){-emit-}
  -> SealPaths -> NewAccess -> IO ()
```

  It moves out of the unexported `Seal.Command.Serve` into a module the suite
  already imports.

## 12. CLI

```
seal access-control enroll [--ttl <N>[smh]] [--no-token] [--force] [--cancel]
seal access-control disable --yes | reset --yes
seal access-control migrate-credentials [--yes] [--force]
```

`runAccessControl :: AccessControlCmd -> ChannelCaps -> SealPaths -> IO ExitCode`
(`exitWith` stays at the `AppMain.hs` call site, so codes are assertable
in-process).

- `--ttl`: `<N>` **must** carry `s`/`m`/`h`; a bare number is a usage error.
  Clamped 30 s – 24 h; defaults 10 m (token) and 5 m (window).
- Flag matrix: `--cancel` is mutually exclusive with `--no-token`, `--ttl` and
  `--force`; `--force` is valid with either mint mode; `--cancel` with nothing
  outstanding exits 0.
- Exit codes `0` ok / `1` refusal / `2` usage; reason on stderr, token on stdout.
- `--no-token` refuses unless the **bind** and the resolved origin are both
  loopback, the origin resolves, **and** the credential store is `NoCredentials`.
  No override.
- `disable --yes` writes `mode = "none"` and preserves credentials. `reset --yes`
  deletes `credentials.toml` and the grant files too. Both require the daemon
  stopped, detected by `flock`-ing `state/serve.lock` (advisory, kernel-released,
  so a crash cannot leave a false refusal).
- `migrate-credentials` also requires the daemon stopped; it never overwrites an
  existing `credentials.toml` (`--force` permits re-running the table removal
  only, not the credential write).

`status` must report what `bootPlan` would act on — the current `loadSection`
swallows a parse error into "not configured" (`Command/AccessControl.hs:86-91`).
Literal format: six store conditions (absent / present with version and
usable+orphaned counts / empty / invalid / legacy / unknown version),
`<unresolved: reason>` for origin/rpId, the grant block
(`minted_via` + expiry, or `none`), and one line per credential
`  - <first 8 of id>  <added_via>  rp_id=<rp>  <usable|not usable here>`.

## 13. Frontend

Both `/access` (AccessView) and the gate (AccessGate) derive everything from
**one shared hook** over the status payload.

**Precedence rule:** `state == 'passkey' && authenticated && usable_credentials >
0` renders the application. The table governs the **gate** only; `/access` owns
the add-passkey flow.

| state | availability | `enrollment_via` | Gate renders |
|---|---|---|---|
| `unconfigured` | `NoCredentials` | `cli_token` | setup + token field + CLI hint |
| `unconfigured` | `NoCredentials` | `cli_window` | setup, no field, action enabled |
| `unconfigured` | `NoCredentials` | `none` | setup, action disabled, CLI instruction + re-check |
| `passkey` | `Usable` | `none` / `cli_token` / `cli_window` | login + token field + "enroll this device" (enabled when a token is typed) |
| `passkey` | `Usable` | `assertion` | unreachable in the gate (assertion ⇒ session ⇒ authenticated ⇒ app) |
| `passkey` | `UnusableOnly` | `cli_token` | setup + token field, "keys registered for a different address" |
| `passkey` | `UnusableOnly` | `none` | setup, no field, CLI instruction + re-check |
| `open` | any | any | children; `/access` owns enrollment |

`passkey ⇒ at least one credential present` and `unconfigured ⇒ NoCredentials`
(§10) make the absent cells unreachable; stated so "total" is honest.

Specific changes:

1. `createPasskey` gains a target (`bootstrap` | `add`); target selection is
   `usable_credentials > 0` ⇒ `credentials/*`, else `register/*`. Callers are
   `AccessGate.tsx:92` and `AccessView.tsx:42` (not `auth.test.ts`, which imports
   neither).
2. `step_up_required`, **when authenticated**: `enroll/options` →
   `navigator.credentials.get` → `enroll/verify` → restart the add ceremony from
   the beginning (the challenge was consumed) → `credentials/options` with the
   returned `grant_token`. **When unauthenticated** (the gate's login panel):
   never call `enroll/options`; render "sign in on a device that already has a
   passkey, or paste an enrollment token". A second `step_up_required` shows
   "That took too long — try adding the passkey again."
3. `grant_required`: CLI instruction; **keep** the token field where a token can
   help (rows 1, 6) and omit it where it cannot (rows 3, 7). `grant_invalid`:
   keep the field and the typed text, stop sending the rejected token (§8.2).
4. Both surfaces get a **"Check again"** action (plus a re-fetch on window
   focus) whenever the primary action is disabled by `enrollment_via: none`;
   it calls `fetchAuthStatus()` and does not clear a typed token.
5. A successful gate enrollment mints a session, so the operator lands in the
   app. Stated, because it defines the journey's success criterion.
6. `/access` renders the `CredentialAdmin` outcome: in `open` mode the list and
   delete work unauthenticated; when `AdminDenied`, show "sign in to manage
   passkeys" rather than a raw 403.
7. Remove is disabled on the last **usable** credential.
8. `added_via` renders as human copy: "confirmed with an existing passkey" /
   "added from the terminal" / "added with an enrollment window" / "migrated";
   orphans marked "cannot sign you in here; safe to remove".
9. Delete the waive button, `auth.ts`'s `waive()` and its styles. `CapabilityNote`
   renders on **both** panels — branch the trailing clause: setup → "or run
   `seal access-control disable --yes` (stop `seal serve` first)"; login → "open
   the gateway over https/localhost". Both lost-device strings
   (`AccessGate.tsx:174-182` and `:184-188`) name `seal access-control enroll`
   **before** `reset --yes`, and say `reset` needs the daemon stopped while
   `enroll` does not.
10. Two distinct prompts: "Confirm it's you to add a passkey to Seal" before the
    step-up `get`; "Follow the prompt to create a passkey" before `create`.
11. `AuthStatus` gains `enrollment_via`, `usable_credentials`,
    `orphaned_credentials`.

## 14. `rp_mismatch`

`rpMismatch = credentialAvailability rpId creds == UnusableOnly`. The explicit
`NoCredentials` case removes the `all`-over-empty-set vacuity. It is **derived
from the map on every mutation** (never assigned), so it cannot go stale:
`persistRegistration` today hardcodes `acsRpMismatch = False` and
`deleteCredential` never recomputes.

## 15. Audit

No Audited log exists (`ISA/Dispatch.hs:101-105`) and the gateway has no logger,
so this is new plumbing: `Seal.Gateway.Audit`, path-based (the CLI emits too),
appending to `state/access-control.log` opened `O_APPEND|O_CREAT|O_NOFOLLOW` at
0600, refusing a symlink or non-regular target, size-capped and rotated.

Events: `credential_added`, `credential_removed`, `grant_minted`,
`grant_consumed`, `grant_refused`, `mode_enabled`, `mode_disabled`.

**Closed field set**, explicitly enumerated: timestamp, event, credential id,
label, `rp_id`, origin, `added_via`/`minted_via`, remaining TTL. **No
request-derived value may appear** — not `rawId`, not `origin` from client data,
not the presented token, not a digest, not `User-Agent`.

`grant_refused` and `grant_invalid` are aggregated per `(event, source, minute)`
on a fixed-size table with backoff applied **before** the emit; state-changing
events go to a separate sink so log-flooding cannot rotate away evidence. The
token backoff counter is keyed on `(source, minute)`, never on the presented
value — an attacker-chosen key would be an unbounded allocation on a pre-auth
path.

**Honest scope:** a detective aid under R2, not tamper-evidence.

## 16. Definition of done

**Step 0 — wiring and blast radius.** Each new module goes in `.cabal`
`exposed-modules:`, `.cabal` test-suite `other-modules:`, and `test/Main.hs`.
`Seal.Config.Paths` gains `credentialsFilePath` (spHome), `enrollmentGrantPath`
(spState), `serveLockPath` (spState), with `PathsSpec` coverage. `seal-harness.cabal`
and `test/Main.hs` are merge hotspots.

Dependency lists, complete:

- **`acfcCredentials` removal** (5): `src/Seal/Gateway/AccessControl.hs`,
  `src/Seal/Security/AccessControl.hs`, `src/Seal/Config/Security.hs`,
  `test/Seal/Gateway/AccessControlSpec.hs` (`passkeySection`, `credMap`),
  `test/Seal/Config/SecurityAccessControlSpec.hs`.
- **`saveSecurityConfig` `WriteMode`** (7): `src/Seal/Config/Security.hs`
  (definition + the three decision points at :317, :347, :364),
  `src/Seal/Config/Migrate.hs` (`try @SomeException` flattening),
  `test/Seal/Config/SecuritySpec.hs`, `test/Seal/Command/ChannelSpec.hs`,
  `test/Seal/Vault/CommandsSpec.hs`, `test/Seal/Config/SecurityAccessControlSpec.hs:72,84`,
  `test/Seal/Gateway/AccessControlSpec.hs:384`.
- **`resolveAccessControl` loses credential decoding** (3):
  `src/Seal/Security/AccessControl.hs`, `src/Seal/Gateway/AccessControl.hs:175`,
  `src/Seal/Command/AccessControl.hs`, plus the `describe "resolveAccessControl"`
  block in `SecurityAccessControlSpec.hs` — **ported**, not deleted.
- **`BootPlan` consumer** (3): `src/Seal/Command/Serve.hs` (preflight call site,
  `:161`, banner removal), `AccessControlSpec`'s 17 `newAccessControlHandle` and
  19 `withHome` call sites (`withHome :: Maybe AccessControlFileConfig -> …`).
- **CLI surface** (3): `src/Seal/Types/Command.hs` (`AccessControlAction` gains
  `AcMigrateCredentials` in W1; `AcEnroll`/`AcDisable` in W3, so no commit leaves
  a non-exhaustive match), `src/Seal/AppMain.hs:47`,
  `src/Seal/Command/AccessControl.hs`.

Stale line numbers from rev 3/4 corrected: `X-Seal-Setup-Token` at
89/98/114/129/148/161/270; `naSetupCode` at 159/340; `acfcCredentials` at
198/397; `passkeySection` :392; `credMap` :400.

1. `credentialsCodec` format round trip `decode (encode c) == Right c` over
   valid bare keys and bounded text; separate semantic round trip through
   `credentialFromFile`/`credentialToFile`. `Arbitrary` newtype-wrapped.
2. An **idiomatic** `[credentials.<id>]`-only fixture decodes non-empty — the
   red test for the implicit-node class. Not `Toml.encode` output.
3. `saveSecurityConfig` in both directions: (a) *red* — a raw fixture containing
   a legacy credential table ⇒ `PreserveCredentials` returns `Left`, bytes
   unchanged; (b) *red* — exercise the production path (`loadSecurityConfig` →
   `saveSecurityConfig … PreserveCredentials`) on **explicit and dotted-key**
   credential-free fixtures, comparing the **recursively walked table-path set**
   before and after; (c) `DropCredentials` is accepted from `migrate-credentials`
   and `reset --yes` and refused from every other call site.
4. `createCredentialsFile` refuses an existing file; `updateCredentialsFile`
   refuses a missing one and an empty result; preserves `version` and untouched
   entries; `Left` without writing for an unparseable file.
5. `preflight`/`bootPlan` total over every row of §10, `BootRefusal` asserted by
   constructor **and** message where two constructors could both fire;
   `BrModeInvalid` covered by the ported `mode = "off"` fixture;
   `newAccessControlHandle` takes a `BootPlan` and never re-reads the file
   (assert by planning a credential absent from disk and serving it).
6. `credentialAvailability` over 5 cases (0 / all-mismatch / mixed / all-match /
   `Nothing` rpId); `enrollmentAuthority` total over all 36 combinations of
   §7.2; `findAuthority` for match, mismatch, absent, session-mismatch, and
   `Nothing` + non-window ⇒ denied. **Regression for B-1:** a cookie-only client
   with no header and a live assertion grant gets `step_up_required` and creates
   no credential.
7. Grant lifecycle: consumed authorizes nothing; expired behaves as absent; a
   grant bound to A cannot redeem B; two concurrent verifies with one grant yield
   one credential and one `grant_invalid`; 119 s / 119.5 s / −1 s boundaries;
   failed verify compare-and-deletes only its own claim; crash between claim and
   persist leaves the marker and grant, adds nothing, and the next `options`
   rebinds. Exemplars: `RegistrySpec.hs:127`, `VaultSpec.hs:164`.
8. **Cross-process freshness:** a grant written by a separate process is honoured
   by a live handle with no restart (this is the test that would have caught the
   cached-grant failure mode).
9. **Boot does not clobber:** an unexpired grant present at startup is preserved,
   and the banner prints its `minted_via` and remaining TTL instead of a new token.
10. A cancelled ceremony leaves a CLI grant live and an assertion grant consumed.
11. **`test/Seal/Gateway/AccessControlSpec.hs` is the harness** (not
    `ApiTestHarness`, which wraps `apiApp`; auth routes are applied outside it at
    `Server.hs:68`). Needs a helper to seed `credentials.toml` and a fresh handle
    per case (`challengeBurst` is 20). Matrix: every §7.2 row × the four
    admin/enroll endpoints; the allowlist case (`credentials/*` must reach the
    handler); cookie-only / malformed / unknown-credential / orphaned-credential
    assertions get `grant_invalid` or `step_up_required` and no `grant_token`.
12. `enroll/*` refuse in `unconfigured`/`open`/`UnusableOnly`; a routine
    `login/verify` sets no grant; `allowCredentials` contains only usable
    credentials.
13. CLI via `runAccessControl` returning `ExitCode`: token to stdout, hints to
    stderr; 0600 files and 0700 `state/`; second outstanding grant refused
    without `--force`; `--cancel` removes all three artefacts; `--ttl` rejects a
    bare number; full flag matrix; exit codes 0/1/2; `--no-token` refuses on a
    non-loopback bind, an unresolvable origin, and a non-`NoCredentials` store.
14. Banner via `printAccessControlBannerTo` with an injected sink: `UnusableOnly`
    mints and prints; healthy `passkey` prints neither; off-TTY prints the path
    and not the token; `mode = "none"` enrollment raises the mode then writes the
    credential, and a failed credential write restores the previous mode.
15. `enrollCredential` is atomic: a failed credential write restores the mode;
    two interleaved ceremonies cannot leave `mode = "none"` beside a credential.
16. Path confinement: `.seal` rejected by the four local `mkSafePath*` variants
    including through a resolved symlink — **landed** (`5428e08`); the two pure
    `mkSafePathRemote*` variants cannot canonicalise and are out of scope.
17. Deletion: cannot remove the last usable credential; can remove an orphan
    while one usable remains; applies in `open`; concurrent deletes cannot reach
    zero; `racRpId = Nothing` permits down to one; `CredentialAdmin` renders in
    `open` mode.
18. Frontend: add-second-passkey happy path; `step_up_required` restarts the
    ceremony exactly once **when authenticated** and shows the sign-in copy when
    not; `grant_required` keeps the field only where it helps and offers
    "Check again"; `grant_invalid` keeps the text and stops sending the token;
    open-mode enrollment with no typing; gate re-check; Remove disabled on the
    last usable; waive UI, `waive()` and styles deleted; `CapabilityNote` copy
    branched by surface.
19. `make check` green (build + test + lint + frontend-test; no coverage numbers
    — HPC is not wired). `README.md` (including "enroll before exposing the
    port", R1), `CHANGELOG.md` ("Upgrading": the TTL, the removed `waive`
    endpoint, the migration) and commented `security.toml` / `credentials.toml`
    examples.

## 17. Review resolutions

**Round 4 — security/correctness (blocking, fixed here).**

| Item | Resolution |
|---|---|
| B-1: absent token fell through to a session grant, so a stolen cookie could redeem a live assertion grant | §5 invariant 2, §7.2 `findAuthority`: authority is always presented; `Nothing` is valid only for `CliWindow`. §16.6 pins the regression |
| B-2: `cli_window` allowed in `UnusableOnly`, contradicting invariants 2/4 | §7.2: window only in `NoCredentials`; `cli_window` elsewhere is `GrantRequired`. §16.13 asserts the refusal |
| Mode raise + credential write not atomic | §6.1 `enrollCredential` under one lock, CAS restore, `ModeRaise` witness |
| Boot clobbers an outstanding grant | §7.3 / §16.9: mint only when none is outstanding |
| Grant freshness across processes unstated | §7.3: read per request, never cached; §16.8 |
| Gate has no re-check | §13.4 |
| Sessionless "enroll this device" 401s | §13.2 branches on `authenticated`; §7.2 returns `GrantRequired` when no session |
| `/access` unusable in `open` mode | §8.1 `CredentialAdmin = AdminOpen`; §13.6 |
| `(passkey, UnusableOnly, none)` row missing | §13 table |
| Stale `seal.enroll-token` contradictory | §8.2 + §13.3 |
| Liveness lock exists nowhere | §6.3 `serve.lock`, §12 `flock`, §16 step 0 `serveLockPath`, W3 |
| `BootRefusal` can't express invalid `mode`; its test was deleted | §10 `BrModeInvalid`; §16.5 ports the fixture |
| Banner has no sink | §11 `(Text -> IO ())` argument, moved to an imported module |
| §16.3(c) vacuous | §16.3(b) compares recursively walked table paths; §16.2 is the red test for implicit nodes |
| `CredentialAvailability` module unassigned; constructor split breaks `-Werror` | §7.1 module placement; §16 step 0 splits the constructors by work unit |

**Rounds 1–3, retained.** Round-3 blockers remain closed as recorded in rev 4
(`WriteMode` chokepoint, claim keying, boot types, `biSection` totality, ADT
justification, isomorphic enums, blast radius, `ExitCode` seam). The rev-3
"base16 casing asymmetry" was **refuted empirically** and is now a regression
guard only.

## 18. Risks

| Risk | Mitigation |
|---|---|
| Stolen cookie mints a permanent credential | authority must be presented; a cookie alone yields `step_up_required` (§7.2) |
| Forged registration with a captured challenge | the grant is the gate, not the ceremony (§3) |
| First-enrollment race | **accepted** (§4 R1); narrow, loud, reversible |
| Two enrolments redeem one grant | `grant_id` + `bound_challenge` + `O_EXCL` claim (§7.3) |
| Crash mid-enrollment | fixed order, grant lost, no credential added (§7.4) |
| Store corrupted or emptied | boot refuses; writer refuses empty and missing-file mutations; `reset` needs the daemon stopped |
| Legacy layout destroyed by `/vault setup` | `saveSecurityConfig` chokepoint with a `--yes`-gated exemption (§10) |
| Boot grant expires | banner names `enroll`; TTL is a flag, not config |
| Operator loses every device | `enroll` first, `reset --yes` last, both on the login screen |
| Audited evidence rotated away | state-changing events in a separate sink; refusal events aggregated (§15) |
| Agent reads/truncates the store or log | accepted (§4 R2); detective only |

## 19. Implementation order

One branch (`gateway/passkey-access-control`), ordered commits; each leaves
`make check` green. `acfcCredentials` may only be removed in the commit that
gives the handle its `credentials.toml`-sourced credentials.

- **W0 — Path confinement.** Landed (`5428e08`).
- **W1 — store split, complete.** `credentials.toml` codec + `fixNode` export +
  `createCredentialsFile`/`updateCredentialsFile` + `CredentialAvailability` +
  `preflight`/`bootPlan` (credentials half) + `newAccessControlHandle` taking
  `BootPlan` + legacy codec/`BrLegacyLayout`/`BrModeInvalid` +
  `saveSecurityConfig` `WriteMode` + `AcMigrateCredentials` + `migrate-credentials`
  + `persistSignCount` move + the last-usable delete guard. `acfcCredentials`
  removed here with its consumer. Fixes §1.4, §1.7.
- **W2 — `rp_mismatch`** derivation + recompute points. Fixes §1.6.
- **W3 — grants.** `Seal.Security.EnrollmentGrant` + `findAuthority` +
  `enrollmentAuthority` + `enrollCredential`/`ModeRaise` + grant/claim lifecycle
  + `serve.lock` acquisition in `serve` + `AcEnroll`/`AcDisable` + `enroll`/
  `disable` CLI.
- **W4 — endpoints and banner.** `enroll/*`, endpoint rewiring, `waive` removal,
  `printAccessControlBannerTo`. Fixes §1.1, §1.2, §1.3, §1.5. W3 and W4 ship
  together — W3 mints grants nothing accepts yet.
- **W5 — audit. W6 — frontend. W7 — docs/CHANGELOG.**

## 20. Open questions

1. Should `disable`/`reset` signal a running daemon rather than refuse?
2. `label` is hardcoded `"passkey"`; derive it at enrollment or make it settable.
3. `registerOptions` mints a fresh random user handle per ceremony (`:621`); a
   stable operator handle would let a synced passkey update rather than
   accumulate.
4. `enrollment_via` is a snapshot; a push frame would remove "Check again".
