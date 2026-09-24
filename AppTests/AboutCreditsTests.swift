import XCTest
@testable import Sensor

/// HANDOFF §3: the in-app credits carry NOTICE.md — every project named there, with its licence.
final class AboutCreditsTests: XCTestCase {
    private static let notice: String = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("NOTICE.md")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// Project names from NOTICE.md's two tables: the link text of each row's first cell.
    private var noticeProjects: [String] {
        Self.notice.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("| ["), let close = line.firstIndex(of: "]") else { return nil }
            return String(line[line.index(line.startIndex, offsetBy: 3)..<close])
        }
    }

    func test_everyNoticeProjectIsCreditedInTheApp() {
        XCTAssertFalse(Self.notice.isEmpty, "NOTICE.md not found")
        let projects = noticeProjects
        XCTAssertGreaterThanOrEqual(projects.count, 10)
        let credited = (Credits.included + Credits.references).map(\.name)
        for project in projects {
            XCTAssertTrue(credited.contains(project), "\(project) is in NOTICE.md but not in the About page")
        }
    }

    func test_licencesMatchNotice() {
        for entry in Credits.included + Credits.references {
            let row = Self.notice.split(separator: "\n").first { $0.hasPrefix("| [\(entry.name)]") }
            XCTAssertNotNil(row, "\(entry.name) has no NOTICE.md row")
            XCTAssertTrue(row?.contains(entry.license) ?? false, "\(entry.name): licence \(entry.license) not in \(row ?? "")")
        }
    }
}
