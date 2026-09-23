import Foundation
@testable import AlertEngine

/// A clock the test moves by hand. No test in this package sleeps.
@MainActor
final class TestClock: AlertClock {
    private(set) var now: Date

    init(_ start: Date = Fixtures.t0) {
        now = start
    }

    func advance(minutes: Double) {
        now = now.addingTimeInterval(minutes * 60)
    }

    func advance(seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }

    func set(_ date: Date) {
        now = date
    }
}
