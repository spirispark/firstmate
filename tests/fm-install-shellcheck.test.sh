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
# Every case runs the real installer with curl, sha256sum, tar and uname
# shimmed on PATH, so the assertions are about what the install actually
# does - which asset URL it requests for a host arch, which digest it
# accepts, and which failures it refuses - not about what its source text
# says. The two SHA-256 constants below are the upstream digests of the
# official ShellCheck v0.11.0 Linux release assets; they are the contract
# the install must enforce, so changing a pin in the script without
# re-verifying it upstream fails here.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALL="$ROOT/bin/fm-install-shellcheck.sh"
VERSION="$("$ROOT/bin/fm-lint.sh" --required-version)"

SHA256_X86_64=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
SHA256_AARCH64=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588

# fm_shellcheck_fakebin <tmp> <uname-s> <uname-m>: build a PATH shim dir that
# pins the host platform, records every requested download URL, reports the
# digest named by FM_FAKE_SHA256, and unpacks an archive whose layout and
# reported version come from FM_FAKE_ARCHIVE_VERSION/FM_FAKE_BINARY_VERSION.
fm_shellcheck_fakebin() {
  local tmp=$1 os=$2 machine=$3 fakebin
  fakebin=$(fm_fakebin "$tmp")

  cat > "$fakebin/uname" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  -s) printf '%s\n' '$os' ;;
  -m) printf '%s\n' '$machine' ;;
  *) printf '%s\n%s\n' '$os' '$machine' ;;
esac
SH

  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
url=""
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=${2:-}; shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
printf '%s\n' "$url" >> "$FM_FAKE_CURL_LOG"
[ -n "$out" ] || exit 2
: > "$out"
SH

  cat > "$fakebin/sha256sum" <<'SH'
#!/usr/bin/env bash
printf '%s  %s\n' "$FM_FAKE_SHA256" "$1"
SH

  cat > "$fakebin/tar" <<'SH'
#!/usr/bin/env bash
dest=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-C" ]; then
    dest=${2:-}
    break
  fi
  shift
done
[ -n "$dest" ] || exit 2
mkdir -p "$dest/shellcheck-v$FM_FAKE_ARCHIVE_VERSION"
cat > "$dest/shellcheck-v$FM_FAKE_ARCHIVE_VERSION/shellcheck" <<EOF
#!/usr/bin/env bash
printf 'ShellCheck - shell script analysis tool\nversion: $FM_FAKE_BINARY_VERSION\n'
EOF
chmod +x "$dest/shellcheck-v$FM_FAKE_ARCHIVE_VERSION/shellcheck"
SH

  chmod +x "$fakebin/uname" "$fakebin/curl" "$fakebin/sha256sum" "$fakebin/tar"
  printf '%s\n' "$fakebin"
}

# fm_run_install <fakebin> <tmp> <sha> <destination>: run the installer under
# the shims and echo its combined output; the caller owns the exit code.
fm_run_install() {
  local fakebin=$1 tmp=$2 sha=$3 destination=$4
  PATH="$fakebin:$PATH" \
    FM_FAKE_CURL_LOG="$tmp/curl.log" \
    FM_FAKE_SHA256="$sha" \
    FM_FAKE_ARCHIVE_VERSION="${FM_FAKE_ARCHIVE_VERSION:-$VERSION}" \
    FM_FAKE_BINARY_VERSION="${FM_FAKE_BINARY_VERSION:-$VERSION}" \
    "$INSTALL" "$destination" 2>&1
}

# The self-hosted ARM64 runner is the consumer that needs the aarch64 branch:
# it must resolve the aarch64 asset and accept only the aarch64 digest.
test_aarch64_host_installs_the_aarch64_asset() {
  local tmp fakebin destination out rc=0
  tmp=$(fm_test_tmproot fm-shellcheck-aarch64)
  fakebin=$(fm_shellcheck_fakebin "$tmp" Linux aarch64)
  destination="$tmp/bin"

  out=$(fm_run_install "$fakebin" "$tmp" "$SHA256_AARCH64" "$destination") || rc=$?
  expect_code 0 "$rc" "aarch64 install"$'\n'"$out"
  assert_grep \
    "https://github.com/koalaman/shellcheck/releases/download/v${VERSION}/shellcheck-v${VERSION}.linux.aarch64.tar.xz" \
    "$tmp/curl.log" \
    "aarch64 host did not request the official aarch64 release asset"
  [ -x "$destination/shellcheck" ] || fail "aarch64 install left no executable at $destination/shellcheck"
  pass "Linux-aarch64 installs the pinned aarch64 ShellCheck asset"
}

# uname -m reports arm64 rather than aarch64 on some ARM64 Linux hosts; both
# must land on the same asset and the same pin.
test_arm64_alias_installs_the_aarch64_asset() {
  local tmp fakebin destination out rc=0
  tmp=$(fm_test_tmproot fm-shellcheck-arm64)
  fakebin=$(fm_shellcheck_fakebin "$tmp" Linux arm64)
  destination="$tmp/bin"

  out=$(fm_run_install "$fakebin" "$tmp" "$SHA256_AARCH64" "$destination") || rc=$?
  expect_code 0 "$rc" "arm64 install"$'\n'"$out"
  assert_grep "shellcheck-v${VERSION}.linux.aarch64.tar.xz" "$tmp/curl.log" \
    "Linux-arm64 did not resolve to the aarch64 asset"
  [ -x "$destination/shellcheck" ] || fail "arm64 install left no executable at $destination/shellcheck"
  pass "Linux-arm64 resolves to the same pinned aarch64 asset"
}

test_x86_64_host_installs_the_x86_64_asset() {
  local tmp fakebin destination out rc=0
  tmp=$(fm_test_tmproot fm-shellcheck-x86)
  fakebin=$(fm_shellcheck_fakebin "$tmp" Linux x86_64)
  destination="$tmp/bin"

  out=$(fm_run_install "$fakebin" "$tmp" "$SHA256_X86_64" "$destination") || rc=$?
  expect_code 0 "$rc" "x86_64 install"$'\n'"$out"
  assert_grep \
    "https://github.com/koalaman/shellcheck/releases/download/v${VERSION}/shellcheck-v${VERSION}.linux.x86_64.tar.xz" \
    "$tmp/curl.log" \
    "x86_64 host did not request the official x86_64 release asset"
  [ -x "$destination/shellcheck" ] || fail "x86_64 install left no executable at $destination/shellcheck"
  pass "Linux-x86_64 installs the pinned x86_64 ShellCheck asset"
}

# Each arch carries its own pin, and the pin is enforced: handing the aarch64
# host the x86_64 digest must refuse the download instead of installing it.
test_cross_arch_digest_is_refused() {
  local tmp fakebin destination out rc=0
  tmp=$(fm_test_tmproot fm-shellcheck-cross-arch)
  fakebin=$(fm_shellcheck_fakebin "$tmp" Linux aarch64)
  destination="$tmp/bin"

  out=$(fm_run_install "$fakebin" "$tmp" "$SHA256_X86_64" "$destination") || rc=$?
  [ "$rc" -ne 0 ] || fail "aarch64 install accepted the x86_64 digest"$'\n'"$out"
  assert_contains "$out" "checksum mismatch" "digest refusal did not name the checksum mismatch"
  assert_absent "$destination/shellcheck" "a digest mismatch must not install a binary"
  pass "a digest that does not match the host arch pin is refused"
}

# The unsupported-platform branch must refuse loudly and before any download,
# rather than silently reaching for an asset that does not exist.
test_unsupported_platform_is_refused_before_download() {
  local tmp fakebin destination out rc=0
  tmp=$(fm_test_tmproot fm-shellcheck-unsupported)
  fakebin=$(fm_shellcheck_fakebin "$tmp" Darwin arm64)
  destination="$tmp/bin"

  out=$(fm_run_install "$fakebin" "$tmp" "$SHA256_AARCH64" "$destination") || rc=$?
  [ "$rc" -ne 0 ] || fail "unsupported platform did not refuse"$'\n'"$out"
  assert_contains "$out" "unsupported platform" "refusal did not name the unsupported platform"
  assert_contains "$out" "Darwin-arm64" "refusal did not report the actual host platform"
  assert_absent "$tmp/curl.log" "an unsupported platform must refuse before any download"
  assert_absent "$destination/shellcheck" "an unsupported platform must not install a binary"
  pass "unsupported platforms are refused loudly before any download"
}

# A download that hands back a differently-versioned binary (cache, mirror
# compromise, URL drift) must not pass as the pinned install.
test_wrong_binary_version_is_refused() {
  local tmp fakebin destination out rc=0
  tmp=$(fm_test_tmproot fm-shellcheck-wrong-version)
  fakebin=$(fm_shellcheck_fakebin "$tmp" Linux aarch64)
  destination="$tmp/bin"

  out=$(FM_FAKE_BINARY_VERSION=0.10.0 \
    fm_run_install "$fakebin" "$tmp" "$SHA256_AARCH64" "$destination") || rc=$?
  [ "$rc" -ne 0 ] || fail "install accepted a binary reporting the wrong version"$'\n'"$out"
  assert_contains "$out" "did not report pinned version ${VERSION}" \
    "version refusal did not name the pinned version"
  pass "a binary that does not report the pinned version ${VERSION} is refused"
}

FM_FAKE_ARCHIVE_VERSION=${FM_FAKE_ARCHIVE_VERSION:-}
FM_FAKE_BINARY_VERSION=${FM_FAKE_BINARY_VERSION:-}

test_aarch64_host_installs_the_aarch64_asset
test_arm64_alias_installs_the_aarch64_asset
test_x86_64_host_installs_the_x86_64_asset
test_cross_arch_digest_is_refused
test_unsupported_platform_is_refused_before_download
test_wrong_binary_version_is_refused
