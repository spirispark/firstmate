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
  if [ -n "${FM_FAKE_QUOTA_SLEEP:-}" ]; then
    sleep "$FM_FAKE_QUOTA_SLEEP"
  fi
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

# A provider whose LIMITING window reports a pace with no burn multiple while a
# NON-limiting window reports one. Real quota-axi emits the pace object carrying
# "status": "unknown" and "reason": "missing_cycle" with no burnMultiple, so this
# shape is reachable rather than contrived.
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
          "pace": { "status": "unknown", "reason": "missing_cycle" }
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

# A provider measured at all_models scope whose availability carries no runway
# object at all, so the runway signal is absent rather than reported unknown.
quota_provider_no_runway() {
  local id=$1 remaining=$2 burn=$3
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
            "limitingWindowIds": ["weekly"]
          }
        ]
      }
    }
JSON
}

# A provider measured at all_models scope whose availability reports a runway
# but no percentage remaining, so the headroom signal alone is missing.
quota_provider_no_headroom() {
  local id=$1 runway=$2 burn=$3
  cat <<JSON
    {
      "provider": "$id",
      "label": "$id",
      "source": "oauth",
      "windows": [
        {
          "id": "weekly",
          "kind": "weekly",
          "pace": { "burnMultiple": $burn }
        }
      ],
      "quotaSemantics": {
        "status": "known",
        "effectiveAvailability": [
          {
            "scope": "all_models",
            "status": "known",
            "limitingWindowIds": ["weekly"],
            "runway": $runway
          }
        ]
      }
    }
JSON
}

# A provider whose quotaSemantics key is present but explicitly null. Reading it
# as a mapping is the difference between this script's own disclosure and a
# Python traceback from a helper whose contract is to refuse rather than guess.
quota_provider_null_semantics() {
  local id=$1
  cat <<JSON
    {
      "provider": "$id",
      "label": "$id",
      "source": "oauth",
      "windows": [],
      "quotaSemantics": null
    }
JSON
}

HEALTHY='{ "status": "through_reset" }'
SCARCE='{ "status": "projected_exhaustion", "usableRunwaySeconds": 22337 }'
# The exhaustion is reported, its length is not a number. A build above the
# compatibility floor still clears the version check and can change a type.
SCARCE_UNREADABLE='{ "status": "projected_exhaustion", "usableRunwaySeconds": "soon" }'
# quota-axi reports this whenever a bounding window's pace is unmeasurable: the
# availability is known, only its runway is not.
UNKNOWN_RUNWAY='{ "status": "unknown", "unmeasurableWindowIds": ["weekly"] }'

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
# The third argument replaces the agent_args_override entries and the fourth
# appends to the block header line, so a case can drive the other declaration
# shapes a hand-edited config legitimately takes. An explicitly empty third
# argument means no entries at all, which is not the same as omitting it.
write_config() {
  local path=$1 agent_line=$2 override=${3-FM_TEST_DEFAULT_OVERRIDE} header_suffix=${4:-}
  if [ "$override" = FM_TEST_DEFAULT_OVERRIDE ]; then
    override='  pi:
    - --provider
    - minimax
    - --model
    - MiniMax-M3'
  fi
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

agent_args_override:$header_suffix
# Pi is the MiniMax validation path.
#
$override

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

# --- a write through a symlink edits the target, not the link ----------------
#
# A dotfiles checkout linked into place is a common setup, and --config makes
# the path arbitrary. Replacing the link with a regular file would leave the
# real config holding the stale order with nothing saying so.

REAL="$TMP_ROOT/linked-target.yaml"
write_config "$REAL" 'agent: [codex, pi]'
cp "$REAL" "$TMP_ROOT/linked.orig"
CFG="$TMP_ROOT/linked.yaml"
ln -s "$REAL" "$CFG"
write_quota "$(quota_provider codex 18 "$SCARCE" 4.874)"

out=$("$SCRIPT" --config "$CFG" --apply 2>&1) || fail "--apply through a symlink failed: $out"
[ -L "$CFG" ] || fail "--apply must leave the symlink a symlink, not a regular file"
assert_grep 'agent: [pi, codex]' "$REAL" "the link target should have received the new agent list"
LINKED_LINE_NO=$(grep -n '^agent:' "$REAL" | cut -d: -f1)
sed "${LINKED_LINE_NO}d" "$TMP_ROOT/linked.orig" > "$TMP_ROOT/linked.before.rest"
sed "${LINKED_LINE_NO}d" "$REAL" > "$TMP_ROOT/linked.after.rest"
cmp -s "$TMP_ROOT/linked.before.rest" "$TMP_ROOT/linked.after.rest" ||
  fail "a write through a symlink changed bytes outside the agent: line"
pass "--apply edits the link target surgically and leaves the symlink intact"

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

# --- a declared provider quota-axi does not report --------------------------
#
# The config declares --provider minimax for pi. A provider that merely happens
# to be named `pi` is a different account, and the config has already said which
# one pi runs, so the name match must not stand in for the declaration.

CFG="$TMP_ROOT/declared-unreported.yaml"
write_config "$CFG" 'agent: [codex, pi]'
write_quota "$(quota_provider codex 18 "$SCARCE" 4.874)" "$(quota_provider pi 96 "$HEALTHY" 0.3)"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
pi_row=$(printf '%s\n' "$out" | grep '^pi ' | head -1)
assert_contains "$pi_row" "none" "an unreported declaration should leave the row with no quota source"
assert_not_contains "$pi_row" "96%" \
  "a provider that only shares the engine's name must never supply that engine's headroom"
assert_contains "$out" \
  "pi: unmeasured - the config declares --provider minimax for it and quota-axi does not report that provider" \
  "the note should name the declared provider quota-axi did not report"
assert_contains "$out" "recommended: pi, codex" "an unreported declaration keeps the engine eligible"
pass "a declared provider quota-axi does not report is a gap, never a name match"

# --- every declaration shape is read, or the helper refuses -----------------
#
# The config is hand-edited and lives outside this repo, so the declaration
# legitimately appears as `--provider=<id>` and at indentations other than two
# spaces. Each shape the parser misses would silently hand the engine back to a
# name match against a provider that merely shares its id, which is the
# wrong-account measurement the declaration exists to prevent.

CFG="$TMP_ROOT/declared-inline.yaml"
write_config "$CFG" 'agent: [codex, pi]' '  pi:
    - --provider=minimax
    - --model=MiniMax-M3'
write_quota "$(quota_provider codex 18 "$SCARCE" 4.874)" "$(quota_provider pi 96 "$HEALTHY" 0.3)"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
pi_row=$(printf '%s\n' "$out" | grep '^pi ' | head -1)
assert_not_contains "$pi_row" "96%" \
  "a single-token --provider=<id> declaration must still block the name match"
assert_contains "$out" \
  "pi: unmeasured - the config declares --provider minimax for it and quota-axi does not report that provider" \
  "a single-token declaration should be read as a declaration"
pass "the single-token --provider=<id> form is read as a declaration"

write_quota "$(quota_provider codex 18 "$SCARCE" 4.874)" "$(quota_provider minimax 96 "$HEALTHY" 0.3)"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
assert_contains "$out" "minimax (declared)" "a single-token declaration should name the measured provider"
pass "a single-token declaration measures the engine against the provider it names"

CFG="$TMP_ROOT/declared-deep-indent.yaml"
write_config "$CFG" 'agent: [codex, pi]' '    pi:
      - --provider
      - minimax'
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
assert_contains "$out" "minimax (declared)" \
  "an indentation other than two spaces must not lose the declaration"
pi_row=$(printf '%s\n' "$out" | grep '^pi ' | head -1)
assert_contains "$pi_row" "96%" "the declared provider's headroom should measure the engine"
pass "a declaration at another indentation depth is still read"

# A declaration the parser cannot read refuses that ENGINE, never the report.
# Every other engine keeps its full evidence row and its place in the order,
# because a helper the worker is told to run before each engine change must not
# switch itself off over one malformed entry.
CFG="$TMP_ROOT/declared-unreadable.yaml"
write_config "$CFG" 'agent: [codex, pi]' '  pi: {provider: minimax}'
write_quota "$(quota_provider codex 18 "$SCARCE" 4.874)" "$(quota_provider pi 96 "$HEALTHY" 0.3)"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
pi_row=$(printf '%s\n' "$out" | grep '^pi ' | head -1)
assert_not_contains "$pi_row" "96%" "an unreadable declaration must never fall through to a name match"
assert_contains "$out" "pi: unmeasured - its agent_args_override entry is not a list of arguments" \
  "the note should say why that engine could not be measured"
assert_contains "$out" "codex (name)" "the other engine must keep its evidence row"
assert_contains "$out" "4.87x" "the other engine's burn multiple must still be reported"
assert_contains "$out" "recommended: pi, codex" "the recommendation must still print"
pass "an unreadable declaration refuses one engine and leaves the rest of the report standing"

CFG="$TMP_ROOT/declared-valueless.yaml"
write_config "$CFG" 'agent: [codex, pi]' '  pi:
    - --provider'
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
assert_contains "$out" \
  "pi: unmeasured - its agent_args_override entry names --provider without a readable value" \
  "a --provider with no value should refuse that engine by name"
pi_row=$(printf '%s\n' "$out" | grep '^pi ' | head -1)
assert_not_contains "$pi_row" "96%" "a valueless --provider must not fall through to a name match"
assert_contains "$out" "recommended: pi, codex" "one bad entry must not cancel the recommendation"
pass "a --provider with no value refuses that engine rather than guessing the account"

# An engine that declares nothing at all is unaffected and keeps the disclosed
# name match.
CFG="$TMP_ROOT/declares-nothing.yaml"
write_config "$CFG" 'agent: [codex, pi]' '  codex:
    - --model
    - gpt-5'
write_quota "$(quota_provider codex 18 "$SCARCE" 4.874)" "$(quota_provider pi 96 "$HEALTHY" 0.3)"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
assert_contains "$out" "pi (name)" "an engine that declares no provider keeps the disclosed name match"
assert_contains "$out" "name match against a reported provider id" "the name-match disclosure should still print"
pass "an engine declaring no provider keeps the name-match path and its disclosure"

# --- ordinary YAML the config legitimately contains -------------------------
#
# 107 of the real config's 146 lines are comments, so a comment beside a
# declaration is an expected edit rather than a contrived one, and a second
# block or a commented key is ordinary YAML too. Each shape a hand-rolled parser
# missed used to hand the engine back to a name match against a provider that
# merely shares its id.

CFG="$TMP_ROOT/inline-comment.yaml"
write_config "$CFG" 'agent: [codex, pi]' '  pi:
    - --provider # the MiniMax account
    - minimax'
write_quota "$(quota_provider codex 18 "$SCARCE" 4.874)" "$(quota_provider pi 96 "$HEALTHY" 0.3)"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
pi_row=$(printf '%s\n' "$out" | grep '^pi ' | head -1)
assert_not_contains "$pi_row" "96%" "an inline comment must not hand the engine back to a name match"
assert_contains "$out" \
  "pi: unmeasured - the config declares --provider minimax for it and quota-axi does not report that provider" \
  "an inline comment on the item must not hide the declaration"
pass "an inline YAML comment on the --provider item leaves the declaration readable"

write_quota "$(quota_provider codex 18 "$SCARCE" 4.874)" "$(quota_provider minimax 96 "$HEALTHY" 0.3)"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
assert_contains "$out" "minimax (declared)" "a commented declaration should measure the engine"
pass "a commented declaration measures the engine against the provider it names"

# A second block later in the file is read rather than ignored.
CFG="$TMP_ROOT/second-block.yaml"
write_config "$CFG" 'agent: [codex, pi]' '  codex:
    - --model
    - gpt-5

model_reasoning_effort: "high"

agent_args_override:
  pi:
    - --provider
    - minimax'
write_quota "$(quota_provider codex 18 "$SCARCE" 4.874)" "$(quota_provider pi 96 "$HEALTHY" 0.3)"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
pi_row=$(printf '%s\n' "$out" | grep '^pi ' | head -1)
assert_not_contains "$pi_row" "96%" "a declaration in a second block must not fall through to a name match"
assert_contains "$out" "pi: unmeasured - the config declares --provider minimax for it" \
  "a declaration in a second agent_args_override block must still be read"
assert_contains "$out" "codex (name)" "an engine declaring no provider keeps its own evidence"
pass "a declaration in a second agent_args_override block is read"

# --- a repeated declaration resolves the way the config's consumer does ------
#
# The config is loaded by a YAML parser, which resolves a duplicate mapping key
# and a repeated flag last-wins. Resolving either one differently here would
# print a healthy window for an account the pipeline never routes to.

# Two blocks declaring the same engine: the later one is what the config means.
CFG="$TMP_ROOT/repeated-block.yaml"
write_config "$CFG" 'agent: [codex, pi]' '  pi:
    - --provider
    - minimax

model_reasoning_effort: "high"

agent_args_override:
  pi:
    - --provider
    - openrouter'
write_quota "$(quota_provider codex 18 "$SCARCE" 4.874)" \
  "$(quota_provider minimax 95 "$HEALTHY" 0.3)" "$(quota_provider openrouter 4 "$SCARCE" 6.0)"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
pi_row=$(printf '%s\n' "$out" | grep '^pi ' | head -1)
assert_contains "$pi_row" "openrouter (declared)" "the later block is the declaration the config means"
assert_contains "$pi_row" "4%" "the engine must be measured against the account it is actually routed to"
assert_not_contains "$pi_row" "95%" "the shadowed declaration's healthy window must never be reported"
pass "a repeated block resolves to the later declaration, as the config's own parser does"

# The same engine key written twice inside ONE block: the later entry replaces
# the earlier one wholesale, so a --provider only in the earlier one is gone.
CFG="$TMP_ROOT/repeated-key.yaml"
write_config "$CFG" 'agent: [codex, pi]' '  pi:
    - --provider
    - minimax
  pi:
    - --model
    - MiniMax-M3'
write_quota "$(quota_provider codex 18 "$SCARCE" 4.874)" \
  "$(quota_provider minimax 95 "$HEALTHY" 0.3)" "$(quota_provider pi 96 "$HEALTHY" 0.2)"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
pi_row=$(printf '%s\n' "$out" | grep '^pi ' | head -1)
assert_not_contains "$pi_row" "minimax (declared)" \
  "an entry the later duplicate replaced must not still declare a provider"
assert_not_contains "$pi_row" "95%" "the replaced declaration's window must never be reported"
assert_contains "$pi_row" "pi (name)" "the surviving entry declares no provider, so the name match applies"
pass "a duplicate engine key resolves to the later entry, as the config's own parser does"

# A repeated flag inside one argument list resolves the same way.
CFG="$TMP_ROOT/repeated-flag.yaml"
write_config "$CFG" 'agent: [codex, pi]' '  pi:
    - --provider
    - minimax
    - --provider
    - openrouter'
write_quota "$(quota_provider codex 18 "$SCARCE" 4.874)" \
  "$(quota_provider minimax 95 "$HEALTHY" 0.3)" "$(quota_provider openrouter 4 "$SCARCE" 6.0)"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
pi_row=$(printf '%s\n' "$out" | grep '^pi ' | head -1)
assert_contains "$pi_row" "openrouter (declared)" "the last --provider in the list is the one that routes"
assert_contains "$pi_row" "4%" "the engine must be measured against the account it is actually routed to"
assert_not_contains "$pi_row" "95%" "the overridden --provider's healthy window must never be reported"
pass "a repeated --provider flag resolves to the last value, as an argument list does"

# When last-wins does not settle it - the surviving --provider has no value -
# that one engine is refused and the rest of the report stands.
CFG="$TMP_ROOT/unsettled-flag.yaml"
write_config "$CFG" 'agent: [codex, pi]' '  pi:
    - --provider
    - minimax
    - --provider'
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
assert_contains "$out" \
  "pi: unmeasured - its agent_args_override entry names --provider without a readable value" \
  "a surviving --provider with no value should refuse that engine"
pi_row=$(printf '%s\n' "$out" | grep '^pi ' | head -1)
assert_not_contains "$pi_row" "95%" "an unsettled declaration must not fall back to an earlier value"
assert_contains "$out" "codex (name)" "the other engine keeps its evidence row"
assert_contains "$out" "18%" "the other engine's headroom must still be reported"
assert_contains "$out" "recommended: pi, codex" "the recommendation must still print"
pass "a declaration last-wins cannot settle refuses that engine only"

# Trailing comments after the block header and after an engine key.
CFG="$TMP_ROOT/commented-keys.yaml"
write_config "$CFG" 'agent: [codex, pi]' '  pi: # the MiniMax path
    - --provider
    - minimax' ' # per-engine flags'
write_quota "$(quota_provider codex 18 "$SCARCE" 4.874)" "$(quota_provider minimax 96 "$HEALTHY" 0.3)"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
assert_contains "$out" "minimax (declared)" \
  "trailing comments on the block header and the engine key must not hide the declaration"
assert_contains "$out" "recommended: pi, codex" "a commented key must not stop the report"
pass "trailing comments after the block header and an engine key are ordinary YAML"

# An empty block declares nothing, which is not the same as being unreadable.
CFG="$TMP_ROOT/empty-block.yaml"
write_config "$CFG" 'agent: [codex, pi]' '' ' {}'
write_quota "$(quota_provider codex 18 "$SCARCE" 4.874)" "$(quota_provider pi 96 "$HEALTHY" 0.3)"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
assert_contains "$out" "pi (name)" "an empty declaration block declares nothing and leaves the name match"
assert_contains "$out" "recommended: pi, codex" "an empty declaration block must not stop the report"
pass "an empty agent_args_override block declares nothing and stops nothing"

# --- a missing YAML parser narrows the report, it never cancels it ----------
#
# PyYAML cannot be assumed present on every machine that runs firstmate. Without
# it no declaration can be read, so no engine may be handed to a name match, but
# the table and the recommended order must still print.

NOYAML="$TMP_ROOT/noyaml"
mkdir -p "$NOYAML/yaml"
printf 'raise ImportError("no YAML parser for this test")\n' > "$NOYAML/yaml/__init__.py"

CFG="$TMP_ROOT/no-parser.yaml"
write_config "$CFG" 'agent: [codex, pi]'
write_quota "$(quota_provider codex 18 "$SCARCE" 4.874)" "$(quota_provider pi 96 "$HEALTHY" 0.3)"
out=$(PYTHONPATH="$NOYAML" "$SCRIPT" --config "$CFG" 2>&1) ||
  fail "the report must still run without a YAML parser: $out"
assert_contains "$out" "recommended: codex, pi" "a missing parser must narrow the report, not cancel it"
assert_contains "$out" "no YAML parser to read it" "each row should say no parser was available"
pi_row=$(printf '%s\n' "$out" | grep '^pi ' | head -1)
codex_row=$(printf '%s\n' "$out" | grep '^codex ' | head -1)
assert_not_contains "$pi_row" "96%" "without a parser no engine may be handed to a name match"
assert_not_contains "$codex_row" "18%" "without a parser no engine may be handed to a name match"
pass "a missing YAML parser narrows the report and never restores a name match"

# With no declaration block at all there is nothing to parse, so the name match
# is unaffected by the parser being absent.
CFG="$TMP_ROOT/no-parser-no-block.yaml"
printf '# only comments\nagent: [codex, pi]\nci_timeout: "168h"\n' > "$CFG"
out=$(PYTHONPATH="$NOYAML" "$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
assert_contains "$out" "codex (name)" "a config with no declaration block needs no parser"
assert_contains "$out" "pi (name)" "a config with no declaration block needs no parser"
pass "a config declaring nothing is unaffected by a missing YAML parser"

# --- a YAML syntax error only costs what the config actually declares -------

CFG="$TMP_ROOT/broken-yaml-no-block.yaml"
printf '# only comments\nagent: [codex, pi]\nci_timeout: "168h\n' > "$CFG"
write_quota "$(quota_provider codex 18 "$SCARCE" 4.874)" "$(quota_provider pi 96 "$HEALTHY" 0.3)"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
assert_contains "$out" "codex (name)" "a config with no declaration block has nothing to lose to a parse error"
assert_contains "$out" "pi (name)" "a config with no declaration block has nothing to lose to a parse error"
assert_contains "$out" "recommended: pi, codex" "a parse error elsewhere must not empty the table"
pass "a YAML syntax error in a config that declares nothing refuses no engine"

# With a declaration block present the parse error does cost the declarations,
# and the parser's own message is reported once rather than per engine.
CFG="$TMP_ROOT/broken-yaml-with-block.yaml"
printf 'agent: [codex, pi]\nagent_args_override:\n  pi:\n    - --provider\n    - minimax\nci_timeout: "168h\n' > "$CFG"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
assert_contains "$out" "pi: unmeasured - the config is not YAML this helper can parse" \
  "an unparseable config must refuse the engines whose declarations it carries"
pi_row=$(printf '%s\n' "$out" | grep '^pi ' | head -1)
assert_not_contains "$pi_row" "96%" "an unparseable config must not fall through to a name match"
assert_contains "$out" "recommended: codex, pi" "an unparseable config must still rank what it can"
detail_count=$(printf '%s\n' "$out" | grep -c 'YAML parser could not read')
[ "$detail_count" = 1 ] ||
  fail "the parser message should be reported once, not once per engine (saw $detail_count)"
pass "an unparseable config reports the parser message once and refuses only its declarations"

# --- a reported provider with unknown availability --------------------------
#
# quota-axi knows the provider exists but reports no effective availability for
# it. The engine is unmeasured, but for a different reason than an absent
# provider, and the note must say which rather than contradicting its own row.

CFG="$TMP_ROOT/unknown-availability.yaml"
write_config "$CFG" 'agent: [codex, pi]'
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

# --- an unknown runway removes only the runway signal ------------------------
#
# quota-axi knows the headroom and cannot project the runway. That is one signal
# missing, not an engine in the same epistemic state as an unmeasured one, so
# the known headroom still carries the verdict and the column says `unknown`.

CFG="$TMP_ROOT/runway-unknown.yaml"
write_config "$CFG" 'agent: [codex, pi]'
write_quota "$(quota_provider codex 40 "$UNKNOWN_RUNWAY" 1.1)" \
  "$(quota_provider minimax 80 "$UNKNOWN_RUNWAY" 1.2)"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
codex_row=$(printf '%s\n' "$out" | grep '^codex ' | head -1)
assert_contains "$codex_row" "unknown" "an unknown runway should be labelled, not left blank"
assert_contains "$codex_row" "40%" "the headroom the report does have must still be shown"
assert_contains "$out" "recommended: pi, codex" \
  "two unknown-runway engines should be ordered by the headroom quota-axi does report"
pass "an unknown runway is disclosed and headroom alone orders the row"

# The same unknown runway must not move the row past a measured-healthy engine
# nor behind a proven-scarce one.
CFG="$TMP_ROOT/runway-unknown-mixed.yaml"
write_config "$CFG" 'agent: [codex, pi, gemini]'
write_quota "$(quota_provider codex 50 "$UNKNOWN_RUNWAY" 1.1)" \
  "$(quota_provider minimax 10 "$SCARCE" 5.0)" \
  "$(quota_provider gemini 90 "$HEALTHY" 0.3)"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
assert_contains "$out" "recommended: gemini, codex, pi" \
  "an unknown runway should rank below a measured-healthy engine and above a proven-scarce one"

# Replacing that unknown runway with a healthy one at the same headroom must
# leave the order identical, so the unknown runway itself moved nothing.
write_quota "$(quota_provider codex 50 "$HEALTHY" 1.1)" \
  "$(quota_provider minimax 10 "$SCARCE" 5.0)" \
  "$(quota_provider gemini 90 "$HEALTHY" 0.3)"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
assert_contains "$out" "recommended: gemini, codex, pi" \
  "an unknown runway alone must not change where the row sits"
pass "an unknown runway neither promotes nor demotes the row it describes"

# The discriminating case: each candidate policy for an unknown runway produces
# a DIFFERENT order here, so only the decided one passes. Keeping the row in the
# measured ranking gives `codex, gemini, pi, cursor`; filing it with the
# unmeasured engines gives `gemini, codex, pi, cursor`; calling it scarce gives
# `gemini, pi, cursor, codex`. codex carries the unknown runway at high headroom,
# gemini is measured healthy at lower headroom, pi is unmeasured because its
# declared minimax is unreported, and cursor is proven scarce at high headroom.
CFG="$TMP_ROOT/runway-unknown-policy.yaml"
write_config "$CFG" 'agent: [codex, pi, gemini, cursor]'
write_quota "$(quota_provider codex 88 "$UNKNOWN_RUNWAY" 1.1)" \
  "$(quota_provider gemini 30 "$HEALTHY" 0.3)" \
  "$(quota_provider cursor 95 "$SCARCE" 5.0)"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
assert_contains "$out" "recommended: codex, gemini, pi, cursor" \
  "an unknown runway must rank by headroom among the measured engines, above a lower-headroom healthy one and above a proven-scarce one"
pass "the unknown-runway rule is pinned against being read as unmeasured or as scarce"

# An availability that carries no runway object at all is the same missing
# signal and must read the same way rather than as an empty column.
CFG="$TMP_ROOT/runway-absent.yaml"
write_config "$CFG" 'agent: [codex, pi]'
write_quota "$(quota_provider_no_runway codex 50 1.1)"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
codex_row=$(printf '%s\n' "$out" | grep '^codex ' | head -1)
assert_contains "$codex_row" "unknown" "an absent runway should read as unknown, not as a blank column"
assert_contains "$out" "recommended: codex, pi" \
  "an absent runway must not demote a measured engine below an unmeasured one"
pass "an absent runway reads as unknown and leaves the measured ranking alone"

# --- a missing headroom number neither promotes nor demotes ------------------
#
# A measured engine whose availability reports no percentage remaining has one
# signal missing, not a bad one. Substituting any stand-in number would decide
# its rank on no evidence, and a below-zero stand-in files it under an engine
# proven to be empty.

CFG="$TMP_ROOT/headroom-absent.yaml"
write_config "$CFG" 'agent: [codex, gemini]'
write_quota "$(quota_provider_no_headroom codex "$HEALTHY" 1.1)" \
  "$(quota_provider gemini 0 "$HEALTHY" 0.3)"
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
codex_row=$(printf '%s\n' "$out" | grep '^codex ' | head -1)
assert_contains "$codex_row" "through reset" "the signals the report does have must still be shown"
assert_contains "$out" "recommended: codex, gemini" \
  "a missing headroom number must not demote a row beneath an engine measured at 0%"
pass "a missing headroom number does not demote the row that lacks it"

# The same pair in the other order: the missing number must not promote it
# either, so its existing position is what decides.
CFG="$TMP_ROOT/headroom-absent-reversed.yaml"
write_config "$CFG" 'agent: [gemini, codex]'
out=$("$SCRIPT" --config "$CFG" 2>&1) || fail "report failed: $out"
assert_contains "$out" "recommended: gemini, codex" \
  "a missing headroom number must not promote a row above an engine that reports one"
pass "a missing headroom number does not promote the row that lacks it"

# --- an unexpected quota-axi shape discloses rather than crashing ------------

CFG="$TMP_ROOT/null-semantics.yaml"
write_config "$CFG" 'agent: [codex, pi]'
write_quota "$(quota_provider_null_semantics codex)"
out=$("$SCRIPT" --config "$CFG" 2>&1)
rc=$?
expect_code 0 "$rc" "a null quotaSemantics should not abort the report"
assert_not_contains "$out" "Traceback" "an unexpected shape must not dump a Python stack trace"
assert_contains "$out" "codex: unmeasured - quota-axi reports provider codex for it but not" \
  "a null quotaSemantics should be disclosed as an unknown availability"
assert_contains "$out" "recommended: codex, pi" "both engines should stay in the candidate set"
pass "a null quotaSemantics is disclosed through the report, not a traceback"

# --- a value of an unexpected type is unusable evidence, not a crash --------
#
# The compatibility floor is a minimum, not a maximum: a quota-axi above it
# clears the version check and can still change a field's type. A field that
# arrives as the wrong type must degrade the way an absent one already does,
# with the reader told which field went unread.

CFG="$TMP_ROOT/headroom-not-a-number.yaml"
write_config "$CFG" 'agent: [codex, pi]'
write_quota "$(quota_provider codex '"18"' "$HEALTHY" 4.874)"
out=$("$SCRIPT" --config "$CFG" 2>&1)
rc=$?
expect_code 0 "$rc" "a headroom that is not a number should not abort the report"
assert_not_contains "$out" "Traceback" "an unexpected value type must not dump a Python stack trace"
assert_contains "$out" \
  "codex: quota-axi reported its headroom in a form this helper cannot read as a number" \
  "the report should disclose which field it could not read"
codex_row=$(printf '%s\n' "$out" | grep '^codex ' | head -1)
assert_not_contains "$codex_row" "18" "a value that is not a number must never be printed as one"
assert_contains "$codex_row" "through reset" "the evidence that did read must still be shown"
assert_contains "$out" "recommended: codex, pi" "the report must still rank what it can"
pass "a headroom of the wrong type blanks that column and says so"

CFG="$TMP_ROOT/burn-not-a-number.yaml"
write_config "$CFG" 'agent: [codex, pi]'
write_quota "$(quota_provider codex 18 "$HEALTHY" '"4.87"')"
out=$("$SCRIPT" --config "$CFG" 2>&1)
rc=$?
expect_code 0 "$rc" "a burn multiple that is not a number should not abort the report"
assert_not_contains "$out" "Traceback" "an unexpected value type must not dump a Python stack trace"
assert_contains "$out" \
  "codex: quota-axi reported its burn multiple in a form this helper cannot read as a number" \
  "the report should disclose which field it could not read"
codex_row=$(printf '%s\n' "$out" | grep '^codex ' | head -1)
assert_contains "$codex_row" "18%" "the headroom that did read must still be shown"
assert_not_contains "$codex_row" "4.87" "a value that is not a number must never be printed as one"
pass "a burn multiple of the wrong type blanks that column and says so"

CFG="$TMP_ROOT/runway-seconds-not-a-number.yaml"
write_config "$CFG" 'agent: [codex, pi]'
write_quota "$(quota_provider codex 18 "$SCARCE_UNREADABLE" 4.874)"
out=$("$SCRIPT" --config "$CFG" 2>&1)
rc=$?
expect_code 0 "$rc" "a runway length that is not a number should not abort the report"
assert_not_contains "$out" "Traceback" "an unexpected value type must not dump a Python stack trace"
assert_contains "$out" \
  "codex: quota-axi reported its usable runway seconds in a form this helper cannot read as a number" \
  "the report should disclose which field it could not read"
assert_contains "$out" "projected empty" "the exhaustion that WAS reported must still be shown"
assert_not_contains "$out" "soon" "a value that is not a number must never be printed as one"
assert_contains "$out" "recommended: pi, codex" "a proven exhaustion still ranks the engine last"
pass "an unreadable runway length keeps the exhaustion verdict and says what went unread"

# A payload that cannot describe providers at all has nothing to report from, so
# it refuses through the script's own message rather than a stack trace.

CFG="$TMP_ROOT/provider-not-an-object.yaml"
write_config "$CFG" 'agent: [codex, pi]'
cp "$CFG" "$TMP_ROOT/provider-not-an-object.orig"
printf '{ "schemaVersion": 3, "providers": ["codex"] }\n' > "$FM_FAKE_QUOTA_FILE"
out=$("$SCRIPT" --config "$CFG" --apply 2>&1)
rc=$?
expect_code 1 "$rc" "a provider entry that is not an object should refuse"
assert_not_contains "$out" "Traceback" "a structurally impossible payload must not dump a stack trace"
assert_contains "$out" "provider entry that is not an object" "the refusal should name the shape"
cmp -s "$TMP_ROOT/provider-not-an-object.orig" "$CFG" || fail "a refused write must leave the config untouched"
pass "a provider entry that is not an object refuses instead of crashing"

printf '[]\n' > "$FM_FAKE_QUOTA_FILE"
out=$("$SCRIPT" --config "$CFG" --apply 2>&1)
rc=$?
expect_code 1 "$rc" "a top-level array should refuse"
assert_not_contains "$out" "Traceback" "a structurally impossible payload must not dump a stack trace"
assert_contains "$out" "did not report an object at the top level" "the refusal should name the shape"
cmp -s "$TMP_ROOT/provider-not-an-object.orig" "$CFG" || fail "a refused write must leave the config untouched"
pass "a top-level array refuses instead of crashing"

printf '{ "schemaVersion": 3, "providers": "codex" }\n' > "$FM_FAKE_QUOTA_FILE"
out=$("$SCRIPT" --config "$CFG" --apply 2>&1)
rc=$?
expect_code 1 "$rc" "a providers value that is not a list should refuse"
assert_not_contains "$out" "Traceback" "a structurally impossible payload must not dump a stack trace"
assert_contains "$out" "something other than a list" "the refusal should name the shape"
cmp -s "$TMP_ROOT/provider-not-an-object.orig" "$CFG" || fail "a refused write must leave the config untouched"
pass "a providers value that is not a list refuses instead of crashing"

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

# quota-axi makes authenticated vendor calls, so a stall must hit this script's
# own bound and refuse rather than blocking the validation lane that ran it.
CFG="$TMP_ROOT/stalled.yaml"
write_config "$CFG" 'agent: [codex, pi]'
cp "$CFG" "$TMP_ROOT/stalled.orig"
out=$(FM_PIPELINE_ENGINE_QUOTA_TIMEOUT=1 FM_FAKE_QUOTA_SLEEP=8 "$SCRIPT" --config "$CFG" --apply 2>&1)
rc=$?
expect_code 1 "$rc" "a stalled quota-axi --json should refuse rather than block"
assert_contains "$out" "did not finish within 1s" "the refusal should name the bound that was hit"
cmp -s "$TMP_ROOT/stalled.orig" "$CFG" || fail "a refused write must leave the config untouched"
pass "a stalled quota-axi --json hits its bound and refuses instead of hanging"

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
