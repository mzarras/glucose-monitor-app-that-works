// Live upload to the owner's Nightscout (HANDOFF §8A step 1). PROGRESS D6: this app uploads CGM
// entries and Trio's CGM upload is off — docs/trio-bridge.md#nightscout-uploads.
//
// Each reading becomes one `sgv` entry:
//   { "type": "sgv", "sgv": 123, "direction": "Flat", "date": 1790172300000,
//     "dateString": "2026-09-23T14:05:00.000Z", "device": "Sensor" }
// Field meanings: cgm-remote-monitor lib/server/entries.js (storage) and lib/api/entries/index.js
// (API), 15.0.8 (92d08342).
//   type        "sgv" — sensor glucose; the dedupe key includes it (entries.js:246-248).
//   sgv         mg/dL; LOW → 39 and HIGH → 401 (NightscoutGlucoseEncoding, S4).
//   direction   Nightscout arrow name from the sensor-reported rate (TrendArrow.nightscoutDirection,
//               HANDOFF §7.5); "NOT COMPUTABLE" when the sensor reported no rate.
//   date        epoch milliseconds of the reading's own timestamp — a backfilled reading keeps its
//               original time (S3), never the upload time.
//   dateString  the same instant in ISO 8601 UTC with milliseconds. Nightscout derives `sysTime`
//               from `dateString` when present (entries.js:120-128), and `sysTime` + `type` is the
//               upsert key (entries.js:130-139, 238-248; the same in 14.2.6, entries.js:102-110). It
//               is built from the same integer milliseconds as `date` with integer formatting (no
//               floating-point fraction), so the same reading always yields a byte-identical
//               `dateString` and `sysTime`: a retry after a lost response upserts the same entry.
//               A backfilled copy of a reading has the same id (serial + sensor timestamp) and is
//               dropped by the repository before it reaches the uploader, so it is never re-sent
//               with a re-derived date.
//   device      the app's name (injected; working name "Sensor").

import Foundation
import GlucoseCore

struct NightscoutEntryPayload: Encodable, Equatable, Sendable {
    let type: String
    let sgv: Int
    let direction: String
    let date: Int64
    let dateString: String
    let device: String

    /// `nil` when the value has no faithful Nightscout representation (S4).
    init?(reading: GlucoseReading, deviceName: String) {
        guard let sgv = NightscoutGlucoseEncoding.sgv(for: reading.value) else { return nil }
        let milliseconds = GlucoseReading.epochMilliseconds(reading.date)
        self.type = "sgv"
        self.sgv = sgv
        self.direction = TrendArrow(rate: reading.trendRate).nightscoutDirection
        self.date = milliseconds
        self.dateString = Self.iso8601UTC(milliseconds: milliseconds)
        self.device = deviceName
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// `YYYY-MM-DDThh:mm:ss.SSSZ` from integer milliseconds (no floating-point rounding of the
    /// fraction, so `dateString` and `date` always name the same millisecond).
    static func iso8601UTC(milliseconds: Int64) -> String {
        let seconds = milliseconds >= 0 ? milliseconds / 1000 : (milliseconds - 999) / 1000
        let fraction = Int(milliseconds - seconds * 1000)
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let c = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0, fraction
        )
    }
}

public struct NightscoutUploadDestination: UploadDestination {
    public let name = "Nightscout"
    /// Readings per POST. Nightscout accepts up to 10000 (lib/api/shared/write-payload.js:6); 100
    /// keeps requests small on a weak connection while draining a day's backlog in 3 requests.
    public let maxBatchSize = 100
    /// Nightscout keeps history, so backfill of any age is uploaded.
    public let maxReadingAge: TimeInterval? = nil

    private let client: NightscoutClient
    private let deviceName: String

    public init(site: NightscoutSite, credentials: any CredentialStore, deviceName: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.client = NightscoutClient(site: site, credentials: credentials, transport: transport)
        self.deviceName = deviceName
    }

    public func canRepresent(_ value: GlucoseValue) -> Bool {
        NightscoutGlucoseEncoding.sgv(for: value) != nil
    }

    public func upload(_ readings: [GlucoseReading]) async throws(UploadError) {
        let payloads = readings.compactMap { NightscoutEntryPayload(reading: $0, deviceName: deviceName) }
        guard payloads.count == readings.count else {
            // `ReadingUploader` never queues these (canRepresent); refusing here keeps S4 local.
            throw UploadError(.configuration, "a queued reading has no Nightscout representation")
        }
        let body: Data
        do {
            // Sorted keys: the same readings always produce byte-identical bodies, so a retry is
            // exactly the request that may already have been stored.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            body = try encoder.encode(payloads)
        } catch {
            throw UploadError(.configuration, "could not encode entries: \(error.localizedDescription)")
        }
        do {
            try await client.postEntries(jsonArray: body)
        } catch {
            throw Self.uploadError(error)
        }
    }

    static func uploadError(_ error: NightscoutClientError) -> UploadError {
        switch error {
        case .missingToken: return UploadError(.missingCredentials, error.description)
        case .credentialStore: return UploadError(.missingCredentials, error.description)
        case .unauthorized: return UploadError(.unauthorized, error.description)
        case .http: return UploadError(.server, error.description)
        case .transport: return UploadError(.transport, error.description)
        case .malformedResponse: return UploadError(.server, error.description)
        }
    }
}

extension ReadingUploader {
    /// Nightscout uploader persisting its queue at `<queueDirectory>/nightscout-upload-queue.json`.
    public static func nightscout(
        site: NightscoutSite,
        credentials: any CredentialStore,
        deviceName: String,
        queueDirectory: URL,
        transport: any HTTPTransport = URLSessionTransport(),
        retryPolicy: RetryPolicy = .default,
        clock: any WallClock = SystemWallClock(),
        log: any DiagnosticLog = NullDiagnosticLog()
    ) throws(QueueFileInUse) -> ReadingUploader {
        try ReadingUploader(
            destination: NightscoutUploadDestination(site: site, credentials: credentials, deviceName: deviceName, transport: transport),
            queueFile: queueDirectory.appendingPathComponent("nightscout-upload-queue.json"),
            retryPolicy: retryPolicy,
            clock: clock,
            log: log
        )
    }
}
