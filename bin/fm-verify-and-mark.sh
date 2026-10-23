#!/usr/bin/env bash
# fm-verify-and-mark.sh - run a pull request's own verification in a clean copy
# and, only when it is green, publish a success status for that exact commit.
#
# Usage: fm-verify-and-mark.sh <task-id> <pr-url>
#
# This is a complement to the required `resultado` check, never a substitute for
# it. The branch protection on main binds `resultado` to the GitHub Actions app,
# so this script does not and cannot satisfy it, and it does not try to. Its
# status uses its own context, `firstmate/verify-main`, which no merge rule
# requires. Its only purpose is an independent signal that the same steps the
# `resultado` job of verify-main.yml runs also pass on this machine.
#
# What it runs, in order, in a fresh clone of the pull request's repository
# checked out at the head commit read from the GitHub API:
#   1. scripts/ci_entorno_python.sh   (the project's Python environment)
#   2. scripts/verify_main.sh --set puertas --in-ci --base <base>
#   3. scripts/verify_main.sh --set humo --in-ci --base <base>
# <base> is origin/main at run time, which is the workflow's base for pushes to
# fm/**. Before running, the script refuses unless verify-main.yml at that commit
# still contains those three invocations, so a changed workflow stops the run
# instead of letting this script drift from what Actions runs.
#
# The steps run in a sanitized environment: no variable from the caller's shell
# leaks in (DATABASE_URL and friends are absent, as on the workflow's runner).
# The Python environment cache is VERIFY_MAIN_CACHE under this home's state,
# never the runners' default cache, so this script cannot prune a venv that a
# runner is using. Each step runs under bin/fm-memory.sh run, which caps its
# memory.
#
# Outcomes:
#   green        both steps exit 0 and the head is still the verified commit:
#                the success status is published on that commit, exit 0.
#   red          a verification step failed: nothing is published, exit 1.
#   unverified   the copy, the environment, or the workflow check could not be
#                completed: nothing is published, exit 3.
#   moved        the pull request head changed after verification: nothing is
#                published, exit 4.
#   post-failed  the verification passed but the status could not be published:
#                exit 5, and the record says so.
# Nothing is ever published as pending or as failure, so a stopped run cannot
# leave a merge blocker behind.
#
# Durable record: state/<task-id>.verify (the latest run: outcome, head, base,
# time, and log path) and state/verify/<task-id>/<head>.log (the full log of
# that commit's run). The status link (target_url) is the pull request's own
# URL, because no hosted log exists; the local log path is in the record.
#
# Exit: 0 green published; 1 red; 2 usage; 3 unverified; 4 moved; 5 post failed.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

CONTEXT="firstmate/verify-main"
WORKFLOW=".github/workflows/verify-main.yml"
PR_RE='^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([1-9][0-9]*)$'

die_usage() {
  echo "error: $*" >&2
  echo "usage: fm-verify-and-mark.sh <task-id> <pr-url>" >&2
  exit 2
}

[ "$#" -eq 2 ] || die_usage "expected a task id and a pull request URL"
TASK=$1
URL=$2
case "$TASK" in
  "" | .* | *[!A-Za-z0-9._-]*) die_usage "invalid task id: $TASK" ;;
esac
if ! [[ "$URL" =~ $PR_RE ]]; then
  die_usage "pull request URL must be https://github.com/<owner>/<repo>/pull/<number>: $URL"
fi
OWNER=${BASH_REMATCH[1]}
REPO=${BASH_REMATCH[2]}
NUMBER=${BASH_REMATCH[3]}

VERIFY_DIR="$STATE/verify/$TASK"
WORK="$VERIFY_DIR/repo"
ENVDIR="$VERIFY_DIR/env"
CACHE="$VERIFY_DIR/venv-cache"
RECORD="$STATE/$TASK.verify"
HEAD_SHA=""
BASE_SHA=""
LOG=""

# record_outcome <outcome> [detail]: write the latest-run record atomically.
record_outcome() {
  local outcome=$1 detail=${2-}
  mkdir -p "$STATE"
  {
    printf 'outcome=%s\n' "$outcome"
    printf 'pr=%s\n' "$URL"
    printf 'head=%s\n' "$HEAD_SHA"
    printf 'base=%s\n' "$BASE_SHA"
    printf 'context=%s\n' "$CONTEXT"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'log=%s\n' "$LOG"
    [ -z "$detail" ] || printf 'detail=%s\n' "$detail"
  } > "$RECORD.tmp"
  mv "$RECORD.tmp" "$RECORD"
  echo "record: $RECORD ($outcome)"
}

# note <line>: to stdout and the run's log.
note() {
  echo "$*"
  [ -z "$LOG" ] || printf '%s\n' "$*" >> "$LOG"
}

# fail_unverified <why>: stop without publishing, naming what failed.
fail_unverified() {
  note "unverified: $1"
  echo "unverified: $1" >&2
  record_outcome unverified "$1"
  exit 3
}

# gh_head: the current head commit of the pull request, read from the API.
gh_head() {
  gh api "repos/$OWNER/$REPO/pulls/$NUMBER" --jq '.head.sha' 2>/dev/null
}

HEAD_SHA=$(gh_head 2>/dev/null) || HEAD_SHA=""
if ! [[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  HEAD_SHA=""
  echo "unverified: could not read the pull request head from GitHub" >&2
  VERIFY_DIR="$STATE/verify/$TASK"
  mkdir -p "$STATE"
  record_outcome unverified "no head read"
  exit 3
fi

mkdir -p "$VERIFY_DIR"
LOG="$VERIFY_DIR/$HEAD_SHA.log"
: > "$LOG"
note "verify: $URL head=$HEAD_SHA"

# A fresh copy every run: nothing from an earlier run can leak into this verdict.
rm -rf "$WORK" "$ENVDIR"
mkdir -p "$ENVDIR" "$CACHE"
: > "$ENVDIR/github_env"
: > "$ENVDIR/github_path"
: > "$ENVDIR/github_output"
if ! gh repo clone "$OWNER/$REPO" "$WORK" -- --filter=blob:none --no-checkout --quiet >>"$LOG" 2>&1; then
  fail_unverified "could not clone $OWNER/$REPO"
fi
if ! git -C "$WORK" fetch --quiet origin "pull/$NUMBER/head" >>"$LOG" 2>&1; then
  fail_unverified "could not fetch the pull request head"
fi
if [ "$(git -C "$WORK" rev-parse FETCH_HEAD)" != "$HEAD_SHA" ]; then
  fail_unverified "the fetched head differs from the head read from GitHub"
fi
if ! git -C "$WORK" checkout --quiet --detach "$HEAD_SHA" >>"$LOG" 2>&1; then
  fail_unverified "could not check out the head commit"
fi
if ! BASE_SHA=$(git -C "$WORK" rev-parse origin/main 2>>"$LOG"); then
  fail_unverified "could not read origin/main"
fi

# Parity guard: refuse to run unless the workflow at this commit still runs the
# steps this script mirrors.
if ! workflow=$(git -C "$WORK" show "$HEAD_SHA:$WORKFLOW" 2>/dev/null); then
  fail_unverified "$WORKFLOW is missing at the head commit"
fi
for needle in \
  'scripts/ci_entorno_python.sh' \
  'scripts/verify_main.sh --set puertas --in-ci --base' \
  'scripts/verify_main.sh --set humo --in-ci --base'; do
  if ! grep -qF -- "$needle" <<<"$workflow"; then
    fail_unverified "$WORKFLOW no longer runs '$needle'; update this script first"
  fi
done

# run_step <name> <command...>: one step in the clean copy, sanitized and capped.
# A failing step is a red verdict for verify steps and an unverified one for setup.
run_step() {
  local name=$1
  shift
  note "step: $name"
  (cd "$WORK" && "$SCRIPT_DIR/fm-memory.sh" run -- env -i \
    HOME="$HOME" PATH="$STEP_PATH" LANG=C.UTF-8 CI=true \
    CI_PYTHON=python3.12 VERIFY_MAIN_CACHE="$CACHE" \
    PYTHON="${STEP_PYTHON:-}" \
    GITHUB_ENV="$ENVDIR/github_env" GITHUB_PATH="$ENVDIR/github_path" \
    GITHUB_OUTPUT="$ENVDIR/github_output" "$@") >>"$LOG" 2>&1
}

STEP_PATH=$PATH
STEP_PYTHON=""
if ! run_step "ci_entorno_python.sh" bash scripts/ci_entorno_python.sh; then
  fail_unverified "scripts/ci_entorno_python.sh failed (see $LOG)"
fi
STEP_PYTHON=$(sed -n 's/^PYTHON=//p' "$ENVDIR/github_env" | tail -n 1)
if [ -z "$STEP_PYTHON" ]; then
  fail_unverified "scripts/ci_entorno_python.sh did not publish a PYTHON"
fi
while IFS= read -r extra; do
  [ -z "$extra" ] || STEP_PATH="$extra:$STEP_PATH"
done < "$ENVDIR/github_path"

verdict=green
for set_name in puertas humo; do
  if ! run_step "verify_main.sh --set $set_name" \
    bash scripts/verify_main.sh --set "$set_name" --in-ci --base "$BASE_SHA"; then
    verdict=red
    note "red: the $set_name verification failed"
    break
  fi
done

if [ "$verdict" = red ]; then
  note "red: nothing is published for $HEAD_SHA"
  record_outcome red "a verification step failed"
  exit 1
fi

# The head must still be the commit that was verified, read again after the run.
if [ "$(gh_head 2>/dev/null || true)" != "$HEAD_SHA" ]; then
  note "moved: the pull request head changed during verification; nothing is published"
  record_outcome moved "head changed after verification"
  exit 4
fi

description="Verificación propia en verde: puertas y humo del commit (no sustituye a resultado)"
if gh api --method POST "repos/$OWNER/$REPO/statuses/$HEAD_SHA" \
  -f state=success \
  -f context="$CONTEXT" \
  -f description="$description" \
  -f target_url="$URL" >>"$LOG" 2>&1; then
  note "green: published $CONTEXT success on $HEAD_SHA"
  record_outcome green
  exit 0
fi
note "post-failed: verification was green but the status could not be published"
record_outcome post-failed "status publication failed"
exit 5
