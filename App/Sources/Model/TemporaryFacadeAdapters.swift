// TEMPORARY ADAPTERS (P2B) — for facade members Integrator A is adding to `AppServices` that are
// not on this branch yet. Each is listed in the P2B report's OPEN QUESTIONS; delete the adapter
// and call the facade member when the change is merged.

import Foundation

extension AppServices {
    /// TEMPORARY: `AppServices.pairAgain(code:)` (p2-services 954d3c9) re-pairs the sensor being
    /// worn (D37). Until it is merged this falls back to the new-sensor flow, which G7Kit uses for
    /// the stored sensor only when that sensor's session has ended — so "Pair again" is not
    /// reliable on this branch alone.
    func pairAgainAdapter(code: String) async throws(PairingError) {
        try await pair(code: code)
    }
}

extension AppServices {
    /// TEMPORARY: G7Kit `G7CGMSource.hasStoredSensor` (integration ede0339) through the facade. Until
    /// A adds it, false — PairingGuidance's safe fallback: every code goes to `pair(code:)`, which
    /// always works, and "Pair again" (`pairAgain(code:)`) is not offered.
    var hasStoredSensorAdapter: Bool { false }
}
