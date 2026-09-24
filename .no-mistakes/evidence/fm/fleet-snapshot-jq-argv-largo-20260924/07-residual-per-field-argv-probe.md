# Residual argv read: a single >128 KiB task metadata value (pre-existing, not a regression)

Fixture: one state/*.meta whose pr_head= line is 200,000 chars (a real pr_head
is a 40-char commit SHA). The 200 KiB value is passed to jq as a single --arg,
which is a different call than the --argjson lines this change fixed.

## Base d7a5ea3
```
exit=0, stdout=1203 bytes
stderr: /tmp/fm-probe-base/bin/fm-fleet-snapshot.sh: line 1969: /home/hugorl/.local/bin/jq: Argument list too long
```

## Head 0357fed
```
exit=0, stdout=1203 bytes
stderr: bin/fm-fleet-snapshot.sh: line 1969: /home/hugorl/.local/bin/jq: Argument list too long
jq '.tasks' -> []
The task is dropped from .tasks with the transport error only on stderr.
```

Base and head behave identically, so this is a pre-existing limitation of
contribution_tasks_json (bin/fm-fleet-snapshot.sh line 1969) and not a
regression or a gap in the --argjson transport this change replaced.
