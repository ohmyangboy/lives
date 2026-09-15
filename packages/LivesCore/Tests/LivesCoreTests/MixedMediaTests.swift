import AVFoundation
import CoreGraphics
import ImageIO
import XCTest
import UniformTypeIdentifiers
@testable import LivesCore

final class MixedMediaTests: XCTestCase {
    func testLowFrameRateMiddleSelectionKeepsRequestedDuration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LivesLowFPS-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = try await makeSolidVideo(at: root.appendingPathComponent("ten-fps.mov"),
            color: (24, 24, 230), frameCount: 120, frameRate: 10)
        let asset = SourceAsset(displayName: "10 fps", relativePath: "ten-fps.mov", durationMs: 12_000,
                                width: 8, height: 8, codec: "avc1")
        let project = ProjectDocument(assets: [asset], placements: [
            Placement(sourceAssetID: asset.id, slotID: "full", startTimeMs: 6800, audioEnabled: false)
        ], outputDurationMs: 3000)
        let pair = try await LivesMediaEngine.render(request: RenderRequest(project: project,
            canvasSize: CanvasSize(width: 160, height: 160), dynamicRange: .sdr),
            resolvedURLs: [asset.id: sourceURL], outputDirectory: root.appendingPathComponent("output"))
        let duration = try await AVURLAsset(url: pair.videoURL).load(.duration)
        XCTAssertEqual(duration.seconds, 3, accuracy: 0.001)
    }

    func testPhotoOnlyProjectRendersAValidThreeSecondPair() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LivesCorePhotoOnly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let photoURL = root.appendingPathComponent("photo.png")
        guard let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(
            photoURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            XCTFail("无法创建测试照片")
            return
        }
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        // Recreate the image after filling the context so the test does not
        // depend on a stale bitmap snapshot.
        guard let filled = context.makeImage() else { XCTFail(); return }
        CGImageDestinationAddImage(destination, filled, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        _ = image

        let asset = SourceAsset(
            displayName: "静态照片",
            relativePath: "photo.png",
            width: 8,
            height: 8,
            contentType: "png"
        )
        let project = ProjectDocument(
            canvas: CanvasSettings(aspectRatio: .square, quality: .p480),
            assets: [asset],
            placements: [Placement(sourceAssetID: asset.id, slotID: "full")]
        )
        let pair = try await LivesMediaEngine.render(
            request: RenderRequest(project: project, canvasSize: CanvasSize(width: 64, height: 64)),
            resolvedSources: [asset.id: .photo(photoURL)],
            outputDirectory: root.appendingPathComponent("output", isDirectory: true)
        )
        try await LivesMediaEngine.validate(pair: pair)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pair.photoURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pair.videoURL.path))
    }

    func testLivePhotoAssetRequiresPairedPathAndUsesMotionDimensions() throws {
        let asset = SourceAsset(
            displayName: "live",
            photoRelativePath: "still.heic",
            pairedVideoRelativePath: "motion.mov",
            durationMs: 3_000,
            photoWidth: 3_024,
            photoHeight: 4_032,
            motionWidth: 1_920,
            motionHeight: 1_080,
            codec: "avc1",
            hasAudio: true
        )
        XCTAssertEqual(asset.kind, .livePhoto)
        XCTAssertEqual(asset.motionWidth, 1_920)
        XCTAssertNoThrow(try ProjectValidation.validate(ProjectDocument(
            templateID: .single,
            assets: [asset],
            placements: [Placement(sourceAssetID: asset.id, slotID: "full")]
        )))
    }

    func testPhotoAndVideoCanRenderTogetherInOneCollage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LivesCoreMixed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let photoURL = try makeSolidPhoto(at: root.appendingPathComponent("photo.png"), color: (0.1, 0.7, 0.2))
        let videoURL = try await makeSolidVideo(at: root.appendingPathComponent("motion.mov"), color: (26, 51, 204))
        let photo = SourceAsset(displayName: "photo", relativePath: "photo.png", width: 8, height: 8, contentType: "png")
        let motionInfo = try await LivesMediaEngine.inspect(url: videoURL)
        let video = SourceAsset(
            displayName: "video",
            relativePath: "motion.mov",
            durationMs: motionInfo.durationMs,
            width: motionInfo.width,
            height: motionInfo.height,
            codec: motionInfo.codec,
            hasAudio: false,
            motionWidth: motionInfo.width,
            motionHeight: motionInfo.height
        )
        let project = ProjectDocument(
            templateID: .stack2,
            canvas: CanvasSettings(aspectRatio: .landscape43, quality: .p480),
            assets: [photo, video],
            placements: [
                Placement(sourceAssetID: photo.id, slotID: "top"),
                Placement(sourceAssetID: video.id, slotID: "bottom")
            ]
        )
        let pair = try await LivesMediaEngine.render(
            request: RenderRequest(project: project, canvasSize: CanvasSize(width: 64, height: 48)),
            resolvedSources: [photo.id: .photo(photoURL), video.id: .video(videoURL)],
            outputDirectory: root.appendingPathComponent("output", isDirectory: true)
        )
        try await LivesMediaEngine.validate(pair: pair)
        let outputInfo = try await LivesMediaEngine.inspect(url: pair.videoURL)
        XCTAssertEqual(outputInfo.width, 64)
        XCTAssertEqual(outputInfo.height, 48)
    }

    func testShortLivePhotoCanInspectAndRenderWithPadding() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LivesCoreShortLive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let photoURL = try makeSolidPhoto(at: root.appendingPathComponent("still.png"), color: (0.9, 0.2, 0.3))
        // 54 frames at 30fps = 1.8 seconds (typical real-world Live Photo duration)
        let videoURL = try await makeSolidVideo(at: root.appendingPathComponent("motion.mov"), color: (12, 180, 50), frameCount: 54)

        let motionInfo = try await LivesMediaEngine.inspect(source: .livePhoto(photoURL: photoURL, pairedVideoURL: videoURL))
        XCTAssertEqual(motionInfo.durationMs, 1800)
        XCTAssertGreaterThan(motionInfo.durationMs, 0)
        XCTAssertLessThan(motionInfo.durationMs, ProjectValidation.outputDurationMs)

        let liveAsset = SourceAsset(
            displayName: "short-live",
            photoRelativePath: "still.png",
            pairedVideoRelativePath: "motion.mov",
            durationMs: motionInfo.durationMs,
            photoWidth: 8,
            photoHeight: 8,
            motionWidth: motionInfo.width,
            motionHeight: motionInfo.height,
            codec: motionInfo.codec,
            hasAudio: false
        )
        let project = ProjectDocument(
            templateID: .single,
            canvas: CanvasSettings(aspectRatio: .square, quality: .p480),
            assets: [liveAsset],
            placements: [Placement(sourceAssetID: liveAsset.id, slotID: "full")]
        )
        XCTAssertNoThrow(try ProjectValidation.validate(project))

        let pair = try await LivesMediaEngine.render(
            request: RenderRequest(project: project, canvasSize: CanvasSize(width: 64, height: 64)),
            resolvedSources: [liveAsset.id: .livePhoto(photoURL: photoURL, pairedVideoURL: videoURL)],
            outputDirectory: root.appendingPathComponent("output", isDirectory: true)
        )
        try await LivesMediaEngine.validate(pair: pair)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pair.photoURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pair.videoURL.path))

        let outputInfo = try await LivesMediaEngine.inspect(url: pair.videoURL)
        XCTAssertEqual(outputInfo.durationMs, 3000)
    }

    func testLivePhotoRenderKeepsPairedMotionFrames() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LivesCoreMotionLive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let photoURL = try makeSolidPhoto(at: root.appendingPathComponent("still.png"), color: (0.2, 0.2, 0.2))
        let motionURL = try await makeColorChangingVideo(at: root.appendingPathComponent("motion.mov"))
        let liveAsset = SourceAsset(
            displayName: "motion-live",
            photoRelativePath: "still.png",
            pairedVideoRelativePath: "motion.mov",
            durationMs: 3_000,
            photoWidth: 8,
            photoHeight: 8,
            motionWidth: 8,
            motionHeight: 8,
            codec: "avc1",
            hasAudio: false
        )
        let project = ProjectDocument(
            templateID: .single,
            canvas: CanvasSettings(aspectRatio: .square, quality: .p480),
            assets: [liveAsset],
            placements: [Placement(sourceAssetID: liveAsset.id, slotID: "full", coverTimeMs: 1500)]
        )
        let pair = try await LivesMediaEngine.render(
            request: RenderRequest(project: project, canvasSize: CanvasSize(width: 64, height: 64)),
            resolvedSources: [liveAsset.id: .livePhoto(photoURL: photoURL, pairedVideoURL: motionURL)],
            outputDirectory: root.appendingPathComponent("output", isDirectory: true)
        )

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: pair.videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let first = try generator.copyCGImage(at: CMTime(value: 12, timescale: 30), actualTime: nil)
        let last = try generator.copyCGImage(at: CMTime(value: 78, timescale: 30), actualTime: nil)
        let firstPixel = centerPixel(first)
        let lastPixel = centerPixel(last)
        XCTAssertGreaterThan(
            abs(Int(firstPixel.0) - Int(lastPixel.0))
                + abs(Int(firstPixel.1) - Int(lastPixel.1))
                + abs(Int(firstPixel.2) - Int(lastPixel.2)),
            80,
            "Live Photo 的配对视频必须让输出画面随时间变化"
        )
    }

    func testVariableDurationSingleMixedAndPhotoOnlyExportsKeepFinalFrames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LivesDuration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photoURL = try makeSolidPhoto(at: root.appendingPathComponent("still.png"), color: (0.2, 0.8, 0.3))
        let videoURL = try await makeSolidVideo(at: root.appendingPathComponent("short.mov"), color: (24, 24, 230), frameCount: 30)
        let info = try await LivesMediaEngine.inspect(url: videoURL)
        XCTAssertEqual(info.durationMs, 1000)
        let photo = SourceAsset(displayName: "照片", relativePath: "still.png", width: 8, height: 8, contentType: "png")
        let video = SourceAsset(displayName: "短片段", relativePath: "short.mov", durationMs: info.durationMs, width: 8, height: 8, codec: info.codec)
        for duration in [1000, 2000, 3000, 3900] {
            for mode in 0..<3 {
                let template: TemplateID = mode == 1 ? .grid4 : .single
                let placements = TemplateCatalog.definition(for: template).slots.enumerated().map { index, slot in
                    Placement(sourceAssetID: (mode == 2 || (mode == 1 && index.isMultiple(of: 2))) ? photo.id : video.id,
                              slotID: slot.id, startTimeMs: mode == 1 ? 500 : 0)
                }
                var project = ProjectDocument(templateID: template, assets: [photo, video], placements: placements, outputDurationMs: duration)
                project.canvas.watermark.mode = .none
                let pair = try await LivesMediaEngine.render(
                    request: RenderRequest(project: project, canvasSize: CanvasSize(width: 64, height: 64)),
                    resolvedSources: [photo.id: .photo(photoURL), video.id: .video(videoURL)],
                    outputDirectory: root.appendingPathComponent("\(duration)-\(mode)"))
                try await LivesMediaEngine.validate(pair: pair, expectedDurationMs: duration)
                let movie = AVURLAsset(url: pair.videoURL)
                let actual = try await movie.load(.duration)
                XCTAssertEqual(actual.seconds, Double(duration) / 1000, accuracy: 1.0 / 30)
                let generator = AVAssetImageGenerator(asset: movie)
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                let last = try generator.copyCGImage(at: CMTime(value: Int64(duration * 30 / 1000 - 1), timescale: 30), actualTime: nil)
                // 分别检查每格，避免中心像素恰好落在分割线上。
                for slot in TemplateCatalog.definition(for: template).slots {
                    let rect = CGRect(x: slot.x * 64, y: slot.y * 64, width: slot.width * 64, height: slot.height * 64)
                    let cropped = try XCTUnwrap(last.cropping(to: rect))
                    let pixel = centerPixel(cropped)
                    XCTAssertGreaterThan(max(pixel.0, pixel.1, pixel.2), 120, "末帧不能变黑，时长 \(duration)，模式 \(mode)")
                }
                if duration != 3000 {
                    do {
                        try await LivesMediaEngine.validate(pair: pair)
                        XCTFail("默认 3 秒校验必须拒绝其他时长")
                    } catch { }
                }
            }
        }
    }

    func testNativeDurationBoundsRespect3Point9SecondExportLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LivesNativeBounds-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photoURL = try makeSolidPhoto(at: root.appendingPathComponent("still.png"), color: (0.2, 0.3, 0.8))
        for (duration, start) in [(800, 0), (3900, 0)] {
            let motionURL = try await makeSolidVideo(at: root.appendingPathComponent("source-\(duration)-\(start).mov"),
                color: (24, 24, 230), frameCount: duration * 30 / 1000)
            let source = SourceAsset(displayName: "原生时长", photoRelativePath: "still.png", pairedVideoRelativePath: motionURL.lastPathComponent,
                durationMs: duration, photoWidth: 8, photoHeight: 8, motionWidth: 8, motionHeight: 8, codec: "avc1", hasAudio: false)
            var project = ProjectDocument(assets: [source], placements: [
                Placement(sourceAssetID: source.id, slotID: "full", startTimeMs: start, coverTimeMs: duration - 100)
            ], outputDurationMs: duration)
            project.canvas.watermark.mode = .none
            XCTAssertTrue(ProjectTimeline.canExport(durationMs: duration, pro: true, bounds: ProjectTimeline.durationBounds(for: project)))
            let pair = try await LivesMediaEngine.render(
                request: RenderRequest(project: project, canvasSize: CanvasSize(width: 64, height: 64)),
                resolvedSources: [source.id: .livePhoto(photoURL: photoURL, pairedVideoURL: motionURL)],
                outputDirectory: root.appendingPathComponent("output-\(duration)-\(start)"))
            try await LivesMediaEngine.validate(pair: pair, expectedDurationMs: duration)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: pair.videoURL))
            let last = try generator.copyCGImage(at: CMTime(value: Int64(duration * 30 / 1000 - 1), timescale: 30), actualTime: nil)
            XCTAssertGreaterThan(centerPixel(last).2, 120, "原生时长的末帧不能变黑")
        }

        let tooLong = SourceAsset(displayName: "超长实况", photoRelativePath: "still.png",
            pairedVideoRelativePath: "motion.mov", durationMs: 4_000, photoWidth: 8,
            photoHeight: 8, motionWidth: 8, motionHeight: 8, codec: "avc1", hasAudio: false)
        let tooLongProject = ProjectDocument(assets: [tooLong], placements: [
            Placement(sourceAssetID: tooLong.id, slotID: "full")
        ], outputDurationMs: 4_000)
        XCTAssertFalse(ProjectTimeline.canExport(durationMs: 4_000, pro: true,
            bounds: ProjectTimeline.durationBounds(for: tooLongProject)))
        XCTAssertThrowsError(try ProjectValidation.validate(tooLongProject))
    }

    private func makeSolidPhoto(at url: URL, color: (CGFloat, CGFloat, CGFloat)) throws -> URL {
        guard let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw LivesCoreError.renderFailed("无法创建测试照片") }
        context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw LivesCoreError.renderFailed("无法写入测试照片")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw LivesCoreError.renderFailed("无法完成测试照片") }
        return url
    }

    private func makeSolidVideo(at url: URL, color: (UInt8, UInt8, UInt8), frameCount: Int = 90, frameRate: Int32 = 30) async throws -> URL {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 8,
            AVVideoHeightKey: 8
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw LivesCoreError.renderFailed("无法创建测试视频") }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 8,
            kCVPixelBufferHeightKey as String: 8
        ])
        guard let buffer = makePixelBuffer(color: color), writer.startWriting() else {
            throw writer.error ?? LivesCoreError.renderFailed("无法开始测试视频")
        }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: frameRate)) else {
                throw writer.error ?? LivesCoreError.renderFailed("无法写入测试视频")
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else {
            throw writer.error ?? LivesCoreError.renderFailed("测试视频生成失败")
        }
        return url
    }

    private func makeColorChangingVideo(at url: URL) async throws -> URL {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 8,
            AVVideoHeightKey: 8
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw LivesCoreError.renderFailed("无法创建动态测试视频") }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 8,
            kCVPixelBufferHeightKey as String: 8
        ])
        guard writer.startWriting() else {
            throw writer.error ?? LivesCoreError.renderFailed("无法开始动态测试视频")
        }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<90 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let color: (UInt8, UInt8, UInt8) = index < 45 ? (230, 24, 24) : (24, 24, 230)
            guard let buffer = makePixelBuffer(color: color),
                  adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30)) else {
                throw writer.error ?? LivesCoreError.renderFailed("无法写入动态测试视频")
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else {
            throw writer.error ?? LivesCoreError.renderFailed("动态测试视频生成失败")
        }
        return url
    }

    private func makePixelBuffer(color: (UInt8, UInt8, UInt8)) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 8, 8, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<8 {
            for x in 0..<8 {
                let offset = y * stride + x * 4
                base[offset] = color.2
                base[offset + 1] = color.1
                base[offset + 2] = color.0
                base[offset + 3] = 255
            }
        }
        return buffer
    }

    private func centerPixel(_ image: CGImage) -> (UInt8, UInt8, UInt8) {
        // 解码器可能返回 BGRA；统一为 RGBA 后再断言颜色。
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return }
            context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        }
        return (pixel[0], pixel[1], pixel[2])
    }
}
