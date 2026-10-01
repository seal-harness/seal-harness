# BROWSER_MANAGE Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Replace the stub `BROWSER_*` opcodes with a single consolidated `BROWSER_MANAGE` opcode that shells out to the `agent-browser` CLI (github.com/vercel-labs/agent-browser) for all browser automation.

**Architecture:** `BROWSER_MANAGE` is an Untrusted opcode following the established `_MANAGE` family pattern (action-based dispatch, consolidated entry point, legacy shims hidden from the model catalog). All browser IO flows through `uioBinExec` — the existing `UntrustedIO` capability seam for spawning named binaries with validated argv. The opcode module never imports `System.Process`; it calls `uioBinExec` with `BinName "agent-browser"` and `[BinArg]` constructed from agent-supplied input via smart constructors. agent-browser manages its own daemon + Chromium lifecycle; Seal Harness treats it as a black-box CLI that returns text or JSON on stdout.

**Tech Stack:** Haskell (GHC2021, GHC 9.12), aeson, hspec + QuickCheck, agent-browser CLI (npm, Apache-2.0)

---

## Design Decisions

### Why BROWSER_MANAGE instead of separate opcodes?

The `_MANAGE` pattern (PROCESS_MANAGE, SKILL_MANAGE, AGENT_MANAGE, SESSION_MANAGE, etc.) is the established convention. A single action-based opcode:
- Minimizes tool-definition tokens — one schema entry instead of N
- Keeps the ISA closed set stable — new browser actions extend the action enum, not the opcode count
- Matches the agent-browser CLI's own command-dispatch model (one binary, many subcommands)

### Why uioBinExec instead of a new UntrustedIO method?

agent-browser is a named binary with argv — exactly what `uioBinExec` is designed for. The validated `BinName`/`BinArg` newtypes (Invariant 2) already provide option-injection defense. No new `UntrustedIO` method is needed; the existing capability surface is sufficient. This is the same pattern BIN_EXEC uses.

### Action surface

The agent-browser CLI has a large command surface. We expose the core workflow actions that an AI agent needs, mapping each to an agent-browser subcommand:

| Action | agent-browser command | Purpose |
|--------|----------------------|---------|
| `open` | `open <url>` | Launch browser + navigate to URL |
| `snapshot` | `snapshot -i` | Accessibility tree with interactive element refs |
| `click` | `click <ref>` | Click element by ref (@eN) or CSS selector |
| `fill` | `fill <ref> <text>` | Clear + fill input |
| `type` | `type <ref> <text>` | Type into element |
| `press` | `press <key>` | Press keyboard key |
| `scroll` | `scroll <dir>` | Scroll page (up/down/left/right) |
| `read` | `read [url]` | Fetch agent-readable text (no Chrome needed for URL; active-tab DOM without) |
| `screenshot` | `screenshot [path]` | Capture screenshot |
| `eval` | `eval <js>` | Run JavaScript in page |
| `wait` | `wait <selector>` or `wait --text <text>` | Wait for condition |
| `close` | `close` | Close browser session |
| `session` | `session list` or `session` | List active sessions or show current |

### Token efficiency

- The `BROWSER_MANAGE` description is ~15 tokens: "Manage browser automation via agent-browser CLI. Use action to select: open, snapshot, click, fill, type, press, scroll, read, screenshot, eval, wait, close, session."
- The input schema lists each action's required fields with short descriptions — no per-action opcode schemas.
- The `--json` flag is always passed so output is structured and machine-parseable (the opcode renders agent-browser's stdout verbatim as TrpText).
- `snapshot` output (the accessibility tree) is the primary token consumer; agent-browser's `-i` flag limits it to interactive elements only, and `--max-output` (passed via `--` separator) bounds the output.

### Security

- **Untrusted opcode** — runs on the untrusted plane, ACK-before-execute.
- **Validated argv** — URL, selector, ref, text, and JS all go through `mkBinArg` (rejects NUL, not empty). URLs and refs are `BinArg` values, never raw `Text` in argv.
- **No shell** — `uioBinExec` uses `System.Process.proc` (RawCommand), so argv tokens are never interpreted by a shell.
- **Autonomy gate** — `Deny` autonomy level blocks all browser actions (same as PROCESS_MANAGE).
- **Domain allow-list** — operator-configured via `config.yaml` (future: passed as `--allowed-domains` to agent-browser). V1 does not implement this; the operator controls agent-browser access at the binary level (don't install it if you don't want browser automation).

### Session isolation

agent-browser supports `--session <name>` for isolated browser sessions. The opcode accepts an optional `session` field on every action. If omitted, agent-browser uses its default session. This lets the agent maintain multiple browser contexts (e.g., one for authenticated sites, one for anonymous browsing).

### What about the existing BrowserDriver abstraction?

The existing `Seal.Web.Browser` module has a `BrowserDriver` record with `bdOpen`/`bdClick`/`bdRead` fields and a `noBrowserDriver` fail-closed default. This abstraction was designed for a future Playwright driver. We're replacing it entirely because:
1. agent-browser is the driver — we don't need a pluggable interface for a single implementation.
2. The `BrowserDriver` record's 3-field surface (open/click/read) is too narrow for agent-browser's 15+ commands.
3. The `_MANAGE` pattern doesn't need a driver record — the action enum IS the dispatch mechanism.

### What about remote mode?

In `mode=remote`, `uioBinExec` runs the binary on the remote machine via SSH. agent-browser must be installed on the remote machine. The operator is responsible for installing it (`npm install -g agent-browser && agent-browser install`). If the binary is not found, `uioBinExec` returns `UeExec ExecNotImplemented` which the opcode renders as an error.

---

## Task Breakdown

### Task 1: Create the BROWSER_MANAGE opcode module

**Objective:** Create `src/Seal/ISA/Ops/Browser.hs` with the `BROWSER_MANAGE` opcode using the `_MANAGE` pattern.

**Files:**
- Create: `src/Seal/ISA/Ops/Browser.hs`
- Modify: `seal-harness.cabal` (add `Seal.ISA.Ops.Browser` to `exposed-modules`)
- Test: `test/Seal/ISA/Ops/BrowserSpec.hs`

**Step 1: Write failing test for authorize gate**

Create `test/Seal/ISA/Ops/BrowserSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.BrowserSpec (spec) where

import Data.Aeson (object, (.=))
import Test.Hspec

import Seal.ISA.Opcode (uoAuthorize)
import Seal.ISA.Ops.Browser (browserManageOp)
import Seal.Security.Policy (SecurityPolicy (..), AutonomyLevel (..))
import Seal.Core.AllowList (AllowList (..))
import Data.Set qualified as Set

testPolicy :: SecurityPolicy
testPolicy = SecurityPolicy (AllowOnly Set.empty) Full

denyPolicy :: SecurityPolicy
denyPolicy = SecurityPolicy (AllowOnly Set.empty) Deny

spec :: Spec
spec = describe "BROWSER_MANAGE opcode" $ do

  describe "authorize gate" $ do
    it "accepts open action with url" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("open" :: String), "url" .= ("https://example.com" :: String)])
        `shouldBe` Right ()
    it "rejects open action without url" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("open" :: String)])
        `shouldBe` Left "BROWSER_MANAGE: open requires {url:string}"
    it "rejects open action with empty url" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("open" :: String), "url" .= ("" :: String)])
        `shouldBe` Left "BROWSER_MANAGE: url is empty"
    it "rejects unknown action" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("frobnicate" :: String)])
        `shouldBe` Left "BROWSER_MANAGE: unknown action \"frobnicate\""
    it "rejects missing action" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object [])
        `shouldBe` Left "BROWSER_MANAGE requires {action:string}"
    it "rejects all actions when autonomy is Deny" $ do
      let op = browserManageOp denyPolicy
      uoAuthorize op (object ["action" .= ("open" :: String), "url" .= ("https://example.com" :: String)])
        `shouldBe` Left "BROWSER_MANAGE denied by autonomy policy"
    it "accepts click action with ref" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("click" :: String), "ref" .= ("@e1" :: String)])
        `shouldBe` Right ()
    it "rejects click action without ref or selector" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("click" :: String)])
        `shouldBe` Left "BROWSER_MANAGE: click requires {ref:string} or {selector:string}"
    it "accepts fill action with ref and text" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("fill" :: String), "ref" .= ("@e1" :: String), "text" .= ("hello" :: String)])
        `shouldBe` Right ()
    it "rejects fill action without text" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("fill" :: String), "ref" .= ("@e1" :: String)])
        `shouldBe` Left "BROWSER_MANAGE: fill requires {text:string}"
    it "accepts close action with no extra fields" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("close" :: String)])
        `shouldBe` Right ()
    it "accepts snapshot action with no extra fields" $ do
      let op = browserManageOp testPolicy
      uoAuthorize op (object ["action" .= ("snapshot" :: String)])
        `shouldBe` Right ()
```

**Step 2: Run test to verify failure**

Run: `nix develop --command cabal test --test-options='-m "BROWSER_MANAGE"' 2>&1 | head -30`
Expected: FAIL — module not found / import error.

**Step 3: Implement the opcode module**

Create `src/Seal/ISA/Ops/Browser.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | BROWSER_MANAGE (Untrusted): consolidated action-based entry point for
-- all browser automation via the @agent-browser@ CLI
-- (<https://github.com/vercel-labs/agent-browser>). The opcode shells out
-- to @agent-browser@ via 'uioBinExec' — the existing 'UntrustedIO' capability
-- seam for named binaries with validated argv. This module never imports
-- 'System.Process'; all IO goes through the capability handle.
--
-- agent-browser manages its own daemon + Chromium lifecycle. Seal Harness
-- treats it as a black-box CLI that returns text or JSON on stdout. The
-- @--json@ flag is always passed so output is structured. The @--max-output@
-- flag bounds the response size (operator-configurable, default 15000 chars).
module Seal.ISA.Ops.Browser
  ( browserManageOp
  , BrowserAction (..)
  , parseBrowserAction
  , buildBrowserArgs
  ) where

import Data.Aeson (Value, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Key (fromText)
import Data.Aeson.Types (parseMaybe)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Seal.Core.Types (OpName (..))
import Seal.ISA.Opcode
import Seal.Providers.Class (ToolResultPart (..))
import Seal.Security.Policy (SecurityPolicy (..), AutonomyLevel (..))
import Seal.Tools.Args (BinArg, BinName, mkBinArg, mkBinName, textBinArg)
import Seal.Tools.Exec.UIO
  ( UntrustedErr (..), renderUntrustedErr, uioBinExec )

-- | The action enum — discriminates between browser operations.
data BrowserAction
  = BaOpen      Text    -- ^ url
  | BaSnapshot
  | BaClick     Text    -- ^ ref (@eN) or CSS selector
  | BaFill      Text Text  -- ^ ref/selector, text
  | BaType      Text Text  -- ^ ref/selector, text
  | BaPress     Text    -- ^ key (Enter, Tab, etc.)
  | BaScroll    Text    -- ^ direction (up/down/left/right)
  | BaRead      (Maybe Text)  -- ^ optional URL
  | BaScreenshot (Maybe Text) -- ^ optional path
  | BaEval      Text    -- ^ JavaScript
  | BaWait      Text    -- ^ selector or condition
  | BaClose
  | BaSession
  deriving stock (Eq, Show)

-- | The default max-output ceiling (characters). Operator-configurable
-- via config in a future task.
defaultMaxOutput :: Int
defaultMaxOutput = 15000

-- | BROWSER_MANAGE opcode. Input: @{ action: string, ...action-specific fields }@.
browserManageOp :: SecurityPolicy -> Opcode
browserManageOp policy = UntrustedOpcode
  { uoName = OpName "BROWSER_MANAGE"
  , uoDesc = "Browser automation via agent-browser CLI. Action: open (url), snapshot (interactive elements), click (ref/selector), fill (ref+text), type (ref+text), press (key), scroll (dir), read (url?), screenshot (path?), eval (js), wait (selector), close, session (list current)."
  , uoInSchema = browserManageSchema
  , uoOutSchema = object []
  , uoAuthorize = \v ->
      case parseBrowserAction v of
        Left e -> Left e
        Right _ -> checkAutonomy
  , uoRun = \v -> do
      let recorded = object [ "action" .= actionField v ]
      case parseBrowserAction v of
        Left e -> pure (OpResult [TrpText e] True recorded)
        Right action -> do
          let mSession = sessionField v
              maxOut = defaultMaxOutput
          case buildBrowserArgs action mSession maxOut of
            Left e -> pure (OpResult [TrpText e] True recorded)
            Right (binName, binArgs) -> do
              res <- uioBinExec binName binArgs Nothing
              pure $ case res of
                Left err -> OpResult [TrpText (renderUntrustedErr err)] True recorded
                Right out -> OpResult [TrpText out] False recorded
  }
  where
    checkAutonomy = case spAutonomy policy of
      Deny -> Left "BROWSER_MANAGE denied by autonomy policy"
      _    -> Right ()

-- | Parse the action + action-specific fields from the input JSON.
parseBrowserAction :: Value -> Either Text BrowserAction
parseBrowserAction v =
  case actionField v of
    Nothing -> Left "BROWSER_MANAGE requires {action:string}"
    Just a
      | a == "open"       -> BaOpen <$> requireField v "url"
      | a == "snapshot"   -> Right BaSnapshot
      | a == "click"      -> BaClick <$> refOrSelector v
      | a == "fill"       -> BaFill <$> refOrSelector v <*> requireField v "text"
      | a == "type"       -> BaType <$> refOrSelector v <*> requireField v "text"
      | a == "press"      -> BaPress <$> requireField v "key"
      | a == "scroll"     -> BaScroll <$> requireField v "dir"
      | a == "read"       -> Right (BaRead (optionalField v "url"))
      | a == "screenshot" -> Right (BaScreenshot (optionalField v "path"))
      | a == "eval"       -> BaEval <$> requireField v "js"
      | a == "wait"       -> BaWait <$> requireField v "selector"
      | a == "close"      -> Right BaClose
      | a == "session"    -> Right BaSession
      | otherwise         -> Left ("BROWSER_MANAGE: unknown action \"" <> a <> "\"")

-- | Build the agent-browser argv from the parsed action.
-- Returns (binary name, argv args) or an error if a BinArg fails validation.
buildBrowserArgs :: BrowserAction -> Maybe Text -> Int
                -> Either Text (BinName, [BinArg])
buildBrowserArgs action mSession maxOut = do
  binName <- mkBinName "agent-browser" `either` Right
  -- Always pass --json for structured output, and --max-output to bound response.
  baseArgs <- toBinArgs
    ([ "--json"
     , "--max-output"
     , T.pack (show maxOut)
     ] ++ sessionArgs)
  cmdArgs <- actionArgs
  Right (binName, baseArgs ++ cmdArgs)
  where
    sessionArgs = case mSession of
      Just s -> ["--session", s]
      Nothing -> []
    -- Convert a list of Text to [BinArg], collecting validation errors.
    toBinArgs :: [Text] -> Either Text [BinArg]
    toBinArgs = foldr step (Right [])
      where
        step t acc = case (mkBinArg t, acc) of
          (Left e, _) -> Left e
          (_, Left e) -> Left e
          (Right a, Right as) -> Right (a : as)
    actionArgs :: Either Text [BinArg]
    actionArgs = case action of
      BaOpen url       -> toBinArgs ["open", url]
      BaSnapshot       -> toBinArgs ["snapshot", "-i"]
      BaClick ref      -> toBinArgs ["click", ref]
      BaFill ref text  -> toBinArgs ["fill", ref, text]
      BaType ref text  -> toBinArgs ["type", ref, text]
      BaPress key      -> toBinArgs ["press", key]
      BaScroll dir     -> toBinArgs ["scroll", dir]
      BaRead mUrl      -> toBinArgs $ case mUrl of
                           Just url -> ["read", url]
                           Nothing  -> ["read"]
      BaScreenshot mPath -> toBinArgs $ case mPath of
                           Just path -> ["screenshot", path]
                           Nothing   -> ["screenshot"]
      BaEval js        -> toBinArgs ["eval", js]
      BaWait sel       -> toBinArgs ["wait", sel]
      BaClose          -> toBinArgs ["close"]
      BaSession        -> toBinArgs ["session", "list"]

-- | The input schema — a flat object with an action enum and action-specific
-- fields. All fields are optional except @action@; the authorize gate
-- validates per-action requirements.
browserManageSchema :: Value
browserManageSchema =
  object
    [ "type" .= ("object" :: Text)
    , "properties" .= object
        [ fromText "action" .= object
            [ "type" .= ("string" :: Text)
            , "enum" .= (actionEnum :: [Text])
            , "description" .= ("Browser operation to perform." :: Text)
            ]
        , fromText "url" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("URL to open or read (open, read)." :: Text)
            ]
        , fromText "ref" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("Element ref from snapshot, e.g. @e1 (click, fill, type)." :: Text)
            ]
        , fromText "selector" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("CSS selector (click, fill, type, wait — alternative to ref)." :: Text)
            ]
        , fromText "text" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("Text to fill or type (fill, type)." :: Text)
            ]
        , fromText "key" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("Key to press, e.g. Enter, Tab, Control+a (press)." :: Text)
            ]
        , fromText "dir" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("Scroll direction: up, down, left, right (scroll)." :: Text)
            ]
        , fromText "path" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("File path for screenshot output (screenshot)." :: Text)
            ]
        , fromText "js" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("JavaScript to evaluate in page (eval)." :: Text)
            ]
        , fromText "selector" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("Wait target: CSS selector or --text value (wait)." :: Text)
            ]
        , fromText "session" .= object
            [ "type" .= ("string" :: Text)
            , "description" .= ("agent-browser session name for isolation. Optional; defaults to the agent-browser default session." :: Text)
            ]
        ]
    , "required" .= (["action"] :: [Text])
    ]
  where
    actionEnum =
      [ "open", "snapshot", "click", "fill", "type", "press"
      , "scroll", "read", "screenshot", "eval", "wait", "close", "session"
      ]

-- ── Field accessors ──────────────────────────────────────────────────────

actionField :: Value -> Maybe Text
actionField = parseMaybe (withObject "in" (.: "action"))

sessionField :: Value -> Maybe Text
sessionField = parseMaybe (withObject "in" (.:? "session"))

requireField :: Value -> Text -> Either Text Text
requireField v field =
  case parseMaybe (withObject "in" (.: field)) v of
    Nothing -> Left ("BROWSER_MANAGE: " <> field <> " requires {" <> field <> ":string}")
    Just s
      | T.null s -> Left ("BROWSER_MANAGE: " <> field <> " is empty")
      | otherwise -> Right s

optionalField :: Value -> Text -> Maybe Text
optionalField v field =
  parseMaybe (withObject "in" (.:? field)) v >>= \case
    Just s | not (T.null s) -> Just s
    _ -> Nothing

-- | Get the ref or selector for click/fill/type actions.
refOrSelector :: Value -> Either Text Text
refOrSelector v =
  case optionalField v "ref" of
    Just r -> Right r
    Nothing -> case optionalField v "selector" of
      Just s -> Right s
      Nothing -> Left "BROWSER_MANAGE: click requires {ref:string} or {selector:string}"
```

**Step 4: Add to cabal file**

In `seal-harness.cabal`, add `Seal.ISA.Ops.Browser` to the library `exposed-modules:` list (after `Seal.ISA.Ops.Process`):

```
         Seal.ISA.Ops.Process
         Seal.ISA.Ops.Browser
```

Add `Seal.ISA.Ops.BrowserSpec` to the test-suite `other-modules:` list (after `Seal.ISA.Ops.ProcessSpec`):

```
         Seal.ISA.Ops.ProcessSpec
         Seal.ISA.Ops.BrowserSpec
```

**Step 5: Wire into test/Main.hs**

In `test/Main.hs`, add:

```haskell
import qualified Seal.ISA.Ops.BrowserSpec
```
(after the `Seal.ISA.Ops.ProcessSpec` import)

And in the `tests` list:

```haskell
  Seal.ISA.Ops.BrowserSpec.spec
```
(after `Seal.ISA.Ops.ProcessSpec.spec`)

**Step 6: Run tests to verify pass**

Run: `nix develop --command cabal test --test-options='-m "BROWSER_MANAGE"' 2>&1 | head -30`
Expected: PASS — all authorize gate tests pass.

**Step 7: Run lint**

Run: `nix develop --command hlint src/Seal/ISA/Ops/Browser.hs test/Seal/ISA/Ops/BrowserSpec.hs`
Expected: No hints.

**Step 8: Commit**

```bash
git add src/Seal/ISA/Ops/Browser.hs test/Seal/ISA/Ops/BrowserSpec.hs seal-harness.cabal test/Main.hs
git commit -m "feat: add BROWSER_MANAGE opcode (authorize gate + action parsing)"
```

---

### Task 2: Add buildBrowserArgs unit tests

**Objective:** Test the argv construction logic — correct argument ordering, BinArg validation, session injection.

**Files:**
- Modify: `test/Seal/ISA/Ops/BrowserSpec.hs`

**Step 1: Write failing tests for buildBrowserArgs**

Append to the spec in `test/Seal/ISA/Ops/BrowserSpec.hs`:

```haskell
  describe "buildBrowserArgs" $ do
    it "builds open args with url" $ do
      let result = buildBrowserArgs (BaOpen "https://example.com") Nothing 15000
      case result of
        Right (_, args) -> do
          map textBinArg args `shouldContain` ["open", "https://example.com"]
          map textBinArg args `shouldContain` ["--json"]
        Left e -> expectationFailure (T.unpack e)
    it "builds snapshot args with -i flag" $ do
      let result = buildBrowserArgs BaSnapshot Nothing 15000
      case result of
        Right (_, args) -> map textBinArg args `shouldContain` ["snapshot", "-i"]
        Left e -> expectationFailure (T.unpack e)
    it "builds click args with ref" $ do
      let result = buildBrowserArgs (BaClick "@e1") Nothing 15000
      case result of
        Right (_, args) -> map textBinArg args `shouldContain` ["click", "@e1"]
        Left e -> expectationFailure (T.unpack e)
    it "builds fill args with ref and text" $ do
      let result = buildBrowserArgs (BaFill "@e1" "hello world") Nothing 15000
      case result of
        Right (_, args) -> map textBinArg args `shouldContain` ["fill", "@e1", "hello world"]
        Left e -> expectationFailure (T.unpack e)
    it "injects --session when session is provided" $ do
      let result = buildBrowserArgs (BaOpen "https://example.com") (Just "my-session") 15000
      case result of
        Right (_, args) -> map textBinArg args `shouldContain` ["--session", "my-session"]
        Left e -> expectationFailure (T.unpack e)
    it "omits --session when no session is provided" $ do
      let result = buildBrowserArgs BaSnapshot Nothing 15000
      case result of
        Right (_, args) -> map textBinArg args `shouldNotContain` ["--session"]
        Left e -> expectationFailure (T.unpack e)
    it "includes --max-output with the configured value" $ do
      let result = buildBrowserArgs BaSnapshot Nothing 5000
      case result of
        Right (_, args) -> map textBinArg args `shouldContain` ["--max-output", "5000"]
        Left e -> expectationFailure (T.unpack e)
```

Add imports at top:

```haskell
import Seal.ISA.Ops.Browser (browserManageOp, BrowserAction (..), buildBrowserArgs)
import Seal.Tools.Args (textBinArg)
import Data.Text qualified as T
```

**Step 2: Run tests to verify pass**

Run: `nix develop --command cabal test --test-options='-m "BROWSER_MANAGE"' 2>&1 | head -30`
Expected: PASS — all buildBrowserArgs tests pass.

**Step 3: Commit**

```bash
git add test/Seal/ISA/Ops/BrowserSpec.hs
git commit -m "test: add buildBrowserArgs unit tests for BROWSER_MANAGE"
```

---

### Task 3: Wire BROWSER_MANAGE into the TurnEngine registry

**Objective:** Register `BROWSER_MANAGE` in `buildSessionRegistry`, add it to `knownOpNames`, and hide the legacy `BROWSER_*` opcodes.

**Files:**
- Modify: `src/Seal/Core/TurnEngine.hs`
- Modify: `src/Seal/ISA/Ops/Agent.hs` (knownOpNames)

**Step 1: Add import and register opcode in TurnEngine**

In `src/Seal/Core/TurnEngine.hs`:

Add import (after `import Seal.ISA.Ops.Process (processManageOp)`):

```haskell
import Seal.ISA.Ops.Browser (browserManageOp)
```

In `buildSessionRegistry`, add after `processManageOp wsRoot securityPolicy` in the `baseOps` list:

```haskell
      , browserManageOp securityPolicy
```

Add `"BROWSER_MANAGE"` to the `legacyHidden` set (it's not legacy, but we add the old opcodes there if we keep them — actually, we're replacing the old opcodes entirely, so we just add BROWSER_MANAGE to the visible ops and remove references to the old ones).

**Step 2: Update knownOpNames in Agent.hs**

In `src/Seal/ISA/Ops/Agent.hs`, add `"BROWSER_MANAGE"` to the `knownOpNames` list:

```haskell
  , "WEB_FETCH", "WEB_SEARCH"
  , "BROWSER_MANAGE"
```

**Step 3: Remove old browser opcode imports from IntegrationSpec**

In `test/Seal/ISA/IntegrationSpec.hs`, replace:

```haskell
import Seal.Web.Browser (browserClickOp, browserOpenOp, browserReadOp,
                         noBrowserDriver)
```

with:

```haskell
import Seal.ISA.Ops.Browser (browserManageOp)
```

And update any tests that reference `browserOpenOp`/`browserClickOp`/`browserReadOp` to use `browserManageOp` instead. The IntegrationSpec tests for the old browser opcodes were testing the fail-closed behavior — replace them with BROWSER_MANAGE authorize-gate tests (which are already covered in BrowserSpec, so the IntegrationSpec references can simply be removed).

**Step 4: Build and run full test suite**

Run: `nix develop --command cabal build 2>&1 | tail -20`
Expected: Build succeeds with no errors.

Run: `nix develop --command cabal test 2>&1 | tail -30`
Expected: All tests pass.

**Step 5: Run lint**

Run: `nix develop --command hlint src/Seal/Core/TurnEngine.hs src/Seal/ISA/Ops/Browser.hs`
Expected: No hints.

**Step 6: Commit**

```bash
git add src/Seal/Core/TurnEngine.hs src/Seal/ISA/Ops/Agent.hs test/Seal/ISA/IntegrationSpec.hs
git commit -m "feat: wire BROWSER_MANAGE into TurnEngine registry + knownOpNames"
```

---

### Task 4: Replace the old Seal.Web.Browser module

**Objective:** The old `Seal.Web.Browser` module with its `BrowserDriver`/`noBrowserDriver`/`browserOpenOp`/`browserClickOp`/`browserReadOp` is now superseded. Remove it and its test, and clean up cabal entries.

**Files:**
- Delete: `src/Seal/Web/Browser.hs`
- Delete: `test/Seal/Web/BrowserSpec.hs`
- Modify: `seal-harness.cabal` (remove `Seal.Web.Browser` from exposed-modules and `Seal.Web.BrowserSpec` from other-modules)
- Modify: `test/Main.hs` (remove `Seal.Web.BrowserSpec` import and spec entry)

**Step 1: Remove the old module files**

```bash
rm src/Seal/Web/Browser.hs test/Seal/Web/BrowserSpec.hs
```

**Step 2: Update cabal file**

In `seal-harness.cabal`, remove the line `Seal.Web.Browser` from the library `exposed-modules` and `Seal.Web.BrowserSpec` from the test-suite `other-modules`.

**Step 3: Update test/Main.hs**

Remove:
```haskell
import qualified Seal.Web.BrowserSpec
```
and:
```haskell
  Seal.Web.BrowserSpec.spec
```

**Step 4: Build and test**

Run: `nix develop --command cabal build 2>&1 | tail -20`
Expected: Build succeeds — no remaining references to `Seal.Web.Browser`.

Run: `nix develop --command cabal test 2>&1 | tail -30`
Expected: All tests pass.

**Step 5: Commit**

```bash
git add -A
git commit -m "refactor: remove superseded Seal.Web.Browser stub module"
```

---

### Task 5: Add the uoRun stub test for fail-closed behavior

**Objective:** Test that BROWSER_MANAGE renders a meaningful error when agent-browser is not installed (the `uioBinExec` returns `UeExec ExecNotImplemented`).

**Files:**
- Modify: `test/Seal/ISA/Ops/BrowserSpec.hs`

**Step 1: Write failing test for run with stub UIO**

Add to `test/Seal/ISA/Ops/BrowserSpec.hs`:

```haskell
  describe "run (stub UIO — no agent-browser installed)" $ do
    it "returns error for open action when binary not found" $ do
      let op = browserManageOp testPolicy
          input = object ["action" .= ("open" :: String), "url" .= ("https://example.com" :: String)]
      result <- runUIOWithEnv (mkTestUIOEnv mkRemoteUntrustedIOStub undefined) (uoRun op input)
      orIsError result `shouldBe` True
```

This requires importing:
```haskell
import Seal.Tools.Exec.UIO (runUIOWithEnv, mkTestUIOEnv)
import Seal.Tools.Exec.UntrustedIO (mkRemoteUntrustedIOStub)
import Seal.Tools.Exec.Clone (emptyCloneDeps)  -- or whatever the stub CloneDeps is
import Seal.ISA.Opcode (OpResult (..))
```

Note: the exact import for a stub `CloneDeps` may vary — check how existing tests in `IntegrationSpec.hs` construct their `UIOEnv`. The key assertion is that `orIsError` is `True` and the error message mentions "exec error" or "not implemented".

**Step 2: Run tests to verify pass**

Run: `nix develop --command cabal test --test-options='-m "BROWSER_MANAGE"' 2>&1 | head -30`
Expected: PASS.

**Step 3: Commit**

```bash
git add test/Seal/ISA/Ops/BrowserSpec.hs
git commit -m "test: add BROWSER_MANAGE fail-closed run test"
```

---

### Task 6: Add BROWSER_MANAGE to the system prompt opcode list

**Objective:** The system prompt that tells the agent what opcodes are available needs to mention BROWSER_MANAGE. Check if there's a hardcoded opcode list in the prompt generation.

**Files:**
- Modify: wherever the system prompt lists available opcodes (check `src/Seal/Agent/` or `src/Seal/Gateway/` for prompt generation)

**Step 1: Find the system prompt opcode list**

```bash
rg -l 'BROWSER_OPEN\|WEB_FETCH\|SHELL_EXEC' src/Seal/Agent/ src/Seal/Gateway/ --type hs
```

If the prompt lists opcodes by name, add `BROWSER_MANAGE` with a brief description. If the prompt dynamically reads from the registry, no change is needed.

**Step 2: Build and test**

Run: `nix develop --command cabal build 2>&1 | tail -20`
Run: `nix develop --command cabal test 2>&1 | tail -30`
Expected: All pass.

**Step 3: Commit**

```bash
git add -A
git commit -m "docs: add BROWSER_MANAGE to system prompt opcode list"
```

---

### Task 7: Full check + final commit

**Objective:** Run the complete local gate (`make check`) and ensure everything passes.

**Step 1: Run make check**

```bash
nix develop --command make check 2>&1 | tail -40
```

Expected: build + test + lint all pass.

**Step 2: Fix any remaining issues**

If hlint or the build surfaces warnings, fix them. Common issues:
- Unused imports (remove them)
- Missing `{-# LANGUAGE OverloadedStrings #-}` pragmas
- Record field naming convention violations

**Step 3: Final commit if any fixes were needed**

```bash
git add -A
git commit -m "fix: address lint/build feedback from make check"
```

---

## Future Work (out of scope for this plan)

1. **Domain allow-list** — operator-configured `--allowed-domains` passed to agent-browser. Requires a config field + plumbing through the opcode.
2. **Configurable max-output** — read `defaultMaxOutput` from `config.yaml` instead of hardcoding 15000.
3. **Screenshot handling** — screenshots produce image files. A future task could add a `TrpImage` tool result part so the model sees the screenshot inline (requires vision support in the provider).
4. **Session lifecycle management** — explicit session creation/destruction via `--session` naming conventions, auto-cleanup on session end.
5. **Remote mode install check** — `hermes setup` equivalent that checks for agent-browser on the untrusted plane and installs it if missing.
6. **Batch action** — expose agent-browser's `batch` command for multi-step browser workflows in a single opcode call (reduces round-trips).
7. **Cloud provider support** — agent-browser supports Browserbase, Browser Use, Kernel, AgentCore cloud providers via `--provider`. A config field could select the provider and pass API keys from the vault.