#!/usr/bin/env bash
# Live scenario driver for the watcher-relay false-alarm change.
#
# Drives the real product surfaces:
#   - bin/fm-guard.sh (the pull guard that prints WATCHER DOWN)
#   - .pi/extensions/fm-primary-pi-watch.ts (the real Pi watcher extension, under node)
# against constructed firstmate homes, comparing HEAD with the base commit
# de0188b and the round-1 intermediate ecfd5b7.
set -u

WORK=/home/hugorl/.no-mistakes/worktrees/71308d303441/01M3AMFSK7B5JGSY2CT93WCC3Q
SCRATCH=/tmp/fm-relay-drive
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/base" "$SCRATCH/prefix" "$SCRATCH/head" "$SCRATCH/cases"
git -C "$WORK" archive de0188b -- bin | tar -x -C "$SCRATCH/base"
git -C "$WORK" archive ecfd5b7 -- bin | tar -x -C "$SCRATCH/prefix"
git -C "$WORK" archive HEAD -- bin | tar -x -C "$SCRATCH/head"
BASE="$SCRATCH/base"
PREFIX="$SCRATCH/prefix"
HEAD="$SCRATCH/head"

PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup EXIT

LIVE_PID=
live() { sleep 300 & LIVE_PID=$!; PIDS+=("$LIVE_PID"); }

CASE_DIR=
new_case() {
  local dir="$SCRATCH/cases/$1"
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/root"
  printf 'window=firstmate:fm-task\nkind=ship\n' > "$dir/home/state/task.meta"
  touch "$dir/home/state/.last-watcher-beat"
  live
  printf '%s\n' "$LIVE_PID" > "$dir/home/state/.lock"
  CASE_DIR=$dir
}

ver() { bash -c '. "$1"; fm_pi_extension_version "$2"' _ "$1/bin/fm-wake-lib.sh" "$2" 2>/dev/null; }

pi_pair() {  # <repo> <dir>
  local repo=$1 dir=$2 root="$2/root" home="$2/home" v pid
  pid=$(sed -n '1p' "$home/state/.lock")
  mkdir -p "$root/.pi/extensions"
  printf '// watch extension\n' > "$root/.pi/extensions/fm-primary-pi-watch.ts"
  printf '// turnend extension\n' > "$root/.pi/extensions/fm-primary-turnend-guard.ts"
  v=$(ver "$repo" "$root/.pi/extensions/fm-primary-pi-watch.ts")
  printf '%s\n%s\n' "$v" "$pid" > "$home/state/.pi-watch-extension-loaded"
  v=$(ver "$repo" "$root/.pi/extensions/fm-primary-turnend-guard.ts")
  printf '%s\n%s\n' "$v" "$pid" > "$home/state/.pi-turnend-extension-loaded"
}

omp_pair() {  # <repo> <dir>
  local repo=$1 dir=$2 root="$2/root" home="$2/home" v pid
  pid=$(sed -n '1p' "$home/state/.lock")
  mkdir -p "$root/.omp/extensions"
  printf '// omp watch extension\n' > "$root/.omp/extensions/fm-primary-omp-watch.ts"
  printf '// omp turnend extension\n' > "$root/.omp/extensions/fm-primary-turnend-guard.ts"
  v=$(ver "$repo" "$root/.omp/extensions/fm-primary-omp-watch.ts")
  printf '%s\n%s\n' "$v" "$pid" > "$home/state/.omp-watch-extension-loaded"
  v=$(ver "$repo" "$root/.omp/extensions/fm-primary-turnend-guard.ts")
  printf '%s\n%s\n' "$v" "$pid" > "$home/state/.omp-turnend-extension-loaded"
}

REAL_NONE_ROW='arm_pid=121788	watcher_pid=121891	origin=started	started_at=1790259225	ended_at=1790259269	exit_code=0	signal=none	reason=actionable-stale	beacon_age=43	lock_before=pid:121891|identity:linux-starttime=22788 cmdline-hex=62617368002f686f6d652f6875676f726c2f66697273746d6174652f62696e2f666d2d77617463682e736800	lock_after=pid:none|identity:none	successor=none'

write_none_row() { printf '%s\n' "$REAL_NONE_ROW" > "$1/home/state/.watch-cycle-exits.log"; }

write_relay_row() {  # <dir> <successor-pid> [recorded-identity]
  local dir=$1 pid=$2 identity=${3:-} row
  row="${REAL_NONE_ROW/successor=none/successor=started:$pid}"
  [ -z "$identity" ] || row="${row/started:$pid/started:$pid|$identity}"
  printf '%s\n' "$row" > "$dir/home/state/.watch-cycle-exits.log"
}

write_stale_watch_lock() {  # <dir> <pid>: a lock left behind by an exited predecessor watcher
  local dir=$1 pid=$2 lock
  lock="$dir/home/state/.watch.lock"
  mkdir -p "$lock"
  printf '%s\n' "$pid" > "$lock/pid"
  printf '%s\n' "$dir/home" > "$lock/fm-home"
  printf '%s\n' "$dir/root/bin/fm-watch.sh" > "$lock/watcher-path"
  printf 'linux-starttime=1 cmdline-hex=00\n' > "$lock/pid-identity"
}

arm_decl() {  # <repo> <dir> <child> <retry> [phase] [drift]
  local repo=$1 dir=$2 child=$3 retry=$4 phase=${5:-active} drift=${6:-}
  local root="$dir/root" home="$dir/home" v pid
  pid=$(sed -n '1p' "$home/state/.lock")
  if [ "$drift" = drift ]; then
    v="sha256:0000000000000000000000000000000000000000000000000000000000000000"
  else
    v=$(ver "$repo" "$root/.pi/extensions/fm-primary-pi-watch.ts")
  fi
  printf '%s\n%s\ngeneration=1 phase=%s\nchild=%s retry=%s\n' \
    "$v" "$pid" "$phase" "$child" "$retry" > "$home/state/.pi-watch-extension-arm"
}

guard() { env FM_ROOT_OVERRIDE="$2/root" FM_HOME="$2/home" FM_GUARD_GRACE=999 FM_SUPERVISION_MODEL="$3" "$1/bin/fm-guard.sh" 2>&1; }

verdict_of() { if grep -q 'WATCHER DOWN' <<<"$1"; then printf 'ALARM'; else printf 'SILENT'; fi; }

report() {  # <label> <output>
  local v
  v=$(verdict_of "$2")
  printf '%-60s -> %s\n' "$1" "$v"
  if [ "$v" = ALARM ]; then
    grep -m1 'no live watcher process holds this home lock\|no watcher has a fresh beacon' <<<"$2" | sed 's/^/        /'
  fi
}

echo "############ S1a: Pi relay window, live recorded successor, watch lock unheld ############"
for repo in HEAD PREFIX BASE; do
  eval "r=\$$repo"
  new_case "s1a-$repo"; d=$CASE_DIR
  pi_pair "$r" "$d"
  live; write_relay_row "$d" "$LIVE_PID"
  report "  $repo" "$(guard "$r" "$d" extension)"
done

echo
echo "############ S1b: Pi relay window, live recorded successor, watch lock still held by dead predecessor ############"
for repo in HEAD PREFIX BASE; do
  eval "r=\$$repo"
  new_case "s1b-$repo"; d=$CASE_DIR
  pi_pair "$r" "$d"
  live; write_relay_row "$d" "$LIVE_PID"
  dead=$(bash -c 'printf "%s" "$$"')
  write_stale_watch_lock "$d" "$dead"
  report "  $repo" "$(guard "$r" "$d" extension)"
done

echo
echo "############ S2: Pi broken chain, successor=none and no declared attempt ############"
for repo in HEAD PREFIX BASE; do
  eval "r=\$$repo"
  new_case "s2-$repo"; d=$CASE_DIR
  pi_pair "$r" "$d"
  write_none_row "$d"
  report "  $repo" "$(guard "$r" "$d" extension)"
done

echo
echo "############ S3: Pi arm declaration: live child retry=0 (the 'watcher: unchanged' state) ############"
new_case s3-head; d=$CASE_DIR; pi_pair "$HEAD" "$d"
live; arm_decl "$HEAD" "$d" "$LIVE_PID" 0
report "  HEAD live declared child" "$(guard "$HEAD" "$d" extension)"
new_case s3-base; d=$CASE_DIR; pi_pair "$BASE" "$d"
live; arm_decl "$BASE" "$d" "$LIVE_PID" 0
report "  BASE live declared child (no declaration support)" "$(guard "$BASE" "$d" extension)"

echo
echo "############ S4: Pi declaration: dead arm child with retry=1 (round-1 fix) ############"
for repo in HEAD PREFIX BASE; do
  eval "r=\$$repo"
  new_case "s4-$repo"; d=$CASE_DIR
  pi_pair "$r" "$d"
  write_none_row "$d"
  dead=$(bash -c 'printf "%s" "$$"')
  arm_decl "$r" "$d" "$dead" 1
  report "  $repo dead child retry=1" "$(guard "$r" "$d" extension)"
done

echo
echo "############ S5: declaration signals are load-bearing (adversarial) ############"
new_case s5-live-child; d=$CASE_DIR; pi_pair "$HEAD" "$d"
write_none_row "$d"
live; arm_decl "$HEAD" "$d" "$LIVE_PID" 0
report "  live child retry=0" "$(guard "$HEAD" "$d" extension)"
new_case s5-pending-retry; d=$CASE_DIR; pi_pair "$HEAD" "$d"
write_none_row "$d"
arm_decl "$HEAD" "$d" none 1
report "  child=none retry=1" "$(guard "$HEAD" "$d" extension)"
new_case s5-dead-child; d=$CASE_DIR; pi_pair "$HEAD" "$d"
write_none_row "$d"
dead=$(bash -c 'printf "%s" "$$"'); arm_decl "$HEAD" "$d" "$dead" 0
report "  dead child retry=0" "$(guard "$HEAD" "$d" extension)"
new_case s5-drift; d=$CASE_DIR; pi_pair "$HEAD" "$d"
write_none_row "$d"
arm_decl "$HEAD" "$d" none 1 active drift
report "  drifted extension build" "$(guard "$HEAD" "$d" extension)"
new_case s5-handoff; d=$CASE_DIR; pi_pair "$HEAD" "$d"
write_none_row "$d"
arm_decl "$HEAD" "$d" none 1 handoff
report "  handoff-phase generation" "$(guard "$HEAD" "$d" extension)"
new_case s5-wrong-pid; d=$CASE_DIR; pi_pair "$HEAD" "$d"
write_none_row "$d"
live; other=$LIVE_PID
arm_decl "$HEAD" "$d" none 1
sed -i "2s/.*/$other/" "$d/home/state/.pi-watch-extension-arm"
report "  declaration pid != live session lock pid" "$(guard "$HEAD" "$d" extension)"

echo
echo "############ S6: omp restoration window over an unheld lock (round-2 fix) ############"
for repo in HEAD PREFIX BASE; do
  eval "r=\$$repo"
  new_case "s6-$repo"; d=$CASE_DIR
  omp_pair "$r" "$d"
  write_none_row "$d"
  rm -rf "$d/home/state/.watch.lock"
  report "  omp $repo live session + fresh beat + successor=none + unheld lock" "$(guard "$r" "$d" extension)"
done
new_case s6-omp-held; d=$CASE_DIR; omp_pair "$HEAD" "$d"
write_none_row "$d"
dead=$(bash -c 'printf "%s" "$$"'); write_stale_watch_lock "$d" "$dead"
report "  omp HEAD held unhealthy lock + successor=none (no unheld proof)" "$(guard "$HEAD" "$d" extension)"
new_case s6-omp-down; d=$CASE_DIR; omp_pair "$HEAD" "$d"
write_none_row "$d"; rm -rf "$d/home/state/.watch.lock"
rm -f "$d/home/state/.omp-watch-extension-loaded"
report "  omp HEAD same state but marker proof removed (watcher down)" "$(guard "$HEAD" "$d" extension)"

echo
echo "############ S7: lost session origin / dead relay successor stay loud ############"
new_case s2b-pi-held; d=$CASE_DIR; pi_pair "$HEAD" "$d"
write_none_row "$d"
dead=$(bash -c 'printf "%s" "$$"'); write_stale_watch_lock "$d" "$dead"
report "  Pi HEAD held unhealthy lock + successor=none" "$(guard "$HEAD" "$d" extension)"
new_case s7-dead-session; d=$CASE_DIR; pi_pair "$HEAD" "$d"
live; write_relay_row "$d" "$LIVE_PID"
printf '%s\n' 99999999 > "$d/home/state/.lock"
report "  HEAD live successor but dead session origin" "$(guard "$HEAD" "$d" extension)"
new_case s7-dead-successor; d=$CASE_DIR; pi_pair "$HEAD" "$d"
dead=$(bash -c 'printf "%s" "$$"'); write_relay_row "$d" "$dead"
report "  HEAD recorded successor process is gone" "$(guard "$HEAD" "$d" extension)"
new_case s7-stale-identity; d=$CASE_DIR; pi_pair "$HEAD" "$d"
live; write_relay_row "$d" "$LIVE_PID" "linux-starttime=1 cmdline-hex=00"
report "  HEAD recorded successor identity no longer matches" "$(guard "$HEAD" "$d" extension)"

echo
echo "############ S8: real Pi extension -> real guard ############"
install_pi_fixture() {
  local repo=$1
  mkdir -p "$repo/.pi/extensions/lib" "$repo/bin" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-tui" "$repo/node_modules/typebox"
  cp "$WORK/.pi/extensions/fm-primary-pi-watch.ts" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$WORK/.pi/extensions/lib/"*.ts "$repo/.pi/extensions/lib/"
  cp "$WORK/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent { render() { return []; } invalidate() {} }
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box { addChild() {} clear() {} setBgFn() {} }
export class Container {}
export class Text {}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = { Object(properties) { return { type: "object", properties, additionalProperties: false }; } };
JS
}

cat > "$SCRATCH/drive-live-child.mjs" <<'JS'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const pi = {
  on() {}, registerCommand() {},
  registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") pi.tool = candidate; },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const first = await pi.tool.execute("call-live-a", {}, undefined, undefined, {});
const second = await pi.tool.execute("call-live-b", {}, undefined, undefined, {});
writeFileSync(process.env.FM_MESSAGES_FILE, `${(first.content[0]?.text ?? "").split("\n")[0]}\n${(second.content[0]?.text ?? "").split("\n")[0]}\n`);
const marker = `${process.env.FM_HOME}/state/.pi-watch-extension-arm`;
let lines = [], state = "";
for (let i = 0; i < 800; i += 1) {
  await new Promise((r) => setTimeout(r, 25));
  if (!existsSync(marker)) continue;
  lines = readFileSync(marker, "utf8").trimEnd().split("\n");
  state = lines[3] ?? "";
  if (/^child=[0-9]+ retry=0$/.test(state)) break;
}
if (!/^child=[0-9]+ retry=0$/.test(state)) throw new Error(`real extension did not declare a live child: ${state}`);
writeFileSync(process.env.FM_PHASE_FILE, `${lines[0]}|${lines[1]}|${lines[2]}|${state}\n`);
await new Promise((r) => setTimeout(r, Number(process.env.FM_HOLD_MS || "30000")));
JS

cat > "$SCRATCH/drive-retry.mjs" <<'JS'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const pi = {
  on() {}, registerCommand() {},
  registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") pi.tool = candidate; },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await pi.tool.execute("call-retry", {}, undefined, undefined, {});
const marker = `${process.env.FM_HOME}/state/.pi-watch-extension-arm`;
let lines = [], state = "";
for (let i = 0; i < 800; i += 1) {
  await new Promise((r) => setTimeout(r, 25));
  if (!existsSync(marker)) continue;
  lines = readFileSync(marker, "utf8").trimEnd().split("\n");
  state = lines[3] ?? "";
  if (state === "child=none retry=1") break;
}
if (state !== "child=none retry=1") throw new Error(`real extension did not declare a pending retry: ${state}`);
writeFileSync(process.env.FM_PHASE_FILE, `${lines[0]}|${lines[1]}|${lines[2]}|${state}\n`);
await new Promise((r) => setTimeout(r, Number(process.env.FM_HOLD_MS || "30000")));
JS

cat > "$SCRATCH/drive-live-retry-window.mjs" <<'JS'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const pi = {
  on() {}, registerCommand() {},
  registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") pi.tool = candidate; },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await pi.tool.execute("call-window", {}, undefined, undefined, {});
const marker = `${process.env.FM_HOME}/state/.pi-watch-extension-arm`;
let lines = [], state = "";
for (let i = 0; i < 800; i += 1) {
  await new Promise((r) => setTimeout(r, 25));
  if (!existsSync(marker)) continue;
  lines = readFileSync(marker, "utf8").trimEnd().split("\n");
  state = lines[3] ?? "";
  if (/^child=[0-9]+ retry=1$/.test(state)) break;
}
if (!/^child=[0-9]+ retry=1$/.test(state)) throw new Error(`restoration window was not declared: ${state}`);
const child = state.match(/^child=([0-9]+) /)[1];
try { process.kill(Number(child), 0); } catch { throw new Error(`declared restoration child ${child} is not alive`); }
writeFileSync(process.env.FM_PHASE_FILE, `${lines[0]}|${lines[1]}|${lines[2]}|${state}|child-alive\n`);
await new Promise((r) => setTimeout(r, Number(process.env.FM_HOLD_MS || "30000")));
JS

wait_phase() { local f=$1 i=0; while [ "$i" -lt 800 ]; do [ -s "$f" ] && return 0; sleep 0.05; i=$((i + 1)); done; return 1; }

track_marker_child() {  # <dir>: register the extension's declared arm child for cleanup
  local child
  child=$(sed -n '4p' "$1/home/state/.pi-watch-extension-arm" 2>/dev/null | sed -n 's/^child=\([0-9][0-9]*\) retry=.*/\1/p')
  [ -n "$child" ] && PIDS+=("$child")
}

# S8a: real extension declares a live arm child (retry=0) -> guard silent
new_case s8a; d=$CASE_DIR; root="$d/root"; home="$d/home"
install_pi_fixture "$root"
cat > "$root/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "${FM_STOP_FILE:?}" ]; do sleep 0.05; done
SH
chmod +x "$root/bin/fm-watch-arm.sh"
FM_STOP_FILE="$d/stop" FM_PHASE_FILE="$d/phase" FM_MESSAGES_FILE="$d/messages" FM_HOLD_MS=30000 PLUGIN="$root/.pi/extensions/fm-primary-pi-watch.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_CONFIG_OVERRIDE="$home/config" node --input-type=module < "$SCRATCH/drive-live-child.mjs" > "$d/node.out" 2>&1 &
nodepid=$!; PIDS+=("$nodepid")
if wait_phase "$d/phase"; then echo "  real extension declaration: $(cat "$d/phase")"; else echo "  real extension never declared a live child"; cat "$d/node.out"; fi
[ -s "$d/messages" ] && sed 's/^/  fm_watch_arm_pi: /' "$d/messages"
report "  guard against the real extension's live-child state" "$(guard "$HEAD" "$d" extension)"
track_marker_child "$d"
touch "$d/stop"; kill "$nodepid" 2>/dev/null || true; wait "$nodepid" 2>/dev/null || true

# S8b: real extension declares a scheduled retry (child=none retry=1) -> guard silent
new_case s8b; d=$CASE_DIR; root="$d/root"; home="$d/home"
install_pi_fixture "$root"
cat > "$root/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
sleep 0.2
exit 0
SH
chmod +x "$root/bin/fm-watch-arm.sh"
FM_PHASE_FILE="$d/phase" FM_HOLD_MS=30000 FM_WATCH_REARM_RETRY_BASE_MS=60000 FM_WATCH_REARM_RETRY_MAX_MS=60000 \
  PLUGIN="$root/.pi/extensions/fm-primary-pi-watch.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_CONFIG_OVERRIDE="$home/config" \
  node --input-type=module < "$SCRATCH/drive-retry.mjs" > "$d/node.out" 2>&1 &
nodepid=$!; PIDS+=("$nodepid")
if wait_phase "$d/phase"; then echo "  real extension declaration: $(cat "$d/phase")"; else echo "  real extension never declared a pending retry"; cat "$d/node.out"; fi
report "  guard against the real extension's pending-retry state" "$(guard "$HEAD" "$d" extension)"
track_marker_child "$d"
kill "$nodepid" 2>/dev/null || true; wait "$nodepid" 2>/dev/null || true

# S8c: real extension's restoration window declares a LIVE child with retry=1
new_case s8c; d=$CASE_DIR; root="$d/root"; home="$d/home"
install_pi_fixture "$root"
cat > "$root/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ ! -e "${FM_COUNTER:?}" ]; then
  : > "$FM_COUNTER"
  printf 'signal: relay-driver-close\n'
  exit 0
fi
i=0; while [ "$i" -lt 1200 ]; do sleep 0.05; i=$((i + 1)); done
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while :; do sleep 0.05; done
SH
chmod +x "$root/bin/fm-watch-arm.sh"
FM_COUNTER="$d/counter" FM_PHASE_FILE="$d/phase" FM_HOLD_MS=30000 \
  FM_PI_ARM_READY_TIMEOUT_MS=60000 FM_WATCH_REARM_RETRY_BASE_MS=60000 FM_WATCH_REARM_RETRY_MAX_MS=60000 \
  PLUGIN="$root/.pi/extensions/fm-primary-pi-watch.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_CONFIG_OVERRIDE="$home/config" \
  node --input-type=module < "$SCRATCH/drive-live-retry-window.mjs" > "$d/node.out" 2>&1 &
nodepid=$!; PIDS+=("$nodepid")
if wait_phase "$d/phase"; then echo "  real extension declaration: $(cat "$d/phase")"; else echo "  real extension never exposed the live-child retry window"; cat "$d/node.out"; fi
report "  guard inside the real restoration window (live child, retry=1)" "$(guard "$HEAD" "$d" extension)"
report "  BASE (pre-change code) inside that same window" "$(guard "$BASE" "$d" extension)"
track_marker_child "$d"
kill "$nodepid" 2>/dev/null || true; wait "$nodepid" 2>/dev/null || true

echo
echo "############ S10: the wake-drain turn (fm-wake-drain.sh) inherits the same verdict ############"
drain() { env FM_ROOT_OVERRIDE="$2/root" FM_HOME="$2/home" FM_STATE_OVERRIDE="$2/home/state" FM_SUPERVISION_MODEL=extension "$1/bin/fm-wake-drain.sh" 2>&1; }
new_case s10-relay; d=$CASE_DIR; pi_pair "$HEAD" "$d"
live; write_relay_row "$d" "$LIVE_PID"
report "  drain in a Pi relay window" "$(drain "$HEAD" "$d")"
new_case s10-broken; d=$CASE_DIR; pi_pair "$HEAD" "$d"
write_none_row "$d"
report "  drain on a broken chain (successor=none)" "$(drain "$HEAD" "$d")"
new_case s10-omp; d=$CASE_DIR; omp_pair "$HEAD" "$d"
write_none_row "$d"; rm -rf "$d/home/state/.watch.lock"
report "  drain in the omp restoration window" "$(drain "$HEAD" "$d")"

echo
echo "############ S9: stale beacon keeps alarming even with relay evidence ############"
new_case s9-stale-beacon; d=$CASE_DIR; pi_pair "$HEAD" "$d"
live; write_relay_row "$d" "$LIVE_PID"
touch -t 202001010000 "$d/home/state/.last-watcher-beat"
report "  HEAD live ledger successor but stale beacon" "$(guard "$HEAD" "$d" extension)"

echo
echo "done"
