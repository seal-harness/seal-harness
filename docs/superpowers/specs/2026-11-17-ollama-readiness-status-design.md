# Ollama provider readiness: stop reporting "Configured" when nothing is installed

Status: approved (design review gate — 5/5 reviewers, 7 rounds)
Date: 2026-11-17

**Revision log.** This design went through six adversarial review rounds; the
per-round history lives in the PR description. Two defects are worth keeping
because both were *empirically* wrong rather than merely unclear, and both were
caught by executing code rather than reading it:

1. **The refusal rule.** An earlier draft matched the substring `refused`
   against `ioeGetErrorString`. Measured on GHC 9.12 / http-client 0.7.19
   against a real closed port:

   ```
   real refusal:  type=NoSuchThing  msg="does not exist"  errno=Just 61
   DNS failure:   type=NoSuchThing  msg="does not exist"  errno=Nothing
   ```

   The two are **byte-identical** in type and message; only errno separates
   them. The message-matching rule would have made `Not Running` unreachable,
   re-creating the bug this design exists to fix. See D3.1.

2. **The bracketed-IPv6 SSRF floor.** `extractHost` truncates at the first
   `:`, so `[fd00:ec2::254]` becomes `[fd00` and the `fd00:ec2::254` entry in
   `alwaysBlockedIps` is unreachable dead code. An earlier draft deferred the
   fix to a follow-up while claiming test coverage for it. See D2.2.

## Problem

A keyless local Ollama is treated as **configured** by config inspection alone:

```haskell
-- src/Seal/Providers/Registry.hs:357
OllamaProvider -> do
  let baseUrl = fromMaybe defaultOllamaBaseUrl (providerBaseUrl cfg "ollama")
  if not (ollamaNeedsKey baseUrl) then pure True   -- never inspects the machine
                  else hasVaultKey mvh (vaultKeyName OllamaProvider)
```

`ollamaNeedsKey` is only a substring test for `ollama.com`
(`src/Seal/Providers/Ollama.hs:97`). So on *any* machine — daemon absent,
uninstalled, or holding no models — `configured` is `True`.

Four user-visible surfaces consume it:

| Surface | Code | Renders | WU |
|---|---|---|---|
| Provider dropdowns (`ProviderModelFields`, `AgentsView`, `NewSessionComposer`) | `GET /api/providers` → `providerInfoJson` (`API.hs:700`) | Ollama offered as usable | A |
| Providers CRUD list | `GET /api/providers/all` → `providerAuthStatus` (`API.hs:3213`) | badge reads **Keyless** | A |
| First-run setup wizard card | `Setup.State.providerCards` (`State.hs:294`) | pill reads **configured** | A |
| TUI `/provider list` | `Command/Provider.hs:249` | `ollama — auth: none (local)` | A |

## Goal

The word "configured" must not assert usability when the thing it needs is
absent. Report a second, observed axis for Ollama: **readiness**.

## Non-goals

- Changing provider resolution, request encoding, or `ollamaResponseTimeoutMicro`.
- Readiness probes for `anthropic`/`openrouter`/`openai`. Remote HTTPS
  endpoints; config + credential genuinely is their whole story.
- Installing or managing Ollama.
- **Readiness for custom OpenAI-compatible instances** (including a `localhost`
  `base_url`). Identical failure mode, known sibling of this bug, probe
  machinery generalises. Tracked as a follow-up (see Closing).
- **Retained copy** (still accurate, unchanged): `hooks/useNewTabSpec.ts:273`,
  `components/ProviderModelFields.tsx:78`, `components/NewSessionComposer.tsx:98`.
- `src/Seal/Session/Kind.hs` needs **no change**: `inferProviderId` is a
  model-prefix heuristic that never consults provider state.

## Decisions

### D1. `configured` stays config-only; readiness is additive

`configured` is load-bearing for the blocking first-run gate
(`classifyProvider` P1 → `required_complete`) and for the dropdown
selectable-provider filter. If a non-answering daemon set it false, a daemon
restart would re-open the blocking gate and eject Ollama from every dropdown —
a cosmetic bug turned availability bug.

- `configured` — operator intent. Unchanged semantics and call sites.
- `readiness` — observed reality. New, additive, Ollama-only.

`ProvidersView`'s list filter is `p.authStatus !== 'none'`, **not**
`configured`; unchanged, so a `Not Running` Ollama stays a visible row.

### D2. The probe: keyless, floored, bounded, out of band

**D2.1 — Keyless, always.** Headers come from `ollamaHeaders Nothing` only. The
probe must not import or call `withHeaders`/`resolveProvider`/`listSome`.
`withHeaders` (`Ollama.hs:537`) attaches the vault key whenever `ollamaNeedsKey`
is true — a substring test, so `base_url = "http://ollama.com.attacker.tld"`
both selects the keyed path and ships the vault key there. Today that needs a
deliberate `POST /api/providers/:name/test`; on a polled endpoint it fires
unattended.

**D2.2 — SSRF floor, with the `extractHost` fix pulled into this PR.**

Reject when `Seal.Web.UrlSafety.isAlwaysBlockedUrl` is true; set
`redirectCount = 0`. Use `isAlwaysBlockedUrl` (pure, metadata-only,
`UrlSafety.hs:99`) and **not** full `isSafeUrl`, which blocks loopback/private
and would kill the primary use case.

Rev 5 said "normalise the host, then consult the floor". **That does not work**,
because the truncation happens *inside* the function being consulted:
`extractHost` (`UrlSafety.hs:227-231`) does `T.takeWhile (/= ':')` on the
authority, so `[fd00:ec2::254]` → `[fd00` and the `fd00:ec2::254` entry in
`alwaysBlockedIps` (`UrlSafety.hs:58-65`) is **unreachable dead code today**
(verified). Deferring this to a follow-up while claiming test 22 pins the IPv6
rejection would be a false claim of protection.

Therefore this PR fixes `Seal.Web.UrlSafety.extractHost` to parse the authority
**bracket-aware and userinfo-stripped**:

- strip everything up to the last `@` in the authority (userinfo);
- for a `[...]` authority, take the bracketed literal as the host (keeping the
  brackets off the value compared against `alwaysBlockedIps`);
- otherwise take up to the first `:` (the port), as today.

This is pure and small, makes the existing metadata list entry live, and fixes
`Seal.Web.Fetch` symmetrically. `extractHost` is **not** exported (the module
exposes only `isSafeUrl`, `isAlwaysBlockedUrl`, `UrlSafetyError`,
`renderUrlSafetyError`), so the new cases are written through the public
surface in `UrlSafetySpec` — no export widening:
`isAlwaysBlockedUrl "http://[fd00:ec2::254]/x"` and
`isAlwaysBlockedUrl "http://x@169.254.169.254/"` must become `True`
post-fix, `"http://169.254.169.254:80/"` is already `True`, and the
loopback/private-must-still-pass cases go through `isSafeUrl`.
`probeTargetFor` (D6.1) then reuses the fixed helper; test 22 asserts the
end-to-end rejections. While editing, tighten `isAlwaysBlockedUrl`'s
`any (T.isPrefixOf host) alwaysBlockedIps` to exact `elem` — `preCheck` and
`isSafeHost` already use `elem`, and with ports/userinfo/brackets now stripped
by `extractHost` the prefix match only invites harmless-but-confusing
collisions like `fd00:ec2::2540`. Add one assertion pinning the
`Seal.Web.Fetch`-facing consequence, since the design claims that fix rides
along: `isSafeUrl "http://x@192.168.1.1/"` must be `Left (UseBlockedIp …)`
rather than today's accidental `Left UseDnsFailed`.

*Recorded residual:* `isAlwaysBlockedUrl` does no DNS resolution, so a name
resolving to a metadata IP passes (rebinding). Accepted because D2.1 means no
credential is sent, D2.3 bounds the body, and only an 8-value enum escapes —
this is a blind connect oracle, not a metadata read. The DNS-resolving variant
stays a follow-up (Closing #3), now scoped to *only* that.

**D2.3 — Bounded body, read in a loop.** `withResponse` + an **accumulating**
`brReadSome` loop until `BS.empty` or 256 KiB. Reaching the cap is
`OpeBadResponse` (fail closed), never a decode of the prefix. A single
`brReadSome` may return short and would truncate a healthy remote daemon into
permanent `unknown`. Model the loop on `sendChatStream` (`Ollama.hs:474-481`),
the request on `Ollama.hs:453-460`. Do **not** reuse `listTags`, which is
`httpLbs` whole-body with no cap (`Ollama.hs:403-420`).

**D2.4 — Out of band, never inline.** A request handler never performs the
outbound call: it reads a cached `IORef` and returns. Removes Warp worker
exhaustion, the latency timing oracle, and browser-triggered egress.

**D2.5 — Warm at startup; refresh on read; refetch on focus.** Neither
`/api/providers` nor `/api/setup` is interval-polled (`useAllProviders`,
`useSetupState`: mount + mutation only), so stale-while-revalidate alone would
leave a healthy daemon blank indefinitely. Therefore:

- gateway kicks the first probe **at startup** (`Serve.hs`, non-blocking,
  before `runGateway`);
- `oprReadiness` returns the last known good value immediately and **kicks an
  async refresh if older than 30 s** — this makes the post-mutation refresh
  implicit, so handlers never need `oprRefresh` (closes arch S1);
- frontend re-fetches on window focus.

`oprRefresh` remains for the startup warm only.

**D2.6 — Single-flight, atomic.** One in-flight probe per normalised base URL;
global cap 1. State must be updated atomically (`atomicModifyIORef'` or a
`TVar`), never read-then-write — this repo has already been bitten by exactly
that race (`claimToolCallIds`, `Ollama.hs:399`). A TTL alone is not a rate
limiter: a writer of `base_url` invalidates a URL-keyed cache per request. Cap
1 means one stuck 2 s probe delays another URL's refresh by up to 2 s —
accepted.

**D2.7 — Timeout.** 2 s per probe, not the provider's 5-minute
`ollamaResponseTimeoutMicro`.

**D2.8 — URL shape (load-bearing, not decorative).** Refuse non-`http(s)`
schemes, and refuse URLs carrying userinfo. This closes a real bypass:
`extractHost` (`UrlSafety.hs`) does `T.takeWhile (/= ':')` on the authority
without stripping `@`, so `http://x@169.254.169.254/api/tags` yields host `x…`
and slips past the floor. Tested explicitly (test 22).

**D2.9 — Manager: the provider manager, never `gatewayManager`.** (Critical;
new in rev 4.) `gatewayManager` (`Serve.hs:874-882`) installs
`managerModifyRequest = pure . authorize`, which stamps
`Authorization: Bearer <gateway service token>` onto **every** request. Building
the probe on it would ship that token to an operator-set `base_url` — worse than
the vault key D2.1 already forbids. The probe takes the provider manager
(`Serve.hs:316`, surfacing as `adHttpManager`, `API.hs:221`). Tests 24/25 must
assert against the real `listTagsDetailed`, not a stub, because a pure
header-construction test cannot observe `managerModifyRequest`.

This critical invariant is pinned by **two** tests, because a structural
assertion on `probeTargetFor` alone cannot observe manager-level header
injection: test 24 (the loopback listener captures the actual request headers
and asserts no `Authorization` arrives) and test 25 (the probe is constructed
from `adHttpManager` — the `mgr` from `Serve.hs:316` — and never from
`gatewayManager`).

**D2.10 — Each refresh re-reads config.** The pass re-reads
`providerBaseUrl cfg "ollama"` (mirroring `adProviders`, `Serve.hs:662-672`) so
a `base_url` change lands without a restart, and the single-flight key is the
URL **normalised** with `stripTrailingSlash` (`Ollama.hs:104`).

### D3. States and what may be claimed

```haskell
data OllamaReadiness
  = RdPending                -- no probe has completed yet in this process
  | RdUnknown                -- a probe ran and failed unexplainably
  | RdNotInstalled           -- loopback URL, no binary found, nothing listening
  | RdNotRunning             -- loopback URL, connection REFUSED
  | RdNoModels               -- daemon answered, zero models
  | RdNoFittingModel         -- daemon answered, models exist, none usable (advisory)
  | RdReady !Int             -- N usable models (cloud ∪ fitting); n >= 1
  | RdCloud                  -- ollama.com: no probe performed
  deriving stock (Eq, Show)
```

`RdReady 0` is excluded by construction: zero usable models is `RdNoFittingModel`
(the usable set is non-empty exactly when this constructor is used).

**D3.1 — "Not running" requires evidence, and the mechanism is specified.**

http-client has no typed "refused": a refusal surfaces as
`HttpExceptionRequest _ (ConnectionFailure e)`. Rev 5 proposed matching the
message text for `"refused"`; **that is empirically wrong on this toolchain**
(measured: `ioeGetErrorType = NoSuchThing`, `ioeGetErrorString = "does not
exist"`, so the rule never fires and `RdNotRunning` becomes unreachable —
re-creating the very bug this design fixes). Rev 5's premise about GHC's errno
table was also backwards; there is no CPP guard, so Linux behaves the same.

Discriminate on **errno**, which is the value GHC curates from the failed
`connect(2)`:

```haskell
data OllamaProbeError
  = OpeRefused       -- ONLY: ConnectionFailure with ioe_errno == eCONNREFUSED
  | OpeBlocked       -- refused by the SSRF floor / URL-shape check, before any request
  | OpeTimeout
  | OpeBadResponse   -- something answered, but not with Ollama's JSON (or >256 KiB)
  | OpeHttp !Int     -- non-2xx status (a 3xx lands here: see below)
  | OpeOther         -- any other transport failure (reset, TLS, DNS, non-IOError)
  deriving stock (Eq, Show)

classifyProbeFailure :: HttpException -> OllamaProbeError
```

The rule, in a pure separately-tested function. Note `ConnectionFailure` carries
a `SomeException`, **not** an `IOException`, so the payload must be unwrapped
explicitly — matching `ConnectionFailure (ioe :: IOException)` directly does not
typecheck (`Couldn't match expected type SomeException with actual type
IOException`). The compilable form, verified to build and behave:

```haskell
classifyProbeFailure :: HttpException -> OllamaProbeError
classifyProbeFailure (HttpExceptionRequest _ (ConnectionFailure se)) =
  case fromException se :: Maybe IOException of
    Just ioe -> case ioe_errno ioe of
      Just n | Errno n == eCONNREFUSED -> OpeRefused
      _                                -> OpeOther   -- reset, TLS, no errno
    Nothing -> OpeOther          -- not an IOError at all
classifyProbeFailure _ = OpeOther
```

`OpeRefused` **iff** `ioe_errno ioe == Just n` and `Errno n == eCONNREFUSED`.
Everything else — `eCONNRESET`, timeout, TLS, DNS — is a non-refusal error →
`RdUnknown`. The trailing `classifyProbeFailure _ = OpeOther` is an
**intentional fail-safe**, not an oversight: it absorbs any future
`HttpException` shape (e.g. `InvalidUrlException`) as "do not claim to know".
One catch-all is right here rather than per-cause constructors — reset, TLS and
DNS all collapse to the same `RdUnknown`, and TLS failures are not cleanly
errno-identifiable anyway (they arrive as a non-`IOError` payload → `Nothing`).
Per-cause diagnostics, if ever wanted, belong on a debug log path, not in the
readiness ADT. (`ioe_errno` is in `GHC.IO.Exception`; `eCONNREFUSED` in
`Foreign.C.Error`. Both come from `base` alone, with no CPP platform guard, so
`ioe_errno` is GHC-portable rather than macOS-only.)

errno is required rather than the message for two reasons: the message is
locale-dependent libc stringdata, and only errno is unit-testable purely.
It also separates the dangerous look-alike: a **DNS failure** yields
`ioe_errno = Nothing`, so an unresolvable *remote* host can never masquerade as
a local refusal.

**Redirects.** `redirectCount = 0` does **not** throw `TooManyRedirects` —
http-client returns the 3xx response (verified). So rev 5's
`OpeTooManyRedirects` constructor was unreachable decoration and is dropped; a
3xx simply lands in `OpeHttp 3xx` → `RdUnknown`, which is the correct outcome.
"Redirects are never followed" is pinned by an assertion that the listener sees
exactly **one** request, not by expecting an exception.

Anything not positively identified as a refusal is `RdUnknown` — rev 1 collapsed
all of these into `RdNotRunning`, reproducing the original bug in a new label.

**D3.2 — Credential override first, and only when readiness exists.**

```
if readiness ∈ {pending}                                       → readiness slot empty,
                                                                  auth badge only
elif readiness present and authStatus ∈ {none, vault-locked}    → BOTH badges
elif readiness == cloud                                        → BOTH badges
elif readiness present and specific                            → readiness REPLACES auth badge
else (readiness absent)                                        → existing AUTH_STATUS_LABELS badge
```

The replacing set is therefore exactly
`{unknown, not-installed, not-running, no-models, no-fitting-model, ready}`
— enumerated rather than called "local state", which rev 3 left undefined.
`pending` is checked **first** and renders no readiness badge, so the
"BOTH badges" branches never promise a badge the label table says is blank (a
`pending` + `vault-locked` Ollama — reachable for an `ollama.com` base URL with
a locked vault — shows only the auth badge). The `readiness is present` guard
matters: without it the credential clause fires for `anthropic`/`openrouter`/
`openai` rows that have no readiness at all, drawing a blank second badge on the
most common credential-problem case (vault-locked Anthropic is already exercised
by `ProvidersView.test.tsx:216-217`).

**D3.3 — Path presence is not installation.** `findExecutable` inspects *this*
process's PATH; a Docker-hosted daemon on default loopback or an install outside
this PATH would both mislabel. So: the label is **`Ollama Not Found`**, its hint
names PATH and Docker, and the binary result refines wording **only** for the
default `localhost:11434` URL.

**D3.4 — Loopback aliases are the same host.** `127.0.0.1`, `[::1]` and
`localhost` (any port) all count as loopback for *state* purposes, so the
`ollama serve` remedy appears for the very common `127.0.0.1:11434` spelling —
not just the exact default string. This is why D6.1 splits host kind from
binary wording.

**D3.5 — `RdNoFittingModel` is advisory, never a verdict, never a gate.** See D5.

### D4. Labels: one table per surface, parameterised

The wire carries the state enum plus an optional usable count; no free text.

```ts
// frontend/src/lib/readiness.ts
export function readinessLabel(state: ProviderReadiness, usableModels?: number): string
export function readinessHint(state: ProviderReadiness, defaultModel?: string): string | null
export function readinessTone(state: ProviderReadiness): 'faint' | 'muted' | 'warn' | 'ok'
```

All three are **total**. `pending` returns `''` from `readinessLabel`, `null`
from `readinessHint`, and `faint` from `readinessTone` (it is never rendered, but
the signature must not have a hole). The backend `readinessText` mirrors this
and additionally renders `RdReady n` as `Ready · n Models` / `Ready · 1 Model`
with the same pluralisation rule, so the CLI and the UI cannot diverge.

`ready` **without** a count renders `Ready` (older cached payload, or a caller
with no count) — specified, not left undefined. Backend:
`readinessText :: OllamaReadiness -> Text`, total over all eight constructors,
`RdPending → ""`; `/provider list` omits the segment when the text is empty.

| State | Label | Tone | Hint |
|---|---|---|---|
| `pending` | *(render nothing)* | — | — |
| `unknown` | `Status Unknown` | `faint` | — |
| `not-installed` | `Ollama Not Found` | `warn` | install from ollama.com; or check PATH/Docker |
| `not-running` | `Not Running` | `warn` | `ollama serve` |
| `no-models` | `No Models Pulled` | `warn` | `ollama pull <default_model ?? llama3.2>` |
| `no-fitting-model` | `May Not Fit in RAM` | `muted` | a smaller or quantized model may run better |
| `ready` (n) | `Ready · n Models` / `Ready · 1 Model` / `Ready` | `ok` | — |
| `cloud` | `Cloud` | `faint` | — |

Title Case throughout, matching "API Key" / "Not Configured" / "Vault Locked".
Vocabulary: "found" for the binary, "pulled" for models — Ollama's own verb.

**Why `May Not Fit in RAM`, not `No Model Fits RAM`:** the evidence
(`size × 1.25` vs total RAM) supports a possibility. A 24 GB-VRAM / 16 GB-RAM
host runs a 20 GB model fine. Rev 2's muted colour changed the tone but kept the
claim. The hint is a suggestion, not a remedy.

**`n` is the usable count** (cloud ∪ fitting), so `Ready · 3 Models` is truthful
on a GPU host and under D5.3.

### D5. RAM-fit: advisory, conservative, never asserted without evidence

**D5.1 — Cloud models are usable and are not sized locally.** Observed on the
reference machine:

```
deepseek-v4.1-flash:cloud      336 B   (remote_host: https://ollama.com)
gemma4:latest              9.6 GB
qwen3-coder-next:latest     51 GB
```

`isCloudModel` is true when **either** the name has a `:cloud` suffix **or**
`remote_host` is present. `remote_host` is authoritative when they disagree;
the suffix alone catches a daemon build that omits the field. Both directions
and the neither-set case are asserted (test 15).

**D5.2 — Weights are not the resident set.** KV cache scales with context and is
not in `size`. 1.25× headroom, in **exact integer arithmetic**
(`size * 5 < ram * 4`) so the predicate stays pure and exact:

```
fits model := isCloudModel model
           || (size known && size * 5 < totalPhysicalRam * 4)
```

**D5.3 — Unknown inputs produce no claim.** If RAM is undeterminable, local
models are assumed usable (`RdReady`), because we cannot substantiate a problem.
`RdNoFittingModel` only when both RAM and sizes are known.

Symmetric rule for **size**: `fits` requires a known `otSizeBytes` for a local
model, so a daemon that omits `size` would otherwise mark every local model as
"not fitting" and emit `May Not Fit in RAM` with zero size evidence — the exact
failure mode this clause forbids for RAM. Therefore `RdNoFittingModel` requires
**at least one known size, and none of the known-size models fit**; when every
candidate size is unknown, local models are usable (`RdReady`, count = all
returned models). Pinned by test 14b.

**Mixed known/unknown sizes are pinned too** (rev 5 left this implicit, so the
two clauses could be read against each other): a local model whose size is
*unknown* counts as **usable**, symmetrically with the RAM-unknown clause — we
cannot substantiate a problem, so we do not claim one. `RdNoFittingModel` is
emitted only when every candidate local model has a **known** size and none
fits. Pinned by test 14c.

**D5.4 — Advisory only.** Never affects `configured`, never gates the wizard,
never blocks selection.

RAM detection: macOS `/usr/sbin/sysctl -n hw.memsize` (absolute path with a
plain-PATH fallback — `/usr/sbin` is often absent from a launchd/GUI gateway's
PATH), Linux `MemTotal` from `/proc/meminfo`. **Memoise only `Just`**, so a
transient PATH miss cannot permanently disable WU-B. `parseMemTotal :: Text -> Maybe Word64`
is pure and unit-tested on both CI legs; `MemTotal` is in **kB** while
`otSizeBytes` is bytes, so the conversion is explicit and pinned by test 21.
A **non-kB unit suffix** (`kB` is the only accepted unit) yields `Nothing`
rather than silently assuming a scale — a wrong 1000x guess would be worse than
"RAM unknown", which degrades safely to D5.3's assume-usable. Pinned by test 21.
Container/cgroup limits are not reflected in either source (stated assumption).

Invariant note (corrected): `sysctl` is **not** on AGENTS.md's permitted-exception
list, but invariant 1 is scoped to *Trusted/Audited opcodes*, and this is
gateway/CLI code. The right justification is precedent — `TlsCert.hs`,
`SearXngSetup.hs`, `EngramBackend.hs` all exec fixed-argv binaries outside the
opcode layer. No opcode gains a capability; invariant 2 is not implicated (no
user-derived argv).

### D6. Modules, types, and seams

**D6.1 — Pure classification** (`Seal.Providers.OllamaReadiness`):

```haskell
data OllamaHostKind
  = OhCloud          -- host is ollama.com: no probe
  | OhDefaultLoopback -- literally defaultOllamaBaseUrl: binary wording allowed
  | OhLoopback       -- 127.0.0.1 / [::1] / localhost, any port
  | OhOtherHost      -- LAN / remote
  deriving stock (Eq, Show)

data OllamaTag = OllamaTag
  { otName       :: !Text
  , otSizeBytes  :: !(Maybe Word64)   -- Nothing = the daemon reported no size
  , otRemoteHost :: !(Maybe Text)     -- Just = cloud model, runs server-side
  } deriving stock (Eq, Show)

data OllamaProbe = OllamaProbe
  { opHostKind      :: !OllamaHostKind
  , opTags          :: !(Either OllamaProbeError [OllamaTag])
  , opBinaryPresent :: !Bool
  , opTotalRam      :: !(Maybe Word64)
  } deriving stock (Eq, Show)

classifyOllamaReadiness :: OllamaProbe -> OllamaReadiness
readinessText           :: OllamaReadiness -> Text
isCloudModel            :: OllamaTag -> Bool
classifyProbeFailure    :: HttpException -> OllamaProbeError
parseMemTotal           :: Text -> Maybe Word64
```

`opHostKind` replaces rev 3's `opLocalUrl :: Bool`, which could not express
`RdCloud` (making test 11 unwritable) and conflated "default loopback" with "any
loopback" (making `127.0.0.1:11434` degrade to `Status Unknown` in exactly the
scenario the issue is about).

House style: type-abbreviation prefixes as used throughout `src`
(`olModel`, `adProviders`, `siConfiguredProviders`), strict fields, no partial
functions. The count is a `length` over a filtered list; nothing computes a
"largest" model, so no fold-to-`Maybe` is needed.

**D6.2 — Seam** (handle record, the repo's established pattern):

```haskell
data OllamaProbes = OllamaProbes
  { oprReadiness :: IO OllamaReadiness   -- reads cache; kicks async refresh if stale
  , oprRefresh   :: IO ()                -- non-blocking; startup warm only
  , oprTotalRam  :: IO (Maybe Word64)    -- memoised on success
  }
```

Injection: `SetupInputs.siOllamaReadiness :: IO OllamaReadiness` (beside
`siConfiguredProviders`) and `ApiDeps.adOllamaReadiness :: IO OllamaReadiness`
(beside `adProviders`). `SetupEnv` gains `seOllamaReadiness`, fed from
`adOllamaReadiness` in `setupEnv` (`API.hs:251-258`, next to
`seProviders = adProviders deps`).

**Stub sites (corrected).** Not `stubSetupDeps` — that is a `SetupDeps`. The
real `SetupInputs` literals are `emptySetupInputs` (`State.hs:125-137`),
`handleSetupState`'s literal (`Setup.hs:161-172`), and
`test/Seal/Setup/StateSpec.hs::inputsFor` (278-311). `ApiDeps` has **no
`Default` instance**, so ~34 record literals across the spec files need the new
field (ApiSpec alone ~28, hotspots at `ApiSpec.hs:297`, `:5594`, `:5735`). Add
one shared helper constant (`noOllamaReadiness = pure RdPending`, in
`TestHelpers`) so the churn is mechanical, and default the stub to `RdPending`
so no existing test touches the network or the real PATH.

`providerCards` (`State.hs:290`) is currently **pure**; WU-A threads readiness in
as an extra argument (`providerCards inputs configured readiness`) rather than
making it effectful.

**D6.3 — I/O module: `Seal.Providers.OllamaReadinessProbe`.** Holds the
`IORef` cache (last result + timestamp + in-flight key), single-flight,
`listTagsDetailed` (2 s, 256 KiB loop, `redirectCount = 0`, keyless headers,
floor + URL-shape checks), `findExecutable`, and the `sysctl`/`/proc/meminfo`
reader. Two new modules means **two** sets of three wiring places.

The cache `IORef` is created in `Serve.hs` in the
`wsHealthRef`/`iconCache` cluster (~line 645-654), **before** `let deps = ApiDeps`
(line 655) and before `runGateway` (line 766), closed over by both
`adOllamaReadiness` and the startup warm. It is process-global, not per-session,
so two sessions cannot observe different readiness for one base URL. `oprRefresh`
forks and returns immediately, so the HTTP bind is never delayed.

Readiness requires **no vault handle** (D2.1), so it is readable with the vault
locked or absent — stated so a future change cannot reintroduce a vault
dependency into the probe path.

The TUI runs in a **different process** and cannot share the cache, so
`/provider list` probes inline (≤2 s + one `sysctl`). Acceptable for an
interactive command; D2.4's "never inline" is scoped to HTTP handlers.

### D7. All three dropdown implementations get the consumer

Rev 2 added `readiness` to `/api/providers` with no consumer, while Problem-row 1
stayed unfixed. Rev 3 named only `ProviderModelFields.tsx` — but `AgentsView`
(`AgentsView.tsx:486-490`) and `NewSessionComposer` (`:99-103`) each hand-roll
their own `<option>` list off the same endpoint. All three are annotated:
`Ollama (Not Running)` — **parenthesised**, matching the existing in-option
annotations ` (default)` and ` (missing)` rather than inventing a dash; when a
row is both `missing` and not running, `missing` wins (it is the stronger
statement) and readiness is omitted. The option stays **selectable** (D1: the
filter is still `configured`), so this is annotation, not gating.

`NewSessionComposer` is **confirmed dead** (only its own test imports it), so it
is deleted, leaving two live sites. Those sites are **not** uniform:
`ProviderSelect` (`ProviderModelFields.tsx:65`) filters on `configured !== false`
**or** `p.missing === true`, and also renders `NewTabComposer`'s and `CronView`'s
lists; `AgentsView.tsx:486` maps over all of `/api/providers` unfiltered. Test
42 says "each live option list" for that reason.

### D8. `ProviderStep`'s CTA must agree with the pill

`ProviderStep` branches solely on `card.configured` (`ProviderStep.tsx:230-247`),
so a `not-running` Ollama would show the honest new pill **and** a primary CTA
"Use Ollama" that calls `onDone()`. Rev 6 specifies:

- the pill renders from `readiness`; when `readiness` is **absent** (a
  non-Ollama card) the pill keeps its current text (`configured` /
  `no credential`) — the absent case is a fallback, not a replacement;
- a hint slot renders below the pill (new);
- the CTA stays `Use <provider>` and stays enabled — the wizard's job is
  credential sufficiency, and a keyless Ollama has nothing missing;
- the "Ollama is not ready yet; you can continue and start it later." sentence
  shows **only** for `{not-installed, not-running, no-models}`, **appended to**
  the existing `ollama · <model>` detail rather than replacing it.

That set is deliberately narrow, and the exclusions matter:

- `pending` — first paint has no probe result yet (the stub default is
  `RdPending`, test 34); claiming "not ready" there would be a wrong sentence in
  the common cold-start path.
- `cloud` — an `ollama.com` endpoint is not probed at all, so "not ready" is
  simply false.
- `no-fitting-model` — advisory by D5.4; turning it into "not ready" is exactly
  the advisory-becomes-a-verdict error the design forbids.
- `unknown` — the probe failed unexplainably, so we do not know; no claim
  either way.
- `ready` — ready.

The sentence is produced by `Setup/State.hs` (`step.detail`), surfaced through
`Gateway/Setup.hs` `stepJson` and rendered at `SetupWizard.tsx:122-125`.
`ProviderStep` receives `step` read-only and **cannot** set `step.detail`, so
the trigger must live in the classifier. `classifyProvider` therefore gains a
readiness argument too — it is the function that actually produces the detail,
and `deriveSetupState` is already in `IO`, so it reads `siOllamaReadiness` once
and passes the value to both `classifyProvider` and `providerCards`.

Pinned by test 44 (frontend) **and** a `StateSpec` assertion on the detail
string (test 33), since a frontend-only test would not catch a backend trigger
error.

`classifyProvider` / `required_complete` remain otherwise untouched (D1): this
design does not gate the wizard, it makes the wizard honest about what it gates
on.

## Wire format

Additive: enum + optional count, on **all three** endpoints. Each keeps its own
existing casing.

`GET /api/providers` (`name`/`configured`/`models` are lowercase; the count key
follows suit):
```json
{ "name": "ollama", "configured": true, "models": [],
  "readiness": "not-running" }
{ "name": "ollama", "configured": true, "models": [],
  "readiness": "ready", "readiness_models": 3 }
```

`GET /api/providers/all` (camelCase 1:1 — `authStatus`/`isDefault`; `types.ts`
documents this endpoint as needing no mapping function):
```json
{ "name": "ollama", "authStatus": "keyless",
  "readiness": "ready", "readinessModels": 3 }
```

`GET /api/setup` card (snake_case — `default_model`/`requires_base_url`):
```json
{ "id": "ollama", "configured": true,
  "readiness": "ready", "readiness_models": 3 }
```

No raw RAM bytes, no model names, no sizes: the `:cloud` and `remote_host` tests
and every fit calculation stay server-side. `readiness` is **absent** for
non-Ollama rows and custom OpenAI-compatible instances; the absent-field
fallback covers them.

Wire values: `pending` | `unknown` | `not-installed` | `not-running` |
`no-models` | `no-fitting-model` | `ready` | `cloud` — kebab-case, matching
`api-key` / `vault-locked`.

## Files touched

New: `src/Seal/Providers/OllamaReadiness.hs` (pure),
`src/Seal/Providers/OllamaReadinessProbe.hs` (I/O),
`test/Seal/Providers/OllamaReadinessSpec.hs`,
`test/Seal/Providers/OllamaReadinessProbeSpec.hs`,
`frontend/src/lib/readiness.ts` (+ test).

**Modified:** `src/Seal/Web/UrlSafety.hs` (`extractHost` becomes bracket-aware
and userinfo-stripping — D2.2) plus its existing spec, which gains the four
host-parsing cases. This is the one change outside the providers area and it is
deliberate: the probe's SSRF floor depends on it.

cabal — **two** new exposed modules (beside `Seal.Providers.Ollama`, ~line 129),
two new test `other-modules:` (beside `Seal.Providers.OllamaSpec`, ~line 675),
two `test/Main.hs` entries. Merge hotspots: land wiring once, then rebase.

Backend: `Setup/State.hs` (`providerCards` **and** `classifyProvider`
signatures, seam, detail string), `Gateway/Setup.hs` (`SetupEnv`, `cardJson`,
the `SetupInputs` literal), `Gateway/API.hs` (`ApiDeps`, `providerInfoJson`,
`providerDetailJsonFor`), `Command/Provider.hs` (`listCmd`),
`Command/Serve.hs` (cache, wiring, startup warm), plus **36** `ApiDeps` literals
(28 in `ApiSpec`) and 1 in `Serve.hs`. `Registry.hs` needs **no** change — D1
leaves `configured` semantics untouched — so it is deliberately absent.

`providerDetailJsonFor` is shared by `GET /api/providers/all` and the POST/PUT
mutation responses (`API.hs:3295`, `:3394`). `DELETE` returns `noContent`
(204, no body), so POST/PUT only. All share one lookup, or saving an Ollama
provider flips its badge back to `Keyless`.

Frontend: `types.ts`, `lib/setupSteps.ts` (`ProviderCard` **and**
`parseProvider`'s destructure whitelist at line 192, which would otherwise drop
the new fields), `components/ProvidersView.tsx` (list row + editor pill; the row
is `text-xs truncate`, so two badges **stack** rather than clip),
`components/setup/ProviderStep.tsx`, `components/ProviderModelFields.tsx`
(shared `ProviderSelect`, which `NewTabComposer` and `CronView` also render, so
they are annotated for free), `components/AgentsView.tsx`,
`components/NewSessionComposer.tsx` (**delete** — confirmed orphaned: the only
import in the whole frontend is its own test), `hooks/useApi.ts` +
`hooks/useSetup.ts` (focus refetch), `lib/readiness.ts`. `types.ts` also gains
`readiness?` on `ProviderOption`, not just `ProviderInfo`/`ProviderDetail`.

## Test plan (RED first)

Pure classification — one `it` per state, exact `shouldBe`:

1. refused + loopback + binary present → `RdNotRunning`
2. refused + loopback + no binary → `RdNotInstalled`
3. refused + `OhOtherHost` → `RdUnknown`
4. refused + `OhCloud` → `RdCloud` (no probe)
5. `OpeBlocked` → `RdUnknown`
6. `OpeTimeout` → `RdUnknown`
7. `OpeBadResponse` → `RdUnknown`
8. `OpeHttp 401` → `RdUnknown`
9. a 3xx response → `OpeHttp 302` → `RdUnknown`, and the listener sees exactly
   one request (`redirectCount = 0` never follows the redirect)
10. daemon answers, zero models → `RdNoModels`
11. daemon answers, one fitting local model → `RdReady 1`
12. daemon answers, only `:cloud` → `RdReady n`
13. daemon answers, none fit, RAM known → `RdNoFittingModel`
14. daemon answers, models exist, RAM **unknown** → `RdReady` (D5.3)
14b. daemon answers, local models with **every size unknown** → `RdReady`
    (D5.3 symmetric size rule)
14c. **mixed**: one local model with a known size that does not fit, one with
    unknown size → `RdReady` (the unknown-size model counts as usable)
15. `isCloudModel`: `remote_host` set → cloud; `:cloud` suffix → cloud; both →
    cloud; neither → not cloud (four explicit assertions)
16. `classifyProbeFailure`, three inputs distinguished by errno:
    (a) **real refused connect** to a closed loopback port → `OpeRefused`;
    (b) **real DNS failure** (an unresolvable `.invalid` host) → not
    `OpeRefused`;
    (c) a synthetic `eCONNRESET` → not `OpeRefused`.
    (a) and (b) must be produced by real connects, not hand-built
    `HttpException`s — a synthesized value would pass the rule and prove
    nothing, and the whole point is that these two are indistinguishable
    except by errno. (c) may be synthetic but must be wrapped with
    `toException` (the field is a `SomeException`) and must supply **every**
    `IOError` record field including `ioe_handle = Nothing`, or `-Werror`
    `-Wmissing-fields` fails the build.
17. `readinessText` over all eight constructors; `RdPending → ""`

Properties (quantified, not single-case assertions):

18. RAM unknown never yields `RdNoFittingModel` (forAll over tag lists)
19. monotonicity, restated over the exported classifier:
    `classify (p {opTotalRam = Just r}) == RdReady n` ⇒
    `classify (p {opTotalRam = Just r'}) == RdReady m` with `m >= n`, for `r' >= r`
20. `otRemoteHost = Just _` ⇒ usable regardless of size (forAll over sizes)

Pure parsers:

21. `parseMemTotal`: `"MemTotal:       16384000 kB"` → `Just 16777216000`
    (kB→bytes pinned); `""` → `Nothing`; `"MemTotal: 0 kB"` → `Nothing`;
    `"garbage"` → `Nothing`; `"MemTotal: 16 MB"` → `Nothing` (non-kB suffix is
    not silently rescaled). **(rev 3 had the excerpt mapping to `Nothing`,
    which would have pinned "RAM always unknown" and neutered WU-B.)**
22. `probeTargetFor :: Text -> Either OllamaProbeError Request` (pure
    pre-request validator) rejects: non-http(s); userinfo
    (`http://x@169.254.169.254/…`); `169.254.169.254`; `http://[fd00:ec2::254]/…`
    — and accepts `http://localhost:11434`, `http://127.0.0.1:11434`,
    `http://192.168.1.9:11434`
23. `probeTargetFor` output carries no `Authorization` header, and is built
    without `withHeaders` (structural assertion, per D2.9)

Probe I/O — `OllamaReadinessProbeSpec`, against a **local loopback listener**
(no external network, no real daemon):

24. **the listener captures the request headers and asserts no
    `Authorization` arrives** (D2.9/D2.1). This is the test that actually
    observes `managerModifyRequest`; test 23's structural assertion cannot.
25. the probe is constructed from `adHttpManager` (the `mgr` from
    `Serve.hs:316`) and **never** from `gatewayManager`
    (`Serve.hs:874-885`) — asserted at the wiring site, so wiring the
    service-token manager fails RED
26. a two-segment `/api/tags` body decodes fully (D2.3 loop, not one-shot)
27. a body over 256 KiB → `OpeBadResponse`, never a partial decode
28. concurrent calls issue exactly one request (D2.6 atomic single-flight)
29. `http://localhost:11434` and `http://localhost:11434/` issue exactly one
    probe (D2.10 normalised single-flight key)

Wiring — `StateSpec`, `ApiSpec`:

30. `configured` unchanged for every readiness value (no gate flap)
31. `GET /api/providers` emits `readiness` + `readiness_models` for Ollama only
32. `/api/setup` card carries `readiness` **and** `readiness_models`;
    `required_complete` unaffected
33. `StateSpec`: the provider step's `detail` carries the "not ready yet"
    sentence for `{not-installed, not-running, no-models}` and does **not** for
    `{pending, unknown, cloud, no-fitting-model, ready}` (D8)
33b. `GET /api/providers/all` and a PUT response carry the same readiness and
    `readinessModels`
34. the stub seam reports `pending`, never `unknown`

Frontend:

35. `ProvidersView` row renders `Not Running` instead of `Keyless`
36. `ProvidersView` editor pill renders it too
37. absent `readiness` falls back to the current badge
38. `vault-locked` on **anthropic** renders **one** badge (the `readiness present`
    guard in D3.2); `vault-locked` on Ollama renders **two**
39. `pending` renders nothing; `unknown` renders `Status Unknown`
40. `readinessLabel` covers all eight states incl. `ready` with no count, and
    singularises `Ready · 1 Model`
41. `parseProvider` preserves `readiness` and `readiness_models`
42. **each live option list** — `ProviderSelect` (which also feeds
    NewTabComposer and CronView) and `AgentsView` — annotates Ollama and keeps
    it selectable
43. a window `focus` event triggers a refetch in `useAllProviders` and
    `useSetupState` (D2.5)
44. `ProviderStep` pill + hint render and the detail copy agrees with the CTA (D8)

`ProvidersView.test.tsx:203` (asserts the literal `Keyless` for a keyless
Ollama) is rewritten in the RED step, not after.

## Work units

All four Problem-table surfaces land in **WU-A** — none needs RAM data, and
leaving any in WU-B would put a user-visible surface behind exactly the debate
WU-B might stall on. (Rev 3's "two of the four" wording was wrong.)

- **WU-A — probe states + all four surfaces.** Both modules (pure + I/O),
  `OllamaProbes` seam, `listTagsDetailed`, `probeTargetFor` + floor,
  **the `extractHost` bracket-aware/userinfo fix in `Seal.Web.UrlSafety`** (the
  floor is inoperative without it — D2.2),
  `classifyProbeFailure`, `findExecutable`, `pending`/`unknown`/`not-installed`/
  `not-running`/`no-models`/`ready`/`cloud`, `readiness` (+`readiness_models`) on
  `/api/providers`, `/api/providers/all` (+ mutations) **and** `/api/setup`,
  ProvidersView (both sites), `ProviderStep` (pill + hint + detail), all three
  option lists, `/provider list`, focus refetch, startup warm, cabal/Main.hs
  wiring, the `ApiDeps` stub helper. In WU-A `RdReady`'s count is **all returned
  models** (D5.3: RAM unknown ⇒ assumed usable), so the label is never blank.
- **WU-B — RAM judgement.** `parseMemTotal`, `otSizeBytes`/`otRemoteHost`, fit
  logic, `RdNoFittingModel`, hedged label + hint. WU-A alone closes the reported
  complaint; WU-B only refines `ready`'s count and adds one advisory state.

WU ownership of the tag record (so both units do not claim it): WU-A declares
`OllamaTag` with `otName` only and does not use `isCloudModel`; WU-B adds
`otSizeBytes`/`otRemoteHost`, `isCloudModel`, and tests 12, 13, 14, 14b, 14c,
15, 18-21.

`RdNoFittingModel` is **declared and labelled in WU-A** (the wire enum and the
`readinessText`/`readinessLabel` tables are fixed there, per tests 17 and 40);
WU-B only makes it **reachable**. WU-A cannot emit it because it has no size
data — which is exactly why WU-A alone closes the reported complaint. The `cloud` *state* comes from `opHostKind = OhCloud`
in WU-A and is unaffected by `isCloudModel`, which is why WU-A closes all four
surfaces without the fit logic.

## Closing — follow-up issues to file

1. Readiness for custom OpenAI-compatible localhost instances (sibling bug;
   `OllamaProbes` generalises).
2. **`ollamaNeedsKey` is a credential-exfiltration primitive**: it is a
   substring test gating `withHeaders` (`Ollama.hs:537`), and it is still used by
   `providerAuthStatus` (`API.hs:3212`) and `configuredProviders`
   (`Registry.hs:362`). Reachable today via `POST /api/providers/:name/test` and
   any chat turn. Fix: parse the URL and compare host equality against
   `ollama.com`, rejecting userinfo. **Pre-existing; not fixed by this PR**, but
   this design routes around it for the probe (D2.1) and must not be read as
   having closed it.
3. `Seal.Web.UrlSafety`: add a **DNS-resolving** companion so the floor covers
   rebinding. Keep the pure `isAlwaysBlockedUrl :: Text -> Bool` as the
   pre-check and add a separate resolution step (it must be `Text -> IO Bool`,
   so it cannot be the same function) — naming them distinctly up front saves
   the follow-up author a wrong turn. (The bracket-aware / userinfo half is no
   longer deferred: it ships in this PR per D2.2.)
4. Optional: trim `baseUrl` from `providerDetailJsonFor` — it leaks strictly more
   than readiness does on the same endpoint.

## Open questions

1. Is the 30 s lazy-refresh window plus focus refetch the right latency budget,
   or should the gateway also refresh on a timer? (Lazy chosen deliberately: it
   avoids recurring unattended egress — Security noted boot-time warm plus a
   timer would create a standing egress path.)
2. Should a documented disable affordance exist for the startup warm (config
   flag), for air-gapped or egress-monitored installs? Security raised it as a
   policy, not a blocker.
3. Is the `~34`-literal `ApiDeps` churn acceptable with the shared
   `noOllamaReadiness` helper, or should the field be threaded differently?
