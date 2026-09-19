# Backpass lane verification

Repeatable evidence for [`bin/fm-backpass-lane.sh`](../../bin/fm-backpass-lane.sh), the periodic backpass worker over an isolated byte-for-byte memory copy.
The lane's header owns its mechanics, budget resolution, provider pin, and review gate.
[`docs/configuration.md`](../configuration.md) owns the per-home startup-memory setting and states that its allowance covers a different surface, and [`docs/scripts.md`](../scripts.md) indexes the command.
This page records the dated adoption evidence only.

Date: 2026-09-19.
Host: the firstmate home under WSL.
Comparison base: local `main` at `7aa994c0`.

## Version under test: backpass 0.1.24

The version was installed privately with `npm install --prefix /tmp/fm-backpass-024 backpass@0.1.24`; nothing global changed.
A file-by-file diff against the installed 0.1.22 shows these changes that matter for this lane:

- the Pi transcript adapter is byte-identical, so corpus discovery and association are unchanged;
- a failing provider call now keeps and reports its non-empty stderr, and the failure classifier matches specific patterns before falling back to "empty output";
- a synthesis edit turn that leaves the staging copy unchanged now terminates immediately as `edit-empty` instead of burning retries that cannot succeed;
- `backpass init` no longer writes all-null `analysis`/`synthesis` blocks, so a repository config inherits a global pin instead of shadowing it;
- `apply` refuses skill writes when `skillsDir` changed between propose and apply.

The lane never calls `apply`, so the last two harden the tool for other users rather than for this lane.

## Isolated end-to-end run

Exact command, against a copy of the live home's memory while the live home was left untouched:

```bash
FM_BACKPASS_BIN=/tmp/fm-backpass-024/node_modules/.bin/backpass FM_HOME=/home/hugorl/firstmate \
  ./bin/fm-backpass-lane.sh --root /tmp/fm-backpass-lane-e2e2 --source /home/hugorl/firstmate --limit 2 \
  --acpx /tmp/fm-acpx-linux/node_modules/.bin/acpx
```

Output:

```console
backpass-lane: backpass 0.1.24
backpass-lane: budget 23975 (measured-surface-plus-margin)
backpass-lane: provider pi analysis=ollama-cloud/deepseek-v4.1-flash synthesis=ollama-cloud/kimi-k3
backpass-lane: corpus 20 transcript(s) associated
backpass-lane: proposal /tmp/fm-backpass-lane-e2e2/runs/20260919T092209Z/proposal.json (1 edit(s), cap 23975)
backpass-lane: live memory unchanged=yes
```

The measured always-loaded surface was 22,475 tokens (AGENTS.md plus skill descriptions), matching the 2026-09-19 evaluation, and the resolved budget is that surface plus the 1,500-token margin.
The proposal extracted the 4,488-token home file-tree into a load-on-trigger skill, a delta of -4,447 tokens, and carried 15 verdicts with its evidence.
The run record under the lane root names the budget resolution, the provider, the source manifests, and the review-gate verdict for the proposal's targets.

Live-memory verification after the run: `sha256sum -c` passed for AGENTS.md, CLAUDE.md, and all 39 skill files; `git -C /home/hugorl/firstmate status --porcelain` was empty; `/home/hugorl/firstmate/.backpass` was absent; and the live `.git/info/exclude` hash was unchanged.

## acpx latency constraint

backpass verifies a pinned model or effort by running `acpx config show` under a hard ten-second bound.
The Windows npm `acpx` 0.15.1 shim reached through WSL measured 4.19 s for `acpx --version` and 5.01-8.17 s for `acpx config show --format json`, so a run failed with `cannot verify acpx adapter configuration for pi: exit null`.
A Linux `acpx` 0.15.1 installed privately with `npm install --prefix /tmp/fm-acpx-linux acpx@0.15.1` answered the same command in 0.50-3.50 s, and the run above completed.
The lane exposes `--acpx` / `FM_BACKPASS_ACPX_BIN` for this, and its failed-run output points at it.
A durable setup therefore needs a local acpx copy or a PATH whose acpx answers inside the bound.

## Portable regression

`tests/fm-backpass-lane.test.sh` drives a stub backpass, so it spends no model tokens and runs in the portable serial lane.
It proves the byte-for-byte copy, the single budget resolution with the value passed equal to the proposal's own cap, the pinned provider argv, the never-apply contract, the stale-proposal guard on an empty corpus, the recorded review-gate verdict including a tiered `data/learnings.md` target, the default run root under the home's own `state/`, and the loud failure paths.

```console
$ tests/fm-backpass-lane.test.sh
ok - the lane copies, publishes, and leaves the live memory untouched
ok - an explicit budget and model override are pinned and passed through
ok - a covering house allowance becomes the budget
ok - a tiered target is reported as requiring the /stow gate
ok - an empty corpus stops before model spend and drops a stale proposal
ok - a failed backpass run is recorded and relayed
ok - a slow-acpx verification failure points at --acpx
ok - the default output lands under the home state directory
ok - a source without AGENTS.md is refused
$ bin/fm-lint.sh bin/fm-backpass-lane.sh tests/fm-backpass-lane.test.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-lint.sh: full ShellCheck extended analysis enabled
$ bin/fm-test-run.sh --check-coverage
FM_TEST_COVERAGE ok total=219 parallel=24 parallel_max_ms=417163 parallel_imbalance_ms=2894 parallel_unhinted=0 serial=179 serial_shards=9 serial_unhinted=3 herdr=16
```
