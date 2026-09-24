# Large task inventory (the --argjson tasks half of the defect)

Fixture: 1200 normal state/*.meta task files -> contribution tasks JSON =
296516 bytes, past Linux MAX_ARG_STRLEN (131072).

## Before the fix (base d7a5ea3)
```
$ FM_HOME=<fixture> bash base/bin/fm-fleet-snapshot.sh --contribution-input
exit=0, stdout=0 bytes
stderr: /tmp/fm-validate-test/base/bin/fm-fleet-snapshot.sh: line 1978: /home/hugorl/.local/bin/jq: Argument list too long
```

## After the fix (head 0357fed)
```
$ FM_HOME=<fixture> bash bin/fm-fleet-snapshot.sh --contribution-input
exit=0, stdout=296516 bytes, stderr=[]
jq '.tasks|length' -> 1200
```

The tasks JSON is staged to a file too, so a large task inventory no longer
overflows argv.
