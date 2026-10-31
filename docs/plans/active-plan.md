# Active Plan
<!-- approved: 2026-10-30T18:15:00Z -->
<!-- gate-iterations: 2 -->
<!-- user-approved: true -->
<!-- status: in-progress -->

See: docs/plans/2026-10-30-vault-access-plan.md (full plan)
Design: docs/plans/2026-10-29-vault-access-design.md (approved by 5-agent design review gate, 3 iterations)
Issue: #287

## Work Units (execution order)
1. WU-1: Create VaultAccess module + type + operations (TDD)
2. WU-2: SessionMeta smAllowedSecrets :: Set Text + compile-fix
3. WU-3: secretManageOp with VaultAccess
4. WU-4: CloneDeps.cdVault :: VaultAccess
5. WU-5: WebSearchConfig.wscVault :: Maybe VaultAccess
6. WU-6: TurnDeps per-turn VaultAccess + all callers
7. WU-7: Gateway API + frontend
8. WU-8: Final integration + PR update

WU-1 and WU-2 can be done in parallel (no interdependencies).