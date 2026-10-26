#!/usr/bin/env bash
# fm-advisor-lib.sh - the single owner of the optional per-task Claude advisor
# axis: which values are accepted, the free pre-launch pairing probe, and the
# consultation-cadence block a worker with an advisor receives.
#
# Sourced, never executed. bin/fm-spawn.sh owns where the axis lands (the
# per-task settings file, the task record, and the appended system prompt) and
# when it is refused; bin/fm-control.sh asks the same probe before it stops a
# running agent for a relaunch. docs/configuration.md "Crew dispatch profiles"
# owns the profile field.
#
#   fm_advisor_value_valid <value>
#       Succeeds when <value> is a model alias or id Claude Code could name:
#       letters, digits, dot, underscore, and dash only. The value reaches a
#       JSON settings file and a command line, so nothing else is accepted.
#
#   fm_advisor_probe <main-model> <advisor>
#       Asks the installed claude whether <advisor> may advise <main-model>,
#       using `claude [--model <main-model>] --advisor <advisor> -p` with empty
#       stdin. Claude Code checks the pairing before it reads a prompt, so the
#       probe never reaches a model and costs no tokens. An empty or `default`
#       main model omits --model, so the probe judges the same default the
#       launch would use. Succeeds only on Claude Code's "Input must be
#       provided" refusal with no "cannot advise" warning. "cannot be used as an
#       advisor" or "cannot advise" (accepted at startup, then left unused for
#       the main model) refuses, and so does any other outcome: a missing
#       claude, an unknown flag, a timeout, or unrecognized output. A refusal
#       prints one error line naming the pair and the probe's own first line.
#       FM_ADVISOR_PROBE_TIMEOUT bounds it (default 60 seconds).
#
#   fm_advisor_cadence_prompt <main-model>
#       Prints, as one line, the consultation-timing block Anthropic's advisor
#       tool documentation recommends for coding work, because an executor
#       without it rarely consults. A Haiku main model receives the documented
#       Haiku coding block instead; any other or default main model receives
#       the general coding timing and advice blocks.
set -u

fm_advisor_value_valid() {
  case "${1:-}" in
  '' | *[!A-Za-z0-9._-]* | [!A-Za-z0-9]*) return 1 ;;
  esac
  return 0
}

fm_advisor_probe() {
  local model=${1:-} advisor=${2:-} bound=${FM_ADVISOR_PROBE_TIMEOUT:-60} out rc=0 first
  local -a args
  case "$bound" in '' | *[!0-9]* | 0*) bound=60 ;; esac
  if ! command -v claude >/dev/null 2>&1; then
    echo "error: advisor '$advisor' cannot be checked: claude executable not found on PATH" >&2
    return 1
  fi
  args=()
  [ -z "$model" ] || [ "$model" = default ] || args+=(--model "$model")
  args+=(--advisor "$advisor" -p)
  if ! command -v fm_run_timed >/dev/null 2>&1; then
    # shellcheck source=bin/fm-timeout-lib.sh
    . "$(dirname "${BASH_SOURCE[0]}")/fm-timeout-lib.sh"
  fi
  out=$(cd / && fm_run_timed "$bound" claude "${args[@]}" </dev/null 2>&1) || rc=$?
  if printf '%s\n' "$out" | grep -q 'cannot be used as an advisor\|cannot advise'; then
    first=$(printf '%s\n' "$out" | grep -m1 'cannot be used as an advisor\|cannot advise')
    echo "error: advisor '$advisor' is refused for main model '${model:-default}': $first" >&2
    return 1
  fi
  if printf '%s\n' "$out" | grep -q 'Input must be provided'; then
    return 0
  fi
  if [ "$rc" -eq 124 ]; then
    echo "error: advisor '$advisor' could not be checked for main model '${model:-default}': the claude pairing probe did not answer within ${bound}s" >&2
  else
    first=$(printf '%s\n' "$out" | sed -n '/./{p;q;}')
    echo "error: advisor '$advisor' could not be checked for main model '${model:-default}': unexpected claude pairing probe result (exit $rc): ${first:-no output}" >&2
  fi
  return 1
}

fm_advisor_cadence_prompt() {
  local model=${1:-}
  case "$model" in
  *[Hh]aiku*)
    cat <<'EOF'
Consult a stronger reviewer who sees your full conversation transcript.

No parameters. When you call advisor(), your entire history -- task, every tool call and result, your reasoning -- is automatically forwarded. The advisor sees exactly what you've done.

Call advisor BEFORE substantive work -- before writing, before committing to an interpretation, before building on an assumption. If the task requires orientation first (finding files, fetching a source, seeing what's there), do that, then call advisor. Orientation is not substantive work. Writing, editing, and declaring an answer are.

Also call advisor:
- When you believe the task is complete. BEFORE this call, make your deliverable durable: write the file, save the result, commit the change. The advisor call takes time; if the session ends during it, a durable result persists and an unwritten one doesn't.
- When stuck -- errors recurring, approach not converging, results that don't fit.
- When considering a change of approach.

On tasks longer than a few steps, call advisor at least once before committing to an approach and once before declaring done. On short reactive tasks where the next action is dictated by tool output you just read, you don't need to keep calling -- the advisor adds most of its value on the first call, before the approach crystallizes.

Give the advice serious weight. If you follow a step and it fails empirically, or you have primary-source evidence that contradicts a specific claim (the file says X, the paper states Y), adapt. A passing self-test is not evidence the advice is wrong -- it's evidence your test doesn't check what the advice is checking.

If you've already retrieved data pointing one way and the advisor points another: don't silently switch. Surface the conflict in one more advisor call -- "I found X, you suggest Y, which constraint breaks the tie?" The advisor saw your evidence but may have underweighted it; a reconcile call is cheaper than committing to the wrong branch.

Call advisor for design, architecture, and risk questions where you won't touch a file. If your response would be analysis or a recommendation with no other tool calls, call advisor first -- that judgment call is exactly where a second opinion is highest-value.

Hard rule: your first write_file, edit_file, or state-changing bash call on a task must be preceded by an advisor call in the same or an earlier turn. Read-only orientation commands (ls, cat, grep, find) are not state-changing. This is a checkpoint, not a difficulty judgment. It applies to one-line edits too.
EOF
    ;;
  *)
    cat <<'EOF'
You have access to an `advisor` tool backed by a stronger reviewer model. It takes NO parameters -- when you call advisor(), your entire conversation history is automatically forwarded. They see the task, every tool call you've made, every result you've seen.

Call advisor BEFORE substantive work -- before writing, before committing to an interpretation, before building on an assumption. If the task requires orientation first (finding files, fetching a source, seeing what's there), do that, then call advisor. Orientation is not substantive work. Writing, editing, and declaring an answer are.

Also call advisor:
- When you believe the task is complete. BEFORE this call, make your deliverable durable: write the file, save the result, commit the change. The advisor call takes time; if the session ends during it, a durable result persists and an unwritten one doesn't.
- When stuck -- errors recurring, approach not converging, results that don't fit.
- When considering a change of approach.

On tasks longer than a few steps, call advisor at least once before committing to an approach and once before declaring done. On short reactive tasks where the next action is dictated by tool output you just read, you don't need to keep calling -- the advisor adds most of its value on the first call, before the approach crystallizes.

Give the advice serious weight. If you follow a step and it fails empirically, or you have primary-source evidence that contradicts a specific claim (the file says X, the paper states Y), adapt. A passing self-test is not evidence the advice is wrong -- it's evidence your test doesn't check what the advice is checking.

If you've already retrieved data pointing one way and the advisor points another: don't silently switch. Surface the conflict in one more advisor call -- "I found X, you suggest Y, which constraint breaks the tie?" The advisor saw your evidence but may have underweighted it; a reconcile call is cheaper than committing to the wrong branch.
EOF
    ;;
  esac | awk 'NF { printf "%s%s", sep, $0; sep = " " } END { printf "\n" }'
}
