# What Leaks Between Tests

Two ways a test in this suite could be broken by one that ran before it, both
found on 2026-09-19, both fixed. The pattern is the same each time: state that
outlives a test, and a name that suggests otherwise.

## The one that caused real failures

`NetRomRealisticWiringTests.testIngestion_UpdatesIntegrationState` and four
tests in `NetRomIntegrationWiringTests` failed together in occasional
full-suite runs and never on a rerun. The reported failure was always a missing
neighbour:

```
K2BBB should be a neighbor (from third-party via path).
Heard 10: [DRL, K0NTS, K0NTS-14, ...]; 52 link stats, 33 routes from 464 packets
```

The cause is one line in `NetRomRoutesPagesModeTests`:

```swift
settings.addIgnoredServiceEndpoint("K2BBB")
```

That store has its own UserDefaults suite, so it reads as isolated. It is not.
The setter's `didSet` calls `CallsignValidator.configureIgnoredServiceEndpoints`,
which writes **process-wide** state, and the test never put it back. Every test
that ran afterwards in the same worker saw `isValidCallsign("K2BBB") == false`.

`NetRomPassiveInference` filters via-path hops through `isValidRoutingNode`, so
the hop disappeared, `repeatedViaNormalized` came up empty, and inference
returned before recording anything. Everything else in the ingest was fine,
which is why the failure looked so strange: 464 packets, 52 link stats, 33
routes, inference working for every other path — `W0EDGE2 via K9DIG`,
`WH6ANH via DRL score=4.00` — and one callsign missing.

### Why it hid

`NetRomRoutesPagesModeTests` sorts alphabetically *after* both classes it
breaks. A sequential run therefore always ran the victims first and passed,
every time. Under parallel testing the workers take classes as they come free,
so the leaker can land ahead of a victim — and only then, and only if no class
that clears the list in `setUp` runs in between.

That combination defeated a lot of searching: twelve full runs under sixteen
times CPU oversubscription, a single-process sequential run of all 7,213 tests,
ten fresh processes of the class alone, and forty in-process repetitions in an
earlier session. None could reproduce it, because none controlled the one
variable that mattered.

What found it was the original failing log. Every line carries the worker pid:

```
Test case 'X.y()' failed on 'My Mac - AXTerm (66810)'
```

Grouping by that pid reconstructs each worker's history. In PID 66810 the
leaker ran at position 27 and the victim at 61, in the same process. That is
the first thing to do with a parallel-only failure, and it was available from
the beginning.

### Proving it

Poisoning the list by hand reproduces the failure byte for byte — same
neighbours, same counts — and removing the poison passes. A flake is not
diagnosed until it has a switch.

### The fix

The leaker restores the list in `tearDown`. The three NET/ROM classes whose
traffic depends on via-hop validity clear it in `setUp`, so they no longer
inherit whatever ran before them. Five other classes in the suite already did
this, which was the clue that it had bitten before and been patched locally
each time rather than at the source.

## The one that had not caused a failure yet

Every test process opens a throwaway UserDefaults suite named from
`TestModeConfiguration.instanceID`, which answers `"default"` unless an
instance name, port or callsign was passed — so under plain `xcodebuild test`
it is the same name in every worker. Each worker then **wiped it on first
access**, erasing what its siblings had written, from another process, at
whatever moment it happened to start.

Two places built that name: `AppEnvironment.defaults` and `AXTermApp.init`.
The second is the scene's own initialiser, which runs in every worker. The
ephemeral database three lines below it already isolated per worker with
`unit-<pid>`; the defaults suite had been missed.

`AppEnvironment` is now the only place that decides this, XCTest hosts get
`...default.pid<N>`, and stale suites are swept on the way in by checking which
pids are still alive — on the way in rather than at exit, because a worker is
killed as often as it exits cleanly and an `atexit` handler that never runs
leaves the file behind anyway. That was the first attempt, and the litter on
disk is what disproved it.

No failure has been attributed to this. It is fixed because two processes
racing to erase each other's settings is wrong on its own terms.

## The rule

Process-global state and parallel workers do not mix, and an object with its
own storage can still write to a global — `AppSettingsStore` does, by design,
because the app needs the validator configured. A test that changes global
state puts it back. A test that depends on global state sets it first.

## Diagnostics left behind

`NetRomIntegration.observationTrace` records one line per `observePacket` under
the test host — duplicate status, base classification, classification used, and
mode — and `NetRomPassiveInference.debugEvidenceSummary` reports the evidence
behind every inferred route with its quality against the publish floor. Both
are what turned "the neighbour is missing" into "the hop was filtered before
inference ran", and both cost nothing until an assertion fails.
