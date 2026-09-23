// Ported from xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0, like this project.
// ConstantsDexcomShare.swift has no copyright header in the original; DexcomShareModels.swift has:
//
//  DexcomShareModels.swift
//  xdrip
//
//  Created by Paul Plant on 4/9/25.
//  Copyright © 2025 Johan Degraeve. All rights reserved.
//
// Ported from xDrip4iOS xDrip/Constants/ConstantsDexcomShare.swift @ 7.1.0 (0370937)
// Ported from xDrip4iOS xDrip/Managers/DexcomShare/DexcomShareModels.swift @ 7.1.0 (0370937)
//
// UNOFFICIAL AND SUBJECT TO BREAKING. Dexcom Share has no public upload API. These endpoints,
// the application id and the user-agent strings are what the Dexcom app used years ago, as
// reverse-engineered by the community (xDrip4iOS, xDrip+, share2nightscout-bridge). Dexcom can
// change or block them at any time; the uploader then fails loudly (S5) and Nightscout, the
// primary follow path, is unaffected.

import Foundation

/// A Dexcom Share server region (PROGRESS D7: Michael is US).
public struct DexcomShareServer: Sendable, Equatable {
    /// Base URL; endpoint paths are appended to it.
    let baseURL: URL

    /// US accounts: `https://share2.dexcom.com/ShareWebServices/Services`
    /// (ConstantsDexcomShare.swift:11 `usBaseShareUrl`).
    public static let us = DexcomShareServer(baseURL: URL(string: "https://share2.dexcom.com/ShareWebServices/Services")!)

    /// Accounts outside the US (Australia, Canada, Europe, …; DexcomShareModels.swift:59-66):
    /// `https://shareous1.dexcom.com/ShareWebServices/Services`
    /// (ConstantsDexcomShare.swift:13 `globalBaseShareUrl`). Japan uses a third server with a
    /// different application id (ConstantsDexcomShare.swift:7, 15), not ported.
    public static let outsideUS = DexcomShareServer(baseURL: URL(string: "https://shareous1.dexcom.com/ShareWebServices/Services")!)

    /// Tests point this at a localhost mock server; production code uses `.us` / `.outsideUS`.
    init(baseURL: URL) {
        self.baseURL = baseURL
    }
}

/// Constants of the Share protocol (ConstantsDexcomShare.swift @ 7.1.0).
enum DexcomShareConstants {
    /// Sent with every login (ConstantsDexcomShare.swift:5 `applicationId`; US and outside-US,
    /// DexcomShareModels.swift:85-93).
    static let applicationID = "d89443d2-327c-4a6f-89e5-496bbb0317db"

    /// Step 1 of login: account name + password → account id (ConstantsDexcomShare.swift:25).
    static let authenticatePath = "General/AuthenticatePublisherAccount"
    /// Step 2 of login: account id + password → session id (ConstantsDexcomShare.swift:27).
    static let loginPath = "General/LoginPublisherAccountById"
    /// Upload EGVs (ConstantsDexcomShare.swift:19).
    static let postReceiverEgvRecordsPath = "Publisher/PostReceiverEgvRecords"
    /// Start the remote monitoring session for the receiver serial (ConstantsDexcomShare.swift:21).
    static let startRemoteMonitoringSessionPath = "Publisher/StartRemoteMonitoringSession"

    /// The session id Share returns for a failed login (ConstantsDexcomShare.swift:32).
    static let failedSessionID = "00000000-0000-0000-0000-000000000000"

    /// User-Agent for the two login calls (DexcomShareUploadManager.swift:546, 602).
    static let loginUserAgent = "Dexcom%20Share/3.0.2.11 CFNetwork/1390 Darwin/22.0.0"
    /// User-Agent for upload and start-session (DexcomShareUploadManager.swift:212, 771).
    static let publisherUserAgent = "Dexcom Share/3.0.2.11 CFNetwork/711.2.23 Darwin/14.0.0"

    /// "TA" field of the upload body. xDrip4iOS always sends -5 (DexcomShareUploadManager.swift:366);
    /// its meaning is undocumented.
    static let uploadTA = -5

    /// xDrip4iOS uploads at most the last 8 hours (DexcomShareUploadManager.swift:338-339).
    static let maxReadingAge: TimeInterval = 8 * 60 * 60
}

/// Error `Code` values in Share's JSON error bodies, as handled by
/// DexcomShareUploadManager.swift:425-478 (upload) and :713-727 (login). Matched
/// case-insensitively, as xDrip4iOS does for the login codes (:717-722 compare `uppercased()`).
enum ShareErrorCode: String, CaseIterable, Sendable {
    case sessionNotValid = "SessionNotValid"
    case sessionIDNotFound = "SessionIdNotFound"
    case monitoringSessionNotActive = "MonitoringSessionNotActive"
    case duplicateEgvPosted = "DuplicateEgvPosted"
    case monitoredReceiverSerialNumberDoesNotMatch = "MonitoredReceiverSerialNumberDoesNotMatch"
    case monitoredReceiverNotAssigned = "MonitoredReceiverNotAssigned"
    case accountNotFound = "SSO_AuthenticateAccountNotFound"
    case passwordInvalid = "SSO_AuthenticatePasswordInvalid"
    /// Spelling as sent by Dexcom (DexcomShareUploadManager.swift:721).
    case maxAttemptsExceeded = "SSO_AuthenticateMaxAttemptsExceeed"

    /// `nil` for a missing or unknown code.
    init?(code: String?) {
        guard let code else { return nil }
        guard let match = Self.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(code) == .orderedSame }) else { return nil }
        self = match
    }
}
