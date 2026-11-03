import Foundation
import XCTest
@testable import LivePhotoService

final class PhotoDiagnosticsTests: XCTestCase {
    private func withLog(_ body: (PhotoDiagnosticsLog) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(PhotoDiagnosticsLog(url: directory.appendingPathComponent("photo-diagnostics.json")))
    }

    private func event(at date: Date = Date(), processID: Int32 = 123, errors: [PhotoDiagnosticEvent.ErrorCode] = []) -> PhotoDiagnosticEvent {
        PhotoDiagnosticEvent(date: date, processID: processID, operation: .save, outcome: .failed,
                             addOnlyStatus: 3, readWriteStatus: 2, errors: errors)
    }

    func testFailurePersistsAcrossReadersWithoutPrivateErrorDetailsOrResourcePaths() throws {
        try withLog { log in
            let privateURL = log.url.deletingLastPathComponent().appendingPathComponent("private-holiday.jpg")
            try FileManager.default.createDirectory(at: privateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: privateURL)
            let underlying = NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [
                NSFilePathErrorKey: "/Users/private-person/Pictures/private-holiday.jpg",
                NSLocalizedDescriptionKey: "private-person private-holiday.jpg secret-token",
            ])
            let error = NSError(domain: "PHPhotosErrorDomain", code: 3302, userInfo: [NSUnderlyingErrorKey: underlying])
            var failure = event(errors: PhotoDiagnosticEvent.errorCodes(from: error))
            failure.photo = .init(url: privateURL)
            failure.video = .init(url: privateURL.appendingPathExtension("missing"))
            try log.append(failure)

            let reopened = PhotoDiagnosticsLog(url: log.url)
            let summary = try reopened.feedbackSummary()
            XCTAssertTrue(summary.contains("PHPhotosErrorDomain:3302>NSCocoaErrorDomain:513"))
            XCTAssertTrue(summary.contains("add=authorized read=denied"))
            XCTAssertTrue(summary.contains("jpg={exists:true,readable:true,bytes:3}"))
            XCTAssertTrue(summary.contains("mov={exists:false,readable:false,bytes:unknown}"))
            let persisted = try String(contentsOf: log.url, encoding: .utf8)
            for value in ["private-person", "private-holiday", "secret-token", "/Users/", privateURL.path] {
                XCTAssertFalse(persisted.contains(value))
                XCTAssertFalse(summary.contains(value))
            }
        }
    }

    func testUnknownErrorDomainsAreRedactedAndMultipleUnderlyingErrorsAreBounded() {
        let error = NSError(domain: "/Users/private-person/secret.mov", code: 1, userInfo: [
            NSMultipleUnderlyingErrorsKey: (2...20).map { NSError(domain: NSPOSIXErrorDomain, code: $0) },
        ])
        let codes = PhotoDiagnosticEvent.errorCodes(from: error)
        XCTAssertEqual(codes.count, 4)
        XCTAssertEqual(codes.first?.domain, "other")
        XCTAssertEqual(codes.last?.code, 4)
    }

    func testRetentionAndFeedbackSizeKeepRecentFailuresAfterRelaunch() throws {
        try withLog { log in
            let now = Date()
            try log.append(event(at: now.addingTimeInterval(-PhotoDiagnosticsLog.retention - 60)))
            let errors = [PhotoDiagnosticEvent.ErrorCode(domain: "PHPhotosErrorDomain", code: 3302)]
            for index in 0..<100 {
                try log.append(event(at: now.addingTimeInterval(Double(index)), processID: Int32(index), errors: errors))
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let data = try Data(contentsOf: log.url)
            let events = try decoder.decode([PhotoDiagnosticEvent].self, from: data)
            XCTAssertEqual(events.count, PhotoDiagnosticsLog.maximumEvents)
            XCTAssertEqual(events.first?.processID, 36)
            XCTAssertLessThanOrEqual(data.count, PhotoDiagnosticsLog.maximumBytes)
            let summary = try log.feedbackSummary(now: now.addingTimeInterval(100))
            XCTAssertTrue(summary.contains("pid=99 "))
            XCTAssertLessThanOrEqual(summary.utf8.count, 1600)
            XCTAssertEqual(try log.feedbackSummary(now: now.addingTimeInterval(PhotoDiagnosticsLog.retention + 200)),
                           "No Photos diagnostics in the last 7 days.")
        }
    }

    func testConcurrentWorkersDoNotLoseEvents() throws {
        try withLog { log in
            DispatchQueue.concurrentPerform(iterations: 20) { index in
                let entry = PhotoDiagnosticEvent(date: Date(), processID: Int32(index), operation: .authorization,
                                                 outcome: .succeeded, addOnlyStatus: 3, readWriteStatus: 0)
                do { try log.append(entry) }
                catch { XCTFail("Concurrent diagnostics write failed: \(error)") }
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let events = try decoder.decode([PhotoDiagnosticEvent].self, from: Data(contentsOf: log.url))
            XCTAssertEqual(Set(events.map(\.processID)), Set((0..<20).map(Int32.init)))
        }
    }

    func testFeedbackKeepsLatestFailureEvenAfterSuccessfulRetries() throws {
        try withLog { log in
            try log.append(event(errors: [.init(domain: "PHPhotosErrorDomain", code: 3302)]))
            for index in 0..<10 {
                let success = PhotoDiagnosticEvent(date: Date(), processID: Int32(index), operation: .save,
                                                   outcome: .succeeded, addOnlyStatus: 3, readWriteStatus: 3)
                try log.append(success)
            }
            let summary = try log.feedbackSummary()
            XCTAssertTrue(summary.contains("PHPhotosErrorDomain:3302"))
            XCTAssertTrue(summary.contains("save/succeeded pid=9 "))
            XCTAssertEqual(summary.split(separator: "\n").count, 7)
        }
    }

    func testMalformedAndOversizedLogsRecoverOnNextEvent() throws {
        try withLog { log in
            try FileManager.default.createDirectory(at: log.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            for data in [Data("broken json with /Users/private-person".utf8), Data(repeating: 0, count: PhotoDiagnosticsLog.maximumBytes + 1)] {
                try data.write(to: log.url)
                XCTAssertEqual(try log.feedbackSummary(), "No Photos diagnostics in the last 7 days.")
                try log.append(event())
                XCTAssertTrue(try log.feedbackSummary().contains("save/failed"))
                XCTAssertLessThan(try Data(contentsOf: log.url).count, PhotoDiagnosticsLog.maximumBytes)
            }
        }
    }
}
