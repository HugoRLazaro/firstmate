#!/usr/bin/env bash
# fm-memory.sh - keep one machine's fleet inside its memory.
#
# Usage:
#   fm-memory.sh guard             refuse (exit 3) when this host is under the launch floor
#   fm-memory.sh [check]           print one line when memory first drops under the alert floor
#   fm-memory.sh arm               write and register state/memory.check.sh
#   fm-memory.sh disarm            remove the check shim, its trust binding, and the episode record
#   fm-memory.sh status            the reading, the floors, and memory held per task
#   fm-memory.sh run [--max-mb N] -- <command> [args...]
#                                  run a heavy job inside its own memory-capped scope
#   fm-memory.sh --help
#
# Why this exists: an agent that finishes its work stays alive in its pane, and
# a job it started keeps its memory after the agent stops, so a host fills up
# with nothing left to say so. Every action here reads the kernel's own numbers
# and none of them changes a host setting.
#
# The reading is /proc/meminfo (FM_MEMINFO_PATH replaces the path): MemAvailable,
# the kernel's estimate of what can be claimed without swapping, and SwapFree.
# A host with no /proc/meminfo has no reading to judge, so every action steps
# aside silently there. A reading that exists but cannot be parsed never blocks
# anything: `guard` warns on stderr and lets the launch continue, and `check`
# stays silent rather than waking firstmate about a number it does not have.
#
# The floors live in config/memory-floor, one `key=<whole megabytes>` per line,
# blank lines and # comments ignored. A missing file, a missing key, or a value
# that is not a whole number uses the default below, and a bad line is named on
# stderr; a bad floor never refuses a launch. 0 turns that one floor off.
#   spawn_available_mb   (2048)  `guard` refuses under this much MemAvailable
#   spawn_swap_free_mb   (512)   `guard` refuses under this much SwapFree, on a
#                                host that has swap at all
#   alert_available_mb   (1536)  `check` reports under this much MemAvailable
#   job_max_mb           (4096)  `run`'s cap when --max-mb is not given; 0
#                                runs the job with no cap
# docs/configuration.md "Memory guard" owns how those defaults were sized and
# the operating rules that go with them.
#
# guard: exit 0 when a launch may proceed, exit 3 with one diagnostic line
# naming the reading and the floor when it may not. FM_MEMORY_GUARD=off is the
# explicit override: it exits 0 and says on stderr that the floor was skipped.
# bin/fm-spawn.sh calls this for every local launch and relaunch.
#
# check: the watcher state-check contract - one line when firstmate should
# wake, nothing otherwise. It reports once per episode: the line is printed
# when MemAvailable first reads under the alert floor, state/.memory-low then
# records the episode, and nothing more is printed until MemAvailable has
# climbed back to the floor plus a quarter. That margin is what keeps a reading
# hovering at the floor from waking firstmate on every poll. Swap is named in
# the line but never opens or closes an episode, because swapped-out pages stay
# out after memory recovers and would hold the episode open forever.
# The watcher runs checks every FM_CHECK_INTERVAL seconds, so this is an early
# warning for a host filling over minutes, never a guarantee against a job that
# takes everything in seconds; `run` is the bound for that.
#
# status: read-only. Sums resident memory of the processes whose working
# directory is inside each recorded task's local copy, scratch directory, or
# data directory, and lists the largest processes that belong to no task.
#
# run: starts the command in a transient systemd user scope carrying MemoryMax
# and MemorySwapMax=0, so a job that outgrows its cap is killed alone instead of
# taking the host's swap with it. The command keeps its working directory, its
# terminal, and its exit status. Every process the job starts stays in that
# scope, including one detached with setsid or nohup. Where no systemd user
# manager answers, the command still runs, uncapped, and stderr says so.
# FM_MEMORY_SYSTEMD_RUN replaces the systemd-run executable.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/memory-floor"
MEMINFO="${FM_MEMINFO_PATH:-/proc/meminfo}"
PROC_ROOT="${FM_PROC_ROOT_OVERRIDE:-/proc}"
RECORD="$STATE/.memory-low"
CHECK_ID=memory
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
GUARD_REFUSE_EXIT=3

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-memory.sh guard       exit 3 with a diagnostic when this host is under the launch floor
  fm-memory.sh [check]     print one line when memory first drops under the alert floor
  fm-memory.sh arm         write and register state/memory.check.sh
  fm-memory.sh disarm      remove the check shim, its trust binding, and the episode record
  fm-memory.sh status      the reading, the floors, and memory held per task
  fm-memory.sh run [--max-mb N] -- <command> [args...]
                           run a heavy job inside its own memory-capped scope
  fm-memory.sh --help      print this help

Floors: config/memory-floor, one key=<megabytes> per line.
  spawn_available_mb (2048), spawn_swap_free_mb (512), alert_available_mb (1536), job_max_mb (4096)
FM_MEMORY_GUARD=off skips the launch floor for one command.
EOF
}

die_usage() {
  printf 'fm-memory: %s\n' "$1" >&2
  usage >&2
  exit 2
}

# --- floors -----------------------------------------------------------------

SPAWN_AVAILABLE_MB=2048
SPAWN_SWAP_FREE_MB=512
ALERT_AVAILABLE_MB=1536
JOB_MAX_MB=4096

floors_load() {
  local line key value
  [ -e "$CONFIG" ] || return 0
  if [ ! -f "$CONFIG" ] || [ ! -r "$CONFIG" ]; then
    printf 'fm-memory: warning: %s is not a readable regular file; using the default floors\n' "$CONFIG" >&2
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=$(printf '%s' "$line" | tr -d '[:space:]')
    [ -n "$line" ] || continue
    key=${line%%=*}
    value=${line#*=}
    case "$line" in *=*) ;; *) value= ;; esac
    case "$value" in
    '' | *[!0-9]*)
      printf 'fm-memory: warning: ignoring "%s" in %s; expected key=<whole megabytes>\n' "$line" "$CONFIG" >&2
      continue
      ;;
    esac
    # Bound the width so a pasted byte count cannot overflow the comparisons.
    [ "${#value}" -le 9 ] || {
      printf 'fm-memory: warning: ignoring "%s" in %s; the value is megabytes\n' "$line" "$CONFIG" >&2
      continue
    }
    value=$((10#$value))
    case "$key" in
    spawn_available_mb) SPAWN_AVAILABLE_MB=$value ;;
    spawn_swap_free_mb) SPAWN_SWAP_FREE_MB=$value ;;
    alert_available_mb) ALERT_AVAILABLE_MB=$value ;;
    job_max_mb) JOB_MAX_MB=$value ;;
    *) printf 'fm-memory: warning: ignoring unknown key "%s" in %s\n' "$key" "$CONFIG" >&2 ;;
    esac
  done <"$CONFIG"
}

# --- reading ----------------------------------------------------------------

# reading_load sets READING to one of:
#   ok           AVAILABLE_MB, SWAP_FREE_MB, and SWAP_TOTAL_MB are set
#   unsupported  the host's own /proc/meminfo does not exist
#   unreadable   a reading exists but cannot be trusted; READING_PROBLEM says why
READING=
READING_PROBLEM=
AVAILABLE_MB=
SWAP_FREE_MB=
SWAP_TOTAL_MB=

reading_load() {
  local fields available swap_free swap_total
  READING=unreadable
  READING_PROBLEM=
  if [ ! -e "$MEMINFO" ]; then
    if [ -z "${FM_MEMINFO_PATH:-}" ]; then
      READING=unsupported
      return 0
    fi
    READING_PROBLEM="$MEMINFO does not exist"
    return 0
  fi
  if [ ! -r "$MEMINFO" ] || [ -d "$MEMINFO" ]; then
    READING_PROBLEM="$MEMINFO cannot be read"
    return 0
  fi
  fields=$(awk '
    $1 == "MemAvailable:" { a = $2; au = $3; an++ }
    $1 == "SwapFree:" { f = $2; fu = $3; fn++ }
    $1 == "SwapTotal:" { t = $2; tu = $3; tn++ }
    END { printf "%s|%s|%s|%s|%s|%s|%s|%s|%s\n", a, au, an + 0, f, fu, fn + 0, t, tu, tn + 0 }
  ' "$MEMINFO" 2>/dev/null) || fields=
  IFS='|' read -r available au an swap_free fu fn swap_total tu tn <<EOF
$fields
EOF
  if [ "${an:-0}" != 1 ] || [ "${au:-}" != kB ]; then
    READING_PROBLEM="$MEMINFO has no single MemAvailable line in kB"
    return 0
  fi
  case "$available" in '' | *[!0-9]*)
    READING_PROBLEM="$MEMINFO reports MemAvailable as '$available'"
    return 0
    ;;
  esac
  # Swap lines are optional: a host with none simply has no swap to judge. A
  # swap line that is present but malformed makes the whole reading ambiguous.
  if [ "${fn:-0}" = 0 ] && [ "${tn:-0}" = 0 ]; then
    swap_free=0
    swap_total=0
  else
    if [ "${fn:-0}" != 1 ] || [ "${tn:-0}" != 1 ] || [ "${fu:-}" != kB ] || [ "${tu:-}" != kB ]; then
      READING_PROBLEM="$MEMINFO has no single SwapFree and SwapTotal line in kB"
      return 0
    fi
    case "$swap_free$swap_total" in '' | *[!0-9]*)
      READING_PROBLEM="$MEMINFO reports swap as '$swap_free' of '$swap_total'"
      return 0
      ;;
    esac
  fi
  [ "${#available}" -le 15 ] && [ "${#swap_free}" -le 15 ] && [ "${#swap_total}" -le 15 ] || {
    READING_PROBLEM="$MEMINFO reports a value too large to be a memory size"
    return 0
  }
  AVAILABLE_MB=$((10#$available / 1024))
  SWAP_FREE_MB=$((10#$swap_free / 1024))
  SWAP_TOTAL_MB=$((10#$swap_total / 1024))
  READING=ok
}

# --- guard ------------------------------------------------------------------

action_guard() {
  case "${FM_MEMORY_GUARD:-}" in
  off)
    printf 'fm-memory: launch floor skipped (FM_MEMORY_GUARD=off)\n' >&2
    return 0
    ;;
  esac
  floors_load
  reading_load
  case "$READING" in
  unsupported) return 0 ;;
  unreadable)
    printf 'fm-memory: warning: memory could not be read (%s); launching without the memory floor\n' "$READING_PROBLEM" >&2
    return 0
    ;;
  esac
  if [ "$SPAWN_AVAILABLE_MB" -gt 0 ] && [ "$AVAILABLE_MB" -lt "$SPAWN_AVAILABLE_MB" ]; then
    printf 'error: launch refused - this host has %s MB of memory available, under the %s MB launch floor (SwapFree %s MB of %s MB). Free memory first: bin/fm-memory.sh status shows what holds it. Floors: config/memory-floor; FM_MEMORY_GUARD=off launches anyway.\n' \
      "$AVAILABLE_MB" "$SPAWN_AVAILABLE_MB" "$SWAP_FREE_MB" "$SWAP_TOTAL_MB" >&2
    return "$GUARD_REFUSE_EXIT"
  fi
  if [ "$SPAWN_SWAP_FREE_MB" -gt 0 ] && [ "$SWAP_TOTAL_MB" -gt 0 ] \
    && [ "$SWAP_FREE_MB" -lt "$SPAWN_SWAP_FREE_MB" ]; then
    printf 'error: launch refused - this host has %s MB of swap free of %s MB, under the %s MB launch floor (MemAvailable %s MB). Free memory first: bin/fm-memory.sh status shows what holds it. Floors: config/memory-floor; FM_MEMORY_GUARD=off launches anyway.\n' \
      "$SWAP_FREE_MB" "$SWAP_TOTAL_MB" "$SPAWN_SWAP_FREE_MB" "$AVAILABLE_MB" >&2
    return "$GUARD_REFUSE_EXIT"
  fi
  return 0
}

# --- processes --------------------------------------------------------------

# One line per process: "<rss-kB> <pid> <comm>", largest first.
process_table() {
  ps -eo rss=,pid=,comm= 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { print $1, $2, $3 }' | sort -rn
}

process_cwd() { # <pid>
  readlink "$PROC_ROOT/$1/cwd" 2>/dev/null || true
}

largest_summary() { # <count>
  local count=$1 rss pid comm cwd out="" n=0
  while read -r rss pid comm; do
    [ -n "$pid" ] || continue
    [ "$n" -lt "$count" ] || break
    cwd=$(process_cwd "$pid")
    out="$out${out:+, }$comm $((rss / 1024)) MB${cwd:+ in $cwd}"
    n=$((n + 1))
  done <<EOF
$(process_table)
EOF
  printf '%s' "$out"
}

# --- check ------------------------------------------------------------------

action_check() {
  local recover line largest
  floors_load
  reading_load
  [ "$READING" = ok ] || return 0
  [ "$ALERT_AVAILABLE_MB" -gt 0 ] || {
    rm -f -- "$RECORD" 2>/dev/null || true
    return 0
  }
  recover=$((ALERT_AVAILABLE_MB + ALERT_AVAILABLE_MB / 4))
  if [ "$AVAILABLE_MB" -ge "$recover" ]; then
    rm -f -- "$RECORD" 2>/dev/null || true
    return 0
  fi
  [ "$AVAILABLE_MB" -lt "$ALERT_AVAILABLE_MB" ] || return 0
  # Already reported, and not yet recovered: the episode is still the same one.
  [ ! -e "$RECORD" ] || return 0
  largest=$(largest_summary 3)
  line="memory low: $AVAILABLE_MB MB available, under the $ALERT_AVAILABLE_MB MB floor (SwapFree $SWAP_FREE_MB MB of $SWAP_TOTAL_MB MB)${largest:+; largest: $largest}; see bin/fm-memory.sh status"
  # Report before recording: a run killed between the two repeats the line once,
  # where the other order would record an episode nobody was told about.
  printf '%s\n' "$line"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  (umask 077 && printf '%s\n%s\n' "$(date +%s)" "$line" >"$RECORD.$$" && mv -f -- "$RECORD.$$" "$RECORD") 2>/dev/null \
    || rm -f -- "$RECORD.$$" 2>/dev/null || true
  return 0
}

# --- arm / disarm -----------------------------------------------------------

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory.
shim_content() { # <home>
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-memory.sh - low-memory poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$1")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-memory.sh") check"
}

ARM_TMP=

# An unregistered shim is not inert: the watcher rejects it on every cycle. So a
# failed or interrupted arm leaves no shim at all, and the home is plainly not
# armed.
arm_rollback() {
  [ -z "$ARM_TMP" ] || rm -f -- "$ARM_TMP"
  ARM_TMP=
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
}

# shellcheck disable=SC2329  # Registered by action_arm's signal trap.
arm_interrupted() {
  arm_rollback
  printf 'fm-memory: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local home device want
  mkdir -p "$STATE" || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || {
    printf 'fm-memory: state directory %s is unavailable\n' "$STATE" >&2
    return 1
  }
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
    printf 'fm-memory: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
    return 1
  }
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || {
    printf 'fm-memory: %s is not a plain file this home owns\n' "$CHECK_SHIM" >&2
    return 1
  }
  want=$(shim_content "$home")
  trap arm_interrupted HUP INT TERM
  ARM_TMP=$(umask 077 && mktemp "$STATE/.fm-memory-check.XXXXXX" 2>/dev/null) || {
    trap - HUP INT TERM
    printf 'fm-memory: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  }
  if ! printf '%s\n' "$want" >"$ARM_TMP" || ! chmod 0700 "$ARM_TMP" || ! mv -f -- "$ARM_TMP" "$CHECK_SHIM"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-memory: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  ARM_TMP=
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$STATE" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-memory: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

# --- status -----------------------------------------------------------------

meta_field() { # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-
}

action_status() {
  local meta id root roots rss pid comm cwd owner n=0 table
  local -a ids=() id_roots=() id_rss=() id_count=()
  floors_load
  reading_load
  case "$READING" in
  ok)
    printf 'memory: %s MB available, swap %s MB free of %s MB\n' "$AVAILABLE_MB" "$SWAP_FREE_MB" "$SWAP_TOTAL_MB"
    ;;
  unsupported)
    printf 'memory: this host has no /proc/meminfo, so nothing here is measured\n'
    return 0
    ;;
  *) printf 'memory: unreadable (%s)\n' "$READING_PROBLEM" ;;
  esac
  printf 'floors: launch %s MB available and %s MB swap free, alert %s MB available, job cap %s MB\n' \
    "$SPAWN_AVAILABLE_MB" "$SPAWN_SWAP_FREE_MB" "$ALERT_AVAILABLE_MB" "$JOB_MAX_MB"
  if [ -e "$RECORD" ]; then
    printf 'alert: a low-memory episode is open and already reported\n'
  fi
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    roots=
    for root in "$(meta_field "$meta" worktree)" "$(meta_field "$meta" tasktmp)" "$DATA/$id"; do
      [ -n "$root" ] && [ -d "$root" ] || continue
      root=$(CDPATH='' cd -- "$root" 2>/dev/null && pwd -P) || continue
      roots="$roots$root"$'\n'
    done
    ids+=("$id")
    id_roots+=("$roots")
    id_rss+=(0)
    id_count+=(0)
  done
  table=$(process_table)
  printf 'outside any task (largest):\n'
  while read -r rss pid comm; do
    [ -n "$pid" ] || continue
    cwd=$(process_cwd "$pid")
    owner=
    if [ -n "$cwd" ]; then
      for i in "${!ids[@]}"; do
        while IFS= read -r root; do
          [ -n "$root" ] || continue
          case "$cwd" in "$root" | "$root"/*)
            owner=$i
            break
            ;;
          esac
        done <<EOF
${id_roots[$i]}
EOF
        [ -z "$owner" ] || break
      done
    fi
    if [ -n "$owner" ]; then
      id_rss[owner]=$((id_rss[owner] + rss))
      id_count[owner]=$((id_count[owner] + 1))
    elif [ "$n" -lt 8 ]; then
      printf '  %6s MB  pid %s  %s%s\n' "$((rss / 1024))" "$pid" "$comm" "${cwd:+  in $cwd}"
      n=$((n + 1))
    fi
  done <<EOF
$table
EOF
  printf 'per task (resident memory of processes working inside the task):\n'
  [ "${#ids[@]}" -gt 0 ] || printf '  no task records in this home\n'
  for i in "${!ids[@]}"; do
    printf '  %6s MB  %s process(es)  %s\n' "$((id_rss[i] / 1024))" "${id_count[i]}" "${ids[$i]}"
  done
}

# --- run --------------------------------------------------------------------

action_run() {
  local max="" systemd_run
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --max-mb)
      [ "$#" -ge 2 ] || die_usage "--max-mb needs a value"
      max=$2
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *) die_usage "run: expected --max-mb <megabytes> or -- before the command, got '$1'" ;;
    esac
  done
  [ "$#" -gt 0 ] || die_usage "run needs a command after --"
  floors_load
  [ -n "$max" ] || max=$JOB_MAX_MB
  case "$max" in '' | *[!0-9]*) die_usage "run: --max-mb must be a whole number of megabytes" ;; esac
  [ "${#max}" -le 9 ] || die_usage "run: --max-mb is megabytes"
  if [ "$max" -eq 0 ]; then
    printf 'fm-memory: warning: the job cap is 0, so this job runs with no memory cap\n' >&2
    exec "$@"
  fi
  systemd_run=${FM_MEMORY_SYSTEMD_RUN:-systemd-run}
  if command -v "$systemd_run" >/dev/null 2>&1 \
    && "$systemd_run" --user --scope --quiet --collect -- true >/dev/null 2>&1; then
    exec "$systemd_run" --user --scope --quiet --collect \
      -p "MemoryMax=${max}M" -p MemorySwapMax=0 -- "$@"
  fi
  printf 'fm-memory: warning: no systemd user manager answered, so this job runs with no memory cap\n' >&2
  exec "$@"
}

case "${1:-check}" in
check) action_check ;;
guard) action_guard ;;
arm) action_arm ;;
disarm) action_disarm ;;
status) action_status ;;
run)
  shift
  action_run "$@"
  ;;
-h | --help) usage ;;
*) die_usage "unknown action: $1" ;;
esac
