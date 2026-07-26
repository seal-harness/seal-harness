# WEB_SEARCH Configuration

## Quick Start (Zero Config)

No configuration needed. WEB_SEARCH defaults to **Parallel Search** using
the free MCP endpoint — no API key, no signup, no Docker.

## Provider Selection

Set the `[web] search_provider` field in your config file:

```toml
[web]
search_provider = "parallel"   # default, free, no key needed
# search_provider = "searxng"  # self-hosted, auto-installs via Docker
# search_provider = "exa"      # requires API key
# search_provider = "firecrawl" # requires API key
# search_provider = "custom"   # use your own endpoint
```

## Providers

### Parallel (default)

- **Zero-config:** Works with no API key using the free MCP endpoint
- **With API key:** Set vault key `parallel_api_key` and `search_auth_key = "parallel_api_key"`
  for higher rate limits
- **Config:** `search_max_results` (default: 10, max: 20)

### SearXNG

- **Self-hosted:** Runs a local SearXNG Docker container automatically
- **Prerequisites:** Docker must be installed and running
- **Config:**
  ```toml
  [web]
  search_provider = "searxng"
  searxng_url = "http://localhost:8888"  # default
  ```
- If no instance is running at the configured URL and the URL is localhost,
  seal-harness will attempt to start one via Docker with JSON format enabled.

### Exa

- **Requires API key:** Get one at https://exa.ai
- **Free tier:** 1,000 searches/month
- **Config:**
  ```toml
  [web]
  search_provider = "exa"
  search_auth_key = "exa_api_key"  # vault key name
  ```

### Firecrawl

- **Requires API key:** Get one at https://firecrawl.dev
- **Free tier:** 500 credits/month
- **Config:**
  ```toml
  [web]
  search_provider = "firecrawl"
  search_auth_key = "firecrawl_api_key"  # vault key name
  ```

### Custom

- Use your own search endpoint that accepts `POST {"query": "..."}` and returns
  JSON results.
- **Config:**
  ```toml
  [web]
  search_provider = "custom"
  search_endpoint = "https://your-search-api.com/search"
  ```

## API Key Setup

API keys are stored in the seal-harness vault, never in config files:

```bash
# Store an API key in the vault
/vault set exa_api_key
# (you'll be prompted to enter the key value)

# Reference it in config
# config.toml:
# [web]
# search_provider = "exa"
# search_auth_key = "exa_api_key"
```

## Common Settings

```toml
[web]
search_provider = "parallel"      # provider selection
search_max_results = 10           # max results per search
search_allow_list = ["example.com"]  # restrict results to these domains
```

## Provider Decision Matrix

| Provider        | Zero-Config | API Key | Docker | Free Tier                 |
| --------------- | :---------: | :-----: | :----: | ------------------------- |
| Parallel (MCP)  |      yes     |    no   |   no   | Generous anonymous limits |
| Parallel (REST) |      no      |    yes  |   no   | With key: higher limits   |
| SearXNG         |     no^1     |    no   |  yes^2 | Unlimited (self-hosted)   |
| Exa             |      no      |    yes  |   no   | 1,000 searches/mo         |
| Firecrawl       |      no      |    yes  |   no   | 500 credits/mo            |
| Custom          |      no      |  varies |   no   | varies                    |

1. SearXNG auto-installs via Docker if a localhost URL is configured and Docker is available
2. Docker must be installed and running

## Per-Call Limit Override

The WEB_SEARCH opcode accepts an optional `limit` integer field in its input,
overriding `search_max_results` for a single call (must be >= 1):

```json
{ "query": "Haskell libraries", "limit": 5 }
```

## Result Shape

All providers normalize results to this JSON shape (what the model sees):

```json
{
  "results": [
    {"title": "...", "url": "...", "description": "...", "position": 1}
  ]
}
```

The transcript records only `{"query": "...", "result_count": N, "provider": "..."}` —
never API keys or full response bodies.