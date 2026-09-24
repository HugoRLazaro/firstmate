# Treehouse pool prune verification

Audience: maintainer verification.

This record supports the post-return pool prune owned by [`bin/fm-teardown.sh`](../../bin/fm-teardown.sh) (script header, "Pool prune after an accepted return").
It records only the facts that must be re-established when the Treehouse prune contract or its output format changes.
Task chronology and the delivery evidence for the change itself stay in the task's own records.

## What the prune must reclaim and leave alone

Verified 2026-09-24 against Treehouse `v2.3.0` on Linux, using one sandbox repository, one pool, and two leased slots: slot 1 carries landed task work (a 64 MiB payload committed and pushed to the default branch) and slot 2 is leased with an uncommitted file.
Commands, run from the project clone with `TREEHOUSE_ROOT` pointing at the sandbox pool:

```
treehouse return --force <slot-1>
treehouse prune --yes
```

Before the two commands `du -sh` on the pool read `65M` and `treehouse status` listed slots 1 and 2 as `leased`.
After them `du -sh` read `32K`, `treehouse status` listed only slot 2, slot 1's directory was gone, and slot 2's uncommitted file was untouched.
The `prune` output was exactly:

```
🌳 Pruned 1 stale worktree and freed 64 MiB.
```

Driven through `bin/fm-teardown.sh` on the same setup, the script's output was:

```
🌳 Worktree returned to pool.
teardown: pool prune for the worktree pool freed 64 MiB (1 copy)
teardown task-x1 complete (window firstmate:fm-task-x1, worktree <slot-1>; pool prune freed 64 MiB (1 copy))
```

The reclaimed count and size therefore appear both on their own line and on the task's completion line, so the freed disk is measurable from the teardown's own output.
A missing `treehouse` command and a `prune` that exits nonzero each warn on stderr and leave the teardown completing normally.

## Refreshing the evidence

The regression case that runs the real binary is `test_pool_prune_real_treehouse_reclaims_only_the_returned_copy` in [`tests/fm-teardown.test.sh`](../../tests/fm-teardown.test.sh).
Run it with `bin/fm-test-run.sh tests/fm-teardown.test.sh`; it skips when `treehouse` is not installed and otherwise asserts the reclaimed copy, the untouched in-use dirty copy, and the reported size.
