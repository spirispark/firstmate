#!/usr/bin/env bash
# Behavior tests for fm-pipeline-engine.sh - the quota-evidence report for the
# no-mistakes pipeline's engine order, with its opt-in write.
#
# Driven entirely through the real command-line interface against a fake
# quota-axi, because the four properties below are the ones whose absence has a
# cost, and each is a real failure mode rather than a hypothetical:
#
# 1. The config it edits is mostly dated decision history in comments, including
#    a live temporary exception and its revert condition. A load-and-dump YAML
#    rewrite destroys all of it, so a write must be provably surgical: exactly
#    one changed line, every other byte identical.
# 2. An engine quota-axi cannot see (Pi's MiniMax path is absent from its output
#    entirely) is disclosed uncertainty, not grounds to exclude. Dropping it, or
#    ranking it below a window PROVEN to be running out, is the mistake.
# 3. An engine excluded by standing captain preference must never be introduced,
#    however healthy its window looks; one already present is under a recorded
#    exception and keeps its exact position rather than being re-ranked.
# 4. An absent config, or an `agent:` line that is not the expected list shape,
#    must refuse and write nothing. Guessing and rewriting is the worst outcome
#    available to this script.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-pipeline-engine-tests)
SCRIPT="$ROOT/bin/fm-pipeline-engine.sh"

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'quota-axi %s\n' "${FM_FAKE_QUOTA_VERSION:-0.1.17}"
  exit 0
fi
if [ "${1:-}" = --json ]; then
  cat "$FM_FAKE_QUOTA_FILE"
  exit 0
fi
exit 1
SH
chmod +x "$FAKEBIN/quota-axi"
export PATH="$FAKEBIN:$BASE_PATH"
export FM_FAKE_QUOTA_FILE="$TMP_ROOT/quota.json"

# --- fixtures ---------------------------------------------------------------

# One provider entry in quota-axi's shape. `runway` is the field that separates
# "healthy through its reset" from "proven to be running out".
quota_provider() {
  local id=$1 remaining=$2 runway=$3 burn=$4
  cat <<JSON
    {
      "provider": "$id",
      "label": "$id",
      "source": "oauth",
      "windows": [
        {
          "id": "weekly",
          "kind": "weekly",
          "percentRemaining": $remaining,
          "pace": { "burnMultiple": $burn }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": $remaining,
            "limitingWindowIds": ["weekly"],
            "runway": $runway
          }
        ]
      }
    }
JSON
}

# A provider quota-axi reports without knowing its availability: the shape real
# quota-axi emits for a signed-in provider it has no quota data for.
quota_provider_unknown() {
  local id=$1
  cat <<JSON
    {
      "provider": "$id",
      "label": "$id",
      "source": "oauth",
      "windows": [],
      "quotaSemantics": {
        "status": "unknown",
        "reason": "no_quota_data"
      }
    }
JSON
}

# A provider whose LIMITING window reports no pace while a NON-limiting window
# does. Real quota-axi emits pace-less windows carrying "status": "unknown" and
# "reason": "missing_cycle", so this shape is reachable rather than contrived.
quota_provider_paceless_limit() {
  local id=$1 remaining=$2 runway=$3 other_burn=$4
  cat <<JSON
    {
      "provider": "$id",
      "label": "$id",
      "source": "oauth",
      "windows": [
        {
          "id": "weekly",
          "kind": "weekly",
          "percentRemaining": $remaining,
          "status": "unknown",
          "reason": "missing_cycle"
        },
        {
          "id": "monthly",
          "kind": "monthly",
          "percentRemaining": 71,
          "pace": { "burnMultiple": $other_burn }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "effectivePercentRemaining": $remaining,
            "limitingWindowIds": ["weekly"],
            "runway": $runway
          }
        ]
      }
    }
JSON
}

HEALTHY='{ "status": "through_reset" }'
SCARCE='{ "status": "projected_exhaustion", "usableRunwaySeconds": 22337 }'

write_quota() {
  {
    printf '{\n  "schemaVersion": 3,\n  "providers": [\n'
    local first=1 entry
    for entry in "$@"; do
      [ "$first" -eq 1 ] || printf ',\n'
      first=0
      printf '%s' "$entry"
    done
    printf '\n  ]\n}\n'
  } > "$FM_FAKE_QUOTA_FILE"
}

# A config in the real one's shape: dated decision comments around a single
# `agent:` list, plus a COMMENTED example list that must never be mistaken for
# the live one.
write_config() {
  local path=$1 agent_line=$2
  cat > "$path" <<CFG
# no-mistakes global configuration

# Agent to use for code generation. This may also be an ordered fallback list,
# for example: agent: [codex, claude]
# Claude is intentionally excluded.
# 2026-08-09 (night): captain directed switching engines after four pi/MiniMax
# stalls in one session. This is a reliability signal, not quota.
# REVERT CONDITION: when codex's weekly window has recovered, return to the
# captain's standing preference.
$agent_line

agent_args_override:
# Pi is the MiniMax validation path.
#
  pi:
    - --provider
    - minimax
    - --model
    - MiniMax-M3

ci_timeout: "168h"
CFG
}

# --- comment preservation across a write ------------------------------------

CFG="$TMP_ROOT/preserve.yaml"
write_config "$CFG" 'agent: [codex, pi]'
cp "$CFG" "$TMP_ROOT/preserve.orig"
write_quota "$(quota_provider codex 18 "$SCARCE" 4.874)"

out=$("$SCRIPT" --config "$CFG" --apply 2>&1) || fail "--apply failed: $out"
assert_contains "$out" 'agent: [pi, codex]' "--apply should report the line it wrote"
assert_grep 'agent: [pi, codex]' "$CFG" "the agent list should be rewritten"

AGENT_LINE_NO=$(grep -n '^agent:' "$CFG" | cut -d: -f1)
[ "$(printf '%s\n' "$AGENT_LINE_NO" | wc -l | tr -d ' ')" = 1 ] ||
  fail "expected exactly one uncommented agent: line after the write"
sed "${AGENT_LINE_NO}d" "$TMP_ROOT/preserve.orig" > "$TMP_ROOT/before.rest"
sed "${AGENT_LINE_NO}d" "$CFG" > "$TMP_ROOT/after.rest"
cmp -s "$TMP_ROOT/before.rest" "$TMP_ROOT/after.rest" ||
  fail "a write changed bytes outside the agent: line:"$'\n'"$(diff "$TMP_ROOT/before.rest" "$TMP_ROOT/after.rest")"
assert_grep '# for example: agent: [codex, claude]' "$CFG" "the commented example list must survive"
assert_grep '# REVERT CONDITION: when codex' "$CFG" "the recorded revert condition must survive"
pass "a write replaces only the agent: line and preserves every comment byte"

# Re-running with the config already at the recommended order writes nothing.
cp "$CFG" "$TMP_ROOT/idempotent.before"
out=$("$SCRIPT" --config "$CFG" --apply 2>&1) || fail "second --apply failed: $out"
assert_contains "$out" "already at the recommended order" "an unchanged order should say so"
cmp -s "$TMP_ROOT/idempotent.before" "$CFG" || fail "an unchanged order must not touch the file"
pass "--apply on an already-recommended order leaves the file untouched"

# --- default is reporting, not writing --------------------------------------

CFG="$TMP_ROOT/report-only.yaml"
write_config "$CFG" 'agent: [codex, pi]'
cp "$CFG" "$TMP_ROOT/report-only.orig"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
assert_contains "$out" "reporting only" "the default run should say it wrote nothing"
cmp -s "$TMP_ROOT/report-only.orig" "$CFG" || fail "a report must never write the config"
pass "reporting is the default and writes nothing"

# --- an unmeasurable provider stays eligible --------------------------------
#
# quota-axi reports codex only. Pi is absent from its output entirely, exactly
# like the real MiniMax path: it must stay in the candidate set, be labelled as
# unmeasured rather than ineligible, and outrank a window proven to be emptying.

CFG="$TMP_ROOT/unmeasured.yaml"
write_config "$CFG" 'agent: [codex, pi]'
write_quota "$(quota_provider codex 18 "$SCARCE" 4.874)"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
assert_contains "$out" "recommended: pi, codex" "an unmeasured engine should outrank a proven-scarce one"
assert_contains "$out" "pi: unmeasured" "an unmeasured engine should be labelled"
assert_contains "$out" "not grounds to exclude" "unmeasured must be stated as disclosed uncertainty"
assert_contains "$out" "empty in 6h12m" "a projected exhaustion should show its usable runway"
assert_contains "$out" "4.87x" "the limiting window's burn multiple should be shown"
pass "an engine quota-axi cannot see stays eligible and outranks a proven-scarce window"

# The same unmeasured engine still ranks BELOW an engine measured healthy, so
# uncertainty is neither a penalty nor a promotion.
write_quota "$(quota_provider codex 91 "$HEALTHY" 0.4)"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
assert_contains "$out" "recommended: codex, pi" "a measured-healthy engine should outrank an unmeasured one"
pass "an unmeasured engine ranks below a measured-healthy one"

# When quota-axi does report the provider the config DECLARES for that engine,
# the row is measured against it and says the link was declared, not guessed.
write_quota "$(quota_provider codex 18 "$SCARCE" 4.874)" "$(quota_provider minimax 96 "$HEALTHY" 0.3)"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
assert_contains "$out" "minimax (declared)" "a declared --provider should be the measured source"
assert_contains "$out" "recommended: pi, codex" "the declared provider's headroom should rank the engine"
assert_not_contains "$out" "pi: unmeasured" "a declared and reported provider is not unmeasured"
pass "an engine is measured against the provider its own config declares"

# The fixture's agent_args_override block carries a column-0 comment above the
# engine entry, exactly as the real config does. A parser that ends the block
# there loses pi's declared --provider and silently degrades it to unmeasured.
assert_contains "$out" "minimax (declared)" \
  "a column-0 comment inside agent_args_override must not hide the declared --provider"
pass "a declared --provider survives a column-0 comment above its engine entry"

# --- a reported provider with unknown availability --------------------------
#
# quota-axi knows the provider exists but reports no effective availability for
# it. The engine is unmeasured, but for a different reason than an absent
# provider, and the note must say which rather than contradicting its own row.

write_quota "$(quota_provider codex 18 "$SCARCE" 4.874)" "$(quota_provider_unknown minimax)"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
assert_contains "$out" "recommended: pi, codex" \
  "an engine whose provider availability is unknown stays eligible and outranks a scarce one"
assert_contains "$out" "minimax (declared)" "the declared link is still evidence when availability is not"
assert_contains "$out" "pi: unmeasured - quota-axi reports provider minimax for it but not" \
  "the note must say the provider is reported but its availability is not"
assert_not_contains "$out" "pi: unmeasured - quota-axi reports no provider" \
  "the note must not claim no provider is reported when the row names one"
pass "a reported provider with unknown availability is unmeasured for the stated reason"

# --- a limiting window with no pace shows no burn ---------------------------
#
# The burn column describes the window that limits the provider. Substituting a
# non-limiting window's figure would read as authoritative about the constraint
# while describing something else.

CFG="$TMP_ROOT/paceless.yaml"
write_config "$CFG" 'agent: [codex, pi]'
write_quota "$(quota_provider_paceless_limit codex 18 "$SCARCE" 9.99)"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
assert_not_contains "$out" "9.99" "a non-limiting window's burn multiple must never be printed"
codex_row=$(printf '%s\n' "$out" | grep '^codex ' | head -1)
assert_contains "$codex_row" "empty in 6h12m" "the limiting window's runway should still be reported"
case "$codex_row" in
  *' -') : ;;
  *) fail "a limiting window with no pace should leave burn empty, row reads: $codex_row" ;;
esac
pass "a limiting window with no pace reports no burn multiple at all"

# --- an excluded provider stays excluded ------------------------------------

CFG="$TMP_ROOT/excluded.yaml"
write_config "$CFG" 'agent: [codex, pi]'
write_quota "$(quota_provider claude 97 "$HEALTHY" 0.2)" "$(quota_provider codex 18 "$SCARCE" 4.874)"
out=$("$SCRIPT" --config "$CFG" --apply 2>&1) || fail "--apply failed: $out"
assert_not_contains "$out" "recommended: claude" "an excluded engine must never be recommended"
assert_not_contains "$(grep '^agent:' "$CFG")" claude \
  "an excluded engine must never be written into the list"
pass "an excluded engine is never introduced, however healthy its window"

# One already in the list is under a recorded exception: its position is pinned
# and the others rank around it, so the exception is never silently re-ranked.
CFG="$TMP_ROOT/exception.yaml"
write_config "$CFG" 'agent: [claude, codex, pi]'
write_quota "$(quota_provider claude 8 "$SCARCE" 6.0)" "$(quota_provider codex 91 "$HEALTHY" 0.4)"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
assert_contains "$out" "recommended: claude, codex, pi" "an excluded-but-present engine keeps its position"
assert_contains "$out" "recorded exception" "the exception should be flagged for the reader"
pass "an excluded engine already in the list keeps its exact position"

# --- quota and reliability stay distinct ------------------------------------

assert_contains "$out" "quota only" "the report must say it ranks quota only"
assert_contains "$out" "reliability problem" "the report must keep the wedge signal distinct"
pass "the report separates the quota signal from the reliability signal"

# --- refusals write nothing -------------------------------------------------

out=$("$SCRIPT" --config "$TMP_ROOT/does-not-exist.yaml" --apply 2>&1)
rc=$?
expect_code 1 "$rc" "an absent config should refuse"
assert_contains "$out" "config not found" "an absent config should say so"
assert_absent "$TMP_ROOT/does-not-exist.yaml" "a refusal must not create the config"
pass "an absent config refuses and creates nothing"

CFG="$TMP_ROOT/scalar.yaml"
write_config "$CFG" 'agent: auto'
cp "$CFG" "$TMP_ROOT/scalar.orig"
out=$("$SCRIPT" --config "$CFG" --apply 2>&1)
rc=$?
expect_code 1 "$rc" "a non-list agent: value should refuse"
assert_contains "$out" "not the expected" "the refusal should name the expected shape"
assert_contains "$out" "agent: auto" "the refusal should quote the offending line"
cmp -s "$TMP_ROOT/scalar.orig" "$CFG" || fail "a refused write must leave the config untouched"
pass "an agent: line that is not a list refuses instead of being rewritten"

CFG="$TMP_ROOT/duplicate.yaml"
write_config "$CFG" 'agent: [codex, pi]'
printf 'agent: [pi]\n' >> "$CFG"
cp "$CFG" "$TMP_ROOT/duplicate.orig"
out=$("$SCRIPT" --config "$CFG" --apply 2>&1)
rc=$?
expect_code 1 "$rc" "two agent: lines should refuse"
assert_contains "$out" "refusing to guess which one" "the refusal should explain the ambiguity"
cmp -s "$TMP_ROOT/duplicate.orig" "$CFG" || fail "a refused write must leave the config untouched"
pass "more than one agent: line refuses instead of picking one"

CFG="$TMP_ROOT/nolist.yaml"
printf '# only comments\nci_timeout: "168h"\n' > "$CFG"
cp "$CFG" "$TMP_ROOT/nolist.orig"
out=$("$SCRIPT" --config "$CFG" --apply 2>&1)
rc=$?
expect_code 1 "$rc" "a config with no agent: line should refuse"
assert_contains "$out" "no \`agent:\` line" "the refusal should name the missing line"
cmp -s "$TMP_ROOT/nolist.orig" "$CFG" || fail "a refused write must leave the config untouched"
pass "a config with no agent: line refuses instead of adding one"

# --- unusable quota evidence refuses ----------------------------------------

CFG="$TMP_ROOT/floor.yaml"
write_config "$CFG" 'agent: [codex, pi]'
cp "$CFG" "$TMP_ROOT/floor.orig"
out=$(FM_FAKE_QUOTA_VERSION=0.0.1 "$SCRIPT" --config "$CFG" --apply 2>&1)
rc=$?
expect_code 1 "$rc" "a quota-axi below the compatibility floor should refuse"
assert_contains "$out" "floor" "the refusal should name the version floor"
cmp -s "$TMP_ROOT/floor.orig" "$CFG" || fail "a refused write must leave the config untouched"
pass "a quota-axi below the shared compatibility floor refuses and writes nothing"

PATH="$BASE_PATH"
out=$("$SCRIPT" --config "$CFG" 2>&1)
rc=$?
expect_code 1 "$rc" "no quota-axi on PATH should refuse"
assert_contains "$out" "quota evidence is required" "the refusal should say why evidence is required"
PATH="$FAKEBIN:$BASE_PATH"
pass "no quota-axi on PATH refuses rather than recommending blind"

# --- usage errors -----------------------------------------------------------

out=$("$SCRIPT" --nope 2>&1)
expect_code 2 "$?" "an unknown argument should be a usage error"
assert_contains "$out" "unknown argument" "the usage error should name the argument"
pass "an unknown argument is a usage error"
