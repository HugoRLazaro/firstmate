# Local Test evidence — native Linux `tasks-axi` preference (fm/arranque-lento-tasks-axi-de-windows-20260924)

Base `de0188be` vs target `d8b6c901`, driven on the reported host: WSL2
(`DESKTOP-6P8M0SA`), captain PATH first entry `/mnt/c/Users/Hugo/AppData/Roaming/npm`
(Windows-side npm shim), native Linux build present off-PATH at
`/home/hugorl/.npm-global/bin/tasks-axi` (0.2.5).

How "which binary ran" was observed: a PATH-first `node` wrapper logged the JS
implementation each invocation executed (`/mnt/c/.../tasks-axi.js` vs
`/home/hugorl/.npm-global/bin/tasks-axi`). The product scripts ran for real; only
the home/backlog data was a fixture, and one fixture isolated the other npm tools
(native symlinks) so the measurement shows the tasks-axi change, not unrelated
Windows-side tools.

## Scenarios

1. **Native preferred over PATH order** — `bin/fm-tasks-axi.sh list` with the
   Windows npm dir first on PATH: base ran the `/mnt/c` implementation
   (1.36–1.77s); target ran the native one (0.13–0.15s).
   Evidence: `before-after-measurement.txt`.

2. **Per-read cost under the reported load** — 16 CPU spinners (the report's 20
   vitest workers on this 20-vCPU host): Windows `show` 17.08s (the reported
   ~17s), native `show` 0.449s; bootstrap bounds each reconcile read at 10s.
   Evidence: `per-read-cost-under-load.txt`.

3. **Bootstrap reconcile no longer trips the 10s read bound** — same command,
   same fixture, load 16. Base: 4 × `BACKLOG_RECONCILE ... tasks-axi show <id>
   exceeded/skipped ... 10s read bound`, nothing healed (63s). Target: 4 ×
   `BOOTSTRAP_INFO: marked <id> in flight`, backlog healed, every one of the 11
   tasks-axi calls native (37s).
   Evidence: `base-bootstrap-reconcile-read-bound.log`,
   `target-bootstrap-reconcile-heals.log`,
   `target-bootstrap-tasks-axi-invocations.log`.

4. **Session start completes instead of `STARTUP TRUNCATED`** — same command,
   same fixture, load 16. Base: 125s, `STARTUP TRUNCATED ... stopped during the
   "fleet-state" stage` after the bootstrap reconcile errors. Target: 103s,
   digest reaches `NEXT STEP ... The digest above is complete`, no banner, all 15
   tasks-axi calls native (compat probes, per-task `show`/`start`, and the four
   compact-listing reads).
   Evidence: `base-session-start-truncated.log`,
   `target-session-start-complete.log`,
   `target-session-start-tasks-axi-invocations.log`.

5. **Fallback preserved when no native build exists** — PATH keeps the Windows
   copy first and `HOME` has no native install: the home still runs the `/mnt/c`
   implementation (previous behavior kept).
   Evidence: `target-fallback-windows-when-no-native.log`.

6. **Off-PATH native binary counts as present in bootstrap** — `MISSING: tasks-axi
   (install: npm install -g tasks-axi)` with the binary only off-PATH: base
   printed it, target printed nothing.
   Evidence: `base-offpath-tasks-axi-missing.log`,
   `target-offpath-tasks-axi-present.log`.

7. **Explicit `TASKS_AXI_BIN`** — a usable pin wins over PATH and the native
   binary; a *relative* pin (`pinbin/tasks-axi`, cwd `/tmp/fm-live`) still runs
   the same file after the wrapper's `cd` to the backlog root, proving it was
   resolved to an absolute path.
   Evidence: `target-pin-absolute-runs.log`, `target-pin-relative-runs.log`.

8. **Unusable `TASKS_AXI_BIN` stops loudly** — missing path, directory, and
   non-executable file all exit 2 with `TASKS_AXI_BIN names <path>, which is not
   an executable file; refusing to resolve a different tasks-axi`, and no other
   binary runs. Bootstrap with the bad pin exits 2 with the same line and prints
   **no** `MISSING: tasks-axi (install: ...)` diagnostic.
   Evidence: `target-pin-nonexistent-refused.log`,
   `target-pin-directory-refused.log`, `target-pin-nonexec-refused.log`,
   `target-badpin-bootstrap-stops.log`.

9. **Adversarial: non-executable candidates are never chosen** — a directory
   named `tasks-axi` in `$HOME/.npm-global/bin`, and one in a PATH entry before
   the Windows copy, are both skipped and the home falls back to a real binary.
   (Ran in the same session as scenario 5; target only.)

10. **Mutation call sites follow the resolved binary** — `fm-backlog-receive.sh`
    moved the delivered item with the native binary (base: `/mnt/c` impl) and
    `fm-backlog-handoff.sh` moved the routed item with the native binary (base:
    `/mnt/c` impl). The handoff's receiver doorbell was refused afterwards by
    `NO_MISTAKES_GATE` (fleet-driving guard), which is expected inside a gate
    agent and does not affect the delegated `mv` the change owns.
    Evidence: `target-receive-mv-native.log`, `base-receive-mv-windows.log`,
    `target-handoff-mv-native.log`, `base-handoff-mv-windows.log`.

11. **Availability probes follow the resolved binary** — with no `tasks-axi` on
    PATH and the native build off-PATH: base refused `fm-public-followup.sh
    register` with `tasks-axi is required` and `fm-captain-hold.sh hold` with
    `compatible tasks-axi is required`; target proceeded through the wrapper to
    the native binary (captain hold landed: `held: yes`, `hold_kind: captain`).
    `fm-remote-doctor.sh` reported `required tasks-axi=MISSING` at base and
    `required tasks-axi=/home/hugorl/.npm-global/bin/tasks-axi` at target.
    Evidence: `base-public-followup-tasks-axi-required.log`,
    `target-public-followup-register-offpath.log`,
    `base-captain-hold-compatible-required.log`,
    `target-captain-hold-native-offpath.log`,
    `base-remote-doctor-tasks-axi-missing.log`,
    `target-remote-doctor-tasks-axi-resolved.log`.

12. **`fm-send.sh --resolve-key` hold resolution with an off-PATH native binary**
    — could not be driven: `bin/fm-gate-refuse-lib.sh` refuses fleet-driving
    (`NO_MISTAKES_GATE` is stamped into this gate agent) before the hold lookup.
    Drive from a normal session.

## Targeted suites (changed files)

- `tests/fm-tasks-axi.test.sh` — all resolver/pin/per-task-read cases pass.
  Evidence: `fm-tasks-axi-suite-target.log`.
- `tests/fm-session-start.test.sh` — passes fully (54 assertions) once `jq` is on
  the suite PATH via `FM_TEST_BASE_PATH=/home/hugorl/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin`
  (this host keeps jq in `~/.local/bin`; without it the suite fails at its first
  case, identically at base). Evidence: `fm-session-start-suite-target.log`.
- `tests/fm-bootstrap.test.sh` — the new off-PATH case passes; the suite then hits
  a pre-existing host-dependent failure (`backend=herdr ... missing session CLI`,
  and without jq `no-key use-profile diagnostic`) that reproduces identically at
  base. Evidence: `fm-bootstrap-suite-target.log`, `fm-bootstrap-suite-base.log`.
