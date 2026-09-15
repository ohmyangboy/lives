import AVFoundation
import CoreImage
import CryptoKit
import ImageIO
import XCTest
@testable import LivesCore

final class WallpaperExportTests: XCTestCase {
    func testLegacyPurposeAndRoundTrip() throws {
        let request = RenderRequest(project: ProjectDocument(), purpose: .lockScreenWallpaper)
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(RenderRequest.self, from: data).purpose, .lockScreenWallpaper)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "purpose")
        XCTAssertEqual(try JSONDecoder().decode(RenderRequest.self, from: JSONSerialization.data(withJSONObject: object)).purpose, .livePhoto)
    }
    func testFixedScheduleAndGeometry() {
        let ticks = WallpaperExportProfile.frameTicks
        XCTAssertEqual(ticks.count, 60)
        XCTAssertEqual(ticks.prefix(4), [0, 10, 20, 30])
        XCTAssertEqual(ticks.suffix(4), [560, 570, 580, 590])
        XCTAssertEqual(WallpaperExportProfile.frameDurations.last, 10)
        XCTAssertEqual(WallpaperExportProfile.frameDurations.reduce(0, +), WallpaperExportProfile.durationTicks)
        XCTAssertTrue(ticks.contains(WallpaperExportProfile.coverTick))
        XCTAssertEqual(WallpaperExportProfile.frameRate, 60, "1 秒输出固定 60 帧，对应锁屏 Live 壁纸的 60 帧经验值")
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920), CGSize(width: 100, height: 100)] {
            let rect = WallpaperExportProfile.contentRect(for: size)
            XCTAssertTrue(WallpaperExportProfile.visibleRect.contains(rect))
            XCTAssertEqual(rect.width / rect.height, size.width / size.height, accuracy: 0.00001)
            XCTAssertEqual(rect.midX, 720); XCTAssertEqual(rect.midY, 960)
        }
    }
    func testWallpaperFillsThreeByFourWithoutInset() {
        XCTAssertEqual(WallpaperExportProfile.contentRect(for: CGSize(width: 300, height: 400)),
                       CGRect(x: 0, y: 0, width: 1440, height: 1920))
    }

    func testSelectedKeyFrameMapsToSharedMarker() {
        let scale = Int64(WallpaperExportProfile.timescale)
        let editTicks = Int64(WallpaperExportProfile.editDurationMs) * scale / 1000
        let uniformCoverTick = WallpaperMotionCurve.uniform.sourceTicks(atOutputTicks: WallpaperExportProfile.coverTick,
                                                                       editTicks: editTicks)
        for selected in [0, 200, 1500, 2600] {
            let offset = WallpaperExportProfile.sourceOffsetTicks(startTimeMs: 400, coverTimeMs: selected,
                durationMs: 4000, curve: .uniform)
            XCTAssertEqual(offset + uniformCoverTick, Int64(400 + selected) * scale / 1000)
        }
        XCTAssertEqual(WallpaperExportProfile.sourceOffsetTicks(startTimeMs: 900, coverTimeMs: 1500, durationMs: 1000,
            curve: .uniform) + uniformCoverTick, 579)
        // 四档共用的语义：用户选定的封面时刻最终落在输出时间轴的同一点，
        // 各档只改变该点在选段内的取样位置。
        for curve in WallpaperMotionCurve.allCases {
            let offset = WallpaperExportProfile.sourceOffsetTicks(startTimeMs: 1000, coverTimeMs: 1200,
                durationMs: 4000, curve: curve)
            let windowTick = curve.sourceTicks(atOutputTicks: WallpaperExportProfile.coverTick, editTicks: editTicks)
            XCTAssertEqual(offset + windowTick, Int64(2200) * scale / 1000)
        }
    }

    func testMotionCurveIsMonotonicAndEndpointLocked() {
        for curve in WallpaperMotionCurve.allCases {
            XCTAssertEqual(curve.progress(0), 0, accuracy: 0.0000001)
            XCTAssertEqual(curve.progress(1), 1, accuracy: 0.0000001)
            var previous = -1.0
            for step in 0...1_000 {
                let value = curve.progress(Double(step) / 1_000)
                XCTAssertGreaterThan(value, previous, "\(curve) 必须在 [0, 1] 上严格单调递增")
                previous = value
            }
        }
    }

    func testMotionCurveKeepsEveryOutputFrameNonEmpty() {
        let editTicks = Int64(WallpaperExportProfile.editDurationMs) * Int64(WallpaperExportProfile.timescale) / 1000
        for curve in WallpaperMotionCurve.allCases {
            let samples = WallpaperExportProfile.frameTicks + [WallpaperExportProfile.durationTicks]
            let ticks = samples.map { curve.sourceTicks(atOutputTicks: $0, editTicks: editTicks) }
            XCTAssertEqual(ticks.first, 0)
            XCTAssertEqual(ticks.last, editTicks, "\(curve) 必须仍然走完整个选段，不能压缩掉内容")
            for (from, to) in zip(ticks, ticks.dropFirst()) {
                XCTAssertGreaterThan(to - from, 0, "\(curve) 每帧的取样区间必须为正，否则会产生零长度片段")
            }
        }
    }

    func testMotionCurveHandComputedAnchors() {
        let editTicks: Int64 = 1200
        // 中点：匀速与缓入缓出都落在选段正中，缓入偏后、缓出偏前。
        XCTAssertEqual(WallpaperMotionCurve.uniform.sourceTicks(atOutputTicks: 300, editTicks: editTicks), 600)
        XCTAssertEqual(WallpaperMotionCurve.easeInOut.sourceTicks(atOutputTicks: 300, editTicks: editTicks), 600)
        XCTAssertEqual(WallpaperMotionCurve.easeIn.sourceTicks(atOutputTicks: 300, editTicks: editTicks), 345)
        XCTAssertEqual(WallpaperMotionCurve.easeOut.sourceTicks(atOutputTicks: 300, editTicks: editTicks), 855)
        // 四分之一处：缓出已经走过更多选段，缓入最少，对应“两头慢、中间快”。
        XCTAssertEqual(WallpaperMotionCurve.uniform.sourceTicks(atOutputTicks: 150, editTicks: editTicks), 300)
        XCTAssertEqual(WallpaperMotionCurve.easeInOut.sourceTicks(atOutputTicks: 150, editTicks: editTicks), 204)
        XCTAssertEqual(WallpaperMotionCurve.easeIn.sourceTicks(atOutputTicks: 150, editTicks: editTicks), 109)
        XCTAssertEqual(WallpaperMotionCurve.easeOut.sourceTicks(atOutputTicks: 150, editTicks: editTicks), 491)
    }

    func testMotionCurvePersistsWithDraftsAndDefaultsToUniform() throws {
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ProjectDocument())) as? [String: Any])
        legacy.removeValue(forKey: "motionCurve")
        let decoded = try JSONDecoder().decode(ProjectDocument.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.motionCurve, .uniform, "旧草稿必须保持原本的匀速时间安排")
        var project = ProjectDocument()
        project.motionCurve = .easeInOut
        let data = try JSONEncoder().encode(project)
        XCTAssertEqual(try JSONDecoder().decode(ProjectDocument.self, from: data).motionCurve, .easeInOut)
    }

    func testWallpaperCompositionHonorsSelectedFramesAndExtendsBoundaries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("input.mov")
        try await makeVideo(url)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let source = try XCTUnwrap(tracks.first)
        let range = try await source.load(.timeRange)
        for selected in [200, 800] {
            let composition = AVMutableComposition()
            let target = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
            try LivesMediaEngine.insertWallpaperMotion(source, into: target, sourceRange: range,
                offsetTicks: WallpaperExportProfile.sourceOffsetTicks(startTimeMs: 0, coverTimeMs: selected,
                    durationMs: 1000, curve: .uniform))
            XCTAssertEqual(composition.duration.seconds, WallpaperExportProfile.outputDuration.seconds, accuracy: 0.00001)
            let marker = CMTime(value: WallpaperExportProfile.coverTick, timescale: WallpaperExportProfile.timescale)
            let segment = try XCTUnwrap(target.segments.first { CMTimeRangeContainsTime($0.timeMapping.target, time: marker) })
            let mapping = segment.timeMapping
            let sourceTime = CMTimeMapTimeFromRangeToRange(marker, fromRange: mapping.target, toRange: mapping.source)
            XCTAssertEqual(sourceTime.seconds, Double(selected) / 1000, accuracy: 0.00001)
        }
    }

    /// 曲线必须真实落到合成的时间映射上，而不只是算出一组数字。
    func testWallpaperCompositionRealizesEveryCurve() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("input.mov")
        try await makeVideo(url, frames: 150)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let source = try XCTUnwrap(tracks.first)
        let range = try await source.load(.timeRange)
        let scale = Int64(WallpaperExportProfile.timescale)
        let editTicks = Int64(WallpaperExportProfile.editDurationMs) * scale / 1000
        for curve in WallpaperMotionCurve.allCases {
            // 5 秒素材 + 2 秒起点：最慢的缓出档也落在选段内，前段不需要补边定格。
            let offset = WallpaperExportProfile.sourceOffsetTicks(startTimeMs: 2000, coverTimeMs: 0,
                durationMs: 5000, curve: curve)
            XCTAssertGreaterThanOrEqual(offset, 0, "\(curve) 在该起点不应插入前段定格")
            XCTAssertLessThanOrEqual(Int64(offset), Int64(WallpaperExportProfile.editDurationMs) * scale / 1000,
                                     "\(curve) 在该起点不应插入尾段定格")
            let composition = AVMutableComposition()
            let target = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
            try LivesMediaEngine.insertWallpaperMotion(source, into: target, sourceRange: range, offsetTicks: offset, curve: curve)
            XCTAssertEqual(composition.duration.seconds, WallpaperExportProfile.outputDuration.seconds, accuracy: 0.00001)
            XCTAssertEqual(composition.duration, WallpaperExportProfile.outputDuration)
            for tick in WallpaperExportProfile.frameTicks {
                let out = CMTime(value: tick, timescale: WallpaperExportProfile.timescale)
                let segment = try XCTUnwrap(target.segments.first { CMTimeRangeContainsTime($0.timeMapping.target, time: out) },
                                            "\(curve) 的输出 \(tick) tick 应落在某个片段内")
                let mapped = CMTimeMapTimeFromRangeToRange(out, fromRange: segment.timeMapping.target, toRange: segment.timeMapping.source)
                let expected = Double(offset + curve.sourceTicks(atOutputTicks: tick, editTicks: editTicks)) / Double(scale)
                XCTAssertEqual(mapped.seconds - range.start.seconds, expected, accuracy: 0.001,
                               "\(curve) 在输出 \(tick) tick 的取样位置不符")
            }
        }
    }

    func testWallpaperGeometryAndMetadataFollowSelectedScreenSize() throws {
        let settings = CanvasSettings(aspectRatio: .wallpaper, customRatio: CustomRatio(width: 1179, height: 2556))
        let geometry = WallpaperOutputGeometry(canvas: CanvasGeometry.size(for: settings))
        XCTAssertEqual(geometry.display, CanvasSize(width: 1178, height: 2556))
        XCTAssertEqual(geometry.encoded, CanvasSize(width: 2556, height: 1178))
        let fields = try WallpaperMOV.atoms(WallpaperMOV.coverSample(size: geometry.encoded), start: 0)
        XCTAssertEqual(try WallpaperMOV.number(fields[2].data, 8), Int(Float(2556).bitPattern))
        XCTAssertEqual(try WallpaperMOV.number(fields[2].data, 12), Int(Float(1178).bitPattern))
        XCTAssertNotNil(try WallpaperMOV.infoDescription(size: geometry.encoded)
            .range(of: WallpaperMOV.box("dims", WallpaperMOV.be(2556) + WallpaperMOV.be(1178))))
    }

    func testAuthoredRecordAndCoverLayout() throws {
        let record = WallpaperMOV.infoSample(tick: 860)
        XCTAssertEqual(record.count, 144)
        XCTAssertEqual(Array(record[50..<52]), [9, 0]) // G04 clears bit 3 and fails on device.
        XCTAssertEqual(Array(record[32..<40]), Array(repeating: 0, count: 8))
        XCTAssertEqual(Array(record[72..<74]), [7, 0])
        XCTAssertEqual(Array(record[112..<120]), [85, 184, 9, 145, 0, 0, 0, 0])
        let cover = WallpaperMOV.coverSample()
        XCTAssertEqual(try WallpaperMOV.atoms(cover, start: 0).map(\.data.count), [9, 80, 16])
        XCTAssertNotNil(try WallpaperMOV.infoDescription().range(of: Data("cfgv".utf8)))
        XCTAssertThrowsError(try WallpaperMOV.atoms(Data([0, 0, 0, 9, 0, 0, 0, 0]), start: 0))
    }
    func testMatchesIndependentPythonGenerator() throws {
        // SHA-256 来自 G08–G11 的自主字段生成器；没有原片二进制 fixture。
        // 45 帧 / 1.5 秒升级到 60 帧 / 1 秒后，三个与时间轴长短和封面锚点相关的
        // 聚合值不再是外部生成器的产物，降级为“载荷与轨道布局未被意外改动”的
        // 回归锚点；逐记录的字段语义由 testInfoRecordsFollowTheSixtyFrameTimeline
        // 按手算公式独立核对。
        func hash(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
        let records = WallpaperExportProfile.frameTicks.map { WallpaperMOV.infoSample(tick: $0) }
        XCTAssertEqual(records.count, 60)
        XCTAssertEqual(hash(records.reduce(Data(), +)), "85c1061693718d9f84b69e59bb45f9659c2e3ecd06dcf528079e5aa8a82baae0")
        XCTAssertEqual(hash(try WallpaperMOV.infoDescription()), "ce286659c53252e56a1fbeca82ebf8ab7647ddc7fbf9fbfbd04f2efa3e1d71ac")
        XCTAssertEqual(hash(WallpaperMOV.coverSample()), "6fe23630877809dbcf4e92c2f95a877813cc94dda5b76009269d4f18bc1247d2")
        XCTAssertEqual(hash(WallpaperMOV.coverDescription()), "95e48d8fcba2fc86cf482c5e150288e588fbeaf47c4f2c710ad0d83cd4d4bdbe")
        XCTAssertEqual(hash(try WallpaperMOV.metadataTrack(info: true, samples: records, offset: 1234)), "9d7e660f0dbfbb1038666a06b5928267b795bd926a47b67d181da4e8017f7e6c")
        XCTAssertEqual(hash(try WallpaperMOV.metadataTrack(info: false, samples: [WallpaperMOV.coverSample()], offset: 1234)), "e758ea7721aad238d3946dae805d67ef66f20ea5dd1505d9c0a177613e03df6d")
    }

    /// 逐记录核对 60 帧时间轴上的 ns 时间字段：手算 (600 + tick) × 10^9 / 600 的整数除法。
    func testInfoRecordsFollowTheSixtyFrameTimeline() throws {
        func littleEndian(_ sample: Data, at offset: Int) -> UInt64 {
            (0..<8).reduce(UInt64(0)) { $0 | UInt64(sample[offset + $1]) << (8 * $1) }
        }
        let ticks = WallpaperExportProfile.frameTicks
        XCTAssertEqual(ticks.count, 60)
        let first = WallpaperMOV.infoSample(tick: try XCTUnwrap(ticks.first))
        XCTAssertEqual(littleEndian(first, at: 112), 1_000_000_000)
        XCTAssertEqual(littleEndian(first, at: 120), 1_000_000_000)
        let last = WallpaperMOV.infoSample(tick: try XCTUnwrap(ticks.last))
        XCTAssertEqual(littleEndian(last, at: 112), 1_983_333_333)
        XCTAssertEqual(littleEndian(last, at: 120), 1_983_333_333)
        XCTAssertEqual(Array(last[50..<52]), [9, 0])
    }

    func testRenderFixedWallpaperAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wallpaper-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("input.mov")
        try await makeVideo(url)
        let asset = SourceAsset(displayName: "Synthetic", relativePath: url.path, durationMs: 1000, width: 64, height: 64, codec: "avc1")
        let project = ProjectDocument(templateID: .single, canvas: CanvasSettings(aspectRatio: .wallpaper, customRatio: CustomRatio(width: 1179, height: 2556), watermark: WatermarkSettings(mode: .none)),
            assets: [asset], placements: [Placement(sourceAssetID: asset.id, slotID: "full")])
        let request = RenderRequest(project: project, purpose: .lockScreenWallpaper)
        let sources: [UUID: ResolvedMediaSource] = [asset.id: .video(url)]
        let pair = try await LivesMediaEngine.render(request: request, resolvedSources: sources, outputDirectory: root.appendingPathComponent("output"))
        try await LivesMediaEngine.validate(pair, request: request)
        XCTAssertEqual(request.project, project)
        let movie = AVURLAsset(url: pair.videoURL)
        let reader = try AVAssetReader(asset: movie)
        let tracks = try await movie.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output); XCTAssertTrue(reader.startReading())
        var ticks: [Int64] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0, CMSampleBufferGetTotalSampleSize(sample) > 0 else { continue }
            ticks.append(CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), timescale: 600, method: .default).value) }
        XCTAssertEqual(ticks, WallpaperExportProfile.frameTicks)
        var damaged = try Data(contentsOf: pair.videoURL)
        let marker = try XCTUnwrap(damaged.range(of: WallpaperMOV.infoSample(tick: 0)))
        damaged[marker.lowerBound + 50] = 1
        XCTAssertThrowsError(try WallpaperMOV.validate(damaged, id: pair.contentIdentifier))
        let cancelled = RenderCancellation(); cancelled.cancel()
        do {
            _ = try await LivesMediaEngine.render(request: request, resolvedSources: sources, outputDirectory: root.appendingPathComponent("cancelled"), cancellation: cancelled)
            XCTFail("Cancellation must fail")
        } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cancelled/paired.mov").path)) }
    }
    func testPhotoOnlyRejectedAndOrdinaryCoverLimitUnchanged() async throws {
        let photo = SourceAsset(displayName: "Photo", relativePath: "photo.png", width: 64, height: 64, contentType: "png")
        let project = ProjectDocument(assets: [photo], placements: [Placement(sourceAssetID: photo.id, slotID: "full")])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            _ = try await LivesMediaEngine.render(request: RenderRequest(project: project, purpose: .lockScreenWallpaper), resolvedSources: [:], outputDirectory: root)
            XCTFail("Photo-only wallpaper must fail")
        } catch { XCTAssertEqual(error as? LivesCoreError, .renderFailed("请添加视频或实况素材")) }
        do {
            _ = try await LivesMediaEngine.render(request: RenderRequest(project: project, coverSize: WallpaperExportProfile.coverSize), resolvedSources: [:], outputDirectory: root)
            XCTFail("Ordinary output must keep its existing cover limit")
        } catch { XCTAssertEqual(error as? LivesCoreError, .renderFailed("封面尺寸超过安全输出上限")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testCancellationDuringWallpaperEncodingRemovesArtifacts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("input.mov")
        try await makeVideo(url)
        let asset = SourceAsset(displayName: "Synthetic", relativePath: url.path, durationMs: 1000, width: 64, height: 64, codec: "avc1")
        let project = ProjectDocument(assets: [asset], placements: [Placement(sourceAssetID: asset.id, slotID: "full")])
        let cancellation = RenderCancellation(), output = root.appendingPathComponent("output")
        do {
            _ = try await LivesMediaEngine.render(request: RenderRequest(project: project, purpose: .lockScreenWallpaper),
                resolvedSources: [asset.id: .video(url)], outputDirectory: output, cancellation: cancellation) { progress in
                    if progress.fraction > 0.4 { cancellation.cancel() }
                }
            XCTFail("Mid-encode cancellation must fail")
        } catch { XCTAssertTrue(cancellation.isCancelled) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
    }

    private func makeVideo(_ url: URL, frames: Int = 30) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let image = CIImage(color: CIColor(red: CGFloat(i) / CGFloat(frames), green: 0.2, blue: 0.7)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
            context.render(image, to: try XCTUnwrap(buffer))
            XCTAssertTrue(adaptor.append(try XCTUnwrap(buffer), withPresentationTime: CMTime(value: Int64(i), timescale: 30)))
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: 30)); input.markAsFinished(); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
