# Waiting In Tests

Why the wait helpers in this suite fail rather than return, and what a fake
radio's reply latency has to do with a modem that would not unkey.

## The failure this came from

`ModemRadioLinkTests.testATransmissionKeysAndUnkeysOverCIV` failed roughly one
run in five when the whole target ran, and passed on its own. What it reported
was:

```
XCTAssertTrue failed - PTT off
```

What had actually happened came before all three of the test's assertions. Its
wait for the link to connect timed out, returned quietly, and the test carried
on against a link that was still opening:

```
XCTAssertNil failed: "notRunning"          ← link.send, into a link not up yet
XCTAssertTrue failed - PTT on              ← nothing was queued, so nothing keyed
XCTAssertTrue failed - PTT off             ← the one in the report
```

The diagnostic captured under load says the rest: `ptt=false`,
`underfilled=400` — every one of the four hundred pumped blocks rendered
silence — and a CI-V transcript holding the open and poll commands and no PTT
command at all. The unkey path, which is what the failure named, was never
reached and was never the problem.

## Two causes, one shape

**The wait returned quietly.** A helper that gives up without saying so hands
the test a world that never arrived, and the blame lands on whatever assertion
trips next. The further apart those two points are, the more misleading the
result: here it crossed a subsystem boundary, from the link's connect to the
modem's PTT.

**The fake radio answered on the shared pool.** `FakeCIVTransport` delivered
replies with `DispatchQueue.global().asyncAfter(0.005)`. On a machine running
the full target in parallel, every worker thread on that pool is busy with
somebody else's test, and five milliseconds lands hundreds of milliseconds
late. Late enough trips `CIVClient`'s 0.5 s request timeout, and an open that
makes half a dozen requests drags past anything the test is willing to wait.

## What the helpers do now

Every polling wait takes a description and calls `XCTFail` at the caller's line
when the condition never holds:

```
timed out after 2.0s waiting for: the link to connect
```

The description is required rather than optional, because "timed out" names
nothing. Where a test genuinely expects a condition *not* to arrive, that is a
separate helper with a name that says so — `waitUntilOrGiveUp` in
`ModemRadioLinkTests`, `letTheStoresSettle` in `PacketHandlingTests` — so the
difference is visible at the call site instead of hidden in a default argument.
That distinction is load-bearing: `testHandleIncomingPacketSkipsPersistenceWhenDisabled`
waits and then asserts that *nothing* was stored, and making its wait assert
would have broken a passing test.

Helpers carrying this: `ModemRadioLinkTests`, `RadioManagerModemTests`,
`AX25ProtocolSimulatorTests`, `PacketHandlingTests`, `EventLoggerTests`,
`WatchNotificationIntegrationTests`, `TwoRadioSessionTraceTests`.

`PacketTableContextMenuRegressionTests.waitForMainQueue` is left alone. It is a
fixed delay built on `XCTestExpectation`, which XCTest already fails on timeout.

## The fake radio

`FakeCIVTransport.replyDelay` of zero or less answers **synchronously**, inside
`write`. That is safe, and the reason is worth keeping: `CIVClient.advance()`
records the in-flight request before it calls `write`, and the client hops
every incoming byte onto its own serial queue, so a synchronous answer is
queued behind the send and cannot arrive before something is waiting for it.

A test that wants a responsive radio should ask for that. A test that is
*about* how long a reply takes keeps a delay, and that path now runs on the
fake's own serial queue at `.userInitiated` rather than on the shared pool.

The difference is between a test that measures the code and one that measures
how busy the machine was.

## A different way tests break each other

Waiting is one. State that outlives a test is another, and it produced a
harder failure in the same week — see [TestIsolation.md](TestIsolation.md).

## Reproducing this class of failure

Load the machine and run the suite against it. Timing flakes do not show up on
an idle laptop, which is why this one survived so long as "passes on its own":

```
for i in $(seq 1 28); do (while :; do :; done) & done
xcodebuild test-without-building -project AXTerm.xcodeproj -scheme AXTerm \
  -destination 'platform=macOS' -derivedDataPath /tmp/axterm-dd \
  -only-testing:AXTermTests/ModemRadioLinkTests
for p in $(jobs -p); do kill -9 $p; done
```

Use a derived-data path of your own, or a running copy of the app will break
codesigning for the test host.

Before the fix that reproduced it about one run in five. After it, twenty
consecutive runs came back clean, eight of them in the parallel multi-suite
shape that had been failing.
