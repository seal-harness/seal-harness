# Active Plan
<!-- approved: 2026-11-07T00:00:00Z -->
<!-- gate-iterations: 6 -->
<!-- user-approved: pending -->
<!-- status: awaiting-approval -->
<!-- branch: gateway/passkey-access-control -->

## Gateway default host `localhost` + first-run config templates

Full plan: `docs/plans/2026-11-07-config-templates-and-localhost-default-plan.md` (rev 6).

Two changes on top of the passkey access-control branch:

1. **Default gateway host becomes `localhost`** (was `127.0.0.1`), and
   `[gateway] host` is wired through to Warp (`setHost`) so it is authoritative
   for the actual bind — today it only feeds the printed URL, the derived
   WebSocket/WebAuthn origins and the "exposed bind" warning, while Warp binds
   every interface. New boot-time validation (`gatewayHostError` /
   `gatewayHostResolutionError`) keeps a typo from aborting inside Warp after
   the banner.
2. **First run writes `~/.seal/config/config.toml` and `~/.seal/security.toml`**
   as templates populated with the default values, so the option surface is
   discoverable. Sources are embedded (`config/templates/*.toml`) and written by
   a new `Seal.Config.Templates.ensureConfigTemplates` from `serve`, `tui` and
   `runAccessControl`, never overwriting an existing file and never changing
   resolved behaviour.

The plan-review gate ran 6 iterations (plan-feasibility + plan-completeness +
plan-scope; all three now PASS). Notable traps it settled: `migrateSecurityConfig`
must not see a freshly created `security.toml` while `config.toml` still holds
legacy `vault_*` fields (it would silently drop them), and the `config.toml`
template must avoid every `legacyMarkers` substring in its own prose (a match
would strip its comments on every boot).

The previous pointer (`frontend/transcript-scroll-purity`) belongs to another
branch; its plan file is untouched.
