# Multiple execution machines — implementation plan (single PR)

<!-- design: docs/superpowers/specs/2026-11-25-multiple-execution-machines-design-rev10.md -->
<!-- status: awaiting plan review gate -->
<!-- scope: 14 work units (13 design + 1 docs), one PR, one branch -->

Date: 2026-11-25 · Branch: `exec/multiple-machines` · Base: `main`

## 0. What this plan is

Execute **the feature's own design units plus one documentation unit in a single PR**. There is no
milestone seam, no Checkpoint A, no destructive phase: the design is additive
throughout, so the whole feature lands together or not at all.

The design is the authority for *why*. This document is the authority for *what order,
what files, what test, what command*. Where the two disagree, the design wins and this
plan has a bug.

**Explicitly excluded: WU-10 (`group` sanitisation).** The design carries a fourteenth
unit, `group` sanitisation, and this plan does **not** include it. It is a pre-existing bug
in `SKILL_WRITE`/`AGENT_DEF` that cannot reach `execution.toml` (`.md` is unconditionally
appended), the design itself says it "is not load-bearing for §4.3" and "may deserve its
own issue regardless of whether this feature ships", and the user's ruling that the memory
system is "completely unrelated to the execution machines" applies to it by the same
reasoning. **Land it as its own PR.** It is omitted here so this PR is one logical change.

**Read before starting:** design rev 10 §5 (the seven-row resolver — it is the spine of
the whole feature), §4 (the trust model and why there is no localhost denylist), and §7
(the design's thirteen feature units plus WU-11). Then run the checker:

```bash
python3 scripts/check-spec-counts.py docs/superpowers/specs/2026-11-25-multiple-execution-machines-design-rev10.md
```

It must print `all checks passed`. If it does not, the design and this plan are out of
sync and you are working from a stale document.

## 1. Ground rules

These are not negotiable and they are not aspirational — each one has already caused a
defect in this feature's history.

1. **TDD.** Failing test first, then the minimal implementation, then commit. The §8 test
   table in the design is the specification; this plan repeats it per unit so you never
   need two windows.
2. **One unit, one commit** (except where a unit explicitly says otherwise). `make check`
   must be green at every commit — build + test + lint + frontend-test.
3. **`make check` is the gate, not `cabal build`.** `-Werror` is on; a module in no cabal
   stanza is never typechecked, so wiring is part of the unit that creates the module.
4. **Never `--no-verify`, never force-push, never skip CI.**
5. **Stay in the unit's file scope.** If a unit needs a file it does not list, stop and
   amend this plan — the recurring defect in this feature's review history is a unit
   scoped against an incomplete file list.
6. **Counts are checked by script, not by eye.** `scripts/check-spec-counts.py` catches
   count drift between the design and itself. If you add a work unit, the script's
   unit-count check will fail until the design is updated too.
7. **SIGPIPE:** never pipe `cabal`/`hlint` through `head`/`tail`. Redirect and page.
8. **Draft PR immediately** after the first commit. `gh pr create --draft --head
   exec/multiple-machines --fill --body "Closes #<NN>"`.

### Verification commands

```bash
make build                                   # cabal build all, -Werror clean
make test                                    # hspec + QuickCheck
make lint                                    # hlint src/ test/ → "No hints"
make check                                   # build + test + lint + frontend-test
python3 scripts/check-spec-counts.py <design> # design/plan count consistency
python3 scripts/count-sessionmeta-sites.py    # 77 sites, 27 record / 50 positional
```

## 2. Unit order and why

The order is a topological sort of the dependency edges, with the demo as early as it
can be.

Commit order (matches the section order below):

```
1. WU-1    Types (pure)                     vocabulary + Ord + dash guards
2. WU-1b   ssh argv builders                -F /dev/null, ControlPath hash
4. WU-2    execution.toml codec/loader/writer
5. WU-3    Seal.Execution.Resolve           needs WU-2's codec
6. WU-4    the per-session pin              77 sites: 27 record / 50 positional
7. WU-5    collapse nine derivations        needs WU-1b, WU-3, WU-4
8. WU-6    --machine, both parsers          ← DEMO CHECKPOINT
9. WU-6b   chat/Telegram mint paths
10. WU-7a  machine write API                THE SECURITY CONTROL; needs WU-2's writer
11. WU-7b  GET /api/machines + dropdown     needs WU-7a (emitters) and WU-6 (body field)
12. WU-7c  the Machines screen              needs WU-7b
13. WU-8   session-viewer surface
13. WU-9   -f remote-only-untrusted coercion
14. WU-11  docs: security.toml template + execution.toml example + CHANGELOG
```

Hard edges, each of which has bitten an earlier revision:

- **WU-1 before everything.** `MachineName`/`SshMachineSpec`/`ResolvedTarget` are the
  vocabulary. Also carries the `Ord` derivations on `SshHost`/`SshUser`/`SshConfig` that
  `ResolvedTarget`'s `Ord` needs — without them it does not compile.
- **WU-1b before WU-5.** WU-5 changes the argv; WU-1b changes the argv. Doing WU-5 first
  would leave WU-1b updating assertions twice.
- **WU-2 before WU-3.** The resolver needs the codec. Rev 4 had these reversed and
  `make check` could not pass.
- **WU-2 before WU-7a.** WU-7a calls `updateExecutionConfig`, which WU-2 ships.
- **WU-4 before WU-5.** WU-5's cache key includes the pin; the pin must exist.
- **WU-6 before WU-7b.** `CreateTabBody.machine` (WU-6) precedes the picker that fills it.
- **WU-9 is independent** except that it edits `allowLocalhostFrom` from WU-2. Do it last;
  it is the only unit needing a second build variant.

---

## WU-1 — `Seal.Execution.Types` (pure)

**Design:** §3.2, §5, §6.2, §7 WU-1.

### Files
- `src/Seal/Execution/Types.hs` (new)
- `src/Seal/Tools/Exec/Types.hs` (edit: `Ord` on three newtypes, leading-`-` guards)
- `test/Seal/Execution/TypesSpec.hs` (new)
- `seal-harness.cabal` (library `exposed-modules:`, test `other-modules:`)
- `test/Main.hs` (wire the spec)

### Deliverables
```haskell
newtype MachineName = MachineName Text   -- constructor unexported
mkMachineName :: Text -> Either Text MachineName
machineNameText :: MachineName -> Text

data ResolvedTarget = WhereLocal | WhereSsh MachineName SshConfig
  deriving stock (Eq, Ord, Show)

data TargetPaths = TargetPaths { tpExecution :: Text, tpSecurity :: Text }

data TargetError
  = TargetUnknownMachine  MachineName [MachineName]
  | TargetLocalNotAllowed MachineName
  | TargetConfigLoadError Text
  | TargetNoMachine
  deriving stock (Eq, Show)

renderTargetError   :: TargetPaths -> TargetError -> Text
targetLabel         :: ResolvedTarget -> Text
targetSshConfig     :: ResolvedTarget -> Maybe SshConfig
sshConfigFromMachine :: SshMachineSpec -> SshConfig          -- total
```

`MachineName` charset `[A-Za-z0-9_-]`, non-empty, no leading `.` or `-`, ≤ 64.
**`local` IS a valid `MachineName`** — it is pinnable, it is `ecDefault`, and
`TargetLocalNotAllowed` carries it. Only the *TOML keys* `[machines.local]` /
`[machines.default]` are reserved; that rejection belongs to WU-2's codec.

`SshMachineSpec` holds validated newtypes (`SmsHost :: SshHost`, `SmsUser :: SshUser`,
`SmsPort :: Int`, `SmsIdentity :: Maybe FilePath`, `SmsKnownHosts :: FilePath`,
`SmsWorkspace :: RemotePath`). Field prefix `sms`, matching `scHost`/`naProvider`.

`renderTargetError`'s four renderings are pinned **verbatim** in design §5; copy them
exactly — do not paraphrase.

### Edits to `Seal.Tools.Exec.Types`
- `deriving stock (Eq, Ord, Show)` on `SshHost` (`:124`), `SshUser` (`:139`),
  `SshConfig` (`:83-91`). `RemotePath` already has `Ord`.
- Leading-`-` rejection in `mkSshHost`/`mkSshUser`, mirroring `mkRemotePath:164` and
  `mkContainerTarget:112`. Reproduced defect: `ssh "-oProxyCommand=…@host"` parses as an
  option. **Behaviour change to existing installs:** a `security.toml` host starting
  with `-` previously loaded and now fail-closes. Correct and hardened; note it in the PR.

### Tests (failing first)
- `mkMachineName` accepts iff charset-valid; empty / leading `.` / leading `-` / 64 vs 65
  / control chars rejected; **`"local"` and `"default"` accepted**.
- `sshConfigFromMachine` is total and field-preserving.
- `mkSshHost`/`mkSshUser` reject leading `-`; existing fixtures (`exec.internal`,
  `192.168.0.104`, `agent`, `zoe`) still pass.
- `renderTargetError` is total; all four renderings match §5 exactly, with paths taken
  from `TargetPaths` (assert no `~/.seal/` literal appears in the output).
- `targetSshConfig WhereLocal == Nothing`; `targetLabel` is total.

### Done when
`make check` green. Cabal wiring present, so the module is actually typechecked.

---

## WU-1b — ssh argv builders: `-F /dev/null` + mux key

**Design:** §6.3, §6.4, §7 WU-1b.

### Files
- `src/Seal/Tools/Exec/Remote.hs` (`sshExecArgv`, `sshExecArgvForwarding`, `muxArgs`, the
  stale comment at `:154-156`)
- `src/Seal/Session/AgentMetaCache.hs` (rsync rsh string, `:186-196`)
- `src/Seal/SourceControl/Clone.hs` (`GIT_SSH_COMMAND`, `:481`)
- `test/Seal/Tools/Exec/RemoteSpec.hs` (five assertions)

### Deliverables
1. `-F /dev/null -o ProxyCommand=none -o ProxyJump=none` in **all four** builders. A
   `Host *` stanza in `~/.ssh/config` otherwise re-points `Hostname` and sets
   `ProxyCommand` — reproduced.
2. Fold a truncated hash of `identity` + `known_hosts` into `ControlPath`. `%C` already
   covers `%l%h%p%r%j` (user **is** hashed — verified); `identity`/`known_hosts` are the
   actual unhashed inputs, so two entries differing only in key share one master and the
   first connection's host key governs both.
3. Correct the stale comment: it claims `%C` excludes the user.

### Tests
**The two behavioural assertions, without which `make check` would stay green if the work
were never done:**

1. `-F /dev/null`, `-o ProxyCommand=none` and `-o ProxyJump=none` are present in **all
   four** builders (`sshExecArgv`, `sshExecArgvForwarding`, the rsync rsh string,
   `GIT_SSH_COMMAND`) — four separate assertions.
2. Two `SshConfig`s differing **only** in `identity` produce **different** `ControlPath`
   values; likewise differing only in `known_hosts`.

The five `RemoteSpec` assertions (`:236,241,242,247,252`). Two compare the path exactly
and **break**; three keep passing but become **vacuous** under a hashed path. Replace all
five. Verify the rsync/`GIT_SSH_COMMAND` insertions are invisible to
`AgentMetaCacheSpec` (`isInfixOfS`, `:166-172`) and `CloneSpec` (`T.isInfixOf`, `:543-546`).

### Done when
`make check` green. No behaviour change for a user who has no `~/.ssh/config`.

---

## WU-2 — `execution.toml`: codec, loader, writer, legacy synthesis

**Design:** §1.5, §3, §3.2, §5, §7 WU-2. This is the largest unit; read the whole of §3.

### Files
- `src/Seal/Config/Execution.hs` (new)
- `src/Seal/Config/Paths.hs` (`executionFilePath`)
- `src/Seal/Config/Security.hs` (`uefcMode :: Maybe Text`, `uefcAllowLocalhost`,
  `allowLocalhostFrom`, `:453`, `:767`)
- `config/templates/execution.toml` (new, comment-only worked example)
- `seal-harness.cabal` (`extra-source-files`)
- `test/Seal/Config/ExecutionSpec.hs` (new)
- `test/Seal/Config/SecuritySpec.hs`, `MigrateSpec.hs`, `WorkdirSpec.hs`,
  `test/Seal/TestHelpers/ApiTestHarness.hs` (the seven `uefcMode` ripples)
- `test/Main.hs`

### Deliverables

```haskell
data ExecutionConfig = ExecutionConfig
  { ecDefault  :: Maybe MachineName
  , ecMachines :: Map MachineName SshMachineSpec
  }

executionFilePath :: SealPaths -> FilePath       -- spConfig </> "execution.toml"

loadExecutionConfig
  :: Bool                                        -- ^ allow_localhost, from allowLocalhostFrom
  -> SealPaths -> IO (Either TargetError ExecutionConfig)

saveExecutionConfig   :: FilePath -> ExecutionConfig -> IO ()      -- .tmp + rename
updateExecutionConfig :: Bool -> SealPaths
                      -> (ExecutionConfig -> ExecutionConfig)
                      -> IO (Either TargetError ExecutionConfig)  -- under the lock
executionWriteLock    :: MVar ()                                    -- DEDICATED
```

The `Bool` parameter is load-bearing: `default = "local"` is a load error when
`allow_localhost = false` and legal when `true` (§3.2, §5 row 1a). Both loader and writer
read it from `allowLocalhostFrom` — never re-derive it.

Write mechanism is `saveRepoRegistry`'s (`SourceControl/Registry.hs:57-62`): `path.tmp` then
`rename`. **Not** `writeSecretFile` — that opens `trunc = True` and writes in place, so a
partial write leaves a truncated inventory and every turn then fails closed. Default file
mode, like `repos.toml`: it holds paths and hostnames, not secrets, and `0600` on a
git-committed file is a needless deviation.

`updateExecutionConfig` validates the **resulting** document: decode it back and check
the ≥ 2-machines-need-a-`default` rule before the rename. Without this the screen can
create the very state the route cannot repair.

**Legacy synthesis (§1.5):** a complete `[untrusted_execution.remote]` block becomes the
implicit machine `default` **only when `allow_localhost = false`** (equivalently
`mode ∈ {absent, "remote"}`). `mode = "local"` ⇒ `WhereLocal`, block ignored. An
**incomplete** block yields **no machine**, not a half-built one. `default` is reserved.

### Codec rules (each one a test)
- required: `name`, `host`, `user`, `known_hosts`, `workspace`; optional: `port` (22),
  `identity` (ssh-agent)
- **`identity` / `known_hosts` path rules (§3.2, §6.2):** absolute, no `..`, no
  `blockedNames` segment **except** `.ssh`/`.seal` (keys live there), and **no whitespace
  and no `=`**. Reproduced rationale: a POSIX-legal path containing a space smuggles a
  second `-o` directive into `UserKnownHostsFile=`, so this is an argv-injection guard, not
  tidiness. `SshMachineSpec`'s `SmsIdentity`/`SmsKnownHosts` are validated newtypes for
  exactly this reason — do **not** ship them as bare `FilePath`.
- each required field missing ⇒ `Left` whose payload **names the field** (WU-7a's 400 body
  is "the codec's field-specific `Left`", so the payload shape is load-bearing)
- `[machines.local]` / `[machines.default]` ⇒ `Left`
- invalid name as a key ⇒ `Left`
- `default` naming an absent machine ⇒ `Left` (dangling; §5 row 1b)
- `default = "local"` + `allow_localhost = false` ⇒ `Left`
- port `0` / `65536` ⇒ `Left`; duplicate `host:port:user` ⇒ `Left`
- unknown key ⇒ **warning**, not error (a typo'd `identiy` silently defaulting to
  ssh-agent is what this catches)
- `[untrusted_execution.remote]` with no `mode` **decodes** (required today, so this is a
  widening)

### Tests
Codec round-trip; every rule above; writer: **a rejected write leaves the file
byte-identical**, concurrent writes serialise (mirror `RegistrySpec.hs:126-143`), and
write→load→resolve round-trips (the codec test alone does not exercise the encoder the
writer uses); `uefcMode = Nothing` ⇒ `allow_localhost` derived correctly.

### Done when
`make check` green. The template file is comment-only, so a fresh install still behaves
exactly as before.

---

## WU-3 — `Seal.Execution.Resolve`

**Design:** §5 (read all seven rows), §6.5, §7 WU-3.

### Files
- `src/Seal/Execution/Resolve.hs` (new)
- `test/Seal/Execution/ResolveSpec.hs` (new)
- `seal-harness.cabal`, `test/Main.hs`

### Deliverables
```haskell
resolveTarget
  :: ExecutionConfig -> Bool -> Maybe MachineName
  -> Either TargetError ResolvedTarget

loadAndResolveTargetIO
  :: SealPaths -> Maybe UntrustedExecFileConfig -> Maybe MachineName
  -> IO (Either TargetError ResolvedTarget)
```

**Seven rows, first-match-wins**, copied from §5 exactly:

| # | Condition | Result |
|---|---|---|
| 0 | pin present and unresolvable (not in inventory, or `local` while `allow_localhost = false`) | `Left TargetUnknownMachine` / `Left TargetLocalNotAllowed` |
| 1 | pin names a machine (incl. `local` when `allow_localhost`) | `WhereSsh` / `WhereLocal` |
| 1a | effective `default` names `local` while `allow_localhost = false` | `Left TargetLocalNotAllowed` |
| 1b | effective `default` names a machine not in the inventory | `Left TargetConfigLoadError` |
| 2 | else effective `default` names an ssh machine | `WhereSsh` |
| 3 | else `allow_localhost = true` | `WhereLocal` |
| 4 | else | `Left TargetNoMachine` |

Effective-default rule: explicit `default` wins; absent + exactly one machine **and
`allow_localhost = false`** ⇒ that machine; absent + one machine + `allow_localhost =
true` ⇒ **`local` stays the default** (writing the first machine must move nobody);
absent + ≥ 2 ssh machines ⇒ config-load error. `local` does **not** count toward the
≥ 2 rule.

**No address classifier.** §4.1 deleted it deliberately; do not reintroduce one.

### Tests
- Table-driven over all seven rows.
- **Row 3 ≡ today's behaviour** for every `SecurityConfig`: property comparing
  `resolveTarget` against the existing `untrustedExecConfigFromSecurity` path.
- **No inventory or pin can produce `WhereLocal` unless `allow_localhost`** — the single
  sentence the design rests on, as a property.
- **Row 1a**: `default = "local"` + `allow_localhost = false` ⇒ `TargetLocalNotAllowed`.
- **Row 1b**: dangling `default` ⇒ `TargetConfigLoadError`, **not** `WhereLocal`.
- Transition tests: `mode=local` + a **complete** remote block ⇒ `WhereLocal`; first
  machine added with `allow_localhost = true` ⇒ pre-existing unpinned sessions **stay**
  `WhereLocal`.
- `TargetPaths` is built from `SealPaths` at the call site (no literals).

### Done when
`make check` green.

---

## WU-4 — the per-session pin

**Design:** §5, §6.1, §7 WU-4. **This is the largest diff in the feature — plan for it.**

### Files
- `src/Seal/Session/Meta.hs` (`smExecMachine`, explicit `ToJSON`/`FromJSON`,
  `defaultSessionMeta`, `setExecMachine`)
- the **77 construction sites across 25 files** (see below)
- `src/Seal/Agent/Runtime/Delegation/Worker.hs` (`writeChildMeta` `:404`,
  `writeHandoffMeta` `:518`)
- `src/Seal/Core/TurnEngine.hs` (`fallbackMeta` `:1340`)
- `src/Seal/Session/Store.hs` (`initSessionMeta`)
- `src/Seal/Gateway/API.hs` (branch handler `:1317-1327`)
- `src/Seal/Gateway/SessionJson.hs` (`execMachine` wire key)
- `test/Seal/Session/MetaSpec.hs`, plus every touched test file

### Deliverables

```haskell
-- SessionMeta gains:
smExecMachine :: Maybe MachineName

-- New in Seal.Session.Meta:
defaultSessionMeta :: SessionId -> UTCTime -> SessionMeta
setExecMachine     :: MachineName -> SessionMeta -> SessionMeta
```

**`ToJSON` must OMIT `exec_machine` when `Nothing`, not emit `null`.** `Meta.hs`'s house
style is `"repo_url" .= smRepoUrl m` (`Maybe → null`); copying it here would make every
post-deploy session carry a *present* key, and the falsification metric's "a present key
means a deliberate choice" would be false on exactly the population it measures.

`FromJSON` explicit, not derived. **Absent ⇒ `Nothing`** (normal, every legacy session).
**Malformed text ⇒ `Nothing` + a load-time warning** — `readSessionMeta :: IO (Maybe …)`
has no error channel and 30 call sites depend on it. A **valid** pin naming an absent
machine is **not** a decode concern: it is §5 row 0, fail-closed.

### The 77-site sweep — two mechanically different problems

```bash
python3 scripts/count-sessionmeta-sites.py
# construction sites: 77 in 25 files
#   record form  : 27   (break via -Wmissing-fields)
#   positional   : 50   (break via ARITY — -Wmissing-fields does NOT report these)
```

| Shape | Count | Fix |
|---|---|---|
| record literal `SessionMeta { … }` | 27 | `defaultSessionMeta sid now { … }` — one line each |
| positional `SessionMeta sid "ollama" …` (13 args) | 50 | **insert the missing argument in the right position** — no base value helps |

The positional sites are concentrated, and the full per-file breakdown is the script's
own output — run it and work down the list (it prints `N (R rec / P pos) path` per file):

```
29  ( 0 rec / 29 pos)  test/Seal/Gateway/ApiSpec.hs
10  ( 1 rec /  9 pos)  test/Seal/Gateway/SendSpec.hs
 5  ( 0 rec /  5 pos)  test/Seal/Command/ModelSpec.hs
 4  ( 4 rec /  0 pos)  test/Seal/Logging/LoggerSpec.hs
 3  ( 3 rec /  0 pos)  test/Seal/Session/BranchSpec.hs
 3  ( 3 rec /  0 pos)  test/Seal/Session/StoreSpec.hs
 ...18 more files, 23 sites
```

Do not treat "the long tail" as discoverable: run the script, and tick each file off. **Work file by file, not
find-and-replace.** `-Werror` will find every one, but the *order* of arguments is yours to
get right.

**Note on the verification command:** `count-sessionmeta-sites.py` classifies a site as
positional by "`SessionMeta` followed by ≥ 3 argument tokens", so a *rewritten* positional
application that still passes 14 arguments **still counts as positional**. The script
therefore cannot be the gate for "all rewritten"; it is a measurement of *shape*, not of
correctness. Use it to prove the total is unchanged (77 → 77) and the classification is
unchanged, and rely on `-Werror` for completeness. Do **not** put "0 positional" in the
DoD — it is unsatisfiable by the prescribed fix.

### Inheritance
Children copy the parent's **value**; a **dead** value fails closed (§5 row 0) — it does
**not** fall back to the default. Sites: `writeChildMeta`, `writeHandoffMeta`,
`fallbackMeta`, `initSessionMeta`, and the branch handler (`API.hs:1317-1327` — *not*
`branchSession`, whose haddock says it writes no `session.json`; the branch arm must
*load* the parent meta first, which it currently does not).

### No opcode may set it
Two tests: a grep asserting zero occurrences under `src/Seal/ISA/Ops/`, and
`SESSION_MANAGE action=new` with an extra `machine` key resolving to the effective
default.

### Tests
`toJSON` of `Nothing` contains **no** `exec_machine` key; `Just name` round-trips; absent
⇒ `Nothing`; malformed ⇒ `Nothing` + warning; a valid pin naming an absent machine ⇒
`TargetUnknownMachine`; all five inheritance sites copy the value; a dead pin fails closed
in the child and never yields `WhereLocal`; `execMachine` present on the wire.

### Done when
`make check` green. The PR body states 77 → 77: the sweep rewrites sites, it does not remove them.

---

## WU-5 — collapse the nine derivations; delete `execFingerprint`

**Design:** §2 (nine live sites), §7 WU-5. **This is the unit that pays for itself
regardless of whether the feature's premise is validated** — it fixes a real bug: editing
a machine's host changes nothing until restart, and a re-pinned session keeps serving its
old exec.

### Files
- `src/Seal/Session/ExecCache.hs` (key, `CachedExec`, `invalidateExec`, delete
  `execFingerprint`)
- `src/Seal/Session/Workdir.hs` (`mkSessionExec` `:182`, delete `mkSessionUntrustedIO`
  `:305-312`)
- `src/Seal/Core/TurnEngine.hs` (`:653`, `:669`, `:918`, `metaCacheEnvFor`, five
  `cachedSessionExec` sites)
- `src/Seal/Gateway/API.hs` (`:1212`, `:1652`, `:1710`)
- `src/Seal/Channel/Cli.hs` (`:158`)
- `src/Seal/Command/Serve.hs` (`:538`, `:677`)
- `src/Seal/Tools/Exec/Untrusted.hs` (delete `selectExecBackend`,
  `selectUntrustedBackend`, `enforceRemoteOnly`)
- `test/Seal/TestHelpers/ApiTestHarness.hs` (32 `UntrustedExecMode` references)
- `test/Seal/Session/ExecCacheSpec.hs`, `WorkdirSpec.hs`, `UntrustedSpec.hs`,
  `Phase4Spec.hs`

### Deliverables
`mkSessionExec`/`cachedSessionExec` take `ResolvedTarget`; memo key
`(SessionId, ResolvedTarget)`; `execFingerprint` **deleted**; `invalidateExec` drops all
targets for the sid.

**Boot sites have no session** and resolve **unpinned**:
- `Cli.hs:158`, `Serve.hs:538` (`isRemote` Bool): log the rendered `TargetError` at warn,
  set `False` — row 4 means nothing executes, so nothing is reachable to be remote.
- `Serve.hs:677` (file explorer): `Left` ⇒ `mkFailClosedFileExplorer`, matching the
  existing "remote without SSH ⇒ fail-closed" posture.

Per-session remote-ness moves **into the turn** (`TurnEngine.hs:918`, `metaCacheEnvFor`)
keyed off the session's pin — otherwise a `builder` session under `allow_localhost =
true` gets `cdIsRemote = False` and the wrong clone path.

**Delete** `mkSessionUntrustedIO` and its equivalence test (`WorkdirSpec.hs:267-276`),
`selectExecBackend`, `selectUntrustedBackend`, `enforceRemoteOnly` (+2 tests). These
branch on `UntrustedExecMode` and will not compile; they are a second parallel
authority-decider and half-migrating them is how two decision paths appear.

**`ApiTestHarness` re-typing is the hidden cost.** `buildTestEnv :: FilePath ->
UntrustedExecMode -> …` (`:413`) is the harness's spine, used at `:365`/`:378`, read at
`:496`/`:498`/`:511`/`:542`. It must become `ResolvedTarget` + `execution.toml` fixtures.
Until it does, `mode` cannot be deleted.

### Tests
- **Two sessions on two machines in one cache get distinct execs** — the headline
  feature, and the only test that proves the key change works.
- A target change rebuilds; an unchanged target reuses; `invalidateExec` clears all
  targets for the sid.
- Post-WU-5 harness equivalence: the remote fixture still yields `sdIsRemote = True` and
  the same argv.
- Additivity, second form: a legacy `[untrusted_execution.remote]` block and the
  equivalent `execution.toml` entry produce the **same** argv *in the same tree*.
- Pre-WU-1b additivity (should already pass): a local install with no `execution.toml`
  yields **no ssh argv at all**.

### Done when
`make check` green. `UntrustedExecMode` is gone from `Untrusted.hs` and the harness;
`uefcMode` **remains** as `Maybe Text` for read-compat (WU-2), so `mode` is gone from the
type layer but not from the file format — the deletion summary in §3 says exactly this.

---

## WU-6 — `--machine` in both parsers ← **DEMO CHECKPOINT**

**Design:** §7 WU-6.

### Files
- `src-gateway-types/Seal/Gateway/Types/NewArgs.hs` (`naMachine :: Maybe Text`)
- `src/Seal/Command/New.hs` (validation, `NewDeps` field, `ccSend` failure)
- `src/Seal/Command/Spec.hs` (if the flag is declared there)
- **`src/Seal/Tui.hs:187-201`** and **`src/Seal/Command/Serve.hs:553-566`** — `NewDeps` is a
  record constructed field-by-field at both, and `-Wmissing-fields` is in `-Wall` with
  `-Werror`, so a new field breaks both. `test/Seal/Command/NewSpec.hs:65,88-98` too.
  `Tui.hs` appears in no other unit's file list.
- `src/Seal/Gateway/API.hs` (`handleTabNew` provider arm, `handleSessionNew`)
- `frontend/src/hooks/useApi.ts` (`CreateTabBody.machine`, `createTab` → `NewTabResult`)
- `frontend/src/components/NewTabComposer.tsx` (`if (!res || !res.ok)`)
- `src-gateway-types/Seal/Gateway/Types/NewArgs.hs` (`renderNewSessionConfirmation`, `:75`)
- tests on both sides

### Deliverables
- `naMachine :: Maybe Text` — **not** `MachineName`: `seal-gateway-types` cannot depend
  on the main library. Validate in `Seal.Command.New`.
- `/new --machine builder` writes it. Validation happens **before** the session is
  minted, via a new `NewDeps` field supplying the inventory.
- `parseNewArgs` **silently ignores unknown flags** (`:63`) and drops a value-less
  `--machine` (`:57`). Fix: value-less `--machine` is an error; failure is reported
  inline via `ccSend` with the available set (matching the `/new -r` failure path).
- `CreateTabBody` gains `machine?: string` — flat, matching `branch_from`/`harness_id`.
- **`createTab` discards the response body on `!res.ok`** (`:1046`), so a 400 is invisible.
  It must return `NewTabResult | null` (`{ok:false, error}`) like `setupRepo` (`:1279`).
- **`NewTabComposer.tsx:81`'s `if (res)` treats `{ok:false}` as success** and would still
  call `onSubmit` + `persistOnSubmit`. It becomes `if (!res || !res.ok)`.
- `buildBody` **omits** `machine` whenever the picker is not rendered **and** whenever
  `branch_from` is set — one rule, not two.
- `renderNewSessionConfirmation` gains the machine name.

### Tests
`--machine` parses; value-less ⇒ error not silent; unknown machine ⇒ 400 whose body
carries the available set; **no `session.json` minted on refusal**; the web path sends an
identical body when the picker is hidden; **`createTab` returns `{ok:false,error}` on a 400
and the composer does not call `onSubmit`/`persistOnSubmit`**.

### Demo (this is the first moment the premise is testable)
With a fixture `execution.toml` containing `builder`, run `/new --machine builder`, show:
1. the `session.json` diff with `"exec_machine": "builder"`;
2. the composed ssh argv from the recording fake containing `builder.example.com`;
3. that **no flag** produces `cdIsRemote = False` / no ssh argv, i.e. legacy is untouched.

### Done when
`make check` green; the demo recorded; and with no flag, `cdIsRemote = False` (legacy
untouched).

---

## WU-6b — the chat and Telegram mint paths

**Design:** §7 WU-6b.

### Files
- `src-chat-channels/Seal/Channels/Chat/HttpClient.hs` (`mintBody`, `rebindBody`, `:223-238`)
- `src-chat-channels/Seal/Channels/Chat/Loop.hs` (`:1744`, `:1765`)
- `src/Seal/Gateway/API.hs` (`handleSessionNew` `:1443`, `handleSessionRebindNew` `:1494`)
- `frontend/src/hooks/useApi.ts` (`createBareSession` decision)
- tests: `HttpClientSpec`, `LoopSpec`

### Deliverables
`/new --machine builder` from Telegram or Signal currently parses the flag and discards
it. Required: `mintBody`/`rebindBody` gain `Maybe Text`; both handlers accept and validate
pre-mint; each returns a `400` carrying the available set, relayed via `ccSend`; and
`createBareSession` ("Recent Sessions +") is **deliberately machine-less** — say so.

**Not in this unit:** `createTab`'s error return and the composer's `if (res)` inversion —
those are WU-6's and are not counted here.

### Tests
`--machine` from a chat channel reaches `handleSessionNew` and lands on the chosen
machine; an unknown machine relays the available set via `ccSend`; a value-less
`--machine` errors rather than defaulting.

### If the PR slips
Cut this unit first. Have the chat parser **reject** `--machine` with "not supported in
chat" (2 lines) rather than silently dropping it — that is strictly better than today,
and `--machine` only becomes reachable when WU-6 lands.

### Done when
`make check` green; `/new --machine builder` from a chat channel lands on the chosen
machine, asserted at the handler and not only at the parser.

---

## WU-7a — the machine write API (the security control)

**Design:** §4.2, §4.3, §4.6, §7 WU-7a. **This is the control the whole trust model rests
on.**

### Files
- `src-gateway-types/Seal/Gateway/Types/Route.hs` (two `SealRoute` constructors,
  `allRoutes`, `routeMeta`)
- `src/Seal/Gateway/OpenApi.hs` (`openApiMeta`)
- `src/Seal/Gateway/AccessControl.hs` (`decide` — the method+path predicate)
- `src/Seal/Gateway/API.hs` (two handlers, `broadcastMachinesChanged` calls)
- `src/Seal/Gateway/StreamBroker.hs` (`BeMachinesChanged` constructor)
- **`src/Seal/Gateway/Stream.hs`** — `sendEvent` at `:191-231` is a **closed, exhaustive
  case over every `BrokerEvent` constructor with no catch-all**. Adding
  `BeMachinesChanged` makes it fail `-Wincomplete-patterns` under `-Werror`. A new
  `sendEvent BeMachinesChanged = sendTextData conn (A.encode …)` arm is required, and
  **no earlier revision of this plan listed the file** — the exact defect ground rule 5
  exists to catch.
- **`src/Seal/Gateway/Audit.hs`** and **`test/Seal/Gateway/AuditSpec.hs`** — see the audit
  deliverable below. `AuditEvent` is a closed enum (`:64-72`) and `auditEventText` an
  exhaustive `case` (`:75-84`) with no catch-all, so new constructors break both under
  `-Werror`; and `AuditFields` (`:88-95`) has **no pin-count field**.
- `test/Seal/Gateway/ApiRouteSpec.hs` (`expectedRouteCount` **81 → 83**)
- `test/Seal/Gateway/AccessControlSpec.hs`, `ApiSpec.hs`

### Deliverables

`POST /api/machines` (upsert: `201` create / `200` replace) and
`DELETE /api/machines/:name`. Six constraints:

1. **Refuse unless `acsMode == AccessPasskey`**, enforced in `AccessControl.decide` as
   **`isMachinesMutation req = pathInfo req == ["api","machines"] ∧ requestMethod req ∈
   {methodPost, methodDelete}`** → `403` unless `AccessPasskey`. `requestMethod` is
   already in scope (`:304`). **The method guard is required**: a bare path match would
   403 `GET /api/machines` on every `access_mode = "none"` install, which is a documented
   supported choice. `accessControlMiddleware` alone is not enough — `AccessOpen`
   short-circuits to allow for every path (`:305`).
2. **Write via WU-2's `updateExecutionConfig`** — `.tmp` + rename under
   `executionWriteLock`. Not `writeSecretFile`. Default file mode.
3. **Body** `{name, host, user, port?, identity?, known_hosts, workspace, default?}`
   validated by WU-2's codec, returning the codec's field-specific `Left` payload. A
   rejected write leaves the file **byte-identical**. `default` is required for the second
   machine (the writer validates the resulting document); `kind` is never sent — every
   POSTed machine is ssh.
4. **Replace is guarded exactly like DELETE.** If the name exists and
   `host`/`port`/`user`/`identity`/`known_hosts`/`workspace` differs, refuse without
   `?force` and report the pin count. This is the `PUT` that does not exist, so it must
   not be smuggled in as an upsert.
5. **Warn — do not refuse — on a loopback host.** Return `warning: string|null` naming
   the *consequence* (§4.5's wording), not merely "this is localhost".
6. **`stat` `identity`/`known_hosts` at write time**; a nonexistent path is a
   field-specific `Left`. This is the cheap substitute for a test-connection endpoint.

**Write responses:** `201`/`200` → `{warning: string|null}` (the saved `MachineInfo` is
not echoed; the screen refetches); `400` → `{error: <rendered codec Left>}`; `409` →
`{error, pinned: Int, unpinned: Int, fallback: string|null}` where `fallback` is the
machine unpinned sessions land on, `null` meaning `TargetNoMachine`; `204` on successful
DELETE; `400` on `DELETE /api/machines/local` (no row exists); `403` unless `AccessPasskey`.

**Route work:** `SealRoute` constructor, **`allRoutes` entry (a plain list — `-Werror`
will not catch an omission)**, `routeMeta`, `openApiMeta` (both exhaustive `\case`),
`expectedRouteCount` 81 → 83. DELETE's capture is `Text` in `seal-gateway-types`, validated
in the handler.

**Audit every mutation.** The design (§4.6) requires an audit-level log carrying the pin
count on `DELETE` and on a `?force` `POST` replace. This is **four** edits, not a function
call:

1. `AuditEvent` gains `MachineAdded` / `MachineRemoved` / `MachineReplaced` — it is a closed
   enum whose doc says "Nothing else may be logged", so the vocabulary change is the point.
2. `auditEventText` is an exhaustive `case`; add three arms.
3. `AuditFields` gains a machine/pin-count field — it currently carries only `afEvent`,
   `afCredentialId`, `afLabel`, `afRpId`, `afOrigin`, `afVia`, `afRemainingSeconds`.
4. `AuditSpec` gains cases for all three events, including a forced removal reporting a
   non-zero count.

A refusal that reports a count is auditable; a silent one is not.

**`broadcastMachinesChanged` after each successful POST and DELETE** — WU-7b adds the
frame, but the emitter calls are here. Otherwise a test injects the frame and passes while
the real route never broadcasts.

### Tests
- **`403` when `acsMode /= AccessPasskey`** — the `AccessOpen` fixture is the regression
  test.
- **A rejected write leaves the file byte-identical.**
- Concurrent writes serialise (mirror `RegistrySpec.hs:126-143`).
- `DELETE` of the effective default refused; `DELETE` of a pinned machine returns the pin
  count and requires `?force`; **`POST` replacing a pinned machine's `host` refuses
  without `?force`**; `POST` validates the resulting document (second machine without
  `default` refused); the loopback `warning` is present; a nonexistent key path ⇒
  field-specific `Left`; `DELETE /local` ⇒ `400`.
- **Opcode ban:** zero `executionFilePath` under `src/Seal/ISA/`; `Seal.ISA.Registry`'s
  import closure excludes `updateExecutionConfig`; no `MACHINE_*` opcode.

### Done when
`make check` green. This unit is the security control — if it is the only thing that
lands, the feature still has a defensible posture.

---

## WU-7b — `GET /api/machines` + the dropdown

**Design:** §4.6, §7 WU-7b.

### Files
- `src/Seal/Gateway/API.hs` (`handleMachinesList`)
- `src-gateway-types/…/Route.hs`, `OpenApi.hs` (third route)
- `test/Seal/Gateway/ApiRouteSpec.hs` (`83 → 84`), `ApiSpec.hs`
- `frontend/src/hooks/useApi.ts` (`useMachines`, `machines-changed`)
- `frontend/src/lib/streamClient.ts` (the frame)
- `frontend/src/hooks/useNewTabSpec.ts` (`buildBody` omission rule, sentinel)
- `frontend/src/components/NewTabComposer.tsx` (the `<select>`)

### Deliverables
`200 {default: string|null, machines: [MachineInfo], resolvable: boolean, error:
string|null}`. **Degraded shapes are 200, never 500.**

```ts
interface MachineInfo {
  name: string
  kind: 'local' | 'ssh'
  default: boolean
  host?: string; user?: string; port?: number
  identity?: string; known_hosts?: string; workspace?: string
}
```
The six ssh-only fields are **omitted** when `kind === 'local'` — pin both goldens.

- **`local` is always listed when `allow_localhost = true`**, so no file ⇒
  `{default:"local", machines:[{name:"local",kind:"local",default:true}], resolvable:true,
  error:null}`. `machines: []` occurs only under `allow_localhost = false`.
- **`resolvable`** disables Start. With `allow_localhost = false` and no inventory the
  form previously minted sessions whose every turn failed closed.
- **Malformed file + `allow_localhost = true`** ⇒ `resolvable: true` **but `error`
  non-null and persistent** — surfaced by WU-7c, not a transient composer message.
- The `<select>` renders only when `machines.length ≥ 2` **and** `kind === 'provider'`;
  read-only in branch mode. **Do not persist it in `LastOptions`** (`UiState.hs:57`).
- **Leading sentinel option** `Default (<effective default>)` whose value is **omitted
  from the body**. Without it, the select renders preselected and every web session
  records a pin, making the metric false on its own population.
- **`machines-changed`**: add the frame + `useMachines` refetch on it. The emitters are
  WU-7a's.
- **Hint at `machines.length == 1`** — the same predicate and the same string as WU-7c.
  An ssh-count predicate would fire while the picker was already rendered, because `local`
  counts toward `≥ 2`.

### Tests
Golden JSON both ways; absent file + `true`; absent + `false`; malformed + `true` ⇒
`resolvable:true` with non-null `error`; sentinel ⇒ untouched picker omits `machine`;
`machines-changed` triggers a refetch without a reload; route count 84. Plus the two that
distinguish implemented from unimplemented:

- **`resolvable: false` ⇒ Start is disabled and `error` is rendered** (a component test).
- **the `≥ 2` render rule**: the `<select>` is absent at 0 and 1 machines, present at 2;
  and it is absent for `kind !== 'provider'` and read-only in branch mode.

### Done when
`make check` green (including frontend-test); a machine added through WU-7a appears in
the picker without a reload; `resolvable:false` disables Start.

---

## WU-7c — the Machines screen

**Design:** §7 WU-7c. **Without this the write API has no user.**

### Files
- `frontend/src/components/MachinesView.tsx` (new, cloning `ReposView.tsx`)
- `frontend/src/components/TopBar.tsx` (`TopSection` union + `SECTION_LABELS`)
- `frontend/src/App.tsx` (`sectionFromPath` + **the render branch**, `:1077`)
- `frontend/src/hooks/useApi.ts` (write calls)
- `frontend/src/components/__tests__/MachinesView.test.tsx` (new)

### Deliverables
- `Machines` member in `TopSection` (`SECTION_LABELS` is `Record<TopSection,string>`, so TS
  forces it), `sectionFromPath`, **and the `App.tsx` render branch whose `else` is the
  Sessions view** — a missing case renders Sessions silently with no compile error.
- List rows: name / host / user / default. Add-or-edit form, one `data-testid` per field,
  required fields marked (`name`, `host`, `user`, `known_hosts`, `workspace`; `port`
  defaults 22, `identity` defaults ssh-agent). **A "set as default" control**
  (`data-testid="machines-set-default"`) — without it the second machine cannot be added.
- **The `?force` flow, one flow for both destructive paths**: attempt → `409` → surface
  `pinned` / `unpinned` / `fallback` in `data-testid="machines-force-confirm"` → "Do it
  anyway" retries with `?force`. Both delete and host-changing edit.
- `fallback: null` renders "unpinned sessions will have no machine to run on".
- **`kind === 'local'` rows: no edit, no delete, no default control**, displayed as
  "This machine (where Seal runs)" — the same string as the select option.
- **`data-testid="machines-form-error"`** renders the codec's `Left` payload (the same
  slot the `?force` confirm uses for its message), and **per-field `data-testid`s** for
  each of the seven form fields. Both are asserted.
- **Delete is confirmed**: the delete control opens a confirmation showing the machine
  name and, when the 409 carries counts, `pinned`/`unpinned`/`fallback` — the count exists
  only in the 409, so the confirm is *step two* of the `?force` flow, never a pre-read.
- **Four copy surfaces, each with a testid and a test**: `machines-error-banner`
  (persistent malformed-file error), `machines-empty-why` (says *why* it is empty),
  `machines-one-machine-hint` (`machines.length == 1`), `machines-loopback-warning`
  (`POST`'s `warning`, transient at save — `GET` carries no warning field and must not).
- **Reachable in every state**, including `resolvable: false`.
- Read-only `allow_localhost` posture with a "set in `security.toml`" note — **no
  directory** (respects `SEAL_HOME`).
- The composer's `resolvable: false` error links to `/machines`.
- `MachinesView` consumes `useMachines`, so the post-write refetch reaches it.

**No test-connection affordance in v1** — stated as a known limitation. `POST`'s `stat`
check (WU-7a constraint 6) catches the most likely mistake.

### Tests
Renders at `/machines` (and the `App.tsx` branch is present, not the Sessions fallback);
**end-to-end ramp on a default install**: no `execution.toml` → add one machine → the
picker renders two options → a session mints on it; add ⇒ row appears; edit ⇒ form
pre-fills; the `?force` flow for both paths; set-as-default lets the second machine be
added; `local` row has no controls; the four copy surfaces; the composer's error link.

### Done when
`make check` green; a frontend dev can build the screen from this spec without asking a
question; the end-to-end ramp test passes on a default install.

---

## WU-8 — session-viewer surface

**Design:** §7 WU-8.

### Files
- `src/Seal/Gateway/API.hs` (`handleSessionWorkdir`)
- `frontend/src/components/ChatArea.tsx` (`OpenWorkdirLink`, `:358`)
- `frontend/src/hooks/useApi.ts` (the client type)
- tests both sides

### Deliverables
`GET /api/sessions/:id/workdir` → `{path, machine, files_machine}`. Value domain for both:
`"local" | <machine name> | null`, `null` **only** when the explorer is `FeDisabled`.

**The link is inert when `files_machine` is `null` OR differs from `machine`.** `null`
means the explorer is disabled, which is the *normal* state on a non-loopback bind — under
the mismatch rule alone, `null == null` leaves a live link returning `403 file explorer
disabled`. The existing `aria-disabled`/no-`href` path supports inertness.

A badge names both machines when they differ. This is the accepted v1 cost of a global
explorer, and it is sharpest for UC-1's compile session — say so in the PR.

### Tests
Response carries both machines; they differ ⇒ badge shown **and** link inert;
`files_machine == null` ⇒ link inert and no badge.

### Done when
`make check` green; a `builder` session's Files link is inert rather than opening a
nonexistent local path, and the `null` (`FeDisabled`) case is equally inert.

---

## WU-9 — the `-f remote-only-untrusted` coercion

**Design:** §1.4, §7 WU-9.

### Files
- `src/Seal/Config/Security.hs` (`allowLocalhostFrom` CPP branch)
- `test/Seal/Config/SecuritySpec.hs` (CPP-guarded spec — **no** second cabal test-suite)
- `seal-harness.cabal` — only if the guard needs a flag to be visible to the spec

### Deliverables
Under `-DREMOTE_ONLY_UNTRUSTED`, `allowLocalhostFrom` returns `False` **unconditionally**,
**including when `security.toml` is absent** — the case earlier revisions missed.
`mkLocalUntrustedIO` has no CPP guard (`UntrustedIO.hs:79` imports `Local`
unconditionally), so this value *is* the runtime guarantee.

It must **override the function**, not re-derive the default in a second place — a second
authority-decider is exactly the shape WU-5 just deleted.

### The variant cannot be built — read this before planning the test

**Measured, not inferred.** Under `-f remote-only-untrusted` the flag removes
`Seal.Tools.Exec.Local` from `exposed-modules` (`seal-harness.cabal:338-341`), while
`test/Seal/Tools/Exec/LocalSpec.hs:16` unconditionally imports it and
`Seal.Tools.Exec.LocalSpec` is listed unconditionally in the single `tests` stanza
(`:647`). `cabal build test:tests -f remote-only-untrusted` fails with `Could not find
module 'Seal.Tools.Exec.Local'` — this repo's own planning history records it twice.

**The obvious fallback also fails.** `test-suite tests` declares no `cpp-options` (it
inherits only `settings`), so a `#if defined(REMOTE_ONLY_UNTRUSTED)` inside the spec never
fires in a normal build; and adding `cpp-options` to that stanza reproduces the `LocalSpec`
failure.

**So the honest scope is: the hardened build cannot be tested in this PR.** Do this
instead, and say so in the PR body:

- Verify the *function*: a spec that makes the macro visible to itself (a local
  `#define` under `{-# LANGUAGE CPP #-}`) asserts `allowLocalhostFrom Nothing == False`
  under the flag and that an explicit `allow_localhost = true` in the file is overridden.
- Do **not** claim anywhere that "the hardened build is tested" or that "the artifact is
  verified". Issue #347 owns the artifact property, and its current state is that the flag
  does not keep `Local` out of the binary either.
- If you want the real thing, it is a separate PR: exclude `LocalSpec` from
  `other-modules` under the flag, add the second variant, and take it to #347.

### Done when
`make check` green; the accessor's function-level test passes under the macro; and the PR
body states plainly that the hardened *artifact* is #347's, not this PR's.

---


## WU-11 — docs: the two templates and the CHANGELOG

**Design:** §1, §1.5, §7 (the design does not give this a unit number; the plan does,
because a setting nobody documents is a setting nobody uses).

### Files
- `config/templates/security.toml`
- `config/templates/execution.toml` (created in WU-2 — this unit fills in the worked
  example and the comments)
- **`src/Seal/Config/Templates.hs`** — seeding is a `file-embed` splice with
  `qAddDependentFile` (`:62-69`) plus a `seedFile` call in `ensureConfigTemplates`
  (`:79-88`). A third seeded template is a third splice and a third `seedFile`, **not** a
  comment edit. Copy the `configTomlTemplate`/`securityTomlTemplate` pattern.
- **`seal-harness.cabal`** — `extra-source-files` (`:2-6`) lists only
  `config/templates/config.toml` and `config/templates/security.toml`.
- **`test/Seal/Config/TemplatesSpec.hs:237`** — asserts
  `created \`shouldBe\` [configFilePath paths, securityFilePath paths]`; it becomes a
  three-element list.
- `CHANGELOG.md`

### Deliverables
`config/templates/security.toml:44-52` currently instructs the user to set
`mode = "local" | "remote"` and explains *"an absent table is what tells it so; writing
mode = 'local' there would change its behaviour"*. **WU-9 makes that rationale false** (the
coercion now overrides the accessor including when the file is absent), and `mode` is
deprecated. Rewrite that block to document `allow_localhost` as the one setting:

```toml
# Whether untrusted tool calls may run on this machine.
#   true  (default) — as before: a session with no machine runs here.
#   false           — nothing may run here; a session must name a machine.
# Set this to false BEFORE the first agent session on a hardened install, and
# review ~/.seal/config/execution.toml at the same time for entries you did not add.
#
# [untrusted_execution]
# allow_localhost = false
```

Keep the `[untrusted_execution.remote]` sub-table block (it still works, by presence — see
WU-2's legacy synthesis), and mark `mode` as **deprecated, still accepted**.

`CHANGELOG.md` gains one entry under the unreleased section naming: the new
`execution.toml`, the `allow_localhost` setting with its default, the two deliberate
behaviour changes (a leading-`-` host now fail-closes; `[untrusted_execution.remote]`
without `mode` now decodes), and the bug fix in WU-5 (`execFingerprint` made a host edit
invisible until restart).

### Tests
`test/Seal/Config/TemplatesSpec.hs` asserts both templates are seeded and that the
`security.toml` template contains `allow_localhost` and no longer presents `mode` as the
way to choose. (The existing template tests already pin the seeded bytes; extend them.)

### Done when
`make check` green. A reader who has never seen the design can set up two machines from
the templates alone.

---

## 3. PR structure

One PR, one branch, fourteen commits (or fewer where units merge naturally). Draft
immediately; `gh pr ready` only when `make check` is green and the §8 test table is
complete.

**PR body must contain:**
1. `Closes #<NN>`.
2. The **deletion summary** — this feature deletes `UntrustedExecMode`, `resolveByMode`,
   `localModeResult`, `execFingerprint`, `mkSessionUntrustedIO`, `selectExecBackend`,
   `selectUntrustedBackend`, `enforceRemoteOnly`, the dead `untrustedIOFromSecurity`, and
   the nine scattered derivations. **`uefcMode` is NOT deleted**: it becomes `Maybe Text`
   and keeps decoding, so an existing `security.toml` still loads. Reviewers need to see
   the list as a net simplification *and* see that the read-compat surface is deliberate —
   an earlier draft of this plan listed `uefcMode` among the deletions while WU-2 kept it,
   which is exactly the kind of contradiction that turns a revert into an outage.
3. The **77-site sweep** count before and after (77, 27 record / 50 positional).
4. The **two behaviour changes** to existing installs, both hardenings:
   a `security.toml` host beginning with `-` now fail-closes; and
   `[untrusted_execution.remote]` without `mode` now decodes instead of being a load error.
5. The **demo**: `/new --machine builder`, the `session.json` diff, the composed argv.
6. The **accepted costs**: the file explorer is a boot-time global (a `builder` session's
   Files link is inert); no test-connection affordance; `allow_localhost` defaults `true`.

**Rollback.** Every change is additive or read-compatible, so `git revert` of the merge
leaves the tree working: `session.json` files with an unknown `exec_machine` key decode
fine under the old `FromJSON` (aeson ignores unknown keys), `execution.toml` becomes an
unread file, and `security.toml`'s `mode` was never removed. The one thing a revert does
**not** undo is a machine the operator added through the UI — that is a config file, and
it stays. Nothing here rewrites a file in place.

**If the PR slips, cut in this order** (each leaves `make check` green):
1. **WU-6b** — reject `--machine` in chat with a message instead of silently dropping it.
2. **WU-9** — a hardened build then keeps `allow_localhost = true` by default; do not ship
   without it if any hardened build exists.

Do **not** cut WU-5 (it fixes a live bug), WU-1/1b (endpoint integrity), WU-2/3/4 (the
substrate), or WU-7a (the security control).

## 4. Risks and how each is caught

| Risk | Caught by |
|---|---|
| The 50 positional sites break in the wrong argument order | per-file review; `-Werror` finds them but not the order |
| `ToJSON` emits `null`, silently falsifying the metric | the explicit omit test in WU-4 |
| The write route is reachable without a passkey | the `AccessOpen` fixture test in WU-7a |
| A rejected write corrupts the inventory | the byte-identical test in WU-2 |
| The picker renders but never invalidates | the `machines-changed` refetch test in WU-7b |
| A `builder` session's Files link opens a local path | the inert-link test in WU-8 |
| A removed machine strands a pinned session, and **branching it reproduces the dead end** | the dead-pin-fails-closed test in WU-4; the remedy is a *fresh* session, not a branch or handoff — state it in the PR body |
| `allow_localhost` re-derived in a second place | WU-9's override test; `allowLocalhostFrom` is the only producer |
| Legacy behaviour changes unnoticed | the two additivity tests, one of which must pass **before** any change |
| Count drift between design and plan | `scripts/check-spec-counts.py` |

## 5. Definition of done

- [ ] All fourteen units committed; `make check` green at every commit.
- [ ] The design's §8 test table is complete — every row has a passing test, including
      the opcode-ban greps and the encoder-omit assertion.
- [ ] The pre-WU-1b additivity test (a local install yields no ssh argv) passed **on the
      unmodified tree** before any change.
- [ ] `python3 scripts/check-spec-counts.py <design>` prints `all checks passed`.
- [ ] `python3 scripts/count-sessionmeta-sites.py` still shows **77 sites** (the sweep is a rewrite, not a reduction), and `make check` is green.
- [ ] `hlint src/ test/` reports "No hints".
- [ ] The demo is recorded in the PR body.
- [ ] The two behaviour changes are called out and justified, in the PR body *and* the
      CHANGELOG.
- [ ] `config/templates/security.toml` documents `allow_localhost` and marks `mode`
      deprecated; `config/templates/execution.toml` is a usable worked example.
- [ ] Two weeks after merge, someone runs the criterion-1 grep — `channel == "web"`,
      `smCreatedAt` after this deploy, `ecDefault` recorded — and either the split shows
      both machines in use, or the picker surfaces come out.
