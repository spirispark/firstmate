#!/usr/bin/env bash
# fm-pipeline-engine.sh - report the no-mistakes validation pipeline's engine
# order from current quota evidence, and apply it only when told to.
#
# The pipeline picks its agent from one static ordered list in the no-mistakes
# global config (`agent: [...]`). That list has no quota awareness: it is a hand
# edit, so in practice it is re-ordered only after a window is already damaged.
# This script turns the same decision into an evidence-led one by printing, for
# every engine ALREADY in that list, the headroom, runway, and burn multiple
# behind the recommended order, so the reader can disagree at a glance.
#
# It is a reporting helper with an opt-in write. It is not a scheduler, not a
# daemon, and not a policy engine: it never runs itself, never watches anything,
# and renders no eligibility verdict.
#
# Boundaries that keep it honest:
#
#   - `quota-axi` is the single data owner. This script reads its JSON and
#     nothing else: no window name, plan, reset rule, or burn formula is
#     reimplemented or hardcoded here. Its compatibility floor is the one owned
#     by bin/fm-quota-axi-lib.sh, and a build below that floor is refused rather
#     than parsed against an unverified schema.
#
#   - An engine `quota-axi` cannot see is UNMEASURED, never ineligible. Pi's
#     MiniMax path is absent from that output entirely; per AGENTS.md section 4
#     that is disclosed uncertainty. An unmeasured engine keeps its place in the
#     candidate set and ranks ahead of an engine with a PROVEN scarce window.
#
#   - The engine-to-provider link is evidence with a stated basis, never a
#     silent inference. `declared` means the config's own agent_args_override
#     names `--provider <id>` and `quota-axi` reports that provider; `name` means
#     the engine id itself matches a reported provider id; `none` means no
#     evidence, so the engine is unmeasured. The basis is printed on every row
#     because AGENTS.md forbids inferring a provider mapping from a name alone,
#     and a disclosed name match is the reader's to reject. A declaration this
#     script cannot read is never downgraded to a name match: that engine alone
#     is reported unmeasured with the reason, and every other engine still gets
#     its full row and its place in the recommended order.
#
#   - Candidates come only from the list already in the config. An engine the
#     captain excluded by standing preference is therefore never introduced by
#     this script. One that IS present is under a recorded exception: it keeps
#     its exact position, is never re-ranked, and is flagged so the reader can
#     check the exception's own revert condition. When the exception ends and the
#     engine leaves the list, nothing here can quietly promote it back.
#
#   - Quota and reliability are different signals. This ranks quota only. An
#     engine that wedges or stalls is a reliability problem (see the
#     fm-wedge-autodetect work); reordering to escape a stall spends a scarce
#     window on a fault the new window does not fix.
#
#   - The config lives outside this repo and is mostly dated decision history in
#     comments. A write is a surgical replacement of the single `agent:` line;
#     every other byte, comments included, is preserved. Anything unexpected -
#     an absent file, no `agent:` line, more than one, or a shape that is not
#     `agent: [a, b, c]` - is refused with the offending line quoted. The script
#     never guesses and rewrites.
#
#   - It never touches the no-mistakes daemon. A config change takes effect on
#     the next agent invocation; the daemon is one shared instance serving every
#     lane, so restarting it would kill other lanes' in-flight runs.
#
# Known limitation, recorded rather than fixed:
#
#   Whether the config declares an agent_args_override block at all is decided by
#   a regex over the raw text, before the YAML parser is consulted. A top-level
#   key that the parser resolves but that regex does not match is therefore
#   skipped entirely, and every engine the block declares falls back to the
#   disclosed name match instead of being measured against its declared provider.
#   The shape that triggers it is the quoted spelling, `"agent_args_override":`;
#   the plain, flow-style and anchor spellings all match and are read normally.
#   This is a known gap left for follow-up work, not a decision.
#
# Usage:
#   fm-pipeline-engine.sh [--config <path>] [--exclude <list>] [--apply]
#
# Options:
#   --config <path>   no-mistakes global config to read (and with --apply,
#                     write). Default: $FM_NO_MISTAKES_CONFIG, else
#                     ~/.no-mistakes/config.yaml
#   --exclude <list>  comma-separated engines excluded by standing captain
#                     preference. Default: $FM_PIPELINE_ENGINE_EXCLUDE, else
#                     "claude". Pass an empty value to exclude nothing.
#   --apply           write the recommended order to the config. Without it the
#                     script only reports; an order equal to the current one is
#                     never written at all.
#   -h, --help        print this usage
#
# Environment:
#   FM_PIPELINE_ENGINE_QUOTA_TIMEOUT  seconds to bound the `quota-axi --json`
#                     read. Default 30. A stalled vendor call refuses rather
#                     than blocking the lane that invoked this.
#
# Exit status:
#   0  the report printed (and with --apply, the config is at the recommended
#      order)
#   1  refused: config missing or unreadable, `agent:` line missing/duplicated/
#      unexpected shape, or no usable quota evidence within the bound. Nothing
#      is written.
#   2  usage error
set -u

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  sed -n '/^# Usage:/,/^#   2  usage error/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'fm-pipeline-engine: %s\n' "$1" >&2
  exit "${2:-1}"
}

CONFIG=${FM_NO_MISTAKES_CONFIG:-$HOME/.no-mistakes/config.yaml}
EXCLUDE=${FM_PIPELINE_ENGINE_EXCLUDE-claude}
APPLY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --config)
      [ "$#" -gt 1 ] || die "--config requires a path" 2
      CONFIG=$2
      shift 2
      ;;
    --config=*)
      CONFIG=${1#--config=}
      shift
      ;;
    --exclude)
      [ "$#" -gt 1 ] || die "--exclude requires a value" 2
      EXCLUDE=$2
      shift 2
      ;;
    --exclude=*)
      EXCLUDE=${1#--exclude=}
      shift
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1" 2
      ;;
  esac
done

[ -f "$CONFIG" ] || die "config not found: $CONFIG"

# The version floor is owned once by bin/fm-quota-axi-lib.sh. Refusing below it
# keeps this script from parsing an output schema nobody checked it against.
# shellcheck source=bin/fm-quota-axi-lib.sh disable=SC1091
. "$SELF_DIR/fm-quota-axi-lib.sh"
command -v quota-axi >/dev/null 2>&1 ||
  die "quota-axi is not on PATH; quota evidence is required to recommend an order"
fm_quota_axi_compatible 20 ||
  die "quota-axi is older than the ${FM_QUOTA_AXI_MIN} floor or did not report a version"

# A non-positive bound is not a bound: `timeout 0` and the Perl fallback's
# `alarm 0` both disable the deadline, so a hung vendor CLI would run unbounded.
QUOTA_TIMEOUT=${FM_PIPELINE_ENGINE_QUOTA_TIMEOUT:-30}
case "$QUOTA_TIMEOUT" in
  ''|*[!0-9]*|0*) QUOTA_TIMEOUT=30 ;;
esac

# Bounded execution is owned by bin/fm-timeout-lib.sh. quota-axi makes
# authenticated vendor calls, and a stalled one must produce this script's own
# refusal rather than an indefinite silent block in a validation lane.
# Exit 124 means the bound was hit.
# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$SELF_DIR/fm-timeout-lib.sh"

QUOTA_RC=0
QUOTA_JSON=$(fm_run_timed "$QUOTA_TIMEOUT" quota-axi --json 2>/dev/null </dev/null) || QUOTA_RC=$?
if [ "$QUOTA_RC" -eq 124 ]; then
  die "quota-axi --json did not finish within ${QUOTA_TIMEOUT}s; refusing to recommend an order without evidence"
elif [ "$QUOTA_RC" -ne 0 ]; then
  die "quota-axi --json failed; refusing to recommend an order without evidence"
fi

command -v python3 >/dev/null 2>&1 || die "python3 is required to read quota-axi JSON"

# The reader below takes the JSON through the environment because stdin already
# carries this script.
FM_PIPELINE_ENGINE_QUOTA_JSON=$QUOTA_JSON \
  python3 - "$CONFIG" "$EXCLUDE" "$APPLY" <<'PY'
import json
import os
import re
import sys

config_path, exclude_raw, apply_raw = sys.argv[1], sys.argv[2], sys.argv[3]
apply_write = apply_raw == "1"
excluded = [e.strip() for e in exclude_raw.split(",") if e.strip()]


def die(msg):
    sys.stderr.write("fm-pipeline-engine: %s\n" % msg)
    raise SystemExit(1)


# --- config: locate the one agent list, refuse anything else ----------------

try:
    with open(config_path, "rb") as fh:
        raw = fh.read()
except OSError as exc:
    die("cannot read %s: %s" % (config_path, exc))

try:
    text = raw.decode("utf-8")
except UnicodeDecodeError:
    die("%s is not valid UTF-8; refusing to rewrite it" % config_path)

lines = text.split("\n")
agent_idx = [i for i, line in enumerate(lines) if re.match(r"^agent\s*:", line)]
if not agent_idx:
    die("no `agent:` line in %s; refusing to guess where the engine list is" % config_path)
if len(agent_idx) > 1:
    die(
        "%d `agent:` lines in %s (lines %s); refusing to guess which one the pipeline reads"
        % (len(agent_idx), config_path, ", ".join(str(i + 1) for i in agent_idx))
    )

idx = agent_idx[0]
shape = re.match(r"^agent\s*:\s*\[([^\]]*)\]\s*$", lines[idx])
if not shape:
    die(
        "the `agent:` line at %s:%d is not the expected `agent: [a, b, c]` list, so there is "
        "no single line to edit safely. Line reads: %s" % (config_path, idx + 1, lines[idx])
    )

current = [e.strip() for e in shape.group(1).split(",") if e.strip()]
if not current:
    die("the `agent:` list at %s:%d is empty" % (config_path, idx + 1))
for engine in current:
    if not re.match(r"^[A-Za-z0-9_.:-]+$", engine):
        die("unexpected engine name %r in the `agent:` list at %s:%d" % (engine, config_path, idx + 1))


# --- config: declared provider per engine (agent_args_override) -------------
#
# Read only what the config itself declares. This is the sole non-inferred
# engine-to-provider evidence available, and it is what makes Pi's MiniMax path
# attributable if quota-axi ever reports that provider.
#
# The invariant: once an agent_args_override block exists, a name match must
# NEVER decide the answer for an engine in it. Either the declaration is parsed
# and used, or that engine is refused with the reason stated on its own row.
#
# A real YAML parser owns the shape, and it resolves the config the same way the
# config's own consumer does. An inline comment on an item, a trailing comment
# after the block header or an engine key, an empty block, any indentation, a
# second block later in the file, and both the `--provider <id>` and
# `--provider=<id>` spellings are then simply understood, rather than chased one
# regex at a time while each unrecognized shape quietly restores the
# wrong-account measurement.
#
# Agreeing with that consumer is the whole point of loading rather than
# hand-resolving: a duplicate mapping key and a repeated flag both resolve
# last-wins, so an engine whose entry is written twice is measured against the
# account the config actually routes it to. Resolving a repeat any other way
# would print a healthy window for an account the pipeline never uses.
#
# The import is optional: PyYAML cannot be assumed present on every machine that
# runs firstmate. Without it the helper still reports, and every engine that
# could carry a declaration is refused by name rather than handed to a name
# match that might measure another account. A refusal is always scoped to the
# engine it concerns, so the rest of the table and the recommended order are
# unaffected: a missing parser narrows the report, it never cancels it. A config
# that declares no block at all has no declaration to lose, so neither a missing
# parser nor a parse error refuses anything there.

try:
    import yaml
except ImportError:
    yaml = None

NO_NAME_MATCH = ", so a name match is not trusted in its place"


def declares_override(text):
    return any(re.match(r"^agent_args_override\s*:", line) for line in text.split("\n"))


def provider_from_args(args):
    """(the LAST --provider value in the list, whether the flag appears at all)."""
    provider, named = None, False
    for i, arg in enumerate(args):
        if not isinstance(arg, str):
            continue
        if arg == "--provider":
            value = args[i + 1] if i + 1 < len(args) else None
            provider = value if isinstance(value, str) else None
            named = True
        elif arg.startswith("--provider="):
            provider = arg.split("=", 1)[1] or None
            named = True
    return provider, named


def declared_providers(text, engines):
    declared, refused, detail = {}, {}, None
    if not declares_override(text):
        return declared, refused, detail

    if yaml is None:
        for engine in engines:
            refused[engine] = (
                "the config declares agent_args_override and this python3 has no YAML parser "
                "to read it" + NO_NAME_MATCH
            )
        return declared, refused, detail

    try:
        config = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        detail = "the YAML parser could not read %s: %s" % (
            config_path,
            " ".join(str(exc).split()),
        )
        for engine in engines:
            refused[engine] = "the config is not YAML this helper can parse" + NO_NAME_MATCH
        return declared, refused, detail

    block = config.get("agent_args_override") if isinstance(config, dict) else None
    if not block:
        return declared, refused, detail
    if not isinstance(block, dict):
        for engine in engines:
            refused[engine] = (
                "its agent_args_override block is not a mapping of engines to arguments"
                + NO_NAME_MATCH
            )
        return declared, refused, detail

    for name, args in block.items():
        if not isinstance(name, str) or args is None:
            continue
        if not isinstance(args, list):
            refused[name] = (
                "its agent_args_override entry is not a list of arguments" + NO_NAME_MATCH
            )
            continue
        provider, named = provider_from_args(args)
        if not named:
            continue
        if not provider or not re.match(r"^[A-Za-z0-9_.:-]+$", provider):
            refused[name] = (
                "its agent_args_override entry names --provider without a readable value"
                + NO_NAME_MATCH
            )
            continue
        declared[name] = provider
    return declared, refused, detail


declared, refused, declaration_detail = declared_providers(text, current)

# --- quota-axi: the single data owner ---------------------------------------

try:
    quota = json.loads(os.environ["FM_PIPELINE_ENGINE_QUOTA_JSON"])
except ValueError as exc:
    die("quota-axi --json is not valid JSON: %s" % exc)

# The version floor is a minimum, not a maximum: a build ABOVE it clears the
# compatibility check and can still change a field's type. So the shape is read
# defensively at two different strengths. A payload that cannot describe
# providers at all - a top level or a provider entry that is not an object - is
# refused, because there is nothing to report from it. A single field that
# arrives as the wrong type is unusable evidence rather than an impossible
# payload, so it degrades exactly the way an absent field already does, and the
# reader is told which field went unread rather than being shown a stack trace.

if not isinstance(quota, dict):
    die("quota-axi --json did not report an object at the top level; refusing to read an unknown shape")

raw_providers = quota.get("providers")
if raw_providers is None:
    raw_providers = []
if not isinstance(raw_providers, list):
    die("quota-axi --json reported `providers` as something other than a list; refusing to read an unknown shape")

providers = {}
for provider in raw_providers:
    if not isinstance(provider, dict):
        die("quota-axi --json reported a provider entry that is not an object; refusing to read an unknown shape")
    pid = provider.get("provider")
    if not isinstance(pid, str) or not pid:
        die("quota-axi --json reported a provider entry with no readable `provider` id; refusing to read an unknown shape")
    providers[pid] = provider


def as_mapping(value):
    return value if isinstance(value, dict) else {}


def as_sequence(value):
    return value if isinstance(value, list) else []


def as_number(value):
    """The value when it is a number this helper can use, else None."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return value


def readable_number(value, label, consequence, unreadable):
    """The value as a number, recording what the row lost when it is not one.

    The consequence travels with the label because only the caller knows what
    the row goes on to render without that value, and a note that guessed would
    be the report contradicting its own table.
    """
    number = as_number(value)
    if number is None and value is not None:
        unreadable.append((label, consequence))
    return number


def availability(provider):
    """all_models effective availability, or None when it is not known."""
    semantics = as_mapping(provider.get("quotaSemantics"))
    for entry in as_sequence(semantics.get("effectiveAvailability")):
        if not isinstance(entry, dict):
            continue
        if entry.get("scope") == "all_models" and entry.get("status") == "known":
            return entry
    return None


def burn_multiple(provider, entry):
    """Burn multiple of the window that limits this provider, else None.

    A burn multiple describes one specific window, so another window's figure is
    never a stand-in for it: printing one in the limiting window's column is a
    category error, a number that reads as authoritative about the constraint
    while describing something else. When the limiting window reports no pace,
    the column shows nothing.
    """
    limiting = (as_sequence(entry.get("limitingWindowIds")) or [None])[0]
    if limiting is None:
        return None
    for window in as_sequence(provider.get("windows")):
        if isinstance(window, dict) and window.get("id") == limiting:
            return as_mapping(window.get("pace")).get("burnMultiple")
    return None


def human_duration(seconds):
    seconds = int(seconds)
    if seconds <= 0:
        return "0m"
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes = rem // 60
    if days:
        return "%dd%dh" % (days, hours)
    if hours:
        return "%dh%dm" % (hours, minutes)
    return "%dm" % minutes


def describe_runway(runway, unreadable):
    status = as_mapping(runway).get("status")
    if status == "through_reset":
        return "through reset", False
    if status == "projected_exhaustion":
        reported = as_mapping(runway).get("usableRunwaySeconds")
        secs = as_number(reported)
        if secs is not None:
            return "empty in %s" % human_duration(secs), True
        label = "projected empty"
        if reported is not None:
            unreadable.append(
                (
                    "the length of its projected exhaustion",
                    "the runway column reports `%s` without a duration" % label,
                )
            )
        return label, True
    if status:
        return str(status).replace("_", " "), False
    return "unknown", False


# A declaration the config makes is evidence, and it settles the question either
# way. When quota-axi does not report the declared provider, the name-match
# fallback is off the table for that engine: measuring it against a provider
# whose id merely equals the engine name is measuring the wrong account, which
# the config itself has already contradicted. A labelled substitute would still
# be the wrong number, so the answer is the gap. The name match stays available
# only to an engine that declares nothing.
rows = []
for position, engine in enumerate(current):
    source, basis = None, "none"
    if engine in refused:
        source, basis = None, "none"
    elif engine in declared:
        if declared[engine] in providers:
            source, basis = declared[engine], "declared"
    elif engine in providers:
        source, basis = engine, "name"

    entry = availability(providers[source]) if source else None
    measured = entry is not None
    unreadable = []
    headroom, burn = None, None
    runway_label, scarce = "-", False
    if measured:
        headroom = readable_number(
            entry.get("effectivePercentRemaining"),
            "its headroom",
            "the headroom column is blank",
            unreadable,
        )
        burn = readable_number(
            burn_multiple(providers[source], entry),
            "its burn multiple",
            "the burn column is blank",
            unreadable,
        )
        runway_label, scarce = describe_runway(entry.get("runway"), unreadable)
    rows.append(
        {
            "engine": engine,
            "position": position,
            "source": source,
            "basis": basis,
            "measured": measured,
            "headroom": headroom,
            "runway": runway_label,
            "scarce": scarce,
            "burn": burn,
            "unreadable": unreadable,
            "excluded": engine in excluded,
        }
    )

# --- recommended order ------------------------------------------------------
#
# Tier 0 is every measured engine whose runway does NOT report a projected
# exhaustion, tier 1 is unmeasured, tier 2 is measured with a projected
# exhaustion. An unknown window outranks a window proven to be running out;
# within a tier, more headroom first, then the existing order so a tie
# introduces no bias.
#
# A runway that is unknown or absent therefore neither promotes nor demotes its
# row: it removes only the runway signal, and a measured engine's known headroom
# carries the verdict alone. Filing it with the unmeasured engines would discard
# a number this report has, because an engine reporting 6% remaining is not in
# the same epistemic state as one reporting nothing at all; calling it scarce
# would rank an engine at 95% headroom last purely because a pace field was
# missing, which is the opposite error. Only a reported projected exhaustion is
# the scarce verdict.
#
# A missing headroom NUMBER is the same rule in the other direction. Inside its
# tier only the rows that report one are sorted against each other; a row without
# one keeps the slot its existing position gives it, so it is neither promoted
# over a measured peer nor filed beneath an engine proven to be at 0%. Any
# stand-in number would decide that on no evidence.


def tier_of(row):
    if not row["measured"]:
        return 1
    return 2 if row["scarce"] else 0


def rank_tier(tier_rows):
    numbered = sorted(
        (row for row in tier_rows if row["headroom"] is not None),
        key=lambda row: (-row["headroom"], row["position"]),
    )
    feed = iter(numbered)
    return [row if row["headroom"] is None else next(feed) for row in tier_rows]


pinned = {row["position"]: row for row in rows if row["excluded"]}
candidates = [row for row in rows if not row["excluded"]]
ranked = []
for tier in (0, 1, 2):
    ranked.extend(rank_tier([row for row in candidates if tier_of(row) == tier]))

recommended, feed = [], iter(ranked)
for position in range(len(rows)):
    recommended.append(pinned[position]["engine"] if position in pinned else next(feed)["engine"])

# --- report -----------------------------------------------------------------

out = sys.stdout.write
out("config:  %s\n" % config_path)
out("current: %s\n" % ", ".join(current))
out("\n")
table = [("engine", "quota source", "headroom", "runway", "burn")]
for row in rows:
    table.append(
        (
            row["engine"],
            "%s (%s)" % (row["source"], row["basis"]) if row["source"] else "none",
            "%d%%" % row["headroom"] if row["headroom"] is not None else "-",
            row["runway"],
            "%.2fx" % row["burn"] if row["burn"] is not None else "-",
        )
    )

# Widths come from the data so no cell can overflow its column and shift the
# rest of its row out of alignment, in a report whose whole point is that the
# reader can disagree at a glance.
widths = [max(len(cells[i]) for cells in table) for i in range(len(table[0]) - 1)]
row_format = " ".join("%%-%ds" % width for width in widths) + " %s\n"
for cells in table:
    out(row_format % cells)

notes = []
for row in rows:
    if not row["measured"]:
        if row["engine"] in refused:
            because = refused[row["engine"]]
        elif row["source"] is None and row["engine"] in declared:
            because = (
                "the config declares --provider %s for it and quota-axi does not report that "
                "provider, so no name match is trusted in its place"
                % declared[row["engine"]]
            )
        elif row["source"] is None:
            because = "quota-axi reports no provider for it"
        else:
            because = (
                "quota-axi reports provider %s for it but not that provider's availability"
                % row["source"]
            )
        notes.append(
            "%s: unmeasured - %s. Disclosed uncertainty, not grounds to exclude; it keeps its "
            "place in the candidate set." % (row["engine"], because)
        )
    for label, consequence in row["unreadable"]:
        notes.append(
            "%s: quota-axi reported %s in a form this helper cannot read as a number, so %s. The "
            "rest of its evidence stands and it keeps its place in the candidate set."
            % (row["engine"], label, consequence)
        )
    if row["excluded"]:
        notes.append(
            "%s: excluded by standing preference but present in the list, so it is under a "
            "recorded exception. Position %d is pinned and never re-ranked here - check that "
            "exception's own revert condition in the config comments."
            % (row["engine"], row["position"] + 1)
        )
if declaration_detail:
    notes.append(declaration_detail)
if any(row["basis"] == "name" for row in rows):
    notes.append(
        "quota source (name) is a name match against a reported provider id, not a declared "
        "one; (declared) comes from the config's own agent_args_override --provider. Reject a "
        "name-matched row if that engine actually runs another provider's model."
    )
if notes:
    out("\n")
    for note in notes:
        out("- %s\n" % note)

out("\n")
out("recommended: %s\n" % ", ".join(recommended))
out(
    "signals:     quota only. A stalling or wedging engine is a reliability problem this "
    "helper does not read and cannot see; reordering to escape a stall spends a scarce window "
    "on a fault the new window does not fix.\n"
)

# --- opt-in write -----------------------------------------------------------

if not apply_write:
    out("\n")
    out("reporting only. Pass --apply to write the recommended order.\n")
    raise SystemExit(0)

if recommended == current:
    out("\n")
    out("--apply: config already at the recommended order; left untouched.\n")
    raise SystemExit(0)

# Surgical: only lines[idx] changes. Every other byte, including the dated
# decision history in the comments, is carried through unchanged.
lines[idx] = "agent: [%s]" % ", ".join(recommended)
new_text = "\n".join(lines)

# The replace target is the real file, not the path the caller named. A config
# reached through a symlink (a dotfiles checkout linked into place) would
# otherwise have its link replaced by a regular file while the real target kept
# the stale order.
target_path = os.path.realpath(config_path)
directory = os.path.dirname(target_path) or "."
tmp_path = os.path.join(directory, ".fm-pipeline-engine.%d.tmp" % os.getpid())
try:
    with open(tmp_path, "wb") as fh:
        fh.write(new_text.encode("utf-8"))
    os.chmod(tmp_path, os.stat(target_path).st_mode & 0o7777)
    os.replace(tmp_path, target_path)
except OSError as exc:
    if os.path.exists(tmp_path):
        os.unlink(tmp_path)
    die("cannot write %s: %s" % (config_path, exc))

out("\n")
out("--apply: %s:%d is now `%s`.\n" % (config_path, idx + 1, lines[idx]))
out("It takes effect on the next agent invocation. Never restart the no-mistakes daemon.\n")
PY
