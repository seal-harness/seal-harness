{-# LANGUAGE OverloadedStrings #-}
-- | Pure helpers for the chat channel's @\/last@ command: argument parsing,
-- error text, and help.
--
-- This module is a leaf — it imports no chat-loop module, so
-- "Seal.Channels.Chat.Route" can carry the raw argument text
-- ('Seal.Channels.Chat.Route.ChatLast') without a module cycle.
--
-- The render half (extraction, resolution, and the user-visible strings) is
-- added by WU-B; this module currently holds only what WU-A needs.
module Seal.Channels.Chat.LastRender
  ( lastHelp
  , isLastHelpArg
  , LastArgs (..)
  , LastError (..)
  , parseLastArgs
  , renderLastError
    -- * Extraction
  , EntryFacts (..)
  , ToolName (..)
  , extractEntry
  , safeOpLabel
  , isLegacyPayload
    -- * Items
  , ToolState (..)
  , ToolOutcome (..)
  , AssistantItem (..)
  , assistantItems
    -- * Views
  , TabHeading (..)
  , PendingQuestion (..)
  , LastView (..)
  , ResolveInput (..)
  , resolveLast
  , viewTag
  , renderedTools
    -- * Rendering
  , renderLast
  , quoteBody
  , singleLine
  ) where

import Data.Char (isDigit)
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V

import Seal.Channels.Chat.Class (QuestionOption (..))
import Seal.Channels.Chat.ToolRender (opEmoji)
import Seal.Gateway.Types.Tab
  ( TabIndex, tabIndexFromChar, tabIndexToChar )

-- | Parsed @\/last@ arguments.
data LastArgs = LastArgs
  { laTab   :: Maybe TabIndex  -- ^ 'Nothing' means the focused tab.
  , laCount :: Int             -- ^ Always clamped to @1..5@.
  } deriving stock (Eq, Show)

-- | Everything @\/last@ can tell the user went wrong.
--
-- A bespoke ADT rather than @Either Text@ because 'renderLastError' matches on
-- the constructor to build a distinct string for each, and the tests assert
-- every constructor.
data LastError
  = LENoSuchTab Text      -- ^ the token was not a tab index
  | LEBadCount Text       -- ^ the second token was not a number
  | LENoSession Char      -- ^ the tab is a harness tab (no session)
  | LENoCurrentTab        -- ^ no focused tab to default to
  | LETabs                -- ^ @GET \/api\/lists@ failed
  | LETranscript Char     -- ^ the transcript fetch failed
  | LEQuestions Char      -- ^ the pending-questions fetch failed
  deriving stock (Eq, Show)

-- | Parse the raw argument text carried by
-- 'Seal.Channels.Chat.Route.ChatLast'.
--
-- The first token is a tab iff it is exactly one character AND
-- 'tabIndexFromChar' accepts it. That is stricter than 'parseTabFocus' (which
-- takes the first character of an arbitrary token): @\/last bb@ naming a bad
-- token back is better than silently meaning tab @b@.
parseLastArgs :: Text -> Either LastError LastArgs
parseLastArgs raw =
  case T.words (T.strip raw) of
    [] -> Right (LastArgs Nothing 1)
    [tabTok] -> LastArgs <$> (Just <$> tabOf tabTok) <*> pure 1
    (tabTok : countTok : _) ->
      LastArgs <$> (Just <$> tabOf tabTok) <*> countOf countTok
  where
    tabOf tok = case T.uncons tok of
      Just (c, rest)
        | T.null rest -> either (const (Left (LENoSuchTab tok))) Right (tabIndexFromChar c)
      _ -> Left (LENoSuchTab tok)

    countOf tok
      | T.null t || not (T.all isDigit t) = Left (LEBadCount tok)
      | otherwise = Right (clamp (T.foldl' step 0 t))
      where
        t = T.strip tok
        step acc c = acc * 10 + (fromEnum c - fromEnum '0')

-- | Clamp a requested count into the supported @1..5@ range.
clamp :: Int -> Int
clamp = max 1 . min 5

-- | Is this @\/last@'s help flag? Only as the sole argument, matching
-- @\/watch -h@ (which is not help either — see @handleWatchToggle@).
isLastHelpArg :: Text -> Bool
isLastHelpArg raw = T.strip raw `elem` ["-h", "--help"]

-- | The @\/last@ help text, in the same @T.unlines@ shape as @bgHelp@ and
-- @watchHelp@.
lastHelp :: Text
lastHelp = T.unlines
  [ "Show a tab's last message without switching to it"
  , ""
  , "Usage: /last [tab] [n]"
  , ""
  , "  tab     A tab (0-9a-z). Defaults to the tab you are on."
  , "  n       How many messages, 1-5. Defaults to 1."
  , ""
  , "The first argument is always the tab, so /last 3 means tab 3, not"
  , "three messages."
  , ""
  , "/last never changes the tab you are focused on."
  , ""
  , "If the tab is waiting on a question, /last shows it. Answer it with"
  , "/N <answer> - for example /b 1 or /b yes - which goes to that tab"
  , "without switching to it."
  , ""
  , "Options:"
  , "  -h, --help  Show this help"
  ]

-- | Render an error for display on the channel.
--
-- The four strings the requirements specify are used verbatim; errors the
-- requirements do not cover follow the same @last failed:@ shape as the
-- existing @focus failed:@ / @inject failed:@ / @tab list failed:@ family.
renderLastError :: LastError -> Text
renderLastError err = case err of
  LENoSuchTab t   -> "last failed: no such tab " <> singleLine t <> " \8212 /tab list"
  LEBadCount t    -> "last failed: \"" <> singleLine t
                     <> "\" isn't a number \8212 use /last <tab> 1-5"
  LENoSession c   -> "last failed: tab " <> T.singleton c
                     <> " has no session (harness tab)"
  LENoCurrentTab  -> "last failed: no current tab"
  LETabs          -> "last failed: couldn't read the tab list \8212 try again in a moment"
  LETranscript c  -> "last failed: couldn't read tab " <> T.singleton c
                     <> "'s transcript \8212 try again in a moment"
  LEQuestions c   -> "last failed: couldn't read tab " <> T.singleton c
                     <> "'s question \8212 try again in a moment"

-- | Flatten and bound text that came from the user, before it is echoed back.
--
-- Without this an inbound message of arbitrary length could be echoed into the
-- chat, and its newlines would let a user spoof a harness-authored line (the
-- same argument that motivates block-quoting a question). 16 characters is
-- enough to show which token was rejected.
singleLine :: Text -> Text
singleLine t =
  let flattened = T.unwords (T.words (T.map newlineToSpace t))
  in if T.length flattened > 16
       then T.take 16 flattened <> "\8230"
       else flattened
  where
    newlineToSpace c = if c == '\n' || c == '\r' || c == '\t' then ' ' else c

-- ---------------------------------------------------------------------------
-- Extraction
-- ---------------------------------------------------------------------------

-- | A tool call as the renderer sees it: an id (for the pass/fail join) and a
-- shape-gated name. The newtype keeps a raw model-authored string from
-- reaching the renderer by accident.
data ToolName = ToolName
  { tnId   :: Text          -- ^ @tool_use.id@, the join key (never rendered)
  , tnName :: Maybe Text    -- ^ 'safeOpLabel' result; 'Nothing' ⇒ render as unknown
  } deriving stock (Eq)

-- | What one transcript entry contributes. Deliberately has **no** field able
-- to hold a tool input, a tool-result body, the system prompt, or a thinking
-- block: the "never tool inputs" guarantee is structural, not testimonial.
data EntryFacts = EntryFacts
  { lefText    :: Text                 -- ^ response text blocks, joined "\n\n"
  , lefTools   :: [ToolName]           -- ^ tool_use names, no inputs
  , lefResults :: [(Text, Bool)]       -- ^ (tool_use_id, is_error) from requests
  , lefLegacy  :: Bool                 -- ^ payload has neither content nor messages
  } deriving stock (Eq)

-- | Shape-gate a model-authored tool name.
--
-- @tool_use.name@ arrives straight from the provider response with no
-- validation, so rendering it unbounded would let a model put arbitrary
-- content (JSON, paths, URLs, keys, newlines) into a trusted-looking tool
-- line. Every real opcode name matches @[A-Z][A-Z0-9_]{0,31}@; anything else
-- is rejected and rendered as @(unknown opcode)@.
--
-- This is a shape gate, not an allowlist: a model can still emit a real
-- opcode's name. It stops content injection, not lying.
safeOpLabel :: Text -> Maybe Text
safeOpLabel t
  | T.null t = Nothing
  | T.length t > 32 = Nothing
  | otherwise =
      let (h, rest) = T.splitAt 1 t
      in if T.all isUpperish h && T.all isNameChar rest then Just t else Nothing
  where
    isUpperish c = c >= 'A' && c <= 'Z'
    isNameChar c = isUpperish c || (c >= '0' && c <= '9') || c == '_'

-- | Extract the facts one frontend-shaped transcript entry carries.
--
-- Rules, all allowlist-based:
--
-- * only @direction == "response"@ contributes text, and only from a block
--   whose @type@ is @\"text\"@ carrying a string @text@ — a @\"thinking\"@
--   block is dropped, and every other type is dropped with no fallback;
-- * only @direction == "request"@ contributes the pass/fail join, from
--   @type == \"tool_result\"@ blocks keyed by @tool_use_id@.
--
-- Tool inputs are never read into 'EntryFacts'.
extractEntry :: Value -> EntryFacts
extractEntry val =
  case val of
    Object o ->
      let dir = strField "direction" o
          payload = fromMaybe Null (KeyMap.lookup (Key.fromText "payload") o)
          legacy = isLegacyPayload val
      in case dir of
           Just "response" -> EntryFacts
             { lefText = textOf payload
             , lefTools = toolsOf payload
             , lefResults = []
             , lefLegacy = legacy
             }
           Just "request" -> EntryFacts "" [] (resultsOf payload) legacy
           _ -> EntryFacts "" [] [] legacy
    _ -> EntryFacts "" [] [] False

-- | Does this entry use the legacy payload shape (no @content@, no
-- @messages@)? Those predate the current encoding; the renderer reports that
-- honestly rather than claiming the session is empty.
isLegacyPayload :: Value -> Bool
isLegacyPayload val = case val of
  Object o -> case KeyMap.lookup (Key.fromText "payload") o of
    Just (Object p) ->
      not (KeyMap.member (Key.fromText "content") p)
        && not (KeyMap.member (Key.fromText "messages") p)
    _ -> False
  _ -> False

-- | The response text: @text@ blocks joined with a blank line. Deliberately
-- not @extractEntryText@'s 'T.concat', which runs paragraphs together.
textOf :: Value -> Text
textOf payload = case blockArray payload of
  Just blocks -> T.intercalate "\n\n"
    [ t | b <- blocks, blockType b == Just "text"
        , Just t <- [strField "text" =<< asObject b] ]
  Nothing -> ""

-- | The @tool_use@ calls in a response, shape-gated.
toolsOf :: Value -> [ToolName]
toolsOf payload = case blockArray payload of
  Just blocks ->
    [ ToolName (fromMaybe "" tid) (safeOpLabel raw)
    | b <- blocks
    , blockType b == Just "tool_use"
    , Object bo <- [b]
    , let raw = fromMaybe "" (strField "name" bo)
    , let tid = strField "id" bo
    ]
  Nothing -> []

-- | The @(tool_use_id, is_error)@ pairs a request entry carries. This is the
-- only thing read from tool-result blocks — never their content.
resultsOf :: Value -> [(Text, Bool)]
resultsOf payload =
  case KeyMap.lookup (Key.fromText "messages") =<< asObject payload of
    Just (Array msgs) -> concatMap fromMessage (V.toList msgs)
    _ -> []
  where
    fromMessage (Object m) = case KeyMap.lookup (Key.fromText "content") m of
      Just (Array blocks) -> mapMaybe fromBlock (V.toList blocks)
      _ -> []
    fromMessage _ = []
    fromBlock (Object b)
      | blockType (Object b) == Just "tool_result"
      , Just tid <- strField "tool_use_id" b =
          Just (tid, fromMaybe False (boolField "is_error" b))
      | otherwise = Nothing
    fromBlock _ = Nothing

blockArray :: Value -> Maybe [Value]
blockArray payload = case KeyMap.lookup (Key.fromText "content") =<< asObject payload of
  Just (Array arr) -> Just (V.toList arr)
  _ -> Nothing

blockType :: Value -> Maybe Text
blockType b = strField "type" =<< asObject b

asObject :: Value -> Maybe (KeyMap.KeyMap Value)
asObject (Object o) = Just o
asObject _ = Nothing

strField :: Text -> KeyMap.KeyMap Value -> Maybe Text
strField k o = case KeyMap.lookup (Key.fromText k) o of
  Just (String t) -> Just t
  _ -> Nothing

boolField :: Text -> KeyMap.KeyMap Value -> Maybe Bool
boolField k o = case KeyMap.lookup (Key.fromText k) o of
  Just (Bool b) -> Just b
  _ -> Nothing

-- ---------------------------------------------------------------------------
-- Items
-- ---------------------------------------------------------------------------

-- | Whether a tool call succeeded. Tri-state because a 'Bool' cannot express
-- "no result in the window": a tool-only response must still name what ran
-- (DoD 2 wants the opcode), and rendering an unfinished call bare would
-- silently assert success.
data ToolState = LtsOk | LtsFailed | LtsUnfinished
  deriving stock (Eq, Show)

data ToolOutcome = ToolOutcome
  { lsaName  :: Maybe Text   -- ^ 'safeOpLabel' result; 'Nothing' ⇒ unknown opcode
  , lsaState :: !ToolState
  } deriving stock (Eq)      -- no Show, as a rule for content-bearing types

data AssistantItem
  = LriText Text
  | LriToolOnly ToolOutcome
  deriving stock (Eq)

-- | Pair responses with their text or their tool calls, chronologically,
-- resolving each tool's pass/fail by joining on @tool_use_id@.
--
-- The join needs both halves: @tool_use@ ids live in responses, their results
-- in requests. A @tool_use@ with no matching result is 'LtsUnfinished'.
assistantItems :: [Value] -> [AssistantItem]
assistantItems entries = mapMaybe toItem facts
  where
    facts = map extractEntry entries
    results = concatMap lefResults facts

    toItem f
      | not (T.null (lefText f)) = Just (LriText (lefText f))
      | (t : _) <- lefTools f = Just (LriToolOnly (outcome t))
      | otherwise = Nothing

    outcome t = ToolOutcome (tnName t) (stateOf (tnId t))
    stateOf tid = case lookup tid results of
      Just True  -> LtsFailed
      Just False -> LtsOk
      Nothing    -> LtsUnfinished

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------

data TabHeading = TabHeading
  { lthIndex :: TabIndex
  , lthTitle :: Maybe Text   -- ^ may be a user snippet; never logged
  } deriving stock (Eq)      -- no Show: lthTitle is content

data PendingQuestion = PendingQuestion
  { lqText    :: Text
  , lqOptions :: [QuestionOption]
  } deriving stock (Eq)      -- no Show: holds question text

data LastView
  = LastMessages TabHeading [AssistantItem]
  | LastQuestion TabHeading PendingQuestion
  | LastWorking  TabHeading (Maybe ToolOutcome)
  | LastEmpty    TabHeading
  deriving stock (Eq)        -- no Show, as a rule for content-bearing types

data ResolveInput = ResolveInput
  { lriHeading   :: TabHeading
  , lriItems     :: [AssistantItem]
  , lriThinking  :: Bool
  , lriQuestion  :: Maybe PendingQuestion
  , lriCount     :: Int        -- ^ requested n, already clamped 1..5
  , lriLegacy    :: Bool
  } deriving stock (Eq)        -- no Show: holds AssistantItem/PendingQuestion

-- | Pick the one view that describes this tab right now.
--
-- Precedence, and why: a pending question is the most actionable state and a
-- blocked turn is *also* thinking, so it must win or it is unreachable;
-- thinking beats messages so a busy tab never implies it finished; anything
-- else with items is 'LastMessages'; otherwise 'LastEmpty'. Pure.
resolveLast :: ResolveInput -> LastView
resolveLast ri
  | Just q <- lriQuestion ri = LastQuestion (lriHeading ri) q
  | lriLegacy ri, null (lriItems ri) = LastEmpty (lriHeading ri)
  | lriThinking ri =
      LastWorking (lriHeading ri) (lastCompleted (lriItems ri))
  | not (null (lriItems ri)) =
      LastMessages (lriHeading ri) (takeLast (lriCount ri) (lriItems ri))
  | otherwise = LastEmpty (lriHeading ri)
  where
    -- The newest *completed* tool, so "last completed" is never a lie.
    lastCompleted items =
      case [ o | LriToolOnly o <- items, lsaState o /= LtsUnfinished ] of
        [] -> Nothing
        os -> Just (last os)

-- | The newest @n@ items, in chronological order.
takeLast :: Int -> [AssistantItem] -> [AssistantItem]
takeLast n xs = drop (max 0 (length xs - n)) xs

-- | A stable tag for a view, for tests and callers that branch without
-- rendering. The view types carry no 'Show', so this is how structure is
-- asserted.
viewTag :: LastView -> Text
viewTag v = case v of
  LastMessages {} -> "messages"
  LastQuestion {} -> "question"
  LastWorking {}  -> "working"
  LastEmpty {}    -> "empty"

-- | The tool lines a view contains, in order.
renderedTools :: LastView -> [Text]
renderedTools v = case v of
  LastMessages _ items -> [ toolLine o | LriToolOnly o <- items ]
  LastWorking _ (Just o) -> [ toolLine o ]
  LastWorking _ Nothing -> []
  LastQuestion {} -> []
  LastEmpty {} -> []

-- | One tool line. 'LtsUnfinished' is rendered distinctly from 'LtsOk',
-- because it means "no result in the window" — i.e. unknown — and a bare name
-- would assert success.
toolLine :: ToolOutcome -> Text
toolLine o =
  opEmoji nameText <> " " <> nameText <> suffix
  where
    nameText = fromMaybe "(unknown opcode)" (lsaName o)
    suffix = case lsaState o of
      LtsOk         -> ""
      LtsFailed     -> " (failed)"
      LtsUnfinished -> " (no result)"

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

-- | Render a view to the exact bytes the channel sends.
--
-- One contract: a heading ends with @:@ iff a body follows, and the body
-- begins after exactly one blank line. A heading with no body ends with @.@.
renderLast :: LastView -> Text
renderLast view = case view of
  LastEmpty h -> heading h <> " \8212 no messages yet."
  LastMessages h [] -> renderLast (LastEmpty h)
  LastMessages h items ->
    heading h <> " \8212 " <> countLabel (length items) <> ":\n\n"
      <> renderItems (lthIndex h) items <> hintFor (lthIndex h) (length items) items
  LastWorking h mt ->
    heading h <> " \8212 still working:\n\n"
      <> maybe "no tools have completed yet" (\o -> "last completed: " <> toolLine o) mt
  LastQuestion h q ->
    heading h <> " \8212 waiting on your answer:\n\n"
      <> quoteBody (formatQ q) <> "\n\n" <> answerFooter (lthIndex h) q
  where
    formatQ q = case lqOptions q of
      [] -> lqText q
      os -> lqText q <> "\n\n"
              <> T.intercalate "\n" (zipWith optLine [1 :: Int ..] os)
    optLine n (QuestionOption lbl desc)
      | T.null desc = T.pack (show n) <> ") " <> lbl
      | otherwise   = T.pack (show n) <> ") " <> lbl <> " \8212 " <> desc

-- | @📔 Tab b (title)@ — the title is omitted when empty.
heading :: TabHeading -> Text
heading h =
  "\128212 Tab " <> T.singleton (tabIndexToChar (lthIndex h)) <> titlePart
  where
    titlePart = case lthTitle h of
      Just t | not (T.null (T.strip t)) -> " (" <> t <> ")"
      _ -> ""

countLabel :: Int -> Text
countLabel 1 = "last message"
countLabel n = "last " <> T.pack (show n) <> " messages"

-- | Items, each attributed with the tab char when there is more than one
-- (a chunk boundary then lands inside or between attributed items).
renderItems :: TabIndex -> [AssistantItem] -> Text
renderItems idx items = T.intercalate "\n\n" (map renderItem items)
  where
    -- More than one item ⇒ each is attributed, so a chunk boundary that falls
    -- between items still tells the reader which tab the text came from.
    prefix = if length items > 1 then T.singleton (tabIndexToChar idx) <> ": " else ""
    renderItem item = prefix <> case item of
      LriText t -> t
      LriToolOnly o -> toolLine o <> " \8212 no reply text."

-- | The "for more" hint, for a text-free block whose window was saturated (so
-- more may exist). Without the saturation gate the hint repeats forever, which
-- is the dead end it exists to avoid. It names the actual tab char, and never
-- re-offers the same count.
hintFor :: TabIndex -> Int -> [AssistantItem] -> Text
hintFor idx n items
  | any isText items = ""
  | n >= 5 = " /b to switch to that tab."
  | otherwise = " /last " <> T.singleton (tabIndexToChar idx) <> " 5 for more."
  where
    isText (LriText _) = True
    isText _ = False

-- | Quote model-authored text so it cannot be mistaken for harness output.
--
-- Every non-blank line gets @"> "@; a blank line becomes a bare @">"@ (no
-- trailing space). Line separators other than @\n@ are normalised first,
-- because @\r@, U+0085, U+2028 and U+2029 render as line breaks but would
-- otherwise slip past 'T.lines' and escape the quote.
quoteBody :: Text -> Text
quoteBody t =
  T.intercalate "\n"
    [ if T.null l then ">" else "> " <> l | l <- T.lines (normalizeNewlines t) ]

-- | Fold the line separators that clients render as breaks into @\n@.
--
-- @\r\n@ collapses to a single newline first, so a CRLF does not become two
-- blank lines. The remaining separators are handled per character.
normalizeNewlines :: Text -> Text
normalizeNewlines = T.map other . T.replace "\r\n" "\n"
  where
    other '\r' = '\n'
    other '\x85' = '\n'
    other '\x2028' = '\n'
    other '\x2029' = '\n'
    other c = c

-- | The answer footer. Both ask kinds get the same one, because a gate ask and
-- an open-ended ask are indistinguishable on the wire (both carry no options).
answerFooter :: TabIndex -> PendingQuestion -> Text
answerFooter idx q = case lqOptions q of
  [] -> "Answer with /" <> c <> " <your answer>."
  _  -> "Answer with /" <> c <> " 1 or /" <> c <> " <your answer>."
  where
    c = T.singleton (tabIndexToChar idx)
