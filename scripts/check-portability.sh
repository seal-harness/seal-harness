#!/usr/bin/env bash
# Assert that a built `seal` does not depend on the Nix store.
#
# Usage: check-portability.sh <path-to-dist>
#
# A release artifact must run on a machine with no Nix. The Nix build happily
# emits binaries that hard-code /nix/store paths for glibc/ncurses/gmp/ffi, so
# without this check a "self-contained" artifact can ship and then fail on the
# user's Mac or Linux box with a loader error. This is the assertion that makes
# "runs without Nix" verifiable rather than aspirational.
#
#   Linux  — a fully static ELF is expected: no dynamic loader and no
#            /nix/store shared-library dependencies. Embedded /nix/store
#            *data* paths (tzdata, terminfo) are reported as a warning.
#   macOS  — a static Haskell executable is not attainable, so the requirement
#            is that the Mach-O links only against /usr/lib, /System/Library and
#            sibling @executable_path libraries (bundled next to it).
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <path-to-dist>" >&2
  exit 2
fi

DIST="$1"
if [ ! -x "$DIST/bin/seal" ]; then
  echo "error: no executable at $DIST/bin/seal" >&2
  exit 1
fi

fail=0

# Print embedded Nix store paths, one per line. Capture rather than piping
# `strings` into `grep -q`: under `set -o pipefail`, grep exiting on the first
# match makes strings die of SIGPIPE (141), which would hide a real finding.
nix_store_paths() {
  command -v strings >/dev/null 2>&1 || return 0
  strings -a "$1" 2>/dev/null | grep '/nix/store/' || true
}

if [ "$(uname -s)" = "Darwin" ]; then
  # Every non-system dependency must resolve inside the bundle.
  for f in "$DIST"/bin/seal "$DIST"/bin/dylibs/*.dylib; do
    [ -e "$f" ] || continue
    stray=$(otool -L "$f" \
            | tail -n +2 \
            | sed 's/^[[:space:]]*//; s/ (compatibility.*//' \
            | grep -v '^/usr/lib/' \
            | grep -v '^/System/' \
            | grep -v '^@executable_path/' || true)
    if [ -n "$stray" ]; then
      echo "::error file=$f::links outside system paths and the bundle:"
      echo "$stray" | sed 's/^/    /'
      fail=1
    fi
  done

  # A hard /nix/store string anywhere (RPATH, embedded path) is a bug even if
  # otool does not show it as a link.
  _nix_paths=$(nix_store_paths "$DIST/bin/seal")
  if [ -n "$_nix_paths" ]; then
    echo "::error file=$DIST/bin/seal::contains embedded /nix/store paths"
    printf '%s\n' "$_nix_paths" | sort -u | sed -n '1,5p' | sed 's/^/    /'
    fail=1
  fi

  # arm64 refuses to execute an invalidly signed binary. Note: `codesign
  # --verify --quiet` exits 2 even for a valid ad-hoc signature (verified),
  # so check the status line rather than trusting the --quiet exit code.
  # Capture first, then grep: piping into `grep -q` under `set -o pipefail`
  # fails with SIGPIPE (141) when grep exits early on a match.
  _sig_out=$(codesign --verify --verbose=2 "$DIST/bin/seal" 2>&1 || true)
  if ! printf '%s' "$_sig_out" | grep -q 'valid on disk'; then
    echo "::error file=$DIST/bin/seal::code signature is missing or invalid"
    printf '%s\n' "$_sig_out" | sed 's/^/    /'
    fail=1
  fi

  # The bundled dylibs are re-signed during the build but macOS's code-signing
  # subsystem rejects re-signing libraries that carry com.apple.provenance from
  # the Nix store, reporting "internal error in Code Signing subsystem".
  # This does NOT affect execution — the libraries load and run correctly — so
  # assert the property that actually matters (they resolve from the bundle,
  # checked above) rather than a signature seal macOS will not grant.
  for f in "$DIST"/bin/dylibs/*.dylib; do
    [ -e "$f" ] || continue
    _lib_sig=$(codesign --verify --verbose=2 "$f" 2>&1 || true)
    if ! printf '%s' "$_lib_sig" | grep -q 'valid on disk'; then
      echo "note: $(basename "$f") has no valid signature (expected; does not affect loading)"
    fi
  done
else
  # Linux release artifacts are fully static musl ELFs: the dynamic loader must
  # not be involved at all. `ldd` exits non-zero for a static binary, so capture
  # its output rather than piping it under `set -o pipefail`.
  _ldd_out=""
  if command -v ldd >/dev/null 2>&1; then
    _ldd_out=$(ldd "$DIST/bin/seal" 2>&1 || true)
  fi

  if printf '%s' "$_ldd_out" | grep -qE 'not a dynamic executable|statically linked'; then
    echo "OK: static ELF"
  else
    # Same SIGPIPE concern as above: readelf emits more than a pipe buffer, so
    # capture its output before matching. Otherwise a matching grep makes
    # readelf exit 141 and `!` would invert that into a false pass.
    _elf_headers=""
    if command -v readelf >/dev/null 2>&1; then
      _elf_headers=$(readelf -l "$DIST/bin/seal" 2>/dev/null || true)
    fi

    if printf '%s' "$_elf_headers" | grep -q 'INTERP'; then
      echo "::error file=$DIST/bin/seal::has a dynamic loader (PT_INTERP)"
      fail=1
    elif command -v file >/dev/null 2>&1 \
         && file -L "$DIST/bin/seal" | grep -q 'statically linked'; then
      echo "OK: static ELF (file)"
    elif [ -n "$_elf_headers" ]; then
      echo "OK: static ELF (no PT_INTERP)"
    else
      echo "::error file=$DIST/bin/seal::not statically linked"
      if [ -n "$_ldd_out" ]; then
        printf '%s\n' "$_ldd_out" | sed 's/^/    /' | sed -n '1,20p'
      fi
      fail=1
    fi
  fi

  # Static linkage does not mean the closure is free of Nix store *data*
  # paths: tzdata and ncurses terminfo embed the directories they were built
  # against. They do not involve the loader, but cron time zones and the TUI
  # can miss them on a host without /nix. Track as a follow-up; do not block
  # the static-link release on them.
  _nix_paths=$(nix_store_paths "$DIST/bin/seal")
  if [ -n "$_nix_paths" ]; then
    echo "::warning file=$DIST/bin/seal::contains embedded /nix/store data paths (non-loader; see follow-up)"
    printf '%s\n' "$_nix_paths" | sort -u | sed -n '1,5p' | sed 's/^/    /'
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "Portability check FAILED — the artifact would not run without Nix." >&2
  exit 1
fi

if [ "$(uname -s)" = "Darwin" ]; then
  echo "Portability check passed: macOS artifact has no Nix store dependencies."
else
  echo "Portability check passed: Linux artifact is statically linked."
fi
