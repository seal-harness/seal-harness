# Revision history for seal-harness

## Unreleased — named provider instances

**Providers are now named instances of a type.** One `openai-compat` endpoint
is no longer the limit: every type (Anthropic, Ollama, and each
OpenAI-compatible catalog row) gets instances, named by you (e.g. `work`,
`local-vllm`). They are addressed by instance name across the CLI
(`/provider add <type> [name]`, `/provider list|test|default|remove|login
<name>`, `/model list|use|default <name> <model>`, `new -p <name>`), the REST
API, sessions and agent defs.

- **Nothing to do on upgrade.** Existing `[providers.anthropic]`,
  `[providers.ollama]` and `[providers.openai-compat]` sections keep working: a
  type named after its own id is an implicit instance that keeps the legacy
  vault keys. A hand-written section with no `type` and a non-legacy name is
  surfaced as a *problem row* (fix or delete it in `config.toml`); a typed
  section whose name is another type's id is also a problem row.
- **Model change:** an instance is identified by its name, not its type.
  `config.toml` gains `type = "<type-id>"` in each `[providers.<name>]` section;
  secrets for non-type-named instances live under `PROVIDER_APIKEY_<NAME>` /
  `PROVIDER_OAUTH_<NAME>` (type-named instances keep `ANTHROPIC_API_KEY` etc.).
- **`default_provider`** now holds an instance name (e.g. `anthropic-work`).
- **Security delta** (guarantees unchanged, surface wider): the set of
  credentials repointable via `PUT {base_url}` grows 2→N (operator-key
  exfiltration to an attacker-chosen host, not merely "repointing"); instance
  names are operator-authored and creation-validated but **not load-validated**,
  and credential target names become enumerable on a surface that can already
  write them; `GET /api/providers/all` does one vault read per instance (no
  cap); a no-credential (broken) row's credentials can no longer be deleted
  from the UI/CLI and orphan until `/vault delete`.
- **Non-goal:** repointing an existing session's provider from the web UI is
  out of scope (the CLI's `/model use <instance> <model>` covers it; there is
  no REST endpoint for it, for any provider).

## Unreleased — generic OpenAI-compatible provider

**Breaking: the `openrouter` provider is now `openai-compat`.** The provider
never was OpenRouter-specific — it speaks OpenAI's `/chat/completions` wire
format — so it is now a generic OpenAI-compatible provider with a **required**
base URL, and further compatible vendors are catalog rows rather than code.

- `openai-compat` requires a **base URL** (`https://host/v1`) and a **model**.
  The API key is optional: local vLLM / llama.cpp / LM Studio endpoints work
  with no vault and no key. A stored key is still used when present.
- `config.toml` is migrated at boot: `default_provider` and
  `[providers.openrouter]` are rewritten to `openai-compat` (keeping your
  `base_url`, `default_model`, and the old implicit model). **One manual step
  remains:** re-enter the API key with `/provider add openai-compat` (the
  migration runs before the vault is unlocked). The old
  `OPENROUTER_API_KEY` entry is left in place; revoke it at the vendor if the
  `openrouter` preset (see below) will not ship.
- Existing sessions and agent defs that name `openrouter` fail with a message
  naming the exact repair (`/model use openai-compat <model>`; edit the def's
  `provider:` line). `new -p openrouter` is rejected up front.
- **Upstream 3xx responses are refused** rather than followed, because the
  redirect would forward the `Authorization` header. Enter a base URL in its
  final form.
- Provider error bodies are single-lined and truncated to 2000 characters (the
  text is persisted to the transcript and re-sent to the model).
- `/provider remove <provider>` no longer deletes the Anthropic OAuth login
  when the provider is not Anthropic, and a keyless provider can now be
  removed/deconfigured.
- `/provider list` lists every known provider with its status and the URL Seal
  will talk to.
- Migrated OpenRouter users lose the `HTTP-Referer`/`X-Title` attribution
  headers until the `openrouter` preset ships.

Next: `openai` and `openrouter` presets (one catalog row each) so the URL and
model never have to be looked up.

## 0.1.0.0 — unreleased

* Project scaffolding. Subcommand CLI built on `configuration-tools`, a
  `ReaderT Env (KatipContextT IO)` application monad, IORef-based mutable
  state, and katip structured logging. The `greet` / `tick` commands are
  placeholder scaffolding demonstrating the patterns; they will be replaced
  by the SealOp ISA implementation (see the implementation plan in
  `docs/`).
