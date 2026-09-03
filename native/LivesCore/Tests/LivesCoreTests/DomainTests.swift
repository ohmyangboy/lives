import XCTest
@testable import LivesCore

final class DomainTests: XCTestCase {
    func testCanvasDimensionsMatchMacRules() {
        XCTAssertEqual(CanvasGeometry.size(for: CanvasSettings(aspectRatio: .portrait34, quality: .p720)), CanvasSize(width: 720, height: 960))
        XCTAssertEqual(CanvasGeometry.size(for: CanvasSettings(aspectRatio: .landscape169, quality: .p1080)), CanvasSize(width: 1920, height: 1080))
    }

    func testCurrentQualityTiersExposeFreeAndProSizes() {
        let low = CanvasGeometry.size(for: CanvasSettings(aspectRatio: .landscape169, quality: .p480))
        XCTAssertEqual(min(low.width, low.height), 480)
        XCTAssertEqual(CanvasGeometry.size(for: CanvasSettings(aspectRatio: .landscape169, quality: .p1080)), CanvasSize(width: 1920, height: 1080))
        XCTAssertEqual(CanvasGeometry.size(for: CanvasSettings(aspectRatio: .landscape169, quality: .automatic)), CanvasSize(width: 1920, height: 1080))
        XCTAssertEqual(CanvasGeometry.size(for: CanvasSettings(aspectRatio: .landscape169, quality: .p4k)), CanvasSize(width: 3840, height: 2160))
        XCTAssertTrue(ExportQuality.automatic.requiresPro)
        XCTAssertTrue(ExportQuality.p4k.requiresPro)
        XCTAssertFalse(ExportQuality.p480.requiresPro)
        XCTAssertFalse(ExportQuality.p1080.requiresPro)
    }

    func testLegacyCanvasDecodingGetsDefaultLivesWatermark() throws {
        let data = #"{"aspectRatio":"9:16","quality":"720p"}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(CanvasSettings.self, from: data)
        XCTAssertEqual(settings.quality, .p720)
        XCTAssertEqual(settings.watermark.mode, .lives)
        XCTAssertEqual(settings.watermark.text, "lives")
    }

    func testPairedPathWithoutKindDecodesAsLivePhoto() throws {
        let id = UUID().uuidString
        let data = """
        {
          "id": "\(id)",
          "displayName": "IMG_0001.HEIC",
          "relativePath": "media/\(id).photo.heic",
          "durationMs": 1800,
          "width": 3024,
          "height": 4032,
          "codec": "heic",
          "pairedRelativePath": "media/\(id).motion.mov",
          "hasAudio": true,
          "motionWidth": 1920,
          "motionHeight": 1080
        }
        """.data(using: .utf8)!
        let asset = try JSONDecoder().decode(SourceAsset.self, from: data)
        XCTAssertEqual(asset.kind, .livePhoto)
        XCTAssertEqual(asset.pairedRelativePath, "media/\(id).motion.mov")
    }

    func testAllEightTemplatesHaveStableSlots() {
        XCTAssertEqual(TemplateCatalog.all.count, 8)
        XCTAssertEqual(TemplateCatalog.definition(for: .heroLeft).requiredAssetCount, 3)
        XCTAssertEqual(TemplateCatalog.definition(for: .weighted3).slots.map(\.id), ["large", "medium", "small"])
    }

    func testPlacementKeyframeIsQuantizedAndClamped() {
        let asset = SourceAsset(displayName: "clip.mov", relativePath: "media/clip.mov", durationMs: 4_000, width: 1080, height: 1920, codec: "hvc1")
        let placement = Placement(sourceAssetID: asset.id, slotID: "full", startTimeMs: 500, coverTimeMs: 2_999)
        let project = ProjectDocument(assets: [asset], placements: [placement])
        XCTAssertEqual(project.placements[0].coverTimeMs, 2_900)
        XCTAssertNoThrow(try ProjectValidation.validate(project))
    }

    func testRejectsShortSourcesAndWrongPlacementCount() {
        let asset = SourceAsset(displayName: "short.mp4", relativePath: "media/short.mp4", durationMs: 2_000, width: 720, height: 1280, codec: "avc1")
        let project = ProjectDocument(assets: [asset], placements: [Placement(sourceAssetID: asset.id, slotID: "full")])
        XCTAssertThrowsError(try ProjectValidation.validate(project)) { error in
            XCTAssertEqual(error as? LivesCoreError, .sourceTooShort)
        }
    }

    func testRejectsDuplicateTemplateSlots() {
        let first = SourceAsset(displayName: "a.mov", relativePath: "a.mov", durationMs: 4_000, width: 1080, height: 1920, codec: "avc1")
        let second = SourceAsset(displayName: "b.mov", relativePath: "b.mov", durationMs: 4_000, width: 1080, height: 1920, codec: "avc1")
        let project = ProjectDocument(
            templateID: .stack2,
            assets: [first, second],
            placements: [
                Placement(sourceAssetID: first.id, slotID: "top"),
                Placement(sourceAssetID: second.id, slotID: "top"),
            ]
        )
        XCTAssertThrowsError(try ProjectValidation.validate(project))
    }
}
