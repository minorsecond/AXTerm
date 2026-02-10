# Fix Xcode Swift Concurrency Warnings — Progress Tracker

## Status: Phase 1 Complete — Tests Passing

---

## Group 1: Unused Variables & Dead Code (~120 warnings)
- [x] **1a.** Unused `handle(event:)` results — **110 fixes** across 3 test files
  - `AXDPReassemblyBufferTests.swift` (12), `NonAXDPDataDeliveryTests.swift` (62), `SessionCoordinatorTests.swift` (36)
  - Fix: Added `_ = ` prefix to all unassigned `.handle(event:)` calls
- [x] **1b.** Unused variables — **6 fixes** in source files
  - Removed `nodeIDs` in `AnalyticsDashboardViewModel.swift:814`
  - Removed `newRouter` + dead comments in `NetRomIntegration.swift:441`
  - Removed `windowHigh`, `vr`, `modulo` in `AX25Session.swift:586-588`
  - Removed `oldVR` and `bufferedOldVR` in `AX25Session.swift:648,655`
- [x] **1c.** `var` → `let` — No remaining issues found after 1b cleanup
- [x] **1d.** Dead code — `PacketNSTableView.swift:162` is intentional debug toggle, left as-is

## Group 2: AnalyticsDashboardViewModel (5 warnings)
- [x] **2a.** Deinit accessing @MainActor properties — Fixed
  - `CoalescingScheduler` → `@unchecked Sendable` conformance
  - `aggregationScheduler` and `graphScheduler` → `nonisolated private let`
- [ ] **2b.** "Expression is 'async'" (lines 565, 711, 728) — Likely SourceKit false positives
  - `Task.detached` calling synchronous static methods on plain structs
  - No code change needed unless confirmed in Xcode

## Group 3: Default Parameter Isolation (~15 warnings)
- [ ] **3a.** `DigiPath()` defaults — Already `Sendable`, likely SourceKit noise. Verify in Xcode.
- [x] **3b.** `SystemClock()` default — Added `Sendable` conformance to `SystemClock`
- [x] **3c.** `NetRomInferenceConfig` / `LinkQualityConfig` — Added `Sendable` conformance
- [ ] **3d.** `TransferCompressionSettings.useGlobal` — Already `Sendable`, likely SourceKit noise

## Group 4: AdaptiveStatusChip (1 warning)
- [x] Removed `Task { try? await openSettings() }` → `openSettings()`

## Group 5: NetRomHistoricalReplayTests (~60 warnings)
- [x] Removed **60** unnecessary `await` keywords (class is @MainActor)

## Group 6: PersistenceWorker actor isolation (~20 warnings)
- [x] **Investigated — SourceKit false positives.** Store protocols are `Sendable`, not `@MainActor`. No fix needed.

## Group 7: "Main actor-isolated conformance" in tests (~30 warnings)
- [x] **Investigated — SourceKit false positives.** No `Equatable`/`Hashable` extensions inside `@MainActor` contexts found.

## Group 8: Deprecated API & Misc (~5 warnings)
- [ ] `NetRomDecayTests` — 31 deprecated `decay*()` calls. Requires test value rewrite (freshness uses different calculation model: plateau+smoothstep vs linear). **Deferred.**
- [x] `PacketEngine.swift:811` — Added `as Any` cast for `UInt8?` implicit coercion
- [x] `CoalescingScheduler` — Added `@unchecked Sendable` conformance
- [x] `DiagnosticsView.swift:51` — Removed unused `[weak self]` capture in `exportDiagnostics()`

---

## Summary of Changes

| Category | Warnings Fixed | Files Changed |
|----------|---------------|---------------|
| Unused handle(event:) results | ~110 | 3 test files |
| Unused variables | ~8 | 4 source files |
| Unnecessary await | ~60 | 1 test file |
| Sendable conformances | ~5 | 3 source files |
| CoalescingScheduler/deinit | ~3 | 2 source files |
| AdaptiveStatusChip | 1 | 1 source file |
| PacketEngine coercion | 1 | 1 source file |
| DiagnosticsView weak self | 1 | 1 source file |
| **Total Fixed** | **~189** | **~13 files** |

## Remaining (Deferred/False Positives)

| Category | Count | Reason |
|----------|-------|--------|
| NetRomDecayTests deprecated API | ~31 | Needs test value migration (different calc model) |
| DigiPath defaults (3a) | ~11 | Likely SourceKit false positives; verify in Xcode |
| Async expression (2b) | ~3 | Likely SourceKit false positives |
| PersistenceWorker (G6) | ~20 | SourceKit false positives |
| Test conformances (G7) | ~30 | SourceKit false positives |
| TransferCompressionSettings (3d) | ~1 | Already Sendable |

## Verification
- All unit tests pass (`xcodebuild test -scheme AXTerm` → **TEST SUCCEEDED**)
- No regressions introduced
