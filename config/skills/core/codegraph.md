---
id: codegraph
description: Explore, navigate, and understand a codebase using CodeGraph — a prebuilt knowledge graph of symbols, call edges, and structure. Use this skill whenever the task involves understanding how code is organized or connected: finding a function or class, tracing who calls what, figuring out what a change will affect, discovering which tests to run, or getting oriented in an unfamiliar repo. Prefer it over repeated grep-and-read exploration for any structural question about the code, even if the user doesn't mention codegraph by name. Not for one-off literal text search (grep is fine for that) or for running builds — it is about code topology, not strings.
created_at: 2026-08-26T00:00:00Z
updated_at: 2026-08-26T00:00:00Z
session: manual
---

# CodeGraph Skill

A `.codegraph/` directory exists in one of the repos cloned into your
workspace. That means CodeGraph has indexed the codebase into a SQLite
knowledge graph of symbols, call edges, and file structure. Use it to
answer structural questions efficiently — one query replaces many
file reads.

## When to use CodeGraph

**Prefer CodeGraph** for any structural question about the code:

- "Where is function X defined?"
- "Who calls function X?" (callers)
- "What does function X call?" (callees)
- "If I change X, what else breaks?" (impact / blast radius)
- "How does the Y system work?" (explore — returns relevant source + call paths)
- "Which tests should I run after changing X?"
- "What files are in the Z module?"

**Do NOT use CodeGraph** for:

- Literal text search across files — use `SEARCH_FILES` (rg) for that.
- Running builds or tests — use `SHELL_EXEC` / `BIN_EXEC`.
- Reading a specific file's contents — use `FILE_READ`.

## How to query

CodeGraph is a CLI tool. Run it via `BIN_EXEC` or `SHELL_EXEC` with the
repo directory as the `cwd`. The index lives at
`<repo>/.codegraph/codegraph.db` and auto-syncs on file changes.

### explore — one-shot context

The most powerful query. Returns relevant symbols' source code + call
paths in a single response. Use this when you need to understand how
something works or what a change will touch:

```
BIN_EXEC { "binary": "codegraph", "args": ["explore", "how does the dispatch loop work"], "cwd": "<repo>" }
```

### query — search symbols

Find symbols by name across the codebase. Useful for locating a function
or class when you know (part of) its name:

```
BIN_EXEC { "binary": "codegraph", "args": ["query", "dispatch", "--json"], "cwd": "<repo>" }
```

Options: `--kind function|class|method`, `--limit N`, `--json`.

### callers — who calls this?

Find everything that calls a given symbol. Essential before modifying
a function to understand the blast radius:

```
BIN_EXEC { "binary": "codegraph", "args": ["callers", "Seal.ISA.Dispatch.dispatch"], "cwd": "<repo>" }
```

### callees — what does this call?

Find everything a function calls. Useful for understanding a function's
dependencies:

```
BIN_EXEC { "binary": "codegraph", "args": ["callees", "Seal.ISA.Dispatch.dispatch"], "cwd": "<repo>" }
```

### impact — blast radius

Trace the full impact radius of changing a symbol — callers of callers,
transitively. Run this before any non-trivial change:

```
BIN_EXEC { "binary": "codegraph", "args": ["impact", "Seal.Skills.Autoload.injectAutoloadSkill"], "cwd": "<repo>" }
```

### status — index health

Check whether the index is up to date and get statistics:

```
BIN_EXEC { "binary": "codegraph", "args": ["status"], "cwd": "<repo>" }
```

### files — file structure

List indexed files faster than a filesystem scan:

```
BIN_EXEC { "binary": "codegraph", "args": ["files", "src/Seal/Skills"], "cwd": "<repo>" }
```

## Practical guidance

- **Always pass `cwd`** set to the repo directory (the one containing
  `.codegraph/`). CodeGraph resolves the index relative to the working
  directory.
- **Use `--json`** when you need to parse the output programmatically;
  the human-readable format is better for understanding.
- **Prefer `explore`** over multiple `query` + `callers` + `callees`
  calls — it returns everything in one shot.
- **The index auto-syncs**: you don't need to re-index after editing
  files. If something seems stale, check with `codegraph status`.
- **Not all languages are indexed**: CodeGraph uses tree-sitter grammars.
  If `codegraph status` shows zero symbols for a file, the language may
  not be supported.