# Fix Xcode Swift Concurrency Warnings — Progress Tracker

## Status: In Progress

---

## Group 1: Unused Variables & Dead Code (~100+ warnings)
- [ ] **1a.** Unused `handle(event:)` results (~80 warnings)
- [ ] **1b.** Unused variables (~15 warnings)
- [ ] **1c.** `var` → `let` warnings (~10 warnings)
- [ ] **1d.** Dead code / "Will never be executed"

## Group 2: AnalyticsDashboardViewModel (5 warnings)
- [ ] **2a.** Deinit accessing @MainActor properties
- [ ] **2b.** "Expression is 'async'" false positives

## Group 3: Default Parameter Isolation (~15 warnings)
- [ ] **3a.** `DigiPath()` defaults
- [ ] **3b.** `SystemClock()` default
- [ ] **3c.** `NetRomInferenceConfig.default` / `LinkQualityConfig.default`
- [ ] **3d.** `TransferCompressionSettings.useGlobal`

## Group 4: AdaptiveStatusChip (1 warning)
- [ ] Remove `try? await` from `openSettings()`

## Group 5: NetRomHistoricalReplayTests (~60 warnings)
- [ ] Remove unnecessary `await` keywords

## Group 6: PersistenceWorker actor isolation (~20 warnings)
- [ ] Investigate and fix if real warnings

## Group 7: "Main actor-isolated conformance" in tests (~30 warnings)
- [ ] Investigate synthesized conformances in @MainActor contexts

## Group 8: Deprecated API & Misc (~5 warnings)
- [ ] `NetRomDecayTests` — use `freshness` instead of `decay`
- [ ] `PacketEngine.swift:811` — explicit cast for `UInt8?` to `Any`
- [ ] `CoalescingScheduler` — add `@unchecked Sendable`

---

## Completed Fixes Log
_(Updated as fixes are applied)_
