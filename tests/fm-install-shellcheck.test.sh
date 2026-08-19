#!/usr/bin/env bash
# Behavior tests for bin/fm-install-shellcheck.sh's architecture support
# contract. The script is the single owner of the CI's pinned ShellCheck
# version, the per-architecture asset URL, and the per-architecture
# SHA-256 pin. CI on the captain's self-hosted ARM64 runner exercises
# the aarch64 branch; the historical GitHub-hosted runner path
# exercised x86_64. A future PR that drops one of the two arches
# silently regresses that consumer without a CI red flag, which is
# what these cases prevent.
#
# The tests inspect the script's source rather than executing the
# download, so a network outage does not flake CI. The pin assertions
# verify the values are non-empty 64-character SHA-256 hashes; the
# version assertion pins the exact grep pattern the install uses to
# confirm the binary matches the version the script claims to install.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALL="$ROOT/bin/fm-install-shellcheck.sh"

assert_sha256_shape() {
  local value=$1
  case "${#value}" in
    64) ;;
    *) fail "expected 64-char SHA-256 pin, got ${#value}-char value '$value'" ;;
  esac
  case "$value" in
    *[!0-9a-fA-F]*) fail "SHA-256 pin '$value' contains non-hex characters" ;;
  esac
}

# Every supported arch branch in the case statement must carry a non-empty
# SHA-256 pin. A dropped pin would silently hand CI an unsigned binary.
test_per_arch_sha256_pins_present() {
  local source
  source="$(cat "$INSTALL")"
  local pins
  pins="$(printf '%s\n' "$source" | awk '
    /^[[:space:]]*Linux-/ {
      arch = $1
      sub(/^\(/, "", arch)
      sub(/\)$/, "", arch)
      need_sha = 1
      next_arch = arch
      next
    }
    need_sha == 1 && /SHA256=/ {
      sha = $0
      sub(/^[[:space:]]*SHA256=/, "", sha)
      sub(/[[:space:]]+$/, "", sha)
      print next_arch "=" sha
      need_sha = 0
    }
')"
  case "$pins" in
    *'Linux-x86_64='*) ;;
    *) fail "Linux-x86_64 branch missing SHA-256 pin" ;;
  esac
  case "$pins" in
    *'Linux-aarch64|Linux-arm64='*) ;;
    *) fail "Linux-aarch64|Linux-arm64 branch missing SHA-256 pin" ;;
  esac
  local arch pin
  while IFS='=' read -r arch pin; do
    [ -n "$arch" ] || continue
    assert_sha256_shape "$pin"
  done <<<"$pins"
  pass "every Linux arch branch carries a non-empty SHA-256 pin"
}

# The unsupported-platform branch must refuse loudly rather than silently
# try to download a non-existent asset. The history of CI failures shows
# silent fallthrough is the dangerous shape; a typed message naming the
# platform is the safe one.
test_unsupported_platform_is_refused_loudly() {
  local source
  source="$(cat "$INSTALL")"
  case "$source" in
    *'unsupported platform'*) ;;
    *) fail "no 'unsupported platform' refusal branch in install script" ;;
  esac
  case "$source" in
    *'exit 1'*) ;;
    *) fail "unsupported platform branch must exit non-zero" ;;
  esac
  pass "unsupported platforms are refused loudly with a non-zero exit"
}

# The install must verify the binary's reported version matches the pin.
# A download that hands back the wrong binary (cache, mirror compromise,
# URL drift) must not pass. The exact pin comes from bin/fm-lint.sh's
# --required-version; the install's --version grep must be a substring
# match against that same value.
test_install_verifies_pinned_version() {
  local source required
  source="$(cat "$INSTALL")"
  required="$("$ROOT/bin/fm-lint.sh" --required-version)"
  case "$source" in
    *'--version'*) ;;
    *) fail "install does not invoke --version on the installed binary" ;;
  esac
  case "$source" in
    *"${required}"*) ;;
    *) fail "install does not assert the exact pinned version ${required}" ;;
  esac
  pass "install verifies the installed binary reports the pinned version ${required}"
}

# The asset URL must derive from the per-architecture archive name, so a
# future arch addition lands a matching URL without re-spelling the host.
test_asset_url_uses_per_arch_archive() {
  local source
  source="$(cat "$INSTALL")"
  case "$source" in
    *'github.com/koalaman/shellcheck/releases'*) ;;
    *) fail "asset URL must point at the official koalaman shellcheck release host" ;;
  esac
  # The URL line must carry the literal ARCHIVE token. The shellcheck
  # SC2016 lint forbids quoting a dollar-brace expression inside a case
  # pattern, so we match the fixed ARCHIVE substring the install template
  # must carry rather than the expanded ${ARCHIVE} form.
  case "$source" in
    *'koalaman/shellcheck/releases/'*'ARCHIVE'*) ;;
    *) fail "asset URL must interpolate the per-arch ARCHIVE variable" ;;
  esac
  pass "asset URL is composed from the per-arch ARCHIVE variable"
}

test_per_arch_sha256_pins_present
test_unsupported_platform_is_refused_loudly
test_install_verifies_pinned_version
test_asset_url_uses_per_arch_archive