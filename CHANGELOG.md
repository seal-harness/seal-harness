# Revision history for seal-harness

## 0.1.0.0 — unreleased

* **The web gateway's settings moved to `security.toml`.** `[gateway]` — the
  bind host and port, the WebSocket Origin allowlist, `static_dir`, and the TLS
  pair — now lives in `~/.seal/security.toml` beside the vault and
  `untrusted_execution`, because a bind address is not a setting an agent
  should be able to change. It is no longer in `config.toml`, so a future
  `CONFIG_UPDATE` opcode typed on the runtime config, and the gateway's own
  `updateRuntimeConfig` writer, cannot express a change to it.

  `seal serve` or `seal tui` migrates an existing `config.toml` on the next
  boot: the table is moved into `security.toml` when that file has none of its
  own (the usual upgrade case — `security.toml` exists but has never held a
  gateway table), and `security.toml` wins if both carry one. Until that boot,
  `seal provider`/`seal model`/`seal agent`/`seal channel` refuse to write
  `config.toml` rather than silently drop the table, and `seal access-control`
  keeps reading it read-only so its origin checks stay correct. Rolling the
  build back does not move the table back: copy `[gateway]` from
  `security.toml` into `config.toml` by hand.

* **A fourth provider: any OpenAI-compatible endpoint.** `openai` (label
  "OpenAI-compatible") reuses the OpenRouter client — both speak
  `/v1/chat/completions` — and differs in exactly one way: it has **no**
  built-in base URL. The endpoint is required input (`[providers.openai]
  base_url`, or the setup wizard's "API endpoint" field), and resolution fails
  with an actionable message rather than defaulting to `api.openai.com`, so a
  key meant for a self-hosted server is never sent to a third party. Its vault
  credential is `OPENAI_API_KEY`; `/api/providers` now lists four providers.

  Because "Test connection" is only useful if it actually reaches the endpoint,
  the OpenAI-compatible client's `listModels` now asks the endpoint's
  `/models` (it used to answer with one static id). That call backs the
  wizard's Test button and `/model list`, so a wrong URL or a rejected key
  surfaces as a real error instead of a cheerful "ok". With no credential the
  call is skipped and the configured default is returned, as before.

* **A first run can now be completed in the browser.** `seal serve` serves a
  guided wizard before the app: create the vault (local `age-keygen` key,
  YubiKey, or your own age identity), then add an LLM provider. It reaches
  parity with the CLI's `/vault setup` for the three backends, writes only the
  three vault-key fields, and never returns key material to the browser. The
  gate is blocking — there is no skip — and the two routes it uses
  (`GET /api/setup`, `POST /api/setup/vault`, plus `POST /api/setup/vault/reopen`
  and `POST /api/providers/:name/test`) sit behind the passkey middleware and
  the mutation origin guard. The CLI remains the way to rotate a key.

* **A `startup`-mode vault needs one `reopen` after a first-run setup.** A
  vault created from the wizard is opened in `on_demand` mode for the rest of
  the process. If `security.toml` asks for `startup`, the wizard's vault step
  reports "locked" with a Reopen action (which unlocks it) until that is done —
  `seal serve` does not unlock at boot. Nothing is lost: the vault is on disk
  and `seal tui`'s `/vault unlock` does the same thing.

* **`age` is now invoked with single-token option forms.** The vault encryptor
  passes `--decrypt --identity=<path>` and `--encrypt --recipient=<value>`
  rather than separating the value, so a stored value that begins with `-` can
  never be read as a flag (AGENTS.md invariant 2).

* **`mkAgeEncryptor` rejects a malformed recipient or identity path.** Both
  credentials are validated at the single choke point every caller goes
  through (CLI, gateway, a hand-edited `security.toml`), so a vault configured
  with a broken value now fails loudly at open time with "invalid recipient" /
  "invalid identity path" instead of failing later inside `age`. This is a
  behaviour change for the CLI: a config that used to limp along now refuses to
  open the vault.


* **Mutating API requests must come from the gateway's own origin.** The REST
  API was reachable from any page in the operator's browser: the router
  answered `OPTIONS` for every path with `Access-Control-Allow-Origin: *`, so a
  cross-origin JSON POST landed, and any cross-origin page could *read*
  `GET /api/sessions` and every transcript. A passkey session does not fix this
  on its own — the cookie travels on cross-origin requests, so a hostile page
  can drive cookie-authenticated mutations (CSRF).

  Every `POST`/`PUT`/`DELETE` (and `GET /api/setup`) now requires `Origin` to
  match the origin the boot plan resolved for the gateway — the same value
  WebAuthn verifies `clientDataJSON.origin` against. When that origin is
  loopback, any loopback alias is accepted, on any port: the SPA is reached at
  `http://127.0.0.1:<port>` in the e2e harness and `http://localhost:5173`
  behind the vite dev proxy, while the boot plan canonicalises a loopback bind
  to `http://localhost:<port>`. Clients that send no `Origin` at all (curl, the
  chat channels, the test suite) are unaffected unless they also declare
  `Sec-Fetch-Site: cross-site`.

  With `access_control.mode = "none"` on a wildcard bind there is no resolvable
  origin and no gate: mutating requests are allowed from anywhere, as before.

* **The API no longer sends permissive CORS headers.** `Access-Control-Allow-Origin: *`
  is gone from every response, and `OPTIONS` answers `204` with no grant (the
  passkey endpoints already sent none). Nothing in the repository depended on
  it — the SPA and the Swagger page are same-origin and the chat channels are
  HTTP clients — but any out-of-tree browser client that relied on reading the
  API cross-origin will stop working. Note that the WebSocket allowlist is
  still exact (`http://localhost:<port>`), so a browser opened at
  `http://127.0.0.1:<port>` can use the REST API but not the live stream; open
  the gateway at the URL its banner prints.

* **`[gateway] host` now actually binds, and defaults to `localhost`.**
  The `host` value never reached the listener: `runGateway` set only the port
  on Warp's `Settings`, and Warp's default host preference is the IPv4
  wildcard, so the gateway bound every interface while the banner, the derived
  WebSocket/WebAuthn origins and the "reachable from another machine" warning
  all described a loopback listener. `warpSettingsFor` passes the host through,
  so the warning now corresponds to reality. The default changes from
  `127.0.0.1` to `localhost` because that is the origin a passkey ceremony is
  verified against (and the one name browsers treat as a secure context) — with
  the literal address the printed boot URL named an origin a browser would never
  send (`canonicalOriginFor` canonicalises loopback to `localhost`), so the
  address the operator was told to open was not the origin being verified, and
  neither matched the interface set actually bound. A `[gateway] host` that cannot bind (blank,
  whitespace, a URL or path, a bracketed IPv6 literal) or does not resolve is
  now refused at boot, with a message naming the key, instead of failing inside
  Warp after the banner.

  **Upgrading:**
  - A gateway that was reachable from another machine only because of the
    implicit wildcard bind is now loopback-only. Set `host = "0.0.0.0"` (or a
    specific address) to expose it again.
  - `host = "*"` — a spelling the old code accepted because `host` was cosmetic
    — is refused as unresolvable. Use `"0.0.0.0"` or `"::"`.
  - `http://127.0.0.1:<port>` no longer matches the WebSocket Origin allowlist
    (only `http://localhost:<port>` does). In passkey mode it would not have
    authenticated anyway: the session cookie is host-scoped. `localhost` may
    resolve to `::1` first, so a client hardcoded to `127.0.0.1` may need the
    name.

* **The first run writes documented `config.toml` and `security.toml`
  templates.** A fresh install had neither file, and both loaders treat "absent"
  as "use the built-in defaults" — Seal worked, but every option was invisible
  until someone read the source. Both files now spell out the default for every
  option, written out where that resolves identically to leaving the key out and
  commented out otherwise (an unset value, a name only the operator knows, a
  machine-absolute path, or a value derived from another key). `security.toml`
  stays almost entirely comments on purpose: absence of `[access_control]` is
  what keeps the gateway fail-closed, and `[untrusted_execution]` does not mean
  the same thing in a `-f remote-only-untrusted` build. The templates are
  embedded in the binary, so they are always the version it shipped with.

  **Upgrading:**
  - An existing `config.toml` or `security.toml` is never overwritten, so an
    install that already has one gets no template. To see it anyway, copy the
    templates out of the repository (`config/templates/`) rather than deleting
    your file: `security.toml` holds your vault and untrusted-execution
    settings, and no template can restore those for you.
  - The scaffolder defers `security.toml` while `config.toml` still holds
    pre-split vault fields, so the one-time migration still moves them.
  - A re-encode (any `seal access-control …` write, `/vault setup`, a `/provider`
    change) does not preserve comments, then or now.

* **Web access control (passkeys).** `seal serve` gates its HTTP API and
  WebSocket stream behind WebAuthn passkeys, configured in
  `~/.seal/security.toml` under `[access_control]`. Three states: absent →
  *unconfigured* (only the setup screen is served), `mode = "none"` → *open*
  (an explicit waiver), `mode = "passkey"` → every request needs a
  passkey-backed session. Credentials moved out of `security.toml` into a
  gateway-owned `~/.seal/credentials.toml` (0600), so a login no longer rewrites
  the boot-critical document. Enrollment is authorised by a short-lived,
  one-shot **grant** — a token from `seal access-control enroll`, a
  loopback-confined window during bootstrap, or a 120 s assertion from an
  already-enrolled passkey — never by a session cookie. `rp_mismatch` (every
  credential registered for another address) is derived from the store instead
  of stored, so it clears. An audit trail lands in
  `~/.seal/state/access-control.log`.

  New commands: `seal access-control status`, `enroll [--ttl N[s|m|h]]
  [--no-token] [--force] [--cancel]`, `disable --yes`, `reset --yes`,
  `migrate-credentials`.

  **Adding a passkey on another device.** `/access` → "Add a passkey" now
  mints a **link** (a file-backed `ui_token` grant, five minutes, single use)
  instead of running the ceremony in the browser that clicked it, because the
  passkey an operator adds is usually for a different device. Open the link
  there; "Add the passkey on this computer" performs the same enrollment
  locally. A captured `#enroll=` token is no longer discarded when the gateway
  reports a usable credential — that count is gateway-side, so a phone holding
  a valid link was losing it on arrival.

  **Upgrading:**
  - A pre-split install that kept credentials in
    `[access_control.credentials.*]` makes `seal serve` refuse to start and
    names `seal access-control migrate-credentials`. Nothing is migrated
    silently.
  - `POST /api/auth/waive` is **removed**. Disabling access control is
    terminal-only: `seal access-control disable --yes` (stop `seal serve`
    first). The setup screen now prints the instruction instead of offering a
    button.
  - Enrollment uses `X-Seal-Enroll-Token`; `X-Seal-Setup-Token` is retired.
    Tokens expire — ten minutes for a CLI token, five for a window, 120 s for an
    assertion — and a successful enrollment consumes them. A restart no longer
    mints a new token while one is still valid; use `enroll --force` to replace
    it.
  - `seal access-control reset --yes` now also deletes `credentials.toml` and
    the grant artefacts, and refuses while `seal serve` is running.
  - `[access_control]` with no `mode` line no longer means "open": absence
    means passkey when credentials exist, and *unconfigured* otherwise. Only a
    written `mode = "none"` turns access control off.
  - Enrolling works in `mode = "none"`, so an open gateway can be locked down
    from the web UI; it can never be turned back off from there.

* **The gateway can serve HTTPS itself.** `[gateway] tls_cert` and `tls_key`
  (PEM paths) switch the listener from plain HTTP to TLS, so a passkey ceremony
  no longer needs a reverse proxy in front. `[gateway] tls = true` alone is the
  whole configuration: the paths default to `keys/tls/cert.pem` and
  `keys/tls/key.pem`, and a missing pair is generated with `openssl` on the next
  start. The startup banner reports
  `https://` / `wss://`, and the WebSocket `Origin` allowlist derives its scheme
  from the listener rather than assuming `http://`. Turning TLS on also makes
  `[access_control] origin` mandatory and `https://` — the derived loopback
  origin would otherwise never match — and a half-configured certificate/key
  pair is refused at boot instead of failing inside the handshake.

  A generated certificate is valid for **397 days** — Chromium and WebKit reject
  anything longer with `ERR_CERT_VALIDITY_TOO_LONG` — and its subject
  alternative name covers `localhost`, `127.0.0.1`, `::1`, the machine hostname,
  the `[access_control] origin` host, every local interface address (LAN, VPN and
  overlay) and every entry in `tls_hosts`, which is listed first and becomes the
  CN. **Upgrade note:** a 10-year certificate generated by an earlier build is
  replaced the first time this version starts, because no browser will accept
  it; the previous pair is kept next to it as `*.bak`, and the new certificate
  must be trusted again on every device. A pair named by `tls_cert`/`tls_key` is
  never validated or replaced — only pairs Seal generated at the default paths
  are maintained. A warning is logged when a generated pair comes within 30 days
  of expiry.

  A generated certificate is self-signed, and that is not enough for passkeys:
  since Chrome 110 a browser disables WebAuthn on any certificate it does not
  trust, so the file has to be installed on the client device and marked
  trusted. TLS also does not make a bare IP usable — a WebAuthn RP ID must be a
  domain string — so `tls_hosts` has to name a hostname the device will use.
  `tailscale cert` remains the frictionless option when a tailnet is available.

* **The gateway no longer refuses a non-loopback bind in remote mode.**
  `untrusted_execution.mode = "remote"` used to make `seal serve` exit rather
  than bind anything but loopback. That was a compensating control for an
  unauthenticated config write that could flip `remote` to `local`
  (design 2026-07-22, V6); the write path's type is now `RuntimeConfig`, which
  cannot name `[untrusted_execution]` at all, so the attack is unrepresentable
  rather than merely blocked. The refusal had also become counter-productive:
  remote mode is the configuration where the agent cannot reach the harness
  binary or its environment, so refusing to bind it on a network address
  pushed operators toward `mode = "local"`, which is strictly weaker. A
  non-loopback bind now logs a warning and serves, in every configuration.

* Project scaffolding. Subcommand CLI built on `configuration-tools`, a
  `ReaderT Env (KatipContextT IO)` application monad, IORef-based mutable
  state, and katip structured logging. The `greet` / `tick` commands are
  placeholder scaffolding demonstrating the patterns; they will be replaced
  by the SealOp ISA implementation (see the implementation plan in
  `docs/`).
