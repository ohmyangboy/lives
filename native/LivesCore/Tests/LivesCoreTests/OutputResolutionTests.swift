import XCTest
@testable import LivesCore

final class OutputResolutionTests: XCTestCase {
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
        XCTAssertEqual(OutputResolution.automatic(for: project(width: 1280, height: 720), pro: true), CanvasSize(width: 1280, height: 720))
        XCTAssertEqual(OutputResolution.automatic(for: project(width: 3840, height: 2160, scale: 2), pro: true), CanvasSize(width: 1920, height: 1080))
    }

    func testUsesSlotSizeAndWeakestPlacedSourceNotUnusedMaterials() {
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
        XCTAssertEqual(OutputResolution.automatic(for: source, pro: true), CanvasSize(width: 404, height: 720))
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
