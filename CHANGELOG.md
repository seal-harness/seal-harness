# Revision history for seal-harness

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
