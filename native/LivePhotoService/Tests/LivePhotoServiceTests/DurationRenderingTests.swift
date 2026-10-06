import AVFoundation
import CoreVideo
import XCTest
@testable import LivePhotoService

final class DurationRenderingTests: XCTestCase {
    private func project(sourcePath: String = "/tmp/duration-fixture.mov", durationMs: Int) -> RenderProject {
        RenderProject(
            id: UUID().uuidString,
            templateId: "single",
            canvas: .init(width: 720, height: 720, fps: 30, durationMs: durationMs),
            clips: [.init(
                id: UUID().uuidString, sourcePath: sourcePath, sourceDurationMs: 2_600, startTimeMs: 1_000,
                crop: .init(normalizedCenterX: 0.5, normalizedCenterY: 0.5, scale: 1),
                targetSlotId: "full", audioEnabled: false, coverTimeMs: 500
            )],
            coverTimeMs: 500
        )
    }

    func testHelperAcceptsVariableDurationsAndRejectsOutOfRangeOrOffStepValues() {
        for duration in [1_000, 3_000, 3_900, 15_000] {
            XCTAssertNoThrow(try LivePhotoPipeline.validate(project(durationMs: duration)))
        }
        for duration in [900, 1_050, 15_100] {
            XCTAssertThrowsError(try LivePhotoPipeline.validate(project(durationMs: duration))) { error in
                XCTAssertEqual((error as? ServiceError)?.code, "INVALID_PROJECT")
            }
        }
    }

    func testPairedOutputsUseChosenDurationAndKeepAPaddedTailVisible() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LivesDuration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.mov")
        try await writeSource(to: sourceURL)

        for durationMs in [1_000, 3_900, 15_000] {
            let result = try await LivePhotoPipeline.exportToFolder(
                project: project(sourcePath: sourceURL.path, durationMs: durationMs),
                directoryPath: directory.path,
                cancellations: CancellationRegistry()
            ) { _, _ in }
            let asset = AVURLAsset(url: URL(fileURLWithPath: result.videoPath))
            let duration = try await asset.load(.duration)
            XCTAssertEqual(duration.seconds, Double(durationMs) / 1000, accuracy: 1.0 / 30)
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.photoPath))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let tail = try await generator.image(at: CMTime(seconds: duration.seconds - 0.1, preferredTimescale: 600)).image
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(tail, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            XCTAssertGreaterThan(pixel[1], 120, "Padded tail must preserve the source's green channel")
            XCTAssertGreaterThan(pixel[2], 120, "Padded tail must preserve the source's blue channel")
        }
    }

    func testCollagePadsEachCellWhileAnotherSourceKeepsPlaying() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LivesDurationCollage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shortURL = directory.appendingPathComponent("short.mov")
        let longURL = directory.appendingPathComponent("long.mov")
        try await writeSource(to: shortURL)
        try await writeSource(to: longURL, frameCount: 198, red: 200, green: 0)
        let value = RenderProject(
            id: UUID().uuidString, templateId: "side-2",
            canvas: .init(width: 720, height: 720, fps: 30, durationMs: 15_000),
            clips: [
                .init(id: "short", sourcePath: shortURL.path, sourceDurationMs: 2_600, startTimeMs: 0,
                    crop: .init(normalizedCenterX: 0.5, normalizedCenterY: 0.5, scale: 1), targetSlotId: "left", audioEnabled: false, coverTimeMs: 1_500),
                .init(id: "long", sourcePath: longURL.path, sourceDurationMs: 6_600, startTimeMs: 0,
                    crop: .init(normalizedCenterX: 0.5, normalizedCenterY: 0.5, scale: 1), targetSlotId: "right", audioEnabled: false, coverTimeMs: 1_500),
            ], coverTimeMs: 1_500
        )
        let result = try await LivePhotoPipeline.exportToFolder(project: value, directoryPath: directory.path, cancellations: CancellationRegistry()) { _, _ in }
        let asset = AVURLAsset(url: URL(fileURLWithPath: result.videoPath))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for time in [3.5, 14.8] {
            let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            var pixels = [UInt8](repeating: 0, count: 8)
            let context = try XCTUnwrap(CGContext(data: &pixels, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(frame, in: CGRect(x: 0, y: 0, width: 2, height: 1))
            XCTAssertGreaterThan(pixels[1], 120, "Short source must remain visible at \(time)s")
            XCTAssertGreaterThan(pixels[2], 120)
            XCTAssertGreaterThan(pixels[4], 120, "Long source must remain visible at \(time)s")
            XCTAssertGreaterThan(pixels[6], 120)
        }
    }

    func testOneSecondConvertedSegmentCanBeInspectedWithoutLoweringTheImportMinimum() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LivesDurationInspection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("one-second.mov")
        try await writeSource(to: sourceURL, frameCount: 30)
        do {
            _ = try await MediaInspector.inspect(path: sourceURL.path)
            XCTFail("Import must retain its 2.5-second minimum")
        } catch {
            XCTAssertEqual((error as? ServiceError)?.code, "VIDEO_TOO_SHORT")
        }
        let inspected = try await MediaInspector.inspect(path: sourceURL.path, minimumDurationMilliseconds: 1_000)
        XCTAssertEqual(inspected.durationMs, 1_000)
    }

    private func writeSource(to url: URL, frameCount: Int = 78, red: UInt8 = 0, green: UInt8 = 200) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let pool = try XCTUnwrap(adaptor.pixelBufferPool)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
        for y in 0..<64 {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
            for x in 0..<64 {
                row[x * 4] = 200
                row[x * 4 + 1] = green
                row[x * 4 + 2] = red
                row[x * 4 + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw try XCTUnwrap(writer.error) }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
