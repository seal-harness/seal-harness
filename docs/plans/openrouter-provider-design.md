# Design: OpenRouter Provider via openai Package (Non-Servant)

## Decision
Implement OpenRouter as a direct provider using the `openai` Hackage package (v2.5.4), non-servant interface. OpenRouter's `/api/v1/chat/completions` endpoint is OpenAI-compatible.

## Not using
- OpenRouter MCP server (`mcp.openrouter.ai`) — informational/data server only; does not serve chat completions.
- Servant interface from `openai` package — user explicitly rejected due to maintenance concerns.
- Direct raw HTTP (without `openai` bindings) — `openai` package provides typed bindings.

## Provider architecture
- Add `OpenRouterProvider` to `Seal.Providers.Registry` (`KnownProvider` sum).
- Implement `Provider` class instance using `openai` non-servant bindings.
- Base URL: `https://openrouter.ai/api/v1`.
- Vault key: `OPENROUTER_API_KEY`.
- Default model: `ModelId "~openai/gpt-sol-latest"` (or similar alias from docs).

## Security
- No opcode touches `~/.seal/`.
- API key stored only in vault (`vhPut`/`vhGet`).
- Secret values go in `orParts` only, not `orRecorded`.
