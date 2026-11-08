# File Explorer Feature — Design Document

> **Status**: Draft (Rev 3 — post design-review-gate round 2 feedback)
> **Date**: 2026-11-08
> **Author**: Human-authored (AI-assisted)

## 1. Use Cases

### Personas

- **Zoe** — a developer who runs Seal Harness on her laptop (local mode).
  She uses the web UI to manage agent sessions and wants to inspect files
  the agent has created or modified without switching to a terminal.
- **Sam** — an operator who runs Seal Harness with a remote execution
  machine (remote mode). He manages agents from his workstation and needs
  to view build artifacts and logs on the remote machine without SSH-ing
  in each time.

### Use Cases

**UC-1: Inspect an agent-created file**
> **WHO**: Zoe (web user)
> **WANTS**: to view the contents of a file the agent just wrote
> **SO THAT**: she can verify the agent's work is correct
> **WHEN**: after an agent completes a coding task that modifies files

**UC-2: Navigate to a file referenced in a transcript**
> **WHO**: Zoe (web user)
> **WANTS**: to click a stable link to a file path mentioned in the
> transcript
> **SO THAT**: she can see the file contents without copying the path to a
> terminal
> **WHEN**: while reviewing a transcript that references file paths
> (Note: auto-generating links from transcripts is deferred; the stable URL
> scheme enables manual linking and future auto-linking)

**UC-3: Download a build artifact or log**
> **WHO**: Sam (remote-mode operator)
> **WANTS**: to download a file from the execution machine
> **SO THAT**: he can share it externally or inspect it in a local tool
> **WHEN**: when an agent produces a build log or artifact he needs to
> review

**UC-4: Browse a project directory tree**
> **WHO**: Zoe (web user)
> **WANTS**: to navigate the directory structure of a cloned repo
> **SO THAT**: she can orient herself in the project the agent is working on
> **WHEN**: when starting a new session or reviewing an agent's work

## 2. Scope

### In Scope (MUST for v1)
- New "Files" top-level section in the web UI
- Directory listing with entry names, types (file/dir), sizes, and mtimes
- File content viewing (text, paged)
- File download (Content-Disposition: attachment)
- Stable, shareable/bookmarkable URL links to directory listings and file
  content views
- Works in both local mode (execution = harness machine) and remote mode
  (execution = separate SSH host)

### In Scope (SHOULD for v1 — nice to have)
- Truncation indicators for large files and large directory listings
- Warning banner when navigating to sensitive directories (`~/.seal/`,
  `.ssh/`, etc.)

### Out of Scope (Deferred)
- File uploads
- Auto-generating file links in session transcripts (the stable URL scheme
  enables this future feature)
- Binary file content rendering (first pass serves text via UTF-8 decode;
  binary files show a "binary file" message and offer download only)
- File editing / creation / deletion
- File search within a directory

### Why Top-Level Nav vs. Contextual Links

The file explorer is placed as a top-level nav section because:
1. It provides general filesystem browsing, not just transcript-linked
   files — operators may want to explore the project structure
   independently of any specific transcript reference.
2. The stable URL scheme (`/files?path=...`) enables future contextual
   linking from transcripts without requiring the explorer to be embedded
   in the transcript view.
3. It mirrors the pattern of other top-level sections (Agents, Skills,
   Repos) that provide management surfaces independent of any specific
   session.

## 3. Success Criteria

### User-Focused Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| File inspection context-switch reduction | Operators report no longer opening a terminal solely to inspect agent-referenced files | GitHub-issue user feedback, 4 weeks post-merge |
| Download convenience | Operators successfully download artifacts/logs via the UI without SCP | User feedback / issue reports |
| Remote-mode browsing usability | Directory navigation feels responsive (< 2s per click) | Operator feedback; SSH mux reuse should make this achievable |

### Failure Criteria
- Operators report the file explorer is too slow vs. SSH (remote mode
  latency makes browsing painful)
- Operators report garbled binary content is confusing (no clear "binary
  file" indicator)
- Security incident resulting from non-loopback exposure (see §4)

### Evaluation Mechanism
Since the project has no telemetry, evaluation is via GitHub-issue user
feedback over 4 weeks post-merge. Success = operators report no longer
SSH-ing to inspect agent-referenced files. Failure = zero adoption or
operators report the explorer is too slow vs SSH.

## 4. Security Considerations

### 4.1 Non-Loopback Fail-Closed (BLOCKER — from security review)

The file explorer introduces an **arbitrary-file-read primitive** with no
authentication. The existing gateway surface (`/api/sessions/:id/send`,
`/api/repos`, etc.) is also unauthenticated, but those routes require a
session ID or repo ID — they are not silent arbitrary-file-read. The file
explorer can read `~/.seal/`, `~/.ssh/id_rsa`, `~/.env`, etc. with a single
GET and no audit trail.

**Mitigation**: The file explorer routes (`/api/files*`) MUST return `403`
when the gateway is bound to a non-loopback address, **unless** the
operator has explicitly opted in via a config flag
(`[gateway] allow_remote_file_explorer = true`). This is a stronger guard
than the existing gateway's warning-only non-loopback behavior, justified
by the file explorer's strictly greater blast radius.

Implementation: the `ApiDeps` record carries an `adFileExplorerEnabled ::
Bool` flag, set at server startup based on:
- `True` when the gateway host is loopback (`127.0.0.1` or `::1`)
- `True` when the config flag `allow_remote_file_explorer` is set
- `False` otherwise

When `False`, all `/api/files*` routes return `403` with an explanatory
error message.

### 4.2 DNS Rebinding / CSRF (from security review)

A malicious web page could use DNS rebinding to reach the loopback gateway
and `fetch("/api/files/content?path=...")`. This is an existing risk for
all gateway routes, but the file explorer makes it catastrophically worse.

**Mitigation**: Validate the `Origin` header on file explorer HTTP
requests. Reject requests where `Origin` is present and does not match the
configured `gcAllowedOrigins` allowlist. (This should ideally apply to all
gateway HTTP routes, but at minimum covers `/api/files*`.)

### 4.3 `~/.seal/` Access — Defense in Depth (from security review)

The design's reasoning that "the `~/.seal/` restriction applies to
agent-driven opcodes, not human-driven web UI features" is **correct for
loopback-only operation** — the operator owns the machine and can already
`cat ~/.seal/vault` in a terminal. However, the web UI introduces new
vectors (bookmarkable URLs, screen-share leakage, browser history sync).

**Mitigation**: Restore the `blockedNames` check from
`Seal.Security.Path` as a **warning, not a blocker**. When the operator
navigates to a path under `~/.seal/`, `.ssh/`, `.env/`, `.gnupg/`, or
`.netrc/`, the API response includes a `warning` field (e.g., `"This
directory contains sensitive files"`) and the frontend shows a warning
banner. Access is NOT blocked — the operator can proceed — but the warning
provides defense-in-depth against accidental exposure.

### 4.4 Audit Logging (from security review)

File reads and downloads produce no transcript entry (correct — this is not
an opcode). However, silent operation with no audit trail is a gap.

**Mitigation**: Log each `/api/files/content` and `/api/files/download`
access (path, timestamp, client IP) via the existing `SealLogger` at
`InfoS`. This creates an audit trail in `seal.log` without the overhead of
transcript entries.

### 4.5 Two-Plane Security

- **Remote mode**: `mkRemoteFileExplorer` is constructed with only the
  `SshConfig` — all operations go through host-key-pinned SSH to the
  execution machine. The harness machine's filesystem is never touched.
- **Local mode**: execution = harness machine, so filesystem access is
  unavoidably equivalent. Acceptable under loopback binding (see §4.1).

### 4.6 Path Safety

- **NUL byte rejection**: paths containing NUL bytes are rejected with 400.
- **Path normalization**: `lexicalCollapse` (from `Seal.Security.Path`) is
  applied to the requested path before processing, so `/home/user/../etc`
  resolves to `/etc` consistently.
- **Shell quoting**: all paths in remote SSH commands are shell-quoted via
  `shellQuote`. The path is assigned to a shell variable before use in
  compound commands (see §5.2 for the corrected construction).
- **`--` separator**: all `ls` commands use `--` before the path argument
  (matching the existing `WorkdirFs` codebase pattern: `ls -1 --`).

### 4.7 Download Headers

- `Content-Type: application/octet-stream` (not `text/plain` — prevents
  browsers from rendering content inline)
- `Content-Disposition: attachment; filename="<basename>"`
- `X-Content-Type-Options: nosniff` (prevents MIME sniffing)
- When the file is truncated (exceeds the byte ceiling), the response
  includes `X-Truncated: true` header so the user is aware they got a
  partial download.

## 5. Design

### 5.1 FileExplorerHandle

A new handle type that abstracts local vs remote file access, mirroring the
`UntrustedIO` pattern.

```haskell
-- | The error ADT for 'FileExplorerHandle' methods. Pinned for exhaustive
-- pattern-match under @-Wall -Werror@.
data FileExplorerErr
  = FeNotFound          -- ^ path does not exist
  | FeIsDirectory       -- ^ path is a directory (for content/download)
  | FeNotADirectory     -- ^ path is a file (for listing)
  | FePermissionDenied  -- ^ permission denied
  | FeIo !Text          -- ^ I/O error (message)
  | FeExec !Text        -- ^ remote SSH exec failure (message)
  | FeTruncated         -- ^ output exceeded the byte ceiling
  | FeDisabled          -- ^ file explorer disabled (non-loopback)
  deriving stock (Eq, Show)

-- | One entry in a directory listing.
data FileEntry = FileEntry
  { feName  :: !Text          -- ^ basename
  , feIsDir :: !Bool          -- ^ True = directory, False = file
  , feSize  :: !(Maybe Integer)    -- ^ Nothing for directories or when unavailable
  , feMtime :: !(Maybe UTCTime)    -- ^ Nothing when unavailable
  , feIsSymlink :: !Bool          -- ^ True = symlink (not followed in listing)
  } deriving stock (Eq, Show)

-- | The result of a directory listing.
data FileListing = FileListing
  { flPath     :: !Text          -- ^ the listed path (normalized)
  , flEntries  :: ![FileEntry]
  , flTruncated :: !Bool         -- ^ True if the listing was cut short
  , flWarning  :: !(Maybe Text)  -- ^ sensitive-directory warning
  } deriving stock (Eq, Show)

-- | The result of a file content read.
data FileContent = FileContent
  { fcPath       :: !Text
  , fcContent    :: !Text
  , fcTruncated  :: !Bool        -- ^ True if content exceeded byte ceiling
  , fcLinesRead  :: !Int         -- ^ number of lines returned (always reflects what's in fcContent)
  , fcIsBinary   :: !Bool        -- ^ True if content appears to be binary (contains NUL bytes)
  } deriving stock (Eq, Show)

-- | The file explorer capability handle. Abstracts local vs remote
-- execution machine access. The @Int@ parameter on construction is the
-- operator-configured byte ceiling for reads (same @maxScanBytes@ as
-- @FILE_READ@).
data FileExplorerHandle = FileExplorerHandle
  { feListDirectory :: FilePath -> IO (Either FileExplorerErr FileListing)
  , feReadFile      :: FilePath -> IO (Either FileExplorerErr FileContent)
  , feResolveHome   :: IO (Either FileExplorerErr FilePath)
  }
```

The download endpoint needs raw bytes (not UTF-8-decoded `Text`), so the
handle also exposes a raw-bytes read method:

```haskell
  , feReadFileBytes :: FilePath -> IO (Either FileExplorerErr (ByteString, Bool))
    -- ^ (bytes up to ceiling, truncated?) — for the download endpoint.
    -- Returns raw bytes so binary files are not corrupted by UTF-8
    -- decode/encode round-trip. The @Bool@ is whether the file exceeded
    -- the byte ceiling (for the @X-Truncated@ response header).
```

**Constructor note**: smart constructors run in `IO` and may close over
mutable state (e.g. the `IORef` home-directory cache in the remote arm).

**Design decisions from review feedback:**

- `feReadFile` no longer takes an `Int` parameter — the byte ceiling is
  captured at construction time (same as `WorkdirFs`).
- `feFileMeta` / `FileMeta` removed — no route uses it. File metadata
  (size, mtime) is returned as part of `FileEntry` in the listing.
- `FileExplorerErr` is fully defined with 8 constructors.
- `fcLinesRead` replaces the ambiguous `totalLines` — it always reflects
  the number of lines in `fcContent` (what was actually read), not the
  total file line count.
- `fcIsBinary` flag: when the decoded content contains NUL bytes, the API
  returns `isBinary: true` and the frontend shows "This appears to be a
  binary file. Download to view." instead of garbled content.
- `feIsSymlink` field on `FileEntry`: symlinks are shown as type "symlink"
  in the listing (not followed for listing, but reads will follow them —
  documented behavior).

### 5.2 Local Mode (`mkLocalFileExplorer`)

- `feListDirectory`: `System.Directory.listDirectory` + per-entry
  `doesDirectoryExist` / `doesFileExist` / `pathIsSymbolicLink` +
  best-effort `getFileSize` / `getModificationTime` (errors → `Nothing`).
  Entries are sorted: directories first, then files, alphabetically.
  **Truncation**: if the entry count exceeds a configurable limit (default
  10,000), the listing is truncated with `flTruncated = True`.
- `feReadFile`: bounded read via `readBoundedLocal` (same helper as
  `UntrustedIO`), UTF-8 decode, detect NUL bytes for `fcIsBinary`, line
  count via `T.lines`.
- `feReadFileBytes`: bounded read via `readBoundedLocal` (returns the raw
  `ByteString` + truncated flag directly — no UTF-8 decode). The download
  endpoint uses this to serve binary files without corruption.
- `feResolveHome`: `System.Environment.getHomeDirectory`.

### 5.3 Remote Mode (`mkRemoteFileExplorer`)

- `feListDirectory`: ONE SSH round trip via `runRemoteShell`. The command
  assigns the path to a shell variable first (fixing the security review's
  correctness bug), then lists entries with type/size/mtime:

  ```sh
  p='/abs/path'; ls -1A -- "$p" 2>/dev/null | while IFS= read -r name; do
    full="$p/$name"
    if [ -L "$full" ]; then echo "S|$name"
    elif [ -d "$full" ]; then echo "D|$name"
    elif [ -f "$full" ]; then
      sz=$(stat -c %s -- "$full" 2>/dev/null || stat -f%z "$full" 2>/dev/null || echo 0)
      mt=$(stat -c %Y -- "$full" 2>/dev/null || stat -f%m "$full" 2>/dev/null || echo 0)
      echo "F|$name|$sz|$mt"
    else echo "O|$name"
    fi
  done
  ```

  The path is `shellQuote`-d before interpolation, producing the
  `p='/abs/path'` assignment. The `while` loop uses `"$p/$name"` (double
  quotes, variable expansion) — no literal single quotes leak into the
  path. Output is bounded by the `RemoteRunner`'s 50KB cap; if truncated,
  `flTruncated = True`.

  **`O|` entry handling**: the `O|name` format is emitted for special
  files (sockets, fifos, devices). These are mapped to `FileEntry` with
  `feIsDir=False, feIsSymlink=False, feSize=Nothing, feMtime=Nothing` —
  shown as "other" entries in the listing (not clickable for navigation
  or content viewing).

  The portable `stat` pattern (try GNU `-c`, fall back to BSD `-f`) matches
  the existing `remoteStatRechecked` in `WorkdirFs`.

- `feReadFile`: SSH `head -c <ceil> -- "$p"` where `p` is the
  shell-quoted path → UTF-8 decode → detect NUL bytes → line count. Same
  pattern as `remoteReadFile` in `WorkdirFs`.
- `feReadFileBytes`: SSH `head -c <ceil> -- "$p"` → returns raw
  `ByteString` + truncated flag (no UTF-8 decode). The download endpoint
  uses this to serve binary files without corruption. Same SSH command as
  `feReadFile` but the result is kept as raw bytes rather than decoded to
  `Text`.
  
- `feResolveHome`: SSH `echo $HOME` (single round trip, result cached in
  an `IORef` per `FileExplorerHandle` instance — per-process, never
  invalidated; if the SSH user's home changes, a server restart refreshes
  it).

### 5.4 Gateway API Routes

Three new routes, **not session-scoped**:

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/files?path=<dir>` | Directory listing |
| GET | `/api/files/content?path=<file>` | File content (text, JSON) |
| GET | `/api/files/download?path=<file>` | File download (raw, attachment) |

**Query parameter `path`**: an absolute filesystem path on the execution
machine. When absent, the backend resolves `$HOME` on the execution machine
via `feResolveHome` and redirects or returns the listing for that path.

**Route 1: Directory listing**
```
GET /api/files?path=/home/user/project
→ 200 { "path": "/home/user/project", "entries": [
    { "name": "src", "isDir": true, "isSymlink": false, "size": null, "mtime": null },
    { "name": "README.md", "isDir": false, "isSymlink": false, "size": 4096, "mtime": "2026-11-08T10:30:00Z" }
  ], "truncated": false, "warning": null }
→ 404 { "error": "path not found" }
→ 403 { "error": "file explorer disabled (gateway is not loopback)" }
→ 400 { "error": "path is required" }
```

**Route 2: File content**
```
GET /api/files/content?path=/home/user/project/README.md
→ 200 { "path": "...", "content": "...", "truncated": false, "linesRead": 42, "isBinary": false }
→ 200 { "path": "...", "content": "", "truncated": false, "linesRead": 0, "isBinary": true }
→ 404 { "error": "file not found" }
→ 400 { "error": "path is a directory" }
→ 403 { "error": "file explorer disabled" }
```

Content is bounded by the operator-configured byte ceiling (same
`maxScanBytes` as `FILE_READ` — 128 KiB per the `Seal.Text.LineFile`
module). When truncated, `truncated: true` and `linesRead` reflects the
lines actually read. When `isBinary: true`, `content` is empty and the
frontend shows a "binary file" message with a download link.

**Route 3: File download**
```
GET /api/files/download?path=/home/user/project/README.md
→ 200 (application/octet-stream,
       Content-Disposition: attachment; filename="README.md",
       X-Content-Type-Options: nosniff, X-Truncated: true|false)
→ 404 { "error": "file not found" }
→ 400 { "error": "path is a directory" }
→ 403 { "error": "file explorer disabled" }
```

The download endpoint returns raw file content (bounded by the same byte
ceiling) as `application/octet-stream` with `Content-Disposition:
attachment`. The `X-Truncated` header indicates whether the file exceeded
the byte ceiling. The download endpoint uses `feReadFileBytes` (raw
`ByteString`) — NOT `feReadFile` (`Text`) — so binary files are served
without UTF-8 corruption. The UTF-8 decode limitation applies only to the
content view endpoint.

**Note on binary downloads**: Files exceeding the byte ceiling are
partially served with `X-Truncated: true`. Full binary download of
arbitrarily large files is deferred.

**Frontend truncation handling for downloads**: The `X-Truncated` header
is invisible when downloading via a plain `<a href>` link. The frontend
uses `fetch()` for downloads instead of `<a href>`: it fetches the
download URL, checks the `X-Truncated` response header, and if true,
shows a warning toast ("File was truncated — only the first 128 KiB was
downloaded") before saving the response blob. This ensures the user is
always aware of partial downloads.

### 5.5 SealRoute GADT + OpenAPI

Three new constructors in `src-gateway-types/Seal/Gateway/Types/Route.hs`:

```haskell
  -- Files (machine-level file explorer)
  RouteFilesList     :: SealRoute '[] '[] Bodyless Resp
  RouteFilesContent  :: SealRoute '[] '[] Bodyless Resp
  RouteFilesDownload :: SealRoute '[] '[] Bodyless Resp
```

Each requires:
1. A `routeMeta` arm (path shape + method):
   ```haskell
   RouteFilesList     -> Meta (match "files" ./ end) qend bodyless (resp (one respCodec)) M.get
   RouteFilesContent  -> Meta (match "files" ./ match "content" ./ end) qend bodyless (resp (one respCodec)) M.get
   RouteFilesDownload -> Meta (match "files" ./ match "download" ./ end) qend bodyless (resp (one respCodec)) M.get
   ```
2. An entry in `allRoutes` (after `RouteAdopt`).
3. An `openApiMeta` arm in `src/Seal/Gateway/OpenApi.hs` (pattern match —
   required for OpenAPI doc generation; missing arms = build failure under
   `-Werror`).

The `path` query parameter is parsed manually in the handler (same pattern
as `handleTranscript`'s `limit` query param — the GADT's `qrys` is `'[]`
for all routes).

### 5.6 Route Count Assertion

The test `test/Seal/Gateway/ApiRouteSpec.hs` asserts the total route count
(currently 62). Adding 3 routes makes 65. This assertion MUST be updated
in the same commit that adds the routes.

### 5.7 ApiDeps Wiring

Two new fields on `ApiDeps`:

```haskell
  , adFileExplorer :: FileExplorerHandle
  , adFileExplorerEnabled :: Bool
    -- ^ 'False' when the gateway is non-loopback and the operator has not
    -- opted in via [gateway] allow_remote_file_explorer. Routes return 403.
  ```

Wired in `Seal.Command.Serve.runServeMain`:

```haskell
let isLoopback = gcHost gwCfg `elem` ["127.0.0.1", "::1", "localhost"]
    fileExplorerEnabled = isLoopback
      || fromMaybe False (gcAllowRemoteFileExplorer gwCfg)
fileExplorer <- case untrustedExecConfigFromSecurity secCfg of
  Nothing -> pure (mkLocalFileExplorer maxScanBytes)  -- local mode
  Just uec -> case uecRemote uec of
    -- mode=remote but SSH details incomplete → fail-closed stub
    -- (NOT a local fallback — that would browse the harness machine
    -- instead of the intended remote machine, a security/correctness
    -- mismatch per architect review)
    Nothing -> pure mkFailClosedFileExplorer
    Just sshCfg -> pure (mkRemoteFileExplorer sshCfg mkRealRemoteRunner maxScanBytes)
```

The `gcAllowRemoteFileExplorer` field is a new optional `Bool` on
`GatewayConfig` (default `False`), read from
`[gateway] allow_remote_file_explorer` in `config.toml`.

`mkFailClosedFileExplorer` is a stub where all methods return
`Left FeDisabled`.

### 5.8 Module Placement

Per architect review, the handle belongs in `Seal.Tools.Exec` (alongside
`UntrustedIO`, `WorkdirFs`, `RemoteRunner`) not `Seal.Web`:

- `src/Seal/Tools/Exec/FileExplorer.hs` — handle type + local/remote/fail-closed constructors
- `test/Seal/Tools/Exec/FileExplorerSpec.hs` — unit tests

The API handlers remain in `src/Seal/Gateway/API.hs` (where all other
route handlers live).

### 5.9 Frontend

**New top-level section**: Add `'files'` to `TopSection` in `TopBar.tsx`,
labeled "Files".

**URL routing** (in `App.tsx`):
- `/files` — file explorer, defaults to home directory
- `/files?path=<dir>` — directory listing
- `/files?path=<file>&view=content` — file content view

**New component**: `frontend/src/components/FilesView.tsx`
- **Breadcrumb bar**: current path as clickable segments (each navigates
  to that parent directory)
- **Directory listing**: sorted entries (dirs first, then files). Directory
  names are clickable (navigate into). Files have "View" and "Download"
  links. Shows size and mtime.
- **File content view**: when `view=content`, shows content in a
  text-escaped `<pre>` block (no HTML rendering — CSP-safe). Has
  "Download" and "Back to directory" buttons. Shows "binary file" message
  when `isBinary: true`.
- **Warning banner**: shown when `warning` field is non-null (sensitive
  directory).
- **Truncation indicator**: shown when `truncated: true` for both listings
  and content.
- **Loading/error states**: standard spinner, error messages for 404/400/403.

**New hooks** (in `useApi.ts`):
- `useFileListing(path)` — `GET /api/files?path=<path>`
- `useFileContent(path)` — `GET /api/files/content?path=<path>`
- `downloadFile(path)` — uses `fetch()` to GET the download URL, checks
  `X-Truncated` header, shows a warning toast if truncated, then saves the
  blob via `URL.createObjectURL` + `<a download>` click. NOT a plain
  `<a href>` — the `fetch` step is needed to detect truncation.

**New types** (in `types.ts`):
```typescript
interface FileEntry {
  name: string
  isDir: boolean
  isSymlink: boolean
  size: number | null
  mtime: string | null
}
interface FileListing {
  path: string
  entries: FileEntry[]
  truncated: boolean
  warning: string | null
}
interface FileContent {
  path: string
  content: string
  truncated: boolean
  linesRead: number
  isBinary: boolean
}
```

### 5.10 Home Directory Resolution

When no `path` query parameter is provided:
- Backend calls `feResolveHome` → resolves `$HOME` on the execution machine
- Returns the listing for `$HOME`
- The response `path` field is the resolved home path

In remote mode, `feResolveHome` runs `echo $HOME` via SSH (cached in an
`IORef` per handle instance — per-process, never invalidated during the
process lifetime).

## 6. Testing

### 6.1 Unit Tests (`FileExplorerSpec.hs`)

```
describe "mkLocalFileExplorer" $ do
  it "lists a directory with entries, types, sizes"
    -- create temp dir with subdirs + files, assert listing shape
  it "returns FeNotFound for a missing path"
  it "returns FeNotADirectory when listing a file"
  it "returns FeIsDirectory when reading a directory"
  it "truncates listing when entry count exceeds limit"
  it "reads file content with correct line count"
  it "sets fcIsBinary when content has NUL bytes"
  it "truncates content when file exceeds byte ceiling"
  it "resolves home directory"

describe "mkRemoteFileExplorer" $ do
  it "lists directory via SSH (fake runner recording argv)"
    -- assert SSH argv is correct, parse canned output
  it "parses D|/F|/S|/O| entry format"
  it "handles truncated SSH output (flTruncated)"
  it "reads file content via SSH head -c"
  it "resolves home via SSH echo $HOME"
  it "caches home directory resolution"
  it "uses -- separator in ls command"
  it "shell-quotes path in variable assignment (no single-quote leak)"

  it "reads raw bytes via feReadFileBytes (fake runner asserts head -c argv)"
  it "feReadFileBytes returns raw ByteString (no UTF-8 decode)"

describe "mkFailClosedFileExplorer" $ do
  it "returns FeDisabled for all methods"
```

### 6.2 Integration Tests (`ApiFilesSpec.hs`)

```
describe "GET /api/files" $ do
  it "returns directory listing as JSON"
  it "defaults to home directory when path omitted"
  it "returns 404 for missing path"
  it "returns 400 for empty path"
  it "returns 403 when file explorer disabled"

describe "GET /api/files/content" $ do
  it "returns file content as JSON"
  it "returns isBinary:true for binary files"
  it "returns 404 for missing file"
  it "returns 400 when path is a directory"
  it "returns 403 when disabled"

describe "GET /api/files/download" $ do
  it "returns raw content with attachment headers"
  it "sets X-Content-Type-Options: nosniff"
  it "sets X-Truncated header for large files"
  it "serves binary bytes without UTF-8 corruption (feReadFileBytes path)"
  it "returns 404 for missing file"
  it "returns 400 when path is a directory"
  it "returns 403 when disabled"
```

### 6.3 Frontend Tests (`FilesView.test.tsx`)

```
it "renders directory listing with entries"
it "navigates into a subdirectory on click"
it "shows file content view when view=content"
it "shows binary file message when isBinary"
it "downloads files via fetch() (not <a href>)"
it "shows truncation warning toast when X-Truncated is true"
it "shows warning banner for sensitive directories"
it "shows truncation indicator"
it "shows error message for 404"
```

### 6.4 QuickCheck Property (suggestion from CTO)

```haskell
it "listing parser round-trips for well-formed input"
  -- property: parseListing (formatListing entries) == entries
  -- for well-formed FileEntry lists (no pipe in names)
```

## 7. File Placement

### Backend (Haskell)
- `src/Seal/Tools/Exec/FileExplorer.hs` — handle type + constructors
- `src/Seal/Gateway/API.hs` — new route handlers + `ApiDeps` fields
- `src-gateway-types/Seal/Gateway/Types/Route.hs` — new `SealRoute` constructors + `routeMeta` + `allRoutes`
- `src/Seal/Gateway/OpenApi.hs` — new `openApiMeta` arms
- `src/Seal/Command/Serve.hs` — wire `adFileExplorer` + `adFileExplorerEnabled`
- `src/Seal/Gateway/Config.hs` — `gcAllowRemoteFileExplorer` field
- `test/Seal/Tools/Exec/FileExplorerSpec.hs` — unit tests
- `test/Seal/Gateway/ApiFilesSpec.hs` — integration tests
- `test/Seal/Gateway/ApiRouteSpec.hs` — update route count assertion
- `seal-harness.cabal` — new exposed-modules + test other-modules
- `test/Main.hs` — wire new test modules

### Frontend (TypeScript/React)
- `frontend/src/components/FilesView.tsx` — main component
- `frontend/src/hooks/useApi.ts` — new hooks
- `frontend/src/types.ts` — new types
- `frontend/src/App.tsx` — new `'files'` section, URL routing
- `frontend/src/components/TopBar.tsx` — new "Files" nav button
- `frontend/src/components/__tests__/FilesView.test.tsx` — component tests

## 8. Future Enhancements (Out of Scope)

- File uploads
- Full binary file downloads (arbitrary size, streaming)
- Auto-generating file links in session transcripts
- File search within a directory
- File editing
