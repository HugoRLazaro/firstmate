# fm-pr-merge.sh adversarial drives (real script; gh faked, no GitHub call)

## protection-names-no-check  (args: )
```
protection: {"checks":[],"contexts":[]}
rollup: [{"n":"resultado","s":"COMPLETED","c":"SUCCESS"},{"n":"unit-gate","s":"COMPLETED","c":"FAILURE"}]
exit: 1
error: refusing to merge https://github.com/example/repo/pull/201
  - check 'unit-gate' is not green
error: these checks are not green: unit-gate
gh pr merge: NOT invoked
```

## required-status-context-pending  (args: )
```
protection: {"contexts":["resultado"]}
rollup: [{"n":"resultado","s":"PENDING","c":null},{"n":"unit-gate","s":"COMPLETED","c":"SUCCESS"}]
exit: 1
error: refusing to merge https://github.com/example/repo/pull/202
  - check 'resultado' is not green
error: these checks are not green: resultado
gh pr merge: NOT invoked
```

## required-status-context-green-legacy-contexts-only  (args: )
```
protection: {"contexts":["resultado"]}
rollup: [{"n":"resultado","s":"SUCCESS","c":null},{"n":"unit-gate","s":"COMPLETED","c":"FAILURE"}]
exit: 0
warning: non-required check 'unit-gate' is FAILURE; it does not block this merge
verified: https://github.com/example/repo/pull/203 is open and mergeable, with every required check green at head bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
gh pr merge: pr merge 203 --repo example/repo --match-head-commit bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb --squash
```

## attended-allow-red-required  (args: --allow-red resultado)
```
protection: {"checks":[{"context":"resultado"},{"context":"lint"}]}
rollup: [{"n":"resultado","s":"COMPLETED","c":"FAILURE"},{"n":"lint","s":"COMPLETED","c":"SUCCESS"}]
exit: 0
verified: https://github.com/example/repo/pull/204 is open and mergeable, with every required check green except the waived 'resultado' at head bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
gh pr merge: pr merge 204 --repo example/repo --match-head-commit bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb --squash
```

## allow-red-while-away-refused  (args: --allow-red resultado)
```
protection: {"checks":[{"context":"resultado"},{"context":"lint"}]}
away record: present (grant task-x1)
rollup: [{"n":"resultado","s":"COMPLETED","c":"FAILURE"},{"n":"lint","s":"COMPLETED","c":"SUCCESS"}]
exit: 2
error: --allow-red is attended-only; while the away-posture record exists the green check is absolute
gh pr merge: NOT invoked
```

## lookalike-name-does-not-satisfy-required  (args: )
```
protection: {"checks":[{"context":"resultado","app_id":15368}],"contexts":["resultado"]}
rollup: [{"n":"resultado-extra","s":"COMPLETED","c":"SUCCESS"},{"n":"resultado","s":"COMPLETED","c":"FAILURE"}]
exit: 1
error: refusing to merge https://github.com/example/repo/pull/206
  - check 'resultado' is not green
error: these checks are not green: resultado
gh pr merge: NOT invoked
```

## away-all-green-merges  (args: )
```
protection: {"checks":[{"context":"resultado","app_id":15368}],"contexts":["resultado"]}
away record: present (grant task-x1)
rollup: [{"n":"resultado","s":"COMPLETED","c":"SUCCESS"},{"n":"lint","s":"COMPLETED","c":"SUCCESS"}]
exit: 0
verified: https://github.com/example/repo/pull/207 is open and mergeable, with every required check green at head bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
gh pr merge: pr merge 207 --repo example/repo --match-head-commit bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb --squash
```

## required-absent-attended-admin-allow-red-other  (args: --allow-red lint --attended-override -- --admin)
```
protection: {"checks":[{"context":"resultado","app_id":15368}],"contexts":["resultado"]}
rollup: [{"n":"lint","s":"COMPLETED","c":"SUCCESS"}]
exit: 1
error: refusing to merge https://github.com/example/repo/pull/208
  - required check 'resultado' has not reported at this head
error: these checks are not green: resultado
gh pr merge: NOT invoked
```

