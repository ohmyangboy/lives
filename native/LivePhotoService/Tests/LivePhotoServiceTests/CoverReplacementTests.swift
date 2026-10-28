import XCTest
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
@testable import LivePhotoService

final class CoverReplacementTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory = tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    private func createSampleImage(width: Int, height: Int, destinationURL: URL, orientation: Int? = nil) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "TestError", code: 1)
        }
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.3, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: "TestError", code: 2)
        }
        var properties: [CFString: Any] = [:]
        if let orientation = orientation {
            properties[kCGImagePropertyOrientation] = orientation
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "TestError", code: 3)
        }
    }

    func testWriteCoverWithCustomImageEmbedsAppleMakerIdentifierAndMatchesCanvasSize() async throws {
        let imageURL = tempDirectory.appendingPathComponent("custom_cover.jpg")
        try createSampleImage(width: 800, height: 1200, destinationURL: imageURL)

        let project = RenderProject(
            id: UUID().uuidString,
            templateId: "single",
            canvas: .init(width: 1080, height: 1920, fps: 30, durationMs: 3000),
            clips: [
                .init(
                    id: UUID().uuidString,
                    sourcePath: "/tmp/dummy.mov",
                    sourceDurationMs: 4000,
                    startTimeMs: 0,
                    crop: .init(normalizedCenterX: 0.5, normalizedCenterY: 0.5, scale: 1.0),
                    targetSlotId: "full",
                    audioEnabled: false,
                    coverTimeMs: 1500,
                    coverPhotoPath: imageURL.path
                ),
            ],
            coverTimeMs: 1500
        )

        let outputURL = tempDirectory.appendingPathComponent("cover.jpg")
        let contentID = UUID().uuidString

        try await LivePhotoPipeline.writeCover(project: project, to: outputURL, contentIdentifier: contentID)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        guard let source = CGImageSourceCreateWithURL(outputURL as CFURL, nil) else {
            XCTFail("Failed to read generated cover image")
            return
        }

        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            XCTFail("Failed to read image properties")
            return
        }

        let pixelWidth = properties[kCGImagePropertyPixelWidth as String] as? Int
        let pixelHeight = properties[kCGImagePropertyPixelHeight as String] as? Int
        XCTAssertEqual(pixelWidth, 1080)
        XCTAssertEqual(pixelHeight, 1920)

        let makerApple = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any]
        XCTAssertEqual(makerApple?["17"] as? String, contentID)
    }

    func testWriteCoverWithCorruptImageThrowsCoverImageFailed() async throws {
        let corruptURL = tempDirectory.appendingPathComponent("corrupted.jpg")
        try "this is not an image".write(to: corruptURL, atomically: true, encoding: .utf8)

        let project = RenderProject(
            id: UUID().uuidString,
            templateId: "single",
            canvas: .init(width: 1080, height: 1920, fps: 30, durationMs: 3000),
            clips: [
                .init(
                    id: UUID().uuidString,
                    sourcePath: "/tmp/dummy.mov",
                    sourceDurationMs: 4000,
                    startTimeMs: 0,
                    crop: .init(normalizedCenterX: 0.5, normalizedCenterY: 0.5, scale: 1.0),
                    targetSlotId: "full",
                    audioEnabled: false,
                    coverTimeMs: 1500,
                    coverPhotoPath: corruptURL.path
                ),
            ],
            coverTimeMs: 1500
        )

        let outputURL = tempDirectory.appendingPathComponent("cover.jpg")

        do {
            try await LivePhotoPipeline.writeCover(project: project, to: outputURL, contentIdentifier: "TEST-ID")
            XCTFail("Expected writeCover to throw for corrupt image")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, "COVER_IMAGE_FAILED")
        }
    }

    func testLoadCoverImageHandlesExifOrientation() throws {
        let rotatedURL = tempDirectory.appendingPathComponent("rotated.jpg")
        // Create 600x800 image with orientation 6 (90 deg clockwise) -> decoded image should be 800x600
        try createSampleImage(width: 600, height: 800, destinationURL: rotatedURL, orientation: 6)

        let loaded = try LivePhotoPipeline.loadCoverImage(from: rotatedURL.path)
        XCTAssertEqual(loaded.width, 800)
        XCTAssertEqual(loaded.height, 600)
    }

    func testSharedCoreBridgeRejectsUnreadableCoverPhotoPath() {
        let project = RenderProject(
            id: UUID().uuidString,
            templateId: "single",
            canvas: .init(width: 1080, height: 1920, fps: 30, durationMs: 3000),
            clips: [
                .init(
                    id: UUID().uuidString,
                    sourcePath: "/tmp/fixture.mov",
                    sourceDurationMs: 4000,
                    startTimeMs: 0,
                    crop: .init(normalizedCenterX: 0.5, normalizedCenterY: 0.5, scale: 1),
                    targetSlotId: "full",
                    audioEnabled: false,
                    coverTimeMs: 1500,
                    coverPhotoPath: "/nonexistent/path/cover.jpg"
                ),
            ],
            coverTimeMs: 1500
        )

        XCTAssertThrowsError(try SharedCoreBridge.validate(project)) { error in
            let serviceError = error as? ServiceError
            XCTAssertEqual(serviceError?.code, "COVER_IMAGE_FAILED")
        }
    }
}
