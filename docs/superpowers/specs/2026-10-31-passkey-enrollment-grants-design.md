Title: Passkey enrollment grants — design
Status: proposed
Date: 2026-10-31
Rev: 4 — rev 3 was rejected by all five reviewers. §17 maps every round-3
blocker to its resolution. Supersedes two items of the predecessor design:
`POST /api/auth/waive` is removed (§8.1) and `[access_control] mode` may be
written by a one-way writer (§5.1).

Follows `2026-10-30-passkey-access-control-design.md` (rev 3). This document
does not revisit that design's verification core; it replaces its enrollment
authorization model and splits credentials out of `security.toml`.

## 1. Problem

Seven issues, in the order a user meets them.

1. **Adding a second passkey dead-ends.** `/access` → "Add a passkey" calls
   `POST /api/auth/register/options` — the *first-run*, setup-code gate
   (`frontend/src/lib/auth.ts:189-193`). A healthy `passkey` boot mints no
   setup code (`needsCode = mode /= AccessPasskey || rpMismatch`), so the
   operator gets `setup_code_required` with "no setup code is active; restart
   `seal serve` to get one" (`Gateway/AccessControl.hs:589`) — and no restart
   can produce one. `credentials/options` exists, is session-gated, and nothing
   calls it. (`credentials/verify` *is* called, `AccessView.tsx:52`.)

2. **A live session can mint a permanent credential.** `credentials/*`
   authorizes on a bare session cookie (`withSessionAuthorization`, `:571`). A
   stolen cookie buys a passkey that outlives the cookie and any revocation.

3. **The only scalable enrollment authority is a boot-time bearer code with no
   expiry**, mintable only by restarting the process.

4. **Credential churn rewrites the boot-critical document.** Credentials live in
   `security.toml`, and `persistSignCount` (`:813`) rewrites the whole file on
   **every successful login**. A corrupt write there refuses to boot.

5. **`rp_mismatch` recovery is unreachable.** The `AccessPasskey` banner branch
   (`Command/Serve.hs:655-657`) never prints the code an orphaned boot mints,
   and never writes `state/setup-code`.

6. **`rp_mismatch` uses the wrong quantifier.** It is
   `any (\c -> Just (credRpId c) /= resolvedRpId) creds` (`:192-193`) — "some
   credential differs". The orphan is never removed, so the flag stays true
   forever: after re-enrollment the operator's *working* key is still reported
   as a mismatch, `AccessGate` keeps rendering the setup screen, and every boot
   mints another grant.

7. **Spec and implementation disagree on `passkey` + zero credentials.**
   Predecessor §10 says exit 1; `resolveAccessControl` downgrades to
   `AccessUnconfigured` first (`Security/AccessControl.hs:87-93`), making
   `bootDecision`'s refuse branch unreachable.

## 2. Non-goals

- Multi-user accounts. One operator, N credentials.
- Removing the ability to run without access control — but *disabling* it
  becomes CLI-only (§8.1).
- Attestation verification (§3 states the constraint; it is not an oversight).
- Per-credential policy.
- A credential count cap.
- TTLs or windows as **config**; they are CLI flags.
- Recovery without local access.
- Sessions surviving a `seal serve` restart.

## 3. The constraint that shapes everything: registration is not authenticated

With `attestation: "none"` and no statement inspection, the verification core
checks *internal consistency* only: the challenge matches one it issued,
`authData.rpIdHash == SHA-256(rpId)`, the flags are set, `rawId` agrees with the
attested id, the COSE key is a valid P-256 point. Every one of those fields is
client-produced, and `clientDataJSON.origin` is the **browser's own claim**.

> A client holding a valid challenge can generate its own P-256 keypair and a
> self-consistent `clientDataJSON` + `authData`, and `verifyRegistration` will
> accept it.

So the origin check is a browser-honesty control, and **the enrollment grant is
the only real gate on a privilege that survives forever.** Three consequences
drive the design:

1. A grant must be a **secret the client holds**, never something ambient to a
   cookie. A session-carried grant is a cookie-carried grant (§7.1).
2. A grant must be short-lived and purpose-scoped.
3. No grant source may be secret-free on a network-reachable surface (§7.2).

## 4. The model, as invariants

1. A passkey is required unless `mode = "none"` is **written** in
   `security.toml`. Absence never means "off", and no writer may introduce that
   meaning implicitly.
2. No usable credential → only a **CLI-minted token** grant authorizes
   enrollment. Local access is the authority.
3. Usable credentials → a grant minted by a **fresh assertion from an enrolled
   credential**, or by a **CLI-minted token**. Both are client-held secrets.
4. `rp_mismatch` (no usable credential) → CLI token only.
5. Every grant is one-shot and TTL-bounded. The TTL is an upper bound, never a
   quota: a 5-minute window with a successful enrollment at minute 1 authorizes
   nothing further.
6. **Disabling access control is CLI-only.** No HTTP endpoint can turn it off.
   Enrolling can only turn it *on*.
7. Deletion stays at session-or-CLI-token level (it cannot grant access), is
   audited, and can never remove the last **usable** credential.

## 5. Configuration

### 5.1 `~/.seal/security.toml`

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

`AccessControlFileConfig` **loses** `acfcCredentials`, so the credentials writer
(§9.1) cannot name `mode`, `origin` or `rp_id`. Three further corrections, all
required by invariants 1 and 6:

- `emptyAccessControl` currently defaults to `acfcMode = Just "none"`
  (`Config/Security.hs:367-373`), so any write to a section-less file records an
  *implicit* off. It becomes `acfcMode = Nothing`.
- `POST /api/auth/waive` is **removed** (§8.1). `seal access-control disable
  --yes` replaces it, with no network surface.
- Enrollment in `mode = "none"` must still turn access control on (today
  `persistRegistration` writes `acfcMode = Just "passkey"`). Since the
  credentials writer cannot name `mode`, a second, *narrower* writer exists:

```haskell
-- Returns the previous mode so the caller can restore exactly that value.
-- It can only raise the mode to "passkey"; it cannot express "none".
enablePasskeyMode   :: FilePath -> IO (Either Text (Maybe Text))
restorePreviousMode :: FilePath -> Maybe Text -> IO (Either Text ())
```

  `restorePreviousMode` writes only the value `enablePasskeyMode` handed back —
  never an independently chosen one — so the invariant holds: **the web UI can
  never lower the mode; it may only undo a raise it just performed.**

  Enrollment is then a two-write sequence, in this order, under
  `securityWriteLock`:

  1. `enablePasskeyMode` — fail ⇒ nothing written, `500 write_failed`.
  2. `createCredentialsFile` / `updateCredentialsFile` — fail ⇒
     `restorePreviousMode`, then `500`. The in-memory handle is updated only
     after both succeed.

  Mode-first is deliberate: a crash between the steps leaves `passkey` +
  absent credentials, which resolves to the grant-gated `unconfigured`
  bootstrap (§10) and is loud. Credential-first would leave a credential
  enrolled on a still-open gateway — silent non-enforcement, the worse failure.

Stated invariant, testable: **the web UI can change which credentials are
enrolled and can turn access control on; it can never turn it off, change
`origin`/`rp_id`, or alter how enrollment is authorized.**

The type split does not stop an agent from *reading* these files — see §17.

### 5.2 `~/.seal/credentials.toml` — new, gateway-owned

Sibling of `security.toml`, not under `config/` (the version-controlled config
repo cannot resurrect a stale credential set). 0600 via `writeSecretFile` plus
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

`added_via` shares its vocabulary with the grant's `minted_via` (§7.1) plus
`legacy`; it is a field on `CredentialFileConfig`, and the runtime `Credential`
gains `credAddedVia` so `/access` and `status` can report it.

Decode policy: unknown `version` ⇒ boot refusal; unknown `added_via` ⇒ `legacy`;
a semantic failure inside one credential (bad base64 key, bad timestamp,
negative counter) ⇒ boot refusal, not a dropped entry.

### 5.3 `~/.seal/state/` — ephemeral

| File | Contents | When |
|---|---|---|
| `enrollment-grant.json` | `{grant_id, minted_via, expires_at, created_at, token_sha256?, bound_challenge?}` | a grant is outstanding |
| `enrollment-grant.claimed-<grant_id>` | `{grant_id, challenge_id, deadline}` | a ceremony is in flight (§7.3) |
| `enrollment-token` | the plaintext token, 0600 | minted **and** stderr is not a TTY |

`token_sha256` is `null` only for `CliWindow`, which by design has no secret
(§7.2). A grant file that fails to parse is treated as absent, deleted and
logged — never a boot refusal, because a grant carries no durable authority and
absent is never more permissive than present (§7.3).

The plaintext file exists so a daemon operator can *read* the token
(learnings 2026-10-30 §8). It is written only off-TTY, and the **token itself is
never printed to stderr** — off-TTY stderr may be a group-readable journal. Off
a TTY the banner prints the path; on a TTY it prints the token.

Claim markers are reaped by the same boot sweep that collects stale ssh-agent
registries (`Command/Serve.hs:132-135`).

## 6. The verification core: unchanged

No change to `Seal.Security.WebAuthn`.

## 7. Enrollment grants

### 7.1 One type, four sources, two deliveries

New module `Seal.Security.EnrollmentGrant` (it cannot live in
`Seal.Security.AccessControl`: `Session`/`AuthErr` are gateway-local and the
import would cycle).

```haskell
data GrantSource = CliToken | CliWindow | Assertion
data GrantPhase  = GrantMinted | GrantBound ChallengeId
newtype GrantId     = GrantId Text
newtype ChallengeId = ChallengeId Text   -- the challenge text, i.e. the map key
data Grant = Grant
  { grId        :: !GrantId
  , grExpiresAt :: !UTCTime
  , grSource    :: !GrantSource
  , grPhase     :: !GrantPhase
  , grTokenSha  :: !(Maybe ByteString)   -- Nothing only for CliWindow
  }

-- | The minting source *is* the authority; a second enum would be isomorphic.
type EnrollmentAuthority = GrantSource

data GrantDenied = GrantRequired | StepUpRequired | GrantInvalid
```

| Source | How the client holds it | Storage | TTL | Consumed |
|---|---|---|---|---|
| `CliToken` (`enroll`) | the printed token | `state/` digest | 10 min | successful registration |
| `CliWindow` (`enroll --no-token`) | nothing | `state/` file | 5 min | successful registration |
| `Assertion` (`enroll/verify`) | **a token in the response body** | session: digest only | 120 s | at bind |
| `CliToken` (boot-minted) | banner / `state/enrollment-token` | `state/` digest | 10 min | successful registration |

**The assertion grant is a client-held secret, not a session flag.** A
session-carried grant is a cookie-carried grant, and §3 says a stolen cookie
must not be able to mint a permanent credential. `POST /api/auth/enroll/verify`
therefore returns

```json
{ "ok": true, "grant_token": "<32 hex>", "grant_expires_at": "…" }
```

and stores only `sha256(grant_token)` for that session. `credentials/{options,
verify}` require the token in `X-Seal-Enroll-Token`. A cookie thief cannot read
another client's response body, and the custom header makes the request
non-simple (a cross-origin page would need a preflight; auth responses carry no
CORS headers). The token lives in JS memory only — never `sessionStorage`,
`localStorage` or a cookie — so a page reload forces a fresh assertion.

**`CliWindow` is confined to a loopback *bind* and a loopback origin, with no
override.** A secret-free grant is acceptable only where "can write `~/.seal/`"
is already the authority (invariant 2). Testing the *origin* is not enough:
`host = "0.0.0.0"` with `origin = "https://localhost:8787"` passes an
origin-only check while the socket is internet-reachable, and §3 means an
attacker could then forge a registration and permanently lock the gateway to
their own key. Two checks, both required:

- `--no-token` refuses unless `isLoopbackHost (gcHost gwCfg)` **and** the
  resolved origin host is loopback.
- Boot refuses (`BrUnsafeBind`) when the bind is non-loopback but the resolved
  origin host is a loopback literal — a configuration that can only serve local
  clients while exposing the socket.

There is no `--allow-remote-enrollment` flag: it existed solely to open a
5-minute unauthenticated enrollment race on a public origin, and a remote
operator can paste a `CliToken` instead. A window grant authorizes **enrollment
only** — never `GET`/`DELETE` (§8.1), and `waive` no longer exists.

**Token form.** `generateToken` emits lowercase hex (verified: presenting
`T.toUpper token` returns 403, `T.toLower` returns 200). The SPA's
`normaliseCode` lowercases both typed input and `#enroll=` fragments
(`auth.ts:58-59`), so the two already agree. The server still compares on
`T.toLower presented` — a no-op today that keeps the browser working if the
formatter's case ever changes. A regression test pins the contract (§16.12).

### 7.2 The decision function

```haskell
data CredentialAvailability = NoCredentials | UnusableOnly | Usable
credentialAvailability :: Maybe Text -> Map Text Credential -> CredentialAvailability

data GrantContext = GrantContext
  { gcNow          :: !UTCTime
  , gcMode         :: !AccessMode
  , gcAvailability :: !CredentialAvailability
  , gcFileGrant    :: Maybe Grant
  , gcSessionGrant :: Maybe Grant
  }

enrollmentAuthority :: GrantContext -> Either GrantDenied EnrollmentAuthority
```

`rpMismatch` is `credentialAvailability rpId creds == UnusableOnly`, which
answers the vacuous-truth problem in §14 by construction. When `racRpId` is
`Nothing` (wildcard bind, `mode = "none"`), a non-empty store counts as
`Usable` — matching §9.4's delete guard so the two cannot drift.

Total matrix (15 rows cover all 3 modes × 3 availabilities × 3 file states ×
2 session states = 54 combinations; `X` = none):

| Mode | Availability | file grant | session grant | Verdict |
|---|---|---|---|---|
| `unconfigured` | `NoCredentials` | `cli_token` | any | `CliToken` |
| `unconfigured` | `NoCredentials` | `cli_window` | any | `CliWindow` |
| `unconfigured` | `NoCredentials` | `X` | any | `Left GrantRequired` |
| `open` | any | `cli_token` | any | `CliToken` |
| `open` | any | `cli_window` | any | `CliWindow` |
| `open` | any | `X` | `X` | `Left GrantRequired` |
| `open` | any | `X` | `assertion` | `Left GrantRequired` |
| `passkey` | `NoCredentials` | token/window | any | as `unconfigured` |
| `passkey` | `UnusableOnly` | `cli_token` | any | `CliToken` |
| `passkey` | `UnusableOnly` | `cli_window` | any | `CliWindow` |
| `passkey` | `UnusableOnly` | `X` | any | `Left GrantRequired` |
| `passkey` | `Usable` | `cli_token` | any | `CliToken` |
| `passkey` | `Usable` | `cli_window` | any | `CliWindow` |
| `passkey` | `Usable` | `X` | `assertion` | `Assertion` |
| `passkey` | `Usable` | `X` | `X` | `Left StepUpRequired` |

Precedence when both are live: `CliToken` > `CliWindow` > `Assertion`, for
attribution and audit — a deliberate act is the better record. **On success
every outstanding grant is cleared**, file and session, so a losing grant cannot
remain a standing capability. Clearing never touches sessions.

A **presented** token is not an input to this table; it is resolved first:

```haskell
findGrant :: Maybe Text{-presented-} -> Maybe Grant{-stored-}
          -> Either GrantDenied Grant
```

A presented token whose digest does not match yields `Left GrantInvalid` **even
when a session assertion grant is live**, so a stale token can never be silently
ignored — and a same-session attacker cannot fall through to the victim's grant.
An absent token falls through to `enrollmentAuthority`. An unmatched token is a
**pure read**: no rebind, no consumption, no TTL extension, and it gets its own
backoff counter plus an audit event. Comparison uses `constantTimeEq` on digests.

`GrantDenied` constructors select the HTTP status, the wire code and the UI
branch, which is why an ADT is warranted over `Either Text` here.

### 7.3 Lifecycle

```
Minted --options--> Bound(c) --verify success--> Consumed
   |                    |
   +------ TTL --------+------ TTL -----------> Expired (deleted on read)
```

- **One deadline rule.** Binding stores
  `effective_deadline = min(grant expiry, now + challengeTtl)` in the claim
  record, and `verify` re-checks that stored value. (rev 2 also refused a grant
  whose remaining TTL was below the challenge TTL; because the assertion grant's
  TTL *equals* the challenge TTL, that rejected every assertion grant and made
  step-up unexecutable. It is gone.)
- **Exactly-once via an exclusive claim.** `state/enrollment-grant.claimed-
  <grant_id>` is created `O_CREAT|O_EXCL` holding
  `{grant_id, challenge_id, deadline}`. The `create` result — not an earlier
  read — decides the winner, so two concurrent verifies with one grant cannot
  both succeed. Keying by `grant_id` alone (one marker per grant) is what makes
  that true; the record carries the challenge so verify can require both ids to
  match.
- **Rebinding after a failed verify.** Failure deletes the claim **iff it still
  carries the same `challenge_id`** (compare-and-delete), so the next `options`
  can rebind and an aborted prompt does not burn a CLI grant for its whole TTL.
- **The bind write-back is conditional.** Rewriting the grant file is allowed
  only if it still holds the `grant_id` that was read, through temp+rename, so a
  concurrent `enroll --cancel` or `--force` is not resurrected.
- **A grant is identified, not just valued.** `grant_id` and `bound_challenge`
  are persisted, so a ceremony bound under G1 cannot consume G2 installed
  mid-ceremony.
- **A failed verify leaves a CLI grant live and unbound** (recovered by the next
  `options`) and leaves an **assertion** grant consumed.
- **Expiry sweep, not "deleted on read".** Reaping happens on enrollment paths,
  on minting and at boot — never on `GET /api/auth/status`, which is public and
  polled: unlinking there could delete a grant the CLI just minted.

### 7.4 Ordering and crash outcome

1. Claim (exclusive `O_EXCL`; the loser gets `grant_invalid`).
2. `enablePasskeyMode` (§5.1) — only when the current mode is not `passkey`.
3. `createCredentialsFile` / `updateCredentialsFile`.
4. Delete the grant file, the claim marker and `state/enrollment-token`.

A crash between 1 and 3 loses the grant and adds no credential — the safe
direction. Write-then-consume would resurrect a live grant, which is worse.
**Lock order is an invariant: `achState` is never held while acquiring
`securityWriteLock`.**

`securityWriteLock` is an in-process `MVar`, so cross-process safety (the CLI
while `serve` runs) rests on unique temp names, atomic rename, digest
comparison and the `O_EXCL` claim — not on the lock. `credentials.toml.tmp` and
`security.toml.tmp` (`Config/Security.hs:280`) both become unique.

## 8. HTTP API

### 8.1 Endpoints

| Endpoint | Gate |
|---|---|
| `POST /api/auth/register/options` / `verify` | `findGrant` + `enrollmentAuthority` |
| `POST /api/auth/credentials/options` / `verify` | `findGrant` + `enrollmentAuthority` |
| `POST /api/auth/enroll/options` | live session **and** `Usable` |
| `POST /api/auth/enroll/verify` | live session **and** a **verified assertion** from a usable credential |
| `POST /api/auth/login/options` / `verify` | none (unchanged) |
| `GET /api/auth/status` | none (unchanged, additive fields §8.3) |
| `GET /api/auth/credentials` | **session or `CliToken`** |
| `DELETE /api/auth/credentials/:id` | **session or `CliToken`** |
| ~~`POST /api/auth/waive`~~ | **removed** |

**`enroll/*` wire format** (previously unspecified, and load-bearing):

- `POST /api/auth/enroll/options` issues a single-use challenge of a distinct
  kind (`stepup`) bound to the calling session, and returns the same shape as
  `login/options` — `{challenge, rpId, timeout, userVerification,
  allowCredentials}` — with **`allowCredentials` restricted to usable
  credentials**. Refuses in `unconfigured`/`open` and when `UnusableOnly`:
  there is nothing to assert with. This is a mode+availability gate, *not* a
  session-presence gate (open mode with credentials enrolled has sessions and
  no usable assertion target).
- `POST /api/auth/enroll/verify` accepts the same body as `login/verify`
  (`clientDataJSON`, `authenticatorData`, `signature`, `rawId`). It requires the
  challenge to be an unconsumed `stepup` challenge belonging to the calling
  session, then runs `verifyAssertion` against the **named credential, which
  must be usable**. Only on success does it return `grant_token` /
  `grant_expires_at` and store the digest; **no failure body carries either
  field**. An assertion naming an orphaned or unknown credential returns
  `grant_invalid` — the picker never offers one, so that is a forged or racing
  client.

**Credential administration predicate** (explicit, because the setup-code
fallback it replaces is retired):

```haskell
data CredentialAdmin = AdminSession | AdminCliToken | AdminDenied
-- window and assertion grants authorize ENROLLMENT ONLY.
```

**`waive` is removed.** Invariant 6 says no HTTP request may disable access
control, so the endpoint goes and `seal access-control disable --yes` replaces
it. That also removes the "one token both enrolls and disables" blast radius and
makes the invariant true by construction rather than by handler logic. The setup
screen's waive affordance becomes instruction text; `AccessGate`'s waive button,
`auth.ts`'s `waive()` and its styles are deleted.

Both `register/*` and `credentials/*` are listed in the middleware allowlists in
every state where a grant can authorize them, and **the handler is the sole
gate** once they are allowlisted — a future omission of the handler check would
be a full bypass, so §16.9's checklist says so explicitly.

### 8.2 Transport

- Header: `X-Seal-Enroll-Token`. `X-Seal-Setup-Token` is retired.
- Fragment: `#enroll=<token>`, parsed and stripped like `#setup=`
  (`auth.ts:46`). The parser accepts a bare token **and** a pasted full URL, so
  a user who copies the whole line `enroll` printed is not punished.
- Comparison: `tokenKey (T.toLower presented)`, `constantTimeEq`, 32-char length
  asserted after normalisation (§7.1).
- Client lifecycle for `seal.enroll-token` (sessionStorage): cleared after a
  successful enrollment, on `grant_invalid`, and on user cancel; never mirrored
  to `localStorage`. When a step-up succeeds the assertion supersedes any stored
  token — the retried request omits the header.
- Wire errors: `grant_required`, `grant_invalid`, `step_up_required`, plus
  `write_failed` (500). No `grant_expired`: an expired grant is deleted and
  treated as absent, so it resolves to whichever verdict the mode implies.

### 8.3 Status

Additive fields (existing consumers unaffected):

```json
{ "enrollment_via": "cli_token|cli_window|assertion|none",
  "usable_credentials": 1,
  "orphaned_credentials": 2 }
```

`enrollment_via` is computed **for the requesting session** and prefers the file
grant when both exist (§7.2 precedence). `usable_credentials` /
`orphaned_credentials` make §14's mixed state legible without keying UI on
`rp_mismatch` (which is false in the mixed case).

There is no separate `enrollment_available` boolean: it duplicated
`enrollment_via` and rev 3's §13 then keyed a button on it while the matrix
keyed a field on the other. One field, one meaning.

`enrollment_via` does disclose "a grant is armed right now" to a same-origin
reader. With `cli_window` confined to a loopback bind, the residual signal is
local-only; documented in §18 rather than removed.

`setup_required` keeps its current meaning for compatibility; the SPA stops
using it as a predicate.

## 9. The credential store

### 9.1 Writers

Two functions, because "create" and "mutate" have different failure semantics:

```haskell
createCredentialsFile :: FilePath -> Map Text CredentialFileConfig
                      -> IO (Either Text ())       -- O_EXCL; first enrollment, migration
updateCredentialsFile :: FilePath
                      -> (Map Text CredentialFileConfig
                            -> Either Text (Map Text CredentialFileConfig))
                      -> IO (Either Text ())       -- requires the file to exist
```

`Either` in the callback so the last-usable rule is enforced **inside** the
lock rather than by a read-then-write in the handler. Round-trip verified before
rename (as `updateAccessControlSection` does). Serialized behind
`securityWriteLock`.

Refusal rules:

- **`updateCredentialsFile` refuses a missing file.** An enrollment creates it;
  every later mutation requires it. That single rule kills two rev-3 hazards: a
  `Map.empty` seed producing a version-only file, and external deletion being
  silently treated as a reset. The caller turns it into "restart `seal serve`"
  guidance.
- **The resulting map may never be empty** ⇒ `Left`.
- External deletion while the daemon runs is therefore loud, not a silent reset,
  and `reset --yes` (which deletes the file) requires the daemon stopped.

`persistSignCount` moves here — it is the highest-frequency writer and the whole
reason for §1.4 — and its failure is **surfaced**, not discarded: today
`claimSignCount` bumps memory first and the file write's `Either` is dropped
(`:813`), so a failed write leaves file and memory divergent across a restart.
New order: persist, then mint the session.

### 9.2 The store is never empty

An existing `credentials.toml` always contains at least one credential, enforced
by §9.1 and §9.4 plus `reset`. That is what makes "present but empty ⇒ refuse to
boot" a corruption signal rather than a lockout.

### 9.3 Codec

`credentialsCodec` needs its own table normalisation for a root `credentials`
node — learnings 2026-10-30 §4 nests per `tableMap` level, and a bare `version`
key does not make the node explicit. `fixNode` is private to
`Seal.Config.Security` and must be exported rather than duplicated. A
normalisation regression makes a *valid* file decode as empty, which is a boot
refusal.

### 9.4 Deletion

Session-or-CLI-token gated. The guard is evaluated on the freshly loaded map
**inside** the writer's callback:

- Refuse if the deletion would leave zero **usable** credentials.
- Count by usability, so removing an orphan is permitted while stripping the
  last working key is not — the correct unit after an rpId change.
- Applies in **every** mode (today only `AccessPasskey`), otherwise a delete in
  `open` mode can empty the file.
- `racRpId == Nothing`: every credential counts as usable, so deletes are
  permitted down to one.
- Concurrent deletes cannot reach zero: check and write are one locked
  operation.

## 10. Boot

Ordering matters more than the ADT, so both are stated. Today: `ensureSealDirs`
(`Serve.hs:128`) → `migrateSecurityConfig` (`:139`) → `loadSecurityConfig`
(`:146`) → `newAccessControlHandle` (`:161`).

**`preflight` runs immediately after `ensureSealDirs`, before every writer.**

```haskell
data BootInputs = BootInputs
  { biSecurityRaw :: !Text
  , biSection     :: Maybe AccessControlFileConfig   -- Nothing = parse failed
  , biCredentials :: !CredentialsPresence
  }

data CredentialsPresence
  = CredentialsAbsent
  | CredentialsPresent Int (Map Text CredentialFileConfig)  -- version, entries
  | CredentialsInvalid Text

data BootRefusal
  = BrSecurityUnparseable Text
  | BrLegacyLayout
  | BrCredentialsInvalid Text
  | BrCredentialsEmpty
  | BrCredentialsVersion Int
  | BrCoordinatesInvalid Text   -- origin/rp_id resolution (resolveOrigin/resolveRpId)
  | BrUnsafeBind Text

data BootPlan = BootPlan
  { bpMode      :: !AccessMode
  , bpOrigin    :: !(Maybe Text)
  , bpRpId      :: !(Maybe Text)
  , bpCreds     :: Map Text Credential
  , bpMintGrant :: !(Maybe GrantSource)
  }

preflight :: SealPaths -> BindCoordinates -> IO (Either BootRefusal BootInputs)
bootPlan  :: BindCoordinates -> BootInputs -> Either BootRefusal BootPlan
```

`biSection :: Maybe` (not `Either Text`) keeps `bootPlan` total: a parse failure
is already a `BootRefusal` from `preflight`. `BrCoordinatesInvalid` carries the
`resolveOrigin`/`resolveRpId` errors, which rev 3 had no constructor for.
`BrCredentialsVersion` is produced by `preflight` from the version field, which
is why `CredentialsPresent` carries it.

`newAccessControlHandle` takes a `BootPlan` and must **not** re-read
`credentials.toml`, or the drift this composite exists to close stays open.
`resolveAccessControl` loses mode-defaulting and credential decoding: presence
and mode resolution live in `bootPlan` alone, which removes §1.7's unreachable
`credentialCount` branch rather than shadowing it.

| Condition | Refusal / action |
|---|---|
| raw `security.toml` unparseable | `BrSecurityUnparseable` — exit 1 |
| legacy credential tables present | `BrLegacyLayout` — exit 1 naming `migrate-credentials` |
| `credentials.toml` unparseable or a semantic entry invalid | `BrCredentialsInvalid` |
| present with zero entries | `BrCredentialsEmpty` |
| unknown `version` | `BrCredentialsVersion` |
| origin/rp_id unresolvable | `BrCoordinatesInvalid` |
| absent credentials + `mode` absent or `passkey` | start `unconfigured`; mint boot grant |
| absent credentials + `mode = "none"` | start `open`; mint boot grant |
| **present and usable**, `mode` absent or `passkey` | start `passkey`; **no** grant |
| **present but `UnusableOnly`** | start `passkey`, `rp_mismatch`; **mint boot grant** |
| present, `mode = "none"` | start `open`; mint boot grant |
| `passkey`, non-loopback bind, origin not `https` | `BrUnsafeBind` |
| non-loopback bind, **loopback-literal origin** | `BrUnsafeBind` (§7.1) |

**Legacy detection decodes, it does not grep.** A raw substring scan for
`[access_control.credentials.` misses the equivalent dotted-key spelling — the
same TOML document — and the next web write would silently drop every table.
`preflight` decodes `biSecurityRaw` with a **retained legacy codec** (a
`LegacyAccessControlFileConfig` that still has `acfcCredentials`) and refuses if
it yields any credential.

**The guard needs a chokepoint, with an explicit exemption.** `security.toml` is
rewritten wholesale by `updateAccessControlSection`, by `updateSecurityConfig`
(`Vault/Commands.hs:227,289` — `/vault setup` and rekey, reachable from a
running gateway or TUI) and by `clearAccessControlSection`. All three call
`saveSecurityConfig`, so the refusal lives there. But a blanket refusal is
self-defeating: `migrate-credentials` and `reset --yes` exist precisely to
*remove* the tables and would be refused too, leaving hand-editing as the only
escape. So the signature gains an explicit intent:

```haskell
data WriteMode = PreserveCredentials | DropCredentials
saveSecurityConfig :: FilePath -> SecurityConfig -> WriteMode -> IO (Either Text ())
```

`DropCredentials` is passed **only** by `migrate-credentials` and `reset --yes`
(both `--yes`-gated, both CLI-only); every other caller passes
`PreserveCredentials` and gets `Left` when the raw file still holds a credential
table. An undocumented bypass would be worse than the four-writer guard this
replaces, so §16.13 asserts both directions.

`migrateSecurityConfig` is **not** a threat: it writes `security.toml` only in
its Case 1 (security.toml absent), which cannot coexist with legacy credentials,
and otherwise rewrites `config.toml` only. It gains `IO (Either Text ())` for
testability; its ordering is not load-bearing.

Absent credentials resolving to `unconfigured` is not a downgrade: anyone who can
delete `~/.seal/credentials.toml` can equally run `reset --yes` or
`disable --yes`, so the required capability is unchanged.

## 11. Boot banner

- `unconfigured`, `open`, and `passkey`+`UnusableOnly` all mint a grant, and all
  three **print it** — to stderr on a TTY, and to `state/enrollment-token` plus a
  *path* mention when not a TTY.
- The banner reports absolute and relative expiry and names
  `seal access-control enroll`, so an expired grant is never "restart
  `seal serve`".
- A healthy `passkey` boot prints neither token nor URL.
- `open` mode: the grant is not protecting an already-open surface; it stops a
  network client from enrolling its own credential and flipping `open` into
  locked-with-my-key. That is the justification, stated rather than implied.
- `printAccessControlBannerTo :: ChannelCaps -> Bool{-stderrIsTTY-} -> SealPaths
  -> NewAccess -> IO ()`. The TTY predicate is an **argument**, never
  `hIsTerminalDevice` inside the callee.

## 12. CLI

```
seal access-control enroll [--ttl <N>[smh]] [--no-token] [--force] [--cancel]
seal access-control disable --yes
seal access-control reset --yes
seal access-control migrate-credentials [--yes] [--force]
```

`runAccessControl :: AccessControlCmd -> ChannelCaps -> SealPaths -> IO ExitCode`
with `exitWith` confined to `AppMain.hs`, so exit codes are assertable in-process
(the rev-3 text promised 0/1/2 with no seam that could return them).

- `--ttl` grammar: `<N>` **must** carry a suffix (`s`/`m`/`h`); a bare number is
  a usage error. Clamped to 30 s – 24 h; defaults 10 m (token) and 5 m (window).
- Flag matrix, complete: `--cancel` is mutually exclusive with `--no-token`,
  `--ttl` and `--force`; `--force` is valid with either mint mode; `--cancel`
  with nothing outstanding is a no-op exiting 0.
- Exit codes: `0` ok, `1` refusal, `2` usage. One-line reason on stderr; the
  token on **stdout** (pipeable).
- Without `--no-token`: mint `CliToken`, print the `#enroll=` URL and the bare
  token. Default refusal on an outstanding grant prints `minted_via` and
  remaining TTL and names `--force`/`--cancel`.
- `--no-token`: mint `CliWindow`. Refuses unless the **bind** and the resolved
  origin are both loopback, and refuses an unresolvable origin. No override.
- `--cancel` removes the file-backed grant, the claim marker and
  `state/enrollment-token` only; `status` says a signed-in session may still
  hold an assertion grant.
- `disable --yes` is the only way to turn access control off: writes
  `mode = "none"` and preserves credentials. `reset --yes` deletes
  `credentials.toml` and the grant files as well as clearing `[access_control]`.
  Both require the daemon stopped — detection is an exclusive lock file held for
  the daemon's lifetime, not a port probe, so the check cannot false-positive.

`status` must report what `bootPlan` would act on, because the current
`loadSection` swallows a parse error into "not configured"
(`Command/AccessControl.hs:86-91`) — the §1.1 dead end in a new place. It
reports: the resolved or not-resolved origin/rpId; the credential-store
condition (absent / present with `version` and usable+orphaned counts / empty /
invalid / legacy / unknown version); the grant block (`minted_via`, expiry, or
none); and per credential a stable line (id prefix, `added_via`, `rp_id`,
usable).

`migrate-credentials`: reads the legacy tables via the legacy codec, writes
`credentials.toml` with `added_via = "legacy"`, removes the table
(`DropCredentials`), reports what it moved, idempotent; requires `--yes`; refuses
when `credentials.toml` exists unless `--force`.

## 13. Frontend

Both `/access` (AccessView) and the bootstrap/login panel (AccessGate) derive
their controls from **one shared hook** over the status payload. This is the fix
for rev 2's split brain, where `enrollment_via` was applied to the gate only and
`/access` kept `needsCode = state !== 'passkey'` — leaving `open` mode (where the
gate renders children) with no working enrollment surface for a `cli_window`
grant.

**Precedence rule, stated first:** `state == 'passkey' && authenticated &&
usable_credentials > 0` renders the application. The table below governs only
what the **gate** shows; `/access` is reachable inside the app and owns the
add-passkey flow.

| state | availability | `enrollment_via` | Gate renders |
|---|---|---|---|
| `unconfigured` | `NoCredentials` | `cli_token` | setup + token field + CLI hint |
| `unconfigured` | `NoCredentials` | `cli_window` | setup, **no** field, action enabled |
| `unconfigured` | `NoCredentials` | `none` | setup, action disabled, CLI instruction |
| `passkey` | `Usable` | `none` | login panel + "enroll this device" (field always visible) |
| `passkey` | `Usable` | `cli_token` / `cli_window` | login panel + "enroll this device", enabled |
| `passkey` | `Usable` | `assertion` | login panel; `/access` add already authorized |
| `passkey` | `UnusableOnly` | `cli_token` | setup + token field, "keys registered for a different address" |
| `passkey` | `UnusableOnly` | `cli_window` | setup, no field, action enabled |
| `open` | any | any | children; `/access` owns enrollment |

`/access` uses the same hook, so open-mode enrollment works with a `cli_window`
grant (no typing) and shows the CLI instruction when `none`. Re-enrollment while
a usable credential exists is `/access`'s "Add a passkey" flow after signing in —
not a gate state; keying it on `rp_mismatch` was the rev-2 error, since
`rp_mismatch` is false in the mixed case.

Specific changes:

1. `createPasskey` gains a target (`bootstrap` | `add`) so options goes to
   `register/options` or `credentials/options`. `auth.test.ts` needs the new
   signature.
2. Target selection for "enroll this device": `usable_credentials > 0` ⇒
   `credentials/*`, else `register/*`.
3. `step_up_required`: `enroll/options` → `credentials.get` → `enroll/verify` →
   **restart the add ceremony from the beginning** (the challenge was consumed;
   re-POSTing the attestation cannot work) → `credentials/options` with the
   returned `grant_token`. A second `step_up_required` shows "That took too
   long — try adding the passkey again."
4. `grant_required`: CLI instruction, no field. `grant_invalid`: keep the field,
   "that token is not valid or has expired", keep the typed value, and clear
   `seal.enroll-token` only on success.
5. A successful enrollment from the gate mints a session (today
   `register/verify` does), so the operator lands in the app. Stated, because it
   determines the journey's success criterion.
6. `/access` no-grant state: instruction text plus a "Check again" action, and
   re-fetch status on `grant_required` — `enrollment_via` is a snapshot, so after
   running `enroll` in a terminal the button would otherwise stay disabled.
7. `/access` Remove: disable on the last **usable** credential (not
   `creds.length <= 1`), and render the `CredentialAdmin` outcome (disabled + one
   line) rather than letting an unauthenticated DELETE 403.
8. `/access` renders `added_via` as human copy: "confirmed with an existing
   passkey" / "added from the terminal" / "added with an enrollment window" /
   "migrated", and marks orphans "cannot sign you in here; safe to remove".
9. Delete the waive button, `auth.ts`'s `waive()` and its styles; replace
   `AccessGate`'s "or continue without access control" (line 286) with the
   `seal access-control disable --yes` instruction. The lost-device note names
   `seal access-control enroll` **before** `reset --yes`, so operators do not
   wipe credentials on devices they still own.
10. Two distinct prompts: "Confirm it's you to add a passkey to Seal" before the
    step-up `get`, then "Now choose the passkey to add" before the `create`.

## 14. `rp_mismatch`, redefined

`rpMismatch = credentialAvailability rpId creds == UnusableOnly`, i.e. *some*
credentials exist and **none** is usable. The explicit `NoCredentials` case
removes the `all`-over-empty-set vacuous truth (a fresh install would otherwise
report `rp_mismatch: true` and show "registered for a different address" with
zero passkeys).

Recompute points, named: the flag is derived from the credential map, so it is
recomputed after every mutation — `persistRegistration` currently hardcodes
`acsRpMismatch = False` (`:~728`) and `deleteCredential` never recomputes. It is
derived from the map on every mutation rather than assigned, so it cannot go
stale in either direction.

## 15. Audit

There is no Audited log (`ISA/Dispatch.hs:101-105`), and
`Seal.Gateway.AccessControl` has no logger in scope. New plumbing:

- `Seal.Gateway.Audit`, appending JSONL to `~/.seal/state/access-control.log`.
  Path-based, so the **CLI can emit `grant_minted` too** (it has no handle).
  Opened `O_APPEND|O_CREAT|O_NOFOLLOW`, refusing a symlink or non-regular
  target, with a size cap and rotation. `writeSecretFile` truncates and cannot be
  reused.
- Events: `credential_added`, `credential_removed`, `grant_minted`,
  `grant_consumed`, `grant_refused`, `mode_enabled`, `mode_disabled`. Fields:
  timestamp, event, credential id, label, `rp_id`, origin, `added_via`/
  `minted_via`, remaining TTL at consumption.
- Never log the token, a token prefix, or a token-derived digest.
- **Every unauthenticated-reachable refusal** (`grant_refused` *and*
  `grant_invalid`) is aggregated per (source, minute) on a key containing no
  attacker-controlled text, with backoff applied *before* the emit, and
  state-changing events are kept out of the flood-rotatable set (separate sink or
  reserved floor) — otherwise log-flooding can rotate away
  `credential_added`/`mode_*` evidence.
- **Stated honestly:** the log is a *detective aid* under the same-uid
  assumption, not tamper-evidence — the agent can truncate it. §17 scopes the
  claims accordingly.

## 16. Definition of done

**Step 0 — wiring and blast radius.** Each new module goes in `.cabal`
`exposed-modules:`, `.cabal` test-suite `other-modules:`, and `test/Main.hs`.
`Seal.Config.Paths` gains `credentialsFilePath` (spHome) and
`enrollmentGrantPath` (spState), with `PathsSpec` coverage. `seal-harness.cabal`
and `test/Main.hs` are merge hotspots: minimal edits, rebase before PR.

Three dependency lists, all of which must move together:

- **`acfcCredentials` removal** (5 files): `src/Seal/Gateway/AccessControl.hs`,
  `src/Seal/Security/AccessControl.hs`, `src/Seal/Config/Security.hs`,
  `test/Seal/Gateway/AccessControlSpec.hs` (`passkeySection`, `credMap`),
  `test/Seal/Config/SecurityAccessControlSpec.hs`.
- **`saveSecurityConfig` gains a `WriteMode`** (5 files):
  `src/Seal/Config/Migrate.hs`, `test/Seal/Config/SecuritySpec.hs`,
  `test/Seal/Command/ChannelSpec.hs`, `test/Seal/Vault/CommandsSpec.hs`,
  `src/Seal/Command/AccessControl.hs`.
- **`resolveAccessControl` loses credential decoding** (2 files):
  `src/Seal/Command/AccessControl.hs`, and the whole
  `describe "resolveAccessControl"` block in `SecurityAccessControlSpec.hs`
  (`:129-190`), not just the four line numbers rev 3 cited.

Also: `src/Seal/Types/Command.hs` (`AccessControlAction` gains `enroll`,
`disable`, `migrate-credentials`) and `src/Seal/AppMain.hs:47`. Existing tests
that break: `AccessControlSpec` (`X-Seal-Setup-Token` at :89, :98, :114, :133,
:146, :255; `naSetupCode` at :144, :325; `acfcCredentials` at :183, :382),
`SecurityAccessControlSpec` (:65, :182, :242, :250), `ApiTestHarness` (:468),
`AccessGate.test.tsx`, `SignOutButton.test.tsx`.

1. `credentialsCodec` format round trip `decode (encode c) == Right c` over
   `Map Text CredentialFileConfig` with valid bare keys and bounded text;
   separate semantic round trip through `credentialFromFile`/`credentialToFile`.
   `Arbitrary` instances newtype-wrapped (no orphans).
2. An **idiomatic** `[credentials.<id>]`-only fixture decodes non-empty — not
   `Toml.encode` output, which hides the implicit-table bug.
3. **Three assertions**, of which (c) is the red one:
   (a) *guard* — `saveSecurityConfig … PreserveCredentials` on a raw fixture
   containing a legacy credential table returns `Left` and leaves the bytes
   identical;
   (b) *no collateral damage* — a write on a credential-free fixture preserves
   every other top-level table;
   (c) *the red one* — parse a raw fixture, re-encode it, and assert every
   top-level table name in `Toml.tomlTables` of the raw document is still present
   in the re-encoded document. Use `Toml.parse` + `Toml.tomlTables` rather than
   text-scanning, and keep the fixture to tables `securityConfigCodec` owns
   (`untrusted_execution`, `access_control`), or it fails for the wrong reason.
4. `createCredentialsFile` refuses an existing file; `updateCredentialsFile`
   refuses a missing one, refuses an empty result, preserves `version` and
   untouched entries, and returns `Left` without writing for an unparseable file.
5. `preflight`/`bootPlan` total over every row of §10, `BootRefusal` asserted by
   **code**; `BrCoordinatesInvalid` covered by a wildcard-bind fixture;
   `newAccessControlHandle` takes a `BootPlan` and never re-reads the file.
6. `credentialAvailability` over 5 cases (0 creds / all-mismatch / mixed /
   all-match / `Nothing` rpId); `enrollmentAuthority` over every row of §7.2;
   `findGrant` for match, mismatch and absent — a presented invalid token yields
   `grant_invalid` even with a live assertion grant.
7. Grant lifecycle: consumed authorizes nothing; expired behaves as absent; a
   grant bound to challenge A cannot redeem B (two ids from two `*/options`
   responses); two concurrent verifies with one grant yield exactly one
   credential and one `grant_invalid`; a grant at 119 s remaining authorizes a
   ceremony completing at 119.5 s and one at −1 s does not; a failed verify
   deletes the claim only when it still carries the same `challenge_id`, so the
   next `options` rebinds; a crash between claim and persist leaves the claim
   marker and the grant present, adds no credential, and a subsequent `options`
   rebinds. Concurrency exemplars: `RegistrySpec.hs:127`, `VaultSpec.hs:164`.
8. A cancelled ceremony leaves a **CLI** grant live and an **assertion** grant
   consumed.
9. **`test/Seal/Gateway/AccessControlSpec.hs` is the harness** (not
   `ApiTestHarness`, which wraps `apiApp`; the auth routes are applied outside it
   in `Server.hs:68`). It needs a helper to seed `credentials.toml`, and a fresh
   handle per case (`challengeBurst` is 20). Matrix: every row of §7.2 × the four
   admin/enroll endpoints, plus the middleware-allowlist case (`credentials/*`
   must not 401/403 before the handler runs), plus: cookie-only client with no
   token gets `step_up_required` and no `grant_token` in any body; malformed,
   unknown-credential and orphaned-credential assertions get `grant_invalid` and
   no `grant_token`.
10. `enroll/*` refuse in `unconfigured`/`open` and when `UnusableOnly`; a
    routine `login/verify` sets no grant; `allowCredentials` contains only usable
    credentials.
11. CLI via `runAccessControl` returning `ExitCode`: token to stdout, hints to
    stderr; 0600 files; second outstanding grant refused without `--force` with
    the remaining-TTL message; `--cancel` removes all three artefacts; `--ttl`
    rejects a bare number and clamps; the full flag matrix; exit codes 0/1/2.
12. Token form: the lowercased setup/enroll token is accepted (regression guard,
    already landed); `--no-token` refuses with a non-loopback **bind** even when
    the origin host is `localhost`; boot refuses that combination.
13. Migration: legacy layout ⇒ `BrLegacyLayout` from `preflight`;
    `PreserveCredentials` refuses for `updateSecurityConfig`,
    `updateAccessControlSection` and `clearAccessControlSection`;
    `DropCredentials` is accepted only from `migrate-credentials` and
    `reset --yes`; `migrate-credentials --yes` moves every credential with
    `added_via = "legacy"`, removes the table, is idempotent, refuses without
    `--yes` and when the file exists without `--force`.
14. Banner via `printAccessControlBannerTo`: `UnusableOnly` mints and prints; a
    healthy `passkey` boot prints neither; off-TTY prints the path and **not**
    the token; `mode = "none"` enrollment flips the mode then writes the
    credential, and a failed credential write restores the previous mode.
15. Path confinement: `.seal` rejected by `mkSafePath`, `mkSafePathForWrite`,
    `mkSafePathAllowAbs`, `mkSafePathForWriteAllowAbs`, including through a
    resolved symlink. **Landed** (`5428e08`); the two pure `mkSafePathRemote*`
    variants cannot canonicalise and are out of scope.
16. Deletion: cannot remove the last usable credential; can remove an orphan
    while one usable remains; applies in `open`; two concurrent deletes cannot
    reach zero; `racRpId = Nothing` permits down to one.
17. Frontend: add-second-passkey happy path; `step_up_required` restarts the
    ceremony exactly once; `grant_required` shows the CLI hint and no field;
    `grant_invalid` keeps the field and the typed value; open-mode enrollment
    with a `cli_window` grant and no typing; session-less "enroll this device";
    `/access` re-fetches on `grant_required`; Remove disabled on the last usable
    credential; waive button, `waive()` and its styles deleted.
18. `make check` green (build + test + lint + frontend-test; no coverage numbers
    — HPC is not wired). `README.md`, `CHANGELOG.md` (an "Upgrading" note for the
    TTL change, the removed `waive` endpoint and the migration) and commented
    `security.toml` / `credentials.toml` examples documented.

## 17. Round-3 review resolutions

| Blocker | Resolution |
|---|---|
| Arch A-R3-1 — chokepoint blocks its own recovery paths | §10 `WriteMode` with `DropCredentials` accepted only from `migrate-credentials` and `reset --yes`; §16.13 asserts both directions |
| Arch A-R3-2 — digest asymmetry (lowercase presented vs uppercase minted) | **Refuted empirically**: `generateToken` emits lowercase hex (`T.toUpper` ⇒ 403, `T.toLower` ⇒ 200). §7.1 states the verified behaviour and keeps a `T.toLower` comparison as a safety net; §16.12 pins it |
| Arch S1 — `BootRefusal` cannot express origin/rp_id errors | §10 `BrCoordinatesInvalid` |
| Arch S2 — revert contradicts "cannot express none" | §5.1 `restorePreviousMode` writes only the returned value; invariant reworded to "can never *lower* the mode" |
| Arch S3/S4 — claim keying, unconditional write-back | §7.3 per-`grant_id` claim carrying `{grant_id, challenge_id, deadline}`, compare-and-delete, conditional write-back |
| Arch S5 — second refusal not expressible | §9.1 split into `createCredentialsFile` / `updateCredentialsFile`; the missing-file rule replaces it |
| Arch S6 — session storage wording | §7.1 session holds the `Grant` record plus the digest; the token itself lives only in JS memory |
| Arch S7 — `open` row conflates grant kinds | §13 table splits by `enrollment_via` |
| Arch S8 — incomplete deletion list | §13.9 deletes `auth.ts`'s `waive()` and its styles |
| Sec NEW-1 — loopback check tests origin only | §7.1 requires loopback **bind** too, plus `BrUnsafeBind` for the mismatch; §16.12 |
| Sec NEW-2 — binding not exactly-once | §7.3 (as above) |
| Sec NEW-3 — assertion requirement not in the normative gate | §8.1 states it for `enroll/verify`; §16.9 adds the negative cases |
| Sec M5 — `Nothing` rpId | §7.2 non-empty ⇒ `Usable`, matching §9.4 |
| Sec M6 — audit flooding | §15 aggregates both refusal events, backoff before emit, state-changing events protected |
| Sec M7 — token in group-readable journal | §11/§5.3 print the path off-TTY, never the token |
| Sec M8 — window grant transitively yields a session | §13.5 states enrollment mints a session |
| PM R3-B1 — matrix missing `Usable` + `cli_token`; gate keyed on a value that cannot co-occur | §8.3 drops `enrollment_available`; §13 adds the row and keys the field on token presence |
| PM — waive removal must reach every surface | §13.9 (`/access`, `CapabilityNote`, lost-device note ordering) |
| PM / Dev — `reset`/`disable` liveness detection unstated | §12 exclusive lock file, not a port probe |
| Dev B1 — `enroll/*` wire format unspecified | §8.1 full specification |
| Dev B2 — table not total over `authenticated` | §13 precedence rule + explicit rows |
| CTO B1/B2 — work-unit ordering regressions | §19: the store split lands *with* its consumer; `CredentialAvailability` moves into the same unit |
| CTO B3 — blast radius incomplete | §16 step 0, three dependency lists |
| CTO B4 — exit codes unassertable | §12 `runAccessControl` returns `ExitCode` |
| CTO S1/S5/S6/S7 — test mechanics, `biSection`, ADT justification, isomorphic enums | §16.3(c), §10, §7.2, §7.1 |
| Round-2 claim that `migrateSecurityConfig` was a threat | withdrawn (§10) |

## 18. Risks

| Risk | Mitigation |
|---|---|
| Stolen cookie mints a permanent credential | grants are the only gate; assertion grants are client-held secrets, not session flags (§7.1) |
| Forged registration with a captured challenge | the grant is the gate, not the ceremony (§3) |
| Secret-free window races an attacker | loopback **bind** + loopback origin, no override, enrollment-only (§7.1) |
| Two enrolments redeem one grant | `grant_id` + `bound_challenge` + `O_EXCL` claim (§7.3) |
| Crash mid-enrollment | fixed order, grant lost, no credential added (§7.4) |
| `credentials.toml` corrupted or emptied | boot refuses; writer refuses empty and missing-file mutations; `reset` requires the daemon stopped |
| Legacy layout destroyed by `/vault setup` | `saveSecurityConfig` chokepoint with an explicit, `--yes`-gated exemption (§10) |
| Boot grant expires | banner names `enroll`; TTL is a CLI flag, not config |
| Operator loses every device | `enroll` first, `reset --yes` last, both documented on the login screen |
| `enrollment_via` discloses an armed grant | loopback-only for `cli_window`; residual signal documented (§8.3) |
| Agent reads or truncates the store/audit log | accepted (§17); public keys are not secret; the log is detective only |

## 19. Implementation order

One branch (`gateway/passkey-access-control`), ordered commits. Each commit
leaves `make check` green; intermediate states are not independently shippable,
and the branch is one release. A unit may only remove `acfcCredentials` in the
same commit that gives the handle its `credentials.toml`-sourced credentials —
otherwise the gateway silently downgrades to `unconfigured` after migration.

- **W0 — Path confinement fix.** Landed (`5428e08`).
- **W1 — store split, complete.** `credentials.toml` codec + `fixNode` export +
  `createCredentialsFile`/`updateCredentialsFile` + `CredentialAvailability` +
  `preflight`/`bootPlan` credentials half + `newAccessControlHandle` taking
  `BootPlan` + legacy codec/`BrLegacyLayout` + `saveSecurityConfig` `WriteMode` +
  `migrate-credentials` + `persistSignCount` move. `acfcCredentials` is removed
  **here**, with its replacement consumer. Fixes §1.4, §1.7.
- **W2 — `rp_mismatch` derivation** from `CredentialAvailability` + recompute
  points. Fixes §1.6.
- **W3 — grants.** `Seal.Security.EnrollmentGrant` + `findGrant` +
  `enrollmentAuthority` + grant file/claim lifecycle + `enroll`/`disable` CLI.
- **W4 — endpoints and banner.** `enroll/*`, the endpoint rewiring, allowlists,
  `waive` removal, `enablePasskeyMode`, `printAccessControlBannerTo`. Fixes §1.1,
  §1.2, §1.3, §1.5. W3 and W4 ship together: W3 mints grants nothing accepts yet.
- **W5 — audit.** **W6 — frontend.** **W7 — docs/CHANGELOG.**

## 20. Open questions

1. Should `disable`/`reset` signal a running daemon rather than refuse? The
   design refuses; a signal is friendlier but new plumbing.
2. `label` is hardcoded `"passkey"`, so `/access` shows N identical rows.
   Derive it at enrollment, or make it settable. Deferred; `added_via` carries
   the detection story until then.
3. `registerOptions` mints a fresh random 16-byte user handle per ceremony
   (`:621`); a stable operator handle would let a synced passkey update rather
   than accumulate. Low risk, deferred.
4. `enrollment_via` is a snapshot; a push notification (or the WS `lists`-style
   frame) would remove the "Check again" action. Deferred.
