# Learnings — generic OpenAI-compatible provider (#271)

Date: 2026-10-19 · PR #272 · Plan:
`docs/superpowers/plans/2026-10-19-openai-compat-provider-plan.md`

## What went well

- **Splitting the rename from the behaviour** (`git mv` + identifier rename
  first, transport second) made the 3 200-test suite a reliable oracle: commit
  1 was provably behaviour-free, so any later failure was the new code's.
- **The catalog seam paid for itself during the work, not after.** Adding
  `parseProviderIn`/`configuredProvidersFor` and a synthetic preset row let the
  "a vendor is one row" claim be *tested* with zero shipped presets. Without
  it, every preset-path assertion would have required shipping step 3 early.
- **The wire-level `warp` mock replaced a test that was silently doing real
  HTTPS** (`complete` with no key hit `https://openrouter.ai` once the guard was
  removed, and still passed). Loopback-only mock tests are cheap, fast, and
  catch wiring bugs a pure test cannot (e.g. "no `Authorization` header on the
  wire").
- **Ordering the config migrations was the highest-value review finding.** The
  provider migration re-encodes `config.toml` through the `RuntimeConfig`
  codec, which does not model `vault_*`/`[untrusted_execution]`. Running it
  before `migrateSecurityConfig` would have silently downgraded `mode=remote`
  to local. That is now an explicit test.
- **Blank-vs-cancel** in the interactive add flow: `""` is a legitimate value
  at optional prompts (keep default / no key) and an abort at required ones.
  Conflating them (the first draft did) would have made `/provider add ollama`
  with blank answers silently write an empty URL.

## Gotchas worth remembering

- `HeaderName` is `CI ByteString`, not `ByteString`. A spec row's "extra
  headers" must use `HeaderName` (OverloadedStrings makes literals work).
- `requestMethod`/`pathInfo`/`requestHeaders` come from **`Network.Wai`** (the
  server's `Request`), not `Network.HTTP.Client`.
- `http-client`'s `redirectCount = 0` surfaces a redirect as
  `HttpExceptionRequest _ (TooManyRedirects _)`; map it to a dedicated
  **non-transient** message or `isTransientError`'s "transport error" wording
  makes the loop retry it.
- Warp's `testWithApplication` gives an ephemeral loopback port — no DNS, no
  egress, and the `pathInfo` is the split path (`["openai","v1","chat","completions"]`).
- `Seal.Agent.Runtime.Registry > agentStatus > records Crashed when the worker
  throws` is flaky under full-suite load (passes alone). Re-run `cabal test`
  before believing a red `make check`.
- `make check` is `build → frontend-build (tsc && vite build) → cabal test →
  hlint`; vitest is **not** in it. `make frontend-test` is now the target.
- A `Maybe ModelId` ripple is not mechanical: three call sites were
  *behaviours* (seeding must not write `""`; `/model use <p>` with no model must
  refuse rather than write `""`; `new` must repair an inherited `""`).
- `ProviderDetail` fixtures in the frontend tests are typed, so adding required
  fields breaks `tsc` (which `make check` runs) — update the `makeProvider`
  factory in the same commit.

## Process notes

- The design gate ran 3 rounds (5 reviewers) and the plan gate 3 rounds
  (3 reviewers); every round found real defects, and the last round found only
  mechanical ones. Splitting the gateway hardening out (design §14) was the
  single biggest scope correction — it turned a two-feature PR into one.
- Reusing the *existing* private security note channel (instead of a public
  issue) for the pre-existing gateway exposure matched AGENTS.md §Security.
