# Revision history for seal-harness

## Unreleased — provider families

**Providers are named instances of a provider *type*, and every type belongs to a
provider *family* (the wire API).** The family never fixes a base URL; a type
combines a family with an endpoint policy. Four built-in providers ship:

- `anthropic` — the Anthropic API, fixed `https://api.anthropic.com`.
- `ollama` — the Ollama API, default `http://localhost:11434` (overridable).
- `openai` — the **generic OpenAI API**: the OpenAI `/chat/completions` wire
  format with **no fixed endpoint**, so you supply the base URL (for
  `https://api.openai.com/v1`, a local vLLM / llama.cpp / LM Studio server, a
  proxy, …). The API key is optional: keyless local servers work with no vault.
- `openrouter` — the same OpenAI API with the base URL **fixed** to
  `https://openrouter.ai/api/v1`, a required key, a default model and the
  `HTTP-Referer` / `X-Title` attribution headers.

Instances are still named (`/provider add <type> [name]`, `/provider list`,
`/model … <name>`, `new -p <name>`). A type-named instance keeps the legacy
vault key (`ANTHROPIC_API_KEY`, `OLLAMA_API_KEY`, `OPENAI_API_KEY`,
`OPENROUTER_API_KEY`); any other name uses `PROVIDER_APIKEY_<NAME>`.

- **`openai-compat` is gone.** It was never released. A development config that
  still has `[providers.openai-compat]` (or `default_provider = "openai-compat"`)
  surfaces as a *problem row* in the Providers view / `/provider list`: re-create
  it as `openai` (or `openrouter`), then `/vault delete OPENAI_COMPAT_API_KEY` to
  remove the orphaned secret.
- **Security delta** (guarantees unchanged, surface wider): the generic `openai`
  row holds `OPENAI_API_KEY` and a `PUT {base_url}` keeps it, so it is
  repointable to an operator-chosen host on the unauthenticated, loopback-bound
  REST surface — accepted for now; a guard is tracked in `TODO.md`. `openrouter`
  is fixed, so its key cannot be repointed. `DELETE /api/providers/openai`
  removes `OPENAI_API_KEY` (the name may be shared with other tooling). Provider
  payloads expose the vault key *names* (`apiKeyName` / `oauthKeyName`) so the UI
  names the exact secret on delete; no secret values are exposed.
- Provider error bodies are single-lined and truncated to 2000 characters (the
  text is persisted to the transcript and re-sent to the model). Upstream 3xx
  responses are refused rather than followed (the redirect would forward the
  `Authorization` header).
- `/provider list` lists every instance with its status and the URL Seal will
  talk to. `new -p openrouter` now works (it is a valid provider); a persisted
  `provider = "openai-compat"` fails closed with a rename hint.
- **The Providers view lists only the providers you can actually use.** An
  instance with no credential and no usable endpoint no longer appears in the
  left-hand list — it is configured from the type picker instead (the picker
  still offers every type, configured or not). Two kinds of row stay visible
  on purpose: a **locked vault** (the credential may well exist, we just
  cannot read it, and the row must stay reachable so the key can be
  rotated) and a **problem row** (the only way to fix or delete a broken
  `config.toml` section). The name field in the new-provider form is labelled
  **"Unique Name"** to make clear that the name identifies one instance.

## 0.1.0.0 — unreleased

* Project scaffolding. Subcommand CLI built on `configuration-tools`, a
  `ReaderT Env (KatipContextT IO)` application monad, IORef-based mutable
  state, and katip structured logging. The `greet` / `tick` commands are
  placeholder scaffolding demonstrating the patterns; they will be replaced
  by the SealOp ISA implementation (see the implementation plan in
  `docs/`).
