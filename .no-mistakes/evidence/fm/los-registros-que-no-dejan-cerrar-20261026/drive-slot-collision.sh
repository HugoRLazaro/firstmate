#!/usr/bin/env bash
# Drives bin/fm-teardown.sh (real script) on an isolated FM_HOME with a real git
# worktree as the Treehouse pool slot; only tmux/treehouse binaries are logged stubs.
# Usage: drive-slot-collision.sh <firstmate-root> <tmpdir>
set -u
ROOT=$1 T=$2
TEARDOWN="$ROOT/bin/fm-teardown.sh"
mkcase() {
  local d=$T/$1; rm -rf "$d"; mkdir -p "$d/home/state" "$d/home/data" "$d/home/config" "$d/fakebin" "$d/project" "$d/pool/1"
  git init -q "$d/project"
  git -C "$d/project" -c user.name=t -c user.email=t@e.invalid commit --allow-empty -qm fixture
  git -C "$d/project" worktree add -q --detach "$d/pool/1/project"
  ln -s pool/1/project "$d/worktree"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$d/pool/1/project" > "$d/pool/treehouse-state.json"
  : > "$d/worktree/sentinel"; : > "$d/runtime.log"
  for b in tmux treehouse; do printf '#!/usr/bin/env bash\nprintf "%s" >> "$FM_RUNTIME_LOG"; printf " <%%s>" "$@" >> "$FM_RUNTIME_LOG"; printf "\\n" >> "$FM_RUNTIME_LOG"\n' $b > "$d/fakebin/$b"; chmod +x "$d/fakebin/$b"; done
  for id in stale-task holder-task; do
    printf '%s\n' "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$d/worktree" "project=$d/project" "kind=scout" > "$d/home/state/$id.meta"
  done
  echo "$d"
}
run() { local d=$1; shift; echo "\$ fm-teardown.sh $*"; FM_GATE_REFUSE_BYPASS=1 FM_HOME="$d/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$d/runtime.log" PATH="$d/fakebin:$PATH" "$TEARDOWN" "$@" 2>&1; echo "[exit=$?]"; }
show() { local d=$1; echo "  state/: $(ls "$d/home/state" | tr '\n' ' ')"; echo "  slot sentinel: $([ -e "$d/pool/1/project/sentinel" ] && echo present || echo GONE)"; echo "  slot claim: $(tr "\n" " " 2>/dev/null < "$d/pool/1/.fm-slot-owner" || echo none)"; echo "  runtime calls: $(grep -c . "$d/runtime.log") $(grep -o 'treehouse <return>' "$d/runtime.log" | head -1)"; }

echo "=== S1: claim names holder-task; teardown of the STALE record ==="
d=$(mkcase s1); printf 'task=holder-task\nhome=%s\n' "$d/home" > "$d/pool/1/.fm-slot-owner"
run "$d" stale-task --force; show "$d"

echo; echo "=== S2: claim names holder-task; teardown of the HOLDER with --force ==="
d=$(mkcase s2); printf 'task=holder-task\nhome=%s\n' "$d/home" > "$d/pool/1/.fm-slot-owner"
run "$d" holder-task --force; show "$d"
echo; echo "=== S3: apply the repair the refusal names, then re-run holder teardown ==="
slot=$(cd "$d/pool/1/project" && pwd -P)
sed -i "s|^worktree=.*|worktree_released=$slot|" "$d/home/state/stale-task.meta"
echo "  stale-task.meta now: $(tr '\n' ' ' < "$d/home/state/stale-task.meta")"
run "$d" holder-task --force; show "$d"
echo; echo "=== S3b: stale record's own teardown after repair ==="
run "$d" stale-task --force; show "$d"

echo; echo "=== S4: no claim on the slot; teardown of either record ==="
d=$(mkcase s4)
run "$d" stale-task --force; show "$d"
run "$d" holder-task; show "$d"
