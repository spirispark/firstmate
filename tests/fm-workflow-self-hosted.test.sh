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
# The test parses the workflow as YAML rather than grepping the source
# text, so a behavior-preserving reformat of the workflow cannot silently
# disable the guard. Asserting the literal string "ubuntu-latest" would be
# the raw proxy this test deliberately does not use. Both YAML backends the
# fleet has - yq on the captain's workstation, python3+PyYAML in the
# ci-runner image - run the whole suite, because a backend that yields a
# different model (or nothing at all) on only one of the two hosts is how a
# guard like this fails open. Fixture workflows in the last case prove the
# guard actually trips on a partial label set and on a .yaml workflow.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOWS_DIR="$ROOT/.github/workflows"

# The label set every captain runner answers, and the parser tag appended to
# each reporter line so a failure names the backend that produced it.
EXPECTED_LABELS="self-hosted,linux,ARM64"
FM_WORKFLOW_PARSER=${FM_WORKFLOW_PARSER:-}
PARSER_SUFFIX=""

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

# The parser backend both readers use. The captain's ci-runner image ships
# python3+PyYAML but no yq, while the captain's workstation has both, so the
# two backends must produce the same model; FM_WORKFLOW_PARSER lets the
# assertions below run the whole suite once per available backend.
workflow_parsers() {
  if command -v yq >/dev/null 2>&1; then
    printf 'yq\n'
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    printf 'python\n'
  fi
}

active_parser() {
  case "${FM_WORKFLOW_PARSER:-}" in
    yq|python) printf '%s\n' "$FM_WORKFLOW_PARSER" ;;
    *) workflow_parsers | head -1 ;;
  esac
}

# Yield every job id declared by one workflow file, one per line.
list_job_ids() {
  local workflow_path=$1
  if [ "$(active_parser)" = yq ]; then
    yq eval '.jobs | keys | .[]' "$workflow_path" 2>/dev/null
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
}

# Yield "<workflow>::<job>" identifiers for every job in every workflow file.
# Both YAML suffixes are inspected: GitHub honours .yml and .yaml alike, so a
# workflow added as .yaml must not slip past the guard unexamined.
discover_jobs() {
  local dir=${1:-$WORKFLOWS_DIR}
  local workflow_path workflow_file job
  for workflow_path in "$dir"/*.yml "$dir"/*.yaml; do
    [ -f "$workflow_path" ] || continue
    workflow_file="$(basename "$workflow_path")"
    while IFS= read -r job; do
      [ -n "$job" ] && printf '%s::%s\n' "$workflow_file" "$job"
    done < <(list_job_ids "$workflow_path")
  done
}

# Print the runs-on label set for one job, one per line, in a normalised
# form: a bare string yields one line; a list yields each label; a mapping
# yields labels plus the group when present.
runs_on_labels() {
  local workflow_path=$1 job_id=$2
  if [ "$(active_parser)" = yq ]; then
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
  [ -n "$(workflow_parsers)" ]
}

# True only when EVERY expected label is present in $1. At-least-one would let
# `runs-on: [self-hosted]` - or a bare `linux` - satisfy a label set no captain
# runner answers, which is exactly the drift docs/ci-runner.md promises this
# test catches.
assert_self_hosted_labels_present() {
  local labels_eff=$1 expected=$2
  local want found label rest
  rest=$expected
  while [ -n "$rest" ]; do
    want=${rest%%,*}
    if [ "$want" = "$rest" ]; then
      rest=""
    else
      rest=${rest#*,}
    fi
    [ -n "$want" ] || continue
    found=0
    while IFS= read -r label; do
      if [ "$label" = "$want" ]; then
        found=1
        break
      fi
    done <<<"$labels_eff"
    [ "$found" -eq 1 ] || return 1
  done
  return 0
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
    fail "expected at least 4 canonical jobs, found $found${PARSER_SUFFIX}"
  fi
  pass "workflows parse and expose canonical jobs${PARSER_SUFFIX}"
}

# Print one offender line per job in <dir> whose runs-on drifts from the
# contract. Shared by the real-workflow assertion and the fixture assertion so
# the guard the fixtures exercise is the guard CI runs.
collect_runner_offenders() {
  local dir=${1:-$WORKFLOWS_DIR}
  local id workflow_file job_id workflow_path labels_eff flat
  while IFS= read -r id; do
    workflow_file="${id%%::*}"
    job_id="${id##*::}"
    workflow_path="$dir/$workflow_file"
    labels_eff="$(runs_on_labels "$workflow_path" "$job_id" | sort -u)"
    if [ -z "$labels_eff" ]; then
      printf '%s (no runs-on)\n' "$id"
      continue
    fi
    flat="$(printf '%s' "$labels_eff" | tr '\n' ',')"
    if allowed_hosted_reason "$id" >/dev/null 2>&1; then
      if assert_no_hosted_label "$labels_eff"; then
        printf '%s (ALLOWED_HOSTED lists it but runs-on is not a hosted label set)\n' "$id"
      fi
      continue
    fi
    if ! assert_self_hosted_labels_present "$labels_eff" "$EXPECTED_LABELS"; then
      printf '%s runs-on=%s (expected %s)\n' "$id" "$flat" "$EXPECTED_LABELS"
    fi
    if ! assert_no_hosted_label "$labels_eff"; then
      printf '%s runs-on=%s (unexpected hosted label)\n' "$id" "$flat"
    fi
  done < <(discover_jobs "$dir")
}

# 2. Every Linux job uses [self-hosted, linux, ARM64] unless it is on
#    ALLOWED_HOSTED_KEYS with a documented reason.
test_linux_jobs_are_self_hosted() {
  local offenders
  offenders="$(collect_runner_offenders "$WORKFLOWS_DIR")"
  if [ -n "$offenders" ]; then
    printf 'workflow-self-hosted: Linux jobs must use the captain self-hosted ARM64 runner:\n%s\n' \
      "$offenders" >&2
    fail "hosted-runner regression${PARSER_SUFFIX}"
  fi
  pass "every Linux job dispatches to the captain's self-hosted ARM64 runner${PARSER_SUFFIX}"
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
  pass "every ALLOWED_HOSTED entry has a reason${PARSER_SUFFIX}"
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
    fail "ALLOWED_HOSTED drifted${PARSER_SUFFIX}"
  fi
  pass "ALLOWED_HOSTED inventory matches hosted-runner usage${PARSER_SUFFIX}"
}

# 5. The guard must actually trip on the two drifts it exists to catch: a job
#    that keeps only part of the label set (no captain runner answers
#    `[self-hosted]` alone), and a hosted-runner job declared in a .yaml rather
#    than .yml workflow file (GitHub honours both suffixes). Both shapes
#    previously passed, so the guard reported green while failing open.
test_guard_trips_on_label_and_suffix_drift() {
  local tmp fixtures ids offenders
  tmp=$(fm_test_tmproot fm-workflow-guard)
  fixtures="$tmp/workflows"
  mkdir -p "$fixtures"

  cat > "$fixtures/partial-labels.yml" <<'YAML'
name: Partial label set
on: [push]
jobs:
  drifted:
    runs-on: [self-hosted]
    steps:
      - run: 'true'
YAML
  cat > "$fixtures/hosted-suffix.yaml" <<'YAML'
name: Hosted runner in a .yaml workflow
on: [push]
jobs:
  hosted:
    runs-on: ubuntu-latest
    steps:
      - run: 'true'
YAML
  cat > "$fixtures/compliant.yml" <<'YAML'
name: Compliant
on: [push]
jobs:
  ok:
    runs-on: [self-hosted, linux, ARM64]
    steps:
      - run: 'true'
YAML

  ids="$(discover_jobs "$fixtures" | sort)"
  assert_contains "$ids" "partial-labels.yml::drifted" \
    "discovery lost a .yml workflow job${PARSER_SUFFIX}"
  assert_contains "$ids" "hosted-suffix.yaml::hosted" \
    "discovery never inspected a .yaml workflow file${PARSER_SUFFIX}"

  offenders="$(collect_runner_offenders "$fixtures")"
  assert_contains "$offenders" "partial-labels.yml::drifted" \
    "a partial label set passed the self-hosted guard${PARSER_SUFFIX}"
  assert_contains "$offenders" "hosted-suffix.yaml::hosted" \
    "a hosted runner in a .yaml workflow passed the guard${PARSER_SUFFIX}"
  assert_not_contains "$offenders" "compliant.yml::ok" \
    "the full label set was reported as an offender${PARSER_SUFFIX}"
  pass "the guard trips on partial label sets and on .yaml workflows${PARSER_SUFFIX}"
}

if ! has_yq_or_yaml; then
  echo "skip: workflow-self-hosted requires yq or python3+PyYAML" >&2
  exit 0
fi

# Run the whole guard once per available parser backend. The captain's
# workstation carries yq; the ci-runner image carries only python3+PyYAML, so a
# backend whose model silently diverges would otherwise only surface on one of
# the two hosts - and a backend that yields nothing at all would read as a
# clean workflow set.
while IFS= read -r parser; do
  FM_WORKFLOW_PARSER=$parser
  PARSER_SUFFIX=" (parser: $parser)"
  test_discover_jobs_finds_required_jobs
  test_linux_jobs_are_self_hosted
  test_allowed_hosted_entries_have_reason
  test_allowed_hosted_inventory_is_exactly_listed
  test_guard_trips_on_label_and_suffix_drift
done < <(workflow_parsers)
