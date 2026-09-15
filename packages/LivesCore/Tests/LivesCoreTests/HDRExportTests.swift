import VideoToolbox
import AVFoundation
import CoreImage
import ImageIO
import XCTest
@testable import LivesCore

final class HDRExportTests: XCTestCase {
    func testCoverPreservesPhotoDetailAndExplicitSource() throws {
        let asset = SourceAsset(displayName: "fixture", photoRelativePath: "photo.heic", pairedVideoRelativePath: "motion.mov",
            durationMs: 3000, photoWidth: 3024, photoHeight: 4032, motionWidth: 1440, motionHeight: 1744,
            codec: "hvc1", hasAudio: false)
        var project = ProjectDocument(assets: [asset], placements: [Placement(sourceAssetID: asset.id, slotID: "full", coverSource: .originalPhoto)])
        XCTAssertEqual(OutputResolution.cover(for: project), CanvasSize(width: 3024, height: 4032))
        XCTAssertEqual(OutputResolution.automatic(for: project, pro: true), CanvasSize(width: 1308, height: 1744))
        project.placements[0].coverSource = .videoFrame
        XCTAssertEqual(OutputResolution.cover(for: project), CanvasSize(width: 1308, height: 1744))
        project.placements[0].coverSource = .originalPhoto
        project.placements[0].crop.scale = 2
        XCTAssertEqual(OutputResolution.cover(for: project), CanvasSize(width: 1512, height: 2016))
        let request = RenderRequest(project: project, coverSize: OutputResolution.cover(for: project), dynamicRange: .preserveHDR)
        let restored = try JSONDecoder().decode(RenderRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(request, restored)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        json.removeValue(forKey: "coverSize"); json.removeValue(forKey: "dynamicRange")
        let legacy = try JSONDecoder().decode(RenderRequest.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.coverSize, legacy.canvasSize)
        XCTAssertEqual(legacy.dynamicRange, .sdr)
    }

    func testCoverBudgetUsesBestPlacedDetailAndCapsPixels() {
        let large = SourceAsset(displayName: "large", relativePath: "large.png", width: 8000, height: 8000, contentType: "png")
        let small = SourceAsset(displayName: "small", relativePath: "small.png", width: 64, height: 64, contentType: "png")
        for ratio in AspectRatioID.allCases where ratio != .wallpaper {
            let project = ProjectDocument(templateID: .stack2, canvas: CanvasSettings(aspectRatio: ratio), assets: [large, small], placements: [
                Placement(sourceAssetID: large.id, slotID: "top"), Placement(sourceAssetID: small.id, slotID: "bottom")])
            let size = OutputResolution.cover(for: project)
            XCTAssertLessThanOrEqual(size.width * size.height, 24_000_000)
            XCTAssertLessThanOrEqual(max(size.width, size.height), 8192)
            XCTAssertGreaterThan(size.width * size.height, 1_000_000)
        }
    }

    func testCameraLivePhotoFixturePreservesOriginalResolutionAndHDR() async throws {
        guard let photoPath = ProcessInfo.processInfo.environment["LIVES_HDR_PHOTO_FIXTURE"],
              let videoPath = ProcessInfo.processInfo.environment["LIVES_HDR_VIDEO_FIXTURE"] else { throw XCTSkip("未提供相机 Live Photo 素材") }
        let photoURL = URL(fileURLWithPath: photoPath), videoURL = URL(fileURLWithPath: videoPath)
        let info = try await LivesMediaEngine.inspect(source: .photo(photoURL))
        let motion = try await LivesMediaEngine.inspect(source: .livePhoto(photoURL: photoURL, pairedVideoURL: videoURL))
        XCTAssertEqual(info.width, 3024); XCTAssertEqual(info.height, 4032)
        let asset = SourceAsset(displayName: "camera", photoRelativePath: "p.heic", pairedVideoRelativePath: "v.mov", durationMs: motion.durationMs,
            photoWidth: info.width, photoHeight: info.height, motionWidth: motion.width, motionHeight: motion.height, codec: motion.codec, hasAudio: false)
        let project = ProjectDocument(assets: [asset], placements: [Placement(sourceAssetID: asset.id, slotID: "full", coverSource: .originalPhoto)])
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LIVES_HDR_OUTPUT"] ?? NSTemporaryDirectory()).appendingPathComponent("camera-\(UUID().uuidString)")
        let pair = try await LivesMediaEngine.render(request: RenderRequest(project: project, canvasSize: OutputResolution.automatic(for: project, pro: true),
            coverSize: OutputResolution.cover(for: project), dynamicRange: .preserveHDR), resolvedSources: [asset.id: .livePhoto(photoURL: photoURL, pairedVideoURL: videoURL)], outputDirectory: root)
        XCTAssertTrue(MediaColorPipeline.photoIsHDR(pair.photoURL))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(pair.photoURL as CFURL, nil)!, 0, nil) as? [String: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth as String] as? Int, 3024)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight as String] as? Int, 4032)
        print("相机样例：照片 \(info.width)x\(info.height)，动态源 \(motion.width)x\(motion.height)，输出 \(root.path)")
    }

    func testCancelledExportLeavesNoPair() async throws {
        let source = SourceAsset(displayName: "cancel", relativePath: "unused.mov", durationMs: 3000, width: 64, height: 64, codec: "avc1")
        let project = ProjectDocument(assets: [source], placements: [Placement(sourceAssetID: source.id, slotID: "full")])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Lives-cancel-\(UUID().uuidString)")
        let cancellation = RenderCancellation(); cancellation.cancel()
        do {
            _ = try await LivesMediaEngine.render(request: RenderRequest(project: project), resolvedURLs: [:], outputDirectory: root, cancellation: cancellation)
            XCTFail("取消必须停止导出")
        } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: root.path)) }
    }

    func testPQAndSDRCollagePreservesHighlightsAndReferenceWhite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Lives-PQ-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("pq.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020],
            AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel]
        ])
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        let pool = try XCTUnwrap(adaptor.pixelBufferPool)
        var optionalBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(optionalBuffer)
        let bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
        let bright = CIImage(color: CIColor(red: 3, green: 3, blue: 3, alpha: 1, colorSpace: MediaColorPipeline.workingSpace)!).cropped(to: bounds)
        MediaColorPipeline.context().render(bright, to: buffer, bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.itur_2100_PQ)!)
        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        XCTAssertEqual(writer.status, .completed)
        let pqIsHDR = try await MediaColorPipeline.videoIsHDR(url); XCTAssertTrue(pqIsHDR)
        let photoURL = root.appendingPathComponent("sdr.png")
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: bounds)
        try MediaColorPipeline.context().writePNGRepresentation(of: green, to: photoURL, format: .RGBA8, colorSpace: MediaColorPipeline.sdrSpace)
        let video = SourceAsset(displayName: "PQ", relativePath: "pq.mov", durationMs: 3000, width: 64, height: 64, codec: "hvc1")
        let photo = SourceAsset(displayName: "SDR", relativePath: "sdr.png", width: 64, height: 64, contentType: "png")
        var project = ProjectDocument(templateID: .side2, assets: [video, photo], placements: [
            Placement(sourceAssetID: video.id, slotID: "left", coverSource: .videoFrame),
            Placement(sourceAssetID: photo.id, slotID: "right", coverSource: .originalPhoto)])
        project.canvas.watermark.mode = .none
        let pair = try await LivesMediaEngine.render(request: RenderRequest(project: project, canvasSize: CanvasSize(width: 128, height: 64), dynamicRange: .preserveHDR),
            resolvedSources: [video.id: .video(url), photo.id: .photo(photoURL)], outputDirectory: root.appendingPathComponent("out"))
        let image = try MediaColorPipeline.photo(pair.photoURL, preserveHDR: true, maxPixel: 128)
        func pixel(x: Int) -> [Float] {
            var values = [Float](repeating: 0, count: 4)
            MediaColorPipeline.context().render(image, toBitmap: &values, rowBytes: 16, bounds: CGRect(x: x, y: 32, width: 1, height: 1), format: .RGBAf, colorSpace: MediaColorPipeline.workingSpace)
            return values
        }
        XCTAssertGreaterThan(pixel(x: 32)[0], 1.2)
        XCTAssertLessThanOrEqual(pixel(x: 96)[1], 1.1, "普通素材不能被一起抬亮")
        let frame = try await MediaColorPipeline.frame(pair.videoURL, timeMs: 1000, preserveHDR: true)
        var values = [Float](repeating: 0, count: 4)
        MediaColorPipeline.context().render(frame, toBitmap: &values, rowBytes: 16, bounds: CGRect(x: 32, y: 32, width: 1, height: 1), format: .RGBAf, colorSpace: MediaColorPipeline.workingSpace)
        XCTAssertGreaterThan(values[0], 1.2)
    }

    func testLegacyPlacementDoesNotChangeCover() throws {
        let placement = Placement(sourceAssetID: UUID(), slotID: "full", coverSource: .originalPhoto)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(placement)) as? [String: Any])
        json.removeValue(forKey: "coverSource")
        let decoded = try JSONDecoder().decode(Placement.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.coverSource, .legacy)
    }

    func testHDRPairContainsRealGainMapAndTenBitVideo() async throws {
        guard #available(iOS 18, macOS 15, *) else { throw XCTSkip("Adaptive HDR 编码需要 iOS 18/macOS 15") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Lives-HDR-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photoURL = root.appendingPathComponent("source.heic")
        let bounds = CGRect(x: 0, y: 0, width: 96, height: 128)
        let sdr = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: bounds)
        let highlight = CIImage(color: CIColor(red: 3, green: 3, blue: 3, alpha: 1, colorSpace: MediaColorPipeline.workingSpace)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 48, height: 64)).composited(over: sdr)
        try MediaColorPipeline.writeCover(highlight, sdrImage: sdr, hdr: true, to: photoURL, identifier: UUID().uuidString)
        XCTAssertTrue(MediaColorPipeline.photoIsHDR(photoURL))
        let photo = SourceAsset(displayName: "hdr", relativePath: "source.heic", width: 96, height: 128, contentType: "heic")
        var project = ProjectDocument(assets: [photo], placements: [Placement(sourceAssetID: photo.id, slotID: "full", coverSource: .originalPhoto)])
        project.canvas.watermark.mode = .none
        let pair = try await LivesMediaEngine.render(request: RenderRequest(project: project, canvasSize: CanvasSize(width: 48, height: 64), coverSize: CanvasSize(width: 96, height: 128), dynamicRange: .preserveHDR), resolvedSources: [photo.id: .photo(photoURL)], outputDirectory: root.appendingPathComponent("out"))
        try await LivesMediaEngine.validate(pair: pair)
        XCTAssertTrue(MediaColorPipeline.photoIsHDR(pair.photoURL))
        let videoHDR = try await MediaColorPipeline.videoIsHDR(pair.videoURL)
        XCTAssertTrue(videoHDR)
        let cover = try XCTUnwrap(CGImageSourceCreateWithURL(pair.photoURL as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(cover, 0, nil) as? [String: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 96)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, 128)
        let image = try MediaColorPipeline.photo(pair.photoURL, preserveHDR: true, maxPixel: 128)
        let pixel = image.cropped(to: CGRect(x: 10, y: 10, width: 1, height: 1))
        var rgba = [Float](repeating: 0, count: 4)
        MediaColorPipeline.context().render(pixel, toBitmap: &rgba, rowBytes: 16, bounds: pixel.extent, format: .RGBAf, colorSpace: MediaColorPipeline.workingSpace)
        XCTAssertGreaterThan(rgba[0], 1.2, "导出后高光不能被裁成 SDR")
        // 再把真实编码后的 HLG 视频作为源，覆盖视频转 Live 与 SDR 回退路径。
        let motion = SourceAsset(displayName: "HLG", relativePath: "out/paired.mov", durationMs: 3000, width: 48, height: 64, codec: "hvc1")
        var videoProject = ProjectDocument(assets: [motion], placements: [Placement(sourceAssetID: motion.id, slotID: "full", coverSource: .videoFrame)])
        videoProject.canvas.watermark.mode = .none
        let converted = try await LivesMediaEngine.render(request: RenderRequest(project: videoProject, canvasSize: CanvasSize(width: 48, height: 64), dynamicRange: .preserveHDR), resolvedSources: [motion.id: .video(pair.videoURL)], outputDirectory: root.appendingPathComponent("video-converted"))
        XCTAssertTrue(MediaColorPipeline.photoIsHDR(converted.photoURL))
        let convertedFrame = try await MediaColorPipeline.frame(converted.videoURL, timeMs: 1500, preserveHDR: true)
        var peak = [Float](repeating: 0, count: 4)
        let maximum = convertedFrame.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: convertedFrame.extent)])
        MediaColorPipeline.context().render(maximum, toBitmap: &peak, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: MediaColorPipeline.workingSpace)
        XCTAssertGreaterThan(peak[0], 1.2, "HDR 视频转 Live 不能压平高光")
        let convertedSDR = try await LivesMediaEngine.render(request: RenderRequest(project: videoProject, canvasSize: CanvasSize(width: 48, height: 64), dynamicRange: .sdr), resolvedSources: [motion.id: .video(pair.videoURL)], outputDirectory: root.appendingPathComponent("video-sdr"))
        XCTAssertFalse(MediaColorPipeline.photoIsHDR(convertedSDR.photoURL))
        let sdrPair = try await LivesMediaEngine.render(request: RenderRequest(project: project, canvasSize: CanvasSize(width: 48, height: 64), coverSize: CanvasSize(width: 96, height: 128), dynamicRange: .sdr), resolvedSources: [photo.id: .photo(photoURL)], outputDirectory: root.appendingPathComponent("sdr"))
        XCTAssertFalse(MediaColorPipeline.photoIsHDR(sdrPair.photoURL))
        let sdrVideoHDR = try await MediaColorPipeline.videoIsHDR(sdrPair.videoURL)
        XCTAssertFalse(sdrVideoHDR)
    }
}
