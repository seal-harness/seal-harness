# Engram CLI Integration — Missing Features

## Context

The Seal Harness memory system (`simplified-memory-system` branch, PR #175) has an engram embedding backend at `src/Seal/Memory/EngramBackend.hs` that shells out to the `engram` CLI for semantic search. The current implementation has two gaps because the real engram CLI differs from what the design doc (`docs/2026-09-19-memory-system-vision.md`) assumed:

## Gap 1: Custom Index Path

The engram CLI (`engram --help`) does not support a `--index <path>` flag. It uses a fixed index at `~/.engram/index.db`. The design doc specifies a separate memory index at `~/.seal/memory/engram.db`, but the current code passes `indexPath` to `engramEmbeddingBackend` where it's silently ignored (the parameter is reserved but unused).

**What to do:** Either (a) submit a PR to engram adding `--index <path>` / `ENGRAM_INDEX_PATH` env var support so the memory system gets its own index, or (b) accept the shared `~/.engram/index.db` and update the design doc + config to remove `index_path`. Option (a) is preferred — the shared index means memory files are mixed with KB files in search results, which is wrong.

## Gap 2: JSON Output

The engram CLI does not support `--json` output for `engram search`. The current code parses engram's human-readable output (` N. /path/to/file.md (dist: 0.680)`) with fragile text parsing in `parseEngramResults`. This breaks if engram changes its output format.

**What to do:** Submit a PR to engram adding `--json` output to `engram search` (structured results with `path`, `content`, `score`/`distance` fields). Then replace `parseEngramResults` with `Data.Aeson.decode`. The `EngramResult` type already exists in the code (commented out / removed) — it expects fields `file`, `content`, `score`.

## Files to modify

- `src/Seal/Memory/EngramBackend.hs` — update `runEngram` to pass `--index` and `--json` once engram supports them; replace `parseEngramResults` with JSON parsing
- `test/Seal/Memory/EngramBackendSpec.hs` — remove `pendingWith` guards and test against the real JSON output once engram supports it
- `docs/2026-09-19-memory-system-vision.md` — update the "Engram Integration" section if the CLI interface changes

## Engram repo

The engram source is at `https://github.com/nousresearch/engram` (Rust). Check the current CLI there before starting — a newer version may already support these flags.