# Spine Probe Commands (Phase 3, M4) Implementation Plan

> **⚠️ CANCELLED (2026-07-03) — retained as a planning record; NOT implemented.**
> This milestone was built and then fully reverted. Operator `/`-commands for the
> spine opcodes proved unnecessary: the model already reaches SHOW_HUMAN,
> ASK_HUMAN, FILE_READ, and SECRET_GET as **tool calls** (they were registered in
> the ISA registry before M4); secrets are managed through the `/vault` command
> family; and SHOW/ASK are the model talking *to* the human, not the reverse. No
> code from the tasks below is in the tree — the four opcodes remain
> tool-call-only. The design doc's M4 section is updated to match.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add four `/`-commands — `/show <text>`, `/ask <text>`, `/read <path>`, `/secret <name>` — that let the operator drive the SHOW_HUMAN / ASK_HUMAN / FILE_READ / SECRET_GET opcodes on demand through the *existing* ISA dispatcher (ACK-before-execute preserved for the Untrusted `/read`).

**Architecture:** A new `Seal.Command.Spine` module carries a `SpineRuntime` (the ISA opcode registry + transcript handle + backend + app `Env`) and a `dispatchSpine` helper that runs one opcode through `Seal.ISA.Dispatch.dispatch` inside `runApp` and renders the `OpResult` to the channel. It exposes `spineCommandSpecs :: SpineRuntime -> [CommandSpec]` — four `GroupSpine` specs. The command registry is presently assembled in `Seal.Tui` *before* the ISA machinery exists (that is built inside `Seal.Channel.Cli.runCliTui`'s `withTranscript` block), so the spine specs are appended to the registry there, where `isaReg`, `tHandle`, `localBackend`, and `appEnv` are all in scope. Because the ISA opcodes already close over the live `ChannelCaps`, driving them from a command reuses the exact same opcodes plain chat uses — one code path, no duplication.

**Tech Stack:** Haskell (GHC2021), `aeson`, `optparse-applicative`, `hspec`. Build/test via `cabal` inside the Nix dev shell.

## Global Constraints

- **Warnings are errors.** The `common settings` stanza sets `-Wall -Werror -Wcompat -Widentities -Wincomplete-uni-patterns -Wincomplete-record-updates -Wname-shadowing -Wpartial-fields -Wredundant-constraints`. Every task must build clean: no unused binds/imports (prefix intentionally-unused args with `_`), no partial-field accessors as bare functions, no incomplete patterns. This stanza applies to the **test-suite too**, so `-Wincomplete-uni-patterns` fires on `let Just x = …` / `let Right x = …` in tests — never write those; use `case`/`maybe`/a total helper.
- **Default extensions** (already on, do not re-declare): `DeriveGeneric DerivingStrategies LambdaCase ScopedTypeVariables`. Add `{-# LANGUAGE OverloadedStrings #-}` per-module where needed. `LambdaCase` is on — a bare `\case` needs no pragma.
- **Secrets discipline.** `/secret <name>` intentionally displays a vault value to the operator who asked for it (that is the probe's purpose). The value still flows only through the opcode's `orParts` and is **never** written to the transcript (the opcode's `orRecorded` carries the key name only). Do not add any new serialization of secret bytes.
- **Error convention:** `Either Text` / render `DispatchError` via `show`. No new error ADT.
- **Clean-room:** no reference to any prior/other implementation in code, identifiers, comments, docs, or commit messages.
- **Cabal registration:** new library modules go in `seal-harness.cabal` `exposed-modules`, new test specs in `other-modules`, both in **alphabetical order**; new test specs are wired into `test/Main.hs` (import + call).
- **Commits:** one per task;
- **Build/test commands** (prefix with `nix develop --command` if not already in the dev shell):
  - Build: `cabal build all`
  - Full test: `cabal test`
  - Focused test: `cabal test --test-options='--match "<needle>"'`
  - hlint: `hlint src/ test/`

---

## File Structure

- **`src/Seal/Command/Spec.hs`** (modify) — add the `GroupSpine` constructor to `CommandGroup`.
- **`src/Seal/Command/Help.hs`** (modify) — add the `groupHeader GroupSpine = "Spine"` case (the function is total; omitting it is a `-Werror` incomplete-patterns failure).
- **`src/Seal/Command/Spine.hs`** (create) — `SpineRuntime`, `dispatchSpine`, `renderSpineResult`, `spineCommandSpecs`.
- **`src/Seal/Channel/Cli.hs`** (modify) — build a `SpineRuntime` inside `withTranscript`, append the spine specs to the registry, thread the augmented registry into the input loop.
- **Tests:** `test/Seal/Command/HelpSpec.hs` (modify), `test/Seal/Command/SpineSpec.hs` (create), `test/Seal/Channel/CliSpec.hs` (modify).

---

## Task 1: `GroupSpine` command group + `/help` "Spine" header

Add the `GroupSpine` constructor and its help-index header. These two edits must land together: adding the constructor without the `groupHeader` case breaks the `-Werror` build.

**Files:**
- Modify: `src/Seal/Command/Spec.hs`
- Modify: `src/Seal/Command/Help.hs`
- Test: `test/Seal/Command/HelpSpec.hs`

**Interfaces:**
- Produces: `GroupSpine :: CommandGroup` (a new nullary constructor); `groupHeader GroupSpine = "Spine"` (internal to `Help.hs`, exercised via `renderHelpIndex`).

- [ ] **Step 1: Write the failing test**

In `test/Seal/Command/HelpSpec.hs`, add a self-contained `describe` block at the end of `spec` (it uses its own tiny registry so it does not disturb the existing `testRegistry` ordering assertions):

```haskell
  -- -------------------------------------------------------------------------
  describe "GroupSpine rendering" $ do
    let spineStub = CommandSpec
          { csName         = CommandName "show"
          , csAliases      = []
          , csGroup        = GroupSpine
          , csSynopsis     = "Show text to the human"
          , csParserInfo   = info (pure (CommandAction $ \caps -> ccSend caps "shown"))
                                  (progDesc "Drive SHOW_HUMAN")
          , csAvailability = InteractiveOnly
          }
        spineReg = mkRegistry [spineStub]

    it "renders a 'Spine' group header" $
      T.isInfixOf "Spine" (renderHelpIndex spineReg) `shouldBe` True

    it "lists the /show command under it" $
      T.isInfixOf "show" (renderHelpIndex spineReg) `shouldBe` True
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cabal test --test-options='--match "GroupSpine rendering"'`
Expected: FAIL to compile — `GroupSpine` not in scope (data constructor missing).

- [ ] **Step 3: Add the constructor and the header case**

In `src/Seal/Command/Spec.hs`, extend `CommandGroup` (place `GroupSpine` after `GroupModel`, before `GroupVault`, so the derived `Ord` — which drives help-index group order — reads General, Providers, Sessions, Model, Spine, Vault):

```haskell
data CommandGroup
  = GroupGeneral
  | GroupProvider
  | GroupSession
  | GroupModel
  | GroupSpine
  | GroupVault
  deriving stock (Eq, Ord, Show, Enum, Bounded)
```

In `src/Seal/Command/Help.hs`, add the matching case to `groupHeader` (after the `GroupModel` line):

```haskell
    groupHeader GroupModel    = "Model"
    groupHeader GroupSpine    = "Spine"
    groupHeader GroupVault    = "Vault"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cabal test --test-options='--match "GroupSpine rendering"'`
Expected: PASS (both examples green). Also confirm no regression in the wider Help suite:
Run: `cabal test --test-options='--match "Seal.Command.Help"'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/Seal/Command/Spec.hs src/Seal/Command/Help.hs test/Seal/Command/HelpSpec.hs
git commit -m "feat(command): add GroupSpine command group + /help header"
```

---

## Task 2: `Seal.Command.Spine` — runtime, dispatch helper, result rendering

Create the module with the `SpineRuntime` bundle, `dispatchSpine` (run one opcode through the real dispatcher and render its result), and `renderSpineResult`. No command specs yet (Task 3). Register the module + its test spec.

**Files:**
- Create: `src/Seal/Command/Spine.hs`
- Create: `test/Seal/Command/SpineSpec.hs`
- Modify: `seal-harness.cabal` (library `exposed-modules`; test `other-modules`)
- Modify: `test/Main.hs` (import + call)

**Interfaces:**
- Consumes: `Seal.ISA.Dispatch (DispatchError (..), dispatch)`, `Seal.ISA.Opcode (BackendExec, OpResult (..))`, `Seal.ISA.Registry` (qualified `ISA`), `Seal.Handles.Transcript (TranscriptHandle)`, `Seal.Types.App (runApp)`, `Seal.Types.Env (Env)`, `Seal.Channel.Caps (ChannelCaps (..))`, `Seal.Core.Types (OpName)`, `Seal.Providers.Class (ToolResultPart (..))`.
- Produces:
  - `data SpineRuntime = SpineRuntime { spOps :: ISA.Registry, spTranscript :: TranscriptHandle, spBackend :: BackendExec, spEnv :: Env }`
  - `dispatchSpine :: SpineRuntime -> ChannelCaps -> OpName -> Value -> IO ()`
  - `renderSpineResult :: ChannelCaps -> Either DispatchError OpResult -> IO ()`

- [ ] **Step 1: Create the module**

Create `src/Seal/Command/Spine.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | The @spine@ probe commands: operator-facing @/@-commands that drive the
-- core ISA opcodes (SHOW_HUMAN / ASK_HUMAN / FILE_READ / SECRET_GET) directly,
-- through the SAME dispatcher plain chat uses. ACK-before-execute is preserved
-- for the Untrusted @/read@ because dispatch itself enforces it — this module
-- adds no opcode logic, only a thin operator entry point.
module Seal.Command.Spine
  ( SpineRuntime (..)
  , dispatchSpine
  , renderSpineResult
  ) where

import Data.Aeson (Value)
import Data.Text qualified as T

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Core.Types (OpName)
import Seal.Handles.Transcript (TranscriptHandle)
import Seal.ISA.Dispatch (DispatchError, dispatch)
import Seal.ISA.Opcode (BackendExec, OpResult (..))
import Seal.ISA.Registry qualified as ISA
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Types.App (runApp)
import Seal.Types.Env (Env)

-- | Everything a spine command needs to drive one opcode: the ISA opcode set
-- (whose Human opcodes already close over the live 'ChannelCaps'), the
-- transcript handle, the execution backend, and the app 'Env' to run 'App' in.
data SpineRuntime = SpineRuntime
  { spOps        :: ISA.Registry
  , spTranscript :: TranscriptHandle
  , spBackend    :: BackendExec
  , spEnv        :: Env
  }

-- | Run @name@ with @input@ through the real dispatcher (so an Untrusted op is
-- ACK-durable before it runs), then render the result to the channel.
dispatchSpine :: SpineRuntime -> ChannelCaps -> OpName -> Value -> IO ()
dispatchSpine sp caps name input = do
  res <- runApp (spEnv sp)
           (dispatch (spOps sp) (spTranscript sp) (spBackend sp) name input)
  renderSpineResult caps res

-- | Render a dispatch outcome. A dispatch-level failure (unknown op / denied /
-- exec failed) is shown with an @error:@ prefix; otherwise each model-visible
-- text part is emitted as its own line. SHOW_HUMAN returns no parts (the opcode
-- already emitted the line), so a bare @/show@ prints nothing extra here.
renderSpineResult :: ChannelCaps -> Either DispatchError OpResult -> IO ()
renderSpineResult caps = \case
  Left e  -> ccSend caps ("error: " <> T.pack (show e))
  Right r -> mapM_ (\(TrpText t) -> ccSend caps t) (orParts r)
```

- [ ] **Step 2: Register the module + test spec**

In `seal-harness.cabal`, add to the library `exposed-modules` immediately after `Seal.Command.Spec` (line ~53):

```
        Seal.Command.Spine
```

Add to the test-suite `other-modules` immediately after `Seal.Command.SpecSpec` (line ~155):

```
        Seal.Command.SpineSpec
```

In `test/Main.hs`, add the import after `import qualified Seal.Command.SpecSpec` (line ~23):

```haskell
import qualified Seal.Command.SpineSpec
```

and the call after `Seal.Command.SpecSpec.spec` (line ~64):

```haskell
  Seal.Command.SpineSpec.spec
```

- [ ] **Step 3: Write the failing tests**

Create `test/Seal/Command/SpineSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.SpineSpec (spec) where

import Data.Aeson (object, (.=))
import Data.IORef (newIORef)
import Data.Text qualified as T
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps)
import Seal.Command.Spine
import Seal.Config.Paths (SealPaths (..))
import Seal.Core.Types (OpName (..))
import Seal.Handles.Transcript (TranscriptHandle (..))
import Seal.ISA.Dispatch (DispatchError (..))
import Seal.ISA.Opcode (localBackend)
import Seal.ISA.Ops.File (fileReadOp)
import Seal.ISA.Ops.Human (askHumanOp, showHumanOp)
import Seal.ISA.Ops.Secret (secretGetOp)
import Seal.ISA.Registry qualified as ISA
import Seal.Security.Path (WorkspaceRoot (..))
import Seal.TestHelpers.FakeCaps (getSent, makeFakeCaps)
import Seal.TestHelpers.FakeVault (makeFakeVault)
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (mkEnv)
import Seal.Vault.Commands (VaultRuntime (..))

-- A transcript handle that records nothing (spine tests assert on the channel,
-- not the log; dispatch's ACK ordering is covered by DispatchSpec).
noopTranscript :: TranscriptHandle
noopTranscript = TranscriptHandle
  { recordAndAck    = \_ -> pure ()
  , recordAsync     = \_ -> pure ()
  , closeTranscript = pure ()
  }

mkSpine :: ISA.Registry -> IO SpineRuntime
mkSpine reg = do
  env <- mkEnv defaultConfig
  pure SpineRuntime
    { spOps = reg, spTranscript = noopTranscript
    , spBackend = localBackend, spEnv = env }

-- A VaultRuntime over an in-memory fake vault. Paths are unused by SECRET_GET.
mkVaultRuntime :: [(T.Text, ByteStringAlias)] -> IO VaultRuntime
mkVaultRuntime seeded = do
  h   <- makeFakeVault seeded
  ref <- newIORef (Just h)
  pure VaultRuntime
    { vrPaths      = SealPaths "" "" "" ""
    , vrConfigPath = ""
    , vrHandleRef  = ref
    }

-- Local alias so the import list above stays minimal; ByteString comes from the
-- fake-vault seed literals via OverloadedStrings.
type ByteStringAlias = Data.ByteString.ByteString

spec :: Spec
spec = describe "Seal.Command.Spine" $ do

  describe "dispatchSpine" $ do
    it "SHOW_HUMAN emits the message" $ do
      (fc, caps) <- makeFakeCaps []
      sp <- mkSpine (ISA.mkRegistry [showHumanOp caps])
      dispatchSpine sp caps (OpName "SHOW_HUMAN")
        (object ["message" .= ("hi there" :: String)])
      getSent fc `shouldReturn` ["hi there"]

    it "ASK_HUMAN prompts and echoes the reply" $ do
      (fc, caps) <- makeFakeCaps ["blue"]
      sp <- mkSpine (ISA.mkRegistry [askHumanOp caps])
      dispatchSpine sp caps (OpName "ASK_HUMAN")
        (object ["question" .= ("color?" :: String)])
      getSent fc `shouldReturn` ["blue"]

    it "SECRET_GET returns the stored value" $ do
      (fc, caps) <- makeFakeCaps []
      rt <- mkVaultRuntime [("K", "s3cr3t")]
      sp <- mkSpine (ISA.mkRegistry [secretGetOp rt])
      dispatchSpine sp caps (OpName "SECRET_GET")
        (object ["name" .= ("K" :: String)])
      getSent fc `shouldReturn` ["s3cr3t"]

    it "FILE_READ returns the file contents" $
      withSystemTempDirectory "seal-spine-read" $ \dir -> do
        writeFile (dir </> "note.txt") "file body"
        (fc, caps) <- makeFakeCaps []
        sp <- mkSpine (ISA.mkRegistry [fileReadOp (WorkspaceRoot dir)])
        dispatchSpine sp caps (OpName "FILE_READ")
          (object ["path" .= ("note.txt" :: String)])
        getSent fc `shouldReturn` ["file body"]

  describe "renderSpineResult" $
    it "renders a dispatch error with an 'error:' prefix" $ do
      (fc, caps) <- makeFakeCaps []
      renderSpineResult caps (Left (OpNotFound (OpName "NOPE")))
      out <- getSent fc
      out `shouldSatisfy` any (T.isInfixOf "error:")
```

Add `import qualified Data.ByteString` to the spec's imports (used by the `ByteStringAlias` synonym). If the `type ByteStringAlias`/`import qualified Data.ByteString` indirection reads awkwardly, replace it by importing `Data.ByteString (ByteString)` directly and giving `mkVaultRuntime :: [(T.Text, ByteString)] -> IO VaultRuntime` — either is fine; keep it warning-clean and drop the alias.

- [ ] **Step 4: Run the tests to verify they fail**

Run: `cabal test --test-options='--match "Seal.Command.Spine"'`
Expected: FAIL — until Step 1's module exists the spec does not compile; once it does, the tests run.

- [ ] **Step 5: Build and run the tests to verify they pass**

Run: `cabal build all && cabal test --test-options='--match "Seal.Command.Spine"'`
Expected: PASS — all four `dispatchSpine` examples plus the `renderSpineResult` example green; build `-Werror` clean.

- [ ] **Step 6: Commit**

```bash
git add src/Seal/Command/Spine.hs test/Seal/Command/SpineSpec.hs seal-harness.cabal test/Main.hs
git commit -m "feat(spine): SpineRuntime + dispatchSpine over the real ISA dispatcher"
```

---

## Task 3: The four spine command specs (`/show`, `/ask`, `/read`, `/secret`)

Add `spineCommandSpecs` — four `GroupSpine`, `InteractiveOnly` command specs whose parsers build the opcode input JSON and drive it via `dispatchSpine`. `/show` and `/ask` accept free-text (one-or-more tokens, space-joined); `/read` and `/secret` take a single argument.

**Files:**
- Modify: `src/Seal/Command/Spine.hs`
- Test: `test/Seal/Command/SpineSpec.hs`

**Interfaces:**
- Consumes: `SpineRuntime`, `dispatchSpine` (Task 2); `Seal.Command.Spec (Availability (..), CommandAction (..), CommandGroup (..), CommandName (..), CommandSpec (..))`; `Options.Applicative`; `Control.Applicative (some)`; `Data.Aeson (object, (.=))`; `Data.Aeson.Key (fromText)`.
- Produces: `spineCommandSpecs :: SpineRuntime -> [CommandSpec]` (four specs, in the order show, ask, read, secret).

- [ ] **Step 1: Write the failing tests**

Append to `test/Seal/Command/SpineSpec.hs` a new `describe` block inside `spec`. Extend the imports first:

```haskell
import Data.List (find)
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure)
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..)
  , CommandName (..), CommandSpec (..) )
```

Add a total helper (no `let Just …`) near the top of the module, after `mkSpine`:

```haskell
-- Run @k@ with the named spec, or fail the example if it is absent.
withSpec :: T.Text -> [CommandSpec] -> (CommandSpec -> IO ()) -> IO ()
withSpec nm specs k =
  case find ((== CommandName nm) . csName) specs of
    Just s  -> k s
    Nothing -> expectationFailure ("no spine spec named " <> T.unpack nm)
```

Then the block:

```haskell
  describe "spineCommandSpecs" $ do
    it "registers show/ask/read/secret under GroupSpine, interactive-only" $ do
      sp <- mkSpine (ISA.mkRegistry [])
      let specs = spineCommandSpecs sp
      map csName specs `shouldBe`
        [ CommandName "show", CommandName "ask"
        , CommandName "read", CommandName "secret" ]
      all ((== GroupSpine) . csGroup) specs `shouldBe` True
      all ((== InteractiveOnly) . csAvailability) specs `shouldBe` True

    it "/show parses multi-word text and drives SHOW_HUMAN" $ do
      (fc, caps) <- makeFakeCaps []
      sp <- mkSpine (ISA.mkRegistry [showHumanOp caps])
      withSpec "show" (spineCommandSpecs sp) $ \s ->
        case execParserPure defaultPrefs (csParserInfo s) ["hello", "world"] of
          Success act -> runCommandAction act caps
          _           -> expectationFailure "expected a successful parse"
      getSent fc `shouldReturn` ["hello world"]

    it "/read parses a single path and drives FILE_READ" $
      withSystemTempDirectory "seal-spine-read2" $ \dir -> do
        writeFile (dir </> "a.txt") "body"
        (fc, caps) <- makeFakeCaps []
        sp <- mkSpine (ISA.mkRegistry [fileReadOp (WorkspaceRoot dir)])
        withSpec "read" (spineCommandSpecs sp) $ \s ->
          case execParserPure defaultPrefs (csParserInfo s) ["a.txt"] of
            Success act -> runCommandAction act caps
            _           -> expectationFailure "expected a successful parse"
        getSent fc `shouldReturn` ["body"]

    it "/show with no argument fails to parse" $ do
      sp <- mkSpine (ISA.mkRegistry [])
      withSpec "show" (spineCommandSpecs sp) $ \s ->
        case execParserPure defaultPrefs (csParserInfo s) [] of
          Success _ -> expectationFailure "expected a parse failure for empty /show"
          _         -> pure ()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cabal test --test-options='--match "spineCommandSpecs"'`
Expected: FAIL — `spineCommandSpecs` not in scope.

- [ ] **Step 3: Implement `spineCommandSpecs`**

In `src/Seal/Command/Spine.hs`, extend the export list:

```haskell
module Seal.Command.Spine
  ( SpineRuntime (..)
  , dispatchSpine
  , renderSpineResult
  , spineCommandSpecs
  ) where
```

Add imports:

```haskell
import Control.Applicative (some)
import Data.Aeson (Value, object, (.=))
import Data.Aeson.Key (fromText)
import Data.Text (Text)
import Options.Applicative

import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..)
  , CommandName (..), CommandSpec (..) )
import Seal.Core.Types (OpName (..))
```

> `Data.Aeson (Value)` is already imported from Task 2 — merge `object`/`(.=)` into that one line rather than duplicating it. `OpName` was imported unqualified in Task 2; widen it to `OpName (..)` only if you construct `OpName` here (you do: the parsers name each opcode) — a single `import Seal.Core.Types (OpName (..))` covers both uses.

Add the specs and their parsers at the end of the module:

```haskell
-- | The four operator probe commands, in display order.
spineCommandSpecs :: SpineRuntime -> [CommandSpec]
spineCommandSpecs sp =
  [ spineSpec "show"   "Show text to the human (SHOW_HUMAN opcode)"
      (textArg  "TEXT" "Text to display")
      (textParser sp (OpName "SHOW_HUMAN") "message")
  , spineSpec "ask"    "Ask the human a question (ASK_HUMAN opcode)"
      (textArg  "TEXT" "Question to ask")
      (textParser sp (OpName "ASK_HUMAN") "question")
  , spineSpec "read"   "Read a workspace file (FILE_READ opcode)"
      (oneArg   "PATH" "Workspace-relative path")
      (argParser sp "PATH" (OpName "FILE_READ") "path")
  , spineSpec "secret" "Fetch a vault secret by name (SECRET_GET opcode)"
      (oneArg   "NAME" "Vault key name")
      (argParser sp "NAME" (OpName "SECRET_GET") "name")
  ]
  where
    -- documentation-only metavar/help pairs, kept beside the specs for clarity
    textArg _ _ = ()
    oneArg  _ _ = ()

spineSpec :: Text -> Text -> () -> ParserInfo CommandAction -> CommandSpec
spineSpec name synopsis _doc pinfo = CommandSpec
  { csName         = CommandName name
  , csAliases      = []
  , csGroup        = GroupSpine
  , csSynopsis     = synopsis
  , csParserInfo   = pinfo
  , csAvailability = InteractiveOnly
  }

-- | Free-text parser: one-or-more tokens, space-joined, sent as JSON @field@.
textParser :: SpineRuntime -> OpName -> Text -> ParserInfo CommandAction
textParser sp name field =
  info (act <**> helper) (progDesc "Drive a spine opcode with free text")
  where
    act = build <$> some (strArgument (metavar "TEXT..."))
    build :: [String] -> CommandAction
    build ws = CommandAction $ \caps ->
      dispatchSpine sp caps name (singletonInput field (T.pack (unwords ws)))

-- | Single-argument parser: one token sent as JSON @field@.
argParser :: SpineRuntime -> String -> OpName -> Text -> ParserInfo CommandAction
argParser sp mv name field =
  info (act <**> helper) (progDesc "Drive a spine opcode with a single argument")
  where
    act = build <$> strArgument (metavar mv)
    build :: String -> CommandAction
    build s = CommandAction $ \caps ->
      dispatchSpine sp caps name (singletonInput field (T.pack s))

-- | @{ field: value }@ as an opcode input object.
singletonInput :: Text -> Text -> Value
singletonInput field value = object [fromText field .= value]
```

> The `textArg`/`oneArg`/`_doc` scaffolding above exists only so the spec list reads as a table; it carries no behavior. If it trips `-Wunused-matches` or reads as noise, delete the `where`, the `()` parameter of `spineSpec`, and the two `textArg`/`oneArg` arguments at the call sites — the four `spineSpec name synopsis parser` calls are equally clear. Ship whichever is warning-clean; do **not** leave dead bindings.

- [ ] **Step 4: Build and run the tests to verify they pass**

Run: `cabal build all && cabal test --test-options='--match "Seal.Command.Spine"'`
Expected: PASS — the `spineCommandSpecs` block (names/group/availability, `/show` multi-word, `/read` single-arg, empty-`/show` failure) and the Task-2 `dispatchSpine` block all green; build `-Werror` clean.

- [ ] **Step 5: Commit**

```bash
git add src/Seal/Command/Spine.hs test/Seal/Command/SpineSpec.hs
git commit -m "feat(spine): /show /ask /read /secret command specs"
```

---

## Task 4: Wire the spine commands into the live registry

Build a `SpineRuntime` inside `runCliTui`'s `withTranscript` block (where the ISA registry, transcript handle, backend, and app `Env` all exist) and append the spine specs to the command registry, threading the augmented registry into the input loop so `/help` lists them and the parser routes them.

**Files:**
- Modify: `src/Seal/Channel/Cli.hs`
- Test: `test/Seal/Channel/CliSpec.hs`

**Interfaces:**
- Consumes: `Seal.Command.Spine (SpineRuntime (..), spineCommandSpecs)`; `Seal.Command.Spec (mkRegistry, registrySpecs)`.
- Produces: `augmentWithSpine :: Registry -> SpineRuntime -> Registry` (exported from `Seal.Channel.Cli` so the wiring is unit-testable without Haskeline).

- [ ] **Step 1: Write the failing test**

In `test/Seal/Channel/CliSpec.hs`, add a `describe` block. Extend imports as needed (mirror the Spine spec's `mkSpine`-style construction; a `no-op` transcript and `mkEnv defaultConfig` are enough):

```haskell
  describe "augmentWithSpine" $
    it "appends /show /ask /read /secret to the base registry" $ do
      env <- mkEnv defaultConfig
      let sp = SpineRuntime
            { spOps        = ISA.mkRegistry []
            , spTranscript = TranscriptHandle
                               { recordAndAck = \_ -> pure ()
                               , recordAsync  = \_ -> pure ()
                               , closeTranscript = pure () }
            , spBackend    = localBackend
            , spEnv        = env
            }
          base = mkRegistry []
          full = augmentWithSpine base sp
      map csName (registrySpecs full) `shouldBe`
        [ CommandName "show", CommandName "ask"
        , CommandName "read", CommandName "secret" ]
```

Required imports for this test (add any not already present):

```haskell
import Seal.Channel.Cli (augmentWithSpine)
import Seal.Command.Spec (CommandName (..), CommandSpec (..), mkRegistry, registrySpecs)
import Seal.Command.Spine (SpineRuntime (..))
import Seal.Handles.Transcript (TranscriptHandle (..))
import Seal.ISA.Opcode (localBackend)
import Seal.ISA.Registry qualified as ISA
import Seal.Types.Config (defaultConfig)
import Seal.Types.Env (mkEnv)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cabal test --test-options='--match "augmentWithSpine"'`
Expected: FAIL — `augmentWithSpine` not in scope.

- [ ] **Step 3: Add `augmentWithSpine` and wire it in**

In `src/Seal/Channel/Cli.hs`, add to the export list:

```haskell
  , augmentWithSpine
```

Extend the `Seal.Command.Spec` import to bring in the registry helpers:

```haskell
import Seal.Command.Spec (CommandAction (..), Registry, mkRegistry, registrySpecs)
```

Add the new import:

```haskell
import Seal.Command.Spine (SpineRuntime (..), spineCommandSpecs)
```

Add the pure helper (near the other top-level helpers, e.g. after `mkSessionAgentEnv`):

```haskell
-- | Append the spine probe commands (@/show@, @/ask@, @/read@, @/secret@) to a
-- base command registry. Kept pure and exported so the wiring is unit-testable
-- without a live Haskeline loop.
augmentWithSpine :: Registry -> SpineRuntime -> Registry
augmentWithSpine base sp = mkRegistry (registrySpecs base <> spineCommandSpecs sp)
```

Now use it inside `runCliTui`. In the `withTranscript` block, after `isaReg` is bound and before `plainHandler`, build the `SpineRuntime` and the augmented registry:

```haskell
  withTranscript transcriptPath $ \tHandle -> do
    let isaReg = ISA.mkRegistry
          [ showHumanOp caps
          , askHumanOp caps
          , fileReadOp wsRoot
          , secretGetOp rt
          ]
        spineRt = SpineRuntime
          { spOps        = isaReg
          , spTranscript = tHandle
          , spBackend    = localBackend
          , spEnv        = appEnv
          }
        fullRegistry = augmentWithSpine registry spineRt
        plainHandler t = do
          meta  <- readIORef (srActive sr)
          eprov <- resolveSessionProvider pr meta
          case eprov of
            Left err            -> ccSend caps err
            Right (prov, model) ->
              handlePlain
                (mkSessionAgentEnv caps prov (smProvider meta) model (smId meta) isaReg tHandle)
                appEnv t
    runInputT hlSettings (loop fullRegistry caps plainHandler)
```

Change `loop` (in the `where` clause) to take the registry as its first argument and use it for `ingest`:

```haskell
    loop :: Registry -> ChannelCaps -> (Text -> IO ()) -> InputT IO ()
    loop reg caps plainHandler = do
      mLine <- getInputLine "> "
      case mLine of
        Nothing   -> pure ()   -- EOF / Ctrl-D
        Just line -> do
          d <- liftIO $ ingest reg chain (RawInbound (T.pack line))
          liftIO $ interpretDisposition caps plainHandler d
          loop reg caps plainHandler
```

> `chain` is still the top-level `runCliTui` parameter captured by the `where` clause — leave it as-is. Only `registry` becomes a `loop` argument (renamed `reg` inside) so the augmented registry is used. The original top-level `registry` parameter is still consumed (by `augmentWithSpine registry spineRt`), so it does not become an unused-binding warning.

- [ ] **Step 4: Build and run the test to verify it passes**

Run: `cabal build all && cabal test --test-options='--match "augmentWithSpine"'`
Expected: PASS. Confirm the surrounding channel suite still passes:
Run: `cabal test --test-options='--match "Seal.Channel"'`
Expected: PASS (no regression in `interpretDisposition`/`handlePlain` wiring tests).

- [ ] **Step 5: Commit**

```bash
git add src/Seal/Channel/Cli.hs test/Seal/Channel/CliSpec.hs
git commit -m "feat(spine): register /show /ask /read /secret in the live registry"
```

---

## Task 5: Full-suite verification + status note

Confirm the whole suite is green and the build is `-Werror`/hlint clean end-to-end, and record the milestone.

**Files:**
- Modify (optional): `README.md` or a phase-status doc — one-line M4 status.

- [ ] **Step 1: Run the entire suite and a clean build**

Run: `cabal build all && cabal test`
Expected: all examples pass (Ollama live example still `pending`); zero warnings (`-Werror`).

Run: `hlint src/ test/`
Expected: no hints. Fix any raised in the new module/test (common ones: prefer `<$>`, redundant `do`, `map`→`fmap`).

- [ ] **Step 2: Manual smoke (optional, exercises the milestone)**

```
cabal run seal -- tui
# in the REPL:
/help                 # shows a "Spine" group with /show /ask /read /secret
/show hello world     # prints: hello world
/ask what is your name?   # prompts, then echoes your reply
/read README.md       # prints the file contents (workspace-relative)
/vault unlock         # (if configured) then:
/secret ANTHROPIC_API_KEY   # prints the stored value
```

Expected: each command drives its opcode; `/read` on a path outside the workspace is rejected by `SafePath`. (Manual verification, not a gate.)

- [ ] **Step 3: Update the status note (optional)**

If `README.md` or a phase-status doc tracks milestone completion, add a line noting M4 (spine probe commands) is implemented.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore(spine): finalize M4 — full suite green"
```

---

## Self-Review

**Spec coverage** (M4 design → task):
- `/show <text>` → SHOW_HUMAN → Task 3 (`textParser`, `OpName "SHOW_HUMAN"`), driven via Task 2 `dispatchSpine`. ✅
- `/ask <text>` → ASK_HUMAN → Task 3 (`textParser`, `OpName "ASK_HUMAN"`). ✅
- `/read <path>` → FILE_READ, **Untrusted, ACK-before-execute preserved** → Task 3 (`argParser`, `OpName "FILE_READ"`) through the real `dispatch`, which enforces `recordAndAck` before run (unchanged; covered by `DispatchSpec`). ✅
- `/secret <name>` → SECRET_GET → Task 3 (`argParser`, `OpName "SECRET_GET"`); value shown to the requesting operator, never serialized (opcode `orRecorded` = key name only). ✅
- "through the existing dispatch" → Task 2 routes every spine command through `Seal.ISA.Dispatch.dispatch` with the same ISA registry plain chat uses; no opcode logic duplicated. ✅
- Discoverable via `/help` → Task 1 adds `GroupSpine` + header; Task 4 registers the four specs into the live registry so they appear in `renderHelpIndex` and per-command `/help`. ✅
- "Chat-driven tool calls continue to exercise the same opcodes indirectly" → unchanged; the ISA registry (`isaReg`) is shared by `mkSessionAgentEnv` (chat) and `SpineRuntime` (commands). ✅

**Placeholder scan:** No `TBD`/`TODO`. The only interim scaffolding is the `textArg`/`oneArg`/`()` table-alignment helpers in Task 3 Step 3, with an explicit instruction to delete them if they are not warning-clean — the shipped form is fully specified either way. The Task-2 `ByteStringAlias` synonym has an explicit "prefer the direct `ByteString` import" note. No `let Just …`/`let Right …` anywhere (global constraint; tests use the total `withSpec` helper and `case`).

**Type consistency:**
- `SpineRuntime` fields `spOps :: ISA.Registry`, `spTranscript :: TranscriptHandle`, `spBackend :: BackendExec`, `spEnv :: Env` — defined in Task 2, constructed identically in Task 2 tests, Task 3 tests, Task 4 wiring, and Task 4 test.
- `dispatchSpine :: SpineRuntime -> ChannelCaps -> OpName -> Value -> IO ()` — Task 2 def; called with that arity in Tasks 2/3 tests and inside the Task 3 parsers' `CommandAction`.
- `spineCommandSpecs :: SpineRuntime -> [CommandSpec]` — Task 3 def; consumed in Task 3 tests and `augmentWithSpine` (Task 4).
- `augmentWithSpine :: Registry -> SpineRuntime -> Registry` — Task 4 def (in `Seal.Channel.Cli`), exercised by the Task 4 test and called in `runCliTui`.
- `GroupSpine` — Task 1 constructor; used by `spineSpec` (Task 3) and the `groupHeader` case (Task 1).
- `renderSpineResult :: ChannelCaps -> Either DispatchError OpResult -> IO ()` — Task 2 def; `ToolResultPart`'s sole constructor `TrpText` makes the `mapM_` lambda total; `DispatchError` derives `Show` (used by the `error:` render and matched via `OpNotFound` in the Task 2 test).
- Command spec field names (`csName`, `csAliases`, `csGroup`, `csSynopsis`, `csParserInfo`, `csAvailability`) match `Seal.Command.Spec` exactly, mirroring `Seal.Command.Session`/`Seal.Command.Model`.
