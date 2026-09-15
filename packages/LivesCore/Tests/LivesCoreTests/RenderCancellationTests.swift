import XCTest
@testable import LivesCore

final class RenderCancellationTests: XCTestCase {
    func testCancellationNotifiesAllNativeResourcesOnceAndPreservesReason() async throws {
        let cancellation = RenderCancellation()
        let calls = expectation(description: "取消两个原生资源")
        calls.expectedFulfillmentCount = 2
        cancellation.onCancel { calls.fulfill() }
        cancellation.onCancel { calls.fulfill() }
        let removed = cancellation.onCancel { XCTFail("已注销的资源不应被取消") }
        cancellation.removeHandler(removed)
        cancellation.cancel(reason: .backgroundExpired)
        cancellation.cancel()
        await fulfillment(of: [calls], timeout: 2)
        XCTAssertEqual(cancellation.reason, .backgroundExpired)
        XCTAssertThrowsError(try cancellation.check()) { error in
            XCTAssertEqual(error.localizedDescription, cancellation.failureMessage)
        }
        let late = expectation(description: "取消后才创建的资源也应停止")
        cancellation.onCancel { late.fulfill() }
        await fulfillment(of: [late], timeout: 2)
    }

    func testUserCancellationIsCancellationError() {
        let cancellation = RenderCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try cancellation.check()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertNil(cancellation.failureMessage)
    }

    func testIdleDeadlineCancelsNativeResourceWithoutProgressCallbacks() async {
        let stopped = expectation(description: "原生读取中断")
        let cancellation = RenderCancellation()
        cancellation.onCancel { stopped.fulfill() }
        let watchdog = RenderWatchdog(cancellation: cancellation, idleTimeout: 0.04, totalTimeout: 2, pollInterval: 0.01)
        defer { watchdog.finish() }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(cancellation.reason, .timedOut)
    }

    func testFinishedWatchdogDoesNotCancelCompletedOutput() async throws {
        let cancellation = RenderCancellation()
        let watchdog = RenderWatchdog(cancellation: cancellation, idleTimeout: 0.04, totalTimeout: 0.1, pollInterval: 0.01)
        watchdog.finish()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(cancellation.isCancelled)
    }

    func testCancelledRenderNeverCreatesOutputDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cancellation = RenderCancellation()
        cancellation.cancel()
        do {
            _ = try await LivesMediaEngine.render(request: RenderRequest(project: ProjectDocument(),
                canvasSize: CanvasSize(width: 320, height: 320)), resolvedSources: [:],
                outputDirectory: directory, cancellation: cancellation)
            XCTFail("已取消的生成不应成功")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
