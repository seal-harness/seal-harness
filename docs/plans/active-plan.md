# Active Plan
<!-- approved: 2026-10-29T18:01:00Z -->
<!-- gate-iterations: 2 -->
<!-- user-approved: true -->
<!-- status: in-progress -->

See: docs/plans/2026-10-29-session-secret-restrictions-plan.md (full plan)
Design: docs/plans/2026-10-29-session-secret-restrictions-design.md (approved by 5-agent design review gate)
Issue: #287

## Work Units (execution order)
1. WU-1: SessionMeta field + serialization (TDD)
2. WU-2: Compile-fix — update all SessionMeta construction sites
3. WU-3: Pure helpers + secret-name validator + opcode filtering (TDD)
4. WU-4: Thread allow-list through buildSessionRegistry + callers
5. WU-5: Child session inheritance (delegation worker)
6. WU-6: Frontend — secret selection UI
7. WU-7: Final integration + draft PR

Note: WU-1 and WU-2 are one atomic compile-fix cycle. Execute together.