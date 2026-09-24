# Behavior preserved on unchanged inputs and other output modes

## contribution-input, normal backlog: base vs head byte-identical
```diff
(no differences)
```
head output: {"backlog":{"path":"/tmp/fm-validate-test/home-normal/data/backlog.md","present":true,"records":[{"order":1,"state":"in_flight","structured":true,"id":"scout-task","checked":false,"title":"Scout Task","repo":"alpha","kind":"scout","priority":null,"hold_reason":null,"hold_kind":null,"hold_until":null,"hold_set":null,"blocked_by":null,"blocked_by_ids":[],"blocked_reason":null,"since":"2026-07-07","merged":null,"reported":null,"done":null,"completion":{"verb":null,"date":null},"links":[],"pr_url":null,"report_path":"data/scout-task/report.md","local_note":null,"raw":"- [ ] scout-task - Scout Task data/scout-task/report.md (repo: alpha) (kind: scout) (since 2026-07-07)","body_lines":[],"body_excerpt":null,"unresolved_blocker_ids":[],"current_role":"worker","requires_child_metadata":true,"hold_age_days":79,"hold_bucket":null,"captain_actionable":false},{"order":2,"state":"in_flight","structured":true,"id":"ship-task","checked":false,"title":"Ship Task","repo":"alpha","kind":"ship","priority":"2","hold_reason":null,"hold_kind":null,"hold_until":null,"hold_set":null,"blocked_by":null,"blocked_by_ids":[],"blocked_reason":null,"since":"2026-07-07","merged":null,"reported":null,"done":null,"completion":{"verb":null,"date":null},"links":["https://github.com/kunchenguid/firstmate/pull/9"],"pr_url":"https://github.com/kunchenguid/firstmate/pull/9","report_path":null,"local_note":null,"raw":"- [ ] ship-task - Ship Task https://github.com/kunchenguid/firstmate/pull/9 (repo: alpha) (kind: ship) (priority: 2) (since 2026-07-07)","body_lines":[],"body_excerpt":null,"unresolved_blocker_ids":[],"current_role":"worker","requires_child_metadata":true,"hold_age_days":79,"hold_bucket":null,"captain_actionable":false},{"order":3,"state":"queued","structured":true,"id":"queued-task","checked":false,"title":"Queued Task","repo":"alpha","kind":"ship","priority":null,"hold_reason":null,"hold_kind":null,"hold_until":null,"hold_set":null,"blocked_by":"ship-task","blocked_by_ids":["ship-task"],"blocked_reason":null,"since":"2026-07-08","merged":null,"reported":null,"done":null,"completion":{"verb":null,"date":null},"links":[],"pr_url":null,"report_path":null,"local_note":null,"raw":"- [ ] queued-task - Queued Task blocked-by: ship-task (repo: alpha) (kind: ship) (since 2026-07-08)","body_lines":[],"body_excerpt":null,"unresolved_blocker_ids":["ship-task"],"current_role":"queued","requires_child_metadata":false,"hold_age_days":78,"hold_bucket":null,"captain_actionable":false},{"order":4,"state":"done","structured":true,"id":"done-task","checked":true,"title":"Done Task","repo":"alpha","kind":"ship","priority":null,"hold_reason":null,"hold_kind":null,"hold_until":null,"hold_set":null,"blocked_by":null,"blocked_by_ids":[],"blocked_reason":null,"since":null,"merged":"2026-07-06","reported":null,"done":null,"completion":{"verb":"merged","date":"2026-07-06"},"links":["https://github.com/kunchenguid/firstmate/pull/7"],"pr_url":"https://github.com/kunchenguid/firstmate/pull/7","report_path":null,"local_note":null,"raw":"- [x] done-task - Done Task https://github.com/kunchenguid/firstmate/pull/7 (repo: alpha) (kind: ship) (merged 2026-07-06)","body_lines":[],"body_excerpt":null,"unresolved_blocker_ids":[],"current_role":"done","requires_child_metadata":false,"hold_age_days":null,"hold_bucket":null,"captain_actionable":false}]},"tasks":[{"id":"ship-task","kind":"ship","pr":{"url":"https://github.com/kunchenguid/firstmate/pull/9","head":"0123456789abcdef0123456789abcdef01234567"},"merge_authority":"attended"}]}

## contribution-input, missing backlog: base vs head byte-identical
```
base: {"backlog":{"path":"/tmp/fm-validate-test/home-empty/data/backlog.md","present":false,"records":[]},"tasks":[]}
head: {"backlog":{"path":"/tmp/fm-validate-test/home-empty/data/backlog.md","present":false,"records":[]},"tasks":[]}
```

## --secondmate-home-summary, large backlog
base and head differ only in the observation timestamp:
```diff
--- /tmp/fm-validate-test/base-summary.json	2026-09-24 21:38:53.506665808 +0200
+++ /tmp/fm-validate-test/head-summary.json	2026-09-24 21:38:52.978346348 +0200
@@ -20,8 +20,8 @@
     "captain": [],
     "captain_omitted": 0
   },
-  "generated": "2026-09-24T19:38:53Z",
-  "generated_epoch": 1790278733,
+  "generated": "2026-09-24T19:38:52Z",
+  "generated_epoch": 1790278732,
   "home": "/tmp/fm-validate-test/home-large",
   "valid": false,
   "reason": "unstructured current backlog row",
```

## Other consumers, large backlog (all exit 0, stderr empty)
```
fm-fleet-snapshot.sh --json     : 2411145 bytes, schema/backlog check true
fm-fleet-view.sh (rendered)     : 2402964 bytes, 57 lines
fm-bearings-snapshot.sh --json  : 1673 bytes, schema fm-bearings.v1 true
fm-contributions.sh arm --if-owned : exit 0, stderr=[]
fm-contributions.sh poll        : exit 0, stdout=[] stderr=[]
```

## Temp transport dirs are reaped (EXIT trap)
```
leftover /tmp/fm-fleet-snapshot.XXXXXX dirs after a --contribution-input run: 0
```
