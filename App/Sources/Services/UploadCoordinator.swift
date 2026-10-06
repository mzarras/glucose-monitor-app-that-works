// Owns the Nightscout and Dexcom Share uploaders (HANDOFF §8A; NightscoutKit wiring notes in
// ReadingUploader.swift and PROGRESS "Phase 2 must-dos"):
// - one `ReadingUploader` per queue file: the old one (and its status task) is released before a
//   replacement is created; `QueueFileInUse` is surfaced as the uploader's setup error (S5) and
//   retried;
// - `flushIfDue` after readings are queued and on foreground; `credentialsChanged()` then `flush()`
//   after credentials are saved; a flush that returns `.alreadyFlushing` is repeated once the
//   running one has finished;
// - queues live in the app's container (Application Support/Uploads), one file per destination;
// - every flush holds a background-time assertion so an upload started during a BLE wake can finish.
// The S2/S6 gate is inside `ReadingUploader.submit`; nothing here decides what may be uploaded.

import Foundation
import GlucoseCore
import NightscoutKit
import UIKit

@MainActor
final class UploadCoordinator {
    /// What the uploaders should be, from preferences and the Keychain.
    struct Configuration: Equatable {
        var nightscoutEnabled: Bool
        var nightscoutSite: NightscoutSite?
        var nightscoutHasToken: Bool
        var shareEnabled: Bool
        var shareRegion: DexcomShareRegion
        var shareReceiverSerial: String?
        var shareHasCredentials: Bool
        /// D20: false in a DEBUG build unless the developer switch is on.
        var liveOutputsAllowed: Bool
    }

    private(set) var nightscoutSummary = UploaderSummary.off
    private(set) var shareSummary = UploaderSummary.off
    var onChange: (@MainActor () -> Void)?

    private let credentials: any CredentialStore
    private let queueDirectory: URL
    private let deviceName: String
    private let transport: any HTTPTransport
    private let diagnostics: any DiagnosticLog

    private var nightscout: Slot?
    private var share: Slot?
    private var configuration: Configuration?
    private var retryTask: Task<Void, Never>?
    private var applying: Task<Void, Never>?

    /// One live uploader and what it was built for.
    private struct Slot {
        let uploader: ReadingUploader
        /// The destination-defining settings; a change means a new uploader.
        let identity: String
        let statusTask: Task<Void, Never>
    }

    /// How long to wait before trying again to create an uploader whose queue file is still held by
    /// a released one (`QueueFileInUse`).
    private let setupRetryDelay: Duration

    init(credentials: any CredentialStore, queueDirectory: URL, deviceName: String, transport: any HTTPTransport = URLSessionTransport(),
         diagnostics: any DiagnosticLog, setupRetryDelay: Duration = .seconds(5)) {
        self.setupRetryDelay = setupRetryDelay
        self.credentials = credentials
        self.queueDirectory = queueDirectory
        self.deviceName = deviceName
        self.transport = transport
        self.diagnostics = diagnostics
    }

    /// The uploaders the pipeline submits to.
    var activeUploaders: [ReadingUploader] {
        [nightscout?.uploader, share?.uploader].compactMap { $0 }
    }

    // MARK: - Configuration

    /// Creates, replaces or releases uploaders to match `configuration`. Calls run one after the
    /// other (a second call waits for the first), so two quick changes cannot create two uploaders
    /// for one queue file.
    func apply(_ configuration: Configuration) async {
        let previous = applying
        let task = Task { [weak self] in
            await previous?.value
            await self?.reconcile(configuration)
        }
        applying = task
        await task.value
    }

    private func reconcile(_ configuration: Configuration) async {
        self.configuration = configuration
        nightscoutSummary.isEnabled = configuration.nightscoutEnabled
        nightscoutSummary.isConfigured = configuration.nightscoutSite != nil && configuration.nightscoutHasToken
        nightscoutSummary.liveOutputsAllowed = configuration.liveOutputsAllowed
        shareSummary.isEnabled = configuration.shareEnabled
        shareSummary.isConfigured = configuration.shareReceiverSerial != nil && configuration.shareHasCredentials
        shareSummary.liveOutputsAllowed = configuration.liveOutputsAllowed

        // Nightscout: needs a site; a missing token fails loudly at upload time (S5).
        let nightscoutIdentity = configuration.nightscoutEnabled && configuration.liveOutputsAllowed
            ? configuration.nightscoutSite.map { "nightscout|\($0.baseURL.absoluteString)" } : nil
        if nightscoutIdentity != nightscout?.identity {
            await release(.nightscout)
            nightscoutSummary.status = nil
            nightscoutSummary.setupError = nil
            if let site = configuration.nightscoutSite, let identity = nightscoutIdentity {
                let credentials = self.credentials, queueDirectory = self.queueDirectory, deviceName = self.deviceName
                let transport = self.transport, diagnostics = self.diagnostics
                switch await Self.claim({ () throws(QueueFileInUse) -> ReadingUploader in
                    try ReadingUploader.nightscout(
                        site: site, credentials: credentials, deviceName: deviceName, queueDirectory: queueDirectory,
                        transport: transport, log: diagnostics
                    )
                }) {
                case .success(let uploader):
                    nightscout = makeSlot(uploader, identity: identity, isNightscout: true)
                case .failure(let error):
                    nightscoutSummary.setupError = Self.describe(error)
                    scheduleRetry()
                }
            }
        }

        // Dexcom Share: needs the receiver serial number; missing credentials fail loudly (S5).
        let shareIdentity = configuration.shareEnabled && configuration.liveOutputsAllowed
            ? configuration.shareReceiverSerial.map { "share|\(configuration.shareRegion.rawValue)|\($0)" } : nil
        if shareIdentity != share?.identity {
            await release(.share)
            shareSummary.status = nil
            shareSummary.setupError = nil
            if let serial = configuration.shareReceiverSerial, let identity = shareIdentity {
                let credentials = self.credentials, queueDirectory = self.queueDirectory
                let transport = self.transport, diagnostics = self.diagnostics
                let server: DexcomShareServer = configuration.shareRegion == .us ? .us : .outsideUS
                switch await Self.claim({ () throws(QueueFileInUse) -> ReadingUploader in
                    try ReadingUploader.dexcomShare(
                        server: server, receiverSerialNumber: serial, credentials: credentials, queueDirectory: queueDirectory,
                        transport: transport, log: diagnostics
                    )
                }) {
                case .success(let uploader):
                    share = makeSlot(uploader, identity: identity, isNightscout: false)
                case .failure(let error):
                    shareSummary.setupError = Self.describe(error)
                    scheduleRetry()
                }
            }
        }
        onChange?()
    }

    private func makeSlot(_ uploader: ReadingUploader, identity: String, isNightscout: Bool) -> Slot {
        let task = Task { [weak self] in
            for await status in await uploader.statusUpdates() {
                guard let self else { return }
                if isNightscout {
                    Self.note(status, in: &self.nightscoutSummary)
                } else {
                    Self.note(status, in: &self.shareSummary)
                }
                self.onChange?()
            }
        }
        return Slot(uploader: uploader, identity: identity, statusTask: task)
    }

    private static func note(_ status: NightscoutKit.UploadStatus, in summary: inout UploaderSummary) {
        summary.status = status
        if status.isFailing {
            summary.problemSince = summary.problemSince ?? status.lastErrorAt ?? status.lastRefusedAt ?? Date()
        } else {
            summary.problemSince = nil
        }
    }

    private enum Destination {
        case nightscout, share
    }

    /// Releases an uploader and its status task before any replacement is created, so the queue
    /// file is free again (NightscoutKit: one uploader per queue file). The slot is taken out of
    /// its property here, so nothing in the caller keeps the old uploader alive.
    private func release(_ destination: Destination) async {
        let slot: Slot?
        switch destination {
        case .nightscout:
            slot = nightscout
            nightscout = nil
        case .share:
            slot = share
            share = nil
        }
        guard let slot else { return }
        slot.statusTask.cancel()
        await slot.statusTask.value
    }

    /// Creates an uploader, waiting up to one second for a released one to go away: its last status
    /// callback or a flush in progress can hold it for a moment after release. Beyond that the
    /// caller surfaces `QueueFileInUse` (S5) and retries later.
    private static func claim(_ make: () throws(QueueFileInUse) -> ReadingUploader) async -> Result<ReadingUploader, QueueFileInUse> {
        for _ in 0..<19 {
            do throws(QueueFileInUse) {
                return .success(try make())
            } catch {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        do throws(QueueFileInUse) {
            return .success(try make())
        } catch {
            return .failure(error)
        }
    }

    /// `QueueFileInUse` for longer: a released uploader is still finishing a flush. Try again shortly.
    private func scheduleRetry() {
        guard retryTask == nil else { return }
        let delay = setupRetryDelay
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, let configuration = self.configuration else { return }
            self.retryTask = nil
            // Force re-creation of whatever failed.
            await self.apply(configuration)
        }
    }

    private static func describe(_ error: QueueFileInUse) -> String {
        "The upload queue \(URL(fileURLWithPath: error.path).lastPathComponent) is still in use by a previous uploader; retrying"
    }

    // MARK: - Flushing

    /// After readings were queued, and on foreground: upload unless backing off.
    func flushIfDue() {
        for uploader in activeUploaders {
            Task { await Self.flush(uploader, ignoringBackoff: false) }
        }
    }

    /// Settings "Retry now": upload now, ignoring backoff.
    func flushNow() async {
        for uploader in activeUploaders {
            await Self.flush(uploader, ignoringBackoff: true)
        }
    }

    /// After new credentials were saved: forget cached logins and backoff, then upload at once.
    func credentialsChanged() async {
        for uploader in activeUploaders {
            await uploader.credentialsChanged()
            await Self.flush(uploader, ignoringBackoff: true)
        }
    }

    /// One flush, repeated while another flush is running (it may have taken its batch before a new
    /// reading was queued, or may be using old credentials), under a background-time assertion.
    private static func flush(_ uploader: ReadingUploader, ignoringBackoff: Bool) async {
        let background = BackgroundTime(name: "Upload \(uploader.destinationName)")
        defer { background.end() }
        for _ in 0..<15 {
            let outcome = ignoringBackoff ? await uploader.flush() : await uploader.flushIfDue()
            guard case .alreadyFlushing = outcome else { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

/// A background-time assertion (`beginBackgroundTask`), ended when the work is done or when iOS
/// says time is up — never left running, which would get the app terminated.
@MainActor
final class BackgroundTime {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
