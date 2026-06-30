# Phase 2 MVP — Vault `/`-Commands over a CLI REPL — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking. Load the repo's `haskell-coder` skill
> before writing any Haskell, and follow `CONTRIBUTING.md`.

**Goal:** Let a human type `/vault …` commands at a terminal REPL and operate the
Phase 1 encrypted vault end-to-end — built on a proper, reusable, channel-agnostic
command + help infrastructure, not a throwaway.

**Architecture:** A single `ingest` chokepoint classifies each inbound line; a
channel-agnostic command **registry** (each command an `optparse-applicative`
parser producing a `CommandAction`) drives dispatch and **auto-derived,
discoverable help**. A thin Haskeline REPL is the first channel. The vault is the
Phase 1 `Seal.Security.Vault` reused unchanged; key material (local age / YubiKey
/ user-supplied identities) is produced by a setup wizard and resolved into the
Phase 1 `mkAgeEncryptor`. Config lives in a git-trackable `~/.seal/config/`;
mutable data and private keys live outside it.

**Tech Stack:** GHC2021 + the Phase 1 strict warning set; `optparse-applicative`
(command parsing + help + future completion), `haskeline` (REPL + hidden input),
`tomland` (`config.toml`), `typed-process` (`age`/`age-keygen`/`age-plugin-*`),
`unix`/`directory`/`filepath` (paths + modes), `stm`/`IORef` (vault state),
`hspec` + `QuickCheck` + `temporary` (tests).

## Global Constraints

These bind **every** task (copied from the approved design
`docs/superpowers/specs/2026-06-28-phase-2-vault-cli-mvp-design.md` §10 and the
Phase 1 conventions):

- **Clean-room:** no reference to any external/upstream project anywhere — code,
  identifiers, comments, commit messages, docs. The strings
  `pureclaw`/`PureClaw`/`OpenClaw` must NOT appear.
- **Namespace:** all new modules under `Seal.*` (`Seal.Command.*`,
  `Seal.Config.*`, `Seal.Vault.*`, `Seal.Channel.*`, `Seal.Ingest`, `Seal.Repl`).
- **Style (haskell-coder):** GHC2021; situational extensions (`OverloadedStrings`,
  `LambdaCase`, `GeneralizedNewtypeDeriving`) as per-file `{-# LANGUAGE #-}`
  pragmas, not `default-extensions`; whole-module imports with qualified aliases
  for `Data.Text`/`Data.Map.Strict`/etc.; `deriving stock`/`deriving newtype`
  explicitly; capability-handle records of IO functions (no handle type classes);
  no effect systems.
- **Errors:** default `Either Text`; a bespoke error ADT only where control flow
  branches on it (this phase: `VaultKeyBackend`, `ParseOutcome`, `Disposition`,
  and Phase 1's `VaultError`/`PathError` qualify). Reuse Phase 1 `VaultError`;
  add `PathInsecureMode FilePath` to the existing `PathError`.
- **Flags & gates:** `-Wall -Werror` + the strict set stays clean; `hlint src/
  test/` reports `No hints`; test output is pristine; the suite stays sub-second
  (bound QuickCheck generators; no unbounded filesystem trees).
- **No secret leaks:** secret values entered via `ccPromptSecret` (hidden);
  `SafeKeyPath` has an unexported constructor + redacted `Show`; identity files
  are mode `0600`, `keys/` is `0700`.
- **Verify in the Nix dev shell.** Every run is `nix develop --command …` from
  the repo root. **One commit per task** with the trailer
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Never
  use `--no-verify`.
- **Cabal/test wiring:** the test-suite `build-depends` must also include `unix`
  (added in Task 0 / first needed in Task 5) alongside the existing
  `directory`/`filepath`/`typed-process`/`temporary`. Each new module registers
  itself in `seal-harness.cabal` (`exposed-modules:` / test `other-modules:`) and
  in `test/Main.hs` within its own task.

## File Structure

| File | Responsibility | Task | Issue |
|---|---|---|---|
| `seal-harness.cabal` | Add `haskeline` + `tomland` (+ test `unix`); register modules. | 0 | — |
| `src/Seal/Channel/Caps.hs` | `ChannelCaps` capability handle (send / prompt / promptSecret). | 1 | #1 |
| `src/Seal/Command/Spec.hs` | `CommandSpec`/`Registry`/`CommandAction`; registry lookup. | 2 | #1 |
| `src/Seal/Command/Parse.hs` | Quote-aware tokenizer + `parseSlash` (`execParserPure` bridge). | 3 | #1 |
| `src/Seal/Command/Help.hs` | `/help` index + per-command help; discoverability invariant. | 4 | #1 |
| `src/Seal/Config/Paths.hs` | `~/.seal`/`SEAL_HOME` resolution + dir bootstrap with modes. | 5 | #2 |
| `src/Seal/Security/Path.hs` | (extend) `KeysRoot` + `mkSafeKeyPath` + `PathInsecureMode`. | 6 | #3 |
| `src/Seal/Config/File.hs` | `config.toml` load/update (tomland). | 7 | #4 |
| `src/Seal/Vault/Backend.hs` | Key backends (local/YubiKey/user), setup, `resolveEncryptor`. | 8 | — |
| `src/Seal/Vault/Commands.hs` | The `/vault` `CommandSpec` over the Phase 1 `VaultHandle`. | 9 | — |
| `src/Seal/Ingest.hs` | `ingest` chokepoint + no-op `PreprocessChain` + `Disposition`. | 10 | — |
| `src/Seal/Channel/Cli.hs`, `src/Seal/Repl.hs`, `exe/Main.hs`, `src/Seal/Types/Command.hs`, `src/Seal/AppMain.hs` | Haskeline REPL + `runRepl` wiring + `repl` subcommand. | 11 | — |

## Task ordering, parallelism, and issue mapping

Tasks are numbered in a valid dependency order (0 → 11). After **Task 0**, the
leaf tasks **1–7** are mutually independent and map to the filed GitHub issues —
they can be worked in parallel by different contributors:

- **Issue #1** → Tasks 1–4 (`Seal.Channel.Caps` + `Seal.Command.*`).
- **Issue #2** → Task 5 (`Seal.Config.Paths`).
- **Issue #3** → Task 6 (`Seal.Security.Path` KeysRoot).
- **Issue #4** → Task 7 (`Seal.Config.File`).

The integration tasks **8–11** depend on the leaves: Task 8 needs 5/6/7 + Phase 1;
Task 9 needs 2 + 8; Task 10 needs 2/3/4; Task 11 needs 9/10/5. The only shared
merge points are `seal-harness.cabal` and `test/Main.hs` — keep edits there
minimal and rebase before opening a PR (see `CONTRIBUTING.md`).

Each task's **Interfaces** block names the exact signatures it consumes from
earlier tasks and produces for later ones; these are the canonical contract — do
not rename across tasks.

---


---

### Task 0: Project deps + module registration

**Files:**
- **Modify:** `seal-harness.cabal`

**Interfaces:** Produces `haskeline` and `tomland` available in the `library`
and `executable seal` stanzas.

#### Registration convention — ALL later tasks follow this checklist

Every task that introduces new source files MUST, as its **first step**:

- [ ] Add each new library module to `exposed-modules:` in `seal-harness.cabal`.
- [ ] Add each new test module to `other-modules:` in the `test-suite tests` stanza.
- [ ] Add `import qualified <Spec>` to `test/Main.hs`.
- [ ] Call `<Spec>.spec` inside the `hspec $ do` block in `test/Main.hs`.

These registrations happen in the same task as the new file, before any code
that imports the new module is written.

#### Steps

- [ ] **Step 1: Add `haskeline` and `tomland` to `seal-harness.cabal`**

  In the `library` stanza, append to `build-depends:`:

  ```cabal
        , haskeline
        , tomland
  ```

  In the `executable seal` stanza, append to `build-depends:`:

  ```cabal
        , haskeline
  ```

  Exact diff:

  ```diff
  --- a/seal-harness.cabal
  +++ b/seal-harness.cabal
  @@ library build-depends @@
         , stm
  +      , haskeline
  +      , tomland
  
  @@ executable seal build-depends @@
         , seal-harness
  +      , haskeline
  ```

- [ ] **Step 2: Verify the existing suite still builds and passes**

  ```
  nix develop --command cabal build all 2>&1 | tail -20
  nix develop --command cabal test         2>&1 | tail -20
  ```

  Expected: all existing tests pass; no new warnings or errors.

- [ ] **Step 3: Commit**

  ```
  git add seal-harness.cabal
  git commit -m "$(cat <<'EOF'
  Add haskeline + tomland deps

  haskeline supplies the line-editor REPL (Seal.Channel.Cli).
  tomland supplies the TOML codec (Seal.Config.File).
  Both are added to the library; haskeline is also added to the
  executable because the exe directly runs the InputT loop.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---



---

### Task 1: Seal.Channel.Caps

> GitHub issue: #1

**Files:**
- Create `src/Seal/Channel/Caps.hs`
- Modify `seal-harness.cabal` — add `Seal.Channel.Caps` to library `exposed-modules`

**Interfaces:**
- Produces: `ChannelCaps` — consumed by Tasks 2, 9, 10, 11
- Consumes: nothing (leaf; `base` + `text` only)

---

- [ ] **Step 1: Create `src/Seal/Channel/Caps.hs` and register in cabal**

  `src/Seal/Channel/Caps.hs`:
  ```haskell
  {-# LANGUAGE OverloadedStrings #-}
  module Seal.Channel.Caps
    ( ChannelCaps(..)
    ) where

  import Data.Text (Text)

  -- | A channel's interaction capabilities as a record of IO functions
  -- (house style: no type class; callers receive the handle and call fields
  -- directly). Web deferral of prompts is a later phase; the CLI REPL
  -- is always interactive.
  data ChannelCaps = ChannelCaps
    { ccSend         :: Text -> IO ()   -- ^ Emit one line to the user
    , ccPrompt       :: Text -> IO Text -- ^ Visible prompt; returns typed line
    , ccPromptSecret :: Text -> IO Text -- ^ Hidden (no-echo) prompt
    }
  ```

  In `seal-harness.cabal`, add to the library `exposed-modules` block:
  ```
      Seal.Channel.Caps
  ```

  ```bash
  nix develop --command cabal build 2>&1 | tail -10
  ```
  Expected: clean build, no warnings (`-Wall -Werror`).

- [ ] **Step 2: hlint + commit**

  ```bash
  nix develop --command hlint src/Seal/Channel/
  ```
  Expected: `No hints`.

  ```bash
  git add src/Seal/Channel/Caps.hs seal-harness.cabal
  git commit -m "$(cat <<'EOF'
  Add Seal.Channel.Caps leaf type for channel interaction capabilities

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

### Task 2: Seal.Command.Spec

> GitHub issue: #1

**Files:**
- Create `src/Seal/Command/Spec.hs`
- Create `test/Seal/Command/SpecSpec.hs`
- Modify `seal-harness.cabal` — add `Seal.Command.Spec` to `exposed-modules`; add `Seal.Command.SpecSpec` to test-suite `other-modules`
- Modify `test/Main.hs` — import and run `Seal.Command.SpecSpec`

**Interfaces:**
- Produces: `CommandName`, `CommandGroup`, `Availability`, `CommandAction`, `CommandSpec`, `Registry`, `mkRegistry`, `registrySpecs`, `lookupSpec` — consumed by Tasks 3, 4, 9, 10
- Consumes: `Seal.Channel.Caps` (`ChannelCaps`); `optparse-applicative` (`ParserInfo`)

---

- [ ] **Step 1: Create stub `src/Seal/Command/Spec.hs` (types + `undefined` bodies)**

  `src/Seal/Command/Spec.hs`:
  ```haskell
  {-# LANGUAGE OverloadedStrings #-}
  module Seal.Command.Spec
    ( CommandName(..)
    , CommandGroup(..)
    , Availability(..)
    , CommandAction(..)
    , CommandSpec(..)
    , Registry(..)
    , mkRegistry
    , registrySpecs
    , lookupSpec
    ) where

  import Data.Text (Text)
  import Options.Applicative (ParserInfo)

  import Seal.Channel.Caps (ChannelCaps)

  newtype CommandName = CommandName Text
    deriving stock (Eq, Ord, Show)

  data CommandGroup
    = GroupGeneral
    | GroupVault
    deriving stock (Eq, Ord, Show, Enum, Bounded)

  data Availability
    = AlwaysAvailable
    | InteractiveOnly
    deriving stock (Eq, Show)

  -- | The runnable action a successfully-parsed command performs on its channel.
  newtype CommandAction = CommandAction { runCommandAction :: ChannelCaps -> IO () }

  data CommandSpec = CommandSpec
    { csName         :: CommandName
    , csAliases      :: [CommandName]
    , csGroup        :: CommandGroup
    , csSynopsis     :: Text              -- ^ One line for /help index
    , csParserInfo   :: ParserInfo CommandAction
    , csAvailability :: Availability
    }

  -- | NOTE: /help is NOT a registered spec — it is a meta-operation handled by
  -- Seal.Command.Help / Seal.Command.Parse over the Registry (avoids the
  -- registry-needs-itself knot). Feature modules build their own CommandSpec
  -- and the startup wiring assembles the Registry.
  newtype Registry = Registry { registrySpecs :: [CommandSpec] }

  mkRegistry :: [CommandSpec] -> Registry
  mkRegistry = undefined

  -- | Case-insensitive head-word lookup honouring aliases.
  lookupSpec :: Registry -> CommandName -> Maybe CommandSpec
  lookupSpec = undefined
  ```

  In `seal-harness.cabal` library `exposed-modules`:
  ```
      Seal.Command.Spec
  ```

  ```bash
  nix develop --command cabal build 2>&1 | tail -10
  ```
  Expected: clean build (stubs compile; `undefined` deferred to runtime).

- [ ] **Step 2: Write `test/Seal/Command/SpecSpec.hs` — RED**

  `test/Seal/Command/SpecSpec.hs`:
  ```haskell
  {-# LANGUAGE OverloadedStrings #-}
  module Seal.Command.SpecSpec (spec) where

  import Data.IORef (newIORef, readIORef, writeIORef)
  import Test.Hspec
  import Options.Applicative

  import Seal.Channel.Caps (ChannelCaps(..))
  import Seal.Command.Spec

  -- ---------------------------------------------------------------------------
  -- Minimal throwaway CommandSpec used only in this test module.
  -- A /ping command with a --loud flag; no vault or external dependencies.
  -- ---------------------------------------------------------------------------

  data PingOpts = PingOpts { poLoud :: Bool }

  pPingOpts :: Parser PingOpts
  pPingOpts = PingOpts
    <$> switch (long "loud" <> short 'l' <> help "Shout the response")

  pingSpec :: CommandSpec
  pingSpec = CommandSpec
    { csName         = CommandName "ping"
    , csAliases      = [CommandName "p"]
    , csGroup        = GroupGeneral
    , csSynopsis     = "Check connectivity"
    , csParserInfo   = info (fmap toPingAction pPingOpts)
                            (progDesc "Send a ping and receive a pong")
    , csAvailability = AlwaysAvailable
    }
    where
      toPingAction (PingOpts loud) = CommandAction $ \caps ->
        ccSend caps (if loud then "PONG!" else "pong")

  echoSpec :: CommandSpec
  echoSpec = CommandSpec
    { csName         = CommandName "echo"
    , csAliases      = []
    , csGroup        = GroupGeneral
    , csSynopsis     = "Echo text back"
    , csParserInfo   = info (pure (CommandAction $ \caps -> ccSend caps "..."))
                            (progDesc "Echo the input back")
    , csAvailability = AlwaysAvailable
    }

  testRegistry :: Registry
  testRegistry = mkRegistry [pingSpec, echoSpec]

  -- ---------------------------------------------------------------------------

  spec :: Spec
  spec = describe "Seal.Command.Spec" $ do

    describe "mkRegistry / registrySpecs" $ do

      it "registrySpecs round-trips through mkRegistry" $
        length (registrySpecs testRegistry) `shouldBe` 2

      it "preserves insertion order" $ do
        let names = map csName (registrySpecs testRegistry)
        names `shouldBe` [CommandName "ping", CommandName "echo"]

    describe "lookupSpec" $ do

      it "finds a spec by exact name" $
        fmap csName (lookupSpec testRegistry (CommandName "ping"))
          `shouldBe` Just (CommandName "ping")

      it "finds a spec by alias" $
        fmap csName (lookupSpec testRegistry (CommandName "p"))
          `shouldBe` Just (CommandName "ping")

      it "lookup is case-insensitive on the name" $
        fmap csName (lookupSpec testRegistry (CommandName "PING"))
          `shouldBe` Just (CommandName "ping")

      it "lookup is case-insensitive on the alias" $
        fmap csName (lookupSpec testRegistry (CommandName "P"))
          `shouldBe` Just (CommandName "ping")

      it "returns Nothing for an unknown command" $
        lookupSpec testRegistry (CommandName "nonexistent")
          `shouldBe` Nothing

      it "finds the second spec when the first does not match" $
        fmap csName (lookupSpec testRegistry (CommandName "echo"))
          `shouldBe` Just (CommandName "echo")

    describe "CommandAction" $ do

      it "runCommandAction invokes the captured IO action" $ do
        ref <- newIORef ("" :: String)
        let caps = ChannelCaps
              { ccSend         = \t -> writeIORef ref (show t)
              , ccPrompt       = \_ -> pure ""
              , ccPromptSecret = \_ -> pure ""
              }
            action = CommandAction (\c -> ccSend c "hello")
        runCommandAction action caps
        readIORef ref `shouldReturn` "\"hello\""
  ```

  Register in `seal-harness.cabal` test-suite `other-modules`:
  ```
      Seal.Command.SpecSpec
  ```

  Add to `test/Main.hs`:
  ```haskell
  import qualified Seal.Command.SpecSpec
  -- …in the hspec $ do block:
  Seal.Command.SpecSpec.spec
  ```

  ```bash
  nix develop --command cabal test 2>&1 | tail -40
  ```
  Expected: **RED** — `undefined` in `mkRegistry`/`lookupSpec` throws exceptions.

- [ ] **Step 3: Implement `mkRegistry` and `lookupSpec` — GREEN**

  Replace the `undefined` stubs in `src/Seal/Command/Spec.hs` with:

  ```haskell
  {-# LANGUAGE OverloadedStrings #-}
  module Seal.Command.Spec
    ( CommandName(..)
    , CommandGroup(..)
    , Availability(..)
    , CommandAction(..)
    , CommandSpec(..)
    , Registry(..)
    , mkRegistry
    , registrySpecs
    , lookupSpec
    ) where

  import Data.List (find)
  import Data.Text (Text)
  import Data.Text qualified as T
  import Options.Applicative (ParserInfo)

  import Seal.Channel.Caps (ChannelCaps)

  newtype CommandName = CommandName Text
    deriving stock (Eq, Ord, Show)

  data CommandGroup
    = GroupGeneral
    | GroupVault
    deriving stock (Eq, Ord, Show, Enum, Bounded)

  data Availability
    = AlwaysAvailable
    | InteractiveOnly
    deriving stock (Eq, Show)

  newtype CommandAction = CommandAction { runCommandAction :: ChannelCaps -> IO () }

  data CommandSpec = CommandSpec
    { csName         :: CommandName
    , csAliases      :: [CommandName]
    , csGroup        :: CommandGroup
    , csSynopsis     :: Text
    , csParserInfo   :: ParserInfo CommandAction
    , csAvailability :: Availability
    }

  -- | NOTE: /help is NOT a registered spec — it is a meta-operation handled by
  -- Seal.Command.Help / Seal.Command.Parse over the Registry (avoids the
  -- registry-needs-itself knot). Feature modules build their own CommandSpec
  -- and the startup wiring assembles the Registry.
  newtype Registry = Registry { registrySpecs :: [CommandSpec] }

  mkRegistry :: [CommandSpec] -> Registry
  mkRegistry = Registry

  -- | Case-insensitive lookup by primary name or any alias.
  lookupSpec :: Registry -> CommandName -> Maybe CommandSpec
  lookupSpec (Registry specs) (CommandName needle) =
    find matchesAny specs
    where
      lower             = T.toCaseFold needle
      nameEq (CommandName n) = T.toCaseFold n == lower
      matchesAny spec   = nameEq (csName spec) || any nameEq (csAliases spec)
  ```

  ```bash
  nix develop --command cabal test 2>&1 | tail -40
  ```
  Expected: **GREEN** — all SpecSpec tests pass.

- [ ] **Step 4: hlint + commit**

  ```bash
  nix develop --command hlint src/Seal/Command/Spec.hs test/Seal/Command/SpecSpec.hs
  ```
  Expected: `No hints`.

  ```bash
  git add src/Seal/Command/Spec.hs test/Seal/Command/SpecSpec.hs \
          seal-harness.cabal test/Main.hs
  git commit -m "$(cat <<'EOF'
  Add Seal.Command.Spec: registry types and case-insensitive lookup

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

### Task 3: Seal.Command.Parse

> GitHub issue: #1

**Files:**
- Create `src/Seal/Command/Parse.hs`
- Create `test/Seal/Command/ParseSpec.hs`
- Modify `seal-harness.cabal` — add `Seal.Command.Parse` to `exposed-modules`; add `Seal.Command.ParseSpec` to test-suite `other-modules`
- Modify `test/Main.hs` — import and run `Seal.Command.ParseSpec`

**Interfaces:**
- Produces: `tokenize`, `ParseOutcome(..)`, `parseSlash` — consumed by Tasks 4, 10
- Consumes: `Seal.Command.Spec` (`Registry`, `CommandName`, `CommandAction`, `lookupSpec`); `optparse-applicative` (`execParserPure`, `defaultPrefs`, `renderFailure`)

---

- [ ] **Step 1: Create stub `src/Seal/Command/Parse.hs` — types only**

  `src/Seal/Command/Parse.hs`:
  ```haskell
  {-# LANGUAGE OverloadedStrings #-}
  module Seal.Command.Parse
    ( tokenize
    , ParseOutcome(..)
    , parseSlash
    ) where

  import Data.Text (Text)

  import Seal.Command.Spec (CommandAction, CommandName, Registry)

  -- | Quote-aware shell-words tokenizer.
  -- Supports double-quoted tokens (so @\/vault add "my key"@ works).
  -- Returns 'Left' with an error message if a quote is never closed.
  tokenize :: Text -> Either Text [Text]
  tokenize = undefined

  data ParseOutcome
    = ParsedAction CommandAction          -- ^ Run the parsed command
    | ParseHelp    (Maybe CommandName)    -- ^ /help, /help <cmd>, or /<cmd> --help
    | ParseFailure Text                   -- ^ Unknown command or optparse error text
    -- NOTE: CompletionInvoked from execParserPure is reserved for future
    -- shell-completion integration (seal --bash-completion-*). The REPL never
    -- triggers it; the MVP maps it to ParseFailure "" (empty message, not shown).

  -- | Parse a full slash-command line (input MUST begin with @\/@).
  -- Strips the leading @\/@, tokenizes, then routes:
  --   head == "help"           -> ParseHelp (optional second token as CommandName)
  --   "--help" or "-h" present -> ParseHelp (Just headName)
  --   known command            -> execParserPure -> ParsedAction | ParseFailure
  --   unknown command          -> ParseFailure
  parseSlash :: Registry -> Text -> ParseOutcome
  parseSlash = undefined
  ```

  In `seal-harness.cabal` library `exposed-modules`:
  ```
      Seal.Command.Parse
  ```

  ```bash
  nix develop --command cabal build 2>&1 | tail -10
  ```
  Expected: clean build.

- [ ] **Step 2: Write `test/Seal/Command/ParseSpec.hs` — RED**

  `test/Seal/Command/ParseSpec.hs`:
  ```haskell
  {-# LANGUAGE OverloadedStrings #-}
  module Seal.Command.ParseSpec (spec) where

  import Data.IORef (newIORef, readIORef, writeIORef)
  import Data.Text (Text)
  import Data.Text qualified as T
  import Test.Hspec
  import Test.Hspec.QuickCheck (prop)
  import Test.QuickCheck
  import Options.Applicative

  import Seal.Channel.Caps (ChannelCaps(..))
  import Seal.Command.Spec
  import Seal.Command.Parse

  -- ---------------------------------------------------------------------------
  -- Sample registry (same ping/echo specs as SpecSpec; kept local to this
  -- module so ParseSpec has no dependency on SpecSpec).
  -- ---------------------------------------------------------------------------

  data PingOpts = PingOpts { poLoud :: Bool }

  pPingOpts :: Parser PingOpts
  pPingOpts = PingOpts
    <$> switch (long "loud" <> short 'l' <> help "Shout the response")

  pingSpec :: CommandSpec
  pingSpec = CommandSpec
    { csName         = CommandName "ping"
    , csAliases      = [CommandName "p"]
    , csGroup        = GroupGeneral
    , csSynopsis     = "Check connectivity"
    , csParserInfo   = info (fmap toPingAction pPingOpts)
                            (progDesc "Send a ping and receive a pong")
    , csAvailability = AlwaysAvailable
    }
    where
      toPingAction (PingOpts loud) = CommandAction $ \caps ->
        ccSend caps (if loud then "PONG!" else "pong")

  testRegistry :: Registry
  testRegistry = mkRegistry [pingSpec]

  -- ---------------------------------------------------------------------------
  -- A "word" safe for the tokenizer QuickCheck: non-empty, no spaces, no quotes.
  -- ---------------------------------------------------------------------------

  newtype SafeWord = SafeWord Text deriving (Show)

  instance Arbitrary SafeWord where
    arbitrary = do
      n  <- choose (1 :: Int, 20)
      cs <- vectorOf n $
              elements (['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ ['-', '_'])
      pure (SafeWord (T.pack cs))

  unSafe :: SafeWord -> Text
  unSafe (SafeWord t) = t

  -- ---------------------------------------------------------------------------

  spec :: Spec
  spec = describe "Seal.Command.Parse" $ do

    describe "tokenize" $ do

      it "empty input yields empty list" $
        tokenize "" `shouldBe` Right []

      it "single word" $
        tokenize "hello" `shouldBe` Right ["hello"]

      it "splits on spaces" $
        tokenize "foo bar baz" `shouldBe` Right ["foo", "bar", "baz"]

      it "collapses multiple spaces" $
        tokenize "foo  bar" `shouldBe` Right ["foo", "bar"]

      it "strips leading and trailing spaces" $
        tokenize "  ping  " `shouldBe` Right ["ping"]

      it "double-quoted string becomes a single token" $
        tokenize "\"hello world\"" `shouldBe` Right ["hello world"]

      it "double-quoted token adjacent to plain token concatenates" $
        tokenize "foo\"bar\"" `shouldBe` Right ["foobar"]

      it "quoted section containing spaces is one token" $
        tokenize "vault add \"my secret key\"" `shouldBe`
          Right ["vault", "add", "my secret key"]

      it "empty quoted string is a valid token" $
        tokenize "\"\"" `shouldBe` Right [""]

      it "unterminated double-quote returns Left" $
        case tokenize "\"hello" of
          Left  _ -> pure ()
          Right _ -> expectationFailure "expected Left for unterminated quote"

      it "unterminated quote mid-word returns Left" $
        case tokenize "foo \"bar" of
          Left  _ -> pure ()
          Right _ -> expectationFailure "expected Left for unterminated quote"

      prop "plain words survive a round-trip through tokenize" $
        \(NonEmpty ws) ->
          let words' = map unSafe ws
              input  = T.intercalate " " words'
          in tokenize input === Right words'

      prop "double-quoted word is a single token regardless of spaces inside" $
        \(SafeWord prefix) (SafeWord suffix) ->
          let inner = prefix <> " " <> suffix
              tok   = "\"" <> inner <> "\""
          in tokenize tok === Right [inner]

    describe "parseSlash" $ do

      it "/help -> ParseHelp Nothing" $
        case parseSlash testRegistry "/help" of
          ParseHelp Nothing -> pure ()
          other -> expectationFailure ("unexpected: " <> show (fmap csName (pure other)))

      it "/help ping -> ParseHelp (Just (CommandName \"ping\"))" $
        case parseSlash testRegistry "/help ping" of
          ParseHelp (Just (CommandName "ping")) -> pure ()
          _ -> expectationFailure "expected ParseHelp (Just ping)"

      it "/HELP is case-insensitive -> ParseHelp Nothing" $
        case parseSlash testRegistry "/HELP" of
          ParseHelp Nothing -> pure ()
          _ -> expectationFailure "expected ParseHelp Nothing for /HELP"

      it "/ping --help -> ParseHelp (Just (CommandName \"ping\"))" $
        case parseSlash testRegistry "/ping --help" of
          ParseHelp (Just (CommandName "ping")) -> pure ()
          _ -> expectationFailure "expected ParseHelp (Just ping) for --help flag"

      it "/ping -h -> ParseHelp (Just (CommandName \"ping\"))" $
        case parseSlash testRegistry "/ping -h" of
          ParseHelp (Just (CommandName "ping")) -> pure ()
          _ -> expectationFailure "expected ParseHelp (Just ping) for -h flag"

      it "/unknown -> ParseFailure with the unknown command name" $
        case parseSlash testRegistry "/nosuchcmd" of
          ParseFailure msg -> T.isInfixOf "nosuchcmd" msg `shouldBe` True
          _                -> expectationFailure "expected ParseFailure"

      it "/ping (no flags) -> ParsedAction" $ do
        ref <- newIORef ("" :: Text)
        let caps = ChannelCaps
              { ccSend         = writeIORef ref
              , ccPrompt       = \_ -> pure ""
              , ccPromptSecret = \_ -> pure ""
              }
        case parseSlash testRegistry "/ping" of
          ParsedAction action -> do
            runCommandAction action caps
            readIORef ref `shouldReturn` "pong"
          other -> expectationFailure ("expected ParsedAction, got: " <> show (isHelp other))

      it "/ping --loud -> ParsedAction that sends PONG!" $ do
        ref <- newIORef ("" :: Text)
        let caps = ChannelCaps
              { ccSend         = writeIORef ref
              , ccPrompt       = \_ -> pure ""
              , ccPromptSecret = \_ -> pure ""
              }
        case parseSlash testRegistry "/ping --loud" of
          ParsedAction action -> do
            runCommandAction action caps
            readIORef ref `shouldReturn` "PONG!"
          other -> expectationFailure ("expected ParsedAction, got: " <> show (isHelp other))

      it "/p (alias) -> ParsedAction" $
        case parseSlash testRegistry "/p" of
          ParsedAction _ -> pure ()
          _              -> expectationFailure "expected ParsedAction for alias /p"

      it "unterminated quote -> ParseFailure" $
        case parseSlash testRegistry "/ping \"unterminated" of
          ParseFailure _ -> pure ()
          _              -> expectationFailure "expected ParseFailure for bad tokenize"

    where
      -- helper so show errors are informative without a Show instance on ParseOutcome
      isHelp :: ParseOutcome -> Bool
      isHelp (ParseHelp _) = True
      isHelp _             = False
  ```

  Register in `seal-harness.cabal` test-suite `other-modules`:
  ```
      Seal.Command.ParseSpec
  ```

  Add to `test/Main.hs`:
  ```haskell
  import qualified Seal.Command.ParseSpec
  -- …in hspec $ do:
  Seal.Command.ParseSpec.spec
  ```

  ```bash
  nix develop --command cabal test 2>&1 | tail -40
  ```
  Expected: **RED** — `undefined` in `tokenize`/`parseSlash` throws exceptions.

- [ ] **Step 3: Implement `tokenize` — partial GREEN (tokenizer only)**

  Replace `src/Seal/Command/Parse.hs` with the tokenizer implemented; `parseSlash` still `undefined`:

  ```haskell
  {-# LANGUAGE OverloadedStrings #-}
  module Seal.Command.Parse
    ( tokenize
    , ParseOutcome(..)
    , parseSlash
    ) where

  import Data.Char (isSpace)
  import Data.Text (Text)
  import Data.Text qualified as T
  import Options.Applicative
    ( ParserResult(..)
    , defaultPrefs
    , execParserPure
    , renderFailure
    )

  import Seal.Command.Spec
    ( CommandAction
    , CommandName(..)
    , Registry
    , csParserInfo
    , lookupSpec
    )

  -- ---------------------------------------------------------------------------
  -- Tokenizer
  -- ---------------------------------------------------------------------------

  -- Internal state for the tokenizer state machine.
  data TokSt
    = Outside              -- ^ Between tokens
    | InWord  [Char]       -- ^ Inside a bare token (reversed chars accumulated)
    | InQuote [Char]       -- ^ Inside a double-quoted span (reversed chars; continues
                           --   any preceding bare chars so adjacent quoted/unquoted
                           --   sections form a single token, e.g. foo"bar" -> "foobar")

  -- | Quote-aware shell-words tokenizer. Supports double-quoted tokens so that
  -- @\/vault add "my key"@ correctly produces three tokens. Returns 'Left' with
  -- an error message if a double-quote is never closed.
  tokenize :: Text -> Either Text [Text]
  tokenize input = go Outside (T.unpack input) []
    where
      -- Flush the current InWord accumulator as a completed token.
      flushWord :: [Char] -> [Text] -> [Text]
      flushWord cs acc = T.pack (reverse cs) : acc

      -- Finalize the state machine after all characters have been consumed.
      finish :: TokSt -> [Text] -> Either Text [Text]
      finish Outside    acc       = Right (reverse acc)
      finish (InWord cs) acc      = Right (reverse (flushWord cs acc))
      finish (InQuote _) _        = Left "unterminated double-quote"

      go :: TokSt -> [Char] -> [Text] -> Either Text [Text]
      go st          []     acc = finish st acc
      -- Outside: skip whitespace; open quote starts quoted token;
      -- any other char starts a bare word.
      go Outside     (c:cs) acc
        | c == '"'             = go (InQuote []) cs acc
        | isSpace c            = go Outside cs acc
        | otherwise            = go (InWord [c]) cs acc
      -- InWord: whitespace terminates this token; quote opens an adjacent
      -- quoted span (still building the *same* token); other chars extend.
      go (InWord ws) (c:cs) acc
        | c == '"'             = go (InQuote ws) cs acc
        | isSpace c            = go Outside cs (flushWord ws acc)
        | otherwise            = go (InWord (c:ws)) cs acc
      -- InQuote: closing quote returns to InWord (bare continuation allowed
      -- immediately after); other chars extend the quoted span.
      go (InQuote ws) (c:cs) acc
        | c == '"'             = go (InWord ws) cs acc
        | otherwise            = go (InQuote (c:ws)) cs acc

  -- ---------------------------------------------------------------------------
  -- ParseOutcome + parseSlash
  -- ---------------------------------------------------------------------------

  data ParseOutcome
    = ParsedAction CommandAction
    | ParseHelp    (Maybe CommandName)
    | ParseFailure Text

  parseSlash :: Registry -> Text -> ParseOutcome
  parseSlash = undefined
  ```

  ```bash
  nix develop --command cabal test 2>&1 | tail -40
  ```
  Expected: **RED** — tokenizer tests pass; `parseSlash` tests still fail on `undefined`.

- [ ] **Step 4: Implement `parseSlash` — GREEN**

  Replace `parseSlash = undefined` with the full implementation (the rest of the module is unchanged):

  ```haskell
  -- | Parse a full slash-command line; input MUST begin with @\/@.
  --
  -- Routing rules (in order):
  --   1. head word == "help" (case-insensitive) -> 'ParseHelp'
  --   2. "--help" or "-h" anywhere in tokens    -> 'ParseHelp' (Just head)
  --   3. head word found in registry            -> 'execParserPure' -> 'ParsedAction' or 'ParseFailure'
  --   4. head word not in registry              -> 'ParseFailure'
  --
  -- 'CompletionInvoked' from 'execParserPure' is reserved for future
  -- shell-completion integration (seal --bash-completion-*); the REPL
  -- never triggers it, so it maps to @ParseFailure ""@ (empty, not shown).
  parseSlash :: Registry -> Text -> ParseOutcome
  parseSlash registry fullLine =
    let line = T.drop 1 fullLine           -- strip leading '/'
    in case tokenize line of
      Left err     -> ParseFailure ("parse error: " <> err)
      Right []     -> ParseFailure "empty command"
      Right (h:rest) ->
        let headName = CommandName h
            -- case-insensitive "help" check
            isHelp   = T.toCaseFold h == "help"
            -- --help / -h flag present anywhere in the remaining tokens
            hasHelpFlag = "--help" `elem` rest || "-h" `elem` rest
        in if isHelp
           then ParseHelp (case rest of
                  []    -> Nothing
                  (n:_) -> Just (CommandName n))
           else if hasHelpFlag
                then ParseHelp (Just headName)
                else case lookupSpec registry headName of
                  Nothing   -> ParseFailure ("unknown command: " <> h)
                  Just spec ->
                    -- execParserPure expects [String], not [Text]
                    let args  = map T.unpack rest
                        -- defaultPrefs: enables --help/--version, no disambiguation,
                        -- single-line error context. CompletionInvoked is reserved
                        -- (see note above).
                        prefs = defaultPrefs
                    in case execParserPure prefs (csParserInfo spec) args of
                      Success action      -> ParsedAction action
                      Failure f           ->
                        let (msg, _) = renderFailure f (T.unpack h)
                        in ParseFailure (T.pack msg)
                      CompletionInvoked _ -> ParseFailure ""
  ```

  ```bash
  nix develop --command cabal test 2>&1 | tail -40
  ```
  Expected: **GREEN** — all ParseSpec and previously-passing tests pass.

- [ ] **Step 5: hlint + commit**

  ```bash
  nix develop --command hlint src/Seal/Command/Parse.hs test/Seal/Command/ParseSpec.hs
  ```
  Expected: `No hints`.

  ```bash
  git add src/Seal/Command/Parse.hs test/Seal/Command/ParseSpec.hs \
          seal-harness.cabal test/Main.hs
  git commit -m "$(cat <<'EOF'
  Add Seal.Command.Parse: quote-aware tokenizer and slash-command router

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

### Task 4: Seal.Command.Help

> GitHub issue: #1

**Files:**
- Create `src/Seal/Command/Help.hs`
- Create `test/Seal/Command/HelpSpec.hs`
- Modify `seal-harness.cabal` — add `Seal.Command.Help` to `exposed-modules`; add `Seal.Command.HelpSpec` to test-suite `other-modules`
- Modify `test/Main.hs` — import and run `Seal.Command.HelpSpec`

**Interfaces:**
- Produces: `renderHelpIndex`, `renderHelpFor` — consumed by Tasks 10, 11
- Consumes: `Seal.Command.Spec` (`Registry`, `CommandName`, `CommandSpec`, `CommandGroup(..)`, `csName`, `csSynopsis`, `csGroup`, `csParserInfo`, `lookupSpec`, `registrySpecs`); `optparse-applicative` (`execParserPure`, `defaultPrefs`, `renderFailure`)

**optparse-applicative help-rendering decisions (see short note at end):**
- `renderHelpFor` calls `execParserPure defaultPrefs info ["--help"]`. This always returns `Failure (ParserFailure ParserHelp)` because `--help` is optparse's built-in help action. We then call `renderFailure f progName` which returns `(String, ExitCode)`; we take the `String` and pack it to `Text`. The exit code (`ExitSuccess` for `--help`) is discarded — we only need the text.
- `renderHelpIndex` produces a static grouped listing by `CommandGroup` (sorted by the `Ord` instance on `CommandGroup`, which derives `Enum`/`Bounded` order). It includes a hand-authored synthetic `help` entry at the top of the index because `/help` is not a registered spec.

---

- [ ] **Step 1: Create stub `src/Seal/Command/Help.hs`**

  `src/Seal/Command/Help.hs`:
  ```haskell
  {-# LANGUAGE OverloadedStrings #-}
  module Seal.Command.Help
    ( renderHelpIndex
    , renderHelpFor
    ) where

  import Data.Text (Text)

  import Seal.Command.Spec (CommandName, Registry)

  -- | Render the grouped \/help index, including a synthetic \"help\" entry.
  renderHelpIndex :: Registry -> Text
  renderHelpIndex = undefined

  -- | Render a specific command's full optparse help (via --help).
  -- Returns an error message if the command is not found.
  renderHelpFor :: Registry -> CommandName -> Text
  renderHelpFor = undefined
  ```

  In `seal-harness.cabal` library `exposed-modules`:
  ```
      Seal.Command.Help
  ```

  ```bash
  nix develop --command cabal build 2>&1 | tail -10
  ```
  Expected: clean build.

- [ ] **Step 2: Write `test/Seal/Command/HelpSpec.hs` — RED**

  This module defines its own throwaway sample registry (ping + --loud) so the
  discoverability test has real data and zero dependency on vault code.

  `test/Seal/Command/HelpSpec.hs`:
  ```haskell
  {-# LANGUAGE OverloadedStrings #-}
  module Seal.Command.HelpSpec (spec) where

  import Control.Monad (forM_)
  import Data.Text (Text)
  import Data.Text qualified as T
  import Test.Hspec
  import Options.Applicative

  import Seal.Channel.Caps (ChannelCaps(..))
  import Seal.Command.Spec
  import Seal.Command.Help

  -- ---------------------------------------------------------------------------
  -- Throwaway sample registry for Help tests.
  -- Defines a /ping command with --loud and a /vault stub so we exercise
  -- multi-group rendering. No vault or external dependencies.
  -- ---------------------------------------------------------------------------

  data PingOpts = PingOpts { poLoud :: Bool, poCount :: Int }

  pPingOpts :: Parser PingOpts
  pPingOpts = PingOpts
    <$> switch
          ( long "loud"
          <> short 'l'
          <> help "Shout the response in uppercase" )
    <*> option auto
          ( long "count"
          <> short 'n'
          <> metavar "N"
          <> value 1
          <> showDefault
          <> help "Number of pings to send" )

  pingSpec :: CommandSpec
  pingSpec = CommandSpec
    { csName         = CommandName "ping"
    , csAliases      = [CommandName "p"]
    , csGroup        = GroupGeneral
    , csSynopsis     = "Check connectivity"
    , csParserInfo   = info (fmap toPingAction pPingOpts)
                            (progDesc "Send a ping and receive a pong")
    , csAvailability = AlwaysAvailable
    }
    where
      toPingAction (PingOpts loud _n) = CommandAction $ \caps ->
        ccSend caps (if loud then "PONG!" else "pong")

  -- A minimal vault stub (no real vault; proves multi-group layout).
  vaultStubSpec :: CommandSpec
  vaultStubSpec = CommandSpec
    { csName         = CommandName "vault"
    , csAliases      = [CommandName "v"]
    , csGroup        = GroupVault
    , csSynopsis     = "Manage the encrypted secret vault"
    , csParserInfo   = info
        (subparser
          (command "status"
            (info (pure (CommandAction $ \caps -> ccSend caps "vault status"))
                  (progDesc "Show vault status"))))
        (progDesc "Encrypt and manage secrets")
    , csAvailability = AlwaysAvailable
    }

  testRegistry :: Registry
  testRegistry = mkRegistry [pingSpec, vaultStubSpec]

  -- ---------------------------------------------------------------------------
  -- Known long options per command in the test registry (for discoverability).
  -- This table is the ground truth: if you add a flag to a spec above, add it
  -- here too or the discoverability test will catch the omission.
  -- ---------------------------------------------------------------------------

  knownOptions :: [(CommandName, [Text])]
  knownOptions =
    [ (CommandName "ping",  ["--loud", "--count"])
    , (CommandName "vault", ["--help"])   -- minimal: only the auto-added --help
    ]

  -- ---------------------------------------------------------------------------

  spec :: Spec
  spec = describe "Seal.Command.Help" $ do

    -- -------------------------------------------------------------------------
    describe "renderHelpIndex" $ do

      it "contains the synthetic 'help' entry" $
        T.isInfixOf "help" (renderHelpIndex testRegistry) `shouldBe` True

      it "contains every registered command name" $ do
        let idx = renderHelpIndex testRegistry
        forM_ (registrySpecs testRegistry) $ \s ->
          let CommandName n = csName s
          in T.isInfixOf n idx `shouldBe` True

      it "contains the synopsis for each command" $ do
        let idx = renderHelpIndex testRegistry
        forM_ (registrySpecs testRegistry) $ \s ->
          T.isInfixOf (csSynopsis s) idx `shouldBe` True

      it "contains group headers for all groups represented" $ do
        let idx = renderHelpIndex testRegistry
        -- GroupGeneral and GroupVault are both in the test registry
        T.isInfixOf "General" idx `shouldBe` True
        T.isInfixOf "Vault"   idx `shouldBe` True

    -- -------------------------------------------------------------------------
    describe "renderHelpFor" $ do

      it "returns a non-empty string for a known command" $
        T.null (renderHelpFor testRegistry (CommandName "ping")) `shouldBe` False

      it "includes the progDesc in the per-command help" $
        T.isInfixOf "ping" (renderHelpFor testRegistry (CommandName "ping"))
          `shouldBe` True

      it "includes the progDesc text set on the ParserInfo" $
        T.isInfixOf "Send a ping" (renderHelpFor testRegistry (CommandName "ping"))
          `shouldBe` True

      it "returns an error message for an unknown command" $ do
        let h = renderHelpFor testRegistry (CommandName "nonexistent")
        T.null h `shouldBe` False

      it "/help vault == /vault --help (same text)" $ do
        let viaHelp  = renderHelpFor testRegistry (CommandName "vault")
            viaFlag  = renderHelpFor testRegistry (CommandName "vault")
        viaHelp `shouldBe` viaFlag

    -- -------------------------------------------------------------------------
    -- CENTERPIECE: Discoverability invariant.
    -- Every command name must surface in the help index.
    -- Every long option declared in knownOptions must surface in that
    -- command's per-command help. Build fails if anything is missing.
    -- -------------------------------------------------------------------------
    describe "discoverability invariant" $ do

      it "every command name appears in renderHelpIndex" $ do
        let idx = renderHelpIndex testRegistry
        forM_ (registrySpecs testRegistry) $ \s ->
          let CommandName n = csName s
          in T.isInfixOf n idx
               `shouldBe` True

      it "every known long option appears in renderHelpFor output" $
        forM_ knownOptions $ \(name, opts) -> do
          let h = renderHelpFor testRegistry name
          forM_ opts $ \opt ->
            T.isInfixOf opt h `shouldBe` True

      it "renderHelpFor ping contains --loud" $
        T.isInfixOf "--loud"
          (renderHelpFor testRegistry (CommandName "ping"))
            `shouldBe` True

      it "renderHelpFor ping contains --count" $
        T.isInfixOf "--count"
          (renderHelpFor testRegistry (CommandName "ping"))
            `shouldBe` True
  ```

  Register in `seal-harness.cabal` test-suite `other-modules`:
  ```
      Seal.Command.HelpSpec
  ```

  Add to `test/Main.hs`:
  ```haskell
  import qualified Seal.Command.HelpSpec
  -- …in hspec $ do:
  Seal.Command.HelpSpec.spec
  ```

  ```bash
  nix develop --command cabal test 2>&1 | tail -40
  ```
  Expected: **RED** — `undefined` in `renderHelpIndex`/`renderHelpFor` throws exceptions.

- [ ] **Step 3: Implement `src/Seal/Command/Help.hs` — GREEN**

  Replace `src/Seal/Command/Help.hs` with the full implementation:

  ```haskell
  {-# LANGUAGE OverloadedStrings #-}
  module Seal.Command.Help
    ( renderHelpIndex
    , renderHelpFor
    ) where

  import Data.List (sortBy)
  import Data.Map.Strict (Map)
  import Data.Map.Strict qualified as Map
  import Data.Ord (comparing)
  import Data.Text (Text)
  import Data.Text qualified as T
  import Options.Applicative
    ( ParserResult(..)
    , defaultPrefs
    , execParserPure
    , renderFailure
    )

  import Seal.Command.Spec
    ( CommandGroup(..)
    , CommandName(..)
    , CommandSpec(..)
    , Registry(..)
    , csGroup
    , csName
    , csParserInfo
    , csSynopsis
    , lookupSpec
    , registrySpecs
    )

  -- ---------------------------------------------------------------------------
  -- Help index
  -- ---------------------------------------------------------------------------

  -- | Render the grouped \/help index.
  --
  -- Output format:
  -- @
  -- Available commands:
  --
  --   /help [command]   Show this help, or detailed help for a command
  --
  -- General
  --   /ping             Check connectivity
  --
  -- Vault
  --   /vault            Manage the encrypted secret vault
  -- @
  --
  -- The synthetic @\/help@ entry is always present at the top even though
  -- @\/help@ is not a registered 'CommandSpec' (to avoid a registry-knot).
  renderHelpIndex :: Registry -> Text
  renderHelpIndex reg =
    T.unlines $
      [ "Available commands:"
      , ""
      , syntheticHelpLine
      , ""
      ]
      ++ concatMap renderGroup (Map.toAscList grouped)
    where
      specs   = registrySpecs reg
      -- Group specs preserving original insertion order within each group.
      grouped :: Map CommandGroup [CommandSpec]
      grouped =
        Map.fromListWith (flip (++))
          [(csGroup s, [s]) | s <- specs]

      syntheticHelpLine :: Text
      syntheticHelpLine =
        "  " <> T.justifyLeft colWidth ' ' "/help [command]"
             <> "Show this help, or detailed help for a command"

      renderGroup :: (CommandGroup, [CommandSpec]) -> [Text]
      renderGroup (grp, grpSpecs) =
        [ groupHeader grp ]
        ++ map renderSpec grpSpecs
        ++ [ "" ]

      groupHeader :: CommandGroup -> Text
      groupHeader GroupGeneral = "General"
      groupHeader GroupVault   = "Vault"

      renderSpec :: CommandSpec -> Text
      renderSpec s =
        let CommandName n = csName s
            label         = "/" <> n
        in "  " <> T.justifyLeft colWidth ' ' label <> csSynopsis s

      -- Column width for the command label column (includes the leading slash).
      colWidth :: Int
      colWidth = 18

  -- ---------------------------------------------------------------------------
  -- Per-command help
  -- ---------------------------------------------------------------------------

  -- | Render a specific command's full optparse help by running its
  -- 'ParserInfo' with @["--help"]@ via 'execParserPure'.
  --
  -- @execParserPure defaultPrefs info ["--help"]@ always returns
  -- @Failure (ParserFailure ParserHelp)@ because @--help@ is optparse's
  -- built-in action. 'renderFailure' converts that to @(String, ExitCode)@;
  -- we take the 'String', pack it to 'Text', and discard the exit code
  -- ('ExitSuccess' for @--help@).
  --
  -- This means the rendered text is 100% derived from the optparse parser
  -- and cannot drift from the actual flags the command accepts.
  renderHelpFor :: Registry -> CommandName -> Text
  renderHelpFor reg name@(CommandName n) =
    case lookupSpec reg name of
      Nothing   -> "No such command: " <> n <> "\n"
      Just spec ->
        case execParserPure defaultPrefs (csParserInfo spec) ["--help"] of
          Failure f ->
            -- progName argument to renderFailure is used as the program name
            -- in the rendered usage line; we use the slash-command name.
            let (msg, _exitCode) = renderFailure f ("/" <> T.unpack n)
            in T.pack msg
          -- The following two branches are unreachable when the input is
          -- ["--help"] against a well-formed ParserInfo, but we must be
          -- total to satisfy -Wall -Werror.
          Success _           -> ""
          CompletionInvoked _ -> ""
  ```

  ```bash
  nix develop --command cabal test 2>&1 | tail -40
  ```
  Expected: **GREEN** — all HelpSpec tests pass, and all previously-passing tests continue to pass.

- [ ] **Step 4: hlint + commit**

  ```bash
  nix develop --command hlint src/Seal/Command/Help.hs test/Seal/Command/HelpSpec.hs
  ```
  Expected: `No hints`.

  Full suite sanity check:
  ```bash
  nix develop --command cabal test 2>&1 | tail -40
  ```
  Expected: all tests GREEN, no warnings.

  ```bash
  git add src/Seal/Command/Help.hs test/Seal/Command/HelpSpec.hs \
          seal-harness.cabal test/Main.hs
  git commit -m "$(cat <<'EOF'
  Add Seal.Command.Help: grouped index and optparse-derived per-command help

  Discoverability property test asserts every command name and every declared
  long option surfaces in help output; build fails if any are missing.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---
<!-- End of Section D (Tasks 1–4) -->


---

### Task 5: Seal.Config.Paths — ~/.seal + SEAL_HOME resolution and directory bootstrap

> GitHub issue: #2

**Files:**
- Create `src/Seal/Config/Paths.hs`
- Test `test/Seal/Config/PathsSpec.hs`
- Modify `seal-harness.cabal` — add `Seal.Config.Paths` to library `exposed-modules:`; add `Seal.Config.PathsSpec` to test-suite `other-modules:`; add `unix` to test-suite `build-depends:`
- Modify `test/Main.hs` — add `import qualified Seal.Config.PathsSpec` and `Seal.Config.PathsSpec.spec` in the `hspec $ do` block

**Interfaces:**
- Consumes: nothing internal (leaf module — `base`, `directory`, `filepath`, `unix` only)
- Produces:
  ```haskell
  data SealPaths = SealPaths
    { spHome   :: FilePath   -- SEAL_HOME or ~/.seal
    , spConfig :: FilePath   -- <home>/config
    , spState  :: FilePath   -- <home>/state
    , spKeys   :: FilePath   -- <home>/keys
    } deriving stock (Eq, Show)

  resolveSealHome :: IO FilePath
  getSealPaths    :: IO SealPaths
  ensureSealDirs  :: SealPaths -> IO ()
  configFilePath  :: SealPaths -> FilePath
  vaultFilePath   :: SealPaths -> FilePath
  keyFilePath     :: SealPaths -> FilePath -> FilePath
  ```

---

- [ ] **Step 1: Write the failing spec `test/Seal/Config/PathsSpec.hs`**

  ```haskell
  module Seal.Config.PathsSpec (spec) where

  import Control.Exception (bracket)
  import System.Directory (doesDirectoryExist, getHomeDirectory)
  import System.Environment (lookupEnv, setEnv, unsetEnv)
  import System.FilePath ((</>))
  import System.IO.Temp (withSystemTempDirectory)
  import System.Posix.Files (fileMode, getFileStatus, intersectFileModes)
  import Test.Hspec

  import Seal.Config.Paths

  spec :: Spec
  spec = describe "Seal.Config.Paths" $ do

    describe "resolveSealHome" $ do
      it "returns SEAL_HOME when the env var is set" $
        withSystemTempDirectory "seal-home" $ \tmp ->
          withSealHomeEnv tmp $ do
            result <- resolveSealHome
            result `shouldBe` tmp

      it "returns ~/.seal when SEAL_HOME is not set" $
        withoutSealHome $ do
          result   <- resolveSealHome
          expected <- fmap (</> ".seal") getHomeDirectory
          result `shouldBe` expected

    describe "getSealPaths" $ do
      it "derives config, state, and keys sub-paths from home" $
        withSystemTempDirectory "seal-home" $ \tmp ->
          withSealHomeEnv tmp $ do
            paths <- getSealPaths
            spHome   paths `shouldBe` tmp
            spConfig paths `shouldBe` tmp </> "config"
            spState  paths `shouldBe` tmp </> "state"
            spKeys   paths `shouldBe` tmp </> "keys"

    describe "ensureSealDirs" $ do
      it "creates config and state directories" $
        withSystemTempDirectory "seal-home" $ \tmp ->
          withSealHomeEnv tmp $ do
            paths <- getSealPaths
            ensureSealDirs paths
            doesDirectoryExist (spConfig paths) `shouldReturn` True
            doesDirectoryExist (spState  paths) `shouldReturn` True

      it "creates keys/ with mode 0700" $
        withSystemTempDirectory "seal-home" $ \tmp ->
          withSealHomeEnv tmp $ do
            paths <- getSealPaths
            ensureSealDirs paths
            st <- getFileStatus (spKeys paths)
            let mode = fileMode st `intersectFileModes` 0o777
            mode `shouldBe` 0o700

      it "is idempotent (calling twice does not throw)" $
        withSystemTempDirectory "seal-home" $ \tmp ->
          withSealHomeEnv tmp $ do
            paths <- getSealPaths
            ensureSealDirs paths
            ensureSealDirs paths
            doesDirectoryExist (spKeys paths) `shouldReturn` True

    describe "path helpers" $ do
      it "configFilePath returns config/config.toml" $
        withSystemTempDirectory "seal-home" $ \tmp ->
          withSealHomeEnv tmp $ do
            paths <- getSealPaths
            configFilePath paths `shouldBe` tmp </> "config" </> "config.toml"

      it "vaultFilePath returns config/vault/vault.age" $
        withSystemTempDirectory "seal-home" $ \tmp ->
          withSealHomeEnv tmp $ do
            paths <- getSealPaths
            vaultFilePath paths `shouldBe` tmp </> "config" </> "vault" </> "vault.age"

      it "keyFilePath appends name under keys/" $
        withSystemTempDirectory "seal-home" $ \tmp ->
          withSealHomeEnv tmp $ do
            paths <- getSealPaths
            keyFilePath paths "mykey.identity" `shouldBe` tmp </> "keys" </> "mykey.identity"

  -- | Run an action with SEAL_HOME set to the given path, restoring the
  -- previous value (or unsetting) on exit, even if the action throws.
  withSealHomeEnv :: FilePath -> IO a -> IO a
  withSealHomeEnv home act =
    bracket
      (do prev <- lookupEnv "SEAL_HOME"
          setEnv "SEAL_HOME" home
          pure prev)
      (\prev -> case prev of
          Nothing -> unsetEnv "SEAL_HOME"
          Just v  -> setEnv "SEAL_HOME" v)
      (const act)

  -- | Run an action with SEAL_HOME unset, restoring any previous value on exit.
  withoutSealHome :: IO a -> IO a
  withoutSealHome act =
    bracket
      (do prev <- lookupEnv "SEAL_HOME"
          maybe (pure ()) (const (unsetEnv "SEAL_HOME")) prev
          pure prev)
      (\prev -> case prev of
          Nothing -> pure ()
          Just v  -> setEnv "SEAL_HOME" v)
      (const act)
  ```

---

- [ ] **Step 2: Register in cabal and Main.hs; create a type-correct stub**

  **`seal-harness.cabal`** — in the `library` stanza, add after `Seal.Security.Command`:
  ```
      Seal.Config.Paths
  ```
  In the `test-suite tests` stanza, add to `other-modules:` after `Seal.Security.CommandSpec`:
  ```
      Seal.Config.PathsSpec
  ```
  And add to `build-depends:`:
  ```
      , unix
  ```

  **`test/Main.hs`** — add the import and runner:
  ```haskell
  module Main (main) where

  import Test.Hspec

  import qualified Seal.ConfigSpec
  import qualified Seal.Config.PathsSpec
  import qualified Seal.Security.CryptoSpec
  import qualified Seal.Security.PathSpec
  import qualified Seal.Security.SecretsSpec
  import qualified Seal.Security.Vault.AgeSpec
  import qualified Seal.Security.VaultSpec
  import qualified Seal.Security.PolicySpec
  import qualified Seal.Security.CommandSpec

  main :: IO ()
  main = hspec $ do
    Seal.ConfigSpec.spec
    Seal.Config.PathsSpec.spec
    Seal.Security.CryptoSpec.spec
    Seal.Security.PathSpec.spec
    Seal.Security.SecretsSpec.spec
    Seal.Security.Vault.AgeSpec.spec
    Seal.Security.VaultSpec.spec
    Seal.Security.PolicySpec.spec
    Seal.Security.CommandSpec.spec
  ```

  **`src/Seal/Config/Paths.hs`** — stub (types correct, bodies fail at runtime):
  ```haskell
  module Seal.Config.Paths
    ( SealPaths (..)
    , resolveSealHome
    , getSealPaths
    , ensureSealDirs
    , configFilePath
    , vaultFilePath
    , keyFilePath
    ) where

  data SealPaths = SealPaths
    { spHome   :: FilePath
    , spConfig :: FilePath
    , spState  :: FilePath
    , spKeys   :: FilePath
    } deriving stock (Eq, Show)

  resolveSealHome :: IO FilePath
  resolveSealHome = error "not implemented"

  getSealPaths :: IO SealPaths
  getSealPaths = error "not implemented"

  ensureSealDirs :: SealPaths -> IO ()
  ensureSealDirs _ = error "not implemented"

  configFilePath :: SealPaths -> FilePath
  configFilePath _ = error "not implemented"

  vaultFilePath :: SealPaths -> FilePath
  vaultFilePath _ = error "not implemented"

  keyFilePath :: SealPaths -> FilePath -> FilePath
  keyFilePath _ _ = error "not implemented"
  ```

---

- [ ] **Step 3: Run — expect RED**

  ```
  nix develop --command cabal test 2>&1 | tail -40
  ```

  Expected (all 9 Task-5 cases fail; existing specs continue to pass):
  ```
  Seal.Config.Paths
    resolveSealHome
      returns SEAL_HOME when the env var is set FAILED [1]
      returns ~/.seal when SEAL_HOME is not set FAILED [2]
    getSealPaths
      derives config, state, and keys sub-paths from home FAILED [3]
    ensureSealDirs
      creates config and state directories FAILED [4]
      creates keys/ with mode 0700 FAILED [5]
      is idempotent (calling twice does not throw) FAILED [6]
    path helpers
      configFilePath returns config/config.toml FAILED [7]
      vaultFilePath returns config/vault/vault.age FAILED [8]
      keyFilePath appends name under keys/ FAILED [9]

  Failures:

    test/Seal/Config/PathsSpec.hs:27:7:
    1) Seal.Config.Paths.resolveSealHome returns SEAL_HOME when the env var is set
         uncaught exception: ErrorCall
         not implemented

  ...

  9 examples, 9 failures
  ```

---

- [ ] **Step 4: Implement `src/Seal/Config/Paths.hs` fully**

  Replace the stub with the complete implementation:

  ```haskell
  module Seal.Config.Paths
    ( SealPaths (..)
    , resolveSealHome
    , getSealPaths
    , ensureSealDirs
    , configFilePath
    , vaultFilePath
    , keyFilePath
    ) where

  import System.Directory (createDirectoryIfMissing, getHomeDirectory)
  import System.Environment (lookupEnv)
  import System.FilePath ((</>))
  import System.Posix.Files (setFileMode)

  -- | All paths derived from the seal home directory.
  --
  -- * 'spConfig' — version-controllable config tree; ordinary directory
  -- * 'spState'  — mutable runtime state; ordinary directory
  -- * 'spKeys'   — key material; created mode 0700, never version-controlled
  data SealPaths = SealPaths
    { spHome   :: FilePath   -- ^ @SEAL_HOME@ env var or @~\/.seal@
    , spConfig :: FilePath   -- ^ @\<home\>\/config@
    , spState  :: FilePath   -- ^ @\<home\>\/state@
    , spKeys   :: FilePath   -- ^ @\<home\>\/keys@
    } deriving stock (Eq, Show)

  -- | Resolve the seal home directory.
  --
  -- Returns the value of @SEAL_HOME@ when the variable is set; otherwise
  -- returns @~\/.seal@ via 'getHomeDirectory'.
  resolveSealHome :: IO FilePath
  resolveSealHome = do
    mEnv <- lookupEnv "SEAL_HOME"
    case mEnv of
      Just h  -> pure h
      Nothing -> do
        home <- getHomeDirectory
        pure (home </> ".seal")

  -- | Compute all sub-paths under the seal home directory without touching
  -- the filesystem.
  getSealPaths :: IO SealPaths
  getSealPaths = do
    home <- resolveSealHome
    pure SealPaths
      { spHome   = home
      , spConfig = home </> "config"
      , spState  = home </> "state"
      , spKeys   = home </> "keys"
      }

  -- | Create the seal directory tree, setting restrictive permissions on the
  -- keys directory.
  --
  -- * @config\/@ and @state\/@ are created with default (umask-governed) mode.
  -- * @keys\/@ is created and then explicitly set to mode @0700@.
  --
  -- Calling this function when the directories already exist is safe
  -- ('createDirectoryIfMissing' is idempotent; 'setFileMode' is idempotent).
  ensureSealDirs :: SealPaths -> IO ()
  ensureSealDirs paths = do
    createDirectoryIfMissing True (spConfig paths)
    createDirectoryIfMissing True (spState  paths)
    createDirectoryIfMissing True (spKeys   paths)
    setFileMode (spKeys paths) 0o700

  -- | Absolute path to the TOML config file: @\<config\>\/config.toml@.
  configFilePath :: SealPaths -> FilePath
  configFilePath paths = spConfig paths </> "config.toml"

  -- | Absolute path to the encrypted vault file:
  -- @\<config\>\/vault\/vault.age@.
  vaultFilePath :: SealPaths -> FilePath
  vaultFilePath paths = spConfig paths </> "vault" </> "vault.age"

  -- | Absolute path to a named key file under @\<keys\>\/@.
  keyFilePath :: SealPaths -> FilePath -> FilePath
  keyFilePath paths name = spKeys paths </> name
  ```

---

- [ ] **Step 5: Run — expect GREEN**

  ```
  nix develop --command cabal test 2>&1 | tail -40
  ```

  Expected:
  ```
  Seal.Config.Paths
    resolveSealHome
      returns SEAL_HOME when the env var is set
      returns ~/.seal when SEAL_HOME is not set
    getSealPaths
      derives config, state, and keys sub-paths from home
    ensureSealDirs
      creates config and state directories
      creates keys/ with mode 0700
      is idempotent (calling twice does not throw)
    path helpers
      configFilePath returns config/config.toml
      vaultFilePath returns config/vault/vault.age
      keyFilePath appends name under keys/

  Finished in 0.XXs
  9 examples, 0 failures
  ```

  All pre-existing specs continue to pass.

---

- [ ] **Step 6: Run hlint**

  ```
  nix develop --command hlint src/ test/
  ```

  Expected: `No hints` (no output).

---

- [ ] **Step 7: Commit**

  ```
  git add src/Seal/Config/Paths.hs \
          test/Seal/Config/PathsSpec.hs \
          seal-harness.cabal \
          test/Main.hs
  git commit -m "$(cat <<'EOF'
  Add Seal.Config.Paths (~/.seal + SEAL_HOME resolution and directory bootstrap)

  Implements SealPaths record, resolveSealHome (SEAL_HOME override → ~/.seal
  default), getSealPaths, ensureSealDirs (config/ state/ ordinary; keys/ 0700),
  and the configFilePath / vaultFilePath / keyFilePath path helpers.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```


---

### Task 6: Seal.Security.Path — KeysRoot + mkSafeKeyPath (key-material confinement)

> GitHub issue: #3

**Files:**
- Modify `src/Seal/Security/Path.hs` — extend the export list; add `PathInsecureMode` to `PathError`; extend `System.Directory` import; add `System.Posix.Files` and `System.Posix.User` imports; append `KeysRoot`, `ensureKeysRoot`, `SafeKeyPath`, `getSafeKeyPath`, `mkSafeKeyPath`. Do **not** rewrite the existing code.
- Modify `test/Seal/Security/PathSpec.hs` — add `System.Posix.Files` import; add a nested `describe "KeysRoot and mkSafeKeyPath"` block inside the existing `describe "Seal.Security.Path"` block; add `isInsecureMode`/`isIM` predicates to the existing `where` clause.
- `seal-harness.cabal` — **no changes**: `unix` (which owns `System.Posix.Files` and `System.Posix.User`) is already a dependency; `temporary` and `hspec` are already test deps.

**Interfaces:**
- Consumes: the existing `lexicalCollapse`, `canonicalizePath`, `splitDirectories`, `isPrefixOf`, `joinPath`, `isAbsolute`, `try`, `IOException` already in `Seal.Security.Path` — call them directly from the new functions without re-importing.
- Produces (exact contract signatures):
  ```haskell
  -- PathError gains:
  --   | PathInsecureMode FilePath
  newtype KeysRoot = KeysRoot FilePath          deriving stock (Eq, Show)
  ensureKeysRoot  :: FilePath -> IO KeysRoot    -- mkdir -p + chmod 0700
  newtype SafeKeyPath                            -- constructor UNEXPORTED; custom Show
  getSafeKeyPath  :: SafeKeyPath -> FilePath
  mkSafeKeyPath   :: KeysRoot -> FilePath -> IO (Either PathError SafeKeyPath)
  ```

---

- [ ] **Step 1 — Write failing tests (RED)**

  In `test/Seal/Security/PathSpec.hs`, add one new import line and one `describe` block, and extend the `where` clause. Shown as exact diffs.

  **Add after the existing `import System.IO.Temp` line:**
  ```haskell
  import System.Posix.Files (fileMode, getFileStatus, intersectFileModes, setFileMode)
  ```

  **Inside the top-level `describe "Seal.Security.Path" $ do` block, immediately before the `where` keyword, add:**
  ```haskell
    describe "KeysRoot and mkSafeKeyPath" $ do

      it "ensureKeysRoot creates the directory with mode 0700" $
        withSystemTempDirectory "seal-keys" $ \tmp -> do
          let keysDir = tmp </> "keys"
          kr <- ensureKeysRoot keysDir
          status <- getFileStatus keysDir
          (fileMode status `intersectFileModes` 0o777) `shouldBe` 0o700
          kr `shouldBe` KeysRoot keysDir

      it "accepts a not-yet-existing path under the root" $
        withSystemTempDirectory "seal-keys" $ \root -> do
          kr <- ensureKeysRoot root
          r  <- mkSafeKeyPath kr "future.identity"
          r `shouldSatisfy` isOk

      it "accepts an existing file with mode 0600" $
        withSystemTempDirectory "seal-keys" $ \root -> do
          kr <- ensureKeysRoot root
          let target = root </> "key.identity"
          BS.writeFile target "key-material"
          setFileMode target 0o600
          r <- mkSafeKeyPath kr "key.identity"
          r `shouldSatisfy` isOk

      it "accepts an existing file with mode 0400" $
        withSystemTempDirectory "seal-keys" $ \root -> do
          kr <- ensureKeysRoot root
          let target = root </> "ro.identity"
          BS.writeFile target "key-material"
          setFileMode target 0o400
          r <- mkSafeKeyPath kr "ro.identity"
          r `shouldSatisfy` isOk

      it "rejects an existing file with mode 0644 (PathInsecureMode)" $
        withSystemTempDirectory "seal-keys" $ \root -> do
          kr <- ensureKeysRoot root
          let target = root </> "loose.identity"
          BS.writeFile target "key-material"
          setFileMode target 0o644
          r <- mkSafeKeyPath kr "loose.identity"
          r `shouldSatisfy` isInsecureMode

      it "rejects a .. escape attempt" $
        withSystemTempDirectory "seal-keys" $ \root -> do
          kr <- ensureKeysRoot root
          r  <- mkSafeKeyPath kr "../escape"
          r `shouldSatisfy` isEscape

      it "rejects an absolute path outside the root" $
        withSystemTempDirectory "seal-keys" $ \root -> do
          kr <- ensureKeysRoot root
          r  <- mkSafeKeyPath kr "/etc/passwd"
          r `shouldSatisfy` isEscape

      it "rejects a symlink that resolves outside the root" $
        withSystemTempDirectory "seal-keys" $ \root ->
          withSystemTempDirectory "seal-outside" $ \outside -> do
            let outsideTarget = outside </> "secret.key"
            BS.writeFile outsideTarget "top-secret"
            createFileLink outsideTarget (root </> "evil-link")
            kr <- ensureKeysRoot root
            r  <- mkSafeKeyPath kr "evil-link"
            r `shouldSatisfy` isEscape

      it "getSafeKeyPath returns a path under the root" $
        withSystemTempDirectory "seal-keys" $ \root -> do
          kr <- ensureKeysRoot root
          r  <- mkSafeKeyPath kr "future.identity"
          case r of
            Left e  -> expectationFailure ("expected Right, got: " <> show e)
            Right p -> getSafeKeyPath p `shouldContain` "future.identity"

      it "show SafeKeyPath does not reveal the path" $
        withSystemTempDirectory "seal-keys" $ \root -> do
          kr <- ensureKeysRoot root
          let target = root </> "secret.identity"
          BS.writeFile target "key"
          setFileMode target 0o600
          r <- mkSafeKeyPath kr "secret.identity"
          case r of
            Left e  -> expectationFailure ("expected Right, got: " <> show e)
            Right p -> show p `shouldNotContain` "secret.identity"
  ```

  **In the existing `where` clause, append two new helpers (after `isMiss`):**
  ```haskell
      isInsecureMode = either isIM (const False)
      isIM (PathInsecureMode _) = True
      isIM _                    = False
  ```

- [ ] **Step 2 — Run: expect RED**

  ```
  nix develop --command cabal test 2>&1 | tail -40
  ```

  Expected output contains GHC errors like:
  ```
  error: Variable not in scope: ensureKeysRoot :: FilePath -> IO KeysRoot
  error: Variable not in scope: mkSafeKeyPath
  error: Variable not in scope: KeysRoot
  error: Variable not in scope: getSafeKeyPath
  error: Data constructor not in scope: PathInsecureMode
  ```
  (The test suite does not compile — that is the expected RED state.)

- [ ] **Step 3 — Implement in `src/Seal/Security/Path.hs`**

  **3a. Replace the module header** (export-list additions only — new lines marked with `+`):
  ```haskell
  module Seal.Security.Path
    ( SafePath
    , getSafePath
    , WorkspaceRoot (..)
    , PathError (..)
    , mkSafePath
    , KeysRoot (..)        -- +
    , ensureKeysRoot       -- +
    , SafeKeyPath          -- + (constructor NOT exported)
    , getSafeKeyPath       -- +
    , mkSafeKeyPath        -- +
    ) where
  ```

  **3b. Extend the `System.Directory` import** (add `createDirectoryIfMissing`):
  ```haskell
  import System.Directory (canonicalizePath, createDirectoryIfMissing, doesPathExist)
  ```

  **3c. Add two new imports** (keep alphabetical order, after `System.FilePath`):
  ```haskell
  import System.Posix.Files
    ( fileMode
    , fileOwner
    , getFileStatus
    , intersectFileModes
    , setFileMode
    )
  import System.Posix.User (getEffectiveUserID)
  ```

  **3d. Add `PathInsecureMode` to the existing `PathError` ADT:**
  ```haskell
  data PathError
    = PathEscapesWorkspace FilePath
    | PathIsBlocked Text
    | PathDoesNotExist FilePath
    | PathInsecureMode FilePath
    deriving stock (Eq, Show)
  ```

  **3e. Append the new types and functions after `mkSafePath`:**
  ```haskell
  -- ---------------------------------------------------------------------------
  -- Key-material confinement
  -- ---------------------------------------------------------------------------

  newtype KeysRoot = KeysRoot FilePath
    deriving stock (Eq, Show)

  -- | Create (mkdir -p) and harden (chmod 0700) a keys directory, returning a
  -- typed 'KeysRoot'. Idempotent — safe to call on an already-existing directory.
  ensureKeysRoot :: FilePath -> IO KeysRoot
  ensureKeysRoot dir = do
    createDirectoryIfMissing True dir
    setFileMode dir 0o700
    pure (KeysRoot dir)

  -- | An absolute path that has been verified to be safely confined within a
  -- 'KeysRoot' directory (no @..@ escape, no symlink escape, and — if the file
  -- already exists — owned by the effective user with mode 0600 or 0400). The
  -- constructor is intentionally not exported; obtain a value via 'mkSafeKeyPath'.
  newtype SafeKeyPath = SafeKeyPath FilePath

  -- | The 'Show' instance deliberately omits the path to prevent accidental
  -- disclosure in logs or error messages.
  instance Show SafeKeyPath where
    show _ = "SafeKeyPath <redacted>"

  getSafeKeyPath :: SafeKeyPath -> FilePath
  getSafeKeyPath (SafeKeyPath p) = p

  -- | Validate that a requested path is safely confined within the 'KeysRoot'.
  --
  -- Steps (in order):
  --   1. Lexically collapse @..@\/@.@ and check containment under the root —
  --      identical to 'mkSafePath' (reuses 'lexicalCollapse' + component-wise
  --      @splitDirectories@ prefix check).
  --   2. Canonicalize (follows symlinks); re-run the containment check to catch
  --      symlink escapes.
  --   3. If the target does not yet exist (key to be written later): return
  --      @Right@ with the lexically-resolved path.
  --   4. If the target exists: require @fileOwner == getEffectiveUserID@ and
  --      @fileMode & 0o777 ∈ {0o600, 0o400}@; otherwise return
  --      @Left (PathInsecureMode path)@.
  mkSafeKeyPath :: KeysRoot -> FilePath -> IO (Either PathError SafeKeyPath)
  mkSafeKeyPath (KeysRoot root) requested = do
    canonRoot <- canonicalizePath root
    let joined     = if isAbsolute requested then requested else canonRoot </> requested
        rootDirs   = splitDirectories canonRoot
        lexicalDirs = lexicalCollapse (splitDirectories joined)
    if not (rootDirs `isPrefixOf` lexicalDirs)
      then pure $ Left $ PathEscapesWorkspace (joinPath lexicalDirs)
      else do
        canonResult <- try (canonicalizePath joined) :: IO (Either IOException FilePath)
        case canonResult of
          Left _ ->
            -- Path does not exist yet — allowed; the caller will create it.
            pure $ Right $ SafeKeyPath (joinPath lexicalDirs)
          Right canon ->
            if not (rootDirs `isPrefixOf` splitDirectories canon)
              then pure $ Left $ PathEscapesWorkspace canon
              else checkSecurity canon
    where
      checkSecurity canon = do
        status <- getFileStatus canon
        euid   <- getEffectiveUserID
        let owner = fileOwner status
            mode  = fileMode status `intersectFileModes` 0o777
        if owner /= euid
          then pure $ Left $ PathInsecureMode canon
          else if mode `notElem` [0o600, 0o400]
            then pure $ Left $ PathInsecureMode canon
            else pure $ Right $ SafeKeyPath canon
  ```

- [ ] **Step 4 — Run: expect GREEN**

  ```
  nix develop --command cabal test 2>&1 | tail -40
  ```

  Expected output (all suites, abridged):
  ```
  Seal.Security.Path
    accepts a file inside the workspace
    ...
    KeysRoot and mkSafeKeyPath
      ensureKeysRoot creates the directory with mode 0700
      accepts a not-yet-existing path under the root
      accepts an existing file with mode 0600
      accepts an existing file with mode 0400
      rejects an existing file with mode 0644 (PathInsecureMode)
      rejects a .. escape attempt
      rejects an absolute path outside the root
      rejects a symlink that resolves outside the root
      getSafeKeyPath returns a path under the root
      show SafeKeyPath does not reveal the path

  Finished in ... seconds
  All N tests passed.
  ```

- [ ] **Step 5 — hlint**

  ```
  nix develop --command hlint src/ test/
  ```

  Expected: `No hints`.

- [ ] **Step 6 — Commit**

  ```
  git add src/Seal/Security/Path.hs test/Seal/Security/PathSpec.hs
  git commit -m "$(cat <<'EOF'
  Add KeysRoot + mkSafeKeyPath key confinement

  Extends Seal.Security.Path with a typed KeysRoot directory (created
  at 0700), a SafeKeyPath whose constructor is unexported and whose Show
  instance is redacted, and mkSafeKeyPath which reuses the existing
  lexical-collapse + canonical component-wise containment primitive and
  adds an owner/mode check (0600 or 0400) for files that already exist.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```


---

### Task 7: Seal.Config.File — config.toml load/update

> GitHub issue: #4

**Files:**
- Create `src/Seal/Config/File.hs`
- Create `test/Seal/Config/FileSpec.hs`
- Modify `seal-harness.cabal`: add `Seal.Config.File` to library `exposed-modules:`; add `Seal.Config.FileSpec` to test-suite `other-modules:`; ensure `tomland >= 1.3 && < 2` is in library `build-depends:` (Task 0 canonically owns this addition — if Task 0 is already merged, verify the dep is present; otherwise add it in this task).
- Modify `test/Main.hs`: import `Seal.Config.FileSpec` and call its `spec` inside the `hspec $ do` block.

**Interfaces:**
- Consumes: `Seal.Config.Paths` (in production, the config file path comes from `configFilePath sealPaths`; tests pass explicit temp-directory paths and never call `getSealPaths`).
- Produces: the contract's `FileConfig` API (`FileConfig`, `defaultFileConfig`, `loadFileConfig`, `saveFileConfig`, `updateFileConfig`) consumed by `Seal.Vault.Backend` (Task 8) and `Seal.Repl` (Task 11).

---

#### Step 1: Write failing tests (RED)

Create `test/Seal/Config/FileSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Seal.Config.FileSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

import Test.Hspec

import Seal.Config.File

spec :: Spec
spec = describe "Seal.Config.File" $ do

  describe "defaultFileConfig" $ do
    it "has all Nothing fields" $
      defaultFileConfig `shouldBe` FileConfig
        { fcVaultPath      = Nothing
        , fcVaultRecipient = Nothing
        , fcVaultIdentity  = Nothing
        , fcVaultUnlock    = Nothing
        , fcVaultKeyType   = Nothing
        }

  describe "loadFileConfig" $ do
    it "returns defaultFileConfig when the file is absent" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        result <- loadFileConfig path
        result `shouldBe` Right defaultFileConfig

    it "parses a valid TOML file with a subset of fields" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path $ T.unlines
          [ "vault_path = \"/home/user/.seal/config/vault/vault.age\""
          , "vault_recipient = \"age1abc123\""
          , "vault_key_type = \"x25519\""
          ]
        result <- loadFileConfig path
        case result of
          Left err -> expectationFailure ("parse failed: " <> T.unpack err)
          Right cfg -> do
            fcVaultPath      cfg `shouldBe` Just "/home/user/.seal/config/vault/vault.age"
            fcVaultRecipient cfg `shouldBe` Just "age1abc123"
            fcVaultIdentity  cfg `shouldBe` Nothing
            fcVaultUnlock    cfg `shouldBe` Nothing
            fcVaultKeyType   cfg `shouldBe` Just "x25519"

    it "returns Left on malformed TOML" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "vault_path = [not valid toml"
        result <- loadFileConfig path
        case result of
          Left _  -> pure ()
          Right _ -> expectationFailure "expected Left for malformed TOML but got Right"

  describe "saveFileConfig / loadFileConfig round-trip" $ do
    it "round-trips a fully-populated FileConfig" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        let cfg = FileConfig
              { fcVaultPath      = Just "/tmp/vault.age"
              , fcVaultRecipient = Just "age1abc"
              , fcVaultIdentity  = Just "/home/user/.seal/keys/default.identity"
              , fcVaultUnlock    = Just "on_demand"
              , fcVaultKeyType   = Just "x25519"
              }
        saveFileConfig path cfg
        result <- loadFileConfig path
        result `shouldBe` Right cfg

    it "round-trips defaultFileConfig (all Nothing)" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        saveFileConfig path defaultFileConfig
        result <- loadFileConfig path
        result `shouldBe` Right defaultFileConfig

    it "leaves no leftover .tmp file after save" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        saveFileConfig path defaultFileConfig
        leftover <- doesFileExist (path <> ".tmp")
        leftover `shouldBe` False

  describe "updateFileConfig" $ do
    it "patches one field and preserves all others" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        let initial = defaultFileConfig
              { fcVaultPath    = Just "/old/vault.age"
              , fcVaultKeyType = Just "x25519"
              }
        saveFileConfig path initial
        result <- updateFileConfig path (\c -> c { fcVaultRecipient = Just "age1new" })
        result `shouldBe` Right ()
        loaded <- loadFileConfig path
        case loaded of
          Left err -> expectationFailure ("reload failed: " <> T.unpack err)
          Right cfg -> do
            fcVaultPath      cfg `shouldBe` Just "/old/vault.age"
            fcVaultKeyType   cfg `shouldBe` Just "x25519"
            fcVaultRecipient cfg `shouldBe` Just "age1new"
            fcVaultIdentity  cfg `shouldBe` Nothing
            fcVaultUnlock    cfg `shouldBe` Nothing

    it "returns Left when the config file is malformed" $
      withSystemTempDirectory "seal-config-test" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path "not = [valid"
        result <- updateFileConfig path id
        case result of
          Left _  -> pure ()
          Right _ -> expectationFailure "expected Left for malformed config"
```

Wire up the spec. Add to `test/Main.hs` (after existing imports and inside the `hspec $ do` block):

```haskell
import qualified Seal.Config.FileSpec
-- ...
  Seal.Config.FileSpec.spec
```

Add to `seal-harness.cabal` test-suite `other-modules:`:

```
Seal.Config.FileSpec
```

Run to confirm RED:

```
nix develop --command cabal test 2>&1 | tail -40
```

Expected: build failure — module `Seal.Config.File` does not yet exist. Confirms RED.

---

#### Step 2: Implement `src/Seal/Config/File.hs` (GREEN)

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | Load and save @config\/config.toml@. Absent file decodes as
-- 'defaultFileConfig'. Writes are atomic (write @.tmp@, rename). All vault
-- config fields are optional — a missing TOML key decodes as 'Nothing' and
-- a 'Nothing' value is omitted from the encoded output.
module Seal.Config.File
  ( FileConfig (..)
  , defaultFileConfig
  , loadFileConfig
  , saveFileConfig
  , updateFileConfig
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist, renameFile)

import Toml ((.=))
import Toml qualified as Toml

-- | All user-editable vault settings persisted in @config\/config.toml@.
-- Every field is optional; a missing key decodes as 'Nothing'.
data FileConfig = FileConfig
  { fcVaultPath      :: Maybe Text
    -- ^ Absolute path to the vault file (default: @~\/.seal\/config\/vault\/vault.age@).
  , fcVaultRecipient :: Maybe Text
    -- ^ age public key: @age1…@ or @age1yubikey1…@.
  , fcVaultIdentity  :: Maybe Text
    -- ^ Path to the identity file under @keys\/@, or a user-supplied path.
  , fcVaultUnlock    :: Maybe Text
    -- ^ @\"startup\"@ | @\"on_demand\"@ | @\"per_access\"@.
  , fcVaultKeyType   :: Maybe Text
    -- ^ Display label: @\"x25519\"@ | @\"yubikey\"@ | @\"user\"@.
  } deriving stock (Eq, Show)

-- | Starting state: all fields absent, before @\/vault setup@ is run.
defaultFileConfig :: FileConfig
defaultFileConfig = FileConfig
  { fcVaultPath      = Nothing
  , fcVaultRecipient = Nothing
  , fcVaultIdentity  = Nothing
  , fcVaultUnlock    = Nothing
  , fcVaultKeyType   = Nothing
  }

-- ---------------------------------------------------------------------------
-- Codec
-- ---------------------------------------------------------------------------

-- | Bidirectional tomland codec for 'FileConfig'.
-- 'Toml.dioptional' wraps each key: absent → 'Nothing' on decode,
-- 'Nothing' → key omitted on encode.
fileConfigCodec :: Toml.TomlCodec FileConfig
fileConfigCodec = FileConfig
  <$> Toml.dioptional (Toml.text "vault_path")      .= fcVaultPath
  <*> Toml.dioptional (Toml.text "vault_recipient")  .= fcVaultRecipient
  <*> Toml.dioptional (Toml.text "vault_identity")   .= fcVaultIdentity
  <*> Toml.dioptional (Toml.text "vault_unlock")     .= fcVaultUnlock
  <*> Toml.dioptional (Toml.text "vault_key_type")   .= fcVaultKeyType

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- | Load the config file at @path@.
--
-- * File absent  → @Right 'defaultFileConfig'@
-- * Parse error  → @Left@ with the rendered tomland diagnostics
loadFileConfig :: FilePath -> IO (Either Text FileConfig)
loadFileConfig path = do
  exists <- doesFileExist path
  if not exists
    then pure (Right defaultFileConfig)
    else do
      contents <- TIO.readFile path
      pure $ case Toml.decode fileConfigCodec contents of
        Right cfg -> Right cfg
        Left errs -> Left (renderErrors errs)
  where
    -- 'TomlDecodeError' has a 'Show' instance; join multiple errors with
    -- newlines. If the pinned tomland version exports
    -- 'Toml.prettyTomlDecodeErrors', prefer that over 'show'.
    renderErrors errs =
      T.intercalate "\n" (map (T.pack . show) errs)

-- | Save @cfg@ to @path@ atomically: write @path.tmp@, rename over @path@.
-- The file is not chmod-restricted (config.toml is not secret material;
-- unlike vault.age which is handled by Phase 1's atomic write with 0600).
saveFileConfig :: FilePath -> FileConfig -> IO ()
saveFileConfig path cfg = do
  let encoded = Toml.encode fileConfigCodec cfg
      tmp     = path <> ".tmp"
  TIO.writeFile tmp encoded
  renameFile tmp path

-- | Load the config at @path@, apply @f@, save. Propagates any load
-- error as @Left Text@ without writing.
updateFileConfig :: FilePath -> (FileConfig -> FileConfig) -> IO (Either Text ())
updateFileConfig path f = do
  result <- loadFileConfig path
  case result of
    Left err  -> pure (Left err)
    Right cfg -> saveFileConfig path (f cfg) >> pure (Right ())
```

Add `Seal.Config.File` to library `exposed-modules:` in `seal-harness.cabal`.

Add `tomland >= 1.3 && < 2` to library `build-depends:` (cross-reference Task 0 — Task 0 canonically adds this dep; add it here only if Task 0 has not yet been applied).

Run:

```
nix develop --command cabal test 2>&1 | tail -40
```

Expected: all `Seal.Config.FileSpec` examples pass. GREEN.

---

#### Step 3: hlint

```
nix develop --command hlint src/Seal/Config/File.hs test/Seal/Config/FileSpec.hs
```

Expected: `No hints`. Fix any warnings before the commit step.

---

#### Step 4: Commit

```
git add src/Seal/Config/File.hs \
        test/Seal/Config/FileSpec.hs \
        seal-harness.cabal \
        test/Main.hs
git commit -m "$(cat <<'EOF'
Add Seal.Config.File (config.toml load/update)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```


---

### Task 8: `Seal.Vault.Backend`

> Depends on Tasks 1 (Seal.Channel.Caps), 5 (Seal.Config.Paths), 6 (Seal.Security.Path
> KeysRoot extension), 7 (Seal.Config.File), and Phase 1 `Seal.Security.Vault.Age` /
> `Seal.Security.Vault`. No single issue; depends on #1–#4 (infra) + Phase 1.

**Files:**
- Create `src/Seal/Vault/Backend.hs`
- Create `test/Seal/Vault/BackendSpec.hs`
- Create `test/Seal/TestHelpers/FakeCaps.hs` ← shared helper, also used by Task 9
- Modify `seal-harness.cabal` (library `exposed-modules`; test-suite `other-modules`)
- Modify `test/Main.hs`

**Interfaces:**

Consumes:
- `Seal.Channel.Caps.ChannelCaps { ccSend, ccPrompt, ccPromptSecret }`
- `Seal.Config.Paths.SealPaths { spKeys }`, `keyFilePath :: SealPaths -> FilePath -> FilePath`
- `Seal.Config.File.FileConfig { fcVaultRecipient, fcVaultIdentity, fcVaultKeyType }`
- `Seal.Security.Path.KeysRoot`, `ensureKeysRoot :: FilePath -> IO KeysRoot`
- `Seal.Security.Vault.Age { mkAgeEncryptor, AgeRecipient(..), AgeIdentity(..), VaultEncryptor, VaultError(..) }`
- `Seal.Security.Vault.UnlockMode(..)`

Produces (verbatim from contract):

```haskell
data VaultKeyBackend
  = LocalAgeKey
  | YubiKey { ykTouchRequired :: Bool }
  | UserSupplied
  deriving stock (Eq, Show)

data ResolvedKey = ResolvedKey
  { rkRecipient :: Text   -- age1... / age1yubikey1...
  , rkIdentity  :: Text   -- absolute path or user-supplied path
  , rkKeyType   :: Text   -- "x25519" | "yubikey" | "user"
  } deriving stock (Eq, Show)

detectAgePlugins  :: IO [Text]
setupLocalAgeKey  :: SealPaths -> Text -> IO (Either Text ResolvedKey)
setupYubiKey      :: SealPaths -> Text -> Bool -> ChannelCaps -> IO (Either Text ResolvedKey)
setupUserSupplied :: ChannelCaps -> IO (Either Text ResolvedKey)
parseUnlockMode   :: Maybe Text -> UnlockMode
resolveEncryptor  :: FileConfig -> IO (Either VaultError VaultEncryptor)
```

---

#### Step 8.1 — Scaffold: shared `FakeCaps` helper, module skeleton, cabal wiring

*The FakeCaps helper must exist before any test that exercises ChannelCaps interaction.*

**Create `test/Seal/TestHelpers/FakeCaps.hs`:**

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | In-process ChannelCaps for tests. ccSend appends (prepend + reverse on
-- read for O(1) writes); ccPrompt and ccPromptSecret both pop from the same
-- scripted-input queue in FIFO order.
module Seal.TestHelpers.FakeCaps
  ( FakeCaps (..)
  , makeFakeCaps
  , getSent
  ) where

import Data.IORef (IORef, modifyIORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)

import Seal.Channel.Caps (ChannelCaps (..))

data FakeCaps = FakeCaps
  { fcSent   :: IORef [Text]   -- reversed accumulator; read via getSent
  , fcInputs :: IORef [Text]   -- remaining scripted answers (head = next)
  }

-- | Build a (FakeCaps, ChannelCaps) pair from a list of canned responses.
-- The pair shares mutable state; use FakeCaps for inspection after the action.
makeFakeCaps :: [Text] -> IO (FakeCaps, ChannelCaps)
makeFakeCaps inputs = do
  sentRef  <- newIORef []
  inputRef <- newIORef inputs
  let pop _prompt = do
        queue <- readIORef inputRef
        case queue of
          []     -> fail "FakeCaps: scripted input queue exhausted"
          (x:xs) -> writeIORef inputRef xs *> pure x
      caps = ChannelCaps
        { ccSend         = \t -> modifyIORef sentRef (t :)
        , ccPrompt       = pop
        , ccPromptSecret = pop
        }
  pure (FakeCaps sentRef inputRef, caps)

-- | Retrieve sent messages in chronological (send) order.
getSent :: FakeCaps -> IO [Text]
getSent fc = reverse <$> readIORef (fcSent fc)
```

**Create `test/Seal/Vault/BackendSpec.hs` (skeleton, placeholder passes):**

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Seal.Vault.BackendSpec (spec) where

import Test.Hspec

spec :: Spec
spec = describe "Seal.Vault.Backend" $ do
  -- Steps below fill this in.
  pure ()
```

**Create `src/Seal/Vault/Backend.hs` (stubs — all `undefined`):**

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Seal.Vault.Backend
  ( VaultKeyBackend (..)
  , ResolvedKey (..)
  , detectAgePlugins
  , setupLocalAgeKey
  , setupYubiKey
  , setupUserSupplied
  , parseUnlockMode
  , resolveEncryptor
  ) where

import Data.Text (Text)

import Seal.Channel.Caps (ChannelCaps)
import Seal.Config.File (FileConfig)
import Seal.Config.Paths (SealPaths)
import Seal.Security.Vault (UnlockMode (..))
import Seal.Security.Vault.Age (VaultEncryptor, VaultError (..))

data VaultKeyBackend
  = LocalAgeKey
  | YubiKey { ykTouchRequired :: Bool }
  | UserSupplied
  deriving stock (Eq, Show)

data ResolvedKey = ResolvedKey
  { rkRecipient :: Text
  , rkIdentity  :: Text
  , rkKeyType   :: Text
  } deriving stock (Eq, Show)

detectAgePlugins :: IO [Text]
detectAgePlugins = undefined

setupLocalAgeKey :: SealPaths -> Text -> IO (Either Text ResolvedKey)
setupLocalAgeKey _ _ = undefined

setupYubiKey :: SealPaths -> Text -> Bool -> ChannelCaps -> IO (Either Text ResolvedKey)
setupYubiKey _ _ _ _ = undefined

setupUserSupplied :: ChannelCaps -> IO (Either Text ResolvedKey)
setupUserSupplied _ = undefined

parseUnlockMode :: Maybe Text -> UnlockMode
parseUnlockMode _ = undefined

resolveEncryptor :: FileConfig -> IO (Either VaultError VaultEncryptor)
resolveEncryptor _ = undefined
```

**Modify `seal-harness.cabal`:**

Library `exposed-modules` — add:
```
Seal.Vault.Backend
```

Test-suite `other-modules` — add:
```
Seal.TestHelpers.FakeCaps
Seal.Vault.BackendSpec
```

**Modify `test/Main.hs`:**

```haskell
import qualified Seal.Vault.BackendSpec
-- in the hspec $ do block:
  Seal.Vault.BackendSpec.spec
```

**RED run:**
```
nix develop --command cabal test 2>&1 | tail -40
```
Expected: compiles; `Seal.Vault.Backend` placeholder passes; no runtime calls to `undefined`.

**GREEN:** same run succeeds ✓

```
nix develop --command hlint src/Seal/Vault/Backend.hs test/Seal/TestHelpers/FakeCaps.hs test/Seal/Vault/BackendSpec.hs
```
Expected: No hints.

---

#### Step 8.2 — `parseUnlockMode`

**Add to `test/Seal/Vault/BackendSpec.hs`:**

```haskell
import Seal.Vault.Backend (parseUnlockMode)
import Seal.Security.Vault (UnlockMode (..))

-- inside spec describe block:
  describe "parseUnlockMode" $ do
    it "Nothing defaults to UnlockOnDemand" $
      parseUnlockMode Nothing `shouldBe` UnlockOnDemand
    it "\"on_demand\" -> UnlockOnDemand" $
      parseUnlockMode (Just "on_demand") `shouldBe` UnlockOnDemand
    it "\"startup\" -> UnlockStartup" $
      parseUnlockMode (Just "startup") `shouldBe` UnlockStartup
    it "\"per_access\" -> UnlockPerAccess" $
      parseUnlockMode (Just "per_access") `shouldBe` UnlockPerAccess
    it "unrecognised value defaults to UnlockOnDemand" $
      parseUnlockMode (Just "bogus") `shouldBe` UnlockOnDemand
```

**RED run** — `parseUnlockMode _ = undefined` throws on evaluation.

**Implement in `src/Seal/Vault/Backend.hs`:**

```haskell
parseUnlockMode :: Maybe Text -> UnlockMode
parseUnlockMode (Just "startup")    = UnlockStartup
parseUnlockMode (Just "per_access") = UnlockPerAccess
parseUnlockMode _                   = UnlockOnDemand
```

**GREEN run + hlint.**

---

#### Step 8.3 — `detectAgePlugins` and its pure helper

Pure helper `filterPluginNames` is testable without touching the filesystem.

**Add to `test/Seal/Vault/BackendSpec.hs`:**

```haskell
import Seal.Vault.Backend (detectAgePlugins, filterPluginNames)
import Data.List (sort)

  describe "filterPluginNames" $ do
    it "returns suffixes for age-plugin-* entries" $ do
      let names = ["age-plugin-yubikey", "age-plugin-fido2", "ssh", "age"]
      sort (filterPluginNames names) `shouldBe` ["fido2", "yubikey"]
    it "ignores files that do not start with age-plugin-" $ do
      filterPluginNames ["age", "ssh", "gpg"] `shouldBe` []
    it "handles empty list" $ do
      filterPluginNames [] `shouldBe` []
    it "detectAgePlugins returns IO [Text] without error" $ do
      -- Smoke test: just ensure it runs without exception
      plugins <- detectAgePlugins
      plugins `shouldSatisfy` all (not . null . show)
```

**RED run** — `filterPluginNames` not exported, `detectAgePlugins` is `undefined`.

**Add to `src/Seal/Vault/Backend.hs` — extend the export list and add imports + implementations:**

```haskell
-- Add to module export list:
  , filterPluginNames   -- exported for testing; not part of the public contract

-- New imports section:
import Control.Exception (IOException, try)
import Data.List (isPrefixOf, nub, sort)
import Data.Text qualified as T
import System.Directory (getSearchPath, listDirectory)

-- Implementations:

-- | Pure helper: given the filenames in one directory, return the plugin suffixes.
filterPluginNames :: [FilePath] -> [Text]
filterPluginNames names =
  [ T.pack (drop prefixLen n)
  | n <- names
  , pluginPrefix `isPrefixOf` n
  ]
  where
    pluginPrefix = "age-plugin-"
    prefixLen    = length pluginPrefix

detectAgePlugins :: IO [Text]
detectAgePlugins = do
  dirs <- getSearchPath
  allNames <- traverse safeList dirs
  pure (sort (nub (concatMap filterPluginNames allNames)))
  where
    safeList d = do
      r <- try @IOException (listDirectory d)
      pure (either (const []) id r)
```

**GREEN run + hlint.**

---

#### Step 8.4 — `resolveEncryptor`: missing-fields path (no age binary needed)

**Add to `test/Seal/Vault/BackendSpec.hs`:**

```haskell
import Seal.Vault.Backend (resolveEncryptor)
import Seal.Config.File (defaultFileConfig, FileConfig (..))
import Seal.Security.Vault.Age (VaultError (..))
import Data.Either (isLeft)

  describe "resolveEncryptor" $ do
    it "returns Left VaultBackendError when recipient is missing" $ do
      result <- resolveEncryptor defaultFileConfig
      result `shouldSatisfy` isLeft
      case result of
        Left (VaultBackendError _) -> pure ()
        other -> expectationFailure $ "expected VaultBackendError, got: " ++ show other

    it "returns Left VaultBackendError when identity is missing" $ do
      let fc = defaultFileConfig { fcVaultRecipient = Just "age1abc" }
      result <- resolveEncryptor fc
      result `shouldSatisfy` isLeft
      case result of
        Left (VaultBackendError _) -> pure ()
        other -> expectationFailure $ "expected VaultBackendError, got: " ++ show other

    it "returns Left VaultBackendError when recipient is missing but identity is present" $ do
      let fc = defaultFileConfig { fcVaultIdentity = Just "/path/to/id" }
      result <- resolveEncryptor fc
      result `shouldSatisfy` isLeft
```

**RED run** — `resolveEncryptor _ = undefined`.

**Implement:**

```haskell
-- New imports:
import Seal.Config.File (FileConfig (..))
import Seal.Security.Vault.Age
  ( AgeIdentity (..)
  , AgeRecipient (..)
  , VaultEncryptor
  , VaultError (..)
  , mkAgeEncryptor
  )

resolveEncryptor :: FileConfig -> IO (Either VaultError VaultEncryptor)
resolveEncryptor fc =
  case (fcVaultRecipient fc, fcVaultIdentity fc) of
    (Just r, Just i) ->
      mkAgeEncryptor (AgeRecipient r) (AgeIdentity i)
    (Nothing, _) ->
      pure (Left (VaultBackendError "vault not configured: missing vault_recipient"))
    (_, Nothing) ->
      pure (Left (VaultBackendError "vault not configured: missing vault_identity"))
```

**GREEN run + hlint.**

Note: when both fields are present but the `age` binary is absent, `mkAgeEncryptor` itself returns `Left (VaultBackendError "age not installed…")`. That path is exercised by the Phase 1 test suite; we rely on the contract rather than re-testing it here.

---

#### Step 8.5 — `setupUserSupplied`

**Add to `test/Seal/Vault/BackendSpec.hs`:**

```haskell
import Seal.TestHelpers.FakeCaps (makeFakeCaps, getSent)
import Seal.Vault.Backend (setupUserSupplied)

  describe "setupUserSupplied" $ do
    it "prompts for recipient then identity path; returns ResolvedKey with rkKeyType=user" $ do
      (_, caps) <- makeFakeCaps ["age1abc123", "/home/user/.seal/keys/mine.identity"]
      result <- setupUserSupplied caps
      result `shouldBe` Right ResolvedKey
        { rkRecipient = "age1abc123"
        , rkIdentity  = "/home/user/.seal/keys/mine.identity"
        , rkKeyType   = "user"
        }

    it "ccSend is not called (prompts only)" $ do
      (fc, caps) <- makeFakeCaps ["age1xyz", "/tmp/k.identity"]
      _ <- setupUserSupplied caps
      sent <- getSent fc
      sent `shouldBe` []
```

**RED run.**

**Implement:**

```haskell
-- New imports:
import Seal.Channel.Caps (ChannelCaps (..))

setupUserSupplied :: ChannelCaps -> IO (Either Text ResolvedKey)
setupUserSupplied caps = do
  recipient <- ccPrompt caps "Recipient (age1…): "
  identity  <- ccPrompt caps "Identity file path: "
  pure (Right ResolvedKey
    { rkRecipient = T.strip recipient
    , rkIdentity  = T.strip identity
    , rkKeyType   = "user"
    })
```

**GREEN run + hlint.**

---

#### Step 8.6 — `setupLocalAgeKey` (guarded on `age-keygen`)

**Add to `test/Seal/Vault/BackendSpec.hs`:**

```haskell
import System.Directory (findExecutable)
import System.IO.Temp (withSystemTempDirectory)
import System.FilePath ((</>))
import Seal.Config.Paths (SealPaths (..))
import Seal.Vault.Backend (setupLocalAgeKey)

  describe "setupLocalAgeKey" $ do
    it "generates a local age identity and returns ResolvedKey with rkKeyType=x25519" $ do
      ageExe      <- findExecutable "age"
      ageKeygenExe <- findExecutable "age-keygen"
      case (ageExe, ageKeygenExe) of
        (Nothing, _) -> pendingWith "age not installed"
        (_, Nothing) -> pendingWith "age-keygen not installed"
        _            ->
          withSystemTempDirectory "seal-backend-test" $ \tmpDir -> do
            let paths = SealPaths
                  { spHome   = tmpDir
                  , spConfig = tmpDir </> "config"
                  , spState  = tmpDir </> "state"
                  , spKeys   = tmpDir </> "keys"
                  }
            result <- setupLocalAgeKey paths "mykey"
            case result of
              Left err -> expectationFailure $ "setupLocalAgeKey failed: " ++ show err
              Right rk -> do
                rkKeyType rk `shouldBe` "x25519"
                rkRecipient rk `shouldSatisfy` ("age1" `T.isPrefixOf`)
                rkIdentity  rk `shouldSatisfy` (".identity" `T.isSuffixOf`)
                -- Identity file must exist and be mode 0600
                let identPath = T.unpack (rkIdentity rk)
                exists <- doesFileExist identPath
                exists `shouldBe` True
                st <- getFileStatus identPath
                let mode = fileMode st .&. 0o777
                mode `shouldBe` 0o600
```

Additional imports needed for this test:
```haskell
import System.Directory (doesFileExist)
import System.Posix.Files (getFileStatus, fileMode)
import System.Posix.Types (FileMode)
import Data.Bits ((.&.))
import Data.Text qualified as T
```

**RED run** — `setupLocalAgeKey _ _ = undefined`.

**Implement in `src/Seal/Vault/Backend.hs`:**

```haskell
-- New imports:
import Data.ByteString.Lazy qualified as BL
import Data.Text.Encoding qualified as TE
import System.Directory (makeAbsolute)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import System.Process.Typed (ExitCode (..), proc, readProcess)

import Seal.Config.Paths (SealPaths (..), keyFilePath)
import Seal.Security.Path (KeysRoot (..), ensureKeysRoot)

setupLocalAgeKey :: SealPaths -> Text -> IO (Either Text ResolvedKey)
setupLocalAgeKey paths name = do
  _keysRoot <- ensureKeysRoot (spKeys paths)
  let identPath = keyFilePath paths (T.unpack name <> ".identity")
  (exitCode, _stdout, stderrBs) <-
    readProcess (proc "age-keygen" ["-o", identPath])
  case exitCode of
    ExitFailure n ->
      pure (Left ("age-keygen failed with exit " <> T.pack (show n)))
    ExitSuccess -> do
      let stderrText = TE.decodeUtf8Lenient (BL.toStrict stderrBs)
      case parseAgePublicKey stderrText of
        Nothing ->
          pure (Left "age-keygen: could not parse public key from stderr")
        Just pubKey -> do
          setFileMode identPath 0o600
          absPath <- makeAbsolute identPath
          pure (Right ResolvedKey
            { rkRecipient = pubKey
            , rkIdentity  = T.pack absPath
            , rkKeyType   = "x25519"
            })

-- | Parse "Public key: age1..." from age-keygen stderr.
-- age-keygen writes exactly one such line; we match it case-sensitively
-- because the actual format is fixed ("Public key: " with capital P).
parseAgePublicKey :: Text -> Maybe Text
parseAgePublicKey stderr =
  case filter (T.isPrefixOf "Public key: ") (T.lines stderr) of
    []       -> Nothing
    (line:_) -> Just (T.drop (T.length "Public key: ") line)
```

**GREEN run + hlint.**

---

#### Step 8.7 — `setupYubiKey` (guarded on `age-plugin-yubikey`)

**Add to `test/Seal/Vault/BackendSpec.hs`:**

```haskell
import Seal.Vault.Backend (setupYubiKey)

  describe "setupYubiKey" $ do
    it "generates a yubikey identity and returns ResolvedKey with rkKeyType=yubikey" $ do
      pluginExe <- findExecutable "age-plugin-yubikey"
      case pluginExe of
        Nothing -> pendingWith "age-plugin-yubikey not installed"
        Just _  ->
          withSystemTempDirectory "seal-yubikey-test" $ \tmpDir -> do
            let paths = SealPaths
                  { spHome   = tmpDir
                  , spConfig = tmpDir </> "config"
                  , spState  = tmpDir </> "state"
                  , spKeys   = tmpDir </> "keys"
                  }
            -- Provide scripted caps for the TTY-fallback path; the happy path
            -- (captured stdout) does not consume these, but if the plugin
            -- requires a TTY the fallback prompts exactly once.
            (_, caps) <- makeFakeCaps [""]
            result <- setupYubiKey paths "yubi" False caps
            case result of
              Left err -> expectationFailure $ "setupYubiKey failed: " ++ show err
              Right rk -> do
                rkKeyType rk `shouldBe` "yubikey"
                rkRecipient rk `shouldSatisfy`
                  (\r -> "age1yubikey1" `T.isPrefixOf` r || "age1" `T.isPrefixOf` r)
```

**RED run** — `setupYubiKey _ _ _ _ = undefined`.

**Implement in `src/Seal/Vault/Backend.hs`:**

```haskell
-- New imports (add to existing):
import Data.ByteString qualified as BS
import System.Directory (findExecutable)

setupYubiKey
  :: SealPaths -> Text -> Bool -> ChannelCaps -> IO (Either Text ResolvedKey)
setupYubiKey paths name touchRequired caps = do
  mPlugin <- findExecutable "age-plugin-yubikey"
  case mPlugin of
    Nothing ->
      pure (Left "age-plugin-yubikey not found; install it to use YubiKey backend")
    Just _ -> do
      _keysRoot <- ensureKeysRoot (spKeys paths)
      let identPath  = keyFilePath paths (T.unpack name <> ".yubikey.txt")
          touchPolicy = if touchRequired then "always" else "never"
      (exitCode, stdoutBs, _stderrBs) <-
        readProcess (proc "age-plugin-yubikey"
          ["--generate", "--touch-policy", touchPolicy])
      let stdoutText = TE.decodeUtf8Lenient (BL.toStrict stdoutBs)
      -- Determine whether we got useful output directly, or need TTY fallback.
      capturedRecipient <-
        if exitCode == ExitSuccess && not (T.null (T.strip stdoutText))
          then do
            BS.writeFile identPath (TE.encodeUtf8 stdoutText)
            setFileMode identPath 0o600
            pure (parsePluginRecipient stdoutText)
          else do
            -- TTY fallback: instruct the user and wait.
            ccSend caps
              ("age-plugin-yubikey requires interactive input. Run this command:\n"
               <> "    age-plugin-yubikey --generate --touch-policy "
               <> T.pack touchPolicy
               <> " > "
               <> T.pack identPath)
            _ <- ccPrompt caps "Press Enter once the command has completed"
            content <- BS.readFile identPath
            setFileMode identPath 0o600
            pure (parsePluginRecipient (TE.decodeUtf8Lenient content))
      case capturedRecipient of
        Nothing ->
          pure (Left "age-plugin-yubikey: could not parse recipient from output")
        Just pubKey -> do
          absPath <- makeAbsolute identPath
          pure (Right ResolvedKey
            { rkRecipient = pubKey
            , rkIdentity  = T.pack absPath
            , rkKeyType   = "yubikey"
            })

-- | Parse "# Recipient: age1yubikey1..." from age-plugin-yubikey stdout.
-- The plugin emits TOML-style identity stanzas with a comment line of the form
-- "# Recipient: age1yubikey1...". We match case-insensitively on "recipient"
-- per the age plugin spec (some versions lowercase it).
-- "# Recipient: " = '#'(1) + ' '(1) + "Recipient"(9) + ':'(1) + ' '(1) = 13 chars.
parsePluginRecipient :: Text -> Maybe Text
parsePluginRecipient stdout =
  let isRecipientLine l = "# recipient: " `T.isPrefixOf` T.toCaseFold l
  in case filter isRecipientLine (T.lines stdout) of
       []      -> Nothing
       (line:_) ->
         -- Extract whatever follows the ": " separator, case-preserving.
         case T.breakOn ": " (T.drop 2 line) of   -- drop "# "
           (_, rest) | not (T.null rest) -> Just (T.strip (T.drop 2 rest))
           _                             -> Nothing
```

**GREEN run + hlint.**

---

#### Step 8.8 — Complete the module: `resolveEncryptor` with valid fields + hlint + commit

The implementation from Step 8.4 is already complete. Verify the full module compiles with `-Wall -Werror`.

**Full `src/Seal/Vault/Backend.hs` (assembled):**

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | Vault key-backend selection and setup. Produces a ResolvedKey (recipient +
-- identity path) from whichever backend the user chooses; converts it into a
-- live VaultEncryptor via the Phase 1 mkAgeEncryptor seam.
module Seal.Vault.Backend
  ( VaultKeyBackend (..)
  , ResolvedKey (..)
  , detectAgePlugins
  , filterPluginNames    -- exported for testing
  , setupLocalAgeKey
  , setupYubiKey
  , setupUserSupplied
  , parseUnlockMode
  , resolveEncryptor
  ) where

import Control.Exception (IOException, try)
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.List (isPrefixOf, nub, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (findExecutable, getSearchPath, listDirectory, makeAbsolute)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import System.Process.Typed (ExitCode (..), proc, readProcess)

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Config.File (FileConfig (..))
import Seal.Config.Paths (SealPaths (..), keyFilePath)
import Seal.Security.Path (ensureKeysRoot)
import Seal.Security.Vault (UnlockMode (..))
import Seal.Security.Vault.Age
  ( AgeIdentity (..)
  , AgeRecipient (..)
  , VaultEncryptor
  , VaultError (..)
  , mkAgeEncryptor
  )

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

data VaultKeyBackend
  = LocalAgeKey
  | YubiKey { ykTouchRequired :: Bool }
  | UserSupplied
  deriving stock (Eq, Show)

data ResolvedKey = ResolvedKey
  { rkRecipient :: Text   -- age1... / age1yubikey1...
  , rkIdentity  :: Text   -- absolute path to identity file
  , rkKeyType   :: Text   -- "x25519" | "yubikey" | "user"
  } deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Plugin detection
-- ---------------------------------------------------------------------------

filterPluginNames :: [FilePath] -> [Text]
filterPluginNames names =
  [ T.pack (drop prefixLen n)
  | n <- names
  , pluginPrefix `isPrefixOf` n
  ]
  where
    pluginPrefix = "age-plugin-"
    prefixLen    = length pluginPrefix

detectAgePlugins :: IO [Text]
detectAgePlugins = do
  dirs     <- getSearchPath
  allNames <- traverse safeList dirs
  pure (sort (nub (concatMap filterPluginNames allNames)))
  where
    safeList d = do
      r <- try @IOException (listDirectory d)
      pure (either (const []) id r)

-- ---------------------------------------------------------------------------
-- Backend setup
-- ---------------------------------------------------------------------------

setupLocalAgeKey :: SealPaths -> Text -> IO (Either Text ResolvedKey)
setupLocalAgeKey paths name = do
  _ <- ensureKeysRoot (spKeys paths)
  let identPath = keyFilePath paths (T.unpack name <> ".identity")
  (exitCode, _stdout, stderrBs) <-
    readProcess (proc "age-keygen" ["-o", identPath])
  case exitCode of
    ExitFailure n ->
      pure (Left ("age-keygen exited with code " <> T.pack (show n)))
    ExitSuccess -> do
      let stderrText = TE.decodeUtf8Lenient (BL.toStrict stderrBs)
      case parseAgePublicKey stderrText of
        Nothing  -> pure (Left "age-keygen: could not parse public key from stderr")
        Just pub -> do
          setFileMode identPath 0o600
          absPath <- makeAbsolute identPath
          pure (Right ResolvedKey
            { rkRecipient = pub
            , rkIdentity  = T.pack absPath
            , rkKeyType   = "x25519"
            })

setupYubiKey
  :: SealPaths -> Text -> Bool -> ChannelCaps -> IO (Either Text ResolvedKey)
setupYubiKey paths name touchRequired caps = do
  mPlugin <- findExecutable "age-plugin-yubikey"
  case mPlugin of
    Nothing ->
      pure (Left "age-plugin-yubikey not found on PATH")
    Just _ -> do
      _ <- ensureKeysRoot (spKeys paths)
      let identPath   = keyFilePath paths (T.unpack name <> ".yubikey.txt")
          touchPolicy = if touchRequired then "always" else "never"
      (exitCode, stdoutBs, _) <-
        readProcess (proc "age-plugin-yubikey"
          ["--generate", "--touch-policy", touchPolicy])
      let stdoutText = TE.decodeUtf8Lenient (BL.toStrict stdoutBs)
      mRecipient <-
        if exitCode == ExitSuccess && not (T.null (T.strip stdoutText))
          then do
            BS.writeFile identPath (TE.encodeUtf8 stdoutText)
            setFileMode identPath 0o600
            pure (parsePluginRecipient stdoutText)
          else do
            -- TTY fallback: instruct user and wait for manual completion.
            ccSend caps
              ("age-plugin-yubikey requires interactive input. Run:\n"
               <> "    age-plugin-yubikey --generate --touch-policy "
               <> T.pack touchPolicy <> " > " <> T.pack identPath)
            _ <- ccPrompt caps "Press Enter once the command has completed"
            raw <- BS.readFile identPath
            setFileMode identPath 0o600
            pure (parsePluginRecipient (TE.decodeUtf8Lenient raw))
      case mRecipient of
        Nothing  -> pure (Left "age-plugin-yubikey: could not parse recipient line")
        Just pub -> do
          absPath <- makeAbsolute identPath
          pure (Right ResolvedKey
            { rkRecipient = pub
            , rkIdentity  = T.pack absPath
            , rkKeyType   = "yubikey"
            })

setupUserSupplied :: ChannelCaps -> IO (Either Text ResolvedKey)
setupUserSupplied caps = do
  recipient <- ccPrompt caps "Recipient (age1\x2026): "
  identity  <- ccPrompt caps "Identity file path: "
  pure (Right ResolvedKey
    { rkRecipient = T.strip recipient
    , rkIdentity  = T.strip identity
    , rkKeyType   = "user"
    })

-- ---------------------------------------------------------------------------
-- Unlock mode + encryptor resolution
-- ---------------------------------------------------------------------------

parseUnlockMode :: Maybe Text -> UnlockMode
parseUnlockMode (Just "startup")    = UnlockStartup
parseUnlockMode (Just "per_access") = UnlockPerAccess
parseUnlockMode _                   = UnlockOnDemand

resolveEncryptor :: FileConfig -> IO (Either VaultError VaultEncryptor)
resolveEncryptor fc =
  case (fcVaultRecipient fc, fcVaultIdentity fc) of
    (Just r, Just i) ->
      mkAgeEncryptor (AgeRecipient r) (AgeIdentity i)
    (Nothing, _) ->
      pure (Left (VaultBackendError "vault not configured: missing vault_recipient"))
    (_, Nothing) ->
      pure (Left (VaultBackendError "vault not configured: missing vault_identity"))

-- ---------------------------------------------------------------------------
-- Internal parsers
-- ---------------------------------------------------------------------------

-- | Parse "Public key: age1..." from age-keygen stderr.
-- age-keygen always emits exactly this line (capital P, no '#' prefix).
parseAgePublicKey :: Text -> Maybe Text
parseAgePublicKey txt =
  case filter (T.isPrefixOf "Public key: ") (T.lines txt) of
    []       -> Nothing
    (line:_) -> Just (T.drop (T.length "Public key: ") line)

-- | Parse "# Recipient: age1yubikey1..." from age-plugin-yubikey output.
-- Match is case-insensitive on "recipient" per the age plugin spec.
-- Structure: "# " (2) + word + ": " + recipient. We drop "# ", then split on ": ".
parsePluginRecipient :: Text -> Maybe Text
parsePluginRecipient txt =
  let isRecipientLine l = "# recipient: " `T.isPrefixOf` T.toCaseFold l
  in case filter isRecipientLine (T.lines txt) of
       []      -> Nothing
       (line:_) ->
         case T.breakOn ": " (T.drop 2 line) of   -- drop "# "
           (_, rest) | not (T.null rest) -> Just (T.strip (T.drop 2 rest))
           _                             -> Nothing
```

**Final GREEN run:**
```
nix develop --command cabal test 2>&1 | tail -40
nix develop --command hlint src/Seal/Vault/Backend.hs test/Seal/TestHelpers/FakeCaps.hs test/Seal/Vault/BackendSpec.hs
```

**Commit:**
```
git add src/Seal/Vault/Backend.hs \
        test/Seal/Vault/BackendSpec.hs \
        test/Seal/TestHelpers/FakeCaps.hs \
        seal-harness.cabal test/Main.hs
git commit -m "$(cat <<'EOF'
Add Seal.Vault.Backend: key-backend setup, plugin detection, encryptor resolution

Implements detectAgePlugins (PATH scan), setupLocalAgeKey (age-keygen -o,
0o600 identity file), setupYubiKey (age-plugin-yubikey with TTY fallback),
setupUserSupplied (prompted), parseUnlockMode, and resolveEncryptor. Adds
shared FakeCaps test helper used by Tasks 8 and 9.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: `Seal.Vault.Commands`

> Depends on Tasks 1 (Seal.Channel.Caps), 2 (Seal.Command.Spec), 5
> (Seal.Config.Paths), 7 (Seal.Config.File), 8 (Seal.Vault.Backend), and
> Phase 1 Seal.Security.Vault / Seal.Security.Vault.Age. No single issue;
> depends on #1–#4 (infra) + Task 8.

**Files:**
- Create `src/Seal/Vault/Commands.hs`
- Create `test/Seal/Vault/CommandsSpec.hs`
- Modify `seal-harness.cabal` (library `exposed-modules`, test `other-modules`)
- Modify `test/Main.hs`

**Interfaces:**

Consumes:
- `Seal.Channel.Caps.ChannelCaps { ccSend, ccPrompt, ccPromptSecret }`
- `Seal.Command.Spec { CommandSpec(..), CommandName(..), CommandGroup(..), CommandAction(..), Availability(..) }`
- `Seal.Config.File { FileConfig(..), defaultFileConfig, loadFileConfig, updateFileConfig }`
- `Seal.Config.Paths { SealPaths, vaultFilePath }`
- `Seal.Security.Vault { VaultConfig(..), VaultHandle(..), VaultStatus(..), UnlockMode(..), openVault }`
- `Seal.Security.Vault.Age { VaultError(..), VaultEncryptor, mkAgeEncryptor, AgeRecipient(..), AgeIdentity(..) }`
- `Seal.Vault.Backend { ResolvedKey(..), detectAgePlugins, parseUnlockMode, resolveEncryptor, setupLocalAgeKey, setupYubiKey, setupUserSupplied }`

Produces (verbatim from contract):

```haskell
data VaultRuntime = VaultRuntime
  { vrPaths      :: SealPaths
  , vrConfigPath :: FilePath
  , vrHandleRef  :: IORef (Maybe VaultHandle)
  }

vaultCommandSpec :: VaultRuntime -> CommandSpec
-- csName = CommandName "vault", csGroup = GroupVault
-- csParserInfo parses subcommands: setup add get list delete lock unlock status
-- each yields a CommandAction (ChannelCaps -> IO ())
```

---

#### Step 9.1 — Scaffold: module skeleton, VaultRuntime, cabal wiring

**Create `src/Seal/Vault/Commands.hs` (stubs):**

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | The \/vault CommandSpec and its subcommand handlers over Phase 1 VaultHandle.
module Seal.Vault.Commands
  ( VaultRuntime (..)
  , vaultCommandSpec
  ) where

import Data.IORef (IORef)
import Data.Text (Text)
import Options.Applicative

import Seal.Channel.Caps (ChannelCaps)
import Seal.Command.Spec
  ( Availability (..)
  , CommandAction (..)
  , CommandGroup (..)
  , CommandName (..)
  , CommandSpec (..)
  )
import Seal.Config.File (FileConfig)
import Seal.Config.Paths (SealPaths)
import Seal.Security.Vault (VaultHandle)

data VaultRuntime = VaultRuntime
  { vrPaths      :: SealPaths
  , vrConfigPath :: FilePath
  , vrHandleRef  :: IORef (Maybe VaultHandle)
  }

vaultCommandSpec :: VaultRuntime -> CommandSpec
vaultCommandSpec rt = CommandSpec
  { csName         = CommandName "vault"
  , csAliases      = []
  , csGroup        = GroupVault
  , csSynopsis     = "Manage the encrypted secret vault"
  , csParserInfo   = vaultParserInfo rt
  , csAvailability = InteractiveOnly
  }

vaultParserInfo :: VaultRuntime -> ParserInfo CommandAction
vaultParserInfo rt =
  info (vaultParser rt <**> helper)
    (progDesc "Encrypted secret vault operations"
     <> header "vault — manage secrets in the on-disk encrypted vault")

vaultParser :: VaultRuntime -> Parser CommandAction
vaultParser _rt = undefined   -- filled in below
```

**Create `test/Seal/Vault/CommandsSpec.hs` (skeleton):**

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Seal.Vault.CommandsSpec (spec) where

import Test.Hspec

spec :: Spec
spec = describe "Seal.Vault.Commands" $ do
  pure ()
```

**Modify `seal-harness.cabal`:**

Library `exposed-modules` — add:
```
Seal.Vault.Commands
```

Test-suite `other-modules` — add:
```
Seal.Vault.CommandsSpec
```

Test-suite `build-depends` — add (if not already present):
```
stm
```
(IORef is in `base`; the test needs `stm` for the vault which uses `TVar`.)

**Modify `test/Main.hs`:**

```haskell
import qualified Seal.Vault.CommandsSpec
-- in hspec $ do:
  Seal.Vault.CommandsSpec.spec
```

**RED/GREEN run:**
```
nix develop --command cabal test 2>&1 | tail -40
```
Expected: compiles; placeholder test passes. `vaultParser` is `undefined` but not called yet.

---

#### Step 9.2 — Test infrastructure: `withTestEnv` helper + `runVaultCmd` helper

These helpers are used by every subsequent test. They go at the top of `CommandsSpec.hs`.

**Full preamble of `test/Seal/Vault/CommandsSpec.hs`:**

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Seal.Vault.CommandsSpec (spec) where

import Control.Monad (void)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Options.Applicative (defaultPrefs, execParserPure, renderFailure, ParserResult (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Spec (CommandSpec (..), CommandName (..), CommandAction (..))
import Seal.Config.Paths (SealPaths (..))
import Seal.Security.Vault (VaultConfig (..), VaultHandle (..), UnlockMode (..), openVault)
import Seal.Security.Vault.Age (mkMockEncryptor)
import Seal.TestHelpers.FakeCaps (FakeCaps, makeFakeCaps, getSent)
import Seal.Vault.Commands (VaultRuntime (..), vaultCommandSpec)

-- ---------------------------------------------------------------------------
-- Test helpers
-- ---------------------------------------------------------------------------

-- | Set up a fresh mock vault + runtime in a temp dir.
-- The VaultHandle is pre-populated (init + unlock) with mkMockEncryptor.
withTestEnv
  :: [Text]                                  -- scripted inputs for FakeCaps
  -> (FakeCaps -> ChannelCaps -> VaultRuntime -> VaultHandle -> IO ())
  -> IO ()
withTestEnv inputs k =
  withSystemTempDirectory "seal-vault-cmd" $ \tmpDir -> do
    let vaultDir  = tmpDir </> "config" </> "vault"
        vaultPath = vaultDir </> "vault.age"
        cfgPath   = tmpDir </> "config" </> "config.toml"
        paths     = SealPaths
          { spHome   = tmpDir
          , spConfig = tmpDir </> "config"
          , spState  = tmpDir </> "state"
          , spKeys   = tmpDir </> "keys"
          }
    createDirectoryIfMissing True vaultDir
    let vaultCfg = VaultConfig
          { vcPath   = vaultPath
          , vcKeyType = "mock"
          , vcUnlock  = UnlockOnDemand
          }
    h <- openVault vaultCfg mkMockEncryptor
    _ <- vhInit h
    _ <- vhUnlock h
    ref <- newIORef (Just h)
    let rt = VaultRuntime
          { vrPaths      = paths
          , vrConfigPath = cfgPath
          , vrHandleRef  = ref
          }
    (fc, caps) <- makeFakeCaps inputs
    k fc caps rt h

-- | Parse and run a vault subcommand through the real optparse parser.
-- Returns Left with the optparse error text on parse failure.
runVaultCmd :: VaultRuntime -> ChannelCaps -> [String] -> IO (Either String ())
runVaultCmd rt caps args =
  let spec   = vaultCommandSpec rt
      result = execParserPure defaultPrefs (csParserInfo spec) args
  in case result of
    Success action ->
      runCommandAction action caps *> pure (Right ())
    Failure failure ->
      let (msg, _) = renderFailure failure "vault"
      in pure (Left msg)
    CompletionInvoked _ ->
      pure (Left "completion not supported in tests")

-- | Run a vault command and assert it succeeds (parse + IO).
runVaultCmd_ :: VaultRuntime -> ChannelCaps -> [String] -> IO ()
runVaultCmd_ rt caps args = do
  result <- runVaultCmd rt caps args
  case result of
    Right () -> pure ()
    Left msg -> expectationFailure $ "vault command parse failed: " ++ msg

spec :: Spec
spec = describe "Seal.Vault.Commands" $ do
  -- Steps below fill this in.
  pure ()
```

**RED/GREEN run:** helpers compile; placeholder test passes.

---

#### Step 9.3 — "vault not configured" guard

Non-setup commands send a help message when `vrHandleRef` is `Nothing`.

**Add to `spec` in `CommandsSpec.hs`:**

```haskell
  describe "unconfigured runtime" $ do
    it "list sends 'vault not configured' when handle is Nothing" $ do
      withSystemTempDirectory "seal-cmd-uncfg" $ \tmpDir -> do
        let paths = SealPaths tmpDir (tmpDir </> "config")
                               (tmpDir </> "state") (tmpDir </> "keys")
        ref <- newIORef Nothing
        let rt = VaultRuntime paths (tmpDir </> "config.toml") ref
        (fc, caps) <- makeFakeCaps []
        runVaultCmd_ rt caps ["list"]
        sent <- getSent fc
        sent `shouldSatisfy` any (T.isInfixOf "vault not configured")

    it "status sends 'vault not configured' when handle is Nothing" $ do
      withSystemTempDirectory "seal-cmd-uncfg" $ \tmpDir -> do
        let paths = SealPaths tmpDir (tmpDir </> "config")
                               (tmpDir </> "state") (tmpDir </> "keys")
        ref <- newIORef Nothing
        let rt = VaultRuntime paths (tmpDir </> "config.toml") ref
        (fc, caps) <- makeFakeCaps []
        runVaultCmd_ rt caps ["status"]
        sent <- getSent fc
        sent `shouldSatisfy` any (T.isInfixOf "vault not configured")
```

**RED run** — `vaultParser _rt = undefined`.

**Implement the guard helper + `list` + `status` stubs in `src/Seal/Vault/Commands.hs`:**

```haskell
-- New imports to add:
import Data.IORef (IORef, readIORef, writeIORef)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.ByteString qualified as BS

import Seal.Config.File (FileConfig (..), defaultFileConfig, loadFileConfig, updateFileConfig)
import Seal.Config.Paths (SealPaths (..), vaultFilePath)
import Seal.Security.Vault
  ( VaultConfig (..)
  , VaultHandle (..)
  , VaultStatus (..)
  , UnlockMode (..)
  , openVault
  )
import Seal.Security.Vault.Age
  ( AgeIdentity (..)
  , AgeRecipient (..)
  , VaultEncryptor
  , VaultError (..)
  , mkAgeEncryptor
  )
import Seal.Vault.Backend
  ( ResolvedKey (..)
  , detectAgePlugins
  , parseUnlockMode
  , resolveEncryptor
  , setupLocalAgeKey
  , setupUserSupplied
  , setupYubiKey
  )

-- ---------------------------------------------------------------------------
-- Guard helper
-- ---------------------------------------------------------------------------

-- | Run k with the vault handle, or send "not configured" and return.
withHandle :: VaultRuntime -> ChannelCaps -> (VaultHandle -> IO ()) -> IO ()
withHandle rt caps k = do
  mh <- readIORef (vrHandleRef rt)
  case mh of
    Nothing -> ccSend caps "vault not configured — run /vault setup"
    Just h  -> k h

-- ---------------------------------------------------------------------------
-- Error mapping
-- ---------------------------------------------------------------------------

vaultErrMsg :: VaultError -> Text
vaultErrMsg VaultLocked           = "vault is locked — run /vault unlock"
vaultErrMsg VaultNotFound         = "vault not found — run /vault setup"
vaultErrMsg VaultAlreadyExists    = "vault already exists"
vaultErrMsg (VaultKeyNotFound k)  = "no such secret: " <> k
vaultErrMsg (VaultBackendError t) = "backend error: " <> t

-- | Apply f to Right, or send the error message for Left.
handleResult
  :: ChannelCaps -> Either VaultError a -> (a -> IO ()) -> IO ()
handleResult caps (Left e)  _ = ccSend caps (vaultErrMsg e)
handleResult _    (Right a) k = k a

-- ---------------------------------------------------------------------------
-- Subcommand actions
-- ---------------------------------------------------------------------------

listCmd :: VaultRuntime -> CommandAction
listCmd rt = CommandAction $ \caps ->
  withHandle rt caps $ \h -> do
    result <- vhList h
    handleResult caps result $ \names ->
      mapM_ (ccSend caps) names

statusCmd :: VaultRuntime -> CommandAction
statusCmd rt = CommandAction $ \caps ->
  withHandle rt caps $ \h -> do
    st <- vhStatus h
    ccSend caps $ T.unlines
      [ "locked:  " <> (if vsLocked st then "yes" else "no")
      , "secrets: " <> T.pack (show (vsSecretCount st))
      , "key:     " <> vsKeyType st
      ]

-- Stubs for remaining commands (filled in next steps):
setupCmd  :: VaultRuntime -> CommandAction
setupCmd  _rt = CommandAction $ \caps -> ccSend caps "setup not yet implemented"

addCmd :: VaultRuntime -> Text -> CommandAction
addCmd _rt _name = CommandAction $ \caps -> ccSend caps "add not yet implemented"

getCmd :: VaultRuntime -> Text -> CommandAction
getCmd _rt _name = CommandAction $ \caps -> ccSend caps "get not yet implemented"

deleteCmd :: VaultRuntime -> Text -> CommandAction
deleteCmd _rt _name = CommandAction $ \caps -> ccSend caps "delete not yet implemented"

lockCmd   :: VaultRuntime -> CommandAction
lockCmd   _rt = CommandAction $ \caps -> ccSend caps "lock not yet implemented"

unlockCmd :: VaultRuntime -> CommandAction
unlockCmd _rt = CommandAction $ \caps -> ccSend caps "unlock not yet implemented"

-- ---------------------------------------------------------------------------
-- optparse parser
-- ---------------------------------------------------------------------------

nameArg :: Parser Text
nameArg = T.pack <$> strArgument (metavar "NAME" <> help "Secret name")

vaultParser :: VaultRuntime -> Parser CommandAction
vaultParser rt = hsubparser
  (  command "setup"
       (info (pure (setupCmd rt))
             (progDesc "Set up the vault backend and create the vault"))
  <> command "add"
       (info (addCmd rt <$> nameArg)
             (progDesc "Add or update a secret (hidden prompt)"))
  <> command "get"
       (info (getCmd rt <$> nameArg)
             (progDesc "Retrieve and reveal a secret"))
  <> command "list"
       (info (pure (listCmd rt))
             (progDesc "List all secret names"))
  <> command "delete"
       (info (deleteCmd rt <$> nameArg)
             (progDesc "Delete a secret"))
  <> command "lock"
       (info (pure (lockCmd rt))
             (progDesc "Lock the vault (clear decrypted cache)"))
  <> command "unlock"
       (info (pure (unlockCmd rt))
             (progDesc "Unlock the vault (decrypt into cache)"))
  <> command "status"
       (info (pure (statusCmd rt))
             (progDesc "Show vault status (locked, secret count, key type)"))
  <> metavar "COMMAND"
  )
```

**GREEN run:**
```
nix develop --command cabal test 2>&1 | tail -40
```
Expected: "vault not configured" tests pass; stub tests not yet written so nothing else fails.

---

#### Step 9.4 — `list` command end-to-end

**Add to `spec`:**

```haskell
  describe "list" $ do
    it "returns empty list on fresh vault" $
      withTestEnv [] $ \fc caps rt _h -> do
        runVaultCmd_ rt caps ["list"]
        sent <- getSent fc
        sent `shouldBe` []

    it "sends each secret name on its own line" $
      withTestEnv [] $ \fc caps rt h -> do
        _ <- vhPut h "alpha" "v1"
        _ <- vhPut h "beta"  "v2"
        runVaultCmd_ rt caps ["list"]
        sent <- getSent fc
        sent `shouldSatisfy` elem "alpha"
        sent `shouldSatisfy` elem "beta"
        length sent `shouldBe` 2
```

**RED run** — `listCmd` sends nothing for the "not yet implemented" stub (step 9.3 had it working already, so these tests should pass with the real implementation from step 9.3).

Actually `listCmd` was implemented in Step 9.3. **GREEN** immediately.

---

#### Step 9.5 — `add NAME` command

**Add to `spec`:**

```haskell
  describe "add" $ do
    it "stores the secret entered via ccPromptSecret" $
      withTestEnv ["s3cr3t!"] $ \_fc caps rt h -> do
        runVaultCmd_ rt caps ["add", "mykey"]
        result <- vhGet h "mykey"
        result `shouldBe` Right (TE.encodeUtf8 "s3cr3t!")

    it "sends a confirmation message after adding" $
      withTestEnv ["my-value"] $ \fc caps rt _h -> do
        runVaultCmd_ rt caps ["add", "tok"]
        sent <- getSent fc
        sent `shouldSatisfy` any (T.isInfixOf "tok")

    it "returns VaultLocked message when vault is locked" $
      withTestEnv ["val"] $ \fc caps rt h -> do
        vhLock h
        -- Re-lock the vault by writing Nothing to the cache (via vhLock)
        -- and switch to UnlockStartup mode so on-demand doesn't re-unlock.
        -- Simpler: use a fresh runtime with no handle.
        ref2 <- newIORef Nothing
        let rt2 = rt { vrHandleRef = ref2 }
        runVaultCmd_ rt2 caps ["add", "k"]
        sent <- getSent fc
        sent `shouldSatisfy` any (T.isInfixOf "vault not configured")
```

**RED run** — `addCmd` is a stub.

**Implement `addCmd`:**

```haskell
addCmd :: VaultRuntime -> Text -> CommandAction
addCmd rt name = CommandAction $ \caps ->
  withHandle rt caps $ \h -> do
    val <- ccPromptSecret caps ("Value for " <> name <> ": ")
    result <- vhPut h name (TE.encodeUtf8 val)
    handleResult caps result $ \() ->
      ccSend caps ("Secret '" <> name <> "' stored.")
```

**GREEN run + hlint.**

---

#### Step 9.6 — `get NAME` command

**Add to `spec`:**

```haskell
  describe "get" $ do
    it "reveals the stored secret value" $
      withTestEnv [] $ \fc caps rt h -> do
        _ <- vhPut h "api-key" (TE.encodeUtf8 "sk-123")
        runVaultCmd_ rt caps ["get", "api-key"]
        sent <- getSent fc
        sent `shouldSatisfy` elem "sk-123"

    it "sends VaultKeyNotFound message for missing key" $
      withTestEnv [] $ \fc caps rt _h -> do
        runVaultCmd_ rt caps ["get", "nosuchkey"]
        sent <- getSent fc
        sent `shouldSatisfy` any (T.isInfixOf "no such secret")

    it "VaultKeyNotFound message includes the key name" $
      withTestEnv [] $ \fc caps rt _h -> do
        runVaultCmd_ rt caps ["get", "missingkey"]
        sent <- getSent fc
        sent `shouldSatisfy` any (T.isInfixOf "missingkey")
```

**RED run** — `getCmd` is a stub.

**Implement `getCmd`:**

```haskell
getCmd :: VaultRuntime -> Text -> CommandAction
getCmd rt name = CommandAction $ \caps ->
  withHandle rt caps $ \h -> do
    result <- vhGet h name
    handleResult caps result $ \bs ->
      ccSend caps (TE.decodeUtf8Lenient bs)
```

**GREEN run + hlint.**

---

#### Step 9.7 — `delete NAME` command

**Add to `spec`:**

```haskell
  describe "delete" $ do
    it "removes the secret from the vault" $
      withTestEnv [] $ \_fc caps rt h -> do
        _ <- vhPut h "tok" (TE.encodeUtf8 "abc")
        runVaultCmd_ rt caps ["delete", "tok"]
        result <- vhGet h "tok"
        result `shouldBe` Left (VaultKeyNotFound "tok")

    it "sends a confirmation message" $
      withTestEnv [] $ \fc caps rt h -> do
        _ <- vhPut h "gone" "x"
        runVaultCmd_ rt caps ["delete", "gone"]
        sent <- getSent fc
        sent `shouldSatisfy` any (T.isInfixOf "gone")

    it "sends 'no such secret' for a missing key" $
      withTestEnv [] $ \fc caps rt _h -> do
        runVaultCmd_ rt caps ["delete", "phantom"]
        sent <- getSent fc
        sent `shouldSatisfy` any (T.isInfixOf "no such secret")
```

**RED run** — `deleteCmd` is a stub.

**Implement `deleteCmd`:**

```haskell
deleteCmd :: VaultRuntime -> Text -> CommandAction
deleteCmd rt name = CommandAction $ \caps ->
  withHandle rt caps $ \h -> do
    result <- vhDelete h name
    handleResult caps result $ \() ->
      ccSend caps ("Secret '" <> name <> "' deleted.")
```

**GREEN run + hlint.**

---

#### Step 9.8 — `lock` and `unlock` commands

**Add to `spec`:**

```haskell
  describe "lock / unlock" $ do
    it "lock leaves vault inaccessible without re-unlock (UnlockStartup mode)" $ do
      withSystemTempDirectory "seal-cmd-lock" $ \tmpDir -> do
        let vaultDir  = tmpDir </> "config" </> "vault"
            vaultPath = vaultDir </> "vault.age"
            paths     = SealPaths tmpDir (tmpDir </> "config")
                                   (tmpDir </> "state") (tmpDir </> "keys")
        createDirectoryIfMissing True vaultDir
        -- UnlockStartup mode: explicit unlock required; auto-unlock on lock disabled.
        let vaultCfg = VaultConfig vaultPath "mock" UnlockStartup
        h <- openVault vaultCfg mkMockEncryptor
        _ <- vhInit h
        _ <- vhUnlock h
        _ <- vhPut h "k" "v"
        ref <- newIORef (Just h)
        let rt = VaultRuntime paths (tmpDir </> "config.toml") ref
        (fc, caps) <- makeFakeCaps []
        runVaultCmd_ rt caps ["lock"]
        -- After lock, status should show locked=True
        st <- vhStatus h
        vsLocked st `shouldBe` True
        -- unlock restores access
        runVaultCmd_ rt caps ["unlock"]
        st2 <- vhStatus h
        vsLocked st2 `shouldBe` False

    it "lock sends a confirmation" $
      withTestEnv [] $ \fc caps rt _h -> do
        runVaultCmd_ rt caps ["lock"]
        sent <- getSent fc
        sent `shouldSatisfy` any (T.isInfixOf "lock")
```

**RED run** — `lockCmd` and `unlockCmd` are stubs.

**Implement:**

```haskell
lockCmd :: VaultRuntime -> CommandAction
lockCmd rt = CommandAction $ \caps ->
  withHandle rt caps $ \h -> do
    vhLock h
    ccSend caps "Vault locked."

unlockCmd :: VaultRuntime -> CommandAction
unlockCmd rt = CommandAction $ \caps ->
  withHandle rt caps $ \h -> do
    result <- vhUnlock h
    handleResult caps result $ \() ->
      ccSend caps "Vault unlocked."
```

**GREEN run + hlint.**

---

#### Step 9.9 — `status` command

**Add to `spec`:**

```haskell
  describe "status" $ do
    it "reports locked=no, zero secrets on freshly unlocked vault" $
      withTestEnv [] $ \fc caps rt _h -> do
        runVaultCmd_ rt caps ["status"]
        sent <- getSent fc
        let out = T.unlines sent
        out `shouldSatisfy` T.isInfixOf "no"      -- locked: no
        out `shouldSatisfy` T.isInfixOf "0"        -- secrets: 0

    it "reports the key type from VaultConfig" $
      withTestEnv [] $ \fc caps rt _h -> do
        runVaultCmd_ rt caps ["status"]
        sent <- getSent fc
        T.unlines sent `shouldSatisfy` T.isInfixOf "mock"

    it "reports correct secret count after additions" $
      withTestEnv [] $ \fc caps rt h -> do
        _ <- vhPut h "a" "1"
        _ <- vhPut h "b" "2"
        runVaultCmd_ rt caps ["status"]
        sent <- getSent fc
        T.unlines sent `shouldSatisfy` T.isInfixOf "2"
```

**GREEN immediately** — `statusCmd` was implemented in Step 9.3. Verify clean run.

---

#### Step 9.10 — `setup` command (real-age-gated)

The setup command requires `age` (for `resolveEncryptor` → `mkAgeEncryptor`) and is
tested with `pendingWith` when the binary is absent. We test only the LocalAgeKey
path here; YubiKey and UserSupplied are integration tests gated separately.

**Add to `spec`:**

```haskell
  describe "setup" $ do
    it "setup with LocalAgeKey creates vault and populates vrHandleRef" $ do
      ageExe      <- findExecutable "age"
      agekeygenExe <- findExecutable "age-keygen"
      case (ageExe, agekeygenExe) of
        (Nothing, _) -> pendingWith "age not installed"
        (_, Nothing) -> pendingWith "age-keygen not installed"
        _ ->
          withSystemTempDirectory "seal-cmd-setup" $ \tmpDir -> do
            let vaultDir = tmpDir </> "config" </> "vault"
                paths    = SealPaths tmpDir (tmpDir </> "config")
                                      (tmpDir </> "state") (tmpDir </> "keys")
                cfgPath  = tmpDir </> "config" </> "config.toml"
            createDirectoryIfMissing True vaultDir
            createDirectoryIfMissing True (tmpDir </> "config")
            ref <- newIORef Nothing
            let rt = VaultRuntime paths cfgPath ref
            -- Scripted inputs: choose backend 1 (LocalAgeKey)
            (fc, caps) <- makeFakeCaps ["1"]
            runVaultCmd_ rt caps ["setup"]
            mh <- readIORef ref
            mh `shouldSatisfy` (/= Nothing)
            sent <- getSent fc
            sent `shouldSatisfy` any (T.isInfixOf "created")

    it "setup on existing vault triggers rekey flow" $ do
      ageExe <- findExecutable "age"
      case ageExe of
        Nothing -> pendingWith "age not installed"
        Just _  ->
          withSystemTempDirectory "seal-cmd-rekey" $ \tmpDir -> do
            let vaultDir = tmpDir </> "config" </> "vault"
                paths    = SealPaths tmpDir (tmpDir </> "config")
                                      (tmpDir </> "state") (tmpDir </> "keys")
                cfgPath  = tmpDir </> "config" </> "config.toml"
            createDirectoryIfMissing True vaultDir
            createDirectoryIfMissing True (tmpDir </> "config")
            ref <- newIORef Nothing
            let rt = VaultRuntime paths cfgPath ref
            -- First setup: backend=1
            (_, caps1) <- makeFakeCaps ["1"]
            runVaultCmd_ rt caps1 ["setup"]
            -- Second setup: backend=1 again; confirm rekey with "y"
            ref2 <- newIORef =<< readIORef ref
            let rt2 = rt { vrHandleRef = ref2 }
            (fc2, caps2) <- makeFakeCaps ["1", "y"]
            runVaultCmd_ rt2 caps2 ["setup"]
            sent2 <- getSent fc2
            sent2 `shouldSatisfy` any
              (\m -> T.isInfixOf "rekey" m || T.isInfixOf "created" m)
```

Additional imports for the spec file:
```haskell
import System.Directory (createDirectoryIfMissing, findExecutable)
import Seal.Security.Vault.Age (VaultError (..), mkMockEncryptor)
```

**RED run** — `setupCmd` is a stub that sends "setup not yet implemented".

**Implement `setupCmd` in `src/Seal/Vault/Commands.hs`:**

```haskell
import Control.Monad (when)
import Data.Maybe (fromMaybe)

setupCmd :: VaultRuntime -> CommandAction
setupCmd rt = CommandAction $ \caps -> do
  -- 1. Detect plugins and present backend menu.
  plugins <- detectAgePlugins
  let hasYubi = "yubikey" `elem` plugins
  ccSend caps "Available vault backends:"
  ccSend caps "  1. Local age key (age-keygen) — key stored on disk"
  when hasYubi $
    ccSend caps "  2. YubiKey (age-plugin-yubikey) — key stays on hardware token [recommended]"
  let userChoice = if hasYubi then "3" else "2"
  ccSend caps ("  " <> userChoice <> ". User-supplied (bring your own key)")
  choice <- T.strip <$> ccPrompt caps "Choose backend [1]: "
  let effectiveChoice = if T.null choice then "1" else choice

  -- 2. Run the selected setup flow.
  rk <- case (effectiveChoice, hasYubi) of
    ("1", _)     -> setupLocalAgeKey (vrPaths rt) "default"
    ("2", True)  -> do
      tp <- ccPrompt caps "Require touch? [y/N]: "
      let touch = T.toLower (T.strip tp) `elem` ["y", "yes"]
      setupYubiKey (vrPaths rt) "default" touch caps
    ("2", False) -> setupUserSupplied caps
    ("3", True)  -> setupUserSupplied caps
    (other, _)   -> pure (Left ("Invalid choice: " <> other))

  case rk of
    Left err -> ccSend caps ("Setup failed: " <> err)
    Right resolvedKey -> do

      -- 3. Persist key info to config.toml.
      updateResult <- updateFileConfig (vrConfigPath rt) $ \fc -> fc
        { fcVaultRecipient = Just (rkRecipient resolvedKey)
        , fcVaultIdentity  = Just (rkIdentity  resolvedKey)
        , fcVaultKeyType   = Just (rkKeyType   resolvedKey)
        }
      case updateResult of
        Left err -> ccSend caps ("Config write failed: " <> err)
        Right () -> do

          -- 4. Build a live encryptor from the resolved key.
          encResult <- mkAgeEncryptor
            (AgeRecipient (rkRecipient resolvedKey))
            (AgeIdentity  (rkIdentity  resolvedKey))
          case encResult of
            Left e -> ccSend caps (vaultErrMsg e)
            Right enc -> do

              -- 5. Open the vault and init (or rekey if it already exists).
              let vaultPath = vaultFilePath (vrPaths rt)
                  vaultCfg  = VaultConfig
                    { vcPath   = vaultPath
                    , vcKeyType = rkKeyType resolvedKey
                    , vcUnlock  = UnlockOnDemand
                    }
              h <- openVault vaultCfg enc
              initResult <- vhInit h
              case initResult of
                Right () -> do
                  writeIORef (vrHandleRef rt) (Just h)
                  ccSend caps "Vault created successfully."

                Left VaultAlreadyExists -> do
                  -- Load OLD config to decrypt with the previous key.
                  cfgResult <- loadFileConfig (vrConfigPath rt)
                  case cfgResult of
                    Left err ->
                      ccSend caps ("Cannot read existing config for rekey: " <> err)
                    Right oldCfg -> do
                      oldEncResult <- resolveEncryptor oldCfg
                      case oldEncResult of
                        Left e ->
                          ccSend caps ("Cannot load existing key for rekey: " <> vaultErrMsg e)
                        Right oldEnc -> do
                          let oldVaultCfg = vaultCfg
                                { vcKeyType = fromMaybe "unknown" (fcVaultKeyType oldCfg) }
                          oldH <- openVault oldVaultCfg oldEnc
                          _ <- vhUnlock oldH
                          let confirmRekey msg = do
                                ccSend caps msg
                                r <- ccPrompt caps "Confirm rekey? [y/N]: "
                                pure (T.toLower (T.strip r) `elem` ["y", "yes"])
                          rekeyResult <- vhRekey oldH enc (rkKeyType resolvedKey) confirmRekey
                          case rekeyResult of
                            Right () -> do
                              writeIORef (vrHandleRef rt) (Just oldH)
                              ccSend caps "Vault rekeyed successfully."
                            Left e ->
                              ccSend caps (vaultErrMsg e)

                Left e ->
                  ccSend caps (vaultErrMsg e)
```

**GREEN run** (setup tests pending without age; others still green).

**hlint:**
```
nix develop --command hlint src/Seal/Vault/Commands.hs test/Seal/Vault/CommandsSpec.hs
```

---

#### Step 9.11 — End-to-end sequence test (mock encryptor, no real age)

Verify the full add → get → list → delete → lock → unlock → status sequence runs
correctly against the pre-populated mock handle. This is the key integration test.

**Add to `spec`:**

```haskell
  describe "full sequence (mock encryptor)" $ do
    it "add -> get -> list -> delete -> status flow" $
      withTestEnv ["my-secret-value"] $ \fc caps rt h -> do
        -- add
        runVaultCmd_ rt caps ["add", "MYKEY"]
        -- get
        (fc2, caps2) <- makeFakeCaps []
        runVaultCmd_ rt caps2 ["get", "MYKEY"]
        sent2 <- getSent fc2
        sent2 `shouldSatisfy` elem "my-secret-value"
        -- list
        (fc3, caps3) <- makeFakeCaps []
        runVaultCmd_ rt caps3 ["list"]
        sent3 <- getSent fc3
        sent3 `shouldSatisfy` elem "MYKEY"
        -- delete
        (fc4, caps4) <- makeFakeCaps []
        runVaultCmd_ rt caps4 ["delete", "MYKEY"]
        r <- vhGet h "MYKEY"
        r `shouldBe` Left (VaultKeyNotFound "MYKEY")
        -- status after delete shows 0 secrets
        (fc5, caps5) <- makeFakeCaps []
        runVaultCmd_ rt caps5 ["status"]
        sent5 <- getSent fc5
        T.unlines sent5 `shouldSatisfy` T.isInfixOf "0"

    it "VaultKeyNotFound error message includes the key name" $
      withTestEnv [] $ \fc caps rt _h -> do
        runVaultCmd_ rt caps ["get", "xyzzy"]
        sent <- getSent fc
        sent `shouldSatisfy` any (T.isInfixOf "xyzzy")

    it "VaultLocked message when vault is locked and mode is UnlockStartup" $ do
      withSystemTempDirectory "seal-locked" $ \tmpDir -> do
        let vaultDir  = tmpDir </> "config" </> "vault"
            vaultPath = vaultDir </> "vault.age"
            paths     = SealPaths tmpDir (tmpDir </> "config")
                                   (tmpDir </> "state") (tmpDir </> "keys")
        createDirectoryIfMissing True vaultDir
        let vaultCfg = VaultConfig vaultPath "mock" UnlockStartup
        h <- openVault vaultCfg mkMockEncryptor
        _ <- vhInit h
        -- Do NOT unlock: vault is locked.
        ref <- newIORef (Just h)
        let rt = VaultRuntime paths (tmpDir </> "config.toml") ref
        (fc, caps) <- makeFakeCaps []
        runVaultCmd_ rt caps ["get", "anything"]
        -- UnlockStartup + locked = VaultLocked error; OnDemand auto-unlocks so
        -- with an empty vault we get VaultKeyNotFound instead. With Startup we
        -- should see the locked message.
        sent <- getSent fc
        -- The vault has no secrets AND is locked — get should return VaultLocked
        -- (since UnlockStartup does not auto-unlock).
        sent `shouldSatisfy` any (T.isInfixOf "locked")
```

**GREEN run** (all tests using mock handle pass; real-age tests pending).

---

#### Step 9.12 — Final hlint + full assembly + commit

**Full `src/Seal/Vault/Commands.hs` (assembled, all stubs replaced):**

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | The \/vault CommandSpec: eight subcommands (setup, add, get, list, delete,
-- lock, unlock, status) wired to the Phase 1 VaultHandle. Commands close over
-- a VaultRuntime so they carry no global state. The optparse parser produces
-- CommandActions; test code calls them through execParserPure.
module Seal.Vault.Commands
  ( VaultRuntime (..)
  , vaultCommandSpec
  ) where

import Control.Monad (when)
import Data.ByteString qualified as BS
import Data.IORef (IORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Options.Applicative

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Spec
  ( Availability (..)
  , CommandAction (..)
  , CommandGroup (..)
  , CommandName (..)
  , CommandSpec (..)
  )
import Seal.Config.File (FileConfig (..), loadFileConfig, updateFileConfig)
import Seal.Config.Paths (SealPaths, vaultFilePath)
import Seal.Security.Vault
  ( VaultConfig (..)
  , VaultHandle (..)
  , VaultStatus (..)
  , UnlockMode (..)
  , openVault
  )
import Seal.Security.Vault.Age
  ( AgeIdentity (..)
  , AgeRecipient (..)
  , VaultEncryptor
  , VaultError (..)
  , mkAgeEncryptor
  )
import Seal.Vault.Backend
  ( ResolvedKey (..)
  , detectAgePlugins
  , parseUnlockMode
  , resolveEncryptor
  , setupLocalAgeKey
  , setupUserSupplied
  , setupYubiKey
  )

-- ---------------------------------------------------------------------------
-- Runtime
-- ---------------------------------------------------------------------------

data VaultRuntime = VaultRuntime
  { vrPaths      :: SealPaths
  , vrConfigPath :: FilePath
  , vrHandleRef  :: IORef (Maybe VaultHandle)
  }

-- ---------------------------------------------------------------------------
-- CommandSpec entry point
-- ---------------------------------------------------------------------------

vaultCommandSpec :: VaultRuntime -> CommandSpec
vaultCommandSpec rt = CommandSpec
  { csName         = CommandName "vault"
  , csAliases      = []
  , csGroup        = GroupVault
  , csSynopsis     = "Manage the encrypted secret vault"
  , csParserInfo   = vaultParserInfo rt
  , csAvailability = InteractiveOnly
  }

vaultParserInfo :: VaultRuntime -> ParserInfo CommandAction
vaultParserInfo rt =
  info (vaultParser rt <**> helper)
    (  progDesc "Encrypted secret vault operations"
    <> header   "vault — manage secrets in the on-disk encrypted vault"
    )

vaultParser :: VaultRuntime -> Parser CommandAction
vaultParser rt = hsubparser
  (  command "setup"
       (info (pure (setupCmd rt))
             (progDesc "Set up the vault backend and create the vault"))
  <> command "add"
       (info (addCmd rt <$> nameArg)
             (progDesc "Add or update a secret (value entered via hidden prompt)"))
  <> command "get"
       (info (getCmd rt <$> nameArg)
             (progDesc "Retrieve and reveal a secret"))
  <> command "list"
       (info (pure (listCmd rt))
             (progDesc "List all secret names (values are never shown)"))
  <> command "delete"
       (info (deleteCmd rt <$> nameArg)
             (progDesc "Delete a secret"))
  <> command "lock"
       (info (pure (lockCmd rt))
             (progDesc "Lock the vault (clear the decrypted cache)"))
  <> command "unlock"
       (info (pure (unlockCmd rt))
             (progDesc "Unlock the vault (decrypt into memory cache)"))
  <> command "status"
       (info (pure (statusCmd rt))
             (progDesc "Show vault status: locked, secret count, key type"))
  <> metavar "COMMAND"
  )

nameArg :: Parser Text
nameArg = T.pack <$> strArgument (metavar "NAME" <> help "Secret name")

-- ---------------------------------------------------------------------------
-- Guard + error helpers
-- ---------------------------------------------------------------------------

withHandle :: VaultRuntime -> ChannelCaps -> (VaultHandle -> IO ()) -> IO ()
withHandle rt caps k = do
  mh <- readIORef (vrHandleRef rt)
  case mh of
    Nothing -> ccSend caps "vault not configured — run /vault setup"
    Just h  -> k h

vaultErrMsg :: VaultError -> Text
vaultErrMsg VaultLocked           = "vault is locked — run /vault unlock"
vaultErrMsg VaultNotFound         = "vault not found — run /vault setup"
vaultErrMsg VaultAlreadyExists    = "vault already exists"
vaultErrMsg (VaultKeyNotFound k)  = "no such secret: " <> k
vaultErrMsg (VaultBackendError t) = "backend error: " <> t

handleResult :: ChannelCaps -> Either VaultError a -> (a -> IO ()) -> IO ()
handleResult caps (Left e)  _ = ccSend caps (vaultErrMsg e)
handleResult _    (Right a) k = k a

-- ---------------------------------------------------------------------------
-- Subcommand handlers
-- ---------------------------------------------------------------------------

setupCmd :: VaultRuntime -> CommandAction
setupCmd rt = CommandAction $ \caps -> do
  plugins <- detectAgePlugins
  let hasYubi = "yubikey" `elem` plugins
  ccSend caps "Available vault backends:"
  ccSend caps "  1. Local age key (age-keygen) — key stored on disk"
  when hasYubi $
    ccSend caps "  2. YubiKey (age-plugin-yubikey) — key stays on token [recommended]"
  let userNum = if hasYubi then "3" else "2"
  ccSend caps ("  " <> userNum <> ". User-supplied (bring your own key)")
  choice <- T.strip <$> ccPrompt caps "Choose backend [1]: "
  let effective = if T.null choice then "1" else choice
  rkResult <- case (effective, hasYubi) of
    ("1", _)     -> setupLocalAgeKey (vrPaths rt) "default"
    ("2", True)  -> do
      tp <- ccPrompt caps "Require touch? [y/N]: "
      let touch = T.toLower (T.strip tp) `elem` ["y", "yes"]
      setupYubiKey (vrPaths rt) "default" touch caps
    ("2", False) -> setupUserSupplied caps
    ("3", True)  -> setupUserSupplied caps
    (other, _)   -> pure (Left ("Invalid choice: " <> other))
  case rkResult of
    Left err -> ccSend caps ("Setup failed: " <> err)
    Right rk -> do
      ur <- updateFileConfig (vrConfigPath rt) $ \fc -> fc
        { fcVaultRecipient = Just (rkRecipient rk)
        , fcVaultIdentity  = Just (rkIdentity  rk)
        , fcVaultKeyType   = Just (rkKeyType   rk)
        }
      case ur of
        Left err -> ccSend caps ("Config write failed: " <> err)
        Right () -> do
          encResult <- mkAgeEncryptor
            (AgeRecipient (rkRecipient rk))
            (AgeIdentity  (rkIdentity  rk))
          case encResult of
            Left e -> ccSend caps (vaultErrMsg e)
            Right enc -> do
              let vaultCfg = VaultConfig
                    { vcPath   = vaultFilePath (vrPaths rt)
                    , vcKeyType = rkKeyType rk
                    , vcUnlock  = UnlockOnDemand
                    }
              h <- openVault vaultCfg enc
              initResult <- vhInit h
              case initResult of
                Right () -> do
                  writeIORef (vrHandleRef rt) (Just h)
                  ccSend caps "Vault created successfully."
                Left VaultAlreadyExists ->
                  rekeyExisting rt caps enc (rkKeyType rk)
                Left e ->
                  ccSend caps (vaultErrMsg e)

-- | Rekey an existing vault with a new encryptor.
-- Loads the OLD encryptor from the saved config, unlocks, rekeyes, and
-- stores the updated handle.
rekeyExisting :: VaultRuntime -> ChannelCaps -> VaultEncryptor -> Text -> IO ()
rekeyExisting rt caps newEnc newKeyType = do
  cfgResult <- loadFileConfig (vrConfigPath rt)
  case cfgResult of
    Left err ->
      ccSend caps ("Cannot read existing config for rekey: " <> err)
    Right oldCfg -> do
      oldEncResult <- resolveEncryptor oldCfg
      case oldEncResult of
        Left e ->
          ccSend caps ("Cannot load existing key for rekey: " <> vaultErrMsg e)
        Right oldEnc -> do
          let oldVaultCfg = VaultConfig
                { vcPath   = vaultFilePath (vrPaths rt)
                , vcKeyType = fromMaybe "unknown" (fcVaultKeyType oldCfg)
                , vcUnlock  = UnlockOnDemand
                }
          oldH <- openVault oldVaultCfg oldEnc
          _ <- vhUnlock oldH
          let confirmRekey msg = do
                ccSend caps msg
                r <- ccPrompt caps "Confirm rekey? [y/N]: "
                pure (T.toLower (T.strip r) `elem` ["y", "yes"])
          rekeyResult <- vhRekey oldH newEnc newKeyType confirmRekey
          case rekeyResult of
            Right () -> do
              writeIORef (vrHandleRef rt) (Just oldH)
              ccSend caps "Vault rekeyed successfully."
            Left e ->
              ccSend caps (vaultErrMsg e)

addCmd :: VaultRuntime -> Text -> CommandAction
addCmd rt name = CommandAction $ \caps ->
  withHandle rt caps $ \h -> do
    val <- ccPromptSecret caps ("Value for " <> name <> ": ")
    result <- vhPut h name (TE.encodeUtf8 val)
    handleResult caps result $ \() ->
      ccSend caps ("Secret '" <> name <> "' stored.")

getCmd :: VaultRuntime -> Text -> CommandAction
getCmd rt name = CommandAction $ \caps ->
  withHandle rt caps $ \h -> do
    result <- vhGet h name
    handleResult caps result (ccSend caps . TE.decodeUtf8Lenient)

listCmd :: VaultRuntime -> CommandAction
listCmd rt = CommandAction $ \caps ->
  withHandle rt caps $ \h -> do
    result <- vhList h
    handleResult caps result (mapM_ (ccSend caps))

deleteCmd :: VaultRuntime -> Text -> CommandAction
deleteCmd rt name = CommandAction $ \caps ->
  withHandle rt caps $ \h -> do
    result <- vhDelete h name
    handleResult caps result $ \() ->
      ccSend caps ("Secret '" <> name <> "' deleted.")

lockCmd :: VaultRuntime -> CommandAction
lockCmd rt = CommandAction $ \caps ->
  withHandle rt caps $ \h -> do
    vhLock h
    ccSend caps "Vault locked."

unlockCmd :: VaultRuntime -> CommandAction
unlockCmd rt = CommandAction $ \caps ->
  withHandle rt caps $ \h -> do
    result <- vhUnlock h
    handleResult caps result $ \() ->
      ccSend caps "Vault unlocked."

statusCmd :: VaultRuntime -> CommandAction
statusCmd rt = CommandAction $ \caps ->
  withHandle rt caps $ \h -> do
    st <- vhStatus h
    ccSend caps $ T.unlines
      [ "locked:  " <> (if vsLocked st then "yes" else "no")
      , "secrets: " <> T.pack (show (vsSecretCount st))
      , "key:     " <> vsKeyType st
      ]
```

**Final run:**
```
nix develop --command cabal test 2>&1 | tail -40
nix develop --command hlint src/Seal/Vault/ test/Seal/Vault/ test/Seal/TestHelpers/
```
Expected: all non-pending tests pass; pending tests show "# PENDING: age not installed" etc.

**Commit:**
```
git add src/Seal/Vault/Commands.hs \
        test/Seal/Vault/CommandsSpec.hs \
        seal-harness.cabal test/Main.hs
git commit -m "$(cat <<'EOF'
Add Seal.Vault.Commands: /vault CommandSpec over Phase 1 VaultHandle

Implements all eight subcommands (setup, add, get, list, delete, lock,
unlock, status) behind a guard that sends 'vault not configured' when the
handle is absent. VaultError is mapped to user-friendly messages. Setup
command runs the backend wizard and triggers rekey when vault already
exists. All non-setup commands are tested end-to-end with the mock
encryptor via FakeCaps; real-age setup test is gated with pendingWith.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```


---

### Task 10: `Seal.Ingest`

**Files:**
- **Create:** `src/Seal/Ingest.hs`
- **Create:** `test/Seal/IngestSpec.hs`
- **Modify:** `seal-harness.cabal` — `Seal.Ingest` → `exposed-modules:`; `Seal.IngestSpec` → test-suite `other-modules:`
- **Modify:** `test/Main.hs` — import + run `Seal.IngestSpec`

**Interfaces:**

Consumes (prior tasks):
- `Seal.Command.Spec`: `CommandAction(..)`, `CommandGroup(..)`, `CommandName(..)`, `CommandSpec(..)`, `Availability(..)`, `Registry`, `mkRegistry`
- `Seal.Command.Parse`: `ParseOutcome(..)`, `parseSlash`
- `Seal.Command.Help`: `renderHelpIndex`, `renderHelpFor`

Produces:
```haskell
newtype RawInbound = RawInbound Text  deriving stock (Eq, Show)
type PreprocessStage = RawInbound -> IO (Either Text RawInbound)
newtype PreprocessChain = PreprocessChain [PreprocessStage]
emptyChain :: PreprocessChain
runChain   :: PreprocessChain -> RawInbound -> IO (Either Text RawInbound)

data Disposition
  = DispatchAction CommandAction
  | ShowText Text
  | PlainMessage Text
  | Rejected Text

ingest :: Registry -> PreprocessChain -> RawInbound -> IO Disposition
```

#### Steps

- [ ] **Step 1: Register in cabal + `test/Main.hs`**

  `seal-harness.cabal` — `library` `exposed-modules:`:
  ```
        Seal.Ingest
  ```

  `seal-harness.cabal` — `test-suite tests` `other-modules:`:
  ```
        Seal.IngestSpec
  ```

  `test/Main.hs` additions:
  ```haskell
  import qualified Seal.IngestSpec
  -- inside hspec $ do:
    Seal.IngestSpec.spec
  ```

- [ ] **Step 2: Create `src/Seal/Ingest.hs` — types + stubs**

  ```haskell
  {-# LANGUAGE OverloadedStrings #-}
  -- | Single-door ingest chokepoint: preprocess chain → Disposition classifier.
  module Seal.Ingest
    ( RawInbound (..)
    , PreprocessStage
    , PreprocessChain (..)
    , emptyChain
    , runChain
    , Disposition (..)
    , ingest
    ) where

  import Data.Text (Text)
  import qualified Data.Text as T

  import Seal.Command.Help (renderHelpFor, renderHelpIndex)
  import Seal.Command.Parse (ParseOutcome (..), parseSlash)
  import Seal.Command.Spec (CommandAction, CommandName, Registry)

  -- ---------------------------------------------------------------------------
  -- Raw input
  -- ---------------------------------------------------------------------------

  newtype RawInbound = RawInbound Text
    deriving stock (Eq, Show)

  -- ---------------------------------------------------------------------------
  -- Preprocess chain
  -- ---------------------------------------------------------------------------

  -- | A single preprocess stage. 'Left' aborts the chain with a rejection message.
  type PreprocessStage = RawInbound -> IO (Either Text RawInbound)

  -- | An ordered sequence of 'PreprocessStage's run before classification.
  newtype PreprocessChain = PreprocessChain [PreprocessStage]

  -- | The empty chain: all input passes through unchanged.
  emptyChain :: PreprocessChain
  emptyChain = PreprocessChain []

  -- | Run every stage in order, short-circuiting on the first 'Left'.
  runChain :: PreprocessChain -> RawInbound -> IO (Either Text RawInbound)
  runChain = undefined

  -- ---------------------------------------------------------------------------
  -- Disposition
  -- ---------------------------------------------------------------------------

  data Disposition
    = DispatchAction CommandAction  -- ^ a parsed command to run
    | ShowText Text                 -- ^ help text or parse error to echo
    | PlainMessage Text             -- ^ non-slash input (MVP stub)
    | Rejected Text                 -- ^ preprocess chain rejected the input

  -- | Classify one inbound line. The chain runs FIRST; if it rejects the
  -- input the result is 'Rejected' regardless of content.
  --
  -- Classification (after chain passes):
  --
  -- * Leading @\/@  → 'parseSlash' → 'DispatchAction' | 'ShowText'
  -- * Otherwise     → 'PlainMessage'
  ingest :: Registry -> PreprocessChain -> RawInbound -> IO Disposition
  ingest = undefined
  ```

- [ ] **Step 3: Create `test/Seal/IngestSpec.hs`**

  ```haskell
  {-# LANGUAGE OverloadedStrings #-}
  module Seal.IngestSpec (spec) where

  import Data.IORef (modifyIORef', newIORef, readIORef)
  import Data.Text (Text)

  import Options.Applicative (info, progDesc)
  import Test.Hspec

  import Seal.Channel.Caps (ChannelCaps (..))
  import Seal.Command.Spec
    ( Availability (..)
    , CommandAction (..)
    , CommandGroup (..)
    , CommandName (..)
    , CommandSpec (..)
    , Registry
    , mkRegistry
    )
  import Seal.Ingest

  -- ---------------------------------------------------------------------------
  -- Fake registry
  -- ---------------------------------------------------------------------------

  -- | Records every 'ccSend' call (prepended; reverse for chronological order).
  recordingCaps :: IORef [Text] -> ChannelCaps
  recordingCaps ref = ChannelCaps
    { ccSend         = \t -> modifyIORef' ref (t :)
    , ccPrompt       = \_ -> pure ""
    , ccPromptSecret = \_ -> pure ""
    }

  -- | The fake "ping" command: sends "pong" via 'ccSend'.
  pingAction :: CommandAction
  pingAction = CommandAction $ \caps -> ccSend caps "pong"

  pingSpec :: CommandSpec
  pingSpec = CommandSpec
    { csName         = CommandName "ping"
    , csAliases      = []
    , csGroup        = GroupGeneral
    , csSynopsis     = "Echo pong"
    , csParserInfo   = info (pure pingAction) (progDesc "Echo pong")
    , csAvailability = AlwaysAvailable
    }

  testRegistry :: Registry
  testRegistry = mkRegistry [pingSpec]

  -- ---------------------------------------------------------------------------
  -- Helper: describe a Disposition without a Show instance for CommandAction
  -- ---------------------------------------------------------------------------

  showShape :: Disposition -> String
  showShape (DispatchAction _) = "DispatchAction"
  showShape (ShowText t)       = "ShowText " <> show t
  showShape (PlainMessage t)   = "PlainMessage " <> show t
  showShape (Rejected t)       = "Rejected " <> show t

  -- ---------------------------------------------------------------------------
  -- Spec
  -- ---------------------------------------------------------------------------

  spec :: Spec
  spec = do
    describe "runChain" $ do
      it "emptyChain passes input through unchanged" $ do
        let r = RawInbound "hello"
        result <- runChain emptyChain r
        result `shouldBe` Right r

      it "a rejecting stage short-circuits with Left" $ do
        let rejectStage :: PreprocessStage
            rejectStage _ = pure (Left "blocked")
            chain = PreprocessChain [rejectStage]
        result <- runChain chain (RawInbound "anything")
        result `shouldBe` Left "blocked"

      it "a passing stage can transform the value" $ do
        let appendBang :: PreprocessStage
            appendBang (RawInbound t) = pure (Right (RawInbound (t <> "!")))
            chain = PreprocessChain [appendBang]
        result <- runChain chain (RawInbound "hi")
        result `shouldBe` Right (RawInbound "hi!")

      it "stages run in order; Left from stage 1 skips stage 2" $ do
        probeRef <- newIORef (0 :: Int)
        let stage1 :: PreprocessStage
            stage1 _ = modifyIORef' probeRef (+ 1) >> pure (Left "stop")
            stage2 :: PreprocessStage
            stage2 r = modifyIORef' probeRef (+ 10) >> pure (Right r)
            chain = PreprocessChain [stage1, stage2]
        _ <- runChain chain (RawInbound "x")
        count <- readIORef probeRef
        count `shouldBe` 1   -- stage2 must NOT have run

    describe "ingest" $ do
      it "returns PlainMessage for non-slash input" $ do
        d <- ingest testRegistry emptyChain (RawInbound "hello there")
        case d of
          PlainMessage t -> t `shouldBe` "hello there"
          other          -> expectationFailure $
            "expected PlainMessage, got: " <> showShape other

      it "returns DispatchAction for a known slash command and runs it" $ do
        ref <- newIORef []
        d   <- ingest testRegistry emptyChain (RawInbound "/ping")
        case d of
          DispatchAction a -> do
            runCommandAction a (recordingCaps ref)
            sent <- readIORef ref
            sent `shouldBe` ["pong"]
          other -> expectationFailure $
            "expected DispatchAction, got: " <> showShape other

      it "returns ShowText (help index) for /help" $ do
        d <- ingest testRegistry emptyChain (RawInbound "/help")
        case d of
          ShowText t -> t `shouldContain` "ping"
          other      -> expectationFailure $
            "expected ShowText (help index), got: " <> showShape other

      it "returns ShowText (command help) for /help ping" $ do
        d <- ingest testRegistry emptyChain (RawInbound "/help ping")
        case d of
          ShowText t -> t `shouldContain` "ping"
          other      -> expectationFailure $
            "expected ShowText (command help), got: " <> showShape other

      it "returns ShowText for an unknown slash command" $ do
        d <- ingest testRegistry emptyChain (RawInbound "/nonexistent")
        case d of
          ShowText _ -> pure ()
          other      -> expectationFailure $
            "expected ShowText (parse failure), got: " <> showShape other

      it "chain runs BEFORE dispatch — Rejected when chain rejects /ping" $ do
        let probe :: PreprocessStage
            probe _ = pure (Left "chain ran first")
            chain   = PreprocessChain [probe]
        d <- ingest testRegistry chain (RawInbound "/ping")
        case d of
          Rejected msg -> msg `shouldBe` "chain ran first"
          other        -> expectationFailure $
            "expected Rejected, got: " <> showShape other
  ```

- [ ] **Step 4 (RED): Confirm tests compile but runtime-fail on `undefined`**

  ```
  nix develop --command cabal test 2>&1 | tail -30
  ```

  Expected: suite compiles; `runChain` and `ingest` tests all fail with
  `Prelude.undefined` or `called undefined`. A compile error means a missing
  export in the stub — fix before continuing.

- [ ] **Step 5: Implement `runChain`**

  Replace the `runChain = undefined` body:

  ```haskell
  runChain :: PreprocessChain -> RawInbound -> IO (Either Text RawInbound)
  runChain (PreprocessChain stages) = go stages
    where
      go []       r = pure (Right r)
      go (s : ss) r = s r >>= \case
        Left err -> pure (Left err)
        Right r' -> go ss r'
  ```

- [ ] **Step 6 (GREEN — chain tests): Run**

  ```
  nix develop --command cabal test 2>&1 | tail -30
  ```

  Expected: all four `runChain` tests pass; `ingest` tests still fail
  (`ingest = undefined`).

- [ ] **Step 7: Implement `ingest`**

  Replace the `ingest = undefined` body:

  ```haskell
  ingest :: Registry -> PreprocessChain -> RawInbound -> IO Disposition
  ingest registry chain raw = do
    chainResult <- runChain chain raw
    case chainResult of
      Left msg             -> pure (Rejected msg)
      Right (RawInbound t) ->
        if T.isPrefixOf "/" t
          then pure $ case parseSlash registry t of
            ParsedAction a     -> DispatchAction a
            ParseHelp Nothing  -> ShowText (renderHelpIndex registry)
            ParseHelp (Just n) -> ShowText (renderHelpFor registry n)
            ParseFailure txt   -> ShowText txt
          else pure (PlainMessage t)
  ```

- [ ] **Step 8 (GREEN — all ingest tests): Run**

  ```
  nix develop --command cabal test 2>&1 | tail -30
  ```

  Expected: all `Seal.IngestSpec` tests pass; no regressions in earlier specs.

- [ ] **Step 9: hlint**

  ```
  nix develop --command hlint src/Seal/Ingest.hs test/Seal/IngestSpec.hs
  ```

  Expected: no suggestions.

- [ ] **Step 10: Commit**

  ```
  git add seal-harness.cabal test/Main.hs \
      src/Seal/Ingest.hs test/Seal/IngestSpec.hs
  git commit -m "$(cat <<'EOF'
  Add Seal.Ingest: preprocess chain + Disposition classifier

  Installs the single-door ingest chokepoint: every inbound line passes
  through the PreprocessChain before any classification.  emptyChain is
  the no-op MVP stage; a Left-returning stage short-circuits to Rejected.
  Slash input routes through parseSlash into DispatchAction / ShowText;
  plain text becomes PlainMessage.  Fully tested with a fake "ping" registry
  and a one-stage probe chain confirming chain-runs-first ordering.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

### Task 11: `Seal.Channel.Cli` + `Seal.Repl` + exe/Main wiring

**Files:**
- **Create:** `src/Seal/Channel/Cli.hs`
- **Create:** `src/Seal/Repl.hs`
- **Create:** `test/Seal/Channel/CliSpec.hs`
- **Modify:** `seal-harness.cabal` — `Seal.Channel.Cli`, `Seal.Repl` → `exposed-modules:`; `Seal.Channel.CliSpec` → test-suite `other-modules:`
- **Modify:** `test/Main.hs` — import + run `Seal.Channel.CliSpec`
- **Modify:** `src/Seal/Types/Command.hs` — add `CommandRepl` + `repl` subcommand
- **Modify:** `src/Seal/AppMain.hs` — dispatch `CommandRepl` via `liftIO Seal.Repl.runRepl`

**Interfaces:**

Consumes (prior tasks):
- `Seal.Ingest`: `Disposition(..)`, `PreprocessChain`, `RawInbound(..)`, `emptyChain`, `ingest`
- `Seal.Channel.Caps`: `ChannelCaps(..)`
- `Seal.Command.Spec`: `CommandAction(..)`, `Registry`, `mkRegistry`
- `Seal.Config.Paths`: `SealPaths(..)`, `getSealPaths`, `ensureSealDirs`, `configFilePath`, `vaultFilePath`
- `Seal.Config.File`: `FileConfig(..)`, `defaultFileConfig`, `loadFileConfig`
- `Seal.Vault.Backend`: `parseUnlockMode`, `resolveEncryptor`
- `Seal.Security.Vault`: `VaultConfig(..)`, `VaultHandle`, `openVault`
- `Seal.Vault.Commands`: `VaultRuntime(..)`, `vaultCommandSpec`
- `haskeline`: `runInputT`, `getInputLine`, `getPassword`, `Settings(..)`, `defaultSettings`, `noCompletion`

Produces:
```haskell
-- Seal.Channel.Cli
interpretDisposition :: ChannelCaps -> Disposition -> IO ()
runCliRepl           :: SealPaths -> Registry -> PreprocessChain -> IO ()

-- Seal.Repl
runRepl :: IO ()

-- Seal.Types.Command (extended)
data Command = ... | CommandRepl
```

#### Steps

- [ ] **Step 1: Register all new modules in cabal + `test/Main.hs`**

  `seal-harness.cabal` — `library` `exposed-modules:` additions:
  ```
        Seal.Channel.Cli
        Seal.Repl
  ```

  `seal-harness.cabal` — `test-suite tests` `other-modules:` addition:
  ```
        Seal.Channel.CliSpec
  ```

  `test/Main.hs` additions:
  ```haskell
  import qualified Seal.Channel.CliSpec
  -- inside hspec $ do:
    Seal.Channel.CliSpec.spec
  ```

- [ ] **Step 2: Add `CommandRepl` to `Seal.Types.Command`**

  Extend the ADT (strict bang on all payload-carrying constructors is already
  present; `CommandRepl` carries no payload so no bang needed):

  ```haskell
  data Command
    = CommandNoOp
    | CommandGreet !Text
    | CommandTick !Int
    | CommandRepl
    deriving (Eq, Show)
  ```

  Extend `pCommand`:

  ```haskell
  pCommand :: Parser Command
  pCommand = hsubparser
    $  command "greet" (info pGreet (progDesc "Greet someone"))
    <> command "tick"  (info pTick  (progDesc "Increment the tick counter N times"))
    <> command "repl"  (info (pure CommandRepl)
                             (progDesc "Start the interactive REPL"))
  ```

  Build immediately to get the -Werror RED signal for the unhandled case:

  ```
  nix develop --command cabal build all 2>&1 | tail -15
  ```

  Expected: compile error — `Seal.AppMain` has a non-exhaustive pattern on
  `Command` (the new `CommandRepl` constructor is unhandled). This is the RED.
  Fix in Step 5.

- [ ] **Step 3 (RED): Write `test/Seal/Channel/CliSpec.hs`**

  The test targets `interpretDisposition`, a pure-ish function that maps a
  `Disposition` to an `IO ()` through `ChannelCaps`.  The haskeline loop
  itself is interactive and left as a `pendingWith` smoke note.

  ```haskell
  {-# LANGUAGE OverloadedStrings #-}
  module Seal.Channel.CliSpec (spec) where

  import Data.IORef (modifyIORef', newIORef, readIORef)
  import Data.Text (Text)

  import Test.Hspec

  import Seal.Channel.Caps (ChannelCaps (..))
  import Seal.Channel.Cli (interpretDisposition)
  import Seal.Command.Spec (CommandAction (..))
  import Seal.Ingest (Disposition (..))

  -- | A 'ChannelCaps' that records every 'ccSend' call into @ref@ (prepended;
  -- reverse for chronological order).  Prompt functions return the empty string.
  recordingCaps :: IORef [Text] -> ChannelCaps
  recordingCaps ref = ChannelCaps
    { ccSend         = \t -> modifyIORef' ref (t :)
    , ccPrompt       = \_ -> pure ""
    , ccPromptSecret = \_ -> pure ""
    }

  spec :: Spec
  spec = do
    describe "interpretDisposition" $ do
      it "ShowText routes the text to ccSend" $ do
        ref <- newIORef []
        interpretDisposition (recordingCaps ref) (ShowText "hello world")
        sent <- readIORef ref
        sent `shouldBe` ["hello world"]

      it "PlainMessage emits the MVP stub message" $ do
        ref <- newIORef []
        interpretDisposition (recordingCaps ref) (PlainMessage "ignored text")
        sent <- readIORef ref
        sent `shouldBe` ["(no agent configured yet)"]

      it "Rejected emits the rejection message" $ do
        ref <- newIORef []
        interpretDisposition (recordingCaps ref) (Rejected "input blocked")
        sent <- readIORef ref
        sent `shouldBe` ["input blocked"]

      it "DispatchAction runs the action through caps" $ do
        ref <- newIORef []
        let caps   = recordingCaps ref
            action = CommandAction $ \c -> ccSend c "from action"
        interpretDisposition caps (DispatchAction action)
        sent <- readIORef ref
        sent `shouldBe` ["from action"]

    describe "seal repl smoke (interactive — manual)" $
      it "seal repl launches and shows the > prompt" $
        pendingWith
          "interactive: run `nix develop --command cabal run seal -- repl` \
          \and verify the '> ' prompt appears; Ctrl-D exits cleanly"
  ```

  Run to confirm RED (`Seal.Channel.Cli` does not exist yet):

  ```
  nix develop --command cabal test 2>&1 | tail -20
  ```

- [ ] **Step 4 (GREEN): Create `src/Seal/Channel/Cli.hs`**

  Design notes:
  - `interpretDisposition` is extracted from the loop so it can be tested in
    plain IO without a Haskeline context.
  - `ccSend` uses `putStrLn`.  During the REPL loop `liftIO` takes us out of
    `InputT IO` before `interpretDisposition` runs, so `putStrLn` and the next
    `getInputLine` do not interleave.
  - `ccPrompt` and `ccPromptSecret` open a fresh `runInputT` session.  This is
    safe because they are only called from inside a command action, i.e., after
    the outer `getInputLine` has already returned its line.
  - EOF (Ctrl-D) from `getInputLine` returns `Nothing`; the loop exits cleanly.

  ```haskell
  {-# LANGUAGE OverloadedStrings #-}
  -- | Haskeline-backed CLI REPL channel.
  module Seal.Channel.Cli
    ( runCliRepl
    , interpretDisposition
    ) where

  import Control.Monad.IO.Class (liftIO)
  import Data.Text (Text)
  import qualified Data.Text as T
  import System.FilePath ((</>))
  import System.Console.Haskeline
    ( InputT
    , Settings (..)
    , defaultSettings
    , getInputLine
    , getPassword
    , noCompletion
    , runInputT
    )

  import Seal.Channel.Caps (ChannelCaps (..))
  import Seal.Command.Spec (CommandAction (..), Registry)
  import Seal.Config.Paths (SealPaths (..))
  import Seal.Ingest (Disposition (..), PreprocessChain, RawInbound (..), ingest)

  -- | Map a 'Disposition' to its channel effect.
  --
  -- Extracted for testability: callers supply a 'ChannelCaps'; no Haskeline
  -- context is required.
  interpretDisposition :: ChannelCaps -> Disposition -> IO ()
  interpretDisposition caps = \case
    DispatchAction a -> runCommandAction a caps
    ShowText t       -> ccSend caps t
    PlainMessage _   -> ccSend caps "(no agent configured yet)"
    Rejected msg     -> ccSend caps msg

  -- | Run the Haskeline REPL loop.
  --
  -- History is persisted at @\<state\>\/history@.  EOF (Ctrl-D) exits.
  runCliRepl :: SealPaths -> Registry -> PreprocessChain -> IO ()
  runCliRepl paths registry chain =
    let histFile   = spState paths </> "history"
        innerSettings = defaultSettings { complete = noCompletion }
        hlSettings    = innerSettings   { historyFile = Just histFile }
        caps = ChannelCaps
          { ccSend         = \t -> putStrLn (T.unpack t)
          , ccPrompt       = \prompt ->
              runInputT innerSettings $ do
                mLine <- getInputLine (T.unpack prompt)
                pure (maybe "" T.pack mLine)
          , ccPromptSecret = \prompt ->
              runInputT innerSettings $ do
                mPass <- getPassword (Just '*') (T.unpack prompt)
                pure (maybe "" T.pack mPass)
          }
    in runInputT hlSettings (loop caps)
    where
      loop :: ChannelCaps -> InputT IO ()
      loop caps = do
        mLine <- getInputLine "> "
        case mLine of
          Nothing   -> pure ()   -- EOF / Ctrl-D
          Just line -> do
            d <- liftIO $ ingest registry chain (RawInbound (T.pack line))
            liftIO $ interpretDisposition caps d
            loop caps
  ```

  Run GREEN:

  ```
  nix develop --command cabal test 2>&1 | tail -30
  ```

  Expected: all four `interpretDisposition` tests pass; `pendingWith` test
  shows as pending (not failed); no regressions.

- [ ] **Step 5: Create `src/Seal/Repl.hs`**

  Wires: `getSealPaths` → `ensureSealDirs` → `loadFileConfig` →
  `tryOpenVault` (if recipient + identity configured) → `newIORef` →
  `VaultRuntime` → `mkRegistry [vaultCommandSpec rt]` → `runCliRepl`.

  Note: `VaultError` must have a `Show` instance (expected from Phase 1 given
  standard Haskell practice; confirm before building).

  ```haskell
  {-# LANGUAGE OverloadedStrings #-}
  -- | Top-level REPL entry: path resolution → config → vault → registry → loop.
  module Seal.Repl (runRepl) where

  import Data.IORef (newIORef)
  import Data.Maybe (fromMaybe)
  import qualified Data.Text as T

  import Seal.Channel.Cli (runCliRepl)
  import Seal.Command.Spec (mkRegistry)
  import Seal.Config.File (FileConfig (..), defaultFileConfig, loadFileConfig)
  import Seal.Config.Paths
    ( SealPaths
    , configFilePath
    , ensureSealDirs
    , getSealPaths
    , vaultFilePath
    )
  import Seal.Ingest (emptyChain)
  import Seal.Security.Vault (VaultConfig (..), VaultHandle, openVault)
  import Seal.Vault.Backend (parseUnlockMode, resolveEncryptor)
  import Seal.Vault.Commands (VaultRuntime (..), vaultCommandSpec)

  -- | Open the vault if both recipient and identity are configured.
  -- Failures print a warning and return 'Nothing' so the REPL still starts;
  -- vault commands will direct the user to run @\/vault setup@.
  tryOpenVault :: SealPaths -> FileConfig -> IO (Maybe VaultHandle)
  tryOpenVault paths cfg =
    case (fcVaultRecipient cfg, fcVaultIdentity cfg) of
      (Just _, Just _) ->
        resolveEncryptor cfg >>= \case
          Left err -> do
            putStrLn ("Warning: vault not available: " <> show err)
            pure Nothing
          Right enc -> do
            let vcfg = VaultConfig
                  { vcPath    = maybe (vaultFilePath paths) T.unpack
                                      (fcVaultPath cfg)
                  , vcKeyType = fromMaybe "x25519" (fcVaultKeyType cfg)
                  , vcUnlock  = parseUnlockMode (fcVaultUnlock cfg)
                  }
            Just <$> openVault vcfg enc
      _ -> pure Nothing

  -- | Full REPL wiring.
  runRepl :: IO ()
  runRepl = do
    paths <- getSealPaths
    ensureSealDirs paths
    let cfgPath = configFilePath paths
    cfg <- loadFileConfig cfgPath >>= \case
      Left err -> do
        putStrLn ("Warning: could not load config: " <> T.unpack err)
        pure defaultFileConfig
      Right c  -> pure c
    mHandle <- tryOpenVault paths cfg
    ref     <- newIORef mHandle
    let rt = VaultRuntime
              { vrPaths      = paths
              , vrConfigPath = cfgPath
              , vrHandleRef  = ref
              }
        registry = mkRegistry [vaultCommandSpec rt]
    runCliRepl paths registry emptyChain
  ```

  Build to confirm the module compiles and the `Seal.AppMain` incomplete-case
  error remains (it is fixed in Step 6):

  ```
  nix develop --command cabal build all 2>&1 | tail -15
  ```

- [ ] **Step 6: Update `Seal.AppMain` to dispatch `CommandRepl`**

  Add import (alongside the existing module imports):

  ```haskell
  import Control.Monad.IO.Class (liftIO)
  import qualified Seal.Repl
  ```

  Extend `dispatch` (full replacement):

  ```haskell
  dispatch :: Config -> IO ()
  dispatch cfg = do
    env <- mkEnv cfg
    runApp env $ case _config_command cfg of
      CommandNoOp    -> pure ()
      CommandGreet n -> greet n
      CommandTick n  -> tick n
      CommandRepl    -> liftIO Seal.Repl.runRepl
  ```

  `App` derives `MonadIO` (verified in `Seal.Types.App`), so `liftIO` is
  available without a separate import if `Control.Monad.IO.Class` is already
  re-exported — add the import if GHC complains.

  Full build + test:

  ```
  nix develop --command cabal build all 2>&1 | tail -15
  nix develop --command cabal test         2>&1 | tail -30
  ```

  Expected: builds cleanly (no incomplete-pattern error); all tests pass or
  show as pending.

- [ ] **Step 7: Manual smoke checks**

  **`seal --help` lists `repl`:**

  ```
  nix develop --command cabal run seal -- --help 2>&1
  ```

  Look for `repl` in the list of available subcommands.

  **`seal repl` enters the loop:**

  ```
  nix develop --command cabal run seal -- repl
  ```

  Verify: `> ` prompt appears; `/help` lists vault commands (or an empty
  registry if vault tasks 8–9 are not yet merged); `/vault status` responds
  rather than crashing; Ctrl-D exits without error.

  Both checks are covered by the `pendingWith` note in `Seal.Channel.CliSpec`;
  they are not automated because they require an interactive terminal.

- [ ] **Step 8: hlint**

  ```
  nix develop --command hlint \
      src/Seal/Channel/Cli.hs \
      src/Seal/Repl.hs \
      src/Seal/Types/Command.hs \
      src/Seal/AppMain.hs \
      test/Seal/Channel/CliSpec.hs
  ```

  Expected: no suggestions.

- [ ] **Step 9: Commit**

  ```
  git add seal-harness.cabal test/Main.hs \
      src/Seal/Channel/Cli.hs \
      src/Seal/Repl.hs \
      src/Seal/Types/Command.hs \
      src/Seal/AppMain.hs \
      test/Seal/Channel/CliSpec.hs
  git commit -m "$(cat <<'EOF'
  Add CLI REPL channel, Seal.Repl wiring, and `seal repl` subcommand

  Seal.Channel.Cli: haskeline InputT loop (history at <state>/history);
  interpretDisposition extracted for pure-ish unit testing via a recording
  ChannelCaps IORef.  ccPrompt/ccPromptSecret use nested runInputT sessions
  (safe: called only after the outer getInputLine has already returned).
  Seal.Repl: wires getSealPaths -> ensureSealDirs -> loadFileConfig ->
  tryOpenVault (opens vault if recipient+identity configured, warns otherwise)
  -> newIORef -> mkRegistry [vaultCommandSpec] -> runCliRepl emptyChain.
  Seal.Types.Command: adds CommandRepl + `repl` subcommand to pCommand.
  Seal.AppMain: dispatches CommandRepl via liftIO Seal.Repl.runRepl; App
  derives MonadIO so liftIO is always in scope.
  Tests: four interpretDisposition cases with recordingCaps; interactive
  haskeline loop and CLI smoke left as pendingWith notes.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

## Phase 2 MVP milestone check

Done when, in the Nix dev shell:

- `nix develop --command cabal build all` is `-Werror` clean (library + `seal` exe).
- `nix develop --command cabal test` is green and pristine, including: the
  tokenizer/parse/registry properties, the **discoverability invariant** (Task 4),
  the paths/modes assertions (Task 5, `keys/` 0700), `mkSafeKeyPath` confinement
  (Task 6), `config.toml` round-trip (Task 7), the vault command behaviours against
  the mock encryptor + fake `ChannelCaps` (Task 9), and `ingest` dispositions
  (Task 10). The real-`age` `setupLocalAgeKey` test runs when `age`/`age-keygen`
  are present and `pendingWith`-skips otherwise.
- `nix develop --command hlint src/ test/` reports `No hints`.
- Manual smoke: `nix develop --command cabal run seal -- repl`, then
  `/help`, `/vault --help`, `/vault setup`, `/vault add FOO`, `/vault get FOO`,
  `/vault list`, `/vault status`, `/vault lock`, `/vault unlock` all behave, with
  the vault written under `~/.seal/config/vault/vault.age` (or `$SEAL_HOME`).

Then: write the Phase 2b plan (web gateway + frontend) or the next-phase plan
before continuing, and update the roadmap/slash-command spec channel-priority note.

## Self-Review & implementer notes

Surfaced during plan self-review — soft spots an executor/reviewer should know:

1. **Discoverability test (Task 4)** enforces help via an explicit `knownOptions`
   table co-located with the test specs: it fails the build if any listed command
   isn't in `/help` or any listed option stops appearing in that command's help.
   It does **not** auto-discover *new* options (optparse offers no clean parser
   introspection), so adding an option means adding a row. Strengthening to full
   introspection (or a `--bash-completion`-derived enumeration) is a follow-up,
   tracked under the completion-readiness work.
2. **Tasks 8 & 9** begin with a compile-skeleton step (module stubs with
   `undefined` for not-yet-built functions + a trivial passing test to confirm the
   module compiles and is wired into cabal/`test/Main.hs`) before per-function TDD.
   That scaffolding step is fine, but **each function must still be driven by a
   real failing test before it is implemented** — do not let the skeleton's
   passing test stand in for behaviour tests.
3. **`Disposition`** intentionally has no `Show` instance (it carries a
   `CommandAction` function); tests describe it via a small shape helper.
4. **`tomland` combinators (Task 7)** are written against the standard documented
   API (`Toml.text`, `Toml.dioptional`, `Toml.encode`, `Toml.decode`, `(.=)`); if
   the flake-pinned version differs, adjust to the available names (the codec
   shape is what matters).
5. **`unix`** must be in the test-suite `build-depends` (Task 0 / first used in
   Task 5) for the mode/owner assertions.
6. **YubiKey setup (Task 8)** captures `age-plugin-yubikey --generate` stdout when
   possible and falls back to an interactive "run this, press Enter" prompt if the
   plugin needs a TTY; the fallback path is not unit-tested (needs the hardware).
