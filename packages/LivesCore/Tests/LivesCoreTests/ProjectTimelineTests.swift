import XCTest
@testable import LivesCore

final class ProjectTimelineTests: XCTestCase {
    private func project() -> ProjectDocument {
        let asset = SourceAsset(displayName: "片段", relativePath: "clip.mov", durationMs: 8000,
                                width: 640, height: 360, codec: "avc1")
        return ProjectDocument(templateID: .stack2, assets: [asset], placements: [
            Placement(sourceAssetID: asset.id, slotID: "top", startTimeMs: 2000, coverTimeMs: 1500),
            Placement(sourceAssetID: asset.id, slotID: "bottom", startTimeMs: 6000, coverTimeMs: 1500)
        ])
    }

    func testDefaultStartTimeCentersMovableSelectionWindow() {
        XCTAssertEqual(ProjectTimeline.defaultStartTimeMs(sourceDurationMs: 9000, outputDurationMs: 3000), 3000)
        XCTAssertEqual(ProjectTimeline.defaultStartTimeMs(sourceDurationMs: 10000, outputDurationMs: 3000), 3500)
        XCTAssertEqual(ProjectTimeline.defaultStartTimeMs(sourceDurationMs: 2500, outputDurationMs: 3000), 0)
    }

    func testLegacyDefaultStartIsCenteredOnlyOnce() throws {
        let asset = SourceAsset(displayName: "片段", relativePath: "clip.mov", durationMs: 9000,
                                width: 640, height: 360, codec: "avc1")
        var value = ProjectDocument(assets: [asset], placements: [
            Placement(sourceAssetID: asset.id, slotID: "full", segmentStartInitialized: false)
        ])

        XCTAssertTrue(ProjectTimeline.initializeDefaultStartTimes(&value))
        XCTAssertEqual(value.placements[0].startTimeMs, 3000)
        XCTAssertTrue(value.placements[0].segmentStartInitialized)

        value.placements[0].startTimeMs = 0
        XCTAssertFalse(ProjectTimeline.initializeDefaultStartTimes(&value))
        XCTAssertEqual(value.placements[0].startTimeMs, 0)
    }

    func testLeadingHandleKeepsEndAndAbsoluteCoverWithoutMovingOtherSlots() {
        var value = project()
        ProjectTimeline.adjust(&value, slotID: "top", edge: .leading, valueMs: 3000)
        XCTAssertEqual(value.outputDurationMs, 2000)
        XCTAssertEqual(value.placements[0].startTimeMs, 3000)
        XCTAssertEqual(value.placements[0].coverTimeMs, 500)
        XCTAssertEqual(value.placements[1].startTimeMs, 6000)
        XCTAssertEqual(value.placements[1].coverTimeMs, 1500)
        ProjectTimeline.adjust(&value, slotID: "top", edge: .leading, valueMs: 10000)
        XCTAssertEqual(value.outputDurationMs, 1000)
        XCTAssertEqual(value.placements[0].startTimeMs, 4000)
        XCTAssertEqual(value.placements[0].coverTimeMs, 0)
        XCTAssertEqual(value.placements[1].coverTimeMs, 900)
    }

    func testTrailingHandleChangesGlobalDurationAndClampsToOneAnd3Point9Seconds() {
        var value = project()
        for (end, duration) in [(2100.0, 1000), (7000.0, 3900), (20000.0, 3900), (5000.0, 3000)] {
            ProjectTimeline.adjust(&value, slotID: "top", edge: .trailing, valueMs: end)
            XCTAssertEqual(value.outputDurationMs, duration)
            XCTAssertEqual(value.placements.map(\.startTimeMs), [2000, 6000])
        }
    }

    func testTranslationPreservesDurationAndRelativeCoverUntilSourceBoundary() {
        var value = project()
        ProjectTimeline.adjust(&value, slotID: "top", edge: .move, valueMs: 4249)
        XCTAssertEqual(value.placements[0].startTimeMs, 4200)
        XCTAssertEqual(value.placements[0].coverTimeMs, 1500)
        XCTAssertEqual(value.outputDurationMs, 3000)
        ProjectTimeline.adjust(&value, slotID: "top", edge: .move, valueMs: 20000)
        XCTAssertEqual(value.placements[0].startTimeMs, 7900)
        XCTAssertEqual(value.placements[0].coverTimeMs, 0)
        XCTAssertEqual(value.outputDurationMs, 3000)
    }

    func testShortSourceKeepsStartAndPadsToGlobalDuration() {
        var value = project()
        ProjectTimeline.adjust(&value, slotID: "bottom", edge: .trailing, valueMs: 11000)
        XCTAssertEqual(value.outputDurationMs, 3900)
        XCTAssertEqual(value.placements[1].startTimeMs, 6000)
        XCTAssertEqual(ProjectValidation.contentDurationMs(sourceDurationMs: 8000, startTimeMs: 6000, outputDurationMs: 3900), 2000)
        XCTAssertEqual(ProjectValidation.paddingDurationMs(sourceDurationMs: 8000, startTimeMs: 6000, outputDurationMs: 3900), 1900)
    }

    func testDraftRoundTripAndLegacyDefault() throws {
        var value = project()
        value.outputDurationMs = 3900
        let encoded = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(ProjectDocument.self, from: encoded), value)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "outputDurationMs")
        XCTAssertEqual(try JSONDecoder().decode(ProjectDocument.self, from: JSONSerialization.data(withJSONObject: json)).outputDurationMs, 3000)
    }

    func testEveryValidDurationCanExportWithoutProAndDoesNotRewriteDraft() {
        let value = project()
        XCTAssertTrue(ProjectTimeline.canExport(durationMs: 3000, pro: false))
        for duration in [1000, 3900] {
            XCTAssertTrue(ProjectTimeline.canExport(durationMs: duration, pro: false))
            XCTAssertTrue(ProjectTimeline.canExport(durationMs: duration, pro: true))
        }
        for duration in [0, 999, 1050, 4000, 5100] {
            XCTAssertFalse(ProjectTimeline.canExport(durationMs: duration, pro: true))
        }
        XCTAssertEqual(value.outputDurationMs, 3000)
    }

    func testInvalidDragValuesLeaveProjectUntouched() {
        var value = project()
        let original = value
        for invalid in [Double.nan, .infinity, -.infinity] {
            ProjectTimeline.adjust(&value, slotID: "top", edge: .leading, valueMs: invalid)
            XCTAssertEqual(value, original)
        }
    }

    func testLegacyNonQuantizedStartKeepsFixedEndAndValidDuration() throws {
        var value = project()
        value.placements[0].startTimeMs = 1234
        ProjectTimeline.adjust(&value, slotID: "top", edge: .leading, valueMs: 1540)
        XCTAssertEqual(value.placements[0].startTimeMs + value.outputDurationMs, 4234)
        XCTAssertEqual(value.outputDurationMs % 100, 0)
        ProjectTimeline.adjust(&value, slotID: "top", edge: .trailing, valueMs: 4500)
        XCTAssertEqual(value.outputDurationMs % 100, 0)
        XCTAssertNoThrow(try ProjectValidation.validate(value))
    }

    func testDurationBoundsIgnorePhotosUnusedAssetsAndTrimStart() {
        let first = SourceAsset(displayName: "长视频", relativePath: "long.mov", durationMs: 8000, width: 640, height: 360, codec: "avc1")
        let short = SourceAsset(displayName: "短视频", relativePath: "short.mov", durationMs: 1734, width: 640, height: 360, codec: "avc1")
        let unused = SourceAsset(displayName: "未使用", relativePath: "unused.mov", durationMs: 1000, width: 640, height: 360, codec: "avc1")
        let photo = SourceAsset(displayName: "静态图", relativePath: "still.png", width: 8, height: 8, contentType: "png")
        var value = ProjectDocument(templateID: .stack3, assets: [first, short, unused, photo], placements: [
            Placement(sourceAssetID: first.id, slotID: "top", startTimeMs: 7000),
            Placement(sourceAssetID: short.id, slotID: "middle", startTimeMs: 1500),
            Placement(sourceAssetID: photo.id, slotID: "bottom")
        ])
        XCTAssertEqual(ProjectTimeline.durationBounds(for: value), 1800...3900)
        value.placements.removeAll { $0.sourceAssetID == short.id }
        XCTAssertEqual(ProjectTimeline.durationBounds(for: value), 3900...3900)
        value.placements.removeAll { $0.sourceAssetID == first.id }
        XCTAssertEqual(ProjectTimeline.durationBounds(for: value), 1000...3900)
    }

    func testBothHandlesRespectDynamicMinimumAndKeepFixedEndpoint() {
        var value = project()
        let bounds = 1800...3900
        ProjectTimeline.adjust(&value, slotID: "top", edge: .leading, valueMs: 4900, bounds: bounds)
        XCTAssertEqual(value.outputDurationMs, 1800)
        XCTAssertEqual(value.placements[0].startTimeMs, 3200)
        ProjectTimeline.adjust(&value, slotID: "top", edge: .trailing, valueMs: 3300, bounds: bounds)
        XCTAssertEqual(value.outputDurationMs, 1800)
        XCTAssertEqual(value.placements[0].startTimeMs, 3200)
    }

    func testLongSourceIsCappedAt3Point9Seconds() throws {
        var value = project()
        value.outputDurationMs = 3900
        let bounds = ProjectTimeline.durationBounds(for: value)
        XCTAssertEqual(bounds, 3900...3900)
        value.outputDurationMs = 4000
        XCTAssertFalse(ProjectTimeline.canExport(durationMs: 4000, pro: true, bounds: bounds))
        XCTAssertThrowsError(try ProjectValidation.validate(value))
        value.outputDurationMs = 3900
        for edge in [SegmentEdge.leading, .trailing] {
            ProjectTimeline.adjust(&value, slotID: "top", edge: edge, valueMs: 1000, bounds: bounds)
            XCTAssertEqual(value.outputDurationMs, 3900)
        }
        XCTAssertTrue(ProjectTimeline.canExport(durationMs: 3900, pro: true, bounds: bounds))
        XCTAssertFalse(ProjectTimeline.canExport(durationMs: 3000, pro: true, bounds: bounds))
        XCTAssertNoThrow(try ProjectValidation.validate(value))
    }

    func testShortNativeLivePhotoSetsSubsecondMinimum() {
        let live = SourceAsset(displayName: "短实况", photoRelativePath: "still.heic", pairedVideoRelativePath: "motion.mov",
            durationMs: 734, photoWidth: 8, photoHeight: 8, motionWidth: 8, motionHeight: 8, codec: "avc1", hasAudio: false)
        let value = ProjectDocument(assets: [live], placements: [Placement(sourceAssetID: live.id, slotID: "full")], outputDurationMs: 800)
        XCTAssertEqual(ProjectTimeline.durationBounds(for: value), 800...3900)
        XCTAssertNoThrow(try ProjectValidation.validate(value))
    }

    func testOneSecondSourcesAndCoverBounds() throws {
        let asset = SourceAsset(displayName: "短视频", relativePath: "clip.mov", durationMs: 1000,
                                width: 640, height: 360, codec: "avc1")
        let value = ProjectDocument(assets: [asset], placements: [Placement(sourceAssetID: asset.id, slotID: "full")], outputDurationMs: 1000)
        XCTAssertEqual(value.placements[0].coverTimeMs, 900)
        XCTAssertNoThrow(try ProjectValidation.validate(value))
        XCTAssertEqual(ProjectTimeline.maximumCoverMs(sourceDurationMs: 8000, startTimeMs: 0, outputDurationMs: 3900), 3800)
    }
}
