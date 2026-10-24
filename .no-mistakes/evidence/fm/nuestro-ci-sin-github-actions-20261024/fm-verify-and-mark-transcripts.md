# fm-verify-and-mark.sh drives (real script against a local bare origin; gh faked so nothing reaches GitHub)

## green — exit 0
```
$ fm-verify-and-mark.sh verify-task https://github.com/acme/project/pull/7
verify: https://github.com/acme/project/pull/7 head=2605810ae7f4eee305d5c9ea06afc20809120cea
step: ci_entorno_python.sh
step: verify_main.sh --set puertas
step: verify_main.sh --set humo
green: 2605810ae7f4eee305d5c9ea06afc20809120cea passed puertas and humo; nothing is published to GitHub
record: /tmp/fm-verify-and-mark.7EaJ4d/green/state/verify-task.verify (green)
--- state/verify-task.verify ---
outcome=green
pr=https://github.com/acme/project/pull/7
head=2605810ae7f4eee305d5c9ea06afc20809120cea
base=ba3d715b9a5e4b843c46ae5f790cb68661ff5105
at=2026-10-24T04:59:04Z
log=/tmp/fm-verify-and-mark.7EaJ4d/green/state/verify/verify-task/2605810ae7f4eee305d5c9ea06afc20809120cea.log
--- run log ---
verify: https://github.com/acme/project/pull/7 head=2605810ae7f4eee305d5c9ea06afc20809120cea
step: ci_entorno_python.sh
step: verify_main.sh --set puertas
step: verify_main.sh --set humo
green: 2605810ae7f4eee305d5c9ea06afc20809120cea passed puertas and humo; nothing is published to GitHub
--- gh calls ---
api repos/acme/project/pulls/7 --jq .head.sha
repo clone acme/project /tmp/fm-verify-and-mark.7EaJ4d/green/state/verify/verify-task/repo -- --filter=blob:none --no-checkout --quiet
api repos/acme/project/pulls/7 --jq .head.sha
--- POSTs to GitHub ---
none
--- what the steps saw ---
set=puertas base=ba3d715b9a5e4b843c46ae5f790cb68661ff5105 python=/usr/bin/python3 database_url=absent cache=/tmp/fm-verify-and-mark.7EaJ4d/green/state/verify/verify-task/venv-cache
set=humo base=ba3d715b9a5e4b843c46ae5f790cb68661ff5105 python=/usr/bin/python3 database_url=absent cache=/tmp/fm-verify-and-mark.7EaJ4d/green/state/verify/verify-task/venv-cache
--- state/verify/verify-task ---
2605810ae7f4eee305d5c9ea06afc20809120cea.log
env
repo
venv-cache
```

## red — exit 1
```
$ fm-verify-and-mark.sh verify-task https://github.com/acme/project/pull/7
verify: https://github.com/acme/project/pull/7 head=8d169955d5c0c659ab6f0f2263e10dc371b1972f
step: ci_entorno_python.sh
step: verify_main.sh --set puertas
red: the puertas verification failed
red: nothing is published for 8d169955d5c0c659ab6f0f2263e10dc371b1972f
record: /tmp/fm-verify-and-mark.7EaJ4d/red/state/verify-task.verify (red)
--- state/verify-task.verify ---
outcome=red
pr=https://github.com/acme/project/pull/7
head=8d169955d5c0c659ab6f0f2263e10dc371b1972f
base=a0cdc675f0b8f89fd02501726a93738e5fa948e5
at=2026-10-24T04:59:04Z
log=/tmp/fm-verify-and-mark.7EaJ4d/red/state/verify/verify-task/8d169955d5c0c659ab6f0f2263e10dc371b1972f.log
detail=a verification step failed
--- run log ---
verify: https://github.com/acme/project/pull/7 head=8d169955d5c0c659ab6f0f2263e10dc371b1972f
step: ci_entorno_python.sh
step: verify_main.sh --set puertas
red: the puertas verification failed
red: nothing is published for 8d169955d5c0c659ab6f0f2263e10dc371b1972f
--- gh calls ---
api repos/acme/project/pulls/7 --jq .head.sha
repo clone acme/project /tmp/fm-verify-and-mark.7EaJ4d/red/state/verify/verify-task/repo -- --filter=blob:none --no-checkout --quiet
--- POSTs to GitHub ---
none
--- what the steps saw ---
set=puertas base=a0cdc675f0b8f89fd02501726a93738e5fa948e5 python=/usr/bin/python3 database_url=absent cache=/tmp/fm-verify-and-mark.7EaJ4d/red/state/verify/verify-task/venv-cache
--- state/verify/verify-task ---
8d169955d5c0c659ab6f0f2263e10dc371b1972f.log
env
repo
venv-cache
```

## drift — exit 3
```
$ fm-verify-and-mark.sh verify-task https://github.com/acme/project/pull/7
verify: https://github.com/acme/project/pull/7 head=ba02f2a4e46dab0a5844581af08e1aafc912d656
unverified: .github/workflows/verify-main.yml no longer runs 'scripts/verify_main.sh --set humo --in-ci --base'; update this script first
record: /tmp/fm-verify-and-mark.7EaJ4d/drift/state/verify-task.verify (unverified)
stderr: unverified: .github/workflows/verify-main.yml no longer runs 'scripts/verify_main.sh --set humo --in-ci --base'; update this script first
--- state/verify-task.verify ---
outcome=unverified
pr=https://github.com/acme/project/pull/7
head=ba02f2a4e46dab0a5844581af08e1aafc912d656
base=4311aaa70f7b9f94f4fb57b08dbaee54443fd3e3
at=2026-10-24T04:59:04Z
log=/tmp/fm-verify-and-mark.7EaJ4d/drift/state/verify/verify-task/ba02f2a4e46dab0a5844581af08e1aafc912d656.log
detail=.github/workflows/verify-main.yml no longer runs 'scripts/verify_main.sh --set humo --in-ci --base'; update this script first
--- run log ---
verify: https://github.com/acme/project/pull/7 head=ba02f2a4e46dab0a5844581af08e1aafc912d656
unverified: .github/workflows/verify-main.yml no longer runs 'scripts/verify_main.sh --set humo --in-ci --base'; update this script first
--- gh calls ---
api repos/acme/project/pulls/7 --jq .head.sha
repo clone acme/project /tmp/fm-verify-and-mark.7EaJ4d/drift/state/verify/verify-task/repo -- --filter=blob:none --no-checkout --quiet
--- POSTs to GitHub ---
none
--- what the steps saw ---
(no verify step ran)
--- state/verify/verify-task ---
ba02f2a4e46dab0a5844581af08e1aafc912d656.log
env
repo
venv-cache
```

## moved — exit 4
```
$ fm-verify-and-mark.sh verify-task https://github.com/acme/project/pull/7
verify: https://github.com/acme/project/pull/7 head=87dad112ce428f24e4eeabc012e6b5705fa85e9c
step: ci_entorno_python.sh
step: verify_main.sh --set puertas
step: verify_main.sh --set humo
moved: the pull request head changed during verification; nothing is published
record: /tmp/fm-verify-and-mark.7EaJ4d/moved/state/verify-task.verify (moved)
--- state/verify-task.verify ---
outcome=moved
pr=https://github.com/acme/project/pull/7
head=87dad112ce428f24e4eeabc012e6b5705fa85e9c
base=8f3dda0988a3e2b686e3b93bcdedf560dc486bcf
at=2026-10-24T04:59:04Z
log=/tmp/fm-verify-and-mark.7EaJ4d/moved/state/verify/verify-task/87dad112ce428f24e4eeabc012e6b5705fa85e9c.log
detail=head changed after verification
--- run log ---
verify: https://github.com/acme/project/pull/7 head=87dad112ce428f24e4eeabc012e6b5705fa85e9c
step: ci_entorno_python.sh
step: verify_main.sh --set puertas
step: verify_main.sh --set humo
moved: the pull request head changed during verification; nothing is published
--- gh calls ---
api repos/acme/project/pulls/7 --jq .head.sha
repo clone acme/project /tmp/fm-verify-and-mark.7EaJ4d/moved/state/verify/verify-task/repo -- --filter=blob:none --no-checkout --quiet
api repos/acme/project/pulls/7 --jq .head.sha
--- POSTs to GitHub ---
none
--- what the steps saw ---
set=puertas base=8f3dda0988a3e2b686e3b93bcdedf560dc486bcf python=/usr/bin/python3 database_url=absent cache=/tmp/fm-verify-and-mark.7EaJ4d/moved/state/verify/verify-task/venv-cache
set=humo base=8f3dda0988a3e2b686e3b93bcdedf560dc486bcf python=/usr/bin/python3 database_url=absent cache=/tmp/fm-verify-and-mark.7EaJ4d/moved/state/verify/verify-task/venv-cache
--- state/verify/verify-task ---
87dad112ce428f24e4eeabc012e6b5705fa85e9c.log
env
repo
venv-cache
```

## green rerun — exit 0
```
stale marker in repo/ after rerun: gone
cache marker kept: /tmp/fm-verify-and-mark.7EaJ4d/green/state/verify/verify-task/venv-cache/KEEP_MARKER
```
