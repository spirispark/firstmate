#!/usr/bin/env bash
# tests/shellcheck-install-helpers.sh - shared shims for the two suites that
# drive bin/fm-install-shellcheck.sh for real (fm-install-shellcheck and
# fm-lint).
#
# The installer resolves a host platform, downloads the matching release asset,
# verifies its SHA-256 against a per-architecture pin, unpacks it, and refuses a
# binary that does not report the pinned version. Exercising any part of that
# needs the same four shims - uname, curl, sha256sum, tar - so they live here
# rather than being re-rolled per suite, where every installer change has to be
# mirrored into each copy. The generic fakebin/temp-root primitives come from
# tests/lib.sh, which this file pulls in.
#
# The digests below are the upstream SHA-256 of the official ShellCheck Linux
# release assets: the contract the installer must enforce, so a pin edited in
# the script without re-verifying it upstream fails the suites that use them.

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FM_SHELLCHECK_VERSION="$("$ROOT/bin/fm-lint.sh" --required-version)"
FM_SHELLCHECK_SHA256_X86_64=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
FM_SHELLCHECK_SHA256_AARCH64=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588

# fm_shellcheck_pin <uname-m>: the upstream digest the installer must enforce on
# that machine type; empty for a machine the installer does not support.
fm_shellcheck_pin() {
  case "$1" in
    x86_64) printf '%s\n' "$FM_SHELLCHECK_SHA256_X86_64" ;;
    aarch64|arm64) printf '%s\n' "$FM_SHELLCHECK_SHA256_AARCH64" ;;
    *) printf '%s\n' '' ;;
  esac
}

# fm_shellcheck_fakebin <tmp> <uname-s> <uname-m>: echo a fakebin dir that pins
# the host platform and shims the installer's download/verify path. Every knob
# is optional and read by the stubs at run time:
#   FM_FAKE_CURL_LOG        - file each requested asset URL is appended to
#   FM_FAKE_CURL_COUNT      - file the download attempt counter is kept in
#   FM_FAKE_CURL_FAILURES   - how many leading attempts fail with curl's 22
#   FM_FAKE_SHA256          - digest sha256sum reports (default: the host pin)
#   FM_FAKE_ARCHIVE_VERSION - version in the unpacked directory name
#   FM_FAKE_BINARY_VERSION  - version the unpacked binary reports
fm_shellcheck_fakebin() {
  local tmp=$1 os=$2 machine=$3 fakebin default_sha
  fakebin=$(fm_fakebin "$tmp")
  default_sha=$(fm_shellcheck_pin "$machine")

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
[ -z "${FM_FAKE_CURL_LOG:-}" ] || printf '%s\n' "$url" >> "$FM_FAKE_CURL_LOG"
count=0
if [ -n "${FM_FAKE_CURL_COUNT:-}" ]; then
  [ ! -f "$FM_FAKE_CURL_COUNT" ] || count=$(cat "$FM_FAKE_CURL_COUNT")
  count=$((count + 1))
  printf '%s\n' "$count" > "$FM_FAKE_CURL_COUNT"
fi
if [ "${FM_FAKE_CURL_FAILURES:-0}" -gt 0 ] && [ "$count" -le "${FM_FAKE_CURL_FAILURES:-0}" ]; then
  exit 22
fi
[ -n "$out" ] || exit 2
: > "$out"
SH

  cat > "$fakebin/sha256sum" <<SH
#!/usr/bin/env bash
printf '%s  %s\n' "\${FM_FAKE_SHA256:-$default_sha}" "\$1"
SH

  cat > "$fakebin/tar" <<SH
#!/usr/bin/env bash
archive_version=\${FM_FAKE_ARCHIVE_VERSION:-$FM_SHELLCHECK_VERSION}
binary_version=\${FM_FAKE_BINARY_VERSION:-$FM_SHELLCHECK_VERSION}
dest=""
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = "-C" ]; then
    dest=\${2:-}
    break
  fi
  shift
done
[ -n "\$dest" ] || exit 2
mkdir -p "\$dest/shellcheck-v\$archive_version"
cat > "\$dest/shellcheck-v\$archive_version/shellcheck" <<EOF
#!/usr/bin/env bash
printf 'ShellCheck - shell script analysis tool\nversion: \$binary_version\n'
EOF
chmod +x "\$dest/shellcheck-v\$archive_version/shellcheck"
SH

  fm_fake_exit0 "$fakebin" sleep
  chmod +x "$fakebin/uname" "$fakebin/curl" "$fakebin/sha256sum" "$fakebin/tar"
  printf '%s\n' "$fakebin"
}
