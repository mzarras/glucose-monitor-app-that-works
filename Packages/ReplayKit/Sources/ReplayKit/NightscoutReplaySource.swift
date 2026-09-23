// Replays a Nightscout entries export as a CGMSource. DEBUG only (S6): compiled out of Release.
#if DEBUG
import Foundation
import GlucoseCore

/// Delivers each usable sgv entry of a Nightscout export as a `.replay` reading at its own date,
/// shifted so the first entry lands on `origin` (spacing and gaps unchanged: nothing is filled in,
/// S1). Pass `export.entries.first!.date` as the origin to keep the export's own timestamps.
///
/// - Reading ids are `REPLAY-NIGHTSCOUT:<milliseconds since session start>`, so entries less than
///   a second apart (two uploaders) stay distinct readings; entries with exactly the same `date`
///   are dropped and counted by `NightscoutExport`.
/// - Trend rate is always nil: Nightscout entries carry a direction name, not the sensor's rate,
///   and turning a name back into a number would fabricate one (S1).
/// - The session is synthetic, serial `REPLAY-NIGHTSCOUT`: it starts 1 hour before the first
///   entry (warm-up over 30 min before it) and lasts until the later of 10 days or the last entry,
///   plus the 12-hour grace period, so every entry passes the DEBUG replay check in
///   `LiveReadingGate` (proven by NightscoutReplayTests).
public final class NightscoutReplaySource: CGMSource {
    public static let serial = "REPLAY-NIGHTSCOUT"

    public enum ReplayError: Error, Equatable {
        case noReadings
    }

    public let export: NightscoutExport
    public let timeline: ReplayTimeline
    private let player: ReplaySource

    public init(export: NightscoutExport, origin: Date, clock: any ReplayClock) throws {
        guard let first = export.entries.first, let last = export.entries.last else {
            throw ReplayError.noReadings
        }
        let shift = origin.timeIntervalSince(first.date)
        let lastDate = last.date.addingTimeInterval(shift)

        let start = origin.addingTimeInterval(-3_600)
        let expiresAt = max(start.addingTimeInterval(G7ReplaySession.ratedLife), lastDate)
        let session = SensorSession(
            serial: Self.serial,
            start: start,
            warmUpEndsAt: start.addingTimeInterval(G7ReplaySession.warmUp),
            expiresAt: expiresAt,
            gracePeriodEndsAt: expiresAt.addingTimeInterval(G7ReplaySession.gracePeriod)
        )
        let factory = ReplayReadingFactory(origin: origin, session: session)

        var events = [ReplayEvent(offset: 0, kind: .state(.active(sessionStart: session.start, expiresAt: session.expiresAt)))]
        for entry in export.entries {
            let date = entry.date.addingTimeInterval(shift)
            let reading = factory.readingWithMillisecondID(at: date, entry.value, trend: nil)
            events.append(ReplayEvent(offset: date.timeIntervalSince(origin), kind: .reading(reading)))
        }

        self.export = export
        self.timeline = ReplayTimeline(name: "nightscout", origin: origin, session: session, initialState: .searching, events: events)
        self.player = ReplaySource(timeline: timeline, clock: clock)
    }

    public var readings: AsyncStream<GlucoseReading> { player.readings }
    public var state: AsyncStream<SensorState> { player.state }
    public var currentSession: SensorSession? { get async { await player.currentSession } }

    public func start(pairingCode: String?) async throws {
        try await player.start(pairingCode: pairingCode)
    }

    public func stop() async {
        await player.stop()
    }

    /// See `ReplaySource.waitForPlayback`.
    public func waitForPlayback() async {
        await player.waitForPlayback()
    }

    /// For tests: everything put on the readings stream so far.
    var emittedReadings: [GlucoseReading] {
        get async { await player.emittedReadings }
    }
}
#endif
