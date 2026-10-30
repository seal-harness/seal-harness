# Passkey access control for the web gateway — design (rev 3)

Status: proposed
Date: 2026-10-30
Rev 2 resolved round-1 review blockers; rev 3 resolves round-2's. §14 maps
every round-2 blocker to its resolution.

## 1. Problem

`seal serve` exposes the full agent surface over HTTP + WebSocket: send a
message (arbitrary tool execution), read every transcript, run every slash
command, clone repos. Today the only control is the bind address. Binding to
a VPN interface (the common deployment — `host = "0.0.0.0"` behind Nebula /
Tailscale) hands that surface to anything that can route to the port, and even
loopback is reachable from any local process *and* from a web page via DNS
rebinding.

Three states, decided at boot from `~/.seal/security.toml`:

- **passkey** (WebAuthn) — every request must present a passkey-backed session.
- **open** (`mode = "none"`) — allowed, but only when the operator says so.
  Never implied.
- **unconfigured** — no decision recorded. The gateway serves the setup screen
  and nothing else; the first browser visit asks the operator to enroll a
  passkey or to explicitly waive the requirement.

**Trust boundary, stated plainly:** passkeys defend the *network*. The agent
runs as the same uid and can already read/write `~/.seal/`, so it is inside the
boundary; a compromised agent is not defended against. This is written in the
boot banner and in `README.md` rather than implied.

## 2. Non-goals

- TLS termination (the gateway stays plain HTTP; passkeys need a secure
  context, so the operator uses `http://localhost` or a TLS reverse proxy).
- Attestation verification (`attestation: "none"`, statement not inspected).
- Multi-user accounts. One operator, N credentials.
- Sessions surviving a `seal serve` restart.
- "Sign out everywhere" / session introspection.

## 3. Trust anchors: origin and rpId resolved once at boot

`clientDataJSON.origin` and `authData.rpIdHash` are checked against a value
computed **once at boot** — never from a request header. A request-derived
origin makes the check vacuous: an attacker rebinding `evil.com` to the port
controls both sides of the comparison.

`resolveAccessControl` (pure, `Seal.Security.AccessControl`):

1. `[access_control] origin` set → use it verbatim (parse scheme/host/port);
   `rp_id` defaults to its host. If `rp_id` is also set, require it to equal the
   host or be a dot-suffix of it, else refuse to boot.
2. Otherwise derive from `[gateway]`: scheme `http`, host `gcHost`, port
   `gcPort`. Loopback (`127.0.0.1`, `::1`, `localhost`) canonicalises to
   `http://localhost:<port>` / rpId `localhost` — the one name every browser
   treats as a secure context, the literal the boot banner prints, and the
   value `gcAllowedOrigins` already defaults to. One URL everywhere means the
   address the operator clicks is the address that verifies.
3. A wildcard bind (`0.0.0.0`, `::`) yields no derivable origin. If `origin` is
   unset and mode is not `open`, refuse to boot with an actionable message.

`/api/auth/status` reports the resolved `origin`/`rp_id`, so the UI can explain
a mismatch ("you opened `http://10.0.0.5:8080`; this gateway verifies
`http://localhost:8080`").

**Credentials are bound to the rpId they were created with.** A credential
enrolled on `localhost` never validates for `seal.example.com`. Changing
`rp_id` therefore orphans existing credentials; when a stored credential's
`rp_id` differs from the resolved one the gateway reports `rp_mismatch`, mints
a fresh setup code (see §6) and the setup screen offers re-enrollment.

**Reverse proxy:** set `origin = "https://seal.example.com"` and
`rp_id = "seal.example.com"`, and enroll *through the proxy* (§10 permits that
boot combination).

## 4. Configuration

```toml
[access_control]
# "passkey" | "none". Absent = unconfigured.
mode = "passkey"

# Optional. Set when the browser reaches Seal through a TLS reverse proxy.
origin = "https://seal.example.com"
rp_id  = "seal.example.com"

[access_control.credentials.<credential-id-base64url>]
public_key = "<base64url, 64-byte x||y>"   # EC2 P-256
sign_count = 0
label      = "Zoe's MacBook"
created_at = "2026-10-30T14:00:00Z"
rp_id      = "localhost"                  # the rpId this credential was made for
```

Credential ids are base64url (`A-Za-z0-9_-`) — valid TOML bare keys; tomland
quotes them if a form ever needs it. `tableMap` + `normalizeAccessControlTable`
(the pattern from `Seal.SourceControl.Repo`), because tomland silently decodes
an empty map for an `[access_control.credentials.<id>]`-only file (learnings
2026-08-02 §4).

### The write path

`security.toml` is boot-only and agent-immutable. This feature needs exactly
one narrow writer, reachable from the gateway:

```haskell
updateAccessControlSection
  :: FilePath
  -> (AccessControlFileConfig -> AccessControlFileConfig)  -- sees ONLY this type
  -> IO (Either Text AccessControlFileConfig)
```

It re-reads the file, applies `f` to `scAccessControl` only, re-encodes,
re-decodes, and renames into place only if the round trip matches. The callback
type cannot name vault or `untrusted_execution` fields, so a gateway-path bug
cannot rewrite them. Serialized behind the existing `securityWriteLock`.

`saveSecurityConfig` is hardened in the same change: the temp file is created
with `openFd … (Just 0o600)` (mode applied at creation — no world-readable
window), written, closed, renamed. Comments are not preserved (true today for
`updateSecurityConfig`); all keys are.

The `Seal.Config.Security` haddocks that say "never re-read" and "NEVER called
by … the HTTP Gateway" are amended in the same change.

### `unconfigured` vs unparseable

Today `Serve.hs` swallows a load error into `defaultSecurityConfig`; with access
control that would reopen the enrollment window on every boot. New rule: a
*missing* file is fine (defaults); an *existing but unparseable* file makes
`seal serve` exit non-zero with the tomland diagnostics. Fail closed.

## 5. Runtime state — opaque handle

```haskell
newtype AccessControlHandle = AccessControlHandle (MVar AccessControlState)

newAccessControlHandle
  :: SealPaths
  -> GatewayConfig              -- ^ supplies gcHost/gcPort for origin resolution
  -> AccessControlFileConfig
  -> Maybe Text                 -- ^ service token for the in-process bridges
  -> IO AccessControlHandle
accessControlState     :: AccessControlHandle -> IO AccessState   -- for /api/auth/status
authorize              :: AccessControlHandle -> Request -> IO AuthDecision
```

`newAccessControlHandle` calls `resolveAccessControl` (§3) itself and stores
the resolved origin/rpId, so the same values drive verification,
`/api/auth/status` and the WS allowlist. `Serve` builds it after loading both
config files and before forking the chat channels, so §10's refuse-to-start
matrix runs at the same point.

One `MVar` holds mode, credentials, challenges, sessions and the failure
backoff. The state is tiny; contention is irrelevant and atomicity is the point.
The handle stores `SealPaths`, not a bare path. No `TVar` field is exported.

## 6. Tokens and codes

| Token | Entropy | Lifetime | Storage |
|---|---|---|---|
| setup code | 16 bytes, hex | boot; cleared when mode leaves `unconfigured` | `MVar (Maybe (Digest SHA256))` |
| service token | 32 bytes, b64url | boot; never leaves the process | `MVar (Maybe (Digest SHA256))` |
| session | 32 bytes, b64url | 24 h idle, 7 day absolute cap | `Map (Digest SHA256) Entry` |

Keys are SHA-256 digests; comparisons use `constantTimeEq` on decoded bytes.

Cookie `seal_session=<tok>; Path=/; HttpOnly; SameSite=Strict; Max-Age=86400`
(+ `Secure` when the resolved origin is `https`), re-issued on every
authenticated request so the cookie tracks the server's idle window. Each
entry also carries a fixed `createdAt`; `now - createdAt > 7 days` rejects the
session and clears the cookie, so a continuously used stolen cookie still
dies.
`Cache-Control: no-store` on every auth response. `Authorization: Bearer <tok>`
is accepted too, for non-browser clients.

### Where the setup code is delivered

`runServeMainInner` writes it to **stderr** with `hPutStrLn` — never through
`SealLogger` (whose file scribe the agent can read) and never in a response
body or query string. When stderr is not a TTY (`launchd`, `systemd`, a pipe)
it is *also* written to `~/.seal/state/setup-code` at mode 0600, so a daemon
operator is never locked out; the banner names that path. That file is inside
the agent's trust boundary like the rest of `~/.seal/`, which is exactly the
boundary §1 states.

Banner (loopback, unconfigured):

```
Access control is not configured — the API is closed until setup completes.
  Open  http://localhost:8080/#setup=4f3c…    (code also in ~/.seal/state/setup-code)
  Or    run `seal access-control reset --yes` to clear a lost passkey.
```

The code is minted when the mode is `unconfigured`, when the mode is `open`
(so the `open → passkey` upgrade needs terminal access and cannot be driven
remotely), and when a `passkey` boot detects `rp_mismatch` (so an orphaned
credential is recoverable in-product). It is **never** minted in a healthy
`passkey` boot.

**Consumption:** verified by every `register/*` and `waive` call, and consumed
(atomically, `modifyMVar` returning `Maybe`) **only by a successful**
`register/verify` or `waive`. A cancelled biometric prompt, a reload or a
second tab therefore retries cleanly; a wrong code never burns it.

### Challenges

`login/options` and `register/options` insert a challenge into a map with a
**120-second** TTL. Issuance is limited to 5/s sustained (burst 20) by a single
token bucket, so at most 600 challenges can be live at once; the map cap is
1024 and, at the cap, an insertion is **rejected with 429** rather than
evicting an existing entry. A flood therefore cannot evict the operator's own
in-flight challenge — the properties compose arithmetically. (Residual,
accepted: an attacker on the network can starve issuance for up to two
minutes. Every unauthenticated endpoint has that property; the cost is a
retry, not a lockout or unbounded memory.)

On verify: `modifyMVar` **removes** the challenge before any cryptographic
work (consume-on-attempt), checks the entry's ceremony kind
(`create`/`get`/`add`) and expiry, and rejects on mismatch. A concurrent replay
of a captured assertion therefore finds no challenge.

## 7. Authentication decision

One function, `authorize handle req`, used by the HTTP middleware and the WS
handshake.

The model is **default deny**: the middleware allows only the paths named in
the unauthenticated allowlist below and denies everything else. A future
`/api/*` route is therefore protected the moment it is added, with no
registration step and no route table to drift.

```
any mode  -> OPTIONS (preflight is never 401'd)
any mode  -> GET /api/health
any mode  -> the service token on any path NOT under /api/auth/   (bridges)

Open         -> Allow everything else.

Unconfigured -> Allow: GET /api/auth/status,
                       POST /api/auth/{register,waive}/*  (setup code required)
                Deny: 403 {code:"access_control_required"}

Passkey      -> Allow: (valid session cookie | bearer) on everything,
                       POST /api/auth/{login,register}/*  (register/* only
                       when the boot minted a setup code, i.e. rp_mismatch),
                       GET /api/auth/status
                Deny: 401 {code:"unauthenticated"}
```

`register/*` is reachable in `passkey` mode *only* when a setup code exists,
which happens only on an `rp_mismatch` boot (§6) — that is what makes the
orphaned-credential re-enrollment path work without opening a general
enrollment window.

- `OPTIONS` is always allowed: preflight must never be 401'd.
  `Access-Control-Allow-Headers` gains `Authorization`;
  `X-Seal-Setup-Token` is deliberately **not** added, so a cross-origin page
  cannot send it — the failed preflight is load-bearing.
- **No loopback bypass.** A local browser is a universal deputy for any web
  page.
- The service token is rejected on `/api/auth/*`, and used only by the
  in-process Signal/Telegram bridges.

### Where the middleware sits

`accessControlMiddleware handle app` wraps **only the `("api":_)` branch** of
`gatewayApp`, inside `requestTimingMiddleware` (so 401/403s are logged):

```haskell
gatewayApp logger deps mStaticDir =
  requestTimingMiddleware logger $ \req respond ->
    case pathInfo req of
      ("api" : _) -> accessControlMiddleware (adAccessControl deps) (apiApp deps) req respond
      _           -> serveStatic/Embedded ...
```

Static assets always load — the setup screen's own bundle must be served in
`unconfigured` mode. `ApiDeps` gains `adAccessControl`.

### CORS

`Seal.Gateway.API.corsHeaders` (today `ACAO: *` on every JSON response) is
split: auth handlers answer with `authCorsHeaders`, which sets **no**
`Access-Control-Allow-Origin` at all, so `/api/auth/*` is not cross-origin
readable and `login/options` cannot leak credential ids. Non-auth routes keep
today's behaviour. `Access-Control-Allow-Credentials` is never sent.

### WebSocket

The outer application pre-checks the upgrade: `isWebSocketsReq req` plus
`authorize`; a rejection returns a real `401` **before** the upgrade (a check
inside `streamApp` could only emit `rejectRequest`'s 400). `StreamGuard` gains
the handle.

`sgAllowedOrigins` becomes the **resolved origin plus `gcAllowedOrigins`**.
The existing wildcard behaviour (empty allowlist ⇒ accept any Origin) is kept
**only for `mode = open` on a wildcard bind**, which is the one boot
combination with no resolved origin (§3 rule 3); in the two configured modes
an origin is always resolved, so the allowlist is never empty and the
accept-any branch is unreachable. `streamApp` accepts a connection when the
Origin header is absent (non-browser client) or exactly equals an allowed
origin.

Browsers authenticate with the cookie (they cannot set WS headers); the bridge
passes `?token=` (loopback only, never logged). A rejected handshake surfaces
to the browser as close code 1006, not 4401, so the frontend **does not** rely
on a close code: `streamClient.ts` re-fetches `/api/auth/status` on close and
dispatches `seal-unauthorized` when the session is gone.

`/api/auth/status` reports `origin = null` exactly when no origin resolved
(`open` on a wildcard bind); §11 then skips the origin-mismatch banner, because
there is no single correct URL to name.

### Rate limiting: no lockout, no per-source buckets

Per-source buckets collapse to one bucket behind the reverse proxy that §3
makes the normal non-loopback deployment, which would let any remote client
lock the operator out. So:

- `login/options` and `register/options` are bounded by the issuance bucket in
  §6 (5/s sustained, burst 20) and the reject-at-cap challenge map.
- Failed `login/verify`/`register/verify` attempts arm a **global** exponential
  backoff (250 ms → 2 s cap) that is reset by any success. It delays, never
  denies; there is no lockout state to exploit and none to strand the operator.
- `/api/auth/*` request bodies are capped at 64 KiB before parsing, so the
  bounded CBOR decoder can never be handed a gigabyte.

No limiter is keyed by peer address, so the reverse-proxy deployment cannot
collapse every client into one bucket and cannot be used to lock the operator
out.

## 8. Endpoints

All under `/api/auth/`. Bodies are snake_case (`{error, code}` on failure)
**except** the WebAuthn options and credential JSON, which go verbatim to
`navigator.credentials` and stay camelCase.

| Method + path | Auth | Purpose |
|---|---|---|
| `GET /api/auth/status` | none | `{state, authenticated, origin, rp_id, setup_required, rp_mismatch}` |
| `POST /api/auth/register/options` | setup code | create-options: challenge, rp, 16-byte random user id, `pubKeyCredParams:[ES256]`, `attestation:"none"`, `authenticatorSelection:{userVerification:"required", residentKey:"preferred"}`, `excludeCredentials` = existing |
| `POST /api/auth/register/verify` | setup code | verify, persist credential (+ mode `passkey` when currently open/unconfigured) in one write, mint session, consume code |
| `POST /api/auth/login/options` | none | get-options: challenge, `allowCredentials` |
| `POST /api/auth/login/verify` | none | verify assertion, bump sign counter on disk, mint session |
| `POST /api/auth/waive` | setup code | write `mode = "none"`, consume code |
| `POST /api/auth/logout` | session | drop the token |
| `GET /api/auth/credentials` | session | id, label, created_at, sign_count |
| `POST /api/auth/credentials/options` | session | add a credential (excludes existing) |
| `POST /api/auth/credentials/verify` | session | persist the added credential, mint a session for it |
| `DELETE /api/auth/credentials/:id` | session | remove; refuses the last credential in `passkey` mode |

State graph, complete:

| from | to | trigger | gate |
|---|---|---|---|
| unconfigured | passkey | `register/verify` | setup code |
| unconfigured | open | `waive` | setup code |
| open | passkey | `register/verify` (setup screen or `/access`) | setup code |
| passkey | open | **CLI only** — edit `security.toml`, or `seal access-control reset --yes` | terminal |
| passkey | passkey | `credentials/*` | session |

There is deliberately **no** network path from `passkey` to `open`: a stolen
session must not be able to permanently disable the control. `waive` returns
403 in `passkey` mode unconditionally.

`passkey` with **zero** credentials is refused at boot, with a message naming
`seal access-control reset --yes`.

### Error codes

Failures are `{"error": "<human sentence>", "code": "<machine token>"}`. The
UI switches on `code`, never on the sentence.

| code | HTTP | meaning / UI reaction |
|---|---|---|
| `access_control_required` | 403 | unconfigured; render the setup screen |
| `unauthenticated` | 401 | no/expired session; render login |
| `setup_code_required` | 403 | missing setup code; prompt for it |
| `setup_code_invalid` | 403 | wrong code; keep the value, show the error, do **not** consume |
| `challenge_expired` | 400 | auto-retry the ceremony once |
| `challenge_invalid` | 400 | ceremony kind/instance mismatch; restart the ceremony |
| `origin_mismatch` | 400 | `clientData.origin` ≠ resolved origin; show the URL banner |
| `rp_mismatch` | 400 | credential's rpId ≠ resolved rpId; show the re-enroll panel |
| `unknown_credential` | 400 | no stored credential with that id |
| `signature_invalid` | 400 | ECDSA/DER/authData check failed; retry |
| `sign_count_regression` | 400 | replayed assertion; retry |
| `user_verification_required` | 400 | authenticator did not assert UV |
| `last_credential` | 409 | refusing to delete the only passkey in `passkey` mode |
| `rate_limited` | 429 | `Retry-After`; back off and retry |
| `body_too_large` | 413 | auth body over 64 KiB |

## 9. Verification core

Pure modules, no new dependencies:

- `Seal.Security.WebAuthn.Types` — leaf types shared by config, verifier and
  gateway (`Credential`, `CosePublicKey`, `AccessMode`, `Challenge`), so there
  is no import cycle.
- `Seal.Security.WebAuthn.Cbor` — strict bounded CBOR decoder (major types
  0–5 + 7; definite lengths only; depth ≤ 32; ≤ 1024 items; no trailing bytes;
  every length checked against the remaining input).
- `Seal.Security.WebAuthn.Der` — strict bounded DER
  `SEQUENCE { INTEGER r, INTEGER s }`; WebAuthn assertion signatures are DER
  and crypton's `ECDSA.verify` takes `Signature Integer Integer`.
- `Seal.Security.WebAuthn` — the ceremonies:

  *registration*: `fmt == "none"` only; parse `attestationObject` → `authData`;
  `rpIdHash == SHA-256(rpId)`; `UP` and `UV` set; `AT` set; parse attested
  credential data; `rawId == credentialId`; credential id length 1–1023; COSE
  map is EC2/P-256/ES256 with 32-byte `x`/`y`.

  *assertion*: rebuild `authData`; `rpIdHash`, `UP` **and** `UV` required
  (registration asks for `userVerification:"required"`, so accepting `UV=0`
  would be a silent downgrade); verify ECDSA-P256-SHA256 over
  `authData || SHA-256(clientDataJSON)`; `type`, `crossOrigin != true`,
  `challenge` compared after base64url-decoding both sides, `origin` compared
  parsed (scheme+host+port) — never `isInfixOf`.

  *sign counter*: under the handle's lock, read-check-write and **persist
  before minting the session**. `new == 0 && stored > 0` → reject; both zero →
  accept; otherwise require `new > stored`. Closes the concurrent-replay window.

`crypton` supplies P-256/ECDSA and SHA-256 (`Crypto.Hash`, not
`Seal.Security.Crypto.sha256Hash`, which returns hex); `base64-bytestring`
supplies base64url; `Seal.Security.Crypto.getRandomBytes` supplies challenges
and tokens.

## 10. Boot behaviour

In `runServeMainInner`, immediately after loading the security config (before
the chat channels are forked and before `StreamHealth` is published):

| mode | bind / origin | action |
|---|---|---|
| file unparseable | — | exit 1 with the tomland diagnostics |
| unconfigured | any bind | start; serve **only** the setup screen; setup URL + code to stderr (and the state file when not a TTY). On a plain-HTTP non-loopback bind the UI explains that passkey enrollment needs a secure context and offers the waiver. The setup code is what prevents a remote client from enrolling or waiving first, so the screen is safe to expose on any interface. |
| open | loopback | start; print the setup URL (upgrade path) |
| open | non-loopback | start; banner states access control is explicitly off and names `security.toml` |
| passkey | loopback | start; log the credential count |
| passkey | non-loopback, origin `https://` | start |
| passkey | non-loopback, origin not https | exit 1 (a plaintext session cookie would leak) |
| passkey, zero credentials | — | exit 1, naming `seal access-control reset --yes` |

Migration: an existing `0.0.0.0` deployment keeps booting, but its API is
closed until setup completes — the operator sees the setup screen on first
visit, which is exactly the behaviour this feature exists to produce.
`CHANGELOG.md` / `README.md` carry an "Upgrading" note naming
`mode = "none"` for VPN users. `failClosedOnNonLoopback` (remote-only
execution) keeps its existing meaning; the rules compose as "either refuses".

## 11. Frontend

### The status contract

`GET /api/auth/status` returns exactly:

```json
{"state": "unconfigured|open|passkey",
 "authenticated": true|false,
 "origin": "http://localhost:8080" | null,
 "rp_id": "localhost" | null,
 "setup_required": true|false,
 "rp_mismatch": true|false}
```

`authenticated` is `false` in `unconfigured` and `open`. `setup_required` is
`state == "unconfigured" || (state == "open" && <the user asked to enroll>)`;
the gate uses it only to decide whether to show the code field on the setup
screen. `rp_mismatch` implies `setup_required`.

### Render rules (exhaustive)

| state | authenticated | renders |
|---|---|---|
| `unconfigured` | false | setup screen |
| `open` | false | the app + the "access control is off" banner |
| `passkey` | false | login screen (or setup screen when `rp_mismatch`) |
| `passkey` | true | the app |

`AccessGate` wraps `<App/>` in `main.tsx`:

1. reads `#setup=<token>` from the fragment, strips it, keeps it in
   `sessionStorage` until the state leaves `unconfigured` (a reload before
   enrolling must not force retyping); paste normalised (whitespace,
   `#setup=` prefix, case);
2. fetches `/api/auth/status`;
3. renders setup / login / app;
4. listens for `seal-unauthorized` — dispatched by a single `fetch` wrapper
   installed at startup (`lib/unauthorized.ts`), which covers every API call
   including the REST fallback the lists hook uses when the WebSocket drops
   (a rejected WS handshake surfaces as close code 1006, so the close event
   itself carries no 401) — and **re-fetches `/api/auth/status`, then re-applies
   the render table above**. It never hard-codes "login": after a
   `reset --yes` + restart the state is `unconfigured`, and only a re-fetch
   gets the tab to the setup screen (no further 401 will fire).

**`state = "open"` renders the app**, plus a persistent banner ("Access
control is off — anyone who can reach this address has full control. [Turn on
access control]"), link to `/access`. The gate never shows the setup screen in
`open` mode; enrollment from `open` goes through `/access`, which asks for the
setup code and flips the mode.

**`state = "passkey"` renders the login screen**, always with the recovery
line: "Lost your only passkey? Run `seal access-control reset --yes` in the
terminal where Seal is running."

Explicit states and copy:

- **insecure context** (`!window.isSecureContext`) — passkey actions disabled:
  "Passkeys need HTTPS or http://localhost. Run Seal behind a TLS reverse
  proxy." On the setup screen (state `unconfigured`/`open`) the sentence ends
  "…or waive access control." — waiving is offered **only** there; on the
  login screen (state `passkey`, where `waive` is 403 by §8) it instead ends
  "…or run `seal access-control reset --yes` to clear the existing passkeys."
- **no WebAuthn** (`window.PublicKeyCredential === undefined`) — same
  treatment, different sentence. Also covers `passkey` over plain HTTP, where
  the login screen would otherwise offer an impossible action.
- **origin mismatch** — "You opened `http://10.0.0.5:8080`; this gateway
  verifies `http://localhost:8080`. Open that URL instead." Shown whenever
  `location.origin` differs from the reported `origin`.
- **rp_mismatch** — "Existing passkeys were registered for a different address
  (`<stored>`). Enter the setup code below to register a new one." The setup
  code is available because the boot minted one (§6).
- **setup code needed but absent** — "The code is in the terminal where you ran
  `seal serve` (also written to `~/.seal/state/setup-code`). Restart `seal
  serve` for a fresh one."
- **waiver** — checkbox + button, not one click: "Anyone who can reach this
  address gets full control of every session: messages the agent will execute,
  every transcript, every slash command. This is recorded in
  `~/.seal/security.toml`. Undo with `seal access-control reset --yes`."
- **`NotAllowedError`** — first occurrence: non-blocking hint "No passkey on
  this device? Add one from a device that is already signed in (Settings →
  Access), or run `seal access-control reset --yes`." Second occurrence: the
  full recovery panel. Never silently do nothing.
- `challenge_expired` → retry once automatically. Other codes → the server's
  message.

`frontend/src/components/AccessView.tsx` (route `/access`, reachable from a
lock icon in `TopBar`) lists credentials (label, sign count, created, rpId),
offers "Add a passkey" (setup code required when the mode is `open`) and
"Remove" (refused for the last credential in `passkey` mode).

## 12. CLI

`seal access-control status` — mode, resolved origin/rpId, credential labels
(no secrets).
`seal access-control reset --yes` — deletes the `[access_control]` table and
prints "the running `seal serve` is unchanged until you restart it; then bind
127.0.0.1 to re-enroll."

Both are human-driven CLI admin commands — the path `AGENTS.md` permits to
touch `~/.seal/`; neither is an opcode.

## 13. Bridges (Signal / Telegram)

They are loopback *network* clients, not in-process calls.

- **HTTP:** `Serve` creates a **dedicated** `Manager` whose
  `managerModifyRequest` adds `Authorization: Bearer <service token>`. That
  manager is used *only* for gateway calls. `withTelegramChatChannel` /
  `forkNewTelegramChatChannel` (and the Signal equivalents) gain a **separate**
  `gwManager` parameter: gateway calls (`HttpClient`, `WsClient`) use
  `gwManager`, while every `api.telegram.org` / Signal transport call keeps the
  existing plain manager. Today a single `Manager` argument serves both roles
  (`Telegram.hs:141-148,340,359,500`), so without the split the service token
  would be sent to Telegram — the split is the fix, not an optimisation.
- **WS:** `Seal.Channels.Chat.WsClient.connectWs` gains a `Maybe Text` token
  argument and appends `?token=` to the request path (`websockets`' `runClient`
  has no header API). `Seal.Channels.Chat.Types.GatewayConfig` gains
  `gcToken :: Maybe Text` (default `Nothing`), threaded by `Serve`.

## 14. Round-2 blockers → resolution

| # | Reviewer | Blocker | Resolution |
|---|---|---|---|
| 1 | Security | challenge lifecycle only in the table, map unbounded | §6 "Challenges" (parameters superseded by row 21): bounded map, consume-on-attempt via `modifyMVar`, kind-bound, TTL |
| 2 | Security, CTO | `passkey → open` contradictory | §8: network `waive` always 403 in `passkey`; the only route is the CLI. DoD split accordingly |
| 3 | Security | per-source rate buckets collapse behind the proxy | §7: no buckets; bounded challenge map + global capped backoff that delays and never denies |
| 4 | Security | `ACAO: *` on auth responses; preflight rule unstated | §7 "CORS": auth handlers set no `ACAO`; `X-Seal-Setup-Token` deliberately absent from `Allow-Headers` |
| 5 | Security, Architect | `sgAllowedOrigins` not wired to the resolved origin; wildcard accepts any | §7 "WebSocket": allowlist = resolved origin + `gcAllowedOrigins`; wildcard accept-any removed |
| 6 | Architect | `passkey` branch has no unauthenticated allowlist | §7: `OPTIONS`, health, status, `login/*` always allowed |
| 7 | Architect | middleware would 403 the static bundle | §7 "Where the middleware sits": wraps only the `("api":_)` branch |
| 8 | Architect | service-token manager would leak to providers/Telegram | §13: a dedicated `Manager` for the bridges only |
| 9 | Architect | WS 401 surfaces as 1006, not 4401 | §7: frontend re-checks `/api/auth/status` on WS close |
| 10 | CTO | DoD contradicts the state graph on `waive` | §8 + §15: split into "passkey → 403" and "unconfigured/open → 200" |
| 11 | CTO | no DoD for rate limiting or the CLI | §15 items 9 and 12 |
| 12 | CTO | frontend tests not in `make check` | §15: `make check` gains `frontend-test` (`npm test`) |
| 13 | CTO | unreachable re-decode branch | §15 item 2 tests it with a deliberately corrupt on-disk fixture |
| 14 | PM | `rp_mismatch` strands the operator | §3/§6/§11: boot mints a setup code on `rp_mismatch`; the setup screen re-enrolls |
| 15 | PM | reverse-proxy first enrollment unreachable | §10: `unconfigured` + non-loopback is allowed when the origin is `https://` |
| 16 | PM, Designer | setup code only on stderr → daemon users stranded | §6: also written to `~/.seal/state/setup-code` (0600) when stderr is not a TTY |
| 17 | PM | bridges dead during `unconfigured` | §7: the service token is allowed on non-auth paths in `unconfigured` too |
| 18 | Designer | `open → passkey` unreachable / misleading | §10 prints the setup URL in `open`; §11 renders the app plus a persistent banner; `/access` flips the mode |
| 19 | Designer | blanket silent `NotAllowedError` retry | §11: first failure shows a hint, second shows the recovery panel |
| 20 | Designer | lost/mistyped setup code is a dead end | §11: state file path + "restart for a fresh code" copy on the setup screen |

### Round-3 blockers

| # | Reviewer | Blocker | Resolution |
|---|---|---|---|
| 21 | Security | a 256-entry evicting map lets a flood push out the operator's challenge | §6: 120 s TTL + 5/s issuance bucket + **reject at cap** instead of evicting (the arithmetic composes); residual starvation stated and accepted |
| 22 | Security | `OPTIONS` missing from the `unconfigured` allowlist | §7: `OPTIONS` is the first line of the decision, for every mode |
| 23 | Security | "24 h absolute" contradicted the re-issued 24 h cookie | §6: 24 h idle + a fixed 7 day absolute cap per entry |
| 24 | Architect | the token-carrying `Manager` would also send the token to Telegram | §13: `withTelegramChatChannel`/Signal gain a distinct `gwManager`; the transport keeps the plain manager |
| 25 | Architect | the handle cannot resolve the origin from `SealPaths` | §5: `newAccessControlHandle` takes `GatewayConfig` and resolves internally |
| 26 | Architect | `open` + wildcard bind has no origin, so the new WS allowlist would reject the LAN origin | §7: wildcard accept-any is retained for `mode = open` only; `origin` is `null` there and the UI skips the mismatch banner |
| 27 | CTO | fixtures would be self-produced (circular) | §15.4: committed corpus generated by Node WebCrypto, so crypton is checked against an independent implementation |
| 28 | CTO | "enumerate every route" is unverifiable in a hand-written router | §7: **default deny** — an unknown `/api/*` path is denied by construction; §15.7 tests the allowlist matcher and a synthetic unknown route |
| 29 | CTO | `crypton` absent from the test stanza | §15.10: add `crypton` + `memory` to `build-depends` of the test suite |
| 30 | Designer | `passkey` allowlist omitted `register/*`, so rp_mismatch re-enrollment would 401 | §7: `register/*` allowed in `passkey` only when a setup code exists (rp_mismatch boot) |
| 31 | Designer | `state`/`authenticated` had no defined render semantics | §11: exhaustive render table + the exact status payload |
| 32 | Designer | the `code` vocabulary the UI branches on was undefined | §8: a code table with HTTP status and UI reaction |

### Round-4 blockers

| # | Reviewer | Blocker | Resolution |
|---|---|---|---|
| 33 | CTO | the re-encode guard has no reachable trigger (a corrupt file fails at load) | §15.2: split into semantic round-trip, a QuickCheck `decode∘encode` identity, and a separate parse-failure test |
| 34 | CTO | the refuse-to-start matrix named no seam | §15.12: pure `bootDecision` tested over the whole table; `Serve` only matches on it |
| 35 | Designer | `seal-unauthorized` hard-coded "login" | §11 step 4: re-fetch status and re-apply the render table |
| 36 | Designer | the insecure-context copy offered `waive` where it is 403 | §11: waiver offered only on the setup screen; the login screen names `reset --yes` |

## 15. Definition of done

1. `security.toml` round-trips `[access_control]`; an idiomatic
   `[access_control.credentials.<id>]`-only file decodes non-empty; absent ⇒
   `Nothing`.
2. `updateAccessControlSection`:
   (a) preserves every other section (semantic round-trip);
   (b) satisfies the QuickCheck property `decode (encode c) == Right c` for
       every `AccessControlFileConfig` the callback can build — this is the
       reachable trigger for the re-encode guard;
   (c) returns `Left` for an on-disk file that fails to *parse* (a reachable
       fixture), exercised separately from (b).
3. CBOR and DER decoders reject indefinite lengths, trailing bytes,
   over-deep/over-long inputs and truncation.
4. **Fixtures are third-party, not self-produced.** A committed corpus under
   `test/fixtures/webauthn/` is generated once by
   `scripts/gen-webauthn-fixture.mjs` using Node's WebCrypto (P-256 ECDSA +
   DER, an implementation independent of crypton) and hand-assembled CBOR, and
   is checked in. Tests read the committed bytes, so the decoder and verifier
   are validated against something other than themselves. The generator script
   is kept for provenance but is not run by the suite.
5. Registration verification accepts the corpus fixture; rejects wrong rpId,
   wrong origin, wrong challenge, `crossOrigin: true`, missing UP, missing UV,
   `rawId`≠credentialId, non-`none` fmt, malformed COSE key.
6. Assertion verification accepts the corpus signature; rejects a tampered
   signature, tampered authData, a replayed/non-increasing sign counter (incl.
   a concurrency test), wrong clientData type/origin/challenge, and UV=0.
7. **Default-deny**: the middleware denies an unknown `/api/*` path in both
   configured modes (tested with a synthetic route that does not exist), and
   the unauthenticated allowlist matcher is unit-tested entry by entry.
   `OPTIONS` → 200 in every mode. `/api/health` → 200 in every mode. The static
   bundle → 200 in every mode, including `index.html` and one hashed asset.
   `GET /api/auth/status` returns exactly the §11 contract shape in each of the
   three states.
8. `waive`: `unconfigured`/`open` + correct code → 200 and `mode = "none"` on
   disk, code unusable afterwards; wrong/absent code → 403; **`passkey` +
   valid session + correct code → 403**.
9. Auth CORS: no `Access-Control-Allow-Origin` on any `/api/auth/*` response;
   `Access-Control-Allow-Headers` contains `Authorization` and not
   `X-Seal-Setup-Token`.
10. Rate limiting: a burst of failed `login/verify` calls delays but never
   denies; a success resets the backoff; challenge issuance over 5/s returns
   429 rather than growing the map; a 1 MiB auth body is rejected with 413. The
   `test-suite tests` stanza gains `crypton` and `memory` in `build-depends`
   (crypton is currently library-only), so the signature test compiles.
11. WS: 401 without a session in `passkey` mode and with a foreign Origin;
    accepted with a valid session cookie, with an absent Origin, and with the
    service token on a non-auth path; the service token is refused on
    `/api/auth/*`.
12. The §10 matrix is a **pure function**
    `bootDecision :: AccessMode -> Bool{-origin-https-} -> Int{-credentials-}
    -> BootDecision` (`Refuse Text | Start`), unit-tested over every row of the
    table plus the unparseable-file case, which lives in the loader and is
    tested there. `runServeMainInner` only pattern-matches the result, so the
    table cannot drift from the tests.
13. CLI: `access-control status` reports mode/origin/labels; `reset --yes`
    removes the table and leaves the rest of `security.toml` intact.
14. Frontend vitest: setup→enroll, setup→waive, login, insecure-context
    fallback, origin-mismatch, `rp_mismatch` re-enroll, 401 → login.
15. `ApiTestHarness`/e2e default to `mode = "none"`; `make check` (now
    build + test + lint + `frontend-test`) green.
16. `README.md`, `CHANGELOG.md` (with the upgrade note) and a commented
    `security.toml` example documented.

## 16. Risks

| Risk | Mitigation |
|---|---|
| Remote attacker enrolls or waives first | the setup code (stderr / 0600 state file, single-use) is required by every enrollment and waiver path; the setup screen exposes nothing else |
| CSRF / DNS rebinding drives waive | boot-resolved exact Origin check; setup code header is not CORS-allowed; no `ACAO` on auth routes |
| Credential persisted but mode not flipped | one atomic write carrying both |
| `security.toml` corrupted by the writer | narrow callback type, lock, 0600-at-creation temp file, atomic rename, re-decode verification |
| Lost sole passkey | `seal access-control reset --yes`; the login screen names it |
| rpId change orphans credentials | `rp_mismatch` mints a setup code; the setup screen re-enrolls |
| Bridges break | dedicated token-carrying manager + `?token=` on the WS |
| Agent can read the setup code | accepted and documented: the agent is inside the trust boundary already; the code is written to the state file only when stderr is not a TTY |
| Operator silently runs open | setup screen blocks the API; banner + in-app banner state the mode |
