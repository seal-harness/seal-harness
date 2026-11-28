{-# LANGUAGE OverloadedStrings #-}
-- | WU-15 — the self-key guard: a "remote" machine must not be this machine.
--
-- Requirements: "Independently, when connecting, if the machine presents a host
-- key identical to the harness machine's own SSH host key, the connection is
-- refused. This catches a non-loopback name or address that still resolves to
-- this machine."
--
-- __The seam is the point.__ Design §3.2 notes revision 1 read
-- @~\/.ssh\/ssh_host_*_key.pub@ when sshd keys live in @/etc/ssh/@, and hardcoded
-- that path so no test could point it elsewhere. The key paths are therefore a
-- VALUE ('HostKeyPaths'), injected, so these tests run against a fixture
-- directory and the assertions fail for the right reason.
--
-- Note what is deliberately NOT here: a @getaddrinfo@ resolution-based loopback
-- refusal. Design §3.2 lists it as layer 1, but plan §0 P23 records that the
-- Scope reviewer struck it as "a third mechanism I invented" — the requirements
-- assign that case to this comparison. The two documents disagree; the
-- requirements win, so this is the mechanism.
module Seal.Tools.Exec.SelfKeyGuardSpec (spec) where

import Data.Text qualified as T
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Seal.Tools.Exec.HostKeyAdoption
  ( HostKeyPaths (..), defaultHostKeyPaths, isSelfHostKey )

spec :: Spec
spec = describe "WU-15 the self-key guard" $ do

  it "detects a presented key that matches one of the harness's own" $
    withSystemTempDirectory "selfkeys" $ \dir -> do
      let ownKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHarnessOwnKey host"
      writeFile (dir <> "/ssh_host_ed25519_key.pub") (T.unpack ownKey <> "\n")
      let paths = defaultHostKeyPaths { hkpSystemKeys = [dir <> "/ssh_host_ed25519_key.pub"] }
      found <- isSelfHostKey paths ownKey
      found `shouldBe` True

  it "does not flag a DIFFERENT key" $
    withSystemTempDirectory "selfkeys" $ \dir -> do
      writeFile (dir <> "/ssh_host_ed25519_key.pub")
        "ssh-ed25519 AAAAHarnessOwnKey host\n"
      let paths = defaultHostKeyPaths { hkpSystemKeys = [dir <> "/ssh_host_ed25519_key.pub"] }
      found <- isSelfHostKey paths "ssh-ed25519 AAAASomeoneElsesKey other"
      found `shouldBe` False

  it "compares the KEY MATERIAL, not the whole line" $
    -- ssh-keyscan writes `<host> <type> <key>`; /etc/ssh writes `<type> <key>
    -- [comment]`. Comparing whole lines would never match, and the guard would
    -- silently never fire — the worst failure mode for a security check.
    withSystemTempDirectory "selfkeys" $ \dir -> do
      writeFile (dir <> "/ssh_host_ed25519_key.pub")
        "ssh-ed25519 AAAAMATCHME harness-comment\n"
      let paths = defaultHostKeyPaths { hkpSystemKeys = [dir <> "/ssh_host_ed25519_key.pub"] }
      found <- isSelfHostKey paths "builder.lan ssh-ed25519 AAAAMATCHME"
      found `shouldBe` True

  it "skips unreadable key paths rather than failing open or crashing" $
    -- Design §3.2 layer 3: "Unreadable ⇒ skipped, degrading from two defences
    -- to one." A guard that threw would take the whole connect path down on a
    -- distro that stores keys elsewhere.
    withSystemTempDirectory "selfkeys" $ \dir -> do
      let paths = defaultHostKeyPaths
            { hkpSystemKeys = [dir <> "/does-not-exist.pub"] }
      found <- isSelfHostKey paths "ssh-ed25519 AAAAMATCHME"
      found `shouldBe` False

  it "checks EVERY configured path, not just the first" $
    withSystemTempDirectory "selfkeys" $ \dir -> do
      writeFile (dir <> "/a.pub") "ssh-rsa AAAAFirst\n"
      writeFile (dir <> "/b.pub") "ssh-ed25519 AAAASecond\n"
      let paths = defaultHostKeyPaths
            { hkpSystemKeys = [dir <> "/a.pub", dir <> "/nonexistent.pub", dir <> "/b.pub"] }
      found <- isSelfHostKey paths "ssh-ed25519 AAAASecond"
      found `shouldBe` True

  it "the production default reads /etc/ssh, not ~/.ssh" $ do
    -- The bug design §3.2 records: revision 1 looked in ~/.ssh, where sshd does
    -- not keep its host keys, so the guard never fired in production.
    let isEtcSsh p = "/etc/ssh" `T.isPrefixOf` T.pack p
    hkpSystemKeys defaultHostKeyPaths `shouldSatisfy` all isEtcSsh
