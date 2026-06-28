# Slash-Command Infrastructure + Channel-Ingress Design

> **Status:** Design (brainstormed, approved). Governs the message-ingress and
> `/`-command layer that every channel sits on. The detailed, TDD implementation
> plan is written from this spec via the writing-plans skill.

## Purpose

Seal must accept commands and messages from multiple channels (web, Signal,
Telegram, a possible TUI, and eventually CLI) and process them through one
uniform, channel-agnostic core. This design replaces the ad-hoc, hand-rolled
`/`-command handling of the reference runtime with:

1. A **two-layer parse model** that preserves the carefully-tuned terse *tab
   grammar* exactly, while routing every other `/`-command through
   **optparse-applicative**.
2. A **command registry** in which each command is channel-agnostic data,
   yielding **auto-derived, always-correct help** so that *every command and
   option is discoverable* through the built-in help — a structurally enforced
   property, not a documentation chore.
3. A **single channel-ingress chokepoint** with an ordered **preprocessing
   chain** that is guaranteed to run before any LLM call, giving a future home
   for security checks (e.g. prompt-injection scanning) that see 100% of inbound
   traffic.

This is a security-spine upgrade over the reference, consistent with this
repo's "the insecure path is harder to write than the secure path" thesis.

## Goals

- Preserve the reference's tab UX *exactly* — single-character `/0`–`/z`
  switching, `/N <payload>` inject, plain-text default, focused-only relay with
  breadcrumbs, tmux-style contiguous slots, per-conversation ref-based cursors.
  This UX is the crown jewel; it is optimized for one-thumb use on a
  single-threaded chat channel and must not regress.
- Use optparse-applicative for all non-tab `/`-commands, so help/usage is
  derived from the parser and cannot drift.
- Make **every** `/`-command and option discoverable through `/help`.
- Define each command **once** as channel-agnostic data; generate every
  surface (chat dispatch, web command palette/autocomplete, chat-platform
  command registration, TUI, all help) from that one definition.
- Guarantee a preprocessing seam that runs before any LLM call on every inbound
  message, on every channel.

## Non-goals

- The `seal` startup CLI argument parser (process `argv`, e.g. `seal vault
  init`) is **out of scope** and stays a completely separate optparse tree. The
  two worlds both use optparse machinery but are intentionally **not** unified.
- The web-frontend *duplication itself* (React/TS/Vite/Tailwind SPA + Warp/WAI
  gateway + WebSocket transcript broker) is a separate behavioral spec written
  when Phase 2's web work begins. This design governs only the command/ingress
  layer the frontend sits on.
- No TUI is built now; the infrastructure is merely designed to support one.
- Compile-time enforcement of "preprocessing precedes LLM" is **deferred** (see
  the gate section).

---

## Architecture overview

Inbound text from any channel flows:

```
RawInbound
   │
   ▼
ingest ─────────────────────────────────────────────┐  (single chokepoint)
   │  PreprocessChain (ordered hooks, run FIRST)      │
   │    1. route   (Layer 1 + Layer 2 classify)       │
   │    2. scan    (future: injection / policy)       │
   │    3. authorize                                   │
   ▼                                                   │
Disposition                                            │
   ├── TabSwitch / TabInject  → tab routing (no LLM)   │
   ├── SlashCommand           → command handler        │
   │                            (MAY call LLM)         │
   └── PlainText              → agent turn (calls LLM) │
                                                       │
   (any LLM call here happens strictly after the ─────┘
    preprocessing chain, by construction of this
    single pipeline)
```

All of the above is a pure-ish library depending only on `Seal.Core` /
`Seal.Security` plus a `ChannelCaps` capability handle. No channel can reach the
agent loop or a provider except by calling `ingest`.

---

## Layer 1 — Routing pre-parser (bespoke, preserved exactly)

A pure classifier recognizing the terse tab grammar *before* anything else:

```
route :: Text -> RoutedInput

data RoutedInput
  = TabSwitch  TabIndex            -- "/N"          (N ∈ one char 0-9 a-z)
  | TabInject  TabIndex Text       -- "/N payload"
  | PlainText  Text                -- no leading slash
  | SlashLine  Text                -- "/word …"  → handed to Layer 2
```

This grammar is deliberately **not** optparse-shaped and never will be:
optparse cannot express `/0` as a subcommand, and forcing it would destroy the
one-character-switch UX. Rules carried verbatim from the reference's tab design:

- Tab index is **exactly one character**: `0`–`9` → slots 0–9, `a`–`z` → slots
  10–35 (36 slots max). Multi-character forms (`/12`, `/aa`, `/01`) are *not*
  switches — they fall through to `SlashLine`/error per the existing grammar.
- Case matters: `/a` is tab 10; `/A` is not a tab switch.
- Slots are contiguous `0..n-1` (tmux renumber-windows style); closing compacts.
- The tab *types* (`TabIndex`, `TabRef`, `TabList` with invariants I1/I2/I3,
  `CursorState`, `RelayMode`, `ConversationKey`) are already seeded in the
  Phase 2 plan as `Seal.Tabs.Types` / `Seal.Handles.Tab`. This design adds the
  **routing front-end** (`route`) and wires it into `ingest`.

The full focused-only relay behavior, breadcrumbs, per-conversation ref-based
cursors, and `/tab` wizard are preserved as specified by the seeded tab types;
this document does not restate them but treats them as a hard constraint: the
observable tab UX must match the reference exactly.

---

## Layer 2 — optparse-applicative command registry

Everything CLI-shaped (`/vault add <name>`, `/session new --target X`,
`/harness start <name> [dir] [--unsafe]`, and the `/tab new|close|rename|resume|
focus|list` subfamily) is defined as an optparse `ParserInfo`.

To run a `SlashLine`:

1. **Tokenize** the line with a quote-aware, shell-words-style splitter (so
   `/tab rename 1 "my db"` works). Tokenization is its own validated step.
2. **Look up** the head word in the registry (honoring aliases).
3. **`execParserPure prefs csParserInfo tokens`**:
   - `Success cmd` → a typed `SlashCommand` value to execute.
   - `Failure`     → render optparse's own error + usage text and send it
     straight back to the channel (no bespoke error copy to maintain).
   - `CompletionInvoked` → not used in chat; reserved for shell-completion of
     the separate CLI.

### Command registry data model

One registry, `[CommandSpec]`, each entry channel-agnostic data:

```haskell
data CommandSpec = CommandSpec
  { csName         :: CommandName             -- "vault"
  , csAliases      :: [CommandName]           -- ["v"]
  , csGroup        :: CommandGroup            -- Session | Vault | Harness | Tab | …
  , csSynopsis     :: Text                    -- one-line, for the grouped /help list
  , csParserInfo   :: ParserInfo SlashCommand -- the optparse parser + its help
  , csAvailability :: Availability            -- which channels/contexts expose it
  }
```

```haskell
parseSlash :: Registry -> Text -> Either Text SlashCommand
-- look up head word (with aliases) → run that spec's ParserInfo over the rest.
-- No giant hand-rolled `asum` of Text matchers.
```

`CommandGroup` mirrors the reference's grouping (Session, Provider, Channel,
Vault, Transcript, Harness, Agent, Mcp, Tab) so `/help` output is organized the
same way. `Availability` lets a command be hidden or deferred on channels that
cannot support it (e.g. an interactive setup wizard on web — see ChannelCaps).

---

## Discoverability — help is derived, structurally guaranteed

This is the part that fixes the reference's ad-hoc help.

- **`/help`** → the grouped command list, generated from
  `csGroup`/`csName`/`csSynopsis` across the whole registry. No hand-maintained
  master list.
- **`/help <command>`** and **`/<command> --help`** are the *same operation*:
  run that command's `ParserInfo` with `--help`, render optparse's `ParserHelp`
  to `Text`, and send it. Every flag, metavar, argument, and default is
  therefore always documented and can never drift from the parser — because it
  **is** the parser.
- **Discoverability is a test-enforced invariant.** A property test enumerates
  the registry and asserts that every command and every option surfaces in some
  help output. Adding a command or option without making it discoverable fails
  the build. This directly satisfies the requirement that *every `/`-command and
  associated option MUST be discoverable*.

### Tab terse-grammar discoverability

The `/N` switch/inject grammar has no optparse parser, yet it must be
discoverable through the same surface. It is registered as a first-class
**synopsis entry** (a hand-authored usage block, group `Tab`, no `ParserInfo`)
in the same registry:

- `/help` lists it under the Tab group.
- `/help tabs` shows the full terse-grammar reference (the `/N`, `/N payload`,
  plain-text-default, relay-mode explanation).
- The `/tab new|close|rename|resume|focus|list` subcommands ARE real optparse
  parsers and get auto-derived help like everything else.

So the crown jewel is fully discoverable through the unified `/help`, even
though it is parsed bespoke. The discoverability property test treats the
synopsis entry as satisfied by the presence of its hand-authored block.

---

## The channel-ingress preprocessing gate

### Goal

Every message entering Seal from *any* channel must pass through `/`-command
processing — and a wider preprocessing chain — before any LLM call is possible.
Every `/`-command must have the ability to do preprocessing that is guaranteed
to run before LLM calls. This is the ingress analogue of the README's
ACK-before-execute and the future home for prompt-injection / policy scanning.

### Mechanism — positional / by-construction (not type-enforced)

After weighing a strongly-typed proof token (an opaque `Preprocessed` value
gating the provider signature), we chose the **lighter, by-construction**
guarantee. Preprocessing is sometimes minimal or unnecessary, and forcing a
proof type through every provider call is overkill for now.

- **Single ingestion chokepoint.** Channels get exactly one entry into the core:

  ```haskell
  ingest :: ChannelCaps -> RawInbound -> App Disposition
  ```

  A channel handle (`Seal.Handles.Channel`) exposes *no* path to the agent loop
  or a provider — only `ingest`. `RawInbound` is the untrusted,
  attacker-controlled payload. This one structural anchor is what makes the
  ordering guarantee hold.

- **PreprocessChain runs first, inside `ingest`, before any routing/dispatch**
  — and therefore before any LLM call. An ordered list of stages:

  ```
  1. route      -- Layer 1 + Layer 2 classification
  2. scan       -- future slots: prompt-injection detectors, content/policy
  3. authorize  -- allow-list / autonomy-posture checks
  ```

  Each stage may pass through, rewrite, or short-circuit-reject. When nothing
  needs doing, the chain is a no-op — it costs nothing, but the seam is always
  present for when a stage *does* matter. Because there is no other ingress
  door, future scanners are guaranteed to see 100% of inbound traffic.

- **Every `/`-command gets pre-LLM preprocessing for free**, because a command
  handler runs *after* the chain and *before* it chooses to call the LLM, so any
  work it does precedes its own model calls by construction.

- **No provider-signature gating.** `complete` takes a normal request; nothing
  forces a token through it. `/`-commands MAY call the LLM (the chain has
  already run for that message); plain-text messages flow to the agent turn.

### What this costs, and the deferred upgrade

The "preprocessing always precedes LLM" property now rests on there being a
**single ingress pipeline with preprocessing as its first stage**, not on the
compiler. If we later want the stronger, non-bypassable guarantee, the
proof-token design is a drop-in upgrade:

> Mint an opaque `Preprocessed` (constructor unexported) at the end of the
> chain; carry it in the `App` env for the duration of handling one message;
> change the provider seam to `complete :: Provider -> LlmAuthorization ->
> CompletionRequest -> App CompletionResponse` where `LlmAuthorization =
> FromInbound Preprocessed | FromInternal InternalOrigin`. Channel input could
> then *only* mint `FromInbound` via the chain; background/scheduled turns mint
> `FromInternal`. Until then, this is documented but not built (YAGNI).

---

## Channel-agnostic surface

The whole stack — `route`, the registry, `parseSlash`, the help renderer,
`ingest`/`PreprocessChain` — depends only on `Seal.Core` / `Seal.Security` and a
`ChannelCaps` handle. `ChannelCaps` abstracts interactive prompting
(`prompt`, `promptSecret`) so a command like `/vault setup` works interactively
on a stateful channel (CLI/Signal) but returns a structured *deferral* on a
request/response channel (web), matching the reference's behavior. Because the
**registry is introspectable data**:

- **Web** renders a command palette / autocomplete from the registry; `/help`
  output streams through the same transcript surface.
- **Signal / Telegram** generate their command and autocomplete lists from the
  registry (including the tab-switch shortcuts the reference registers).
- **TUI** (if ever built) consumes the same registry — no command defined twice.

### Module shape (proposed)

- `Seal.Command.Spec`     — `CommandSpec`, `CommandGroup`, `Availability`,
  `Registry`, registry assembly.
- `Seal.Command.Parse`    — quote-aware tokenizer + `parseSlash` over the
  registry (the `execParserPure` bridge).
- `Seal.Command.Help`     — `/help` grouped list + per-command `ParserHelp`
  rendering; the discoverability property test lives against this.
- `Seal.Routing.Route`    — Layer 1 `route` (terse tab grammar front-end).
- `Seal.Ingest`           — `ingest`, `PreprocessChain`, `Disposition`,
  `RawInbound`, stage assembly.
- Commands register their `CommandSpec` from their owning module (vault,
  session, harness, …) as those features land in later phases.

Exact module names are finalized in the implementation plan against existing
`Seal.*` conventions; the leaf-ish dependency rule (Core/Security only) is firm.

---

## Roadmap impact

This design changes channel priorities and Phase 2 scope. The roadmap
(`docs/superpowers/plans/2026-06-28-seal-harness-roadmap.md`) is updated to
match.

- **Channel priority flips:** **Web = the MVP channel (Phase 2)**, **Signal =
  next**, **CLI = much later**. The throwaway-CLI MVP assumption is dropped.
- **Web frontend stack:** clean-room reimplementation of the reference's stack —
  **React 18 + TypeScript + Vite + Tailwind** SPA over a Warp/WAI gateway with a
  WebSocket transcript-streaming broker — close-duplicating behavior and
  appearance (never copying source).
- **Phase 2 grows** to carry: the gateway + WebSocket broker, the React/TS
  frontend (close duplication), the `/`-command infrastructure (registry +
  optparse-help bridge + Layer-1 routing front-end + `/help`), and the
  `ingest`/preprocessing gate. The tab *types* are already seeded in Phase 2;
  this adds their routing front-end and the command system on top.
- **Phase 2 may split** to keep milestones green and bite-sized:
  - **Phase 2a** — command infrastructure + ingress/preprocessing gate +
    minimal end-to-end web loop (chat + transcript stream + `/help` + tabs).
  - **Phase 2b** — full close-duplication of the frontend (sidebar, tab
    controls, harness controls, sessions, archived views, pairing).
- **Later phases register their commands into the existing registry** as
  features land (vault, harness, mcp, …). The infrastructure ships in Phase 2;
  the command *surface* fills in over time.
- The detailed **web-frontend behavioral spec** is written at the start of the
  Phase 2 web work; this design governs the command/ingress layer beneath it.

---

## Testing strategy

- **Layer 1 routing** — QuickCheck: the single-char index grammar; round-trip of
  switch/inject/plain/slash classification; multi-char and uppercase forms never
  parse as switches; preservation of the reference's exact tab-index mapping.
- **Tokenizer** — properties on quote handling, whitespace, and that no token
  injection escapes quoting.
- **Registry / parse** — every `CommandSpec` parses its own documented synopsis;
  alias resolution; unknown command yields a helpful error.
- **Discoverability invariant (key test)** — enumerate the registry and assert
  every command and every option appears in some help output; the tab synopsis
  entry is present in `/help`.
- **Help rendering** — `/help <cmd>` equals the command's optparse `--help`.
- **Ingress ordering** — a stage placed in the chain is observed to run before
  the dispatch/agent-turn step for every `Disposition` variant; a no-op chain
  leaves behavior unchanged.
- **ChannelCaps** — interactive commands prompt on a stateful channel and return
  a structured deferral on a request/response channel.

## Open questions / deferred

- Exact `Seal.*` module names (finalized in the implementation plan).
- Whether to later upgrade the ingress gate to the type-enforced proof-token
  design (documented above; not built now).
- Whether `Availability` needs per-channel granularity beyond
  interactive-vs-not (decide when the second channel lands).
