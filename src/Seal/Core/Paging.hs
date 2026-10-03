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
  , paginateDesc
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

-- | Back-to-front pagination. @offset@ counts from the end of the list:
-- @offset=0@ returns the last @size@ items, @offset=size@ returns the
-- items before that, and so on. Items within the window remain in their
-- original (input) order — only the window selection is reversed.
--
-- @pgOffset@ is the 0-based index in the /original/ list where the window
-- starts, so message-index rendering stays correct. @pgHasMore@ means
-- "there are older items before this window" (read with a larger offset
-- to page further back).
paginateDesc :: PageParams -> Int -> Maybe Int -> [a] -> Page a
paginateDesc params offset mLimit items =
  let total      = length items
      size       = windowSize params total mLimit
      offset'    = clamp 0 total offset
      avail      = max 0 (total - offset')
      effStart   = max 0 (total - offset' - size)
      actualSize = min size avail
      window     = if offset' >= total
                     then []
                     else take actualSize (drop effStart items)
      hasMore    = not (null window) && effStart > 0
  in Page
       { pgItems   = window
       , pgOffset  = effStart
       , pgTotal   = total
       , pgHasMore = hasMore
       }
-- | 'PageParams' used everywhere in this milestone.
-- @PageParams { ppFloor = 500, ppCeiling = 2000, ppCoeff = 0.0 }@.
-- A flat 500-line default (matching Hermes' read_file), with a 2000-line
-- hard ceiling. @ppCoeff = 0@ means @pageSize = clamp 500 2000 0 = 500@
-- regardless of total line count — no dynamic sqrt scaling.
defaultPageParams :: PageParams
defaultPageParams = PageParams { ppFloor = 500, ppCeiling = 2000, ppCoeff = 0.0 }
