# Large backlog: --contribution-input (the reported defect)

Fixture: data/backlog.md with 40 free-form "Queued" lines x 60,000 chars of
padding (2401541 bytes) - the same shape as the new
tests/fm-fleet-snapshot-view.test.sh regression case.

## Before the fix (base d7a5ea3, worktree copy in /tmp)
```
$ FM_HOME=<fixture> bash /tmp/fm-validate-test/base/bin/fm-fleet-snapshot.sh --contribution-input
exit=0 (the script swallows jq's failure), stdout=0 bytes
stderr: /tmp/fm-validate-test/base/bin/fm-fleet-snapshot.sh: line 1978: /home/hugorl/.local/bin/jq: Argument list too long
```
Silent empty output is the defect: the fleet photo / bootstrap sees no backlog.

## After the fix (head 0357fed)
```
$ FM_HOME=<fixture> bash bin/fm-fleet-snapshot.sh --contribution-input
exit=0, stdout=2409136 bytes, stderr=[]
$ jq -e '.backlog.present == true and (.backlog.records|length) == 40 and (.tasks|length) == 0'
true
```

The 2.4 MB payload now travels through the transport file (jq --slurpfile),
so neither the backlog JSON nor the tasks JSON is an argument any more.
