#!/usr/bin/env bash
# Behavior tests for bin/fm-backpass-lane.sh.
#
# The lane's contract is that it runs backpass over a byte-for-byte isolated
# copy, pins one dedicated provider, resolves one budget and passes exactly that
# value, never invokes `apply`, and leaves a run record that states the review
# gate. These tests drive a stub backpass, so no model tokens are spent, and
# assert on the lane's record, the stub's captured argv, and independent byte
# fingerprints of the live fixture home.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backpass-lane)
FAKE="$TMP_ROOT/fakebin"
LOG="$TMP_ROOT/backpass.log"
mkdir -p "$FAKE"
FM_FAKE_BACKPASS_LOG=$LOG
export FM_FAKE_BACKPASS_LOG

make_backpass() {
  cat > "$FAKE/backpass" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_BACKPASS_LOG:?}"
case "${1:-}" in
  -v)
    printf '0.1.24-fake\n'
    exit 0
    ;;
  status)
    printf '{"budgets":[{"path":"AGENTS.md","label":"AGENTS.md + skill descriptions","capTokens":5000,"current":%s,"withinBudget":false,"instructions":138,"pointerTo":null}]}\n' "${FM_FAKE_BACKPASS_SURFACE:-22475}"
    exit 0
    ;;
  scan)
    if [ "${FM_FAKE_BACKPASS_CORPUS:-2}" = 0 ]; then
      printf '{"transcripts":[]}\n'
    else
      printf '{"transcripts":[{"id":"a"},{"id":"b"}]}\n'
    fi
    exit 0
    ;;
esac
if [ "${FM_FAKE_BACKPASS_FAIL:-0}" = 1 ]; then
  if [ "${FM_FAKE_BACKPASS_ACPX_FAIL:-0}" = 1 ]; then
    printf 'cannot verify acpx adapter configuration for pi: exit null\n' >&2
  else
    printf 'fake provider failure\n' >&2
  fi
  exit 1
fi
mkdir -p .backpass
cat > .backpass/proposal.json <<JSON
{
  "version": 1,
  "memoryFile": {"path": "AGENTS.md"},
  "targetFiles": [{"file": "${FM_FAKE_BACKPASS_TARGET:-AGENTS.md}"}],
  "budget": {"capTokens": ${FM_FAKE_BACKPASS_CAP:-23975}, "current": 22475, "projected": 22536, "delta": 61},
  "stats": {"transcripts": 2},
  "edits": [
    {
      "id": "e1",
      "kind": "rewrite",
      "file": "${FM_FAKE_BACKPASS_TARGET:-AGENTS.md}",
      "title": "Tighten a line",
      "deltaTokens": 61,
      "skills": [{"name": "new-skill", "description": "A new skill", "path": ".agents/skills/new-skill/SKILL.md"}]
    }
  ],
  "verdicts": [{"instruction": "AG-1", "verdict": "keep", "positive": 2, "negative": 0}]
}
JSON
printf '{"stats":{"transcripts":2}}\n'
SH
  chmod +x "$FAKE/backpass"
}

make_home() {
  local home=$1
  mkdir -p "$home/.agents/skills/alpha" "$home/config"
  printf 'Agent instructions.\n' > "$home/AGENTS.md"
  printf '<!-- points at AGENTS.md -->\n@AGENTS.md\n' > "$home/CLAUDE.md"
  printf '# alpha\n' > "$home/.agents/skills/alpha/SKILL.md"
  printf '7500\n' > "$home/config/startup-memory-budget"
  printf 'state/\n' > "$home/.gitignore"
  fm_git_init_commit "$home"
  git -C "$home" add -A
  git -C "$home" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm memory
  fm_git_add_origin "$home" "$home.origin.git"
}

run_lane() { # <home> <lane-root> [args...]
  local home=$1 lane=$2
  shift 2
  FM_HOME="$home" FM_BACKPASS_BIN="$FAKE/backpass" \
    "$ROOT/bin/fm-backpass-lane.sh" --root "$lane" --source "$home" "$@"
}

run_lane_default_root() { # <home> [args...]
  local home=$1
  shift
  FM_HOME="$home" FM_BACKPASS_BIN="$FAKE/backpass" \
    "$ROOT/bin/fm-backpass-lane.sh" --source "$home" "$@"
}

test_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

fingerprint_dir() { # <dir>: content fingerprint of the lane's memory surface
  (
    cd "$1" || exit 1
    find AGENTS.md CLAUDE.md .agents -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r file; do
      printf '%s %s\n' "$file" "$(test_sha256 "$file")"
    done
  )
}

test_lane_copies_the_memory_and_publishes_a_proposal_without_writing_the_source() {
  local home="$TMP_ROOT/home-main" lane="$TMP_ROOT/lane-main" record before after out
  make_home "$home"
  : > "$LOG"
  before=$(fingerprint_dir "$home")
  out=$(run_lane "$home" "$lane" 2>&1) || fail "lane run failed: $out"
  after=$(fingerprint_dir "$home")
  record="$lane/latest/record.txt"

  assert_equals "$before" "$after" "the lane must not change the live memory"
  assert_equals "$before" "$(fingerprint_dir "$lane/memory")" "the isolated copy must be byte-for-byte"
  assert_absent "$home/.backpass" "the lane must never create .backpass in the live home"
  assert_present "$lane/memory/.backpass" "the lane keeps backpass state in the isolated copy"
  assert_present "$lane/latest/proposal.json" "the run must publish proposal.json"
  assert_grep '"e1"' "$lane/latest/proposal.json" "the published proposal must carry the edits"
  assert_present "$record" "the run must publish a record"
  assert_grep "backpass_version=0.1.24-fake" "$record" "the record must name the backpass version"
  assert_grep "corpus_transcripts=2" "$record" "the record must count the associated corpus"
  assert_grep "budget_effective=23975" "$record" "the budget must be the measured surface plus the margin"
  assert_grep "budget_measured_surface=22475" "$record" "the record must name the measured surface"
  assert_grep "budget_margin=1500" "$record" "the record must name the margin"
  assert_grep "budget_house_startup_memory=7500" "$record" "the record must carry the house allowance"
  assert_grep "different surfaces" "$record" "a house/surface mismatch must be stated, not hidden"
  assert_grep "budget_match_backpass=yes" "$record" "the passed budget must match the proposal cap"
  assert_grep "provider_agent=pi" "$record" "the agent must stay pinned"
  assert_grep "provider_analysis_model=ollama-cloud/deepseek-v4.1-flash" "$record" "the analysis model must be pinned"
  assert_grep "provider_synthesis_model=ollama-cloud/kimi-k3" "$record" "the synthesis model must be pinned"
  assert_grep "apply_invoked=never" "$record" "the record must state that apply never runs"
  assert_grep "live_memory_unchanged=yes" "$record" "the record must carry the live-memory verdict"
  assert_grep "stow_marker_convention_applies=no" "$record" "AGENTS.md carries no stow markers"
  assert_grep "proposal_targets=.agents/skills/new-skill/SKILL.md AGENTS.md" "$record" \
    "a created skill path must be listed as a review target"
  assert_grep "skill=.agents/skills/new-skill/SKILL.md" "$record" "the record must name a created skill"
  assert_grep "--budget 23975" "$LOG" "the run must pass the resolved budget"
  assert_grep "--analysis-agent pi --analysis-model ollama-cloud/deepseek-v4.1-flash" "$LOG" "the analysis pass must be pinned"
  assert_grep "--synthesis-agent pi --synthesis-model ollama-cloud/kimi-k3" "$LOG" "the synthesis pass must be pinned"
  assert_grep "scan --json --since all --strict" "$LOG" "the corpus scan must be deterministic and complete"
  assert_no_grep "apply" "$LOG" "the lane must never invoke apply"
  [ -z "$(git -C "$home" status --porcelain)" ] || fail "the live checkout status must stay clean"
  pass "the lane copies, publishes, and leaves the live memory untouched"
}

test_lane_pins_an_explicit_budget_and_model_overrides() {
  local home="$TMP_ROOT/home-pin" lane="$TMP_ROOT/lane-pin" record out
  make_home "$home"
  : > "$LOG"
  printf '#!/bin/sh\nexit 0\n' > "$FAKE/acpx"
  chmod +x "$FAKE/acpx"
  out=$(FM_FAKE_BACKPASS_CAP=12345 run_lane "$home" "$lane" --acpx "$FAKE/acpx" \
    --budget 12345 --analysis-model openrouter/analysis-x --synthesis-model openrouter/synthesis-y 2>&1) \
    || fail "lane run failed: $out"
  record="$lane/latest/record.txt"
  assert_grep "budget_effective=12345" "$record" "an explicit budget must win"
  assert_grep "budget_source=explicit" "$record" "the record must name the budget source"
  assert_grep "acpx_bin=$FAKE/acpx" "$record" "the record must name the acpx copy in use"
  assert_grep "--budget 12345" "$LOG" "the explicit budget must be passed through"
  assert_grep "--analysis-model openrouter/analysis-x" "$LOG" "an analysis model override must be passed through"
  assert_grep "--synthesis-model openrouter/synthesis-y" "$LOG" "a synthesis model override must be passed through"
  assert_grep "budget_match_backpass=yes" "$record" "the explicit budget must match the proposal cap"
  pass "an explicit budget and model override are pinned and passed through"
}

test_lane_uses_the_house_allowance_when_it_covers_the_surface() {
  local home="$TMP_ROOT/home-house" lane="$TMP_ROOT/lane-house" record out
  make_home "$home"
  printf '30000\n' > "$home/config/startup-memory-budget"
  : > "$LOG"
  out=$(FM_FAKE_BACKPASS_CAP=30000 run_lane "$home" "$lane" 2>&1) || fail "lane run failed: $out"
  record="$lane/latest/record.txt"
  assert_grep "budget_effective=30000" "$record" "a covering house allowance must be used"
  assert_grep "budget_source=house-startup-memory-budget" "$record" "the record must name the covering source"
  assert_grep "budget_match=yes" "$record" "a covering allowance must be recorded as matching"
  pass "a covering house allowance becomes the budget"
}

test_lane_states_the_stow_gate_for_a_tiered_target() {
  local home="$TMP_ROOT/home-stow" lane="$TMP_ROOT/lane-stow" record out
  make_home "$home"
  : > "$LOG"
  out=$(FM_FAKE_BACKPASS_TARGET=data/learnings.md run_lane "$home" "$lane" 2>&1) \
    || fail "lane run failed: $out"
  record="$lane/latest/record.txt"
  assert_grep "proposal_targets=.agents/skills/new-skill/SKILL.md data/learnings.md" "$record" \
    "the record must name the proposed target"
  assert_grep "stow_marker_convention_applies=yes" "$record" "a tiered memory target must require the stow gate"
  assert_grep "run /stow" "$record" "the record must name the marker/tier pass"
  pass "a tiered target is reported as requiring the /stow gate"
}

test_lane_stops_before_model_spend_when_the_corpus_is_empty() {
  local home="$TMP_ROOT/home-empty" lane="$TMP_ROOT/lane-empty" record out
  make_home "$home"
  mkdir -p "$lane/memory/.backpass"
  printf '{"stale":true}\n' > "$lane/memory/.backpass/proposal.json"
  : > "$LOG"
  out=$(FM_FAKE_BACKPASS_CORPUS=0 run_lane "$home" "$lane" 2>&1) || fail "lane run failed: $out"
  record="$lane/latest/record.txt"
  assert_grep "corpus_transcripts=0" "$record" "an empty corpus must be recorded"
  assert_grep "proposal=absent" "$record" "an empty corpus must not publish a proposal"
  assert_absent "$lane/latest/proposal.json" "a stale proposal must never be republished"
  assert_absent "$lane/memory/.backpass/proposal.json" "an empty corpus must clear the stale copy proposal"
  assert_no_grep "--since all --limit" "$LOG" "an empty corpus must not start the model pass"
  assert_no_grep "apply" "$LOG" "the lane must never invoke apply"
  pass "an empty corpus stops before model spend and drops a stale proposal"
}

test_lane_fails_loudly_when_backpass_fails() {
  local home="$TMP_ROOT/home-fail" lane="$TMP_ROOT/lane-fail" record rc out
  make_home "$home"
  : > "$LOG"
  rc=0
  out=$(FM_FAKE_BACKPASS_FAIL=1 run_lane "$home" "$lane" 2>&1) || rc=$?
  expect_code 1 "$rc" "a failed backpass run"
  record="$lane/latest/record.txt"
  assert_grep "backpass_run_rc=1" "$record" "a failed run must be recorded"
  assert_grep "live_memory_unchanged=yes" "$record" "a failed run must still verify the live memory"
  assert_grep "fake provider failure" "$lane/latest/run.log" "the run log must keep the failure evidence"
  assert_contains "$out" "fm-backpass-lane: backpass run failed" "the lane must say the run failed"
  pass "a failed backpass run is recorded and relayed"
}

test_lane_points_at_a_faster_acpx_when_verification_fails() {
  local home="$TMP_ROOT/home-acpx" lane="$TMP_ROOT/lane-acpx" rc out
  make_home "$home"
  : > "$LOG"
  rc=0
  out=$(FM_FAKE_BACKPASS_FAIL=1 FM_FAKE_BACKPASS_ACPX_FAIL=1 run_lane "$home" "$lane" 2>&1) || rc=$?
  expect_code 1 "$rc" "a slow-acpx verification failure"
  assert_contains "$out" "pass --acpx <path>" "the lane must point at the supported fix"
  pass "a slow-acpx verification failure points at --acpx"
}

test_lane_defaults_the_lane_root_under_the_home_state() {
  local home="$TMP_ROOT/home-default" record out
  make_home "$home"
  : > "$LOG"
  out=$(run_lane_default_root "$home" 2>&1) || fail "lane run failed: $out"
  record="$home/state/backpass-lane/latest/record.txt"
  assert_present "$record" "the default lane root must live under the home state directory"
  assert_grep "lane_root=$home/state/backpass-lane" "$record" "the record must name the default lane root"
  pass "the default output lands under the home state directory"
}

test_lane_refuses_a_source_without_memory() {
  local home="$TMP_ROOT/home-nomem" lane="$TMP_ROOT/lane-nomem" rc out
  mkdir -p "$home"
  fm_git_init_commit "$home"
  fm_git_add_origin "$home" "$home.origin.git"
  rc=0
  out=$(run_lane "$home" "$lane" 2>&1) || rc=$?
  expect_code 1 "$rc" "a source without AGENTS.md"
  assert_contains "$out" "no AGENTS.md" "the lane must name the missing memory file"
  pass "a source without AGENTS.md is refused"
}

make_backpass
test_lane_copies_the_memory_and_publishes_a_proposal_without_writing_the_source
test_lane_pins_an_explicit_budget_and_model_overrides
test_lane_uses_the_house_allowance_when_it_covers_the_surface
test_lane_states_the_stow_gate_for_a_tiered_target
test_lane_stops_before_model_spend_when_the_corpus_is_empty
test_lane_fails_loudly_when_backpass_fails
test_lane_points_at_a_faster_acpx_when_verification_fails
test_lane_defaults_the_lane_root_under_the_home_state
test_lane_refuses_a_source_without_memory
