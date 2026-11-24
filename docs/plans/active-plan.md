# Active Plan
<!-- approved: 2026-11-24 -->
<!-- gate-iterations: 2 -->
<!-- user-approved: true -->
<!-- status: in-progress -->

Sub-agent termination is reported as success — root cause + truthful status +
handoff parent linkage + UI visibility (rev 6).

Canonical plan (full text, work units, DoD):
`docs/superpowers/plans/2026-11-24-subagent-termination-truthfulness-plan.md`

Execution: orchestrated (6 work units), user-selected 2026-11-24.

| WU | Title | Status | Commit |
|---|---|---|---|
| WU-1 | runChildWithTimeout seam + catchChildSync + three catch sites | complete | d72af9e |
| WU-1.5 | withHeartbeat bracket (operator-approved; disclosed by WU-1 review) | complete | ab7eabd |
| WU-2 | Structural exit reason (aeStopFanoutDone + terminalReasonRef + childStopKind) | complete | 02d73d4 |
| WU-3 | Registry truthfulness (real crStatus + log line) | complete | b4d4040 |
| WU-4 | Handoff callback (parentSid, sidecar append, parent wake) | complete | a9e2f3b |
| WU-5 | Live broadcast (dwdOnEntry :: SessionId -> IO ()) | complete | 02b6cc0 |
| WU-6 | make check green | pending | — |

Prior active plan (completed 2026-11-14):
`docs/superpowers/plans/2026-11-14-chunked-resumable-download-plan.md`
