---
id: codegraph
description: Explore, navigate, and understand a codebase using CodeGraph — a prebuilt knowledge graph of symbols, call edges, and structure. Use this skill whenever the task involves understanding how code is organized or connected: finding a function or class, tracing who calls what, figuring out what a change will affect, discovering which tests to run, or getting oriented in an unfamiliar repo. Prefer it over repeated grep-and-read exploration for any structural question about the code, even if the user doesn't mention codegraph by name. Not for one-off literal text search (grep is fine for that) or for running builds — it is about code topology, not strings.
created_at: 2026-08-26T00:00:00Z
updated_at: 2026-09-18T00:00:00Z
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

## Pitfall: the grep-then-read spiral

The most common failure mode is reaching for `SEARCH_FILES` (rg) out of
habit when you need to understand how a system works, then falling into
a multi-step spiral:

1. `SEARCH_FILES` with a broad pattern like `"tool.*call"` or `"emoji"`
   → hundreds of lines of matches across dozens of files
2. `FILE_READ` the 3-4 files that look most relevant
3. `SEARCH_FILES` again with a refined pattern to narrow down
4. `FILE_READ` more files from the refined results
5. Repeat 2-3 more times

This spiral wastes 5-10 tool calls and produces a scattered
understanding. **One `codegraph explore` call** returns the same
information — relevant symbols, their callers, their callees, and their
full source — in a single response.

### Before (grep-then-read spiral — 6+ calls)

```
SEARCH_FILES "emoji"                          → no results
SEARCH_FILES "tool.*call|toolCall|ToolCall"   → 500+ lines
SEARCH_FILES "icon|emoji|🔧|🔨|⚡"             → more results
FILE_READ   src/Seal/Channels/StreamProgress.hs
FILE_READ   src/Seal/Channels/Loop.hs
SEARCH_FILES "formatToolLine"                 → 10 results
FILE_READ   test/Seal/Channels/StreamProgressSpec.hs
```

### After (codegraph explore — 1 call)

```
BIN_EXEC { "binary": "codegraph",
           "args": ["explore", "how does tool call streaming progress work"],
           "cwd": "seal-harness" }
→ 65 symbols across 3 files, including formatToolLine, onToolCall,
  and all their callers — with full source code
```

### The rule

If your `SEARCH_FILES` pattern contains wildcards (`.*`, `|`, `.*call`)
or matches a concept rather than a literal string, you are exploring
structure — use `codegraph explore` instead. Reserve `SEARCH_FILES`
for literal text matching: finding a specific string, a specific error
message, or a specific config key.

## How to query

CodeGraph is a CLI tool. Run it via `BIN_EXEC` or `SHELL_EXEC` with the
repo directory as the `cwd`. The index lives at
`<repo>/.codegraph/codegraph.db` and auto-syncs on file changes.

### explore — one-shot context

The most powerful query. Answers multi-file questions like "how does X
work across the codebase?" in a single call — use it instead of
search-then-read-then-search-again chains. A typical `explore` call
replaces 3-5 `SEARCH_FILES` + `FILE_READ` calls. Returns relevant
symbols' source code + call paths in a single response:

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
