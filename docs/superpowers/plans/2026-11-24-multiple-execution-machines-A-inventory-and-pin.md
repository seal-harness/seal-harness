# Milestone A — machine inventory and per-session pin

<!-- branch: exec/multiple-machines -->
<!-- design: docs/superpowers/specs/2026-11-23-multiple-execution-machines-design.md (rev 3c) -->
<!-- handoff: docs/handoffs/2026-11-23-multiple-execution-machines-handoff.md -->
<!-- supersedes: docs/superpowers/plans/2026-11-24-multiple-execution-machines-plan.md (one 1620-line plan, split for reviewability) -->
<!-- status: draft — awaiting plan review gate -->
<!-- milestone: A of 2 -->

## 0. What this milestone is

Milestone **A** builds the machine inventory and lets a session pick a machine — and
stops. It **deletes nothing**, `untrusted_execution.mode` keeps working, and it adds no new
authority.

**One behaviour change is deliberate and must be stated, not buried** (§5): WU-1c adds
`-F /dev/null -o ProxyCommand=none -o ProxyJump=none` to **every** remote ssh argv. If an
existing `mode = "remote"` deployment relied on a `~/.ssh/config` `Host` alias,
`ProxyJump`, or `ProxyCommand`, that deployment **changes behaviour or breaks**. The change
is design-mandated (D6: without it, `validateTarget` validates a string `ssh` does not
honour) and it *hardens* rather than loosens, but it is a visible change for remote users
and must appear in the release note. An earlier draft called the milestone "purely
additive … no change at all", which was false for exactly this reason.

It ends where the design says the feature becomes testable: **WU-4 ships a session pinned
to a machine, and the composed ssh argv really changes.** That is Checkpoint A, the
design's two-week falsification clock.

**Milestone B is contingent on A's answer.** If nobody pins a non-default machine, B is
re-scoped (drop the picker, WU-8) or abandoned — and, critically, **no destructive change
has happened yet**, so abandoning is free. That is the whole reason the seam sits here
rather than at an arbitrary halfway point.

| | Milestone A | Milestone B |
|---|---|---|
| Units | WU-1a, 1b, 1c, 2, 3, 4 | WU-2b, 5, 6, 7, 8, 2c, 9 |
| Nature | **additive** | **destructive** |
| Deletes production code | no | yes — `mode`, `UntrustedExecMode`, `resolveRemoteSsh`, `mkLocalUIO`, `mkSessionUntrustedExec` |
| Ships a user-visible feature | `--machine` + a persisted pin | picker UI, re-pin, gateway API, docs |
| Ends at | **Checkpoint A** (falsification) | Checkpoint C (PR) |
| Reversible | by discarding the branch — **except WU-1c's argv change, which ships the moment it merges** | not cheaply |

### 0.1 Why the split is here (and not anywhere else)

The design's own risk analysis supplies the seam. Three facts converge on it:

1. **D9's falsification point is WU-4.** The design and the handoff both say the premise
   is untestable before it and that the picker is droppable if unproven. Splitting after
   WU-4 puts the decision point at the end of a milestone, where a decision belongs.
2. **Every destructive change is after WU-4 already.** `mode`'s deletion (WU-2b) already
   had to come after WU-4 — the plan ordered it that way so WU-4 could be demoable. So
   the seam is not imposed on the design; it exposes the seam the design already had.
3. **A is independently valuable and cheap to abandon.** An operator can define machines
   and pin sessions; unpinned sessions resolve exactly as today; nothing is deleted. The
   one exception is WU-1c's ssh-argv hardening, which is a deliberate, design-mandated
   behaviour change for existing remote users (§0). Abandoning A is still cheap — discard
   the branch — but it is not "zero risk", and the earlier wording said so wrongly.

## 1. What carries over from the full plan (unapproved material — see §1.1)

Everything in this milestone is **verbatim** from the full plan except: the
unit order is now explicit, §0.1's gate-status section is replaced by the note below, and
cross-references to B's units are marked. Unit numbering is kept (1a, 1b, 1c, 2, 3, 4) so
the design's decision numbers and the full plan's citations still resolve.

### 1.1 Gate status — read before trusting this plan

The **full** plan (`docs/superpowers/plans/2026-11-24-multiple-execution-machines-plan.md`)
was submitted to the Plan Review Gate three times; **no attempt returned a verdict**
(600 s wall clock twice, provider idle-stream timeout once; 15 spawns). That record is in
the full plan's §0.1 and is **not** erased by splitting. This milestone is a
**re-cut of unapproved material**, not a newly approved document. What the split *does*
buy: this document is ~800 lines instead of 1620, which is inside what a reviewer can
actually finish — so it can now be gated for real.

Known unreviewed material inherits as follows: **WU-5..9 were never independently
reviewed** (they are all in Milestone B — another reason A is the safer place to start).

## 2. Dependency graph and order

```text
WU-1a (pure types) ──→ WU-1b (IO resolve)
        │                   │
        │                   ├────────┐
        └──────────┬────────┘        │
                   ▼                 │
                 WU-2 (config)       │
                   │                 │
WU-1c (ssh argv) ──┼── independent   │
                   │                 │
WU-3 (mechanical) ─┴─────────────────┘
                   ▼
                 WU-4  ← CHECKPOINT A  (end of milestone)
```

**Order:** WU-1a, then {WU-1b ∥ WU-1c ∥ WU-3}, then WU-2, then WU-4.
(WU-1a must precede WU-1b and WU-2; WU-2 and WU-4 need WU-1b; WU-4 needs WU-2 and WU-3.)

**Not parallelizable in practice:** WU-2 and WU-4 both touch `Config.Security`'s
codec surface (`scUntrustedExec`'s neighbours), so running them concurrently invites a
conflict in the file this repo already calls a merge hotspot.

## 3. Work units

### WU-1a — `Seal.Execution.Types`: the pure type model

**Spec:** D1 (model shape), D3 (typed machine model, corrected), D4 (`Where`,
`ResolvedTarget`, `TargetError`, `teOperatorAction`, `renderTargetError`,
precedence table), D6 steps 1–4 as pure functions, D7 (`WorkspaceRoot'`), D8
(`KeyFilePath`, `IdentitySource` — pure core), D12 (port range), D16 (property
surface), D17 (leaf module).

**New file:** `src/Seal/Execution/Types.hs`.

**Public surface (exact):**

```haskell
module Seal.Execution.Types
  ( MachineName, mkMachineName, machineNameText
  , WorkspaceRoot'(), mkWorkspaceRoot, workspaceRootText
  , KeyFilePath(), mkKeyFilePath                    -- pure core; IO canonicalisation in WU-1b
  , IdentitySource (..)
  , SshMachineSpec (..), MachineSpec (..)
  , ExecutionConfig (..), defaultExecutionConfig, lookupMachine
  , Where (..), ResolvedTarget (..)
  , TargetError (..), teOperatorAction, renderTargetError
  , SelfIdentity(), selfIdentityFrom, selfIdentityTexts
  , parseIpv4Loose
  , hostDenotesSelf                                 -- D6 steps 1-4, pure
  , resolveTarget, validateTarget                   -- pure, per D4 precedence rows 1-8
  ) where
```

- Imports `Seal.Tools.Exec.Types` (the existing cycle-breaker leaf) and
  `Seal.Security.Path` (for `blockedNames` — D7's blocklist must have one source of
  truth; see C6). **No `Seal.Config.*`, no `Seal.Tools.Exec.Untrusted`** — D17 rules
  1–2 are satisfied by construction, and a DoD grep enforces exactly those two bans.
- `MachineName` derives `stock (Eq, Ord, Show)` — the CTO round-2 build break.
- `MachineSpec = MachineLocal | MachineSsh SshMachineSpec`, and `SshMachineSpec`
  **nests** the SSH record (no partial-field selectors: `-Wpartial-fields` is in
  `-Wall -Werror`).
- `ExecutionConfig { exDefault :: Maybe MachineName, exMachines :: Map MachineName MachineSpec }`
  with `defaultExecutionConfig = ExecutionConfig Nothing mempty`.
- `mkMachineName` enforces `^[a-z0-9][a-z0-9_-]*$` and nothing else (a dot is not in
  the class, so `.`, `..`, `%`, and any uppercase are rejected without a second rule).
- `mkWorkspaceRoot` rejects empty/relative, any `..` segment, any segment in
  `Seal.Security.Path.blockedNames` **on the root itself** (D7), **and — added here —
  a leading `-` or any control character.** It is pure: the D7 rule is lexical, because
  the root is an anchor, not a path to resolve. Documented as such in the haddock.

  The hyphen/control rejection is not D7's; it is required by WU-4's projection, and it is
  listed so the reason is visible: `mkWorkspaceRoot`'s output becomes an `SshConfig`'s
  `scWorkspace` through `mkRemotePath`, which rejects `-` (option injection) and control
  characters (`Types.hs:161-170`). Without this rule the projection is **partial**, and
  `error` in that position would be a crash reachable from a config file. With it,
  `sshConfigFromMachine` is total for a reason, not by assumption.
- `mkKeyFilePath` enforces D8's *lexical* half: absolute, no `..`. The *canonical*
  half (symlink resolution + `~/.ssh`/`~/.seal` allowlist) is IO and lives in
  WU-1b, because `mkKeyFilePath` must stay pure for the TOML codec to use it.
  **The constructor is not exported**; `validateKeyFilePathIO` (WU-1b) is the only
  way to obtain a `KeyFilePath` from operator input, and it calls `mkKeyFilePath`
  first. The pure constructor exists solely so the codec can be total.
  **`KeyFilePath`'s `Show` is redacted** (`show _ = "KeyFilePath <redacted>"`),
  mirroring `SafeKeyPath` (`Path.hs:369`): a `TargetError` or a log line must never
  carry a key path. It is therefore **not** `deriving stock (Show)` — a hand-written
  instance, and a DoD item asserts `show` does not contain the path.
- `parseIpv4Loose :: Text -> Maybe Word32` accepts 1–4 parts, each decimal, octal
  (`0` prefix), or hex (`0x` prefix), left-to-right filling, rejecting >32 bits and
  empty parts. Tested against `127.1`, `127.0.0.1`, `2130706433`, `0x7f000001`,
  `017700000001`, `0x7f.1`, `1` (→ `0.0.0.1`, not loopback ⇒ not self).
- `hostDenotesSelf` implements D6 steps 1–4 *in that order*, conditioned on
  `allowLocal = False` at the call site (`validateTarget`), never inside.
- `resolveTarget` implements D4's eight rows, including **row 2.5** (empty
  inventory → `TargetNoDefault []`) and **row 5** (≥2 machines, no default →
  `TargetNoDefault known`).
- `validateTarget` is `resolveTarget`'s post-pass: rows 6–8 only (local forbidden,
  self-host, allowed). Signature per D4.

**DoD:**

1. `nix develop --command cabal build all` exits 0 with `-Werror` clean.
2. `src/Seal/Execution/Types.hs` and `test/Seal/Execution/TypesSpec.hs` are in
   `exposed-modules` / test `other-modules` **in this commit**, and
   `test/Main.hs` imports the spec. Negative check (must be in the commit message):
   `grep -c 'Seal.Execution.Types' seal-harness.cabal` ≥ 2.
3. Deliberate-type-error probe, recorded in the commit message both ways:
   inserting `x :: Int; x = "s"` into the module makes `cabal build all` **fail**;
   removing it makes it pass. (This is the D16/CTO-round-2 proof that the module is
   actually typechecked.)
4. `MachineName` derives `(Eq, Ord, Show)`; a test constructs `TargetSelfHost` and
   compares it with `shouldBe` (fails to compile without the deriving clause).
5. `mkMachineName` rejects: `""`, `"a.b"`, `"."`, `".."`, `"%2e"`, `"Foo"`, `"-a"`,
   `"a b"`, `"a/b"`; accepts `"a"`, `"builder"`, `"build-box_2"`.
6. `parseIpv4Loose` table test (all eight forms above), plus a property that the
   result is ≤ 32 bits by construction.
7. `hostDenotesSelf` rejects **all** of `localhost`, `localhost.`, `LOCALHOST`,
   `127.0.0.1`, `127.1`, `2130706433`, `0x7f000001`, `0.0.0.0`, `ip6-localhost`
   against `selfIdentityFrom "arrakis.local" []` — the constructor production uses
   (see §0.2). Rejects `arrakis.local`, `ARRAKIS.LOCAL`, and any address in the
   `[Text]` argument.
8. `hostDenotesSelf` accepts `builder.example.com`, `10.0.0.5` (when not in
   `SelfIdentity`), `203.0.113.7`.
9. `selfIdentityFrom "h" []` contains `localhost`, `localhost.localdomain`,
   `ip6-localhost`, `ip6-loopback`, `127.0.0.1`, `::1` (D6 step 2, the round-2
   Security blocker).
10. `resolveTarget` table test: one case per D4 row 1, 2, 2.5, 3, 4, 5 (rows 6–8
    are `validateTarget`). Row 5 asserted reachable with a 2-machine,
    no-`default` config.
11. `validateTarget` table test: rows 6, 7, 8. Row 7 asserted only when
    `allowLocal = False` (D4's "conditioned on" qualifier).
12. **D16 property** (`Test.Hspec.QuickCheck.prop`, wrapper newtype to avoid orphan
    instances, generators through the smart constructors as `Gen (Maybe …)`):
    ```haskell
    prop "allowLocal=False ⇒ never WhereLocal, never an SSH target on this box"
      $ \cfg pin (SelfIdWrapper sid_) ->
          case validateTarget sid_ False <$> resolveTarget cfg False pin of
            Left _      -> True
            Right t     -> case rtWhere t of
              WhereLocal   -> False
              WhereSsh c   -> not (hostDenotesSelf sid_ (getSshHost (scHost c)))
    ```
    This is the property the design says is worth having (not
    `allowLocal=False ⇒ never TargetLocal`, which is true by construction).
13. `mkWorkspaceRoot` rejects `"~/.seal"`, `"a/../b"`, `"../x"`, `""`, `"rel/path"`;
    accepts `"/srv/seal/workspace"`. Property: *every segment of a validated root is
    blocked-name clean* (D7).
14. `renderTargetError` produces exactly the five D13 strings; a test asserts each
    string is non-empty, contains no `"allow_local = "` instruction addressed to the
    agent, and that `teOperatorAction` is `False` only for `TargetUnknownMachine`.
15. `hlint src/ test/` reports `No hints` for the two new files.
16. `grep -n 'Seal\.Config\.\|Seal\.Tools\.Exec\.Untrusted' src/Seal/Execution/Types.hs`
    returns nothing (D17 rules 1 & 2, mechanically enforced). The permitted imports
    are exactly `Seal.Tools.Exec.Types` and `Seal.Security.Path`; a test-adjacent
    assertion is unnecessary because the build fails on a cycle, but the grep makes
    the rule auditable rather than incidental.
17. **The redacting `Show` is asserted on a value that actually exists.** Write the test
    against a *known-good* path built in a temp dir (so `mkKeyFilePath` returns `Right`),
    then assert `show` of it contains neither the temp-dir path nor `"/home/me"`:
    ```haskell
    it "KeyFilePath's Show redacts the path" $ withSystemTempDirectory "kf" $ \d -> do
      let p = d </> "id_ed25519"
      case mkKeyFilePath p of
        Right kf -> do show kf `shouldNotSatisfy` T.isInfixOf (T.pack d)
                       show kf `shouldBe` "KeyFilePath <redacted>"
        Left e   -> expectationFailure ("fixture path rejected: " <> show e)
    ```
    An earlier draft wrote this as `show (either (const undefined) id (mkKeyFilePath ...))`,
    which is self-defeating: if the path is rejected, `undefined` is forced and the test
    throws; if it is accepted, the test passes without ever exercising redaction
    meaningfully. **Never assert on `either (const undefined) id`** — that pattern tests
    nothing in either branch.

**File scope:** `src/Seal/Execution/Types.hs` (new),
`test/Seal/Execution/TypesSpec.hs` (new), `seal-harness.cabal`, `test/Main.hs`.

**Depends:** none.

---

---

### WU-1b — `Seal.Execution.Resolve`: the IO entry points

**Spec:** D4 (`getSelfIdentity`, `resolveTargetIO`), D6 step 2 (real
`getHostName` + `TlsCert.localAddressNames`), D8 (canonicalising half), D13/C4
(`TargetConfigUnreadable` producer).

**New file:** `src/Seal/Execution/Resolve.hs`.

```haskell
module Seal.Execution.Resolve
  ( getSelfIdentity
  , resolveTargetIO
  , loadAndResolveTargetIO
  , validateKeyFilePathIO
  ) where
```

- `getSelfIdentity = selfIdentityFrom <$> getHostName <*> localAddressNames`.
  Uses the existing `Seal.Security.TlsCert.localAddressNames` (`TlsCert.hs:222`) —
  the same enumeration the TLS SAN list already trusts. It must **not** be the only
  source: `selfIdentityFrom` supplies the loopback literals.

  **Use `nodeName <$> getSystemID`, not `Network.HostName.getHostName`.** The
  `hostname` package is present in the dev shell but is **not** in the library's
  `build-depends` (`seal-harness.cabal:240-300`), whereas `System.Posix.Unistd`
  from `unix` already is, and this tree already reads the node name that way at
  `src/Seal/Command/Serve.hs:32` (`import System.Posix.Unistd (getSystemID, nodeName)`).
  Verified on this machine: both return `arrakis.local`. Using the undeclared
  package would fail `cabal build` in a clean nix shell, not in the session's shell.
- `loadAndResolveTargetIO paths allowLocal pin`: `loadExecutionConfig (executionFilePath paths)`
  → `Left err` ⇒ `Left (TargetConfigUnreadable err)`; `Right cfg` ⇒
  `resolveTargetIO cfg allowLocal pin`.
- `validateKeyFilePathIO paths raw`: canonicalise (following symlinks, then
  re-check), reject any path segment in `blockedNames` **except** when the
  canonical path is under `spHome paths </> ".ssh"` or `spKeys`/`spConfig` under
  `spHome` (D8's allowlist) — implemented as an explicit allowlist, not a silent
  exemption, with the reason in a haddock.

**DoD:**

1. Build clean; module wired into `exposed-modules`, test spec into
   `other-modules` + `test/Main.hs` in this commit.
2. `getSelfIdentity` test (does not assert on the machine's real hostname, which
   would make CI machine-dependent): the result **contains** `"localhost"`,
   `"127.0.0.1"`, `"::1"`, and contains `nodeName <$> getSystemID` lower-cased
   (assert the *containment*, computed from the same call, not a literal).
3. `loadAndResolveTargetIO` with an unparseable `execution.toml` returns
   `Left (TargetConfigUnreadable _)` — **the C4 producer test**; with a valid file it
   returns `Right` carrying `rtName`.
4. `validateKeyFilePathIO` accepts `~/.ssh/id_ed25519` and `~/.seal/keys/x`;
   rejects a relative path, a path containing `..`, and a symlink inside
   `~/.ssh` pointing at `/etc/passwd` (created in a temp dir fixture: this is D8's
   "else `~/.seal/key -> /tmp/x` passes" case). Each rejection is `Left`.
5. **`Seal.Execution.Resolve`'s import set, stated correctly.** It imports
   `Seal.Execution.Types`, `Seal.Security.TlsCert` (`localAddressNames`),
   `Seal.Config.Paths` (`SealPaths`, `spHome`/`spKeys`/`spConfig` for
   `validateKeyFilePathIO`) and `Seal.Config.Execution` (`loadExecutionConfig` for
   `loadAndResolveTargetIO`). An earlier draft listed only the first two, which
   `validateKeyFilePathIO` and `loadAndResolveTargetIO` cannot be written without.
   **What D17 rule 1 actually forbids is the reverse edge: `Seal.Config.Security` must not
   import `Seal.Execution.Types`.** Assert exactly that, and only that:
   `grep -n 'Seal\.Execution' src/Seal/Config/Security.hs` returns nothing. Do **not**
   assert the (false) claim that `Resolve` imports nothing else — that would fail on the
   first build.
6. `hlint` clean.

**File scope:** `src/Seal/Execution/Resolve.hs` (new),
`test/Seal/Execution/ResolveSpec.hs` (new), `seal-harness.cabal`, `test/Main.hs`.

**Depends:** WU-1a.

---

---

### WU-1c — Close D6's `~/.ssh/config` escape hatch

**Spec:** D6, final paragraph (unowned in the design's table — see C2).

**Change:** `sshExecArgv` and `sshExecArgvForwarding` (`src/Seal/Tools/Exec/Remote.hs:93,130`)
gain, in both variants:

```
"-F", "/dev/null"
"-o", "ProxyCommand=none"
"-o", "ProxyJump=none"
```

Rationale to be carried in the haddock: `ssh` honours `~/.ssh/config`, so a
`Host builder` → `HostName 127.0.0.1` alias defeats every lexical self-host check
without touching `execution.toml`. `-F /dev/null` makes the argv the *whole* config,
which is what `validateTarget` validates.

**DoD:**

1. Build clean.
2. Test: `sshExecArgv cfg "echo hello"` contains the adjacent pair `("-F", "/dev/null")`.
3. Test: the same for `sshExecArgvForwarding`.
4. Test: both variants contain `("-o", "ProxyCommand=none")` and
   `("-o", "ProxyJump=none")`.
5. Test: `-F` appears **before** the `user@host` element in both (a later `-F` is
   still honoured by ssh, but pinning the position keeps the argv diffable against
   the docs).
6. Existing `RemoteSpec` assertions still pass unchanged: `StrictHostKeyChecking=yes`
   adjacency, `UserKnownHostsFile=`, `-A` absent from `sshExecArgv`, `-A` present in
   `sshExecArgvForwarding`, `--` separator, fixed program path `ssh`.
7. `test/Seal/Tools/Exec/FileExplorerSpec.hs`, `UntrustedIORemoteSpec.hs`,
   `Session/AgentMetaCacheSpec.hs` (all of which call these constructors) still pass —
   they assert on argv shape, and the three added flags do not displace anything they
   check.
8. `hlint` clean.

**File scope:** `src/Seal/Tools/Exec/Remote.hs`,
`test/Seal/Tools/Exec/RemoteSpec.hs`.

**Depends:** none (parallel with WU-1a/1b).

---

---

### WU-2 — `Seal.Config.Execution` + `allow_local` + the validators' IO half (additive)

**Spec:** D1 (`execution.toml` shape and `ex`/`exMachines` naming), D2 (`allow_local`,
read per turn, *not* described as boot-only), D4a/D5 (boot **warning**, not boot
exit), D7/D8 (validators), D12 (port range).

**New file:** `src/Seal/Config/Execution.hs`.

```haskell
module Seal.Config.Execution
  ( loadExecutionConfig      -- :: FilePath -> IO (Either Text ExecutionConfig)
  , decodeExecutionConfig    -- :: Text -> Either Text ExecutionConfig   (pure, for tests)
  , executionConfigCodec     -- :: Toml.TomlCodec ExecutionConfig
  , saveExecutionConfig      -- :: FilePath -> ExecutionConfig -> IO (Either Text ())
  , executionBootWarning     -- :: ExecutionConfig -> Maybe Text          (D4a)
  ) where
```

- Top-level keys, **not** `[execution]`: `default = "builder"` and
  `[machines.<name>]`, per D1. `exDefault`/`exMachines`, `ex`/`exMachines` prefixes.
- `local` is a **reserved name**: a `[machines.local]` table carrying any key other
  than none is a decode error naming the offending key. Represented in the model as
  `MachineLocal`; there is no `local = true` field to mis-set (D1).
- Absent file ⇒ `Right defaultExecutionConfig` (mirrors `loadRuntimeConfig`).
- `executionBootWarning cfg` returns `Just` text when
  `Map.size (exMachines cfg) >= 2 && isNothing (exDefault cfg)` (D4a/D5). It is
  **pure** and returns text; boot *prints* it (below) and keeps going — never
  `exitFailure`.
- The codec must survive the tomland implicit-table trap already solved twice in this
  tree (`File.hs:584-624` for `[providers.*]`, `Security.hs:386-400` for
  `[access_control]`): a file declaring only `[machines.builder]` with no bare
  `[machines]` header decodes to an **empty map** unless the AST node is made
  explicit before decoding. Reuse that pattern; a DoD item tests exactly the
  header-less spelling, because it is the idiomatic one and every hand-written
  config will use it.
- `allow_local` is added to `UntrustedExecFileConfig` as
  `uefcAllowLocal :: Maybe Bool` with `Toml.dioptional (Toml.bool "allow_local")`,
  plus `resolvedAllowLocal :: UntrustedExecFileConfig -> Bool`
  (`fromMaybe True`) and `SecurityConfig -> Bool` convenience
  (`securityAllowLocal :: SecurityConfig -> Bool`, absent section ⇒ `True`).
  **Additive**: `uefcMode` and `uefcRemote` still work, so every existing caller
  keeps compiling and every existing spec keeps passing.
- Boot wiring: `src/Seal/Command/Serve.hs` and `src/Seal/Channel/Cli.hs` print
  `executionBootWarning` once at startup (through the existing logger/`putStrLn`
  path each already uses), and continue. **Not** a boot exit — D4a, because the
  gateway must stay reachable so the operator can read the message.
- New template `config/templates/execution.toml`, embedded via `file-embed` in
  `Seal.Config.Templates` (`qAddDependentFile` + `embedFile`, exactly like the other
  two), added to `extra-source-files`. `TemplatesSpec`'s staleness test is extended
  to cover it in the same commit.
- `Paths.hs` gains `executionFilePath :: SealPaths -> FilePath` =
  `spConfig paths </> "execution.toml"`.

**DoD:**

1. Build clean; `Seal.Config.Execution` wired into `exposed-modules`, its spec into
   `other-modules` + `test/Main.hs`, in this commit.
2. Decode tests: absent file ⇒ `defaultExecutionConfig`; minimal (`[machines.local]`
   only) ⇒ one `MachineLocal`; full `[machines.builder]` with all seven keys ⇒
   `MachineSsh` with every field populated; **header-less**
   (`[machines.builder]` with no `[machines]`) ⇒ same as full (the tomland trap);
   malformed TOML ⇒ `Left`; duplicate machine names ⇒ `Left`;
   `[machines.local]` with `host = "x"` ⇒ `Left` naming `host`.
3. Port range (D12): `port = 0` and `port = 65536` are `Left`; `1` and `65535` are
   `Right`. A `Left` for a *missing* port is **not** an error (defaults 22).
4. `machineName` charset is enforced **at decode time**: `[machines."Bad.Name"]` is
   `Left` (not a panic at use time).
5. `workspace` is validated at decode time through `mkWorkspaceRoot`:
   `workspace = "../x"` and `workspace = "rel"` are `Left` (D7).
6. `identity`/`known_hosts` are validated at decode time for the lexical half:
   a relative path is `Left` (D8).
7. `executionBootWarning` returns `Nothing` for 0 machines, 1 machine, and 2 machines
   with a `default`; returns `Just` naming the machine count and the file path for
   2 machines without one.
8. `resolvedAllowLocal` defaults to `True` when the key is absent, honours
   `allow_local = false`, and `saveSecurityConfig` round-trips the key (write, reload,
   assert) — this is the "security.toml comments survive" check: the writer must not
   drop the key it just wrote.
9. `TemplatesSpec`: `config/templates/execution.toml` (a) decodes via
   `decodeExecutionConfig`, (b) is byte-identical to the embedded copy (the staleness
   test), (c) has a copy-pasteable `# [machines.builder]` header, and (d) every key it
   mentions resolves to the same config as an absent file (the templates' standing
   "never change behaviour" invariant).
10. `seal-harness.cabal` `extra-source-files` lists `config/templates/execution.toml`
    (sdist builds).
11. Boot warning is printed by `seal serve` and `seal tui` when the fixture is
    ≥2-no-default, and the process **still starts** (integration-level assertion on
    the wiring function, not a live server).
12. Existing `SecuritySpec`, `TemplatesSpec`, `Phase4Spec`, `UntrustedSpec`,
    `ApiTestHarness` specs still pass unchanged (the additive guarantee).
13. `hlint` clean.

**File scope:** `src/Seal/Config/Execution.hs` (new),
`test/Seal/Config/ExecutionSpec.hs` (new), `src/Seal/Config/Paths.hs`,
`test/Seal/Config/PathsSpec.hs`, `src/Seal/Config/Security.hs`,
`test/Seal/Config/SecuritySpec.hs`, `src/Seal/Config/Templates.hs`,
`test/Seal/Config/TemplatesSpec.hs`, `config/templates/execution.toml` (new),
`src/Seal/Command/Serve.hs`, `src/Seal/Channel/Cli.hs`, `seal-harness.cabal`,
`test/Main.hs`.

**Depends:** WU-1a, WU-1b.

---

---

### WU-3 — `defaultSessionMeta` (mechanical, zero behaviour change)

**Spec:** D15 (the design says 75 construction sites across 31 files; **measured
77 across 25** with `scripts/count-sessionmeta-sites.py` — see DoD 2. The exact
number matters only because it is the DoD's baseline; what matters is that a count,
not a hand-written list, defines "done").

**Change:** `Seal.Session.Meta` gains

```haskell
defaultSessionMeta :: SessionId -> UTCTime -> SessionMeta
```

carrying today's field values (`channel = "cli"`, `sealFrontMatter = True`,
everything else `Nothing`). Every positional construction site in `src`/`test` is
rewritten as `(defaultSessionMeta sid t) { field = … }`.

**Why record-update and not more positional arguments:** the sites that hurt are the
positional literals (`test/Seal/Gateway/SendSpec.hs:273` and friends pass thirteen
bare arguments). Adding a fourteenth argument to those is how a field gets silently
swapped; record-update syntax cannot.

**DoD:**

1. Build clean; **no behavioural change** — the full suite is green with the same test
   count as baseline (record the before/after counts in the commit message; the count
   must be equal, not merely "green").
2. **Sites remaining, counted by the plan's own baseline command.** Run:
   ```
   python3 scripts/count-sessionmeta-sites.py
   ```
   The script is **not created by this unit** — it already exists in the tree
   (`scripts/count-sessionmeta-sites.py`, 131 lines) and was written while planning, so
   the baseline is already taken rather than needing to be committed first. This unit
   **extends** it only if the predicate needs to cover a shape it misses; otherwise it
   leaves the file untouched and its output is the gate.
   A 20-line script, not a `grep`, because **a single `grep` cannot express this
   predicate** — the three shapes are `= SessionMeta` (positional, 37 sites),
   `... SessionMeta` followed by `{` (record), and `SessionMeta` at end-of-line with
   the brace on the next line; and the naive alternations also match the *type* in
   `:: SessionMeta`, `IO (Maybe SessionMeta)`, `[SessionMeta]`, `data SessionMeta`
   and `SessionMeta(..)` in imports. Measured with the script's predicate on the
   pre-change tree: **77 construction sites across 25 files** — `ApiSpec.hs` 29,
   `SendSpec.hs` 10, `ModelSpec.hs` 5, `LoggerSpec.hs` 4, `BranchSpec.hs` 3,
   `StoreSpec.hs` 3, and one or two each in the remaining nineteen. (The design's
   "75 across 31" and the handoff's "~56" are both approximations; the script's
   number is the one that must reach 0.)
   **DoD:** the script reports `0` outside `src/Seal/Session/Meta.hs`, and its
   pre-change output (77 / 25 files) is pasted in the commit message. The script is
   **not** authored here — it already exists (see above) — so it needs no review in this
   unit.
3. Every rewritten site preserves its original field values: spot-check the 12
   non-trivial ones (`smAgent`, `smAgentName`, `smRepoUrl`, `smDescription`,
   `smSealFrontMatter = False`) by name in the commit message.
4. `Seal.Session.Meta` still exports `readSessionMeta` unchanged; `MetaSpec` still
   covers tolerant decode (missing `channel` ⇒ `"cli"`, missing `agent` ⇒ `Nothing`) —
   plus one new case: a `session.json` written *before* this feature (no `exec_machine`
   key) decodes with the new field `Nothing`.
5. `hlint` clean.

**File scope:** `src/Seal/Session/Meta.hs` and every file the baseline script lists: `src/Seal/Session/Store.hs`, `src/Seal/Core/TurnEngine.hs`,
`src/Seal/Agent/Runtime/Delegation/Worker.hs`,
`test/Seal/{Tabs/PartitionSpec,Core/SystemPromptSpec,ISA/Ops/AgentHandoffSpec,ISA/Ops/SessionSpec,TestHelpers/ApiTestHarness,Agent/Runtime/Delegation/WorkerSpec,RepoDiscoverySpec,Channel/CliSpec,Command/{ModelSpec,NewSpec,SessionSpec,TabSpec},Logging/LoggerSpec,Gateway/{MutationGuardSpec,ServerSpec,ApiFilesSpec,SendSpec,PatIngestionSpec,ApiSpec,SetupApiSpec},Phase7aSpec,Session/{MetaSpec,StoreSpec,BranchSpec}}.hs`.
the 25 files the script names — its output is the authoritative list, since a
hand-written enumeration is exactly how a site gets missed. (`SessionJson.hs`,
`Search.hs`, `Partition.hs`, `ChannelContext.hs` and `Command/Model.hs` mention
`SessionMeta` only in type positions and have **no** construction site — verified by
running the script, which is why they are absent from its output.) `src-gateway-types` and `src-chat-channels` contain **no**
construction site (the only `SessionMeta` occurrences there are a doc comment in
`AesonUtils.hs:14`).

**Depends:** none (parallel with WU-1a/1b/1c).

**Checkpoint:** no.

---

---

### WU-4 — The per-session pin, and `--machine` in both parsers  ← **CHECKPOINT A**

**Spec:** D9 (pin field, tolerant decode, inheritance, **no opcode may set it**) — with
**one documented deviation**, C9 below; D10's precondition (a refused session is
re-pinnable later); PM round-2 blocker 2 (`--machine` must land here, or WU-1..4 persist a
field nothing can write).

**C9 — the one place this milestone deliberately departs from the design.** D9 says
"**Resolved at creation, persisted as the name.** Changing `default` does not move new
sessions." Milestone A **cannot** do that and stay additive, and the reason is structural:

- D9 was written for the post-D2 world, where `mode` is gone and `default` is the only
  fallback. In that world "persist the resolution" is well-defined and safe.
- In A, `mode` still exists and is still authoritative. With no `execution.toml`,
  `resolveTarget` row 1 answers `WhereLocal`; persisting that resolution stamps
  `exec_machine = "local"` onto every new session and the pin case then bypasses
  `mode = "remote"` — §3.1's regression, through the creation path.
- So A persists **the request** (`Just name` when explicitly pinned, `Nothing` otherwise)
  and validates at creation so the *error* still surfaces there.

**Consequence, stated so it is not a surprise later:** in A, an unpinned session keeps
`exec_machine = null` and re-resolves through `mode` at turn time, so it *can* move when
`mode` changes — where D9 promises new sessions do not move. **Milestone B's WU-2b restores
D9 exactly**: once `mode` is deleted, `default` is the only fallback, and persisting the
resolution becomes both safe and required. D9's invariant therefore lands in B, not A, and
B's DoD must assert it (it does: the migration + `TargetNoDefault` row).

**Change:**

- `SessionMeta` gains `smExecMachine :: Maybe MachineName` (not `Maybe Text`) —
  D9's reason (`smAgent :: Maybe AgentDefId` precedent). On-disk key `exec_machine`.
  `ToJSON`/`FromJSON` updated; decode is **tolerant**: an invalid name is dropped
  (`.:?` into `Maybe Text` then `mkMachineName` with `either (const Nothing) Just`),
  matching the existing "inherited branch that no longer validates is dropped"
  policy.
- **Do not change `newSessionMeta`/`newSession`'s arity beyond the pin.** Measured with
  `grep -rnE '\bnewSession(Meta)?[[:space:](]' --include=*.hs src test` (excluding the two
  definitions in `Store.hs`): **101 call sites across exactly these 11 files** —

  | Sites | File |
  |---|---|
  | 62 | `test/Seal/ISA/Ops/SessionSpec.hs` |
  | 15 | `test/Seal/Session/SearchSpec.hs` |
  | 5 | `test/Seal/Session/StoreSpec.hs` |
  | 5 | `src/Seal/Session/Store.hs` |
  | 5 | `src/Seal/Gateway/API.hs` |
  | 3 | `test/Seal/Gateway/ApiSpec.hs` |
  | 2 | `src/Seal/Command/New.hs` |
  | 1 | `test/Seal/Command/SessionSpec.hs` |
  | 1 | `src/Seal/ISA/Ops/Session.hs` |
  | 1 | `src/Seal/Command/Serve.hs` |
  | 1 | `src/Seal/Channel/Cli.hs` |

  All eleven are in this unit's file scope. An earlier draft of this plan named a
  *different* eleven — it omitted `test/Seal/Session/StoreSpec.hs` and
  `test/Seal/Command/SessionSpec.hs` while listing files that have no call site at all.
  That is the classic "changed signature, unnamed call sites" defect, and because the new
  parameter is non-optional under `-Werror`, those two files would simply not compile.

- **No signature change anywhere: the cache reads the pin itself.** Two earlier designs
  were wrong and are recorded in §3.1 so they are not re-attempted:
  a `securityConfigForTarget` bridge in `TurnEngine` (**unsafe** — it silently moved
  untrusted execution to the harness box), and threading a `Maybe MachineName` argument
  through `cachedSessionExec`/`mkSessionExec` (**16 `cachedSessionExec` calls** — 10 in
  `ExecCacheSpec.hs`, 5 in `TurnEngine.hs`, 1 in `API.hs` — **plus 3 `mkSessionExec`
  calls**, two of which live inside the modules being changed: the same "changed a
  signature, named the wrong files" defect).

  The pin does not need to travel as an argument at all. `cachedSessionExec` already has
  what it takes to read it:

  ```haskell
  cachedSessionExec
    :: SessionExecCache -> SealPaths -> SecurityConfig -> SessionId
    -> CloneDeps -> RemoteRunner -> Maybe HostKeyAdoption -> IO SessionExec
  -- unchanged from today
  ```

  Inside, before choosing the arm:

  ```haskell
  -- Already-available imports; Meta imports nothing from ExecCache, so no cycle.
  mPin <- smExecMachine <$> readSessionMeta paths sid   -- Seal.Session.Meta.readSessionMeta
  ```

  `readSessionMeta :: SealPaths -> SessionId -> IO (Maybe SessionMeta)`
  (`Meta.hs:33`) takes exactly the two arguments already in scope, and `Seal.Session.Meta`
  imports no `Seal.Session.*` module, so the import cannot cycle (verified).

  Then, and only then, the three cases. **The mechanism, stated exactly** — the earlier
  draft claimed "no signature change" while also requiring the pin to reach `mkSessionExec`,
  and those two are incompatible: `mkSessionExec` derives local-vs-remote *internally* from
  `untrustedExecConfigFromSecurity secCfg` (`Workdir.hs:181-182`), so it cannot be told
  about a pin without being told something.

  - `cachedSessionExec`'s **type is unchanged** (it reads the pin itself, above).
  - `mkSessionExec` **gains one parameter**, `Maybe ResolvedTarget`, appended before the
    `IO` result:
    ```haskell
    mkSessionExec :: SealPaths -> SecurityConfig -> SessionId
                  -> CloneDeps -> RemoteRunner -> Maybe HostKeyAdoption
                  -> Maybe ResolvedTarget -> IO SessionExec
    ```
    Its body gets one new case **ahead of** the existing `case`:
    ```haskell
    mkSessionExec paths secCfg sid cloneDeps runner mAdoption mTarget =
      case mTarget of
        Nothing -> existingBody paths secCfg sid cloneDeps runner mAdoption
        Just rt -> case rtWhere rt of
          WhereLocal  -> existingLocalArm ...        -- today's Nothing arm
          WhereSsh c  -> existingRemoteArm c ...     -- bypass the mode lookup only here
    ```
    `existingBody` is the current body, moved verbatim behind the `Nothing` branch — so the
    unpinned path is *the same code*, not a re-implementation. That is what makes DoD 14
    meaningful.
  - `mkSessionExec` has exactly **3 call sites**, all inside files already in this unit's
    scope: `ExecCache.hs:113` (the cache itself), `Workdir.hs:312` (`mkSessionUntrustedIO`,
    passes `Nothing`), `API.hs:1656` (passes the session's resolved pin). No other file
    changes.
  - **`WhereSsh` needs a `SshConfig`, and `SshMachineSpec` is not one.** WU-1a's
    `SshMachineSpec` holds validated newtypes (`SmsHost :: SshHost`, `SmsUser :: SshUser`,
    `SmsPort :: Int`, `SmsIdentity :: IdentitySource`, `SmsKnownHosts :: KeyFilePath`,
    `SmsWorkspace :: WorkspaceRoot'`), while `SshConfig` wants `SshHost`, `SshUser`, `Int`,
    `Maybe FilePath`, `FilePath`, `RemotePath`. So WU-1a also exports one pure projection,
    and the plan must name it or an implementer will invent it:
    ```haskell
    -- Seal.Execution.Types, pure, total (both sides already validated)
    sshConfigFromMachine :: SshMachineSpec -> SshConfig
    ```
    It reuses the *already-constructed* newtypes (no re-parsing, no new failure mode):
    `scHost = smsHost`, `scUser = smsUser`, `scPort = smsPort`,
    `scIdentity = case smsIdentity of AgentOnly -> Nothing; PinnedFile k -> Just (getKeyFilePath k)`,
    `scKnownHosts = getKeyFilePath (smsKnownHosts ...)`, `scWorkspace = mkRemotePath (workspaceRootText smsWorkspace)`
    — the last one is the only fallible conversion. It is total **because**
    `mkWorkspaceRoot` rejects a leading `-` and control characters (WU-1a, above), which are
    exactly `mkRemotePath`'s extra rejections beyond empty. An earlier draft called this
    "total in practice"; it was not, and `error` there would have been a config-reachable
    crash. If the projection ever returns `Left`, that is a bug in `mkWorkspaceRoot`'s
    validator, and the DoD asserts the implication rather than trusting it.

  The pin also becomes part of the cache key here, which is D11's requirement anyway
  (`ceSessionPin`); doing it in the cache is where that guard belongs.

- **`newSessionMeta`/`newSession` persist a pin ONLY when one was explicitly requested.**
  This is the second place the §3.1 regression can re-enter, and an earlier draft had it
  wrong. The rule:

  | Caller passed | Persisted | Turn-time resolution |
  |---|---|---|
  | `Just name` | `Just name` after validation | the pin (validated at creation; `400`/refusal on `Left`) |
  | `Nothing` | **`Nothing`** | **today's `mode` path, unchanged** |

  An earlier draft resolved `Nothing` through `loadAndResolveTargetIO` and persisted the
  *result* (`Just (rtName t)`). On a legacy install that is fatal: with no
  `execution.toml`, `resolveTarget` row 1 answers `WhereLocal`, so every new session would
  be stamped `exec_machine = "local"` — and the pin case then ignores `mode = "remote"`,
  moving untrusted execution onto the harness box. DoD 14 would not catch it either, since
  it asserts on `smExecMachine = Nothing`, a state that design removes for every **new**
  session.

  So validation still uses `loadAndResolveTargetIO` (it is how an unknown or unselectable
  name becomes a `400`), but **the persisted value is the request, not the resolution**.
  That keeps "resolve at creation" true in the sense that matters — the *error* is reported
  at creation — while leaving the unpinned path byte-identical to today.

  Consequence for D9: a session that never pins a machine keeps `exec_machine = null` and
  continues to resolve through `default` at turn time. That is intentional and is what
  makes A additive; Milestone B's WU-2b is the unit that changes it, because B removes
  `mode` and makes `default` the only path. **`allowLocal` is read from the security config
  at creation time** via `securityAllowLocal` (WU-2), used only for validation.
- `POST /api/tabs/new`: `handleTabNew` (`API.hs:1280`) validates an `exec_machine` field
  (unknown machine ⇒ `400` with `renderTargetError`'s text). Absent ⇒ `Nothing` (resolve
  via `default`). **Note precisely where the change lands:** there is **no Haskell
  `CreateTabBody`** — the server takes a raw `A.Value` and reads fields ad hoc. The
  `CreateTabBody` *interface* is TypeScript-only (`frontend/src/hooks/useApi.ts:1021`) and
  is extended by **WU-8**, not here. An earlier draft of this plan named `CreateTabBody` as
  the WU-4 change site, which sent an implementer looking for a type that does not exist.
- `NewArgs` gains `naMachine :: Maybe Text`; `parseNewArgs` learns **`--machine` only**
  (long-only, per the design — no `-M`), single value, unknown flags still ignored. The
  chat `/new` path therefore picks it up with no separate parser: `parseNewArgs` *is*
  the shared parser (`src-gateway-types/Seal/Gateway/Types/NewArgs.hs:52`, imported by
  `src-chat-channels/Seal/Channels/Chat/Loop.hs:1727`).
- `mintNewSessionWith`/`mintNewSession` (`src/Seal/Command/New.hs:210,220`) pass
  `naMachine >>= either (const Nothing) Just . mkMachineName`. `NewArgs` lives in
  `seal-gateway-types`, which cannot import the main library, so `naMachine` is
  `Maybe Text` and validation happens here — the same split `naBranch` uses.
- **Inheritance (D9): children copy the parent's `exec_machine` *value* — never a resolved
  default.** `writeChildMeta` (`Worker.hs:397`), `writeHandoffMeta` (`Worker.hs:516`),
  `fallbackMeta` (`TurnEngine.hs:1339`), and the branch path (`API.hs:1319` →
  `branchSession`, whose `SessionMeta` the caller writes just after) set
  `smExecMachine = smExecMachine parent`.

  Two corrections to an earlier draft, both from C9's rule that **A persists the request,
  not the resolution**:
  (a) it said "copy the parent's **resolved** machine … else the parent's default-resolved
  name", which would have stamped `local` onto every child of an unpinned session on a
  legacy `mode=remote` install — the §3.1 regression, a **fourth** route;
  (b) it justified itself with "anchored children already reuse the parent's exec
  (`TurnEngine.hs:1282`)", but that line reads `mAnchor` to choose the *exec-cache key*
  (`execSid`), not to copy a pin. The citation did not support the claim.

  So: a pinned parent's children are pinned to the same machine; an unpinned parent's
  children are unpinned and resolve through `mode` like the parent. That is the behaviour
  that keeps A additive end to end.
- **No opcode sets it.** `SESSION_MANAGE action=new` (`src/Seal/ISA/Ops/Session.hs`)
  and cron fires pass `Nothing` for the pin. A DoD item asserts this by grep plus a
  test that a `SESSION_MANAGE`-created session's `session.json` has `exec_machine`
  equal to the resolved `default`, never the parent's machine.
- Wire: `sessionInfoJson` (`SessionJson.hs:80`) gains `"execMachine" .= smExecMachine`.
  **Not** `execRefusal` yet — that needs resolution, which is WU-7.

**DoD:**

1. Build clean.
2. `smExecMachine` round-trips through `session.json`; a legacy file with no
   `exec_machine` decodes to `Nothing`; a file with `"exec_machine": "Bad.Name"`
   decodes to `Nothing` **without failing the whole decode** (the tolerant-decode
   requirement — asserted by decoding a full meta object, not by testing the field
   alone).
3. `parseNewArgs "--machine builder"` ⇒ `naMachine = Just "builder"`;
   `parseNewArgs "--machine"` (no value) ⇒ unchanged (`naMachine = Nothing`);
   `parseNewArgs "-M builder"` ⇒ `naMachine = Nothing` (**long-only**, asserted so a
   future `-M` cannot be added silently); `parseNewArgs` ignores `--machine` when it
   appears as a value of another flag.
4. `NewSpec`: the four cases above, plus a case proving `--machine` composes with
   `-p/-m/-r/-b`.
5. **Falsification demo, recorded verbatim in the checkpoint report.** The fixture must
   make the pin the *only* thing that changes the argv — so it declares
   `default = "local"`, `[machines.local]`, and `[machines.builder]`, and the fixture's
   `security.toml` sets **`mode = "local"`**. With `mode = "remote"` (an earlier draft's
   fixture), the unpinned baseline would already compose the remote argv, but the remote
   *host* would come from `[untrusted_execution.remote]`, not from `[machines.builder]` —
   so `--machine builder` could not be shown to have changed anything. Assert **both**
   argv in one test: **no flag ⇒ `localhost`** (from `mode = "local"`), **`--machine
   builder` ⇒ `builder.example.com`**.
   With that fixture, `/new --machine builder` on the CLI prints a session whose
   `session.json` carries `"exec_machine": "builder"`, and the **composed ssh argv**
   for that session's next untrusted op contains `builder.example.com` (captured from
   the recording fake runner, not from a live SSH). This is the design's stated
   falsification point.
6. `POST /api/tabs/new` with `{"kind":"provider","exec_machine":"nope"}` ⇒ `400` whose
   body is `TargetUnknownMachine`'s message and lists the known names.
7. `POST /api/tabs/new` with a machine named `local` while `allow_local = false` ⇒
   `400` with `TargetLocalForbidden`'s message (creation-time refusal, D9 + D4 row 6).
8. Child inheritance: a `builder` parent spawning a delegated child yields a child
   `session.json` with `exec_machine = "builder"`; a handoff session likewise; a
   branched session likewise. Three separate assertions.
9. **`SESSION_MANAGE action=new` leaves the pin absent.** In a `builder` session, the new
   session's `session.json` has **no** `exec_machine` (**not** `"builder"`, and **not** a
   resolved `"default"` — see C9: A persists only explicit requests). Its first turn
   resolves through `mode`, exactly as an unpinned session does. An earlier draft asserted
   the field would equal the resolved `default`, which contradicted C9 in the same unit.
10. `sessionInfoJson` output contains `execMachine`, `null` for an unpinned session.
11. `--machine` appears in `/help`'s `/new` line (the parser and the help text agree;
    `/help` is generated from `CommandSpec`, so this is a one-line addition with a
    test).
12b. **Failure-mode row 6 of the design** ("parent's machine unknown ⇒ child refuses
    with the parent's reason"), which no other DoD item reaches: a parent pinned to a
    machine that does not exist in the inventory spawns a delegated child; the child's
    refusal text is `renderTargetError`'s `TargetUnknownMachine` for the **parent's**
    pinned name (inherited verbatim per D9), not a fresh resolution against `default`.
    A test that only asserted "the child fails" would pass on an implementation that
    silently fell back to `default` and then failed for an unrelated reason.
12c. **Failure-mode row 7** ("machine unreachable / host-key mismatch ⇒ unchanged
    structured `ExecError`; the session stays usable"): recorded as a **no-regression**
    item — `HostKeyAdoptionSpec`, `ExecCacheSpec` and `RemoteSpec` pass unmodified, and
    a turn against a fake runner returning `Left ExecRemoteUnreachable` yields a turn
    error whose text is the `ExecError` (not a `TargetError`), after which a subsequent
    turn with a reachable runner succeeds (the session is not bricked).
13. **The 101-site sweep is complete, and the count is the gate.** The command is
    `grep -rnE '\bnewSession(Meta)?[[:space:](]' --include=*.hs src test | grep -vE '^src/Seal/Session/Store.hs:(86|92|103):'`
    — `-E`, because the earlier draft used a BRE where `\(` is a *group operator*, so the
    pattern silently meant "`newSession ` or `newSessionMeta `" and did not do what the DoD
    claimed. Baseline **101** is recorded above, per file. After the change: the same 101
    sites exist (each now passing `Nothing` or a pin), and the compiler — not a list —
    proves the sweep, because the added parameter is non-optional under `-Werror`.
    **This count is a different population from WU-3's 77 `SessionMeta` construction
    sites**; do not conflate them. Paste both numbers in the commit message.
14. **The additivity proof — the DoD that makes §3.1 un-regressible.** Two assertions,
    both required:
    **(a) read path.** A fixture with `security.toml` carrying
    `[untrusted_execution] mode = "remote"` + a full `[untrusted_execution.remote]` block,
    **no** `execution.toml`, and a session with `smExecMachine = Nothing` must produce a
    **remote** `SessionExec` whose argv, captured by `mkFakeRemoteRunnerRecording`, names
    `exec.internal` — never the local cache workdir.
    **(b) creation path.** Creating a session with **no** pin on that same fixture must
    write `session.json` with **`exec_machine` absent/`null`** — *not* `"local"`. Then that
    new session's first turn must still produce the `exec.internal` argv.
    Assert on the recorded argv, not on a `Bool`. **(b) is the one that catches the
    regression re-entering through creation**; an earlier draft only had (a), which passes
    on an implementation that stamps `local` onto every new session.
    Write both **first**, confirm they pass on the unmodified tree, then keep them green.
12b. **Failure-mode row 6 of the design** ("parent's machine unknown ⇒ child refuses
    with the parent's reason"), which no other DoD item reaches: a parent pinned to a
    machine that does not exist in the inventory spawns a delegated child; the child's
    refusal text is `renderTargetError`'s `TargetUnknownMachine` for the **parent's**
    pinned name (inherited verbatim per D9), not a fresh resolution against `default`.
    A test that only asserted "the child fails" would pass on an implementation that
    silently fell back to `default` and then failed for an unrelated reason.
12c. **Failure-mode row 7** ("machine unreachable / host-key mismatch ⇒ unchanged
    structured `ExecError`; the session stays usable"): recorded as a **no-regression**
    item — `HostKeyAdoptionSpec`, `ExecCacheSpec` and `RemoteSpec` pass unmodified, and
    a turn against a fake runner returning `Left ExecRemoteUnreachable` yields a turn
    error whose text is the `ExecError` (not a `TargetError`), after which a subsequent
    turn with a reachable runner succeeds (the session is not bricked).
13. **The 101-site sweep is complete, and the count is the gate.** The command is
    `grep -rnE '\bnewSession(Meta)?[[:space:](]' --include=*.hs src test | grep -vE '^src/Seal/Session/Store.hs:(86|92|103):'`
    — `-E`, because the earlier draft used a BRE where `\(` is a *group operator*, so the
    pattern silently meant "`newSession ` or `newSessionMeta `" and did not do what the DoD
    claimed. Baseline **101** is recorded above, per file. After the change: the same 101
    sites exist (each now passing `Nothing` or a pin), and the compiler — not a list —
    proves the sweep, because the added parameter is non-optional under `-Werror`.
    **This count is a different population from WU-3's 77 `SessionMeta` construction
    sites**; do not conflate them. Paste both numbers in the commit message.
15. A session **with** `smExecMachine = Just "builder"` produces an argv naming
    `builder.example.com`; a session with `smExecMachine = Nothing` and
    `mode = "remote"` still produces the `exec.internal` argv. **Both assertions in one
    test**, because a test that only checks the pinned case would pass on an
    implementation that broke the unpinned one — that is exactly the §3.1 shape.
16. **Exactly one signature changes, and the counts are the gate.** Assert:
    (a) `cachedSessionExec`'s type is **unchanged** — `git diff` shows no change to its
    signature line, and `test/Seal/Session/ExecCacheSpec.hs` is **byte-identical** (its
    **10** `cachedSessionExec` calls at `:48,50,61,63,72,74,83,84,96,99` must still compile
    verbatim; if that file needed editing, a parameter was added that did not need to be);
    (b) `mkSessionExec` gains exactly one parameter and its **3** call sites —
    `ExecCache.hs:113`, `Workdir.hs:312`, `API.hs:1656` — are all updated in this commit;
    (c) `TurnDeps` is untouched: `grep -n 'tdResolvedTarget' src` returns nothing, and
    `Send.hs` is byte-identical.
    Record all three counts (10 / 3 / 0) in the commit message.
16b. **`sshConfigFromMachine` is total.** A QuickCheck property over `SshMachineSpec`
    values built through the smart constructors: `sshConfigFromMachine s` never throws and
    its `scWorkspace` round-trips to a non-empty `RemotePath`. This closes the one fallible
    conversion in the projection.17. Full suite green; `hlint` clean.

**File scope:** `src/Seal/Session/Meta.hs`, `src/Seal/Session/Store.hs`,
`src/Seal/Command/New.hs`, `src-gateway-types/Seal/Gateway/Types/NewArgs.hs`,
`src/Seal/Channel/Cli.hs`, `src/Seal/Command/Serve.hs` (the `newSession*` call sites only
— the 101-site sweep demands it), `src/Seal/Session/ExecCache.hs` (reads the pin; three-case body),
`src/Seal/Session/Workdir.hs` (the remote arm's `SshConfig` parameter — see §3.1),
`src/Seal/Gateway/API.hs` (the `handleTabNew` arm and the branch arm only),
`src/Seal/Gateway/SessionJson.hs`, `src/Seal/Agent/Runtime/Delegation/Worker.hs`,
`src/Seal/Core/TurnEngine.hs` (`fallbackMeta` only), `src/Seal/ISA/Ops/Session.hs`
(the new-session arm only), `test/Seal/Command/NewSpec.hs`,
`test/Seal/Session/MetaSpec.hs`, `test/Seal/Gateway/ApiSpec.hs`,
`test/Seal/ISA/Ops/SessionSpec.hs`, `test/Seal/Agent/Runtime/Delegation/WorkerSpec.hs`,
`test/Seal/Session/BranchSpec.hs`, `test/Seal/Session/SearchSpec.hs`,
`test/Seal/Session/StoreSpec.hs`, `test/Seal/Command/SessionSpec.hs`.

**Depends:** WU-1a, WU-1b, WU-2, WU-3.

**Checkpoint A:** **yes.** Present the falsification demo (DoD 5) and wait. This is
the design's two-week clock; the report must say so explicitly and restate the
operator decision the clock encodes.

---

---

## 3.1 The security regression this milestone nearly shipped (do not re-introduce it)

An earlier revision of WU-4 made the pin reach the executor through a bridge,
`securityConfigForTarget :: ResolvedTarget -> SecurityConfig -> SecurityConfig`, added as
an unexported helper in `TurnEngine` alongside a new `TurnDeps` field
`tdResolvedTarget`. **It would have silently moved untrusted execution from a remote
machine onto the harness box** for every existing remote deployment. The chain, verified
against the tree:

1. `execution.toml` does not exist on any existing install — creating it is Milestone B's
   migration (`B` WU-2b item 11). So `ExecutionConfig` is empty.
2. `resolveTarget` row 1 (`design` D4) answers `TargetLocal` when the config is empty and
   `allowLocal` is true — which is the default.
3. The bridge set `scUntrustedExec = Nothing` for a `WhereLocal` target.
4. `untrustedExecConfigFromSecurity` (`Security.hs:761–771`) then returns `Nothing`,
   **discarding the operator's `mode = "remote"` entirely**.
5. `mkSessionExec` (`Workdir.hs:181–190`) takes its `Nothing` arm → `mkLocalUntrustedIO`.
6. Untrusted code that ran on the remote box now runs on the harness box, for a user who
   never passed `--machine` and changed no configuration.

That directly contradicts D2 (the operator's security decision is authoritative), the
milestone's own additivity claim, and the design's central sentence — *untested code must
not execute on this kernel*. It also could not have been caught by the existing suite:
no spec drives a `mode=remote` turn through that path.

**The rule that prevents it, and that any future revision must keep:** with **no pin**, A
must behave *exactly* as today, consulting `mode` unchanged. A pin may only ever *add* a
target; it may never cause the security config to be ignored. The current design satisfies
this by resolving inside `cachedSessionExec` and leaving `SecurityConfig` untouched when
`smExecMachine` is `Nothing` — the only branch that exists for every pre-existing session.

A **second** rejected design is worth recording, because it looked safer and was still
wrong: threading `Maybe MachineName` through `cachedSessionExec`/`mkSessionExec`. It is not
unsafe like the first, but it changes a signature with 16 `cachedSessionExec` calls (10 in
`ExecCacheSpec.hs`) plus 3 `mkSessionExec` calls — reproducing the exact defect that made
the *first* review round fail. The adopted design reads the pin inside the cache and leaves
`cachedSessionExec`'s type alone; only `mkSessionExec` gains one parameter, at 3 call sites,
all in scope.

**A third and fourth route were found later, both in the same unit, both by the same rule:**

- **Creation path.** Persisting `loadAndResolveTargetIO`'s *result* stamped
  `exec_machine = "local"` onto every new session on a legacy install, after which the pin
  case ignored `mode`. Fixed by persisting **the request, not the resolution** (C9).
- **Inheritance.** Copying the parent's "resolved" machine did the same thing one level
  down, for every child and handoff of an unpinned session. Fixed by copying the parent's
  `exec_machine` **value**.

The general rule, which is what should be checked rather than the individual cases:
**anywhere A converts a `Nothing` into a machine name, it can produce `local` and thereby
bypass `mode`.** There are four such places — read, signature (rejected), creation,
inheritance — and all four are now either absent or guarded.

**DoD items assert the safety property** directly (WU-4 DoD 14, both paths) and the
no-signature-change property (DoD 16).

---

## 4. Checkpoint A — END OF MILESTONE A (stop here)

This is not a progress report; it is the **milestone boundary**, and the design's
falsification test.

Present, then **stop and wait**:

1. The demo (WU-4 DoD 5): `/new --machine builder` on a fixture inventory, the
   `session.json` diff showing `"exec_machine": "builder"`, and the composed ssh argv
   captured from the recording fake showing `builder.example.com`.
2. The DoD evidence table for WU-1a..WU-4, including the measured baselines
   (77 SessionMeta sites; 4868 tests / 43 pending at branch point).
3. The explicit statement of the decision the clock encodes: *if nobody pins a
   non-default machine within two weeks, Milestone B drops the picker (WU-8) or does
   not happen at all — and nothing here has to be undone, because A is additive.*

**Do not begin Milestone B without an answer.** B's first unit deletes `mode`, which is
the only working runtime backstop today; starting it while A's premise is unvalidated
would spend the reversibility this milestone was designed to preserve.

## 5. Security considerations for A

A adds **no** new authority. It cannot: every path it writes to is already
operator-writable, and it deletes nothing.

| Boundary | Input | Validation | WU |
|---|---|---|---|
| `execution.toml` (agent-writable) → argv | `host` / `user` | `mkSshHost` / `mkSshUser` (reject control, space, colon) | 2 |
| ″ | `port` | 1..65535 (D12; the pre-existing `fromMaybe 22` had no range check) | 2 |
| ″ | `identity` / `known_hosts` | `KeyFilePath`: absolute, no `..`, canonicalised, `blockedNames` except `~/.ssh`/`~/.seal` (D8) | 1a/1b |
| ″ | `workspace` | `WorkspaceRoot'`: absolute, no `..`, root's own segments blocked-name clean (D7) | 1a |
| ″ | machine `<name>` | `MachineName` charset, at decode **and** every API entry | 1a/2 |
| session pin → exec | `exec_machine` | tolerant decode; validated at creation; **no opcode may set it** (D9) | 4 |
| ssh argv | `~/.ssh/config` | `-F /dev/null -o ProxyCommand=none -o ProxyJump=none` (D6) — **a deliberate behaviour change for existing remote users, not merely validation** | 1c |

**What A deliberately does NOT yet do,** and why that is safe:

- `mkSessionExec` still takes a `SecurityConfig` and re-derives local-vs-remote
  internally — the bypass *shape* D11 calls out. It is not exploitable differently from
  today, because `mode` still exists and is still enforced; the shape is removed in
  **B's** WU-2b, which is the unit that makes `mode` disappear.
- WU-4's bridge (`securityConfigForTarget`, an unexported helper in `TurnEngine`)
  rewrites only `scUntrustedExec` at one call site so the pin reaches the executor.
  **B deletes it**, with a grep proving it gone.
- `allow_local` is parsed (WU-2) and **enforced at session creation only** (WU-4 DoD 7:
  pinning `local` while `allow_local = false` is a `400`). It is *not* yet enforced on the
  per-turn exec path, because that path still resolves through `mode`; the resolve-time
  enforcement and the hardened-build coercion are B's WU-2b. Stated as a deliberate
  half-measure rather than an oversight: creation-time is where a human is present to read
  the refusal.

## 6. External dependencies

**None.** No API keys, no services, no network at test time: every SSH interaction in
the specs goes through `mkFakeRemoteRunner`/`mkFakeRemoteRunnerRecording`. `ssh-keygen` is
required by the existing `ApiTestHarness` fixture generator, not by anything A adds.

## 7. Out of scope for A

Everything in the full plan's §9, plus all of Milestone B: deleting `mode`, the
migration, the hardened-build coercion re-point, the `*IsRemote` flag removal, the
gateway API (`/api/machines`, `PUT /machine`, `/session machine`), the frontend picker
and refusal UI, the docs/template rewrite. Issues **#347** and **#348** remain out of
scope for the whole feature.

## 8. Execution method

`orchestrated-execution`'s 4-phase loop per unit (IMPLEMENT → VALIDATE → ADVERSARIAL
REVIEW with a **fresh** reviewer → COMMIT), `make check` as the VALIDATE gate. Method
choice (orchestrated vs. subagent vs. parallel session) is confirmed with the operator
before starting, per AGENTS.md.
