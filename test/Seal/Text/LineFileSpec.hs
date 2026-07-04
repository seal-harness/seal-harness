{-# LANGUAGE OverloadedStrings #-}
module Seal.Text.LineFileSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

import Seal.Core.Paging
import Seal.Security.Path (SafePath, WorkspaceRoot (..), mkSafePath)
import Seal.TestHelpers.Arbitrary ()
import Seal.Text.LineFile

-- | Lines drawn from a small alphabet, no newlines inside.
genLines :: Gen [Text]
genLines = listOf (T.pack <$> listOf (elements "abc "))

-- | Helper: write a file under a temp workspace and return its SafePath.
withSafeFile :: FilePath -> ByteString -> (SafePath -> IO a) -> IO a
withSafeFile dir content action = do
  let fp = dir </> "f.txt"
  BS.writeFile fp content
  Right safe <- mkSafePath (WorkspaceRoot dir) "f.txt"
  action safe

spec :: Spec
spec = describe "Seal.Text.LineFile" $ do

  ---------------------------------------------------------------------------
  -- Line semantics (pinned: T.lines)
  ---------------------------------------------------------------------------

  describe "line semantics (T.lines)" $ do
    it "\"a\\nb\\nc\\n\" -> 3 lines" $
      T.lines "a\nb\nc\n" `shouldBe` ["a", "b", "c"]
    it "\"a\\nb\\nc\" (no final newline) -> 3 lines" $
      T.lines "a\nb\nc" `shouldBe` ["a", "b", "c"]
    it "\"\" -> 0 lines" $
      T.lines "" `shouldBe` []

  ---------------------------------------------------------------------------
  -- windowLines (pure)
  ---------------------------------------------------------------------------

  describe "windowLines" $ do

    it "defaultPageParams first window of 320 lines is 72, hasMore True" $ do
      let ls  = [T.pack (show n) | n <- [1..320 :: Int]]
          win = windowLines defaultPageParams 0 Nothing ls
      length (lwLines win) `shouldBe` 72
      lwStart win `shouldBe` 0
      lwEnd win `shouldBe` 72
      lwTotal win `shouldBe` 320
      lwHasMore win `shouldBe` True
      lwTruncated win `shouldBe` False

    it "offset past end -> empty window, hasMore False" $ do
      let ls  = ["a", "b", "c"]
          win = windowLines defaultPageParams 10 Nothing ls
      lwLines win `shouldBe` []
      lwHasMore win `shouldBe` False
      lwStart win `shouldBe` 3
      lwEnd win `shouldBe` 3

    it "explicit limit is honored (and clamped to ceiling)" $ do
      let ls  = [T.pack (show n) | n <- [1..1000 :: Int]]
          win = windowLines defaultPageParams 0 (Just 5) ls
      length (lwLines win) `shouldBe` 5
      lwEnd win `shouldBe` 5

    it "explicit limit above ceiling clamps to ceiling" $ do
      let ls  = [T.pack (show n) | n <- [1..1000 :: Int]]
          win = windowLines defaultPageParams 0 (Just 10000) ls
      length (lwLines win) `shouldBe` 200

    prop "lwEnd == lwStart + length lwLines" $ \offset mLimit (ls :: [Text]) ->
      let win = windowLines defaultPageParams offset mLimit ls
      in lwEnd win == lwStart win + length (lwLines win)

    prop "lwLines is a contiguous slice, order preserved" $ \offset mLimit (ls :: [Text]) ->
      let win  = windowLines defaultPageParams offset mLimit ls
          size = windowSize defaultPageParams (length ls) mLimit
      in lwLines win == take size (drop (lwStart win) ls)

    prop "lwHasMore iff lwEnd < lwTotal (pure path, not truncated)" $ \offset mLimit (ls :: [Text]) ->
      let win = windowLines defaultPageParams offset mLimit ls
      in lwHasMore win == (lwEnd win < lwTotal win)

    prop "REASSEMBLY: paging from 0 with successive lwEnd reconstructs the T.lines list" $
      forAll (resize 50 genLines) $ \ls ->
        let tot = length ls
            reassemble from acc
              | from >= tot = acc
              | otherwise =
                  let win = windowLines defaultPageParams from Nothing ls
                  in reassemble (lwEnd win) (acc <> lwLines win)
        in reassemble 0 [] == ls

  ---------------------------------------------------------------------------
  -- renderWindow (all six ordered states)
  ---------------------------------------------------------------------------

  describe "renderWindow" $ do

    -- Guard 6: final window
    it "final window footer (guard 6)" $ do
      let ls  = ["a", "b", "c"]
          win = windowLines defaultPageParams 0 (Just 3) ls
      renderWindow win `shouldBe` "a\nb\nc\n\n[lines 1-3 of 3 (end of file)]"

    -- Guard 5: more lines
    it "more-lines footer (guard 5)" $ do
      let ls  = ["a", "b", "c", "d"]
          win = windowLines defaultPageParams 0 (Just 2) ls
      renderWindow win `shouldBe` "a\nb\n\n[lines 1-2 of 4; 2 more - read with offset=2 for the next window]"

    -- Guard 3 (non-truncated): offset past end
    it "offset past end footer (guard 3, non-truncated)" $ do
      let ls  = ["a", "b", "c"]
          win = windowLines defaultPageParams 10 Nothing ls
      renderWindow win `shouldBe` "[offset 3 is past end of file (3 lines); read with offset=0 to start over]"

    -- Guard 2: empty file
    it "empty file footer (guard 2)" $ do
      let win = windowLines defaultPageParams 0 Nothing []
      renderWindow win `shouldBe` "[empty file (0 lines)]"

    -- Guards 1 and 4 require lwTruncated, which windowLines never sets; we
    -- exercise them by constructing LineWindow directly here (and via the IO
    -- path below).
    it "guard 1: empty file truncated footer" $ do
      let win = LineWindow { lwLines = [], lwStart = 0, lwEnd = 0
                           , lwTotal = 0, lwHasMore = True, lwTruncated = True }
      renderWindow win `shouldBe`
        "[no line break within the scan limit; file may be a single long line or non-line-oriented]"

    it "guard 3 truncated: empty window on truncated file footer" $ do
      let win = LineWindow { lwLines = [], lwStart = 5, lwEnd = 5
                           , lwTotal = 5, lwHasMore = True, lwTruncated = True }
      renderWindow win `shouldBe`
        "[offset 5 reached the scan limit (5+ lines counted so far); read with offset=0 to restart]"

    it "guard 4: non-empty window on truncated file" $ do
      let win = LineWindow { lwLines = ["x", "y"], lwStart = 0, lwEnd = 2
                           , lwTotal = 2, lwHasMore = True, lwTruncated = True }
      renderWindow win `shouldBe`
        "x\ny\n\n[lines 1-2 of >=2 (file exceeds scan limit; more may exist) - read with offset=2 for the next window]"

    -- The footer guard order is enforced; no inverted range can be emitted.
    prop "NO-INVERTED-RANGE: whenever a footer prints a numeric range, lwStart+1 <= lwEnd" $
      \(lines' :: [Text]) (NonNegative start) (NonNegative n) (NonNegative extra) trunc ->
        let end = start + n + extra   -- preserve the lwEnd >= lwStart invariant
            tot = end + 1
            win = LineWindow { lwLines = lines', lwStart = start, lwEnd = end
                             , lwTotal = tot, lwHasMore = True, lwTruncated = trunc }
            rendered = renderWindow win
        in not (printsRange rendered) || (start + 1 <= end)

  ---------------------------------------------------------------------------
  -- readLineWindow (IO)
  ---------------------------------------------------------------------------

  describe "readLineWindow" $ do

    it "reads a small multi-line file: exact window + footer" $
      withSystemTempDirectory "seal-lf" $ \dir ->
        withSafeFile dir "a\nb\nc\n" $ \safe -> do
          win <- readLineWindow defaultPageParams 0 Nothing safe
          lwLines win `shouldBe` ["a", "b", "c"]
          lwStart win `shouldBe` 0
          lwEnd win `shouldBe` 3
          lwTotal win `shouldBe` 3
          lwTruncated win `shouldBe` False
          lwHasMore win `shouldBe` False

    it "no-trailing-newline file: lwTotal correct (3, not 4)" $
      withSystemTempDirectory "seal-lf" $ \dir ->
        withSafeFile dir "a\nb\nc" $ \safe -> do
          win <- readLineWindow defaultPageParams 0 Nothing safe
          lwTotal win `shouldBe` 3
          lwLines win `shouldBe` ["a", "b", "c"]
          lwTruncated win `shouldBe` False
          lwHasMore win `shouldBe` False

    it "empty file: 0 lines, guard-2 footer" $
      withSystemTempDirectory "seal-lf" $ \dir ->
        withSafeFile dir "" $ \safe -> do
          win <- readLineWindow defaultPageParams 0 Nothing safe
          lwTotal win `shouldBe` 0
          lwLines win `shouldBe` []
          lwTruncated win `shouldBe` False
          renderWindow win `shouldBe` "[empty file (0 lines)]"

    it "file exceeding maxScanBytes: lwTruncated True, read stays bounded" $
      withSystemTempDirectory "seal-lf" $ \dir -> do
        -- A file with one long line (no newline) larger than maxScanBytes.
        let big = BS.replicate (maxScanBytes + 1000) 65  -- 'A's, no newline
        withSafeFile dir big $ \safe -> do
          win <- readLineWindow defaultPageParams 0 Nothing safe
          lwTruncated win `shouldBe` True
          lwTotal win `shouldBe` 0    -- no complete line within the scan
          lwLines win `shouldBe` []    -- window pass took 0 lines
          renderWindow win `shouldBe`
            "[no line break within the scan limit; file may be a single long line or non-line-oriented]"
          -- Memory bound: the window must not be the whole file. The window
          -- is empty here, the strongest available assertion that the whole
          -- file was not materialized.

    it "newline-free file exceeding maxScanBytes: guard 1, memory bounded" $
      withSystemTempDirectory "seal-lf" $ \dir -> do
        let big = BS.replicate (maxScanBytes + 5000) 90  -- 'Z's, no newline
        withSafeFile dir big $ \safe -> do
          win <- readLineWindow defaultPageParams 0 Nothing safe
          lwTruncated win `shouldBe` True
          lwTotal win `shouldBe` 0
          lwLines win `shouldBe` []
          renderWindow win `shouldBe`
            "[no line break within the scan limit; file may be a single long line or non-line-oriented]"

    it "file with many short lines over the byte ceiling: truncated, partial not counted" $
      withSystemTempDirectory "seal-lf" $ \dir -> do
        -- "x\n" repeated: each line is 2 bytes. maxScanBytes/2 lines fit within
        -- the cap; then the cap is hit mid-stream. lwTotal is the count of
        -- complete lines within the cap.
        let unit = "x\n"
            n    = maxScanBytes `div` 2 + 100
            body = BS.concat (replicate n unit)
        withSafeFile dir body $ \safe -> do
          win <- readLineWindow defaultPageParams 0 Nothing safe
          lwTruncated win `shouldBe` True
          lwTotal win `shouldBe` (maxScanBytes `div` 2)

    it "offset paging reaches the tail" $
      withSystemTempDirectory "seal-lf" $ \dir -> do
        let ls  = ["l" <> T.pack (show i) | i <- [1..30 :: Int]]
            body = BS.intercalate "\n" (map TE.encodeUtf8 ls) <> "\n"
        withSafeFile dir body $ \safe -> do
          -- defaultPageParams: pageSize = clamp 10 200 (round(4*sqrt 30)) =
          -- clamp 10 200 (round 21.90) = 22.
          w1 <- readLineWindow defaultPageParams 0 Nothing safe
          length (lwLines w1) `shouldBe` 22
          lwHasMore w1 `shouldBe` True
          -- Page to offset = lwEnd w1 (the copy-paste footer value).
          w2 <- readLineWindow defaultPageParams (lwEnd w1) Nothing safe
          lwStart w2 `shouldBe` 22
          lwLines w2 `shouldBe` drop 22 ls
          lwHasMore w2 `shouldBe` False

    it "limit override bounds the window" $
      withSystemTempDirectory "seal-lf" $ \dir -> do
        let ls  = [T.pack (show i) | i <- [1..50 :: Int]]
            body = BS.intercalate "\n" (map TE.encodeUtf8 ls) <> "\n"
        withSafeFile dir body $ \safe -> do
          w <- readLineWindow defaultPageParams 0 (Just 3) safe
          length (lwLines w) `shouldBe` 3
          lwLines w `shouldBe` take 3 ls
          lwHasMore w `shouldBe` True

    prop "IO readLineWindow matches windowLines on T.lines-decoded content" $
      forAll (resize 60 genLines) $ \ls ->
        ioProperty $
          withSystemTempDirectory "seal-lf" $ \dir -> do
            let body = if null ls
                       then BS.empty
                       else BS.intercalate "\n" (map TE.encodeUtf8 ls) <> "\n"
            withSafeFile dir body $ \safe -> do
              win <- readLineWindow defaultPageParams 0 Nothing safe
              let expected = windowLines defaultPageParams 0 Nothing
                              (T.lines (TE.decodeUtf8Lenient body))
              pure $ lwLines win == lwLines expected
                     .&&. lwTotal win == lwTotal expected
                     .&&. lwStart win == lwStart expected
                     .&&. lwEnd win == lwEnd expected

-- | A footer prints a numeric range iff it contains a @<digit>-<digit>@
-- substring — the @N-M@ form used only by the range-printing footers
-- (guards 4-6). The empty/degenerate footers (guards 1-3) never contain a
-- digit-hyphen-digit sequence.
printsRange :: Text -> Bool
printsRange = go . T.unpack
  where
    go (d1 : '-' : d2 : _)
      | isDigitC d1 && isDigitC d2 = True
    go (_ : rest) = go rest
    go []         = False
    isDigitC c = c `elem` ("0123456789" :: String)