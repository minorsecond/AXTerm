# Continuous integration

AXTerm's CI runs on GitHub Actions with a self-hosted macOS runner, a Mac
with Xcode that GitHub hands jobs to. A hosted Mac would bill macOS minutes
at ten times the Linux rate, and the nightly soaks run for hours.

## What runs

| Workflow | When | What |
|---|---|---|
| `CI` (`.github/workflows/ci.yml`) | every push and pull request | macOS build and the full unit suite, then the iOS build |
| `Nightly soak` (`.github/workflows/nightly.yml`) | 02:00 Mountain daylight time, or by hand | growth fuzz (5,000 seeds), every stress family (200 seeds), property tests (20,000 cases, a fresh seed base each night), the sound modem with noise (2,000 cases), full-stack fuzz of transfers, Winlink, the mailbox and the node (200 seeds each) |

Both call `Scripts/ci/run.sh` (`unit`, `ios`, `soak`), so a local run uses
the same flags:

```bash
Scripts/ci/run.sh unit
```

The script builds into `build/ci/DerivedData`, not the shared DerivedData,
so a CI run does not replace the app a developer is running from Xcode. Logs,
result bundles and the soak reports go to `build/ci/`, and the workflows keep
them as artifacts (7 days for CI, 30 for the soaks). Each job's summary page
lists the failing tests.

Tests that need a TNC, a radio or the network are excluded by name in the
script (`LIVE_TESTS`). They also skip themselves without their flag files,
but CI runs on a Mac that is also used on the air, and a leftover
`/tmp/axterm_rf_tests_enabled` must never let a CI run transmit. A new live
test class has to be added to that list.

A night the runner is asleep or offline, GitHub holds the scheduled job and
runs it when the runner comes back, for up to a day. Scheduled workflows run
from the default branch only.

The soak sizes can be changed for a manual run from the workflow's
"Run workflow" button.

## The runner

The runner is GitHub's `actions/runner`, registered to this repository with
the labels `self-hosted`, `macOS` and `axterm`, and installed as a launch
agent so it runs whenever the user is logged in. It needs the Xcode that
builds the project and the signing identity the project uses, both of which
a development Mac already has.

Setting one up (the token comes from Settings › Actions › Runners › New
self-hosted runner, or `gh api -X POST repos/minorsecond/AXTerm/actions/runners/registration-token`):

```bash
mkdir -p ~/actions-runner && cd ~/actions-runner
# download and unpack the macOS arm64 release from github.com/actions/runner/releases
./config.sh --url https://github.com/minorsecond/AXTerm --token <TOKEN> --labels axterm --name "$(scutil --get LocalHostName)" --unattended
./svc.sh install
./svc.sh start
```

`./svc.sh stop` pauses it; `./svc.sh uninstall` and `./config.sh remove
--token <TOKEN>` take it off the machine and out of the repository.

Jobs run as the logged-in user, launch the AXTerm test host as an app and
use the CPU heavily while they run.

The repository is public, so the runner must never run a fork's code. The
CI job skips pull requests whose branch lives in a fork, and the
repository setting Settings › Actions › General › "Fork pull request
workflows" should be set to require approval for all outside
collaborators as a second guard.
