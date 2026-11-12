{-# LANGUAGE OverloadedStrings #-}
-- | Tests for 'Seal.ISA.RepeatDetect' (session-read hardening WU4): the
-- pure verdict core, the canonical key, and the process-lifetime
-- per-session registry. Maintainer-confirmed thresholds: warn at ≥2
-- identical calls within the window, block at ≥4, window = last 16 calls.
module Seal.ISA.RepeatDetectSpec (spec) where

import Control.Monad (replicateM)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Test.Hspec
import Test.QuickCheck

import Seal.Core.Types (OpName (..), mkSystemSessionId)
import Seal.ISA.RepeatDetect

sessionManage :: OpName
sessionManage = OpName "SESSION_MANAGE"

sessionGet :: OpName
sessionGet = OpName "SESSION_GET"

-- | A small, bounded JSON value: depth ≤ 2, short strings, ≤ 3 object
-- keys / array elements. Big enough to exercise the encoder's object and
-- array paths; small enough to keep the suite sub-second.
newtype SmallJson = SmallJson { unSmallJson :: Value }
  deriving (Eq, Show)

instance Arbitrary SmallJson where
  arbitrary = SmallJson <$> genSmallValue 2

genSmallValue :: Int -> Gen Value
genSmallValue depth
  | depth <= 0 = genLeaf
  | otherwise = oneof
      [ genLeaf
      , Object . KeyMap.fromList <$> genBounded genEntry
      , Array . V.fromList <$> genBounded (genSmallValue (depth - 1))
      ]
  where
    genBounded gen = chooseInt (1, 3) >>= \n -> vectorOf n gen
    genEntry = do
      k <- elements ["a", "b", "c"]
      v <- genSmallValue (depth - 1)
      pure (Key.fromText k, v)
    genLeaf = oneof
      [ String . T.pack <$> listOf1 (elements ['a'..'e'])
      , Number . fromIntegral <$> chooseInt (0, 9 :: Int)
      , elements [Bool True, Bool False, Null]
      ]

-- | A bounded window over a 4-key alphabet (≤ 50 entries).
genWindow :: Gen [Text]
genWindow = do
  n <- chooseInt (0, 50)
  vectorOf n (elements ["k", "x", "y", "z"])

-- | Fold a list of canonical keys into a window (most recent first).
pushMany :: [Text] -> [Text]
pushMany = foldl' (flip stepWindow) []

-- | Count a key's occurrences in a window.
countIn :: Text -> [Text] -> Int
countIn key = length . filter (== key)

-- | Distinct filler keys ("o1", "o2", …) — distinct from each other and
-- from the key under test, matching the eviction scenario's "intervening
-- distinct calls".
fillers :: Int -> [Text]
fillers n = ["o" <> T.pack (show i) | i <- [1 .. n]]

-- | The canonical SESSION_MANAGE get input used by the behavioral tests.
getInput :: Value
getInput = object ["action" .= ("get" :: Text)]

spec :: Spec
spec = describe "Seal.ISA.RepeatDetect" $ do
  describe "repeatScope" $ do
    it "contains exactly SESSION_MANAGE and SESSION_GET" $ do
      Set.member sessionManage repeatScope `shouldBe` True
      Set.member sessionGet repeatScope `shouldBe` True
      Set.size repeatScope `shouldBe` 2

    it "excludes other opcodes (zero behavior change out of scope)" $
      Set.member (OpName "SHELL_EXEC") repeatScope `shouldBe` False

  describe "windowVerdict (pure core)" $ do
    it "1st occurrence in the window allows" $
      windowVerdict "k" ["k"] `shouldBe` RvAllow

    it "2nd and 3rd occurrences warn" $ do
      windowVerdict "k" ["k", "k"] `shouldBe` RvWarn
      windowVerdict "k" ["k", "k", "k"] `shouldBe` RvWarn

    it "4th and beyond block" $
      map (\n -> windowVerdict "k" (replicate n "k"))
          [4 .. 16] `shouldBe` replicate 13 RvBlock

    it "counts only the key under test" $
      windowVerdict "k" (replicate 15 "x" ++ ["k"]) `shouldBe` RvAllow

    it "window eviction: 16 intervening distinct calls make the key fresh again" $ do
      let window = pushMany (["k"] <> fillers 16)
      -- The original "k" was pushed out by the 16 fillers.
      countIn "k" window `shouldBe` 0
      windowVerdict "k" (stepWindow "k" window) `shouldBe` RvAllow

    it "eviction boundary: 14 intervening calls still warn, 15 evicts the original" $ do
      let after14 = stepWindow "k" (pushMany (["k"] <> fillers 14))
          after15 = stepWindow "k" (pushMany (["k"] <> fillers 15))
      countIn "k" after14 `shouldBe` 2
      windowVerdict "k" after14 `shouldBe` RvWarn
      countIn "k" after15 `shouldBe` 1
      windowVerdict "k" after15 `shouldBe` RvAllow

  describe "stepWindow (pure core)" $ do
    it "caps the window at repeatWindowCapacity entries" $
      [length (stepWindow "k" (replicate n "x")) | n <- [0 .. 25]]
        `shouldBe` [min repeatWindowCapacity (n + 1) | n <- [0 .. 25]]

    it "most recent first" $ do
      stepWindow "k" ["x", "y"] `shouldBe` ["k", "x", "y"]
      stepWindow "k" [] `shouldBe` ["k"]

  describe "canonicalKey (pure core)" $ do
    it "two structurally identical constructions share a key" $ do
      let v1 = object ["action" .= ("get" :: Text)]
          v2 = Object (KeyMap.fromList [(Key.fromText "action", String "get")])
      canonicalKey sessionManage v1 `shouldBe` canonicalKey sessionManage v2

    it "equal values (encode/decode round-trip) produce identical keys" $
      forAll (genSmallValue 2) $ \v ->
        case A.decode (A.encode v) of
          Just v' -> canonicalKey sessionManage v === canonicalKey sessionManage v'
          Nothing -> ioProperty (expectationFailure "aeson round-trip decode failed")

    it "repeated encoding of the same value yields the identical key" $
      forAll (genSmallValue 2) $ \v ->
        canonicalKey sessionGet v === canonicalKey sessionGet v

    it "the opcode name separates keys for identical inputs" $
      property $ \(SmallJson v) ->
        canonicalKey sessionManage v /= canonicalKey sessionGet v

  describe "QuickCheck properties (pure core)" $ do
    it "≥4 occurrences within the window always block" $
      forAll genWindow $ \w ->
        countIn "k" (stepWindow "k" w) >= 4 ==>
          windowVerdict "k" (stepWindow "k" w) === RvBlock

    it "monotonicity: once blocked, the next identical push stays blocked" $
      forAll genWindow $ \w ->
        windowVerdict "k" (stepWindow "k" w) == RvBlock ==>
          windowVerdict "k" (stepWindow "k" (stepWindow "k" w)) === RvBlock

    it "n identical calls in sequence: allow, warn, warn, then block (n ∈ [4, 8])" $
      forAll (chooseInt (4, 8)) $ \n ->
        let verdicts = go n []
            go 0 _ = []
            go i win =
              let win' = stepWindow "k" win
              in windowVerdict "k" win' : go (i - 1) win'
        in verdicts === RvAllow : RvWarn : RvWarn : replicate (n - 3) RvBlock

  describe "recordCall" $ do
    it "four identical calls: allow, warn, warn, block" $ do
      track <- newRepeatTrack
      verdicts <- replicateM 4 (recordCall track sessionManage getInput)
      verdicts `shouldBe` [RvAllow, RvWarn, RvWarn, RvBlock]

    it "distinct inputs never warn" $ do
      track <- newRepeatTrack
      verdicts <- mapM
        (\(i :: Int) -> recordCall track sessionManage (object ["offset" .= i]))
        [1 .. 4]
      verdicts `shouldBe` replicate 4 RvAllow

    it "different opcodes with identical inputs count independently" $ do
      track <- newRepeatTrack
      v1 <- recordCall track sessionManage getInput
      v2 <- recordCall track sessionGet getInput
      v1 `shouldBe` RvAllow
      v2 `shouldBe` RvAllow

    it "recording the same generated input twice warns on the second call" $
      property $ \(SmallJson v) -> ioProperty $ do
        track <- newRepeatTrack
        v1 <- recordCall track sessionManage v
        v2 <- recordCall track sessionManage v
        pure (v1 === RvAllow .&&. v2 === RvWarn)

    it "block is not permanent: 16 distinct intervening calls reset the counter" $ do
      track <- newRepeatTrack
      mapM_
        (\(i :: Int) ->
          recordCall track sessionManage (object ["action" .= ("get" :: Text), "n" .= i]))
        [1 .. 16]
      reset <- recordCall track sessionManage getInput
      reset `shouldBe` RvAllow

  describe "SessionRepeatRegistry" $ do
    it "lookupOrCreateRepeatTrack returns the same track for the same sid" $ do
      reg <- newSessionRepeatRegistry
      let sid = mkSystemSessionId "s1"
      t1 <- lookupOrCreateRepeatTrack reg sid
      t2 <- lookupOrCreateRepeatTrack reg sid
      v1 <- recordCall t1 sessionManage getInput
      v2 <- recordCall t2 sessionManage getInput
      v1 `shouldBe` RvAllow
      v2 `shouldBe` RvWarn

    it "process-lifetime: the window survives two separate lookups (a per-request registry fails this)" $ do
      reg <- newSessionRepeatRegistry
      let sid = mkSystemSessionId "s1"
      -- First "turn": look up, record one identical call.
      t1 <- lookupOrCreateRepeatTrack reg sid
      first_ <- recordCall t1 sessionManage getInput
      first_ `shouldBe` RvAllow
      -- Second "turn": a FRESH lookup must observe the SAME window.
      t2 <- lookupOrCreateRepeatTrack reg sid
      second_ <- recordCall t2 sessionManage getInput
      second_ `shouldBe` RvWarn

    it "per-session isolation: the same key under two sids has independent verdicts" $ do
      reg <- newSessionRepeatRegistry
      let sid1 = mkSystemSessionId "s1"
          sid2 = mkSystemSessionId "s2"
      t1 <- lookupOrCreateRepeatTrack reg sid1
      t2 <- lookupOrCreateRepeatTrack reg sid2
      _ <- recordCall t1 sessionManage getInput
      w1 <- recordCall t1 sessionManage getInput
      a2 <- recordCall t2 sessionManage getInput
      w1 `shouldBe` RvWarn
      a2 `shouldBe` RvAllow

    it "per-session isolation: two sessions count the same key independently" $ do
      reg <- newSessionRepeatRegistry
      let sid1 = mkSystemSessionId "s1"
          sid2 = mkSystemSessionId "s2"
      t1 <- lookupOrCreateRepeatTrack reg sid1
      t2 <- lookupOrCreateRepeatTrack reg sid2
      verdicts1 <- replicateM 4 (recordCall t1 sessionManage getInput)
      verdicts2 <- replicateM 4 (recordCall t2 sessionManage getInput)
      verdicts1 `shouldBe` [RvAllow, RvWarn, RvWarn, RvBlock]
      verdicts2 `shouldBe` [RvAllow, RvWarn, RvWarn, RvBlock]

    it "window eviction at 16 through the registry path" $ do
      reg <- newSessionRepeatRegistry
      let sid = mkSystemSessionId "s1"
      track <- lookupOrCreateRepeatTrack reg sid
      first_ <- recordCall track sessionManage getInput
      mapM_
        (\(i :: Int) ->
          recordCall track sessionManage (object ["action" .= ("get" :: Text), "n" .= i]))
        [1 .. 16]
      afterEviction <- recordCall track sessionManage getInput
      first_ `shouldBe` RvAllow
      afterEviction `shouldBe` RvAllow

  describe "messages" $ do
    it "the warn note is fixed and non-empty" $ do
      T.null repeatWarnNote `shouldBe` False
      repeatWarnNote `shouldBe`
        "[note: repeated identical session read — no new information expected]"

    it "the blocked message names the opcode and is actionable" $ do
      let msg = repeatBlockedMessage sessionManage
      msg `shouldSatisfy` ("blocked: repeated identical SESSION_MANAGE call" `T.isPrefixOf`)
      msg `shouldSatisfy` ("refine the request or move on" `T.isInfixOf`)