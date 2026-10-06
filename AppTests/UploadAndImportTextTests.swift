import NightscoutKit
import XCTest
@testable import Sensor

/// NightscoutKit review m3 in the UI: readings held because they are dated ahead of the phone's
/// clock, or dropped for impossible dates, each get their own line (S5) instead of the generic
/// "not getting through"; and a stopped import's message is shown in full.
@MainActor
final class UploadAndImportTextTests: XCTestCase {
    private func summary(_ status: NightscoutKit.UploadStatus) -> UploaderSummary {
        UploaderSummary(isEnabled: true, isConfigured: true, liveOutputsAllowed: true, status: status, setupError: nil, problemSince: t0)
    }

    func test_heldAndDiscardedReadingsHaveTheirOwnLine() {
        var held = NightscoutKit.UploadStatus(destination: "Nightscout")
        held.heldInFuture = 3
        XCTAssertTrue(held.isFailing)
        XCTAssertEqual(ServiceHealthMapping.uploadProblem(summary(held)),
                       "3 readings are waiting because they're dated ahead of the phone's clock; they'll upload when the clock catches up.")
        held.heldInFuture = 1
        XCTAssertEqual(ServiceHealthMapping.uploadProblem(summary(held)),
                       "1 reading is waiting because it's dated ahead of the phone's clock; it'll upload when the clock catches up.")
        guard case .failing(_, let line, _) = ServiceHealthMapping.uploadStatus(summary(held), notSetUp: "", now: t0) else {
            return XCTFail("held readings are a problem (S5)")
        }
        XCTAssertEqual(line, ServiceHealthMapping.uploadProblem(summary(held)), "the Settings note and the banner use it")

        var discarded = NightscoutKit.UploadStatus(destination: "Dexcom Share")
        discarded.discardedSinceLastSuccess = 2
        discarded.lastDiscardReason = "2 readings dated before 1970 or more than a day in the future (S2)"
        XCTAssertEqual(ServiceHealthMapping.uploadProblem(summary(discarded)),
                       "2 readings weren't uploaded and won't be (latest: 2 readings dated before 1970 or more than a day in the future).")
        discarded.lastDiscardReason = nil
        XCTAssertEqual(ServiceHealthMapping.uploadProblem(summary(discarded)), "2 readings weren't uploaded and won't be.")

        // A connection failure is still named first.
        var both = held
        both.consecutiveFailures = 2
        both.lastError = UploadError(.transport, "The Nightscout site didn't answer.")
        XCTAssertEqual(ServiceHealthMapping.uploadProblem(summary(both)), "The Nightscout site didn't answer.")
        XCTAssertFalse(ServiceHealthMapping.uploadProblem(summary(held)).contains("not getting through"))
    }

    /// NightscoutKit's `unusableHistory` names the date range and what to do: shown in full, with
    /// no generic advice that would contradict it.
    func test_stoppedImportMessageIsShownInFull() {
        let unusable = NightscoutImportError.unusableHistory(
            "Nightscout has a full page of entries between 2026-01-01T00:00:00Z and 2026-01-02T00:00:00Z without a usable date, so the import cannot continue past them. Check or delete those entries in Nightscout, then reset the import. Readings imported so far are kept."
        ).description
        XCTAssertEqual(OnboardingText.importFailure(unusable), unusable)
        var state = HistoryImportState(origin: .nightscout, phase: .failed(message: unusable), readingsImported: 10, readingsSkippedByStore: 0,
                                       coveredFrom: nil, coveredTo: nil, skipped: [:], rejectedFutureDated: 0, startedAt: t0, finishedAt: t0)
        XCTAssertEqual(OnboardingMapping.importProgress(state)?.errorMessage, unusable, "the facade's message, whole")
        state.phase = .failed(message: "Nightscout returned HTTP 401")
        XCTAssertEqual(OnboardingText.importFailure("Nightscout returned HTTP 401"),
                       "Nightscout returned HTTP 401. Already-imported readings are kept; running the import again continues where it stopped.")
    }
}
