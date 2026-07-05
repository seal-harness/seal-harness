# Phase 3, M3 follow-up: keyless local Ollama needs no vault

Date: 2026-07-02
Status: APPROVED (design) — core fix; see "Open question" for the deferred UX part
Parent: `docs/superpowers/specs/2026-07-02-ollama-provider-design.md`

## Motivation

M3 shipped the Ollama provider, but keyless **local** Ollama is unreachable in
practice: `Seal.Channel.Cli.resolveSessionProvider` requires a configured vault
handle for *every* provider, and the Ollama branch of `resolveProvider` reads
`OLLAMA_API_KEY` from the vault. With a locked vault (e.g. a YubiKey vault that is
locked at startup) the read returns `VaultLocked`, so chatting with a local model
that needs no secret fails with *"vault is locked — run /vault unlock"* — forcing a
YubiKey tap for a keyless local call. With no vault at all it fails with *"vault not
configured"*. The M3 spec listed "zero-vault local Ollama" as a non-goal; this
follow-up reverses that, because it blocks all local testing.

Observed real setup that motivates this: a local `ollama serve` at
`http://localhost:11434` that also proxies Ollama Cloud models (tags like
`glm-5.2:cloud`, `remote_host: https://ollama.com`). Both local and cloud models are
reachable through the local daemon **by name, with no key held by Seal** — the daemon
handles cloud auth. So for this (common) setup Seal never needs a credential.

## Decision: base_url determines whether a key (and thus the vault) is needed

A single, deterministic rule replaces the unconditional vault requirement for Ollama:

- **Local / custom host** (base URL host is not `ollama.com`): resolve **keyless** —
  build `mkOllama mgr baseUrl Nothing model` **without touching the vault at all**.
  No vault handle required, no unlock required.
- **Cloud-direct host** (base URL host contains `ollama.com`): a key **is** required —
  consult the vault for `OLLAMA_API_KEY` exactly as M3 does today (missing key / locked
  / no vault → a clear error telling the user to add the key / unlock).

This keeps the M3 cloud-direct path (for users with no local daemon) intact while
making the overwhelmingly common local case need nothing. It is not "opportunistic
fallback" (which could silently downgrade a cloud request to localhost); the host in
the configured base URL is the explicit signal.

`ollamaNeedsKey :: Text -> Bool` — true iff the base URL contains `ollama.com` — is the
one predicate encoding this. It lives in `Seal.Providers.Ollama` next to
`defaultOllamaBaseUrl`.

## Components

### `Seal.Providers.Registry.resolveProvider` — take `Maybe VaultHandle`

Change the signature from `VaultHandle` to `Maybe VaultHandle` so a provider can be
resolved with no vault:

```haskell
resolveProvider
  :: Maybe VaultHandle -> Manager -> Text -> KnownProvider -> ModelId
  -> IO (Either Text SomeProvider)
```

- **Anthropic:** `Nothing` → `Left "vault not configured — run /vault setup"` (keys are
  mandatory); `Just vh` → the existing OAuth-then-API-key logic unchanged.
- **Ollama, `ollamaNeedsKey baseUrl == False` (local/custom):** ignore the vault
  entirely → `Right (SomeProvider (mkOllama mgr baseUrl Nothing model))`.
- **Ollama, `ollamaNeedsKey baseUrl == True` (cloud-direct):**
  - `Nothing` → `Left "Ollama Cloud needs an API key — run /vault setup then /provider add ollama"`.
  - `Just vh` → read `OLLAMA_API_KEY`; `Right k` → `Just (mkApiKey k)`; any `VaultError`
    (locked / missing) → `Left (vaultErrText e)` (cloud genuinely needs it).

### `Seal.Channel.Cli.resolveSessionProvider` — drop the blanket vault gate

Stop returning "vault not configured" before resolution. Read the (maybe-absent) vault
handle and pass it straight through:

```haskell
Just kp -> do
  eCfg <- loadFileConfig (prConfigPath pr)
  let baseUrl = fromMaybe defaultOllamaBaseUrl (either (const Nothing) fcOllamaBaseUrl eCfg)
      model   = ModelId (smModel meta)
  mh <- readIORef (vrHandleRef (prVault pr))
  fmap (fmap (, model)) (resolveProvider mh (prManager pr) baseUrl kp model)
```

Anthropic still errors on `Nothing` inside `resolveProvider`, so its behavior is
unchanged; local Ollama now resolves with `mh == Nothing` or a locked handle.

### `Seal.Command.Provider.testCmd` — pass `Just vh`

`testCmd` runs inside `withVaultHandle` (a handle exists), so it passes `Just vh`. For a
local base URL the handle is ignored (keyless); for the cloud host the key is read as
today. (Making `/provider test ollama` work with *no* vault at all is out of scope — the
handle-exists requirement there is unchanged.)

## Error handling

`Either Text`. Local Ollama surfaces only transport/HTTP errors (unreachable daemon →
the existing `unreachableMsg`; non-2xx → `ollamaErrorText`). Cloud-direct without a key
gets an actionable vault message. No secret bytes in any message.

## Testing

**Pure/unit:**
- `ollamaNeedsKey`: `http://localhost:11434` → False; `https://ollama.com` → True;
  `https://api.ollama.com` → True; a LAN host → False.
- `resolveProvider` (`Maybe VaultHandle`):
  - Ollama local, `Nothing` vault → `Right` (keyless).
  - Ollama local, `Just` locked vault → `Right` (keyless; vault untouched — verified by a
    locked fake vault that would error on any access).
  - Ollama cloud host, `Just` vault with `OLLAMA_API_KEY` → `Right`.
  - Ollama cloud host, `Nothing` vault → `Left` (actionable).
  - Ollama cloud host, `Just` locked vault → `Left` "locked".
  - Anthropic, `Nothing` → `Left` "vault not configured"; `Just` with key → `Right`.
- Update the four existing Anthropic `resolveProvider` calls + the M3 Ollama tests to the
  `Maybe VaultHandle` signature (`Just <$>` the fake vaults).

**Manual (now possible against a running daemon):** `/model use ollama <name>` then a
chat turn reaches `localhost:11434` with no vault unlock.

## Follow-up (approved): `/model list <provider>` — live model listing

Motivated by a real failure: `/model use ollama glm-5.2` → `HTTP 404: model 'glm-5.2'
not found`, because the local daemon exposes that cloud model as `glm-5.2:cloud` (the
`:cloud` tag). Cloud models *are* handled (verified: `glm-5.2:cloud` returns a
completion); the gap is **discoverability of the exact model names**. The fix is a
command that lists a provider's live models.

- **Command:** extend the existing `/model list`. `/model list` (no arg) keeps today's
  behavior (each known provider + its default model, plus the active selection).
  `/model list <provider>` resolves that provider and prints its live `listModels`
  result — for Ollama this is the daemon's `/api/tags` (e.g. `glm-5.2:cloud`,
  `llama3.2:latest`, …); for Anthropic it is the single configured model.
- **List-only, no validation.** `/model use` stays permissive (a wrong name still fails
  at send time with the provider's 404). Validating `use` against the live list is
  intentionally out of scope (extra per-switch network call + a daemon-down failure
  mode); trivially added later if wanted.
- **Plumbing:** `modelCommandSpec` gains the provider-resolution context (the existing
  `ProviderRuntime`: HTTP `Manager` + vault handle-ref + config path) so it can call
  `resolveProvider` (the `Maybe VaultHandle` form above) + a new
  `listSome :: SomeProvider -> IO (Either Text [ModelId])` (mirrors `completeSome`).
  Local Ollama lists keyless (no vault); Anthropic/cloud-Ollama resolution still needs
  the vault, so `/model list anthropic` without an unlocked vault reports the resolve
  error.

Testing: pure `listSome` pass-through; a `/model list ollama` handler test driven by a
scripted in-process provider (asserts the model lines and the empty case); `/model list`
with no arg unchanged. Manual: `/model list ollama` against the running daemon shows the
`:cloud` tag.
- `/provider test ollama` without any vault handle (keeps requiring a handle to exist).
- Parsing the URL host rigorously — a substring check for `ollama.com` is sufficient and
  clear; revisit only if a real host legitimately contains that substring without being
  Ollama Cloud.
