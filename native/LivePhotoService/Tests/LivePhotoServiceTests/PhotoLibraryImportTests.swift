import Photos
import XCTest
@testable import LivePhotoService

final class PhotoLibraryImportTests: XCTestCase {
    @MainActor
    func testPickerGuidanceExplainsEmptyAndLimitedLibraries() {
        XCTAssertTrue(LivePhotoLibraryPicker.guidance(limited: false, count: 0).contains("没有找到 Live Photo"))
        XCTAssertTrue(LivePhotoLibraryPicker.guidance(limited: true, count: 0).contains("系统设置"))
        XCTAssertTrue(LivePhotoLibraryPicker.guidance(limited: false, count: 1).contains("下方图库"))
    }

    func testReadAuthorizationIsDistinctFromAddOnlyAndSupportsLimitedAccess() {
        XCTAssertNil(PhotoAuthorization.readError(for: .authorized))
        XCTAssertNil(PhotoAuthorization.readError(for: .limited))
        XCTAssertEqual(PhotoAuthorization.readError(for: .denied)?.code, "PHOTO_READ_DENIED")
        XCTAssertEqual(PhotoAuthorization.readError(for: .restricted)?.code, "PHOTO_READ_RESTRICTED")
        XCTAssertEqual(PhotoAuthorization.readError(for: .notDetermined)?.code, "PHOTO_READ_UNAVAILABLE")
        XCTAssertTrue(PhotoAuthorization.readError(for: .denied)?.recovery.contains("系统设置") == true)
        XCTAssertEqual(PhotoAuthorization.error(for: .denied)?.code, "PHOTO_PERMISSION_DENIED")
    }

    func testEditedLivePhotoKeepsOriginalResourcesTogether() throws {
        let pair = try PhotoLibraryImporter.originalResourceIndices(types: [.fullSizePhoto, .pairedVideo, .adjustmentData, .photo, .fullSizePairedVideo])
        XCTAssertEqual(pair.photo, 3)
        XCTAssertEqual(pair.video, 1)
        for types: [PHAssetResourceType] in [[], [.photo], [.photo, .video], [.photo, .fullSizePairedVideo], [.photo, .photo, .pairedVideo]] {
            XCTAssertThrowsError(try PhotoLibraryImporter.originalResourceIndices(types: types))
        }
    }

    func testCancelledSelectionDoesNotAccessLibrary() async throws {
        let pairs = try await PhotoLibraryImporter.export(identifiers: [], to: URL(fileURLWithPath: "/nonexistent"))
        XCTAssertTrue(pairs.isEmpty)
    }

    func testCancelledAndFailedImportsRemoveOnlyTheirOwnPartialResources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("existing.mov")
        try Data([1]).write(to: existing)
        let cancelled = try await PhotoLibraryWorkerClient.withImportDirectory(root: root) { directory in
            try Data([2]).write(to: directory.appendingPathComponent("partial.mov"))
            return []
        }
        XCTAssertTrue(cancelled.isEmpty)
        do {
            _ = try await PhotoLibraryWorkerClient.withImportDirectory(root: root) { directory in
                try Data([3]).write(to: directory.appendingPathComponent("partial.heic"))
                throw PhotoLibraryImporter.unavailableSelection
            }
            XCTFail("Expected error")
        } catch let error as ServiceError { XCTAssertEqual(error.code, "PHOTO_READ_LIMITED") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["existing.mov"])
        XCTAssertEqual(try Data(contentsOf: existing), Data([1]))
    }

    func testSuccessfulImportKeepsBothResourcesOutsideWorkerTemporaryDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let imported = try await PhotoLibraryWorkerClient.withImportDirectory(root: root) { directory in
            let photo = directory.appendingPathComponent("0.heic")
            let video = directory.appendingPathComponent("0.mov")
            try Data([1]).write(to: photo)
            try Data([2]).write(to: video)
            return [ImportedLivePhoto(video: VideoInfo(path: video.path, durationMs: 3000, width: 100, height: 100, codec: "avc1"),
                livePhoto: LivePhotoSource(photoPath: photo.path, contentIdentifier: "id", width: 100, height: 100, motionWidth: 100, motionHeight: 100))]
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: imported[0].video.path)), Data([2]))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: imported[0].livePhoto.photoPath)), Data([1]))
    }

    func testTaskCancellationRemovesPartialBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "partial file written")
        let task = Task {
            try await PhotoLibraryWorkerClient.withImportDirectory(root: root) { directory in
                try Data([1]).write(to: directory.appendingPathComponent("partial.mov"))
                started.fulfill()
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return []
            }
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
}
