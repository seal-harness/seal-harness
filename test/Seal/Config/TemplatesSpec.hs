{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
-- | The first-run config templates: do they document every option, and does
-- writing them change anything?
--
-- Two kinds of assertion live here, and they fail for different reasons:
--
-- * @content@: every key the codecs accept must be mentioned somewhere in its
--   template (otherwise a new option ships invisible), and every value written
--   out must resolve to exactly what an absent key resolves to (otherwise the
--   first run silently pins a policy on the operator).
-- * @writer and call sites@: never overwrite, never throw, never pre-empt the
--   security migration, and actually run from @seal serve@, @seal tui@ and
--   @seal access-control@.
--
-- The call-site guards embed the sources with @file-embed@ (the mechanism
-- 'Seal.Skills.Builtins' already uses) because nothing else can see a deleted
-- call: those three entry points bind ports, own a terminal, or probe a daemon,
-- so none of them can be driven from a test.
module Seal.Config.TemplatesSpec (spec) where

import Control.Monad (forM_)
import Data.FileEmbed (embedFile)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Language.Haskell.TH (litE, stringL)
import Language.Haskell.TH qualified as TH (runIO)
import System.Directory
  ( createDirectoryIfMissing, doesFileExist, getCurrentDirectory, getFileSize )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus, intersectFileModes)
import Test.Hspec
import Toml qualified

import Seal.Config.File
  ( AgentConfig (..), DelegationFileConfig (..), EmbeddingConfig (..)
  , ProviderConfig (..), RetrievalConfig (..), RuntimeConfig (..)
  , SkillsConfig (..), ToolTimeoutFileConfig (..), WebConfig (..)
  , WorkdirConfig (..), defaultMaxModelRetries, defaultMaxTurns
  , defaultModelRetryBaseDelayMs, defaultRetrievalMaxScanBytes
  , defaultRuntimeConfig
  , loadRuntimeConfig, maxTurnsConfig, onDemandSchemas
  , resolvedAutoloadSkill, resolvedAvailableAgents
  , resolvedAvailableSkills, resolvedCredentialToolGuidance
  , resolvedParallelToolGuidance, resolvedTaskCompletionGuidance
  , resolvedToolUseEnforcement, retrievalMaxScanBytes, runtimeConfigCodec
  , toolTimeoutConfig )
import Seal.Agent.Runtime.Delegation (fromFileConfig, resolveDelegationConfig)
import Seal.Tools.Timeout (defaultToolTimeoutConfig)
import Seal.Config.Migrate
  ( configHasLegacySecurityFields, migrateSecurityConfig )
import Seal.Config.Paths
  ( SealPaths (..), configFilePath, securityFilePath )
import Seal.Config.Security
  ( AccessControlFileConfig (..), SecurityConfig (..)
  , UntrustedExecFileConfig (..), UntrustedExecRemoteFileConfig (..)
  , decodeSecurityConfig, gatewayConfigFromSecurity, scUntrustedExec
  , scVaultKeyType, scVaultUnlock, securityConfigCodec, tomlKeyPaths )
import Seal.Config.Templates
  ( configTomlTemplate, ensureConfigTemplates, securityTomlTemplate )
import Seal.Core.AllowList (AllowList (..))
import Seal.Gateway.Config
  ( PartialGatewayConfig (..), defaultGatewayConfig, tlsEnabled )
import Seal.Signal.Config (SignalConfig (..))
import Seal.Telegram.Config (TelegramConfig (..))
import Seal.Vault.Backend (parseUnlockMode)

spec :: Spec
spec = describe "Seal.Config.Templates" $ do
  describe "templates decode" $ do
    it "config.toml parses and decodes" $
      withSystemTempDirectory "seal-templates" $ \dir -> do
        let path = dir </> "config.toml"
        TIO.writeFile path configTomlTemplate
        result <- loadRuntimeConfig path
        case result of
          Left err -> expectationFailure ("config.toml does not decode: " <> T.unpack err)
          Right _  -> pure ()

    it "security.toml parses and decodes" $
      case decodeSecurityConfig securityTomlTemplate of
        Left err -> expectationFailure ("security.toml does not decode: " <> T.unpack err)
        Right _  -> pure ()

  describe "the embedded copy is the file in the tree" $ do
    -- `file-embed` bakes the bytes in at compile time, and cabal-install does
    -- not monitor an .toml that is not a module source: editing a template and
    -- running an incremental build can leave the previous copy in the binary.
    -- Comparing against the file on disk turns that into a red test instead of
    -- a stale config template shipped to users.
    forM_ [("config", "config/templates/config.toml", configTomlTemplate),
           ("security", "config/templates/security.toml", securityTomlTemplate)]
      $ \(label, path, embedded) ->
          it ("matches " <> path) $
            withSystemTempDirectory "seal-templates" $ \_ -> do
              onDisk <- TIO.readFile (buildRoot </> path)
              if onDisk == embedded
                then pure ()
                else expectationFailure
                  ("the binary embedded a stale copy of " <> path
                    <> " (" <> T.unpack label
                    <> "); touch src/Seal/Config/Templates.hs and rebuild")

  describe "both templates survive their own writers" $ do
    -- The writers ('Seal.Config.Templates.seedFile' -> Data.Text.IO /
    -- 'Seal.Config.Security.writeSecretFile') encode through the process's
    -- locale, so under a C locale every non-ASCII character is truncated to its
    -- low byte. A template with an em dash in it would be corrupted on write.
    -- Keeping the sources ASCII makes the scaffolding encoding-independent.
    it "are pure ASCII" $ do
      let nonAscii = filter ((> 0x7F) . fromEnum)
      nonAscii (T.unpack configTomlTemplate) `shouldBe` []
      nonAscii (T.unpack securityTomlTemplate) `shouldBe` []

  describe "config.toml is not mistaken for a pre-split config" $ do
    -- Seal.Config.Migrate chooses between "move the values across" and
    -- "security.toml wins" by scanning config.toml for legacy markers. The
    -- template must never trip that scan, or every boot after the first would
    -- re-encode the file and drop its comments.
    it "carries no legacy security marker" $
      configHasLegacySecurityFields configTomlTemplate `shouldBe` False

  describe "every option is documented" $ do
    it "config.toml mentions every leaf key runtimeConfigCodec accepts" $ do
      let keys = leafKeys (Toml.encode runtimeConfigCodec sampleRuntimeConfig)
      keys `shouldSatisfy` (not . null)
      forM_ keys $ \key -> (key `T.isInfixOf` configTomlTemplate) `shouldBe` True

    it "security.toml mentions every leaf key securityConfigCodec accepts" $ do
      let keys = leafKeys (Toml.encode securityConfigCodec sampleSecurityConfig)
      keys `shouldSatisfy` (not . null)
      forM_ keys $ \key -> (key `T.isInfixOf` securityTomlTemplate) `shouldBe` True

    it "writes only keys the codec actually reads" $ do
      -- The coverage tests above catch a key that is missing. This catches the
      -- other direction: an active line whose key is misspelled (`hostn = ...`)
      -- decodes to nothing and would otherwise sit in the file forever, looking
      -- like configuration.
      let cfgKeys = leafKeys (Toml.encode runtimeConfigCodec sampleRuntimeConfig)
      let secKeys = leafKeys (Toml.encode securityConfigCodec sampleSecurityConfig)
      forM_ (activeKeyNames configTomlTemplate) $ \key ->
        (key `elem` cfgKeys) `shouldBe` True
      forM_ (activeKeyNames securityTomlTemplate) $ \key ->
        (key `elem` secKeys) `shouldBe` True

    it "commented-out tables carry a copy-pasteable header" $ do
      -- tomlKeyPaths omits table nodes, so a key name in prose would satisfy
      -- the two tests above while leaving no block to copy.
      forM_ ["# [providers.<label>]", "# [signal]", "# [telegram]", "# [workdir]"]
        $ \header -> (header `T.isInfixOf` configTomlTemplate) `shouldBe` True
      forM_ [ "# [untrusted_execution]", "# [untrusted_execution.remote]"
            , "# [access_control]" ]
        $ \header -> (header `T.isInfixOf` securityTomlTemplate) `shouldBe` True
      -- The remote block's six keys must be inside the block, not just anywhere.
      let remoteBlock = snd (T.breakOn "# [untrusted_execution.remote]"
                                    securityTomlTemplate)
      forM_ ["host", "user", "port", "identity", "known_hosts", "workspace"]
        $ \key -> (key `T.isInfixOf` remoteBlock) `shouldBe` True

  describe "written values resolve like absent keys" $ do
    it "keeps the loopback gateway default" $
      case decodeSecurityConfig securityTomlTemplate of
        Left err -> expectationFailure ("security.toml does not decode: " <> T.unpack err)
        Right sec -> do
          let resolved = gatewayConfigFromSecurity sec
          resolved `shouldBe` defaultGatewayConfig
          tlsEnabled resolved `shouldBe` False

    it "agrees with every exported resolver" $ withDecodedTemplate $ \tpl -> do
      let absent = defaultRuntimeConfig
      maxTurnsConfig tpl `shouldBe` maxTurnsConfig absent
      maxTurnsConfig tpl `shouldBe` defaultMaxTurns
      toolTimeoutConfig tpl `shouldBe` defaultToolTimeoutConfig
      retrievalMaxScanBytes tpl `shouldBe` defaultRetrievalMaxScanBytes
      onDemandSchemas tpl `shouldBe` onDemandSchemas absent
      resolvedAutoloadSkill tpl `shouldBe` resolvedAutoloadSkill absent
      resolvedAvailableSkills tpl `shouldBe` resolvedAvailableSkills absent
      resolvedParallelToolGuidance tpl `shouldBe` resolvedParallelToolGuidance absent
      resolvedToolUseEnforcement tpl `shouldBe` resolvedToolUseEnforcement absent
      resolvedTaskCompletionGuidance tpl `shouldBe` resolvedTaskCompletionGuidance absent
      resolvedCredentialToolGuidance tpl `shouldBe` resolvedCredentialToolGuidance absent
      resolvedAvailableAgents tpl `shouldBe` resolvedAvailableAgents absent

    it "agrees on the delegation tuple" $ withDecodedTemplate $ \tpl ->
      resolveDelegationConfig (fromFileConfig (rcDelegation tpl))
        `shouldBe` resolveDelegationConfig (fromFileConfig (rcDelegation defaultRuntimeConfig))

    it "agrees on the two retry knobs" $ withDecodedTemplate $ \tpl -> do
      rcMaxModelRetries tpl `shouldBe` Just defaultMaxModelRetries
      rcRetryBaseDelayMs tpl `shouldBe` Just defaultModelRetryBaseDelayMs

    it "leaves every commented-out section absent" $ withDecodedTemplate $ \tpl -> do
      -- The mirror of the security.toml guard below: a key that is meant to be
      -- commented out must not be live, or the template pins a policy the
      -- operator never chose.
      rcSignal tpl `shouldBe` Nothing
      rcTelegram tpl `shouldBe` Nothing
      rcWorkdir tpl `shouldBe` Nothing
      rcProviders tpl `shouldBe` Map.empty
      rcDefaultProvider tpl `shouldBe` Nothing
      rcDefaultModel tpl `shouldBe` Nothing
      rcDefaultAgent tpl `shouldBe` Nothing
      (rcDelegation tpl >>= dfcSubagentAutoApprove) `shouldBe` Nothing
      (rcWeb tpl >>= wcMaxFetchBytes) `shouldBe` Nothing

    it "writes the [web] defaults that are genuinely static" $ withDecodedTemplate $ \tpl -> do
      -- max_fetch_bytes is deliberately absent: its effective default is
      -- [retrieval] max_scan_bytes, so writing it would freeze that coupling.
      (rcWeb tpl >>= wcSearchProvider) `shouldBe` Just "parallel"
      (rcWeb tpl >>= wcSearchMaxResults) `shouldBe` Just 10
      (rcWeb tpl >>= wcSearXngUrl) `shouldBe` Just "http://localhost:8888"

    it "keeps security.toml inert" $
      case decodeSecurityConfig securityTomlTemplate of
        Left err -> expectationFailure ("security.toml does not decode: " <> T.unpack err)
        Right sec -> do
          -- Absence of [access_control] is what makes the gateway fail closed
          -- and mint its enrollment grant; a template must never pre-configure it.
          scAccessControl sec `shouldBe` Nothing
          -- Not written at all: the section is not inert under a build flag.
          scUntrustedExec sec `shouldBe` Nothing
          -- Written, and identical to the absent-key resolution.
          scVaultKeyType sec `shouldBe` Just "x25519"
          scVaultUnlock sec `shouldBe` Just "on_demand"
          parseUnlockMode (scVaultUnlock sec) `shouldBe` parseUnlockMode Nothing

  describe "ensureConfigTemplates" $ do
    it "creates both files on a fresh home, and only once" $
      withSealHome $ \paths -> do
        (created, warnings) <- ensureConfigTemplates paths
        warnings `shouldBe` []
        created `shouldBe` [configFilePath paths, securityFilePath paths]
        TIO.readFile (configFilePath paths) `shouldReturn` configTomlTemplate
        TIO.readFile (securityFilePath paths) `shouldReturn` securityTomlTemplate
        (createdAgain, warningsAgain) <- ensureConfigTemplates paths
        createdAgain `shouldBe` []
        warningsAgain `shouldBe` []

    it "creates security.toml with nothing group- or world-readable" $
      withSealHome $ \paths -> do
        _ <- ensureConfigTemplates paths
        st <- getFileStatus (securityFilePath paths)
        (fileMode st `intersectFileModes` 0o077) `shouldBe` 0

    it "leaves an existing file alone" $
      withSealHome $ \paths -> do
        -- A real boot runs Seal.Config.Paths.ensureSealDirs first.
        createDirectoryIfMissing True (spConfig paths)
        let mine = "# my own config\nmax_turns = 5\n"
        TIO.writeFile (configFilePath paths) mine
        (created, _) <- ensureConfigTemplates paths
        created `shouldBe` [securityFilePath paths]
        TIO.readFile (configFilePath paths) `shouldReturn` mine

    it "reports a failure instead of throwing, and still writes the other file" $
      withSealHome $ \paths -> do
        -- Make config.toml's parent a regular file, so that write cannot
        -- succeed while security.toml's still can.
        TIO.writeFile (spConfig paths) "not a directory"
        (created, warnings) <- ensureConfigTemplates paths
        length warnings `shouldBe` 1
        created `shouldBe` [securityFilePath paths]
        doesFileExist (configFilePath paths) `shouldReturn` False

    it "defers to the security migration while config.toml is pre-split" $
      withSealHome $ \paths -> do
        -- A pre-split install: vault settings still in config.toml, no
        -- security.toml. Creating the file here would make the migration take
        -- its "security.toml wins" branch and drop those settings.
        createDirectoryIfMissing True (spConfig paths)
        TIO.writeFile (configFilePath paths) "vault_unlock = \"startup\"\n"
        (created, warnings) <- ensureConfigTemplates paths
        created `shouldBe` []
        warnings `shouldBe` []
        doesFileExist (securityFilePath paths) `shouldReturn` False

        -- A real boot migrates first; the template must not then touch what the
        -- migration wrote.
        migrateSecurityConfig paths
        migrated <- TIO.readFile (securityFilePath paths)
        migrated `shouldSatisfy` T.isInfixOf "startup"
        (createdAfter, _) <- ensureConfigTemplates paths
        createdAfter `shouldBe` []
        TIO.readFile (securityFilePath paths) `shouldReturn` migrated

    it "survives the migration byte-for-byte when both templates are in place" $
      withSealHome $ \paths -> do
        _ <- ensureConfigTemplates paths
        snapshotBefore <- (,) <$> TIO.readFile (configFilePath paths)
                               <*> TIO.readFile (securityFilePath paths)
        migrateSecurityConfig paths
        snapshotAfter <- (,) <$> TIO.readFile (configFilePath paths)
                              <*> TIO.readFile (securityFilePath paths)
        snapshotAfter `shouldBe` snapshotBefore

    it "writes a non-empty config template" $
      withSealHome $ \paths -> do
        _ <- ensureConfigTemplates paths
        getFileSize (configFilePath paths) `shouldReturn` fromIntegral (T.length configTomlTemplate)

  describe "the bootstrap actually runs" $ do
    -- Nothing can drive these three entry points from a test: they bind ports,
    -- own a terminal, or probe a daemon. Guard the call sites textually.
    it "seal serve scaffolds after migrating" $ do
      ("ensureConfigTemplates paths" `T.isInfixOf` serveSource) `shouldBe` True
      ordered "migrateSecurityConfig paths" "ensureConfigTemplates paths" serveSource
        `shouldBe` True

    it "seal serve validates the host before it reaches Warp" $
      ordered "gatewayHostResolutionError hostResolves" "runGateway logger" serveSource
        `shouldBe` True

    it "seal tui scaffolds after migrating" $ do
      ("ensureConfigTemplates paths" `T.isInfixOf` tuiSource) `shouldBe` True
      ordered "migrateSecurityConfig paths" "ensureConfigTemplates paths" tuiSource
        `shouldBe` True

    it "seal access-control scaffolds too, because it writes security.toml" $
      ("ensureConfigTemplates paths" `T.isInfixOf` accessControlSource) `shouldBe` True

-- ---------------------------------------------------------------------------
-- Samples: every field Just, so a codec key that the template forgets shows up
-- ---------------------------------------------------------------------------

sampleRuntimeConfig :: RuntimeConfig
sampleRuntimeConfig = RuntimeConfig
  { rcDefaultProvider = Just "anthropic"
  , rcDefaultModel    = Just "claude-opus-4-8"
  , rcDefaultAgent    = Just "sample-agent"
  , rcProviders       = Map.fromList
      [("sample", ProviderConfig (Just "sample-model") (Just "https://example.com"))]
  , rcRetrieval       = Just (RetrievalConfig (Just 1024))
  , rcSignal          = Just (SignalConfig (Just "+15551230000") (Just 1998)
                               (AllowOnly (Set.singleton "+15551230001")))
  , rcTelegram        = Just (TelegramConfig (Just "sample-token") (Just 3900)
                               (AllowOnly (Set.singleton "12345")))
  , rcChannels        = Map.empty
  , rcDebugSessionTranscript = Just True
  , rcDebugModelResponses    = Just True
  , rcMaxModelRetries        = Just 3
  , rcRetryBaseDelayMs       = Just 1000
  , rcOnDemandSchemas        = Just True
  , rcDelegation      = Just (DelegationFileConfig (Just 3) (Just 600) (Just 3)
                               (Just True) (Just "sample") (Just "sample-model")
                               (Just "https://example.com") (Just "sample-key")
                               (Just "chat_completions") (Just True))
  , rcWeb             = Just (WebConfig (Just "https://search.example.com")
                               (Just ["search.example.com"]) (Just ["fetch.example.com"])
                               (Just 1024) (Just "parallel") (Just 10)
                               (Just "http://localhost:8888") (Just "sample-key"))
  , rcWorkdir         = Just (WorkdirConfig (Just True))
  , rcSkills          = Just (SkillsConfig (Just "seal-usage") (Just True))
  , rcAgent           = Just (AgentConfig (Just True) (Just True) (Just True)
                               (Just True) (Just True))
  , rcMaxTurns        = Just 90
  , rcToolTimeout     = Just (ToolTimeoutFileConfig (Just 120) (Just 600) (Just 3)
                               (Just 2000000) (Just 2.0) (Just 5000000)
                               (Just 50000) (Just 100000))
  , rcEmbedding       = Just (EmbeddingConfig (Just "engram") (Just "/bin/engram")
                               (Just "/idx"))
  }

sampleSecurityConfig :: SecurityConfig
sampleSecurityConfig = SecurityConfig
  { scVaultPath      = Just "/vault.age"
  , scVaultRecipient = Just "age1sample"
  , scVaultIdentity  = Just "/identity.txt"
  , scVaultUnlock    = Just "startup"
  , scVaultKeyType   = Just "x25519"
  , scUntrustedExec  = Just (UntrustedExecFileConfig "remote" (Just
      (UntrustedExecRemoteFileConfig (Just "builder.example.com") (Just "seal")
        (Just 22) (Just "/id_ed25519") (Just "/known_hosts") (Just "/workspace"))))
  , scAccessControl  = Just (AccessControlFileConfig (Just "passkey")
                               (Just "https://seal.example.com")
                               (Just "seal.example.com"))
  , scGateway        = Just (PartialGatewayConfig
      { pgcPort = Just 8080, pgcWsPort = Just 8080, pgcHost = Just "sample-host"
      , pgcStaticDir = Just "/srv/sample", pgcAllowedOrigins = ["https://sample"]
      , pgcTlsCert = Just "/c.pem", pgcTlsKey = Just "/k.pem", pgcTls = Just True
      , pgcTlsHosts = ["sample.lan"] })
  }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

withDecodedTemplate :: (RuntimeConfig -> IO ()) -> IO ()
withDecodedTemplate k =
  withSystemTempDirectory "seal-templates" $ \dir -> do
    let path = dir </> "config.toml"
    TIO.writeFile path configTomlTemplate
    result <- loadRuntimeConfig path
    case result of
      Left err -> expectationFailure ("config.toml does not decode: " <> T.unpack err)
      Right cfg -> k cfg

serveSource, tuiSource, accessControlSource :: Text
serveSource = TE.decodeUtf8 $(embedFile "src/Seal/Command/Serve.hs")
tuiSource = TE.decodeUtf8 $(embedFile "src/Seal/Tui.hs")
accessControlSource = TE.decodeUtf8 $(embedFile "src/Seal/Command/AccessControl.hs")

-- | The package root at compile time. Embedding it keeps the staleness checks
-- independent of the test process's working directory (other specs move it).
buildRoot :: FilePath
buildRoot = $((litE . stringL) =<< TH.runIO getCurrentDirectory)

-- | Key names of the template's /active/ assignment lines: not a comment, not
-- a table header.
activeKeyNames :: Text -> [Text]
activeKeyNames txt =
  [ T.strip (fst (T.breakOn "=" line))
  | raw <- T.lines txt
  , let line = T.strip raw
  , not (T.null line)
  , not ("#" `T.isPrefixOf` line)
  , not ("[" `T.isPrefixOf` line)
  , "=" `T.isInfixOf` line
  ]

-- | Leaf key names of every value-bearing key path in an encoded document.
leafKeys :: Text -> [Text]
leafKeys txt = case Toml.parse txt of
  Left _    -> []
  Right doc -> [ Toml.unPiece (last pieces)
               | pieces <- tomlKeyPaths doc, not (null pieces) ]

-- | Index of the last occurrence of @needle@, or 'Nothing'.
lastIndexOf :: Text -> Text -> Maybe Int
lastIndexOf needle hay
  | T.null needle = Nothing
  | otherwise =
      let (prefix, rest) = T.breakOnEnd needle hay
      in if T.null rest then Nothing
         else Just (T.length prefix - T.length needle)

-- | Does @first@ occur before @second@ (last occurrences, so import lines in a
-- header cannot decide the answer)?
ordered :: Text -> Text -> Text -> Bool
ordered first second hay = case (lastIndexOf first hay, lastIndexOf second hay) of
  (Just a, Just b) -> a < b
  _                -> False

withSealHome :: (SealPaths -> IO a) -> IO a
withSealHome action = withSystemTempDirectory "seal-home" $ \dir ->
  action SealPaths
    { spHome   = dir
    , spConfig = dir </> "config"
    , spState  = dir </> "state"
    , spKeys   = dir </> "keys"
    , spCache  = dir </> "cache"
    }
