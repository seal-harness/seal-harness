# Phase 3 — M2 (core): First-class sessions + `/session` & `/model`, chat uses the session's model

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make sessions first-class — each `seal repl` launch creates a session directory under `~/.seal/state/sessions/<id>/` with its own `session.json` + `transcript.jsonl`, holds a selected provider+model, and drives plain chat through that selection (replacing the hardcoded `ANTHROPIC_API_KEY`/pinned-model startup path).

**Architecture:** A new `Seal.Session.{Meta,Store}` layer owns the on-disk session format and lifecycle. A single mutable "active session" (`IORef SessionMeta`, wrapped in `SessionRuntime`) is created at startup and shared between the `/session` and `/model` command groups (which read/mutate + persist it) and the CLI plain-text handler (which resolves the session's provider via the M1 registry each turn and builds the per-turn `AgentEnv`). One transcript is opened per launch at the session's path via the existing bracket — no transcript-daemon changes.

**Tech Stack:** Haskell (GHC2021), hspec + QuickCheck, `optparse-applicative` command parsers, `aeson` (session.json), `Data.Time` (session-id timestamps), POSIX file modes for 0600/0700.

**Scope note / split from the design:** The design's M2 bullet lists `/session list|resume|info`. `/session resume` requires tearing down and re-opening the transcript writer mid-REPL (the daemon currently only shuts down via its startup bracket). To keep M2 the shortest path to a user-testable slice, **`/session resume` and the required `openTranscript`/`closeTranscript` refactor are deferred to a follow-on M2b plan.** This plan ships new-session-per-launch, `/session list|info`, `/model list|use`, and session-driven chat — all testable without touching the transcript lifecycle. `SessionMeta` is also trimmed to the fields these features use (id, provider, model, channel, created_at, last_active); `archived`/`description` land when a feature needs them.

## Global Constraints

- Language/build: **GHC2021**, `-Wall -Werror`, **hlint-clean**. Build/test inside the Nix dev shell: `nix develop -c cabal build`, `nix develop -c cabal test`, `nix develop -c hlint <files>`.
- Style: `deriving stock`; **post-positive qualified imports** (`import Data.Text qualified as T`); capability-handle pattern; no effect systems. Match the `/vault` and `/provider` command modules.
- Errors: **`Either Text`** by default; typed ADT only for control flow (none new here).
- Secrets: provider API keys stay opaque (`ApiKey`); never serialized, logged, or `Show`n. `session.json` holds only the provider **label** and model id — never a key.
- On-disk perms: session directory mode **0700**; `session.json` and `transcript.jsonl` mode **0600** (mirror the vault's tmp→chmod→rename atomic write).
- Session id format: **`YYYYMMDD-HHMMSS-mmm`** (millisecond-padded, timestamp-leading so lexicographic = chronological); must satisfy `Seal.Core.Types.isValidSessionId`.
- No manifest/index file — the session list is derived by enumerating `state/sessions/`.
- Clean-room: **no prior/reference runtime named** in code, comments, docs, or commit messages.
- TDD: failing test → fail → minimal impl → pass → commit. Each task ends green (`cabal build` + `cabal test`). Register new library modules in `seal-harness.cabal` `exposed-modules`; new specs in test-suite `other-modules` + `test/Main.hs`. One commit per task with trailer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Test-run: full `nix develop -c cabal test`; focused `nix develop -c cabal test --test-options='-m "<pattern>"'`.

**Consumes from M1 (already merged):** `Seal.Providers.Registry` — `KnownProvider (..)`, `knownProviders`, `parseProvider :: Text -> Maybe KnownProvider`, `providerLabel :: KnownProvider -> Text`, `defaultModelFor :: KnownProvider -> ModelId`, `resolveProvider :: VaultHandle -> Manager -> KnownProvider -> ModelId -> IO (Either Text SomeProvider)`; `Seal.Command.Provider` — `ProviderRuntime (..)` (`prConfigPath`, `prVault :: VaultRuntime`, `prManager :: Manager`); `Seal.Config.File` — `FileConfig (..)` incl. `fcDefaultProvider`/`fcDefaultModel`.

---

### Task 1: Session path helpers in `Seal.Config.Paths`

**Files:**
- Modify: `src/Seal/Config/Paths.hs`
- Test: `test/Seal/Config/PathsSpec.hs`

**Interfaces:**
- Consumes: `SealPaths (..)` (has `spState`); `SessionId`, `sessionIdText` from `Seal.Core.Types`.
- Produces: `sessionsRoot :: SealPaths -> FilePath`; `sessionDir :: SealPaths -> SessionId -> FilePath`; `sessionMetaPath :: SealPaths -> SessionId -> FilePath`; `sessionTranscriptPath :: SealPaths -> SessionId -> FilePath`.

- [ ] **Step 1: Write the failing test**

Add to `test/Seal/Config/PathsSpec.hs` inside the top-level `spec`:

```haskell
  describe "session paths" $ do
    it "derives sessions root, dir, meta and transcript paths under state/" $ do
      let paths = SealPaths
            { spHome = "/h", spConfig = "/h/config"
            , spState = "/h/state", spKeys = "/h/keys" }
          Right sid = mkSessionId "20260701-120000-042"
      sessionsRoot paths          `shouldBe` "/h/state/sessions"
      sessionDir paths sid        `shouldBe` "/h/state/sessions/20260701-120000-042"
      sessionMetaPath paths sid   `shouldBe` "/h/state/sessions/20260701-120000-042/session.json"
      sessionTranscriptPath paths sid `shouldBe` "/h/state/sessions/20260701-120000-042/transcript.jsonl"
```

Ensure these imports exist at the top of the file (add any missing):

```haskell
import Seal.Config.Paths
  ( SealPaths (..), sessionsRoot, sessionDir, sessionMetaPath, sessionTranscriptPath )
import Seal.Core.Types (mkSessionId)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nix develop -c cabal test --test-options='-m "session paths"'`
Expected: FAIL — `sessionsRoot`/`sessionDir`/… not in scope.

- [ ] **Step 3: Implement the helpers**

In `src/Seal/Config/Paths.hs`, extend the export list (after `vaultFilePath`):

```haskell
  , configFilePath
  , vaultFilePath
  , sessionsRoot
  , sessionDir
  , sessionMetaPath
  , sessionTranscriptPath
  ) where
```

Add imports:

```haskell
import Data.Text qualified as T

import Seal.Core.Types (SessionId, sessionIdText)
```

Append the helpers:

```haskell
-- | Root directory holding one subdirectory per session: @\<state\>\/sessions@.
sessionsRoot :: SealPaths -> FilePath
sessionsRoot paths = spState paths </> "sessions"

-- | Directory for one session: @\<state\>\/sessions\/\<id\>@.
sessionDir :: SealPaths -> SessionId -> FilePath
sessionDir paths sid = sessionsRoot paths </> T.unpack (sessionIdText sid)

-- | The session's metadata file: @\<sessionDir\>\/session.json@.
sessionMetaPath :: SealPaths -> SessionId -> FilePath
sessionMetaPath paths sid = sessionDir paths sid </> "session.json"

-- | The session's transcript: @\<sessionDir\>\/transcript.jsonl@.
sessionTranscriptPath :: SealPaths -> SessionId -> FilePath
sessionTranscriptPath paths sid = sessionDir paths sid </> "transcript.jsonl"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nix develop -c cabal test --test-options='-m "session paths"'`
Expected: PASS.

- [ ] **Step 5: Build clean + commit**

Run: `nix develop -c cabal build` (expected: clean with `-Werror`).

```bash
git add src/Seal/Config/Paths.hs test/Seal/Config/PathsSpec.hs
git commit -m "Add session path helpers to Seal.Config.Paths"
```

---

### Task 2: `Seal.Session.Meta` — the session metadata type + JSON

**Files:**
- Create: `src/Seal/Session/Meta.hs`
- Create: `test/Seal/Session/MetaSpec.hs`
- Modify: `seal-harness.cabal` (expose module + register spec)
- Modify: `test/Main.hs` (register spec)

**Interfaces:**
- Consumes: `SessionId` from `Seal.Core.Types`; `UTCTime` from `Data.Time`.
- Produces: `data SessionMeta = SessionMeta { smId :: SessionId, smProvider :: Text, smModel :: Text, smChannel :: Text, smCreatedAt :: UTCTime, smLastActive :: UTCTime }` deriving `stock (Eq, Show)`, with hand-written `ToJSON`/`FromJSON` using snake_case keys (`id`, `provider`, `model`, `channel`, `created_at`, `last_active`); `FromJSON` tolerant of a missing `channel` (defaults `"cli"`).

- [ ] **Step 1: Write the failing test**

Create `test/Seal/Session/MetaSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Seal.Session.MetaSpec (spec) where

import Data.Aeson (decode, encode, object, (.=))
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec

import Seal.Core.Types (mkSessionId, sessionIdText)
import Seal.Session.Meta (SessionMeta (..))

sampleTime :: UTCTime
sampleTime = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 43200)

sampleMeta :: SessionMeta
sampleMeta =
  let Right sid = mkSessionId "20260701-120000-042"
  in SessionMeta
       { smId = sid, smProvider = "anthropic", smModel = "claude-opus-4-8"
       , smChannel = "cli", smCreatedAt = sampleTime, smLastActive = sampleTime }

spec :: Spec
spec = describe "Seal.Session.Meta" $ do
  it "round-trips through JSON" $
    decode (encode sampleMeta) `shouldBe` Just sampleMeta

  it "uses snake_case keys and preserves the id text" $ do
    let m2 = decode (encode sampleMeta)
    fmap (sessionIdText . smId) m2 `shouldBe` Just "20260701-120000-042"

  it "defaults channel to \"cli\" when absent" $ do
    let j = object
              [ "id" .= ("20260701-120000-042" :: String)
              , "provider" .= ("anthropic" :: String)
              , "model" .= ("claude-opus-4-8" :: String)
              , "created_at" .= sampleTime
              , "last_active" .= sampleTime ]
    fmap smChannel (decode (encode j)) `shouldBe` Just "cli"
```

Register: add `import qualified Seal.Session.MetaSpec` and `Seal.Session.MetaSpec.spec` to `test/Main.hs`; add `Seal.Session.Meta` to the library `exposed-modules` and `Seal.Session.MetaSpec` to the test-suite `other-modules` in `seal-harness.cabal`.

- [ ] **Step 2: Run test to verify it fails**

Run: `nix develop -c cabal test --test-options='-m "Seal.Session.Meta"'`
Expected: FAIL — module `Seal.Session.Meta` not found.

- [ ] **Step 3: Create the module**

Create `src/Seal/Session/Meta.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | The on-disk session metadata record ('session.json'). Holds the session's
-- selected provider label + model id (never a key), its channel of origin, and
-- timestamps. The 'FromJSON' is tolerant (missing 'channel' defaults to "cli")
-- so older/partial files still load.
module Seal.Session.Meta
  ( SessionMeta (..)
  ) where

import Data.Aeson
  ( FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.!=), (.=) )
import Data.Text (Text)
import Data.Time (UTCTime)

import Seal.Core.Types (SessionId)

data SessionMeta = SessionMeta
  { smId         :: SessionId
  , smProvider   :: Text      -- ^ Provider label, e.g. @\"anthropic\"@.
  , smModel      :: Text      -- ^ Model id, e.g. @\"claude-opus-4-8\"@.
  , smChannel    :: Text      -- ^ Channel that created the session, e.g. @\"cli\"@.
  , smCreatedAt  :: UTCTime
  , smLastActive :: UTCTime
  } deriving stock (Eq, Show)

instance ToJSON SessionMeta where
  toJSON m = object
    [ "id"          .= smId m
    , "provider"    .= smProvider m
    , "model"       .= smModel m
    , "channel"     .= smChannel m
    , "created_at"  .= smCreatedAt m
    , "last_active" .= smLastActive m
    ]

instance FromJSON SessionMeta where
  parseJSON = withObject "SessionMeta" $ \o -> SessionMeta
    <$> o .:  "id"
    <*> o .:  "provider"
    <*> o .:  "model"
    <*> o .:? "channel" .!= "cli"
    <*> o .:  "created_at"
    <*> o .:  "last_active"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `nix develop -c cabal test --test-options='-m "Seal.Session.Meta"'`
Expected: PASS (3 examples).

- [ ] **Step 5: Build clean + commit**

Run: `nix develop -c cabal build`.

```bash
git add src/Seal/Session/Meta.hs test/Seal/Session/MetaSpec.hs test/Main.hs seal-harness.cabal
git commit -m "Add Seal.Session.Meta session metadata type + JSON codec"
```

---

### Task 3: `Seal.Session.Store` — session id, create, list, persist + runtime

**Files:**
- Create: `src/Seal/Session/Store.hs`
- Create: `test/Seal/Session/StoreSpec.hs`
- Modify: `seal-harness.cabal` (expose module + register spec)
- Modify: `test/Main.hs` (register spec)

**Interfaces:**
- Consumes: `SealPaths (..)`, `sessionDir`, `sessionMetaPath`, `sessionsRoot` (Task 1); `SessionMeta (..)` (Task 2); `mkSessionId`, `sessionIdText`, `isValidSessionId` from `Seal.Core.Types`; `FileConfig (..)`, `fcDefaultProvider`, `fcDefaultModel` from `Seal.Config.File`; `defaultModelFor`, `AnthropicProvider` from `Seal.Providers.Registry`; `ModelId (..)` from `Seal.Core.Types`.
- Produces:
  - `formatSessionId :: UTCTime -> Text` (pure; `YYYYMMDD-HHMMSS-mmm`)
  - `newSession :: SealPaths -> Text -> Text -> Text -> IO SessionMeta` (provider label, model, channel → creates dir 0700 + `session.json` 0600)
  - `saveSessionMeta :: SealPaths -> SessionMeta -> IO ()` (atomic 0600 write)
  - `listSessions :: SealPaths -> IO [SessionMeta]` (enumerate, decode, skip corrupt, sort by `smLastActive` desc)
  - `defaultSessionSelection :: FileConfig -> (Text, Text)` (provider label, model — from config, falling back to anthropic + its default model)
  - `initSession :: SealPaths -> FileConfig -> IO SessionMeta` (create a new session using the config defaults, channel `"cli"`)
  - `data SessionRuntime = SessionRuntime { srPaths :: SealPaths, srConfigPath :: FilePath, srActive :: IORef SessionMeta }`

- [ ] **Step 1: Write the failing tests**

Create `test/Seal/Session/StoreSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Seal.Session.StoreSpec (spec) where

import Control.Monad (forM_)
import Data.List (isPrefixOf)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus)
import Test.Hspec

import Seal.Config.File (defaultFileConfig, FileConfig (..))
import Seal.Config.Paths (SealPaths (..), sessionDir, sessionMetaPath)
import Seal.Core.Types (isValidSessionId, sessionIdText)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store
  ( defaultSessionSelection, formatSessionId, initSession, listSessions
  , newSession, saveSessionMeta )

mkPaths :: FilePath -> SealPaths
mkPaths root = SealPaths
  { spHome = root, spConfig = root </> "config"
  , spState = root </> "state", spKeys = root </> "keys" }

aTime :: UTCTime
aTime = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 43200)

spec :: Spec
spec = describe "Seal.Session.Store" $ do
  describe "formatSessionId" $ do
    it "formats as YYYYMMDD-HHMMSS-mmm and is a valid session id" $ do
      let t = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 43200 + 0.042)
      formatSessionId t `shouldBe` "20260701-120000-042"
      isValidSessionId (formatSessionId t) `shouldBe` True

  describe "newSession" $
    it "creates a 0700 dir with a 0600 session.json carrying the selection" $
      withSystemTempDirectory "seal-sess" $ \root -> do
        let paths = mkPaths root
        m <- newSession paths "anthropic" "claude-opus-4-8" "cli"
        smProvider m `shouldBe` "anthropic"
        smModel m    `shouldBe` "claude-opus-4-8"
        doesFileExist (sessionMetaPath paths (smId m)) >>= (`shouldBe` True)
        dirMode  <- fileMode <$> getFileStatus (sessionDir paths (smId m))
        metaMode <- fileMode <$> getFileStatus (sessionMetaPath paths (smId m))
        (dirMode  `mod` 0o1000) `shouldBe` 0o700
        (metaMode `mod` 0o1000) `shouldBe` 0o600

  describe "listSessions" $ do
    it "returns [] when no sessions exist" $
      withSystemTempDirectory "seal-sess" $ \root ->
        listSessions (mkPaths root) >>= (`shouldBe` [])

    it "lists saved sessions sorted by last_active descending, skipping corrupt" $
      withSystemTempDirectory "seal-sess" $ \root -> do
        let paths = mkPaths root
            mk idText la = do
              let Right sid = Seal.Core.Types.mkSessionId idText
              saveSessionMeta paths SessionMeta
                { smId = sid, smProvider = "anthropic", smModel = "m"
                , smChannel = "cli", smCreatedAt = aTime, smLastActive = la }
        mk "20260701-120000-001" aTime
        mk "20260701-120000-002" (aTime { utctDay = fromGregorian 2026 7 2 })
        -- a corrupt session dir is skipped
        let Right badSid = Seal.Core.Types.mkSessionId "20260701-120000-003"
        writeFile (sessionMetaPath paths badSid) "{ not json"
        metas <- listSessions paths
        map (sessionIdText . smId) metas
          `shouldBe` ["20260701-120000-002", "20260701-120000-001"]

  describe "defaultSessionSelection" $ do
    it "falls back to anthropic + its default model when config is empty" $
      defaultSessionSelection defaultFileConfig
        `shouldBe` ("anthropic", "claude-opus-4-8")

    it "honours configured defaults" $
      defaultSessionSelection defaultFileConfig
        { fcDefaultProvider = Just "ollama", fcDefaultModel = Just "llama3" }
        `shouldBe` ("ollama", "llama3")

  describe "initSession" $
    it "creates a session from the config defaults on the cli channel" $
      withSystemTempDirectory "seal-sess" $ \root -> do
        let paths = mkPaths root
        m <- initSession paths defaultFileConfig
        smProvider m `shouldBe` "anthropic"
        smModel m    `shouldBe` "claude-opus-4-8"
        smChannel m  `shouldBe` "cli"
        sessionIdText (smId m) `shouldSatisfy` ("2" `isPrefixOf`) . T.unpack
  where _ = forM_  -- silence unused-import if a later edit drops the only use
```

Add the missing imports the test references:

```haskell
import qualified Data.Text as T
import qualified Seal.Core.Types
```

(If `forM_`/the `where _ =` guard trips hlint, delete both — they are only there to keep the import list stable; prefer removing the unused import.)

Register `Seal.Session.Store` (library `exposed-modules`) and `Seal.Session.StoreSpec` (test-suite `other-modules` + `test/Main.hs`).

- [ ] **Step 2: Run tests to verify they fail**

Run: `nix develop -c cabal test --test-options='-m "Seal.Session.Store"'`
Expected: FAIL — module `Seal.Session.Store` not found.

- [ ] **Step 3: Create the module**

Create `src/Seal/Session/Store.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | Session lifecycle over the @\<state\>\/sessions@ tree: id minting, creation,
-- atomic persistence (dir 0700, session.json 0600), and listing (newest first,
-- corrupt files skipped). No manifest file — the list is derived by enumerating
-- the directory. 'SessionRuntime' bundles the mutable active-session ref shared
-- between the /session and /model commands and the chat handler.
module Seal.Session.Store
  ( formatSessionId
  , newSession
  , saveSessionMeta
  , listSessions
  , defaultSessionSelection
  , initSession
  , SessionRuntime (..)
  ) where

import Control.Monad (filterM, forM)
import Data.Aeson (decode, encode)
import Data.ByteString.Lazy qualified as BL
import Data.IORef (IORef)
import Data.List (sortOn)
import Data.Maybe (catMaybes, fromMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time
  ( UTCTime (..), defaultTimeLocale, diffTimeToPicoseconds, formatTime, getCurrentTime )
import System.Directory
  ( createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, renameFile )
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)

import Seal.Config.File (FileConfig (..))
import Seal.Config.Paths
  ( SealPaths, sessionDir, sessionMetaPath, sessionsRoot )
import Seal.Core.Types (ModelId (..), SessionId, mkSessionId)
import Seal.Providers.Registry (KnownProvider (..), defaultModelFor)
import Seal.Session.Meta (SessionMeta (..))

-- | The mutable active-session ref plus the paths the commands need.
data SessionRuntime = SessionRuntime
  { srPaths      :: SealPaths
  , srConfigPath :: FilePath
  , srActive     :: IORef SessionMeta
  }

-- | @YYYYMMDD-HHMMSS-mmm@. Timestamp-leading so a lexicographic sort of ids is
-- chronological; only digits and dashes, so it is a valid 'SessionId'.
formatSessionId :: UTCTime -> Text
formatSessionId t =
  let base   = formatTime defaultTimeLocale "%Y%m%d-%H%M%S" t
      millis = (diffTimeToPicoseconds (utctDayTime t) `div` 1000000000) `mod` 1000
      s      = show millis
      mmm    = replicate (3 - length s) '0' <> s
  in T.pack (base <> "-" <> mmm)

-- | Create a fresh session directory + session.json for the given selection.
newSession :: SealPaths -> Text -> Text -> Text -> IO SessionMeta
newSession paths provider model channel = do
  now <- getCurrentTime
  sid <- case mkSessionId (formatSessionId now) of
    Right s -> pure s
    Left e  -> ioError (userError ("session id generation failed: " <> T.unpack e))
  let meta = SessionMeta
        { smId = sid, smProvider = provider, smModel = model
        , smChannel = channel, smCreatedAt = now, smLastActive = now }
  saveSessionMeta paths meta
  pure meta

-- | Persist @session.json@ atomically: dir 0700, write @.tmp@, chmod 0600, rename.
saveSessionMeta :: SealPaths -> SessionMeta -> IO ()
saveSessionMeta paths meta = do
  let dir  = sessionDir paths (smId meta)
      path = sessionMetaPath paths (smId meta)
      tmp  = path <> ".tmp"
  createDirectoryIfMissing True dir
  setFileMode dir 0o700
  BL.writeFile tmp (encode meta)
  setFileMode tmp 0o600
  renameFile tmp path

-- | All sessions, newest 'smLastActive' first. Corrupt/undecodable session.json
-- files are silently skipped (a partial write never breaks the list).
listSessions :: SealPaths -> IO [SessionMeta]
listSessions paths = do
  let root = sessionsRoot paths
  exists <- doesDirectoryExist root
  if not exists
    then pure []
    else do
      entries <- listDirectory root
      dirs    <- filterM (doesDirectoryExist . (root </>)) entries
      metas   <- forM dirs $ \e -> do
        let mp = root </> e </> "session.json"
        ok <- doesFileExist mp
        if not ok then pure Nothing else decode <$> BL.readFile mp
      pure (sortOn (Down . smLastActive) (catMaybes metas))

-- | The provider label + model a new session should start with: the configured
-- defaults, falling back to Anthropic and its default model.
defaultSessionSelection :: FileConfig -> (Text, Text)
defaultSessionSelection cfg =
  ( fromMaybe "anthropic" (fcDefaultProvider cfg)
  , fromMaybe modelText (fcDefaultModel cfg) )
  where ModelId modelText = defaultModelFor AnthropicProvider

-- | Create a new session from the config defaults, on the @cli@ channel.
initSession :: SealPaths -> FileConfig -> IO SessionMeta
initSession paths cfg =
  let (p, m) = defaultSessionSelection cfg
  in newSession paths p m "cli"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `nix develop -c cabal test --test-options='-m "Seal.Session.Store"'`
Expected: PASS (all Store examples).

- [ ] **Step 5: Build clean + commit**

Run: `nix develop -c cabal build`.

```bash
git add src/Seal/Session/Store.hs test/Seal/Session/StoreSpec.hs test/Main.hs seal-harness.cabal
git commit -m "Add Seal.Session.Store: session id, create, list, persist + runtime"
```

---

### Task 4: `/session list|info` command group

**Files:**
- Modify: `src/Seal/Command/Spec.hs` (add `GroupSession`)
- Modify: `src/Seal/Command/Help.hs` (header for `GroupSession`)
- Create: `src/Seal/Command/Session.hs`
- Create: `test/Seal/Command/SessionSpec.hs`
- Modify: `seal-harness.cabal` + `test/Main.hs`

**Interfaces:**
- Consumes: `ChannelCaps (..)`; `CommandAction (..)`, `CommandGroup (..)`, `CommandName (..)`, `CommandSpec (..)`, `Availability (..)` from `Seal.Command.Spec`; `SessionRuntime (..)`, `listSessions` from `Seal.Session.Store`; `SessionMeta (..)` from `Seal.Session.Meta`; `sessionIdText` from `Seal.Core.Types`.
- Produces: `sessionCommandSpec :: SessionRuntime -> CommandSpec`; new `CommandGroup` constructor `GroupSession`; pure `renderSessionLine :: SessionId -> SessionMeta -> Text` and `renderSessionInfo :: SessionMeta -> [Text]`.

- [ ] **Step 1: Add the `GroupSession` group + its Help header**

In `src/Seal/Command/Spec.hs`, insert `GroupSession` between `GroupProvider` and `GroupVault`:

```haskell
data CommandGroup
  = GroupGeneral
  | GroupProvider
  | GroupSession
  | GroupVault
  deriving stock (Eq, Ord, Show, Enum, Bounded)
```

In `src/Seal/Command/Help.hs`, add the header case (keep `groupHeader` total):

```haskell
    groupHeader GroupGeneral  = "General"
    groupHeader GroupProvider = "Providers"
    groupHeader GroupSession  = "Sessions"
    groupHeader GroupVault    = "Vault"
```

- [ ] **Step 2: Write the failing test**

Create `test/Seal/Command/SessionSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.SessionSpec (spec) where

import Data.IORef (newIORef)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps)
import Seal.Command.Session (renderSessionInfo, renderSessionLine, sessionCommandSpec)
import Seal.Command.Spec (CommandSpec (..), runCommandAction)
import Seal.Config.Paths (SealPaths (..))
import Seal.Core.Types (mkSessionId, sessionIdText)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..), newSession)
import Seal.TestHelpers.FakeCaps (getSent, makeFakeCaps)

aTime :: UTCTime
aTime = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 43200)

meta :: T.Text -> SessionMeta
meta idText =
  let Right sid = mkSessionId idText
  in SessionMeta sid "anthropic" "claude-opus-4-8" "cli" aTime aTime

mkSR :: FilePath -> SessionMeta -> IO SessionRuntime
mkSR root active = do
  ref <- newIORef active
  let paths = SealPaths root (root </> "config") (root </> "state") (root </> "keys")
  pure SessionRuntime { srPaths = paths, srConfigPath = root </> "config.toml", srActive = ref }

runSess :: SessionRuntime -> [String] -> ChannelCaps -> IO ()
runSess sr argv caps =
  case execParserPure defaultPrefs (csParserInfo (sessionCommandSpec sr)) argv of
    Success act -> runCommandAction act caps
    _           -> expectationFailure ("parse failed: " <> show argv)

spec :: Spec
spec = describe "Seal.Command.Session" $ do
  describe "pure renderers" $ do
    it "marks the active session" $ do
      let Right active = mkSessionId "20260701-120000-002"
      renderSessionLine active (meta "20260701-120000-002")
        `shouldSatisfy` ("(active)" `T.isInfixOf`)
      renderSessionLine active (meta "20260701-120000-001")
        `shouldSatisfy` (not . ("(active)" `T.isInfixOf`))

    it "info includes id, provider and model" $ do
      let ls = T.unlines (renderSessionInfo (meta "20260701-120000-002"))
      ls `shouldSatisfy` ("20260701-120000-002" `T.isInfixOf`)
      ls `shouldSatisfy` ("anthropic" `T.isInfixOf`)
      ls `shouldSatisfy` ("claude-opus-4-8" `T.isInfixOf`)

  describe "/session commands" $ do
    it "list shows saved sessions" $
      withSystemTempDirectory "seal-sess" $ \root -> do
        sr <- mkSR root (meta "20260701-000000-000")
        _  <- newSession (srPaths sr) "anthropic" "claude-opus-4-8" "cli"
        (fc, caps) <- makeFakeCaps []
        runSess sr ["list"] caps
        sent <- getSent fc
        T.unlines sent `shouldSatisfy` ("anthropic" `T.isInfixOf`)

    it "info prints the active session" $
      withSystemTempDirectory "seal-sess" $ \root -> do
        sr <- mkSR root (meta "20260701-120000-009")
        (fc, caps) <- makeFakeCaps []
        runSess sr ["info"] caps
        sent <- getSent fc
        T.unlines sent `shouldSatisfy` ("20260701-120000-009" `T.isInfixOf`)
```

Register `Seal.Command.Session` (library `exposed-modules`) and `Seal.Command.SessionSpec` (test-suite + `test/Main.hs`).

- [ ] **Step 3: Run test to verify it fails**

Run: `nix develop -c cabal test --test-options='-m "Seal.Command.Session"'`
Expected: FAIL — module `Seal.Command.Session` not found.

- [ ] **Step 4: Create the module**

Create `src/Seal/Command/Session.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | The @/session@ command group: list sessions and show the active one.
-- (@/session resume@ is a follow-on milestone.)
module Seal.Command.Session
  ( sessionCommandSpec
  , renderSessionLine
  , renderSessionInfo
  ) where

import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..)
  , CommandName (..), CommandSpec (..) )
import Seal.Core.Types (SessionId, sessionIdText)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..), listSessions)
import Data.IORef (readIORef)

sessionCommandSpec :: SessionRuntime -> CommandSpec
sessionCommandSpec sr = CommandSpec
  { csName         = CommandName "session"
  , csAliases      = []
  , csGroup        = GroupSession
  , csSynopsis     = "List sessions and show the active one"
  , csParserInfo   = sessionParserInfo sr
  , csAvailability = InteractiveOnly
  }

sessionParserInfo :: SessionRuntime -> ParserInfo CommandAction
sessionParserInfo sr =
  info (sessionParser sr <**> helper)
    (  progDesc "Inspect chat sessions"
    <> header   "session — list sessions and show the active one"
    )

sessionParser :: SessionRuntime -> Parser CommandAction
sessionParser sr = hsubparser
  (  command "list"
       (info (pure (listCmd sr)) (progDesc "List all sessions (newest first)"))
  <> command "info"
       (info (pure (infoCmd sr)) (progDesc "Show the active session's details"))
  <> metavar "COMMAND"
  )

listCmd :: SessionRuntime -> CommandAction
listCmd sr = CommandAction $ \caps -> do
  active <- readIORef (srActive sr)
  metas  <- listSessions (srPaths sr)
  if null metas
    then ccSend caps "no sessions yet"
    else mapM_ (ccSend caps . renderSessionLine (smId active)) metas

infoCmd :: SessionRuntime -> CommandAction
infoCmd sr = CommandAction $ \caps -> do
  active <- readIORef (srActive sr)
  mapM_ (ccSend caps) (renderSessionInfo active)

-- | One line per session for @/session list@, marking the active one.
renderSessionLine :: SessionId -> SessionMeta -> Text
renderSessionLine active m =
  let mark = if smId m == active then "  (active)" else ""
  in sessionIdText (smId m)
       <> "  " <> smProvider m <> "/" <> smModel m
       <> "  " <> T.pack (show (smLastActive m)) <> mark

-- | Multi-line detail for @/session info@.
renderSessionInfo :: SessionMeta -> [Text]
renderSessionInfo m =
  [ "id:          " <> sessionIdText (smId m)
  , "provider:    " <> smProvider m
  , "model:       " <> smModel m
  , "channel:     " <> smChannel m
  , "created:     " <> T.pack (show (smCreatedAt m))
  , "last active: " <> T.pack (show (smLastActive m))
  ]
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `nix develop -c cabal test --test-options='-m "Seal.Command.Session"'`
Expected: PASS.

- [ ] **Step 6: Build clean + commit**

Run: `nix develop -c cabal build`.

```bash
git add src/Seal/Command/Spec.hs src/Seal/Command/Help.hs src/Seal/Command/Session.hs \
        test/Seal/Command/SessionSpec.hs test/Main.hs seal-harness.cabal
git commit -m "Add /session list|info command group"
```

---

### Task 5: `/model list|use` command group

**Files:**
- Modify: `src/Seal/Command/Spec.hs` (add `GroupModel`)
- Modify: `src/Seal/Command/Help.hs` (header for `GroupModel`)
- Create: `src/Seal/Command/Model.hs`
- Create: `test/Seal/Command/ModelSpec.hs`
- Modify: `seal-harness.cabal` + `test/Main.hs`

**Interfaces:**
- Consumes: `ChannelCaps (..)`; the `Seal.Command.Spec` command types; `SessionRuntime (..)`, `saveSessionMeta` from `Seal.Session.Store`; `SessionMeta (..)` from `Seal.Session.Meta`; `KnownProvider`, `knownProviders`, `parseProvider`, `providerLabel`, `defaultModelFor` from `Seal.Providers.Registry`; `ModelId (..)` from `Seal.Core.Types`.
- Produces: `modelCommandSpec :: SessionRuntime -> CommandSpec`; new `CommandGroup` constructor `GroupModel`.

- [ ] **Step 1: Add the `GroupModel` group + its Help header**

In `src/Seal/Command/Spec.hs`, insert `GroupModel` between `GroupSession` and `GroupVault`:

```haskell
data CommandGroup
  = GroupGeneral
  | GroupProvider
  | GroupSession
  | GroupModel
  | GroupVault
  deriving stock (Eq, Ord, Show, Enum, Bounded)
```

In `src/Seal/Command/Help.hs`:

```haskell
    groupHeader GroupSession  = "Sessions"
    groupHeader GroupModel    = "Model"
    groupHeader GroupVault    = "Vault"
```

- [ ] **Step 2: Write the failing test**

Create `test/Seal/Command/ModelSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.ModelSpec (spec) where

import Data.IORef (newIORef, readIORef)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps)
import Seal.Command.Model (modelCommandSpec)
import Seal.Command.Spec (CommandSpec (..), runCommandAction)
import Seal.Config.Paths (SealPaths (..))
import Seal.Core.Types (mkSessionId)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..))
import Seal.TestHelpers.FakeCaps (getSent, makeFakeCaps)

aTime :: UTCTime
aTime = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 43200)

mkSR :: FilePath -> IO SessionRuntime
mkSR root = do
  let Right sid = mkSessionId "20260701-120000-002"
      m0 = SessionMeta sid "anthropic" "claude-opus-4-8" "cli" aTime aTime
      paths = SealPaths root (root </> "config") (root </> "state") (root </> "keys")
  ref <- newIORef m0
  pure SessionRuntime { srPaths = paths, srConfigPath = root </> "config.toml", srActive = ref }

runModel :: SessionRuntime -> [String] -> ChannelCaps -> IO ()
runModel sr argv caps =
  case execParserPure defaultPrefs (csParserInfo (modelCommandSpec sr)) argv of
    Success act -> runCommandAction act caps
    _           -> expectationFailure ("parse failed: " <> show argv)

spec :: Spec
spec = describe "Seal.Command.Model" $ do
  it "list shows known providers and the active selection" $
    withSystemTempDirectory "seal-model" $ \root -> do
      sr <- mkSR root
      (fc, caps) <- makeFakeCaps []
      runModel sr ["list"] caps
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("anthropic" `T.isInfixOf`)
      T.unlines sent `shouldSatisfy` ("active" `T.isInfixOf`)

  it "use updates the active selection and persists it" $
    withSystemTempDirectory "seal-model" $ \root -> do
      sr <- mkSR root
      (fc, caps) <- makeFakeCaps []
      runModel sr ["use", "anthropic", "claude-haiku-4-5"] caps
      active <- readIORef (srActive sr)
      smProvider active `shouldBe` "anthropic"
      smModel active    `shouldBe` "claude-haiku-4-5"
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("claude-haiku-4-5" `T.isInfixOf`)

  it "rejects an unknown provider without mutating the session" $
    withSystemTempDirectory "seal-model" $ \root -> do
      sr <- mkSR root
      (fc, caps) <- makeFakeCaps []
      runModel sr ["use", "bogus", "x"] caps
      active <- readIORef (srActive sr)
      smModel active `shouldBe` "claude-opus-4-8"   -- unchanged
      sent <- getSent fc
      T.unlines sent `shouldSatisfy` ("unknown provider" `T.isInfixOf`)
```

Register `Seal.Command.Model` (library) and `Seal.Command.ModelSpec` (test-suite + `test/Main.hs`).

- [ ] **Step 3: Run test to verify it fails**

Run: `nix develop -c cabal test --test-options='-m "Seal.Command.Model"'`
Expected: FAIL — module `Seal.Command.Model` not found.

- [ ] **Step 4: Create the module**

Create `src/Seal/Command/Model.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
-- | The @/model@ command group: list known providers/models and set the active
-- session's provider+model (persisted to session.json). Provider+model are named
-- explicitly (unambiguous once providers host arbitrary model names).
module Seal.Command.Model
  ( modelCommandSpec
  ) where

import Data.IORef (readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Spec
  ( Availability (..), CommandAction (..), CommandGroup (..)
  , CommandName (..), CommandSpec (..) )
import Seal.Core.Types (ModelId (..))
import Seal.Providers.Registry
  ( KnownProvider, defaultModelFor, knownProviders, parseProvider, providerLabel )
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..), saveSessionMeta)

modelCommandSpec :: SessionRuntime -> CommandSpec
modelCommandSpec sr = CommandSpec
  { csName         = CommandName "model"
  , csAliases      = []
  , csGroup        = GroupModel
  , csSynopsis     = "List models and set the active session's model"
  , csParserInfo   = modelParserInfo sr
  , csAvailability = InteractiveOnly
  }

modelParserInfo :: SessionRuntime -> ParserInfo CommandAction
modelParserInfo sr =
  info (modelParser sr <**> helper)
    (  progDesc "List known providers/models and choose the session's model"
    <> header   "model — inspect and set the active session's model"
    )

modelParser :: SessionRuntime -> Parser CommandAction
modelParser sr = hsubparser
  (  command "list"
       (info (pure (listCmd sr)) (progDesc "List known providers and their default models"))
  <> command "use"
       (info (useCmd sr <$> provArg <*> modelArg)
             (progDesc "Set the session's provider and model"))
  <> metavar "COMMAND"
  )

provArg :: Parser Text
provArg = T.pack <$> strArgument (metavar "PROVIDER" <> help "Provider id (e.g. anthropic)")

modelArg :: Parser Text
modelArg = T.pack <$> strArgument (metavar "MODEL" <> help "Model id")

listCmd :: SessionRuntime -> CommandAction
listCmd sr = CommandAction $ \caps -> do
  mapM_ (ccSend caps . renderKnown) knownProviders
  active <- readIORef (srActive sr)
  ccSend caps ("active: " <> smProvider active <> "/" <> smModel active)
  where
    renderKnown kp =
      let ModelId dm = defaultModelFor kp
      in providerLabel kp <> " (default model: " <> dm <> ")"

useCmd :: SessionRuntime -> Text -> Text -> CommandAction
useCmd sr provLbl model = CommandAction $ \caps ->
  case parseProvider provLbl of
    Nothing -> ccSend caps (unknownProviderMsg provLbl)
    Just kp -> do
      m0 <- readIORef (srActive sr)
      let m1 = m0 { smProvider = providerLabel kp, smModel = model }
      writeIORef (srActive sr) m1
      saveSessionMeta (srPaths sr) m1
      ccSend caps ("session model set to " <> providerLabel kp <> "/" <> model)

unknownProviderMsg :: Text -> Text
unknownProviderMsg lbl =
  "unknown provider: " <> lbl <> " (known: "
    <> T.intercalate ", " (map providerLabel knownProviders) <> ")"
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `nix develop -c cabal test --test-options='-m "Seal.Command.Model"'`
Expected: PASS.

- [ ] **Step 6: Build clean + commit**

Run: `nix develop -c cabal build`.

```bash
git add src/Seal/Command/Spec.hs src/Seal/Command/Help.hs src/Seal/Command/Model.hs \
        test/Seal/Command/ModelSpec.hs test/Main.hs seal-harness.cabal
git commit -m "Add /model list|use command group"
```

---

### Task 6: Register the session at startup + wire `/session` and `/model` into the registry

**Files:**
- Modify: `src/Seal/Tui.hs`
- Modify: `test/Seal/Command/SessionSpec.hs` (help-index integration test)

**Interfaces:**
- Consumes: `initSession`, `SessionRuntime (..)` from `Seal.Session.Store`; `sessionCommandSpec` (Task 4); `modelCommandSpec` (Task 5); `renderHelpIndex` from `Seal.Command.Help`.
- Produces: `runTui` creates a session at startup, builds a `SessionRuntime`, and adds `sessionCommandSpec sr` + `modelCommandSpec sr` to the registry. (Chat still uses the old provider path; Task 7 rewires it.)

- [ ] **Step 1: Write the failing help-index test**

Append to the `/session commands` describe in `test/Seal/Command/SessionSpec.hs`. Add imports:

```haskell
import Seal.Command.Help (renderHelpIndex)
import Seal.Command.Model (modelCommandSpec)
import Seal.Command.Spec (mkRegistry)
```

Add:

```haskell
    it "session and model appear under their groups in the help index" $
      withSystemTempDirectory "seal-sess" $ \root -> do
        sr <- mkSR root (meta "20260701-120000-000")
        let idx = renderHelpIndex (mkRegistry [sessionCommandSpec sr, modelCommandSpec sr])
        idx `shouldSatisfy` ("Sessions" `T.isInfixOf`)
        idx `shouldSatisfy` ("/session" `T.isInfixOf`)
        idx `shouldSatisfy` ("Model" `T.isInfixOf`)
        idx `shouldSatisfy` ("/model" `T.isInfixOf`)
```

- [ ] **Step 2: Run test to verify it fails/passes**

Run: `nix develop -c cabal test --test-options='-m "appear under their groups"'`
Expected: FAIL on the missing imports until added; once the imports resolve the assertion itself should pass (the specs already set `GroupSession`/`GroupModel`). That is acceptable — it confirms Tasks 4–5 wired the groups. Proceed to wire `runTui`.

- [ ] **Step 3: Wire `Seal.Tui.runTui`**

In `src/Seal/Tui.hs`, add imports:

```haskell
import Data.IORef (newIORef)

import Seal.Command.Session (sessionCommandSpec)
import Seal.Command.Model (modelCommandSpec)
import Seal.Session.Store (SessionRuntime (..), initSession)
```

(`newIORef` is likely already imported — the M1 wiring imports `Data.IORef (newIORef)`. If so, don't duplicate.)

In `runTui`, after `pr` (the `ProviderRuntime`) is built and before `registry`, create the session and its runtime, and add the two specs to the registry list. Replace the registry-assembly line:

```haskell
  -- Every launch starts a fresh session (resume is a follow-on milestone).
  sessionMeta <- initSession paths cfg
  activeRef   <- newIORef sessionMeta
  let sr = SessionRuntime
             { srPaths      = paths
             , srConfigPath = cfgPath
             , srActive     = activeRef
             }
      registry = mkRegistry
        [ vaultCommandSpec rt
        , providerCommandSpec pr
        , sessionCommandSpec sr
        , modelCommandSpec sr
        ]
  runCliTui paths rt registry emptyChain
```

- [ ] **Step 4: Run the targeted test + full suite**

Run: `nix develop -c cabal test --test-options='-m "appear under their groups"'` → PASS.
Run: `nix develop -c cabal test` → all pass.

- [ ] **Step 5: Build clean + commit**

Run: `nix develop -c cabal build` and `nix develop -c hlint src/Seal/Tui.hs src/Seal/Command/Session.hs src/Seal/Command/Model.hs src/Seal/Session/Store.hs src/Seal/Session/Meta.hs`.

```bash
git add src/Seal/Tui.hs test/Seal/Command/SessionSpec.hs
git commit -m "Create a session at startup and register /session and /model"
```

---

### Task 7: Chat uses the session's provider+model; remove the `ANTHROPIC_API_KEY` hardcode

**Files:**
- Modify: `src/Seal/Channel/Cli.hs`
- Modify: `src/Seal/Tui.hs` (update the `runCliTui` call)
- Test: `test/Seal/Channel/CliSpec.hs`

**Interfaces:**
- Consumes: `SessionRuntime (..)`, `srActive` (Task 3); `SessionMeta (..)`; `ProviderRuntime (..)`, `prVault`, `prManager` from `Seal.Command.Provider`; `resolveProvider`, `parseProvider` from `Seal.Providers.Registry`; `VaultRuntime (..)`, `vrHandleRef`; `SomeProvider (..)`, `Provider (..)` from `Seal.Providers.Class`; `AgentEnv (..)`; `localBackend`; `fakeTranscript`, `TranscriptHandle` from `Seal.Handles.Transcript`; `ISA.mkRegistry`.
- Produces:
  - `runCliTui :: SealPaths -> VaultRuntime -> ProviderRuntime -> SessionRuntime -> Registry -> PreprocessChain -> IO ()` (new signature)
  - `resolveSessionProvider :: ProviderRuntime -> SessionMeta -> IO (Either Text (SomeProvider, ModelId))`
  - `mkSessionAgentEnv :: ChannelCaps -> SomeProvider -> ModelId -> SessionId -> ISA.Registry -> TranscriptHandle -> AgentEnv`

- [ ] **Step 1: Write the failing tests**

Add to `test/Seal/Channel/CliSpec.hs` (create the `describe` blocks; add imports as needed):

```haskell
  describe "resolveSessionProvider" $ do
    it "reports when the vault is not configured" $ do
      ref <- newIORef (Nothing :: Maybe VaultHandle)
      mgr <- newManager defaultManagerSettings
      let pr = ProviderRuntime
                 { prConfigPath = "/nonexistent/config.toml"
                 , prVault = VaultRuntime
                     { vrPaths = SealPaths "/x" "/x" "/x" "/x"
                     , vrConfigPath = "/x/config.toml", vrHandleRef = ref }
                 , prManager = mgr }
      r <- resolveSessionProvider pr (metaWith "anthropic" "claude-opus-4-8")
      case r of
        Left e  -> e `shouldSatisfy` ("vault not configured" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left"

    it "reports an unknown provider label in the session" $ do
      ref <- newIORef (Nothing :: Maybe VaultHandle)
      mgr <- newManager defaultManagerSettings
      let pr = ProviderRuntime
                 { prConfigPath = "/x/config.toml"
                 , prVault = VaultRuntime
                     { vrPaths = SealPaths "/x" "/x" "/x" "/x"
                     , vrConfigPath = "/x/config.toml", vrHandleRef = ref }
                 , prManager = mgr }
      r <- resolveSessionProvider pr (metaWith "bogus" "m")
      case r of
        Left e  -> e `shouldSatisfy` ("unknown provider" `T.isInfixOf`)
        Right _ -> expectationFailure "expected Left"

  describe "mkSessionAgentEnv" $
    it "carries the session's model and id into the AgentEnv" $ do
      (_, caps) <- makeFakeCaps []
      th <- fakeTranscript
      let Right sid = mkSessionId "20260701-120000-002"
          env = mkSessionAgentEnv caps (SomeProvider StubProvider)
                  (ModelId "claude-haiku-4-5") sid (ISA.mkRegistry []) th
      aeModel env   `shouldBe` ModelId "claude-haiku-4-5"
      aeSession env `shouldBe` sid
```

Add the stub provider + helper near the top of the spec (after imports):

```haskell
data StubProvider = StubProvider
instance Provider StubProvider where
  complete _ _   = pure (Left "stub")
  listModels _   = pure (Right [])

metaWith :: T.Text -> T.Text -> SessionMeta
metaWith p m =
  let Right sid = mkSessionId "20260701-120000-002"
      t = UTCTime (fromGregorian 2026 7 1) (secondsToDiffTime 43200)
  in SessionMeta sid p m "cli" t t
```

Ensure these imports are present in `CliSpec.hs`:

```haskell
import Data.IORef (newIORef)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Network.HTTP.Client (defaultManagerSettings, newManager)

import Seal.Agent.Env (AgentEnv (..))
import Seal.Channel.Cli (mkSessionAgentEnv, resolveSessionProvider)
import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Config.Paths (SealPaths (..))
import Seal.Core.Types (ModelId (..), mkSessionId)
import Seal.Handles.Transcript (fakeTranscript)
import qualified Seal.ISA.Registry as ISA
import Seal.Providers.Class (Provider (..), SomeProvider (..))
import Seal.Security.Vault (VaultHandle)
import Seal.Session.Meta (SessionMeta (..))
import Seal.TestHelpers.FakeCaps (makeFakeCaps)
import Seal.Vault.Commands (VaultRuntime (..))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `nix develop -c cabal test --test-options='-m "resolveSessionProvider"'`
Expected: FAIL — `resolveSessionProvider`/`mkSessionAgentEnv` not exported from `Seal.Channel.Cli`.

- [ ] **Step 3: Rewire `Seal.Channel.Cli`**

Edit `src/Seal/Channel/Cli.hs`:

(a) Extend the export list:

```haskell
module Seal.Channel.Cli
  ( runCliTui
  , interpretDisposition
  , handlePlain
  , resolveSessionProvider
  , mkSessionAgentEnv
  ) where
```

(b) Add/adjust imports (remove now-unused ones like `mkApiKey`, `lookupEnv`, `Data.Text.Encoding`, `mkAnthropic` if the hardcode is fully removed):

```haskell
import Data.IORef (readIORef)

import Seal.Command.Provider (ProviderRuntime (..))
import Seal.Providers.Registry (parseProvider, resolveProvider)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (SessionRuntime (..))
import Seal.Vault.Commands (VaultRuntime (..))
```

(c) Add the two new functions:

```haskell
-- | Resolve the active session's provider from the vault, or explain why not.
-- Key bytes never surface: 'resolveProvider' returns an opaque 'SomeProvider'.
resolveSessionProvider
  :: ProviderRuntime -> SessionMeta -> IO (Either Text (SomeProvider, ModelId))
resolveSessionProvider pr meta =
  case parseProvider (smProvider meta) of
    Nothing -> pure (Left ("unknown provider in session: " <> smProvider meta))
    Just kp -> do
      mh <- readIORef (vrHandleRef (prVault pr))
      case mh of
        Nothing -> pure (Left "vault not configured — run /vault setup")
        Just vh -> do
          let model = ModelId (smModel meta)
          fmap (fmap (\p -> (p, model))) (resolveProvider vh (prManager pr) kp model)

-- | Build the per-turn 'AgentEnv' for a session's selected provider+model.
mkSessionAgentEnv
  :: ChannelCaps -> SomeProvider -> ModelId -> SessionId
  -> ISA.Registry -> TranscriptHandle -> AgentEnv
mkSessionAgentEnv caps provider model sid isaReg tHandle = AgentEnv
  { aeProvider   = provider
  , aeModel      = model
  , aeRegistry   = isaReg
  , aeTranscript = tHandle
  , aeBackend    = localBackend
  , aeCaps       = caps
  , aeSession    = sid
  , aeMaxTurns   = 12
  }
```

Ensure the needed imports for these signatures exist (`ModelId` from `Seal.Core.Types`, `SessionId` likewise, `TranscriptHandle` from `Seal.Handles.Transcript`, `SomeProvider` from `Seal.Providers.Class`, `ISA` qualified). `ModelId`/`SessionId` — import `Seal.Core.Types (ModelId (..), SessionId)` (drop the old `mkSessionId`/`ModelId (..)` usage tied to the "cli" literal).

(d) Change `runCliTui`'s signature and body. New signature:

```haskell
runCliTui :: SealPaths -> VaultRuntime -> ProviderRuntime -> SessionRuntime -> Registry -> PreprocessChain -> IO ()
runCliTui paths rt pr sr registry chain = do
```

Inside: replace the transcript path with the session's, delete the `mProvider`/`ANTHROPIC_API_KEY` block entirely, and make `plainHandler` resolve per turn. Concretely:

```haskell
  active0 <- readIORef (srActive sr)
  let histFile       = spState paths </> "history"
      transcriptPath = sessionTranscriptPath paths (smId active0)
      innerSettings  = (defaultSettings :: Settings IO) { complete = noCompletion }
      hlSettings     = innerSettings { historyFile = Just histFile }
      caps = ChannelCaps { … }   -- unchanged
  wsRoot <- WorkspaceRoot <$> getCurrentDirectory
  appEnv <- mkEnv defaultConfig
  withTranscript transcriptPath $ \tHandle -> do
    let isaReg = ISA.mkRegistry
          [ showHumanOp caps, askHumanOp caps, fileReadOp wsRoot, secretGetOp rt ]
        plainHandler t = do
          meta  <- readIORef (srActive sr)
          eprov <- resolveSessionProvider pr meta
          case eprov of
            Left err            -> ccSend caps err
            Right (prov, model) ->
              handlePlain
                (mkSessionAgentEnv caps prov model (smId meta) isaReg tHandle)
                appEnv t
    runInputT hlSettings (loop caps plainHandler)
```

Delete the old `where`-clause bindings that referenced the removed hardcode: `model = ModelId "claude-opus-4-8"`, `sid = fromRight … (mkSessionId "cli")`, and `mkAgentEnv`. Add `sessionTranscriptPath` to the `Seal.Config.Paths` import list in `Cli.hs`. Remove the now-unused `newTlsManager` import if the only manager use was the deleted block (the manager now lives in `ProviderRuntime`).

- [ ] **Step 4: Update the caller in `Seal.Tui`**

In `src/Seal/Tui.hs`, change the final line to pass `pr` and `sr`:

```haskell
  runCliTui paths rt pr sr registry emptyChain
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `nix develop -c cabal test --test-options='-m "resolveSessionProvider"'` and `-m "mkSessionAgentEnv"` → PASS.
Run: `nix develop -c cabal test` → all pass.

- [ ] **Step 6: Build clean + hlint**

Run: `nix develop -c cabal build` (clean, `-Werror`).
Run: `nix develop -c hlint src/Seal/Channel/Cli.hs src/Seal/Tui.hs` → "No hints".

- [ ] **Step 7: Manual smoke (user-testable checkpoint)**

With a real key available to type and the Nix dev shell:

```
cabal run seal -- repl
> /vault setup        # if needed
> /provider add anthropic
> /session info       # shows a fresh YYYYMMDD-HHMMSS-mmm session, anthropic/claude-opus-4-8
> <type a message>    # chat runs against the session's model; transcript written under state/sessions/<id>/
> /model use anthropic claude-haiku-4-5
> /session info       # model now claude-haiku-4-5
> /session list       # the current session appears, marked (active)
```

Confirm `~/.seal/state/sessions/<id>/{session.json,transcript.jsonl}` exist with modes 0600 and the dir 0700.

- [ ] **Step 8: Commit**

```bash
git add src/Seal/Channel/Cli.hs src/Seal/Tui.hs test/Seal/Channel/CliSpec.hs
git commit -m "Route chat through the session's provider+model; drop ANTHROPIC_API_KEY hardcode"
```

---

## Self-Review

**Spec coverage (against the design's M2 bullets, minus the split-out resume):**
- Sessions under `~/.seal/state/sessions/<id>/` with `session.json` (0600) + `transcript.jsonl` (0600), dir 0700 → Tasks 1–3, 7.
- New session per launch; default provider+model from config → Task 3 (`initSession`/`defaultSessionSelection`) + Task 6.
- `/session list|info` → Task 4. `/model list|use <provider> <model>` → Task 5.
- Plain chat runs against the session's selected provider+model; `ANTHROPIC_API_KEY` startup hardcode removed → Task 7.
- Session id `YYYYMMDD-HHMMSS-mmm`, valid `SessionId`, chronological sort; no manifest (enumerate) → Tasks 1, 3.
- Channel-agnostic: `SessionRuntime`, Store, and both command modules take no Haskeline/CLI types; only `ChannelCaps` → verified by tests driving them through `FakeCaps`.
- **Deferred to M2b (documented in the header):** `/session resume` + transcript `openTranscript`/`closeTranscript` refactor + mid-REPL swap.
- **Also incorporates M1 follow-up (3):** model selection now lives per-session (`smModel`), not the global `default_model` — a second provider can now be added safely in M3.

**Placeholder scan:** No TBD/TODO; every code step shows complete code; no `pending` tests introduced (M2 core is fully offline-testable except the manual smoke, which is a checklist step, not a test).

**Type consistency:** `SessionMeta`/`sm*` fields, `SessionRuntime`/`sr*` fields, `formatSessionId`, `newSession`, `saveSessionMeta`, `listSessions`, `defaultSessionSelection`, `initSession`, `sessionsRoot`/`sessionDir`/`sessionMetaPath`/`sessionTranscriptPath`, `sessionCommandSpec`, `modelCommandSpec`, `GroupSession`/`GroupModel`, `resolveSessionProvider`, `mkSessionAgentEnv`, and the new `runCliTui` signature are used with identical names/types across defining and consuming tasks. `ProviderRuntime`/`prVault`/`prManager`, `resolveProvider`, `parseProvider`, `defaultModelFor`, `VaultRuntime`/`vrHandleRef`, and `AgentEnv` fields match the merged M1 / spine code.
