// What a replay source delivers, and when. DEBUG only (S6): compiled out of Release.
#if DEBUG
import Foundation
import GlucoseCore

/// One scripted delivery.
public struct ReplayEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A live reading, delivered at `offset` (its date equals the delivery date).
        case reading(GlucoseReading)
        /// Readings delivered together after a gap, ascending by date, each flagged `isBackfill`
        /// and carrying its original timestamp (S3).
        case backfill([GlucoseReading])
        /// A sensor state change.
        case state(SensorState)
    }

    /// Seconds after the timeline origin at which the event is delivered.
    public let offset: TimeInterval
    public let kind: Kind

    public init(offset: TimeInterval, kind: Kind) {
        self.offset = offset
        self.kind = kind
    }
}

/// A complete, deterministic replay: the session, the state before anything happens, and every
/// event in delivery order. Nothing is generated while playing; the source delivers exactly this.
public struct ReplayTimeline: Sendable, Equatable {
    public let name: String
    /// Scenario time zero. Event offsets and milestone offsets are relative to it.
    public let origin: Date
    public let session: SensorSession
    /// The first element of the source's `state` stream, emitted when the source is created.
    public let initialState: SensorState
    /// Ascending by offset; events with equal offsets are delivered in array order.
    public let events: [ReplayEvent]

    public init(name: String, origin: Date, session: SensorSession, initialState: SensorState, events: [ReplayEvent]) {
        precondition(
            zip(events, events.dropFirst()).allSatisfy { $0.offset <= $1.offset },
            "ReplayTimeline \(name): events must be in delivery order"
        )
        self.name = name
        self.origin = origin
        self.session = session
        self.initialState = initialState
        self.events = events
    }

    public func deliveryDate(of event: ReplayEvent) -> Date {
        origin.addingTimeInterval(event.offset)
    }

    /// Every reading with the offset at which it is delivered, in delivery order.
    public var deliveries: [(offset: TimeInterval, reading: GlucoseReading)] {
        events.flatMap { event -> [(offset: TimeInterval, reading: GlucoseReading)] in
            switch event.kind {
            case .reading(let reading): return [(event.offset, reading)]
            case .backfill(let readings): return readings.map { (event.offset, $0) }
            case .state: return []
            }
        }
    }

    /// Every reading, in delivery order (what the `readings` stream carries, and nothing else).
    public var readingsInDeliveryOrder: [GlucoseReading] {
        deliveries.map(\.reading)
    }

    /// Every state change after `initialState`, in delivery order.
    public var stateChanges: [(offset: TimeInterval, state: SensorState)] {
        events.compactMap { event in
            if case .state(let state) = event.kind { return (event.offset, state) }
            return nil
        }
    }

    /// Delivery offset of the first reading that satisfies `predicate`.
    public func firstDeliveryOffset(where predicate: (GlucoseReading) -> Bool) -> TimeInterval? {
        deliveries.first { predicate($0.reading) }?.offset
    }

    /// Delivery offset of the first reading after `offset` that satisfies `predicate`.
    public func firstDeliveryOffset(after offset: TimeInterval, where predicate: (GlucoseReading) -> Bool) -> TimeInterval? {
        deliveries.first { $0.offset > offset && predicate($0.reading) }?.offset
    }

    /// Delivery offset of the first state change that satisfies `predicate`.
    public func firstStateOffset(where predicate: (SensorState) -> Bool) -> TimeInterval? {
        stateChanges.first { predicate($0.state) }?.offset
    }
}
#endif
