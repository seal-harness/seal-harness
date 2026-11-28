#!/usr/bin/env bash
# Install the `seal` CLI from GitHub Releases.
#
#   curl -fsSL https://raw.githubusercontent.com/seal-harness/seal-harness/main/scripts/install.sh | bash
#
#   ... | bash -s -- --version 0.1.0
#   ... | bash -s -- --no-modify-path
#
# The macOS artifact is not a single file: `seal` loads five bundled dylibs from
# `bin/dylibs/` via @executable_path. So this installs the whole `bin/` tree and
# symlinks the executable, rather than copying the binary somewhere on its own
# (which would fail with "Library not loaded").
#
# Uses curl rather than a browser download on purpose: curl does not set
# com.apple.quarantine, so the installed binary runs without a Gatekeeper prompt
# even though it is not yet signed with an Apple Developer ID.
#
# Written for bash 3.2 — that is what macOS ships as /bin/bash, so no
# associative arrays, no ${var,,}, no mapfile.
set -euo pipefail

REPO="seal-harness/seal-harness"
VERSION=""                 # empty means the rolling `latest` tag
MODIFY_PATH=1
LOCAL_TARBALL=""           # install from a local artifact instead of a release

# Where the tree lands, and where the symlink goes. Follows XDG on Linux and
# ~/.local on macOS, matching what most CLI installers do.
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
BIN_HOME="${XDG_BIN_HOME:-$HOME/.local/bin}"
INSTALL_ROOT="$DATA_HOME/seal"
LINK_PATH="$BIN_HOME/seal"

# ── output helpers ──────────────────────────────────────────────────────────
# Colour only when stderr is a terminal, so piped/CI output stays clean.
if [ -t 2 ]; then
  C_DIM=$'\033[2m'; C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'
  C_YEL=$'\033[0;33m'; C_RST=$'\033[0m'
else
  C_DIM=''; C_RED=''; C_GRN=''; C_YEL=''; C_RST=''
fi

info()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RST" >&2; }
ok()    { printf '%s%s%s\n' "$C_GRN" "$*" "$C_RST" >&2; }
warn()  { printf '%s%s%s\n' "$C_YEL" "$*" "$C_RST" >&2; }
die()   { printf '%sError: %s%s\n' "$C_RED" "$*" "$C_RST" >&2; exit 1; }

usage() {
  cat <<'EOF'
Install the seal CLI.

Usage: install.sh [options]

Options:
  --version <v>       Install a specific release version (e.g. 0.1.0).
                      Default: the rolling `latest` build.
  --no-modify-path    Do not touch shell config files; print the PATH line
                      to add instead.
  --from-tarball <p>  Install from a local .tar.gz instead of downloading.
                      Skips the checksum check (there is nothing to verify
                      against). Intended for testing and offline installs.
  -h, --help          Show this help.

Environment:
  XDG_DATA_HOME, XDG_BIN_HOME   Override install locations.
  SEAL_INSTALL_ROOT             Override the tree location entirely.

The whole bin/ tree is installed, because seal loads shared libraries from
bin/dylibs/ beside itself. Move or symlink the tree, never the bare binary.
EOF
}

# ── argument parsing ────────────────────────────────────────────────────────
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      [ "$#" -ge 2 ] || die "--version needs a value"
      VERSION="$2"; shift 2 ;;
    --version=*)
      VERSION="${1#--version=}"; shift ;;
    --from-tarball)
      [ "$#" -ge 2 ] || die "--from-tarball needs a path"
      LOCAL_TARBALL="$2"; shift 2 ;;
    --from-tarball=*)
      LOCAL_TARBALL="${1#--from-tarball=}"; shift ;;
    --no-modify-path)
      MODIFY_PATH=0; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "unknown argument: $1 (try --help)" ;;
  esac
done

# ── platform detection ──────────────────────────────────────────────────────
# Produces an ordered list of candidate platform suffixes, most preferred
# first. The first one with a published asset wins; this keeps the script
# working if we add platforms later without editing it.
detect_platforms() {
  local os arch
  case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux)  os="linux" ;;
    *) die "unsupported operating system: $(uname -s). seal publishes macOS and Linux builds only." ;;
  esac

  arch="$(uname -m)"
  case "$arch" in
    arm64|aarch64) arch="aarch64" ;;
    x86_64|amd64)  arch="x86_64" ;;
    *) die "unsupported architecture: $arch" ;;
  esac

  # A shell running under Rosetta reports x86_64 but the machine is arm64.
  # Prefer the native build so the user does not silently get the slower one.
  if [ "$os" = "darwin" ] && [ "$arch" = "x86_64" ]; then
    if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = "1" ]; then
      arch="aarch64"
    fi
  fi

  echo "${arch}-${os}"
}

# ── release URL ────────────────────────────────────────────────────────────
# `latest` is a prerelease tag, so the /releases/latest/download/ redirect does
# not apply — it resolves to the newest *non*-prerelease, which may not exist.
# Addressing the tag explicitly works for both the rolling and versioned cases.
release_base() {
  local tag="${VERSION:-latest}"
  case "$tag" in
    v*) tag="${tag#v}" ;;
  esac
  # A versioned release tags itself `v<version>`; the rolling one is `latest`.
  if [ -n "$VERSION" ]; then
    echo "https://github.com/${REPO}/releases/download/v${tag}"
  else
    echo "https://github.com/${REPO}/releases/download/latest"
  fi
}

# ── tooling ────────────────────────────────────────────────────────────────
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "need sha256sum or shasum to verify the download"
  fi
}

fetch() {
  # -f so an HTML error page is never mistaken for an asset; -L for the
  # redirect to the asset CDN.
  curl -fsSL --retry 3 --retry-delay 1 -o "$2" "$1"
}

TMP=""
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# ── main ───────────────────────────────────────────────────────────────────
command -v curl >/dev/null 2>&1 || die "curl is required but was not found"
command -v tar  >/dev/null 2>&1 || die "tar is required but was not found"

PLATFORM="$(detect_platforms)"
BASE="$(release_base)"

info "Installing seal for ${PLATFORM}${VERSION:+ (version ${VERSION})}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/seal-install.XXXXXX")"

ARCHIVE=""
if [ -n "$LOCAL_TARBALL" ]; then
  # Local artifact: no download, nothing to verify against.
  [ -f "$LOCAL_TARBALL" ] || die "no such file: $LOCAL_TARBALL"
  ARCHIVE="$LOCAL_TARBALL"
  info "Installing from local tarball ${LOCAL_TARBALL}"
else
  SUMS="$TMP/checksums-sha256.txt"
  info "Fetching checksums"
  fetch "$BASE/checksums-sha256.txt" "$SUMS" \
    || die "could not download checksums from $BASE — check that the release exists"

  # Pick the asset for this platform. The checksums file is the source of truth
  # for the exact asset name: the rolling release calls it
  # seal-aarch64-darwin.tar.gz while a versioned one calls it
  # seal-0.1.0-aarch64-darwin.tar.gz. Matching on the platform suffix handles
  # both, so this script does not need to know which channel it is talking to.
  ASSET=""
  EXPECTED=""
  # Candidates in preference order. Rosetta already resolves to aarch64 inside
  # detect_platforms; the extra x86_64-darwin entry lets an Intel Mac fall back
  # to a Rosetta-compatible build if one is ever published.
  CANDIDATES="$(detect_platforms)"
  if [ "$(detect_platforms)" = "aarch64-darwin" ]; then
    CANDIDATES="$CANDIDATES x86_64-darwin"
  fi

  for candidate in $CANDIDATES; do
    line="$(grep -E -- "-${candidate}\.tar\.gz\$" "$SUMS" | head -1 || true)"
    if [ -n "$line" ]; then
      EXPECTED="$(echo "$line" | awk '{print $1}')"
      ASSET="$(echo "$line" | awk '{print $2}')"
      break
    fi
  done

  if [ -z "$ASSET" ]; then
    warn "No build published for ${PLATFORM}. Available:"
    awk '{print "  " $2}' "$SUMS" >&2
    die "no matching artifact for this platform"
  fi

  info "Downloading ${ASSET}"
  fetch "$BASE/$ASSET" "$TMP/$ASSET" || die "could not download $BASE/$ASSET"

  info "Verifying checksum"
  ACTUAL="$(sha256_of "$TMP/$ASSET")"
  if [ "$ACTUAL" != "$EXPECTED" ]; then
    die "checksum mismatch for ${ASSET}
  expected ${EXPECTED}
  actual   ${ACTUAL}
Refusing to install a corrupted or tampered download."
  fi
  ok "Checksum verified"
  ARCHIVE="$TMP/$ASSET"
fi

# ── extract ────────────────────────────────────────────────────────────────
info "Extracting"
case "$ARCHIVE" in
  *.tar.gz) tar -xzf "$ARCHIVE" -C "$TMP" ;;
  *) die "unexpected archive type: $ARCHIVE" ;;
esac

[ -d "$TMP/bin" ] || die "archive did not contain a bin/ directory"
[ -f "$TMP/bin/seal" ] || die "archive did not contain bin/seal"
chmod +x "$TMP/bin/seal"

# ── install the tree ───────────────────────────────────────────────────────
# Replace the tree as a unit. Installing into a sibling directory and then
# renaming means an interrupted run cannot leave a half-written tree behind,
# and the symlink keeps pointing at a path that exists either way.
info "Installing to ${INSTALL_ROOT}"
mkdir -p "$(dirname "$INSTALL_ROOT")"
STAGE="$(dirname "$INSTALL_ROOT")/.seal-install.$$"
rm -rf "$STAGE"
mkdir -p "$STAGE"
# Keep the bin/ level: the executable resolves bin/dylibs/ relative to itself.
mv "$TMP/bin" "$STAGE/bin"
rm -rf "$INSTALL_ROOT"
mv "$STAGE" "$INSTALL_ROOT"

# ── symlink ────────────────────────────────────────────────────────────────
# A symlink is safe: seal resolves its libraries from the real path of the
# executable, not the link's location. The bare binary must never be copied.
mkdir -p "$BIN_HOME"
if [ -e "$LINK_PATH" ] && [ ! -L "$LINK_PATH" ]; then
  warn "Replacing existing non-symlink $LINK_PATH"
  rm -f "$LINK_PATH"
fi
ln -sfn "$INSTALL_ROOT/bin/seal" "$LINK_PATH"
ok "Linked ${LINK_PATH}"

# ── PATH ───────────────────────────────────────────────────────────────────
PATH_LINE="export PATH=\"${BIN_HOME}:\$PATH\""

case ":${PATH}:" in
  *":${BIN_HOME}:"*)
    # Already on PATH; nothing to do.
    ;;
  *)
    if [ "$MODIFY_PATH" -eq 1 ]; then
      SHELL_NAME="$(basename "${SHELL:-/bin/sh}")"
      case "$SHELL_NAME" in
        zsh)
          # .zshrc is what interactive zsh actually reads; ZDOTDIR moves it.
          RC="${ZDOTDIR:-$HOME}/.zshrc" ;;
        bash)
          # macOS terminals start login shells, which read .bash_profile;
          # Linux terminals usually start non-login shells (.bashrc). Writing
          # .profile covers both, but match the platform's convention first.
          if [ "$(uname -s)" = "Darwin" ]; then
            RC="$HOME/.bash_profile"
          else
            RC="$HOME/.bashrc"
          fi ;;
        fish)
          RC="${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish"
          PATH_LINE="fish_add_path \"${BIN_HOME}\"" ;;
        *)
          RC="" ;;
      esac

      if [ -n "$RC" ]; then
        mkdir -p "$(dirname "$RC")"
        if ! grep -qF "$BIN_HOME" "$RC" 2>/dev/null; then
          printf '\n# Added by the seal installer\n%s\n' "$PATH_LINE" >> "$RC"
          ok "Added ${BIN_HOME} to PATH in ${RC}"
          warn "Restart your shell (or \`source ${RC}\`) to pick it up"
        fi
      else
        warn "Unknown shell '${SHELL_NAME}'. Add this to your shell config:"
        warn "  ${PATH_LINE}"
      fi
    else
      warn "Add this to your shell config to put seal on PATH:"
      warn "  ${PATH_LINE}"
    fi ;;
esac

# ── verify ─────────────────────────────────────────────────────────────────
# A binary that installs but cannot start is the failure this whole script
# exists to prevent, so prove it runs before claiming success. This is not
# theoretical: it caught a staging bug that flattened bin/ during development.
#
# `seal --help` exercises dyld (it needs the bundled libncursesw/libgmp/etc),
# so a resolution failure shows up here rather than on the user's first run.
if ! "$LINK_PATH" --help >/dev/null 2>&1; then
  die "installed seal but it failed to run — please report this at
https://github.com/${REPO}/issues"
fi

# seal has no --version flag, so report the source of the install instead of
# trying to introspect the binary.
printf '\n' >&2
ok "seal installed${VERSION:+ (version ${VERSION})}"
info "  tree: ${INSTALL_ROOT}"
info "  exe:  ${LINK_PATH}"
printf '\n' >&2
info "Keep ${INSTALL_ROOT}/bin together — seal loads its libraries from"
info "bin/dylibs/ beside the executable. Do not copy the bare binary."
printf '\n' >&2
info "Next: seal --help"
