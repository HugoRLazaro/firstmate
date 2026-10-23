#!/usr/bin/env bash
# Behavior tests for bin/fm-verify-and-mark.sh. A green verification publishes
# one success status on the verified head under firstmate/verify-main, and the
# verification sees the base, a sanitized environment, and its own cache. A red
# run, an unverifiable run, a workflow that no longer runs the mirrored steps, an
# unreadable head, and a head that moved all publish nothing, and a failed post
# is reported as such. The status context is never resultado.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-verify-and-mark.sh"
TMP_ROOT=$(fm_test_tmproot fm-verify-and-mark)
TASK=verify-task
PR_URL=https://github.com/acme/project/pull/7
RUN_CODE=0

# install_stub <path> <ctrl> <origin>: write the stdin body to <path> with the
# control directory and origin path substituted in.
install_stub() {
  local path=$1 ctrl=$2 origin=$3
  sed -e "s#@CTRL@#$ctrl#g" -e "s#@ORIGIN@#$origin#g" > "$path"
  chmod +x "$path"
}

# write_workflow <file> <drop_humo>: a verify-main.yml that runs the mirrored
# steps, optionally without the humo invocation.
write_workflow() {
  local file=$1 drop=$2
  # The ${{ }} expressions are the workflow's own literal text, not shell.
  # shellcheck disable=SC2016
  {
    echo 'name: Verify main'
    echo 'jobs:'
    echo '  resultado:'
    echo '    steps:'
    echo '      - run: scripts/ci_entorno_python.sh || { exit 1; }'
    echo '      - run: scripts/verify_main.sh --set puertas --in-ci --base "${{ steps.base.outputs.sha }}"'
    if [ "$drop" != 1 ]; then
      echo '      - run: scripts/verify_main.sh --set humo --in-ci --base "${{ steps.base.outputs.sha }}"'
    fi
  } > "$file"
}

# make_fixture <name> [drop_humo]: a bare origin whose refs/pull/7/head is a
# feature commit on top of main, a control directory the stubs read, and a fake
# gh first on PATH.
make_fixture() {
  local name=$1 drop=${2:-0} dir origin seed ctrl fakebin head
  dir="$TMP_ROOT/$name"
  origin="$dir/origin.git"
  seed="$dir/seed"
  ctrl="$dir/ctrl"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$ctrl" "$dir/state"

  git init -q -b main "$seed"
  mkdir -p "$seed/.github/workflows" "$seed/scripts"
  write_workflow "$seed/.github/workflows/verify-main.yml" "$drop"
  install_stub "$seed/scripts/ci_entorno_python.sh" "$ctrl" "$origin" <<'SH'
#!/usr/bin/env bash
[ ! -f @CTRL@/rc-entorno ] || exit "$(cat @CTRL@/rc-entorno)"
printf 'PYTHON=%s\n' "$(command -v python3)" >> "$GITHUB_ENV"
SH
  install_stub "$seed/scripts/verify_main.sh" "$ctrl" "$origin" <<'SH'
#!/usr/bin/env bash
set_name=""
base=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --set) set_name=$2; shift 2 ;;
    --base) base=$2; shift 2 ;;
    *) shift ;;
  esac
done
printf 'set=%s base=%s python=%s database_url=%s cache=%s\n' \
  "$set_name" "$base" "${PYTHON:-unset}" "${DATABASE_URL:-absent}" "${VERIFY_MAIN_CACHE:-unset}" \
  >> @CTRL@/verify.log
[ ! -f "@CTRL@/rc-$set_name" ] || exit "$(cat "@CTRL@/rc-$set_name")"
SH
  git -C "$seed" add -A
  git -C "$seed" -c user.name=Test -c user.email=test@example.invalid commit -qm base
  git -C "$seed" checkout -q -b fm/verify-task
  echo feature > "$seed/feature.txt"
  git -C "$seed" add -A
  git -C "$seed" -c user.name=Test -c user.email=test@example.invalid commit -qm feature
  head=$(git -C "$seed" rev-parse HEAD)
  git clone -q --bare "$seed" "$origin"
  git -C "$origin" update-ref refs/pull/7/head "$head"

  install_stub "$fakebin/gh" "$ctrl" "$origin" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> @CTRL@/gh.log
if [ "$1" = api ] && [ "$2" = repos/acme/project/pulls/7 ]; then
  [ ! -f @CTRL@/head_unreadable ] || exit 1
  reads=$(cat @CTRL@/reads 2>/dev/null || echo 0)
  reads=$((reads + 1))
  echo "$reads" > @CTRL@/reads
  if [ "$reads" -ge 2 ] && [ -f @CTRL@/head_after ]; then
    cat @CTRL@/head_after
  else
    cat @CTRL@/head
  fi
  exit 0
fi
if [ "$1" = repo ] && [ "$2" = clone ]; then
  git clone -q @ORIGIN@ "$4"
  exit $?
fi
if [ "$1" = api ] && [[ "$*" == *"--method POST"* ]]; then
  printf '%s\n' "$*" >> @CTRL@/posts.log
  [ ! -f @CTRL@/post_fail ] || exit 1
  echo '{}'
  exit 0
fi
echo "fake gh: unexpected $*" >&2
exit 1
SH
  printf '%s\n' "$head" > "$ctrl/head"
  git -C "$seed" rev-parse main > "$ctrl/main"
  printf '%s\n' "$name"
}

# run_verify <name>: run the script against a fixture with the caller's shell
# carrying a database URL that must not reach the verification.
run_verify() {
  local dir=$TMP_ROOT/$1
  DATABASE_URL=leaked-from-shell \
    FM_STATE_OVERRIDE="$dir/state" \
    PATH="$dir/fakebin:$PATH" \
    "$SCRIPT" "$TASK" "$PR_URL" >"$dir/out" 2>"$dir/err"
  RUN_CODE=$?
}

posts_of() { cat "$TMP_ROOT/$1/ctrl/posts.log" 2>/dev/null || true; }

assert_no_post() {
  assert_absent "$TMP_ROOT/$1/ctrl/posts.log" "$2 published a status"
}

record_of() { cat "$TMP_ROOT/$1/state/$TASK.verify" 2>/dev/null || true; }

test_green_publishes_one_success_on_verified_head() {
  local name=green dir head posts
  make_fixture "$name" >/dev/null
  dir=$TMP_ROOT/$name
  head=$(cat "$dir/ctrl/head")
  run_verify "$name"
  expect_code 0 "$RUN_CODE" "green verification"

  posts=$(posts_of "$name")
  assert_equals 1 "$(printf '%s\n' "$posts" | grep -c .)" "green must publish exactly one status"
  assert_contains "$posts" "repos/acme/project/statuses/$head" "status is not on the verified head"
  assert_contains "$posts" "-f state=success" "green status is not success"
  assert_contains "$posts" "-f context=firstmate/verify-main" "green status uses the wrong context"
  assert_contains "$posts" "-f target_url=$PR_URL" "status does not link the pull request"
  assert_not_contains "$posts" "context=resultado" "the required check name must never be written"
  assert_contains "$(record_of "$name")" "outcome=green" "record does not say green"

  local verify_log
  verify_log=$(cat "$dir/ctrl/verify.log")
  assert_contains "$verify_log" "set=puertas base=$(cat "$dir/ctrl/main") " "puertas did not run against origin/main"
  assert_contains "$verify_log" "set=humo base=$(cat "$dir/ctrl/main") " "humo did not run against origin/main"
  assert_contains "$verify_log" "database_url=absent" "the caller's database URL reached the verification"
  assert_contains "$verify_log" "cache=$dir/state/verify/" "the verification cache is not owned by this home"
  assert_no_grep "python=unset" "$dir/ctrl/verify.log" "the verification did not receive the project Python"

  pass "green verification publishes one success on the verified head under its own context"
}

test_red_publishes_nothing() {
  local name=red
  make_fixture "$name" >/dev/null
  printf '1\n' > "$TMP_ROOT/$name/ctrl/rc-humo"
  run_verify "$name"
  expect_code 1 "$RUN_CODE" "red verification"
  assert_no_post "$name" "red verification"
  assert_contains "$(record_of "$name")" "outcome=red" "record does not say red"
  pass "red verification publishes no status at all"
}

test_unverifiable_environment_publishes_nothing() {
  local name=unverifiable
  make_fixture "$name" >/dev/null
  printf '1\n' > "$TMP_ROOT/$name/ctrl/rc-entorno"
  run_verify "$name"
  expect_code 3 "$RUN_CODE" "unverifiable environment"
  assert_no_post "$name" "unverifiable environment"
  assert_absent "$TMP_ROOT/$name/ctrl/verify.log" "verification ran after its environment failed"
  assert_contains "$(record_of "$name")" "outcome=unverified" "record does not say unverified"
  pass "a verification that cannot run fails and publishes nothing"
}

test_workflow_drift_stops_before_verifying() {
  local name=drift
  make_fixture "$name" 1 >/dev/null
  run_verify "$name"
  expect_code 3 "$RUN_CODE" "drifted workflow"
  assert_no_post "$name" "drifted workflow"
  assert_absent "$TMP_ROOT/$name/ctrl/verify.log" "verification ran against a drifted workflow"
  assert_contains "$(cat "$TMP_ROOT/$name/err")" "humo" "drift refusal does not name the missing step"
  pass "a workflow that no longer runs the mirrored steps stops the run"
}

test_unreadable_head_publishes_nothing() {
  local name=unreadable
  make_fixture "$name" >/dev/null
  : > "$TMP_ROOT/$name/ctrl/head_unreadable"
  run_verify "$name"
  expect_code 3 "$RUN_CODE" "unreadable head"
  assert_no_post "$name" "unreadable head"
  pass "an unreadable pull request head publishes nothing"
}

test_moved_head_publishes_nothing() {
  local name=moved dir
  make_fixture "$name" >/dev/null
  dir=$TMP_ROOT/$name
  cat "$dir/ctrl/main" > "$dir/ctrl/head_after"
  run_verify "$name"
  expect_code 4 "$RUN_CODE" "moved head"
  assert_no_post "$name" "moved head"
  assert_contains "$(record_of "$name")" "outcome=moved" "record does not say moved"
  pass "a head that moved during verification publishes nothing"
}

test_failed_post_is_reported() {
  local name=postfail
  make_fixture "$name" >/dev/null
  : > "$TMP_ROOT/$name/ctrl/post_fail"
  run_verify "$name"
  expect_code 5 "$RUN_CODE" "failed post"
  assert_contains "$(record_of "$name")" "outcome=post-failed" "record does not say the post failed"
  pass "a verified commit whose status cannot be posted is reported as post-failed"
}

test_bad_arguments_are_refused() {
  local name=usage
  make_fixture "$name" >/dev/null
  PATH="$TMP_ROOT/$name/fakebin:$PATH" FM_STATE_OVERRIDE="$TMP_ROOT/$name/state" \
    "$SCRIPT" "$TASK" https://example.com/not-a-pr >/dev/null 2>&1
  expect_code 2 "$?" "non-PR URL"
  assert_absent "$TMP_ROOT/$name/ctrl/posts.log" "a refused argument reached GitHub"
  pass "a URL that is not a GitHub pull request is refused before any work"
}

test_green_publishes_one_success_on_verified_head
test_red_publishes_nothing
test_unverifiable_environment_publishes_nothing
test_workflow_drift_stops_before_verifying
test_unreadable_head_publishes_nothing
test_moved_head_publishes_nothing
test_failed_post_is_reported
test_bad_arguments_are_refused
