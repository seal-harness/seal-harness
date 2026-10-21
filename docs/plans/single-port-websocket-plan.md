# Single-Port WebSocket — Implementation Plan

Branch: `fix/single-port-websocket`
Approved: 2026-10-20 (user: "Let's do item 1 first, and then do item 2 on the same branch")

## Problem

The gateway runs the WebSocket stream server on a **separate port** from the
HTTP/static server. `Seal.Command.Serve` forks it with no exception
handling, so a bind failure kills the WS thread **silently** while the HTTP
gateway stays up and `/api/health` keeps advertising the dead `wsPort`.

Observed in the field: `agent-browser` held port 9092; `seal serve` bound
9090 only; the web frontend's transcript froze permanently (no WS, and the
transcript has no HTTP fallback). A hard refresh "fixed" it because the
HTTP seed path still worked.

The split was a deliberate 2026-07-06 decision
(`docs/superpowers/plans/2026-07-06-phase-7a-web-frontend.md:37`):
`wai-app-websockets` was not in the Nix snapshot, and hand-rolling a Warp
`ResponseRaw` hijack was judged fragile. **That blocker is gone** — the
package was renamed to `wai-websockets` and is now available, built against
exactly the `wai-3.2.4` / `websockets-0.13.0.0` this repo already uses.

## Scope

### Part 1 — Make WS failure visible and truthful (backend only)

User decision: "Backend + health, no frontend" for Part 1.

- **P1.1** `runStreamServer` must not die silently. Catch the bind
  exception, log at Error, and surface it. (Red test: bind a port that is
  already taken; assert the failure is reported rather than swallowed.)
- **P1.2** `/api/health` must report the **actual** WS state, not the
  configured `ws_port`. Add `wsStatus` (`up` / `down` / `failed`) and keep
  `wsPort` for compatibility during Part 2.
- **P1.3** `seal serve` startup must not pretend success: if the WS server
  cannot bind, log a loud, actionable error naming the port and the cause.

### Part 2 — Single port (WS served by the same Warp app)

- **P2.1** Add `wai-websockets` to the library `build-depends` + the flake
  so it resolves in the dev shell.
- **P2.2** Convert `Seal.Gateway.Stream` from `runStreamServer` (own
  listener) to a `ServerApp` that `websocketsOr` can mount inside
  `gatewayApp`. The Origin allowlist moves from `PendingConnection` to the
  WAI `Request` (or keeps using `getRequestHead`).
- **P2.3** `Seal.Gateway.Server.gatewayApp` mounts the WS app at the WS
  path; `runGateway` serves it on the single HTTP port.
- **P2.4** `Seal.Gateway.Config`: `ws_port` becomes optional; when absent
  the WS shares the HTTP port. Keep the field so existing configs keep
  working (a configured `ws_port` may still request the legacy split for a
  transition period, or be ignored with a warning — decide at
  implementation time; prefer **same port always**, with `ws_port` honored
  only if explicitly set AND the user opts in).
- **P2.5** `/api/health`: `wsPort` becomes the HTTP port (same origin);
  frontend no longer needs port discovery.
- **P2.6** `frontend/src/lib/streamClient.ts`: connect to the same origin
  (`ws://host:port/`), keeping the `/api/health` discovery as a fallback
  for older servers.
- **P2.7** The in-process chat channels (`forkNewSignalChatChannel`,
  `forkNewTelegramChatChannel` in `Seal.Command.Serve`) build
  `ChatTypes.gcWsUrl` from `gcWsPort` — they must use the same port now.
  (These are **threads in the same process**, not separate processes.)
- **P2.8** Update tests: `test/Seal/Gateway/ConfigSpec.hs` (8080/8081
  split assertions), `test/Seal/Gateway/StreamSpec.hs` (the WS test
  server), `test/Seal/Gateway/ServerSpec.hs`, `test/Seal/Gateway/ApiSpec.hs`
  (health payload).

## Files in scope

Backend:
- `src/Seal/Gateway/Stream.hs` — WS server → WS app; bind-failure handling
- `src/Seal/Gateway/Server.hs` — mount the WS app; single-port run
- `src/Seal/Gateway/Config.hs` — `ws_port` optional
- `src/Seal/Gateway/API.hs` — `/api/health` reports real WS state
- `src/Seal/Command/Serve.hs` — wiring; chat-channel WS URLs
- `seal-harness.cabal` — `wai-websockets` dep
- `flake.nix` — ensure `wai-websockets` resolves

Frontend (Part 2 only):
- `frontend/src/lib/streamClient.ts` — same-origin WS URL

Tests:
- `test/Seal/Gateway/StreamSpec.hs`
- `test/Seal/Gateway/ServerSpec.hs`
- `test/Seal/Gateway/ConfigSpec.hs`
- `test/Seal/Gateway/ApiSpec.hs`

## Out of scope

- Frontend reconnect-wedge fix and transcript HTTP-polling fallback
  (user deferred these; they remain the right follow-ups).
- Chat-channel protocol changes beyond their WS URL.

## Risks

- **Origin allowlist**: today it is checked on the `PendingConnection`.
  Under `websocketsOr` the check must still happen **before** the upgrade
  (reject with 403). `getRequestHead` gives access to the headers.
- **Warp + WebSocket**: Warp must be run with a setting that permits
  long-lived upgraded connections. `warp` supports `ResponseRaw` upgrades
  via `websocketsOr`, but the `runSettings` may need
  `setInstallShutdownHandler` / timeout tuning so an idle WS is not
  reaped. Verify with a real connection that survives >30s idle.
- **`withPingThread`**: currently used for the 30s server ping. Under the
  WAI bridge the same helper applies to the accepted `Connection`.
- The chat channels connect over WS to the gateway; if they run in the
  same process, a same-port WS must not deadlock the HTTP server.

## Validation

- `make check` (build + test + lint) green.
- New tests: bind-conflict is reported; `/api/health` reflects a dead WS;
  a WS client can connect on the HTTP port and receive `hello`.
- Manual: `seal serve` on a free port, then connect a WS client to
  `ws://127.0.0.1:<httpPort>/` and confirm `hello` + a `lists` frame.
