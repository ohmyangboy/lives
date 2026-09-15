import Foundation
import XCTest
@testable import LivesCore

final class PreviewReaderCancellationTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    func testCancellationRequestsNativeStopOnlyOnce() throws {
        let counter = Counter()
        let controller = PreviewReaderCancellationController(timeout: nil)
        controller.install { counter.increment() }

        controller.cancel()
        controller.cancel()

        XCTAssertEqual(counter.count, 1)
        XCTAssertThrowsError(try controller.check()) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testTimeoutCancelsLateInstalledReaderAndStaysTimedOut() async throws {
        let counter = Counter()
        let controller = PreviewReaderCancellationController(timeout: .milliseconds(10))
        try await Task.sleep(for: .milliseconds(30))

        controller.install { counter.increment() }
        controller.finish()

        XCTAssertEqual(counter.count, 1)
        XCTAssertThrowsError(try controller.check()) { error in
            XCTAssertEqual(error as? PreviewReaderCancellationController.Failure, .timedOut)
        }
    }

    func testFinishedReadIsNotCancelledByLateDeadline() async throws {
        let counter = Counter()
        let controller = PreviewReaderCancellationController(timeout: .milliseconds(20))
        controller.install { counter.increment() }

        controller.finish()
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(counter.count, 0)
        XCTAssertNoThrow(try controller.check())
    }
}
