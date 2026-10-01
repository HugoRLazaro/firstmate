# Evidence: disk guard against WSL/Windows host-disk exhaustion

Change: `484682e` "refuse launches and warn before the host disk fills" (firstmate).

The host this ran on is the machine from the incident report: WSL2
(`6.18.33.2-microsoft-standard-WSL2`), real `/mnt/c` at ~10.7 GB free (99 %),
and a real 712 MB `wsl-crashes` folder, so the live readings below are the
production readings, not fixtures.

| Artifact | What it shows |
| --- | --- |
| `live-host-disk.txt` | Live `status`, a real low-disk episode over the real `/mnt/c` (reported once, silent on the repeat), and a live `guard` above the 10 GB floor |
| `guard-refusal.txt` | The measured incident reading (482 kB free) refuses with exit 3, names reading/floor/root reading/override, and `FM_DISK_GUARD=off` vs `FM_MEMORY_GUARD=off` independence |
| `adversarial.txt` | `FM_DISK_GUARD=off` does not waive a low memory floor; a malformed (negative) reading warns and allows and never opens an episode; `alert_host_disk_free_mb=0` silences; a raised `spawn_host_disk_free_mb` refuses |
| `non-wsl.txt` | A non-WSL kernel: guard silent, `disk-check` silent, `status` says there is no host disk, `arm` writes only the memory check; an unmounted host disk on WSL warns and launches |
| `arm-disarm.txt` | `arm` writes and registers both shims, `arm --missing` leaves an operator's existing check byte-identical and arms only the absent one, `disarm` removes shims/bindings/episode records |
| `watcher-live-check.txt` | The armed disk check reaches the real watcher poll (`fm-watch-checkpoint.sh`) as a `check:` wake carrying the live low-disk line and records the episode |
| `brief-rule8.txt` | The emitted ship and scout briefs' rule 8 (node/vitest worker bounds, free-space check before many-GB writes, intermediate-data cleanup) and the named commands run |
| `teardown-data-size.log` | Targeted end-to-end teardown drive: reports `data/task-x1 3 MB` and removes nothing |
| `changed-path-mapping.txt` | `bin/fm-test-run.sh --changed` selects 221 suites for this diff with exit 0 and no unmapped path for the new `tests/assets/diskinfo-healthy` |
| `fm-memory-suite.log` | Full `tests/fm-memory.test.sh`, all cases pass, including real `fm-spawn.sh`/`fm-control.sh relaunch` refusal under the disk floor and the armed-check watcher wake |
| `fm-bootstrap-suite-no-typekey.log` | `tests/fm-bootstrap.test.sh` 30/30 with the host's leaked `TYPESAFE_API_KEY` unset, including the arming case |
| `fm-brief-suite.log` | Full `tests/fm-brief.test.sh`, 26/26 |
| `fm-bootstrap-suite.log` | First bootstrap run: the one unrelated failure from the leaked `TYPESAFE_API_KEY`, which aborted the suite early |
| `fm-teardown-suite.log` | The full teardown suite cannot run on this host: it needs the globally installed `tasks-axi` binary that CI installs; the new case was driven through a targeted derived copy instead |
