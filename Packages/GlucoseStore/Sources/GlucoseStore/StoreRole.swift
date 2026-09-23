// The two repository roles (GlucoseReadingRepository doc comment, PROGRESS.md D20). A store has
// exactly one role for its whole life and the roles never share a database.

import GlucoseCore

enum StoreRole: Sendable, Equatable {
    /// The app's database: `.sensor` and `.imported` readings only.
    case production
    #if DEBUG
    /// DEBUG builds only: a separate database used while a ReplayKit source runs. `.replay` and
    /// `.mock` readings only. Compiled out of Release together with every factory that makes one.
    case replay
    #endif

    /// `reading.sourceKind` values this role stores. Everything else is refused on insert.
    var allowedSourceKinds: Set<String> {
        switch self {
        case .production: return ["sensor", "imported"]
        #if DEBUG
        case .replay: return ["replay", "mock"]
        #endif
        }
    }

    func allows(_ source: ReadingSource) -> Bool {
        allowedSourceKinds.contains(ReadingRow.sourceKind(of: source))
    }

    /// `latestLiveReading()`: the newest `.sensor` row in production, the newest `.replay`/`.mock`
    /// row in a replay store; never `.imported`.
    var latestLiveReadingSQL: String {
        switch self {
        case .production:
            // The WHERE clause is identical to the partial index `reading_sensor_on_date`
            // (StoreSchema.swift), which is what lets SQLite use it. Keep them identical.
            return """
                SELECT \(ReadingRow.selectColumns) FROM reading
                WHERE sourceKind = 'sensor'
                ORDER BY date DESC, id DESC
                LIMIT 1
                """
        #if DEBUG
        case .replay:
            return """
                SELECT \(ReadingRow.selectColumns) FROM reading
                WHERE sourceKind IN ('replay', 'mock')
                ORDER BY date DESC, id DESC
                LIMIT 1
                """
        #endif
        }
    }
}
