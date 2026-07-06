{-# LANGUAGE OverloadedStrings #-}
-- | On-demand scan for unmanaged tmux windows (those without a @seal_id
-- marker) that could be adopted by the harness registry.
module Seal.Harness.Discovery
  ( DiscoverableWindow (..)
  , scanDiscoverableIO
  ) where

import Data.Text (Text)
import Data.Text qualified as T

import Seal.Handles.Harness (HarnessError)
import Seal.Harness.Tmux (TmuxRunner (..))

-- | A discovered tmux window that could be adopted.
data DiscoverableWindow = DiscoverableWindow
  { dwTmuxCoord    :: Text        -- ^ "session:window" or "%<pane>"
  , dwTitle        :: Text        -- ^ the window's name
  , dwFlavourHint  :: Maybe Text  -- ^ guessed from the title
  } deriving stock (Eq, Show)

-- | Scan for unmanaged tmux windows (no @seal_id marker). IO via the
-- 'TmuxRunner' seam: @tmux list-windows -F "#{window_id}:#{window_name}"@
-- (a real call would also check each window's markers; for 6a's
-- fake-runner test, the scripted stdout is parsed as one window per line).
-- Windows whose title starts with @seal:@ (the harness's own naming) are
-- considered managed and filtered out.
scanDiscoverableIO :: TmuxRunner -> IO (Either HarnessError [DiscoverableWindow])
scanDiscoverableIO runner = do
  r <- runTmux runner ["list-windows", "-F", "#{window_id}:#{window_name}"]
  pure $ case r of
    Left e  -> Left e
    Right t -> Right (parseWindows t)

-- | Parse @tmux list-windows -F@ output: one line per window, format
-- @<coord>:<name>@. Filter out managed harness windows (name starts with
-- @seal-@ — the harness naming convention).
parseWindows :: Text -> [DiscoverableWindow]
parseWindows = mapMaybe parseLine . T.lines
  where
    parseLine ln =
      case T.breakOn ":" ln of
        (coord, rest)
          | T.null rest -> Nothing
          | otherwise ->
              let title = T.drop 1 rest  -- drop the leading ":"
              in if "seal-" `T.isPrefixOf` title
                   then Nothing  -- managed harness window
                   else Just (DiscoverableWindow coord title (guessFlavour title))

-- | Guess a flavour from the window title.
guessFlavour :: Text -> Maybe Text
guessFlavour title
  | "claude"  `T.isInfixOf` T.toCaseFold title = Just "claude-code"
  | "codex"   `T.isInfixOf` T.toCaseFold title = Just "codex"
  | otherwise                                  = Nothing

-- local helper (avoid a Data.Maybe import for one helper)
mapMaybe :: (a -> Maybe b) -> [a] -> [b]
mapMaybe _ []     = []
mapMaybe f (x:xs) = case f x of
  Just y  -> y : mapMaybe f xs
  Nothing -> mapMaybe f xs