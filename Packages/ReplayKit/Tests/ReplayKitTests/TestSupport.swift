#if DEBUG
import Foundation
import GlucoseCore
@testable import ReplayKit

/// 2026-01-15T12:00:00Z. Scenario time zero in most tests.
let testOrigin = Date(timeIntervalSince1970: 1_768_478_400)

/// An origin with sub-second detail, like `Date()` in a UI demo.
let fractionalOrigin = Date(timeIntervalSince1970: 1_768_478_400.123_456_7)

extension AsyncStream.Iterator {
    /// The next `count` elements. Keep one iterator per stream for a whole test: dropping an
    /// AsyncStream iterator cancels the stream.
    mutating func next(_ count: Int) async -> [Element] {
        var elements: [Element] = []
        for _ in 0..<count {
            guard let element = await next() else { break }
            elements.append(element)
        }
        return elements
    }
}

/// Plays `source` to the end with the clock it was given (must not be a ManualReplayClock) and
/// returns what the streams carried: exactly as many readings as the script holds, plus the
/// playback log. The log is how a test proves nothing beyond the script was emitted.
func playToEnd(_ source: ReplaySource) async throws -> (streamed: [GlucoseReading], states: [SensorState], logged: [GlucoseReading]) {
    try await source.start(pairingCode: nil)
    await source.waitForPlayback()
    var readings = source.readings.makeAsyncIterator()
    var states = source.state.makeAsyncIterator()
    let streamed = await readings.next(source.timeline.readingsInDeliveryOrder.count)
    let streamedStates = await states.next(source.timeline.stateChanges.count + 1)
    let logged = await source.emittedReadings
    return (streamed, streamedStates, logged)
}

/// Loads the synthetic Nightscout export shipped with the tests.
func fixtureExportData() throws -> Data {
    guard let url = Bundle.module.url(forResource: "nightscout-entries", withExtension: "json", subdirectory: "Fixtures") else {
        throw CocoaError(.fileNoSuchFile)
    }
    return try Data(contentsOf: url)
}
#endif
