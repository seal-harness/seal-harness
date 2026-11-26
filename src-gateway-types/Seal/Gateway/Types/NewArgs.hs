{-# LANGUAGE OverloadedStrings #-}
-- | Pure, channel-agnostic pieces of the @\/new@ command, shared between the
-- main library (@Seal.Command.New@) and the gateway-API chat channels
-- (@seal-chat-channels@), which cannot import the main library.
--
-- Two things live here:
--
-- * 'NewArgs' and its parser — the @-p@\/@-m@\/@-r@\/@-b@ flags of @\/new@. The
--   chat-channel loop parses the same flags as the CLI/web registry, so the
--   parser must be shared rather than re-implemented (handoff §4 item 9:
--   "reuse it, do not re-parse by hand").
-- * 'renderNewSessionConfirmation' — the one-line confirmation naming the new
--   session, the old session, and the resume hint. Extracted so the chat loop
--   and 'Seal.Command.New.renderNewConfirmation' emit byte-identical text.
module Seal.Gateway.Types.NewArgs
  ( NewArgs (..)
  , parseNewArgs
  , emptyNewArgs
  , renderNewSessionConfirmation
  ) where

import Data.Text (Text)
import Data.Text qualified as T

-- | Optional arguments for @/new@. All fields are 'Maybe' — 'Nothing' means
-- "use the config default" (for provider/model), "no repo" (for repo), or
-- "the remote's default branch" (for branch).
data NewArgs = NewArgs
  { naProvider :: Maybe Text
  , naModel    :: Maybe Text
  , naRepo     :: Maybe Text
  , naBranch   :: Maybe Text
    -- ^ The branch or tag to check out when @-r@ clones a repo. 'Nothing'
    -- means the remote's default branch.
  , naMachine  :: Maybe Text
    -- ^ The execution machine the new session is pinned to. 'Nothing' means
    -- "the effective default", which is what a user who did not ask for a
    -- machine gets — and what keeps the metric's "a present pin means a
    -- deliberate choice" true.
    --
    -- 'Text' and not 'MachineName': this module is in @seal-gateway-types@,
    -- which cannot depend on the main library. Validation happens in
    -- 'Seal.Command.New', where the inventory is available.
  } deriving stock (Eq, Show)

-- | The empty 'NewArgs' — no overrides, use all config defaults.
emptyNewArgs :: NewArgs
emptyNewArgs = NewArgs
  { naProvider = Nothing
  , naModel    = Nothing
  , naRepo     = Nothing
  , naBranch   = Nothing
  , naMachine  = Nothing
  }

-- | Parse the raw argument text from the routing layer into 'NewArgs'.
-- This is a simple manual parse used by the inbox-channel loop path
-- ('Seal.Channels.Chat.Loop'), which doesn't go through
-- optparse-applicative. Supports @-p@\/@--provider@, @-m@\/@--model@,
-- @-r@\/@--repo@, @-b@\/@--branch@ and @-M@\/@--machine@ with a single value
-- each. Unknown flags are ignored; a machine that does not validate is an
-- error reported by the CALLER ('Seal.Command.New'), not here — this module
-- has no inventory to check against.
parseNewArgs :: Text -> NewArgs
parseNewArgs raw =
  go (splitArgs raw) emptyNewArgs
  where
    go [] acc = acc
    go (flag : val : rest) acc
      | flag `elem` ["-p", "--provider"] = go rest acc { naProvider = Just val }
      | flag `elem` ["-m", "--model"]    = go rest acc { naModel    = Just val }
      | flag `elem` ["-r", "--repo"]     = go rest acc { naRepo     = Just val }
      | flag `elem` ["-b", "--branch"]   = go rest acc { naBranch   = Just val }
      | flag `elem` ["-M", "--machine"]  = go rest acc { naMachine  = Just val }
      | otherwise                        = go (val : rest) acc
    go (_flag : rest) acc = go rest acc

    -- Split on whitespace, preserving non-empty tokens.
    splitArgs t = case T.words t of
      [] -> []
      ws -> ws

-- | Render the one-line @/new@ confirmation. Names the old session + resume
-- hint so the safety net (old session kept on disk) is user-visible.
--
-- @new session \<sid\> (\<provider\>/\<model\>) — prior session \<oldSid\> kept in
-- /session list@
renderNewSessionConfirmation :: Text -> Text -> Text -> Text -> Text
renderNewSessionConfirmation newSid provider model oldSid =
  "new session " <> newSid
    <> " (" <> provider <> "/" <> model <> ")"
    <> " — prior session " <> oldSid
    <> " kept in /session list"
