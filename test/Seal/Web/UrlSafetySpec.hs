{-# LANGUAGE OverloadedStrings #-}
module Seal.Web.UrlSafetySpec (spec) where

import Data.Either (isLeft, isRight)
import Test.Hspec

import Seal.Web.UrlSafety (isSafeUrl, isAlwaysBlockedUrl, UrlSafetyError (..))

spec :: Spec
spec = describe "Seal.Web.UrlSafety" $ do

  describe "isSafeUrl (pure pre-checks)" $ do

    it "rejects a non-http scheme" $ do
      e <- isSafeUrl "ftp://example.com/file"
      e `shouldSatisfy` isLeftWith (\case UseInvalidScheme _ -> True; _ -> False)

    it "rejects a missing host" $ do
      e <- isSafeUrl "http:///path"
      e `shouldSatisfy` isLeftWith' UseNoHost

    it "blocks cloud metadata hostname metadata.google.internal" $ do
      e <- isSafeUrl "http://metadata.google.internal/computeMetadata/v1/"
      e `shouldSatisfy` isLeftWith' (UseBlockedHost "metadata.google.internal")

    it "blocks cloud metadata IP 169.254.169.254" $ do
      e <- isSafeUrl "http://169.254.169.254/latest/meta-data/"
      e `shouldSatisfy` isLeftWith' (UseBlockedIp "169.254.169.254")

    it "blocks AWS ECS task metadata IP 169.254.170.2" $ do
      e <- isSafeUrl "http://169.254.170.2/v2/metadata"
      e `shouldSatisfy` isLeftWith' (UseBlockedIp "169.254.170.2")

    it "blocks Alibaba Cloud metadata 100.100.100.200" $ do
      e <- isSafeUrl "http://100.100.100.200/latest/meta-data/"
      e `shouldSatisfy` isLeftWith' (UseBlockedIp "100.100.100.200")

    it "blocks loopback 127.0.0.1" $ do
      e <- isSafeUrl "http://127.0.0.1:8080/admin"
      e `shouldSatisfy` isLeftWith' (UseBlockedIp "127.0.0.1")

    it "blocks localhost (literal IP 127.0.0.1)" $ do
      -- localhost is a hostname, not an IP literal; it resolves via DNS.
      -- On most systems localhost → 127.0.0.1, so this should be blocked.
      e <- isSafeUrl "http://localhost:8080/admin"
      e `shouldSatisfy` isLeft

    it "blocks private 10.x.x.x" $ do
      e <- isSafeUrl "http://10.0.0.1/internal"
      e `shouldSatisfy` isLeftWith' (UseBlockedIp "10.0.0.1")

    it "blocks private 192.168.x.x" $ do
      e <- isSafeUrl "http://192.168.1.1/router"
      e `shouldSatisfy` isLeftWith' (UseBlockedIp "192.168.1.1")

    it "blocks private 172.16.x.x" $ do
      e <- isSafeUrl "http://172.16.0.1/internal"
      e `shouldSatisfy` isLeftWith' (UseBlockedIp "172.16.0.1")

    it "does NOT block 172.32.x.x (outside the 172.16/12 range)" $ do
      e <- isSafeUrl "http://172.32.0.1/page"
      e `shouldSatisfy` isRight

    it "blocks CGNAT 100.64.x.x" $ do
      e <- isSafeUrl "http://100.64.0.1/vpn"
      e `shouldSatisfy` isLeftWith' (UseBlockedIp "100.64.0.1")

    it "does NOT block 100.128.0.1 (outside CGNAT)" $ do
      e <- isSafeUrl "http://100.128.0.1/page"
      e `shouldSatisfy` isRight

    it "blocks link-local 169.254.x.x (non-metadata)" $ do
      e <- isSafeUrl "http://169.254.1.1/test"
      e `shouldSatisfy` isLeftWith' (UseBlockedIp "169.254.1.1")

    it "blocks multicast 224.0.0.1" $ do
      e <- isSafeUrl "http://224.0.0.1/multicast"
      e `shouldSatisfy` isLeftWith' (UseBlockedIp "224.0.0.1")

    it "allows a public IP" $ do
      e <- isSafeUrl "http://93.184.216.34/"  -- example.com
      e `shouldSatisfy` isRight

    it "allows a public domain (passes pre-check; DNS may pass or fail)" $ do
      e <- isSafeUrl "https://example.com/page"
      -- The pre-check passes (example.com is not blocked); DNS resolution
      -- may succeed (example.com resolves to a public IP) — we only
      -- assert it's not blocked by the pre-check (not Left with a
      -- pre-check error).
      e `shouldSatisfy` \case
        Left (UseDnsFailed _) -> True   -- DNS may fail in CI/sandbox
        Left _                -> False  -- but no other pre-check error
        Right _               -> True

    it "allows https URLs" $ do
      e <- isSafeUrl "https://example.com/page"
      e `shouldSatisfy` \case
        Left (UseInvalidScheme _) -> False
        _ -> True

  describe "isAlwaysBlockedUrl" $ do

    it "blocks metadata.google.internal" $
      isAlwaysBlockedUrl "http://metadata.google.internal/x" `shouldBe` True

    it "blocks 169.254.169.254" $
      isAlwaysBlockedUrl "http://169.254.169.254/x" `shouldBe` True

    it "does NOT block example.com" $
      isAlwaysBlockedUrl "https://example.com/x" `shouldBe` False

-- | Assert the 'Either' is 'Left' with a specific error constructor.
isLeftWith :: (UrlSafetyError -> Bool) -> Either UrlSafetyError a -> Bool
isLeftWith p (Left e) = p e
isLeftWith _ _ = False

-- | Assert 'Left' with a specific error value (for equality-checkable errors).
isLeftWith' :: UrlSafetyError -> Either UrlSafetyError a -> Bool
isLeftWith' expected (Left e) = e == expected
isLeftWith' _ _ = False