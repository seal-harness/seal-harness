{-# LANGUAGE OverloadedStrings #-}
module Seal.SourceControl.RepoSpec (spec) where

import Control.Monad (forM_)
import Data.Aeson (Value (..), decode, encode, object, (.:), (.:?), (.=), withObject)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck hiding (Failure, Success)

import Toml qualified
import Validation (Validation (..))

import Seal.SourceControl.Repo

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------

mkRepo :: Text -> Text -> VcsKind -> RepoCredential -> (RepoId, SourceRepo)
mkRepo rid url kind cred =
  case mkRepoId rid of
    Right i  -> (i, SourceRepo i url kind cred Nothing Nothing)
    Left err -> error ("bad fixed repo id in test: " <> T.unpack err)

patRepo :: (RepoId, SourceRepo)
patRepo = mkRepo "seal-harness"
  "git@github.com:seal-harness/seal-harness.git"
  VcsGitHub
  (CredPat "GITHUB_PAT_SEAL_HARNESS")

deployRepo :: (RepoId, SourceRepo)
deployRepo = mkRepo "private-tool"
  "git@github.com:acme/private-tool.git"
  VcsGitHub
  (CredDeployKey "GITHUB_DEPLOYKEY_PRIVATE_TOOL")

machineRepo :: (RepoId, SourceRepo)
machineRepo = mkRepo "acme-infra"
  "git@github.com:acme/infra.git"
  VcsGitHub
  (CredMachineUser "GITHUB_MACHINEUSER_ACME" "acme-bot")

sampleMap :: Map RepoId SourceRepo
sampleMap = Map.fromList [patRepo, deployRepo, machineRepo]

-- | Round-trip a map through encode -> parse -> normalize -> decode.
roundTrip :: Map RepoId SourceRepo -> Validation [Toml.TomlDecodeError] (Map RepoId SourceRepo)
roundTrip m =
  let encoded = Toml.encode repoRegistryCodec m
  in case Toml.parse encoded of
       Left err   -> Failure [Toml.ParseError err]
       Right toml -> Toml.runTomlCodec repoRegistryCodec (normalizeReposTable toml)

-- | Decode a raw TOML text as a repo registry (with normalization).
decodeText :: Text -> Validation [Toml.TomlDecodeError] (Map RepoId SourceRepo)
decodeText txt =
  case Toml.parse txt of
    Left err   -> Failure [Toml.ParseError err]
    Right toml -> Toml.runTomlCodec repoRegistryCodec (normalizeReposTable toml)

isFailure :: Validation e a -> Bool
isFailure (Failure _) = True
isFailure (Success _) = False

isLeft :: Either a b -> Bool
isLeft (Left _)  = True
isLeft (Right _) = False

fromRight' :: Either a b -> b
fromRight' (Right b) = b
fromRight' (Left _)  = error "fromRight' on Left"

----------------------------------------------------------------------------
-- Spec
----------------------------------------------------------------------------

spec :: Spec
spec = describe "Seal.SourceControl.Repo" $ do

  --------------------------------------------------------------------------
  -- mkRepoId
  --------------------------------------------------------------------------
  describe "mkRepoId" $ do
    let bad = ["", "bad/id", "../x", "a/b", "with space", "dot.x", "has.dot"]
        good = ["ok", "ok-1", "ok_2", "Aaa-Bbb_123", "x"]
    forM_ bad $ \t ->
      it ("rejects " <> show t) $
        mkRepoId t `shouldSatisfy` isLeft
    forM_ good $ \t ->
      it ("accepts " <> show t) $
        case mkRepoId t of
          Right i  -> repoIdText i `shouldBe` t
          Left err -> expectationFailure ("expected Right, got Left: " <> T.unpack err)

  --------------------------------------------------------------------------
  -- Codec round-trip
  --------------------------------------------------------------------------
  describe "repoRegistryCodec round-trip" $ do
    it "round-trips a map with all three credential kinds" $
      roundTrip sampleMap `shouldBe` Success sampleMap

    it "round-trips a single PAT repo" $
      let m = Map.fromList [patRepo]
      in roundTrip m `shouldBe` Success m

    it "round-trips a single deploy-key repo" $
      let m = Map.fromList [deployRepo]
      in roundTrip m `shouldBe` Success m

    it "round-trips a single machine-user repo" $
      let m = Map.fromList [machineRepo]
      in roundTrip m `shouldBe` Success m

    it "round-trips a git (non-github) vcs_kind" $
      let (i, r) = mkRepo "git-server"
              "git@git.example.org:team/repo.git"
              VcsGit
              (CredDeployKey "GIT_DEPLOYKEY")
          m = Map.fromList [(i, r)]
      in roundTrip m `shouldBe` Success m

  --------------------------------------------------------------------------
  -- Absent -> empty
  --------------------------------------------------------------------------
  describe "absent repos table" $ do
    it "decodes empty TOML to an empty map" $
      Toml.runTomlCodec repoRegistryCodec mempty `shouldBe` Success Map.empty

    it "decodes a TOML with no [repos] table to an empty map" $
      decodeText "default_provider = \"ollama\"\n" `shouldBe` Success Map.empty

  --------------------------------------------------------------------------
  -- Fail-closed edges
  --------------------------------------------------------------------------
  describe "fail-closed decode" $ do
    it "rejects an unknown credential_kind" $ do
      let txt = T.unlines
            [ "[repos.bad]"
            , "url = \"git@github.com:o/r.git\""
            , "vcs_kind = \"github\""
            , "credential_kind = \"oauth\""
            , "vault_key = \"K\""
            ]
      decodeText txt `shouldSatisfy` isFailure

    it "rejects a missing vault_key" $ do
      let txt = T.unlines
            [ "[repos.bad]"
            , "url = \"git@github.com:o/r.git\""
            , "vcs_kind = \"github\""
            , "credential_kind = \"pat\""
            ]
      decodeText txt `shouldSatisfy` isFailure

    it "rejects machine_user without username" $ do
      let txt = T.unlines
            [ "[repos.bad]"
            , "url = \"git@github.com:o/r.git\""
            , "vcs_kind = \"github\""
            , "credential_kind = \"machine_user\""
            , "vault_key = \"K\""
            ]
      decodeText txt `shouldSatisfy` isFailure

    it "rejects an unknown vcs_kind" $ do
      let txt = T.unlines
            [ "[repos.bad]"
            , "url = \"git@github.com:o/r.git\""
            , "vcs_kind = \"hg\""
            , "credential_kind = \"pat\""
            , "vault_key = \"K\""
            ]
      decodeText txt `shouldSatisfy` isFailure

    it "rejects a missing url" $ do
      let txt = T.unlines
            [ "[repos.bad]"
            , "vcs_kind = \"github\""
            , "credential_kind = \"pat\""
            , "vault_key = \"K\""
            ]
      decodeText txt `shouldSatisfy` isFailure

    it "rejects a bad repo id key" $ do
      let txt = T.unlines
            [ "[repos.\"bad/id\"]"
            , "url = \"git@github.com:o/r.git\""
            , "vcs_kind = \"github\""
            , "credential_kind = \"pat\""
            , "vault_key = \"K\""
            ]
      decodeText txt `shouldSatisfy` isFailure

    it "accepts machine_user with username" $ do
      let txt = T.unlines
            [ "[repos.acme]"
            , "url = \"git@github.com:o/r.git\""
            , "vcs_kind = \"github\""
            , "credential_kind = \"machine_user\""
            , "vault_key = \"K\""
            , "username = \"bot\""
            ]
      case decodeText txt of
        Success m   -> Map.size m `shouldBe` 1
        Failure err -> expectationFailure ("decode failed: " <> T.unpack (Toml.prettyTomlDecodeErrors err))

  --------------------------------------------------------------------------
  -- normalizeReposTable
  --------------------------------------------------------------------------
  describe "normalizeReposTable" $ do
    let handWritten = T.unlines
          [ "[repos.foo]"
          , "url = \"git@github.com:o/r.git\""
          , "vcs_kind = \"github\""
          , "credential_kind = \"pat\""
          , "vault_key = \"K\""
          ]
    it "WITHOUT normalization yields empty (the tomland implicit-table bug)" $
      case Toml.parse handWritten of
        Right toml -> Toml.runTomlCodec repoRegistryCodec toml `shouldBe` Success Map.empty
        Left err   -> expectationFailure ("parse failed: " <> T.unpack (Toml.unTomlParseError err))

    it "WITH normalization yields the non-empty map" $
      case Toml.parse handWritten of
        Right toml ->
          case Toml.runTomlCodec repoRegistryCodec (normalizeReposTable toml) of
            Success m   -> Map.size m `shouldBe` 1
            Failure err -> expectationFailure ("decode failed: " <> T.unpack (Toml.prettyTomlDecodeErrors err))
        Left err -> expectationFailure ("parse failed: " <> T.unpack (Toml.unTomlParseError err))

  --------------------------------------------------------------------------
  -- URL helpers
  --------------------------------------------------------------------------
  describe "parseRepoHost" $ do
    it "parses an SSH GitHub URL" $
      parseRepoHost "git@github.com:seal-harness/seal-harness.git" `shouldBe` Right "github.com"

    it "parses an HTTPS GitHub URL" $
      parseRepoHost "https://github.com/seal-harness/seal-harness.git" `shouldBe` Right "github.com"

    it "parses an HTTPS URL without trailing .git" $
      parseRepoHost "https://github.com/seal-harness/seal-harness" `shouldBe` Right "github.com"

    it "rejects an empty URL" $
      parseRepoHost "" `shouldSatisfy` isLeft

    it "rejects a non-URL string" $
      parseRepoHost "not a url at all" `shouldSatisfy` isLeft

    it "rejects an scp-form URL missing the colon" $
      parseRepoHost "git@github.com-owner/repo.git" `shouldSatisfy` isLeft

    it "parses an ssh:// GitHub URL" $
      parseRepoHost "ssh://git@github.com/seal-harness/seal-harness.git" `shouldBe` Right "github.com"

    it "parses an ssh:// URL without a user@" $
      parseRepoHost "ssh://github.com/seal-harness/seal-harness.git" `shouldBe` Right "github.com"

    it "parses an ssh:// URL with a port" $
      parseRepoHost "ssh://git@github.com:2222/seal-harness/seal-harness.git" `shouldBe` Right "github.com"

    it "rejects an ssh:// URL with no host" $
      parseRepoHost "ssh:///path/to/repo" `shouldSatisfy` isLeft

  describe "hostAllowed" $ do
    it "allows github.com for github repos" $
      hostAllowed VcsGitHub "github.com" `shouldBe` True

    it "rejects an unknown host for github repos" $
      hostAllowed VcsGitHub "evil.example.org" `shouldBe` False

    it "allows any host for git repos" $ do
      hostAllowed VcsGit "evil.example.org" `shouldBe` True
      hostAllowed VcsGit "192.168.80.201" `shouldBe` True
      hostAllowed VcsGit "neb-arrakis" `shouldBe` True

    it "isGithubHost identifies GitHub hosts" $ do
      isGithubHost "github.com" `shouldBe` True
      isGithubHost "evil.example.org" `shouldBe` False

    it "githubHosts is the GitHub allow-list" $
      githubHosts `shouldBe` ["github.com"]

  describe "urlShapeValid" $ do
    it "accepts an SSH GitHub URL" $
      urlShapeValid "git@github.com:owner/repo.git" `shouldBe` True

    it "accepts an HTTPS GitHub URL" $
      urlShapeValid "https://github.com/owner/repo.git" `shouldBe` True

    it "accepts an ssh:// URL" $
      urlShapeValid "ssh://git@github.com/owner/repo.git" `shouldBe` True

    it "accepts an ssh:// URL without user@" $
      urlShapeValid "ssh://github.com/owner/repo.git" `shouldBe` True

    it "rejects an empty URL" $
      urlShapeValid "" `shouldBe` False

    it "rejects a plain string" $
      urlShapeValid "not a url" `shouldBe` False

    prop "valid SSH and HTTPS forms parse to an allowed host" $
      \(NonEmptyText' owner) (NonEmptyText' repo) ->
        let ssh    = "git@github.com:" <> owner <> "/" <> repo <> ".git"
            https  = "https://github.com/" <> owner <> "/" <> repo <> ".git"
            sshScheme = "ssh://git@github.com/" <> owner <> "/" <> repo <> ".git"
        in conjoin
             [ parseRepoHost ssh   === Right "github.com"
             , hostAllowed VcsGitHub (fromRight' (parseRepoHost ssh)) === True
             , urlShapeValid ssh === True
             , parseRepoHost https === Right "github.com"
             , hostAllowed VcsGitHub (fromRight' (parseRepoHost https)) === True
             , urlShapeValid https === True
             , parseRepoHost sshScheme === Right "github.com"
             , hostAllowed VcsGitHub (fromRight' (parseRepoHost sshScheme)) === True
             , urlShapeValid sshScheme === True
             ]

  --------------------------------------------------------------------------
  -- vcsKindText / parseVcsKind / repoCredentialKindText / parseCredentialKind
  --------------------------------------------------------------------------
  describe "vcsKindText / parseVcsKind" $ do
    it "vcsKindText rounds git/github" $ do
      vcsKindText VcsGit `shouldBe` "git"
      vcsKindText VcsGitHub `shouldBe` "github"
    it "parseVcsKind accepts known kinds" $ do
      parseVcsKind "git" `shouldBe` Right VcsGit
      parseVcsKind "github" `shouldBe` Right VcsGitHub
    it "parseVcsKind rejects unknown kinds" $
      parseVcsKind "hg" `shouldSatisfy` isLeft

  describe "repoCredentialKindText / parseCredentialKind" $ do
    it "repoCredentialKindText maps each constructor" $ do
      repoCredentialKindText (CredPat "K") `shouldBe` "pat"
      repoCredentialKindText (CredDeployKey "K") `shouldBe` "deploy_key"
      repoCredentialKindText (CredMachineUser "K" "u") `shouldBe` "machine_user"
    it "parseCredentialKind builds a PAT" $
      parseCredentialKind "pat" "K" Nothing `shouldBe` Right (CredPat "K")
    it "parseCredentialKind builds a deploy key" $
      parseCredentialKind "deploy_key" "K" Nothing `shouldBe` Right (CredDeployKey "K")
    it "parseCredentialKind builds a machine user with username" $
      parseCredentialKind "machine_user" "K" (Just "bot") `shouldBe` Right (CredMachineUser "K" "bot")
    it "parseCredentialKind rejects machine_user without username" $
      parseCredentialKind "machine_user" "K" Nothing `shouldSatisfy` isLeft
    it "parseCredentialKind rejects an unknown kind" $
      parseCredentialKind "oauth" "K" Nothing `shouldSatisfy` isLeft
    it "parseCredentialKind rejects an empty vault_key" $
      parseCredentialKind "pat" "" Nothing `shouldSatisfy` isLeft

  --------------------------------------------------------------------------
  -- JSON round-trip
  --------------------------------------------------------------------------
  describe "SourceRepo JSON" $ do
    it "round-trips a PAT repo" $ do
      let (_, r) = patRepo
      decode (encode r) `shouldBe` Just r

    it "round-trips a deploy-key repo" $ do
      let (_, r) = deployRepo
      decode (encode r) `shouldBe` Just r

    it "round-trips a machine-user repo" $ do
      let (_, r) = machineRepo
      decode (encode r) `shouldBe` Just r

    it "emits the descriptor shape {id,url,vcs_kind,credential:{kind,vault_key}}" $ do
      let (_, r) = patRepo
          parsed :: Maybe (Text, Text, Text, Text)
          parsed = decode (encode r) >>= parseMaybe (withObject "repo" $ \o -> do
            i <- o .: "id"
            u <- o .: "url"
            k <- o .: "vcs_kind"
            ck <- o .: "credential" >>= credKind
            pure (i, u, k, ck))
      parsed `shouldBe` Just ("seal-harness", "git@github.com:seal-harness/seal-harness.git", "github", "pat")

    it "credential has username only for machine_user" $ do
      let (_, rMu) = machineRepo
          parsed = decode (encode rMu) >>= parseMaybe (withObject "repo" $ \o -> do
            cred <- o .: "credential"
            (,) <$> credKind cred <*> credUsername cred)
      parsed `shouldBe` Just ("machine_user", Just "acme-bot")

    it "does NOT emit any field named token/value/secret" $ do
      let (_, r) = patRepo
      case decode (encode r) :: Maybe Value of
        Just (Object o) ->
          let ks = map Key.toText (KeyMap.keys o)
          in ("token" `elem` ks || "value" `elem` ks || "secret" `elem` ks) `shouldBe` False
        _ -> expectationFailure "expected a JSON object"

    it "machine_user without username is rejected by FromJSON" $ do
      let v = object
            [ "id" .= ("x" :: Text)
            , "url" .= ("https://github.com/o/r.git" :: Text)
            , "vcs_kind" .= ("github" :: Text)
            , "credential" .= object
                [ "kind" .= ("machine_user" :: Text)
                , "vault_key" .= ("K" :: Text)
                ]
            ]
      (decode (encode (v :: Value)) :: Maybe SourceRepo) `shouldBe` Nothing

    it "round-trips via decode . encode for a generated repo" $
      property $ \(GenRepo i url kind cred) ->
        let r = SourceRepo i url kind cred Nothing Nothing
        in (decode (encode r) :: Maybe SourceRepo) === Just r

  --------------------------------------------------------------------------
  -- W1: lookupRepoByUrl (cross-scheme URL matching)
  --------------------------------------------------------------------------
  describe "lookupRepoByUrl" $ do
    let (crossSchemeId, sshRepo) = mkRepo "cross-scheme"
          "git@github.com:seal-harness/seal-harness.git"
          VcsGitHub
          (CredDeployKey "K")
        (crossHttpsId, httpsRepo) = mkRepo "cross-https"
          "https://github.com:acme/other.git"
          VcsGitHub
          (CredPat "K")
        (trailingId, trailingRepo) = mkRepo "trailing"
          "https://github.com:example/project"
          VcsGitHub
          (CredPat "K")
        reg = RepoRegistry (Map.fromList
                [ (crossSchemeId, sshRepo)
                , (crossHttpsId,  httpsRepo)
                , (trailingId,     trailingRepo)
                ])
    it "finds an SSH-registered repo via its HTTPS form" $
      lookupRepoByUrl "https://github.com/seal-harness/seal-harness.git" reg
        `shouldBe` Just sshRepo
    it "finds an SSH-registered repo via its HTTPS form without trailing .git" $
      lookupRepoByUrl "https://github.com/seal-harness/seal-harness" reg
        `shouldBe` Just sshRepo
    it "finds an HTTPS-registered repo via its SSH form" $
      lookupRepoByUrl "git@github.com:acme/other.git" reg
        `shouldBe` Just httpsRepo
    it "finds a repo registered without .git via its .git form" $
      lookupRepoByUrl "https://github.com/example/project.git" reg
        `shouldBe` Just trailingRepo
    it "returns Nothing for an unregistered repo" $
      lookupRepoByUrl "git@github.com:other/other.git" reg
        `shouldBe` Nothing
    it "returns Nothing for an empty registry" $
      lookupRepoByUrl "git@github.com:seal-harness/seal-harness.git" (RepoRegistry Map.empty)
        `shouldBe` Nothing

  --------------------------------------------------------------------------
  -- W1: normalizeRepoUrl (shared — lives in SourceControl.Repo now)
  --------------------------------------------------------------------------
  describe "normalizeRepoUrl (shared)" $ do
    it "strips https:// scheme" $
      normalizeRepoUrl "https://github.com/o/r.git" `shouldBe` "github.com/o/r"
    it "strips SSH scp-form user@ and converts : to /" $
      normalizeRepoUrl "git@github.com:o/r.git" `shouldBe` "github.com/o/r"
    it "strips trailing .git without a trailing slash" $
      normalizeRepoUrl "https://github.com/o/r" `shouldBe` "github.com/o/r"
    it "lowercases the result" $
      normalizeRepoUrl "https://GitHub.com/O/R.git" `shouldBe` "github.com/o/r"
    it "treats SSH and HTTPS forms of the same repo as equal" $
      normalizeRepoUrl "git@github.com:o/r.git"
        `shouldBe` normalizeRepoUrl "https://github.com/o/r.git"

  --------------------------------------------------------------------------
  -- W1: CredAccountKey codec fail-closed (reserved constructor)
  --------------------------------------------------------------------------
  describe "account_key codec fail-closed" $ do
    it "parseCredentialKind rejects account_key" $
      parseCredentialKind "account_key" "K" Nothing `shouldSatisfy` isLeft
    it "TOML credentialCodec rejects credential_kind = account_key" $ do
      let txt = T.unlines
            [ "[repos.bad]"
            , "url = \"git@github.com:o/r.git\""
            , "vcs_kind = \"github\""
            , "credential_kind = \"account_key\""
            , "vault_key = \"K\""
            ]
      decodeText txt `shouldSatisfy` isFailure
    it "FromJSON rejects credential.kind = account_key" $ do
      let v = object
            [ "id" .= ("x" :: Text)
            , "url" .= ("https://github.com/o/r.git" :: Text)
            , "vcs_kind" .= ("github" :: Text)
            , "credential" .= object
                [ "kind" .= ("account_key" :: Text)
                , "vault_key" .= ("K" :: Text)
                ]
            ]
      (decode (encode (v :: Value)) :: Maybe SourceRepo) `shouldBe` Nothing

----------------------------------------------------------------------------
-- QuickCheck helpers
----------------------------------------------------------------------------

-- | A non-empty Text restricted to the RepoId charset.
newtype NonEmptyText' = NonEmptyText' Text
  deriving stock (Eq, Show)

instance Arbitrary NonEmptyText' where
  arbitrary = NonEmptyText' . T.pack <$> listOf1 (elements charset)
    where charset = ['A'..'Z'] <> ['a'..'z'] <> ['0'..'9'] <> "_-"

-- | A generated SourceRepo with a valid RepoId and a github.com URL shape.
data GenRepo = GenRepo RepoId Text VcsKind RepoCredential
  deriving stock (Eq, Show)

instance Arbitrary GenRepo where
  arbitrary = do
    NonEmptyText' rid <- arbitrary
    NonEmptyText' owner <- arbitrary
    NonEmptyText' repoName <- arbitrary
    kind <- elements [VcsGit, VcsGitHub]
    ssh <- arbitrary
    let url = (if ssh then "git@github.com:" else "https://github.com/") <> owner <> "/" <> repoName <> ".git"
    cred <- genCredential
    case mkRepoId rid of
      Right i  -> pure (GenRepo i url kind cred)
      Left _   -> pure (GenRepo (RepoId "fallback") url kind cred)
    where
      genCredential =
        oneof
          [ CredPat <$> genKey
          , CredDeployKey <$> genKey
          , CredMachineUser <$> genKey <*> (T.pack <$> listOf1 (elements userCharset))
          ]
      genKey = T.pack <$> listOf1 (elements keyCharset)
      keyCharset = ['A'..'Z'] <> ['0'..'9'] <> "_"
      userCharset = ['a'..'z'] <> ['0'..'9'] <> "-_"

-- | Parse the @kind@ text field out of a credential JSON object.
credKind :: Value -> Parser Text
credKind = withObject "credential" (.: "kind")

-- | Parse the optional @username@ field out of a credential JSON object.
credUsername :: Value -> Parser (Maybe Text)
credUsername = withObject "credential" (.:? "username")