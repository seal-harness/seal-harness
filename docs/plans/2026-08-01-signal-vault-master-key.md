# Plan: Signal channel secrets via vault-supplied master key

**Branch:** `feat/signal-vault-master-key`
**Design reference (signal-cli fork):** `~/code/signal-cli/docs/ENCRYPTED_STORAGE.md`
**Precondition:** the `mightybyte/signal-cli` fork ships `--master-key-fd <N>`
per the design doc above. **Do not start implementation until that fork is
released and on Seal's `PATH`** — every work unit below assumes the flag
exists. A preflight `signal-cli --help | grep -- --master-key-fd` gate is
W0.

---

## Summary

Store the signal-cli account-encryption master key in the Seal vault (not on
disk, not in `environ`, not in `ps`). On `seal signal` startup, Seal reads
the key from the vault, opens a pipe, passes the read end to signal-cli as
fd 3, and adds `--master-key-fd 3` to the signal-cli argv. signal-cli
encrypts its account JSON + SQLite DB with that key; the cleartext never
touches disk after first run. Mirrors the existing Telegram bot-token
pattern (`telegramVaultKey` / `VaultStore`) so the setup wizard writes the
key and runtime reads it.

The work is entirely on the Seal side — the fork does the encryption.

## Threat model (post-change)

| Threat | Before | After |
|---|---|---|
| Disk read (stolen laptop, backup) | All signal-cli secrets cleartext on disk | Ciphertext on disk; key in vault, not on disk |
| `ps` / `environ` snooping | N/A | Key in pipe kernel buffer only, never in args/env |
| Vault unavailable at startup | N/A | Graceful fallback to cleartext (with warning), same as Telegram today |

## In scope

- Seal generates a 32-byte master key on first Signal setup, stores it in the
  vault under `SIGNAL_MASTER_KEY`.
- `seal signal` startup reads the key from the vault, opens a pipe, passes
  the read end as fd 3, and adds `--master-key-fd 3` to the signal-cli argv.
- Setup wizard (`/channel signal`) gains a "store the master key in the
  vault" step, mirroring `/channel telegram`'s vault-write step.
- Graceful fallback: if the vault is unavailable, `seal signal` runs signal-cli
  **without** `--master-key-fd` (cleartext) with a warning — same shape as the
  Telegram wizard's "vault not set up" path. Never a hard failure.

## Out of scope

- Any change to the `mightybyte/signal-cli` fork (covered by the design doc).
- Reading signal-cli's account label from the vault (the stubbed CPS at
  `Run.hs:294-295`). This is a separate, smaller win that does NOT protect
  the private keys; it can be a follow-up and is deliberately not bundled
  here to keep this change reviewable.
- OS-keyring integration (the fork's `KeyringMasterKeyProvider` stub is the
  future extension point; Seal's vault is our key source).

## Construction-site notes (adding fields breaks these)

- `SignalTransport` / `mkRealSignalTransport` (`src/Seal/Channels/Signal/Transport.hs:80`) —
  gains an fd-3 plumbing arg. Call sites: `src/Seal/Channels/Signal/Run.hs:80`,
  the wizard's `scReceiveSender`/`scLink`/`scRegister`/`scVerify` sites in
  `src/Seal/Command/Channel.hs` (these are one-shot reads, NOT the jsonRpc
  long-running transport — they don't need the key; see W3).
- `ChannelRuntime` (`src/Seal/Command/Channel.hs:80`) — the wizard runtime
  already carries `crVaultStore`; reused, no new field needed.
- `SignalConfig` (`src/Seal/Signal/Config.hs`) — gains a `signalVaultKey`
  constant (mirroring `telegramVaultKey`).

## Vault key

```haskell
-- src/Seal/Signal/Config.hs
signalVaultKey :: Text
signalVaultKey = "SIGNAL_MASTER_KEY"
```

32 random bytes stored via `vsStore`. Mirrors `telegramVaultKey` exactly.

---

## Work units (RED-GREEN, `make check` gate)

Dependency order: **W0 → (W1, W2 parallel) → W3 → W4 → W5**

### W0 — Preflight gate: fork has `--master-key-fd`

**Why:** every later work unit assumes the fork flag exists. Starting
implementation against stock signal-cli would produce code that can't be
exercised.

**Do:**
- `signal-cli --help | grep -- --master-key-fd` exits 0.
- `signal-cli --version` reports the fork's build (not stock `0.14.5`).
- Record the fork version in `CHANGELOG.md` under an "Unreleased" section as
  a prerequisite.

**Gate:** the grep succeeds. If it fails, STOP and surface to the user — the
fork work isn't done yet.

**No tests** — this is a precondition check, not a code unit.

---

### W1 — `signalVaultKey` + vault read/write helpers (pure-ish, vault-backed)

**Why:** establish the vault key constant and the 32-byte generation + storage
before wiring the subprocess. Mirrors `telegramVaultKey` so the pattern is
identical and reviewers can diff against the Telegram path.

**Module:** `src/Seal/Signal/Config.hs` (new export), `src/Seal/Command/Channel.hs` (use).

**Changes:**
- Export `signalVaultKey :: Text` from `Seal.Signal.Config`.
- Add `generateSignalMasterKey :: IO ByteString` — 32 cryptographically
  random bytes. Use `crypto-api` / `entropy` / whatever the existing
  `Seal.Security.Vault.Age` key-gen uses (check `Vault/Age.hs` for the
  established primitive; do NOT pull a new RNG dep). If the codebase has no
  existing RNG, `Data.ByteString` + `System.Entropy` (`entropy` pkg) is the
  conventional choice — confirm it's already a dep before adding.
- The wizard's vault-write path: after `writeSignalConfig`, if the vault is
  available and the key is not already present, generate + store it. Reuse
  `vsStore` from `ChannelRuntime.crVaultStore`. Idempotent: `vhGet` first,
  skip if present.

**Tests** (`test/Seal/Signal/ConfigSpec.hs` — new or extended):
- `signalVaultKey == "SIGNAL_MASTER_KEY"`.
- `generateSignalMasterKey` returns 32 bytes; two calls differ (not
  constant; randomness works).
- Round-trip: store via a mock `VaultStore`, read back, bytes equal.

**Gate:** `make check` green; hlint clean.

---

### W2 — fd-3 pipe plumbing in `mkRealSignalTransport`

**Why:** the subprocess needs an extra inherited fd. This is the
lowest-level Haskell change and the one most likely to have a portable-fd
surprise; isolate it.

**Module:** `src/Seal/Channels/Signal/Transport.hs`.

**Changes to `mkRealSignalTransport`:**
- New signature: `mkRealSignalTransport :: Maybe ByteString -> Text -> IO (Either Text SignalTransport)`
  where the first arg is `Just key` (32 bytes) or `Nothing` (cleartext mode).
- When `Just key`:
  1. Create a pipe (`createPipe` from `System.Posix.IO` or
     `System.Process`'s `UsePipe` on a custom `std_err`-style field — see
     implementation note below).
  2. Write exactly the 32 key bytes to the write end, then close the write
     end in the parent immediately (the child reads once and closes).
  3. Pass the read end as fd 3 to the child via `CreateProcess.delegate_ctlc`
     is irrelevant — use the `System.Posix.IO` approach: `dup` the read end
     to fd 3 in the child before `execve`, OR use the
     `createProcess` + `UseHandle` on a specifically-numbered fd via
     `System.Process.Internals` / a custom `CreateProcess` extension.
     **Implementation note:** `System.Process` does not expose a
     "pass this handle as fd N" option directly. The portable approach is
     to wrap signal-cli in a tiny shell helper OR use the
     `unix` package's `dup2` in a `forkProcess`/`executeFile` pre-exec
     hook. **Resolve this in W2 before proceeding** — it's the riskiest
     portable-fd detail. The cleanest pure-Haskell option is likely
     `System.Process.createProcess` with `std_in = UseHandle readEnd` is
     NOT viable (that's fd 0). Investigate `System.Posix.Process.forkProcess`
     + `executeFile` with the read end pre-dup'd to fd 3. If that's too
     invasive, the fallback is a `sh -c 'exec signal-cli --master-key-fd 3 ...'`
     wrapper with fd 3 set up via a here-string + redirection — but that
     reintroduces shell wrapping, which the codebase explicitly avoids
     (see `docs/superpowers/plans/2026-07-06-phase-2b-signal-channel.md:72`:
     "No shell-wrapping"). **Prefer the forkProcess + dup2 path; fall back to
     shell only if that proves unworkable, and document the deviation.**
  4. Add `--master-key-fd 3` to the argv at `Transport.hs:88`.
- When `Nothing`: argv unchanged; no pipe. Today's behavior.

**Tests** (`test/Seal/Channels/Signal/TransportSpec.hs` — extend):
- `mkRealSignalTransport Nothing account` produces an argv WITHOUT
  `--master-key-fd` (assert via a seam — see testability note).
- `mkRealSignalTransport (Just key) account` produces an argv WITH
  `--master-key-fd 3` and the key is written to the pipe read end. **This
  requires either** (a) a test-only seam that exposes the argv + the
  write-end action without spawning signal-cli, or (b) a mock binary. Prefer
  (a): refactor `mkRealSignalTransport` to delegate to a pure
  `signalCliArgs :: Maybe ByteString -> Text -> [String]` and a separate
  `withMasterKeyPipe :: ByteString -> (Handle -> IO a) -> IO a`; test both
  in isolation.
- Property: for any 32-byte key, the bytes reaching fd 3 equal the input.

**Testability note:** the existing `mkRealSignalTransport` shells out
directly; tests use `mkMockSignalTransport` and never call the real one. To
make W2 testable without a real signal-cli binary, extract the argv
construction + pipe logic into testable pure/small-IO helpers as above.
Keep `mkRealSignalTransport` as the thin IO shell over them.

**Gate:** `make check` green; hlint clean; no shell wrapping introduced
unless W2 explicitly documents why.

---

### W3 — Thread the vault key through `seal signal` startup

**Why:** connect W1 (vault read) to W2 (transport) at the `seal signal`
startup site.

**Module:** `src/Seal/Channels/Signal/Run.hs`.

**Changes to `runSignalMain` (`Run.hs:242`) and `runSignal` (`Run.hs:73`):**
- After `tryOpenVault` (`Run.hs:259`) resolves `mHandle`, read the master key:
  ```haskell
  mMasterKey <- case mHandle of
    Nothing -> pure Nothing
    Just vh -> do
      r <- Vault.vhGet vh signalVaultKey
      pure $ case r of
        Right bs | BS.length bs == 32 -> Just bs
        _                             -> Nothing
  ```
- Thread `mMasterKey` into `runSignal` → `mkRealSignalTransport mMasterKey accountLabel`
  (`Run.hs:80`).
- If `mHandle` is `Nothing` (vault unavailable) OR the key is absent/short,
  pass `Nothing` to `mkRealSignalTransport` and log a warning:
  `"vault unavailable; signal-cli account data will be stored in cleartext"`.
  This is the graceful-fallback path — never a hard failure.

**Important scope boundary:** the wizard's one-shot signal-cli calls
(`scLink`, `scRegister`, `scVerify`, `scReceiveSender`, `scListAccounts` in
`Command/Channel.hs`) are NOT the long-running `jsonRpc` transport and do NOT
load the account file the same way — `register`/`verify` create a fresh
account, `link` provisions. They do **not** need `--master-key-fd` to
function. Do NOT thread the key into `SignalCli`/`mkRealSignalCli`. Only the
`jsonRpc` transport (used by the actual `seal signal` runtime loop) needs
the key. If, during implementation, a wizard subcommand turns out to read
the encrypted account file and fails, that's a fork-side concern (the
wizard would need to pass the key too) — surface it, don't speculatively
thread it everywhere.

**Tests** (`test/Seal/Channels/Signal/RunSpec.hs` — extend or new):
- With a mock vault containing `SIGNAL_MASTER_KEY` → 32 bytes,
  `runSignal` passes `Just key` to the transport (assert via a mock
  `SignalTransport` factory captured in the test).
- With no vault → `runSignal` passes `Nothing` and logs the warning.
- With a vault but a short/missing key → `Nothing` + warning.

**Gate:** `make check` green; hlint clean.

---

### W4 — Wizard: generate + store the master key on first setup

**Why:** the key has to exist in the vault before `seal signal` can read
it. This is the user-facing entry point, mirroring `/channel telegram`.

**Module:** `src/Seal/Command/Channel.hs` (the Signal wizard, near
`writeSignalConfig` at `Channel.hs:363`).

**Changes to `writeSignalConfig` (or a new `ensureSignalMasterKey` called after it):**
- After writing the `[signal]` config, if the vault is available
  (`vsAvailable (crVaultStore rt)`):
  1. Check if `SIGNAL_MASTER_KEY` is already present (`vhGet` via the
     vault handle — but note `VaultStore` only exposes `vsStore`, not
     `vsGet`; see below).
  2. If absent, `generateSignalMasterKey` (W1) and `vsStore signalVaultKey key`.
  3. Confirm to the user: `"Master key stored in vault (key: SIGNAL_MASTER_KEY) — signal-cli account data will be encrypted at rest."`
- If the vault is NOT available:
  - Warn: `"Vault is not set up. signal-cli account data will be stored in cleartext. Run /vault setup, then /channel signal again to enable encryption."`
  - Do NOT block — the account still works (cleartext fallback). Same UX as
    the Telegram wizard's vault-unavailable path (`Channel.hs:479-485`).

**VaultStore seam gap:** `VaultStore` (`Channel.hs:91`) exposes `vsStore` and
`vsAvailable` but NOT `vsGet`. To make the idempotent check ("only generate
if absent") work, either:
- (a) Add `vsGet :: Text -> IO (Either Text (Maybe ByteString))` to the
  `VaultStore` record and implement it in `mkRealVaultStore` / `noVaultStore`
  (small, mirrors `vhGet` on `VaultHandle`). **Preferred** — keeps the seam
  honest and is useful for the runtime read path too.
- (b) Skip the idempotent check and always overwrite — simpler but
  regenerates the key on every wizard run, which would orphan the previous
  encrypted account file (the user could no longer decrypt it). **Do NOT
  do this** — silent key rotation on re-setup is a footgun.

Go with (a). Add `vsGet` to `VaultStore` in this work unit; update
`mkRealVaultStore`, `noVaultStore`, and the wizard's Telegram path is
unaffected (it doesn't read, only writes).

**Tests** (`test/Seal/Command/ChannelSpec.hs` — extend):
- With a mock `VaultStore` that returns `Nothing` for `vsGet SIGNAL_MASTER_KEY`:
  wizard calls `vsStore SIGNAL_MASTER_KEY <32 bytes>` exactly once.
- With a mock that returns `Just existingKey`: wizard does NOT call `vsStore`
  (idempotent — existing encrypted account stays decryptable).
- With `vsAvailable = False`: wizard does not call `vsGet`/`vsStore`, shows
  the cleartext warning, does not fail.
- Telegram wizard path is unchanged (regression guard: its tests still pass).

**Gate:** `make check` green; hlint clean.

---

### W5 — Docs + CHANGELOG + final `make check`

**Why:** the user-facing surface changes (a new vault key, a new behavior on
first run). Document it.

**Changes:**
- `CHANGELOG.md`: under "Unreleased", add the feature + the signal-cli fork
  version prerequisite (from W0).
- `docs/`: if there's a Signal-channel setup doc, add a "Secret storage" note
  pointing at the vault and the cleartext-fallback caveat. (Don't create new
  docs speculatively — only update existing.)
- `AGENTS.md`: no change (this is a feature, not a project-notes item).
- Run `make check` end-to-end one final time.

**Gate:** `make check` green; hlint clean; CHANGELOG updated.

---

## Acceptance criteria (Definition of Done)

1. A 32-byte `SIGNAL_MASTER_KEY` lives in the Seal vault after `/channel
   signal` setup (when the vault is available).
2. `seal signal` reads the key from the vault and passes it to signal-cli
   via fd 3 (`--master-key-fd 3`); the key is never in `environ` or argv.
3. With the vault available, signal-cli's account JSON + SQLite DB are
   encrypted at rest (verified by inspecting
   `~/.local/share/signal-cli/data/<number>` — starts with the fork's
   encryption magic, not `{`).
4. With the vault unavailable, `seal signal` runs in cleartext mode with a
   logged warning; no hard failure.
5. Re-running `/channel signal` with an existing key does NOT regenerate it
   (idempotent — existing encrypted data stays decryptable).
6. `make check` passes; hlint clean; no new shell-wrapping introduced.
7. The Telegram channel and all other channels are unaffected (regression
   suite green).

## Human checkpoints (pause for review)

- After W2 (the fd-3 plumbing approach is settled — the riskiest piece;
  confirm the forkProcess/dup2 path vs. any shell fallback before proceeding).
- After W4 (wizard UX — confirm the cleartext-fallback warning wording and
  that the idempotent check works as intended before the final pass).

## Test verification

- `make check` is the gate (Haskell/cabal; per `AGENTS.md` the
  `.coverage-thresholds.json` enforcement command is `make test`).
- Focused runs during development:
  - `nix develop -c cabal test --test-options='-m "Seal.Signal.Config"'`
  - `nix develop -c cabal test --test-options='-m "Seal.Channels.Signal"'`
  - `nix develop -c cabal test --test-options='-m "Seal.Command.Channel"'`
- Final: `nix develop -c cabal test` (all), `nix develop -c hlint src/Seal/Signal/Config.hs src/Seal/Channels/Signal/Transport.hs src/Seal/Channels/Signal/Run.hs src/Seal/Command/Channel.hs`.

## Out of scope / future work

- **Account label from vault** (`Run.hs:294-295` stubbed CPS): a separate,
  smaller win that does NOT protect private keys. Track separately.
- **OS-keyring path**: the fork's `KeyringMasterKeyProvider` stub is the
  extension point; Seal's vault is our key source. If a downstream user
  wants the OS keyring, they implement the fork stub and Seal is
  uninvolved.
- **`--decrypt-storage`**: if the fork adds it, a future Seal command could
  expose it; not needed for this feature.