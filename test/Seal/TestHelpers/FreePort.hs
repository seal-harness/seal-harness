-- | A reusable helper for tests that need a free TCP port. Grabs an
-- ephemeral port from the OS (bind to port 0, read the assigned port,
-- close the socket) so tests never collide with each other or with
-- long-running processes (e.g. @ssh-agent@, a stray @seal serve@).
--
-- The race window between 'withFreePort' closing the socket and the
-- caller rebinding it is small and the OS won't reissue the port in that
-- window (TIME_WAIT only applies to established connections, not a bare
-- bind-then-close). In practice this eliminates the \"Address already in
-- use\" crashes seen when tests hardcoded ports (e.g. 18080) that
-- @ssh-agent@ happened to hold.
module Seal.TestHelpers.FreePort
  ( withFreePort
  ) where

import Control.Exception (bracket)
import Network.Socket
  ( Family (..), SocketType (Stream), SockAddr (SockAddrInet), close
  , bind, listen, socket, socketPort, defaultProtocol )

-- | Run an action with a free TCP port. The port is obtained by binding
-- to port 0 (the OS assigns an ephemeral port), reading the assigned
-- port, and closing the socket — so the action receives a port that was
-- free a moment ago. The action is responsible for binding its own
-- socket (e.g. via 'runStreamServer'); the helper just finds a free
-- port number.
withFreePort :: (Int -> IO a) -> IO a
withFreePort action = bracket open close' reuse
  where
    open = do
      s <- socket AF_INET Stream defaultProtocol
      bind s (SockAddrInet 0 0)  -- 0 = ephemeral port
      listen s 1
      pure s
    close' = close
    reuse s = do
      port <- socketPort s
      action (fromIntegral port)