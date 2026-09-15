import XCTest
@testable import LivesCore

final class OutputResolutionTests: XCTestCase {
    func testCoverShortEdgeCapPreservesDetailAndAspectRatio() {
        let asset = SourceAsset(displayName: "photo", relativePath: "photo.jpg", width: 3024, height: 4032, contentType: "jpeg")
        var source = ProjectDocument(assets: [asset], placements: [Placement(sourceAssetID: asset.id, slotID: "full")])
        XCTAssertEqual(OutputResolution.cover(for: source, maximumShortEdge: 1080), CanvasSize(width: 1080, height: 1440))
        XCTAssertEqual(OutputResolution.cover(for: source), CanvasSize(width: 3024, height: 4032))
        for ratio in AspectRatioID.allCases {
            source.canvas.aspectRatio = ratio
            source.canvas.customRatio = CustomRatio(width: 1, height: 3)
            let original = OutputResolution.cover(for: source)
            let capped = OutputResolution.cover(for: source, maximumShortEdge: 1080)
            XCTAssertLessThanOrEqual(min(capped.width, capped.height), 1080)
            XCTAssertLessThanOrEqual(capped.width, original.width)
            XCTAssertLessThanOrEqual(capped.height, original.height)
        }
        source.canvas.aspectRatio = .portrait34
        source.assets[0].width = 600
        source.assets[0].height = 800
        XCTAssertEqual(OutputResolution.cover(for: source, maximumShortEdge: 1080), CanvasSize(width: 600, height: 800))
    }

    func testMixedLivePhotoCollageSeparatesAutomaticVideoAndPhotoDetail() {
        let high = SourceAsset(displayName: "high", photoRelativePath: "high.heic", pairedVideoRelativePath: "high.mov",
            durationMs: 3000, photoWidth: 3024, photoHeight: 4032, motionWidth: 1308, motionHeight: 1744,
            codec: "hvc1", hasAudio: false)
        let low = SourceAsset(displayName: "low", photoRelativePath: "low.jpg", pairedVideoRelativePath: "low.mov",
            durationMs: 3000, photoWidth: 980, photoHeight: 1308, motionWidth: 980, motionHeight: 1308,
            codec: "avc1", hasAudio: false)
        var source = ProjectDocument(templateID: .stack2, canvas: CanvasSettings(aspectRatio: .portrait34),
            assets: [high, low], placements: [
                Placement(sourceAssetID: high.id, slotID: "top", coverSource: .originalPhoto),
                Placement(sourceAssetID: low.id, slotID: "bottom", coverSource: .originalPhoto)])
        source.canvas.quality = .automatic
        XCTAssertEqual(OutputResolution.resolve(for: source, pro: true), CanvasSize(width: 1308, height: 1744))
        XCTAssertEqual(OutputResolution.cover(for: source), CanvasSize(width: 3024, height: 4032))
        source.canvas.quality = .p1080
        XCTAssertEqual(OutputResolution.resolve(for: source, pro: true), CanvasSize(width: 1080, height: 1440))
        XCTAssertEqual(OutputResolution.cover(for: source), CanvasSize(width: 3024, height: 4032))
    }

    func testWallpaperKeepsDevicePixelDimensionsAcrossQualityTiers() {
        for quality in ExportQuality.allCases {
            var source = project(width: 2556, height: 1179, ratio: .wallpaper)
            source.canvas.quality = quality
            source.canvas.customRatio = CustomRatio(width: 1179, height: 2556)
            XCTAssertEqual(
                OutputResolution.resolve(for: source, pro: false),
                CanvasSize(width: 1178, height: 2556)
            )
        }
    }

    private func project(width: Int, height: Int, ratio: AspectRatioID = .landscape169, scale: Double = 1) -> ProjectDocument {
        let asset = SourceAsset(displayName: "fixture", relativePath: "fixture.mov", durationMs: 3000,
                                width: width, height: height, codec: "hvc1")
        return ProjectDocument(canvas: CanvasSettings(aspectRatio: ratio), assets: [asset],
                               placements: [Placement(sourceAssetID: asset.id, slotID: "full", crop: CropPosition(scale: scale))])
    }

    func test4KIsCappedByEntitlementAndSourceDetail() {
        let source = project(width: 3840, height: 2160)
        XCTAssertEqual(OutputResolution.automatic(for: source, pro: false), CanvasSize(width: 1920, height: 1080))
        XCTAssertEqual(OutputResolution.automatic(for: source, pro: true), CanvasSize(width: 3840, height: 2160))
        XCTAssertEqual(OutputResolution.automatic(for: project(width: 1280, height: 720), pro: true), CanvasSize(width: 1920, height: 1080))
        XCTAssertEqual(OutputResolution.automatic(for: project(width: 3840, height: 2160, scale: 2), pro: true), CanvasSize(width: 1920, height: 1080))
    }

    func testUsesBestPlacedSourceNotUnusedMaterials() {
        var source = project(width: 1920, height: 1080, ratio: .portrait916)
        source.templateID = .stack2
        source.placements[0].slotID = "top"
        source.placements.append(Placement(sourceAssetID: source.assets[0].id, slotID: "bottom"))
        // Two 1080-high clips can fill a 2160-high collage without upscaling.
        XCTAssertEqual(OutputResolution.automatic(for: source, pro: true), CanvasSize(width: 1214, height: 2160))
        let low = SourceAsset(displayName: "low", relativePath: "low.mov", durationMs: 3000, width: 640, height: 360, codec: "avc1")
        source.assets.append(low)
        XCTAssertEqual(OutputResolution.automatic(for: source, pro: true), CanvasSize(width: 1214, height: 2160))
        source.placements[1].sourceAssetID = low.id
        XCTAssertEqual(OutputResolution.automatic(for: source, pro: true), CanvasSize(width: 1214, height: 2160))
    }

    func testExtremeRatiosAndAllTemplatesRespectPixelAndEncodingBounds() {
        for template in TemplateCatalog.all {
            for ratio in AspectRatioID.allCases {
                var source = project(width: 8000, height: 8000, ratio: ratio)
                source.canvas.customRatio = CustomRatio(width: 3, height: 1)
                source.templateID = template.id
                source.placements = template.slots.map { Placement(sourceAssetID: source.assets[0].id, slotID: $0.id) }
                for pro in [false, true] {
                    let output = OutputResolution.automatic(for: source, pro: pro)
                    XCTAssertLessThanOrEqual(max(output.width, output.height), pro ? 3840 : 1920)
                    XCTAssertLessThanOrEqual(min(output.width, output.height), pro ? 2160 : 1080)
                    XCTAssertTrue(output.width.isMultiple(of: 2) && output.height.isMultiple(of: 2))
                }
            }
        }
    }

    func testAutoSizePersistsInRequestAndLegacyDraftRemainsReadable() throws {
        let source = project(width: 3840, height: 2160)
        let request = RenderRequest(project: source, canvasSize: OutputResolution.automatic(for: source, pro: true))
        let restored = try JSONDecoder().decode(RenderRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(restored.canvasSize, CanvasSize(width: 3840, height: 2160))
        XCTAssertEqual(restored.audioPolicy, .perPlacement)
        XCTAssertEqual(RenderRequest(project: source).canvasSize, CanvasSize(width: 1920, height: 1080))

        let legacyJSON = try JSONSerialization.data(withJSONObject: [
            "project": try JSONSerialization.jsonObject(with: JSONEncoder().encode(source)),
            "canvasSize": ["width": 1920, "height": 1080]
        ])
        let legacy = try JSONDecoder().decode(RenderRequest.self, from: legacyJSON)
        XCTAssertEqual(legacy.audioPolicy, .perPlacement)

        let muted = RenderRequest(project: source, audioPolicy: .muted)
        let restoredMuted = try JSONDecoder().decode(RenderRequest.self, from: JSONEncoder().encode(muted))
        XCTAssertEqual(restoredMuted.audioPolicy, .muted)
    }
}
