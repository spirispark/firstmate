#!/usr/bin/env bash
# Behavior tests for the tracked graphify harness config.
#
# Four contracts:
#   PLUGIN - .opencode/plugins/graphify.js shares the tool.execute.before chain
#            with the watcher-arm seatbelt (.opencode/plugins/fm-primary-pretool-check.js,
#            bin/fm-arm-command-policy.mjs), which classifies the WHOLE bash
#            program. A reminder prepended to a firstmate bin script would make a
#            legitimate arm call read as watcher-bundled, so those commands must
#            pass through untouched while an ordinary command still gets the
#            once-per-session reminder.
#   HOOK   - the .gemini/settings.json BeforeTool command must exit 0 silently
#            when graphify is not installed, and delegate to `graphify hook-guard
#            gemini` when PATH resolves it.
#   ALIAS  - GEMINI.md is a symlink alias of AGENTS.md, so every harness reads one
#            rule set instead of drifting into a second standalone file.
#   IGNORE - graphify-out/ stays ignored, so the `graphify update .` AGENTS.md
#            tells agents to run cannot leave an untracked entry that makes
#            dirty_status (bin/fm-ff-lib.sh) non-empty and stops bin/fm-update.sh
#            from fast-forwarding a home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-graphify-harness)
GRAPHIFY_PLUGIN="$ROOT/.opencode/plugins/graphify.js"
GEMINI_SETTINGS="$ROOT/.gemini/settings.json"
BARE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# --- PLUGIN: .opencode/plugins/graphify.js ----------------------------------

test_plugin_spares_fm_bin_scripts() {
  local graph_dir out status=0
  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found for the graphify opencode plugin test"
    return 0
  fi
  graph_dir="$TMP_ROOT/plugin"
  mkdir -p "$graph_dir/graphify-out"
  printf '{}\n' > "$graph_dir/graphify-out/graph.json"

  out=$(PLUGIN="$GRAPHIFY_PLUGIN" GRAPH_DIR="$graph_dir" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const hooks = await mod.GraphifyPlugin({ directory: process.env.GRAPH_DIR });
const call = async (command) => {
  const output = { args: { command } };
  await hooks["tool.execute.before"]({ tool: "bash" }, output);
  return output.args.command;
};

const arm = "bin/fm-watch-arm.sh --home /tmp/home";
const armResult = await call(arm);
if (armResult !== arm) throw new Error(`watcher-arm command was rewritten: ${armResult}`);

const ordinary = "git status --porcelain";
const ordinaryResult = await call(ordinary);
if (!ordinaryResult.startsWith('echo "[graphify]')) {
  throw new Error(`ordinary command lost the reminder: ${ordinaryResult}`);
}
if (!ordinaryResult.endsWith(` ; ${ordinary}`)) {
  throw new Error(`ordinary command body was not preserved: ${ordinaryResult}`);
}

const repeat = await call("ls");
if (repeat !== "ls") throw new Error(`reminder repeated within one session: ${repeat}`);
EOF
  ) || status=$?
  expect_code 0 "$status" "graphify plugin bash rewrite: $out"
  [ -z "$out" ] || fail "graphify plugin test printed output: $out"
  pass "graphify plugin: a bin/fm-*.sh command passes through, an ordinary one is reminded once"
}

# --- HOOK: .gemini/settings.json BeforeTool ---------------------------------

gemini_hook_command() {
  python3 - "$GEMINI_SETTINGS" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
commands = [
    hook["command"]
    for entry in data["hooks"]["BeforeTool"]
    if "read_file" in entry["matcher"].split("|")
    for hook in entry["hooks"]
    if hook["type"] == "command"
]
if len(commands) != 1:
    raise SystemExit(f"expected exactly one read_file BeforeTool command, got {len(commands)}")
print(commands[0])
PY
}

test_gemini_hook_is_silent_without_graphify() {
  local hook out status=0
  hook=$(gemini_hook_command) || fail "could not read the gemini BeforeTool hook command"
  out=$(PATH="$BARE_PATH" bash -c "$hook" 2>&1) || status=$?
  expect_code 0 "$status" "gemini BeforeTool hook with graphify absent from PATH"
  [ -z "$out" ] || fail "gemini hook was not silent without graphify installed: $out"
  pass "gemini BeforeTool hook: exit 0 and silent when graphify is not installed"
}

test_gemini_hook_delegates_to_graphify() {
  local hook fakebin out status=0
  hook=$(gemini_hook_command) || fail "could not read the gemini BeforeTool hook command"
  fakebin=$(fm_fakebin "$TMP_ROOT/gemini-hook")
  cat > "$fakebin/graphify" <<'SH'
#!/usr/bin/env bash
printf 'graphify %s\n' "$*"
SH
  chmod +x "$fakebin/graphify"
  out=$(PATH="$fakebin:$BARE_PATH" bash -c "$hook" 2>&1) || status=$?
  expect_code 0 "$status" "gemini BeforeTool hook with graphify on PATH"
  [ "$out" = "graphify hook-guard gemini" ] \
    || fail "gemini hook did not delegate to 'graphify hook-guard gemini': $out"
  pass "gemini BeforeTool hook: delegates to the PATH-resolved graphify hook-guard"
}

# --- ALIAS: GEMINI.md -------------------------------------------------------

test_gemini_md_is_an_agents_md_alias() {
  [ -L "$ROOT/GEMINI.md" ] \
    || fail "GEMINI.md must stay a symlink alias instead of a second standalone rule file"
  [ "$ROOT/GEMINI.md" -ef "$ROOT/AGENTS.md" ] \
    || fail "GEMINI.md does not resolve to AGENTS.md"
  pass "GEMINI.md resolves to AGENTS.md, so every harness reads one rule set"
}

# --- IGNORE: graphify-out/ --------------------------------------------------

test_graphify_out_stays_ignored() {
  local sample
  for sample in graphify-out/graph.json graphify-out/GRAPH_REPORT.md graphify-out/wiki/index.md; do
    git -C "$ROOT" check-ignore -q "$sample" \
      || fail "git does not ignore $sample (graphify update . would dirty the tree and block the fast-forward)"
  done
  pass "graphify-out/ is ignored as a directory, so a generated graph never dirties the tree"
}

test_plugin_spares_fm_bin_scripts
test_gemini_hook_is_silent_without_graphify
test_gemini_hook_delegates_to_graphify
test_gemini_md_is_an_agents_md_alias
test_graphify_out_stays_ignored
