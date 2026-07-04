-- | The Dynamic Retrieval page-sizer and a generic 'paginate'.
--
-- File- and ISA-agnostic. The sizer computes a page size as
-- @clamp floor ceiling (round (coeff * sqrt total))@, with a per-call
-- explicit limit overriding the computed size (clamped to
-- @[1, ppCeiling]@ so a caller can never request an unbounded window).
module Seal.Core.Paging
  ( PageParams (..)
  , Page (..)
  , clamp
  , pageSize
  , windowSize
  , paginate
  , defaultPageParams
  ) where

-- | Sizer parameters. Invariants: @1 <= ppFloor <= ppCeiling@ and
-- @ppCoeff >= 0@.
data PageParams = PageParams
  { ppFloor   :: !Int   -- ^ minimum page size (invariant: @1 <= ppFloor <= ppCeiling@)
  , ppCeiling :: !Int   -- ^ maximum page size
  , ppCoeff   :: !Double -- ^ @A@ in @round(A * sqrt total)@ (invariant: @>= 0@)
  } deriving stock (Eq, Show)

-- | A page of results plus the metadata a model needs to page forward.
data Page a = Page
  { pgItems   :: [a]   -- ^ the windowed items, in input order
  , pgOffset  :: !Int  -- ^ 0-based offset this page starts at (clamped to @[0,total]@)
  , pgTotal   :: !Int  -- ^ total item count (== length of the input list)
  , pgHasMore :: !Bool -- ^ @pgOffset + length pgItems < pgTotal@
  } deriving stock (Eq, Show)

-- | @clamp lo hi x = max lo (min hi x)@. Value last, matching
-- @Data.Ord.clamp (lo,hi) x@.
clamp :: Int -> Int -> Int -> Int
clamp lo hi x = max lo (min hi x)

-- | @pageSize params total = clamp ppFloor ppCeiling (round (ppCoeff * sqrt total))@.
-- Result is always within @[ppFloor, ppCeiling]@.
pageSize :: PageParams -> Int -> Int
pageSize (PageParams floor' ceiling' coeff) total =
  clamp floor' ceiling' (round (coeff * sqrt (fromIntegral total :: Double)))

-- | The single source of truth for "how many items to return", shared by
-- 'paginate' (list path) and 'Seal.Text.LineFile.readLineWindow'
-- (streaming path) so they cannot drift.
--
-- @windowSize params total mLimit = maybe (pageSize params total) (clamp 1 ppCeiling) mLimit@
windowSize :: PageParams -> Int -> Maybe Int -> Int
windowSize params@(PageParams _ ceiling' _) total mLimit =
  case mLimit of
    Nothing  -> pageSize params total
    Just lim -> clamp 1 ceiling' lim

-- | @paginate params offset mLimit items@, where @total = length items@.
--
--   * @offset'  = clamp 0 total offset@
--   * @size     = windowSize params total mLimit@
--   * @window   = take size (drop offset' items)@
paginate :: PageParams -> Int -> Maybe Int -> [a] -> Page a
paginate params offset mLimit items =
  let total   = length items
      offset' = clamp 0 total offset
      size    = windowSize params total mLimit
      window  = take size (drop offset' items)
  in Page
       { pgItems   = window
       , pgOffset  = offset'
       , pgTotal   = total
       , pgHasMore = offset' + length window < total
       }

-- | 'PageParams' used everywhere in this milestone.
-- @PageParams { ppFloor = 10, ppCeiling = 200, ppCoeff = 4.0 }@.
defaultPageParams :: PageParams
defaultPageParams = PageParams { ppFloor = 10, ppCeiling = 200, ppCoeff = 4.0 }