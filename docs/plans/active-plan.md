# Active Plan
<!-- approved: 2026-11-09 -->
<!-- gate-iterations: 3 -->
<!-- user-approved: true -->
<!-- status: in-progress -->

Move the whole `[gateway]` table out of `~/.seal/config/config.toml` and into
`~/.seal/security.toml`, so the bind address, origin allowlist and TLS paths
are not expressible by any agent-reachable or gateway-reachable config writer.

Canonical plan (full text, work units, DoD):
`docs/superpowers/plans/2026-11-09-gateway-config-to-security-toml-plan.md`
(revision 4; operator decision: an un-migrated `config.toml` write is refused,
not silently stripped).

Execution: orchestrated (2 work units).

| WU | Title | Status |
|---|---|---|
| WU1 | the section moves (atomic) | in progress |
| WU2 | enforcement and prose | pending |
