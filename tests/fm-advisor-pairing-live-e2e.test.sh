#!/usr/bin/env bash
# tests/fm-advisor-pairing-live-e2e.test.sh - default-on live guard for the
# Claude advisor pairing probe (bin/fm-advisor-lib.sh's fm_advisor_probe).
#
# The probe's verdict comes from text the installed Claude Code prints: the
# empty-prompt refusal for an accepted pairing, and "cannot be used as an
# advisor" or "cannot advise" for a refused one. Only the real CLI can show that
# those strings still mean what the probe assumes, so this guard asks the
# installed claude for one accepted and two refused pairings. Every call has
# empty stdin and fails before a conversation starts, so it spends no tokens.
# tests/fm-spawn-advisor.test.sh pins the same matrix against a fake claude in
# CI. Run this guard after every Claude Code upgrade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_ADVISOR_PAIRING claude

# shellcheck source=bin/fm-advisor-lib.sh
. "$ROOT/bin/fm-advisor-lib.sh"

version=$(claude --version 2>/dev/null | head -1)
printf '# claude %s\n' "${version:-unknown version}"

fm_advisor_probe claude-haiku-5-5 claude-opus-5-5 \
  || fail "claude ${version:-?}: Haiku 5.5 with an Opus 5.5 advisor was not accepted"
pass "claude ${version:-?} accepts Haiku 5.5 with an Opus 5.5 advisor"

out=$(fm_advisor_probe claude-haiku-5-5 claude-haiku-4-5 2>&1) \
  && fail "claude ${version:-?}: Haiku 4.5 was accepted as an advisor"
assert_contains "$out" "cannot be used as an advisor" "claude ${version:-?}: the invalid-advisor refusal text changed"
pass "claude ${version:-?} refuses Haiku 4.5 as an advisor"

out=$(fm_advisor_probe claude-opus-5-5 claude-haiku-5-5 2>&1) \
  && fail "claude ${version:-?}: a weaker advisor was accepted for Opus 5.5"
assert_contains "$out" "cannot advise" "claude ${version:-?}: the weaker-advisor warning text changed"
pass "claude ${version:-?} refuses a weaker advisor for Opus 5.5"

echo "# all fm-advisor-pairing-live-e2e tests passed"
