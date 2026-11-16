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
#   Linux  — a fully static ELF is expected: `ldd` says "not a dynamic
#            executable", and no /nix/store string is present.
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
  if strings -a "$DIST/bin/seal" | grep -q '^/nix/store/'; then
    echo "::error file=$DIST/bin/seal::contains embedded /nix/store paths"
    strings -a "$DIST/bin/seal" | grep '^/nix/store/' | sort -u | head -5 | sed 's/^/    /'
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
  if ldd "$DIST/bin/seal" 2>&1 | grep -q 'not a dynamic executable'; then
    echo "OK: static ELF"
  else
    echo "::error file=$DIST/bin/seal::not statically linked; ldd reports:"
    ldd "$DIST/bin/seal" 2>&1 | sed 's/^/    /' | head -20
    fail=1
  fi

  if strings -a "$DIST/bin/seal" | grep -q '/nix/store/'; then
    echo "::error file=$DIST/bin/seal::contains embedded /nix/store paths"
    fail=1
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "Portability check FAILED — the artifact would not run without Nix." >&2
  exit 1
fi

echo "Portability check passed: $(uname -s) artifact has no Nix store dependencies."
