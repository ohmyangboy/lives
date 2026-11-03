import Foundation
import XCTest
@testable import LivePhotoService

final class FileCreationTimeTests: XCTestCase {
    func testCreationTimeUsesFileMetadataAndMissingFilesHaveNoDate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(MediaInspector.creationTimeMilliseconds(path: url.path))
        try Data([1]).write(to: url)
        let date = try XCTUnwrap(MediaInspector.creationTimeMilliseconds(path: url.path))
        XCTAssertLessThan(abs(date - Date().timeIntervalSince1970 * 1000), 10_000)
    }
    func testVideoInfoAddsCreationTimeWithoutRequiringItForOlderCallers() throws {
        var info = VideoInfo(path: "test.mp4", durationMs: 3000, width: 1920, height: 1080, codec: "h264")
        let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as! [String: Any]
        XCTAssertNil(old["createdAtMs"])
        info.createdAtMs = 123_456
        let current = try JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as! [String: Any]
        XCTAssertEqual(current["createdAtMs"] as? Double, 123_456)
    }
}
