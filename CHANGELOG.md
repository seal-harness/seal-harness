# Revision history for seal-harness

## 0.1.0.0 — unreleased

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

* Project scaffolding. Subcommand CLI built on `configuration-tools`, a
  `ReaderT Env (KatipContextT IO)` application monad, IORef-based mutable
  state, and katip structured logging. The `greet` / `tick` commands are
  placeholder scaffolding demonstrating the patterns; they will be replaced
  by the SealOp ISA implementation (see the implementation plan in
  `docs/`).
