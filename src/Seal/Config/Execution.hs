{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | @config\/execution.toml@ — the SSH machine inventory.
--
-- Three things live here, deliberately together because they must agree
-- about the same document:
--
--   * the /codec/ ('executionConfigCodec') — what a valid document is;
--   * the /loader/ ('loadExecutionConfig') — absent file, legacy synthesis,
--     and the warnings that are not errors;
--   * the /writer/ ('saveExecutionConfig', 'updateExecutionConfig') — atomic,
--     serialised, validating the /resulting/ document before it lands.
--
-- Why the loader takes a 'Bool': @default = \"local\"@ is a load error when
-- @allow_localhost = false@ and legal when it is @true@, so neither the codec
-- nor the inventory alone can decide it. The value comes from
-- 'Seal.Config.Security.allowLocalhostFrom' — never re-derived here.
--
-- Why the writer is not 'Seal.Config.Security.writeSecretFile': that opens
-- with @trunc = True@ and writes in place, so a partial write leaves a
-- truncated inventory and every subsequent turn fails closed. @path.tmp@ then
-- @rename@ (the shape 'Seal.SourceControl.Registry.saveRepoRegistry' uses)
-- is what makes a rejected write leave the file byte-identical.
--
-- File mode is the default, like @config.toml@ and @repos.toml@: the file
-- holds paths and hostnames, not secrets, and its purpose is to be
-- git-committed — @0600@ would be a needless deviation.
--
-- **No opcode may call 'saveExecutionConfig' or 'updateExecutionConfig'.**
-- The inventory decides where untrusted code runs, so an agent that could
-- write it under @allow_localhost = false@ could add a machine pointing
-- anywhere. The only writer is the passkey-gated route.
module Seal.Config.Execution
  ( ExecutionConfig (..)
  , executionFilePath
  , executionWriteLock
  , loadExecutionConfig
  , loadExecutionConfigWith
  , saveExecutionConfig
  , updateExecutionConfig
  , executionConfigCodec
  , validateExecutionConfig
  ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Monad.State (modify)
import Data.Bifunctor (first)
import Data.HashMap.Strict qualified as HashMap
import Data.List (group, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory
  ( createDirectoryIfMissing, doesDirectoryExist, doesFileExist, renameFile )
import System.FilePath (takeDirectory)
import System.IO.Unsafe (unsafePerformIO)
import Validation (Validation (..))

import Toml ((.=))
import Toml qualified
import Toml.Codec.BiMap (BiMap (..), TomlBiMap, TomlBiMapError (..))
import Toml.Codec.Error (TomlDecodeError (..))
import Toml.Codec.Types (Codec (..), TomlCodec, eitherToTomlState)
import Toml.Parser (parseKey, unTomlParseError)
import Toml.Type.Key (Key, pattern (:||), unPiece)
import Toml.Type.Printer (prettyKey)
import Toml.Type.TOML (TOML (..), insertKeyAnyVal)

import Seal.Config.Paths (SealPaths, executionFilePath)
import Seal.Config.Security
  ( UntrustedExecFileConfig (..), UntrustedExecRemoteFileConfig (..) )
import Seal.Execution.Types
  ( MachineName, SshMachineSpec (..), TargetError (..)
  , getSshLocalPath, machineNameText, mkMachineName, mkSshLocalPath )
import Seal.Tools.Exec.Types
  ( getRemotePath, getSshHost, getSshUser, mkRemotePath, mkSshHost, mkSshUser )

-- ---------------------------------------------------------------------------
-- The type
-- ---------------------------------------------------------------------------

-- | The decoded inventory. 'ecDefault' is the /explicit/ @default@ key, not
-- the /effective/ default — that is a resolution rule (design §5) and the
-- resolver owns it, so there is one place it can be wrong.
data ExecutionConfig = ExecutionConfig
  { ecDefault  :: Maybe MachineName
  , ecMachines :: Map MachineName SshMachineSpec
  }
  deriving stock (Eq, Show)

-- | TOML keys that may never name a machine. @local@ is a legal
-- 'MachineName' — it is pinnable and it can be the effective default — but a
-- @[machines.local]@ / @[machines.default]@ table would collide with the
-- reserved literals, so the refusal belongs to the codec, not the newtype.
reservedMachineKeys :: [Text]
reservedMachineKeys = ["local", "default"]
-- ---------------------------------------------------------------------------
-- Codec
-- ---------------------------------------------------------------------------

-- | The whole document: an optional top-level @default@ plus @[machines.*]@.
executionConfigCodec :: Bool -> TomlCodec ExecutionConfig
executionConfigCodec allowLocalhost = ExecutionConfig
  <$> optionalValidatedCodec defaultKey parseDefault machineNameText .= ecDefault
  <*> machineTableCodec .= ecMachines
  where
    defaultKey = keyOf "default"
    -- `default = "local"` is only meaningful when untrusted code may run
    -- here. Refusing it in the codec as well as in the resolver is
    -- deliberate belt-and-braces: the resolver must be correct on its own,
    -- and the codec is where a human gets a message naming the file.
    parseDefault t
      | t == "local" && not allowLocalhost =
          Left "default cannot be \"local\" while allow_localhost = false"
      | otherwise = mkMachineName t

-- | @[machines.\<name\>]@ — keyed by validated name, mirroring
-- 'Seal.SourceControl.Repo.repoRegistryCodec'.
machineTableCodec :: TomlCodec (Map MachineName SshMachineSpec)
machineTableCodec = Toml.tableMap keyMachineBiMap machineCodecByKey machinesKey
  where
    machinesKey = keyOf "machines"

-- | Make the @machines@ node explicit before decoding.
--
-- 'Toml.tableMap' looks the node up by requiring an explicit value in the
-- parsed AST. A file that declares only @[machines.\<name\>]@ sub-tables —
-- the idiomatic style, and what every hand-written inventory uses — never
-- writes a bare @[machines]@ header, so the node is /implicit/ in tomland's
-- prefix tree and the lookup silently returns an empty map. This walks the
-- AST once and makes that node explicit. Direct sibling of
-- 'Seal.SourceControl.Repo.normalizeReposTable', and required for the same
-- reason.
normalizeMachinesTable :: TOML -> TOML
normalizeMachinesTable t =
  t { tomlTables = HashMap.adjust explicitNode "machines" (tomlTables t) }
  where
    explicitNode :: Toml.PrefixTree TOML -> Toml.PrefixTree TOML
    explicitNode tree = case tree of
      Toml.Branch pref Nothing children ->
        Toml.Leaf pref (mempty { tomlTables = children })
      Toml.Branch _ (Just _) _ -> tree
      Toml.Leaf (_ :|| []) _  -> tree
      Toml.Leaf (_ :|| (p : ps)) v ->
        Toml.Leaf ("machines" :|| []) (mempty { tomlTables = Toml.single (p :|| ps) v })

machineCodecByKey :: Key -> TomlCodec SshMachineSpec
machineCodecByKey rawKey =
  case mkMachineName raw of
    Left msg -> failingCodec rawKey msg
    Right n
      | raw `elem` reservedMachineKeys ->
          failingCodec rawKey
            ("[machines." <> raw <> "] is reserved; machine names `local` and \
             \`default` cannot be declared")
      | otherwise -> Toml.table (machineCodec n) rawKey
  where
    raw = displayKey rawKey

-- | A codec that always fails on decode, so a rejected key is a decode
-- 'Failure' rather than an `undefined` in a branch that "cannot happen".
failingCodec :: Key -> Text -> TomlCodec a
failingCodec rawKey msg =
  Codec (\_ -> Failure [BiMapError rawKey (ArbitraryError msg)])
        (\_ -> pure (error "unreachable: decoding an always-failing codec"))

keyMachineBiMap :: TomlBiMap Key MachineName
keyMachineBiMap = BiMap
  { forward  = first (ArbitraryError . prefix) . mkMachineName . displayKey
  , backward = first (ArbitraryError . unTomlParseError)
                 . parseKey . machineNameText
  }
  where
    prefix msg = "invalid machine name: " <> msg

-- | One machine's table. Each field decodes through a validating codec, so a
-- bad value fails closed with a message a human can act on — and that message
-- is the payload WU-7a's 400 body renders.
machineCodec :: MachineName -> TomlCodec SshMachineSpec
machineCodec n = SshMachineSpec
  <$> validatedCodec (fieldKey n "host") mkSshHost getSshHost       .= smsHost
  <*> validatedCodec (fieldKey n "user") mkSshUser getSshUser       .= smsUser
  <*> defaultedIntCodec (fieldKey n "port") 22                       .= smsPort
  <*> Toml.dioptional
        (validatedCodec (fieldKey n "identity") mkSshLocalPath
           (T.pack . getSshLocalPath))
                                                                     .= smsIdentity
  <*> validatedCodec (fieldKey n "known_hosts")
        mkSshLocalPath (T.pack . getSshLocalPath)                    .= smsKnownHosts
  <*> validatedCodec (fieldKey n "workspace") mkRemotePath getRemotePath
                                                                     .= smsWorkspace

-- | A required-or-defaulted 'Int'. @Toml.dioptional@ yields a 'Maybe', which
-- would need a 'Maybe' field; this fills the default at decode time so the
-- record carries the resolved value.
--
-- The range check lives in 'validateExecutionConfig' so the refusal can name
-- the machine.
defaultedIntCodec :: Key -> Int -> TomlCodec Int
defaultedIntCodec key dflt = Codec input output
  where
    input toml = case HashMap.lookup key (tomlPairs toml) of
      Nothing  -> Success dflt
      Just val -> case backward Toml._Int val of
        Left err -> Failure [BiMapError key err]
        Right i  -> Success i
    output i = do
      anyVal <- eitherToTomlState (forward Toml._Int i)
      i <$ modify (insertKeyAnyVal key anyVal)

-- | A machine's own field key. Bare, /not/ prefixed with the machine name:
-- 'Toml.table' has already nested the codec under the machine's key, so a
-- prefixed key would resolve to @machines.\<name\>.\<name\>.\<field\>@.
fieldKey :: MachineName -> Text -> Key
fieldKey _n = keyOf

keyOf :: Text -> Key
keyOf t = case parseKey t of
  Right k -> k
  Left _  -> case parseKey "machines" of
    Right k -> k
    -- parseKey of a plain dotted alphanumeric literal cannot fail; this arm
    -- exists only so the module has no partial function.
    Left _  -> error "unreachable: `parseKey` rejected a literal key"

displayKey :: Key -> Text
displayKey = T.filter (/= '"') . prettyKey

-- | A field that is /absent/ ⇒ 'Nothing', but a field that is /present and
-- invalid/ ⇒ a decode 'Failure'.
--
-- 'Toml.dioptional' cannot express this: it is @fmap Just . codecRead <!>
-- \\_ -> pure Nothing@, so it converts any failure — including a genuine
-- validation error — into 'Nothing'. For a security-relevant field that is
-- exactly the silent-move this feature exists to prevent: an unparseable
-- @default@ would be discarded and resolution would fall through to the next
-- row.
optionalValidatedCodec :: Key -> (Text -> Either Text a) -> (a -> Text) -> TomlCodec (Maybe a)
optionalValidatedCodec key parse render = Codec input output
  where
    input toml = case HashMap.lookup key (tomlPairs toml) of
      Nothing  -> Success Nothing
      Just val -> case backward Toml._Text val of
        Left err  -> Failure [BiMapError key err]
        Right txt -> case parse txt of
          Left msg -> Failure [BiMapError key (ArbitraryError msg)]
          Right a  -> Success (Just a)
    output Nothing  = pure Nothing
    output (Just a) = do
      anyVal <- eitherToTomlState (forward Toml._Text (render a))
      Just a <$ modify (insertKeyAnyVal key anyVal)

-- | A required field parsed into a validated type. A missing key is
-- 'KeyNotFound'; a rejected value is a 'BiMapError' carrying the parser's
-- message (so the field name travels with it).
validatedCodec :: Key -> (Text -> Either Text a) -> (a -> Text) -> TomlCodec a
validatedCodec key parse render = Codec input output
  where
    input toml = case HashMap.lookup key (tomlPairs toml) of
      Nothing  -> Failure [KeyNotFound key]
      Just val -> case backward Toml._Text val of
        Left err  -> Failure [BiMapError key err]
        Right txt -> case parse txt of
          Left msg -> Failure [BiMapError key (ArbitraryError msg)]
          Right a  -> Success a

    output a = do
      anyVal <- eitherToTomlState (forward Toml._Text (render a))
      a <$ modify (insertKeyAnyVal key anyVal)

-- ---------------------------------------------------------------------------
-- Loader
-- ---------------------------------------------------------------------------

loadExecutionConfig :: Bool -> SealPaths -> IO (Either TargetError ExecutionConfig)
loadExecutionConfig allowLocalhost paths =
  fmap fst <$> loadExecutionConfigWith allowLocalhost Nothing paths

-- | Load, with a legacy @[untrusted_execution]@ section available for
-- synthesis, returning non-fatal warnings alongside the config.
--
-- Legacy synthesis (design §1.5) is gated on the /derived/ @allow_localhost@,
-- not merely on the block being present: a byte-identical remote block means
-- \"run on the remote box\" under @mode = remote@ and \"run here\" under
-- @mode = local@, so presence alone would silently move untrusted execution.
-- An /incomplete/ block yields no machine rather than half of one.
loadExecutionConfigWith
  :: Bool
  -> Maybe UntrustedExecFileConfig
  -> SealPaths
  -> IO (Either TargetError (ExecutionConfig, [Text]))
loadExecutionConfigWith allowLocalhost legacy paths = do
  let path = executionFilePath paths
  exists <- doesFileExist path
  if not exists
    then pure (finish allowLocalhost legacy Nothing [])
    else do
      raw <- TIO.readFile path
      pure $ case Toml.parse raw of
        Left err   -> Left (TargetConfigLoadError (T.pack (show (unTomlParseError err))))
        Right toml -> finish allowLocalhost legacy (Just toml) (scanUnknownKeys toml)

finish
  :: Bool
  -> Maybe UntrustedExecFileConfig
  -> Maybe TOML
  -> [Text]
  -> Either TargetError (ExecutionConfig, [Text])
finish allowLocalhost legacy mtoml warns = do
  ec0 <- case mtoml of
    Nothing    -> Right (ExecutionConfig Nothing Map.empty)
    Just toml  -> case Toml.runTomlCodec (executionConfigCodec allowLocalhost)
                           (normalizeMachinesTable toml) of
      Success ec   -> Right ec
      Failure errs -> Left (TargetConfigLoadError (Toml.prettyTomlDecodeErrors errs))
  let ec = if not allowLocalhost && Map.null (ecMachines ec0)
             then maybe ec0 (synthesiseLegacy ec0) (legacyMachine legacy)
             else ec0
  validateExecutionConfig allowLocalhost ec
  pure (ec, warns)

-- | The implicit machine @default@ from a legacy block, or 'Nothing' when the
-- block is absent or incomplete.
legacyMachine :: Maybe UntrustedExecFileConfig -> Maybe SshMachineSpec
legacyMachine Nothing    = Nothing
legacyMachine (Just uec) = case uefcMode uec of
  -- `mode = "local"` means "run here"; the block is ignored, never migrated.
  Just "local" -> Nothing
  _ -> do
    r          <- uefcRemote uec
    host       <- uerfcHost r
    user       <- uerfcUser r
    knownHosts <- uerfcKnownHosts r
    workspace  <- uerfcWorkspace r
    h  <- rightToMaybe (mkSshHost host)
    u  <- rightToMaybe (mkSshUser user)
    kh <- rightToMaybe (mkSshLocalPath (T.pack knownHosts))
    w  <- rightToMaybe (mkRemotePath workspace)
    pure SshMachineSpec
      { smsHost       = h
      , smsUser       = u
      , smsPort       = fromMaybe 22 (uerfcPort r)
      , smsIdentity   = uerfcIdentity r >>= rightToMaybe . mkSshLocalPath . T.pack
      , smsKnownHosts = kh
      , smsWorkspace  = w
      }

synthesiseLegacy :: ExecutionConfig -> SshMachineSpec -> ExecutionConfig
synthesiseLegacy ec spec = case mkMachineName "default" of
  Left _  -> ec
  Right n -> ec { ecMachines = Map.insert n spec (ecMachines ec)
                , ecDefault  = Just n }

rightToMaybe :: Either a b -> Maybe b
rightToMaybe = either (const Nothing) Just

-- ---------------------------------------------------------------------------
-- Document-level validation (shared by loader and writer)
-- ---------------------------------------------------------------------------

-- | The rules that cannot be expressed field by field.
--
-- Called by the loader /and/ by 'updateExecutionConfig' on the document it is
-- about to write. Without the second call the screen could create the very
-- state the route cannot repair: a second machine with no @default@, after
-- which every subsequent write is also invalid.
validateExecutionConfig
  :: Bool -> ExecutionConfig -> Either TargetError ()
validateExecutionConfig allowLocalhost ec = do
  mapM_ checkPort (Map.toList (ecMachines ec))
  case duplicates (map aliasOf (Map.elems (ecMachines ec))) of
    (alias:_) -> Left (TargetConfigLoadError
      ("two machines share the address " <> alias
        <> "; they would share one multiplexed connection, so the first"
        <> " connection's key and pinned host key would serve both"))
    []        -> Right ()
  when' (Map.size (ecMachines ec) >= 2 && isNothing (ecDefault ec))
    (Left (TargetConfigLoadError
      "more than one machine is defined; set `default` to one of them"))
  case ecDefault ec of
    Nothing -> Right ()
    Just d
      | machineNameText d == "local", not allowLocalhost ->
          Left (TargetLocalNotAllowed d)
      | machineNameText d == "local" -> Right ()
      | Map.member d (ecMachines ec) -> Right ()
      | otherwise -> Left (TargetConfigLoadError
          ("default names \"" <> machineNameText d
            <> "\", which is not in [machines]"))
  where
    checkPort (n, s)
      | smsPort s < 1 || smsPort s > 65535 =
          Left (fieldError n "port must be between 1 and 65535")
      | otherwise = Right ()
    fieldError n msg = TargetConfigLoadError
      ("[machines." <> machineNameText n <> "]: " <> msg)
    when' c e = if c then e else Right ()

aliasOf :: SshMachineSpec -> Text
aliasOf s = getSshHost (smsHost s) <> ":" <> T.pack (show (smsPort s))
              <> ":" <> getSshUser (smsUser s)

duplicates :: [Text] -> [Text]
duplicates xs =
  [ x | g@(x:_) <- group (sortOn id xs), length g > 1 ]

-- ---------------------------------------------------------------------------
-- Writer
-- ---------------------------------------------------------------------------

-- | Atomically write @ec@ to @path@: @path.tmp@ then @rename@. Creates the
-- parent directory if it is missing (the first run seeds @config\/@, but a
-- test or a fresh @SEAL_HOME@ may not have).
--
-- Deliberately does /not/ validate: 'updateExecutionConfig' is the validating
-- entry point, and seeding an empty, comment-only inventory
-- (@ExecutionConfig Nothing Map.empty@) must be possible.
saveExecutionConfig :: FilePath -> ExecutionConfig -> IO ()
saveExecutionConfig path ec = do
  let dir = takeDirectory path
  exists <- doesDirectoryExist dir
  if exists then pure () else createDirectoryIfMissing True dir
  let tmp = path <> ".tmp"
  TIO.writeFile tmp (encodeConfig ec)
  renameFile tmp path

encodeConfig :: ExecutionConfig -> Text
encodeConfig = Toml.encode (executionConfigCodec True)

-- | Process-wide lock serialising inventory writes.
--
-- DEDICATED, not shared with 'Seal.Config.File.configWriteLock': a slow
-- inventory write must not block a config read, and the two documents have
-- different writers.
{-# NOINLINE executionWriteLock #-}
executionWriteLock :: MVar ()
executionWriteLock = unsafePerformIO (newMVar ())

-- | Load, apply, validate the /resulting/ document, write. Serialised behind
-- 'executionWriteLock'.
--
-- The resulting-document check is what stops the screen from creating a second
-- machine with no @default@ — a state the route would then be unable to
-- repair, because the next write could not be validated either.
--
-- The encoded form is decoded back before the rename, so the codec and the
-- encoder cannot drift: the codec test alone never exercises the writer's
-- encoder.
--
-- A rejected write never touches the file, so it stays byte-identical.
updateExecutionConfig
  :: Bool
  -> FilePath
  -> (ExecutionConfig -> ExecutionConfig)
  -> IO (Either TargetError ExecutionConfig)
updateExecutionConfig allowLocalhost path f = withMVar executionWriteLock $ \_ -> do
  loaded <- loadAt
  case loaded of
    Left e -> pure (Left e)
    Right ec -> case step ec of
      Left e    -> pure (Left e)
      Right ec' -> saveExecutionConfig path ec' >> pure (Right ec')
  where
    loadAt = do
      exists <- doesFileExist path
      if not exists
        then pure (Right (ExecutionConfig Nothing Map.empty))
        else do
          raw <- TIO.readFile path
          pure (decode False raw)

    step ec = do
      let ec' = f ec
      validateExecutionConfig allowLocalhost ec'
      -- round-trip: the encoded document must decode to the same inventory
      case decode True (encodeConfig ec') of
        Left e   -> Left e
        Right rt
          | ecMachines rt == ecMachines ec' && ecDefault rt == ecDefault ec'
              -> Right ec'
          | otherwise -> Left (TargetConfigLoadError
              "the inventory did not survive an encode/decode round-trip; \
              \refusing to write a document the loader cannot read back")

decode :: Bool -> Text -> Either TargetError ExecutionConfig
decode allowLocalhost raw = case Toml.parse raw of
  Left err   -> Left (TargetConfigLoadError (T.pack (show (unTomlParseError err))))
  Right toml -> case Toml.runTomlCodec (executionConfigCodec allowLocalhost)
                         (normalizeMachinesTable toml) of
    Success ec   -> Right ec
    Failure errs -> Left (TargetConfigLoadError (Toml.prettyTomlDecodeErrors errs))

-- ---------------------------------------------------------------------------
-- Unknown-key warnings
-- ---------------------------------------------------------------------------

-- | A typo'd key is a /warning/, not an error: @identiy@ silently defaulting
-- to ssh-agent is exactly the failure this catches, and failing the whole
-- boot on a cosmetic slip would be worse.
--
-- Only the top level is scanned. A per-machine scan would need the raw prefix
-- tree, and the top level already catches the case that matters (a mistyped
-- @default@).
scanUnknownKeys :: TOML -> [Text]
scanUnknownKeys toml = topLevel <> concatMap perMachine (machineBodies toml)
  where
    topLevel =
      [ "unknown key at top level: " <> displayKey k
      | k <- HashMap.keys (tomlPairs toml)
      , displayKey k `notElem` (["default", "machines"] :: [Text])
      ]
    perMachine (name, body) =
      [ "unknown key in [machines." <> name <> "]: " <> displayKey k
      | k <- HashMap.keys (tomlPairs body)
      , displayKey k `notElem` knownMachineFields
      ]

-- | Each declared machine's own table body, read from the parsed AST.
--
-- Walking the AST (rather than the decoded 'Map') is what lets a mistyped
-- field still be reported: the codec ignores unknown keys by design, so the
-- warning has to come from here.
machineBodies :: TOML -> [(Text, TOML)]
machineBodies toml = maybe [] collect (HashMap.lookup "machines" (tomlTables toml))
  where
    -- The `machines` node is either a Branch (a bare `[machines]` header was
    -- written) or a Leaf holding the single sub-table. Descend one level in
    -- both cases, then label each child by its HashMap key — the machine
    -- name — carrying the child's own body.
    collect = \case
      -- `[machines.a]` and `[machines.b]` — a Branch with one child per name.
      Toml.Branch _ _ children -> concatMap (uncurry one) (HashMap.toList children)
      -- A single `[machines.builder]` folds into one Leaf whose prefix is
      -- `machines :| ["builder"]`, so the name is that leaf's last piece.
      Toml.Leaf (p :|| ps) v   -> [(unPiece (if null ps then p else last ps), v)]
    one piece tree = case tree of
      Toml.Leaf _ body            -> [(unPiece piece, body)]
      Toml.Branch _ (Just body) _ -> [(unPiece piece, body)]
      Toml.Branch _ Nothing _     -> []

knownMachineFields :: [Text]
knownMachineFields =
  ["host", "user", "port", "identity", "known_hosts", "workspace"]
