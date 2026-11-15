# Web Access Control (passkeys)

`seal serve` exposes the whole agent surface — sending messages (which the
agent executes), every transcript, every slash command — over HTTP and
WebSocket. Access control is configured once, in `~/.seal/security.toml`;
the enrolled passkeys live next door in `~/.seal/credentials.toml`:

```toml
# ~/.seal/security.toml
[access_control]
# "passkey" (require a passkey) | "none" (run open — an explicit waiver)
mode = "passkey"

# Optional: only needed when a TLS reverse proxy fronts the gateway.
# origin = "https://seal.example.com"
# rp_id  = "seal.example.com"
```

```toml
# ~/.seal/credentials.toml — gateway-owned, mode 0600; do not edit by hand
version = 1

[credentials.<credential-id-base64url>]
public_key = "<base64url, 64-byte x||y>"
sign_count = 0
label      = "passkey"
created_at = "2026-10-30T14:00:00Z"
rp_id      = "localhost"
added_via  = "cli_token"   # cli_token | cli_window | assertion | legacy
```

Three states:

| `security.toml` | Gateway behaviour |
|---|---|
| no `[access_control]` table | **unconfigured** — the API is closed; the first browser visit shows a setup screen |
| `mode = "none"` | **open** — runs with no authentication (for a host only reachable over a VPN) |
| `mode = "passkey"` | **passkey** — every request needs a passkey-backed session |

**Enroll before you expose the port.** The first enrollment is a race: any
client that can reach the gateway and holds an enrollment token can win the
one slot. Nothing is escalated to before a passkey exists, and the operator
finds out immediately (their own attempt fails with `grant_invalid`), but the
winner holds the full agent surface until `seal access-control reset --yes`.
So enroll from the machine itself, then open the firewall or the tunnel.

Enrollment authority is always a secret presented on the request — never a
cookie:

```bash
seal access-control enroll                 # 10-minute token on stdout, hints on stderr
seal access-control enroll --ttl 90s       # s/m/h required; clamped to 30s-24h
seal access-control enroll --no-token      # loopback-only window, bootstrap state only
seal access-control enroll --cancel        # drop the outstanding grant
seal access-control status                 # mode, origin, credentials, armed grant
seal access-control disable --yes          # turn access control off (keeps credentials)
seal access-control reset --yes            # delete credentials.toml + the section
seal access-control migrate-credentials    # move pre-split credentials out of security.toml
```

On a terminal the boot banner prints the enrollment URL and the token; off a
terminal (`systemd`, `launchd`, a pipe) it writes the token to
`~/.seal/state/enrollment-token` at mode 0600 and prints only the path, so the
token never lands in a log. A restart does **not** mint a new token when one is
still valid.

Adding a second passkey no longer needs a terminal: from `/access` on a signed-in
device, Seal asks you to confirm with an existing passkey (a 120 s grant), then
runs the create prompt. `disable` and `reset` require the daemon stopped —
`serve.lock` is an advisory kernel lock, so a crashed daemon never blocks them.

Passkeys need a **secure context**: `http://localhost`, or HTTPS. That is why the
gateway's default `[gateway] host` is `localhost` — it is the origin Seal
verifies, the origin it allows for the WebSocket, and the one name every browser
treats as a secure context. `host` is authoritative: Seal passes it to the
listener, so a loopback default really does bind loopback, and an address that
cannot be bound refuses to start before anything listens.

The gateway can terminate TLS itself, so no reverse proxy is required:

```toml
# ~/.seal/security.toml
[gateway]
# "localhost" (the default) is loopback-only. Bind a specific address, or
# 0.0.0.0 to listen on every IPv4 interface, when clients are elsewhere.
host = "0.0.0.0"
port = 8443
tls  = true                       # serves ~/.seal/keys/tls/{cert,key}.pem
# tls_cert = "/etc/ssl/fullchain.pem"   # optional overrides for a real cert
# tls_key  = "/etc/ssl/privkey.pem"
# tls_hosts = ["seal.lan"]          # names for a generated certificate's SAN
```

The bind address, the Origin allowlist and the TLS pair are security settings:
they live in `~/.seal/security.toml`, not `config.toml`, so no opcode or agent
config writer can move the listener. An install that still carries `[gateway]`
in `config.toml` is migrated on the next `seal serve` or `seal tui` boot;
`seal provider`/`seal channel`/`seal agent` refuse to write `config.toml` until
that has happened.

`tls = true` is the whole configuration: the PEM paths default to
`~/.seal/keys/tls/cert.pem` and `~/.seal/keys/tls/key.pem`. Setting both paths
explicitly also turns TLS on, so pointing at a real certificate needs no flag.
If those files are absent, Seal generates a self-signed pair with `openssl`
(key written `0600`) on the next start.

The generated certificate is valid for **397 days**. Chromium and WebKit reject
anything longer outright — `ERR_CERT_VALIDITY_TOO_LONG` is not a warning the
user can click through — so a longer-lived pair is worse than useless. Its
subject alternative name covers every name and address the gateway answers on:

* `localhost`, `127.0.0.1` and `::1`
* this machine's hostname
* the host of `[access_control] origin`, when one is set (the name passkeys are
  bound to)
* every local interface address — LAN, VPN and overlay interfaces included
* everything in `tls_hosts`, which comes first in the list and becomes the CN

Anything `network-info` cannot see (it reports one address per family per
interface) can be added to `tls_hosts`, which accepts names and IP literals.

**When an existing pair is replaced.** A pair Seal generated at the default
paths is Seal's to maintain, and is regenerated at boot when it cannot serve a
browser a legal certificate: its window exceeds 397 days, or it does not load
(a truncated file, or a certificate next to the wrong key). The previous pair is
kept as `keys/tls/cert.pem.bak` and `keys/tls/key.pem.bak` so the change can be
undone by hand. Replacing the pair means a **new key**, so the certificate has
to be trusted again on every device that uses this gateway.

Changing `tls_hosts` does **not** by itself regenerate a pair: the names in an
existing certificate are not re-derived on every restart. Delete
`keys/tls/cert.pem` and `keys/tls/key.pem` after editing `tls_hosts`, or the
certificate keeps the old names and the browser rejects the ceremony. The same
deletion is the way to force a fresh key at any other time; when a generated
pair comes within 30 days of expiry, `serve` logs a warning telling you so.

A pair you point at with `tls_cert` / `tls_key` is never validated, replaced or
rotated — a real certificate or a private PKI may legitimately outlive 397
days — so its renewal is your business. A missing file at those paths is
created, exactly as before.

Seal never touches your DNS configuration or zone files, and it never downgrades
the listener to plain HTTP: with `tls = false` it serves HTTP because you asked
it to, and it does not change that setting on its own.

```toml
# ~/.seal/security.toml — must be the https URL clients actually use
[access_control]
origin = "https://seal.example.com:8443"
```

Both PEM paths are required together. Turning TLS on makes `origin` mandatory
and `https://`: the loopback default is `http://localhost:<port>`, which no
ceremony could ever match. A reverse proxy still works too — leave
`tls_cert`/`tls_key` unset and point `origin` / `rp_id` at the proxy's URL.

**A generated certificate does not make passkeys work on its own.** Since Chrome
110 a browser disables WebAuthn outright on a site whose certificate it does not
trust — clicking through the warning is not enough — so the generated
certificate has to be *installed* on the phone (and marked trusted) before any
ceremony will run. It also has to name a hostname: an IP can never be an RP ID,
so set `tls_hosts` to the name the device will use. For the same effort,
`tailscale cert <name>` produces a certificate that every device already
trusts, with no installation step — that is the better default when you have a
tailnet.

**Harness on another machine.** If the browser is not on the harness host, the
lowest-friction options avoid trusting a certificate at all:

* **SSH tunnel** (one operator): bind the gateway to loopback
  (`[gateway] host = "localhost"`, `tls = false`,
  `[access_control] origin = "http://localhost:<port>"`), then
  `ssh -N -L 9090:localhost:<port> you@harness` and open
  `http://localhost:9090`. `localhost` is a secure context, so passkeys work
  with `rp_id = localhost`; the passkey is bound to that tunnel, which is fine
  for a single operator.
* **Tailscale**: `tailscale serve --bg https / http://localhost:8080`, bind Seal
  to loopback, and set `origin`/`rp_id` to the `*.ts.net` URL. Clients already
  trust the certificate, so every device works with no installation step.
* **mkcert / an internal CA**: install the root once per device, then point
  `tls_cert`/`tls_key` at the issued pair. Rotating the leaf certificate does
  not require re-trusting.

The generated certificate remains useful for a single trusted device. If you
use it on several, install the same PEM on each and fully quit the browser after
changing the trust store.

**Troubleshooting: "The passkey prompt was cancelled or timed out."** When no
Touch ID / Windows Hello prompt appears at all and the ceremony fails
instantly, the browser is refusing WebAuthn because it does not trust the
certificate — the prose about cancellation is misleading, since `NotAllowedError`
covers both user cancellation and a browser-side refusal. The definitive check
is the address bar: "Not Secure" or a struck-through padlock means the cert is
not trusted, and no ceremony will run until it is. A padlock means the cert is
trusted and the failure is elsewhere.

On macOS, trust the generated certificate in the **System** keychain (Chrome and
Safari read the system trust store, not the login keychain alone):

```sh
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ~/.seal/keys/tls/cert.pem
```

Then **fully quit** the browser — `⌘Q` on macOS, not just closing the window.
Browsers cache certificate-trust decisions for the lifetime of the process, so a
reopened tab inherits the old "Not Secure" verdict until the whole browser is
restarted. Reopen, confirm the address bar shows a padlock, then try the
passkey again.

A subtle trap: `seal serve` regenerates its managed certificate when the SAN
list changes or the existing pair cannot serve a legal certificate (see above),
which gives the new pair a **new key** — and a different fingerprint from the
one you just trusted. If the "Not Secure" warning returns after a restart, the
cert on disk no longer matches what is in the keychain. Verify by comparing
fingerprints:

```sh
# What the gateway is actually serving:
openssl s_client -connect <host>:<port> -showcerts </dev/null 2>/dev/null \
  | openssl x509 -fingerprint -sha256 -noout
# What the keychain holds:
security find-certificate -c <host> -p /Library/Keychains/System.keychain \
  | openssl x509 -fingerprint -sha256 -noout
```

Mismatched fingerprints mean the cert was regenerated after you trusted it;
re-run `add-trusted-cert` against the current `~/.seal/keys/tls/cert.pem`. To
avoid this entirely, prefer `mkcert` (a local CA you install once, after which
every generated cert is trusted with no per-cert step) or `tailscale cert` (a
publicly-trusted pair when the host is on your tailnet) over trusting the
self-signed pair by hand.

**A hostname is required, not just TLS.** A WebAuthn RP ID must be a domain
string, so `https://192.168.1.42:8443` still cannot register a passkey — Chrome
raises `SecurityError` before the ceremony starts. Use a name that resolves on
the client (a tailnet name, a DNS record for the LAN address, or
`tailscale cert` for a real certificate) and set `origin`/`rp_id` to it.

Deleting the last **usable** passkey is refused; an orphaned one (registered
for another address) is safe to remove.

`reset` is the terminal-only escape hatch: no opcode and no HTTP route can turn
access control off — `POST /api/auth/waive` was removed, and `mode = "none"` can
only be written by `seal access-control disable --yes`. The agent runs as the
same uid and can read `~/.seal/`, so passkeys defend the **network** — not a
compromised agent.
