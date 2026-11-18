{-# LANGUAGE OverloadedStrings #-}
-- | Pure classification of Ollama's observed readiness.
--
-- The module exists because @configured@ answers "did the operator express
-- intent?" and nothing else. On a machine with no daemon, no binary and no
-- models, @configured@ is still @True@ for a keyless local Ollama — so the
-- provider dropdowns, the CRUD list, the setup wizard and @\/provider list@
-- all asserted usability they had never observed. This module is the second,
-- observed axis.
--
-- Everything here is pure and total. The I/O — the HTTP probe, the cache, the
-- single-flight gate, @findExecutable@, the RAM reader — lives in
-- "Seal.Providers.OllamaReadinessProbe".
--
-- == Why "refused" is decided on errno, never on the message
--
-- Measured on GHC 9.12 \/ http-client against a real closed port:
--
-- > refusal:      type=NoSuchThing  msg="does not exist"  errno=Just 61
-- > DNS failure:  type=NoSuchThing  msg="does not exist"  errno=Nothing
--
-- The two are byte-identical in exception type and message. A substring match
-- on @\"refused\"@ never fires, which would make 'RdNotRunning' unreachable
-- and re-create the very bug this module exists to fix. 'classifyProbeFailure'
-- therefore discriminates on 'ioe_errno' alone, and everything it cannot
-- positively identify is 'OpeOther' — "do not claim to know".
module Seal.Providers.OllamaReadiness
  ( OllamaReadiness (..)
  , OllamaProbeError (..)
  , OllamaHostKind (..)
  , OllamaTag (..)
  , OllamaProbe (..)
  , classifyOllamaReadiness
  , isCloudModel
  , parseMemTotal
  , readinessText
  , readinessWire
  , readinessUsableCount
  , classifyProbeFailure
  , probeTargetFor
  , hostKindFor
  , singleFlightKey
  , probeTimeoutMicro
  ) where

import Control.Exception (IOException, fromException)
import Data.Char (isDigit)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64)
import Foreign.C.Error (Errno (..), eCONNREFUSED)
import GHC.IO.Exception (ioe_errno)
import Network.HTTP.Client
  ( HttpException (..), HttpExceptionContent (..), Request (..), parseRequest
  , responseTimeoutMicro )
import Network.HTTP.Types.Header (hContentType)

import Seal.Providers.Ollama (defaultOllamaBaseUrl)
import Seal.Web.UrlSafety (isAlwaysBlockedUrl)

-- | The second, observed axis. 'RdPending' means /this process has not
-- finished a probe yet/ — it is the only state that renders as nothing,
-- because "we have not looked" must never be shown as a verdict.
data OllamaReadiness
  = RdPending          -- ^ no probe has completed yet in this process
  | RdUnknown          -- ^ a probe ran and failed unexplainably
  | RdNotInstalled     -- ^ loopback URL, nothing listening, no binary on PATH
  | RdNotRunning       -- ^ loopback URL, connection REFUSED
  | RdNoModels         -- ^ daemon answered, zero models
  | RdNoFittingModel   -- ^ daemon answered, models exist, none usable (advisory)
  | RdReady !Int       -- ^ N usable models; @n >= 1@ by construction
  | RdCloud            -- ^ ollama.com: no probe performed
  deriving stock (Eq, Show)

-- | Why a probe did not produce a tag list. 'OpeRefused' is the only
-- constructor that permits the 'RdNotRunning' claim.
data OllamaProbeError
  = OpeRefused       -- ^ only: ConnectionFailure with @ioe_errno == eCONNREFUSED@
  | OpeBlocked       -- ^ refused by the SSRF floor / URL-shape check, pre-request
  | OpeTimeout
  | OpeBadResponse   -- ^ something answered, but not with Ollama's JSON (or over the cap)
  | OpeHttp !Int     -- ^ non-2xx status; a 3xx lands here (redirects are never followed)
  | OpeOther         -- ^ any other transport failure (reset, TLS, DNS, non-IOError)
  deriving stock (Eq, Show)

-- | Where the base URL points. Split from the binary check because only the
-- default-loopback spelling may refine its wording from @findExecutable@
-- (D3.3): a Docker-hosted daemon is "not running", not "not installed".
data OllamaHostKind
  = OhCloud           -- ^ host is ollama.com: no probe at all
  | OhDefaultLoopback -- ^ literally 'defaultOllamaBaseUrl': binary wording allowed
  | OhLoopback        -- ^ 127\/8 \/ [::1] \/ localhost, any port
  | OhOtherHost       -- ^ LAN \/ remote
  deriving stock (Eq, Show)

-- | One installed model, as @\/api\/tags@ reports it.
--
-- The two optional fields are what make the fit judgement hedgeable rather
-- than assertive: an absent size or an absent RAM figure is /no evidence/, and
-- no evidence must never become a claim (design D5.3).
data OllamaTag = OllamaTag
  { otName       :: !Text
  , otSizeBytes  :: !(Maybe Word64)
    -- ^ 'Nothing' = the daemon reported no size.
  , otRemoteHost :: !(Maybe Text)
    -- ^ 'Just' = the model runs server-side (cloud), so it is never sized
    --   against local RAM.
  } deriving stock (Eq, Show)

-- | The pure inputs to classification. Assembled by the I/O module.
data OllamaProbe = OllamaProbe
  { opHostKind      :: !OllamaHostKind
  , opTags          :: !(Either OllamaProbeError [OllamaTag])
  , opBinaryPresent :: !Bool
    -- ^ Only consulted for 'OhDefaultLoopback' \/ 'OhLoopback' refusals.
  , opTotalRam      :: !(Maybe Word64)
    -- ^ Unused in WU-A; WU-B's fit predicate consumes it.
  } deriving stock (Eq, Show)

-- | The state machine. Total, and deliberately narrow: every branch that is
-- not positively identified degrades to 'RdUnknown'.
classifyOllamaReadiness :: OllamaProbe -> OllamaReadiness
classifyOllamaReadiness p = case opHostKind p of
  -- An ollama.com endpoint is not probed at all, so there is nothing to
  -- classify — and "not ready" would simply be false.
  OhCloud -> RdCloud
  _ -> case opTags p of
    Right [] -> RdNoModels
    Right tags -> classifyTags (opTotalRam p) tags
    Left OpeRefused
      -- A refusal is evidence about *this* machine only when the URL points
      -- at this machine. For a LAN or remote host, our own PATH says nothing.
      | opHostKind p == OhDefaultLoopback || opHostKind p == OhLoopback ->
          if opBinaryPresent p then RdNotRunning else RdNotInstalled
      | otherwise -> RdUnknown
    -- Everything else — blocked, timed out, malformed, an HTTP status, a
    -- reset, TLS, DNS — is "we do not know", never "not running".
    Left _ -> RdUnknown

-- | Count the usable models, or report that none of the /sized/ ones fit.
--
-- The rules, all from design D5.3, are deliberately symmetric — RAM and size
-- are treated the same way, because an asymmetry would emit
-- @May Not Fit in RAM@ with zero evidence on one side:
--
-- * A /cloud/ model is always usable and is never sized locally
--   ('isCloudModel').
-- * An unknown size counts as usable: we cannot substantiate a problem.
-- * Unknown RAM means /every/ local model is usable, and never
--   'RdNoFittingModel'.
-- * 'RdNoFittingModel' requires at least one /known/ size, and none of the
--   known-size local models fitting.
--
-- The "at least one known size" requirement is satisfied /by construction/
-- rather than by a separate guard, which is worth stating because it is the
-- kind of thing that looks like a missing case: 'isUsable' returns 'True' for
-- an unknown size, so @usable == 0@ can only happen when /every/ tag had a
-- known size and none of them fit. If a size is ever unknown, the model counts
-- as usable and we take the @RdReady@ branch — exactly the D5.3 rule
-- ("every size unknown ⇒ RdReady with the full count"), reached without an
-- extra test. An explicit @any hasKnownSize@ guard here would be dead code.
classifyTags :: Maybe Word64 -> [OllamaTag] -> OllamaReadiness
classifyTags mRam tags =
  case mRam of
    -- No RAM figure: nothing to judge against, so everything is usable.
    Nothing -> RdReady (length tags)
    Just ram ->
      let usable = length (filter (isUsable ram) tags)
      in if usable > 0
           then RdReady usable
           else RdNoFittingModel

-- | Is a model usable at the given total RAM?
--
-- Cloud models always are. A local model is usable when its size is unknown
-- (no evidence) or when 1.25x its size still fits in RAM. The comparison is
-- exact integer arithmetic — @size * 5 < ram * 4@ — so the predicate stays
-- pure and exact, and never rounds in the operator's favour or against it.
--
-- The arithmetic is done in 'Integer', not 'Word64'. @size@ comes from the
-- daemon, so it is untrusted input: a size near @2^64@ would wrap a 'Word64'
-- multiplication and make an absurd model compare as fitting. @Integer@ is
-- arbitrary-precision, so that cannot happen. RAM is bounded in practice, but
-- widening both sides keeps the comparison obviously exact rather than
-- exact-by-luck.
isUsable :: Word64 -> OllamaTag -> Bool
isUsable ram t
  | isCloudModel t = True
  | otherwise = case otSizeBytes t of
      Nothing   -> True
      Just size -> (toInteger size * 5) < (toInteger ram * 4)

-- | Is this model served remotely?
--
-- True when @remote_host@ is present /or/ the name carries the @:cloud@
-- suffix. @remote_host@ is authoritative when the two disagree: the suffix
-- alone is a naming convention, while the field is what the daemon actually
-- does.
isCloudModel :: OllamaTag -> Bool
isCloudModel t = case otRemoteHost t of
  Just _  -> True
  Nothing -> ":cloud" `T.isSuffixOf` otName t

-- | Parse @MemTotal:@ from one @\/proc\/meminfo@ line, as bytes.
--
-- @kB@ is the only accepted unit. A non-kB suffix yields 'Nothing' rather than
-- a silent rescale: a wrong 1000x guess would be worse than "RAM unknown",
-- which degrades safely to "assume usable". @MemTotal: 0 kB@ is 'Just 0' — a
-- real (if pathological) kernel value, not an absence.
parseMemTotal :: Text -> Maybe Word64
parseMemTotal line = do
  rest <- T.stripPrefix "MemTotal:" line
  case T.words rest of
    [valueT, unitT]
      | unitT == "kB" -> (* 1024) <$> readDecimal valueT
    _ -> Nothing
  where
    readDecimal t = case reads (T.unpack t) of
      [(n, "")] -> Just n
      _         -> Nothing

-- | How many models 'RdReady' counts. Exposed so the wire and the label
-- cannot disagree.
readinessUsableCount :: OllamaReadiness -> Maybe Int
readinessUsableCount (RdReady n) = Just n
readinessUsableCount _           = Nothing

-- | The CLI's rendering (@\/provider list@). Total over all eight
-- constructors; 'RdPending' is the empty string, and the caller omits the
-- segment when the text is empty rather than printing a stray separator.
readinessText :: OllamaReadiness -> Text
readinessText = \case
  RdPending        -> ""
  RdUnknown        -> "Status Unknown"
  RdNotInstalled   -> "Ollama Not Found"
  RdNotRunning     -> "Not Running"
  RdNoModels       -> "No Models Pulled"
  RdNoFittingModel -> "May Not Fit in RAM"
  RdReady 1        -> "Ready · 1 Model"
  RdReady n        -> "Ready · " <> T.pack (show n) <> " Models"
  RdCloud          -> "Cloud"

-- | The wire value (kebab-case, matching @api-key@ \/ @vault-locked@). The
-- frontend's label table keys off exactly these strings.
readinessWire :: OllamaReadiness -> Text
readinessWire = \case
  RdPending        -> "pending"
  RdUnknown        -> "unknown"
  RdNotInstalled   -> "not-installed"
  RdNotRunning     -> "not-running"
  RdNoModels       -> "no-models"
  RdNoFittingModel -> "no-fitting-model"
  RdReady _        -> "ready"
  RdCloud          -> "cloud"

-- ---------------------------------------------------------------------------
-- Failure classification
-- ---------------------------------------------------------------------------

-- | Turn an 'HttpException' into the probe's own error type. The /only/ way
-- to get 'OpeRefused' is a @ConnectionFailure@ whose payload unwraps to an
-- 'IOException' with @ioe_errno == Just n@ and @Errno n == eCONNREFUSED@.
--
-- Note the unwrap: @ConnectionFailure@ carries a 'SomeException', not an
-- 'IOException', so matching on an 'IOException' pattern directly does not
-- typecheck. The trailing catch-all is an intentional fail-safe, not an
-- oversight — it absorbs any future 'HttpException' shape as "do not claim to
-- know" rather than inventing a state.
classifyProbeFailure :: HttpException -> OllamaProbeError
classifyProbeFailure (HttpExceptionRequest _ (ConnectionFailure se)) =
  case fromException se :: Maybe IOException of
    Just ioe -> case ioe_errno ioe of
      Just n | Errno n == eCONNREFUSED -> OpeRefused
      _                                -> OpeOther
    Nothing -> OpeOther
classifyProbeFailure (HttpExceptionRequest _ ResponseTimeout) = OpeTimeout
classifyProbeFailure _ = OpeOther

-- ---------------------------------------------------------------------------
-- The request
-- ---------------------------------------------------------------------------

-- | The probe's per-request timeout. Two seconds, deliberately /not/ the
-- provider's five-minute 'Seal.Providers.Ollama.ollamaResponseTimeoutMicro':
-- the cache caps in-flight probes at one globally, so a probe that never
-- returns would hold that slot forever and starve every later refresh.
probeTimeoutMicro :: Int
probeTimeoutMicro = 2_000_000

-- | Validate a base URL and build the probe request. Pure, so the URL-shape
-- and SSRF rules are testable without a socket.
--
-- Rejected, in order of cheapness:
--
-- * a scheme other than http\/https ('OpeBlocked');
-- * any authority carrying userinfo ('OpeBlocked') — @http:\/\/x\@169.254.169.254\/@
--   is the bypass this rule closes;
-- * a URL the SSRF floor blocks ('OpeBlocked') — the cloud-metadata literals;
-- * a URL http-client cannot parse ('OpeBadResponse').
--
-- The resulting request is built from 'parseRequest' plus explicit fields. It
-- never goes through @withHeaders@, so it cannot acquire the vault key: the
-- probe is keyless by construction (D2.1).
probeTargetFor :: Text -> Either OllamaProbeError Request
probeTargetFor baseUrl
  | not (isHttpScheme baseUrl) = Left OpeBlocked
  | carriesUserinfo baseUrl = Left OpeBlocked
  | isAlwaysBlockedUrl baseUrl = Left OpeBlocked
  | otherwise = case parseRequest (T.unpack ("GET " <> baseUrl <> "/api/tags")) of
      Left _ -> Left OpeBadResponse
      Right req -> Right req
          { requestHeaders  = [ (hContentType, "application/json") ]
          -- Never follow a redirect: a 3xx is reported, not chased. This is
          -- what keeps a metadata redirect from being reached at all.
          , redirectCount   = 0
          , responseTimeout = responseTimeoutMicro probeTimeoutMicro
          }

-- | Everything after @scheme://@. 'T.breakOn' leaves the delimiter in the
-- suffix, so it must be dropped — keeping it would make the authority
-- @"://localhost:11434"@ and every host comparison fail.
afterSchemeOf :: Text -> Text
afterSchemeOf url = T.drop 3 (snd (T.breakOn "://" url))

-- | The scheme check. Deliberately not a URL parser: it only needs to know
-- whether the prefix is one of the two allowed schemes.
isHttpScheme :: Text -> Bool
isHttpScheme url =
  "http://" `T.isPrefixOf` lowered || "https://" `T.isPrefixOf` lowered
  where lowered = T.toLower url

-- | Does the authority carry userinfo (an @\@@ before the path)? This is the
-- D2.8 bypass guard. The last @\@@ in the authority is the separator, because
-- a password may itself contain one.
carriesUserinfo :: Text -> Bool
carriesUserinfo url =
  let afterScheme = afterSchemeOf url
      authority = T.takeWhile (\c -> c /= '/' && c /= '?' && c /= '#') afterScheme
  in T.any (== '@') authority

-- ---------------------------------------------------------------------------
-- Host kind
-- ---------------------------------------------------------------------------

-- | Which host kind a base URL is. The comparison is on the authority (after
-- userinfo and port stripping), and @localhost@ must match /exactly/ — a
-- @localhost.attacker.tld@ is 'OhOtherHost', not the default loopback.
hostKindFor :: Text -> OllamaHostKind
hostKindFor baseUrl
  | host == "ollama.com" = OhCloud
  | stripTrailingSlash baseUrl == defaultOllamaBaseUrl = OhDefaultLoopback
  | isLoopbackHost host = OhLoopback
  | otherwise = OhOtherHost
  where
    host = hostOf baseUrl

-- | The authority's host: userinfo stripped, port stripped, IPv6 brackets
-- stripped and lowercased. A small local twin of
-- @Seal.Web.UrlSafety@'s internal helper (which is deliberately not exported);
-- keeping it here means the readiness rules are testable without widening that
-- module's public surface.
hostOf :: Text -> Text
hostOf url =
  let afterScheme = afterSchemeOf url
      authority = T.takeWhile (\c -> c /= '/' && c /= '?' && c /= '#') afterScheme
      afterUserinfo = snd (T.breakOnEnd "@" authority)
  in T.toLower $ case T.uncons afterUserinfo of
       Just ('[', rest) -> T.takeWhile (/= ']') rest
       _                -> T.takeWhile (/= ':') afterUserinfo

-- | The loopback aliases that count as "this machine" for state purposes
-- (D3.4): @localhost@, all of @127\/8@, and the IPv6 loopback @::1@. Only the
-- exact spellings count — a hostname that merely starts with one does not.
isLoopbackHost :: Text -> Bool
isLoopbackHost host =
  host == "localhost"
  || host == "::1"
  || case T.stripPrefix "127." host of
       Just rest -> not (T.null rest) && T.all isDigitable rest
       Nothing   -> False
  where
    isDigitable c = isDigit c || c == '.'

-- ---------------------------------------------------------------------------
-- Cache key
-- ---------------------------------------------------------------------------

-- | The single-flight key: the base URL with one trailing slash removed. Two
-- spellings that differ only by that slash must share one in-flight probe
-- (D2.10).
singleFlightKey :: Text -> Text
singleFlightKey = stripTrailingSlash

-- | Drop exactly one trailing slash. A local twin of the same rule in
-- @Seal.Providers.Ollama@, which keeps it private; duplicating three lines is
-- cheaper than widening that module's surface, and both spellings must agree
-- so the cache key is stable.
stripTrailingSlash :: Text -> Text
stripTrailingSlash t = fromMaybe t (T.stripSuffix "/" t)
