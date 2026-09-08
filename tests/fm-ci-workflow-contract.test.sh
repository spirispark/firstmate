#!/usr/bin/env bash
# Contract test for the tracked GitHub Actions workflow at
# .github/workflows/ci.yml. Single owner for "the CI workflow must do X"
# assertions. This file does NOT touch any other test's domain:
#   - It does not exercise bin/fm-lint.sh; that is tests/fm-lint.test.sh.
#   - It does not exercise bin/fm-herdr-*; those tests live elsewhere.
#   - It parses .github/workflows/ci.yml into a workflow model to assert the
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

WORKFLOW="$ROOT/.github/workflows/ci.yml"

fm_workflow_lint_step_field() {  # <field>
  ruby -ryaml - "$WORKFLOW" "$1" <<'RUBY'
path, field = ARGV
workflow = YAML.safe_load_file(path, aliases: true)
jobs = workflow.fetch("jobs")
lint = jobs.fetch("lint")
steps = lint.fetch("steps")
abort "lint job steps is not a sequence" unless steps.is_a?(Array)
matches = steps.select { |step| step.is_a?(Hash) && step["run"] == "bin/fm-lint.sh" }
abort "expected exactly one lint step, found #{matches.length}" unless matches.length == 1
step = matches.fetch(0)
case field
when "run"
  print step.fetch("run")
when "env.FM_LINT_JOBS"
  env = step.fetch("env")
  abort "lint step env is not a mapping" unless env.is_a?(Hash)
  value = env.fetch("FM_LINT_JOBS")
  abort "lint step FM_LINT_JOBS is not a string" unless value.is_a?(String)
  print value
else
  abort "unknown field #{field}"
end
RUBY
}

test_lint_job_runs_pinned_shellcheck_lint() {
  [ -f "$WORKFLOW" ] || fail "CI workflow not found at $WORKFLOW"
  local run
  run=$(fm_workflow_lint_step_field run) || run=
  [ "$run" = "bin/fm-lint.sh" ] \
    || fail "Lint job 'Run bin/fm-lint.sh' step missing or changed: got '$run'"
  pass "CI workflow Lint job runs bin/fm-lint.sh directly under the lint: job key"
}

test_lint_job_forces_serial_shellcheck_jobs() {
  [ -f "$WORKFLOW" ] || fail "CI workflow not found at $WORKFLOW"
  local env_value
  env_value=$(fm_workflow_lint_step_field env.FM_LINT_JOBS) || env_value=
  [ "$env_value" = "1" ] \
    || fail "CI workflow Lint job must export FM_LINT_JOBS='1' to serialize ShellCheck; got '$env_value'"
  pass "CI workflow Lint job forces FM_LINT_JOBS=1 so pinned ShellCheck stays deterministically memory-bounded"
}

test_lint_job_runs_pinned_shellcheck_lint
test_lint_job_forces_serial_shellcheck_jobs
