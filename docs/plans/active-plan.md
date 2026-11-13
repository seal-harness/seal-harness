# Active Plan
<!-- approved: 2026-10-23 -->
<!-- gate-iterations: 6 -->
<!-- user-approved: true -->
<!-- status: in-progress -->

CRON_MANAGE Web UI — a `Cron` tab in the top bar with a two-pane CRUD view
over the existing `CronStore`. The gateway-wide Origin check (WU-4 in the
original plan) is already implemented by the passkey/mutation-guard work and
is dropped from this plan. Run history is also dropped (operator decision);
the route count goes from 70 to 75 (5 cron routes).

Canonical plan (full text, work units, DoD):
`docs/plans/2026-10-22-cron-web-ui-plan.md` (revision 6; WU-4 dropped,
run history dropped, `adAllowedOrigins` subsumed by existing
`adCanonicalOrigin`).

Execution: TDD per work unit, one commit per WU.

| WU | Title | Status |
|---|---|---|
| WU-0 | set the active plan | complete |
| WU-1 | shared cron operations module + total `computeNextFire` | pending |
| WU-2 | `ApiDeps.adCronStore` field | pending |
| WU-3 | 5 cron REST endpoints (route count 70 → 75) | pending |
| ~~WU-4~~ | ~~gateway-wide Origin check~~ | dropped (already done) |
| WU-5 | frontend types + API hooks | pending |
| WU-6 | `CronView` component | pending |
| WU-7 | top bar + routing | pending |
| WU-8 | full gate + docs | pending |
