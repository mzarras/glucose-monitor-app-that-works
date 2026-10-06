#!/usr/bin/env bash
# Proves scripts/check.sh fails on planted defects (Phase 0 review B1, M3, m6).
# Runs in a throwaway git worktree of HEAD; never touches your working tree.
#
# Planted: a Release-only failing S2 test, a compiler warning in GlucoseCore (after warming a cache, so a cached build would hide
# it), a skipped safety test, a safety test that "passes" via XCTExpectFailure (separate files), a
# ReplayKit symbol that leaks into Release, a .mock reading built outside #if DEBUG, and a package
# with zero tests (WidgetCore's Phase 0 placeholder, if still present). Every plant must be reported.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/check-selftest.XXXXXX")"
WT="$TMP/wt"
trap 'git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1; rm -rf "$TMP"' EXIT

git -C "$ROOT" worktree add --detach --quiet "$WT" HEAD || exit 2
cd "$WT"

cat >> Packages/GlucoseCore/Sources/GlucoseCore/GlucoseUnit.swift <<'SWIFT'

func checkSelftestPlantedWarning() { let unusedValue = 1 }
SWIFT
cat > Packages/GlucoseCore/Tests/GlucoseCoreTests/CheckSelftestSkip.swift <<'SWIFT'
import XCTest

final class CheckSelftestSkip: XCTestCase {
    func test_S5_plantedSkip() throws { throw XCTSkip("planted by check-selftest") }
}
SWIFT
cat > Packages/GlucoseCore/Tests/GlucoseCoreTests/CheckSelftestExpectFailure.swift <<'SWIFT'
import XCTest

final class CheckSelftestExpectFailure: XCTestCase {
    func test_S7_plantedExpectedFailure() { XCTExpectFailure("planted"); XCTFail("planted") }
}
SWIFT
# A safety test that fails only in the Release configuration (gate 2 runs debug, so only the
# Release S2/S6 step can catch it; Phase 3 review m7).
cat > Packages/GlucoseCore/Tests/GlucoseCoreTests/CheckSelftestReleaseOnly.swift <<'SWIFT'
import XCTest

#if !DEBUG
final class CheckSelftestReleaseOnly: XCTestCase {
    func test_S2_plantedReleaseOnlyFailure() { XCTFail("planted by check-selftest") }
}
#endif
SWIFT
# A Release symbol leak: ReplayKit code outside #if DEBUG.
cat > Packages/ReplayKit/Sources/ReplayKit/CheckSelftestLeak.swift <<'SWIFT'
public enum CheckSelftestLeak { public static func leaked() -> Int { 1 } }
SWIFT
# A .mock reading constructed outside an #if DEBUG block, in a file that has one elsewhere.
cat > App/Sources/CheckSelftestMock.swift <<'SWIFT'
import Foundation
import GlucoseCore

#if DEBUG
let checkSelftestGuarded = 1
#endif

let checkSelftestMock = GlucoseReading(
    id: "x", date: .distantPast, value: .mgdl(100), trendRate: nil, isBackfill: false,
    source: .mock, sensorSerial: ""
)
SWIFT
# Warm a cache the way a developer would before running the gate.
(cd Packages/GlucoseCore && swift build) > /dev/null 2>&1

OUT="$TMP/out.txt"
GATES=build,tests,safety PACKAGES="GlucoseCore WidgetCore" SAFETY_RULES="S5 S7" scripts/check.sh > "$OUT" 2>&1
status=$?

missing=0
expect() {
    if grep -qE "$1" "$OUT"; then echo "ok    reported: $2"; else echo "MISS  not reported: $2"; missing=1; fi
}
expect '^FAIL  build Debug has warnings' "warning in app Debug build"
expect '^FAIL  GlucoseCore has warnings' "warning in swift test build"
expect '^FAIL  S5: 1 skipped safety test' "skipped safety test"
expect '^FAIL  safety tests live in files using XCTSkip/XCTExpectFailure:.*CheckSelftestSkip' "XCTSkip in a safety-test file"
expect '^FAIL  safety tests live in files using XCTSkip/XCTExpectFailure:.*CheckSelftestExpectFailure' "XCTExpectFailure in a safety-test file"
expect '^FAIL  S6: ReplayKit defines [0-9]+ symbols in Release' "ReplayKit symbol leak into Release"
expect '^FAIL  S2/S6 Release-configuration tests in GlucoseCore' "safety test failing only in Release"
expect '^FAIL  S6: .replay/.mock readings constructed outside #if DEBUG at: .*CheckSelftestMock.swift:[0-9]+' ".mock construction outside #if DEBUG"
if [ -f Packages/WidgetCore/Tests/WidgetCoreTests/Placeholder.swift ]; then
    expect '^FAIL  WidgetCore executed no tests' "package with zero tests"
fi
if [ $status -eq 0 ]; then echo "MISS  check.sh exited 0"; missing=1; else echo "ok    check.sh exited $status"; fi

if [ $missing -ne 0 ]; then
    echo "check-selftest: FAILED — output in $OUT"; cp "$OUT" "$ROOT/.build-logs/check-selftest-last.txt" 2>/dev/null
    exit 1
fi
echo "check-selftest: all planted defects were caught."
