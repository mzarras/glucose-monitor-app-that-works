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
# breaches listed at the "D57 plants begin" marker below. They get their own pass because some of
# them (a binary target in ForecastKit's manifest, ForecastKit linked into the widget, new source
# paths, a deleted scan root) would break the app build pass 1 checks. Allowed importers are planted
# too, as a negative control the lint must not name. Every plant must be reported by name. (Pass
# 2's exit status proves nothing on its own: the safety gate without the tests gate always fails on
# "no test logs".)

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
# D57 plants begin
#   packages   ForecastKit: a package dependency (GlucoseCore), a .binaryTarget, unsafeFlags.
#              WidgetCore: unsafeFlags whose "-module-alias" is built by string concatenation, and
#              a dependency on "../Forecast" + "Kit" (neither spells ForecastKit or module-alias)
#   sources    a non-Foundation import (GlucoseCore) and `internal import UIKit` in ForecastKit
#   importers  `#if false` + `import ForecastKit` in App/Sources/Pipeline; `@testable import` in
#              AlertEngine's tests and in GlucoseStats' sources; `internal import ForecastKit` in
#              App/Sources/Services; `import struct ForecastKit.LatestForecast` in Screens/Now;
#              `import Foundation; import `ForecastKit`` in App/Sources/Pipeline; a string holding
#              "//" or "*/*" plus a comment between the tokens (the matcher misses these; the
#              backstop must not); a CR-only file whose second line imports ForecastKit; allowed
#              names in denied places (Pipeline/ReadingPipeline+Forecast.swift,
#              Model/ViewStateMapping+Forecast.swift, Widgets/Sources/ForecastWidgetEntry.swift)
#   exports    `@_exported import ForecastKit` in an allowed file, plainly and hidden behind a
#              string and a comment (App/Sources/Screens/Predict/PredictExports.swift)
#   symlink    App/Sources/Pipeline/Linked -> a directory outside the scan roots that imports it
#   roots      the AppUITests/ scan root deleted
#   project    in project.yml: ForecastKit linked to SensorWidgets through a YAML anchor and alias
#              (XcodeGen resolves a plain `- package: ForecastKit` to the same thing); Sensor
#              sources `Shared` (a new root with a plain import) and
#              `Packages/ForecastKit/Sources/ForecastKit` (ForecastKit compiled into the app);
#              Sensor's OTHER_SWIFT_FLAGS `-module-alias Fk=ForecastKit` with `import Fk`
#   flags      `-Xfrontend -import-module -Xfrontend ForecastKit` in Config/Base.xcconfig
cat > Packages/ForecastKit/Package.swift <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ForecastKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ForecastKit", targets: ["ForecastKit"])],
    dependencies: [.package(path: "../GlucoseCore")],
    targets: [
        .target(name: "ForecastKit", dependencies: ["GlucoseCore"], swiftSettings: [.unsafeFlags(["-Onone"])]),
        .binaryTarget(name: "CheckSelftestBinary", path: "CheckSelftest.xcframework"),
    ]
)
SWIFT
cat > Packages/WidgetCore/Package.swift <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WidgetCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "WidgetCore", targets: ["WidgetCore"])],
    dependencies: [.package(path: "../Forecast" + "Kit")],
    targets: [
        .target(name: "WidgetCore", swiftSettings: [.unsafeFlags(["-module-" + "alias", "Fk=Forecast" + "Kit"])]),
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
mkdir -p App/Sources/Services App/Sources/Screens/Now App/Sources/Screens/Predict App/Sources/Model Packages/GlucoseStats/Sources/GlucoseStats Widgets/Sources
cat > App/Sources/Services/SomeCoordinator.swift <<'SWIFT'
internal import ForecastKit
SWIFT
cat > App/Sources/Screens/Now/CheckSelftestNowForecast.swift <<'SWIFT'
import struct ForecastKit.LatestForecast
SWIFT
cat > Packages/GlucoseStats/Sources/GlucoseStats/CheckSelftestStatsForecast.swift <<'SWIFT'
@testable import ForecastKit
SWIFT
# A string holding "//" (or "*/*") defeats the comment-stripped reading; the comment between the
# tokens defeats the raw one. Both compile.
cat > App/Sources/Services/CheckSelftestStringComment.swift <<'SWIFT'
let checkSelftestSlashes = "//"; import/**/ForecastKit
SWIFT
cat > App/Sources/Services/CheckSelftestStarSlash.swift <<'SWIFT'
let checkSelftestAccept = "*/*"
import/* x */ForecastKit
SWIFT
# CR-only line endings: awk would read the file as one record and see only `import Foundation`.
printf 'import Foundation\rimport ForecastKit\r' > App/Sources/Services/CheckSelftestCROnly.swift
# Allowed names in denied places.
printf 'import ForecastKit\n' > App/Sources/Pipeline/ReadingPipeline+Forecast.swift
printf 'import ForecastKit\n' > App/Sources/Model/ViewStateMapping+Forecast.swift
printf 'import ForecastKit\n' > Widgets/Sources/ForecastWidgetEntry.swift
# @_exported in allowed files: plain, and hidden behind a string and a comment.
printf '@_exported import ForecastKit\n' > App/Sources/Model/ForecastReexport.swift
cat > App/Sources/Screens/Predict/PredictExports.swift <<'SWIFT'
let checkSelftestSlashes = "//"; @_exported /* D57 */ import ForecastKit
SWIFT
# A symlinked directory: `find` and `grep -r` do not descend into it; XcodeGen compiles it.
mkdir -p Stash/dir
printf 'import ForecastKit\n' > Stash/dir/ReadingSink.swift
ln -s ../../../Stash/dir App/Sources/Pipeline/Linked
# A new source root, ForecastKit's own sources compiled into the app, a module alias, and
# ForecastKit linked to the widget extension through a YAML anchor on the app's own dependency and
# an alias in the widget's (no line of the widget target mentions ForecastKit).
mkdir -p Shared
printf 'import ForecastKit\n' > Shared/ReadingSink.swift
printf 'import Fk\n' > App/Sources/Pipeline/CheckSelftestAlias.swift
awk '
    { print }
    /^[A-Za-z]/ { section = $1 }
    section == "targets:" && /^  [A-Za-z]/ { target = $1 }
    target == "Sensor:" && /^    sources:$/ {
        print "      - path: Shared"
        print "      - path: Packages/ForecastKit/Sources/ForecastKit"
    }
    target == "Sensor:" && /^      base:$/ { print "        OTHER_SWIFT_FLAGS: \"$(inherited) -module-alias Fk=ForecastKit\"" }
    target == "Sensor:" && /^    dependencies:$/ { print "      - &checkSelftestForecast"; print "        package: ForecastKit" }
    target == "SensorWidgets:" && /^    dependencies:$/ { print "      - *checkSelftestForecast" }
' project.yml > "$TMP/project.yml" && cp "$TMP/project.yml" project.yml
for line in '      - \*checkSelftestForecast' '      - &checkSelftestForecast' '      - path: Shared' \
            '      - path: Packages/ForecastKit/Sources/ForecastKit' '        OTHER_SWIFT_FLAGS: "\$(inherited) -module-alias Fk=ForecastKit"'; do
    if ! grep -q "^$line\$" project.yml; then echo "MISS  could not plant into project.yml (its layout changed): $line"; missing=1; fi
done
printf '\nOTHER_SWIFT_FLAGS = $(inherited) -Xfrontend -import-module -Xfrontend ForecastKit\n' >> Config/Base.xcconfig
# A scan root that is gone.
rm -rf AppUITests
# Negative control: allowed importers (overwritten if they exist; this worktree is thrown away).
ALLOWED="App/Sources/Services/ForecastService.swift App/Sources/Model/AppModel+Predict.swift App/Sources/Screens/Predict/X.swift"
for allowed in $ALLOWED; do printf 'import ForecastKit\n' > "$allowed"; done
# D57 plants end

OUT2="$TMP/out2.txt"
GATES=safety PACKAGES="ForecastKit" scripts/check.sh > "$OUT2" 2>&1

expect "$OUT2" '^FAIL  D57: ForecastKit declares [0-9]+ package dependencies' "ForecastKit package dependency"
expect "$OUT2" '^FAIL  D57: ForecastKit.s targets are: .*CheckSelftestBinary\(binary\)' "binary target in ForecastKit's manifest"
expect "$OUT2" '^FAIL  D57: ForecastKit has target dependencies other than ForecastKitTests->ForecastKit:.*GlucoseCore' "ForecastKit target depending on GlucoseCore"
expect "$OUT2" '^FAIL  D57: ForecastKit.s manifest uses settings it may not: .*unsafeFlags' "unsafeFlags in ForecastKit's manifest"
expect "$OUT2" '^FAIL  D57: unsafeFlags in the manifests of:.* WidgetCore' "unsafeFlags in another package's manifest"
expect "$OUT2" '^FAIL  D57: packages depending on ForecastKit:.* WidgetCore' "a package depending on \"../Forecast\" + \"Kit\""
expect "$OUT2" '^FAIL  D57: ForecastKit imports modules other than Foundation:.*CheckSelftestImport.swift:[0-9]+\(GlucoseCore\)' "non-Foundation import in ForecastKit"
expect "$OUT2" '^FAIL  D57: ForecastKit imports modules other than Foundation:.*CheckSelftestUIKit.swift:[0-9]+\(UIKit\)' "internal import UIKit in ForecastKit"
ALLOWLIST='^FAIL  D57: ForecastKit imported outside its allowlist:'
BACKSTOP='^FAIL  D57: ForecastKit named outside its allowlist:'
expect "$OUT2" "$ALLOWLIST.*App/Sources/Pipeline/CheckSelftestForecastImport.swift" "ForecastKit imported by the pipeline (#if false)"
expect "$OUT2" "$ALLOWLIST.*Packages/AlertEngine/Tests/AlertEngineTests/CheckSelftestForecastImport.swift" "ForecastKit imported by AlertEngine's tests"
expect "$OUT2" "$ALLOWLIST.*App/Sources/Services/SomeCoordinator.swift" "internal import ForecastKit in App/Sources/Services"
expect "$OUT2" "$ALLOWLIST.*App/Sources/Screens/Now/CheckSelftestNowForecast.swift" "import struct ForecastKit.LatestForecast in Screens/Now"
expect "$OUT2" "$ALLOWLIST.*Packages/GlucoseStats/Sources/GlucoseStats/CheckSelftestStatsForecast.swift" "@testable import ForecastKit in GlucoseStats"
expect "$OUT2" "$ALLOWLIST.*App/Sources/Pipeline/CheckSelftestSemicolonForecast.swift" "import Foundation; import \`ForecastKit\` in the pipeline"
expect "$OUT2" "$ALLOWLIST.*App/Sources/Services/CheckSelftestCROnly.swift:2" "CR-only file importing ForecastKit on its second line"
expect "$OUT2" "$ALLOWLIST.*App/Sources/Pipeline/ReadingPipeline\+Forecast.swift" "allowed name in a denied directory (Pipeline/ReadingPipeline+Forecast.swift)"
expect "$OUT2" "$ALLOWLIST.*App/Sources/Model/ViewStateMapping\+Forecast.swift" "allowed name on a denied file (Model/ViewStateMapping+Forecast.swift)"
expect "$OUT2" "$ALLOWLIST.*Widgets/Sources/ForecastWidgetEntry.swift" "allowed name in the widget extension (Widgets/Sources/ForecastWidgetEntry.swift)"
expect "$OUT2" "$BACKSTOP.*App/Sources/Services/CheckSelftestStringComment.swift:1" "backstop: string with // plus import/**/ForecastKit"
expect "$OUT2" "$BACKSTOP.*App/Sources/Services/CheckSelftestStarSlash.swift:2" "backstop: string with */* plus import/* x */ForecastKit"
expect "$OUT2" "$BACKSTOP.*App/Sources/Services/CheckSelftestCROnly.swift:2" "backstop: CR-only file"
expect "$OUT2" '^FAIL  D57: @_exported .*App/Sources/Model/ForecastReexport.swift:1' "@_exported import ForecastKit in an allowed file"
expect "$OUT2" '^FAIL  D57: @_exported .*App/Sources/Screens/Predict/PredictExports.swift:1' "@_exported hidden behind a string and a comment in an allowed file"
expect "$OUT2" '^FAIL  D57: symbolic links .*App/Sources/Pipeline/Linked' "a symlinked directory in App/Sources"
expect "$OUT2" '^FAIL  D57: scan root AppUITests is missing' "a missing scan root"
expect "$OUT2" '^FAIL  D57: target sources outside .*Sensor:Shared( |$)' "a new source root (Shared) on the Sensor target"
expect "$OUT2" '^FAIL  D57: target sources outside .*Sensor:Packages/ForecastKit/Sources/ForecastKit' "ForecastKit's sources compiled into the Sensor target"
expect "$OUT2" '^FAIL  D57: project.yml links or names ForecastKit outside .*targets.Sensor\(outside-dependencies\)' "ForecastKit named in the Sensor target outside its dependencies"
expect "$OUT2" '^FAIL  D57: project.yml links or names ForecastKit outside .*targets.SensorWidgets' "ForecastKit linked to the widget through a YAML anchor/alias"
expect "$OUT2" '^FAIL  D57: module-alias/import-module .*project.yml:[0-9]+' "-module-alias in project.yml"
expect "$OUT2" '^FAIL  D57: module-alias/import-module .*Config/Base.xcconfig:[0-9]+' "-import-module in Config/Base.xcconfig"
expect "$OUT2" '^FAIL  D57: module-alias/import-module .*package-WidgetCore.json' "-module-alias built by concatenation, seen in WidgetCore's resolved manifest"
for allowed in $ALLOWED; do
    if grep -E "$ALLOWLIST|$BACKSTOP" "$OUT2" | grep -qF "$allowed"; then
        echo "MISS  negative control: $allowed was flagged"; missing=1
    else
        echo "ok    negative control: $allowed not flagged"
    fi
done

if [ $missing -ne 0 ]; then
    echo "check-selftest: FAILED — output in $OUT and $OUT2"
    cp "$OUT" "$ROOT/.build-logs/check-selftest-last.txt" 2>/dev/null
    cp "$OUT2" "$ROOT/.build-logs/check-selftest-last-d57.txt" 2>/dev/null
    exit 1
fi
echo "check-selftest: all planted defects were caught."
