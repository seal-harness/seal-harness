# Seal Harness — TODO

## Status: Pre-alpha → Public Launch

## Active Work

- [~] Tool-call timeout/abort/retry — [plan written](docs/superpowers/plans/2026-08-14-tool-call-timeout-abort-retry.md), ready to implement
- [~] Ask-human stock answers — [slice 1](docs/superpowers/plans/2026-08-10-ask-human-stock-answers-slice1-plan.md), [slice 2](docs/superpowers/plans/2026-08-10-ask-human-stock-answers-slice2-plan.md), [slice 3](docs/superpowers/plans/2026-08-10-ask-human-stock-answers-slice3-plan.md)
- [~] Memory distillation + codegraph — [plan](docs/superpowers/plans/2026-08-03-memory-distillation-codegraph-skills-hierarchy.md) (branch `feat/memory-distillation-codegraph`)
- [ ] Remote enforcement hardening — [plan](docs/superpowers/plans/2026-07-22-remote-enforcement-hardening-plan.md)
- [ ] Session partition invariants — [plan](docs/superpowers/plans/2026-07-25-session-partition-invariants.md)

## Known Issues

### Critical

- #106 fix(remote-mode): agent-def/skill backends use direct local FS, miss repo's .agents/agents.md in mode=remote `(bug)`

### High

- #98 SSH agent management and cleanup
- #88 feat: session→repo association (persistent ssh-agent registry + tab-closure cleanup + repo-aware sessions) `(enhancement, area:config, area:security)`
- #81 feat: git opcodes + SSH agent forwarding (no un-encrypted secret on disk) `(enhancement, area:config, area:security)`
- #78 feat: Source control repo registry + credential-backed cloning `(enhancement, area:config, area:security)`

### Help Wanted

- #15 Run local models with Ollama `(area:providers)`
- #14 OpenAI / GPT models `(area:providers)`
- #13 Anthropic Claude models `(area:providers)`
- #12 Terminal chat (seal chat) `(area:channels)`
- #11 Slack support `(area:channels)`
- #10 Discord support `(area:channels)`
- #9 Signal support `(area:channels)`
- #19 iMessage support `(area:channels)`
- #18 WhatsApp support `(area:channels)`
- #17 Google Gemini support `(area:providers)`
- #16 OpenRouter support `(area:providers)`
- #6 Add OSS health files: CODE_OF_CONDUCT, SECURITY, issue/PR templates `(documentation)`
- #7 CI: add hlint as a required gate `(good first issue, area:ci)`

## Backlog

- #50 Per-session workdir + optional chroot isolation for untrusted opcodes
- [ ] GitHub PAT support for repos — pass token to `gh` via env var (`GH_TOKEN`/`GITHUB_TOKEN`) in mode=remote; no unencrypted credentials ever written to disk
- #40 On-demand opcode schema loading (config flag + OPCODE_DESCRIBE)
- #5 Refine CONTRIBUTING.md as Phase 2 lands

## Done

- [x] Skills: available-skills catalog, SETUP_REPO opcode, static guidance (#71)
- [x] Signal channel: auto-lock allow_from, link wizard QR, transport fixes (#72)
- [x] Streaming: migrate Ollama provider + agent loop to streaming
- [x] Frontend: spinner, copy-session-id, model display in tabs, JSON tree
- [x] Ask-human: stock answers (#92), Telegram buttons (#94), open-ended questions
- [x] Git opcodes + SSH agent forwarding (#82)
- [x] .agents Protocol + skills discovery from cloned repos (#87, #99)
- [x] FILE_READ: Hermes-like pagination
- [x] FILE_PATCH: content-based apply, not position-based
- [x] Consolidated Tools row into System row (#101)
- [x] Haskell coder + reviewer skills wired (#84)
- [x] Human-authorship rule added to CONTRIBUTING.md (#85)

<!-- Last updated: 2026-08-17 by Seal session agent -->
