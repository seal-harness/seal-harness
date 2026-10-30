# Revision history for seal-harness

## 0.1.0.0 — unreleased

* **Web access control (passkeys).** `seal serve` now gates its HTTP API and
  WebSocket stream behind WebAuthn passkeys, configured in
  `~/.seal/security.toml` under `[access_control]`. Three states: absent →
  *unconfigured* (only the setup screen is served), `mode = "none"` → *open*
  (an explicit waiver), `mode = "passkey"` → every request needs a
  passkey-backed session. Enrollment and waiver require a one-time setup code
  printed by `seal serve`, so a remote client cannot configure or open the
  gateway first. New commands: `seal access-control status` and
  `seal access-control reset --yes`.

  **Upgrading:** an existing gateway that binds a non-loopback address keeps
  starting, but its API is closed until setup completes — the setup screen
  appears on the first visit. If that host is only reachable over a VPN, add
  `[access_control] mode = "none"` to `~/.seal/security.toml` to restore the
  previous open behaviour. An unparseable `security.toml` now makes
  `seal serve` exit instead of silently falling back to defaults. The
  `[access_control]` table may be written by the gateway (enrollment, waiver,
  credential management) — no other section of `security.toml` can be.


* Project scaffolding. Subcommand CLI built on `configuration-tools`, a
  `ReaderT Env (KatipContextT IO)` application monad, IORef-based mutable
  state, and katip structured logging. The `greet` / `tick` commands are
  placeholder scaffolding demonstrating the patterns; they will be replaced
  by the SealOp ISA implementation (see the implementation plan in
  `docs/`).
