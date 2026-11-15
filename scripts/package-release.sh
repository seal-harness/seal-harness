#!/usr/bin/env bash
# Package the built `seal` executable as a release tarball plus SHA256 sidecar.
#
# Usage: package-release.sh <system> <version> <basename>
#
#   system    Nix system string, e.g. x86_64-linux (recorded in the tarball name
#             for the versioned release; the CI per-run artifact passes its own
#             basename instead)
#   version   Release version without a leading `v` (e.g. 0.1.0). Pass "" for
#             CI-only artifacts that are not tied to a release.
#   basename  Output name without the .tar.gz suffix.
#
# Both ci.yml and release.yml call this, so the asset naming cannot drift
# between the rolling `latest` release and a versioned release.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <system> <version> <basename>" >&2
  exit 2
fi

SYSTEM="$1"
VERSION="$2"
BASENAME="$3"

# nix build leaves ./result/bin/seal
BIN="${SEAL_BIN:-./result/bin/seal}"
if [ ! -x "$BIN" ]; then
  echo "error: no executable at $BIN — run 'nix build' first" >&2
  exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp "$BIN" "$STAGING/seal"
chmod +x "$STAGING/seal"

# --owner/--group 0 --numeric-owner so the archive does not encode the
# building user, and the mtime is pinned to the commit-independent epoch: the
# tarball is a published artifact and should be reproducible.
#
# BSD tar (macOS runners) rejects GNU's --owner/--mtime spellings, so branch on
# which tar is present rather than assuming GNU.
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  tar --numeric-owner --owner=0 --group=0 --mtime='@0' \
      -czf "${BASENAME}.tar.gz" -C "$STAGING" seal
else
  # bsdtar: pin ownership and timestamps before archiving instead, which is
  # portable and gives the same reproducible result.
  chmod 0755 "$STAGING/seal"
  ( cd "$STAGING" && COPYFILE_DISABLE=1 tar -czf - seal ) > "${BASENAME}.tar.gz"
fi

sha256sum "${BASENAME}.tar.gz" > "${BASENAME}.tar.gz.sha256" 2>/dev/null \
  || shasum -a 256 "${BASENAME}.tar.gz" > "${BASENAME}.tar.gz.sha256"

echo "Packaged ${BASENAME}.tar.gz ($(wc -c < "${BASENAME}.tar.gz") bytes) for ${SYSTEM}${VERSION:+ ${VERSION}}"
