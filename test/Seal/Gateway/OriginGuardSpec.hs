{-# LANGUAGE OverloadedStrings #-}
-- | RED tests for the mutation guard's pure verdict (issue #302, WU3).
--
-- The verdict is a pure function over two request headers and the canonical
-- origin the boot plan resolved once at startup (the same value WebAuthn
-- verifies @clientDataJSON.origin@ against). Keeping it pure is what makes the
-- whole 403 matrix — including the loopback-alias cases that keep @vite dev@ and
-- the e2e harness working — reachable without a socket or a config file.
module Seal.Gateway.OriginGuardSpec (spec) where

import Data.Text (Text)
import Data.Char (isDigit)
import Data.Text qualified as T
import Test.Hspec
import Test.QuickCheck

import Seal.Gateway.OriginGuard
  ( GuardHeaders (..), GuardVerdict (..), sameOriginVerdict )

spec :: Spec
spec = describe "Seal.Gateway.OriginGuard.sameOriginVerdict" $ do

  describe "no canonical origin (mode = none on a wildcard bind)" $ do
    it "allows a request with any headers" $
      allowed (sameOriginVerdict Nothing (GuardHeaders (Just "https://evil.example") (Just "cross-site")))
        `shouldBe` True
    it "allows a request with no headers at all" $
      allowed (sameOriginVerdict Nothing (GuardHeaders Nothing Nothing)) `shouldBe` True

  describe "an exact match" $ do
    it "allows the canonical origin" $
      allowed (sameOriginVerdict (Just "http://localhost:8080")
                 (GuardHeaders (Just "http://localhost:8080") Nothing))
        `shouldBe` True

  describe "a non-loopback canonical origin" $ do
    it "rejects a different scheme" $
      allowed (sameOriginVerdict (Just "http://seal.lan:8080")
                 (GuardHeaders (Just "https://seal.lan:8080") Nothing))
        `shouldBe` False
    it "rejects a different host" $
      allowed (sameOriginVerdict (Just "http://seal.lan:8080")
                 (GuardHeaders (Just "http://evil.example:8080") Nothing))
        `shouldBe` False
    it "rejects a different port" $
      allowed (sameOriginVerdict (Just "http://seal.lan:8080")
                 (GuardHeaders (Just "http://seal.lan:9999") Nothing))
        `shouldBe` False

  describe "a loopback canonical origin compares the scheme" $ do
    it "rejects an https origin against an http canonical" $
      allowed (sameOriginVerdict (Just "http://localhost:8080")
                 (GuardHeaders (Just "https://localhost:8080") Nothing))
        `shouldBe` False
    it "rejects an http origin against an https canonical" $
      allowed (sameOriginVerdict (Just "https://localhost:8080")
                 (GuardHeaders (Just "http://localhost:8080") Nothing))
        `shouldBe` False

  describe "a loopback canonical origin accepts any loopback alias" $ do
    it "accepts 127.0.0.1 on a different port (e2e harness, vite dev)" $
      allowed (sameOriginVerdict (Just "http://localhost:8080")
                 (GuardHeaders (Just "http://127.0.0.1:9999") Nothing))
        `shouldBe` True
    it "accepts another 127.0.0.0/8 address" $
      allowed (sameOriginVerdict (Just "http://localhost:8080")
                 (GuardHeaders (Just "http://127.1.2.3:8080") Nothing))
        `shouldBe` True
    it "accepts [::1]" $
      allowed (sameOriginVerdict (Just "http://localhost:8080")
                 (GuardHeaders (Just "http://[::1]:8080") Nothing))
        `shouldBe` True
    it "rejects a non-loopback host" $
      allowed (sameOriginVerdict (Just "http://localhost:8080")
                 (GuardHeaders (Just "http://10.0.0.1:8080") Nothing))
        `shouldBe` False
    it "rejects a host that merely looks loopback" $
      allowed (sameOriginVerdict (Just "http://localhost:8080")
                 (GuardHeaders (Just "http://localhost.evil.com:8080") Nothing))
        `shouldBe` False

  describe "malformed and opaque origins" $ do
    it "rejects Origin: null" $
      allowed (sameOriginVerdict (Just "http://localhost:8080")
                 (GuardHeaders (Just "null") Nothing))
        `shouldBe` False
    it "rejects an origin carrying a path" $
      allowed (sameOriginVerdict (Just "http://localhost:8080")
                 (GuardHeaders (Just "http://localhost:8080/evil") Nothing))
        `shouldBe` False
    it "tolerates a single trailing slash" $
      allowed (sameOriginVerdict (Just "http://localhost:8080")
                 (GuardHeaders (Just "http://localhost:8080/") Nothing))
        `shouldBe` True
    it "is case-insensitive on scheme and host" $
      allowed (sameOriginVerdict (Just "http://localhost:8080")
                 (GuardHeaders (Just "HTTP://LOCALHOST:8080") Nothing))
        `shouldBe` True
    it "rejects a scheme other than http/https" $
      allowed (sameOriginVerdict (Just "http://localhost:8080")
                 (GuardHeaders (Just "file://localhost") Nothing))
        `shouldBe` False

  describe "requests without Origin (curl, chat channels)" $ do
    it "allows absent fetch metadata" $
      allowed (sameOriginVerdict (Just "http://localhost:8080") (GuardHeaders Nothing Nothing))
        `shouldBe` True
    it "allows same-origin fetch metadata" $
      allowed (sameOriginVerdict (Just "http://localhost:8080")
                 (GuardHeaders Nothing (Just "same-origin")))
        `shouldBe` True
    it "allows none fetch metadata" $
      allowed (sameOriginVerdict (Just "http://localhost:8080")
                 (GuardHeaders Nothing (Just "none")))
        `shouldBe` True
    it "rejects cross-site fetch metadata" $
      allowed (sameOriginVerdict (Just "http://localhost:8080")
                 (GuardHeaders Nothing (Just "cross-site")))
        `shouldBe` False
    it "rejects same-site fetch metadata" $
      allowed (sameOriginVerdict (Just "http://localhost:8080")
                 (GuardHeaders Nothing (Just "same-site")))
        `shouldBe` False

  describe "properties" $ do
    it "a rejection always carries a reason" $
      property $ \a b c ->
        let v = sameOriginVerdict (pickCanon a) (GuardHeaders (pickOrigin b) (pickFetch c))
        in case v of
             Allowed      -> property True
             Rejected why -> property (not (T.null why))
    it "Allowed implies an acceptable origin" $
      property $ \a b c ->
        let canon   = pickCanon a
            headers = GuardHeaders (pickOrigin b) (pickFetch c)
        in allowed (sameOriginVerdict canon headers) ==> acceptable canon headers

-- Helpers -------------------------------------------------------------------

allowed :: GuardVerdict -> Bool
allowed Allowed      = True
allowed (Rejected _) = False

pickCanon :: Int -> Maybe Text
pickCanon n = case n `mod` 3 of
  0 -> Nothing
  1 -> Just "http://localhost:8080"
  _ -> Just "http://seal.lan:8080"

pickOrigin :: Int -> Maybe Text
pickOrigin n = case n `mod` 7 of
  0 -> Nothing
  1 -> Just "http://localhost:8080"
  2 -> Just "http://127.0.0.1:9999"
  3 -> Just "http://seal.lan:8080"
  4 -> Just "https://evil.example"
  5 -> Just "null"
  _ -> Just "https://localhost:8080"

pickFetch :: Int -> Maybe Text
pickFetch n = case n `mod` 4 of
  0 -> Nothing
  1 -> Just "same-origin"
  2 -> Just "cross-site"
  _ -> Just "none"

-- | An independent restatement of the rule set, deliberately written against
-- the raw strings rather than reusing the implementation's parser.
acceptable :: Maybe Text -> GuardHeaders -> Bool
acceptable canon (GuardHeaders mOrigin mSfs) = case (canon, mOrigin) of
  (Nothing, _) -> True
  (Just _, Nothing) -> mSfs `notElem` [Just "cross-site", Just "same-site"]
  (Just c, Just o) ->
    httpish o
      && (lower o == lower c
            || (schemeOf o == schemeOf c && loopbackCanon c && loopbackHost (hostOf o)))

schemeOf :: Text -> Text
schemeOf t = lower (T.takeWhile (/= ':') t)

httpish :: Text -> Bool
httpish t = "http://" `T.isPrefixOf` lower t || "https://" `T.isPrefixOf` lower t

lower :: Text -> Text
lower = T.toLower

hostOf :: Text -> Text
hostOf t =
  let authority = T.takeWhile (/= '/') (T.dropWhile (== '/') (snd (T.breakOnEnd "://" t)))
  in stripPort (T.toLower authority)
  where
    stripPort a
      | "[" `T.isPrefixOf` a = T.takeWhile (/= ']') a <> "]"
      | otherwise = case T.breakOnEnd ":" a of
          (pre, port)
            | not (T.null pre) && not (T.null port) && T.all isDigit port -> T.dropEnd 1 pre
          _ -> a

loopbackCanon :: Text -> Bool
loopbackCanon = loopbackHost . hostOf

loopbackHost :: Text -> Bool
loopbackHost h =
  h == "localhost"
    || h == "[::1]" || h == "::1"
    || (case T.splitOn "." h of
          (o : _) -> o == "127"
          []      -> False)
