# Phase 2 MVP — Vault `/`-Commands over a CLI REPL — Design

> **Status:** Design (brainstormed, approved 2026-06-28). The detailed, TDD
> implementation plan is written from this spec via the writing-plans skill.
>
> **Companion spec:** This builds directly on
> [`2026-06-28-slash-command-infrastructure-design.md`](./2026-06-28-slash-command-infrastructure-design.md)
> (the channel-agnostic command/ingress layer). That spec's architecture is
> adopted unchanged; this document scopes the *first concrete slice* of it and
> reconciles the channel priority (see §11).

## Purpose

Reach a point where a human can type `/vault …` commands and operate the Phase 1
encrypted vault **as soon as possible**, without building the web stack first.
The fastest vehicle is a thin terminal REPL that reads `/`-prefixed lines and
dispatches them through the real command infrastructure. The vault itself
(`Seal.Security.Vault`, Phase 1) is reused untouched.

Two firm quality bars, set by the user:

1. The `/vault` command and the **help system** are built **properly, not as a
   throwaway** — the full registry + auto-derived, exhaustive, discoverable help
   ships now and is reused verbatim by every future channel (web, Signal, …).
2. The terminal interaction itself stays **minimal** — off-the-shelf
   `optparse-applicative` (the "getopt/similar") for parsing, `haskeline` for the
   line editor. No bespoke TUI.

## MVP goal (done-when)

In the Nix dev shell, a user runs `seal` (or `seal repl`), and can:

- `/vault setup` → choose a key backend, create the vault, store config;
- `/vault add NAME` → enter a secret (hidden input) and persist it;
- `/vault get NAME`, `/vault list`, `/vault delete NAME`, `/vault lock`,
  `/vault unlock`, `/vault status` → all working against the real on-disk vault;
- `/help` and `/vault --help` (== `/help vault`) → list/usages auto-derived from
  the parsers, with a build-failing test that every command and option is
  discoverable.

…with the encrypted vault living in a git-trackable config directory and the
private key material isolated outside it.

---

## §1 — `~/.seal` directory layout

Single root (`~/.seal`, "very similar to PureClaw's `~/.pureclaw`"), split
**inside** into one version-controlled config tree and a mutable tree, with key
material isolated in its own restrictive directory:

```
~/.seal/
  config/          ← the user runs `git init` HERE (version-controlled)
    config.toml          user-authored settings (incl. vault_recipient/identity refs)
    vault/vault.age      ENCRYPTED secret store — tracked (encrypted ⇒ safe to commit)
    .gitignore           (belt-and-suspenders; this subtree is what you track)
  state/           ← mutable, NOT version-controlled
    sessions/  logs/  history   (memory.db, rag/, run/<sockets> arrive in later phases)
  keys/            ← identity / key material, NOT version-controlled, dir mode 0700
    <name>.identity      local age secret key            (file 0600)
    <name>.yubikey.txt   YubiKey plugin identity stanzas (file 0600; secret stays on the token)
```

**Rationale for the split.** `config/` is the one directory a user points a git
repo at to track and sync their setup; the encrypted vault rides along (it is
ciphertext, so committing it is safe and gives history/backup). Everything
mutable and derived (sessions, logs, future sqlite/RAG) is excluded so a
`git status` in `config/` stays meaningful. Private keys never enter the tracked
tree and never sit loose in `config/`.

**Root override.** `SEAL_HOME` env var overrides the base (`~/.seal` default).
This is a clean-room improvement over the reference (which had no such override):
it lets the whole test-suite run against a temp dir and never touch a real home.

**Path module.** A new `Seal.Config.Paths` computes and creates these
directories with correct permissions: `config/` and `state/` ordinary; `keys/`
created mode `0700`. Key-file confinement (no `..`, stays under `keys/`, owner ==
euid, file mode `0600`/`0400`) reuses a small `KeysRoot` + `mkSafeKeyPath`
layered onto the Phase 1 `Seal.Security.Path` module (the same canonicalize +
component-wise containment primitive, plus a stat/mode check). The encrypted
vault file continues to be written by the Phase 1 vault's atomic
`tmp → chmod 0600 → rename`.

---

## §2 — Vault key-backend model

The Phase 1 encryptor (`mkAgeEncryptor recipient identity`, shelling out to
`age --encrypt --recipient …` / `age --decrypt --identity …`) **already supports
all three backends** the user named, because `age` auto-discovers plugins from
the identity file. The backends therefore differ only in *how the
recipient+identity are produced at setup* and in the reported key-type label —
**not** in the encrypt/decrypt path.

A real ADT replaces the reference's structural selection:

```haskell
data VaultKeyBackend
  = LocalAgeKey                        -- age-keygen → secret key file in keys/  (secret on disk)
  | YubiKey { touchRequired :: Bool }  -- age-plugin-yubikey; secret stays on the hardware token
  | UserSupplied                       -- user provides an existing recipient + identity path
```

| Backend | Setup action | Recipient | Identity (the `--identity` arg) | Secret at rest |
|---|---|---|---|---|
| `LocalAgeKey` | `age-keygen -o keys/<name>.identity` | parsed `age1…` (public) | `keys/<name>.identity` | **on disk** (weak, but ≫ plaintext) |
| `YubiKey` | detect `age-plugin-yubikey`; `--generate` with chosen `--touch-policy` (`always`/`never`) + `--pin-policy` | parsed `age1yubikey1…` | `keys/<name>.yubikey.txt` (plugin stanzas) | **on the token** (strong) |
| `UserSupplied` | prompt for an existing recipient + identity path | given | given path | wherever the user keeps it |

Security framing (per the user): a local key file beside the encrypted vault is
"better than plaintext but still bad", so the wizard presents `YubiKey` as the
recommended path when `age-plugin-yubikey` is detected, with touch-required as an
explicit, recommended sub-choice. `UserSupplied` is the escape hatch for people
who manage their own age/plugin identities.

**Passphrase backend is explicitly deferred** — it needs a different encryptor
(native `age` scrypt or `age --passphrase`), out of scope for this MVP.

**Config fields** (TOML, in `config/config.toml`), resolved into a live vault at
startup exactly as Phase 1's `openVault`/`mkAgeEncryptor` expect:

| Key | Meaning |
|---|---|
| `vault_path` | default `~/.seal/config/vault/vault.age` |
| `vault_recipient` | `age1…` / `age1yubikey1…` |
| `vault_identity` | path under `keys/` (or user-supplied path) |
| `vault_unlock` | `startup` \| `on_demand` \| `per_access` (→ Phase 1 `UnlockMode`) |
| `vault_key_type` | display label (`x25519`, `yubikey`, `user`) |

---

## §3 — `/vault` command surface

Defined once as registry data (§4), dispatched to the Phase 1 `VaultHandle`:

| Command | Phase 1 op | Notes |
|---|---|---|
| `/vault setup` | `vhInit` (new) or `vhRekey` (exists) | interactive wizard (§2); writes config + key files; re-run on an existing vault triggers a confirmed rekey |
| `/vault add NAME` | `vhPut` | value entered via **hidden prompt** (`getPassword`), never an argv arg |
| `/vault get NAME` | `vhGet` | **reveals** the value to the terminal — an explicit, deliberate secret-reveal action |
| `/vault list` | `vhList` | names only, never values |
| `/vault delete NAME` | `vhDelete` | distinct "not found" result via Phase 1 `VaultKeyNotFound` |
| `/vault lock` | `vhLock` | |
| `/vault unlock` | `vhUnlock` | may prompt depending on backend/unlock mode |
| `/vault status` | `vhStatus` | locked?, secret count, key-type label |

`VaultLocked` / `VaultNotFound` / `VaultAlreadyExists` from Phase 1 drive the
user-facing branches (ask to unlock, suggest `/vault setup`, route to rekey).

---

## §4 — Command infrastructure (built properly, now)

Adopts the companion slash-command spec's registry model. Each command is
channel-agnostic data carrying an `optparse-applicative` `ParserInfo`, so **help
is derived from the parser and cannot drift**.

- **`Seal.Command.Spec`** — `CommandSpec { csName, csAliases, csGroup,
  csSynopsis, csParserInfo :: ParserInfo SlashCommand, csAvailability }`, the
  `CommandGroup` enum, and the assembled `Registry`. The vault command registers
  its spec from its own module.
- **`Seal.Command.Parse`** — a quote-aware, shell-words-style tokenizer (so
  `/vault add "my key"` works) + `parseSlash :: Registry → Text → Either Help
  SlashCommand`, bridging to `execParserPure prefs csParserInfo tokens`
  (`Success` → typed command; `Failure` → optparse's own error+usage text;
  `CompletionInvoked` → reserved, see below).
- **`Seal.Command.Help`** — `/help` renders the grouped command list from
  `csGroup`/`csName`/`csSynopsis`; `/help <cmd>` and `/<cmd> --help` are the
  *same operation* (render that command's optparse `ParserHelp` to `Text`).
  - **Exhaustive & discoverable, test-enforced:** a property test enumerates the
    registry and asserts every command **and every option** appears in some help
    output. Adding a command/option without making it discoverable **fails the
    build**. This is the "fully-functioning and exhaustive help system" bar.

### Completion-readiness (forward-compatible, not built now)

The help/registry design is structured so **argument completion** can be added
later with no rework:

- The `Registry` is introspectable data → command-name and alias completion is a
  pure fold over it.
- Each command carries its full `ParserInfo` → option/flag/metavar completion is
  derivable per command; `optparse-applicative` already emits bash/zsh/fish
  completion scripts and surfaces the `CompletionInvoked` branch from
  `execParserPure`. We **reserve and document** that branch now (no-op in the
  REPL) rather than discarding it.
- A future Haskeline tab-completer (or a `seal --bash-completion-*` hook on the
  separate startup CLI) consults the same two sources. No command is ever
  redefined for completion.

---

## §5 — CLI REPL channel (minimal)

`Seal.Channel.Cli` — a `haskeline` loop: `> ` prompt, line history persisted in
`state/history`, `getPassword` for hidden secret entry (`/vault add`). Each line
goes through the §6 ingest chokepoint. EOF (Ctrl-D) exits. This is intentionally
thin — no tabs, no panes, no colors beyond what `optparse`/plain text give us.

`ChannelCaps` (interactive `prompt` / `promptSecret`) is included from the start
so `/vault setup` and `/vault add` work interactively here, and the *same*
command code returns a structured **deferral** on a non-interactive channel
(web) when that lands — exactly the companion spec's behavior.

---

## §6 — Ingest seam (chokepoint now, stages later)

`Seal.Ingest` provides the single `ingest :: ChannelCaps → RawInbound → App
Disposition` chokepoint and the ordered `PreprocessChain`, **as a no-op seam**
for this MVP: the chain runs first (before any dispatch) but contains no
scan/authorize stages yet. This installs the structural guarantee from the
companion spec — every inbound line, on every future channel, passes one door —
without building the scanners now. `Disposition` for the MVP is just
`SlashCommand` vs `PlainText` (plain text is currently a no-op "no agent yet"
message); **Layer-1 tab routing is deferred** (single-session CLI has no tabs).

---

## §7 — Module shape (proposed; finalized in the plan)

- `Seal.Config.Paths` — `SEAL_HOME`/`~/.seal` resolution; create `config/`,
  `state/`, `keys/` (0700) with correct modes; typed roots.
- `Seal.Config.File` — `config.toml` load/update (TOML), incl. the vault fields.
- `Seal.Security.Path` (extend) — add `KeysRoot` + `mkSafeKeyPath` (0700 dir,
  0600/0400 + owner check) on the Phase 1 confinement primitive.
- `Seal.Vault.Backend` — `VaultKeyBackend`, setup flows (age-keygen / plugin
  detect+generate / user-supplied), recipient+identity production, config write.
- `Seal.Vault.Commands` — the `/vault` `CommandSpec` + handlers over Phase 1
  `VaultHandle`.
- `Seal.Command.Spec` / `Seal.Command.Parse` / `Seal.Command.Help` — the registry,
  tokenizer+parse bridge, and derived/discoverable help.
- `Seal.Ingest` — `ingest`, `PreprocessChain` (no-op), `Disposition`, `RawInbound`.
- `Seal.Channel.Cli` — the Haskeline REPL + `ChannelCaps`.
- `exe/Main.hs` (extend) — a `repl` entry that wires paths → config → vault →
  registry → ingest → CLI loop. The existing `greet`/`tick` placeholders are
  retired here.

The leaf-ish dependency rule holds: the command/ingest stack depends only on
`Seal.Core`/`Seal.Security`/`Seal.Config` + `ChannelCaps`.

---

## §8 — Non-goals / deferred

- Web gateway (Warp/WAI), WebSocket transcript broker, React/TS frontend.
- Layer-1 tab routing and the multi-conversation tab UX.
- `scan` / `authorize` preprocess stages (seam only this phase).
- The agent turn / LLM provider loop (plain text is a stub).
- Passphrase vault backend; sqlite/RAG/memory stores; Signal/Telegram channels;
  non-vault commands. All register into the *same* infra later.

---

## §9 — Testing strategy

- **Tokenizer** — quote/whitespace properties; no token escapes quoting.
- **Registry/parse** — each spec parses its own synopsis; alias resolution;
  unknown command → helpful error.
- **Discoverability invariant (key test)** — every command + every option
  surfaces in some help output; build fails otherwise.
- **Help rendering** — `/help vault` == `/vault --help`.
- **Ingest ordering** — a probe stage runs before dispatch for every
  `Disposition`; the no-op chain leaves behavior unchanged.
- **Paths/modes** — under a `SEAL_HOME` temp dir: `config/`/`state/`/`keys/`
  created, `keys/` is `0700`, identity files `0600`, vault file `0600`;
  `mkSafeKeyPath` rejects `..`/escape/loose-mode.
- **Vault commands end-to-end** — against the Phase 1 **mock encryptor**: setup
  → add → get → list → delete → lock/unlock → status; rekey on re-setup.
- **Real-`age` setup** — a `pendingWith`-guarded test for `LocalAgeKey`
  (age-keygen → real encrypt/decrypt round-trip); `YubiKey` setup guarded on
  `age-plugin-yubikey` presence (skips in CI without the binary/token).

---

## §10 — Clean-room & style constraints (inherited)

All [[seal-harness-clean-room]] rules hold: no reference to any upstream
project anywhere; `Seal.*` namespace; haskell-coder style (GHC2021, whole-module
imports, `-Wall -Werror` + strict set, `Either Text` default with a typed ADT
only where control flow branches — `VaultKeyBackend`/`Disposition` qualify);
hlint clean; TDD with QuickCheck for the pure parser/registry/help logic.

---

## §11 — Roadmap reconciliation

This phase **reprioritizes the channel order** the companion slash-command spec
assumed:

- The committed spec's "**Web = the MVP channel, CLI = much later**" becomes:
  **the CLI REPL is the bootstrap test channel (this phase); Web remains the
  eventual primary UX (a later phase).** The command/ingress *infrastructure* is
  unchanged — web plugs into the exact registry/help/ingest built here.
- The master roadmap
  (`docs/superpowers/plans/2026-06-28-seal-harness-roadmap.md`) and the companion
  spec's "Roadmap impact" section are updated to record this when the
  implementation plan is written.

## §12 — Open questions / deferred decisions

- Exact final `Seal.*` module names (settled in the plan).
- Whether `config/.gitignore` should ship with a default ignoring `../state` and
  `../keys` siblings (only relevant if a user `git init`s at `~/.seal` instead of
  `~/.seal/config`); default assumes tracking `config/`.
- YubiKey `--pin-policy` default (`once` vs `never`) alongside the touch choice —
  pinned in the plan when the wizard is specified in detail.
- Whether `/vault get` should require a confirm or a `--reveal` flag (MVP: direct
  reveal; revisit if it feels too easy to footgun).
