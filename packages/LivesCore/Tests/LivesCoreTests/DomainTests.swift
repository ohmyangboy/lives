import XCTest
@testable import LivesCore

final class DomainTests: XCTestCase {
    func testCanvasDimensionsMatchMacRules() {
        XCTAssertEqual(CanvasSettings().aspectRatio, .portrait34)
        XCTAssertEqual(CanvasGeometry.size(for: CanvasSettings(aspectRatio: .portrait34, quality: .p720)), CanvasSize(width: 720, height: 960))
        XCTAssertEqual(CanvasGeometry.size(for: CanvasSettings(aspectRatio: .portrait45, quality: .p1080)), CanvasSize(width: 1080, height: 1350))
        XCTAssertEqual(CanvasGeometry.size(for: CanvasSettings(aspectRatio: .landscape75, quality: .p1080)), CanvasSize(width: 1512, height: 1080))
        XCTAssertEqual(CanvasGeometry.size(for: CanvasSettings(aspectRatio: .landscape169, quality: .p1080)), CanvasSize(width: 1920, height: 1080))
        XCTAssertEqual(
            CanvasGeometry.size(for: CanvasSettings(
                aspectRatio: .wallpaper,
                quality: .p1080,
                customRatio: CustomRatio(width: 1179, height: 2556)
            )),
            CanvasSize(width: 1178, height: 2556)
        )
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

    func testAllNineTemplatesHaveStableSlots() {
        XCTAssertEqual(TemplateCatalog.all.count, 9)
        XCTAssertEqual(TemplateCatalog.all.last?.id, .grid4)
        XCTAssertEqual(TemplateCatalog.all.map(\.requiredAssetCount), TemplateCatalog.all.map(\.requiredAssetCount).sorted())
        XCTAssertEqual(TemplateCatalog.definition(for: .grid4).slots.map(\.id), ["top-left", "top-right", "bottom-left", "bottom-right"])
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
        let asset = SourceAsset(displayName: "short.mp4", relativePath: "media/short.mp4", durationMs: 900, width: 720, height: 1280, codec: "avc1")
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

    func testPlacementRotationAndDraftCompatibility() throws {
        let assetID = UUID()
        let p0 = Placement(sourceAssetID: assetID, slotID: "full", rotation: 0)
        XCTAssertEqual(p0.rotation, 0)
        XCTAssertFalse(p0.isTransposed)

        let p90 = Placement(sourceAssetID: assetID, slotID: "full", rotation: 90)
        XCTAssertEqual(p90.rotation, 90)
        XCTAssertTrue(p90.isTransposed)

        let p180 = Placement(sourceAssetID: assetID, slotID: "full", rotation: 180)
        XCTAssertEqual(p180.rotation, 180)
        XCTAssertFalse(p180.isTransposed)

        let p270 = Placement(sourceAssetID: assetID, slotID: "full", rotation: 270)
        XCTAssertEqual(p270.rotation, 270)
        XCTAssertTrue(p270.isTransposed)

        // 旋转尺寸换算
        let originalSize = CGSize(width: 1080, height: 1920)
        XCTAssertEqual(CropGeometry.orientedSourceSize(source: originalSize, rotation: 0), CGSize(width: 1080, height: 1920))
        XCTAssertEqual(CropGeometry.orientedSourceSize(source: originalSize, rotation: 90), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(CropGeometry.orientedSourceSize(source: originalSize, rotation: 180), CGSize(width: 1080, height: 1920))
        XCTAssertEqual(CropGeometry.orientedSourceSize(source: originalSize, rotation: 270), CGSize(width: 1920, height: 1080))

        // 旧草稿无 rotation 字段向后兼容解码
        let legacyJSON = """
        {
            "id": "\(UUID().uuidString)",
            "sourceAssetID": "\(assetID.uuidString)",
            "slotID": "full",
            "startTimeMs": 0,
            "crop": { "normalizedCenterX": 0.5, "normalizedCenterY": 0.5, "scale": 1.0 },
            "audioEnabled": false,
            "coverTimeMs": 1500,
            "coverSource": "legacy"
        }
        """.data(using: .utf8)!
        let decodedLegacy = try JSONDecoder().decode(Placement.self, from: legacyJSON)
        XCTAssertEqual(decodedLegacy.rotation, 0)
        XCTAssertFalse(decodedLegacy.isTransposed)
        XCTAssertTrue(decodedLegacy.segmentStartInitialized, "旧草稿无法区分默认起点和手选起点，必须保留")

        // 新草稿带 rotation 编码解码往返
        let encoded = try JSONEncoder().encode(p90)
        let decodedNew = try JSONDecoder().decode(Placement.self, from: encoded)
        XCTAssertEqual(decodedNew.rotation, 90)
        XCTAssertTrue(decodedNew.isTransposed)
        XCTAssertTrue(decodedNew.segmentStartInitialized)
    }
}
