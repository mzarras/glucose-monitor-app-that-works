// Trio, Nightscout, Dexcom Share and history import in the live services (HANDOFF §4.5, §8, §8A).
// Secrets go to the Keychain (NightscoutKit `KeychainCredentialStore`, AfterFirstUnlock, not
// synchronized) and are never read back into the UI; only whether one is stored.

import Foundation
import GlucoseCore
import NightscoutKit

extension LiveAppServices {
    // MARK: - Trio bridge

    var trio: TrioBridgeSummary { trioCoordinator.summary }

    func setTrioBridgeEnabled(_ enabled: Bool) async {
        let wasActive = trioCoordinator.activeBridge != nil
        preferences.trioBridgeEnabled = enabled
        trioCoordinator.configure(enabled: enabled, liveOutputsAllowed: liveOutputsAllowed)
        attachOutputs()
        if enabled {
            await reseedTrio()
            await updateTrioHeartbeat()
        } else if wasActive {
            // Remove this app's readings and heartbeat keys from Trio's App Group.
            await trioCoordinator.removeEverythingFromTrio()
        }
        log(.bridge, "Trio bridge turned \(enabled ? "on" : "off")")
        await sendTrioAlertInput()
    }

    /// docs/trio-bridge.md: after a relaunch the bridge's window is empty; hand it the last ~5 hours
    /// of stored sensor readings (each passes the gate again). Also when it is switched on.
    func reseedTrio() async {
        guard !isReplaying, let store = productionStore, trioCoordinator.activeBridge != nil else { return }
        let date = now()
        do {
            let recent = try await store.readings(from: date.addingTimeInterval(-5 * 3_600), to: date.addingTimeInterval(LiveReadingGate.futureTolerance))
            await trioCoordinator.reseed(with: recent, session: await g7.currentSession)
        } catch {
            log(.bridge, "Trio re-seed skipped: \(error)")
        }
    }

    /// docs/trio-bridge.md "Heartbeat wiring": re-evaluated after pairing, forgetting and every
    /// sensor state. Only for the live sensor (never during a DEBUG replay run).
    func updateTrioHeartbeat() async {
        guard isBootstrapped, !isReplaying else { return }
        let target = await g7.heartbeatTarget
        await trioCoordinator.updateHeartbeat(target.map(TrioCoordinator.heartbeatPeripheral(for:)))
    }

    // MARK: - Uploads

    /// For the UI: nil until bootstrap (preferences are not read before the first unlock).
    var nightscoutSite: NightscoutSite? {
        guard isBootstrapped else { return nil }
        return savedNightscoutSite
    }

    /// The saved site, read without the bootstrap guard: `applyUploadConfiguration` runs during
    /// bootstrap (protected data is available by then), before `isBootstrapped` is set. Reading
    /// `nightscoutSite` there returned nil, so no Nightscout uploader was created at launch.
    private var savedNightscoutSite: NightscoutSite? {
        preferences.nightscoutSiteURL.flatMap { try? NightscoutSite($0) }
    }

    var nightscout: NightscoutSummary {
        NightscoutSummary(siteURL: nightscoutSite?.baseURL.absoluteString, hasToken: nightscoutHasToken, upload: uploads.nightscoutSummary)
    }

    var dexcomShare: DexcomShareSummary {
        DexcomShareSummary(
            accountName: shareAccountName, hasPassword: shareHasPassword,
            receiverSerialNumber: isBootstrapped ? preferences.dexcomShareReceiverSerial : nil,
            region: isBootstrapped ? preferences.dexcomShareRegion : .us,
            upload: uploads.shareSummary
        )
    }

    /// Reads which secrets are stored (never their values into the UI, except the account name).
    func loadSharingSecrets() {
        nightscoutHasToken = Self.read(.nightscoutToken, from: credentials) != nil
        shareAccountName = Self.read(.dexcomShareAccountName, from: credentials)
        shareHasPassword = Self.read(.dexcomSharePassword, from: credentials) != nil
    }

    private static func read(_ key: CredentialKey, from store: any CredentialStore) -> String? {
        do throws(CredentialStoreError) {
            return try store.read(key)
        } catch {
            return nil
        }
    }

    func applyUploadConfiguration() async {
        await uploads.apply(UploadCoordinator.Configuration(
            nightscoutEnabled: preferences.nightscoutUploadEnabled,
            nightscoutSite: savedNightscoutSite,
            nightscoutHasToken: nightscoutHasToken,
            shareEnabled: preferences.dexcomShareUploadEnabled,
            shareRegion: preferences.dexcomShareRegion,
            shareReceiverSerial: preferences.dexcomShareReceiverSerial,
            shareHasCredentials: shareAccountName != nil && shareHasPassword,
            liveOutputsAllowed: liveOutputsAllowed
        ))
        attachOutputs()
    }

    func saveNightscout(url: String, token: String?) async throws(ServiceConfigurationError) {
        let site: NightscoutSite
        do throws(NightscoutSite.ValidationError) {
            site = try NightscoutSite(url)
        } catch {
            throw .invalidNightscoutURL(Self.describe(error))
        }
        if let token {
            do throws(CredentialStoreError) {
                if token.isEmpty {
                    try credentials.delete(.nightscoutToken)
                } else {
                    try credentials.write(token, for: .nightscoutToken)
                }
            } catch {
                throw .keychain(error.message)
            }
        }
        preferences.nightscoutSiteURL = site.baseURL.absoluteString
        loadSharingSecrets()
        log(.upload, "Nightscout site saved (\(site.baseURL.host ?? "?")), token \(nightscoutHasToken ? "stored" : "not stored")")
        await applyUploadConfiguration()
        await uploads.credentialsChanged()
        send(.uploads)
    }

    private static func describe(_ error: NightscoutSite.ValidationError) -> String {
        switch error {
        case .notAURL: return "That is not a web address"
        case .insecureScheme: return "Use an https:// address"
        case .missingHost: return "The address has no host name"
        case .containsCredentialsOrQuery: return "Enter the address without a token or query; the token goes in its own field"
        }
    }

    func setNightscoutUploadEnabled(_ enabled: Bool) async {
        preferences.nightscoutUploadEnabled = enabled
        log(.upload, "Nightscout upload turned \(enabled ? "on" : "off")")
        await applyUploadConfiguration()
        uploads.flushIfDue()
    }

    func saveDexcomShare(accountName: String, password: String?, receiverSerialNumber: String) async throws(ServiceConfigurationError) {
        let name = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        let serial = receiverSerialNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let hasPassword = password.map { !$0.isEmpty } ?? shareHasPassword
        guard !name.isEmpty, !serial.isEmpty, hasPassword else { throw .incompleteDexcomShareCredentials }
        do throws(CredentialStoreError) {
            try credentials.write(name, for: .dexcomShareAccountName)
            if let password, !password.isEmpty {
                try credentials.write(password, for: .dexcomSharePassword)
            }
        } catch {
            throw .keychain(error.message)
        }
        preferences.dexcomShareReceiverSerial = serial
        loadSharingSecrets()
        log(.upload, "Dexcom Share credentials saved")
        await applyUploadConfiguration()
        // A wrong password is otherwise retried only every 30 min (account lockout): retry now.
        await uploads.credentialsChanged()
        send(.uploads)
    }

    func setDexcomShareRegion(_ region: DexcomShareRegion) async {
        preferences.dexcomShareRegion = region
        await applyUploadConfiguration()
    }

    func setDexcomShareEnabled(_ enabled: Bool) async {
        preferences.dexcomShareUploadEnabled = enabled
        log(.upload, "Dexcom Share upload turned \(enabled ? "on" : "off")")
        await applyUploadConfiguration()
        uploads.flushIfDue()
    }

    func retryUploads() async {
        await uploads.flushNow()
    }

    // MARK: - History import (S6: to the store only)

    var historyImport: HistoryImportState? { historyImports.state }

    func startNightscoutImport(scope: NightscoutImportScope) {
        guard let store = productionStore else {
            historyImports.fail(origin: .nightscout, message: "The reading database is not open yet")
            return
        }
        guard let site = nightscoutSite else {
            historyImports.fail(origin: .nightscout, message: "Enter your Nightscout address first")
            return
        }
        historyImports.startNightscout(
            site: site, credentials: credentials, repository: store,
            checkpoints: UserDefaultsNightscoutImportCheckpointStore(), scope: scope, transport: httpTransport
        )
    }

    func startClarityImport(fileData: Data, timeZone: TimeZone) {
        guard let store = productionStore else {
            historyImports.fail(origin: .clarityCSV, message: "The reading database is not open yet")
            return
        }
        historyImports.startClarity(data: fileData, timeZone: timeZone, repository: store)
    }

    func cancelHistoryImport() {
        historyImports.cancel()
    }

    func historyImportChanged(_ state: HistoryImportState, finished: Bool) {
        if finished {
            preferences.lastHistoryImport = state
        }
        send(.historyImport)
    }
}
