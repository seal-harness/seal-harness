# Phase 3 (revised): Multi-provider sessions + spine-exercising command surface

Date: 2026-06-30
Status: APPROVED (design)
Branch: `phase-3-multi-provider-sessions` (based on the Phase 2.5 agent spine)

## Motivation

Phase 2.5 shipped the agent spine: the `Provider` class + Anthropic implementation,
the ISA opcodes, the turn loop, and per-session transcript machinery. But the provider
is **hardcoded at startup** — resolved from `ANTHROPIC_API_KEY` with the model pinned to
`claude-opus-4-8` in `Seal.Channel.Cli` — and there is no `/`-command to inspect, switch,
or exercise it. There is one implicit `"cli"` session writing a single
`state/transcript.jsonl`.

This phase makes providers and sessions first-class and adds a grouped `/`-command
surface that exercises every piece of the spine end-to-end, all behind channel-agnostic
seams so the next channel (Signal) drops in without reworking this layer.

## Goals

1. **Multi-provider, config-driven.** A registry of configured providers, selected at
   runtime, replacing the env-var hardcode. Implement **Anthropic** and **Ollama**
   (Ollama supporting both a local host and Ollama cloud).
2. **Vault-stored credentials.** Provider API keys live in the encrypted secrets vault
   (reusing the Phase 1/2 vault), never serialized to config or transcripts.
3. **First-class sessions.** Each session holds a selected provider+model, an id, and its
   own transcript laid out under `~/.seal/state/sessions/<id>/`, matching the reference
   runtime's on-disk organization.
4. **Grouped `/`-command surface** that exercises providers, sessions, models, and the
   four spine opcodes.
5. **Channel-ready.** Providers, sessions, and command actions take no Haskeline/CLI
   types, so Signal reuses them unchanged later.

## Non-goals (this phase)

- The Signal channel itself (next phase; this phase only keeps the seams clean).
- Streaming responses (the spine is non-streaming; unchanged here).
- Additional providers beyond Anthropic + Ollama (the registry is generic so more are
  config + one `Provider` instance later).
- OAuth / token-refresh flows (API-key + keyless-local only).
- Passphrase-prompt-on-startup vault unlock changes (reuse existing `/vault` unlock).

## Guiding principle

**Minimize implementation before reaching a user-testable point.** The build order below
is a sequence of independently runnable vertical slices; we stop and the user tests at the
end of each milestone before starting the next.

## Build order (milestones)

### M1 — Provider config + vault credentials + `/provider` (Anthropic only)

The shortest path to "test the provider from the REPL."

- `config.toml` gains a `[providers]` section and `default_provider` / `default_model`.
- `/provider add <id>` — prompts for the API key with hidden input (`ccPromptSecret`),
  stores it in the vault under the provider's key name (e.g. `ANTHROPIC_API_KEY`).
- `/provider list` — shows configured providers and whether a credential is present.
- `/provider test <id>` — resolves the provider and performs one trivial live `complete`
  round-trip, reporting ok / error (key-safe).
- `/provider remove <id>` — removes the vault credential and/or config entry.

*User-testable:* store a real key in the vault and prove a live API call from the REPL.

### M2 — First-class sessions + `/session` + `/model`; chat uses the session's model

- `Seal.Session.{Meta,Store}` — sessions under `~/.seal/state/sessions/<id>/` with
  `session.json` (0600) + `transcript.jsonl` (0600); dir 0700.
- New session created on each launch; default provider+model taken from config.
- `/session list|resume <ref>|info`, `/model list|use <provider> <model>`.
- Plain chat now runs against the session's selected provider+model — **deletes the
  `ANTHROPIC_API_KEY` startup hardcode** in `Seal.Channel.Cli`.

*User-testable:* real chat in a session, switch model, quit, resume the session.

### M3 — Ollama provider (local + cloud)

- `Seal.Providers.Ollama` — a `Provider` instance with a configurable `base_url`
  (localhost:11434 for local, the cloud host otherwise) and an **optional** API key
  (none for local; from vault for cloud).
- `listModels` via `GET /api/tags` (local); `complete` via the Ollama chat endpoint.
- `/provider add ollama`, `/model use ollama <name>` work end-to-end.

*User-testable:* multi-provider switching across Anthropic and Ollama.

### M4 — Spine probe commands — CANCELLED (2026-07-03)

**Dropped as unnecessary.** The idea was operator `/`-commands (`/show`, `/ask`,
`/read`, `/secret`) that directly drive SHOW_HUMAN / ASK_HUMAN / FILE_READ /
SECRET_GET. On review none were needed: the model already reaches all four
opcodes as **tool calls** (they are registered in the ISA registry), secrets are
managed through the `/vault` command family, and SHOW/ASK are the model talking
*to* the human (not the reverse). The opcodes remain tool-call-only; no operator
commands ship. See `../plans/2026-07-03-phase-3-m4-spine-commands.md` (retained
as a cancelled planning record).

## Components

### New modules

- **`Seal.Providers.Registry`** — builds `ProviderId → SomeProvider` from config + vault.
  Credentials resolved **lazily** from the vault on first use (so an unconfigured or
  locked provider does not block startup). No channel/Haskeline dependency.
- **`Seal.Providers.Ollama`** — `Provider` instance; `base_url` + optional `ApiKey`;
  `complete` + `listModels`. Pure request/response codec separated from the HTTP
  round-trip (mirrors the Anthropic module's `encodeRequest`/`decodeResponse` split).
- **`Seal.Providers.Transcript`** — a `Provider` *decorator* that records the request and
  response around the inner `complete`, with auth headers / secrets redacted, writing
  `TranscriptEntry` rows (Request then correlated Response) to the session transcript.
  Keeps the agent loop unchanged and gives a single, honest record point. (Resolves the
  Phase 2.5 spine-review follow-up about where opcode/provider results get recorded.)
- **`Seal.Session.Meta`** — `SessionMeta` record + atomic JSON read/write. Fields:
  `id`, `provider`, `model`, `channel`, `created_at`, `last_active`, `archived`,
  `description`. JSON keys snake_case; tolerant `FromJSON` for forward-compat.
- **`Seal.Session.Store`** — `newSession` (id format `YYYYMMDD-HHMMSS-mmm`, optional
  suffix), `listSessions` (enumerate `state/sessions/`, read each `session.json`, sort by
  `last_active` desc, skip corrupt — **no manifest/index file**), `resumeSession`
  (traversal-safe id validation via `Seal.Core.Types.isValidSessionId` before path-join,
  then load meta), `touchLastActive`.
- **`Seal.Command.{Provider,Session,Model,Spine}`** — one `CommandSpec` group each,
  following the existing `/vault` pattern (optparse-derived parsers, `CommandAction`
  over `ChannelCaps`). New `CommandGroup` constructors: `GroupProvider`, `GroupSession`,
  `GroupModel`, `GroupSpine`.

### Changed modules

- **`Seal.Config.File`** — add a `[providers.<id>]` table (per-provider: enabled,
  default model, `base_url` for Ollama, vault key name) plus top-level
  `default_provider` / `default_model`.
- **`Seal.Channel.Cli` / `Seal.AppMain`** — startup wiring: build the `ProviderRegistry`
  from config+vault, create/open the session, assemble the registry with the new command
  groups, and point plain chat at the session's selected provider+model. Remove the
  `ANTHROPIC_API_KEY` env hardcode and the pinned model literal.

## Data flow

1. **Startup:** load `config.toml` → build `ProviderRegistry` (lazy credential
   resolution) → `newSession` creates the session dir + `session.json` → open the
   session's transcript daemon → enter the REPL.
2. **Plain text:** `ingest` → `PlainMessage` → `runTurn` with an `AgentEnv` built from the
   session's selected provider (wrapped by `Seal.Providers.Transcript`) + model.
3. **`/model use <provider> <model>`:** mutate the in-memory session selection and persist
   to `session.json`.
4. **`/provider test <id>`:** resolve the provider from the registry → one trivial
   `complete` → report ok/error.
5. **`/session resume <ref>`:** validate + load the target session, swap the active
   session (its transcript + selection) for subsequent turns.

## Credential storage

- Vault keys named per provider: `ANTHROPIC_API_KEY`, `OLLAMA_API_KEY` (cloud only).
- `/provider add <id>` prompts hidden via `ccPromptSecret` → `vault add`.
- Local Ollama needs no key.
- Resolution order: inline config value (discouraged, for non-secret hosts) → vault.
- Keys reuse the opaque `ApiKey`/`Secret` types: no `ToJSON`/`ToTOML`, `Show` redacts;
  never written to config or transcript.

## Error handling

`Either Text` per project convention (typed ADT only where control flow needs it).

- Provider `test`/chat surface transport/HTTP errors key-safely (reuse the Anthropic
  key-safe error paths).
- Vault locked when a credential is needed → actionable message pointing at
  `/vault unlock`.
- Unknown provider/model → clear message listing configured options.
- Corrupt `session.json` → skipped on `list`, explicit error on `resume`.
- Missing credential for a provider → `test`/chat report it without leaking key bytes.

## Multi-channel readiness

`ChannelCaps` already abstracts `ccSend` / `ccPrompt` / `ccPromptSecret`.
`ProviderRegistry`, `SessionStore`, and every `CommandAction` are written against
`ChannelCaps` with **no Haskeline/CLI types**. The CLI channel supplies a Haskeline-backed
`ChannelCaps`; the Signal channel later supplies its own and reuses the registry, session
store, and all `/`-commands unchanged. `SessionMeta._channel` records which channel
created a session.

## Testing

**Pure:**
- `config.toml` parse incl. `[providers.*]` and defaults.
- Session-id format + `isValidSessionId` traversal safety.
- `SessionMeta` JSON round-trip (+ tolerant decode of a minimal/legacy object).
- Registry resolution (which provider for a given id; missing → error).
- Ollama request/response codec round-trip.
- Transcript-decorator redaction: a request carrying a fake auth header is redacted in the
  recorded `TranscriptEntry`.

**IO with mocks/temp dirs:**
- Session store create/list/resume against a temp `SEAL_HOME` (perms 0700/0600 asserted).
- Credential resolution with the existing mock vault encryptor.
- `/provider test` driven by a scripted in-process `Provider` (no network) — asserts the
  ok and error reports.
- Command wiring: a `/model use` round-trips to `session.json`; chat routes to the
  session's selected provider.

**Gated (pending):** live Anthropic round-trip; live Ollama round-trip (local) — both
require external services / keys, marked `pending` like the existing YubiKey/REPL smoke
tests.

## Key decisions

- **New session each launch**; `/session resume` continues an old one. No manifest file —
  the session list is derived by enumerating the `sessions/` directory.
- **Model switch names provider + model explicitly** (`/model use anthropic claude-opus-4-8`)
  to stay unambiguous once Ollama hosts arbitrary model names; the **default
  provider+model come from config**, so a new session needs no typing.
- **Transcript-wrapping provider** is the single record point for provider req/resp, with
  auth redacted on the request — matching the reference runtime and resolving a spine
  follow-up.
- **Lazy vault credential resolution** so startup never blocks on a locked or
  unconfigured provider.
