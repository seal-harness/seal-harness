# Ollama readiness status — learnings (2026-11-17)

Branch `providers/ollama-readiness-status`. Adds an observed `readiness` axis
for Ollama so the web UI, setup wizard and TUI stop asserting usability from
config inspection alone. Commits: `cf4e077` (WU-A), `e38e1ac` (WU-B),
`1244656` (overflow fix).

## Measurement beats reading, again

Every design claim that mattered was checkable in a minute, and two were wrong
until executed:

**1. A refusal and a DNS failure are byte-identical.** Measured on GHC 9.12 /
http-client 0.7.19:

```
real refusal:  type=NoSuchThing  msg="does not exist"  errno=Just 61
DNS failure:   type=NoSuchThing  msg="does not exist"  errno=Nothing
```

Type and message are identical; **only `ioe_errno` separates them**. Any
discriminator matching `"refused"` against the message makes `Not Running`
unreachable — re-creating the exact bug being fixed. `classifyProbeFailure`
therefore matches errno and nothing else, with a fail-safe catch-all. The
tests use **real** connects (a closed loopback port; a `.invalid` host), not
synthesized `HttpException`s — a synthesized value would pass the rule and
prove nothing.

**2. `redirectCount = 0` does not throw.** With a 302 response, http-client
*returns* the 3xx. A `TooManyRedirects` constructor would have been unreachable
decoration. "Redirects are never followed" is pinned by counting requests at
the listener, not by expecting an exception.

## Two bugs my own tests caught (and the mutations that prove the tests bite)

**`T.breakOn` leaves the delimiter in the suffix.** `snd (T.breakOn "://" url)`
is `"://localhost:11434"`, not `"localhost:11434"`. Every host comparison
failed until dropped. Two call sites had it.

**Word64 overflow in the fit predicate.** `otSizeBytes` comes from the daemon,
so it is untrusted. A size of `2^64/5 + 1` makes `size * 5` wrap to exactly 4 —
smaller than `ram * 4` — so an absurd model compares as **fitting**, the worst
possible direction. Fixed by comparing in `Integer`.

The first test for this used `maxBound - 4`, which does **not** wrap, and so
passed against the broken code. A test that cannot fail is worse than no test:
it is a false claim of protection. Worth stating plainly — write the mutation
first, then the assertion.

**Method that worked:** for each load-bearing property, mutate the
implementation and confirm the test goes red. Properties verified this way:
monotonicity, the symmetric size rule (14b/14c/14b(ii)), the overflow guard,
"memoise only Just".

## Unreachable guards are a code smell, not belt-and-braces

Two guards I wrote turned out to be dead code, and the honest fix was to
delete them and document why:

- `any hasKnownSize tags` before `RdNoFittingModel`: `isUsable` already returns
  `True` for an unknown size, so `usable == 0` implies every tag had a known
  size. The D5.3 rule is satisfied *by construction*.
- "Memoise only `Just`": the cache is a `Maybe Word64`, so there is no way to
  record "I fetched this and got `Nothing`". A miss leaves the ref empty and
  retries.

An explicit guard here would be unreachable code that *looks* like protection.
Delete it and write the paragraph explaining why the invariant holds anyway,
or the next reader adds it back.

## `-Werror` makes mutation testing partly redundant

`-Wunused-top-binds` and `-Wunused-imports` turn several mutations into
*compile* errors rather than test failures. That is a weaker signal — a
compile error proves the helper was unreferenced, not that the behaviour is
pinned. When mutating, make the mutation **compile** so the test is what fails.

## Test-suite wall-clock is a shared resource

Adding ~76 examples made a pre-existing racy test fail in 3 consecutive
`make check` runs while passing standalone and passing on replay of the same
hspec seed.

`test/Seal/Phase7aSpec.hs` had three defects: a **hardcoded port** (18095)
shared across concurrent runs; a fixed `threadDelay 200000` instead of waiting
for the socket to accept; and a `forkIO`'d server **never cancelled**, so the
listener outlived the test (observed in `CLOSE_WAIT`).

*Lesson:* `forkIO` + `threadDelay` + hardcoded port is a flake generator. Use
`testWithApplication` (ephemeral port, managed teardown). And when a suite
gets longer, budget for the tests whose correctness depends on timing.

## Three endpoints, three casings

`/api/providers` is lowercase snake_case (`readiness_models`),
`/api/providers/all` is camelCase 1:1 (`readinessModels`), `/api/setup` is
snake_case. Each keeps its own existing convention, so the shared fragment
takes a `ReadinessKeyCasing` rather than forcing one spelling.

The trap: `ProviderOption` (the shared select's input type) is satisfied
**structurally** by `ProviderInfo`, which mirrors `/api/providers`. Naming the
field `readinessModels` there compiled fine and silently dropped the count.
Caught by a failing `CronView` test asserting `Ollama (Ready · 3 Models)`.

*Lesson:* when two interfaces are related by structural typing, the field name
is part of the contract, not a style choice.

## Absent, not null

`readiness` is **absent** for non-Ollama rows and for custom OpenAI-compatible
instances — never `null`. That is what lets every consumer keep its
absent-field fallback (`readiness === undefined` → today's badge) instead of
distinguishing "no readiness" from "readiness is null". Pinned on all three
endpoints.

## Security notes worth keeping

The probe is **keyless by construction**: `probeTargetFor` builds the request
directly and never calls `withHeaders`, so the vault key cannot reach an
operator-set `base_url`. It is also built on the **provider** manager, never
`gatewayManager` (which stamps `Authorization: Bearer <service token>` onto
every request).

A structural assertion on the request alone cannot observe
`managerModifyRequest`, so the provider-manager rule needs a *behavioural*
control: construct the factory over a manager that stamps a sentinel header and
assert the header **arrives**. Add the negative control too (a manager that
stamps `Authorization` — the listener *must* see it), or "no Authorization
arrived" is unfalsifiable.

The single-flight cap of 1 globally makes the 2 s timeout a **liveness**
requirement, not a nicety: a probe that never returns holds the slot forever
and starves every later refresh permanently.

## Residual, recorded not hidden

`isAlwaysBlockedUrl` performs no DNS resolution, so a hostname resolving to a
metadata IP passes (rebinding). Accepted: no credential is sent, the body is
capped at 256 KiB, and only an 8-value enum escapes the process. It is a blind
connect oracle, not a metadata read.

`ollamaNeedsKey` is still a substring test gating `withHeaders` — a
credential-exfiltration primitive reachable via `POST /api/providers/:name/test`
and any chat turn. This PR routes *around* it for the probe; it does **not**
fix it.
