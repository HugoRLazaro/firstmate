# fm-pr-merge.sh required-check gate: real script output per case (gh faked; no GitHub call)

## github-required-only

```
protection: {"checks":[{"context":"resultado","app_id":15368}],"contexts":["resultado"]}
rollup: [{"n":"resultado","s":"COMPLETED","c":"SUCCESS"},{"n":"unit-gate","s":"COMPLETED","c":"FAILURE"}]
--- stderr ---
warning: non-required check 'unit-gate' is FAILURE; it does not block this merge
verified: https://github.com/example/repo/pull/90 is open and mergeable, with every required check green at head bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
--- gh pr merge invoked? ---
pr merge 90 --repo example/repo --match-head-commit bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb --squash
```

## github-required-red

```
protection: {"checks":[{"context":"resultado","app_id":15368}],"contexts":["resultado"]}
rollup: [{"n":"resultado","s":"COMPLETED","c":"FAILURE"}]
--- stderr ---
error: refusing to merge https://github.com/example/repo/pull/91
  - check 'resultado' is not green
error: these checks are not green: resultado
--- gh pr merge invoked? ---
NO (gh pr merge never ran)
```

## github-protection-unreadable

```
protection: <unreadable: gh api exits 1>
rollup: [{"n":"resultado","s":"COMPLETED","c":"SUCCESS"},{"n":"unit-gate","s":"COMPLETED","c":"FAILURE"}]
--- stderr ---
error: refusing to merge https://github.com/example/repo/pull/92
  - check 'unit-gate' is not green
error: these checks are not green: unit-gate
--- gh pr merge invoked? ---
NO (gh pr merge never ran)
```

## github-required-only-away

```
protection: {"checks":[{"context":"resultado","app_id":15368}],"contexts":["resultado"]}
rollup: [{"n":"resultado","s":"COMPLETED","c":"SUCCESS"},{"n":"unit-gate","s":"COMPLETED","c":"FAILURE"}]
away record: present
--- stderr ---
error: refusing to merge https://github.com/example/repo/pull/93
  - check 'unit-gate' is not green
error: these checks are not green: unit-gate
--- gh pr merge invoked? ---
NO (gh pr merge never ran)
```

## github-required-absent

```
protection: {"checks":[{"context":"resultado","app_id":15368}],"contexts":["resultado"]}
rollup: [{"n":"unit-gate","s":"COMPLETED","c":"SUCCESS"}]
--- stderr ---
error: refusing to merge https://github.com/example/repo/pull/94
  - required check 'resultado' has not reported at this head
error: these checks are not green: resultado
--- gh pr merge invoked? ---
NO (gh pr merge never ran)
```

## github-required-absent-away

```
protection: {"checks":[{"context":"resultado","app_id":15368}],"contexts":["resultado"]}
rollup: [{"n":"unit-gate","s":"COMPLETED","c":"SUCCESS"}]
away record: present
--- stderr ---
error: refusing to merge https://github.com/example/repo/pull/96
  - required check 'resultado' has not reported at this head
error: these checks are not green: resultado
--- gh pr merge invoked? ---
NO (gh pr merge never ran)
```

## github-non-required-in-progress

```
protection: {"checks":[{"context":"resultado","app_id":15368}],"contexts":["resultado"]}
rollup: [{"n":"resultado","s":"COMPLETED","c":"SUCCESS"},{"n":"unit-gate","s":"IN_PROGRESS","c":""}]
--- stderr ---
warning: non-required check 'unit-gate' is IN_PROGRESS; it does not block this merge
verified: https://github.com/example/repo/pull/97 is open and mergeable, with every required check green at head bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
--- gh pr merge invoked? ---
pr merge 97 --repo example/repo --match-head-commit bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb --squash
```

## github-required-only-away-after-view

```
protection: {"checks":[{"context":"resultado","app_id":15368}],"contexts":["resultado"]}
rollup: [{"n":"resultado","s":"COMPLETED","c":"SUCCESS"},{"n":"unit-gate","s":"COMPLETED","c":"FAILURE"}]
away record: present
away record: published by gh during the preflight view (after the pre-lock read)
--- stderr ---
warning: non-required check 'unit-gate' is FAILURE; it does not block this merge
verified: https://github.com/example/repo/pull/95 is open and mergeable, with every required check green at head bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
error: refusing to merge https://github.com/example/repo/pull/95
  - check 'unit-gate' is not green
error: these checks are not green: unit-gate
--- gh pr merge invoked? ---
NO (gh pr merge never ran)
```

