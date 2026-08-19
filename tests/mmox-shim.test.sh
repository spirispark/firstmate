#!/usr/bin/env bash
# Behavior tests for bin/mmox-shim.sh (the bash launcher).
#
# Addresses Amazon Q findings on PR #6:
# 4. Unquoted PID variable (defensive: PID file content must be validated as
#    an integer, and corrupted PIDs must not propagate to kill).
# 5. Empty MMOX_STATE_DIR must not collapse LOG_FILE to /shim.log (a root write).
#
# Strategy: invoke the launcher in a hermetic temp root with HOME and PATH
# shimmed, then assert on the resulting state directory layout and the
# launcher's responses to status/env/start commands.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-mmox-shim)
SHIM="$ROOT/bin/mmox-shim.sh"

# Common fixture: a fake HOME plus a fakebin with curl/healthcheck stubs.
fake_home="$TMP_ROOT/home"
fake_state="$TMP_ROOT/state"
fakebin="$TMP_ROOT/fakebin"
mkdir -p "$fake_home" "$fake_state" "$fakebin"

# Stub `mmox-openai-shim.py` as a no-op so `start` exits quickly and writes
# its PID file before our assertions run.
cat > "$fakebin/mmox-openai-shim.py" <<'PY'
#!/usr/bin/env python3
import sys, time
# Become a long-running loopback until killed.
while True:
    time.sleep(60)
PY
chmod +x "$fakebin/mmox-openai-shim.py"

# Stub curl so ensure_running's poll loop doesn't hit the network.
cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
# Always succeed when the launcher probes /healthz — keeps start fast.
exit 0
SH
chmod +x "$fakebin/curl"

# Stub the Python interpreter path so SHIM resolution succeeds.
PYBIN="$TMP_ROOT/pybin"
mkdir -p "$PYBIN"
ln -sf "$(command -v python3)" "$PYBIN/python3"

# Helper: run the launcher under controlled env.
run_shim() {
  local cmd=$1
  env -i \
    HOME="$fake_home" \
    PATH="$fakebin:$PYBIN:/usr/bin:/bin" \
    MMOX_STATE_DIR="$fake_state" \
    FM_ROOT_OVERRIDE="$ROOT/bin" \
    "$SHIM" "$cmd" "$@"
}

# ---------------------------------------------------------------------------
# Finding #5: empty MMOX_STATE_DIR safety.
# ---------------------------------------------------------------------------

test_empty_state_dir_does_not_collapse_log_path() {
  local state_root="$TMP_ROOT/empty-state"
  mkdir -p "$state_root"

  # Override HOME and MMOX_STATE_DIR="" together — worst-case combo.
  local out
  out=$(env -i \
    HOME="$fake_home" \
    PATH="$fakebin:$PYBIN:/usr/bin:/bin" \
    MMOX_STATE_DIR="" \
    FM_ROOT_OVERRIDE="$ROOT/bin" \
    "$SHIM" status 2>&1) || true

  # The launcher must not have written to /shim.log (or attempted to).
  # We assert by inspecting the resolved LOG_FILE through env output instead,
  # because status() does not print it. The `env` subcommand prints the env
  # it would export — but LOG_FILE is launcher-internal. So we drive `start`
  # in a child PID that we immediately stop, then check the file layout.
  local pid_file="$state_root/shim.pid"
  local log_file="$state_root/shim.log"

  # Pre-create empty state dir; launcher must reuse it (not write to /shim.log).
  env -i \
    HOME="$fake_home" \
    PATH="$fakebin:$PYBIN:/usr/bin:/bin" \
    MMOX_STATE_DIR="" \
    FM_ROOT_OVERRIDE="$ROOT/bin" \
    "$SHIM" start >/dev/null 2>&1 || true

  # Either start succeeded (and PID+log live in state_root) or it failed cleanly.
  # In NEITHER case must a file have been created at /shim.log.
  if [ -e /shim.log ]; then
    fail "launcher wrote /shim.log when MMOX_STATE_DIR was empty (root write)"
  fi

  # When start succeeded, both PID and log files must be under state_root.
  if [ -f "$pid_file" ]; then
    assert_present "$log_file" \
      "log file must live under MMOX_STATE_DIR when MMOX_STATE_DIR is empty"
    # The PID file content must be a non-empty positive integer.
    local pid_content
    pid_content=$(cat "$pid_file")
    case "$pid_content" in
      ''|*[!0-9]*) fail "PID file must contain only digits, got: [$pid_content]" ;;
      0) fail "PID file must not be zero, got: [$pid_content]" ;;
    esac
    # Stop the background shim so the test exits cleanly.
    kill "$pid_content" 2>/dev/null || true
    rm -f "$pid_file" "$log_file"
  fi

  pass "empty MMOX_STATE_DIR does not collapse LOG_FILE to /shim.log"
}

test_unset_state_dir_uses_default_under_home() {
  local out
  out=$(env -i \
    HOME="$fake_home" \
    PATH="$fakebin:$PYBIN:/usr/bin:/bin" \
    FM_ROOT_OVERRIDE="$ROOT/bin" \
    "$SHIM" status 2>&1) || true
  # When state dir is unset, the launcher uses ~/.cache/mmox-shim.
  # We assert the launcher doesn't crash; the resolved location is internal.
  case "$out" in
    stopped|running*) pass "unset MMOX_STATE_DIR: launcher responds normally" ;;
    *) fail "launcher output unexpected when MMOX_STATE_DIR is unset: $out" ;;
  esac
}

test_home_unset_falls_back_safely() {
  # With HOME unset and MMOX_STATE_DIR unset, the launcher must not try to
  # mkdir /, must not write to /shim.log, and must report something
  # sensible (or fail closed without corrupting the filesystem).
  local out
  out=$(env -i \
    PATH="$fakebin:$PYBIN:/usr/bin:/bin" \
    FM_ROOT_OVERRIDE="$ROOT/bin" \
    "$SHIM" status 2>&1) || true

  if [ -e /shim.log ]; then
    fail "launcher wrote /shim.log with HOME unset (root write)"
  fi
  case "$out" in
    stopped|running*) pass "HOME unset: launcher responds without writing /shim.log" ;;
    *) fail "HOME unset: launcher output unexpected: $out" ;;
  esac
}

# ---------------------------------------------------------------------------
# Finding #4: unquoted / unsafe PID variable.
# ---------------------------------------------------------------------------

test_corrupt_pid_file_is_handled_safely() {
  local pid_file="$fake_state/shim.pid"
  echo "garbage not a pid" > "$pid_file"
  # Status should not crash even with a non-integer PID file.
  local out
  out=$(run_shim status 2>&1) || true
  case "$out" in
    stopped|running*) pass "corrupt PID file does not crash status (got: $out)" ;;
    *) fail "corrupt PID file caused unexpected output: $out" ;;
  esac

  # Stop must not pass the corrupted content to kill as a multi-arg PID list.
  # Replace with whitespace+number to exercise that case.
  printf '123\n  456\n' > "$pid_file"
  out=$(run_shim stop 2>&1) || true
  case "$out" in
    "not running"|"[mmox-shim] not running"|"[mmox-shim] stopped"|"stopped") pass "corrupt PID file with whitespace handled safely" ;;
    *) fail "corrupt PID file with whitespace caused unexpected output: $out" ;;
  esac
}

test_empty_pid_file_is_handled_safely() {
  local pid_file="$fake_state/shim.pid"
  : > "$pid_file"
  local out
  out=$(run_shim status 2>&1) || true
  case "$out" in
    stopped|running*) pass "empty PID file does not crash status (got: $out)" ;;
    *) fail "empty PID file caused unexpected output: $out" ;;
  esac
}

# ---------------------------------------------------------------------------
# Lifecycle sanity: stop when stopped, status when stopped.
# ---------------------------------------------------------------------------

test_stop_when_already_stopped() {
  rm -f "$fake_state/shim.pid"
  local out
  out=$(run_shim stop 2>&1) || true
  case "$out" in
    "not running"|"[mmox-shim] not running") pass "stop when not running prints 'not running'" ;;
    *) fail "stop when not running produced: $out" ;;
  esac
}

test_status_when_stopped() {
  rm -f "$fake_state/shim.pid"
  local out
  out=$(run_shim status 2>&1) || true
  case "$out" in
    stopped) pass "status when not running prints 'stopped'" ;;
    *) fail "status when not running produced: $out" ;;
  esac
}

# ---------------------------------------------------------------------------
# API-key redaction: status/start output must not leak a configured key.
# ---------------------------------------------------------------------------

test_status_does_not_leak_api_key() {
  local secret="sk-secret-abcdef1234567890"
  local out
  out=$(env -i \
    HOME="$fake_home" \
    PATH="$fakebin:$PYBIN:/usr/bin:/bin" \
    MMOX_STATE_DIR="$fake_state" \
    FM_ROOT_OVERRIDE="$ROOT/bin" \
    MMOX_API_KEY="$secret" \
    "$SHIM" status 2>&1) || true
  case "$out" in
    *"$secret"*) fail "status leaked MMOX_API_KEY: $out" ;;
    *) pass "status does not leak MMOX_API_KEY" ;;
  esac
}

test_env_does_not_leak_api_key() {
  local secret="sk-secret-abcdef1234567890"
  local out
  out=$(env -i \
    HOME="$fake_home" \
    PATH="$fakebin:$PYBIN:/usr/bin:/bin" \
    MMOX_STATE_DIR="$fake_state" \
    FM_ROOT_OVERRIDE="$ROOT/bin" \
    MMOX_API_KEY="$secret" \
    "$SHIM" env 2>&1) || true
  case "$out" in
    *"$secret"*) fail "env leaked MMOX_API_KEY: $out" ;;
    *) pass "env does not leak MMOX_API_KEY" ;;
  esac
}

# Run all tests in order.
test_empty_state_dir_does_not_collapse_log_path
test_unset_state_dir_uses_default_under_home
test_home_unset_falls_back_safely
test_corrupt_pid_file_is_handled_safely
test_empty_pid_file_is_handled_safely
test_stop_when_already_stopped
test_status_when_stopped
test_status_does_not_leak_api_key
test_env_does_not_leak_api_key

# Cleanup any leftover background shims from the start test above.
if [ -f "$fake_state/shim.pid" ]; then
  pid_content=$(cat "$fake_state/shim.pid")
  case "$pid_content" in
    ''|*[!0-9]*) ;;
    *) kill "$pid_content" 2>/dev/null || true ;;
  esac
  rm -f "$fake_state/shim.pid"
fi
