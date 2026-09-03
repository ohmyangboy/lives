import AVFoundation
import XCTest
@testable import LivePhotoService

final class VideoPreviewTests: XCTestCase {
    func testStandardDefinitionSourcesDoNotNeedAProxy() {
        XCTAssertFalse(VideoPreviewGenerator.shouldGeneratePreview(for: CGSize(width: 1920, height: 1080)))
        XCTAssertFalse(VideoPreviewGenerator.shouldGeneratePreview(for: CGSize(width: 1080, height: 1920)))
        XCTAssertTrue(VideoPreviewGenerator.shouldGeneratePreview(for: CGSize(width: 3840, height: 2160)))
    }

    func testHighResolutionFixtureGetsAWebViewSafePreview() async throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["LIVES_PREVIEW_FIXTURE"] else {
            throw XCTSkip("Set LIVES_PREVIEW_FIXTURE to run the high-resolution preview regression")
        }

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LivesPreviewTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let preview = try await VideoPreviewGenerator.prepare(
            path: sourcePath,
            cacheDirectory: cacheDirectory
        )

        XCTAssertNotEqual(preview.path, sourcePath)
        let asset = AVURLAsset(url: URL(fileURLWithPath: preview.path))
        let isPlayable = try await asset.load(.isPlayable)
        XCTAssertTrue(isPlayable)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertLessThanOrEqual(max(size.width, size.height), 1920)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let image = try await generator.image(at: .zero).image
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)

        let secondPreview = try await VideoPreviewGenerator.prepare(
            path: sourcePath,
            cacheDirectory: cacheDirectory
        )
        XCTAssertEqual(secondPreview.path, preview.path)
    }
}
