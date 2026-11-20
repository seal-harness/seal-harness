#!/usr/bin/env bash
# Package the portable `seal` distribution as a release tarball plus a SHA256
# sidecar.
#
# Usage: package-release.sh <system> <version> <basename>
#
#   system    Nix system string, e.g. x86_64-linux
#   version   Release version without a leading `v` (e.g. 0.1.0). Pass "" for
#             CI-only artifacts that are not tied to a release.
#   basename  Output name without the .tar.gz suffix.
#
# Both ci.yml and release.yml call this, so asset naming cannot drift between
# the rolling `latest` release and a versioned release.
#
# The input is the `dist` output of the flake (a bin/ tree holding `seal` and,
# on macOS, the shared libraries it needs beside it). The whole tree is
# archived so the binary keeps working on a machine with no Nix.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <system> <version> <basename>" >&2
  exit 2
fi

SYSTEM="$1"
VERSION="$2"
BASENAME="$3"

# `nix build .#dist` leaves ./result/bin
DIST="${SEAL_DIST:-./result}"
if [ ! -d "$DIST/bin" ]; then
  echo "error: no bin/ at $DIST — run 'nix build .#dist' first" >&2
  exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

# Copy the tree, resolving the ./result symlink. Timestamps are pinned so the
# archive is reproducible.
cp -rL "$DIST"/. "$STAGING"/
chmod -R u+w "$STAGING"
find "$STAGING" -exec touch -t 198001010000 {} +

# Strip macOS extended attributes: bsdtar would otherwise add AppleDouble ._
# entries, which are useless in a Linux-consumed archive and break reproducible
# hashing.
if command -v xattr >/dev/null 2>&1; then
  find "$STAGING" -exec xattr -c {} + 2>/dev/null || true
fi

# Reproducible archiving. GNU tar can pin ownership and mtime directly; bsdtar
# (macOS) cannot, so the mtimes are pinned above instead. Either way the gzip
# stream must be `-n` — without it gzip records its own creation time in header
# bytes 4-7 and the archive differs run to run even for identical payloads.
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  tar --numeric-owner --owner=0 --group=0 --mtime='@0' \
      -czf "${BASENAME}.tar.gz" -C "$STAGING" .
else
  ( cd "$STAGING" && COPYFILE_DISABLE=1 tar -cf - . | gzip -n ) > "${BASENAME}.tar.gz"
fi

sha256sum "${BASENAME}.tar.gz" > "${BASENAME}.tar.gz.sha256" 2>/dev/null \
  || shasum -a 256 "${BASENAME}.tar.gz" > "${BASENAME}.tar.gz.sha256"

echo "Packaged ${BASENAME}.tar.gz ($(wc -c < "${BASENAME}.tar.gz") bytes) for ${SYSTEM}${VERSION:+ ${VERSION}}"
