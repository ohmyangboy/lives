import AVFoundation
import CoreGraphics
import CoreVideo
import XCTest
@testable import LivePhotoService

final class TemplateLayoutTests: XCTestCase {
    func testMediaLibraryFolderScanFindsSupportedVideosRecursively() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = root.appendingPathComponent("聚会", isDirectory: true)
        let hidden = root.appendingPathComponent(".cache", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data().write(to: root.appendingPathComponent("10.MOV"))
        try Data().write(to: nested.appendingPathComponent("2.mp4"))
        try Data().write(to: nested.appendingPathComponent("说明.txt"))
        try Data().write(to: hidden.appendingPathComponent("hidden.m4v"))

        let paths = try MediaLibraryScanner.scan(path: root.path)

        XCTAssertEqual(Set(paths.map { URL(fileURLWithPath: $0).lastPathComponent }), Set(["2.mp4", "10.MOV"]))
    }

    func testSupportedCanvasSizesCoverEveryEditorRatioAndQuality() {
        XCTAssertTrue(LivePhotoPipeline.supportsCanvas(width: 1080, height: 1920))
        XCTAssertTrue(LivePhotoPipeline.supportsCanvas(width: 1080, height: 1440))
        XCTAssertTrue(LivePhotoPipeline.supportsCanvas(width: 1080, height: 1080))
        XCTAssertTrue(LivePhotoPipeline.supportsCanvas(width: 720, height: 1280))
        XCTAssertTrue(LivePhotoPipeline.supportsCanvas(width: 720, height: 960))
        XCTAssertTrue(LivePhotoPipeline.supportsCanvas(width: 720, height: 720))
        XCTAssertTrue(LivePhotoPipeline.supportsCanvas(width: 1920, height: 1080))
        XCTAssertTrue(LivePhotoPipeline.supportsCanvas(width: 1440, height: 1080))
        XCTAssertTrue(LivePhotoPipeline.supportsCanvas(width: 1280, height: 720))
        XCTAssertTrue(LivePhotoPipeline.supportsCanvas(width: 960, height: 720))
        XCTAssertFalse(LivePhotoPipeline.supportsCanvas(width: 640, height: 480))
    }

    func testCoverContextRectPreservesTopToBottomImageOrientation() {
        let top = CGRect(x: 0, y: 0, width: 1080, height: 960)
        let bottom = LivePhotoPipeline.coverContextRect(for: top, canvasHeight: 1920)

        XCTAssertEqual(bottom, CGRect(x: 0, y: 960, width: 1080, height: 960))
    }

    func testBitRateAdaptsToOutputFrameSize() {
        XCTAssertEqual(VideoRenderer.adaptiveBitRate(width: 1080, height: 1920), 12_000_000)
        XCTAssertEqual(VideoRenderer.adaptiveBitRate(width: 720, height: 1280), 5_333_333)
        XCTAssertEqual(VideoRenderer.adaptiveBitRate(width: 720, height: 720), 4_000_000)
    }

    func testShortLivePhotoVideoUsesItsContentThenPadsTheRemainder() {
        let segment = MediaConstraints.segmentDurations(
            sourceDurationMilliseconds: 2_833,
            startTimeMilliseconds: 0
        )

        XCTAssertEqual(MediaConstraints.minimumSourceDurationMilliseconds, 2_500)
        XCTAssertEqual(segment.contentMilliseconds, 2_833)
        XCTAssertEqual(segment.paddingMilliseconds, 167)
    }

    func testLongVideoStillUsesAThreeSecondSelectionWithoutPadding() {
        let segment = MediaConstraints.segmentDurations(
            sourceDurationMilliseconds: 8_000,
            startTimeMilliseconds: 2_000
        )

        XCTAssertEqual(segment.contentMilliseconds, 3_000)
        XCTAssertEqual(segment.paddingMilliseconds, 0)
    }

    func testShortLivePhotoDerivedFixtureRendersAndValidatesWhenProvided() async throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["LIVES_SHORT_VIDEO_FIXTURE"] else {
            throw XCTSkip("Set LIVES_SHORT_VIDEO_FIXTURE to run the short Live Photo video regression")
        }
        let info = try await MediaInspector.inspect(path: sourcePath)
        XCTAssertGreaterThanOrEqual(info.durationMs, MediaConstraints.minimumSourceDurationMilliseconds)
        XCTAssertLessThan(info.durationMs, MediaConstraints.outputDurationMilliseconds)

        let project = RenderProject(
            id: "short-live-photo-regression-\(UUID().uuidString)",
            templateId: "single",
            canvas: .init(width: 720, height: 1280, fps: 30, durationMs: 3_000),
            clips: [
                .init(
                    id: "short-live-photo-source",
                    sourcePath: sourcePath,
                    sourceDurationMs: info.durationMs,
                    startTimeMs: 0,
                    crop: .init(normalizedCenterX: 0.5, normalizedCenterY: 0.5, scale: 1),
                    targetSlotId: "full",
                    audioEnabled: false,
                    coverTimeMs: 1500
                ),
            ],
            coverTimeMs: 1_500
        )
        let result = try await LivePhotoPipeline.validateOnly(
            project: project,
            cancellations: CancellationRegistry()
        ) { _, _ in }

        XCTAssertTrue(result.validated)
        XCTAssertEqual(result.durationMs, 3_000)
    }

    func testIncompatibleVideoIsConvertedWhenFixtureIsProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sourcePath = environment["LIVES_INCOMPATIBLE_VIDEO_FIXTURE"] else {
            throw XCTSkip("Set LIVES_INCOMPATIBLE_VIDEO_FIXTURE to run the compatibility conversion regression")
        }
        guard environment["LIVES_FFMPEG_PATH"] != nil else {
            throw XCTSkip("Set LIVES_FFMPEG_PATH to the bundled FFmpeg runtime")
        }
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let sourceRequiresConversion = try await CompatibilityTranscoder.requiresTranscoding(sourceURL: sourceURL)
        XCTAssertTrue(sourceRequiresConversion)

        let info = try await MediaInspector.inspect(path: sourcePath)
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LivesCompatibilityTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        let project = RenderProject(
            id: "compatibility-regression-\(UUID().uuidString)",
            templateId: "single",
            canvas: .init(width: 720, height: 1280, fps: 30, durationMs: 3_000),
            clips: [
                .init(
                    id: "incompatible-source",
                    sourcePath: sourcePath,
                    sourceDurationMs: info.durationMs,
                    startTimeMs: 0,
                    crop: .init(normalizedCenterX: 0.5, normalizedCenterY: 0.5, scale: 1),
                    targetSlotId: "full",
                    audioEnabled: true,
                    coverTimeMs: 1500
                ),
            ],
            coverTimeMs: 1_500
        )

        let prepared = try await CompatibilityTranscoder.prepare(
            project: project,
            workingDirectory: workingDirectory,
            cancellations: CancellationRegistry()
        ) { _ in }

        let converted = try XCTUnwrap(prepared.clips.first)
        XCTAssertNotEqual(converted.sourcePath, sourcePath)
        XCTAssertEqual(converted.startTimeMs, 0)
        XCTAssertGreaterThanOrEqual(converted.sourceDurationMs, 3_000)
        let convertedRequiresConversion = try await CompatibilityTranscoder.requiresTranscoding(
            sourceURL: URL(fileURLWithPath: converted.sourcePath)
        )
        XCTAssertFalse(convertedRequiresConversion)
    }

    func testStackThreeUsesEqualVerticalSlots() throws {
        let canvas = CGSize(width: 1080, height: 1920)
        let top = try TemplateLayout.rect(for: "top", templateId: "stack-3", canvas: canvas)
        let middle = try TemplateLayout.rect(for: "middle", templateId: "stack-3", canvas: canvas)
        let bottom = try TemplateLayout.rect(for: "bottom", templateId: "stack-3", canvas: canvas)
        XCTAssertEqual(top.height, 640, accuracy: 0.001)
        XCTAssertEqual(middle.minY, 640, accuracy: 0.001)
        XCTAssertEqual(bottom.minY, 1280, accuracy: 0.001)
    }

    func testSideBySideAndHeroLayoutsFillTheCanvas() throws {
        let canvas = CGSize(width: 1080, height: 1920)
        let left = try TemplateLayout.rect(for: "left", templateId: "side-2", canvas: canvas)
        let right = try TemplateLayout.rect(for: "right", templateId: "side-2", canvas: canvas)
        XCTAssertEqual(left.width, 540, accuracy: 0.001)
        XCTAssertEqual(right.minX, 540, accuracy: 0.001)

        let hero = try TemplateLayout.rect(for: "hero-left", templateId: "hero-left", canvas: canvas)
        let rightTop = try TemplateLayout.rect(for: "right-top", templateId: "hero-left", canvas: canvas)
        let rightBottom = try TemplateLayout.rect(for: "right-bottom", templateId: "hero-left", canvas: canvas)
        XCTAssertEqual(hero.width, 720, accuracy: 0.001)
        XCTAssertEqual(rightTop.minX, 720, accuracy: 0.001)
        XCTAssertEqual(rightTop.height + rightBottom.height, canvas.height, accuracy: 0.001)
    }

    func testVerticalThreeUsesEqualHorizontalSlots() throws {
        let canvas = CGSize(width: 1920, height: 1080)
        let left = try TemplateLayout.rect(for: "left", templateId: "side-3", canvas: canvas)
        let center = try TemplateLayout.rect(for: "center", templateId: "side-3", canvas: canvas)
        let right = try TemplateLayout.rect(for: "right", templateId: "side-3", canvas: canvas)
        XCTAssertEqual(left.width, 640, accuracy: 0.001)
        XCTAssertEqual(center.minX, 640, accuracy: 0.001)
        XCTAssertEqual(right.minX, 1280, accuracy: 0.001)
        XCTAssertEqual(right.maxX, canvas.width, accuracy: 0.001)
    }

    func testEveryTemplateHasTheExpectedClipCount() {
        XCTAssertEqual(LivePhotoPipeline.expectedClipCount(for: "single"), 1)
        XCTAssertEqual(LivePhotoPipeline.expectedClipCount(for: "side-2"), 2)
        XCTAssertEqual(LivePhotoPipeline.expectedClipCount(for: "side-3"), 3)
        XCTAssertEqual(LivePhotoPipeline.expectedClipCount(for: "hero-left"), 3)
        XCTAssertEqual(LivePhotoPipeline.expectedClipCount(for: "hero-top"), 3)
        XCTAssertEqual(LivePhotoPipeline.expectedClipCount(for: "weighted-3"), 3)
        XCTAssertEqual(LivePhotoPipeline.expectedClipCount(for: "unknown"), 0)
    }

    func testCancellationRegistryClearsFinishedJobs() async throws {
        let registry = CancellationRegistry()
        await registry.cancel("job")
        await XCTAssertThrowsErrorAsync(try await registry.check("job"))
        await registry.finish("job")
        try await registry.check("job")
    }

    func testLivePhotoValidationStopsBeforeStartingWhenCancelled() async throws {
        let registry = CancellationRegistry()
        await registry.cancel("cancelled-validation")
        do {
            try await LivePhotoPipeline.validatePair(
                photoURL: URL(fileURLWithPath: "/does-not-need-to-exist.jpg"),
                pairedVideoURL: URL(fileURLWithPath: "/does-not-need-to-exist.mov"),
                cancellations: registry,
                jobId: "cancelled-validation"
            )
            XCTFail("Expected validation to stop")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, ServiceError.cancelled.code)
        }
    }

    func testLivePhotoPairWhenFixtureIsProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let photoPath = environment["LIVE_COLLAGE_TEST_PHOTO"],
              let videoPath = environment["LIVE_COLLAGE_TEST_VIDEO"] else {
            throw XCTSkip("Set Live Photo fixture paths to run the Photos integration check")
        }
        let registry = CancellationRegistry()
        try await LivePhotoPipeline.validatePair(
            photoURL: URL(fileURLWithPath: photoPath),
            pairedVideoURL: URL(fileURLWithPath: videoPath),
            cancellations: registry,
            jobId: "fixture-validation",
            timeoutNanoseconds: 5_000_000_000
        )
    }

    func testFolderExportCopiesAPairedResourceSetWithoutOverwriting() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let sourcePhoto = root.appendingPathComponent("source.jpg")
        let sourceVideo = root.appendingPathComponent("source.mov")
        try Data("photo".utf8).write(to: sourcePhoto)
        try Data("video".utf8).write(to: sourceVideo)
        let destination = root.appendingPathComponent("output", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let first = try LivePhotoPipeline.copyPair(photoURL: sourcePhoto, videoURL: sourceVideo, toDirectoryPath: destination.path, now: date)
        let second = try LivePhotoPipeline.copyPair(photoURL: sourcePhoto, videoURL: sourceVideo, toDirectoryPath: destination.path, now: date)

        XCTAssertTrue(fileManager.fileExists(atPath: first.photoPath))
        XCTAssertTrue(fileManager.fileExists(atPath: first.videoPath))
        XCTAssertNotEqual(first.photoPath, second.photoPath)
        XCTAssertNotEqual(first.videoPath, second.videoPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: second.photoPath)), Data("photo".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: second.videoPath)), Data("video".utf8))
    }

    func testAspectFillCentersHorizontalOverflow() {
        let transform = TemplateLayout.aspectFillTransform(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: .identity,
            target: CGRect(x: 0, y: 0, width: 1080, height: 640),
            centerX: 0.5,
            centerY: 0.5,
            userScale: 1
        )
        let rendered = CGRect(x: 0, y: 0, width: 1920, height: 1080).applying(transform)
        XCTAssertLessThanOrEqual(rendered.minX, 0)
        XCTAssertGreaterThanOrEqual(rendered.maxX, 1080)
        XCTAssertEqual(rendered.height, 640, accuracy: 0.01)
    }

    func testLandscapeSideBySideCropIsConvertedBackToSourceCoordinates() {
        let naturalSize = CGSize(width: 640, height: 360)
        let target = CGRect(x: 0, y: 0, width: 640, height: 720)
        let transform = TemplateLayout.aspectFillTransform(
            naturalSize: naturalSize,
            preferredTransform: .identity,
            target: target,
            centerX: 0.5,
            centerY: 0.5,
            userScale: 1
        )
        let canvas = CGSize(width: 1280, height: 720)
        let crop = TemplateLayout.sourceCropRectangle(
            target: target,
            canvas: canvas,
            transform: transform,
            naturalSize: naturalSize
        )

        XCTAssertEqual(crop.minX, 0)
        XCTAssertEqual(crop.minY, 0)
        XCTAssertEqual(crop.width, 481.0, accuracy: 0.001)
        XCTAssertEqual(crop.height, 360, accuracy: 0.001)
    }

    func testTemplateLayoutSnapsOuterEdgesToCanvasBounds() throws {
        // 720p 16:9 canvas where 1280 is not divisible by 3
        let canvas = CGSize(width: 1280, height: 720)
        let left = try TemplateLayout.rect(for: "left", templateId: "side-3", canvas: canvas)
        let center = try TemplateLayout.rect(for: "center", templateId: "side-3", canvas: canvas)
        let right = try TemplateLayout.rect(for: "right", templateId: "side-3", canvas: canvas)

        XCTAssertEqual(left.minX, 0)
        XCTAssertEqual(left.minY, 0)
        XCTAssertEqual(left.height, 720)
        XCTAssertEqual(right.maxX, 1280)
        XCTAssertEqual(right.height, 720)
        XCTAssertEqual(center.height, 720)

        let heroTop = try TemplateLayout.rect(for: "hero-top", templateId: "hero-top", canvas: CGSize(width: 720, height: 1280))
        let bottomLeft = try TemplateLayout.rect(for: "bottom-left", templateId: "hero-top", canvas: CGSize(width: 720, height: 1280))
        let bottomRight = try TemplateLayout.rect(for: "bottom-right", templateId: "hero-top", canvas: CGSize(width: 720, height: 1280))

        XCTAssertEqual(heroTop.minX, 0)
        XCTAssertEqual(heroTop.minY, 0)
        XCTAssertEqual(heroTop.width, 720)
        XCTAssertEqual(bottomLeft.minX, 0)
        XCTAssertEqual(bottomLeft.maxY, 1280)
        XCTAssertEqual(bottomRight.maxX, 720)
        XCTAssertEqual(bottomRight.maxY, 1280)
    }

    func testSourceCropRectangleClampsWithoutTruncatingEdgeDimensions() {
        let naturalSize = CGSize(width: 1080, height: 1920)
        let canvas = CGSize(width: 1080, height: 1920)
        let target = CGRect(x: 0, y: 0, width: 1080, height: 1920)
        let transform = CGAffineTransform.identity
        let crop = TemplateLayout.sourceCropRectangle(
            target: target,
            canvas: canvas,
            transform: transform,
            naturalSize: naturalSize
        )

        XCTAssertEqual(crop.minX, 0)
        XCTAssertEqual(crop.minY, 0)
        XCTAssertEqual(crop.width, 1080)
        XCTAssertEqual(crop.height, 1920)
    }

    func testDiagnoseCollageRenderingAndCoverPixels() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceVideoURL = directory.appendingPathComponent("source.mov")
        let outputVideoURL = directory.appendingPathComponent("paired.mov")

        // Create a 3-second 1080x1920 test video filled with solid cyan (R:0, G:200, B:200)
        let width = 1080
        let height = 1920
        let fps = 30
        let durationSeconds = 3.0

        let writer = try AVAssetWriter(outputURL: sourceVideoURL, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        guard let pixelBufferPool = adaptor.pixelBufferPool else {
            XCTFail("No pixel buffer pool")
            return
        }
        let frameCount = Int(durationSeconds * Double(fps))
        for frameIndex in 0..<frameCount {
            let time = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, adaptor.pixelBufferPool!, &buffer)
            guard let pixelBuffer = buffer else { continue }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)!
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            // Fill with solid magenta / cyan (B:200, G:200, R:0, A:255)
            for y in 0..<height {
                let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    row[x * 4 + 0] = 200 // B
                    row[x * 4 + 1] = 200 // G
                    row[x * 4 + 2] = 0   // R
                    row[x * 4 + 3] = 255 // A
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            adaptor.append(pixelBuffer, withPresentationTime: time)
        }
        input.markAsFinished()
        await writer.finishWriting()

        // Now render side-2 (left and right) using this video
        let project = RenderProject(
            id: UUID().uuidString,
            templateId: "side-2",
            canvas: .init(width: width, height: height, fps: fps, durationMs: 3000),
            clips: [
                .init(
                    id: "clip-left",
                    sourcePath: sourceVideoURL.path,
                    sourceDurationMs: 3000,
                    startTimeMs: 0,
                    crop: .init(normalizedCenterX: 0.5, normalizedCenterY: 0.5, scale: 1),
                    targetSlotId: "left",
                    audioEnabled: false,
                    coverTimeMs: 1500
                ),
                .init(
                    id: "clip-right",
                    sourcePath: sourceVideoURL.path,
                    sourceDurationMs: 3000,
                    startTimeMs: 0,
                    crop: .init(normalizedCenterX: 0.5, normalizedCenterY: 0.5, scale: 1),
                    targetSlotId: "right",
                    audioEnabled: false,
                    coverTimeMs: 1500
                ),
            ],
            coverTimeMs: 0
        )

        try await VideoRenderer.render(
            project: project,
            outputURL: outputVideoURL,
            contentIdentifier: UUID().uuidString,
            cancellations: CancellationRegistry()
        ) { _ in }

        // Extract cover
        let asset = AVURLAsset(url: outputVideoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: .zero).image

        // Inspect pixel colors in the extracted image
        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, height)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            XCTFail("Failed to create context")
            return
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixelData = context.data else {
            XCTFail("Failed to read pixel data")
            return
        }

        let ptr = pixelData.assumingMemoryBound(to: UInt8.self)
        func getPixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            let offset = (y * width + x) * 4
            return (ptr[offset + 0], ptr[offset + 1], ptr[offset + 2], ptr[offset + 3])
        }

        let midY = height / 2
        print("[Diagnose] Left edge x=0:", getPixel(x: 0, y: midY))
        print("[Diagnose] Left slot inner x=100:", getPixel(x: 100, y: midY))
        print("[Diagnose] Seam x=539:", getPixel(x: 539, y: midY))
        print("[Diagnose] Seam x=540:", getPixel(x: 540, y: midY))
        print("[Diagnose] Right slot inner x=900:", getPixel(x: 900, y: midY))
        print("[Diagnose] Right edge x=1079:", getPixel(x: 1079, y: midY))

        // Check if edges or seam are black (R+G+B < 30)
        let leftEdge = getPixel(x: 0, y: midY)
        let rightEdge = getPixel(x: 1079, y: midY)
        let seam1 = getPixel(x: 539, y: midY)
        let seam2 = getPixel(x: 540, y: midY)

        XCTAssertGreaterThan(Int(leftEdge.g) + Int(leftEdge.b), 100, "Left edge is black: \(leftEdge)")
        XCTAssertGreaterThan(Int(rightEdge.g) + Int(rightEdge.b), 100, "Right edge is black: \(rightEdge)")
        XCTAssertGreaterThan(Int(seam1.g) + Int(seam1.b), 100, "Seam (539) is black: \(seam1)")
        XCTAssertGreaterThan(Int(seam2.g) + Int(seam2.b), 100, "Seam (540) is black: \(seam2)")
    }

    func testDiagnoseRotatedVideoCollagePixels() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceVideoURL = directory.appendingPathComponent("rotated_source.mov")
        let outputVideoURL = directory.appendingPathComponent("paired_rotated.mov")

        // Create a 1920x1080 landscape video with a 90-degree transform (iPhone portrait video)
        let sourceWidth = 1920
        let sourceHeight = 1080
        let fps = 30
        let durationSeconds = 3.0

        let writer = try AVAssetWriter(outputURL: sourceVideoURL, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: sourceWidth,
            AVVideoHeightKey: sourceHeight,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        // iPhone vertical video has preferredTransform: 90 deg clockwise [0, 1, -1, 0, 1080, 0]
        input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: sourceWidth,
                kCVPixelBufferHeightKey as String: sourceHeight,
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(durationSeconds * Double(fps))
        for frameIndex in 0..<frameCount {
            let time = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, adaptor.pixelBufferPool!, &buffer)
            guard let pixelBuffer = buffer else { continue }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)!
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            // Fill with solid yellow (B:0, G:220, R:220, A:255)
            for y in 0..<sourceHeight {
                let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<sourceWidth {
                    row[x * 4 + 0] = 0   // B
                    row[x * 4 + 1] = 220 // G
                    row[x * 4 + 2] = 220 // R
                    row[x * 4 + 3] = 255 // A
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            adaptor.append(pixelBuffer, withPresentationTime: time)
        }
        input.markAsFinished()
        await writer.finishWriting()

        let width = 1080
        let height = 1920

        // Render side-2 with rotated source in left and right
        let project = RenderProject(
            id: UUID().uuidString,
            templateId: "side-2",
            canvas: .init(width: width, height: height, fps: fps, durationMs: 3000),
            clips: [
                .init(
                    id: "clip-left",
                    sourcePath: sourceVideoURL.path,
                    sourceDurationMs: 3000,
                    startTimeMs: 0,
                    crop: .init(normalizedCenterX: 0.5, normalizedCenterY: 0.5, scale: 1),
                    targetSlotId: "left",
                    audioEnabled: false,
                    coverTimeMs: 1500
                ),
                .init(
                    id: "clip-right",
                    sourcePath: sourceVideoURL.path,
                    sourceDurationMs: 3000,
                    startTimeMs: 0,
                    crop: .init(normalizedCenterX: 0.5, normalizedCenterY: 0.5, scale: 1),
                    targetSlotId: "right",
                    audioEnabled: false,
                    coverTimeMs: 1500
                ),
            ],
            coverTimeMs: 0
        )

        try await VideoRenderer.render(
            project: project,
            outputURL: outputVideoURL,
            contentIdentifier: UUID().uuidString,
            cancellations: CancellationRegistry()
        ) { _ in }

        // Extract cover
        let asset = AVURLAsset(url: outputVideoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: .zero).image

        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, height)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            XCTFail("Failed to create context")
            return
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixelData = context.data else {
            XCTFail("Failed to read pixel data")
            return
        }

        let ptr = pixelData.assumingMemoryBound(to: UInt8.self)
        func getPixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            let offset = (y * width + x) * 4
            return (ptr[offset + 0], ptr[offset + 1], ptr[offset + 2], ptr[offset + 3])
        }

        let midY = height / 2
        print("[Diagnose Rotated] Left edge x=0:", getPixel(x: 0, y: midY))
        print("[Diagnose Rotated] Left slot inner x=100:", getPixel(x: 100, y: midY))
        print("[Diagnose Rotated] Seam x=539:", getPixel(x: 539, y: midY))
        print("[Diagnose Rotated] Seam x=540:", getPixel(x: 540, y: midY))
        print("[Diagnose Rotated] Right slot inner x=900:", getPixel(x: 900, y: midY))
        print("[Diagnose Rotated] Right edge x=1079:", getPixel(x: 1079, y: midY))

        let leftEdge = getPixel(x: 0, y: midY)
        let rightEdge = getPixel(x: 1079, y: midY)
        let seam1 = getPixel(x: 539, y: midY)
        let seam2 = getPixel(x: 540, y: midY)

        XCTAssertGreaterThan(Int(leftEdge.r) + Int(leftEdge.g), 100, "Left edge is black: \(leftEdge)")
        XCTAssertGreaterThan(Int(rightEdge.r) + Int(rightEdge.g), 100, "Right edge is black: \(rightEdge)")
        XCTAssertGreaterThan(Int(seam1.r) + Int(seam1.g), 100, "Seam (539) is black: \(seam1)")
        XCTAssertGreaterThan(Int(seam2.r) + Int(seam2.g), 100, "Seam (540) is black: \(seam2)")
    }

    func testDiagnoseBottomEdgeAndStackCollagePixels() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceVideoURL = directory.appendingPathComponent("stack_source.mov")
        let outputVideoURL = directory.appendingPathComponent("stack_paired.mov")

        let sourceWidth = 1080
        let sourceHeight = 1920
        let fps = 30
        let durationSeconds = 3.0

        let writer = try AVAssetWriter(outputURL: sourceVideoURL, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: sourceWidth,
            AVVideoHeightKey: sourceHeight,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: sourceWidth,
                kCVPixelBufferHeightKey as String: sourceHeight,
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        guard let pixelBufferPool = adaptor.pixelBufferPool else {
            XCTFail("No pixel buffer pool")
            return
        }
        let frameCount = Int(durationSeconds * Double(fps))
        for frameIndex in 0..<frameCount {
            let time = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &buffer)
            guard let pixelBuffer = buffer else { continue }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)!
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            // Fill with solid purple (B:200, G:0, R:200, A:255)
            for y in 0..<sourceHeight {
                let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<sourceWidth {
                    row[x * 4 + 0] = 200 // B
                    row[x * 4 + 1] = 0   // G
                    row[x * 4 + 2] = 200 // R
                    row[x * 4 + 3] = 255 // A
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            adaptor.append(pixelBuffer, withPresentationTime: time)
        }
        input.markAsFinished()
        await writer.finishWriting()

        let width = 1080
        let height = 1920

        // Test stack-2 (top & bottom)
        let project = RenderProject(
            id: UUID().uuidString,
            templateId: "stack-2",
            canvas: .init(width: width, height: height, fps: fps, durationMs: 3000),
            clips: [
                .init(
                    id: "clip-top",
                    sourcePath: sourceVideoURL.path,
                    sourceDurationMs: 3000,
                    startTimeMs: 0,
                    crop: .init(normalizedCenterX: 0.5, normalizedCenterY: 0.5, scale: 1),
                    targetSlotId: "top",
                    audioEnabled: false,
                    coverTimeMs: 1500
                ),
                .init(
                    id: "clip-bottom",
                    sourcePath: sourceVideoURL.path,
                    sourceDurationMs: 3000,
                    startTimeMs: 0,
                    crop: .init(normalizedCenterX: 0.5, normalizedCenterY: 0.5, scale: 1),
                    targetSlotId: "bottom",
                    audioEnabled: false,
                    coverTimeMs: 1500
                ),
            ],
            coverTimeMs: 0
        )

        try await VideoRenderer.render(
            project: project,
            outputURL: outputVideoURL,
            contentIdentifier: UUID().uuidString,
            cancellations: CancellationRegistry()
        ) { _ in }

        let asset = AVURLAsset(url: outputVideoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: .zero).image

        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, height)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            XCTFail("Failed to create context")
            return
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixelData = context.data else {
            XCTFail("Failed to read pixel data")
            return
        }

        let ptr = pixelData.assumingMemoryBound(to: UInt8.self)
        func getPixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            let offset = (y * width + x) * 4
            return (ptr[offset + 0], ptr[offset + 1], ptr[offset + 2], ptr[offset + 3])
        }

        let midX = width / 2
        print("[Diagnose Stack] Top edge y=0:", getPixel(x: midX, y: 0))
        print("[Diagnose Stack] Seam y=959:", getPixel(x: midX, y: 959))
        print("[Diagnose Stack] Seam y=960:", getPixel(x: midX, y: 960))
        print("[Diagnose Stack] Bottom edge y=1919:", getPixel(x: midX, y: 1919))
        print("[Diagnose Stack] Bottom-left (0, 1919):", getPixel(x: 0, y: 1919))
        print("[Diagnose Stack] Bottom-right (1079, 1919):", getPixel(x: 1079, y: 1919))

        let topEdge = getPixel(x: midX, y: 0)
        let bottomEdge = getPixel(x: midX, y: 1919)
        let seam1 = getPixel(x: midX, y: 959)
        let seam2 = getPixel(x: midX, y: 960)

        XCTAssertGreaterThan(Int(topEdge.r) + Int(topEdge.b), 100, "Top edge is black: \(topEdge)")
        XCTAssertGreaterThan(Int(bottomEdge.r) + Int(bottomEdge.b), 100, "Bottom edge is black: \(bottomEdge)")
        XCTAssertGreaterThan(Int(seam1.r) + Int(seam1.b), 100, "Seam (959) is black: \(seam1)")
        XCTAssertGreaterThan(Int(seam2.r) + Int(seam2.b), 100, "Seam (960) is black: \(seam2)")
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
