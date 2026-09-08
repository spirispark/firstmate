#!/usr/bin/env bash
# Contract test for the tracked GitHub Actions workflow at
# .github/workflows/CI.yml. Single owner for "the CI workflow must do X"
# assertions. This file does NOT touch any other test's domain:
#   - It does not exercise bin/fm-lint.sh; that is tests/fm-lint.test.sh.
#   - It does not exercise bin/fm-herdr-*; those tests live elsewhere.
#   - It reads .github/workflows/CI.yml directly to assert the workflow's
#     contract is preserved against tracked edits.
#
# A contract guard exists because CI behavior drifts when the workflow is
# edited. The Lint job in particular was OOM-killed mid-run by the
# self-hosted ARM64 runner kernel (exit 137) because the two-shard default
# let two large canonical files' pinned ShellCheck 0.11.0 invocations
# race for memory; the only viable fix without a runner upgrade was to
# force the bounded workers to serialize inside that one job via
# FM_LINT_JOBS=1. That fix only protects CI; the script's default stays
# JOBS=2 so local developer iteration and the pre-push gate are unchanged.
# A future workflow edit that drops the env block, renames the variable,
# or moves the lint invocation elsewhere breaks CI behavior; this guard
# catches that before it reaches a runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOW="$ROOT/.github/workflows/CI.yml"

# fm_workflow_lint_step: print the "Run bin/fm-lint.sh" step line that lives
# directly under the Lint job. Returns nonzero if the step is absent. Uses
# awk rather than a YAML parser so the guard stays portable to macOS Bash
# 3.2 (the no-mistakes pre-push lane runs there too).
fm_workflow_lint_step() {
  awk '
    /^  lint:/ { in_lint = 1; next }
    in_lint && /- run: bin\/fm-lint\.sh/ { print; found = 1; exit }
    END { exit !found }
  ' "$WORKFLOW"
}

# fm_workflow_lint_step_env: print the first "KEY: value" line directly under
# the Lint job's "Run bin/fm-lint.sh" step (i.e. inside its `env:` block).
# Leading whitespace is stripped so callers can compare exact strings.
# The first rule resets both flags whenever we enter a new top-level job key
# (any "  <word>:" at column 2 that is not the lint job), so an absent env
# block yields no match instead of bleeding into the next job's env.
fm_workflow_lint_step_env() {
  awk '
    /^  [a-z]/ && !/^  lint:/ { in_lint = 0; in_step = 0 }
    /^  lint:/ { in_lint = 1; next }
    in_lint && /- run: bin\/fm-lint\.sh/ { in_step = 1; next }
    in_step && /^          [A-Z_]+: / { sub(/^[[:space:]]+/, ""); print; exit }
  ' "$WORKFLOW"
}

test_lint_job_runs_pinned_shellcheck_lint() {
  [ -f "$WORKFLOW" ] || fail "CI workflow not found at $WORKFLOW"
  local step
  step=$(fm_workflow_lint_step) || step=
  [ "$step" = "      - run: bin/fm-lint.sh" ] \
    || fail "Lint job 'Run bin/fm-lint.sh' step missing or changed: got '$step'"
  pass "CI workflow Lint job runs bin/fm-lint.sh directly under the lint: job key"
}

test_lint_job_forces_serial_shellcheck_jobs() {
  [ -f "$WORKFLOW" ] || fail "CI workflow not found at $WORKFLOW"
  local env_value
  env_value=$(fm_workflow_lint_step_env) || env_value=
  # The Lint job must serialize the two-shard default so the pinned
  # ShellCheck 0.11.0 cannot OOM-kill mid-run on the self-hosted ARM64
  # runner. Local developer invocation is unaffected: the script's
  # default stays JOBS=2.
  [ "$env_value" = "FM_LINT_JOBS: '1'" ] \
    || fail "CI workflow Lint job must export FM_LINT_JOBS='1' to serialize ShellCheck; got '$env_value'"
  pass "CI workflow Lint job forces FM_LINT_JOBS=1 so pinned ShellCheck stays deterministically memory-bounded"
}

test_lint_job_runs_pinned_shellcheck_lint
test_lint_job_forces_serial_shellcheck_jobs
