{-# LANGUAGE OverloadedStrings #-}
module Seal.Command.NewSpec (spec) where

import Control.Monad (void)
import Data.Default (def)
import System.IO.Unsafe (unsafePerformIO)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text as T
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure)
import System.Directory (getTemporaryDirectory)
import System.FilePath ((</>))
import Test.Hspec

import Seal.Channel.Caps (ChannelCaps (..))
import Seal.Command.Help (renderHelpIndex)
import Seal.Command.New
  ( NewDeps (..), newCommandSpec, renderNewConfirmation
  , NewArgs (..), parseNewArgs, emptyNewArgs, resolveRepoUrl )
import Data.Map.Strict qualified as Map
import Seal.Config.Machines
  ( MachineName, MachineRegistry (..), MachineTarget (..), localMachineName
  , mkMachineName )
import Seal.Config.Paths (SealPaths (..))
import Seal.Gateway.Types.NewArgs (renderNewSessionConfirmation)
import Seal.Command.Parse (ParseOutcome (..), parseSlash)
import Seal.Command.Spec (CommandSpec (csParserInfo), mkRegistry, runCommandAction)
import Seal.Core.Types (SessionId, mkSessionId)
import Seal.Session.Meta (SessionMeta (..))
import Seal.Session.Store (listSessions)
import Seal.SourceControl.Repo
  ( SourceRepo (..), RepoCredential (CredPat), VcsKind (VcsGitHub)
  , mkRepoId )
import Seal.SourceControl.Registry (RepoRegistryHandle (..))

mkSid :: Text -> SessionId
mkSid t = case mkSessionId t of
  Right s -> s
  Left _  -> error ("invalid session id: " <> show t)

-- | A stub repo for testing.
mkTestRepo :: Text -> Text -> SourceRepo
mkTestRepo rid url = SourceRepo
  { srId = case mkRepoId rid of Right r -> r; Left e -> error (T.unpack e)
  , srUrl = url
  , srVcsKind = VcsGitHub
  , srCredential = CredPat "test-key"
  , srDeployKeyPublic = Nothing
  , srKeyfilePath = Nothing
  }

-- | A stub RepoRegistryHandle that returns a fixed list of repos.
stubRepoReg :: [SourceRepo] -> RepoRegistryHandle
stubRepoReg repos = RepoRegistryHandle
  { rrhList = pure (Right repos)
  , rrhMutate = \_ -> pure (Right ())
  }

-- | A stub NewDeps. ndInsertTab returns a canned old sid; the disk-touching
-- mint + the actual tab insert are exercised at the CLI/integration level,
-- not here.
stubDeps :: NewDeps
stubDeps =
  NewDeps
    { ndPaths = error "ndPaths: unused"
    , ndCfg = error "ndCfg: unused"
    , ndAgentDefs = error "ndAgentDefs: unused"
    , ndChannelLabel = "test"
    , ndOldMeta = error "ndOldMeta: unused by parse/render tests"
    , ndInsertTab = \_caps _newMeta -> pure (mkSid "20260701-000000-000")
    , ndSetupRepo = Nothing
    , ndRepoReg = Nothing
    , ndMachines = error "ndMachines: unused by parse/render tests"
    }

-- | A throwaway 'SealPaths' under the system temp dir. The @\/new@ happy path
-- persists the freshly-minted session's @session.json@ (via 'newSession'), so
-- the end-to-end tests need a real, writable state tree.
tempSealPaths :: IO SealPaths
tempSealPaths = do
  -- A UNIQUE directory per call. A fixed name leaked state between cases
  -- ("no machine recorded" saw a session written by an earlier test), which is
  -- a real hazard here because 'newSession' persists to disk and the assertions
  -- read back every session under the root.
  tmp <- getTemporaryDirectory
  uniq <- getUniqueSuffix
  let root = tmp </> ("seal-new-spec-" <> uniq)
  pure SealPaths
    { spHome   = root
    , spConfig = root </> "config"
    , spState  = root </> "state"
    , spKeys   = root </> "keys"
    , spCache  = root </> "cache"
    }

-- | A 'ChannelCaps' fixture that records every 'ccSend' line.
recordingCaps :: IORef [Text] -> ChannelCaps
recordingCaps ref = def { ccSend = \t -> modifyIORef' ref (t :) }

-- | 'stubDeps' wired for a real run: a temp state dir, a canned pre-swap
-- session, and an optional recording repo-setup seam.
seamDeps
  :: SealPaths
  -> SessionMeta
  -> Maybe (SessionId -> Text -> Maybe Text -> IO (Either Text Text))
  -> NewDeps
seamDeps paths oldMeta mSeam = stubDeps
  { ndPaths     = paths
  , ndOldMeta   = pure oldMeta
  , ndSetupRepo = mSeam
  }

-- | Parse argv against the @\/new@ spec and run the resulting action.
runNewAction :: NewDeps -> ChannelCaps -> [String] -> IO ()
runNewAction deps caps argv =
  case execParserPure defaultPrefs (csParserInfo (newCommandSpec deps)) argv of
    Success act -> void (runCommandAction act caps)
    _           -> expectationFailure ("parse failed: " <> show argv)

spec :: Spec
spec = describe "Seal.Command.New" $ do
  let newMeta = SessionMeta
        { smId = mkSid "20260719-120000-001"
        , smProvider = "anthropic"
        , smModel = "claude-sonnet-4-20250514"
        , smChannel = "cli"
        , smParent = Nothing
        , smAgent = Nothing
        , smSystemOverride = Nothing
        , smAgentName = Nothing
        , smDescription = Nothing
        , smSealFrontMatter = True
        , smRepoUrl = Nothing
        ,smMachine    = Nothing
        , smRepoBranch = Nothing
        , smCreatedAt = error "unused"
        , smLastActive = error "unused"
        }
      oldSid = mkSid "20260701-000000-000"
      line = renderNewConfirmation newMeta oldSid
  describe "renderNewConfirmation" $ do
    it "names the new session id" $
      T.unpack line `shouldContain` "new session 20260719-120000-001"
    it "names the provider/model" $
      T.unpack line `shouldContain` "anthropic/claude-sonnet-4-20250514"
    it "names the prior session + resume hint" $ do
      T.unpack line `shouldContain` "prior session 20260701-000000-000"
      T.unpack line `shouldContain` "/session list"

  -- The shared renderer lives in 'seal-gateway-types' so the gateway-API chat
  -- channels (which cannot import this module) emit byte-identical text.
  describe "Seal.Gateway.Types.NewArgs.renderNewSessionConfirmation" $ do
    let golden =
          "new session 20260719-120000-001 (anthropic/claude-sonnet-4-20250514) — prior session 20260701-000000-000 kept in /session list"
    it "renders the exact golden /new confirmation line" $
      renderNewSessionConfirmation
        "20260719-120000-001" "anthropic" "claude-sonnet-4-20250514" "20260701-000000-000"
        `shouldBe` golden
    it "is the same text 'renderNewConfirmation' produces (no drift)" $
      line `shouldBe` golden

  describe "parseNewArgs" $ do
    it "empty string yields emptyNewArgs" $
      parseNewArgs "" `shouldBe` emptyNewArgs
    it "parses -p provider" $
      parseNewArgs "-p anthropic" `shouldBe`
        emptyNewArgs { naProvider = Just "anthropic" }
    it "parses --provider provider" $
      parseNewArgs "--provider ollama" `shouldBe`
        emptyNewArgs { naProvider = Just "ollama" }
    it "parses -m model" $
      parseNewArgs "-m claude-sonnet-4" `shouldBe`
        emptyNewArgs { naModel = Just "claude-sonnet-4" }
    it "parses --model model" $
      parseNewArgs "--model llama3" `shouldBe`
        emptyNewArgs { naModel = Just "llama3" }
    it "parses -r repo" $
      parseNewArgs "-r https://github.com/foo/bar.git" `shouldBe`
        emptyNewArgs { naRepo = Just "https://github.com/foo/bar.git" }
    it "parses --repo repo" $
      parseNewArgs "--repo git@github.com:foo/bar.git" `shouldBe`
        emptyNewArgs { naRepo = Just "git@github.com:foo/bar.git" }
    it "parses all three flags" $
      parseNewArgs "-p anthropic -m claude-sonnet-4 -r https://github.com/foo/bar.git"
        `shouldBe` NewArgs
          { naProvider = Just "anthropic"
          , naModel = Just "claude-sonnet-4"
          , naRepo = Just "https://github.com/foo/bar.git"
          , naMachine = Nothing
          , naBranch = Nothing
          }
    it "parses long-form all three" $
      parseNewArgs "--provider anthropic --model claude-sonnet-4 --repo https://github.com/foo/bar.git"
        `shouldBe` NewArgs
          { naProvider = Just "anthropic"
          , naModel = Just "claude-sonnet-4"
          , naRepo = Just "https://github.com/foo/bar.git"
          , naMachine = Nothing
          , naBranch = Nothing
          }
    it "parses -b branch alongside -r repo" $
      parseNewArgs "-r seal -b dev" `shouldBe`
        emptyNewArgs { naRepo = Just "seal", naBranch = Just "dev" }
    it "parses --branch branch" $
      parseNewArgs "--branch main" `shouldBe`
        emptyNewArgs { naBranch = Just "main" }
    it "leaves naBranch as Nothing when -b is absent" $
      parseNewArgs "-r seal" `shouldBe`
        emptyNewArgs { naRepo = Just "seal" }
    it "parses all four flags together" $
      parseNewArgs "-p anthropic -m claude-sonnet-4 -r seal -b dev"
        `shouldBe` NewArgs
          { naProvider = Just "anthropic"
          , naModel = Just "claude-sonnet-4"
          , naRepo = Just "seal"
          , naMachine = Nothing
          , naBranch = Just "dev"
          }
    it "ignores unknown flags" $
      parseNewArgs "--unknown foo -p anthropic" `shouldBe`
        emptyNewArgs { naProvider = Just "anthropic" }
    it "parses -x machine" $
      parseNewArgs "-x mac-mini" `shouldBe` emptyNewArgs { naMachine = Just "mac-mini" }
    it "parses --machine machine" $
      parseNewArgs "--machine builder" `shouldBe` emptyNewArgs { naMachine = Just "builder" }

  -- ── WU-10: /new -x — the machine override.
  --
  -- Two failure modes matter and neither is a crash: an unknown name must fail
  -- AT /new TIME with the valid choices (not mint a session that cannot run
  -- anything), and a session started without -x must record NOTHING so the
  -- configured default keeps deciding — which is what makes an operator's later
  -- change of `default` move sessions that never pinned one.
  describe "WU-10 /new -x machine override" $ do

    it "-x <selectable> persists that machine into session.json" $ do
      paths <- tempSealPaths
      sentRef <- newIORef ([] :: [Text])
      let deps = (seamDeps paths newMeta Nothing)
            { ndMachines = pure (Right twoMachineRegistry) }
      runNewAction deps (recordingCaps sentRef) ["-x", "alpha"]
      -- The id is minted from the clock, so read whatever landed rather than
      -- guessing: the assertion is about the RECORDED machine, not the id.
      metas <- listSessions paths
      map smMachine metas `shouldBe` [Just (machineName "alpha")]

    it "-x <unknown> fails before minting, listing the choices" $ do
      paths <- tempSealPaths
      sentRef <- newIORef ([] :: [Text])
      let deps = (seamDeps paths newMeta Nothing)
            { ndMachines = pure (Right twoMachineRegistry) }
      runNewAction deps (recordingCaps sentRef) ["-x", "nope"]
      sent <- readIORef sentRef
      sent `shouldSatisfy` any (\t ->
        "unknown execution machine \"nope\"" `T.isInfixOf` t
          && "alpha" `T.isInfixOf` t)
      -- Nothing minted: no confirmation line, and no session.json.
      sent `shouldNotSatisfy` any (T.isPrefixOf "new session ")

    it "-x local fails when allow_localhost is false" $ do
      -- `local` is absent from regMachines in that state, so the same check
      -- refuses it. Asserted separately because `local` is not constructible
      -- via mkMachineName — it needs its own branch in the resolver, and that
      -- branch is easy to get wrong.
      paths <- tempSealPaths
      sentRef <- newIORef ([] :: [Text])
      let deps = (seamDeps paths newMeta Nothing)
            { ndMachines = pure (Right noLocalRegistry) }
      runNewAction deps (recordingCaps sentRef) ["-x", "local"]
      sent <- readIORef sentRef
      sent `shouldSatisfy` any (\t -> "unknown execution machine \"local\"" `T.isInfixOf` t)
      sent `shouldNotSatisfy` any (T.isPrefixOf "new session ")

    it "-x local succeeds when allow_localhost is true" $ do
      paths <- tempSealPaths
      sentRef <- newIORef ([] :: [Text])
      let deps = (seamDeps paths newMeta Nothing)
            { ndMachines = pure (Right twoMachineRegistry) }
      runNewAction deps (recordingCaps sentRef) ["-x", "local"]
      sent <- readIORef sentRef
      sent `shouldSatisfy` any (T.isPrefixOf "new session ")

    it "omitting -x records NO machine, so the default keeps deciding" $ do
      paths <- tempSealPaths
      sentRef <- newIORef ([] :: [Text])
      let deps = (seamDeps paths newMeta Nothing)
            { ndMachines = pure (Right twoMachineRegistry) }
      runNewAction deps (recordingCaps sentRef) []
      metas <- listSessions paths
      map smMachine metas `shouldBe` [Nothing]

  describe "resolveRepoUrl" $ do
    let repos =
          [ mkTestRepo "seal-test-repo" "https://github.com/seal-harness/seal-harness.git"
          , mkTestRepo "other-repo" "git@github.com:foo/bar.git"
          ]
        regH = stubRepoReg repos

    it "resolves a registered repo ID to its URL" $ do
      url <- resolveRepoUrl regH "seal-test-repo"
      url `shouldBe` "https://github.com/seal-harness/seal-harness.git"

    it "resolves a different registered repo ID to its URL" $ do
      url <- resolveRepoUrl regH "other-repo"
      url `shouldBe` "git@github.com:foo/bar.git"

    it "falls back to the raw value when the ID is not registered" $ do
      url <- resolveRepoUrl regH "https://github.com/unknown/repo.git"
      url `shouldBe` "https://github.com/unknown/repo.git"

    it "falls back to the raw value when the registry is empty" $ do
      let emptyReg = stubRepoReg []
      url <- resolveRepoUrl emptyReg "some-repo-id"
      url `shouldBe` "some-repo-id"

    it "falls back to the raw value when the registry returns an error" $ do
      let errReg = RepoRegistryHandle
            { rrhList = pure (Left "corrupt toml")
            , rrhMutate = \_ -> pure (Right ())
            }
      url <- resolveRepoUrl errReg "some-repo-id"
      url `shouldBe` "some-repo-id"

  describe "newCommandSpec" $ do
    it "parses /new with no args" $ do
      let reg = mkRegistry [newCommandSpec stubDeps]
      case parseSlash reg "/new" of
        ParsedAction _ -> pure ()
        other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)

    it "parses /new -p anthropic" $ do
      let reg = mkRegistry [newCommandSpec stubDeps]
      case parseSlash reg "/new -p anthropic" of
        ParsedAction _ -> pure ()
        other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)

    it "parses /new -p anthropic -m claude-sonnet-4" $ do
      let reg = mkRegistry [newCommandSpec stubDeps]
      case parseSlash reg "/new -p anthropic -m claude-sonnet-4" of
        ParsedAction _ -> pure ()
        other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)

    it "parses /new -r https://github.com/foo/bar.git" $ do
      let reg = mkRegistry [newCommandSpec stubDeps]
      case parseSlash reg "/new -r https://github.com/foo/bar.git" of
        ParsedAction _ -> pure ()
        other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)

    it "parses /new -r seal-test-repo" $ do
      let reg = mkRegistry [newCommandSpec stubDeps]
      case parseSlash reg "/new -r seal-test-repo" of
        ParsedAction _ -> pure ()
        other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)

    it "parses /new -r seal -b dev" $ do
      let reg = mkRegistry [newCommandSpec stubDeps]
      case parseSlash reg "/new -r seal -b dev" of
        ParsedAction _ -> pure ()
        other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)

    it "parses /new --provider anthropic --model claude-sonnet-4 --repo https://github.com/foo/bar.git" $ do
      let reg = mkRegistry [newCommandSpec stubDeps]
      case parseSlash reg "/new --provider anthropic --model claude-sonnet-4 --repo https://github.com/foo/bar.git" of
        ParsedAction _ -> pure ()
        other -> expectationFailure ("expected ParsedAction, got: " <> showPO other)

    it "/help index includes /new" $ do
      let reg = mkRegistry [newCommandSpec stubDeps]
          help = renderHelpIndex reg
      T.unpack help `shouldContain` "/new"

  -- WU-4: @-b\/--branch@ must reach the repo-setup seam (@ndSetupRepo@), and
  -- @-b@ without @-r@ must perform no repo setup at all — the parsed flag
  -- alone never triggers a clone.
  describe "/new -b reaches the repo-setup seam" $ do
    let recordingSeam ref _sid url mBranch = do
          modifyIORef' ref ((url, mBranch) :)
          pure (Right "cloned")

    it "passes Just \"dev\" to the seam for -r <url> -b dev" $ do
      paths <- tempSealPaths
      callsRef <- newIORef ([] :: [(Text, Maybe Text)])
      sentRef  <- newIORef ([] :: [Text])
      let deps = seamDeps paths newMeta (Just (recordingSeam callsRef))
      runNewAction deps (recordingCaps sentRef)
        ["-r", "https://github.com/foo/bar.git", "-b", "dev"]
      calls <- readIORef callsRef
      calls `shouldBe` [("https://github.com/foo/bar.git", Just "dev")]
      sent <- readIORef sentRef
      sent `shouldSatisfy` any (T.isPrefixOf "new session ")

    it "passes Nothing to the seam for -r <url> with no -b (default branch)" $ do
      paths <- tempSealPaths
      callsRef <- newIORef ([] :: [(Text, Maybe Text)])
      sentRef  <- newIORef ([] :: [Text])
      let deps = seamDeps paths newMeta (Just (recordingSeam callsRef))
      runNewAction deps (recordingCaps sentRef) ["-r", "seal"]
      calls <- readIORef callsRef
      calls `shouldBe` [("seal", Nothing)]

    it "does not call the seam for -b dev without -r" $ do
      paths <- tempSealPaths
      callsRef <- newIORef ([] :: [(Text, Maybe Text)])
      sentRef  <- newIORef ([] :: [Text])
      let deps = seamDeps paths newMeta (Just (recordingSeam callsRef))
      runNewAction deps (recordingCaps sentRef) ["-b", "dev"]
      calls <- readIORef callsRef
      calls `shouldBe` []
      sent <- readIORef sentRef
      sent `shouldSatisfy` any (T.isPrefixOf "new session ")

showPO :: ParseOutcome -> String
showPO (ParsedAction _)   = "ParsedAction"
showPO (ParseHelp Nothing) = "ParseHelp nothing"
showPO (ParseHelp (Just _)) = "ParseHelp just"
showPO (ParseFailure _)   = "ParseFailure"

-- | Two selectable machines plus the implicit `local` — the shape an install
-- with @allow_localhost = true@ resolves to.
twoMachineRegistry :: MachineRegistry
twoMachineRegistry = MachineRegistry
  { regMachines = Map.fromList
      [ (machineName "alpha", MtLocal), (localMachineName, MtLocal) ]
  , regRejected = Map.empty
  , regDefault  = Just (machineName "alpha")
  , regWarnings = []
  }

-- | The same machines with @allow_localhost = false@: no `local` entry.
noLocalRegistry :: MachineRegistry
noLocalRegistry = twoMachineRegistry
  { regMachines = Map.fromList [ (machineName "alpha", MtLocal) ] }

machineName :: Text -> MachineName
machineName t = case mkMachineName t of
  Right n -> n
  Left e  -> error ("fixture: mkMachineName " <> T.unpack t <> ": " <> T.unpack e)

-- | A per-call unique directory suffix.
getUniqueSuffix :: IO String
getUniqueSuffix = show <$> atomicModifyIORef' uniqueCounter (\n -> (n + 1, n))

uniqueCounter :: IORef Int
uniqueCounter = unsafePerformIO (newIORef 0)
{-# NOINLINE uniqueCounter #-}
