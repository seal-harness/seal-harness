---
title: "Seal Harness Memory System — Vision & Roadmap"
created: 2026-09-19
updated: 2026-09-19
status: active
tags: [seal-harness, memory-system, architecture, roadmap, trusted-untrusted, engram]
related:
  - agent-memory-architecture.md — Anthropic 5-layer model
  - design-ideas.md — Edit-survival observability, AHE component decomposition
  - isa-plan.md — SealOp ISA specification (§3.1 Memory)
  - seallang-design.md — SealLang DSL spec
---

# Seal Harness Memory System — Vision & Roadmap

## Core Design

Memory is a file-based store on the trusted Harness Machine. Files are append-only (no mutation, no deletion), indexed by engram for semantic search, and organized into directory hierarchies by the agent. The system is intentionally simple: four opcodes, two directories, one search index.

### Key Principles

1. **Memory is not agent definition.** Anything injected into the system prompt (persona, preferences, instructions) is an agent concern, not a memory concern. Memory is for facts, observations, and lessons the agent needs to recall on demand — not for shaping every turn.

2. **Memory is immutable and append-only.** You cannot overwrite or patch a memory file. To change a fact, archive the old memory and write a new one. This preserves full history, makes conflict resolution explicit, and keeps the system simple.

3. **Memory is never deleted, only archived.** Active memories live in `active/`, archived memories live in `archived/`. Archive is a move, not a delete. The full history is always recoverable.

4. **Memory is file-based.** One file per memory, organized into directory hierarchies. Human-readable, git-trackable, debuggable with standard tools. No database.

5. **Memory search is semantic.** engram (or a pluggable equivalent) indexes all memory files. Search returns ranked results by meaning, not just keyword match.

---

## Architecture

```
~/.seal/memory/
├── active/          ← live memory files
│   ├── user/
│   │   ├── preferences.md
│   │   └── timezone.md
│   ├── projects/
│   │   ├── pureclaw/
│   │   │   ├── architecture.md
│   │   │   └── sprint-status.md
│   │   └── vtag/
│   │       └── camera-selection.md
│   ├── env/
│   │   ├── spark-01.md
│   │   └── nebula-mesh.md
│   └── lessons/
│       └── haskell-beam-quirks.md
├── archived/        ← superseded or stale memories (timestamped to avoid collisions)
│   └── user/
│       └── 20260919T143000Z-old-location.md
└── engram.db        ← engram index (separate from KB index)
```

Both `active/` and `archived/` support arbitrary directory hierarchies. The agent organizes memories however it wants — the directory structure is the agent's filing system. The harness doesn't impose a schema on the hierarchy.

### Trust Model

All memory files live on the **Harness Machine** (trusted). They are:
- Written by the agent via MEMORY_WRITE (trusted opcode)
- Read by the agent via MEMORY_READ (trusted opcode)
- Searched via MEMORY_SEARCH (trusted opcode, engram subprocess)
- Never directly accessible to untrusted execution workers

Untrusted workers access memory through trusted opcode dispatch — same pattern as all trusted opcodes. The worker calls the opcode, the harness executes it on the trusted machine, results cross back. See the Trusted/Untrusted section below.

---

## Opcodes

Four opcodes. That's the entire memory system.

### MEMORY_WRITE

```
MEMORY_WRITE  TRUSTED
  Input:  { path: text, content: text }
  Output: { path: text, indexed: bool }
  
  Writes a new memory file at the given path under active/.
  Path is relative to active/ — e.g. "projects/pureclaw/architecture.md"
  creates ~/.seal/memory/active/projects/pureclaw/architecture.md.
  
  Fails if the file already exists (append-only / immutable).
  The agent must archive the existing memory first, then write the new one.
  
  After writing, the file is added to the engram index.
  Atomicity: file write is atomic (temp + rename). If engram indexing
  fails, the file still exists — a periodic reconciliation cron re-indexes
  any files that are in active/ but not in the index.
```

### MEMORY_READ

```
MEMORY_READ  TRUSTED
  Input:  { path: text }
  Output: { path: text, content: text, exists: bool }
  
  Reads a memory file by path (relative to active/).
  Returns the full file content.
  
  If the file doesn't exist in active/, checks archived/ and returns
  it with an "archived: true" flag. This lets the agent read superseded
  memories when needed.
```

### MEMORY_LIST

```
MEMORY_LIST  TRUSTED
  Input:  { prefix: text, include_archived?: bool }
  Output: { entries: [text], count: uint }
  
  Lists memory file paths matching the given prefix.
  Prefix is a directory path — e.g. "projects/pureclaw/" returns
  all files under that directory.
  
  Returns paths relative to active/ (or archived/ if include_archived).
  By default, only active/ entries are returned.
  
  This is the "what memories do I have about X?" browse operation.
  It does not return file contents — use MEMORY_READ for that.
```

### MEMORY_SEARCH

```
MEMORY_SEARCH  TRUSTED
  Input:  { query: text, limit?: uint, include_archived?: bool }
  Output: { results: [{ path, content, score }], total_matches: uint }
  
  Semantic search over memory files via engram (or pluggable backend).
  Returns ranked results by meaning, not keyword match.
  
  By default, searches only active/ memories.
  Set include_archived: true to also search archived/.
  
  limit defaults to 10. total_matches tells the model how many results
  exist beyond the returned set.
```

### MEMORY_ARCHIVE

```
MEMORY_ARCHIVE  TRUSTED
  Input:  { path: text }
  Output: { path: text, archived_path: text }
  
  Moves a memory file from active/ to archived/.
  The directory hierarchy is preserved — archiving "projects/pureclaw/old-spec.md"
  moves it to "archived/projects/pureclaw/{timestamp}-old-spec.md".
  
  The archived filename is prefixed with a timestamp (e.g. "20260919T143000Z-")
  to prevent collisions when the same path is archived multiple times across
  the agent's lifetime (write new → archive → write new → archive again).
  
  After moving, the engram index is updated (the file's path changes
  in the index so MEMORY_SEARCH can distinguish active vs archived).
  
  This is the only way to "remove" a memory. The file is never deleted.
```

---

## Immutability and Effective Mutation

Memory files are write-once. MEMORY_WRITE fails if the path already exists in `active/`. There is no MEMORY_PATCH, no MEMORY_UPDATE, no in-place edit.

**How the agent updates a fact:**

1. `MEMORY_ARCHIVE(path="user/timezone.md")` — archive the old memory
2. `MEMORY_WRITE(path="user/timezone.md", content="User is now UTC-5...")` — write the new one

This is deliberate:
- **Full audit trail.** The archived memory is still there. You can always see what the agent used to believe and when it changed.
- **No merge conflicts.** No read-modify-write race conditions. Write is create-only.
- **Simplicity.** Four opcodes, no update logic, no diff/patch, no conflict resolution.
- **Consistent with transcript philosophy.** The transcript is append-only; memory is too.

The agent can always read archived memories via MEMORY_READ (which falls back to archived/) or MEMORY_SEARCH with `include_archived: true`. The history is never lost.

---

## Engram Integration

### How It Works

engram is our existing semantic search utility:
- Rust binary at `~/.local/bin/engram`
- SQLite-vec backend, `ollama/nomic-embed-text` embeddings (768 dimensions)
- Commands: `add`, `search`, `remove`, `rebuild`, `status`

The memory system uses a **separate engram index** from the KB:

```
~/.engram/index.db          — KB index (existing)
~/.seal/memory/engram.db    — Seal Harness memory index
```

### Index Lifecycle

- **MEMORY_WRITE** → `engram add <file>` (index the new file)
- **MEMORY_ARCHIVE** → `engram remove <old-path>` + `engram add <new-path>` (re-index under archived/ path so search can filter by active/archived)
- **MEMORY_SEARCH** → `engram search "<query>" --limit N` (subprocess, parse JSON results)
- **MEMORY_READ** → no engram interaction (direct file read)
- **MEMORY_LIST** → no engram interaction (directory listing)

### Reconciliation

A periodic cron job (daily) scans `active/` and `archived/` and reconciles the engram index:
- Files in the directory but not in the index → `engram add`
- Files in the index but not in the directory → `engram remove` (stale index entries)
- This catches any indexing failures from crashed writes

### Pluggable Embedding Backend

The embedding tool is a **top-level Seal Harness concern**, not specific to memory. The same embedding backend is used for memory search, session search, and any future feature that needs semantic retrieval. Configuration lives at the top level, not under `memory:`.

The embedding interface is a **typeclass** (Haskell) so different backends can be dropped in:

```haskell
class EmbeddingBackend m where
  index      :: FilePath -> Text -> m ()       -- add file to index
  unindex    :: FilePath -> m ()               -- remove file from index
  search     :: Text -> Int -> m [SearchResult] -- semantic search
  backendName :: m Text
```

**Ships with:**
1. **engram backend** — subprocess to engram CLI. Zero new infrastructure.
2. **null backend** — no search, returns empty results. For development without ollama.

**Future backends (drop-in):**
- sqlite-vec direct — skip subprocess overhead
- OpenAI embeddings API — for cloud deployments
- Custom fine-tuned models — for specialized domains

**Configuration:**

```yaml
embedding:
  backend: engram          # engram | null | (future: openai, custom)
  engram:
    binary_path: ~/.local/bin/engram
    # Each consumer (memory, session search, etc.) gets its own index path
    # via the backend's multi-index support or separate engram instances.
  # future:
  # openai:
  #   model: text-embedding-3-small
  #   api_key_env: OPENAI_API_KEY

memory:
  search:
    max_results: 10
    char_budget: 4000
    index_path: ~/.seal/memory/engram.db    # memory's engram index
```

---

## Trusted/Untrusted Memory Architecture

### The Principle

The Seal Harness memory system lives entirely on the **trusted Harness Machine**. This is the point of making memory a first-class harness feature rather than just letting agents use FILE_WRITE on the execution machine.

**Why first-class memory exists:** Agents can store whatever they want on the untrusted execution machine using FILE_WRITE / FILE_READ. That's fine for working files, build artifacts, scratch data. But when the harness provides memory as a managed service, it provides **behavioral guarantees that untrusted agents cannot violate:**

- **Immutability.** No agent can modify or delete a memory file. Write-once, archive-only. A rogue or compromised agent cannot rewrite history.
- **Full audit trail.** Every memory ever written is preserved — active or archived. You can always see what was believed and when it changed.
- **Trusted retrieval.** Memory search results come from the trusted machine. An untrusted agent cannot tamper with the index or inject fake results.
- **Access control.** (Future) Which agents can read which memories is enforced by the trusted harness, not by the agents themselves.

If memory lived on the untrusted machine, none of these guarantees would hold. A compromised agent could rewrite memories to manipulate future sessions, delete evidence of its own actions, or poison the search index. The trusted machine is the enforcement boundary.

### Architecture

```
┌──────────────────────────────────────┐     ┌──────────────────────────┐
│  Harness Machine (Trusted)           │     │  Execution Machine        │
│                                      │     │  (Untrusted)              │
│  ┌────────────────────────────────┐  │     │                          │
│  │ Memory System                  │  │     │  ┌────────────────────┐  │
│  │  ├─ active/    (live memories) │  │     │  │ Untrusted agents    │  │
│  │  ├─ archived/  (preserved)     │  │     │  │ can store whatever  │  │
│  │  └─ engram.db  (search index)  │◄─┼─────┼──│ they want here via  │  │
│  │                                │  │     │  │ FILE_WRITE/READ.    │  │
│  │  Guarantees:                   │  │     │  │ No immutability,    │  │
│  │  • Write-once (no mutation)    │  │     │  │ no audit trail,     │  │
│  │  • Archive-only (no deletion)  │  │     │  │ no search index.    │  │
│  │  • Trusted search results      │  │     │  │ Just files.         │  │
│  └────────────────────────────────┘  │     │  └────────────────────┘  │
│                                      │     │                          │
│  ┌────────────────────────────────┐  │     │                          │
│  │ Session DB (transcripts)       │  │     │                          │
│  └────────────────────────────────┘  │     │                          │
│                                      │     │                          │
└──────────────────────────────────────┘     └──────────────────────────┘
                   │
                   │ Trusted opcode dispatch
                   │ (MEMORY_WRITE, MEMORY_READ,
                   │  MEMORY_LIST, MEMORY_SEARCH,
                   │  MEMORY_ARCHIVE)
                   │
                   ▼
          Agent calls memory opcodes →
          harness executes on trusted machine →
          results returned to agent
```

### How Untrusted Workers Access Memory

Untrusted workers interact with memory exclusively through trusted opcode dispatch:

1. Worker calls a memory opcode (e.g. MEMORY_SEARCH)
2. Opcode is classified Trusted → dispatched to Harness Machine
3. Harness Machine executes the operation against the memory store
4. Results returned through the trusted dispatch path

The worker never touches memory files or the engram index directly. It only sees what the trusted opcodes return. This is the same dispatch pattern used for all trusted opcodes — memory isn't special in the dispatch mechanism, it's special in the guarantees the trusted store provides.

### What Lives Where

| Data | Location | Why |
|------|----------|-----|
| Memory files (active + archived) | Trusted | Immutability, audit trail, tamper resistance |
| engram search index | Trusted | Search results must be trustworthy |
| Session transcripts | Trusted | Audit trail, cross-session recall |
| Agent definitions (SOUL.md, etc.) | Trusted | Agent identity must not be forgeable |
| Build artifacts, scratch files | Untrusted | No guarantees needed, agents manage their own working files |

### Read-Only Mount in Untrusted Environment

The memory directory (`active/` only — `archived/` stays trusted-only) can be **mounted read-only** in the untrusted execution environment. The untrusted agent cannot modify memory files through this mount — read-only is enforced externally, not with an OS permission. But it can `grep` across both its own working files and trusted memory in a single command:

```bash
# Search across untrusted working files AND trusted memory in one shot
grep -r "haskell beam" /workspace/ /mnt/seal-memory/
```

This is useful for one-shot discovery where the agent needs to check both its local artifacts and the memory store without making two separate opcode calls. The read-only mount is a convenience — MEMORY_SEARCH via engram is still the primary search mechanism (semantic, ranked, budget-capped). The grep mount is for the "I just need to find a string" case.

**What's mounted:** `active/` only. Archived memories are not mounted — they're accessible only via MEMORY_READ (with automatic archived/ fallback) and MEMORY_SEARCH with `include_archived: true`, both through trusted opcode dispatch. This keeps the untrusted filesystem view clean and prevents archived clutter from polluting grep results.

### Cross-Session Queries

For queries spanning trusted memory and untrusted local artifacts:

```
Worker needs: "what do we know about X?"

1. Worker calls MEMORY_SEARCH (Trusted opcode)
   → Harness Machine searches engram index
   → Returns ranked memory results

2. Worker calls SESSION_SEARCH (Trusted opcode)
   → Harness Machine searches session transcripts
   → Returns scoped session results

3. Worker locally searches its own artifacts
   → Filesystem search on Execution Machine
   → No trust boundary crossed

4. Worker synthesizes results
   → Combines trusted query results + local artifacts
```

**Key invariant:** Trusted data crosses the boundary exactly once, through trusted opcode dispatch. The untrusted machine can combine it with its own data but can never reach back for unfiltered access.

---

## What's NOT Here (Deferred to Later)

Everything below is explicitly out of scope for the first implementation. These are good ideas that can be built on top of the file-based foundation later.

- **Knowledge graph** (entities, relationships, graph traversal) — not needed yet. The directory hierarchy provides basic organization.
- **Forgetting layer** (contradiction detection, staleness decay, consolidation policies) — the archive model handles this at a basic level. The agent archives stale memories and writes new ones. Automated consolidation is a later enhancement.
- **Episodic bridge** (MEMORY_PROMOTE, MEMORY_TRACE, provenance linking) — can be added later by writing provenance metadata into memory file content (it's just text).
- **Observability** (reference tracking, access logging, MEMORY_STATS) — can be added later by logging access to a file or adding metadata to frontmatter.
- **Layered distillation** (L0→L3 pipeline from TencentDB Agent Memory) — long-term roadmap. The file-based system is the foundation it would build on.
- **Typed memory assets** (Chat Memory / Skills / Wiki / CodeGraph) — long-term. The directory hierarchy is the lightweight version of this.
- **Team memory sharing** (ACLs, agent loadout, privacy tiers) — V3 territory.
- **System prompt injection** — explicitly NOT a memory concern. Agent definitions handle what goes in the system prompt. Memory is recall-on-demand.

---

## Comparison to Hermes

Hermes has a single `memory` tool with `add`/`replace`/`remove`/`apply_batch` actions, operating on two flat files (MEMORY.md + USER.md) that are injected into the system prompt. Seal Harness's memory system differs fundamentally:

| Dimension | Hermes | Seal Harness |
|-----------|--------|--------------|
| System prompt injection | Yes — memory IS the system prompt | No — memory is recall-on-demand |
| Storage | Two flat files | Directory hierarchy of files |
| Mutation | replace/remove in place | Immutable — archive + write new |
| Deletion | remove (entry gone) | Archive (never deleted) |
| Search | None (it's in the prompt) | Semantic via engram |
| Organization | None (flat list) | Directory hierarchy |
| System prompt role | Memory and persona are the same thing | Memory and agent definition are separate concerns |

The key architectural difference: **Hermes conflates memory with agent definition.** MEMORY.md and USER.md shape every turn because they're in the system prompt. Seal Harness separates these — agent definitions (SOUL.md, etc.) go in the system prompt, memory is searched when needed. This keeps the system prompt small and stable (preserving prefix cache) while allowing unlimited memory growth.

---

## Research Foundations

| Source | Key Insight | How We Apply It |
|--------|-------------|-----------------|
| Anthropic 5-layer model | Forgetting layer is the biggest gap | Archive mechanism is the first-cut forgetting layer |
| AHE (2604.25850) | Memory is largest single-component harness gain (+5.6pp) | Justifies memory as a first-class system |
| MemoHarness (2607.14159) | Dual-layer experience bank | Long-term: distillation pipeline on top of file-based store |
| TencentDB Agent Memory | Typed assets, agent loadout, L0-L3 pipeline | Long-term roadmap |
| FinMem | Episodic memory has largest ablation impact (-6.7%) | SESSION_SEARCH already handles episodic; memory system is complementary |
| Edit-survival (Mighty's idea) | Zero-cost within-session feedback | Can be added later via memory access logging |

---

## Open Questions

1. **engram incremental add/remove.** Can engram v0.1.0 incrementally add/remove individual files, or does it require a full rebuild? The memory system needs incremental operations on every WRITE and ARCHIVE. If engram doesn't support this, we need to enhance engram or use a different backend.

2. **engram path-based filtering.** MEMORY_SEARCH needs to distinguish active vs archived results. Options: (a) maintain separate engram indexes for active/ and archived/, (b) use one index and filter results by path after search, (c) use engram's metadata features if available. Need to check engram's capabilities.

3. **File format: plain text or frontmatter?** The simplest approach is plain text (memory content is just the file body). If we later need metadata (created date, tags, provenance), YAML frontmatter can be added without breaking plain-text reads. Start with plain text, add frontmatter when needed.

4. **Should MEMORY_READ fall back to archived/ automatically?** Current design: yes, returns archived content with a flag. Alternative: require explicit `include_archived` flag like MEMORY_LIST and MEMORY_SEARCH. The automatic fallback is more convenient but could surprise the agent.

5. **Multi-harness memory federation.** Long-term: how do multiple Seal Harness instances share memory? Network protocol? Shared filesystem? This is a V3+ question.

6. **Embedding model versioning.** When swapping embedding models, the engram index needs rebuilding. How to handle gracefully — version the index, rebuild in background, cut over atomically?

---

## Related Documents

- `agent-memory-architecture.md` — Anthropic 5-layer model source material
- `design-ideas.md` — Edit-survival observability, AHE component decomposition
- `isa-plan.md` — SealOp ISA specification (§3.1 Memory opcodes)
- `seallang-design.md` — SealLang DSL spec (memory primitives)
- `memory-system-plan.md` — Earlier implementation plan (now superseded by this document for the first cut; still useful for later phases)
- [TencentDB Agent Memory](https://github.com/TencentCloud/TencentDB-Agent-Memory) — Long-term architectural inspiration
- [MemoHarness paper](https://arxiv.org/abs/2607.14159) — Dual-layer experience bank
- [AHE paper](https://arxiv.org/abs/2604.25850) — Observability-driven harness evolution
- [engram](https://github.com/nousresearch/engram) — Semantic search utility (local)