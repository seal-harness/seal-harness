# Default agent binding at session init

**Date**: 2026-07-06 · **Status**: draft · **Branch target**: `skills-and-agents`

## 1. Problem

`fcDefaultAgent` is persisted by `/agent default <id>` but never read at
session start. `initSession` (`Session/Store.hs:111`) only resolves
`smProvider`/`smModel` from `fcDefaultProvider`/`fcDefaultModel`; the
default agent is invisible to new sessions. Additionally, `runTurn`
(`Agent/Loop.hs:62`) sets `crSystem = Nothing` — the system prompt never
reaches the provider as a system field (sub-agents currently pass it as
the first user message, a hack).

**User's definition**: "An agent is the things that get injected into the
beginning of the context window." So binding a default agent means: at
session init, resolve the agent def, persist its id, and inject its
system prompt into every turn as the system field.

## 2. Design

### 2.1 `SessionMeta` gains `smAgent :: Maybe AgentDefId`

Persisted in `session.json`. Bound once at init from `fcDefaultAgent`.
Mid-session `/agent default x` affects only future sessions (mirrors
`smProvider`/`smModel`). `FromJSON` is tolerant: missing field → `Nothing`
(older session.json files still load).

### 2.2 `initSession` resolves the default agent def

`initSession` gains access to the `AgentDefBackend` (new parameter) so it
can resolve `fcDefaultAgent`. Resolution:

1. `fcDefaultAgent = Nothing` → `smAgent = Nothing`; provider/model from
   `defaultSessionSelection` as today.
2. `fcDefaultAgent = Just aid` but def missing on disk → warn to stderr
   ("default agent <id> not found; proceeding without one"), `smAgent =
   Nothing`, provider/model from config defaults.
3. `fcDefaultAgent = Just aid` and def exists → `smAgent = Just aid`.
   If the def's `adProvider`/`adModel` are non-empty, they **override**
   the config defaults (matches PureClaw `resolveOverride` precedence:
   frontmatter > config > default). Empty fields fall back to the config
   defaults (the dir-scheme-no-frontmatter case).

### 2.3 `AgentEnv` gains `aeSystem :: Maybe Text`

`runTurn` sets `crSystem = aeSystem env` (fixes the `crSystem = Nothing`
bug). The `EnvelopeDelta.edSystem` on the Request entry also carries
`aeSystem` so the transcript records it.

### 2.4 `mkSessionAgentEnv` takes `aeSystem`

New parameter: `mkSessionAgentEnv caps provider provLabel model sid
system isaReg tHandle`. The main session's `system` comes from the
resolved default agent's `adSystem`. Sub-agent workers (`mkWorker` in
`Cli.hs`) pass `adSystem def` as `aeSystem` instead of as the first user
message (removes the hack at `Cli.hs:248`).

### 2.5 Wiring (`Tui.hs`, `Cli.hs`)

`Tui.runTui`: build backends *before* `initSession` (currently backends
are built after). Pass `bAgentDefs` to `initSession`. Resolve the default
agent's `adSystem` and thread it into `mkSessionAgentEnv` in
`handlePlain`.

`Cli.runCliTui`: `handlePlain` already reads the active session meta; it
now also resolves the agent def's system prompt when `smAgent` is set
(cached per-session — read once at first turn, or re-read per turn for
simplicity; re-read is fine, agent dirs are small).

## 3. File scope

| File | Change |
|---|---|
| `src/Seal/Session/Meta.hs` | Add `smAgent :: Maybe AgentDefId`; ToJSON/FromJSON (tolerant) |
| `src/Seal/Session/Store.hs` | `initSession` takes `AgentDefBackend`; resolves default agent; provider/model override |
| `src/Seal/Agent/Env.hs` | Add `aeSystem :: Maybe Text` |
| `src/Seal/Agent/Loop.hs` | `crSystem = aeSystem`; `edSystem = aeSystem` |
| `src/Seal/Channel/Cli.hs` | `mkSessionAgentEnv` takes system; `handlePlain` resolves agent system; `mkWorker` passes `adSystem` as `aeSystem` not user message |
| `src/Seal/Tui.hs` | Build backends before `initSession`; pass `bAgentDefs` to `initSession` |
| `test/Seal/Session/StoreSpec.hs` | Update `initSession` calls (new arg); add default-agent-override + missing-agent cases |
| `test/Seal/Session/MetaSpec.hs` | Round-trip `smAgent` field; tolerant FromJSON |
| `test/Seal/Phase5Spec.hs` | Update `mkSessionAgentEnv` calls (new arg) |

## 4. Definition of Done

- [ ] `cabal build all` -Werror clean; `hlint src/ test/` clean.
- [ ] `cabal test` green; 0 failures, 0 new pending beyond pre-existing 6.
- [ ] A new test asserts: `initSession` with `fcDefaultAgent = Just "zoe"`
      and a `zoe/` dir with `AGENTS.md` frontmatter `model = "foo"` →
      `smAgent = Just zoe`, `smModel = "foo"` (override).
- [ ] A new test asserts: `initSession` with `fcDefaultAgent = Just "missing"`
      → `smAgent = Nothing`, warns, proceeds with config defaults.
- [ ] A new test asserts: `SessionMeta` with `smAgent = Just aid`
      round-trips through JSON; an older JSON without the field decodes
      to `smAgent = Nothing`.
- [ ] A new test asserts: `runTurn` with `aeSystem = Just "sys"` sends
      `crSystem = Just "sys"` to the provider (the ScriptProvider sees
      it). This may already be covered by an existing ISA/Loop spec —
      check first; if so, no new test needed.
- [ ] UAT: set `default_agent = "zoe"` in `~/.seal/config/config.toml`,
      run `make tui`, verify the startup line shows the resolved
      provider/model (overridden by zoe's frontmatter if present) and a
      plain-text turn uses zoe's composed prompt as the system field.

## 5. Human checkpoints

1. **After implementation lands and tests pass** — manual UAT per the
   DoD item above.

## 6. Risks / open questions

- **Backwards compat**: existing `session.json` files have no `agent`
  field. The tolerant `FromJSON` (missing → `Nothing`) handles this;
  no migration.
- **Provider/model override precedence**: the def overrides config. If
  the user sets `default_agent = "zoe"` and `zoe`'s `AGENTS.md` has
  `model = "claude-opus-4-8"` but the user also has `default_model =
  "glm-5.2:cloud"` in config, the def wins. This matches PureClaw's
  philosophy but may surprise. The `/model use` command still works
  mid-session to override. Document in the `/agent default` help.
- **Re-reading the agent def per turn**: if the user edits `zoe/SOUL.md`
  mid-session, the next turn picks up the change (re-read). Slight cost
  per turn; acceptable. If it becomes hot, cache per-session.
- **Sub-agent `mkWorker` change**: removing the user-message hack is a
  behavior change for sub-agents. The composed prompt now goes to the
  system field where it belongs; the first user message is the actual
  task. The Phase5Spec capstone may need updating if it asserts on the
  user-message form of the system prompt.