#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process belong to that same harness session?"
# decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'
FM_CODEX_THREAD_LOCK_PREFIX='codex-thread:'
# A codex-thread identity names a Codex conversation, not a process, so no other
# session can probe it for liveness. Ownership is proven by a lease instead: the
# owning session rewrites state/.lock when it acquires the lock and refreshes it
# from every guarded command it runs (bin/fm-guard.sh), and any OTHER session
# must read a lock refreshed inside this window as a live owner it may not
# displace. Only an expired lease is stale-lock recovery. Long enough that a
# live-but-idle Codex primary keeps exclusive control, short enough that a
# crashed session's home frees itself unattended.
FM_CODEX_THREAD_LEASE_SECS_DEFAULT=900

fm_codex_thread_id_valid() {
  printf '%s' "${1:-}" \
    | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

fm_codex_thread_identity() {
  [ "${CODEX_CI:-}" = 1 ] || return 1
  fm_codex_thread_id_valid "${CODEX_THREAD_ID:-}" || return 1
  printf '%s%s\n' "$FM_CODEX_THREAD_LOCK_PREFIX" "$CODEX_THREAD_ID"
}

fm_codex_thread_lock_valid() {
  local id=${1:-}
  case "$id" in
    "$FM_CODEX_THREAD_LOCK_PREFIX"*) ;;
    *) return 1 ;;
  esac
  fm_codex_thread_id_valid "${id#"$FM_CODEX_THREAD_LOCK_PREFIX"}"
}

fm_codex_thread_lease_secs() {
  local secs=${FM_CODEX_THREAD_LEASE_SECS:-$FM_CODEX_THREAD_LEASE_SECS_DEFAULT}
  case "$secs" in
    ''|*[!0-9]*|0) secs=$FM_CODEX_THREAD_LEASE_SECS_DEFAULT ;;
  esac
  printf '%s\n' "$secs"
}

# Portable mtime in epoch seconds. Kept self-contained so the SessionStart nudge
# keeps sourcing this leaf lib alone.
fm_session_lock_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# True when lock file $1 was refreshed inside the codex-thread lease window.
# A missing path, an unreadable mtime, or an unreadable clock is uncertainty
# about a foreign Codex owner, and uncertainty fails CLOSED as "still live": the
# caller then refuses to mutate and stays read-only, rather than letting two
# simultaneously live Codex primaries trade one home's lock back and forth.
fm_codex_thread_lease_fresh() {
  local lock=${1:-} mtime now
  [ -n "$lock" ] || return 0
  mtime=$(fm_session_lock_mtime "$lock") || return 0
  now=$(date +%s 2>/dev/null) || return 0
  case "$mtime" in ''|*[!0-9]*) return 0 ;; esac
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  [ "$(( now - mtime ))" -lt "$(fm_codex_thread_lease_secs)" ]
}

# Walk the current process ancestry (up to 16 hops) and print a harness identity.
# For every harness except Claude, the first match wins (innermost pid), which
# is where e.g. Pi's shared signed-wrapper ancestry actually holds the session:
# a "pi-signed" launcher can be the direct parent of the inner "pi" engine
# pid that owns the lock, and the wrapper pid above it is not that owner.
# Claude Code's bg-spare hook worker chain is the opposite shape: it nests
# several claude-named processes directly parent-child with no non-harness
# process between them, and the lock is held by the outermost pid of that
# run. So once a claude-named match is found, this keeps walking past it
# looking for a still-more-ancestral claude-named match, and stops the
# instant a non-match follows - never walking past that gap to an unrelated
# claude-named process further up the real process tree (e.g. the live
# session that launched a test as its own subprocess). The harness pid lives
# as long as the session, unlike the transient subshell pid of any one tool
# call. Codex 0.146.0 can deny `ps` inside its seatbelt; when that happens,
# fall back to Codex's verified per-thread marker and publish a codex-thread
# identity instead of a numeric pid.
fm_harness_ancestry_pid() {
  local pid=$$ comm args best='' bc extending=0 hit=0 is_claude=0 identity
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    bc=$(basename -- "$comm")
    hit=0; is_claude=0
    if printf '%s' "$bc" | grep -qE "$FM_HARNESS_RE"; then
      hit=1
      case "$bc" in *claude*) is_claude=1 ;; esac
    else
      # Bare interpreter (e.g. node): match the harness name in its script path.
      case "$comm" in
        *node*|*python*)
          if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
            hit=1
            case "$args" in *claude*) is_claude=1 ;; esac
          fi
          ;;
      esac
    fi
    if [ "$hit" -eq 1 ]; then
      best="$pid"
      if [ "$is_claude" -eq 1 ]; then
        extending=1
      else
        break
      fi
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ -n "$best" ] && { echo "$best"; return 0; }
  identity=$(fm_codex_thread_identity 2>/dev/null) && { echo "$identity"; return 0; }
  return 1
}

# True if $1 is a live process, or a non-process session identity that the
# calling environment still resolves to, and that looks like a verified harness.
# $2 is the lock file $1 was read from, needed only to age a codex-thread lease.
# A codex-thread identity has no observable process to probe, so liveness is
# either the caller resolving to that same thread, or - for a FOREIGN thread -
# the lease on the lock file still being fresh. A fresh foreign lease keeps
# mutual exclusion between two simultaneously live Codex primaries; an expired
# one is stale-lock recovery through the unchanged bin/fm-lock.sh path, so the
# first Codex session still cannot poison the home's lock forever.
fm_harness_pid_alive() {
  local pid=$1 lock=${2:-} comm args
  case "$pid" in
    "$FM_CODEX_THREAD_LOCK_PREFIX"*)
      fm_codex_thread_lock_valid "$pid" || return 1
      [ "$(fm_codex_thread_identity 2>/dev/null)" = "$pid" ] && return 0
      fm_codex_thread_lease_fresh "$lock"
      return
      ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  if printf '%s' "$(basename -- "$comm")" | grep -qE "$FM_HARNESS_RE"; then
    return 0
  fi
  case "$comm" in
    *node*|*python*)
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"
      ;;
    *) return 1 ;;
  esac
}

# True when state dir $1 holds the current process's harness-session identity:
# this script runs inside the session that owns the home's fleet lock. A missing
# lock, a lock held by another live harness, or an identity that cannot be
# resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_identity my_identity
  lock_identity=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_identity" in
    ''|1) return 1 ;;
  esac
  my_identity=$(fm_harness_ancestry_pid) || return 1
  [ "$my_identity" = "$lock_identity" ]
}

# Renew this session's codex-thread lease on state dir $1's lock, so a long
# Codex session keeps proving exclusive ownership between session starts. A
# numeric owner proves liveness through its own process and needs no lease, so
# this is a no-op there, as it is for any session that does not own the lock.
fm_session_lock_refresh_self() {
  local state=${1:-} lock_identity
  lock_identity=$(cat "$state/.lock" 2>/dev/null) || return 0
  fm_codex_thread_lock_valid "$lock_identity" || return 0
  [ "$(fm_codex_thread_identity 2>/dev/null)" = "$lock_identity" ] || return 0
  touch "$state/.lock" 2>/dev/null || true
}
