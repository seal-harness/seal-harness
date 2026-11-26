{-# LANGUAGE OverloadedStrings #-}
module Seal.Execution.TypesSpec (spec) where

import Data.Either (isLeft, isRight)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck ()

import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Seal.Execution.Types
import Seal.Tools.Exec.Types
  ( SshConfig (..), mkRemotePath, mkSshHost, mkSshUser )

import Seal.TestHelpers.Arbitrary ()

-- | The charset @MachineName@ allows, mirroring the design's §3.2 rule.
isLegalNameChar :: Char -> Bool
isLegalNameChar c =
  isAsciiLower c || isAsciiUpper c || isDigit c || c == '_' || c == '-'

isNameStart :: Char -> Bool
isNameStart c = isAsciiLower c || isAsciiUpper c || isDigit c

paths :: TargetPaths
paths = TargetPaths
  { tpExecution = "/home/op/.seal/config/execution.toml"
  , tpSecurity  = "/home/op/.seal/security.toml"
  }

spec :: Spec
spec = describe "Seal.Execution.Types" $ do

  describe "mkMachineName" $ do

    prop "accepts iff the charset rule holds" $ \(t :: Text) ->
      case mkMachineName t of
        Right n -> machineNameText n == t
                     && not (T.null t)
                     && T.length t <= 64
                     && T.all isLegalNameChar t
                     && isNameStart (T.head t)
        Left _  -> T.null t
                     || T.length t > 64
                     || not (isNameStart (T.head t))
                     || T.any (not . isLegalNameChar) t
    prop "round-trips every accepted name" $ \(t :: Text) ->
      case mkMachineName t of
        Right n -> machineNameText n == t
        Left _  -> True

    prop "never accepts a name whose first character is not alphanumeric" $ \(t :: Text) ->
      case mkMachineName t of
        Right n -> T.head (machineNameText n) `notElem` ("_-." :: String)
        Left _  -> True

    it "accepts a plain name" $
      mkMachineName "builder" `shouldSatisfy` isRight

    it "accepts dashes and underscores after the first character" $
      mkMachineName "build-box_2" `shouldSatisfy` isRight

    it "accepts the reserved name local" $
      mkMachineName "local" `shouldSatisfy` isRight

    it "accepts the reserved name default" $
      mkMachineName "default" `shouldSatisfy` isRight

    it "rejects empty" $
      mkMachineName "" `shouldSatisfy` isLeft

    it "rejects a leading dot" $
      mkMachineName ".hidden" `shouldSatisfy` isLeft

    it "rejects a leading dash (option injection)" $
      mkMachineName "-oProxyCommand=x" `shouldSatisfy` isLeft

    it "rejects a leading underscore" $
      mkMachineName "_private" `shouldSatisfy` isLeft

    it "rejects a dot anywhere (no path segments)" $
      mkMachineName "a.b" `shouldSatisfy` isLeft

    it "rejects a path separator" $
      mkMachineName "a/b" `shouldSatisfy` isLeft

    it "rejects an embedded space" $
      mkMachineName "two words" `shouldSatisfy` isLeft

    it "accepts exactly 64 characters" $
      mkMachineName (T.replicate 64 "a") `shouldSatisfy` isRight

    it "rejects 65 characters" $
      mkMachineName (T.replicate 65 "a") `shouldSatisfy` isLeft

    prop "rejects a name containing any control character" $ \(t :: Text) ->
      let injected = "a" <> T.filter (not . isLegalNameChar) t <> "b"
      in case mkMachineName injected of
           Right n -> T.all isLegalNameChar (machineNameText n)
           Left _  -> True

  describe "mkSshLocalPath" $ do

    it "accepts an absolute path under .ssh" $
      mkSshLocalPath "/home/op/.ssh/id_ed25519" `shouldSatisfy` isRight

    it "accepts an absolute path under .seal" $
      mkSshLocalPath "/home/op/.seal/keys/known_hosts" `shouldSatisfy` isRight

    it "rejects a relative path" $
      mkSshLocalPath ".ssh/id_ed25519" `shouldSatisfy` isLeft

    it "rejects a parent segment" $
      mkSshLocalPath "/home/op/../etc/passwd" `shouldSatisfy` isLeft

    it "rejects a blocked segment that is neither .ssh nor .seal" $
      mkSshLocalPath "/home/op/.gnupg/foo" `shouldSatisfy` isLeft

    it "rejects whitespace (smuggles a second -o into UserKnownHostsFile=)" $
      mkSshLocalPath "/home/op/.ssh/known hosts" `shouldSatisfy` isLeft

    it "rejects an embedded equals sign" $
      mkSshLocalPath "/home/op/.ssh/a=b" `shouldSatisfy` isLeft

    it "rejects empty" $
      mkSshLocalPath "" `shouldSatisfy` isLeft

    prop "round-trips every accepted path" $ \(t :: Text) ->
      case mkSshLocalPath t of
        Right p -> T.pack (getSshLocalPath p) == t
        Left _  -> True

  describe "sshConfigFromMachine" $ do

    it "is field-preserving" $ do
      let m = builderMachine
          c = sshConfigFromMachine m
      scHost c `shouldBe` smsHost m
      scUser c `shouldBe` smsUser m
      scPort c `shouldBe` smsPort m
      scKnownHosts c `shouldBe` getSshLocalPath (smsKnownHosts m)
      scWorkspace c `shouldBe` smsWorkspace m

    it "preserves an absent identity as Nothing" $
      scIdentity (sshConfigFromMachine builderMachine) `shouldBe` Nothing

    it "preserves a present identity" $
      scIdentity (sshConfigFromMachine
                    builderMachine { smsIdentity = Just (sshLocalPath "/home/op/.ssh/id_ed25519") })
        `shouldBe` Just "/home/op/.ssh/id_ed25519"

  describe "ResolvedTarget" $ do

    it "targetSshConfig WhereLocal is Nothing" $
      targetSshConfig WhereLocal `shouldBe` Nothing

    it "targetSshConfig WhereSsh carries the machine's config" $
      targetSshConfig (WhereSsh (mn "builder") (sshConfigFromMachine builderMachine))
        `shouldBe` Just (sshConfigFromMachine builderMachine)

    it "targetLabel names the machine for WhereSsh" $
      targetLabel (WhereSsh (mn "builder") (sshConfigFromMachine builderMachine))
        `shouldBe` "builder"

    it "targetLabel for WhereLocal says whose local it is" $
      targetLabel WhereLocal `shouldBe` "This machine (where Seal runs)"

    it "orders distinct targets distinctly" $
      (WhereLocal :: ResolvedTarget) `shouldSatisfy` (< WhereSsh (mn "builder") (sshConfigFromMachine builderMachine))

  describe "renderTargetError" $ do

    it "TargetUnknownMachine names the machine, the available set and the screen" $ do
      let out = renderTargetError paths
                  (TargetUnknownMachine (mn "builder") [mn "a", mn "b"])
      out `shouldBe` "No execution machine named \"builder\"; available: a, b. \
                     \Start a new session pinned to one of them, or add one on \
                     \the Machines screen."

    it "TargetUnknownMachine says none when the inventory is empty" $ do
      let out = renderTargetError paths (TargetUnknownMachine (mn "builder") [])
      out `shouldSatisfy` T.isInfixOf "available: none"

    it "TargetLocalNotAllowed names the machine, the setting and the security path" $ do
      let out = renderTargetError paths (TargetLocalNotAllowed (mn "local"))
      out `shouldBe` "machine \"local\" runs on this host, but allow_localhost = \
                     \false in /home/op/.seal/security.toml. Set allow_localhost = \
                     \true, or start a new session pinned elsewhere."

    it "TargetConfigLoadError prefixes the execution path with the codec's reason" $ do
      renderTargetError paths (TargetConfigLoadError "unknown machine \"x\"")
        `shouldBe` "/home/op/.seal/config/execution.toml: unknown machine \"x\""

    it "TargetNoMachine names all three remedies" $ do
      let out = renderTargetError paths TargetNoMachine
      out `shouldBe` "No execution machine is configured. Add one on the Machines \
                     \screen, or add a [machines.<name>] block to \
                     \/home/op/.seal/config/execution.toml, or set allow_localhost = \
                     \true in /home/op/.seal/security.toml."

    it "takes both paths from TargetPaths, never a ~/.seal literal" $ do
      let odd_ = TargetPaths
            { tpExecution = "/srv/alt/seal/config/execution.toml"
            , tpSecurity  = "/srv/alt/seal/security.toml"
            }
          renderings =
            -- only these three name a path; TargetUnknownMachine names the
            -- Machines screen instead.
            [ renderTargetError odd_ (TargetLocalNotAllowed (mn "local"))
            , renderTargetError odd_ (TargetConfigLoadError "boom")
            , renderTargetError odd_ TargetNoMachine
            ]
      mapM_ (\r -> r `shouldSatisfy` T.isInfixOf "/srv/alt/seal") renderings
      mapM_ (\r -> r `shouldNotSatisfy` T.isInfixOf "~/.seal") renderings

    prop "is total over the available-set argument" $ \(av :: [Text]) ->
      T.length (renderTargetError paths (TargetUnknownMachine (mn "x") (mapMaybe mnOf av))) > 0

-- ---------------------------------------------------------------------------
-- fixtures
-- ---------------------------------------------------------------------------

-- | A name known to be legal, for fixtures that are not about name validation.
mn :: Text -> MachineName
mn = either (error "test fixture: MachineName") id . mkMachineName

-- | Variant for property arguments, which may be illegal.
mnOf :: Text -> Maybe MachineName
mnOf = either (const Nothing) Just . mkMachineName

-- | A path known to be legal.
sshLocalPath :: Text -> SshLocalPath
sshLocalPath = either (error "test fixture: SshLocalPath") id . mkSshLocalPath

builderMachine :: SshMachineSpec
builderMachine = SshMachineSpec
  { smsHost       = either (error "test fixture: SshHost") id (mkSshHost "builder.example.com")
  , smsUser       = either (error "test fixture: SshUser") id (mkSshUser "seal")
  , smsPort       = 22
  , smsIdentity   = Nothing
  , smsKnownHosts = sshLocalPath "/home/op/.ssh/known_hosts"
  , smsWorkspace  = either (error "test fixture: RemotePath") id (mkRemotePath "/srv/seal/workspace")
  }
