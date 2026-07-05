# Anthropic OAuth (Claude subscription) support — design

Date: 2026-07-01
Status: APPROVED (design)
Branch: `phase-2.5-agent-spine` (the consolidated PR #21 branch; builds on Phase 3 M1/M2)

## Motivation

Chatting with a Claude **subscription** credential currently fails with `provider error:
Anthropic API returned HTTP 401`. Root cause: the Anthropic provider only ever sends
`x-api-key: <token>`. Subscription OAuth tokens are rejected on that header — they must be
sent as `Authorization: Bearer <token>` together with `anthropic-beta: oauth-2025-04-20`,
and **without** `x-api-key`. seal has no OAuth path at all.

This milestone adds an Anthropic OAuth login flow (PKCE) with automatic token refresh,
alongside the existing API-key path.

## Goals

1. `/provider login anthropic` authenticates via the Claude OAuth flow and stores tokens in
   the encrypted vault.
2. Chat and `/provider test` work with an OAuth credential (Bearer + beta headers).
3. Access tokens refresh automatically before expiry; the rotated tokens persist to the vault.
4. API-key auth keeps working unchanged; OAuth is selected automatically when present.

## Non-goals

- A localhost redirect listener (we use the manual paste flow the endpoint expects).
- OAuth for other providers (Anthropic only here).
- Any change to `/session` or `/model`.

## Decisions (from the design conversation)

- **Full login flow + refresh** (not paste-a-token).
- **Auth selection by stored credential:** OAuth tokens present → OAuth; else API key; else the
  existing "no credential" error. If both exist, **OAuth wins** (documented).
- **Manual paste flow** with Anthropic's hosted callback that displays the code.
- Provider carries an **`AnthropicAuth` sum**; refresh-on-expiry happens inside `complete`.
- Fold in a **cheap general fix**: surface the Anthropic error **response body** instead of a
  bare `HTTP <code>` (key-safe — the body carries no secret).

## Constants (the OAuth endpoint contract)

- client_id: `9d1c250a-e61b-44d9-88ed-5944d1962f5e`
- authorize URL: `https://claude.ai/oauth/authorize`
- token URL: `https://console.anthropic.com/v1/oauth/token`
- redirect_uri: `https://console.anthropic.com/oauth/code/callback` (hosted page that displays the code)
- scope: `org:create_api_key user:profile user:inference`
- anthropic-version: `2023-06-01`; anthropic-beta: `oauth-2025-04-20`
- PKCE: verifier = 32 random bytes → base64url (no padding, 43 chars); challenge =
  base64url-nopad(SHA-256(verifier bytes)); method `S256`. `state` = verifier (the convention
  the endpoint requires).

## Flow — `/provider login anthropic`

1. Generate verifier + challenge (PKCE, S256). `state = verifier`.
2. Build the authorize URL with query params, in order:
   `response_type=code`, `client_id`, `redirect_uri`, `scope`, `state=<verifier>`,
   `code_challenge=<challenge>`, `code_challenge_method=S256` (values percent-encoded).
   Print it; best-effort open in the browser (failure ignored — headless-friendly).
3. `ccPrompt` for the code Anthropic displays. Input is pasted as `CODE#STATE`; split on the
   first `#` → `code` (before) and `state` (after).
4. POST the token URL with headers `content-type: application/json`,
   `anthropic-version: 2023-06-01`, `anthropic-beta: oauth-2025-04-20`, and JSON body:
   `grant_type=authorization_code`, `client_id`, `code`, `state`, `redirect_uri`,
   `code_verifier`.
5. Parse `access_token`, `refresh_token`, `expires_in`; compute `expiresAt = now + expires_in`.
   Store the blob in the vault under `ANTHROPIC_OAUTH_TOKENS` as JSON
   `{ "access_token": …, "refresh_token": …, "expires_at": <unix-seconds> }`.
6. Report success.

## Refresh

Access tokens are short-lived. The OAuth provider checks expiry **before each request** with a
~60s skew buffer (`expiresAt <= now + 60s` → refresh; a small improvement over an exact `<= now`
check that could expire mid-request). Refresh = POST the token URL with the same headers and
body `grant_type=refresh_token`, `client_id`, `refresh_token`; the response **rotates** the
refresh token (parsed by the same response parser). On success: update the in-memory tokens
**and** persist the new blob to the vault, then build the request. `resolveProvider` also does one
eager refresh-if-expired when it builds the provider at startup.

## Components

### New: `Seal.Providers.Anthropic.OAuth`
- Pure: `codeChallenge :: ByteString -> Text`; `buildAuthorizeUrl :: Pkce -> Text`;
  `parsePastedCode :: Text -> (Text, Text)` (`CODE#STATE`); `parseTokenResponse :: Value ->
  Either Text OAuthTokens`; `serializeTokens :: OAuthTokens -> ByteString` /
  `deserializeTokens :: ByteString -> Either Text OAuthTokens` (the vault blob codec); the
  constants above.
- IO: `newPkce :: IO Pkce` (random verifier); `exchangeCode :: Manager -> Pkce -> Text -> Text
  -> IO (Either Text OAuthTokens)`; `refreshTokens :: Manager -> OAuthTokens -> IO (Either Text
  OAuthTokens)`.

### Changed: `Seal.Providers.Anthropic`
- `data AnthropicAuth = AuthApiKey ApiKey | AuthOAuth OAuthSession`, where
  `OAuthSession = OAuthSession { osTokens :: IORef OAuthTokens, osRefresh :: OAuthTokens -> IO
  (Either Text OAuthTokens), osPersist :: OAuthTokens -> IO () }`.
- `mkAnthropic` (API key, unchanged signature) and a new `mkAnthropicOAuth`.
- `complete` branches on the auth: API-key path unchanged; OAuth path reads `osTokens`, refreshes
  if within the skew window (writing the ref + calling `osPersist`), then sets
  `Authorization: Bearer <access>`, `anthropic-version`, `anthropic-beta: oauth-2025-04-20`,
  `content-type` — and omits `x-api-key`.
- Non-2xx errors now include the response body text (key-safe).

### Changed: `Seal.Providers.Registry`
- `resolveProvider` for Anthropic: `vhGet "ANTHROPIC_OAUTH_TOKENS"` first → deserialize → seed an
  `IORef`, build `osRefresh` (via `refreshTokens mgr`) and `osPersist`
  (`vhPut vh "ANTHROPIC_OAUTH_TOKENS" . serializeTokens`), eager refresh-if-expired, then
  `mkAnthropicOAuth`. Else `vhGet "ANTHROPIC_API_KEY"` → `mkAnthropic`. Else the existing error.

### Changed: `Seal.Command.Provider`
- New `login` subcommand: `/provider login anthropic` runs the flow (uses `prManager`, `prVault`,
  `ccPrompt`).
- `remove` clears **both** `ANTHROPIC_API_KEY` and `ANTHROPIC_OAUTH_TOKENS`.
- `list` shows the auth type per provider: `oauth` / `api-key` / `none`.

### Secret handling
- `OAuthTokens` holds `access`/`refresh` **opaque** (reuse `BearerToken`; add an opaque
  `RefreshToken` newtype — redacted `Show`, no `ToJSON`/`ToTOML`) and `expiresAt :: UTCTime`
  (non-secret). The **only** place token bytes are serialized is `serializeTokens`, writing into
  the *encrypted* vault. The Bearer header is built via the CPS accessor. No error path includes
  token bytes.
- `state = verifier` exposes the PKCE verifier in the printed authorize URL — matches the
  endpoint's required convention; acceptable (user's own terminal, single-use).

## Error handling

`Either Text` throughout. OAuth HTTP failures (exchange/refresh non-2xx) return `Left` with the
status + response body (no secret). A missing/expired refresh that fails to renew surfaces a clear
message pointing at `/provider login anthropic`. `complete` on a failed refresh returns the refresh
error rather than sending a stale token.

## Testing

**Pure:** `codeChallenge` (known verifier → known S256 challenge); `buildAuthorizeUrl` exact
string; `parsePastedCode` (`CODE#STATE`, and code-only); `parseTokenResponse`; `serializeTokens` /
`deserializeTokens` round-trip; OAuth vs API-key header construction; `OAuthTokens`/`RefreshToken`
`Show` redaction.

**IO with stubs:** the OAuth provider takes an injectable `osRefresh`; a test with `expiresAt` in
the past asserts `complete` (or a dedicated `ensureFresh` helper) invokes refresh, updates the
`IORef`, and calls `osPersist` — no live HTTP. `resolveProvider` prefers OAuth over API key when
both vault entries exist (mock vault).

**Gated/manual:** the real login flow + a live OAuth chat (needs a Claude subscription).

## Scope

Single milestone, one implementation plan. Builds on the merged M1 (registry, `ProviderRuntime`,
vault) and M2. No `/session`/`/model` changes.
