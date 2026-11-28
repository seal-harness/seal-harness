{-# LANGUAGE OverloadedStrings #-}
module Seal.ISA.Ops.MachineSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Seal.Config.Machines (MachineName, Selectable (..), localMachineName, mkMachineName)
import Seal.Core.Types (OpName (..))
import Seal.ISA.Ops.Machine
import Seal.Tools.Exec.Machine
  ( MachineError (..), UnreachableReason (..), UnusableReason (..) )

spec :: Spec
spec = describe "Seal.ISA.Ops.Machine" $ do

  describe "machineField" $ do
    it "is Nothing when the property is absent" $
      machineField (object []) `shouldBe` Nothing

    it "is Nothing for an empty or blank string" $ do
      machineField (object ["machine" .= ("" :: String)]) `shouldBe` Nothing
      machineField (object ["machine" .= ("  " :: String)]) `shouldBe` Nothing

    it "reads the name when present" $
      machineField (object ["machine" .= ("mac-mini" :: String)]) `shouldBe` Just "mac-mini"

    it "is Nothing for a non-string value rather than failing" $
      machineField (object ["machine" .= (7 :: Int)]) `shouldBe` Nothing

  describe "renderMachineError — the frozen separator" $ do

    -- The requirements specify "<OP> failed: <body>" — ONE space, no colon
    -- after the opcode. The repo's own convention inside error bodies is
    -- "<OPNAME>: <msg>"; a frozen user-facing string is not paraphrased.
    it "uses a single space after the opcode name, not a colon" $ do
      let rendered = renderMachineError (OpName "SHELL_EXEC")
                       (MachineUnknown "macbook" [])
      rendered `shouldSatisfy` isPrefixOfText "SHELL_EXEC failed: "
      rendered `shouldNotSatisfy` isInfixOfText "SHELL_EXEC:"
      rendered `shouldNotSatisfy` isInfixOfText "SHELL_EXEC :"

  describe "renderMachineError — the frozen bodies" $ do

    it "unknown machine names the request and lists the choices" $
      renderMachineError (OpName "SHELL_EXEC")
        (MachineUnknown "macbook" [localMachineName, nm "linux-builder"])
        `shouldBe` "SHELL_EXEC failed: unknown execution machine \"macbook\". \
                   \Selectable machines: local, linux-builder."

    it "unusable machine names the condition but never the configured value" $ do
      let rendered = renderMachineError (OpName "SHELL_EXEC")
                       (MachineUnusable (nm "mac-mini") UrrMissingWorkspace)
      rendered `shouldBe`
        "SHELL_EXEC failed: execution machine \"mac-mini\" is unusable: \
        \workspace not configured. Fix it in ~/.seal/machines.toml."

    it "a loopback-host rejection says so without echoing a host" $ do
      let rendered = renderMachineError (OpName "SHELL_EXEC")
                       (MachineUnusable (nm "builder") UrrLoopbackHost)
      rendered `shouldSatisfy` isInfixOfText "its host is this machine"
      -- No host, address, or path may reach the model.
      rendered `shouldNotSatisfy` isInfixOfText "localhost"
      rendered `shouldNotSatisfy` isInfixOfText "127.0.0.1"

    it "deleted session machine says it is no longer configured" $
      renderMachineError (OpName "SHELL_EXEC") (MachineGone (nm "mac-mini"))
        `shouldBe` T.concat
          [ "SHELL_EXEC failed: this session runs on execution machine \"mac-mini\""
          , ", which is no longer configured. Resuming it on another machine would "
          , "run its work somewhere it never ran. Add \"mac-mini\" back to "
          , "~/.seal/machines.toml, or start a new session."
          ]

    it "no machine configured points at machines.toml" $
      renderMachineError (OpName "SHELL_EXEC") NoMachineSelected
        `shouldBe` "SHELL_EXEC failed: allow_localhost is false and no execution \
                   \machine is configured. Add one under [machines.<name>] in \
                   \~/.seal/machines.toml."

    it "host-key-changed explains the two readings and the fix" $ do
      let rendered = renderMachineError (OpName "SHELL_EXEC")
                       (MachineHostKeyChanged (nm "mac-mini"))
      rendered `shouldSatisfy` isInfixOfText "does not match the key recorded in ~/.seal/exec-known-hosts"
      rendered `shouldSatisfy` isInfixOfText "rebuilt"
      rendered `shouldSatisfy` isInfixOfText "intercepting"
      rendered `shouldSatisfy` isInfixOfText "remove its entry from that file"

    it "not-permitted explains allow_localhost" $ do
      let rendered = renderMachineError (OpName "SHELL_EXEC")
                       (MachineNotPermitted localMachineName)
      rendered `shouldSatisfy` isInfixOfText "allow_localhost is false"

    it "unreachable uses the typed reason, not free text" $ do
      let rendered = renderMachineError (OpName "SHELL_EXEC")
                       (MachineUnreachable (nm "mac-mini") UrConnectFailed)
      rendered `shouldBe`
        "SHELL_EXEC failed: execution machine \"mac-mini\" is not reachable: \
        \could not connect."

  describe "renderUnusableReason — payload-free" $ do
    it "names every condition without a value" $
      map renderUnusableReason
        [ UrrMissingHost, UrrMissingUser, UrrMissingWorkspace, UrrLoopbackHost
        , UrrInvalidHost, UrrInvalidWorkspace, UrrInvalidPort
        , UrrReservedName, UrrInvalidName ]
        `shouldBe`
        [ "host not configured", "user not configured", "workspace not configured"
        , "its host is this machine", "invalid host", "invalid workspace"
        , "invalid port", "reserved name", "invalid name" ]

  describe "machinePropertySchema" $ do

    it "renders an enum of the selectable names, local included" $ do
      let v = machinePropertySchema [SelLocal, SelMachine (nm "builder")]
      T.pack (show v) `shouldSatisfy` isInfixOfText "\"local\""
      T.pack (show v) `shouldSatisfy` isInfixOfText "\"builder\""

    it "omits local when it is not selectable" $ do
      let v = machinePropertySchema [SelMachine (nm "builder")]
      T.pack (show v) `shouldNotSatisfy` isInfixOfText "\"local\""

    it "tells the model that each machine has its own filesystem" $ do
      T.pack (show (machinePropertySchema [SelLocal]))
        `shouldSatisfy` isInfixOfText "own filesystem"

  describe "renderSelectableNames" $ do
    it "renders none for an empty list" $
      renderSelectableNames [] `shouldBe` "none"

    it "joins with a comma and space" $
      renderSelectableNames [nm "a", nm "b"] `shouldBe` "a, b"

-- Helpers -----------------------------------------------------------------

nm :: String -> MachineName
nm s = case mkMachineName (T.pack s) of
  Right n -> n
  Left e  -> error ("MachineSpec: invalid test machine name: " <> show e)

isPrefixOfText :: Text -> Text -> Bool
isPrefixOfText = T.isPrefixOf

isInfixOfText :: Text -> Text -> Bool
isInfixOfText = T.isInfixOf
