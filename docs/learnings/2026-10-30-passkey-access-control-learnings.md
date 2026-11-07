# Learnings: Passkey access control for the web gateway

**Captured**: 2026-10-30 (post-implementation, pre-PR self-reflect)
**Feature**: passkey access control for `seal serve`
**Design**: `docs/superpowers/specs/2026-10-30-passkey-access-control-design.md`

Durable facts about the codebase and about WebAuthn that future agents should
not have to rediscover. Each item is something that cost real time here or that
a test caught only by accident.

---

## 1. crypton is built against `ram`, not `memory` — and both expose `Data.ByteArray`

**The gotcha.** `crypton-1.1.4` depends on `ram` (the successor to `memory`).
So the `ByteArrayAccess` instance for `Crypto.Hash.Digest` lives in `ram`. With
only `memory` in `build-depends`, `Data.ByteArray.convert (hash bs)` fails with
"No instance for ByteArrayAccess (Digest SHA256)" — an error that reads like a
crypton problem and is actually a package-identity problem.

**The fix.** The library depends on `ram` (replacing `memory`), not both: if
both are dependencies, every bare `import Data.ByteArray` becomes an ambiguous
module error. `ram` is API-compatible for everything this repo uses
(`constEq`, `convert`, `Data.ByteArray.Encoding`).

**The lesson.** If a crypton type refuses an instance that obviously exists, check
which package defines it (`ghc-pkg field crypton depends`) before adding a
language extension or a workaround.

---

## 2. WebAuthn assertion signatures are DER; WebCrypto's are raw

- Authenticators return `SEQUENCE { r INTEGER, s INTEGER }` (DER).
- `crypto.subtle.sign()` returns the **raw 64-byte r||s** instead.

So a Node-WebCrypto fixture generator must use the classic
`crypto.sign('sha256', msg, {key, dsaEncoding: 'der'})` — otherwise the fixture
exercises a code path no real browser ever produces, and a DER parser looks
broken for the wrong reason.

`crypton`'s `ECDSA.verify` takes `(Integer, Integer)`, so the repo needed its own
bounded DER decoder (`Seal.Security.WebAuthn.Der`). ~60 lines; keep it strict
(reject indefinite lengths, negative integers, trailing bytes).

---

## 3. `Crypto.PubKey.ECC.Types` exports `CurveName`, not a usable `PublicKey`

- the curve is `SEC_p256r1` (not `Curve_P256R1`),
- `PublicKey { public_curve :: Curve, public_q :: Point }` comes from
  `Crypto.PubKey.ECC.ECDSA`,
- build it with `getCurveByName SEC_p256r1` (NOT `common_curve`, which takes a
  `Curve` and returns `CurveCommon`),
- validate the point with `isPointValid curve point` from
  `Crypto.PubKey.ECC.Prim` — skipping this makes an off-curve key a runtime
  surprise instead of a clean rejection,
- `SHA256` needs `SHA256(..)` in the import list to be usable as the
  `HashAlgorithm` *value* that `verify`/`sign` take.

---

## 4. tomland's implicit-table gotcha nests one level deeper than documented

The known bug (learnings 2026-08-02 §4) is that
`Toml.tableMap … "section"` decodes an empty map for a file with only
`[section.<key>]`. The fix — `normalizeXTable` — must be applied **at every
level of nesting**: `[access_control.credentials.<id>]` leaves *both*
`access_control` and `credentials` implicit, and normalising only the outer one
still yields an empty map. `Seal.Config.Security.normalizeAccessControlTable`
therefore runs `fixNode` twice.

**The lesson.** Any new `tableMap` codec deeper than one level needs a test whose
fixture is in the *idiomatic hand-written* form (no bare section header). Do not
test with `Toml.encode` output — the encoder always writes the explicit header,
so the bug never reproduces.

---

## 5. A "wire state" and a "config spelling" are not the same string

`[access_control] mode = "none"` (the operator's waiver) must be reported by
`/api/auth/status` as `state: "open"` (what the gateway is doing). Reusing the
config spelling for the wire value made the SPA's `state === 'open'` branch
unreachable, so the app rendered the setup screen in open mode.

**How it was caught.** Not by the unit tests — they mocked the status payload —
and not by the Haskell tests, which only asserted the `unconfigured` case. The
**Playwright capstone** caught it, because it drives the real SPA against a real
`seal serve`.

**The lesson.** (a) A status enum that crosses a config/API boundary deserves
its own mapping function and a test asserting *all three* values. (b) When a
security gate is added in front of an existing e2e path, run the e2e — the unit
suite cannot see a render-table mistake.

---

## 6. The capstone e2e was already failing on `main`

`frontend/e2e/capstone.spec.ts:57` ("Close tab" never appears after creating a
tab) fails identically on a pristine `main` — verified by `git stash -u` +
rebuild + rerun. Do not spend time attributing it to a new change; and when
adding to `global-setup.ts`, confirm progress by the *failure line moving* (26 →
57 here), not by the run going green.

---

## 7. A rejected WebSocket handshake is invisible to JavaScript

A 401 returned before the upgrade surfaces in the browser as
`onclose` with code **1006** — never a custom code like 4401. So the frontend
cannot learn "your session expired" from the WS close event.

**The fix.** One `fetch` wrapper installed at startup
(`frontend/src/lib/unauthorized.ts`) dispatches `seal-unauthorized` on any 401;
the WS path is covered indirectly because the lists hook falls back to REST
polling when the stream drops. One interceptor instead of ~45 call sites.

---

## 8. `hIsTerminalDevice` is the right test for "will a human see this?"

The setup code must never go through `SealLogger` (its file scribe writes
`seal.log`, which the agent can read). Write it with `hPutStrLn stderr`, and when
stderr is **not** a TTY (`launchd`, `systemd`, a pipe) also write it to
`~/.seal/state/setup-code` at 0600 — otherwise a daemon operator can never
complete setup. Delete that file once setup succeeds.

Related: `openFd … defaultFileFlags { trunc = True, creat = Just 0o600,
nofollow = True }` applies the mode **at creation**; `writeFile` then
`setFileMode` leaves a world-readable window. `Seal.Config.Security.writeSecretFile`
is the shared helper.

---

## 9. `setRequestBodyChunks` in wai takes a *chunk source*, not a list

Its argument is `IO ByteString` — re-invoked until it returns an empty chunk. A
`pure payload` source returns the same bytes forever, so a "bounded body" guard
accumulates to the cap and answers 413. Tests need a stateful `IORef`-backed
source, created **outside** the IO action (and without `unsafePerformIO` shared
across two requests, which exhausts it).

---

## 10. Test fixture independence is worth the generator script

`scripts/gen-webauthn-fixture.mjs` produces `test/fixtures/webauthn/ceremony.json`
with Node's WebCrypto/OpenSSL. crypton is then checked against a *different
implementation*, and the fixture is committed (embedded via `file-embed`, so the
test does not depend on the working directory — another spec may have changed it).

Do this for any crypto format decoder. "Round-trip my own encoder" tests only
prove self-consistency.

---

## 11. Middleware placement: wrap the `("api":_)` branch, not the app

`gatewayApp` dispatches on `pathInfo`; wrapping the whole application with the
access-control middleware 403s the SPA bundle, and the setup screen can then
never load. Wrap only the API branch (inside `requestTimingMiddleware` so
401/403s are logged).

For the WebSocket the opposite is true: `streamMiddleware` wraps `gatewayApp`,
so an `/api/*` middleware never sees the upgrade. The check has to live in the
outer application (`isWebSocketsReq` + `authorize`) to be able to return a real
401.
