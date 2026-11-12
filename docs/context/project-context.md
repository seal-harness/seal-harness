# Project Context (Maintained by Orchestrator)

## Tooling
- Build: `cabal build all` (inside nix dev shell; SIGPIPE pitfall — redirect to file)
- Test: `cabal test >test.log 2>&1; head -80 test.log`
- Focused test: `cabal test --test-options='--match "<needle>"'`
- Lint: `hlint src/ test/` — must report: No hints
- Full gate: `make check` (build + test + lint)
- Frontend: `cd frontend && npm test -- --run` / `npm run build`

## Completed Work Units
| W1 | Seal.Channels.Config | src/Seal/Channels/Config.hs, test/Seal/Channels/ConfigSpec.hs | ChannelId, ChannelConfig, ResolvedChannel, channelConfigCodec, keyChannelIdBiMap, telegramVaultKeyFor, resolveChannelConfig |
| W5 | Frontend ChannelsView | frontend/src/components/ChannelsView.tsx, types.ts, useApi.ts | ChannelDetail, ChannelInput, useChannels, createChannel, updateChannel, deleteChannel |

## Established Patterns
- Providers CRUD: `Map Text ProviderConfig` via `Toml.tableMap` + `keyRepoBiMap`; `normalizeProvidersTable`; `upsertProvider`; `updateRuntimeConfig` (MVar-serialized); camelCase response JSON / snake_case input JSON; `ProvidersView.tsx` list+editor template; `useAllProviders` mount+refresh (not polling)
- Channel config: `Map ChannelId ChannelConfig` mirrors providers; restricted kind codec (Signal/Telegram only); `telegramVaultKeyFor` maps legacy "telegram" to unsuffixed key

## Active Services
See SERVICE-INVENTORY.md (not yet created)
