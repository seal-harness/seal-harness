# Phase 5 follow-up: hybrid agent-def discovery + bootstrap-file prompt composition

**Date**: 2026-07-05 · **Status**: draft · **Branch target**: `skills-and-agents` (or follow-on)

## 1. Problem

The Phase 5 pivot made `~/.seal/config/` a git repo with agent defs as flat
Markdown files at `config/agents/<id>.md`. The user's on-disk layout (mirrored
from PureClaw) is `config/agents/zoe/{AGENTS,MEMORY,SOUL,USER}.md` — a
subdirectory per agent with multiple bootstrap files. The current backend's
`listAgentDefs` (`src/Seal/Agent/Def/Backend.hs:147`) enumerates only top-level
`.md` files, so it reports "no agent defs defined" for the user's real layout.

PureClaw's method (`~/code/pureclaw/src/PureClaw/Agent/AgentDef.hs`):

1. **Discovery**: enumerate subdirectories under `agents/`; the dirname is the
   agent name (validated via `mkAgentName`).
2. **Config**: optional TOML frontmatter on `AGENTS.md` inside the agent dir
   (`model`, `tool_profile`, `workspace`).
3. **Prompt composition**: read bootstrap files (`SOUL.md`, `USER.md`,
   `AGENTS.md` body, `MEMORY.md`, `IDENTITY.md`, `TOOLS.md`, `BOOTSTRAP.md`)
   in fixed order, join with `--- SOUL ---`-style section markers, truncate
   each at a per-file limit, skip missing/empty/oversized.

The user wants seal-harness to **read both layouts**: the existing flat
`agents/<id>.md` scheme (which `AGENT_DEF_CREATE` writes) **and** the
PureClaw directory-per-agent scheme (so existing on-disk agents like `zoe/`
are discovered). `AGENT_DEF_CREATE` keeps writing the flat single-file form.

## 2. Goals / non-goals

**Goals**

- `/agent list` discovers both flat `.md` files and `<id>/` subdirectories
  under `config/agents/`.
- Directory-scheme agents compose their system prompt from bootstrap files
  in the PureClaw order with PureClaw's section markers and per-file
  truncation.
- `AGENT_DEF_CREATE` / `AGENT_DEF_UPDATE` keep writing the flat
  `agents/<id>.md` file (the model can author single-file defs; humans
  drop directories).
- The existing capstone test (`Seal.Phase5Spec`) stays green; a new test
  exercises directory-scheme discovery + prompt composition.

**Non-goals**

- No PureClaw `tool_profile` text label — seal-harness keeps its
  `AllowList OpName` capability model (stored as frontmatter `tools` field,
  in both schemes).
- No PureClaw `workspace` validation (`validateWorkspace` /
  `ensureDefaultWorkspace`) — seal-harness has its own `WorkspaceRoot`
  concept already.
- No `IDENTITY.md` / `TOOLS.md` / `BOOTSTRAP.md` handling beyond passing
  them through the same read-or-skip pipeline (files we read if present,
  skip if absent). Match PureClaw's section list to keep the composition
  function identical.
- No rewriting `AGENT_DEF_CREATE` to emit directories.
- No SQLite, no Audited log (per handoff §8 / Decision 1).

## 3. Design

### 3.1 Two source schemes, one `AgentDef` type

`AgentDef` stays as-is (id/name/provider/model/system/tools/timestamps/session).
The backend gains a **source scheme** distinction internally:

- `FlatScheme`: data lives in `agents/<id>.md` with frontmatter
  (`id`/`name`/`provider`/`model`/`tools`/timestamps/`session`) and body =
  system prompt. `decodeAgentDef` already handles this.
- `DirScheme`: data lives in `agents/<id>/`. Frontmatter comes from
  `AGENTS.md` (optional TOML frontmatter, decoded by `tomland` — already a
  cabal dep). The system prompt is **composed** on demand by reading
  `SOUL.md`, `USER.md`, `AGENTS.md` (body only), `MEMORY.md`,
  `IDENTITY.md`, `TOOLS.md`, `BOOTSTRAP.md` in fixed order with `--- SOUL ---`
  style markers, per-file truncation at a configurable limit (default
  PureClaw's behavior: skip empty / oversized >1MiB / unreadable).

The backend keeps the **same `AgentDefBackend` interface** (`adbRead` /
`adbUpdate` / `adbList`); the scheme is an internal implementation detail.
`adbRead` and `adbList` may need to compose the system prompt lazily —
see 3.4.

### 3.2 Field resolution per scheme

| Field          | FlatScheme                              | DirScheme                                                                |
|----------------|-----------------------------------------|--------------------------------------------------------------------------|
| `adId`         | frontmatter `id`                        | dirname                                                                  |
| `adName`       | frontmatter `name`                      | dirname (no `name` field in PureClaw frontmatter)                        |
| `adProvider`   | frontmatter `provider`                  | `AGENTS.md` frontmatter `provider` (optional; `""` if absent)            |
| `adModel`      | frontmatter `model`                     | `AGENTS.md` frontmatter `model` (optional; `""` if absent)               |
| `adSystem`     | file body                               | composed on demand from bootstrap files (see 3.4); `Nothing` if empty    |
| `adTools`      | frontmatter `tools` (`all` / JSON arr)  | `AGENTS.md` frontmatter `tools` (same encoding; absent → `AllowAll`)     |
| `adCreatedAt`  | frontmatter `created_at`                | file mtime of `AGENTS.md` (or epoch if missing)                          |
| `adUpdatedAt`  | frontmatter `updated_at`                | file mtime of `AGENTS.md` (or epoch if missing)                          |
| `adSession`    | frontmatter `session`                   | `"manual"` (no provenance for hand-dropped dirs)                         |

**Provider/model fallback (resolved)**: when `adProvider` or `adModel` are
empty for a DirScheme agent, `AGENT_START`'s `mkWorker` falls back to the
active session's provider and/or model (consistent with PureClaw's
`resolveOverride` precedence: CLI > frontmatter > config > default). Both
fields fall back symmetrically — not just provider. A non-empty-but-unknown
provider still fails with the existing "unknown provider" error; the
fallback fires only on empty strings. This unblocks `zoe/` immediately
without forcing the user to add frontmatter.

**Timestamp instability note**: mtime is reset by `git checkout` / `git pull`
to the checkout time, not the original commit time. This means DirScheme
timestamps are unstable across git operations. Currently harmless
(`/agent list` sorts by name, not timestamp), but noted as a known
limitation. If it matters later, read the last-commit timestamp via
`git log -1 --format=%ct -- agents/<id>/AGENTS.md`.

### 3.3 Frontmatter codec for DirScheme `AGENTS.md`

PureClaw uses `tomland` with a `TomlCodec AgentConfig`. seal-harness already
depends on `tomland` (used in `Seal.Config.File`). The codec is a small
subset:

```haskell
data DirAgentConfig = DirAgentConfig
  { dacModel    :: Maybe Text
  , dacProvider :: Maybe Text
  , dacTools    :: Maybe Text   -- "all" or JSON-array string; reused from flat codec
  }

dirAgentConfigCodec :: TomlCodec DirAgentConfig
dirAgentConfigCodec = DirAgentConfig
  <$> dioptional (Toml.text "model")    .= dacModel
  <*> dioptional (Toml.text "provider") .= dacProvider
  <*> dioptional (Toml.text "tools")    .= dacTools
```

The frontmatter fence splitter needs to return the **raw inner block**
(not a pre-parsed map). The existing `Seal.Store.Markdown.splitFrontmatter`
parses the inner block as YAML-ish `key: value` lines before returning, so
it cannot be reused directly. We add a small additive function
`splitFrontmatterRaw :: Text -> (Maybe Text, Text)` to
`Seal.Store.Markdown` that mirrors PureClaw's `extractFrontmatter`
(AgentDef.hs:91-100): recognizes a leading `---\n`, a terminating `\n---\n`,
returns the raw inner block as `Just text` (or `Nothing` if no fence) and
the body after the closer. `splitFrontmatter` is unchanged.

**Why not extend the flat YAML-ish codec to also live in `AGENTS.md`?**
Because PureClaw already uses TOML frontmatter on `AGENTS.md`, and the
user wants to read existing PureClaw-style dirs. Two frontmatter dialects
in one file is a non-starter.

### 3.4 System-prompt composition

New code folded into `Seal.Agent.Def.Backend.hs` (no separate module —
~80 lines total, two new modules would be over-fragmentation). Mirrors
PureClaw's `composeAgentPrompt`:

```haskell
composeDirSystemPrompt
  :: FilePath          -- agent dir
  -> Int               -- per-file char limit
  -> IO Text           -- composed prompt (empty if all sections missing)
```

Section order: `SOUL.md`, `USER.md`, `AGENTS.md` (body after frontmatter),
`MEMORY.md`, `IDENTITY.md`, `TOOLS.md`, `BOOTSTRAP.md`. Missing/empty/
oversized files (>1MiB) are skipped. Each surviving section is rendered as
`--- <NAME> ---\n<body>`, joined with `\n\n`. Sections exceeding the limit
are truncated with PureClaw's exact marker:
`\n[...truncated at <limit> chars...]`.

The composed prompt is **stored in `adSystem`** at read time
(`adbRead` / `adbList` compose eagerly). Rationale: the existing
`AGENT_START` worker-builder (`Cli.hs:233`) reads `adSystem` once and
passes it to `runTurn`; composing at read time keeps the worker code
unchanged and preserves the testability seam (the Phase5Spec fake
`mkWorker` doesn't touch disk). Cost: O(filesize) per read — acceptable;
agent dirs are small and reads are infrequent.

**Empty-composition encoding**: if all bootstrap files are missing/empty,
the composed prompt is `""`. This is stored as `adSystem = Nothing`
(matches flat-scheme behavior at `Backend.hs:113`:
`if T.null body then Nothing else Just body`) and renders as `(none)` in
`renderDef` (`Ops/Agent.hs:386`).

### 3.5 Discovery algorithm

`listAgentDefs` becomes:

```
entries = listDirectory agentsDir
flat    = [e | e <- entries, ".md" isSuffixOf e]                  -- existing
dirs    = [e | e <- entries, isDirectory (agentsDir </> e)
                && isValidAgentDefId (pack e) ]                  -- new
flatDefs = map (decodeAgentDef <=< readFile) flat                -- existing
dirDefs  = map (loadDirAgentDef agentsDir) dirs                  -- new
sortOn adId (catMaybes (flatDefs ++ dirDefs))
```

Conflict policy: if both `agents/zoe.md` and `agents/zoe/` exist, the
flat file wins (it's the model-authored form; the directory is the
human-authored form; flat is more authoritative because it carries
timestamps and provenance). Document this; don't deduplicate silently —
emit a log warning if both exist.

### 3.6 `adbRead` for DirScheme

`adbRead aid`:
1. Try flat: `agents/<id>.md` → decode as today. If present, return it.
2. Else try dir: `agents/<id>/` exists? → compose config + system prompt,
   return the `AgentDef`.
3. Else `Nothing`.

### 3.7 `adbUpdate` (write path) — directories are a one-time import

`adbUpdate` writes the flat `agents/<id>.md` file for both schemes. If a
directory `agents/<id>/` exists, `adbUpdate` writes the flat file alongside
it; the next `adbRead` returns the flat (per conflict policy above).

**This is the intended UX**: directories are a **one-time import path**.
A user drops `agents/zoe/` in; seal-harness reads it; the first
`AGENT_DEF_CREATE` or `AGENT_DEF_UPDATE` for `zoe` flattens it into
`agents/zoe.md` (taking the composed prompt as the flat body), which then
takes precedence. The user can delete the original directory at their
leisure. No refusal logic, no scheme tagging, no special-casing — the
flat file is simply the authoritative form going forward.

This means `AGENT_DEF_UPDATE` on a DirScheme agent is a *flattening*
operation, not a destructive shadowing one: the composed prompt is
preserved verbatim as the flat file's body. The dir files remain on disk
until the user removes them; they're just no longer read once the flat
file exists.

### 3.8 `encodeDefRecorded` — composed prompt recorded in full

`encodeDefRecorded` (`Ops/Agent.hs:361`) records `adSystem` in full into
the `orRecorded` payload. For a DirScheme agent this is the composed
prompt — potentially multi-KB. This is **accepted as-is**: the
transitional DirScheme state is bounded by the flattening behavior in
§3.7 (a `CREATE`/`UPDATE` flattens the dir into a single `.md`, after
which the flat body is the recorded text, same as today). The
multi-KB-read scenario only arises when the model `AGENT_DEF_READ`s a
DirScheme agent *before* any flattening has happened — a one-time cost
per import, not a recurring one. No manifest, no digest, no truncation.

### 3.9 `Command.Agent` rendering

`renderAgentLine` and `renderAgentInfo` are unchanged — they read fields
off `AgentDef`, which the backend populates identically for both schemes.
For a DirScheme agent with empty `adProvider`/`adModel`, the line will
read `zoe  zoe  (/)` — acceptable for `/agent list`; `/agent info` can
show `(inferred at start)` next to empty provider/model if we want
nicety. Keep it simple for now: render the empty strings as `(default)`
in `renderAgentLine` only. Optional polish; can defer.

## 4. File scope

| File | Change |
|---|---|
| `src/Seal/Store/Markdown.hs` | Add `splitFrontmatterRaw :: Text -> (Maybe Text, Text)` (additive; mirrors PureClaw `extractFrontmatter`). `splitFrontmatter` unchanged. |
| `src/Seal/Agent/Def/Backend.hs` | Add DirScheme discovery + `loadDirAgentDef` + `composeDirSystemPrompt` + `DirAgentConfig` codec (folded in, no new modules); conflict policy (flat wins) |
| `src/Seal/Agent/Def/Types.hs` | No change (DirScheme is a backend-internal concept; no scheme tag on `AgentDef`) |
| `src/Seal/ISA/Ops/Agent.hs` | No change (the opcode layer is scheme-agnostic; `encodeDefRecorded` records `adSystem` in full as today) |
| `src/Seal/Channel/Cli.hs` | `mkWorker` resolves provider/model from def; on empty `adProvider`/`adModel`, fall back to active session's `smProvider`/`smModel` (symmetric). |
| `src/Seal/Command/Agent.hs` | Cosmetic: render empty provider/model as `(default)` in `renderAgentLine`. |
| `test/Seal/Phase5Spec.hs` | Existing capstone unchanged (flat writes). Add a new `it` case for DirScheme discovery + composition. |
| `test/Seal/Agent/Def/BackendSpec.hs` (NEW) | Unit tests for `DirAgentConfig` codec + `composeDirSystemPrompt` + conflict policy. |
| `test/Main.hs` | Wire new `BackendSpec` into the hspec entry point. |
| `seal-harness.cabal` | No new `exposed-modules` (folded into `Backend.hs`); add `test/Seal/Agent/Def/BackendSpec.hs` to test `other-modules`. |

## 5. Definition of Done

- [ ] `cabal build all` is `-Werror` clean (Nix dev shell).
- [ ] `cabal test` green; 0 failures, 0 new pending beyond the pre-existing 6.
- [ ] `hlint src/ test/` clean.
- [ ] `/agent list` against the user's real `~/.seal/config/agents/zoe/`
      shows the `zoe` agent (no manual `zoe.md` needed).
- [ ] `/agent info zoe` shows provider/model (inferred from `AGENTS.md`
      frontmatter or empty), composed system prompt rendered.
- [ ] `AGENT_DEF_CREATE` still writes `agents/<id>.md`; the capstone test
      (which asserts `agents/worker.md` exists) stays green.
- [ ] A new unit test asserts: given `agents/zoe/{SOUL.md,AGENTS.md}`,
      `adbList` returns one def with `adId=zoe`, `adSystem` composed from
      both files in PureClaw order with `--- SOUL ---` / `--- AGENTS ---`
      markers.
- [ ] A new unit test asserts: per-file truncation marker fires at the
      configured limit.
- [ ] A new unit test asserts: per-file truncation marker fires at the
      configured limit.
- [ ] A new unit test asserts: a >1MiB bootstrap file is skipped.
- [ ] A new unit test asserts: DirScheme agent with no bootstrap files →
      `adbRead` returns def with `adSystem = Nothing`.
- [ ] Conflict policy test: both `agents/foo.md` and `agents/foo/` exist
      → flat wins, log warning emitted.
- [ ] A new unit test asserts: `AGENT_DEF_UPDATE` on a DirScheme agent
      writes `agents/<id>.md` (flattening); subsequent `adbRead` returns
      the flat form with the composed prompt preserved as the body.
- [ ] A new unit test asserts: `resolveDefProvider pr "" (ModelId "")`
      falls back to the active session's provider+model (symmetric
      fallback for empty def fields).

## 6. Human checkpoints

1. **After implementation lands and tests pass** — manual UAT: delete the
   bootstrap `~/.seal/config/agents/zoe.md` (created earlier as a
   stopgap), then `make tui` → `/agent list` shows `zoe` (read from
   `zoe/` directory) → `/agent info zoe` shows the composed prompt →
   (optional) `/agent default zoe` then start the zoe agent and verify
   the composed prompt actually reaches the model.

## 7. Risks / open questions

- **Frontmatter dialect collision.** A hand-authored `AGENTS.md` with
  YAML-ish (`key: value`) frontmatter instead of TOML will fail
  `Toml.decode` and fall back to `defaultDirAgentConfig` (model/tools
  absent → `AllowAll` + empty model). This is the same permissive
  fallback PureClaw uses. Document; don't try to autodetect the dialect.
- **`MEMORY.md` double-duty.** PureClaw reads `MEMORY.md` as a bootstrap
  section; seal-harness has a separate `config/memory/` store. The
  DirScheme's `MEMORY.md` is the agent's *personal* long-term memory
  (in PureClaw's sense), not the same as the `config/memory/*.md`
  global memories. They coexist; no merge.
- **Provider fallback precedence.** §3.2: empty `adProvider`/`adModel`
  → session's provider/model. This couples AGENT_START to the parent
  session's provider, which is currently `ollama` always (the only
  provider). If a multi-provider setup emerges, revisit. A non-empty-
  but-unknown provider still fails with the existing error (fallback
  fires only on empty strings).
- **Composition cost.** Composing the prompt at `adbRead` time means
  every `/agent list` reads every DirScheme agent's bootstrap files.
  For <100 agents with <10KiB files this is negligible; flag if it
  becomes hot.
- **Timestamp instability.** DirScheme timestamps come from file mtime,
  which `git checkout`/`git pull` resets to checkout time. Currently
  harmless (`/agent list` sorts by name), but a known limitation.
- **Transcript size for DirScheme reads.** `encodeDefRecorded` records
  the full composed prompt on `AGENT_DEF_READ`. Accepted: bounded by
  the flattening behavior (§3.7) — a one-time cost per import, not
  recurring.

## 8. Out of scope / explicitly deferred

- PureClaw's `workspace` validation + `ensureDefaultWorkspace`.
- PureClaw's `tool_profile` text label.
- Mutating DirScheme agents via opcodes (model can only write flat;
  `AGENT_DEF_UPDATE` flattens — see §3.7).
- Off-box git mirror (already deferred in handoff §10).
- Removing the `Audited` `TrustLevel` constructor (handoff §8).