#!/usr/bin/env bash
# Proves scripts/check.sh fails on planted defects (Phase 0 review B1, M3, m6; p5-forecast review M1).
# Runs in a throwaway git worktree of HEAD; never touches your working tree.
#
# Pass 1 (gates build, tests, safety) plants: a Release-only failing S2 test, a compiler warning in
# GlucoseCore (after warming a cache, so a cached build would hide it), a skipped safety test, a
# safety test that "passes" via XCTExpectFailure (separate files), a ReplayKit symbol that leaks
# into Release, a .mock reading built outside #if DEBUG, and a package with zero tests
# (WidgetCore's Phase 0 placeholder, if still present).
#
# Pass 2 (gate safety only; nothing is built with these plants) plants the D57 forecast-isolation
# breaches. They get their own pass because two of them, a binary target in ForecastKit's manifest
# and ForecastKit linked into the widget, would break the app build pass 1 checks. Breaches:
#   manifest   a package dependency (GlucoseCore) and a .binaryTarget
#   sources    a non-Foundation import (GlucoseCore) and `internal import UIKit` in ForecastKit
#   importers  `#if false` + `import ForecastKit` in App/Sources/Pipeline; `@testable import` in
#              AlertEngine's tests and in GlucoseStats' sources; `internal import ForecastKit` in
#              App/Sources/Services; `import struct ForecastKit.LatestForecast` in Screens/Now;
#              `import Foundation; import `ForecastKit`` in App/Sources/Pipeline
#   linkage    ForecastKit added to the SensorWidgets target in project.yml
# Negative control: pass 2 also plants allowed importers (App/Sources/Services/ForecastService.swift,
# App/Sources/Model/AppModel+Predict.swift, App/Sources/Screens/Predict/X.swift); the lint must not
# name them. Every plant must be reported.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/check-selftest.XXXXXX")"
WT="$TMP/wt"
trap 'git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1; rm -rf "$TMP"' EXIT

git -C "$ROOT" worktree add --detach --quiet "$WT" HEAD || exit 2
cd "$WT"

missing=0
expect() {
    if grep -qE "$2" "$1"; then echo "ok    reported: $3"; else echo "MISS  not reported: $3"; missing=1; fi
}

# ---------------------------------------------------------------------------------------------
# Pass 1: build, tests, safety
# ---------------------------------------------------------------------------------------------
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

expect "$OUT" '^FAIL  build Debug has warnings' "warning in app Debug build"
expect "$OUT" '^FAIL  GlucoseCore has warnings' "warning in swift test build"
expect "$OUT" '^FAIL  S5: 1 skipped safety test' "skipped safety test"
expect "$OUT" '^FAIL  safety tests live in files using XCTSkip/XCTExpectFailure:.*CheckSelftestSkip' "XCTSkip in a safety-test file"
expect "$OUT" '^FAIL  safety tests live in files using XCTSkip/XCTExpectFailure:.*CheckSelftestExpectFailure' "XCTExpectFailure in a safety-test file"
expect "$OUT" '^FAIL  S6: ReplayKit defines [0-9]+ symbols in Release' "ReplayKit symbol leak into Release"
expect "$OUT" '^FAIL  S2/S6 Release-configuration tests in GlucoseCore' "safety test failing only in Release"
expect "$OUT" '^FAIL  S6: .replay/.mock readings constructed outside #if DEBUG at: .*CheckSelftestMock.swift:[0-9]+' ".mock construction outside #if DEBUG"
if [ -f Packages/WidgetCore/Tests/WidgetCoreTests/Placeholder.swift ]; then
    expect "$OUT" '^FAIL  WidgetCore executed no tests' "package with zero tests"
fi
if [ $status -eq 0 ]; then echo "MISS  pass 1: check.sh exited 0"; missing=1; else echo "ok    pass 1: check.sh exited $status"; fi

# ---------------------------------------------------------------------------------------------
# Pass 2: D57 forecast isolation (safety gate only)
# ---------------------------------------------------------------------------------------------
cat > Packages/ForecastKit/Package.swift <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ForecastKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ForecastKit", targets: ["ForecastKit"])],
    dependencies: [.package(path: "../GlucoseCore")],
    targets: [
        .target(name: "ForecastKit", dependencies: ["GlucoseCore"]),
        .binaryTarget(name: "CheckSelftestBinary", path: "CheckSelftest.xcframework"),
    ]
)
SWIFT
cat > Packages/ForecastKit/Sources/ForecastKit/CheckSelftestImport.swift <<'SWIFT'
import Foundation
import GlucoseCore
SWIFT
cat > Packages/ForecastKit/Sources/ForecastKit/CheckSelftestUIKit.swift <<'SWIFT'
internal import UIKit
SWIFT
cat > App/Sources/Pipeline/CheckSelftestForecastImport.swift <<'SWIFT'
#if false
import ForecastKit
#endif
SWIFT
cat > App/Sources/Pipeline/CheckSelftestSemicolonForecast.swift <<'SWIFT'
import Foundation; import `ForecastKit`
SWIFT
cat > Packages/AlertEngine/Tests/AlertEngineTests/CheckSelftestForecastImport.swift <<'SWIFT'
@testable import ForecastKit
SWIFT
mkdir -p App/Sources/Services App/Sources/Screens/Now Packages/GlucoseStats/Sources/GlucoseStats
cat > App/Sources/Services/SomeCoordinator.swift <<'SWIFT'
internal import ForecastKit
SWIFT
cat > App/Sources/Screens/Now/CheckSelftestNowForecast.swift <<'SWIFT'
import struct ForecastKit.LatestForecast
SWIFT
cat > Packages/GlucoseStats/Sources/GlucoseStats/CheckSelftestStatsForecast.swift <<'SWIFT'
@testable import ForecastKit
SWIFT
# ForecastKit as a dependency of the widget extension: one line after SensorWidgets' `dependencies:`.
awk '
    { print }
    /^  SensorWidgets:/ { widget = 1 }
    widget && /^    dependencies:/ { print "      - package: ForecastKit"; widget = 0 }
' project.yml > "$TMP/project.yml" && cp "$TMP/project.yml" project.yml
if ! awk '/^  SensorWidgets:/ { w = 1 } w && /^      - package: ForecastKit$/ { found = 1 } END { exit !found }' project.yml; then
    echo "MISS  could not plant ForecastKit into SensorWidgets in project.yml (its layout changed)"; missing=1
fi
# Negative control: allowed importers (overwritten if they exist; this worktree is thrown away).
mkdir -p App/Sources/Model App/Sources/Screens/Predict
ALLOWED="App/Sources/Services/ForecastService.swift App/Sources/Model/AppModel+Predict.swift App/Sources/Screens/Predict/X.swift"
for allowed in $ALLOWED; do printf 'import ForecastKit\n' > "$allowed"; done

OUT2="$TMP/out2.txt"
GATES=safety PACKAGES="ForecastKit" scripts/check.sh > "$OUT2" 2>&1
status=$?

expect "$OUT2" '^FAIL  D57: ForecastKit declares [0-9]+ package dependencies' "ForecastKit package dependency"
expect "$OUT2" '^FAIL  D57: ForecastKit.s targets are: .*CheckSelftestBinary\(binary\)' "binary target in ForecastKit's manifest"
expect "$OUT2" '^FAIL  D57: ForecastKit has target dependencies other than ForecastKitTests->ForecastKit:.*GlucoseCore' "ForecastKit target depending on GlucoseCore"
expect "$OUT2" '^FAIL  D57: ForecastKit imports modules other than Foundation:.*CheckSelftestImport.swift:[0-9]+\(GlucoseCore\)' "non-Foundation import in ForecastKit"
expect "$OUT2" '^FAIL  D57: ForecastKit imports modules other than Foundation:.*CheckSelftestUIKit.swift:[0-9]+\(UIKit\)' "internal import UIKit in ForecastKit"
ALLOWLIST='^FAIL  D57: ForecastKit imported outside its allowlist:'
expect "$OUT2" "$ALLOWLIST.*App/Sources/Pipeline/CheckSelftestForecastImport.swift" "ForecastKit imported by the pipeline (#if false)"
expect "$OUT2" "$ALLOWLIST.*Packages/AlertEngine/Tests/AlertEngineTests/CheckSelftestForecastImport.swift" "ForecastKit imported by AlertEngine's tests"
expect "$OUT2" "$ALLOWLIST.*App/Sources/Services/SomeCoordinator.swift" "internal import ForecastKit in App/Sources/Services"
expect "$OUT2" "$ALLOWLIST.*App/Sources/Screens/Now/CheckSelftestNowForecast.swift" "import struct ForecastKit.LatestForecast in Screens/Now"
expect "$OUT2" "$ALLOWLIST.*Packages/GlucoseStats/Sources/GlucoseStats/CheckSelftestStatsForecast.swift" "@testable import ForecastKit in GlucoseStats"
expect "$OUT2" "$ALLOWLIST.*App/Sources/Pipeline/CheckSelftestSemicolonForecast.swift" "import Foundation; import \`ForecastKit\` in the pipeline"
expect "$OUT2" '^FAIL  D57: ForecastKit linked outside the Sensor app and its test targets: .*project.yml:[0-9]+\(targets SensorWidgets\)' "ForecastKit linked into the widget in project.yml"
flagged="$(grep -E "$ALLOWLIST" "$OUT2")"
for allowed in $ALLOWED; do
    case "$flagged" in
        *"$allowed"*) echo "MISS  negative control: the allowlist flagged $allowed"; missing=1 ;;
        *) echo "ok    negative control: $allowed not flagged" ;;
    esac
done
if [ $status -eq 0 ]; then echo "MISS  pass 2: check.sh exited 0"; missing=1; else echo "ok    pass 2: check.sh exited $status"; fi

if [ $missing -ne 0 ]; then
    echo "check-selftest: FAILED — output in $OUT and $OUT2"
    cp "$OUT" "$ROOT/.build-logs/check-selftest-last.txt" 2>/dev/null
    cp "$OUT2" "$ROOT/.build-logs/check-selftest-last-d57.txt" 2>/dev/null
    exit 1
fi
echo "check-selftest: all planted defects were caught."
