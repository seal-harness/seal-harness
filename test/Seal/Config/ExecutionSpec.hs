{-# LANGUAGE OverloadedStrings #-}
module Seal.Config.ExecutionSpec (spec) where

import Control.Concurrent.Async (mapConcurrently)
import Data.Either (isLeft, isRight)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Config.Execution
import Seal.Config.Paths (SealPaths (..))
import Seal.Config.Security
  ( UntrustedExecFileConfig (..), UntrustedExecRemoteFileConfig (..) )
import Seal.Execution.Types
import Seal.Tools.Exec.Types
  ( getRemotePath, getSshHost, getSshUser, mkRemotePath, mkSshHost, mkSshUser )

-- ---------------------------------------------------------------------------
-- fixtures
-- ---------------------------------------------------------------------------

pathsAt :: FilePath -> SealPaths
pathsAt dir = SealPaths
  { spHome   = dir
  , spConfig = dir </> "config"
  , spState  = dir </> "state"
  , spKeys   = dir </> "keys"
  , spCache  = dir </> "cache"
  }

oneMachine :: Text
oneMachine = T.unlines
  [ "[machines.builder]"
  , "host = \"builder.example.com\""
  , "user = \"seal\""
  , "known_hosts = \"/home/op/.ssh/known_hosts\""
  , "workspace = \"/srv/seal/workspace\""
  ]

twoMachines :: Text
twoMachines = T.unlines
  [ "default = \"builder\""
  , ""
  , "[machines.builder]"
  , "host = \"builder.example.com\""
  , "user = \"seal\""
  , "known_hosts = \"/home/op/.ssh/known_hosts\""
  , "workspace = \"/srv/seal/workspace\""
  , ""
  , "[machines.tester]"
  , "host = \"tester.example.com\""
  , "user = \"seal\""
  , "port = 2222"
  , "identity = \"/home/op/.ssh/id_ed25519\""
  , "known_hosts = \"/home/op/.ssh/known_hosts\""
  , "workspace = \"/srv/seal/tester\""
  ]

spec :: Spec
spec = describe "Seal.Config.Execution" $ do

  describe "executionFilePath" $
    it "is <config>/execution.toml — derived from SealPaths, never a literal" $
      executionFilePath (pathsAt "/srv/alt/seal")
        `shouldBe` "/srv/alt/seal/config/execution.toml"

  describe "loadExecutionConfig" $ do

    it "an absent file yields an empty inventory" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        result <- loadExecutionConfig True (pathsAt dir)
        fmap ecMachines result `shouldBe` Right Map.empty
        fmap ecDefault result `shouldBe` Right Nothing

    it "a comment-only file yields an empty inventory" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        writeInventory dir "# nothing enabled here\n"
        fmap (fmap ecMachines) (loadExecutionConfig True (pathsAt dir))
          `shouldReturn` Right Map.empty

    it "decodes one machine" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        writeInventory dir oneMachine
        result <- loadExecutionConfig True (pathsAt dir)
        fmap (sort . map machineNameText . Map.keys . ecMachines) result
          `shouldBe` Right ["builder"]

    it "preserves every field of a decoded machine" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        writeInventory dir twoMachines
        result <- loadExecutionConfig True (pathsAt dir)
        case result of
          Left e    -> expectationFailure ("decode failed: " <> T.unpack (render e))
          Right ec  -> case Map.lookup (mn "tester") (ecMachines ec) of
            Nothing -> expectationFailure "tester not decoded"
            Just t  -> do
              getSshHost (smsHost t) `shouldBe` "tester.example.com"
              getSshUser (smsUser t) `shouldBe` "seal"
              smsPort t `shouldBe` 2222
              fmap getSshLocalPath (smsIdentity t)
                `shouldBe` Just "/home/op/.ssh/id_ed25519"
              getSshLocalPath (smsKnownHosts t)
                `shouldBe` "/home/op/.ssh/known_hosts"
              getRemotePath (smsWorkspace t) `shouldBe` "/srv/seal/tester"

    it "defaults port to 22 and identity to ssh-agent when absent" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        writeInventory dir oneMachine
        result <- loadExecutionConfig True (pathsAt dir)
        case result of
          Left e   -> expectationFailure ("decode failed: " <> T.unpack (render e))
          Right ec -> case Map.lookup (mn "builder") (ecMachines ec) of
            Nothing -> expectationFailure "builder not decoded"
            Just b  -> do
              smsPort b `shouldBe` 22
              smsIdentity b `shouldBe` Nothing

    describe "required fields" $
      mapM_ (\(field, body) ->
        it ("a missing " <> T.unpack field <> " is a Left naming it") $
          withSystemTempDirectory "seal-exec" $ \dir -> do
            writeInventory dir body
            result <- loadExecutionConfig True (pathsAt dir)
            case result of
              Right _ -> expectationFailure "expected a decode failure"
              Left e  -> T.unpack (render e) `shouldContain` T.unpack field)
        [ ("host",        omit "host" oneMachine)
        , ("user",        omit "user" oneMachine)
        , ("known_hosts", omit "known_hosts" oneMachine)
        , ("workspace",   omit "workspace" oneMachine)
        ]

    it "rejects the reserved [machines.local] key" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        writeInventory dir (T.replace "machines.builder" "machines.local" oneMachine)
        (isLeft <$> loadExecutionConfig True (pathsAt dir)) `shouldReturn` True

    it "rejects the reserved [machines.default] key" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        writeInventory dir (T.replace "machines.builder" "machines.default" oneMachine)
        (isLeft <$> loadExecutionConfig True (pathsAt dir)) `shouldReturn` True

    it "rejects an invalid machine name as a key" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        writeInventory dir (T.replace "machines.builder" "machines.\"-oProxy=x\"" oneMachine)
        (isLeft <$> loadExecutionConfig True (pathsAt dir)) `shouldReturn` True

    it "rejects a dotted machine name key (path-ish)" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        writeInventory dir (T.replace "machines.builder" "machines.\"a.b\"" oneMachine)
        (isLeft <$> loadExecutionConfig True (pathsAt dir)) `shouldReturn` True

    it "rejects a default naming an absent machine (dangling)" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        writeInventory dir ("default = \"ghost\"\n" <> oneMachine)
        result <- loadExecutionConfig True (pathsAt dir)
        case result of
          Right _ -> expectationFailure "expected a dangling-default failure"
          Left e  -> render e `shouldSatisfy` T.isInfixOf "ghost"

    it "rejects default = local when allow_localhost = false" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        writeInventory dir ("default = \"local\"\n" <> oneMachine)
        (isLeft <$> loadExecutionConfig False (pathsAt dir)) `shouldReturn` True

    it "accepts default = local when allow_localhost = true" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        writeInventory dir ("default = \"local\"\n" <> oneMachine)
        fmap (fmap ecDefault) (loadExecutionConfig True (pathsAt dir))
          `shouldReturn` Right (Just (mn "local"))

    it "rejects a port of 0" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        writeInventory dir (insert "port = 0" oneMachine)
        (isLeft <$> loadExecutionConfig True (pathsAt dir)) `shouldReturn` True

    it "rejects a port of 65536" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        writeInventory dir (insert "port = 65536" oneMachine)
        (isLeft <$> loadExecutionConfig True (pathsAt dir)) `shouldReturn` True

    it "rejects a duplicate host:port:user across machines" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        writeInventory dir
          (T.replace "tester.example.com" "builder.example.com"
             (T.replace "port = 2222\n" "" twoMachines))
        (isLeft <$> loadExecutionConfig True (pathsAt dir)) `shouldReturn` True

    it "rejects a known_hosts path containing a space" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        writeInventory dir
          (T.replace "/home/op/.ssh/known_hosts" "/home/op/.ssh/known hosts" oneMachine)
        (isLeft <$> loadExecutionConfig True (pathsAt dir)) `shouldReturn` True

    it "rejects two machines without a default" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        writeInventory dir (T.replace "default = \"builder\"\n\n" "" twoMachines)
        (isLeft <$> loadExecutionConfig True (pathsAt dir)) `shouldReturn` True

    it "accepts exactly one machine without a default" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        writeInventory dir oneMachine
        (isRight <$> loadExecutionConfig True (pathsAt dir)) `shouldReturn` True

  describe "unknown keys" $ do

    it "warns rather than failing on a typo'd machine key" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        -- append inside the [machines.builder] table, not above its header
        writeInventory dir (oneMachine <> "identiy = \"/home/op/.ssh/oops\"\n")
        result <- loadExecutionConfigWith True Nothing (pathsAt dir)
        case result of
          Left e -> expectationFailure ("should have warned, not failed: " <> T.unpack (render e))
          Right (ec, warns) -> do
            Map.size (ecMachines ec) `shouldBe` 1
            warns `shouldSatisfy` any (T.isInfixOf "identiy")

    it "warns rather than failing on a typo'd top-level key" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        writeInventory dir ("defualt = \"builder\"\n" <> oneMachine)
        result <- loadExecutionConfigWith True Nothing (pathsAt dir)
        either (\e -> expectationFailure ("should have warned: " <> T.unpack (render e)))
               (\(_, warns) -> warns `shouldSatisfy` (not . null)) result

    it "does not warn for a well-formed file" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        writeInventory dir oneMachine
        result <- loadExecutionConfigWith True Nothing (pathsAt dir)
        either (expectationFailure . T.unpack . render)
               (\(_, warns) -> warns `shouldBe` []) result

  describe "legacy synthesis from [untrusted_execution.remote]" $ do

    it "an incomplete block yields no machine" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        result <- loadExecutionConfigWith False (Just legacyIncomplete) (pathsAt dir)
        fmap (Map.size . ecMachines . fst) result `shouldBe` Right 0

    it "a complete block under allow_localhost = false becomes the machine default" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        result <- loadExecutionConfigWith False (Just legacyRemoteFull) (pathsAt dir)
        case result of
          Left e -> expectationFailure ("legacy synthesis failed: " <> T.unpack (render e))
          Right (ec, _) -> do
            Map.size (ecMachines ec) `shouldBe` 1
            fmap machineNameText (ecDefault ec) `shouldBe` Just "default"
            getSshHost . smsHost <$> Map.lookup (mn "default") (ecMachines ec)
              `shouldBe` Just "legacy.example.com"

    it "a complete block under allow_localhost = true yields no machine" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        result <- loadExecutionConfigWith True (Just legacyRemoteFull) (pathsAt dir)
        fmap (Map.size . ecMachines . fst) result `shouldBe` Right 0

    it "mode = local with a complete block yields no machine" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        result <- loadExecutionConfigWith True
                    (Just legacyRemoteFull { uefcMode = Just "local" }) (pathsAt dir)
        fmap (Map.size . ecMachines . fst) result `shouldBe` Right 0

    it "an execution.toml entry wins over the legacy block" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        writeInventory dir twoMachines
        result <- loadExecutionConfigWith False (Just legacyRemoteFull) (pathsAt dir)
        fmap (sort . map machineNameText . Map.keys . ecMachines . fst) result
          `shouldBe` Right ["builder", "tester"]

  describe "saveExecutionConfig" $ do

    it "writes a file that loads back to the same inventory" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        let p  = executionFilePath (pathsAt dir)
            ec = ExecutionConfig
              { ecDefault  = Just (mn "builder")
              , ecMachines = Map.fromList
                  [ (mn "builder", machine "builder.example.com" 22 Nothing)
                  , (mn "tester", machine "tester.example.com" 2222
                                    (Just "/home/op/.ssh/id_ed25519"))
                  ]
              }
        createDirectoryIfMissing True (spConfig (pathsAt dir))
        saveExecutionConfig p ec
        result <- loadExecutionConfig True (pathsAt dir)
        fmap ecMachines result `shouldBe` Right (ecMachines ec)
        fmap ecDefault result  `shouldBe` Right (ecDefault ec)

    it "creates no .tmp file behind" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        let p = executionFilePath (pathsAt dir)
        createDirectoryIfMissing True (spConfig (pathsAt dir))
        saveExecutionConfig p (ExecutionConfig Nothing Map.empty)
        doesFileExist (p <> ".tmp") `shouldReturn` False

  describe "updateExecutionConfig" $ do

    it "applies the update and persists it" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        let p = executionFilePath (pathsAt dir)
        res <- updateExecutionConfig True p $ \ec ->
          ec { ecMachines = Map.fromList
                 [(mn "builder", machine "builder.example.com" 22 Nothing)] }
        fmap (Map.size . ecMachines) res `shouldBe` Right 1
        fmap (fmap (Map.size . ecMachines)) (loadExecutionConfig True (pathsAt dir))
          `shouldReturn` Right 1

    it "a rejected write leaves the file byte-identical" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        let p = executionFilePath (pathsAt dir)
        createDirectoryIfMissing True (spConfig (pathsAt dir))
        saveExecutionConfig p (ExecutionConfig Nothing
          (Map.fromList [(mn "builder", machine "builder.example.com" 22 Nothing)]))
        prior <- TIO.readFile p
        res <- updateExecutionConfig True p $ \ec ->
          ec { ecMachines = Map.insert (mn "tester")
                            (machine "tester.example.com" 22 Nothing) (ecMachines ec) }
        res `shouldSatisfy` isLeft
        TIO.readFile p `shouldReturn` prior

    it "validates the resulting document: a second machine needs a default" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        let p = executionFilePath (pathsAt dir)
        res <- updateExecutionConfig True p $ \_ ->
          ExecutionConfig Nothing (Map.fromList
            [ (mn "a", machine "a.example.com" 22 Nothing)
            , (mn "b", machine "b.example.com" 22 Nothing) ])
        res `shouldSatisfy` isLeft

    it "accepts a second machine when the update also sets a default" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        let p = executionFilePath (pathsAt dir)
        res <- updateExecutionConfig True p $ \_ ->
          ExecutionConfig (Just (mn "a")) (Map.fromList
            [ (mn "a", machine "a.example.com" 22 Nothing)
            , (mn "b", machine "b.example.com" 22 Nothing) ])
        res `shouldSatisfy` isRight

    it "serializes N concurrent updates with no lost machine" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        let p = executionFilePath (pathsAt dir)
            n = 10
        _ <- mapConcurrently
               (\i -> updateExecutionConfig True p $ \ec ->
                        let name = mn ("m" <> T.pack (show i))
                        in ec
                             { ecMachines = Map.insert name
                                 (machine ("m" <> T.pack (show i) <> ".example.com")
                                    22 Nothing)
                                 (ecMachines ec)
                               -- >= 2 machines require a default; pin it to the
                               -- first one written and leave it alone after.
                             , ecDefault  = case ecDefault ec of
                                 Nothing -> Just name
                                 d       -> d
                             })
               [1 .. n :: Int]
        fmap (fmap (Map.size . ecMachines)) (loadExecutionConfig True (pathsAt dir))
          `shouldReturn` Right n

    it "propagates a load error as Left without writing" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        let p = executionFilePath (pathsAt dir)
        writeInventory dir "this is = [not valid toml"
        res <- updateExecutionConfig True p id
        res `shouldSatisfy` isLeft

  describe "writer/encoder round-trip" $
    it "write -> load preserves identity, port and workspace" $
      withSystemTempDirectory "seal-exec" $ \dir -> do
        let p = executionFilePath (pathsAt dir)
            spec' = machine "b.example.com" 2222 (Just "/home/op/.ssh/id_ed25519")
        createDirectoryIfMissing True (spConfig (pathsAt dir))
        saveExecutionConfig p (ExecutionConfig (Just (mn "b"))
                                      (Map.fromList [(mn "b", spec')]))
        loaded <- loadExecutionConfig True (pathsAt dir)
        case loaded of
          Left e -> expectationFailure (T.unpack (render e))
          Right ec -> Map.lookup (mn "b") (ecMachines ec) `shouldBe` Just spec'

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

writeInventory :: FilePath -> Text -> IO ()
writeInventory dir body = do
  let cfgDir = dir </> "config"
  createDirectoryIfMissing True cfgDir
  TIO.writeFile (cfgDir </> "execution.toml") body

-- | Delete a @key = ...@ line from a fixture body.
omit :: Text -> Text -> Text
omit key = T.unlines . filter (not . T.isPrefixOf (key <> " =")) . T.lines

-- | Insert a line after the first line of a fixture body.
insert :: Text -> Text -> Text
insert line body = case T.lines body of
  (l:rest) -> T.unlines (l : line : rest)
  []       -> line <> "\n"

-- | Render an error for assertions (the payload shape is WU-7a's 400 body,
-- so tests assert on the rendered text, not on the constructor).
render :: TargetError -> Text
render = renderTargetError (TargetPaths "/x/config/execution.toml" "/x/security.toml")

mn :: Text -> MachineName
mn = either (error "fixture: MachineName") id . mkMachineName

machine :: Text -> Int -> Maybe Text -> SshMachineSpec
machine h port ident = SshMachineSpec
  { smsHost       = either (error "fixture: SshHost") id (mkSshHost h)
  , smsUser       = either (error "fixture: SshUser") id (mkSshUser "seal")
  , smsPort       = port
  , smsIdentity   = ident >>= either (const Nothing) Just . mkSshLocalPath
  , smsKnownHosts = either (error "fixture: known_hosts") id
                      (mkSshLocalPath "/home/op/.ssh/known_hosts")
  , smsWorkspace  = either (error "fixture: RemotePath") id
                      (mkRemotePath "/srv/seal/workspace")
  }

legacyRemoteFull :: UntrustedExecFileConfig
legacyRemoteFull = UntrustedExecFileConfig
  { uefcMode   = Just "remote"
  , uefcAllowLocalhost = Nothing
  , uefcRemote = Just UntrustedExecRemoteFileConfig
      { uerfcHost       = Just "legacy.example.com"
      , uerfcUser       = Just "seal"
      , uerfcPort       = Just 22
      , uerfcIdentity   = Nothing
      , uerfcKnownHosts = Just "/home/op/.ssh/known_hosts"
      , uerfcWorkspace  = Just "/srv/seal/legacy"
      }
  }

legacyIncomplete :: UntrustedExecFileConfig
legacyIncomplete = legacyRemoteFull
  { uefcRemote = fmap (\r -> r { uerfcWorkspace = Nothing })
                  (uefcRemote legacyRemoteFull) }
