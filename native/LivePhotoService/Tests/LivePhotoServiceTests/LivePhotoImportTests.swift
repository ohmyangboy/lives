import XCTest
@testable import LivePhotoService

final class LivePhotoImportTests: XCTestCase {
    func testPairingUsesIdentifiersRatherThanSelectionOrder() throws {
        XCTAssertEqual(try LivePhotoImporter.matchedIndices(photoIDs: ["a", "b"], videoIDs: ["b", "a"]), [1, 0])
    }

    func testPairingRejectsMissingMismatchedAndAmbiguousResources() {
        for (photos, videos) in [([], []), (["a"], []), (["a"], ["b"]), ([""], [""]), (["a", "a"], ["a", "a"])] {
            XCTAssertThrowsError(try LivePhotoImporter.matchedIndices(photoIDs: photos, videoIDs: videos))
        }
    }

    func testMixedSelectionMatchesOnlyUniquePhotoIdentifiers() throws {
        XCTAssertEqual(try LivePhotoImporter.matchedIndices(photoIDs: ["a", "b"], videoIDs: ["", "b", "other", "a"], allowUnmatchedVideos: true), [3, 1])
        XCTAssertThrowsError(try LivePhotoImporter.matchedIndices(photoIDs: ["missing"], videoIDs: ["", "other"], allowUnmatchedVideos: true))
        XCTAssertThrowsError(try LivePhotoImporter.matchedIndices(photoIDs: ["a"], videoIDs: ["a", "a"], allowUnmatchedVideos: true))
    }

    func testUnreadablePhotoProducesActionableError() async {
        do {
            _ = try await LivePhotoImporter.pair(paths: ["/nonexistent/live.heic", "/nonexistent/live.mov"])
            XCTFail("Missing files must not import as ordinary video")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, "INVALID_LIVE_PHOTO")
            XCTAssertTrue(error.message.contains("读取"))
            XCTAssertFalse(error.recovery.isEmpty)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testLegacyRenderProtocolAndLivePhotoCoreValidation() throws {
        let json = #"{"id":"project","templateId":"single","canvas":{"width":720,"height":1280,"fps":30,"durationMs":3000},"clips":[{"id":"clip","sourcePath":"/tmp/video.mov","sourceDurationMs":3000,"startTimeMs":0,"crop":{"normalizedCenterX":0.5,"normalizedCenterY":0.5,"scale":1},"targetSlotId":"full","audioEnabled":false,"coverTimeMs":1500}],"coverTimeMs":1500}"#
        let project = try JSONDecoder().decode(RenderProject.self, from: Data(json.utf8))
        XCTAssertNil(project.clips[0].livePhoto)
        XCTAssertNoThrow(try SharedCoreBridge.validate(project))
        var clip = project.clips[0]
        clip.kind = "livePhoto"
        let incomplete = RenderProject(id: project.id, templateId: project.templateId, canvas: project.canvas, clips: [clip], coverTimeMs: project.coverTimeMs)
        XCTAssertThrowsError(try SharedCoreBridge.validate(incomplete))
        clip.livePhoto = LivePhotoSource(photoPath: "/tmp/photo.heic", contentIdentifier: "id", width: 4032, height: 3024, motionWidth: 1920, motionHeight: 1080)
        let live = RenderProject(id: project.id, templateId: project.templateId, canvas: project.canvas, clips: [clip], coverTimeMs: project.coverTimeMs)
        XCTAssertNoThrow(try SharedCoreBridge.validate(live))
        let decoded = try JSONDecoder().decode(RenderProject.self, from: JSONEncoder().encode(live))
        XCTAssertEqual(decoded.clips[0].livePhoto?.photoPath, "/tmp/photo.heic")
        XCTAssertEqual(decoded.clips[0].kind, "livePhoto")
    }
}
