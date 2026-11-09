# TLS certificate lifetimes — Part 1 (rev 4)

<!-- status: ready for implementation approval -->
<!-- date: 2026-11-05 -->
<!-- branch: gateway/passkey-access-control (stacks on PR #289) -->
<!-- source spec: seal-harness-tls-certs-task.md, Part 1 (external doc, not in this repo) -->
<!-- rev 2: added interface enumeration, dropped auto-rotation, restructured WUs. -->
<!-- rev 3: deps moved to WU-1, exact s_client prerequisites, non-goals, rollback, edge cases. -->
<!-- rev 4: operator approved replacing existing certs; end-to-end SAN check moved into WU-1; -->
<!--        ownership ADT and clock-skew rule dropped; regeneration falls back instead of -->
<!--        refusing to boot; operator-path generation left exactly as today. -->

## 0. Operator decisions

| Decision | Answer | Consequence |
|---|---|---|
| May Part 1 replace an existing, already-trusted 10-year certificate on first boot after upgrade? | **Yes** (2026-11-05) | Existing installs get a legal certificate instead of keeping the broken one forever. Cost: one re-trust per device, once. The replaced pair is kept as `*.bak` so it is reversible. |

## 1. Scope and non-goals

**In scope** — make the *generated* certificate a legal one: a validity window
browsers accept, and a SAN set covering every name and address the gateway is
reached at. Chrome/WebKit reject a certificate whose validity exceeds 398 days
(`ERR_CERT_VALIDITY_TOO_LONG`) and reject a missing/incorrect SAN
(`ERR_CERT_COMMON_NAME_INVALID`); both are hard failures, not interstitials.

**Non-goals (guards — the spec forbids these explicitly):**

| Prohibited | How this plan keeps it true |
|---|---|
| Changing the DNS namespace, CoreDNS config, or zone files | No DNS/zone file appears in any work unit's file list (§6). The work is confined to the PEM pair and its SAN list. |
| Removing TLS, or falling back to plain HTTP | `tlsEnabled` (`Seal/Gateway/Config.hs:128-129`) and the `runTLS` call (`Seal/Gateway/Server.hs:312`) are untouched. With `tls = false` the plain-HTTP path is unchanged, and no code path writes `tls = false`. WU-1 DoD 9 pins this. |

**Out of scope** — Part 2: root CA + short-lived leaf, `seal trust`,
per-platform trust-store installation, stale-anchor removal, automatic leaf
rotation. Recorded in §9.

## 2. What the code is today

The certificate feature is **not on `main`**; it lives on
`gateway/passkey-access-control` (draft PR #289), which this work stacks on.

Single generation site — the audit the spec asks for first:

| Site | Call |
|---|---|
| `src/Seal/Security/TlsCert.hs:74` | the only `openssl` invocation in the repo |
| `src/Seal/Command/Serve.hs:187` | its only caller (`ensureTlsCertificate`) |
| `test/Seal/Security/TlsCertSpec.hs` | calls the same function; no fixture or independent builder |

No dev/prod/mTLS split, no second hard-coded day count, no other `openssl`
call (repo-wide grep for `openssl|3650|subjectAltName|mkcert` — hits only
`TlsCert.hs:74,91,120`, `Serve.hs:179` prose, README/CHANGELOG prose, and the
test's `findExecutable`). No mTLS/client-cert code exists.

Baseline on this branch: `cabal build all` clean; `cabal test` = 3674
examples, 0 failures, 41 pending.

## 3. Defects, with live evidence

I booted the current code in a scratch `SEAL_HOME`
(`[gateway] tls = true`, `[access_control] origin = "https://localhost:18443"`)
and inspected the pair it generated:

```
notBefore=Nov  5 17:26:40 2026 GMT
notAfter=Nov  2 17:26:40 2036 GMT       <- G1: 3650 days; every browser rejects this
subject= /CN=127.0.0.1
X509v3 Subject Alternative Name:
    IP Address:127.0.0.1, DNS:localhost   <- G2: no ::1, no machine name, no interfaces
```

**G1 — ten-year lifetime.** `TlsCert.hs:91` passes `"-days", "3650"`.

**G2 — incomplete SAN set.** `sanHostsFor` (`TlsCert.hs:42-48`) yields
`tls_hosts` ∪ bind host ∪ `localhost`.

**G3 — IPv6 misclassification.** `isIpv4` (`TlsCert.hs:132`) recognises only
dotted-quad, so `::1` would render as `DNS.::1` — a SAN that can never match.

**G4 — existing installs are never repaired** (found in recon; not in the
spec's bullets, approved as in-scope in §0). Generation only happens when a PEM
is missing (`TlsCert.hs:62-64`), so a 10-year certificate already on disk
survives the upgrade forever.

**G5 — the pair is never validated after generation.** A pair that does not
load (truncated write, cert with a different key) is discovered by warp-tls at
handshake time instead of at boot.

## 4. Verified in this environment

| Claim | Evidence |
|---|---|
| `-days 397` gives exactly a 397-day window | generated a pair; `notBefore`→`notAfter` delta = 397.0 days |
| `IP.n = ::1` and a ULA (`fd7a:…`) are accepted | SAN renders `IP Address:0:0:0:0:0:0:0:1`, `IP Address:FD7A:115C:A1E0:…` |
| **The dev shell's `openssl` is LibreSSL 3.3.6** (`/usr/bin/openssl`), not OpenSSL 3.x | `openssl version`; it accepts the config-file form and `-days 397`, which is why `TlsCert.hs` already uses a config file instead of `-addext` |
| **LibreSSL has no `openssl x509 -ext`** | `unknown option -ext`; acceptance must use `-text -noout` (or a library parse) on macOS |
| `crypton-x509-1.9.1` exposes `Data.X509.File.readSignedObject`; `certValidity :: (DateTime, DateTime)`; `ExtSubjectAltName`/`AltNameDNS`/`AltNameIP` | ghci `:browse`/`:info`; `dist-newstyle/cache/plan.json` lists the version |
| `time-hourglass-0.3.0` exposes `Data.Hourglass`, `Time.Types` (`DateTime` = `Date`+`TimeOfDay`; `Date{dateYear::Int, dateMonth::Month, dateDay::Int}`) | `ghc-pkg field time-hourglass exposed-modules`; ghci `:info` |
| `Network.TLS.credentialLoadX509 :: FilePath -> FilePath -> IO (Either String Credential)` | ghci `:t` |
| `Network.Info.getNetworkInterfaces :: IO [NetworkInterface]`, `ipv4 :: IPv4`, `ipv6 :: IPv6` | ghci `:info` |
| `network-info-0.2.1` resolves and is **prebuilt** for this compiler | added the dep, `cabal build --dry-run`; nix copied `network-info-lib-network-info-0.2.1` from `cache.iog.io` (edit reverted) |
| `isIpLiteral` is already exported and handles v4 **and** `:`-containing v6 | `Seal/Security/AccessControl.hs:18` (export), `:103-110` |
| `[access_control] origin` is a hard prerequisite once TLS is on, and a scratch home with a https origin boots and generates | the boot in §3; `tlsOriginError` (`Seal/Gateway/Config.hs:162-172`) |

## 5. Design decisions

**D1 — lifetime constant.** `certificateLifetimeDays = 397` (not 398: the
browser limit is inclusive and tooling rounds differently). One binding feeds
both the `-days` argv and the validation bound.

**D2 — SAN inputs are explicit and pure.**

```haskell
data SanInputs = SanInputs
  { siConfigured  :: [Text]      -- ^ [gateway] tls_hosts, operator order
  , siBindHost    :: Text        -- ^ [gateway] host
  , siMachineName :: Text        -- ^ Network.Socket.getHostName
  , siOriginName  :: Maybe Text  -- ^ host of [access_control] origin
  , siAddresses   :: [Text]      -- ^ local interface addresses
  }

sanInputsFor :: GatewayConfig -> Text -> Maybe Text -> [Text] -> SanInputs
sanHostsFor  :: SanInputs -> [Text]

addressNamesFor      :: [NetworkInterface] -> [Text]   -- ^ pure filter
localAddressNames    :: IO [Text]
localAddressNamesWith :: IO [NetworkInterface] -> IO [Text]  -- ^ injectable
```

Result order (first entry becomes CN): configured → origin → bind host (unless
wildcard) → machine name → interface addresses → `localhost` → `127.0.0.1` →
`::1`; de-duplicated case-insensitively, empties and `0.0.0.0`/`::` dropped.

The enumeration is split so both halves are testable: `addressNamesFor` is pure
(filtering, de-duplication, zone-ID stripping), and `localAddressNamesWith`
takes the enumeration action so a failing enumeration is an assertable case
rather than prose. `localAddressNames = localAddressNamesWith getNetworkInterfaces`
and swallows enumeration failure to `[]` — a missing SAN must never stop boot.

**D3 — interface enumeration uses `network-info`** (new dependency: base-only,
read-only, BSD-3, prebuilt in the project's cache — §4). Alternatives rejected:
`network`'s `getNetworkInterfaces` (3.2.8.0) exposes names and flags but **no
addresses**, and `unix` has no `getifaddrs`, so the only other route was a
hand-written FFI `c-sources` shim — more code, and `sockaddr` parsing in a
security-adjacent path. Stated limit: `NetworkInterface` carries one `ipv4` and
one `ipv6` value, so two same-family addresses on one interface are invisible
to it; anything unusual can still be listed in `tls_hosts`.

**D4 — one SAN classifier, reusing the existing one.** `classifySanName` maps a
name to `SanDns`/`SanIp` (rendered `DNS.n`/`IP.n`) using the **already
exported** `Seal.Security.AccessControl.isIpLiteral`. Values are normalised
first — bracketed IPv6 (`[::1]`) has its brackets stripped, since
`isIpLiteral` accepts brackets but OpenSSL will not take them in an `IP.n`
entry.

**D5 — origin FQDN.** The passkey RP ID is the origin's host, so a certificate
that omits it fails every ceremony with no useful message. `Serve` loads
`SecurityConfig` at `Serve.hs:155`, before TLS generation at `:182-204`, so
`scAccessControl >>= acfcOrigin` is available. Host extraction lifts the
existing local `hostOf` (`AccessControl.hs:141`) to an export
`originHostOf :: Text -> Maybe Text` — one export, no second URL parser.

**D6 — two verbs, no ownership ADT.** Who owns the pair is a property of the
call site, not a value to thread around:

```haskell
-- | Seal owns the default paths: create when missing, replace when the pair
-- cannot serve a legal certificate.
ensureGeneratedCertificate :: FilePath -> FilePath -> [Text]
                           -> IO (Either Text TlsCertOutcome)

-- | Operator pointed tls_cert/tls_key somewhere: create when missing, exactly
-- as today; never validate, never replace.
ensureCertificateAt :: FilePath -> FilePath -> [Text]
                    -> IO (Either Text TlsCertOutcome)

data TlsCertOutcome
  = TlsCertCreated
  | TlsCertReplaced Text    -- ^ why the old pair was unacceptable
  | TlsCertUnchanged

certificateDefect :: (UTCTime, UTCTime) -> Maybe Text
pairLoads :: FilePath -> FilePath -> IO (Either Text ())
```

`certificateDefect` is pure and has exactly two rules: the window exceeds 397
days, or `notAfter` is not after `notBefore`. It does **not** act on expiry —
that is Part 2's rotation (§9). `pairLoads` uses
`Network.TLS.credentialLoadX509`, the exact loader warp-tls uses, so a broken
pair is found at boot.

**No new boot refusals.** If an owned pair is unacceptable but regeneration
fails (no `openssl`, disk error), and the existing pair *does* load, Seal logs
a warning and serves with the old pair — today's behaviour, minus the silence.
Boot is refused only in the cases where it is refused today.

**Operator paths are untouched.** `ensureCertificateAt` creates a missing pair
(exactly as the current code does) and never replaces an existing one: an
operator's real certificate may legitimately outlive 397 days.

Replacement keeps the old pair as `cert.pem.bak`/`key.pem.bak` (mode 0600),
logged and documented, so a bad replacement can be undone by hand. The `.bak`
pair is a single slot holding the most recently replaced pair, not a history.

**D7 — expiry is surfaced, not acted on.** When an owned pair has < 30 days
left, `Serve` warns with the expiry date and how to regenerate. Part 1 has no
rotation (that is Part 2), so without this the listener would one day start
failing with nothing in the log to explain it. Warning only: no behaviour
change.

**D8 — logging.** `TlsCertCreated` → info + the existing "install it on the
device" warning; `TlsCertReplaced reason` → warning naming the reason and the
`.bak` path, saying the certificate must be re-installed on devices; the
fall-back path (unacceptable but loadable, regeneration failed) → warning;
`TlsCertUnchanged` → debug.

## 6. Work units

Each unit ends with `make check` green. **WU-1 adds every dependency the work
needs** (library and test stanzas: `network-info`, `crypton-x509`,
`time-hourglass`, `tls`) so no unit depends on a later one.

Gate-strength note, stated rather than assumed: certificate-level tests are
guarded by `findExecutable "openssl"` (`TlsCertSpec.hs:14-18`) and `pendingWith`
otherwise, and the dev shell does not declare `openssl` as an input (it inherits
`/usr/bin/openssl`, LibreSSL 3.3.6, here). Pure tests always run; I will run
`cabal test` with openssl present and paste the non-pending results into the
PR, and CI on Linux exercises OpenSSL 3.x. No DoD claims openssl-independent
*generation* — only openssl-independent *assertions* (parsing the PEM, not
openssl's text output).

### WU-1 — SAN completeness (including interface addresses)

Files: `src/Seal/Security/TlsCert.hs`, `src/Seal/Security/AccessControl.hs`,
`src/Seal/Command/Serve.hs`, `src/Seal/Gateway/Config.hs` (the `gcTlsHosts`
haddock at `:40-41` describes the old semantics),
`test/Seal/Security/TlsCertSpec.hs`, `seal-harness.cabal` (library + test
`build-depends`).

DoD:
1. `sanHostsFor` with no configured hosts, wildcard bind, machine
   `arrakis.local`, addresses `["192.168.1.42","fd7a::5"]` →
   `["arrakis.local","192.168.1.42","fd7a::5","localhost","127.0.0.1","::1"]`.
2. Configured hosts stay first and de-duplicate case-insensitively.
3. Origin host appears when set and disappears when `Nothing`.
4. `::1`, `fd7a::5` and `[::1]` render `IP.n` (brackets stripped);
   `arrakis.local` renders `DNS.n`; asserted on the rendered OpenSSL config
   **and** on a generated certificate's SAN extension (`ExtSubjectAltName` →
   `AltNameDNS`/`AltNameIP`).
5. `addressNamesFor` drops `0.0.0.0`, `::`, zero/absent addresses and
   duplicates, and strips `%zone` suffixes; `localAddressNamesWith` returns
   `[]` when the enumeration action throws.
6. `sanInputsFor` maps each field from `GatewayConfig` plus its three
   arguments. (This is a pure mapping test: it proves the *shape* of the
   record, not that `Serve` calls it.) The call site is proven by DoD 7.
7. **End-to-end SAN assertion** — the check that actually fails if `Serve`
   passes the wrong inputs: boot a scratch `SEAL_HOME`
   (`[gateway] host = "127.0.0.1"`, `port = <free>`, `tls = true`,
   `[gateway] tls_hosts = ["seal.test"]`,
   `[access_control] origin = "https://localhost:<port>"`), then parse
   `keys/tls/cert.pem` and assert the SAN extension contains
   `DNS:localhost`, `IP:127.0.0.1`, `IP:::1`, `DNS:<machine hostname>`,
   `DNS:seal.test`, and `IP:<this machine's LAN address>`. Output pasted into
   the PR.
8. Existing `TlsCertSpec` cases updated for the new signature and default set;
   no test still asserts the old two-entry list.
9. `tls = false` is unchanged: `ConfigSpec`'s `tlsEnabled`/`tlsConfigError`
   cases still pass, and `Serve` enters the TLS block only when `tlsEnabled`.
10. `make check` green; `hlint` reports no hints.

### WU-2 — 397-day lifetime, existing-pair validation, replacement

Files: `src/Seal/Security/TlsCert.hs`, `src/Seal/Command/Serve.hs`,
`test/Seal/Security/TlsCertSpec.hs`.

DoD:
1. A generated pair's `notAfter − notBefore` ≤ 397 days, asserted by parsing the
   PEM (`certValidity`), not by parsing openssl's text output.
2. A 3650-day pair at the managed paths is replaced; the outcome names the
   397-day limit; `cert.pem.bak`/`key.pem.bak` hold the previous pair (0600).
3. An unparseable/truncated PEM is replaced, not fatal (no exception escapes).
4. A readable cert with a *different* key is replaced (`pairLoads` fails).
5. `ensureCertificateAt` with an existing 3650-day pair leaves it
   byte-identical and unvalidated; with a missing pair it creates one (today's
   behaviour, unchanged).
6. Regeneration failure with a loadable pair present serves the old pair and
   logs a warning (asserted on the pure message builder plus the returned
   outcome); with no loadable pair it returns `Left` (today's behaviour).
7. A pair with < 30 days left is kept (`TlsCertUnchanged`) and the D7 warning
   text is produced (pure message builder).
8. `certificateDefect`: exactly 397 → `Nothing`; 398 → `Just`; `notAfter` ≤
   `notBefore` → `Just`.
9. With no `openssl` on PATH, the fresh-install path returns `Left` carrying
   the install hint (via an internal `ensureTlsCertificateWith <binary>` seam,
   so the test need not mutate `PATH`).
10. No `.tmp` files are left behind on any path; key `0600`, directory `0700`.
11. Live endpoint: the scratch-home boot from WU-1 DoD 7 also answers
    `openssl s_client -connect 127.0.0.1:<port> -servername localhost`, and the
    presented chain shows the new dates. Output pasted into the PR.
12. `make check` green.

Operator checkpoints (not claimed here): loading `https://<hostname>:<port>` in
Chrome and in Safari with no interstitial requires trusting the certificate in
that browser's keychain — a system trust-store change I will not make
unilaterally. Listed as an operator step with the certificate path.

### WU-3 — Documentation

Files: `README.md`, `CHANGELOG.md`

DoD:
1. README: the generated certificate is valid 397 days and covers `localhost`,
   `127.0.0.1`, `::1`, the machine hostname, the origin's FQDN, every local
   interface address (LAN/VPN/overlay) and everything in `tls_hosts`; anything
   missed (`network-info` sees one address per family per interface) can be
   added to `tls_hosts`.
2. README extends the existing force-regenerate procedure (`README.md:315-318`)
   rather than replacing it, and states all replacement triggers: an owned pair
   is replaced at boot when its window exceeds 397 days, when `notAfter` is
   not after `notBefore`, or when it does not load; the previous pair is kept
   as `*.bak`; a
   fall-back warning is logged, and serving continues, if regeneration fails
   while the old pair still loads; `tls_cert`/`tls_key` pairs are never
   validated or replaced; a warning is logged within 30 days of expiry.
3. README acceptance snippets use `openssl x509 -noout -text` (LibreSSL has no
   `-ext`), noting the OpenSSL 3.x alternative.
4. CHANGELOG: upgrade note — existing installs keep the 10-year pair until the
   first boot on this version, which replaces it, so the new certificate must
   be trusted on every device again (Part 2 removes that step permanently);
   plus the `.bak` location and the note that reverting the code leaves the new
   pair in place (an existing pair is not regenerated on downgrade).
5. One-line non-goal statement: this change does not touch DNS/CoreDNS/zone
   files and does not remove TLS or add a plain-HTTP fallback.

## 7. Acceptance

Automated (`TlsCertSpec`, no dependence on openssl's text output):

- window ≤ 397 days; SAN set contains `DNS:localhost`, `IP:127.0.0.1`,
  `IP:::1`, `DNS:<machine>`, `DNS:<origin host>`, `DNS:<tls_hosts entry>`,
  `IP:<a local interface address>` (asserted on a certificate generated by the
  real boot path);
- legacy pair replaced with `.bak`; operator pair untouched; broken pair
  replaced; fall-back serves the old pair when regeneration fails.

Manual, recorded in the PR (LibreSSL-compatible):

```bash
openssl x509 -in <cert> -noout -dates -subject -issuer      # ≤ 397d
openssl x509 -in <cert> -noout -text | grep -A2 'Alternative Name'
openssl s_client -connect 127.0.0.1:<port> -servername localhost </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

## 8. Risks and open points

- **One re-trust per device on upgrade.** Approved in §0. The old pair is kept
  as `*.bak` so the change is reversible.
- **New dependency (`network-info`).** Base-only, read-only, BSD-3, prebuilt for
  this compiler. Only route to "all local interface addresses" without a
  hand-written FFI shim. Flagged for objection.
- **Date parsing vs a stored digest.** A "regenerate unless the pair records
  the inputs we would use now" digest would avoid
  `crypton-x509`/`time-hourglass` — considered and rejected: it cannot detect
  an expired or unloadable pair, needs its own sidecar format and migration,
  and Part 2's leaf rotation needs real date math regardless.
- **`openssl` is not in AGENTS.md's permitted-binary list** (`age`, `ssh`,
  `tmux`; `AGENTS.md:184-185`). Precedent: `Seal.Security.Vault.Age`;
  `TlsCert.hs` documents the fixed-argv justification. No new binary and no
  argv element built from request data. Flagged, not decided.
- **`-copy_extensions` (spec bullet) is dispositioned, not ignored**: Part 1
  generates with `req -x509` (self-signed, no CSR), so no extension-copy step
  exists; it applies to Part 2's CA-signed leaf and is recorded in §9.
- **A legal-but-stale SAN set is not refreshed** (e.g. a VPN interface that
  appears after generation, or an edited `tls_hosts`). Delete the pair and
  restart — documented in WU-3.

## 9. Recorded for Part 2 (not in scope)

- Root CA (~10 years, `0600` key) + ≤397-day leaf, so one trust install is
  permanent; automatic leaf rotation before expiry (deliberately not in Part 1
  — D7 warns instead).
- CA-signed leaf generation must carry the SANs over (`-copy_extensions copy`
  on OpenSSL 3.x, or extensions in the signing config on LibreSSL) and must be
  verified to keep them.
- `seal trust` per platform (macOS/Linux/Windows/iOS/Android), including the
  iOS "enable under Certificate Trust Settings" step.
- Migration note for removing the stale 10-year anchor.
- The spec's two `Escalate` items (cross-device passkey sync with a private CA;
  DNS namespace permanence) need real devices and a product decision — neither
  is code.
