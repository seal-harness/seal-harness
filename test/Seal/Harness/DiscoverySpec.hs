{-# LANGUAGE OverloadedStrings #-}
module Seal.Harness.DiscoverySpec (spec) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Test.Hspec

import Seal.Handles.Harness (HarnessError (..))
import Seal.Harness.Discovery
import Seal.Harness.Tmux (TmuxRunner (..))

spec :: Spec
spec = describe "Seal.Harness.Discovery" $ do
  it "scanDiscoverableIO parses list-windows output, filters managed" $ do
    -- list-windows -F "#{window_id}:#{window_name}" output.
    -- Managed harness windows are named "seal-<uuid>"; those are filtered.
    let scripted = "@1:seal-abc-uuid\n@2:claude-code\n@3:bash\n"
    (runner, _) <- mkFakeRunner scripted
    r <- scanDiscoverableIO runner
    case r of
      Right ws -> do
        length ws `shouldBe` 2  -- @2:claude-code + @3:bash; @1:seal- filtered
        dwTmuxCoord (headSafe ws) `shouldBe` "@2"
        dwFlavourHint (headSafe ws) `shouldBe` Just "claude-code"
        dwTmuxCoord (second ws) `shouldBe` "@3"
        dwFlavourHint (second ws) `shouldBe` Nothing
      Left e -> expectationFailure ("unexpected Left: " <> show e)

  it "guesses codex from the title" $ do
    let scripted = "@3:codex session\n"
    (runner, _) <- mkFakeRunner scripted
    r <- scanDiscoverableIO runner
    case r of
      Right [w] -> dwFlavourHint w `shouldBe` Just "codex"
      other     -> expectationFailure ("expected one window, got: " <> show other)

  it "returns Left HeTmuxMissing when tmux is absent" $ do
    (runner, _) <- mkFakeRunner "__EXIT__127__"
    r <- scanDiscoverableIO runner
    r `shouldBe` Left HeTmuxMissing

-- | A fake TmuxRunner scripting a single stdout reply.
mkFakeRunner :: Text -> IO (TmuxRunner, IO [[String]])
mkFakeRunner scripted = do
  argsRef <- newIORef []
  let runner = TmuxRunner $ \argv -> do
        modifyIORef' argsRef (argv :)
        if scripted == "__EXIT__127__"
          then pure (Left HeTmuxMissing)
          else pure (Right scripted)
      getArgs = reverse <$> readIORef argsRef
  pure (runner, getArgs)

headSafe :: [a] -> a
headSafe (x:_) = x
headSafe []    = error "headSafe: empty list"

second :: [a] -> a
second (_:x:_) = x
second _       = error "second: too few elements"