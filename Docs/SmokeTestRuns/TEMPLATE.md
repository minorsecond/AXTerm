# Smoke test run YYYY-MM-DD-N

Copy this file to `YYYY-MM-DD-N.md` to start a run. The plan is
[../SmokeTestPlan.md](../SmokeTestPlan.md). Update the resume point after
every test; commit this file after every layer and at every stop.

| | |
|---|---|
| Plan version | 1 |
| Commit under test | `<hash>` on `<branch>` |
| Started | YYYY-MM-DD HH:MM MDT |
| Ended | |
| Operator | |
| Driven by | Claude |

## Resume point

Rewrite this block after every test.

- **Updated:** HH:MM
- **Next:** S1 (setup)
- **Running:** nothing
- **A (705):** frequency, mode, power; Warbler transmit on/off
- **B (ID-50):** channel as last set by the operator; TNC4 on USB/Bluetooth
- **Station features on:** none (NODES advertising, beacons, digipeater)
- **Links up:** none
- **Interrupted:** none
- **To resume:** read this block, check the stations match it, run setup again
  if an instance was closed, re-run any interrupted test, then continue at
  "Next".

## Stations

| | A (705) | B (ID-50) |
|---|---|---|
| Callsign | K0EPI-2 | K0EPI-3 |
| Path to the radio | sound modem through Warbler `localhost:50100` | Mobilinkd TNC4, USB serial `<device>` |
| Firmware or version | AXTerm `<hash>`; Warbler `<version>` | TNC4 firmware `<version>` |
| TX delay | | 800 ms |

## Starting state (S6, before anything transmits)

| | Value |
|---|---|
| A (705) frequency | |
| A (705) mode | |
| A (705) power | |
| TNC4 output gain | |
| TNC4 output twist | |
| TNC4 input gain | |
| TNC4 input twist | |
| TNC4 modem type | |
| TNC4 PTT | |
| B (ID-50) channel (operator) | |

## Setup

| Step | Status | Time | Notes |
|---|---|---|---|
| S1 | — | | |
| S2 | — | | |
| S3 | — | | |
| S4 | — | | |
| S5 | — | | |
| S6 | — | | |

## Results

Status: `—` not run, `PASS`, `FAIL` (issue number), `RETEST PASS` (fix commit),
`BLOCKED` (why), `SKIP` (why, who decided). Evidence: file sums, log times,
frame counts, screenshots.

| ID | Status | Time | Notes and evidence |
|---|---|---|---|
| 0.1 | — | | |
| 0.2 | — | | |
| 1.1 | — | | |
| 1.2 | — | | |
| 1.3 | — | | |
| 1.4 | — | | |
| 1.5 | — | | |
| 1.6 | — | | |
| 2.1 | — | | |
| 2.2 | — | | |
| 2.3 | — | | |
| 3.1 | — | | |
| 3.2 | — | | |
| 3.3 | — | | |
| 3.4 | — | | |
| 3.5 | — | | |
| 3.6 | — | | |
| 3.7 | — | | |
| 3.8 | — | | |
| 3.9 | — | | |
| 3.10 | — | | |
| 4.1 | — | | |
| 4.2 | — | | |
| 4.3 | — | | |
| 4.4 | — | | |
| 4.5 | — | | |
| 4.6 | — | | |
| 5.1 | — | | |
| 5.2 | — | | |
| 5.3 | — | | |
| 5.4 | — | | |
| 5.5 | — | | |
| 5.6 | — | | |
| 5.7 | — | | |
| 5.8 | — | | |
| 6.1 | — | | |
| 6.2 | — | | |
| 6.3 | — | | |
| 6.4 | — | | |
| 6.5 | — | | |
| 6.6 | — | | |
| 6.7 | — | | |
| 7.1 | — | | |
| 7.2 | — | | |
| 7.3 | — | | |
| 7.4 | — | | |
| 7.5 | — | | |
| 7.6 | — | | |
| 7.7 | — | | |
| 8.1 | — | | |
| 8.2 | — | | |
| 9.1 | — | | |
| 9.2 | — | | |
| 9.3 | — | | |
| 9.4 | — | | |
| 9.5 | — | | |
| 9.6 | — | | |
| 9.7 | — | | |
| 10.1 | — | | |
| 10.2 | — | | |
| 10.3 | — | | |
| 10.4 | — | | |
| 10.5 | — | | |
| 11.1 | — | | |
| 11.2 | — | | |
| 11.3 | — | | |
| 12.1 | — | | |
| 12.2 | — | | |
| 12.3 | — | | |
| 12.4 | — | | |
| 12.5 | — | | |
| 13.1 | — | | |
| 13.2 | — | | |
| 13.3 | — | | |

## Closing

| Step | Status | Time | Notes |
|---|---|---|---|
| E1 | — | | |
| E2 | — | | |
| E3 | — | | |
| E4 | — | | |
| E5 | — | | |
| E6 | — | | |

## Issues found

| # | Test | What happened | Evidence | Status (fix commit, retest) |
|---|---|---|---|---|

## Session notes

Chronological: who did what, when, breaks taken, anything odd.

-

## Summary

Filled in at the end: counts by status, issues fixed, anything carried to the
next run.
