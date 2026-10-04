#!/usr/bin/env bash
# fm-session-start.sh - one command for the whole session start.
#
# Collapses AGENTS.md sections 3 (bootstrap) and 5 (recovery) into ONE script
# producing ONE ordered digest, so a session starts in one or two turns
# instead of the six-plus separate reads the old docs required: run
# fm-bootstrap.sh, then separately read data/projects.md, data/secondmates.md,
# data/captain.md, data/captain-shared.md, data/learnings.md, then run
# fm-lock.sh, fm-wake-drain.sh, then read data/backlog.md, every state/*.meta,
# and every state/*.status.
# Every one of those reads is UNCONDITIONAL at every session start, so they
# belong in a script, not in N agent turns.
#
# COMPOSITION, NOT DUPLICATION: this script calls fm-lock.sh, fm-bootstrap.sh,
# fm-wake-drain.sh, and fm-startup-network.sh as real subprocesses and prints
# their real output. It never re-implements their logic; all
# sequencing/formatting logic added here stays local to this file. Those four
# scripts remain fully working
# standalone with unchanged default behavior - other flows (fm-bootstrap.sh
# install <tools> after consent, /updatefirstmate, the afk daemon, existing
# tests) still call them directly. The one seam this script needed -
# bootstrap running its detect-only diagnostics without its six mutating
# sweeps - is an opt-in FM_BOOTSTRAP_DETECT_ONLY=1 flag on fm-bootstrap.sh
# itself (default unset/0 = unchanged behavior), not a fork.
#
# ORDERING, and why LOCK now runs before BOOTSTRAP (the old AGENTS.md order
# was bootstrap-then-lock):
#
#   1. lock          - acquire the per-home session lock FIRST, before any
#                       mutating step runs.
#   2. bootstrap      - home-local stale Herdr projection cleanup runs only
#                       when this session actually holds the lock. Detect-only
#                       diagnostics always run. Bootstrap's six MUTATING sweeps
#                       (same-home backlog reconciliation,
#                       secondmate convergence, secondmate liveness, pending remote
#                       handoff retry, X-mode artifact writes, fleet sync) also run only when
#                       locked; the four network sweeps run in the deferred
#                       stage rather than this synchronous bootstrap section.
#   3. wake-drain     - presents durable wakes and advances recovery handling
#                       state, so it only runs when locked. The local bounded
#                       inactive-outcome startup scan runs in the deferred worker.
#   4. supervision-instructions - the one emitted operating block for the
#                       detected primary harness.
#   5. read-once contract - the do-not-re-read contract covering every source
#                       represented by the two digests below.
#   6. fleet digest   - a compact data/backlog.md identity/metadata listing,
#                       every state/*.meta, a bounded state/*.status tail,
#                       the away posture (state/.afk-contract and the legacy
#                       state/.afk daemon flag), and a cheap per-task
#                       endpoint-liveness read:
#                       read-only, always runs.
#   7. network checks - the result of the deferred network stage started back at
#                       step 1, harvested WITHOUT waiting for it.
#   8. context digest - data/projects.md, data/secondmates.md, data/captain.md,
#                       data/captain-shared.md, data/learnings.md: read-only,
#                       always safe, always runs.
#   9. closing reminder - prints the context-specific watcher next step; this
#                       script points back to the emitted harness supervision
#                       block and deliberately never arms the watcher itself.
#
# Those nine names are also the runtime-bound stage list below, so a truncated
# startup can name exactly which of them never ran.
#
# NO NETWORK ON THE BLOCKING PATH. This digest runs on a session-open hook that
# blocks session initialization, so anything it waits for is time the captain
# waits before the first turn - and every external-network call it used to make
# was individually unbounded. One unreachable remote secondmate could burn the
# entire FM_SESSION_START_TIMEOUT and truncate the digest, so a slow network
# could cost the work queue itself.
# So no step between here and the last line below makes an external-network
# call. The five that did - `gh auth status`, secondmate liveness, secondmate
# convergence, pending remote handoff delivery, and the fleet-sync fetch - are
# started as one detached bounded worker right after the lock (step 1) and
# harvested at step 7 without ever blocking on it. The bounded inactive-outcome
# startup scan joins that worker because its local current-state reads can also
# be slow. bin/fm-startup-network.sh owns that stage and its safety argument;
# bin/fm-bootstrap.sh and bin/fm-inactive-reconcile.sh remain the owners of the
# work itself and still run it.
# The digest is therefore composed from bounded local reads and local
# subprocesses only, while slow network or inactive-state reconciliation delays
# a reported check rather than startup.
# What this deliberately trades: on a slow network the digest prints "IN
# PROGRESS" and names exactly which checks are not yet confirmed, instead of
# waiting for them. It never reports an unconfirmed check as passed.
#
# ORDERING, and why FLEET STATE now runs before CONTEXT: this digest is
# delivered through a harness that truncates an oversized payload from the TAIL,
# and it has really been truncated in practice - a 70KB digest arrived as lines
# 1-435 of 578, cutting off eight lines before the live-task inventory. What a
# truncated tail drops must therefore be the CHEAPEST thing to lose. Curated
# memory is stable session to session, is already governed by a captain-set
# budget (config/startup-memory-budget), and is recoverable with one targeted
# read; live fleet identity - which tasks exist, their windows, worktrees,
# backends, and endpoint liveness - changes every session and is exactly what
# recovery depends on. So fleet state goes first and the memory files absorb the
# truncation. The read-once contract moves ahead of both for the same reason: a
# contract that only arrives after the payload it governs is the first thing a
# truncated digest loses, and it carries the truncation caveat that keeps it
# honest when a stage below it never ran.
# The LOCK/BOOTSTRAP/WAKE-QUEUE safety preamble keeps its order: it establishes
# mutation authority and this turn's work queue before anything else is read.
#
# On a Pi primary, the supervision-block step also checks whether Pi's two
# tracked primary extensions are loaded and prints a PI_WATCH_EXTENSION
# reminder line when one is missing.
#
# Why lock first: the old documented order (bootstrap, THEN lock) let a
# SECOND concurrent session run bootstrap's mutating sweeps - converging
# secondmate homes, retrying pending handoff outboxes and receiver wakes, writing
# X-mode artifacts, and fetching or fast-forwarding every project clone - before
# ever discovering another session already holds the lock. Two sessions racing
# those sweeps is exactly the hazard the lock exists to prevent, so locking first closes the
# hole outright: only the session that actually wins the lock ever touches
# shared mutable state.
#
# The tradeoff this ordering accepts: a refused (read-only) session must not
# go dark. So on refusal, bootstrap still runs (in FM_BOOTSTRAP_DETECT_ONLY=1
# mode) for its local read-only detect lines - missing tools, the worktree-tangle
# check, the harness override, crew-dispatch validation, tasks-axi and quota-axi
# tool checks, and tasks-axi availability - none of which mutate shared state
# and all of which are safe to compute without verified lock ownership.
# It deliberately skips the network-only GitHub-auth probe because a read-only
# session has no dispatch, spawn, steer, or merge action for that verdict to gate.
# Only projection cleanup, the six bootstrap mutating sweeps, and wake-queue
# presentation are skipped.
# The context and fleet-state digests
# below are always read-only, so they run unconditionally in both modes.
#
# BACKLOG DIGEST: the startup listing is a RECOVERY input, not a reporting
# surface, so it carries what this turn can act on and nothing else.
#   - `done` rows are never listed. Retained completion history belongs to the
#     reporting surfaces (bin/fm-bearings-snapshot.sh, /ahoy), and at startup it
#     is pure weight - 10 done rows cost 3.3KB in an observed main-home digest.
#   - Every in-flight, held, and blocked row is listed IN FULL, with its
#     hold_kind/hold_reason and blocked_by. Those are the rows AGENTS.md
#     sections 7 and 10 make actionable at startup, so they are never bounded
#     away.
#   - Only the plain queued (dispatchable-now) listing is bounded, by
#     FM_SESSION_START_QUEUED_LIMIT, default 20. Anything it omits is disclosed
#     with an exact remainder count and the command that shows the rest, so a
#     deep queue costs a counter rather than kilobytes.
#     (This replaces FM_SESSION_START_BACKLOG_LIMIT, which bounded the whole
#     listing indiscriminately and so could drop a held or blocked row.)
# When compatible tasks-axi is selected and available, the shared tasks-axi
# backend probe remains the compatibility owner and this script asks
# `tasks-axi list` for the compact identity fields plus blocked_by, hold_kind,
# and hold_reason, never body. The groups are the tool's own filters
# (`--state in_flight`, `--state held`, `--state queued --blocked`, and
# `tasks-axi ready`), so this script never reimplements task state; the groups
# can overlap, because an in-flight item that is also held appears under both.
# When manual mode is selected, or tasks-axi is unavailable or incompatible,
# this script prints only backlog section headings and item title lines, so
# title-line hold and blocked-by metadata remain visible while indented bodies
# stay out of the startup digest; the same never-bound-a-held-or-blocked-row
# rule applies, recognized there from the title line's own hold/blocked-by
# markers.
# Full bodies are targeted follow-up only: `bin/fm-tasks-axi.sh show <id> --full` when
# compatible tasks-axi is available, or `data/backlog.md` when the file body is
# truly needed.
#
# STATUS TAILS: FM_SESSION_START_STATUS_TAIL bounds how many lines each task's
# tail prints, and bin/fm-line-cap-lib.sh bounds how long each of those lines
# may be. Both bounds are safe because the section prints every task's full
# status log path, and AGENTS.md section 8 treats a status line as a wake EVENT
# rather than current state - bin/fm-crew-state.sh owns current state.
#
# RUNTIME BOUND: the digest is now executed through a native session-open
# adapter (see bin/fm-sessionstart-run.sh), which blocks either hook-driven
# session initialization or Pi's first provider preflight while it runs, so an
# unbounded digest is no longer merely slow - it can strand a whole session or
# first turn behind one hung subprocess. Every remaining step is local, but
# local is not the same as bounded: tool version probes, the backlog listing,
# and the per-task endpoint reads are all unbounded subprocesses. So the whole
# digest still runs as ONE bounded child of this script
# (FM_SESSION_START_TIMEOUT, default 120s). The deferred network stage
# deliberately sits OUTSIDE that bound,
# in its own process group under its own aggregate deadline, so a truncated
# digest neither waits for it nor orphans it unbounded. The
# child writes the digest straight to this script's stdout, so everything it
# emitted before the bound was hit is already delivered; the parent then prints
# a loud STARTUP TRUNCATED banner naming the stage that did not finish and the
# sections that were therefore never emitted, and still exits 0. The child
# records its progress in FM_SESSION_START_STAGE_FILE, which is also the flag
# that tells a child it is the child - the parent never recurses.
# Hosts without timeout, gtimeout, or perl use the shared pure-Bash watchdog, so
# the digest never runs without the same hard bound and process-group cleanup.
#
# Usage: fm-session-start.sh [--reemit] [--source <source>]
#   Prints the full ordered digest to stdout and always exits 0: this is a
#   reporting command, not a gate. A lock refusal is reported as a loud
#   banner inline, never a silent failure or a non-zero exit that would make
#   an agent skip the rest of the digest.
#
#   --reemit  This process ALREADY took the helm at its own startup and has
#             only lost its context (a /clear or a compaction). Skip the
#             mutating sweeps that startup already reconciled - the stale Herdr
#             projection cleanup and bootstrap's six mutating sweeps (fleet
#             sync, same-home backlog reconciliation, secondmate convergence and
#             liveness, pending remote handoff retry, X-mode
#             artifact writes) - and
#             re-emit the rest. Wake-queue presentation is NOT skipped: queued
#             records are this turn's work queue, they arrived after startup,
#             and a session that owns the lock is exactly the session that must
#             handle and acknowledge them. Lock acquisition still runs, because
#             ownership must be re-verified rather than assumed: fm-lock.sh
#             already treats a lock owned through shared ancestry or a trusted
#             same-session Claude id as its own, so the re-emit proceeds, while
#             a lock another live session took meanwhile still produces the
#             ordinary read-only path.
#
#             BOUNDED RE-EMIT. What a re-emit prints depends on what the
#             session lost, which `--source` names:
#               compact  the BOUNDED re-emit. A compaction keeps a summary of
#                        what the session knew, so reprinting the two bulk
#                        digests returns to context exactly the weight the
#                        compaction just removed, and a digest larger than the
#                        room a compaction frees turns into a compaction loop:
#                        one observed main-home re-emit measured 306KB. So this
#                        path prints the lock verification, the detect-only
#                        bootstrap lines, the wake queue, the supervision
#                        operating instructions, the away posture and public
#                        commitments, the network checks, and the closing
#                        reminder. FLEET STATE (backlog listing, state/*.meta,
#                        status tails, orphan status logs) and CONTEXT (the five
#                        data/ files) are NOT reprinted: a RE-EMIT SCOPE section
#                        names them, forbids rebuilding them in bulk, and says
#                        how to read one source when the work needs it, and
#                        each data/ file's presence is still listed because
#                        absence is meaningful.
#               clear, or no source
#                        the full reprint. A clear leaves no summary behind, so
#                        the session has nothing to rebuild the digests from and
#                        every section prints exactly as at a true start.
#             The bounded re-emit also has a HARD byte budget, so nothing added
#             to it later can grow back into the loop:
#             FM_SESSION_START_REEMIT_BUDGET, default 24576 bytes, with any
#             value under 8192 raised to that floor because a budget that
#             cannot hold the fixed text is not a budget. The fixed text is
#             always printed and counted. Each variable section (bootstrap, the
#             supervision block, public commitments, network checks) prints only
#             when it fits with 4096 bytes still reserved for the fixed text
#             that follows it; a section that does not fit is replaced, where it
#             would have printed, by a RE-EMIT BUDGET line naming it, its size,
#             and the command that reads it, and NEXT STEP names every omitted
#             section again. Two payloads are deliberately OUTSIDE the budget,
#             because cutting either loses something no pointer can recover:
#             the wake-queue presentation, whose drain has already advanced the
#             presentation cursor, and the AGENTS.md instruction refresh below.
#             The refresh is nevertheless bounded: a per-session durable marker
#             records the (session identity, content hash) pair it already
#             re-emitted, so the file is delivered complete at most once per
#             session per content and a later compaction with the same bytes
#             prints one withheld line instead.
#             NEXT STEP closes with a RE-EMIT SIZE line accounting for the
#             budgeted bytes and for both of those payloads.
#
#   --source  The native session-open source, supplied only by
#             fm-sessionstart-run.sh. A genuine `startup` that owns the active
#             session lock records AGENTS.md's SHA-256 baseline only after the
#             digest completion record is published, keyed to that lock's
#             harness pid. No resume, clear, reset, compact, or other rebuild
#             creates or replaces it. Pi and pi-signed compaction are the only
#             supported stale-cache rebuild pair: a changed hash against this
#             session's own baseline causes the complete current AGENTS.md to
#             print before the bulky digest; an equal baseline emits no refresh.
#             The baseline remains immutable, so a drift keeps returning; a
#             second durable marker (state/.session-start-agents-refresh.<id>,
#             one per harness session identity, with the lock-owning pid as the
#             identity when none arrives) keyed to that identity and the content
#             hash records the bytes already re-emitted, so the complete refresh
#             is delivered once per session per content and later compactions
#             of that session with the same bytes print one withheld line naming
#             the AGENTS.md path instead. The Pi extension passes that identity
#             in FM_SESSIONSTART_SESSION_ID and discards the session's marker
#             when it stops a generation whose result it never delivered.
#             Markers and baselines are separate: a refresh never rewrites the
#             true-start baseline, and a marker is consulted only when this
#             session holds the lock and it names this session, so a marker
#             from another session can never suppress a refresh.
#             A session with no baseline of its own - none recorded, or one
#             recorded for another harness pid, which is what a resumed or
#             manually started session has - is judged by a freshness proof
#             instead of refreshing unconditionally: a harness loads its native
#             instruction copy no earlier than its own process start, so an
#             AGENTS.md whose bytes and inode last changed more than 3 seconds
#             before that start is necessarily the copy the session already
#             runs on, and no refresh is emitted. The change time is the later
#             of the file's mtime and ctime, so a backdated mtime cannot hide an
#             edit. The start is the EARLIER of two readings. The first is the
#             wall clock minus POSIX `ps -o etime`, read after the wall clock,
#             so it is structurally early and can only understate the true
#             start, never overstate it. The second is the mtime of the
#             state/.lock this same pid wrote when it took the helm - a stamp
#             necessarily later than the process start, and what bounds a host
#             whose elapsed clock stops while its wall clock moves on - a
#             paused VM, which WSL2 is across a host sleep - where the first
#             reading drifts later by the length of every pause. Taking the
#             earlier of the two therefore keeps the estimate at or before the
#             process start in the normal case; the one real gap is
#             lock-acquisition latency, where a stalled elapsed clock pushes
#             the first reading past the stamp and the estimate lands on the
#             helm instead of the process start. A change made in that gap -
#             after the process started but before it took the helm - can be
#             read as unchanged; the 3-second margin absorbs etime truncation,
#             not a stall. The proof records nothing and is repeated on every
#             compaction. Any step that cannot be read - no harness pid, a lock
#             this pid does not own, an unreadable or malformed etime, a failed
#             stat, a symlinked AGENTS.md - refreshes exactly as before, and so
#             does a file changed after the start. A true `startup` baseline,
#             which compares bytes, has no such gap.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
COMPLETION_FILE="$STATE/.session-start-complete"
AGENTS_BASELINE_FILE="$STATE/.session-start-agents-baseline"
AGENTS_REFRESH_MARKER_PREFIX="$STATE/.session-start-agents-refresh"

REEMIT=0
SESSION_SOURCE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reemit)
      REEMIT=1
      shift
      ;;
    --source)
      SESSION_SOURCE=${2:-}
      if [ "$#" -ge 2 ]; then shift 2; else shift; fi
      ;;
    --source=*)
      SESSION_SOURCE=${1#--source=}
      shift
      ;;
    -h|--help)
      sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-session-start.sh" | sed 's/^# \{0,1\}//; $d'
      exit 0
      ;;
    *)
      printf 'fm-session-start: unknown argument: %s\n' "$1" >&2
      printf 'usage: fm-session-start.sh [--reemit] [--source <source>]\n' >&2
      exit 2
      ;;
  esac
done

# --- 0. runtime bound ---------------------------------------------------------
# The ordered stage list is the contract behind the truncation banner: the child
# names the stage it is entering, and the parent reports every stage at or after
# that one as never emitted. Keep it in the exact order the digest prints.
SESSION_START_STAGES='lock bootstrap wake-queue supervision-instructions read-once fleet-state network-checks context next-step'

stage() {  # <stage-name>: breadcrumb for the parent's truncation banner
  [ -n "${FM_SESSION_START_STAGE_FILE:-}" ] || return 0
  printf '%s\n' "$1" > "$FM_SESSION_START_STAGE_FILE" 2>/dev/null || true
}

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

if [ -z "${FM_SESSION_START_STAGE_FILE:-}" ]; then
  SESSION_START_BUDGET=${FM_SESSION_START_TIMEOUT:-120}
  # A non-positive or non-numeric budget is not a budget (`timeout 0` disables
  # the deadline outright), so an unusable value falls back to the default
  # rather than silently removing the bound.
  case "$SESSION_START_BUDGET" in ''|*[!0-9]*|0) SESSION_START_BUDGET=120 ;; esac
  SESSION_START_STAGE_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-session-start-stage.XXXXXX" 2>/dev/null) || SESSION_START_STAGE_FILE=
  if [ -z "$SESSION_START_STAGE_FILE" ]; then
    # Without a breadcrumb the bound still holds; only the banner's precision
    # is lost, so the child still runs bounded.
    SESSION_START_STAGE_FILE=/dev/null
  fi
  if [ "$REEMIT" -eq 1 ]; then
    if [ -n "$SESSION_SOURCE" ]; then
      fm_run_timed "$SESSION_START_BUDGET" \
        env FM_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
        "$SCRIPT_DIR/fm-session-start.sh" --reemit --source "$SESSION_SOURCE"
    else
      fm_run_timed "$SESSION_START_BUDGET" \
        env FM_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
        "$SCRIPT_DIR/fm-session-start.sh" --reemit
    fi
  elif [ -n "$SESSION_SOURCE" ]; then
    fm_run_timed "$SESSION_START_BUDGET" \
      env FM_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
      "$SCRIPT_DIR/fm-session-start.sh" --source "$SESSION_SOURCE"
  else
    fm_run_timed "$SESSION_START_BUDGET" \
      env FM_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
      "$SCRIPT_DIR/fm-session-start.sh"
  fi
  SESSION_START_RC=$?
  if [ "$SESSION_START_RC" -eq 124 ]; then
    SESSION_START_LAST_STAGE=$(cat "$SESSION_START_STAGE_FILE" 2>/dev/null) || SESSION_START_LAST_STAGE=
    [ -n "$SESSION_START_LAST_STAGE" ] || SESSION_START_LAST_STAGE=unknown
    SESSION_START_PENDING=$(
      printf '%s\n' "$SESSION_START_STAGES" | tr ' ' '\n' |
        awk -v from="$SESSION_START_LAST_STAGE" '$0 == from {seen = 1} seen' | tr '\n' ' '
    )
    [ -n "${SESSION_START_PENDING# }" ] || SESSION_START_PENDING='(unknown - the digest may be incomplete anywhere)'
    BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    printf '\n%s\n' "$BAR"
    printf '●  STARTUP TRUNCATED - SESSION START HIT ITS %ss RUNTIME BOUND\n' "$SESSION_START_BUDGET"
    printf '●  It stopped during the "%s" stage, so everything above is COMPLETE\n' "$SESSION_START_LAST_STAGE"
    printf '●  only up to that point.\n'
    printf '●  RECONCILE these stages before acting on anything they would have shown:\n'
    printf '●    %s\n' "${SESSION_START_PENDING% }"
    printf '●  Rerun bin/fm-session-start.sh now to finish taking the helm. If it truncates\n'
    printf '●  again, raise FM_SESSION_START_TIMEOUT and report the slow stage - a stage that\n'
    printf '●  cannot finish inside the bound is a fleet problem, not a reporting detail.\n'
    printf '%s\n' "$BAR"
  fi
  # The bounded re-emit's scratch block file lives beside the breadcrumb; never
  # derive it from the /dev/null fallback.
  if [ "$SESSION_START_STAGE_FILE" != /dev/null ]; then
    rm -f "$SESSION_START_STAGE_FILE" "$SESSION_START_STAGE_FILE.block" 2>/dev/null || true
  fi
  exit 0
fi

PRIMARY_HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-public-followup-lib.sh
. "$SCRIPT_DIR/fm-public-followup-lib.sh"
# shellcheck source=bin/fm-trace-context-lib.sh
. "$SCRIPT_DIR/fm-trace-context-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"

# One tasks-axi compatibility verdict per session start. The probe costs three
# tasks-axi subprocesses and this digest needs the same answer twice - here for
# the backlog listing and again inside the fm-bootstrap.sh child, which reports
# an incompatible build as MISSING. Computing it once and handing it to that
# child collapses six subprocesses to three. fm-tasks-axi-lib.sh owns both reuse
# layers and the one-hop consumption rule that keeps the verdict out of any
# agent's environment.
if fm_tasks_axi_compatible; then TASKS_AXI_COMPATIBLE=1; else TASKS_AXI_COMPATIBLE=0; fi

STATUS_TAIL=${FM_SESSION_START_STATUS_TAIL:-5}
case "$STATUS_TAIL" in ''|*[!0-9]*) STATUS_TAIL=5 ;; esac
QUEUED_LIMIT=${FM_SESSION_START_QUEUED_LIMIT:-20}
case "$QUEUED_LIMIT" in ''|*[!0-9]*|0) QUEUED_LIMIT=20 ;; esac
BACKLOG_FIELDS=blocked_by,hold_kind,hold_reason

# The bounded re-emit and its hard budget: see the header's BOUNDED RE-EMIT note.
REEMIT_BOUNDED=0
if [ "$REEMIT" -eq 1 ] && [ "$SESSION_SOURCE" = compact ]; then REEMIT_BOUNDED=1; fi
REEMIT_BUDGET_DEFAULT=24576
REEMIT_BUDGET_FLOOR=8192
REEMIT_RESERVE=4096
REEMIT_BUDGET=${FM_SESSION_START_REEMIT_BUDGET:-$REEMIT_BUDGET_DEFAULT}
case "$REEMIT_BUDGET" in ''|*[!0-9]*) REEMIT_BUDGET=$REEMIT_BUDGET_DEFAULT ;; esac
REEMIT_BUDGET=$((10#$REEMIT_BUDGET))
[ "$REEMIT_BUDGET" -ge "$REEMIT_BUDGET_FLOOR" ] || REEMIT_BUDGET=$REEMIT_BUDGET_FLOOR
REEMIT_USED=0
REEMIT_OMITTED=
REEMIT_WAKE_BYTES=0
REEMIT_AGENTS_BYTES=0

RULE='================================================================================'
SUBRULE='--------------------------------------------------------------------------------'

section() { printf '\n%s\n%s\n%s\n' "$RULE" "$1" "$RULE"; }
subsection() { printf '\n%s\n%s\n' "$1" "$SUBRULE"; }

# block_begin / block_end bracket one printed block of the digest. Outside the
# bounded re-emit both are no-ops, so every other path still streams each line
# to stdout the moment it is printed. Inside it, block_begin diverts stdout to a
# scratch file and block_end weighs what the block printed before releasing it:
#   fixed    always printed, and counted against the budget
#   bounded  printed only when it fits with REEMIT_RESERVE left for the fixed
#            text still to come; otherwise replaced by one RE-EMIT BUDGET line
#   exempt   always printed and never counted; its size is only recorded for
#            the closing RE-EMIT SIZE line
# The scratch file sits beside the stage breadcrumb, so the parent that removes
# one removes the other even when this child is killed at its runtime bound.
# With no usable scratch file a fixed or exempt block streams unmeasured, and a
# bounded block is discarded and reported omitted, so the budget still holds.
REEMIT_BLOCK_FILE=
REEMIT_BLOCK_OPEN=0
if [ "$REEMIT_BOUNDED" -eq 1 ]; then
  case "${FM_SESSION_START_STAGE_FILE:-}" in
    ''|/dev/null) ;;
    *) REEMIT_BLOCK_FILE="$FM_SESSION_START_STAGE_FILE.block" ;;
  esac
fi

block_begin() {  # <fixed|bounded|exempt>
  [ "$REEMIT_BOUNDED" -eq 1 ] || return 0
  REEMIT_BLOCK_OPEN=0
  if [ -n "$REEMIT_BLOCK_FILE" ] && (umask 077; : > "$REEMIT_BLOCK_FILE") 2>/dev/null; then
    exec 7>&1 >"$REEMIT_BLOCK_FILE"
    REEMIT_BLOCK_OPEN=1
  elif [ "$1" = bounded ]; then
    exec 7>&1 >/dev/null
    REEMIT_BLOCK_OPEN=2
  fi
}

block_end() {  # <fixed|bounded|exempt> <name> [<how to read it>]
  local kind=$1 name=$2 recovery=${3:-} size notice
  [ "$REEMIT_BOUNDED" -eq 1 ] || return 0
  [ "$REEMIT_BLOCK_OPEN" -ne 0 ] || return 0
  exec >&7 7>&-
  if [ "$REEMIT_BLOCK_OPEN" -eq 1 ]; then
    size=$(wc -c < "$REEMIT_BLOCK_FILE" 2>/dev/null | tr -d '[:space:]')
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
  else
    size=unmeasured
  fi
  case "$kind" in
    exempt)
      cat "$REEMIT_BLOCK_FILE"
      case "$name" in
        'WAKE QUEUE') REEMIT_WAKE_BYTES=$size ;;
        *) REEMIT_AGENTS_BYTES=$size ;;
      esac
      ;;
    fixed)
      cat "$REEMIT_BLOCK_FILE"
      REEMIT_USED=$((REEMIT_USED + size))
      ;;
    bounded)
      if [ "$size" != unmeasured ] && [ $((REEMIT_USED + size + REEMIT_RESERVE)) -le "$REEMIT_BUDGET" ]; then
        cat "$REEMIT_BLOCK_FILE"
        REEMIT_USED=$((REEMIT_USED + size))
      else
        if [ "$size" = unmeasured ]; then
          notice=$(printf '\nRE-EMIT BUDGET: %s omitted - no scratch file was available to weigh it against the %s-byte re-emit budget.\nRead it directly: %s' \
            "$name" "$REEMIT_BUDGET" "$recovery")
        else
          notice=$(printf '\nRE-EMIT BUDGET: %s omitted - its %s bytes do not fit the %s-byte re-emit budget (%s used, %s reserved for the fixed text below).\nRead it directly: %s' \
            "$name" "$size" "$REEMIT_BUDGET" "$REEMIT_USED" "$REEMIT_RESERVE" "$recovery")
        fi
        printf '%s\n' "$notice"
        REEMIT_USED=$((REEMIT_USED + ${#notice} + 1))
        REEMIT_OMITTED="${REEMIT_OMITTED}  - ${name}: ${recovery}
"
      fi
      ;;
  esac
  REEMIT_BLOCK_OPEN=0
}

# print_file_or_absent <path> <label>: full contents under a labeled
# subsection, or an explicit ABSENT marker. Absence is semantically
# meaningful for every one of these files (captain.md absent = firstmate
# repo built-in defaults, projects.md absent = rebuild from clones, etc. -
# AGENTS.md section 3) and must never be confused with an empty-but-present
# file, so the two cases print differently.
print_file_or_absent() {
  local path=$1 label=$2
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      cat "$path"
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

# print_file_presence <path> <label>: the same three-way distinction as
# print_file_or_absent, without the contents. The bounded re-emit uses it so an
# ABSENT file still reads as absent when nothing is reprinted.
print_file_presence() {
  local path=$1 label=$2 size
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      size=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
      printf '  %s: present (%s bytes) - %s\n' "$label" "${size:-?}" "$path"
    else
      printf '  %s: present, empty\n' "$label"
    fi
  else
    printf '  %s: ABSENT\n' "$label"
  fi
}

print_backlog_pointer() {
  printf 'Full task bodies remain available on demand: bin/fm-tasks-axi.sh show <id> --full when compatible tasks-axi is available, or data/backlog.md.\n'
}

# A queued title line whose own text already marks it held or blocked. The
# manual renderer has no task model, so this is the only signal it gets, and it
# is the one tasks-axi's markdown backend writes: "(hold: ...)", "(hold-kind:
# ...)", and "blocked-by: ...". Bracket expressions rather than backslashes,
# because awk's -v applies escape processing before the regex is ever compiled.
MANUAL_KEEP_RE='[(]hold|blocked-by:'

print_backlog_manual_compact() {
  local path=$1 reason=$2
  printf 'compact backlog listing (%s; done rows omitted; every in-flight, held, and blocked title line kept; other queued bounded to %s; indented task bodies omitted)\n' \
    "$reason" "$QUEUED_LIMIT"
  awk -v max="$QUEUED_LIMIT" -v keep_re="$MANUAL_KEEP_RE" '
    function state_for_heading(line, heading) {
      heading = line
      sub(/^##[[:space:]]+/, "", heading)
      sub(/[[:space:]]+$/, "", heading)
      if (heading == "In flight") return "in_flight"
      if (heading == "Queued") return "queued"
      if (heading == "Done") return "done"
      return ""
    }
    /^##[[:space:]]+/ {
      state = state_for_heading($0)
      # The Done heading is recognized so its items are skipped, never printed.
      if (state != "" && state != "done") print $0
      next
    }
    state == "in_flight" && /^[-*][[:space:]]+/ { in_flight++; print $0; next }
    state == "done" && /^[-*][[:space:]]+/ { done_total++; next }
    state == "queued" && /^[-*][[:space:]]+/ {
      queued_total++
      if ($0 ~ keep_re) { gated++; print $0; next }
      if (plain_shown < max) { plain_shown++; print $0 }
      next
    }
    END {
      plain_total = queued_total - gated
      if (in_flight + queued_total + done_total == 0) {
        print "(no backlog item title lines found)"
      } else {
        printf "(shown %d in-flight, %d held or blocked queued, %d of %d other queued title line(s); %d done row(s) omitted)\n", \
          in_flight, gated, plain_shown, plain_total, done_total
        if (plain_total > plain_shown) {
          printf "(%d more queued - raise FM_SESSION_START_QUEUED_LIMIT or read data/backlog.md for the rest)\n", plain_total - plain_shown
        }
      }
    }
  ' "$path"
}

# tasks-axi closes every listing with its own help block. This section composes
# four listings, so keeping them would repeat the same pointers four times, once
# per group, each carrying this home's full backlog path. The section prints one
# equivalent pointer of its own (print_backlog_pointer), so the per-group help
# blocks stop at their `help[` header instead.
strip_axi_help() {
  awk '/^help\[/ { exit } { print }'
}

# Bound the dispatchable-now listing without rewriting the tool's own rendering:
# `tasks-axi ready` rows are the indented lines under its ready[N]{...} header,
# and every other line it prints (its count, its public-followup line) passes
# through untouched. Whatever is cut is disclosed exactly.
print_ready_queued_bounded() {
  local ready=$1
  printf '%s\n' "$ready" | awk -v max="$QUEUED_LIMIT" '
    /^help\[/ { exit }
    /^ready\[/ { rows = 1; print; next }
    rows && /^[[:space:]]/ {
      total++
      if (shown < max) { print; shown++ }
      next
    }
    { rows = 0; print }
    END {
      if (total > 0) {
        printf "(shown %d of %d ready queued item(s))\n", shown, total
        if (total > shown) {
          printf "(%d more queued - bin/fm-tasks-axi.sh ready)\n", total - shown
        }
      }
    }
  '
}

print_backlog_tasks_axi_compact() {
  local path=$1 in_flight held blocked ready err axi_bin=${FM_TASKS_AXI_BIN:-tasks-axi}
  if ! in_flight=$("$axi_bin" list --file "$path" --state in_flight --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$in_flight
  elif ! held=$("$axi_bin" list --file "$path" --state held --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$held
  elif ! blocked=$("$axi_bin" list --file "$path" --state queued --blocked --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$blocked
  elif ! ready=$("$axi_bin" ready --file "$path" 2>&1); then
    err=$ready
  else
    printf 'compact backlog listing (tasks-axi; done rows omitted; every in-flight, held, and blocked row shown in full; ready queued bounded to %s; task bodies omitted)\n' \
      "$QUEUED_LIMIT"
    printf '\nin flight:\n'
    printf '%s\n' "$in_flight" | strip_axi_help
    printf '\nheld (captain- or time-gated; an in-flight item that is also held appears in both groups):\n'
    printf '%s\n' "$held" | strip_axi_help
    printf '\nblocked queued:\n'
    printf '%s\n' "$blocked" | strip_axi_help
    printf '\nready queued (dispatchable now):\n'
    print_ready_queued_bounded "$ready"
    return 0
  fi
  printf 'tasks-axi compact listing failed; falling back to title-line rendering.\n'
  printf '%s\n' "$err"
  print_backlog_manual_compact "$path" "fallback"
}

print_backlog_compact() {
  local path=$1 label=$2
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      if fm_tasks_axi_backend_available "$CONFIG"; then
        print_backlog_tasks_axi_compact "$path"
      elif fm_backlog_backend_manual "$CONFIG"; then
        print_backlog_manual_compact "$path" "manual backend"
      else
        print_backlog_manual_compact "$path" "tasks-axi unavailable or incompatible"
      fi
      print_backlog_pointer
    else
      printf '(present, empty)\n'
    fi
  else
    printf 'ABSENT\n'
  fi
}

print_status_tail() {
  local status=$1 line
  printf 'status tail (last %s line(s), each capped at %s characters, wake-EVENT history, not current state; full log: %s):\n' \
    "$STATUS_TAIL" "$FM_LINE_CAP_DEFAULT" "$status"
  # A crewmate writes its own status lines, so their length is unbounded: one
  # observed line ran 865 characters. Cap each one the way the wake digest's
  # OPEN DECISIONS section does; the lede carries the state word and the key,
  # and the full log path above reaches the rest.
  while IFS= read -r line || [ -n "$line" ]; do
    fm_cap_line "$line"
  done < <(tail -n "$STATUS_TAIL" "$status")
}

hash_file_sha256() {
  local file=$1 digest
  [ -f "$file" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256 "$file" 2>/dev/null | awk '
      length($1) == 64 && $1 !~ /[^[:xdigit:]]/ { print "sha256:" $1; found=1; exit }
      END { if (!found) exit 1 }
    ') && [ -n "$digest" ] && { printf '%s\n' "$digest"; return 0; }
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$file" 2>/dev/null | awk '
      length($1) == 64 && $1 !~ /[^[:xdigit:]]/ { print "sha256:" $1; found=1; exit }
      END { if (!found) exit 1 }
    ') && [ -n "$digest" ] && { printf '%s\n' "$digest"; return 0; }
  fi
  return 1
}

# The baseline describes instructions this true session started with, not the
# most recently emitted instructions. It is intentionally immutable for this
# lock owner: every later stale-context rebuild needs the current file again.
write_agents_baseline() {  # <lock-pid> <agents-hash>
  local lock_pid=$1 agents_hash=$2 tmp
  [ -n "$lock_pid" ] && [ -n "$agents_hash" ] || return 1
  tmp=$(mktemp "$STATE/.session-start-agents-baseline.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n%s\n' "$lock_pid" "$agents_hash" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$AGENTS_BASELINE_FILE" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

# The durable record behind the once-per-session, once-per-content
# instruction refresh: the harness session identity the Pi extension passed
# (or the lock-owning pid when none arrived) and the AGENTS.md SHA-256 that
# session already had re-emitted, one per line. A different identity, or a
# different hash, never matches. Separate from the true-start baseline, which
# stays immutable.
agents_refresh_marker_applies() {  # <lock-pid>
  [ "$READ_ONLY" -eq 0 ] \
    && [ "$(cat "$STATE/.lock" 2>/dev/null || true)" = "$1" ]
}

agents_refresh_identity() {  # <lock-pid>
  local session_id=${FM_SESSIONSTART_SESSION_ID:-}
  case "$session_id" in
    ''|*[!A-Za-z0-9._-]*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$session_id" ;;
  esac
}

# Each identity gets its own marker file so one conversation's delivery never
# suppresses another's; the lock-owning pid is the identity when no harness
# session identity arrives.
agents_refresh_marker_file() {  # <identity>
  printf '%s\n' "$AGENTS_REFRESH_MARKER_PREFIX.$1"
}

agents_refresh_already_delivered() {  # <identity> <content-key>
  local identity=$1 content_key=$2 marker
  [ -n "$identity" ] && [ -n "$content_key" ] || return 1
  marker=$(agents_refresh_marker_file "$identity")
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  [ "$(sed -n '1p' "$marker" 2>/dev/null || true)" = "$identity" ] \
    && [ "$(sed -n '2p' "$marker" 2>/dev/null || true)" = "$content_key" ]
}

record_agents_refresh() {  # <identity> <content-key>
  local identity=$1 content_key=$2 marker tmp
  [ -n "$identity" ] && [ -n "$content_key" ] || return 1
  marker=$(agents_refresh_marker_file "$identity")
  tmp=$(mktemp "$STATE/.session-start-agents-refresh.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n%s\n' "$identity" "$content_key" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$marker" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

# The freshness proof for a session with no baseline of its own: see the
# header's --source note for the argument and its limits.
AGENTS_FRESH_MARGIN_SECS=3

file_change_epoch() {  # <file>: the later of its mtime and ctime, epoch seconds
  local file=$1 mtime ctime
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  if [ "$(uname -s 2>/dev/null || true)" = Darwin ]; then
    mtime=$(/usr/bin/stat -f %m "$file" 2>/dev/null) || return 1
    ctime=$(/usr/bin/stat -f %c "$file" 2>/dev/null) || return 1
  else
    mtime=$(stat -c %Y "$file" 2>/dev/null) || return 1
    ctime=$(stat -c %Z "$file" 2>/dev/null) || return 1
  fi
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  case "$ctime" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$ctime" -gt "$mtime" ]; then printf '%s\n' "$ctime"; else printf '%s\n' "$mtime"; fi
}

process_elapsed_secs() {  # <pid>: POSIX `ps -o etime`, [[dd-]hh:]mm:ss, as seconds
  local pid=$1 etime
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  etime=$(LC_ALL=C ps -o etime= -p "$pid" 2>/dev/null) || return 1
  printf '%s\n' "$etime" | awk '
    { gsub(/[[:space:]]/, "") }
    !/^([0-9]+-)?([0-9]+:)?[0-9]+:[0-9]+$/ { exit 1 }
    {
      days = 0
      dash = index($0, "-")
      if (dash) { days = substr($0, 1, dash - 1); $0 = substr($0, dash + 1) }
      n = split($0, part, ":")
      if (n == 3) secs = part[1] * 3600 + part[2] * 60 + part[3]
      else secs = part[1] * 60 + part[2]
      print days * 86400 + secs
      found = 1
      exit 0
    }
    END { if (!found) exit 1 }
  '
}

file_mtime_epoch() {  # <file>
  local file=$1 mtime
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  if [ "$(uname -s 2>/dev/null || true)" = Darwin ]; then
    mtime=$(/usr/bin/stat -f %m "$file" 2>/dev/null) || return 1
  else
    mtime=$(stat -c %Y "$file" 2>/dev/null) || return 1
  fi
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$mtime"
}

# The wall clock is read BEFORE the elapsed time, so the gap between the two
# reads can only make the estimated start earlier, never later.
agents_unchanged_since_session_start() {  # <rebuilding-session-pid>
  local pid=$1 now elapsed changed started helm
  [ "$(cat "$STATE/.lock" 2>/dev/null || true)" = "$pid" ] || return 1
  helm=$(file_mtime_epoch "$STATE/.lock") || return 1
  now=$(date +%s 2>/dev/null) || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  elapsed=$(process_elapsed_secs "$pid") || return 1
  case "$elapsed" in ''|*[!0-9]*) return 1 ;; esac
  changed=$(file_change_epoch "$FM_ROOT/AGENTS.md") || return 1
  started=$((now - elapsed))
  [ "$helm" -ge "$started" ] || started=$helm
  [ $((changed + AGENTS_FRESH_MARGIN_SECS)) -lt "$started" ]
}

agents_baseline_drifted() {  # <rebuilding-session-pid>
  local lock_pid=$1 baseline_pid='' baseline_hash current_hash
  if [ -f "$AGENTS_BASELINE_FILE" ] && [ ! -L "$AGENTS_BASELINE_FILE" ]; then
    baseline_pid=$(sed -n '1p' "$AGENTS_BASELINE_FILE" 2>/dev/null || true)
  fi
  if [ -n "$baseline_pid" ] && [ "$baseline_pid" = "$lock_pid" ]; then
    baseline_hash=$(sed -n '2p' "$AGENTS_BASELINE_FILE" 2>/dev/null || true)
    current_hash=$(hash_file_sha256 "$FM_ROOT/AGENTS.md" 2>/dev/null || true)
    [ -n "$current_hash" ] && [ "$baseline_hash" = "$current_hash" ] && return 1
    return 0
  fi
  agents_unchanged_since_session_start "$lock_pid" && return 1
  return 0
}

# Only run-tier source pairs with both a stale native instruction cache and a
# working Firstmate delivery path arrive here. Claude fresh-reads on reset, and
# Codex has no tracked interactive reset delivery path.
agents_refresh_required() {  # <rebuilding-session-pid>
  local lock_pid=$1
  case "$PRIMARY_HARNESS:$SESSION_SOURCE" in
    pi:compact|pi-signed:compact) ;;
    *) return 1 ;;
  esac
  agents_baseline_drifted "$lock_pid"
}

print_agents_refresh_if_required() {  # <rebuilding-session-pid>
  local lock_pid=$1 identity content_key
  agents_refresh_required "$lock_pid" || return 0
  identity=$(agents_refresh_identity "$lock_pid")
  content_key=$(hash_file_sha256 "$FM_ROOT/AGENTS.md" 2>/dev/null || true)
  if [ -n "$content_key" ] && agents_refresh_marker_applies "$lock_pid" \
    && agents_refresh_already_delivered "$identity" "$content_key"; then
    printf 'AGENTS.md REFRESH: the current bytes in %s were already delivered to this session, so they are not reprinted here; read that file directly if needed.\n' "$FM_ROOT/AGENTS.md"
    AGENTS_REFRESH_WITHHELD=1
    return 0
  fi
  section "CURRENT AGENTS.md - INSTRUCTION REFRESH"
  if [ -f "$FM_ROOT/AGENTS.md" ]; then
    cat <<'EOF'
The complete on-disk AGENTS.md below supersedes the instruction copy this session
started with. Apply it as the current Firstmate instruction contract.

EOF
    cat "$FM_ROOT/AGENTS.md"
  else
    printf 'The original AGENTS.md baseline no longer matches, but the current file is absent.\n'
  fi
  if [ -n "$content_key" ] && agents_refresh_marker_applies "$lock_pid"; then
    record_agents_refresh "$identity" "$content_key" || true
  fi
}

AGENTS_START_HASH=
AGENTS_REFRESH_WITHHELD=0
if [ "$REEMIT" -eq 0 ] && [ "$SESSION_SOURCE" = startup ]; then
  AGENTS_START_HASH=$(hash_file_sha256 "$FM_ROOT/AGENTS.md" 2>/dev/null || true)
fi

block_begin fixed
if [ "$REEMIT_BOUNDED" -eq 1 ]; then
  section "SESSION START (CONTEXT RE-EMIT) - $FM_HOME"
  printf 'This session already took the helm at its own startup and has only lost context\n'
  printf 'to a compaction, whose summary carries what the session already knew, so this\n'
  printf 're-emit is deliberately small. Lock ownership is re-verified and the supervision\n'
  printf 'operating instructions are reprinted. The sweeps startup already reconciled\n'
  printf 'are NOT repeated, and the fleet-state and context digests are NOT reprinted: the\n'
  printf 'RE-EMIT SCOPE section below says how to read one source when the work needs it.\n'
  printf 'Queued wakes ARE still drained: they arrived after startup and are this turn work.\n'
elif [ "$REEMIT" -eq 1 ]; then
  section "SESSION START (CONTEXT RE-EMIT) - $FM_HOME"
  printf 'This session already took the helm at its own startup and has only lost its\n'
  printf 'context. Lock ownership is re-verified and the durable records below are\n'
  printf 'reprinted, but the sweeps startup already reconciled - project clone refresh,\n'
  printf 'secondmate convergence and liveness, pending remote handoff\n'
  printf 'retry, X-mode artifact writes, and stale Herdr child cleanup - are NOT repeated.\n'
  printf 'Queued wakes ARE still drained: they arrived after startup and are this turn work.\n'
else
  section "SESSION START - $FM_HOME"
fi
# --- 1. lock -----------------------------------------------------------
stage lock
subsection "LOCK"
LOCK_OUT=$("$SCRIPT_DIR/fm-lock.sh" 2>&1)
LOCK_RC=$?
printf '%s\n' "$LOCK_OUT"
READ_ONLY=0
if [ "$LOCK_RC" -ne 0 ]; then
  READ_ONLY=1
  BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '%s\n' "$BAR"
    printf '●  READ-ONLY SESSION - FLEET LOCK OWNERSHIP WAS NOT VERIFIED\n'
    printf '●  %s\n' "$LOCK_OUT"
    printf '●  Skipping every mutating step: stale Herdr child cleanup,\n'
    printf '●  secondmate convergence, secondmate liveness, pending remote handoff retry,\n'
    printf '●  X-mode artifacts, fleet sync, and wake-queue drain. Detect-only bootstrap\n'
    printf '●  diagnostics and the rest of this read-only-safe digest still ran below.\n'
    printf '●  Operate read-only until this resolves - do not spawn, steer, merge, or\n'
    printf '●  otherwise mutate fleet state from this session.\n'
    printf '%s\n' "$BAR"
  }
fi
block_end fixed LOCK
REBUILDING_SESSION_PID=$(fm_harness_ancestry_pid 2>/dev/null || true)
block_begin exempt
print_agents_refresh_if_required "$REBUILDING_SESSION_PID"
block_end exempt 'AGENTS.md REFRESH'

if [ "$READ_ONLY" -eq 0 ]; then
  if [ "$REEMIT" -eq 0 ]; then
    rm -f "$COMPLETION_FILE" 2>/dev/null || true
  fi
  fm_trace_context_session_start "$CONFIG" "$STATE/.trace-context-effective"
  # A full locked start publishes this home's current structured summary.
  # Publication is side-band and best-effort, so it can never change the
  # session-start result. A context re-emit is not another session start.
  if [ "$REEMIT" -eq 0 ]; then
    "$SCRIPT_DIR/fm-home-summary-refresh.sh" --best-effort || true
  fi
  # Every network call and the potentially slow inactive-outcome startup scan
  # are launched HERE, detached and bounded, so they run concurrently with the
  # whole digest below instead of in front of it. Step 7 harvests whatever has
  # finished, without ever waiting.
  # --reemit passes --locked 0 for the same reason it runs bootstrap detect-only:
  # this process already ran the mutating sweeps at its own startup, so only the
  # read-only GitHub-auth probe is owed. A read-only session starts nothing at
  # all: it holds no mutation authority for the sweeps, and it must not spawn,
  # steer, or merge anyway, so it has no action left for an auth verdict to gate.
  NETWORK_STAGE_LOCKED=1
  [ "$REEMIT" -eq 0 ] || NETWORK_STAGE_LOCKED=0
  "$SCRIPT_DIR/fm-startup-network.sh" start \
    --locked "$NETWORK_STAGE_LOCKED" --harvest-pid $$ >/dev/null 2>&1 || true
fi

# --- 2. bootstrap --------------------------------------------------------
# FM_BOOTSTRAP_NETWORK=skip on every path: bootstrap's own network half is what
# the deferred stage above is running right now, and running it twice would both
# re-block this digest and race the worker's sweeps against themselves.
stage bootstrap
block_begin bounded
subsection "BOOTSTRAP"
if [ "$READ_ONLY" -eq 1 ]; then
  BOOT_OUT=$(FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip \
    FM_TASKS_AXI_COMPATIBLE="$TASKS_AXI_COMPATIBLE" "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1)
elif [ "$REEMIT" -eq 1 ]; then
  BOOT_OUT=$(FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_LOCKED=1 FM_BOOTSTRAP_NETWORK=skip \
    FM_TASKS_AXI_COMPATIBLE="$TASKS_AXI_COMPATIBLE" "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1)
else
  BOOT_OUT=$(
    "$SCRIPT_DIR/fm-herdr-session-cleanup.sh" 2>&1 || true
    FM_BOOTSTRAP_NETWORK=skip FM_TASKS_AXI_COMPATIBLE="$TASKS_AXI_COMPATIBLE" \
      "$SCRIPT_DIR/fm-bootstrap.sh" 2>&1
  )
fi
if [ -n "$BOOT_OUT" ]; then
  printf '%s\n' "$BOOT_OUT"
else
  printf '(silent - all good)\n'
fi
block_end bounded BOOTSTRAP "FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip $SCRIPT_DIR/fm-bootstrap.sh"

# --- 3. wake-drain ---------------------------------------------------------
# The inactive-outcome startup scan runs in the deferred worker launched above,
# where its potentially slow current-state reads cannot block this digest. It
# publishes findings through the same durable queue drained here; the watcher's
# separate 900-second cadence remains unchanged.
# Presented records are this turn's first work queue and remain durable until
# post-handling acknowledgement. The drain's separate OPEN DECISIONS section
# remains actionable even when that queue is empty (AGENTS.md sections 3 and 8).
# The drain also runs fm-guard.sh internally on the locked path, so the
# tangle/watcher-liveness alarms land right here too, ahead of the bulk digest
# below. The read-only path never touches the queue because it lacks mutation
# authority, and another session may be actively handling it. It still runs
# fm-guard.sh directly with non-mutating advisory text, so the same alarms
# surface without repair commands.
stage wake-queue
block_begin exempt
subsection "WAKE QUEUE"
if [ "$READ_ONLY" -eq 1 ]; then
  QLEN=0
  [ -s "$STATE/.wake-queue" ] && QLEN=$(grep -c . "$STATE/.wake-queue" 2>/dev/null || printf '0')
  printf 'skipped (read-only session) - %s record(s) remain queued because this session lacks verified fleet-lock ownership.\n' "$QLEN"
  GUARD_OUT=$(FM_GUARD_READ_ONLY=1 "$SCRIPT_DIR/fm-guard.sh" 2>&1)
  [ -n "$GUARD_OUT" ] && printf '%s\n' "$GUARD_OUT"
else
  # Pi supervision-branch recovery, locked path only: clear leases whose
  # supervising session died, and surface outcomes the branch stored durably
  # that never reached main (docs/pi-supervision-branch.md). Gated to the
  # pi/pi-signed primary so a non-Pi home runs neither step - homes on any
  # other harness stay entirely untouched (captain-decided criterion).
  if [ "$PRIMARY_HARNESS" = pi ] || [ "$PRIMARY_HARNESS" = pi-signed ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-lease.sh" sweep 2>/dev/null || true
    BRANCH_REPLAY_OUT=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-branch-outcome.sh" startup-replay 2>&1) || BRANCH_REPLAY_OUT=
    if [ -n "$BRANCH_REPLAY_OUT" ]; then
      printf '%s\n' "$BRANCH_REPLAY_OUT"
    fi
  fi
  DRAIN_OUT=$("$SCRIPT_DIR/fm-wake-drain.sh" 2>&1)
  if [ -n "$DRAIN_OUT" ]; then
    printf '%s\n' "$DRAIN_OUT"
  else
    printf '(no queued wakes)\n'
  fi
fi
block_end exempt 'WAKE QUEUE'

# --- 4. supervision operating instructions ----------------------------------
stage supervision-instructions
AFK_PRESENT=0
[ -e "$STATE/.afk" ] && AFK_PRESENT=1
AFK_MODE=$(fm_afk_mode "$STATE")
X_MODE_PRESENT=0
[ -f "$CONFIG/x-mode.env" ] && X_MODE_PRESENT=1

block_begin bounded
if [ "$PRIMARY_HARNESS" = pi ] || [ "$PRIMARY_HARNESS" = pi-signed ]; then
  PI_EXT="$FM_ROOT/.pi/extensions/fm-primary-pi-watch.ts"
  PI_TURNEND_EXT="$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
  PI_WATCH_MARKER="$STATE/.pi-watch-extension-loaded"
  PI_TURNEND_MARKER="$STATE/.pi-turnend-extension-loaded"
  PI_LOCK="$STATE/.lock"
  PI_RESTART_COMMAND=$PRIMARY_HARNESS
  [ "$PRIMARY_HARNESS" != pi ] || PI_RESTART_COMMAND='plain pi'
  PI_WATCH_VERSION=$(fm_pi_extension_version "$PI_EXT" || printf '')
  PI_TURNEND_VERSION=$(fm_pi_extension_version "$PI_TURNEND_EXT" || printf '')
  if ! fm_pi_extension_loaded "$PI_WATCH_MARKER" "$PI_WATCH_VERSION" "$PI_LOCK" \
    || ! fm_pi_extension_loaded "$PI_TURNEND_MARKER" "$PI_TURNEND_VERSION" "$PI_LOCK"; then
    printf 'PI_WATCH_EXTENSION: not loaded - approve Pi project trust once per clone, then restart %s so %s and %s auto-load for turn-end guard and background wake coverage; use -e %s -e %s only if project hooks are not trusted\n' "$PI_RESTART_COMMAND" "$PI_TURNEND_EXT" "$PI_EXT" "$PI_TURNEND_EXT" "$PI_EXT"
  fi
fi
# omp (Oh My Pi) has no project-trust gate: it auto-discovers <cwd>/.omp/extensions
# with no dialog, so the only ways both tracked primary extensions fail to load
# are a session started outside this home, an extension disabled in the omp
# config, or a build older than the tracked file. The markers carry the loaded
# build plus the loading pid, exactly as the Pi ones do (bin/fm-wake-lib.sh).
if [ "$PRIMARY_HARNESS" = omp ]; then
  OMP_EXT="$FM_ROOT/.omp/extensions/fm-primary-omp-watch.ts"
  OMP_TURNEND_EXT="$FM_ROOT/.omp/extensions/fm-primary-turnend-guard.ts"
  OMP_WATCH_MARKER="$STATE/.omp-watch-extension-loaded"
  OMP_TURNEND_MARKER="$STATE/.omp-turnend-extension-loaded"
  OMP_LOCK="$STATE/.lock"
  OMP_WATCH_VERSION=$(fm_pi_extension_version "$OMP_EXT" || printf '')
  OMP_TURNEND_VERSION=$(fm_pi_extension_version "$OMP_TURNEND_EXT" || printf '')
  if ! fm_pi_extension_loaded "$OMP_WATCH_MARKER" "$OMP_WATCH_VERSION" "$OMP_LOCK" \
    || ! fm_pi_extension_loaded "$OMP_TURNEND_MARKER" "$OMP_TURNEND_VERSION" "$OMP_LOCK"; then
    printf 'OMP_WATCH_EXTENSION: not loaded - restart omp with this home as its working directory so %s and %s auto-load from .omp/extensions/ for turn-end guard and background wake coverage; pass -e %s -e %s only when omp must start from another directory, never together with auto-discovery (omp loads a file named both ways twice)\n' "$OMP_TURNEND_EXT" "$OMP_EXT" "$OMP_TURNEND_EXT" "$OMP_EXT"
  fi
fi
"$SCRIPT_DIR/fm-supervision-instructions.sh" \
  --harness "$PRIMARY_HARNESS" \
  --read-only "$READ_ONLY" \
  --afk "$AFK_PRESENT" \
  --afk-mode "$AFK_MODE" \
  --x-mode "$X_MODE_PRESENT"
block_end bounded 'SUPERVISION OPERATING INSTRUCTIONS' \
  "$SCRIPT_DIR/fm-supervision-instructions.sh --harness $PRIMARY_HARNESS --read-only $READ_ONLY --afk $AFK_PRESENT --afk-mode $AFK_MODE --x-mode $X_MODE_PRESENT"

# --- 5. read-once contract -------------------------------------------------
# Ahead of the two digests it governs, not after them: a truncated tail is
# exactly what drops a closing reminder, and this contract is what stops the
# next turn from re-reading everything the digest just printed. Because it now
# arrives BEFORE its subject, it also names the one condition that voids it -
# a stage that never ran, which the truncation banner names by stage.
stage read-once
block_begin fixed
if [ "$REEMIT_BOUNDED" -eq 1 ]; then
  section "RE-EMIT SCOPE"
  cat <<'EOF'
A true session start prints two bulk digests that this re-emit leaves out,
because the compaction summary already carries what they said:
  FLEET STATE  the backlog listing, every state/*.meta, each task's status
               tail, and the orphan status logs
  CONTEXT      data/projects.md, data/secondmates.md, data/captain.md,
               data/captain-shared.md, and data/learnings.md
Do NOT bulk-read those sources, and do NOT rerun bin/fm-session-start.sh, to
rebuild them: that returns to context the weight this re-emit keeps out of it.

Read one source directly only when the work in hand needs it:
  - one task's current state: bin/fm-crew-state.sh <id>
  - one task's record or its wake-event history: state/<id>.meta, state/<id>.status
  - the whole fleet at a glance: bin/fm-fleet-view.sh
  - the queue: bin/fm-tasks-axi.sh list when compatible tasks-axi is available,
    or data/backlog.md; one full body with bin/fm-tasks-axi.sh show <id> --full
  - a captain preference, a learning, a secondmate route, or the project
    registry: the one data/ file that owns it (listed under CONTEXT below)
A section this re-emit had no budget for is named where it would have printed,
and again under NEXT STEP, with the command that reads it.
EOF
else
section "READ-ONCE CONTRACT"
cat <<'EOF'
Everything below is printed in full for this session start: every state/*.meta,
a compact data/backlog.md listing, a bounded tail of every state/*.status,
data/projects.md, data/secondmates.md, data/captain.md, data/captain-shared.md,
and data/learnings.md.
Do NOT re-read any of them after reading this digest, and do NOT bulk-read
data/backlog.md or state/*.status: re-reading everything defeats the entire
point of this command.

Go to a source directly only when:
  - this digest flagged it ABSENT (then rebuild or create it per AGENTS.md),
  - its contents looked unparseable or corrupt,
  - an individual full status log is needed for older wake-event history, or a
    status line was capped and its tail matters (each task's full log path is
    printed with its tail),
  - a full task body is needed (bin/fm-tasks-axi.sh show <id> --full, or data/backlog.md),
  - the backlog listing disclosed omitted queued items and this turn needs them,
  - the NETWORK CHECKS section reported its checks still IN PROGRESS and this
    turn needs their verdict (bin/fm-startup-network.sh report),
  - or a STARTUP TRUNCATED banner named the stage that would have printed it, in
    which case that stage's sources were never emitted and must be reconciled.
EOF
fi
block_end fixed 'RE-EMIT SCOPE'

# --- 6. fleet-state digest ---------------------------------------------
# Before CONTEXT: see this file's ORDERING note. Live fleet identity is what a
# truncated tail must never take.
stage fleet-state
block_begin fixed
if [ "$REEMIT_BOUNDED" -eq 1 ]; then
  section "FLEET STATE (NOT REPRINTED)"
  META_COUNT=0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && META_COUNT=$((META_COUNT + 1))
  done
  STATUS_COUNT=0
  for status in "$STATE"/*.status; do
    [ -f "$status" ] && STATUS_COUNT=$((STATUS_COUNT + 1))
  done
  printf '%s task record(s) (*.meta) and %s status log(s) (*.status) are on disk under %s.\n' \
    "$META_COUNT" "$STATUS_COUNT" "$STATE"
  printf 'None is reprinted, and neither is the backlog listing: see RE-EMIT SCOPE above.\n'
else
section "FLEET STATE"
print_backlog_compact "$DATA/backlog.md" "data/backlog.md"

subsection "Work under way (state/*.meta)"
META_FOUND=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  META_FOUND=1
  id=$(basename "$meta" .meta)
  printf '\n--- %s ---\n' "$id"
  cat "$meta"

  window=$(fm_meta_get "$meta" window)
  target=$(fm_backend_target_of_meta "$meta")
  if [ -n "$window" ]; then
    backend=$(fm_backend_of_meta "$meta")
    if fm_backend_target_exists "$backend" "${target:-$window}" "fm-$id"; then
      printf 'endpoint: alive (backend=%s window=%s)\n' "$backend" "$window"
    else
      printf 'endpoint: dead (backend=%s window=%s)\n' "$backend" "$window"
    fi
  else
    printf 'endpoint: unknown (no window recorded)\n'
  fi

  status="$STATE/$id.status"
  if [ -f "$status" ]; then
    print_status_tail "$status"
  else
    printf 'status tail: (no status file yet: %s)\n' "$status"
  fi
done
[ "$META_FOUND" -eq 1 ] || printf '(none)\n'

subsection "Orphan status logs (state/*.status without matching .meta)"
ORPHAN_STATUS_FOUND=0
for status in "$STATE"/*.status; do
  [ -f "$status" ] || continue
  id=$(basename "$status" .status)
  [ -f "$STATE/$id.meta" ] && continue
  ORPHAN_STATUS_FOUND=1
  printf '\n--- %s ---\n' "$id"
  print_status_tail "$status"
done
[ "$ORPHAN_STATUS_FOUND" -eq 1 ] || printf '(none)\n'
fi

subsection "AFK"
# The away posture is the record (bin/fm-afk-contract.sh); the legacy flag
# still marks a running daemon on the harnesses that launch one.
if [ -f "$STATE/.afk-contract" ]; then
  printf 'present - away posture recorded at %s (hold-for-return only; bin/fm-afk-contract.sh readback for the mandate)' \
    "$("$SCRIPT_DIR/fm-afk-contract.sh" field entered 2>/dev/null || printf unknown)"
  if [ -e "$STATE/.afk" ]; then
    if [ "$AFK_MODE" = quiet ]; then
      printf '; the quiet daemon owns the watcher.\n'
    else
      printf '; the away daemon owns the watcher.\n'
    fi
  else
    printf '; no daemon runs, the ordinary supervision session continues.\n'
  fi
elif [ -e "$STATE/.afk" ]; then
  if [ "$AFK_MODE" = quiet ]; then
    printf 'present - quiet-mode supervision is active; the daemon owns the watcher, only an explicit /quiet off exits it (legacy flag with no posture record).\n'
  else
    printf 'present - away-mode supervision is active; the daemon owns the watcher (legacy flag with no posture record).\n'
  fi
else
  printf 'absent\n'
fi
block_end fixed 'FLEET STATE'

# Public commitments made through the myfirstmate relay. A promise to reply in a
# public thread must survive compaction and restart, so it is surfaced from disk
# here rather than from conversation memory. fm-public-followup-lib.sh owns both
# gates: a home that never opted into the relay runs one [ -f ] test, prints no
# subsection, and never reaches fm-public-followup.sh.
if fm_pf_relay_active "$FM_HOME" \
  && { fm_pf_has_registrations "$STATE" || fm_pf_has_events "$STATE"; }; then
  PUBLIC_FOLLOWUP=$("$SCRIPT_DIR/fm-public-followup.sh" pending 2>/dev/null) || PUBLIC_FOLLOWUP=
  if [ -n "$PUBLIC_FOLLOWUP" ]; then
    block_begin bounded
    subsection "Public commitments"
    printf '%s\n' "$PUBLIC_FOLLOWUP"
    printf '\nEach line is a public loop this home still holds: a reply still owed, or an open loop with nothing owed.\n'
    printf 'Reconcile terminal results with %s/bin/fm-public-followup.sh consume, then deliver a ready one with\n' "$FM_ROOT"
    printf '%s/bin/fm-public-followup.sh deliver <id>. Hand a delivered loop on with rechain, or close it with\n' "$FM_ROOT"
    printf '%s/bin/fm-public-followup.sh retire <id> --reason "...". Load fmx-respond for the procedure.\n' "$FM_ROOT"
    block_end bounded 'Public commitments' "$SCRIPT_DIR/fm-public-followup.sh pending (then load fmx-respond)"
  fi
fi

# --- 7. network checks ------------------------------------------------------
# Deliberately here and not later: these lines are actionable (a stuck clone, a
# secondmate that could not be relaunched, broken GitHub auth), and the section
# after this one is the curated memory a truncated tail is meant to take first.
# Deliberately here and not earlier: this is the last point in the digest, so the
# worker started at step 1 has had the whole composition above to finish in. It
# is a NON-BLOCKING read either way - whatever the worker has published by now is
# printed, and whatever it has not is named as not yet confirmed.
stage network-checks
block_begin bounded
section "NETWORK CHECKS"
if [ "$READ_ONLY" -eq 1 ]; then
  printf 'skipped (read-only session) - GitHub authentication, project clone refresh,\n'
  printf 'secondmate liveness and convergence, and pending handoff delivery were not run.\n'
  printf 'They need the fleet lock, and this session must not spawn, steer, or merge, so it\n'
  printf 'has no action they would gate. The session holding the lock runs them.\n'
else
  "$SCRIPT_DIR/fm-startup-network.sh" harvest --pid $$ 2>&1 || true
fi
block_end bounded 'NETWORK CHECKS' "$SCRIPT_DIR/fm-startup-network.sh report"

# --- 8. context digest -----------------------------------------------------
# Last of the bulk sections deliberately: curated memory is stable session to
# session, already governed by config/startup-memory-budget, and recoverable
# with one targeted read, so it is the cheapest thing for a truncated tail to
# take (see this file's ORDERING note).
stage context
block_begin fixed
if [ "$REEMIT_BOUNDED" -eq 1 ]; then
  section "CONTEXT (NOT REPRINTED)"
  printf 'Not reprinted: see RE-EMIT SCOPE above. Presence is still listed, because an\n'
  printf 'ABSENT file is meaningful (AGENTS.md section 3) and is not an empty one.\n'
  print_file_presence "$DATA/projects.md" "data/projects.md"
  print_file_presence "$DATA/secondmates.md" "data/secondmates.md"
  print_file_presence "$DATA/captain.md" "data/captain.md"
  print_file_presence "$DATA/captain-shared.md" "data/captain-shared.md"
  print_file_presence "$DATA/learnings.md" "data/learnings.md"
else
section "CONTEXT"
print_file_or_absent "$DATA/projects.md" "data/projects.md"
print_file_or_absent "$DATA/secondmates.md" "data/secondmates.md"
print_file_or_absent "$DATA/captain.md" "data/captain.md"
print_file_or_absent "$DATA/captain-shared.md" "data/captain-shared.md (shared, main-authoritative, read-only in secondmate homes)"
print_file_or_absent "$DATA/learnings.md" "data/learnings.md"
fi
block_end fixed CONTEXT

# --- 9. closing reminder -----------------------------------------------
stage next-step
block_begin fixed
section "NEXT STEP"
if [ "$READ_ONLY" -eq 1 ]; then
  cat <<'EOF'
This session did not acquire the fleet lock. Stay read-only: do not arm,
drain, spawn, steer, merge, or repair fleet state from here. Only a session
with verified fleet-lock ownership may perform mutable follow-up.

EOF
elif [ "$AFK_PRESENT" -eq 1 ] && [ "$AFK_MODE" = quiet ]; then
  cat <<'EOF'
Quiet mode is active. Follow the supervision operating instructions block
above: load /quiet and ensure the daemon is running, because the daemon owns
watcher supervision. Ordinary captain chat does not exit it; only an
explicit /quiet off does.

EOF
elif [ "$AFK_PRESENT" -eq 1 ]; then
  cat <<'EOF'
Away mode is active. Follow the supervision operating instructions block above:
load /afk and ensure the daemon is running, because the daemon owns watcher
supervision.

EOF
elif [ -f "$CONFIG/x-mode.env" ]; then
  cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
X mode is active, so the emitted block's cadence instruction applies.
This script never starts supervision itself.

EOF
else
cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
This script never starts supervision itself.

EOF
fi
if [ "$REEMIT_BOUNDED" -eq 1 ]; then
  cat <<'EOF'
The re-emit above is complete. Its RE-EMIT SCOPE section governs what may still
be read from disk.
EOF
else
cat <<'EOF'
The digest above is complete for this session start. The READ-ONCE CONTRACT
section near the top of it governs what may still be read from disk.
EOF
fi
block_end fixed 'NEXT STEP'
if [ "$REEMIT_BOUNDED" -eq 1 ]; then
  if [ -n "$REEMIT_OMITTED" ]; then
    printf '\nRE-EMIT BUDGET EXCEEDED - these sections were omitted, and each is read with the command beside it:\n%s' \
      "$REEMIT_OMITTED"
  fi
  if [ "$AGENTS_REFRESH_WITHHELD" -eq 1 ]; then
    printf '\nRE-EMIT SIZE: %s of %s budgeted bytes used; outside the budget: wake queue %s bytes, AGENTS.md refresh withheld (same bytes already delivered).\n' \
      "$REEMIT_USED" "$REEMIT_BUDGET" "$REEMIT_WAKE_BYTES"
  else
    printf '\nRE-EMIT SIZE: %s of %s budgeted bytes used; outside the budget: wake queue %s bytes, AGENTS.md refresh %s bytes.\n' \
      "$REEMIT_USED" "$REEMIT_BUDGET" "$REEMIT_WAKE_BYTES" "$REEMIT_AGENTS_BYTES"
  fi
fi

if [ "$READ_ONLY" -eq 0 ] && [ "$REEMIT" -eq 0 ]; then
  COMPLETION_RECORDED=0
  COMPLETION_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$COMPLETION_PID" in
    ''|*[!0-9]*) COMPLETION_PID= ;;
  esac
  COMPLETION_TMP=$(mktemp "$STATE/.session-start-complete.XXXXXX" 2>/dev/null || true)
  if [ -n "$COMPLETION_PID" ] && [ -n "$COMPLETION_TMP" ] \
    && printf '%s\n' "$COMPLETION_PID" > "$COMPLETION_TMP" 2>/dev/null \
    && mv -f "$COMPLETION_TMP" "$COMPLETION_FILE" 2>/dev/null; then
    COMPLETION_RECORDED=1
  else
    [ -z "$COMPLETION_TMP" ] || rm -f "$COMPLETION_TMP" 2>/dev/null || true
    printf '\nSESSION_START_COMPLETION: not recorded - the next clear or compact will run a full startup.\n'
  fi
  if [ "$SESSION_SOURCE" = startup ] && [ "$COMPLETION_RECORDED" -eq 1 ] && [ -n "$AGENTS_START_HASH" ]; then
    if ! write_agents_baseline "$COMPLETION_PID" "$AGENTS_START_HASH"; then
      printf '\nSESSION_START_AGENTS_BASELINE: not recorded - a later supported rebuild will re-emit AGENTS.md.\n'
    fi
  fi
fi

exit 0
