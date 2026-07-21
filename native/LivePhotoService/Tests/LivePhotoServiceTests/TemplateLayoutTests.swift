import CoreGraphics
import XCTest
@testable import LivePhotoService

final class TemplateLayoutTests: XCTestCase {
    func testMediaLibraryFolderScanFindsSupportedVideosRecursively() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = root.appendingPathComponent("聚会", isDirectory: true)
        let hidden = root.appendingPathComponent(".cache", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data().write(to: root.appendingPathComponent("10.MOV"))
        try Data().write(to: nested.appendingPathComponent("2.mp4"))
        try Data().write(to: nested.appendingPathComponent("说明.txt"))
        try Data().write(to: hidden.appendingPathComponent("hidden.m4v"))

        let paths = try MediaLibraryScanner.scan(path: root.path)

        XCTAssertEqual(Set(paths.map { URL(fileURLWithPath: $0).lastPathComponent }), Set(["2.mp4", "10.MOV"]))
    }

    func testSupportedCanvasSizesCoverEveryEditorRatioAndQuality() {
        XCTAssertTrue(LivePhotoPipeline.supportsCanvas(width: 1080, height: 1920))
        XCTAssertTrue(LivePhotoPipeline.supportsCanvas(width: 1080, height: 1440))
        XCTAssertTrue(LivePhotoPipeline.supportsCanvas(width: 1080, height: 1080))
        XCTAssertTrue(LivePhotoPipeline.supportsCanvas(width: 720, height: 1280))
        XCTAssertTrue(LivePhotoPipeline.supportsCanvas(width: 720, height: 960))
        XCTAssertTrue(LivePhotoPipeline.supportsCanvas(width: 720, height: 720))
        XCTAssertTrue(LivePhotoPipeline.supportsCanvas(width: 1920, height: 1080))
        XCTAssertTrue(LivePhotoPipeline.supportsCanvas(width: 1440, height: 1080))
        XCTAssertTrue(LivePhotoPipeline.supportsCanvas(width: 1280, height: 720))
        XCTAssertTrue(LivePhotoPipeline.supportsCanvas(width: 960, height: 720))
        XCTAssertFalse(LivePhotoPipeline.supportsCanvas(width: 640, height: 480))
    }

    func testBitRateAdaptsToOutputFrameSize() {
        XCTAssertEqual(VideoRenderer.adaptiveBitRate(width: 1080, height: 1920), 12_000_000)
        XCTAssertEqual(VideoRenderer.adaptiveBitRate(width: 720, height: 1280), 5_333_333)
        XCTAssertEqual(VideoRenderer.adaptiveBitRate(width: 720, height: 720), 4_000_000)
    }

    func testStackThreeUsesEqualVerticalSlots() throws {
        let canvas = CGSize(width: 1080, height: 1920)
        let top = try TemplateLayout.rect(for: "top", templateId: "stack-3", canvas: canvas)
        let middle = try TemplateLayout.rect(for: "middle", templateId: "stack-3", canvas: canvas)
        let bottom = try TemplateLayout.rect(for: "bottom", templateId: "stack-3", canvas: canvas)
        XCTAssertEqual(top.height, 640, accuracy: 0.001)
        XCTAssertEqual(middle.minY, 640, accuracy: 0.001)
        XCTAssertEqual(bottom.minY, 1280, accuracy: 0.001)
    }

    func testSideBySideAndHeroLayoutsFillTheCanvas() throws {
        let canvas = CGSize(width: 1080, height: 1920)
        let left = try TemplateLayout.rect(for: "left", templateId: "side-2", canvas: canvas)
        let right = try TemplateLayout.rect(for: "right", templateId: "side-2", canvas: canvas)
        XCTAssertEqual(left.width, 540, accuracy: 0.001)
        XCTAssertEqual(right.minX, 540, accuracy: 0.001)

        let hero = try TemplateLayout.rect(for: "hero-left", templateId: "hero-left", canvas: canvas)
        let rightTop = try TemplateLayout.rect(for: "right-top", templateId: "hero-left", canvas: canvas)
        let rightBottom = try TemplateLayout.rect(for: "right-bottom", templateId: "hero-left", canvas: canvas)
        XCTAssertEqual(hero.width, 720, accuracy: 0.001)
        XCTAssertEqual(rightTop.minX, 720, accuracy: 0.001)
        XCTAssertEqual(rightTop.height + rightBottom.height, canvas.height, accuracy: 0.001)
    }

    func testVerticalThreeUsesEqualHorizontalSlots() throws {
        let canvas = CGSize(width: 1920, height: 1080)
        let left = try TemplateLayout.rect(for: "left", templateId: "side-3", canvas: canvas)
        let center = try TemplateLayout.rect(for: "center", templateId: "side-3", canvas: canvas)
        let right = try TemplateLayout.rect(for: "right", templateId: "side-3", canvas: canvas)
        XCTAssertEqual(left.width, 640, accuracy: 0.001)
        XCTAssertEqual(center.minX, 640, accuracy: 0.001)
        XCTAssertEqual(right.minX, 1280, accuracy: 0.001)
        XCTAssertEqual(right.maxX, canvas.width, accuracy: 0.001)
    }

    func testEveryTemplateHasTheExpectedClipCount() {
        XCTAssertEqual(LivePhotoPipeline.expectedClipCount(for: "single"), 1)
        XCTAssertEqual(LivePhotoPipeline.expectedClipCount(for: "side-2"), 2)
        XCTAssertEqual(LivePhotoPipeline.expectedClipCount(for: "side-3"), 3)
        XCTAssertEqual(LivePhotoPipeline.expectedClipCount(for: "hero-left"), 3)
        XCTAssertEqual(LivePhotoPipeline.expectedClipCount(for: "hero-top"), 3)
        XCTAssertEqual(LivePhotoPipeline.expectedClipCount(for: "weighted-3"), 3)
        XCTAssertEqual(LivePhotoPipeline.expectedClipCount(for: "unknown"), 0)
    }

    func testCancellationRegistryClearsFinishedJobs() async throws {
        let registry = CancellationRegistry()
        await registry.cancel("job")
        await XCTAssertThrowsErrorAsync(try await registry.check("job"))
        await registry.finish("job")
        try await registry.check("job")
    }

    func testLivePhotoValidationStopsBeforeStartingWhenCancelled() async throws {
        let registry = CancellationRegistry()
        await registry.cancel("cancelled-validation")
        do {
            try await LivePhotoPipeline.validatePair(
                photoURL: URL(fileURLWithPath: "/does-not-need-to-exist.jpg"),
                pairedVideoURL: URL(fileURLWithPath: "/does-not-need-to-exist.mov"),
                cancellations: registry,
                jobId: "cancelled-validation"
            )
            XCTFail("Expected validation to stop")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, ServiceError.cancelled.code)
        }
    }

    func testLivePhotoPairWhenFixtureIsProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let photoPath = environment["LIVE_COLLAGE_TEST_PHOTO"],
              let videoPath = environment["LIVE_COLLAGE_TEST_VIDEO"] else {
            throw XCTSkip("Set Live Photo fixture paths to run the Photos integration check")
        }
        let registry = CancellationRegistry()
        try await LivePhotoPipeline.validatePair(
            photoURL: URL(fileURLWithPath: photoPath),
            pairedVideoURL: URL(fileURLWithPath: videoPath),
            cancellations: registry,
            jobId: "fixture-validation",
            timeoutNanoseconds: 5_000_000_000
        )
    }

    func testFolderExportCopiesAPairedResourceSetWithoutOverwriting() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let sourcePhoto = root.appendingPathComponent("source.jpg")
        let sourceVideo = root.appendingPathComponent("source.mov")
        try Data("photo".utf8).write(to: sourcePhoto)
        try Data("video".utf8).write(to: sourceVideo)
        let destination = root.appendingPathComponent("output", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let first = try LivePhotoPipeline.copyPair(photoURL: sourcePhoto, videoURL: sourceVideo, toDirectoryPath: destination.path, now: date)
        let second = try LivePhotoPipeline.copyPair(photoURL: sourcePhoto, videoURL: sourceVideo, toDirectoryPath: destination.path, now: date)

        XCTAssertTrue(fileManager.fileExists(atPath: first.photoPath))
        XCTAssertTrue(fileManager.fileExists(atPath: first.videoPath))
        XCTAssertNotEqual(first.photoPath, second.photoPath)
        XCTAssertNotEqual(first.videoPath, second.videoPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: second.photoPath)), Data("photo".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: second.videoPath)), Data("video".utf8))
    }

    func testAspectFillCentersHorizontalOverflow() {
        let transform = TemplateLayout.aspectFillTransform(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: .identity,
            target: CGRect(x: 0, y: 0, width: 1080, height: 640),
            centerX: 0.5,
            centerY: 0.5,
            userScale: 1
        )
        let rendered = CGRect(x: 0, y: 0, width: 1920, height: 1080).applying(transform)
        XCTAssertLessThanOrEqual(rendered.minX, 0)
        XCTAssertGreaterThanOrEqual(rendered.maxX, 1080)
        XCTAssertEqual(rendered.height, 640, accuracy: 0.01)
    }

    func testLandscapeSideBySideCropIsConvertedBackToSourceCoordinates() {
        let naturalSize = CGSize(width: 640, height: 360)
        let target = CGRect(x: 0, y: 0, width: 640, height: 720)
        let transform = TemplateLayout.aspectFillTransform(
            naturalSize: naturalSize,
            preferredTransform: .identity,
            target: target,
            centerX: 0.5,
            centerY: 0.5,
            userScale: 1
        )
        let crop = TemplateLayout.sourceCropRectangle(
            target: target,
            transform: transform,
            naturalSize: naturalSize
        )

        XCTAssertEqual(crop.minX, 160, accuracy: 0.001)
        XCTAssertEqual(crop.minY, 0, accuracy: 0.001)
        XCTAssertEqual(crop.width, 320, accuracy: 0.001)
        XCTAssertEqual(crop.height, 360, accuracy: 0.001)
        XCTAssertEqual(crop.applying(transform), target)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
