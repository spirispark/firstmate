#!/usr/bin/env bash
# Behavior tests for the .github/workflows contract that the self-hosted CI
# migration relies on. Every workflow under .github/workflows/ must dispatch
# every Linux job to the captain's self-hosted Docker runner, label set
# [self-hosted, linux, ARM64]. The single documented exception is
# macos-stock-bash in ci.yml: /bin/bash 3.2.57 is a stock macOS Bash the
# snapshot and bearings consumers exercise, and a Linux container cannot
# provide it. windows-herdr-spike.yml stays on windows-latest because it is
# a Windows-only manual dispatch spike.
#
# This test refuses a future PR that reintroduces a GitHub-hosted runner on
# a Linux job, even by accident. Hosted-runner labels are matched against
# the upstream set GitHub documents for ubuntu/macos/windows and any other
# label that ends in "-latest", so a self-hosted label-set change cannot
# silently bypass the check.
#
# The test parses the workflow as YAML (yq, when present, or PyYAML as a
# portable fallback) rather than grepping the source text, so a
# behavior-preserving reformat of the workflow cannot silently disable the
# guard. Asserting the literal string "ubuntu-latest" would be the raw
# proxy this test deliberately does not use.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOWS_DIR="$ROOT/.github/workflows"

# ALLOWED_HOSTED_KEYS - jobs whose runs-on is allowed to be GitHub-hosted.
# ALLOWED_HOSTED_REASONS - one reason per key, parallel to ALLOWED_HOSTED_KEYS.
# macos-stock-bash is the lone legacy consumer of stock macOS Bash;
# windows-herdr-spike is a manual Windows dispatch. Parallel arrays keep the
# check runnable under stock macOS Bash 3.2.57 (which does not support
# `declare -A`).
ALLOWED_HOSTED_KEYS=(
  'ci.yml::macos-stock-bash'
  'windows-herdr-spike.yml::measure'
)
ALLOWED_HOSTED_REASONS=(
  'Stock macOS Bash 3.2.57 is a macOS-only binary a Linux container cannot provide; the test is recorded here so this job never expands into a second offender.'
  'Manual Windows-only Herdr spike; workflow_dispatch only and never receives push or pull_request events.'
)

# Look up the allow-list reason for an id; print nothing when the id is not
# on the allow-list. Used to assert every entry has a documented reason.
allowed_hosted_reason() {
  local id=$1 i
  for i in "${!ALLOWED_HOSTED_KEYS[@]}"; do
    if [ "${ALLOWED_HOSTED_KEYS[$i]}" = "$id" ]; then
      printf '%s\n' "${ALLOWED_HOSTED_REASONS[$i]:-}"
      return 0
    fi
  done
  return 1
}

allowed_hosted_inventory() {
  printf '%s\n' "${ALLOWED_HOSTED_KEYS[@]}"
}

# Yield "<workflow>::<job>" identifiers for every job in every workflow file.
discover_jobs() {
  local workflow_path workflow_file
  for workflow_path in "$WORKFLOWS_DIR"/*.yml; do
    [ -f "$workflow_path" ] || continue
    workflow_file="$(basename "$workflow_path")"
    if command -v yq >/dev/null 2>&1; then
      yq eval '.jobs | keys | .[]' "$workflow_path" 2>/dev/null \
        | while IFS= read -r job; do
            [ -n "$job" ] && printf '%s::%s\n' "$workflow_file" "$job"
          done
    else
      python3 - "$workflow_path" <<'PY'
import sys
import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
if not isinstance(doc, dict):
    sys.exit(f"workflow-self-hosted: {path} root must be a YAML mapping")
jobs = doc.get("jobs") or {}
if not isinstance(jobs, dict):
    sys.exit(f"workflow-self-hosted: {path} jobs must be a YAML mapping")
for job_id in jobs:
    print(job_id)
PY
    fi
  done
}

# Print the runs-on label set for one job, one per line, in a normalised
# form: a bare string yields one line; a list yields each label; a mapping
# yields labels plus the group when present.
runs_on_labels() {
  local workflow_path=$1 job_id=$2
  if command -v yq >/dev/null 2>&1; then
    yq eval ".jobs.\"${job_id}\".runs-on | to_json" "$workflow_path" 2>/dev/null \
      | python3 -c '
import json, sys
runs_on = json.loads(sys.stdin.read())
if isinstance(runs_on, str):
    print(runs_on)
elif isinstance(runs_on, list):
    for item in runs_on:
        if isinstance(item, (str, int)):
            print(item)
elif isinstance(runs_on, dict):
    for key in ("labels", "group"):
        value = runs_on.get(key)
        if isinstance(value, str):
            print(value)
        elif isinstance(value, list):
            for item in value:
                if isinstance(item, (str, int)):
                    print(item)
'
  else
    python3 - "$workflow_path" "$job_id" <<'PY'
import sys
import yaml

path = sys.argv[1]
job_id = sys.argv[2]
with open(path, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
job = (doc.get("jobs") or {}).get(job_id) or {}
runs_on = job.get("runs-on")
if isinstance(runs_on, str):
    print(runs_on)
elif isinstance(runs_on, list):
    for item in runs_on:
        if isinstance(item, (str, int)):
            print(item)
elif isinstance(runs_on, dict):
    for key in ("labels", "group"):
        value = runs_on.get(key)
        if isinstance(value, str):
            print(value)
        elif isinstance(value, list):
            for item in value:
                if isinstance(item, (str, int)):
                    print(item)
PY
  fi
}

has_yq_or_yaml() {
  if command -v yq >/dev/null 2>&1; then
    return 0
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# True when every label in $1 is non-empty and at least one is the expected.
assert_self_hosted_labels_present() {
  local labels_eff=$1 expected=$2
  local label
  while IFS= read -r label; do
    case ",${expected}," in
      *,"${label}",*) return 0 ;;
    esac
  done <<<"$labels_eff"
  return 1
}

# True when none of the labels looks like a GitHub-hosted runner label.
assert_no_hosted_label() {
  local labels_eff=$1
  local label
  while IFS= read -r label; do
    case "$label" in
      ubuntu-*|macos-*|windows-*)
        return 1
        ;;
    esac
    if [ "$label" = "self-hosted" ]; then
      : # the bare "self-hosted" string is not a hosted runner - it is the
        # self-hosted prefix label and lives in every captain runner's label set.
    elif [[ "$label" == *-latest ]]; then
      return 1
    fi
  done <<<"$labels_eff"
  return 0
}

# ---- assertions ------------------------------------------------------------

# 1. The firstmate CI parses and ships the expected jobs.
test_discover_jobs_finds_required_jobs() {
  local found=0
  local id
  while IFS= read -r id; do
    case "$id" in
      ci.yml::lint|ci.yml::macos-stock-bash|ci.yml::tests-herdr|no-mistakes-required.yml::check)
        found=$((found + 1))
        ;;
    esac
  done < <(discover_jobs)
  if [ "$found" -lt 4 ]; then
    fail "expected at least 4 canonical jobs, found $found"
  fi
  pass "workflows parse and expose canonical jobs"
}

# 2. Every Linux job uses [self-hosted, linux, ARM64] unless it is on
#    ALLOWED_HOSTED_KEYS with a documented reason.
test_linux_jobs_are_self_hosted() {
  local id workflow_file job_id workflow_path
  local labels_eff offenders=""
  while IFS= read -r id; do
    workflow_file="${id%%::*}"
    job_id="${id##*::}"
    workflow_path="$WORKFLOWS_DIR/$workflow_file"
    labels_eff="$(runs_on_labels "$workflow_path" "$job_id" | sort -u)"
    if [ -z "$labels_eff" ]; then
      fail "no runs-on on $id"
    fi
    if allowed_hosted_reason "$id" >/dev/null 2>&1; then
      if assert_no_hosted_label "$labels_eff"; then
        offenders="$offenders\n$id (ALLOWED_HOSTED lists it but runs-on is not a hosted label set)"
      fi
      continue
    fi
    if ! assert_self_hosted_labels_present "$labels_eff" "self-hosted,linux,ARM64"; then
      offenders="$offenders\n$id runs-on=$labels_eff (expected self-hosted,linux,ARM64)"
    fi
    if ! assert_no_hosted_label "$labels_eff"; then
      offenders="$offenders\n$id runs-on=$labels_eff (unexpected hosted label)"
    fi
  done < <(discover_jobs)
  if [ -n "$offenders" ]; then
    printf 'workflow-self-hosted: Linux jobs must use the captain self-hosted ARM64 runner:%b\n' "$offenders" >&2
    fail "hosted-runner regression"
  fi
  pass "every Linux job dispatches to the captain's self-hosted ARM64 runner"
}

# 3. The allow-list has a non-empty reason for every entry. This catches
#    a future PR that adds a hosted exception without explaining why.
test_allowed_hosted_entries_have_reason() {
  local id reason i
  for i in "${!ALLOWED_HOSTED_KEYS[@]}"; do
    id="${ALLOWED_HOSTED_KEYS[$i]}"
    reason="${ALLOWED_HOSTED_REASONS[$i]:-}"
    if [ -z "$reason" ]; then
      fail "ALLOWED_HOSTED entry $id has empty reason"
    fi
  done
  pass "every ALLOWED_HOSTED entry has a reason"
}

# 4. The ALLOWED_HOSTED list is exactly the set of documented exceptions.
#    A PR that adds a new hosted-runner job without updating this list
#    will trip test 2 before it reaches this one; this one pins the
#    allow-list surface so the future-PR reviewer can spot a silently
#    widened allow-list.
test_allowed_hosted_inventory_is_exactly_listed() {
  local id workflow_file job_id workflow_path labels_eff label
  local hosted_in_use=()
  while IFS= read -r id; do
    workflow_file="${id%%::*}"
    job_id="${id##*::}"
    workflow_path="$WORKFLOWS_DIR/$workflow_file"
    labels_eff="$(runs_on_labels "$workflow_path" "$job_id")"
    while IFS= read -r label; do
      case "$label" in
        ubuntu-*|macos-*|windows-*) hosted_in_use+=("$id") ; break ;;
      esac
      if [ "$label" != "self-hosted" ] && [[ "$label" == *-latest ]]; then
        hosted_in_use+=("$id")
        break
      fi
    done <<<"$labels_eff"
  done < <(discover_jobs)
  local sorted_in_use
  if [ "${#hosted_in_use[@]}" -gt 0 ]; then
    sorted_in_use="$(printf '%s\n' "${hosted_in_use[@]}" | sort -u)"
  else
    sorted_in_use=""
  fi
  local sorted_allowed
  sorted_allowed="$(allowed_hosted_inventory | sort -u)"
  if [ "$sorted_in_use" != "$sorted_allowed" ]; then
    {
      printf 'workflow-self-hosted: ALLOWED_HOSTED inventory drifted from hosted-runner usage.\n'
      printf '  allowed but unused: '
      if [ -n "$sorted_allowed" ]; then
        comm -23 <(printf '%s\n' "$sorted_allowed") <(printf '%s\n' "$sorted_in_use")
      fi
      printf '  used but not allowed: '
      if [ -n "$sorted_in_use" ]; then
        comm -13 <(printf '%s\n' "$sorted_allowed") <(printf '%s\n' "$sorted_in_use")
      fi
    } >&2
    fail "ALLOWED_HOSTED drifted"
  fi
  pass "ALLOWED_HOSTED inventory matches hosted-runner usage"
}

if ! has_yq_or_yaml; then
  echo "skip: workflow-self-hosted requires yq or python3+PyYAML" >&2
  exit 0
fi

test_discover_jobs_finds_required_jobs
test_linux_jobs_are_self_hosted
test_allowed_hosted_entries_have_reason
test_allowed_hosted_inventory_is_exactly_listed