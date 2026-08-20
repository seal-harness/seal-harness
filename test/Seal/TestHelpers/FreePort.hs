-- | A reusable helper for tests that need a free TCP port. Picks a random
-- port in the IANA ephemeral range (49152–65535) and returns it. Unlike a
-- bind-to-0-then-close approach, there is no grab-close-rebind race: the
-- caller binds directly. A collision with another process (rare in CI)
-- surfaces as a bind error that the caller can catch and retry, or skip
-- the test with 'pendingWith'.
module Seal.TestHelpers.FreePort
  ( withFreePort
  ) where

import System.Random (randomRIO)

-- | Pick a random port in the IANA ephemeral range (49152–65535). The
-- caller is responsible for binding it; if the bind fails (another
-- process grabbed the same port), the caller should retry or skip.
-- Random selection makes collisions vanishingly unlikely in practice
-- (there are ~16k ports in the range).
withFreePort :: (Int -> IO a) -> IO a
withFreePort action = do
  port <- randomRIO (49152, 65535)
  action port