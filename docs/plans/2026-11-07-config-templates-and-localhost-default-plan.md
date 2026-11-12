# Gateway default host `localhost` + first-run config templates

<!-- status: draft v6 -->
<!-- branch: gateway/passkey-access-control -->
<!-- date: 2026-11-07 -->
<!-- gate: r1 FAIL, r2 FAIL, r3 FAIL, r4 FAIL, r5 feasibility PASS /
     completeness FAIL (3 items). v6 fixes those three and the nits. -->

## Goal

Two changes on `gateway/passkey-access-control`:

1. **Default gateway host becomes `localhost`** (was `127.0.0.1`), and
   `[gateway] host` is made authoritative for the actual listener — today it
   never reaches Warp.
2. **First run writes `~/.seal/config/config.toml` and `~/.seal/security.toml`**
   as template files populated with the default values, so the option surface
   is discoverable without reading the source.

## Why `localhost` (item 1)

A passkey ceremony needs a secure context and a relying-party id that is a
domain name, so the browser must open `http://localhost:<port>`. The pieces are
already aligned for that name and *not* for the literal address:

- `canonicalOriginFor` maps any loopback bind to `http://localhost:<port>`;
  `127.0.0.1` is deliberately never used, because rpIds match by domain suffix
  and mixing spellings yields credentials that fail depending on which URL was
  typed (`Security/AccessControl.hs:83-92`, design §3).
- `gcAllowedOrigins` default is already `["http://localhost:8080"]`
  (`Gateway/Config.hs:53-54`).
- `isLoopbackHost` already accepts `"localhost"`
  (`Security/AccessControl.hs:296`), so `BootPlan.checkBind` keeps seeing a
  loopback bind and nothing starts refusing to boot.

### The bind is currently not wired (found while reading `runGateway`)

```haskell
warpSettings = setPort port settings      -- Server.hs:306; settings = setTimeout 120_000 defaultSettings
runTLS  … warpSettings app                -- :312
runSettings warpSettings app              -- :313
```

Warp's `defaultSettings` host preference is the IPv4 wildcard (`*4`), so the
gateway bound every interface regardless of `[gateway] host`, and `host` fed
only: the printed boot URL (`Server.hs:299-303`), the derived WS/WebAuthn
origins, `isExposedBind`'s warning (call at `:302`, predicate at `:321`), the
passkey boot matrix's loopback check, and the generated certificate's SAN list
(`Security/TlsCert.hs:132`). README:300 already documents
`host = "0.0.0.0"` as *the* way to expose a gateway, i.e. the docs assume
`host` binds.

**Decision (operator): wire `setHost`.**

### Consequences of wiring it (all three must be handled)

1. **`host` becomes a boot-fatal input.** Any string used to be survivable;
   now `host = ""`, a bracketed `[::1]`, a pasted URL or a typo aborts
   `seal serve` inside Warp, after the banner. `[gateway] tls_cert`/`tls_key`
   already fail early with an actionable message (`tlsConfigError`, called at
   `Serve.hs:178`); `host` gets the same treatment:

   ```haskell
   -- Seal.Gateway.Config, both exported
   gatewayHostError :: Text -> Maybe Text
   --   pure: empty/whitespace-only, contains '/' or whitespace, or is
   --   bracketed → Just message naming the key and the fix

   hostResolves :: Text -> IO Bool
   --   the production resolver (getAddrInfo-backed); True = at least one address

   gatewayHostResolutionError :: (Text -> IO Bool) -> Text -> IO (Maybe Text)
   --   refuses when the host does not resolve to at least one address
   ```

   The rule is **resolvable**, not "local": Warp may legitimately bind any
   address this machine has — a tailnet or LAN address is a normal `host` value
   (README:300) — so a locality test would refuse valid configurations. The
   resolver is injected into `gatewayHostResolutionError` so the refusal branch
   is testable without DNS; production passes `hostResolves`. `network` is
   already a direct dependency. Both checks run where `tlsConfigError` runs
   (`Serve.hs:178`), before anything binds, and the W3.9 guard pins that call
   site. Tests live in the existing `test/Seal/Gateway/ConfigSpec.hs` (already
   wired; no new module).

2. **The WebSocket Origin allowlist narrows.** `Serve.hs:497-505` derives the
   guard's allowlist as `scheme://<gcHost>:<port>` prepended to
   `gcAllowedOrigins`. With the old default the set was
   `{127.0.0.1:8080, localhost:8080}`; with the new one it is
   `{localhost:8080}` alone. A browser at a bookmarked
   `http://127.0.0.1:8080` can still reach the listener, but its WS handshake
   is refused — and in passkey mode it would be refused anyway, because the
   session cookie is host-scoped. **No code change**: the design's "one URL
   everywhere" rule (`canonicalOriginFor`'s doc comment) is exactly this.
   Stated in the CHANGELOG and README.

3. **The listener narrows**, which is the point, and `isExposedBind`'s warning
   finally corresponds to the bind.

Evidence that W1's DoD is assertable: warp 3.4.13.1 is in the dev shell's store,
`Network.Wai.Handler.Warp` exports `getHost` (3.4.7 haddock `doc-index-G.html`),
and `HostPreference` has an `IsString` instance
(`$fIsStringHostPreference_$cfromString` in the installed `Settings.hi`). The
DoD is written with `fromString` on both sides so it names no unverified
constructor: `getHost (warpSettingsFor defaultGatewayConfig) == fromString
"localhost"`. **If that does not compile against the pinned warp, stop and
report** — do not substitute a weaker smoke test (connect-to-localhost passes
under a wildcard bind too, so it would certify the bug).

## Design: templates (item 2)

### Where the text lives

Embedded sources, the way built-in skills already are (`Seal.Skills.Builtins`,
`Data.FileEmbed` import at `Builtins.hs:25`, `embedFile` splices at `:66-77`):

- `config/templates/config.toml`
- `config/templates/security.toml`

New module `Seal.Config.Templates`:

```haskell
configTomlTemplate   :: Text
securityTomlTemplate :: Text
ensureConfigTemplates :: SealPaths -> IO ([FilePath], [Text])   -- (created, warnings)
```

No `data-files`, no install-layout dependency. `flake.nix` uses `src = ./.;`,
so new files under `config/` reach the nix build without an
`extra-source-files` entry.

### When they are written

Three call sites, all human-driven CLI paths, each before the file it scaffolds
is read or written:

- `Serve.runServeMainInner`, immediately after `migrateSecurityConfig`
  (`Serve.hs:153`), before either config is loaded;
- `Tui.runTui`, same position (`Tui.hs:86`);
- `Command.AccessControl.runAccessControl`, at the top. **Required**, because
  `seal access-control disable|reset|migrate-credentials` write `security.toml`
  through `updateAccessControlSection` (`Command/AccessControl.hs:240`) and
  `clearAccessControlSection` (`:291`), and `saveSecurityConfig` *creates* the
  file when it is absent (`Security.hs:480-489`). Without this call site a fresh
  install that runs one of those commands first would never receive the
  template.

It never throws: parent-dir creation and the write for each file sit inside one
handler, a failure becomes an entry in the warnings list, and the other file is
still attempted. The caller logs one Info line per created path (so a fresh
operator is told the files exist) and one Warning per failure — a missing
template never stops the harness from booting.

### Never overwrite

Both files are written only when absent; an existing (operator- or
program-written) file is left byte-for-byte alone, including a
migration-produced `security.toml`. An upgrading install therefore keeps its file
and gets no template — stated in the README and CHANGELOG rather than implied.

`seal`'s CLI subcommands are `tui`, `serve`, `access-control …` and
`gen-openapi` (`Types/Command.hs:19-24`; there is no `seal provider add`), so
every CLI path that writes either file is covered by the three call sites above.
The remaining writers — `saveRuntimeConfig`/`updateRuntimeConfig` from
`Gateway/API.hs` and `Command/{Channel,Provider,Model,Agent}.hs` — run either
inside one of those call sites or inside an HTTP request to an already
scaffolded `serve`. *(Re-verify at implementation; if a new CLI subcommand that
writes either file appears, seed from it too.)*

A documented wart left alone: `seal access-control reset --yes` on a fresh
install re-encodes `security.toml` into an empty document rather than leaving it
absent (`clearAccessControlSection` → `saveSecurityConfig`). Changing that is a
behaviour change to a documented command, so it is a follow-up, not part of this
PR; the scaffolder runs first, so the operator has already seen the template.

### The migration trap (two halves, both required)

`migrateSecurityConfig` has two behaviours keyed on `doesFileExist
security.toml` plus a **raw substring scan** of `config.toml` for
`legacyMarkers` (`Migrate.hs:56`, list at `:73-81`: `vault_path`,
`vault_recipient`, `vault_identity`, `vault_unlock`, `vault_key_type`,
`[untrusted_execution]`):

- Case 1 (`security.toml` absent, markers present) → migrate the values into
  `security.toml`, then rewrite `config.toml`.
- Case 2 (`security.toml` present, markers present, `Migrate.hs:60-67`) →
  `security.toml` wins; `cleanConfigToml` (`:113-117`) → `loadRuntimeConfig` +
  `saveRuntimeConfig` (`.tmp` + rename, `File.hs:610-615`), which **re-encodes
  the document and drops every comment**, and prints a "removed stale …" line.

Two hazards follow, and the plan defeats both:

1. **Creating `security.toml` converts Case 1 into Case 2**, silently discarding
   the operator's vault configuration. The writer consults the document itself
   (not call ordering) and skips `security.toml` while `config.toml` still
   carries legacy security fields. Implementation: export
   `configHasLegacySecurityFields :: Text -> Bool` from `Seal.Config.Migrate`
   (reusing `legacyMarkers`); the name is deliberately distinct from
   `Seal.Config.Security.hasLegacyLayout`, which inspects the other document.
2. **`config.toml`'s template must contain no `legacyMarker` substring at all —
   prose included.** So the `[untrusted_execution]`, `[untrusted_execution.
   remote]` and `[access_control]` headers belong to **`security.toml` only**;
   `config.toml`'s header points at `~/.seal/security.toml` without naming any
   `vault_*` key or that bracketed table. `runtimeConfigCodec` carries no
   security leaves, so a marker-free `config.toml` can still document every one
   of its keys. Guarded by W3.2 and W3.8.

### Which template carries which headers

| template | commented table headers it must contain |
|---|---|
| `config.toml` | `# [providers.<label>]`, `# [signal]`, `# [telegram]`, `# [web]`, `# [embedding]`, `# [delegation]`, `# [gateway]`, `# [workdir]` |
| `security.toml` | `# [untrusted_execution]`, `# [untrusted_execution.remote]`, `# [access_control]` |

### What is active vs. commented

Documented in both file headers, applied mechanically:

> A key is **active** only when its default is concrete, portable
> (machine-independent), read by some code path, *and* writing it resolves to
> exactly the behaviour of leaving the key out. Everything else is commented out
> with its default stated in the comment.

**`config.toml` — active:** `max_turns = 90`, `max_model_retries = 3`,
`model_retry_base_delay_ms = 1000`, `debug_session_transcript = false`,
`debug_model_responses = false`, `on_demand_schemas = false`,
`[retrieval] max_scan_bytes = 131072`, `[gateway] host = "localhost"`,
`port = 8080`, `allowed_origins = ["http://localhost:8080"]`, `tls = false`,
`[delegation]` (`max_concurrent_children = 3`, `child_timeout_seconds = 600.0`,
`max_spawn_depth = 3`, `orchestrator_enabled = true`), `[web]`
(`search_provider = "parallel"`, `search_max_results = 10`,
`searxng_url = "http://localhost:8888"`), `[skills] autoload = "seal-usage"`,
`available_skills = true`, `[agent]` (all five `true`), `[tool_timeout]`
(`default_seconds = 120`, `max_seconds = 600`, `retry_max = 3`,
`retry_base_micros = 2000000`, `retry_factor = 2.0`,
`kill_grace_micros = 5000000`, `max_output_bytes = 50000`,
`abort_poll_micros = 100000`), `[embedding] backend = "null"`.

Both float-typed keys are written as floats: `Toml.double` for `retry_factor`
(`File.hs:481`) and for `child_timeout_seconds` (`File.hs:504`).

**`config.toml` — commented:**

- `default_provider`, `default_model`, `default_agent`
- `# [providers.<label>]` `default_model`, `base_url`
- `# [signal]` `account`, `text_chunk_limit = 1998`, `allow_from`
- `# [telegram]` `token`, `text_chunk_limit = 3900`, `allow_from` (the token is
  stored in the vault by the setup wizard, so the key is documented, not
  written)
- `# [gateway]` `ws_port` (deprecated but still decoded), `static_dir`,
  `tls_cert`, `tls_key`, `tls_hosts = []`
- `# [web]` `search_endpoint`, `search_allow_list = []`,
  `fetch_allow_list = []`, `search_auth_key`, **`max_fetch_bytes`** — its
  effective default is *derived* (`wfcMaxBytes = unwrapOpt wcMaxFetchBytes
  webCfg operatorCeiling`, `TurnEngine.hs:355`, with `operatorCeiling` =
  `[retrieval] max_scan_bytes`), so writing it would freeze that coupling
- `# [embedding]` `binary_path`, `index_path` (machine-absolute defaults)
- `# [delegation]` `provider`, `model`, `base_url`, `api_key`, `api_mode`,
  **`subagent_auto_approve`** — *reserved: not read by any code path yet*
  (`Delegation.hs:135-138`)
- `# [workdir]` **`cleanup_on_exit`** — *reserved: `wdcCleanupOnExit` is
  decoded but not read by any code path* (`File.hs:324,535`), so it gets the
  same marker rather than being shipped as a live knob that does nothing

**`security.toml` — active:** `vault_key_type = "x25519"` (`Serve.hs:604`),
`vault_unlock = "on_demand"` (`Vault/Backend.hs:230-233`).

**`security.toml` — commented:** `vault_path`, `vault_identity` (their defaults
are `<SEAL_HOME>`-derived absolute paths — writing them would bake this
machine's home into an otherwise portable file); `vault_recipient` (unset until
`seal vault setup`); `# [untrusted_execution]` (`mode = "local"`) and its
`# [untrusted_execution.remote]` block (`host`, `user`, `port = 22`,
`identity`, `known_hosts`, `workspace` — `Security.hs:419-426`);
`# [access_control]` (`mode`, `origin`, `rp_id`).

Why `[untrusted_execution]` is not active: it is **not** inert under a build
flag. With `-f remote-only-untrusted`, an absent section yields
`isRemoteExec = False` whereas `mode = "local"` yields `Just UemRemote`
(`Security.hs:658-665`, `Serve.hs:338-341`). A documentation file must not
change behaviour conditionally on how the binary was built.

Why `[access_control]` is not active: absence means *unconfigured* and
fail-closed, and `BootPlan` mints its enrollment grant from exactly that absence
(`mintFor`, `BootPlan.hs:251-260`); `mode = "none"` is an explicit waiver only a
human writes. The header states that enrolled passkeys live in
`~/.seal/credentials.toml`.

Both headers state that Seal re-encodes these files when it writes them, so
comments do not survive the first programmatic write.

### File modes

- `security.toml`: `writeSecretFile` into `path <> ".tmp"` (0600 at creation,
  `O_NOFOLLOW`; `Security.hs:511`), then `renameFile` — the pattern
  `saveSecurityConfig` already uses (`Security.hs:480`).
- `config.toml`: `.tmp` + `renameFile` (`File.hs:610-615`).

## Work units

### W1 — `localhost` default, `setHost` wiring, host validation

| # | Change | DoD |
|---|---|---|
| 1 | `Gateway/Config.hs:28,52`: `gcHost = "localhost"` + field comment | `test/Seal/Gateway/ConfigSpec.hs:16,21` updated |
| 2 | `Gateway/Server.hs`: `warpSettingsFor :: GatewayConfig -> Settings` applying `setPort` **and** `setHost (fromString (T.unpack (gcHost cfg)))`, used by both arms (`:306,312-313`); added to the module's export list and `setHost`/`getHost` added to its `Network.Wai.Handler.Warp` import | extend the **existing** `test/Seal/Gateway/ServerSpec.hs` (already wired: `seal-harness.cabal:457`, `test/Main.hs:28`): `getHost (warpSettingsFor defaultGatewayConfig) == fromString "localhost"`, and `== fromString "0.0.0.0"` for `gcHost = "0.0.0.0"`. If `getHost` is not exported by the pinned warp, stop and report |
| 3 | `Gateway/Config.hs`: `gatewayHostError`, `hostResolves`, `gatewayHostResolutionError` (all exported); called in `Serve.hs` beside `tlsConfigError` (`:178`), before any bind | in `test/Seal/Gateway/ConfigSpec.hs`: pure refuse `""`, `" "`, `"http://localhost"`, `"[::1]"` — each message names `[gateway] host`; pure accept `"localhost"`, `"0.0.0.0"`, `"::1"`, `"seal.lan"`; injected resolver `const (pure False)` → `Just` naming `[gateway] host`, `const (pure True)` → `Nothing`; `hostResolves` returns `True` for `"127.0.0.1"`, `"0.0.0.0"`, `"::1"` (numeric, no DNS) and for `"localhost"` (NSS/hosts; `pendingWith` if the environment resolves neither). The libc-failure mapping itself is exercised only through the seam — stated in a code comment |
| 4 | `Types/Config.hs:32`: `_serverConfig_host = "localhost"` (the `--print-config` / `--server-host` legacy surface, **not** wired to the gateway) | new assertion in `test/Seal/ConfigSpec.hs` (the module that already imports `Seal.Types.Config`; the file currently holds one round-trip test) |
| 5 | `src-chat-channels/Seal/Channels/Chat/Types.hs:130-134`: chat-client host + `gcApiBase` + `gcWsUrl` | `test/Seal/Channels/Chat/TypesSpec.hs:97` updated |
| 6 | `make check` green (`build test lint frontend-test`, `Makefile:35`) | no frontend source change expected; the frontend suite is part of the gate |

### W2 — Templates, writer module, call sites, minimal API widening

| # | Change | DoD |
|---|---|---|
| 1 | `config/templates/{config,security}.toml` per the active/commented rule, the per-file header table, and a marker-free `config.toml` | W3.1–W3.5 |
| 2 | `src/Seal/Config/Templates.hs`: two embedded `Text` values + `ensureConfigTemplates` returning `(created, warnings)`; parent-dir creation and write inside one per-file handler; never throws | in `seal-harness.cabal` `exposed-modules` (alphabetical, after `Seal.Config.Security`) |
| 3 | `Seal.Config.Migrate`: export `configHasLegacySecurityFields`; `ensureConfigTemplates` skips `security.toml` while `config.toml` carries legacy fields | W3.8 |
| 4 | The three call sites (Serve, Tui, `Command.AccessControl`); created paths logged at Info, warnings at Warning, boot continues either way | W3.7 (failure path) + W3.9 |
| 5 | `Seal.Config.File`: export `ToolTimeoutFileConfig (..)` (siblings already exported; without the constructor the fully-populated `[tool_timeout]` sample cannot be built) and promote the retry fallbacks that are literals at `TurnEngine.hs:1026,1033` to exported `defaultMaxModelRetries` / `defaultModelRetryBaseDelayMs`, used at both sites | W3.3 compiles; W3.5 compares against those constants |

### W3 — Tests (`test/Seal/Config/TemplatesSpec.hs` + wiring)

1. Both templates parse (`Toml.parse`) **and decode** (`loadRuntimeConfig` over a
   temp-dir copy / `decodeSecurityConfig` directly) — decoding, not parsing,
   catches type mismatches.
2. `configHasLegacySecurityFields configTomlTemplate == False`. (The check does
   not apply to `security.toml` — that is the file those keys belong to.)
3. **Discoverability of keys.** One sample `RuntimeConfig` with every field
   `Just` (providers with one label; `[signal]`/`[telegram]` with `AllowOnly` so
   `allow_from` is emitted) and one sample `SecurityConfig` with every field
   `Just`; encode through the exported `runtimeConfigCodec` /
   `securityConfigCodec`; `tomlKeyPaths` the result; assert every **leaf key
   name** appears in the corresponding template. Leaf names only: the providers
   path carries the sample label, which no placeholder can contain. Covers every
   nested codec without a new codec export. Credential keys are out of scope by
   construction (`securityConfigCodec` has no credentials field).
4. **Header discoverability.** `config.toml` contains the literal
   `# [providers.<label>]`, `# [signal]`, `# [telegram]`, `# [web]`,
   `# [embedding]`, `# [delegation]`, `# [gateway]`, `# [workdir]`;
   `security.toml` contains `# [untrusted_execution]`,
   `# [untrusted_execution.remote]`, `# [access_control]`, plus the six remote
   key names inside that block. (A key name in prose is not a copy-pasteable
   block, and `tomlKeyPaths` omits table nodes.)
5. **Resolved-behaviour equivalence** with an absent file, on resolved values:
   - `maxTurnsConfig`, `toolTimeoutConfig` vs `defaultToolTimeoutConfig`,
     `retrievalMaxScanBytes`, `onDemandSchemas`, `resolvedAutoloadSkill`,
     `resolvedAvailableSkills`, the five `[agent]` resolvers;
   - `maybe defaultGatewayConfig withGatewayDefaults (rcGateway tpl)` vs
     `defaultGatewayConfig`;
   - `resolveDelegationConfig (fromFileConfig (rcDelegation tpl))` vs
     `resolveDelegationConfig (fromFileConfig Nothing)` (both exported), plus
     `rcDelegation tpl >>= dfcSubagentAutoApprove == Nothing`;
   - `rcDebugSessionTranscript == Just False`, `rcDebugModelResponses == Just
     False`, `rcMaxModelRetries == Just defaultMaxModelRetries`,
     `rcRetryBaseDelayMs == Just defaultModelRetryBaseDelayMs` (the `Just
     True`-gated behaviour is `TurnEngine.hs:1010,1017`);
   - **the commented sections stay absent**: `rcSignal == Nothing`,
     `rcTelegram == Nothing`, `rcProviders == Map.empty`,
     `rcDefaultProvider/Model/Agent == Nothing`, `rcWorkdir == Nothing` — the
     mirror of W3.6's `scAccessControl == Nothing` guard, so an accidentally
     live `text_chunk_limit` under `# [signal]` fails;
   - `rcWeb tpl == Just (WebConfig Nothing Nothing Nothing Nothing (Just
     "parallel") (Just 10) (Just "http://localhost:8888") Nothing)` — a literal
     pin, because `unwrapOpt` lives in `TurnEngine` and is not exported; values
     cite `TurnEngine.hs:344-350`, `Search.hs:362`, `SearXngSetup.hs:21`;
   - `rcWeb tpl >>= wcMaxFetchBytes == Nothing` (the derived-ceiling decision);
   - `rcEmbedding tpl == Just (EmbeddingConfig (Just "null") Nothing Nothing)` —
     a literal pin, documented as such (`src/Seal/Memory/EngramBackend.hs:137-146`).
6. `security.toml`: `scAccessControl == Nothing` (never pre-configured);
   `scVaultKeyType == Just "x25519"`; `parseUnlockMode (scVaultUnlock tpl) ==
   parseUnlockMode Nothing`; `scUntrustedExec == Nothing`.
7. Writer: creates both when absent (two entries in `created`, no warnings);
   second call is a no-op (`created == []`); a pre-seeded file is not modified;
   `security.toml` is mode 0600; parent dirs are created; a write failure is
   reported in `warnings` rather than thrown — point `spConfig` at a path whose
   parent is a regular file and assert one warning, `config.toml` absent from
   `created`, and `security.toml` still created (per-file independence).
8. **Migration interaction, end to end.** In a temp `SEAL_HOME`: (a) seed both
   templates, run `migrateSecurityConfig`, assert both files byte-identical (no
   comment stripping, no false migration); (b) legacy `config.toml` with
   `vault_*` fields and no `security.toml` → `ensureConfigTemplates` does not
   create `security.toml`; `migrateSecurityConfig` then moves the values; a
   second `ensureConfigTemplates` leaves the migrated file untouched.
9. **Call-site guards** (precedent: `embedFile` in the test suite,
   `WebAuthnSpecFixture.hs:76`). Embed three sources with `$(embedFile …)` and
   assert, using last-occurrence positions so imports cannot interfere:
   - `Command/Serve.hs`: `ensureConfigTemplates paths` occurs after
     `migrateSecurityConfig paths`, and `gatewayHostResolutionError` occurs
     before the last `runGateway logger` (the call, not the comments above it);
   - `Tui.hs`: `ensureConfigTemplates paths` occurs after
     `migrateSecurityConfig paths`;
   - `Command/AccessControl.hs`: `ensureConfigTemplates paths` occurs.

   A deleted call site, a reordering, or a reverted `setHost` wiring fails the
   gate.

Wire `Seal.Config.TemplatesSpec` into `test/Main.hs` and the cabal test-suite
`other-modules`.

### W4 — Docs

- `README.md`: `[gateway] host` default is `localhost` and *does* bind; an
  unusable `host` refuses to boot; the WS allowlist now names only `localhost`;
  the first run writes both template files (an existing file is never replaced);
  exposing a gateway (`host = "0.0.0.0"`, README:300).
- `CHANGELOG.md`: entry for both changes with an **Upgrading** list — listener
  loopback-only unless `host` says so; `host` is now validated (was cosmetic);
  `http://127.0.0.1:<port>` loses its WebSocket handshake; `localhost` may
  resolve to `::1` first, so a client hardcoded to `127.0.0.1` may need the
  name; templates are written once and never overwritten, so existing installs
  get none; `host = "*"` (a wildcard spelling the old code accepted implicitly)
  is now refused as unresolvable — use `"0.0.0.0"` or `"::"`.
- `docs/superpowers/specs/2026-07-22-remote-enforcement-tamper-proof-design.md`:
  correct the two statements this change falsifies — line 128 ("The Gateway
  binds `127.0.0.1` by default") and the refusal-table row at line 563 ("bind
  `127.0.0.1`") — to `localhost` plus "and `[gateway] host` is the bind".
- Fix the three stale `max_spawn_depth` comments that say "Default 1 (flat)" or
  "default 1, clamped to [1,3]" when the real default is 3
  (`Delegation.hs:164`): `File.hs:192`, `Delegation.hs:23`, `Delegation.hs:123`.

## Files touched

`seal-harness.cabal`, `config/templates/{config,security}.toml`,
`src/Seal/Config/Templates.hs`, `src/Seal/Config/Migrate.hs`,
`src/Seal/Config/File.hs` (exports + comment), `src/Seal/Core/TurnEngine.hs`
(two literals → constants + their use sites), `src/Seal/Gateway/Config.hs`
(default + host validation), `src/Seal/Gateway/Server.hs` (export list, imports,
`warpSettingsFor`), `src/Seal/Types/Config.hs`, `src/Seal/Command/Serve.hs`,
`src/Seal/Command/AccessControl.hs`, `src/Seal/Tui.hs`,
`src/Seal/Agent/Runtime/Delegation.hs` (comments only),
`src-chat-channels/Seal/Channels/Chat/Types.hs`, `test/Main.hs`,
`test/Seal/Config/TemplatesSpec.hs`, `test/Seal/ConfigSpec.hs`,
`test/Seal/Gateway/ConfigSpec.hs`, `test/Seal/Gateway/ServerSpec.hs`,
`test/Seal/Channels/Chat/TypesSpec.hs`, `README.md`, `CHANGELOG.md`,
`docs/superpowers/specs/2026-07-22-remote-enforcement-tamper-proof-design.md`.

## Risks and rollback

- **The listener narrows** (the point of the change). A LAN/tailnet gateway that
  relied on the implicit wildcard bind must set `host = "0.0.0.0"`.
- **`host` becomes fallible**: malformed or unresolvable values refuse to boot
  before any bind, with a message naming the key (W1.3).
- **`http://127.0.0.1:<port>` loses its WS handshake** — the allowlist no longer
  contains it; documented, and moot in passkey mode.
- **`localhost` may resolve to `::1` first**, so `127.0.0.1` may stop answering.
- **Template drift** — guarded by W3.3/W3.4 (keys and headers documented), W3.5
  (every written default resolves like the absent key, and the commented
  sections stay absent), and W3.8 (byte-identical through the migration path).
- **Comment loss on rewrite** is pre-existing; stated in the templates' headers.
- **Rollback.** Configuration-revertible without a rebuild: set
  `host = "127.0.0.1"` (or `"0.0.0.0"`); delete either template to return to
  absent-file behaviour. Templates persist across a downgrade and every key in
  them is one those codecs already knew, but an older build has no `setHost`, so
  a written `host = "localhost"` would not bind — the one behaviour that
  silently reverts on downgrade.

## Out of scope (follow-ups to file, not part of this PR)

- **`legacyMarkers` is a substring scan** (`Migrate.hs:56,73-81`), so *any*
  mention of a `vault_*` key or `[untrusted_execution]` in a `config.toml`
  comment — including one an operator writes later — triggers the migration
  branch. This plan works around it; the structural fix (decode, then inspect
  keys) deserves its own issue, because that branch also deletes comments.
- `seal access-control reset --yes` creating an empty `security.toml` on a fresh
  install (see "Never overwrite").
- `--server-host` (the `Configuration.Utils` surface in `Seal.Types.Config`) is
  not wired to the gateway; only its default value is aligned.
- The frontend e2e fixture keeps writing `host = "127.0.0.1"` and pre-writes both
  files, so the new writer is a no-op there.
- No comment-preserving TOML writer.
