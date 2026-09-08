#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

make_herdr_ready_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_HERDR_LOG:?FM_FAKE_HERDR_LOG unset}
{
  printf '%s' "${HERDR_SESSION:-}"
  for arg in "$@"; do
    printf '\037%s' "$arg"
  done
  printf '\n'
} >> "$log"

case "${1:-}:${2:-}" in
  status:--json)
    printf '%s\n' '{"client":{"version":"0.8.2","protocol":20},"server":{"running":true,"version":"0.8.2","protocol":20}}'
    exit 0
    ;;
  workspace:list)
    printf '%s\n' '{"result":{"workspaces":[]}}'
    exit 0
    ;;
  workspace:create)
    printf '%s\n' '{"result":{"workspace":{"workspace_id":"w1"},"tab":{"tab_id":"t-seed"},"root_pane":{"pane_id":"w1:p1"}}}'
    exit 0
    ;;
  tab:list)
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"t-seed","workspace_id":"w1","label":"1"}]}}'
    exit 0
    ;;
  tab:create)
    printf '%s\n' '{"result":{"tab":{"tab_id":"t-task","workspace_id":"w1"},"root_pane":{"pane_id":"w1:p2"}}}'
    exit 0
    ;;
  pane:process-info)
    if [ "${FM_FAKE_HERDR_READY_SHAPE:-malformed}" = valid ]; then
      printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":67,"foreground_process_group_id":67,"foreground_processes":[{"pid":67,"name":"zsh","argv0":"zsh"}]}}}'
    else
      printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","foreground_processes":[{}]}}}'
    fi
    exit 0
    ;;
  pane:get)
    printf '{"result":{"pane":{"pane_id":"w1:p2","foreground_cwd":"%s"}}}\n' "${FM_FAKE_HERDR_FOREGROUND_CWD:?FM_FAKE_HERDR_FOREGROUND_CWD unset}"
    exit 0
    ;;
  pane:run|pane:send-text|pane:send-keys|agent:get)
    exit 0
    ;;
esac

printf 'unexpected herdr call: %s\n' "$*" >&2
exit 1
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$fakebin"
}

make_herdr_ready_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin log
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  log="$case_dir/herdr.log"
  fakebin=$(make_herdr_ready_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'off\n' > "$home/config/herdr-presentation-spaces"
  printf 'Delivery contract: mode=no-mistakes\nbrief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat" "$log"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$log"
}

read_herdr_ready_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR HERDR_LOG <<EOF
$1
EOF
}

run_herdr_ready_spawn() {
  local id=$1 shape=$2
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 HERDR_SESSION=fm-spawn-ready \
    FM_SPAWN_HERDR_READY_SAMPLES=2 FM_SPAWN_HERDR_READY_STABLE=2 \
    FM_SPAWN_HERDR_READY_INTERVAL=0 \
    FM_FAKE_HERDR_LOG="$HERDR_LOG" FM_FAKE_HERDR_READY_SHAPE="$shape" \
    FM_FAKE_HERDR_FOREGROUND_CWD="$WT_DIR" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" "printf ready" --mode no-mistakes --yolo off --backend herdr 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read still only
# costs the loop's existing one-second inter-poll sleep to confirm - not an
# extra full cycle on top of that.
test_already_settled_pane_costs_one_confirm_sleep() {
  local rec id out status start end elapsed
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  start=$(date +%s)
  out=$(run_settle_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$elapsed" -le 5 ] || fail "already-settled pane took ${elapsed}s to confirm - expected close to the single inter-poll sleep"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

test_herdr_readiness_rejects_null_process_identity() {
  local rec id out status
  id=herdr-ready-null-z1
  rec=$(make_herdr_ready_case herdr-ready-null "$id")
  read_herdr_ready_record "$rec"

  out=$(run_herdr_ready_spawn "$id" malformed)
  status=$?
  expect_code 1 "$status" "spawn should reject malformed Herdr process-info"
  assert_contains "$out" "did not become ready before the spawn handoff" \
    "readiness failure did not explain the Herdr handoff gate"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "malformed Herdr process-info still published task metadata"
  assert_no_grep $'\x1f''pane'$'\x1f''run'$'\x1f''w1:p2'$'\x1f''treehouse get' "$HERDR_LOG" \
    "malformed Herdr process-info reached the first pane handoff command"
  pass "malformed Herdr process-info cannot satisfy spawn readiness"
}

test_herdr_readiness_accepts_exact_numeric_shell_owner() {
  local rec id out status
  id=herdr-ready-valid-z2
  rec=$(make_herdr_ready_case herdr-ready-valid "$id")
  read_herdr_ready_record "$rec"

  out=$(run_herdr_ready_spawn "$id" valid)
  status=$?
  expect_code 0 "$status" "spawn should accept valid Herdr process-info"
  assert_contains "$out" "spawned $id" "valid Herdr readiness did not launch"
  assert_grep $'\x1f''pane'$'\x1f''run'$'\x1f''w1:p2'$'\x1f''treehouse get' "$HERDR_LOG" \
    "valid Herdr readiness did not reach the first pane handoff command"
  assert_grep "backend=herdr" "$HOME_DIR/state/$id.meta" \
    "valid Herdr spawn did not record its backend"
  assert_grep "herdr_pane_id=w1:p2" "$HOME_DIR/state/$id.meta" \
    "valid Herdr spawn did not record the exact pane id"
  pass "valid exact Herdr process-info satisfies spawn readiness"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_herdr_readiness_rejects_null_process_identity
test_herdr_readiness_accepts_exact_numeric_shell_owner

echo "# all fm-spawn-worktree-settle tests passed"
