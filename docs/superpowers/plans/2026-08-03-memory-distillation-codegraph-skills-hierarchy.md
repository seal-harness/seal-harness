# Memory Distillation, CodeGraph, and Skills Hierarchy — Implementation Plan

> **For agentic workers:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Steal the best ideas from TencentDB Agent Memory — layered conversation distillation (L0→L3), CodeGraph, and cold-start import — and implement them in Seal Harness's Haskell architecture. Also augment the skills system to support the full Agent Skills directory hierarchy standard (public/private/examples three-tier, as revealed by the Claude Fable 5 system prompt).

**Architecture:** All new features build on the existing Phase 5 git-backed Markdown stores. Layered distillation adds an async LLM pipeline that processes session transcripts into progressively refined memory layers (L1 atoms, L2 scenarios, L3 persona). CodeGraph adds code symbol/call-graph indexing as a new asset type. Cold-start import hooks into the repo-add workflow. Skills hierarchy adds a three-tier directory layout with read-only enforcement for builtin and example tiers.

**Tech Stack:** GHC 9.12, Cabal, Nix, `sqlite-simple` (FTS5 for keyword search), existing provider abstraction (for LLM calls in distillation pipeline), existing `Seal.Git.Repo` (versioning), existing `Seal.Memory.Backend` (Markdown + git auto-commit).

---

## Context

### What we're stealing from TencentDB Agent Memory

Tencent's system has four genuinely good ideas buried in a TypeScript/Node.js codebase with beta-quality execution:

1. **Layered distillation (L0→L3):** Raw conversations (L0) are distilled into atoms (L1 facts/preferences/events), scenarios (L2 project-organized knowledge blocks), and persona (L3 long-term profile). Each layer is progressively more compressed and more valuable. This means old session transcripts can be safely deleted because the distilled knowledge persists.

2. **CodeGraph:** Index code symbols, files, call relationships, and impact paths. Agents can search, read, and do impact analysis before modifying code. Tencent uses an external "CodeGraph" library; we'll build a Haskell-native version.

3. **Cold-start import:** When a user adds a repo, auto-index it (CodeGraph) and auto-generate structured doc pages (Wiki). Tencent does this through their Memory Hub panel; we'll hook into the repo-add event in the frontend.

4. **Skills as first-class objects with versions, trigger boundaries, execution steps, and validation rules.** We already have this. Tencent acknowledges using Hermes Agent's skill code as a base. Our Seal skills are already first-class Markdown files with frontmatter, git versioning, and ISA opcodes.

### What we already have and don't need to rebuild

- **Skills storage and management** — `~/.seal/config/skills/<id>.md` with frontmatter (`id`, `description`, `created_at`, `updated_at`, `session`), union backend (builtins + user), SKILL_WRITE/LOAD/LIST/DELETE opcodes, git auto-commit. DONE in Phase 5.
- **Memory storage** — `~/.seal/config/memory/<id>.md` with the same pattern. MEMORY_STORE/RECALL/LIST/UPDATE/DELETE opcodes. DONE in Phase 5.
- **Session transcripts** — `~/.seal/state/sessions/<session-id>/conversation.jsonl` + `entries.jsonl`, two-file format, append-only, fsync. DONE.
- **Versioning** — `~/.seal/config/` is a git repo with one commit per opcode mutation. No need for Tencent's separate versioning layer.
- **Agent definitions** — `~/.seal/config/agents/<id>.md`. DONE.
- **Visibility/trust model** — Untrusted/Trusted/Audited. Tencent's private/team/restricted/agent ACLs are over-engineered for our current needs. We can add more levels later if we need them.

### What we're explicitly NOT doing

- **No web panel** (Tencent's "Memory Hub"). Our frontend (Phase 7) will render these features, not a separate panel.
- **No TencentDB lock-in.** Everything is local SQLite + Markdown + git.
- **No multi-agent team ACLs.** Trusted/untrusted is sufficient for now.
- **No Wiki layer.** Our knowledge base already serves this purpose. CodeGraph is the higher-value addition.
- **No BM25 + vector + RRF hybrid retrieval (yet).** Start with FTS5 keyword search. Add vector search later if retrieval quality demands it. YAGNI.

---

## Phase 1: Skills Directory Hierarchy

### Objective

Augment the skills system to support the three-tier directory hierarchy standard (as revealed by the Claude Fable 5 system prompt): builtin (read-only, compile-time embedded), user (writable via SKILL_WRITE), and examples (read-only templates).

### Current state

- Builtins: embedded in binary via `file-embed`, served by `unionSkillBackend` as the fallback layer. Already read-only. (src/Seal/Skills/Builtins.hs)
- User skills: `~/.seal/config/skills/<id>.md`, writable via SKILL_WRITE. (src/Seal/Skills/Backend.hs)
- Union backend: user layer checked first, builtins as fallback. User overrides shadow builtins on id collision. (src/Seal/Skills/Backend.hs)
- No examples tier exists.

### Design

Add a third tier — **examples** — to the union backend. Examples are read-only Markdown files shipped with the Seal binary (embedded via `file-embed`, same as builtins) but serve as templates the model can copy to user space and modify. The resolution order becomes:

1. User skills (`~/.seal/config/skills/<id>.md`) — writable, highest priority
2. Example skills (embedded in binary, read-only) — templates, middle priority
3. Builtin skills (embedded in binary, read-only) — operational defaults, lowest priority

A new opcode `SKILL_COPY` lets the model copy a builtin or example skill to user space for editing. This mirrors Fable 5's "copy to writable location first" pattern.

### Tasks

### Task 1: Add example skills directory and embed mechanism

**Objective:** Create the `config/examples/` directory in the repo and wire up `file-embed` for example skills, parallel to the existing builtins mechanism.

**Files:**
- Create: `config/examples/seal-skill-template.md` (a template skill showing best practices)
- Create: `config/examples/code-review-checklist.md` (a practical example skill)
- Modify: `src/Seal/Skills/Builtins.hs` — add example embedding alongside builtins
- Test: `test/Seal/Skills/BuiltinsSpec.hs`

**Step 1: Write failing test**

```haskell
-- test/Seal/Skills/BuiltinsSpec.hs
module Seal.Skills.BuiltinsSpec (spec) where

import Test.Hspec
import Seal.Skills.Builtins

spec :: Spec
spec = do
  describe "builtinSkills" $ do
    it "includes seal-usage" $ do
      let ids = map fst builtinSkills
      ids `shouldContain` ["seal-usage"]

  describe "exampleSkills" $ do
    it "includes seal-skill-template" $ do
      let ids = map fst exampleSkills
      ids `shouldContain` ["seal-skill-template"]

    it "includes code-review-checklist" $ do
      let ids = map fst exampleSkills
      ids `shouldContain` ["code-review-checklist"]
```

**Step 2: Run test to verify failure**

Run: `nix develop --command cabal test seal-harness-test --test-options="--match Builtins"`
Expected: FAIL — `exampleSkills` not in scope

**Step 3: Create example skill files**

`config/examples/seal-skill-template.md`:
```markdown
---
id: seal-skill-template
description: Template for creating new skills. Copy this and customize.
created_at: 2026-08-03T00:00:00Z
updated_at: 2026-08-03T00:00:00Z
session: builtin
---

# Skill Template

## Purpose
[What this skill does and when to use it]

## Steps
1. [Numbered steps with exact commands]
2. [Each step is one action]

## Pitfalls
- [Known failure modes]
- [Things that look right but aren't]

## Verification
[How to confirm the task succeeded]
```

`config/examples/code-review-checklist.md`:
```markdown
---
id: code-review-checklist
description: Systematic code review checklist for Haskell projects. Use when reviewing PRs or doing self-review before commit.
created_at: 2026-08-03T00:00:00Z
updated_at: 2026-08-03T00:00:00Z
session: builtin
---

# Code Review Checklist

## Pre-Review
1. `nix develop --command cabal build all` — builds clean
2. `nix develop --command cabal test` — all tests pass
3. `nix develop --command hlint src/ test/` — no warnings

## Review
1. Types: No `forall` or `Any` hiding specificity. No `String` where `Text` is appropriate.
2. Errors: `Either Text` for simple cases. Typed error ADT only when pattern-matched for control flow.
3. Security: No secret ever serialized. `Show` instances redacted. No `ToJSON` for secret newtypes.
4. Imports: Whole-module imports. No explicit import lists unless ambiguity.
5. Extensions: GHC2021 baseline. Situational extensions via `{-# LANGUAGE #-}` pragmas only.
6. Pattern matches: No incomplete patterns. `-Wincomplete-uni-patterns` clean.
```

**Step 4: Add exampleSkills to Builtins module**

In `src/Seal/Skills/Builtins.hs`, add:

```haskell
import Data.FileEmbed (embedFile)

-- | Example skills embedded at compile time. Read-only templates.
exampleSkills :: [(Text, ByteString)]
exampleSkills =
  [ ("seal-skill-template", $(embedFile "config/examples/seal-skill-template.md"))
  , ("code-review-checklist", $(embedFile "config/examples/code-review-checklist.md"))
  ]
```

Also add `qAddDependentFile` lines so GHC recompiles when these files change.

**Step 5: Run test to verify pass**

Run: `nix develop --command cabal test seal-harness-test --test-options="--match Builtins"`
Expected: PASS

**Step 6: Commit**

```bash
git add config/examples/ src/Seal/Skills/Builtins.hs test/Seal/Skills/BuiltinsSpec.hs
git commit -m "feat(skills): add example skills tier (seal-skill-template, code-review-checklist)"
```

---

### Task 2: Extend union backend with examples tier

**Objective:** Add the examples tier to the `unionSkillBackend` resolution chain. User > examples > builtins.

**Files:**
- Modify: `src/Seal/Skills/Backend.hs` — add examples layer to union
- Test: `test/Seal/Skills/BackendSpec.hs`

**Step 1: Write failing test**

```haskell
-- test/Seal/Skills/BackendSpec.hs
-- Add to existing spec:
  describe "unionSkillBackend with examples" $ do
    it "returns user skill when it shadows example" $ do
      -- User skill with same id as an example should win
      ...

    it "returns example skill when no user skill exists" $ do
      -- Example skill should be returned when no user skill has that id
      ...

    it "returns builtin skill when no user or example skill exists" $ do
      -- Fallback to builtin
      ...
```

**Step 2: Run test to verify failure**

Run: `nix develop --command cabal test seal-harness-test --test-options="--match Backend"`
Expected: FAIL — examples layer not in union

**Step 3: Implement examples tier in union backend**

In `src/Seal/Skills/Backend.hs`, modify `unionSkillBackend` to accept three backends instead of two, or add an `exampleSkillBackend` (in-memory, like the builtin backend) and chain it in the union.

The union resolution becomes:
1. Check user backend (disk). If found, return.
2. Check example backend (in-memory from embedded files). If found, return.
3. Check builtin backend (in-memory from embedded files). If found, return.
4. Not found.

**Step 4: Run test to verify pass**

Run: `nix develop --command cabal test seal-harness-test --test-options="--match Backend"`
Expected: PASS

**Step 5: Commit**

```bash
git add src/Seal/Skills/Backend.hs test/Seal/Skills/BackendSpec.hs
git commit -m "feat(skills): add examples tier to union backend (user > examples > builtins)"
```

---

### Task 3: Add SKILL_COPY opcode

**Objective:** New ISA opcode that copies a read-only skill (builtin or example) to the user's writable skills directory. This mirrors Fable 5's "copy to writable location first" pattern.

**Files:**
- Modify: `src/Seal/ISA/Ops/Skills.hs` — add `SKILL_COPY`
- Modify: `src/Seal/ISA/Opcode.hs` — register the new opcode
- Test: `test/Seal/ISA/Ops/SkillsSpec.hs`

**Step 1: Write failing test**

```haskell
-- Test that SKILL_COPY copies a builtin skill to user space
-- and that the copied skill is writable (can be updated via SKILL_WRITE)
it "copies a builtin skill to user space" $ do
  -- setup: union backend with builtin "seal-usage", no user skill
  -- action: SKILL_COPY "seal-usage"
  -- assert: user skill file exists at ~/.seal/config/skills/seal-usage.md
  -- assert: SKILL_LOAD "seal-usage" returns the user copy (not builtin)
  -- assert: content matches builtin content
```

**Step 2: Run test to verify failure**

Run: `nix develop --command cabal test seal-harness-test --test-options="--match Skills"`
Expected: FAIL — `SKILL_COPY` not found

**Step 3: Implement SKILL_COPY opcode**

```haskell
-- src/Seal/ISA/Ops/Skills.hs

-- SKILL_COPY: Copy a read-only skill (builtin or example) to user space.
-- Input: { "id": "<skill-id>" }
-- Output: { "id": "<skill-id>", "copied_from": "builtin" | "example" }
-- Behavior:
--   1. Look up skill in union backend (user > examples > builtins)
--   2. If source is user skill, return error (already in user space)
--   3. Write the skill content to ~/.seal/config/skills/<id>.md via user backend
--   4. Auto-commit to git
-- Trust: Trusted (file write to config repo, like SKILL_WRITE)
```

**Step 4: Run test to verify pass**

Run: `nix develop --command cabal test seal-harness-test --test-options="--match Skills"`
Expected: PASS

**Step 5: Commit**

```bash
git add src/Seal/ISA/Ops/Skills.hs src/Seal/ISA/Opcode.hs test/Seal/ISA/Ops/SkillsSpec.hs
git commit -m "feat(isa): add SKILL_COPY opcode for copying read-only skills to user space"
```

---

### Task 4: Update SKILL_LIST to show tier origin

**Objective:** `SKILL_LIST` should indicate which tier each skill comes from (user/example/builtin), so the model knows what it can modify and what it needs to copy first.

**Files:**
- Modify: `src/Seal/Skills/Backend.hs` — `listSkills` returns tier info
- Modify: `src/Seal/ISA/Ops/Skills.hs` — `SKILL_LIST` includes tier in output
- Test: `test/Seal/ISA/Ops/SkillsSpec.hs`

**Step 1: Write failing test**

```haskell
it "SKILL_LIST shows tier for each skill" $ do
  -- User skill "my-skill" → tier: "user"
  -- Example skill "seal-skill-template" → tier: "example"
  -- Builtin skill "seal-usage" → tier: "builtin"
  -- User skill shadowing builtin "seal-usage" → tier: "user" (not "builtin")
```

**Step 2: Run test to verify failure**

Expected: FAIL — no tier field in output

**Step 3: Implement tier annotation**

Add a `SkillTier` type (`User | Example | Builtin`) and include it in the skill listing. The union backend's list operation merges all three tiers, marking each with its source, and user skills shadow lower tiers.

**Step 4: Run test to verify pass**

Expected: PASS

**Step 5: Commit**

```bash
git add src/Seal/Skills/Backend.hs src/Seal/ISA/Ops/Skills.hs test/Seal/ISA/Ops/SkillsSpec.hs
git commit -m "feat(skills): SKILL_LIST shows tier origin (user/example/builtin)"
```

---

### Task 5: Update seal-usage skill to document the hierarchy

**Objective:** The auto-loaded `seal-usage` skill should teach the model about the three-tier hierarchy, the `SKILL_COPY` opcode, and which skills are read-only.

**Files:**
- Modify: `config/skills/seal-usage.md`

**Step 1: Update the skill content**

Add a section explaining:
- Skills come in three tiers: user (writable), examples (read-only templates), builtin (read-only)
- Use `SKILL_COPY` to copy a read-only skill to user space before modifying it
- `SKILL_LIST` shows the tier for each skill
- User skills shadow builtins and examples on id collision

**Step 2: Build and verify**

Run: `nix develop --command cabal build all`
Expected: PASS (file-embed picks up the change)

**Step 3: Commit**

```bash
git add config/skills/seal-usage.md
git commit -m "docs(skills): document three-tier hierarchy and SKILL_COPY in seal-usage skill"
```

---

## Phase 2: Layered Memory Distillation

### Objective

Implement the L0→L1→L2→L3 conversation distillation pipeline. Raw session transcripts (L0, already captured) are distilled into progressively refined memory layers by an async LLM pipeline. This makes old session transcripts safely deletable — the distilled knowledge persists in L1-L3.

### Design

**Layers:**
- **L0 (Conversation)** — Existing session transcripts (`conversation.jsonl` + `entries.jsonl`). No new work. This is the raw input to the pipeline.
- **L1 (Atoms)** — Extracted facts, preferences, constraints, and events. Stored as individual Markdown files in `~/.seal/config/memory/l1/<id>.md` with frontmatter (`id`, `type`, `priority`, `source_session`, `source_message_ids`, `created_at`). Types: `persona` (stable attributes), `episodic` (events with timestamps), `instruction` (behavioral rules).
- **L2 (Scenarios)** — Knowledge blocks organized around projects or themes. Stored as Markdown files in `~/.seal/config/memory/l2/<id>.md` with frontmatter (`id`, `summary`, `heat`, `created_at`, `updated_at`). Each scenario is a coherent narrative (≤1500 chars) aggregating related L1 atoms.
- **L3 (Persona)** — Long-term profile, stable patterns, high-level cognition. A single `~/.seal/config/memory/l3/persona.md` file with structured sections: User Narrative Profile, Archetype, Basic Information, Long-term Preferences, Interaction & Cognitive Protocol, Deep Insights & Evolution. Updated incrementally.

**Pipeline:**
- Runs as a background task when a tab is closed (or during idle periods).
- L1 extraction: One LLM call per batch of ~5 conversation turns. Extracts atoms with type/priority/source references.
- L2 scenario consolidation: One LLM call after L1 processes new atoms. Organizes atoms into scenario files (max 15 scenarios, each ≤1500 chars). Uses file-based workspace (read/write Markdown files in a temp dir, like Tencent's scene_blocks approach).
- L3 persona update: One LLM call after L2 completes (or every ~50 new L1 atoms). Incremental update of the persona.md file.
- All LLM calls use the existing provider abstraction (`Seal.Providers`).
- Each layer is git-committed to the config repo via the existing auto-commit mechanism.

**Retrieval:**
- At session start, inject L3 persona and L2 scenario summaries into the system prompt (stable, cacheable — like Tencent's `appendSystemContext`).
- During conversation, L1 atoms are retrieved via FTS5 keyword search on the current query, injected into the user prompt prefix (dynamic, per-turn — like Tencent's `prependContext`).
- Character budgets prevent memory from overwhelming the context window: `maxTotalRecallChars` (default 2000), `maxCharsPerMemory` (default 500).
- New ISA opcodes for explicit memory search: `MEMORY_SEARCH` (keyword search across L1-L3) and `MEMORY_CONTEXT` (load full L2 scenario or L3 persona on demand).

**Storage layout:**
```
~/.seal/config/memory/
├── l1/                    ← L1 atoms (one .md per atom)
│   ├── <id>.md
│   └── ...
├── l2/                    ← L2 scenarios (one .md per scenario)
│   ├── <id>.md
│   └── ...
├── l3/                    ← L3 persona (single file)
│   └── persona.md
└── <existing flat .md>    ← existing MEMORY_STORE entries (unchanged)
```

Existing `MEMORY_STORE`/`MEMORY_RECALL` opcodes continue to work on the flat `memory/` directory (ad-hoc memory). The new L1-L3 layers are managed by the distillation pipeline, not directly writable by the model (they're Trusted pipeline outputs, like git commits).

### Tasks

### Task 6: Define L1/L2/L3 types

**Objective:** Create the data types for the three memory layers.

**Files:**
- Create: `src/Seal/Memory/Distilled.hs`
- Test: `test/Seal/Memory/DistilledSpec.hs`

**Step 1: Write failing test**

```haskell
module Seal.Memory.DistilledSpec (spec) where

import Test.Hspec
import Seal.Memory.Distilled

spec :: Spec
spec = do
  describe "AtomType" $ do
    it "has persona, episodic, instruction constructors" $ do
      show Persona `shouldBe` "Persona"
      show Episodic `shouldBe` "Episodic"
      show Instruction `shouldBe` "Instruction"

  describe "L1Atom" $ do
    it "round-trips through Markdown" $ do
      let atom = L1Atom
            { aId = "20260803-020000-abc"
            , aType = Persona
            , aPriority = 75
            , aContent = "User prefers concise responses"
            , aSourceSession = "20260803-010000-xyz"
            , aSourceMessageIds = ["msg-1", "msg-3"]
            , aCreatedAt = read "2026-08-03T02:00:00Z"
            }
      let md = encodeL1Atom atom
      decodeL1Atom md `shouldBe` Right atom
```

**Step 2: Run test to verify failure**

Run: `nix develop --command cabal test seal-harness-test --test-options="--match Distilled"`
Expected: FAIL — module not found

**Step 3: Implement types**

```haskell
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module Seal.Memory.Distilled
  ( AtomType(..)
  , L1Atom(..)
  , L2Scenario(..)
  , L3Persona(..)
  , encodeL1Atom
  , decodeL1Atom
  , encodeL2Scenario
  , decodeL2Scenario
  , encodeL3Persona
  , decodeL3Persona
  ) where

import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Data.Aeson (Value)
import GHC.Generics (Generic)

-- | Classification of L1 atoms (from Tencent's l1-extraction prompt)
data AtomType = Persona | Episodic | Instruction
  deriving (Eq, Show, Generic, Enum, Bounded)

-- | L1: Extracted facts, preferences, constraints, events
data L1Atom = L1Atom
  { aId :: Text              -- ^ Unique atom ID (timestamp-based)
  , aType :: AtomType        -- ^ persona | episodic | instruction
  , aPriority :: Int         -- ^ -1 to 100 (higher = more important)
  , aContent :: Text         -- ^ The extracted fact/preference/event
  , aSourceSession :: Text   -- ^ Session ID the atom was extracted from
  , aSourceMessageIds :: [Text] -- ^ Message IDs in the source conversation
  , aCreatedAt :: UTCTime    -- ^ When this atom was created
  } deriving (Eq, Show, Generic)

-- | L2: Scenario — knowledge block organized around a project/theme
data L2Scenario = L2Scenario
  { sId :: Text              -- ^ Scenario ID (slugified name)
  , sSummary :: Text         -- ≤200 char summary
  , sHeat :: Int             -- Access count (higher = more active)
  , sBody :: Text             -- ≤1500 char narrative Markdown
  , sCreatedAt :: UTCTime
  , sUpdatedAt :: UTCTime
  } deriving (Eq, Show, Generic)

-- | L3: Persona — long-term user profile
data L3Persona = L3Persona
  { pNarrative :: Text       -- ^ User narrative profile
  , pArchetype :: Text       -- ^ User archetype
  , pBasicInfo :: Text       -- ^ Basic information
  , pPreferences :: Text     -- ^ Long-term preferences
  , pInteractionProtocol :: Text -- ^ Interaction & cognitive protocol
  , pDeepInsights :: Text    -- ^ Deep insights & evolution
  , pVersion :: Int          -- ^ Incremental version number
  , pUpdatedAt :: UTCTime
  } deriving (Eq, Show, Generic)

-- Markdown encode/decode using the same frontmatter pattern as Skills/Memory
-- (Seal.Store.Markdown.decodeDoc / encodeDoc)
-- ... implementations ...
```

**Step 4: Run test to verify pass**

Run: `nix develop --command cabal test seal-harness-test --test-options="--match Distilled"`
Expected: PASS

**Step 5: Commit**

```bash
git add src/Seal/Memory/Distilled.hs test/Seal/Memory/DistilledSpec.hs
git commit -m "feat(memory): add L1/L2/L3 distilled memory types"
```

---

### Task 7: Create L1/L2/L3 storage backend

**Objective:** Disk backend for reading/writing distilled memory layers, using the existing Markdown+git pattern.

**Files:**
- Create: `src/Seal/Memory/DistilledBackend.hs`
- Test: `test/Seal/Memory/DistilledBackendSpec.hs`

**Step 1: Write failing test**

Test that:
- Writing an L1 atom creates `~/.seal/config/memory/l1/<id>.md` with correct frontmatter
- Reading it back round-trips
- Listing L1 atoms returns all in the directory
- Same for L2 scenarios and L3 persona
- All writes auto-commit to git

**Step 2: Run test to verify failure**

Expected: FAIL — module not found

**Step 3: Implement backend**

Follow the pattern in `src/Seal/Memory/Backend.hs`:
- Atomic writes (tmp → chmod 0600 → rename)
- Auto-commit to config git repo
- Directory enumeration for list operations
- L1: `~/.seal/config/memory/l1/<id>.md`
- L2: `~/.seal/config/memory/l2/<id>.md`
- L3: `~/.seal/config/memory/l3/persona.md` (single file, updated in place)

Create `ensureDistilledDirs` in `Seal.Config.Paths` to create the `l1/`, `l2/`, `l3/` subdirectories on first run.

**Step 4: Run test to verify pass**

Expected: PASS

**Step 5: Commit**

```bash
git add src/Seal/Memory/DistilledBackend.hs src/Seal/Config/Paths.hs test/Seal/Memory/DistilledBackendSpec.hs
git commit -m "feat(memory): add L1/L2/L3 distilled storage backend (Markdown + git)"
```

---

### Task 8: Implement L1 extraction prompt and pipeline

**Objective:** The L1 extraction step takes raw conversation messages and produces L1 atoms via an LLM call. This is the core of the distillation pipeline.

**Files:**
- Create: `src/Seal/Memory/Pipeline/L1Extraction.hs`
- Create: `src/Seal/Memory/Pipeline/Prompts.hs` (prompt templates)
- Test: `test/Seal/Memory/Pipeline/L1ExtractionSpec.hs`

**Step 1: Write failing test**

Test with a mock LLM provider that returns a canned JSON response:
- Given a conversation with 5 messages about user preferences
- The L1 extraction produces atoms with correct types (persona, episodic, instruction)
- Atoms have valid IDs, source session references, and message ID references
- Atoms are written to the L1 backend

**Step 2: Run test to verify failure**

Expected: FAIL — module not found

**Step 3: Implement L1 extraction**

The extraction prompt (adapted from Tencent's `l1-extraction.ts`, reimplemented in our own style):

**System prompt** instructs the LLM to:
1. Segment the conversation into scenes (topics)
2. Extract memories from each scene, classifying each as:
   - `persona`: Stable user attributes/preferences (priority 50-100)
   - `episodic`: Objective events with optional timestamps (priority 60-100)
   - `instruction`: Long-term behavioral rules for the AI (priority 70-100, or -1 for dead commands)
3. Output as JSON: `[{scene_name, message_ids, memories: [{content, type, priority, source_message_ids}]}]`

**User prompt** includes:
- Previous scene name (for continuity)
- Background messages (read-only context from prior turns)
- New messages formatted as `[id] [role] [timestamp]: content`

**Pipeline logic:**
1. Read the last N messages from session transcript (default N=5, with warmup ramp)
2. Format as extraction prompt
3. Call LLM via `Seal.Providers`
4. Parse JSON response
5. For each extracted memory, create an `L1Atom` with generated ID and source references
6. Write atoms to L1 backend
7. Return count of atoms created

**Dedup:** Before writing, query existing L1 atoms for this session via FTS5 keyword search on the new atom's content. If a high-similarity match exists (same type, overlapping content), skip or update instead of creating a duplicate.

**Step 4: Run test to verify pass**

Expected: PASS

**Step 5: Commit**

```bash
git add src/Seal/Memory/Pipeline/ src/Seal/Config/Paths.hs test/Seal/Memory/Pipeline/L1ExtractionSpec.hs
git commit -m "feat(memory): implement L1 atom extraction pipeline"
```

---

### Task 9: Implement L2 scenario consolidation

**Objective:** After L1 atoms are extracted, consolidate them into L2 scenario files — coherent narrative blocks organized around projects or themes.

**Files:**
- Create: `src/Seal/Memory/Pipeline/L2Consolidation.hs`
- Test: `test/Seal/Memory/Pipeline/L2ConsolidationSpec.hs`

**Step 1: Write failing test**

Test with mock LLM:
- Given 10 L1 atoms across 3 themes
- L2 consolidation produces 3 scenario files
- Each scenario has summary, heat, body (≤1500 chars)
- Scenarios are written to L2 backend
- Existing scenarios are updated (heat incremented) rather than duplicated

**Step 2: Run test to verify failure**

Expected: FAIL

**Step 3: Implement L2 consolidation**

The L2 consolidation prompt (adapted from Tencent's `scene-extraction.ts`):

**System prompt** instructs the LLM to act as a "Memory Consolidation Architect" that:
1. Reviews existing L2 scenario files (provided as context)
2. Reviews new L1 atoms (provided as input)
3. Organizes atoms into coherent scenarios
4. Writes/updates scenario files using the file workspace pattern (the LLM gets read/write access to a temp directory containing existing scenario files)
5. Enforces: max 15 scenarios, each ≤1500 chars, META frontmatter with heat
6. Soft-delete by writing `[DELETED]`

**Stage-0 check:** Before the LLM call, count existing scenarios. If ≥ max (15), instruct the LLM to MERGE first. If max-1 (14), only UPDATE. Otherwise, CREATE/UPDATE.

**Pipeline logic:**
1. Wait for L1 extraction to complete (triggered after L1 batch)
2. Delay: `l2DelayAfterL1Seconds` (default 10s)
3. Copy existing L2 scenarios to a temp workspace dir
4. Call LLM with scenario workspace + new L1 atoms
5. LLM reads/writes/edits scenario files in the workspace
6. Sync workspace back to L2 backend (detect changes, write updated scenarios)
7. Auto-commit to git

**Step 4: Run test to verify pass**

Expected: PASS

**Step 5: Commit**

```bash
git add src/Seal/Memory/Pipeline/L2Consolidation.hs test/Seal/Memory/Pipeline/L2ConsolidationSpec.hs
git commit -m "feat(memory): implement L2 scenario consolidation pipeline"
```

---

### Task 10: Implement L3 persona generation

**Objective:** Incrementally update the long-term persona profile from L2 scenarios.

**Files:**
- Create: `src/Seal/Memory/Pipeline/L3Persona.hs`
- Test: `test/Seal/Memory/Pipeline/L3PersonaSpec.hs`

**Step 1: Write failing test**

Test with mock LLM:
- Given L2 scenarios and no existing persona → first-time generation
- Given existing persona + new L2 scenarios → incremental update
- Persona file written to `~/.seal/config/memory/l3/persona.md`
- Version number increments

**Step 2: Run test to verify failure**

Expected: FAIL

**Step 3: Implement L3 persona generation**

The L3 persona prompt (adapted from Tencent's `persona-generation.ts`):

**System prompt** — "Persona Architect - Incremental Evolution Protocol":
- Four-layer deep scan: Base & Facts, Interest Graph, Interface (interaction protocol), Core (cognitive kernel)
- Output: single `persona.md` (≤2000 chars)
- Incremental mode: receive existing persona + new scenarios → decide strengthen/supplement/correct/restructure/no-change
- First-time mode: generate from scratch

**Pipeline logic:**
1. Trigger: after L2 consolidation completes, or every `triggerEveryN` new L1 atoms (default 50)
2. Global mutex (concurrency=1) — only one L3 update at a time
3. Load existing persona (if any) + all L2 scenarios
4. Determine mode: first (no persona) vs incremental (persona exists)
5. Call LLM with persona + scenarios
6. Parse response, write/update `persona.md`
7. Increment version, auto-commit to git

**Step 4: Run test to verify pass**

Expected: PASS

**Step 5: Commit**

```bash
git add src/Seal/Memory/Pipeline/L3Persona.hs test/Seal/Memory/Pipeline/L3PersonaSpec.hs
git commit -m "feat(memory): implement L3 persona generation pipeline"
```

---

### Task 11: Implement pipeline scheduler

**Objective:** Orchestrate the L1→L2→L3 pipeline. Decide when to trigger each layer, manage concurrency, handle session lifecycle.

**Files:**
- Create: `src/Seal/Memory/Pipeline/Scheduler.hs`
- Test: `test/Seal/Memory/Pipeline/SchedulerSpec.hs`

**Step 1: Write failing test**

Test that the scheduler:
- Triggers L1 after every N conversation turns (default 5, with warmup)
- Triggers L2 after L1 completes + delay
- Triggers L3 after L2 completes (or every 50 new atoms)
- Cancels L2 if session inactive > 24h
- Uses SerialQueue (concurrency=1) per session for L1 and L2

**Step 2: Run test to verify failure**

Expected: FAIL

**Step 3: Implement scheduler**

```haskell
-- Pipeline trigger configuration
data PipelineConfig = PipelineConfig
  { pcEveryNConversations :: Int    -- default 5
  , pcEnableWarmup :: Bool           -- default True (1→2→4→8→...→everyN)
  , pcL1IdleTimeoutSeconds :: Int   -- default 600
  , pcL2DelayAfterL1Seconds :: Int  -- default 10
  , pcL2MinIntervalSeconds :: Int   -- default 900 (15 min)
  , pcL2MaxIntervalSeconds :: Int   -- default 3600 (60 min)
  , pcSessionActiveWindowHours :: Int -- default 24
  , pcL3TriggerEveryN :: Int        -- default 50
  }
```

The scheduler:
- Listens for session events (message appended, session ended, idle timeout)
- Manages per-session serial queues (L1 and L2 are sequential per session)
- L3 uses a global mutex (only one L3 update at a time across all sessions)
- Warmup: first extraction after 1 turn, then 2, then 4, then 8, then settle at `everyNConversations`
- On session end: flush remaining L1, trigger L2, trigger L3 if threshold met

**Step 4: Run test to verify pass**

Expected: PASS

**Step 5: Commit**

```bash
git add src/Seal/Memory/Pipeline/Scheduler.hs test/Seal/Memory/Pipeline/SchedulerSpec.hs
git commit -m "feat(memory): implement distillation pipeline scheduler"
```

---

### Task 12: Implement memory retrieval and context injection

**Objective:** At session start and during conversation, retrieve relevant distilled memories and inject them into the LLM context.

**Files:**
- Create: `src/Seal/Memory/Retrieval.hs`
- Test: `test/Seal/Memory/RetrievalSpec.hs`

**Step 1: Write failing test**

Test that:
- At session start, L3 persona is injected into system prompt (stable/cacheable section)
- At session start, L2 scenario summaries are injected into system prompt (stable/cacheable section)
- During conversation, L1 atoms matching the current query are injected into user prompt prefix (dynamic section)
- Character budgets are enforced: `maxTotalRecallChars` (2000), `maxCharsPerMemory` (500)
- Recall timeout: if retrieval takes > 5000ms, skip injection (don't block the user)

**Step 2: Run test to verify failure**

Expected: FAIL

**Step 3: Implement retrieval**

```haskell
data RecallConfig = RecallConfig
  { rcMaxResults :: Int        -- default 5
  , rcMaxCharsPerMemory :: Int -- default 500
  , rcMaxTotalRecallChars :: Int -- default 2000
  , rcScoreThreshold :: Double  -- default 0.3
  , rcTimeoutMs :: Int          -- default 5000
  }

-- | Stable context (injected into system prompt, cacheable)
buildStableContext :: L3Persona -> [L2Scenario] -> Text
buildStableContext persona scenarios =
  "<user-persona>\n" <> encodeL3Persona persona <> "\n</user-persona>\n"
  <> "<scene-navigation>\n" <> formatScenarioSummaries scenarios <> "\n</scene-navigation>"

-- | Dynamic context (injected into user prompt prefix, per-turn)
buildDynamicContext :: Text -> [L1Atom] -> RecallConfig -> Maybe Text
buildDynamicContext query atoms cfg =
  let results = fts5Search query atoms (rcMaxResults cfg * 3)
      filtered = filter (\(_, score) -> score >= rcScoreThreshold cfg) results
      truncated = applyCharBudget atoms filtered cfg
  in if null truncated then Nothing
     else Just ("<relevant-memories>\n" <> formatAtoms truncated <> "\n</relevant-memories>")
```

**FTS5 search:** Use SQLite FTS5 (via `sqlite-simple`) to index L1 atom content. The FTS5 index is a separate file (`~/.seal/state/memory-index.db`) rebuilt on each L1 write. This gives us keyword search without adding vector embeddings.

**Context injection points:**
- System prompt (stable): L3 persona + L2 scenario summaries. Appended after the auto-loaded skill.
- User prompt prefix (dynamic): L1 atoms matching the current query. Prepended to the user's message.

**Step 4: Run test to verify pass**

Expected: PASS

**Step 5: Commit**

```bash
git add src/Seal/Memory/Retrieval.hs src/Seal/Memory/FTS.hs test/Seal/Memory/RetrievalSpec.hs
git commit -m "feat(memory): implement FTS5 retrieval and context injection"
```

---

### Task 13: Add MEMORY_SEARCH and MEMORY_CONTEXT opcodes

**Objective:** Let the model explicitly search distilled memories and load full L2/L3 content on demand.

**Files:**
- Modify: `src/Seal/ISA/Ops/Memory.hs`
- Modify: `src/Seal/ISA/Opcode.hs`
- Test: `test/Seal/ISA/Ops/MemorySpec.hs`

**Step 1: Write failing test**

```haskell
-- MEMORY_SEARCH: keyword search across L1-L3
it "MEMORY_SEARCH finds relevant L1 atoms" $ do
  -- Given L1 atoms about "Haskell" and "trading"
  -- MEMORY_SEARCH "Haskell" returns atoms mentioning Haskell
  -- Results include id, type, content, score

-- MEMORY_CONTEXT: load full L2 scenario or L3 persona
it "MEMORY_CONTEXT loads L2 scenario by id" $ do
  -- Given L2 scenario "trading-strategy"
  -- MEMORY_CONTEXT {layer: "l2", id: "trading-strategy"} returns full body
```

**Step 2: Run test to verify failure**

Expected: FAIL

**Step 3: Implement opcodes**

```haskell
-- MEMORY_SEARCH: Keyword search across distilled memory layers
-- Input: { "query": "<text>", "layer": "l1" | "l2" | "l3" | "all", "max_results": int }
-- Output: { "results": [{ "id", "type", "content", "score", "layer" }] }
-- Trust: Trusted (read-only operation)

-- MEMORY_CONTEXT: Load full memory content by layer and id
-- Input: { "layer": "l2" | "l3", "id": "<id>" }
-- Output: { "content": "<full markdown>" }
-- Trust: Trusted (read-only operation)
```

**Step 4: Run test to verify pass**

Expected: PASS

**Step 5: Commit**

```bash
git add src/Seal/ISA/Ops/Memory.hs src/Seal/ISA/Opcode.hs test/Seal/ISA/Ops/MemorySpec.hs
git commit -m "feat(isa): add MEMORY_SEARCH and MEMORY_CONTEXT opcodes"
```

---

### Task 14: Wire distillation pipeline into session lifecycle

**Objective:** Connect the pipeline scheduler to session events so distillation runs automatically.

**Files:**
- Modify: `src/Seal/Session/Store.hs` — emit events on session end
- Modify: `src/Seal/Handles/Transcript.hs` — emit events on message append
- Modify: `src/Seal/Harness.hs` (or equivalent turn loop) — wire scheduler hooks
- Test: `test/Seal/Memory/Pipeline/IntegrationSpec.hs`

**Step 1: Write failing test**

Integration test that:
1. Creates a session with 10 conversation turns
2. Ends the session
3. Verifies L1 atoms were extracted (count > 0)
4. Verifies L2 scenarios were created (after delay)
5. Verifies L3 persona was updated (if threshold met)
6. Verifies a new session receives the distilled context on start

**Step 2: Run test to verify failure**

Expected: FAIL

**Step 3: Wire the scheduler**

- On each `tfwRecordAsync` (Trusted message append), notify the scheduler
- On session end, trigger a flush of the pipeline
- On session start, call `buildStableContext` and inject into system prompt
- On each turn, call `buildDynamicContext` with the user's message and inject into prompt prefix

The scheduler runs in a background thread (using `async` from the `async` package). LLM calls for distillation use a separate provider instance (or the same one with lower priority) to avoid blocking user-facing turns.

**Step 4: Run test to verify pass**

Expected: PASS

**Step 5: Commit**

```bash
git add src/Seal/Session/Store.hs src/Seal/Handles/Transcript.hs src/Seal/Harness.hs test/Seal/Memory/Pipeline/IntegrationSpec.hs
git commit -m "feat(memory): wire distillation pipeline into session lifecycle"
```

---

### Task 15: Add distillation config to config.toml

**Objective:** Make the pipeline configurable via the existing `config.toml` mechanism.

**Files:**
- Modify: `src/Seal/Config/File.hs` — add `[memory.distillation]` section

**Step 1: Implement config parsing**

```toml
[memory.distillation]
enabled = true                  # default: true
every_n_conversations = 5       # default: 5
enable_warmup = true            # default: true
l1_idle_timeout_seconds = 600   # default: 600
l2_delay_after_l1_seconds = 10 # default: 10
l2_min_interval_seconds = 900  # default: 900
l2_max_interval_seconds = 3600 # default: 3600
session_active_window_hours = 24 # default: 24
l3_trigger_every_n = 50        # default: 50

[memory.recall]
max_results = 5                # default: 5
max_chars_per_memory = 500     # default: 500
max_total_recall_chars = 2000 # default: 2000
score_threshold = 0.3          # default: 0.3
timeout_ms = 5000             # default: 5000
```

**Step 2: Test config parsing**

Run: `nix develop --command cabal test seal-harness-test --test-options="--match Config"`
Expected: PASS

**Step 3: Commit**

```bash
git add src/Seal/Config/File.hs test/Seal/Config/FileSpec.hs
git commit -m "feat(config): add [memory.distillation] and [memory.recall] config sections"
```

---

## Phase 3: CodeGraph

### Objective

Index code symbols, files, call relationships, and impact paths for repos that Seal agents work with. Store the graph in SQLite. Expose search and impact analysis via new ISA opcodes.

### Design

**Storage:** `~/.seal/state/codegraph/<repo-hash>.db` — one SQLite DB per indexed repo.

**Indexing:** Uses tree-sitter (via Haskell bindings or shelling out to `tree-sitter` CLI) for multi-language symbol extraction. For Haskell specifically, can use `ghc` API or `haskell-names` for more precise type information. Start with tree-sitter for language breadth.

**Graph schema (SQLite):**
```sql
CREATE TABLE symbols (
  id INTEGER PRIMARY KEY,
  file_path TEXT NOT NULL,
  name TEXT NOT NULL,
  kind TEXT NOT NULL,          -- function, class, method, variable, type
  line_start INTEGER,
  line_end INTEGER,
  doc_string TEXT
);

CREATE TABLE edges (
  caller_id INTEGER REFERENCES symbols(id),
  callee_id INTEGER REFERENCES symbols(id),
  edge_type TEXT NOT NULL,     -- calls, imports, implements, extends
  PRIMARY KEY (caller_id, callee_id, edge_type)
);

CREATE TABLE files (
  path TEXT PRIMARY KEY,
  language TEXT,
  symbol_count INTEGER,
  indexed_at TEXT
);

CREATE VIRTUAL TABLE symbols_fts USING fts5(name, doc_string, content=symbols);
```

**ISA opcodes:**
- `CODEGRAPH_INDEX` — Index or re-index a repo (given a repo path or URL)
- `CODEGRAPH_SEARCH` — Search for symbols by name
- `CODEGRAPH_IMPACT` — Given a symbol, find all callers (impact analysis)
- `CODEGRAPH_LIST` — List indexed repos and their stats

**Cold-start integration:** When a user adds a repo (via the frontend, Phase 7), `CODEGRAPH_INDEX` is called automatically. This is the cold-start hook (Phase 4).

### Tasks

### Task 16: Create CodeGraph types and SQLite schema

**Objective:** Define the data types and SQLite schema for the code graph.

**Files:**
- Create: `src/Seal/CodeGraph/Types.hs`
- Create: `src/Seal/CodeGraph/Schema.hs`
- Test: `test/Seal/CodeGraph/TypesSpec.hs`

**Step 1: Write failing test**

Test types round-trip through JSON, schema initializes correctly.

**Step 2: Run test to verify failure**

Expected: FAIL

**Step 3: Implement types and schema**

```haskell
data Symbol = Symbol
  { symId :: Int64
  , symFilePath :: Text
  , symName :: Text
  , symKind :: SymbolKind    -- Function | Class | Method | Variable | Type
  , symLineStart :: Int
  , symLineEnd :: Int
  , symDocString :: Maybe Text
  } deriving (Eq, Show, Generic)

data Edge = Edge
  { eCaller :: Int64
  , eCallee :: Int64
  , eType :: EdgeType        -- Calls | Imports | Implements | Extends
  } deriving (Eq, Show, Generic)

data CodeGraphDB = CodeGraphDB
  { cgdbPath :: FilePath
  , cgdbConn :: Connection
  }
```

Schema initialization creates the tables and FTS5 index above.

**Step 4: Run test to verify pass**

Expected: PASS

**Step 5: Commit**

```bash
git add src/Seal/CodeGraph/ test/Seal/CodeGraph/TypesSpec.hs
git commit -m "feat(codegraph): add types and SQLite schema"
```

---

### Task 17: Implement symbol extraction via tree-sitter

**Objective:** Extract symbols from source files using tree-sitter for multi-language support.

**Files:**
- Create: `src/Seal/CodeGraph/Extract.hs`
- Test: `test/Seal/CodeGraph/ExtractSpec.hs`

**Step 1: Write failing test**

Test that extracting from a sample Haskell file produces expected symbols (function names, type declarations). Test with a sample Python file too.

**Step 2: Run test to verify failure**

Expected: FAIL

**Step 3: Implement extraction**

Two approaches (pick based on Haskell ecosystem maturity):
1. **tree-sitter-hs** (`tree-sitter` package on Hackage) — Haskell bindings to tree-sitter. Supports all tree-sitter grammars. Most flexible.
2. **Shell out to `tree-sitter` CLI** — `tree-sitter parse --json <file>`. Simpler but adds a dependency on the CLI tool.

Start with approach 1 if the package is available in Nix; fall back to approach 2.

For each file:
1. Detect language from extension
2. Parse with appropriate grammar
3. Walk the AST, extracting symbol nodes (function defs, class defs, type declarations)
4. For each symbol, extract: name, kind, line range, doc string (from preceding comment)
5. Detect edges (calls, imports) by walking the AST for call expressions and import statements

**Step 4: Run test to verify pass**

Expected: PASS

**Step 5: Commit**

```bash
git add src/Seal/CodeGraph/Extract.hs test/Seal/CodeGraph/ExtractSpec.hs
git commit -m "feat(codegraph): implement symbol extraction via tree-sitter"
```

---

### Task 18: Implement edge detection (call graph)

**Objective:** Detect call relationships between symbols to build the call graph.

**Files:**
- Modify: `src/Seal/CodeGraph/Extract.hs` — add edge detection
- Test: `test/Seal/CodeGraph/ExtractSpec.hs`

**Step 1: Write failing test**

Test that:
- A function calling another function in the same file produces a `Calls` edge
- An import statement produces an `Imports` edge
- A class implementing an interface produces an `Implements` edge

**Step 2: Run test to verify failure**

Expected: FAIL

**Step 3: Implement edge detection**

During AST walk:
1. For each function body, find all call expressions. Match callee name to known symbols (in scope). Create `Calls` edges.
2. For each import statement, create `Imports` edges to the imported symbols.
3. For class/type declarations, detect inheritance/implements patterns. Create `Extends`/`Implements` edges.

**Step 4: Run test to verify pass**

Expected: PASS

**Step 5: Commit**

```bash
git add src/Seal/CodeGraph/Extract.hs test/Seal/CodeGraph/ExtractSpec.hs
git commit -m "feat(codegraph): implement edge detection (call graph)"
```

---

### Task 19: Implement CODEGRAPH ISA opcodes

**Objective:** Expose CodeGraph functionality to the model via ISA opcodes.

**Files:**
- Create: `src/Seal/ISA/Ops/CodeGraph.hs`
- Modify: `src/Seal/ISA/Opcode.hs`
- Test: `test/Seal/ISA/Ops/CodeGraphSpec.hs`

**Step 1: Write failing test**

Test each opcode:
- `CODEGRAPH_INDEX` — indexes a repo, returns stats (file count, symbol count)
- `CODEGRAPH_SEARCH` — searches symbols by name, returns matches with file/line info
- `CODEGRAPH_IMPACT` — given a symbol ID, returns all transitive callers (impact analysis)
- `CODEGRAPH_LIST` — lists indexed repos

**Step 2: Run test to verify failure**

Expected: FAIL

**Step 3: Implement opcodes**

```haskell
-- CODEGRAPH_INDEX
-- Input: { "path": "<repo-path>" }  (path is SafePath-validated, relative to workdir)
-- Output: { "files_indexed": int, "symbols_indexed": int, "edges_indexed": int }
-- Trust: Untrusted (operates on files in workdir, not config repo)
-- Note: Uses tree-sitter, which is a native library call, not a shell command

-- CODEGRAPH_SEARCH
-- Input: { "query": "<symbol-name>", "repo": "<repo-path>" (optional) }
-- Output: { "results": [{ "id", "name", "kind", "file", "line", "doc" }] }
-- Trust: Trusted (read-only SQLite query)

-- CODEGRAPH_IMPACT
-- Input: { "symbol_id": int, "repo": "<repo-path>" (optional) }
-- Output: { "callers": [{ "id", "name", "kind", "file", "line" }] }
-- Trust: Trusted (read-only graph traversal)

-- CODEGRAPH_LIST
-- Input: {}
-- Output: { "repos": [{ "path", "files", "symbols", "indexed_at" }] }
-- Trust: Trusted (read-only)
```

**Step 4: Run test to verify pass**

Expected: PASS

**Step 5: Commit**

```bash
git add src/Seal/ISA/Ops/CodeGraph.hs src/Seal/ISA/Opcode.hs test/Seal/ISA/Ops/CodeGraphSpec.hs
git commit -m "feat(isa): add CodeGraph opcodes (INDEX, SEARCH, IMPACT, LIST)"
```

---

## Phase 4: Cold-Start Import

### Objective

When a user adds a repo to Seal (via the frontend or CLI), automatically index it with CodeGraph and make it available for search/impact analysis. This is the cold-start hook.

### Design

The cold-start import is a thin orchestration layer over existing capabilities:
1. User adds a repo via the frontend (Phase 7) or CLI command
2. Seal calls `CODEGRAPH_INDEX` on the repo path
3. CodeGraph indexes in the background
4. When indexing completes, the repo appears in `CODEGRAPH_LIST` results
5. The model can immediately use `CODEGRAPH_SEARCH` and `CODEGRAPH_IMPACT`

No Wiki layer. No conversation session import (our session transcripts are already in the right format for the distillation pipeline).

### Tasks

### Task 20: Add repo-add CLI command and event

**Objective:** CLI command to add a repo for indexing, and an event the frontend can hook into later.

**Files:**
- Modify: `src/Seal/CLI.hs` — add `seal repo add <path>` command
- Create: `src/Seal/CodeGraph/Import.hs` — import orchestration
- Test: `test/Seal/CodeGraph/ImportSpec.hs`

**Step 1: Write failing test**

Test that:
- `seal repo add /path/to/repo` triggers CodeGraph indexing
- After indexing, `CODEGRAPH_LIST` includes the repo
- Adding the same repo again re-indexes (updates)

**Step 2: Run test to verify failure**

Expected: FAIL

**Step 3: Implement**

```haskell
-- src/Seal/CodeGraph/Import.hs
module Seal.CodeGraph.Import (importRepo, reindexRepo) where

-- | Index a repo for the first time (or re-index)
importRepo :: FilePath -> App ImportResult
importRepo repoPath = do
  -- 1. Validate path (SafePath)
  -- 2. Detect language(s) from file extensions
  -- 3. Create/open CodeGraph SQLite DB for this repo
  -- 4. Walk the directory tree, extract symbols + edges
  -- 5. Write to SQLite
  -- 6. Return stats
```

The CLI command:
```
seal repo add <path>     — Add a repo for CodeGraph indexing
seal repo list           — List indexed repos
seal repo reindex <path> — Force re-index
seal repo remove <path>  — Remove a repo and its index
```

**Step 4: Run test to verify pass**

Expected: PASS

**Step 5: Commit**

```bash
git add src/Seal/CLI.hs src/Seal/CodeGraph/Import.hs test/Seal/CodeGraph/ImportSpec.hs
git commit -m "feat(codegraph): add repo import (cold-start) via CLI"
```

---

### Task 21: Add frontend hook point for repo-add

**Objective:** When the web frontend (Phase 7) lands, wire the repo-add flow to trigger CodeGraph indexing automatically. For now, define the API endpoint as a stub.

**Files:**
- Create: `src/Seal/Gateway/API/Repo.hs` — API endpoint stub
- Modify: `src/Seal/Gateway.hs` — register the route

**Note:** This task can be deferred until Phase 7 (Web frontend) is in progress. The CLI command from Task 20 is sufficient for now.

**Step 1: Define API endpoint**

```
POST /api/repos
Body: { "path": "<repo-path>" }
Response: { "job_id": "<id>", "status": "indexing" }

GET /api/repos
Response: { "repos": [{ "path", "files", "symbols", "indexed_at" }] }

GET /api/repos/:id/status
Response: { "status": "indexing" | "ready" | "error", "stats": {...} }
```

**Step 2: Implement as stub (returns 202 Accepted, triggers background indexing)**

**Step 3: Commit**

```bash
git add src/Seal/Gateway/API/Repo.hs src/Seal/Gateway.hs
git commit -m "feat(gateway): add repo-add API endpoint stub for CodeGraph cold-start"
```

---

## Summary: What We're Building

| Feature | Source | Seal Implementation | Status |
|---|---|---|---|
| Skills directory hierarchy | Fable 5 system prompt | Three-tier: builtin (embedded), user (writable), examples (read-only templates). `SKILL_COPY` opcode. | NEW |
| L0→L1 atom extraction | TencentDB l1-extraction | Haskell LLM pipeline, FTS5 dedup, Markdown storage | NEW |
| L1→L2 scenario consolidation | TencentDB scene-extraction | Haskell LLM pipeline, file-workspace pattern, heat tracking | NEW |
| L2→L3 persona generation | TencentDB persona-generation | Haskell LLM pipeline, incremental evolution | NEW |
| Pipeline scheduler | TencentDB pipeline-manager | Haskell async scheduler, per-session serial queues, warmup | NEW |
| Memory retrieval | TencentDB auto-recall | FTS5 keyword search, char budgets, stable+dynamic context split | NEW |
| MEMORY_SEARCH/CONTEXT opcodes | TencentDB tdai_memory_search | New ISA opcodes for explicit memory search | NEW |
| CodeGraph | TencentDB CodeGraph | tree-sitter extraction, SQLite graph, Haskell-native | NEW |
| Cold-start import | TencentDB cold-start | CLI command + API stub, hooks into repo-add | NEW |
| Skills versioning | Already have | git auto-commit in config repo | DONE |
| Visibility/trust model | Already have | Untrusted/Trusted (Tencent's private/team/restricted/agent deferred) | DONE |
| Session transcripts | Already have | conversation.jsonl + entries.jsonl, two-file format | DONE |

## What We're Explicitly NOT Building

- **No Wiki layer** — out of scope
- **No vector embeddings** — start with FTS5 keyword search; add vector search later if retrieval quality demands it. YAGNI.
- **No multi-agent team ACLs** — trusted/untrusted is sufficient. Add more levels later if needed.
- **No web panel** — the frontend (Phase 7) will render these features, not a separate panel
- **No TencentDB** — everything is local SQLite + Markdown + git
- **No Node.js/TypeScript** — pure Haskell, clean-room reimplementation
