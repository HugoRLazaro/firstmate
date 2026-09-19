#!/usr/bin/env bash
# fm-backpass-lane.sh - run backpass as a periodic worker over an isolated copy
# of this home's always-loaded memory, and land its proposal for review.
#
# Usage:
#   fm-backpass-lane.sh [run] [options]
#   fm-backpass-lane.sh --help
#
# What it does, in order:
#   1. refreshes a byte-for-byte isolated copy of the memory surface backpass
#      reads - AGENTS.md, CLAUDE.md when present, and .agents/skills - under the
#      lane root (default state/backpass-lane/memory), never in the live home;
#   2. keeps backpass's own scan cache, evidence, gap ledger, and staging under
#      that same isolated copy, so its evidence accumulates across runs;
#   3. pins one provider for both passes (default pi against the ollama-cloud
#      API key) so a run never competes with the captain's interactive
#      subscriptions;
#   4. resolves one always-loaded budget and passes exactly that value on (see
#      "Budget" below);
#   5. publishes the run's proposal.json and a record of version, budget,
#      provider, source hashes, and the review gate under
#      state/backpass-lane/runs/<stamp>/.
#
# What it never does: it never calls `backpass apply`, never writes a live
# memory file, and never installs anything. Nothing reaches the memory without
# a separate, human decision.
#
# Budget - one value, resolved once, recorded and passed as the same number:
#
#   * an explicit --budget / FM_BACKPASS_BUDGET wins;
#   * otherwise the lane measures backpass's own always-loaded surface
#     (`backpass status --json`: the memory file plus every skill description)
#     and passes the measured surface plus FM_BACKPASS_BUDGET_MARGIN (default
#     1500, the margin the 2026-09-19 evaluation used: 24000 over 22475);
#   * when bin/fm-startup-memory-budget.sh reports the source home's governed
#     allowance and that allowance already covers the measured surface, the lane
#     uses the allowance itself.
#
#   The house startup-memory allowance covers a different surface -
#   data/captain.md, data/captain-shared.md, and data/learnings.md - so the two
#   numbers need not match. When they differ, the run record says so instead of
#   forcing the other surface's number onto this one, which would turn every run
#   into a forced-shrink plan.
#
# Review gate - stated and checked in every run record:
#
#   An accepted proposal is never committed as-is. A proposal that targets a
#   tiered memory file - data/captain.md, data/captain-shared.md, or
#   data/learnings.md - must pass through the /stow skill first so the entry
#   receives its marker and tier before it is committed. This lane's surface is
#   AGENTS.md plus .agents/skills, which carry no /stow markers; for those
#   targets the marker convention does not apply and tracked-material rules do.
#   The run record prints which case the proposal falls in.
#
# Options:
#   --source <home>          home whose memory is copied        [FM_HOME]
#   --root <dir>             isolated lane root      [$STATE/backpass-lane]
#   --budget <tokens>        pin the always-loaded budget
#   --limit <n>              analyze at most N transcripts      [6]
#   --since <dur>            backpass corpus window             [all]
#   --agent <harness>        acpx agent for both passes          [pi]
#   --analysis-model <id>    analysis model  [ollama-cloud/deepseek-v4.1-flash]
#   --synthesis-model <id>   synthesis model [ollama-cloud/kimi-k3]
#   --backpass <path>        backpass executable              [backpass]
#   --acpx <path>            acpx executable whose directory goes first on PATH
#                            for this run (see "Slow acpx" below)
#   -h, --help               print this usage
#
# Slow acpx: backpass verifies a pinned model or effort by running
#   `acpx config show` under a hard ten-second bound. An acpx reached through
#   slow process interop - a Windows npm shim under WSL, for example - can
#   exceed that bound and fail the run with "cannot verify acpx adapter
#   configuration". --acpx / FM_BACKPASS_ACPX_BIN points the run at a faster
#   copy of the same acpx version, which is the supported fix on such a host.
#
# Environment overrides, when the matching option is not passed:
#   FM_BACKPASS_BIN, FM_BACKPASS_SOURCE, FM_BACKPASS_LANE_ROOT,
#   FM_BACKPASS_LIMIT, FM_BACKPASS_SINCE, FM_BACKPASS_AGENT,
#   FM_BACKPASS_ANALYSIS_MODEL, FM_BACKPASS_SYNTHESIS_MODEL,
#   FM_BACKPASS_ANALYSIS_EFFORT, FM_BACKPASS_SYNTHESIS_EFFORT,
#   FM_BACKPASS_BUDGET, FM_BACKPASS_BUDGET_MARGIN, FM_BACKPASS_ACPX_BIN.
#
# Exit status: 0 when the run completes and the live memory is verified
# unchanged, 1 on a setup, provider, or verification failure. A completed run
# with no proposal is still 0: "nothing to propose" is a valid result.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

BACKPASS_BIN="${FM_BACKPASS_BIN:-backpass}"
ACPX_BIN="${FM_BACKPASS_ACPX_BIN:-}"
SOURCE="${FM_BACKPASS_SOURCE:-$FM_HOME}"
LANE_ROOT="${FM_BACKPASS_LANE_ROOT:-$STATE/backpass-lane}"
LIMIT="${FM_BACKPASS_LIMIT:-6}"
SINCE="${FM_BACKPASS_SINCE:-all}"
AGENT="${FM_BACKPASS_AGENT:-pi}"
ANALYSIS_MODEL="${FM_BACKPASS_ANALYSIS_MODEL:-ollama-cloud/deepseek-v4.1-flash}"
SYNTHESIS_MODEL="${FM_BACKPASS_SYNTHESIS_MODEL:-ollama-cloud/kimi-k3}"
ANALYSIS_EFFORT="${FM_BACKPASS_ANALYSIS_EFFORT:-medium}"
SYNTHESIS_EFFORT="${FM_BACKPASS_SYNTHESIS_EFFORT:-high}"
BUDGET_PIN="${FM_BACKPASS_BUDGET:-}"
BUDGET_MARGIN="${FM_BACKPASS_BUDGET_MARGIN:-1500}"

MEM=
RUNS=
XDG_ROOT=
LOCK=
RUN_ID=
RUN_DIR=
RECORD=
PROPOSAL=
BUDGET_EFFECTIVE=
BUDGET_SOURCE=
BUDGET_SURFACE=
BUDGET_HOUSE=absent
SOURCE_ORIGIN=
SOURCE_BEFORE=
SOURCE_MANIFEST_BEFORE=
SOURCE_MANIFEST_AFTER=
SOURCE_PARENT=
CORPUS_TRANSCRIPTS=

die() {
  printf 'fm-backpass-lane: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0"
}

is_uint() {
  case "${1:-}" in
    '' | *[!0-9]*) return 1 ;;
  esac
  return 0
}

require_node() {
  command -v node >/dev/null 2>&1 || die "node is required (backpass is a Node CLI)"
}

resolve_backpass() {
  case "$BACKPASS_BIN" in
    */*)
      [ -x "$BACKPASS_BIN" ] || die "backpass executable not found: $BACKPASS_BIN"
      ;;
    *)
      BACKPASS_BIN=$(command -v "$BACKPASS_BIN" 2>/dev/null) \
        || die "backpass not found on PATH; install it or set FM_BACKPASS_BIN"
      ;;
  esac
}

# Point this run at a specific acpx copy before backpass probes it. backpass
# verifies a pinned model or effort with a hard ten-second `acpx config show`,
# which a slow interop shim can exceed; the recorded path makes that choice
# inspectable rather than silent.
resolve_acpx() {
  [ -n "$ACPX_BIN" ] || return 0
  case "$ACPX_BIN" in
    */*)
      [ -x "$ACPX_BIN" ] || die "acpx executable not found: $ACPX_BIN"
      ;;
    *)
      ACPX_BIN=$(command -v "$ACPX_BIN" 2>/dev/null) \
        || die "acpx not found on PATH: $ACPX_BIN"
      ;;
  esac
  PATH="$(dirname "$ACPX_BIN"):$PATH"
  export PATH
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      run)
        ;;
      --source)
        [ "$#" -ge 2 ] || die "--source needs a value"
        SOURCE=$2
        shift
        ;;
      --root)
        [ "$#" -ge 2 ] || die "--root needs a value"
        LANE_ROOT=$2
        shift
        ;;
      --budget)
        [ "$#" -ge 2 ] || die "--budget needs a value"
        BUDGET_PIN=$2
        shift
        ;;
      --limit)
        [ "$#" -ge 2 ] || die "--limit needs a value"
        LIMIT=$2
        shift
        ;;
      --since)
        [ "$#" -ge 2 ] || die "--since needs a value"
        SINCE=$2
        shift
        ;;
      --agent)
        [ "$#" -ge 2 ] || die "--agent needs a value"
        AGENT=$2
        shift
        ;;
      --analysis-model)
        [ "$#" -ge 2 ] || die "--analysis-model needs a value"
        ANALYSIS_MODEL=$2
        shift
        ;;
      --synthesis-model)
        [ "$#" -ge 2 ] || die "--synthesis-model needs a value"
        SYNTHESIS_MODEL=$2
        shift
        ;;
      --backpass)
        [ "$#" -ge 2 ] || die "--backpass needs a value"
        BACKPASS_BIN=$2
        shift
        ;;
      --acpx)
        [ "$#" -ge 2 ] || die "--acpx needs a value"
        ACPX_BIN=$2
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

validate_args() {
  is_uint "$LIMIT" && [ "$LIMIT" -ge 1 ] || die "--limit must be a positive integer, got: $LIMIT"
  is_uint "$BUDGET_MARGIN" || die "FM_BACKPASS_BUDGET_MARGIN must be a non-negative integer, got: $BUDGET_MARGIN"
  if [ -n "$BUDGET_PIN" ]; then
    is_uint "$BUDGET_PIN" && [ "$BUDGET_PIN" -ge 1 ] || die "--budget must be a positive integer, got: $BUDGET_PIN"
  fi
  [ -n "$SOURCE" ] || die "--source must not be empty"
  [ -n "$LANE_ROOT" ] || die "--root must not be empty"
  [ -f "$SOURCE/AGENTS.md" ] || die "no AGENTS.md under the source home: $SOURCE"
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

# One stable hash over the memory surface the lane copies: every file of
# AGENTS.md, CLAUDE.md, and .agents/skills, with symlinks hashed by their target
# string so a redirected or dangling link still changes the fingerprint.
source_manifest() {
  local file
  if [ -f "$SOURCE/AGENTS.md" ]; then
    printf 'AGENTS.md\tfile:%s\n' "$(sha256_file "$SOURCE/AGENTS.md")"
  fi
  if [ -f "$SOURCE/CLAUDE.md" ]; then
    printf 'CLAUDE.md\tfile:%s\n' "$(sha256_file "$SOURCE/CLAUDE.md")"
  fi
  if [ -d "$SOURCE/.agents/skills" ]; then
    (
      cd "$SOURCE/.agents/skills" || exit 1
      find . -type f -print -o -type l -print | LC_ALL=C sort | while IFS= read -r file; do
        if [ -L "$file" ]; then
          printf '.agents/skills/%s\tlink:%s\n' "${file#./}" "$(readlink "$file")"
        else
          printf '.agents/skills/%s\tfile:%s\n' "${file#./}" "$(sha256_file "./$file")"
        fi
      done
    )
  fi
  return 0
}

prepare_lane_root() {
  MEM="$LANE_ROOT/memory"
  RUNS="$LANE_ROOT/runs"
  XDG_ROOT="$LANE_ROOT/xdg"
  LOCK="$LANE_ROOT/.run-lock"
  case "$MEM" in
    / | "" | "$HOME" | "$SOURCE")
      die "refusing unsafe lane memory path: $MEM"
      ;;
  esac
  [ "${#MEM}" -ge 12 ] || die "refusing unsafe lane memory path: $MEM"
  mkdir -p "$LANE_ROOT" "$RUNS" "$XDG_ROOT" || die "cannot create lane root: $LANE_ROOT"
  mkdir "$LOCK" 2>/dev/null || die "another run holds $LOCK; remove it only if no run is live"
}

prepare_copy() {
  mkdir -p "$MEM" || die "cannot create the isolated copy: $MEM"
  SOURCE_PARENT=$(dirname "$SOURCE")
  SOURCE_ORIGIN=$(git -C "$SOURCE" remote get-url origin 2>/dev/null) \
    || die "the source repo has no origin remote, so the copy cannot associate sessions: $SOURCE"
  if [ ! -d "$MEM/.git" ]; then
    git -C "$MEM" init -q || die "git init failed in the isolated copy: $MEM"
  fi
  git -C "$MEM" remote set-url origin "$SOURCE_ORIGIN" 2>/dev/null \
    || git -C "$MEM" remote add origin "$SOURCE_ORIGIN" \
    || die "cannot bind the origin remote in the isolated copy: $MEM"
  node -e '
const fs = require("node:fs");
const args = process.argv.slice(1);
const config = {
  skillsDir: ".agents/skills",
  discovery: { cloneRoots: [args[0], args[1]] },
};
fs.writeFileSync(args[2], JSON.stringify(config, null, 2) + "\n");
' "$SOURCE" "$SOURCE_PARENT" "$MEM/.backpassrc.json" \
    || die "cannot write the isolated backpass config: $MEM/.backpassrc.json"
  rm -rf "$MEM/.agents" "$MEM/AGENTS.md" "$MEM/CLAUDE.md" \
    || die "cannot refresh the isolated copy: $MEM"
  cp -a "$SOURCE/AGENTS.md" "$MEM/AGENTS.md" || die "cannot copy AGENTS.md into the isolated copy"
  if [ -f "$SOURCE/CLAUDE.md" ]; then
    cp -a "$SOURCE/CLAUDE.md" "$MEM/CLAUDE.md" || die "cannot copy CLAUDE.md into the isolated copy"
  fi
  if [ -d "$SOURCE/.agents/skills" ]; then
    mkdir -p "$MEM/.agents" || die "cannot create the isolated skills directory"
    cp -a "$SOURCE/.agents/skills" "$MEM/.agents/skills" || die "cannot copy .agents/skills into the isolated copy"
  fi
}

# The measured always-loaded surface, straight from backpass: the memory file
# plus every skill description line, with the user config directory isolated
# under the lane root so ambient config can never change the verdict.
measure_surface() {
  local raw
  raw=$(cd "$MEM" && XDG_CONFIG_HOME="$XDG_ROOT" "$BACKPASS_BIN" status --json) \
    || return 1
  printf '%s' "$raw" | node -e '
const chunks = [];
process.stdin.on("data", (chunk) => chunks.push(chunk));
process.stdin.on("end", () => {
  const data = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  const budgets = (data.budgets || []).filter((b) => b.pointerTo === null || b.pointerTo === undefined);
  const withSkills = budgets.find((b) => String(b.label || "").includes("skill descriptions"));
  const pick = withSkills || budgets.reduce((best, b) => (best === null || b.current > best.current ? b : best), null);
  if (pick === null || !Number.isFinite(pick.current)) {
    console.error("fm-backpass-lane: backpass status reported no measurable memory budget");
    process.exit(1);
  }
  process.stdout.write(String(pick.current));
});
'
}

resolve_budget() {
  if [ -n "$BUDGET_PIN" ]; then
    BUDGET_EFFECTIVE=$BUDGET_PIN
    BUDGET_SOURCE=explicit
    return 0
  fi
  BUDGET_SURFACE=$(measure_surface) \
    || die "cannot measure the always-loaded surface with 'backpass status --json'; pass --budget to skip the measurement"
  if [ -x "$SCRIPT_DIR/fm-startup-memory-budget.sh" ]; then
    BUDGET_HOUSE=$(FM_HOME="$SOURCE" "$SCRIPT_DIR/fm-startup-memory-budget.sh" read 2>/dev/null) \
      || BUDGET_HOUSE=absent
  fi
  if [ "$BUDGET_HOUSE" != absent ] && [ "$BUDGET_HOUSE" -ge "$BUDGET_SURFACE" ]; then
    BUDGET_EFFECTIVE=$BUDGET_HOUSE
    BUDGET_SOURCE=house-startup-memory-budget
  else
    BUDGET_EFFECTIVE=$((BUDGET_SURFACE + BUDGET_MARGIN))
    BUDGET_SOURCE=measured-surface-plus-margin
  fi
}

scan_corpus() {
  local scan_out=$1
  (cd "$MEM" && XDG_CONFIG_HOME="$XDG_ROOT" "$BACKPASS_BIN" scan --json --since "$SINCE" --strict) > "$scan_out" 2> "$RUN_DIR/scan.log" \
    || return 1
  CORPUS_TRANSCRIPTS=$(node -e '
const fs = require("node:fs");
const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
process.stdout.write(String((data.transcripts || []).length));
' "$scan_out") || return 1
}

run_pass() {
  (cd "$MEM" && XDG_CONFIG_HOME="$XDG_ROOT" "$BACKPASS_BIN" \
    --since "$SINCE" --limit "$LIMIT" --strict \
    --budget "$BUDGET_EFFECTIVE" \
    --analysis-agent "$AGENT" --analysis-model "$ANALYSIS_MODEL" --analysis-effort "$ANALYSIS_EFFORT" \
    --synthesis-agent "$AGENT" --synthesis-model "$SYNTHESIS_MODEL" --synthesis-effort "$SYNTHESIS_EFFORT" \
    --json) > "$RUN_DIR/run.json" 2> "$RUN_DIR/run.log"
}

# The proposal's own capTokens must equal the value the lane resolved and
# passed, so the recorded budget and backpass's budget provably coincide.
proposal_cap_tokens() {
  node -e '
const fs = require("node:fs");
const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const cap = data.budget && data.budget.capTokens;
process.stdout.write(Number.isFinite(cap) ? String(cap) : "unknown");
' "$1"
}

proposal_targets() {
  node -e '
const fs = require("node:fs");
const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const files = new Set();
for (const target of data.targetFiles || []) {
  if (target && target.file) files.add(String(target.file));
}
for (const edit of data.edits || []) {
  if (edit && edit.file) files.add(String(edit.file));
  for (const skill of (edit && edit.skills) || []) {
    if (skill && skill.path) files.add(String(skill.path));
  }
}
for (const file of Array.from(files).sort()) console.log(file);
' "$1"
}

proposal_details() {
  node -e '
const fs = require("node:fs");
const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const edits = data.edits || [];
const budget = data.budget || {};
const stats = data.stats || {};
console.log("proposal_edits=" + edits.length);
if (Number.isFinite(budget.delta)) console.log("proposal_delta_tokens=" + (budget.delta >= 0 ? "+" : "") + budget.delta);
if (Number.isFinite(stats.transcripts)) console.log("proposal_analyzed_transcripts=" + stats.transcripts);
for (const edit of edits) {
  const delta = Number.isFinite(edit.deltaTokens) ? (edit.deltaTokens >= 0 ? "+" : "") + edit.deltaTokens : "?";
  const title = String(edit.title || "").replace(/\s+/g, " ");
  console.log("edit=" + (edit.id || "?") + " file=" + (edit.file || "?") + " kind=" + (edit.kind || "?") + " delta=" + delta + " title=" + title);
  for (const skill of edit.skills || []) {
    if (skill && skill.path) console.log("skill=" + skill.path + " name=" + (skill.name || "?"));
  }
}
for (const verdict of data.verdicts || []) {
  console.log("verdict=" + verdict.instruction + " " + verdict.verdict + " positive=" + verdict.positive + " negative=" + verdict.negative);
}
' "$1"
}

stow_check() {
  local target tiered=no
  STOW_TARGETS=
  if [ -n "$PROPOSAL" ] && [ -f "$PROPOSAL" ]; then
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      STOW_TARGETS="${STOW_TARGETS}${STOW_TARGETS:+ }$target"
      case "$target" in
        data/captain.md | data/captain-shared.md | data/learnings.md)
          tiered=yes
          ;;
      esac
    done < <(proposal_targets "$PROPOSAL")
  fi
  if [ "$tiered" = yes ]; then
    STOW_APPLIES=yes
    STOW_CHECK="this proposal targets a tiered memory file, so run /stow for its marker and tier before committing it"
  else
    STOW_APPLIES=no
    STOW_CHECK="proposal targets carry no /stow markers (tracked shared material, not tiered memory files), so the marker and tier convention does not apply; normal tracked-material review does"
  fi
}

publish_run() {
  PROPOSAL=
  if [ -f "$MEM/.backpass/proposal.json" ]; then
    PROPOSAL="$RUN_DIR/proposal.json"
    cp -a "$MEM/.backpass/proposal.json" "$PROPOSAL" || die "cannot publish the proposal"
  fi
  cp -a "$MEM/.backpass/gap-ledger.json" "$RUN_DIR/gap-ledger.json" 2>/dev/null || true
  cp -a "$MEM/.backpass/evidence-summary.json" "$RUN_DIR/evidence-summary.json" 2>/dev/null || true
}

write_record() {
  local run_rc=$1 backpass_version=$2 budget_cap=unknown
  {
    printf 'lane_run=%s\n' "$RUN_ID"
    printf 'lane_root=%s\n' "$LANE_ROOT"
    printf 'source=%s\n' "$SOURCE"
    printf 'memory_copy=%s\n' "$MEM"
    printf 'backpass_bin=%s\n' "$BACKPASS_BIN"
    printf 'backpass_version=%s\n' "$backpass_version"
    printf 'backpass_run_rc=%s\n' "$run_rc"
    printf 'corpus_transcripts=%s\n' "${CORPUS_TRANSCRIPTS:-0}"
    printf 'source_manifest_before=%s\n' "$SOURCE_MANIFEST_BEFORE"
    printf 'source_manifest_after=%s\n' "$SOURCE_MANIFEST_AFTER"
    printf 'live_memory_unchanged=%s\n' "$LIVE_MEMORY_UNCHANGED"
    printf 'source_git_status_unchanged=%s\n' "$SOURCE_GIT_STATUS_UNCHANGED"
    printf 'harness_store_sessions_before=%s\n' "$HARNESS_STORE_BEFORE"
    printf 'harness_store_sessions_after=%s\n' "$HARNESS_STORE_AFTER"
    printf 'budget_effective=%s\n' "$BUDGET_EFFECTIVE"
    printf 'budget_source=%s\n' "$BUDGET_SOURCE"
    printf 'budget_measured_surface=%s\n' "${BUDGET_SURFACE:-unknown}"
    printf 'budget_margin=%s\n' "$BUDGET_MARGIN"
    printf 'budget_house_startup_memory=%s\n' "$BUDGET_HOUSE"
    printf 'budget_house_source=bin/fm-startup-memory-budget.sh read (data/captain.md + data/captain-shared.md + data/learnings.md)\n'
    if [ "$BUDGET_HOUSE" = absent ]; then
      printf 'budget_match=uncompared (house allowance absent)\n'
    elif [ "$BUDGET_HOUSE" = "$BUDGET_EFFECTIVE" ]; then
      printf 'budget_match=yes\n'
    else
      printf 'budget_match=no (different surfaces: house %s over the tiered data files, lane %s over AGENTS.md + skill descriptions)\n' \
        "$BUDGET_HOUSE" "$BUDGET_EFFECTIVE"
    fi
    if [ -n "$PROPOSAL" ] && [ -f "$PROPOSAL" ]; then
      budget_cap=$(proposal_cap_tokens "$PROPOSAL")
      if [ "$budget_cap" = "$BUDGET_EFFECTIVE" ]; then
        printf 'budget_match_backpass=yes\n'
      else
        printf 'budget_match_backpass=no (proposal capTokens %s)\n' "$budget_cap"
      fi
    else
      printf 'budget_match_backpass=unverified (no proposal)\n'
    fi
    printf 'provider_agent=%s\n' "$AGENT"
    printf 'provider_analysis_model=%s\n' "$ANALYSIS_MODEL"
    printf 'provider_synthesis_model=%s\n' "$SYNTHESIS_MODEL"
    printf 'provider_note=dedicated API-key provider (%s), separate from the captain interactive subscriptions (openai-codex OAuth and Claude session limits)\n' \
      "${ANALYSIS_MODEL%%/*}"
    printf 'acpx_bin=%s\n' "${ACPX_BIN:-PATH default}"
    printf 'apply_invoked=never\n'
    printf 'external_writes=backpass model calls append self-excluded sessions to the harness session store; no live memory file is written\n'
    if [ -n "$PROPOSAL" ] && [ -f "$PROPOSAL" ]; then
      printf 'proposal=%s\n' "$PROPOSAL"
      proposal_details "$PROPOSAL"
    else
      printf 'proposal=absent (backpass proposed nothing this run)\n'
    fi
    printf 'review_gate=an accepted proposal is never committed as-is; a target under data/ that carries /stow markers must pass through the stow skill for its marker and tier first\n'
    printf 'stow_tiered_files=data/captain.md data/captain-shared.md data/learnings.md\n'
    printf 'proposal_targets=%s\n' "${STOW_TARGETS:-none}"
    printf 'stow_marker_convention_applies=%s\n' "$STOW_APPLIES"
    printf 'stow_check=%s\n' "$STOW_CHECK"
  } >> "$RUN_DIR/record.txt"
}

main() {
  parse_args "$@"
  validate_args
  require_node
  resolve_backpass
  resolve_acpx
  prepare_lane_root
  trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT HUP INT TERM
  prepare_copy
  RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
  RUN_DIR="$RUNS/$RUN_ID"
  RECORD="$RUN_DIR/record.txt"
  mkdir -p "$RUN_DIR" || die "cannot create the run directory: $RUN_DIR"
  : > "$RECORD"
  SOURCE_BEFORE=$(source_manifest)
  printf '%s\n' "$SOURCE_BEFORE" > "$RUN_DIR/source.before.manifest"
  SOURCE_GIT_STATUS_BEFORE=$(git -C "$SOURCE" status --porcelain 2>/dev/null | sha256_stdin)
  HARNESS_STORE_BEFORE=$(harness_store_sessions)
  local backpass_version
  backpass_version=$("$BACKPASS_BIN" -v 2>/dev/null | head -n 1) || backpass_version=unknown
  [ -n "$backpass_version" ] || backpass_version=unknown
  resolve_budget
  printf 'backpass-lane: backpass %s\n' "$backpass_version"
  printf 'backpass-lane: budget %s (%s)\n' "$BUDGET_EFFECTIVE" "$BUDGET_SOURCE"
  printf 'backpass-lane: provider %s analysis=%s synthesis=%s\n' "$AGENT" "$ANALYSIS_MODEL" "$SYNTHESIS_MODEL"
  if ! scan_corpus "$RUN_DIR/scan.json"; then
    die "backpass scan failed; see $RUN_DIR/scan.log"
  fi
  printf 'backpass-lane: corpus %s transcript(s) associated\n' "$CORPUS_TRANSCRIPTS"
  local run_rc=0
  if [ "$CORPUS_TRANSCRIPTS" -eq 0 ]; then
    : > "$RUN_DIR/run.json"
    : > "$RUN_DIR/run.log"
  else
    run_pass || run_rc=$?
  fi
  SOURCE_AFTER=$(source_manifest)
  printf '%s\n' "$SOURCE_AFTER" > "$RUN_DIR/source.after.manifest"
  SOURCE_MANIFEST_BEFORE=$(printf '%s\n' "$SOURCE_BEFORE" | sha256_stdin)
  SOURCE_MANIFEST_AFTER=$(printf '%s\n' "$SOURCE_AFTER" | sha256_stdin)
  if [ "$SOURCE_BEFORE" = "$SOURCE_AFTER" ]; then
    LIVE_MEMORY_UNCHANGED=yes
  else
    LIVE_MEMORY_UNCHANGED=no
  fi
  SOURCE_GIT_STATUS_AFTER=$(git -C "$SOURCE" status --porcelain 2>/dev/null | sha256_stdin)
  if [ "$SOURCE_GIT_STATUS_BEFORE" = "$SOURCE_GIT_STATUS_AFTER" ]; then
    SOURCE_GIT_STATUS_UNCHANGED=yes
  else
    SOURCE_GIT_STATUS_UNCHANGED=no
  fi
  HARNESS_STORE_AFTER=$(harness_store_sessions)
  if [ "$CORPUS_TRANSCRIPTS" -eq 0 ]; then
    PROPOSAL=
    rm -f "$MEM/.backpass/proposal.json" 2>/dev/null || true
  else
    publish_run
  fi
  stow_check
  write_record "$run_rc" "$backpass_version"
  ln -sfn "$RUN_DIR" "$LANE_ROOT/latest" 2>/dev/null || true
  printf 'backpass-lane: run %s\n' "$RUN_DIR"
  if [ "$PROPOSAL" != "" ]; then
    printf 'backpass-lane: proposal %s (%s edit(s), cap %s)\n' "$PROPOSAL" "$(proposal_edits_count "$PROPOSAL")" "$(proposal_cap_tokens "$PROPOSAL")"
  else
    printf 'backpass-lane: proposal absent\n'
  fi
  printf 'backpass-lane: live memory unchanged=%s\n' "$LIVE_MEMORY_UNCHANGED"
  if [ "$run_rc" -ne 0 ] && grep -q "cannot verify acpx adapter configuration" "$RUN_DIR/run.log" 2>/dev/null; then
    printf 'backpass-lane: hint: acpx on PATH is too slow for backpass verification; pass --acpx <path> with a faster copy\n' >&2
  fi
  [ "$run_rc" -eq 0 ] || die "backpass run failed with status $run_rc; see $RUN_DIR/run.log"
  [ "$LIVE_MEMORY_UNCHANGED" = yes ] || die "the live memory changed during the run; inspect $RUN_DIR/source.before.manifest and $RUN_DIR/source.after.manifest"
  [ "$SOURCE_GIT_STATUS_UNCHANGED" = yes ] || die "the live source checkout status changed during the run"
  return 0
}

harness_store_sessions() {
  local store
  store="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/sessions"
  if [ ! -d "$store" ]; then
    printf 'absent'
    return 0
  fi
  find "$store" -type f 2>/dev/null | wc -l | tr -d ' '
}

proposal_edits_count() {
  node -e '
const fs = require("node:fs");
const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
process.stdout.write(String((data.edits || []).length));
' "$1"
}

main "$@"
