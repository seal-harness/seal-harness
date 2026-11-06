# Seal Harness — TODO

## Status: Pre-alpha → Public Launch

## Active Work

- [~] Tool-call timeout/abort/retry — [plan written](docs/superpowers/plans/2026-08-14-tool-call-timeout-abort-retry.md), ready to implement
- [~] Ask-human stock answers — [slice 1](docs/superpowers/plans/2026-08-10-ask-human-stock-answers-slice1-plan.md), [slice 2](docs/superpowers/plans/2026-08-10-ask-human-stock-answers-slice2-plan.md), [slice 3](docs/superpowers/plans/2026-08-10-ask-human-stock-answers-slice3-plan.md)
- [~] Memory distillation + codegraph — [plan](docs/superpowers/plans/2026-08-03-memory-distillation-codegraph-skills-hierarchy.md) (branch `feat/memory-distillation-codegraph`)
- [ ] Remote enforcement hardening — [plan](docs/superpowers/plans/2026-07-22-remote-enforcement-hardening-plan.md)
- [ ] Session partition invariants — [plan](docs/superpowers/plans/2026-07-25-session-partition-invariants.md)
- [ ] Surface WebSocket connection issues in the web UI — [plan](docs/plans/websocket-connection-visibility-followups.md)

## Known Issues

### Critical

- #106 fix(remote-mode): agent-def/skill backends use direct local FS, miss repo's .agents/agents.md in mode=remote `(bug)`

### High

- [x] Remove all `GIT_` opcodes (except for SETUP_REPO).  Repo-related auth will be handled by BIN_EXEC when the binary is `git` or `gh` instead of introducing many new opcodes.
- [ ] GitHub PAT support for repos — existing SSH deploy key credentials only support git operations (clone, push); operations like creating PRs require `gh` CLI auth via env var (`GH_TOKEN`/`GITHUB_TOKEN`) in mode=remote; no unencrypted credentials ever written to disk
- [ ] Gateway API integration tests — transition core functionality testing to the gateway API level for consistency across web frontend, chat channels, and TUI; test both local and remote opcode execution modes; use containers for mode=remote rather than separate machines to keep complexity manageable
- #98 SSH agent management and cleanup
- #88 feat: session→repo association (persistent ssh-agent registry + tab-closure cleanup + repo-aware sessions) `(enhancement, area:config, area:security)`
- #81 feat: git opcodes + SSH agent forwarding (no un-encrypted secret on disk) `(enhancement, area:config, area:security)`
- #78 feat: Source control repo registry + credential-backed cloning `(enhancement, area:config, area:security)`

### Sub-agent completion delivery — follow-ups (found while diagnosing PR #279)

- [ ] Gateway restart mid-turn strands the pending completions — a startup sweep over every session's `agent-completions.jsonl` sidecar is needed (gateway-lifecycle feature, out of scope of the delivery fix; plan §5)
- [ ] `agent def not found` spawn failures were invisible to the parent (5 of 18 completions in the incident session were `agent def not found: dr3-*`); the completions now surface, but the spawn-side validation is missing (plan §5)
- [ ] The deferred-delivery path never delivers: `Seal/ISA/Ops/Agent.hs` skips the sidecar append when a child has pending descendants (`shouldDeferDelivery`) and nothing acts on the recorded settle flag (plan §5)
- [ ] Torn-read hazard: `readConversation` is `mapMaybe decode`, so a partially-written trailing line is silently dropped (latent — unreachable while completion handoffs are durable) (plan §5)
- [ ] `/model` and `/stop` notices never reach `conversation.jsonl` (they append to a conversation they never read; found by the new alignment detector) (plan §5)
- [ ] `RegistrySpec > agentStatus > records Crashed when the worker throws` is load-flaky (its poll is bounded at ~2s and flaked once under full-suite load, 2026-10-23)

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
- #16 OpenRouter support `(area:providers)` — shipped as the `openai` (generic) + `openrouter` (fixed URL) providers (#271/#273)
- #6 Add OSS health files: CODE_OF_CONDUCT, SECURITY, issue/PR templates `(documentation)`
- #7 CI: add hlint as a required gate `(good first issue, area:ci)`

## Backlog

- #50 Per-session workdir + optional chroot isolation for untrusted opcodes
- #40 On-demand opcode schema loading (config flag + OPCODE_DESCRIBE)
- #5 Refine CONTRIBUTING.md as Phase 2 lands
- [ ] Provider base-URL repoint guard — a keyed instance's `PUT {base_url}` keeps its stored key; add a rotate-key / explicit-confirmation guard
- [ ] Derive `catalogProblems`' built-in id list and `legacyReservedKeys` from `providerTypes`

## Done

- [x] Skills: available-skills catalog, SETUP_REPO opcode, static guidance (#71)
- [x] Signal channel: auto-lock allow_from, link wizard QR, transport fixes (#72)
- [x] Streaming: migrate Ollama provider + agent loop to streaming
- [x] Frontend: spinner, copy-session-id, model display in tabs, JSON tree
- [x] Ask-human: stock answers (#92), Telegram buttons (#94), open-ended questions
- [x] Git opcodes + SSH agent forwarding (#82)
- [x] .agents Protocol + skills discovery from cloned repos (#87, #99)
- [x] CodeGraph integration: auto-run `codegraph init` on SETUP_REPO + conditional skill injection
- [x] FILE_READ: Hermes-like pagination
- [x] FILE_PATCH: content-based apply, not position-based
- [x] Consolidated Tools row into System row (#101)
- [x] Haskell coder + reviewer skills wired (#84)
- [x] Human-authorship rule added to CONTRIBUTING.md (#85)

<!-- Last updated: 2026-10-21 by Seal session agent -->
