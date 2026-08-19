#!/usr/bin/env bash
# fm-install-shellcheck.sh - install CI's pinned, verified ShellCheck build.
#
# Single owner of the exact ShellCheck version and the per-architecture
# SHA-256 pins used by every CI lane that consumes it. Selects the
# official GitHub Releases asset for the host OS/arch, downloads it,
# verifies the SHA-256 against the per-architecture pin, then refuses
# to finish unless the binary reports the exact pinned version.
#
# Usage:
#   fm-install-shellcheck.sh <destination-directory>
#
# Pins ShellCheck v0.11.0. The x86_64 pin matches the historical
# GitHub-hosted runner install; the aarch64 pin is required for the
# captain's self-hosted ARM64 Docker runner (label set
# [self-hosted, linux, ARM64]) and any other ARM64 Linux consumer.
# A test in tests/fm-install-shellcheck.test.sh asserts that every
# supported arch has a non-empty pin and that the install resolves the
# binary the script claims to.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$("$ROOT/bin/fm-lint.sh" --required-version)"

os=$(uname -s)
arch=$(uname -m)
case "${os}-${arch}" in
  Linux-x86_64)
    ARCHIVE="shellcheck-v${VERSION}.linux.x86_64.tar.xz"
    SHA256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
    ;;
  Linux-aarch64|Linux-arm64)
    ARCHIVE="shellcheck-v${VERSION}.linux.aarch64.tar.xz"
    SHA256=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588
    ;;
  *)
    printf 'fm-install-shellcheck.sh: unsupported platform %s-%s; this script installs the official ShellCheck x86_64/aarch64 Linux assets only.\n' "$os" "$arch" >&2
    exit 1
    ;;
esac

URL="https://github.com/koalaman/shellcheck/releases/download/v${VERSION}/${ARCHIVE}"
DESTINATION=${1:?usage: fm-install-shellcheck.sh <destination-directory>}
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-shellcheck.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

DOWNLOAD_ATTEMPTS=6
download_attempt=1
while ! curl -fsSL "$URL" -o "$TMP/$ARCHIVE"; do
  [ "$download_attempt" -lt "$DOWNLOAD_ATTEMPTS" ] || {
    printf 'fm-install-shellcheck.sh: download failed after %s attempts\n' "$DOWNLOAD_ATTEMPTS" >&2
    exit 1
  }
  printf 'fm-install-shellcheck.sh: download attempt %s failed; retrying\n' "$download_attempt" >&2
  sleep $((1 << (download_attempt - 1)))
  download_attempt=$((download_attempt + 1))
done
ACTUAL_SHA256=$(sha256sum "$TMP/$ARCHIVE" | awk '{print $1}')
[ "$ACTUAL_SHA256" = "$SHA256" ] || {
  printf 'fm-install-shellcheck.sh: checksum mismatch for %s\n' "$ARCHIVE" >&2
  exit 1
}
tar -xJf "$TMP/$ARCHIVE" -C "$TMP"
EXTRACTED="$TMP/shellcheck-v${VERSION}/shellcheck"
chmod 0755 "$EXTRACTED"
"$EXTRACTED" --version | grep -F "version: ${VERSION}" >/dev/null \
  || { printf 'fm-install-shellcheck.sh: downloaded binary did not report pinned version %s\n' "$VERSION" >&2; exit 1; }
mkdir -p "$DESTINATION"
install -m 0755 "$EXTRACTED" "$DESTINATION/shellcheck"