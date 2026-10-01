#!/usr/bin/env bash
# fm-memory.sh - keep one machine's fleet inside its memory and its disk.
#
# Usage:
#   fm-memory.sh guard             refuse (exit 3) when this host is under a launch floor
#   fm-memory.sh [check]           print one line when memory first drops under the alert floor
#   fm-memory.sh disk-check        print one line when the host disk first drops under its alert floor
#   fm-memory.sh arm [--missing]   write and register state/memory.check.sh and state/disk.check.sh
#   fm-memory.sh disarm            remove both check shims, their trust bindings, and the episode records
#   fm-memory.sh status            the readings, the floors, and memory held per task
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
#   spawn_host_disk_free_mb (10240)  `guard` refuses under this much free space
#                                on the host disk
#   alert_host_disk_free_mb (20480)  `disk-check` reports under this much free
#                                space on the host disk
# docs/configuration.md "Memory guard" owns how those defaults were sized and
# the operating rules that go with them.
#
# The disk reading is free space, from df, of the root disk and of the host
# disk. The host disk exists only where this machine is a virtual machine whose
# own disk is a file on another machine's disk: under WSL, detected from the
# kernel's own release string or its WSLInterop registration and never from a
# machine name, it is the Windows drive mounted at /mnt/c (FM_DISK_HOST_PATH
# replaces the mount). When that drive fills, the virtual disk cannot grow and
# the whole machine goes down with every worker on it, whatever the memory
# reading says. Only the host disk is judged; the root disk is reported.
# Everywhere else there is no host disk, so nothing disk-related is judged,
# armed, or reported as low. A host disk that should be there but cannot be read
# never blocks anything, exactly like an unparseable memory reading.
# FM_DISKINFO_PATH replaces the live reading with a file holding
# `RootAvailable: <n> kB` and `HostAvailable: <n> kB` lines, mainly for tests.
#
# guard: exit 0 when a launch may proceed, exit 3 with one diagnostic line
# naming the reading and the floor when it may not. It judges memory, then the
# host disk. FM_MEMORY_GUARD=off and FM_DISK_GUARD=off are the explicit
# overrides, one per reading: each skips its own floor and says so on stderr.
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
# disk-check: the same contract and the same episode mechanics for the host
# disk, recorded in state/.disk-low. Its line names the free space, the floor,
# and the three largest of the places it can size cheaply: the WSL crash-dump
# folder and each data/<task-id>/ directory of this home.
#
# arm: registers one shim per notification this host has a reading for, so a
# machine with no host disk gets no disk shim. --missing writes only a shim
# that does not exist yet and never rewrites one that does, which is what
# bin/fm-bootstrap.sh runs at every locked session start. A notification is
# silenced by setting its alert floor to 0, not by disarming.
#
# status: read-only. Prints both readings, the floors, and the size of the WSL
# crash-dump folder when there is one. Sums resident memory of the processes whose working
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
# The job `run` wraps keeps the caller's own locale; the forced C below is for
# this script's own parsing, so the caller's value is kept to restore around
# the exec.
CALLER_LC_ALL=${LC_ALL-}
CALLER_LC_ALL_SET=0
[ -z "${LC_ALL+x}" ] || CALLER_LC_ALL_SET=1
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/memory-floor"
MEMINFO="${FM_MEMINFO_PATH:-/proc/meminfo}"
PROC_ROOT="${FM_PROC_ROOT_OVERRIDE:-/proc}"
RECORD="$STATE/.memory-low"
DISK_RECORD="$STATE/.disk-low"
DISK_HOST_PATH="${FM_DISK_HOST_PATH:-/mnt/c}"
DISKINFO="${FM_DISKINFO_PATH:-}"
# Longest one sizing pass may take; the watcher allows a check 30 seconds.
SIZE_TIMEOUT=15
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
GUARD_REFUSE_EXIT=3

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-memory.sh guard       exit 3 with a diagnostic when this host is under a launch floor
  fm-memory.sh [check]     print one line when memory first drops under the alert floor
  fm-memory.sh disk-check  print one line when the host disk first drops under its alert floor
  fm-memory.sh arm [--missing]
                           write and register state/memory.check.sh and state/disk.check.sh;
                           --missing leaves an existing shim untouched
  fm-memory.sh disarm      remove both check shims, their trust bindings, and the episode records
  fm-memory.sh status      the readings, the floors, and memory held per task
  fm-memory.sh run [--max-mb N] -- <command> [args...]
                           run a heavy job inside its own memory-capped scope
  fm-memory.sh --help      print this help

Floors: config/memory-floor, one key=<megabytes> per line.
  spawn_available_mb (2048), spawn_swap_free_mb (512), alert_available_mb (1536), job_max_mb (4096),
  spawn_host_disk_free_mb (10240), alert_host_disk_free_mb (20480)
FM_MEMORY_GUARD=off skips the memory launch floor for one command; FM_DISK_GUARD=off skips the disk one.
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
SPAWN_HOST_DISK_FREE_MB=10240
ALERT_HOST_DISK_FREE_MB=20480

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
    spawn_host_disk_free_mb) SPAWN_HOST_DISK_FREE_MB=$value ;;
    alert_host_disk_free_mb) ALERT_HOST_DISK_FREE_MB=$value ;;
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

# kb_field <label>: reads a meminfo-shaped text on stdin and prints
# "<value>|<unit>|<times the label appeared>" for that label.
kb_field() {
  awk -v want="$1:" '$1 == want { v = $2; u = $3; n++ } END { printf "%s|%s|%d\n", v, u, n + 0 }' 2>/dev/null
}

reading_load() {
  local available swap_free swap_total au an fu fn tu tn
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
  IFS='|' read -r available au an <<EOF
$(kb_field MemAvailable <"$MEMINFO")
EOF
  IFS='|' read -r swap_free fu fn <<EOF
$(kb_field SwapFree <"$MEMINFO")
EOF
  IFS='|' read -r swap_total tu tn <<EOF
$(kb_field SwapTotal <"$MEMINFO")
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

# --- disk reading -----------------------------------------------------------

# True on a WSL machine, judged from the kernel's own identity.
host_is_wsl() {
  local release
  [ ! -e "$PROC_ROOT/sys/fs/binfmt_misc/WSLInterop" ] || return 0
  [ ! -e "$PROC_ROOT/sys/fs/binfmt_misc/WSLInterop-late" ] || return 0
  release=$(cat "$PROC_ROOT/sys/kernel/osrelease" 2>/dev/null) || return 1
  case "$release" in *[Mm]icrosoft* | *WSL*) return 0 ;; esac
  return 1
}

# True where this machine has a host disk to read at all.
host_disk_expected() {
  [ -n "$DISKINFO" ] || host_is_wsl
}

# bounded <command...>: a filesystem walk must not outlast the watcher's check
# timeout, so it is cut short where the host has `timeout`.
bounded() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$SIZE_TIMEOUT" "$@"
  else
    "$@"
  fi
}

df_available_kb() { # <path>
  bounded df -Pk -- "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

# disk_reading_load sets DISK_READING to one of:
#   ok           ROOT_FREE_MB and HOST_FREE_MB are set, either one empty when
#                this machine has no such disk to read
#   unreadable   a reading that should exist cannot be trusted;
#                DISK_READING_PROBLEM says why
DISK_READING=
DISK_READING_PROBLEM=
ROOT_FREE_MB=
HOST_FREE_MB=

disk_reading_load() {
  local text root host ru rn hu hn kb
  DISK_READING=unreadable
  DISK_READING_PROBLEM=
  ROOT_FREE_MB=
  HOST_FREE_MB=
  if [ -n "$DISKINFO" ]; then
    if [ ! -f "$DISKINFO" ] || [ ! -r "$DISKINFO" ]; then
      DISK_READING_PROBLEM="$DISKINFO cannot be read"
      return 0
    fi
    text=$(cat "$DISKINFO" 2>/dev/null) || text=
    [ -n "$text" ] || {
      DISK_READING_PROBLEM="$DISKINFO is empty"
      return 0
    }
  else
    text=
    kb=$(df_available_kb /)
    [ -z "$kb" ] || text="RootAvailable: $kb kB"
    if host_is_wsl; then
      kb=$(df_available_kb "$DISK_HOST_PATH")
      [ -n "$kb" ] || {
        DISK_READING_PROBLEM="the host disk at $DISK_HOST_PATH did not answer df"
        return 0
      }
      text="$text"$'\n'"HostAvailable: $kb kB"
    fi
  fi
  IFS='|' read -r root ru rn <<EOF
$(printf '%s\n' "$text" | kb_field RootAvailable)
EOF
  IFS='|' read -r host hu hn <<EOF
$(printf '%s\n' "$text" | kb_field HostAvailable)
EOF
  if [ -n "$DISKINFO" ] && [ "${rn:-0}" = 0 ] && [ "${hn:-0}" = 0 ]; then
    DISK_READING_PROBLEM="$DISKINFO has no RootAvailable or HostAvailable line"
    return 0
  fi
  if [ "${rn:-0}" != 0 ]; then
    if [ "$rn" != 1 ] || [ "${ru:-}" != kB ]; then
      DISK_READING_PROBLEM="the disk reading has no single RootAvailable line in kB"
      return 0
    fi
    case "$root" in '' | *[!0-9]*)
      DISK_READING_PROBLEM="the disk reading reports RootAvailable as '$root'"
      return 0
      ;;
    esac
  fi
  if [ "${hn:-0}" != 0 ]; then
    if [ "$hn" != 1 ] || [ "${hu:-}" != kB ]; then
      DISK_READING_PROBLEM="the disk reading has no single HostAvailable line in kB"
      return 0
    fi
    case "$host" in '' | *[!0-9]*)
      DISK_READING_PROBLEM="the disk reading reports HostAvailable as '$host'"
      return 0
      ;;
    esac
  fi
  [ "${#root}" -le 15 ] && [ "${#host}" -le 15 ] || {
    DISK_READING_PROBLEM="the disk reading reports a value too large to be a disk size"
    return 0
  }
  [ "${rn:-0}" = 0 ] || ROOT_FREE_MB=$((10#$root / 1024))
  [ "${hn:-0}" = 0 ] || HOST_FREE_MB=$((10#$host / 1024))
  DISK_READING=ok
}

# --- guard ------------------------------------------------------------------

action_guard() {
  local rc=0
  floors_load
  memory_guard || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  disk_guard
}

disk_guard() {
  host_disk_expected || return 0
  case "${FM_DISK_GUARD:-}" in
  off)
    printf 'fm-memory: disk launch floor skipped (FM_DISK_GUARD=off)\n' >&2
    return 0
    ;;
  esac
  disk_reading_load
  if [ "$DISK_READING" != ok ]; then
    printf 'fm-memory: warning: disk space could not be read (%s); launching without the disk floor\n' "$DISK_READING_PROBLEM" >&2
    return 0
  fi
  [ -n "$HOST_FREE_MB" ] || return 0
  if [ "$SPAWN_HOST_DISK_FREE_MB" -gt 0 ] && [ "$HOST_FREE_MB" -lt "$SPAWN_HOST_DISK_FREE_MB" ]; then
    printf 'error: launch refused - the host disk (%s) has %s MB free, under the %s MB launch floor (root disk %s MB free). When that disk fills, this whole machine goes down. Free space on it first: bin/fm-memory.sh status shows both readings and the crash-dump folder. Floors: config/memory-floor; FM_DISK_GUARD=off launches anyway.\n' \
      "$DISK_HOST_PATH" "$HOST_FREE_MB" "$SPAWN_HOST_DISK_FREE_MB" "${ROOT_FREE_MB:-unknown}" >&2
    return "$GUARD_REFUSE_EXIT"
  fi
  return 0
}

memory_guard() {
  case "${FM_MEMORY_GUARD:-}" in
  off)
    printf 'fm-memory: launch floor skipped (FM_MEMORY_GUARD=off)\n' >&2
    return 0
    ;;
  esac
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

# episode_opens <record> <reading> <floor>: exit 0 exactly when this reading
# opens a new episode the caller must report. A floor of 0, or a reading back
# at the floor plus a quarter, closes the episode; anything in between, or an
# episode already on record, is silence.
episode_opens() {
  local record=$1 reading=$2 floor=$3
  [ "$floor" -gt 0 ] || {
    rm -f -- "${record:?}" 2>/dev/null || true
    return 1
  }
  if [ "$reading" -ge $((floor + floor / 4)) ]; then
    rm -f -- "${record:?}" 2>/dev/null || true
    return 1
  fi
  [ "$reading" -lt "$floor" ] || return 1
  # Already reported, and not yet recovered: the episode is still the same one.
  [ ! -e "$record" ]
}

# episode_report <record> <line>: report before recording, because a run killed
# between the two repeats the line once, where the other order would record an
# episode nobody was told about.
episode_report() {
  local record=$1 line=$2 tmp
  printf '%s\n' "$line"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  tmp="${record:?}.$$"
  (umask 077 && printf '%s\n%s\n' "$(date +%s)" "$line" >"$tmp" && mv -f -- "$tmp" "$record") 2>/dev/null \
    || rm -f -- "${tmp:?}" 2>/dev/null || true
  return 0
}

action_check() {
  local largest
  floors_load
  reading_load
  [ "$READING" = ok ] || return 0
  episode_opens "$RECORD" "$AVAILABLE_MB" "$ALERT_AVAILABLE_MB" || return 0
  largest=$(largest_summary 3)
  episode_report "$RECORD" "memory low: $AVAILABLE_MB MB available, under the $ALERT_AVAILABLE_MB MB floor (SwapFree $SWAP_FREE_MB MB of $SWAP_TOTAL_MB MB)${largest:+; largest: $largest}; see bin/fm-memory.sh status"
}

# The WSL crash-dump folder on the host disk, when this machine has one: every
# process that aborts under WSL is written there whole.
crash_dump_dir() {
  local dir
  host_disk_expected || return 0
  for dir in "$DISK_HOST_PATH"/Users/*/AppData/Local/Temp/wsl-crashes; do
    [ -d "$dir" ] || continue
    printf '%s\n' "$dir"
    return 0
  done
}

path_size_mb() { # <path>
  local kb
  kb=$(bounded du -sk -- "$1" 2>/dev/null | awk 'NR == 1 { print $1 }')
  case "$kb" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s\n' "$((kb / 1024))"
}

# The largest of the places that can be sized without walking a whole disk: the
# crash-dump folder and this home's per-task data directories.
disk_largest_summary() { # <count>
  local crash dir
  local -a places=()
  crash=$(crash_dump_dir)
  [ -z "$crash" ] || places+=("$crash")
  for dir in "$DATA"/*/; do
    [ -d "$dir" ] && [ ! -L "${dir%/}" ] || continue
    places+=("${dir%/}")
  done
  [ "${#places[@]}" -gt 0 ] || return 0
  bounded du -sk -- "${places[@]}" 2>/dev/null \
    | sort -rn | awk -v count="$1" -F '\t' '
      $1 ~ /^[0-9]+$/ && $1 >= 1024 && n < count {
        out = out (n ? ", " : "") $2 " " int($1 / 1024) " MB"
        n++
      }
      END { printf "%s", out }'
}

action_disk_check() {
  local largest
  floors_load
  host_disk_expected || return 0
  disk_reading_load
  [ "$DISK_READING" = ok ] && [ -n "$HOST_FREE_MB" ] || return 0
  episode_opens "$DISK_RECORD" "$HOST_FREE_MB" "$ALERT_HOST_DISK_FREE_MB" || return 0
  largest=$(disk_largest_summary 3)
  episode_report "$DISK_RECORD" "disk low: the host disk ($DISK_HOST_PATH) has $HOST_FREE_MB MB free, under the $ALERT_HOST_DISK_FREE_MB MB floor (root disk ${ROOT_FREE_MB:-unknown} MB free)${largest:+; largest: $largest}; this machine goes down when that disk fills; see bin/fm-memory.sh status"
}

# --- arm / disarm -----------------------------------------------------------

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory.
shim_content() { # <home> <label> <action>
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    "# Auto-generated by fm-memory.sh - $2 poll shim." \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$1")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-memory.sh") $3"
}

ARM_TMP=
ARM_ID=

# An unregistered shim is not inert: the watcher rejects it on every cycle. So a
# failed or interrupted arm leaves no shim at all, and the home is plainly not
# armed.
arm_rollback() {
  [ -z "$ARM_TMP" ] || rm -f -- "${ARM_TMP:?}"
  ARM_TMP=
  [ -z "$ARM_ID" ] || rm -f -- "${STATE:?}/${ARM_ID:?}.check.sh" "${STATE:?}/${ARM_ID:?}.check-trust"
}

# shellcheck disable=SC2329  # Registered by arm_one's signal trap.
arm_interrupted() {
  arm_rollback
  printf 'fm-memory: arming was interrupted, so state/%s.check.sh is not armed\n' "$ARM_ID" >&2
  exit 1
}

arm_one() { # <check-id> <label> <action> <home> <missing-only>
  local id=$1 label=$2 action=$3 home=$4 missing=$5 shim device want
  shim="$STATE/$id.check.sh"
  if [ "$missing" = 1 ] && { [ -e "$shim" ] || [ -L "$shim" ]; }; then
    return 0
  fi
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$shim" "$device" || {
    printf 'fm-memory: %s is not a plain file this home owns\n' "$shim" >&2
    return 1
  }
  want=$(shim_content "$home" "$label" "$action")
  trap arm_interrupted HUP INT TERM
  ARM_TMP=$(umask 077 && mktemp "$STATE/.fm-memory-check.XXXXXX" 2>/dev/null) || {
    trap - HUP INT TERM
    printf 'fm-memory: could not write %s\n' "$shim" >&2
    return 1
  }
  ARM_ID=$id
  if ! printf '%s\n' "$want" >"$ARM_TMP" || ! chmod 0700 "$ARM_TMP" || ! mv -f -- "$ARM_TMP" "$shim"; then
    trap - HUP INT TERM
    arm_rollback
    ARM_ID=
    printf 'fm-memory: could not write %s\n' "$shim" >&2
    return 1
  fi
  ARM_TMP=
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$STATE" "$REGISTER_BIN" "$id" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    ARM_ID=
    printf 'fm-memory: could not register %s\n' "$shim" >&2
    return 1
  fi
  trap - HUP INT TERM
  ARM_ID=
  printf 'armed: state/%s.check.sh\n' "$id"
}

action_arm() {
  local home missing=0 rc=0
  case "${1:-}" in
  '') ;;
  --missing) missing=1 ;;
  *) die_usage "arm: unknown option '$1'" ;;
  esac
  mkdir -p "$STATE" || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || {
    printf 'fm-memory: state directory %s is unavailable\n' "$STATE" >&2
    return 1
  }
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
    printf 'fm-memory: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
    return 1
  }
  # --missing arms only what this host can read; a plain arm keeps arming the
  # memory check wherever it is asked to, as it always has.
  if [ "$missing" = 0 ] || [ -e "$MEMINFO" ]; then
    arm_one memory low-memory check "$home" "$missing" || rc=1
  fi
  if host_disk_expected; then
    arm_one disk low-disk disk-check "$home" "$missing" || rc=1
  fi
  return "$rc"
}

action_disarm() {
  rm -f -- "${STATE:?}/memory.check.sh" "${STATE:?}/memory.check-trust" "${RECORD:?}" \
    "${STATE:?}/disk.check.sh" "${STATE:?}/disk.check-trust" "${DISK_RECORD:?}"
  printf 'disarmed: state/memory.check.sh state/disk.check.sh\n'
}

# --- status -----------------------------------------------------------------

meta_field() { # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-
}

disk_status() {
  local crash size
  disk_reading_load
  if [ "$DISK_READING" != ok ]; then
    printf 'disk: unreadable (%s)\n' "$DISK_READING_PROBLEM"
  elif [ -n "$HOST_FREE_MB" ]; then
    printf 'disk: host disk (%s) %s MB free, root disk %s MB free\n' "$DISK_HOST_PATH" "$HOST_FREE_MB" "${ROOT_FREE_MB:-unknown}"
  else
    printf 'disk: root disk %s MB free; this machine has no host disk to read\n' "${ROOT_FREE_MB:-unknown}"
    return 0
  fi
  printf 'disk floors: launch %s MB free on the host disk, alert %s MB free on the host disk\n' \
    "$SPAWN_HOST_DISK_FREE_MB" "$ALERT_HOST_DISK_FREE_MB"
  crash=$(crash_dump_dir)
  if [ -n "$crash" ]; then
    if size=$(path_size_mb "$crash"); then
      printf 'wsl crash dumps: %s MB in %s\n' "$size" "$crash"
    else
      printf 'wsl crash dumps: %s could not be sized\n' "$crash"
    fi
  fi
  if [ -e "$DISK_RECORD" ]; then
    printf 'alert: a low-disk episode is open and already reported\n'
  fi
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
  disk_status
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
    if [ -n "$cwd" ] && [ "${#ids[@]}" -gt 0 ]; then
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
  if [ "${#ids[@]}" -gt 0 ]; then
    for i in "${!ids[@]}"; do
      printf '  %6s MB  %s process(es)  %s\n' "$((id_rss[i] / 1024))" "${id_count[i]}" "${ids[$i]}"
    done
  else
    printf '  no task records in this home\n'
  fi
}

# --- run --------------------------------------------------------------------

# The wrapped job gets the locale it would have had outside this wrapper: the
# script's own C is only for the parsing above, which is done by now.
exec_job() {
  if [ "$CALLER_LC_ALL_SET" = 1 ]; then
    export LC_ALL="$CALLER_LC_ALL"
  else
    unset LC_ALL
  fi
  exec "$@"
}

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
    exec_job "$@"
  fi
  systemd_run=${FM_MEMORY_SYSTEMD_RUN:-systemd-run}
  if command -v "$systemd_run" >/dev/null 2>&1 \
    && "$systemd_run" --user --scope --quiet --collect -- true >/dev/null 2>&1; then
    exec_job "$systemd_run" --user --scope --quiet --collect \
      -p "MemoryMax=${max}M" -p MemorySwapMax=0 -- "$@"
  fi
  printf 'fm-memory: warning: no systemd user manager answered, so this job runs with no memory cap\n' >&2
  exec_job "$@"
}

case "${1:-check}" in
check) action_check ;;
guard) action_guard ;;
disk-check) action_disk_check ;;
arm)
  shift
  action_arm "$@"
  ;;
disarm) action_disarm ;;
status) action_status ;;
run)
  shift
  action_run "$@"
  ;;
-h | --help) usage ;;
*) die_usage "unknown action: $1" ;;
esac
