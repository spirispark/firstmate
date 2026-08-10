// graphify OpenCode plugin
// Injects a knowledge graph reminder before bash tool calls when the graph exists.
//
// IMPORTANT: keep the reminder string free of backticks and $(...) constructs.
// The hook prepends `echo "<reminder>" && <cmd>` to the user's bash command;
// backticks inside the double-quoted echo trigger bash command substitution,
// which both corrupts tool output and silently executes the very graphify
// command we are only suggesting. Plain words render fine in opencode's TUI.
import { existsSync } from "fs";
import { join } from "path";

// Firstmate divergence from upstream graphify: a firstmate bin script may be
// audited by the watcher-arm PreToolUse seatbelt (bin/fm-arm-command-policy.mjs),
// which classifies the whole bash program, so a prepended echo would make a
// legitimate arm call read as watcher-bundled. Leave those commands untouched
// and let the next ordinary command carry the reminder.
const FM_BIN_SCRIPT = /bin\/fm[a-z0-9-]*\.sh/;

export const GraphifyPlugin = async ({ directory }) => {
  let reminded = false;

  return {
    "tool.execute.before": async (input, output) => {
      if (reminded) return;
      if (!existsSync(join(directory, "graphify-out", "graph.json"))) return;

      if (input.tool === "bash") {
        if (FM_BIN_SCRIPT.test(output.args.command)) return;
        // ';' not '&&' — Windows PowerShell 5.1 rejects '&&' as a statement
        // separator, breaking the first bash command of the session (#1646).
        output.args.command =
          'echo "[graphify] knowledge graph at graphify-out/. For focused questions, run graphify query with your question (scoped subgraph, usually much smaller than graphify-out/GRAPH_REPORT.md) instead of grepping raw files. Read graphify-out/GRAPH_REPORT.md only for broad architecture context." ; ' +
          output.args.command;
        reminded = true;
      }
    },
  };
};
