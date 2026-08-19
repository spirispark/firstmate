#!/usr/bin/env bash
# fm-install-node.sh - install CI's pinned, verified Node.js LTS build.
#
# Single owner of the exact Node.js version, the official release asset URL,
# and the per-architecture SHA-256 pin used by every CI lane that consumes
# Node.js. Never installs a floating "latest" or an Ubuntu-distro default.
#
# Usage:
#   fm-install-node.sh <destination-directory>
#
# Pins Node.js v22.23.2 (LTS "Jod"). The minimum LTS line that supports
# importing TypeScript files natively (Node.js 22.6+) is required by several
# behavior tests (e.g. tests/fm-calm-pi-extension.test.sh's
# test_pi_compat_missing_adapter_exports, tests/fm-pi-watch-extension.test.sh,
# tests/fm-sessionstart-nudge.test.sh, tests/fm-turnend-guard.test.sh,
# tests/fm-busy-adapter-wiring.test.sh, tests/fm-operational-input.test.sh,
# tests/fm-graphify-harness.test.sh) which load .ts sources directly with
# `pathToFileURL(...)`. The captain's self-hosted ARM64 Docker runner image
# (ci-runner:2.336.0-tools-v3) ships Ubuntu 24.04's stock Node.js 18, which
# cannot parse .ts - a regression vs. the historical ubuntu-latest runner's
# Node 22 default. Pinning LTS here restores that contract on the new runner.
#
# Selects the official Node.js Linux release asset for the host OS/arch,
# downloads it with bounded retries, verifies SHA-256 before install, then
# refuses to finish unless the installed binary reports the exact pinned
# version. A test in tests/fm-install-node.test.sh asserts every supported
# arch has a non-empty pin and that the install resolves the binaries the
# script claims to.
set -eu

# Exact pin - change only with a re-verified Node.js LTS round-trip.
FM_NODE_CI_VERSION=22.23.2
# Bounded download ceiling (bytes). The largest official Linux 22.23.2
# asset is under 30 MiB.
FM_NODE_CI_MAX_BYTES=32000000

die() {
  printf 'fm-install-node.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-node.sh <destination-directory>}

os=$(uname -s)
arch=$(uname -m)
case "${os}-${arch}" in
  Linux-x86_64)
    ASSET="node-v${FM_NODE_CI_VERSION}-linux-x64.tar.xz"
    SHA256=d60acfe00a2932254bb0ad20e01b0d74397a0875595de719654b214f4b03f307
    ;;
  Linux-aarch64|Linux-arm64)
    ASSET="node-v${FM_NODE_CI_VERSION}-linux-arm64.tar.xz"
    SHA256=fff4078c5def658577f92c88db7db3bc0072924bfb93fe52c1e744a54e94abb8
    ;;
  *)
    die "unsupported platform ${os}-${arch}; this script installs the official Node.js v${FM_NODE_CI_VERSION} Linux x86_64/aarch64 assets only"
    ;;
esac

URL="https://nodejs.org/dist/v${FM_NODE_CI_VERSION}/${ASSET}"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-node.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

printf 'fm-install-node.sh: downloading %s from %s\n' "$ASSET" "$URL" >&2
# --fail: HTTP errors; --location: follow redirects; --max-filesize: bound.
curl -fsSL --max-filesize "$FM_NODE_CI_MAX_BYTES" "$URL" -o "$TMP/$ASSET" \
  || die "download failed for $URL (bounded at $FM_NODE_CI_MAX_BYTES bytes)"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ASSET" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify the Node.js asset"
fi

[ "$ACTUAL_SHA256" = "$SHA256" ] || die "checksum mismatch for $ASSET (expected $SHA256, got $ACTUAL_SHA256)"

tar -xJf "$TMP/$ASSET" -C "$TMP"
EXTRACTED="$TMP/node-v${FM_NODE_CI_VERSION}-linux-$(case "$arch" in x86_64) echo x64 ;; aarch64|arm64) echo arm64 ;; esac)"
[ -x "$EXTRACTED/bin/node" ] || die "extracted archive does not contain a node binary at $EXTRACTED/bin/node"

# Post-extract version gate (no floating latest): refuse to copy a
# binary that does not report the exact pinned version, so a cache,
# mirror compromise, or URL drift cannot leave a wrong-versioned
# binary at the destination the caller is about to put on PATH.
"$EXTRACTED/bin/node" --version | grep -F "v${FM_NODE_CI_VERSION}" >/dev/null \
  || die "extracted binary did not report pinned version v${FM_NODE_CI_VERSION}"

mkdir -p "$DESTINATION"
install -m 0755 "$EXTRACTED/bin/node" "$DESTINATION/node"
install -m 0755 "$EXTRACTED/bin/npm" "$DESTINATION/npm"
install -m 0755 "$EXTRACTED/bin/npx" "$DESTINATION/npx"
if [ -x "$EXTRACTED/bin/corepack" ]; then
  install -m 0755 "$EXTRACTED/bin/corepack" "$DESTINATION/corepack"
fi

printf 'fm-install-node.sh: installed node %s to %s\n' \
  "$("$DESTINATION/node" --version)" "$DESTINATION/node" >&2
"$DESTINATION/node" --version
