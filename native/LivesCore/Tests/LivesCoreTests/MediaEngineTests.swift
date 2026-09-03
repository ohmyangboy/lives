import AVFoundation
import ImageIO
import XCTest
@testable import LivesCore

final class MediaEngineTests: XCTestCase {
    func testAudioSwitchPreservesAudibleSamplesAndMutesExport() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIVES_AUDIO_FIXTURE"] else {
            throw XCTSkip("设置 LIVES_AUDIO_FIXTURE 为包含测试音的片段")
        }
        let url = URL(fileURLWithPath: path)
        let info = try await LivesMediaEngine.inspect(url: url)
        XCTAssertTrue(info.hasAudio)
        let asset = SourceAsset(displayName: "Tone", relativePath: "tone.mp4", durationMs: info.durationMs,
                                width: info.width, height: info.height, codec: info.codec)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LivesAudioTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        for enabled in [true, false] {
            let project = ProjectDocument(assets: [asset], placements: [
                Placement(sourceAssetID: asset.id, slotID: "full", startTimeMs: 2000, audioEnabled: enabled)
            ])
            let pair = try await LivesMediaEngine.render(
                request: RenderRequest(project: project, canvasSize: CanvasSize(width: 320, height: 320)),
                resolvedURLs: [asset.id: url], outputDirectory: directory.appendingPathComponent(enabled ? "audio" : "muted"))
            let movie = AVURLAsset(url: pair.videoURL)
            let tracks = try await movie.loadTracks(withMediaType: .audio)
            if !enabled { XCTAssertTrue(tracks.isEmpty); continue }
            XCTAssertEqual(tracks.count, 1)
            let track = try XCTUnwrap(tracks.first)
            let range = try await track.load(.timeRange)
            XCTAssertEqual(range.duration.seconds, 3, accuracy: 0.08)
            let reader = try AVAssetReader(asset: movie)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: false, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false
            ])
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            var peak = 0
            var samples = 0
            while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
                let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Int16>.size
                var pcm = [Int16](repeating: 0, count: count)
                let status = pcm.withUnsafeMutableBytes { bytes in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
                }
                XCTAssertEqual(status, kCMBlockBufferNoErr)
                peak = max(peak, pcm.map { abs(Int($0)) }.max() ?? 0)
                samples += count
            }
            XCTAssertEqual(reader.status, .completed)
            XCTAssertGreaterThan(samples, 100_000)
            XCTAssertGreaterThan(peak, 100, "有音轨并不等于有声音，必须实际解码出非静音样本")
        }
    }

    func test4KAutomaticRenderWritesFullResolutionPairWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIVES_4K_FIXTURE"] else {
            throw XCTSkip("设置 LIVES_4K_FIXTURE 后运行 4K 编码回归")
        }
        let url = URL(fileURLWithPath: path)
        let info = try await LivesMediaEngine.inspect(url: url)
        let asset = SourceAsset(displayName: "4K", relativePath: "4k.mp4", durationMs: info.durationMs,
                                width: info.width, height: info.height, codec: info.codec)
        let project = ProjectDocument(canvas: CanvasSettings(aspectRatio: .landscape169), assets: [asset],
                                      placements: [Placement(sourceAssetID: asset.id, slotID: "full")])
        let size = OutputResolution.automatic(for: project, pro: true)
        XCTAssertEqual(size, CanvasSize(width: 3840, height: 2160))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Lives4KTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pair = try await LivesMediaEngine.render(request: RenderRequest(project: project, canvasSize: size),
                                                    resolvedURLs: [asset.id: url], outputDirectory: directory)
        try await LivesMediaEngine.validate(pair: pair)
        let video = try await LivesMediaEngine.inspect(url: pair.videoURL)
        XCTAssertEqual(video.width, 3840)
        XCTAssertEqual(video.height, 2160)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(pair.photoURL as CFURL, nil))
        let cover = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(cover.width, 3840)
        XCTAssertEqual(cover.height, 2160)
    }

    func testRenderAndValidateFixtureWhenProvided() async throws {
        guard let fixturePath = ProcessInfo.processInfo.environment["LIVES_MEDIA_FIXTURE"] else {
            throw XCTSkip("设置 LIVES_MEDIA_FIXTURE 后运行媒体渲染回归")
        }

        let fixtureURL = URL(fileURLWithPath: fixturePath)
        let info = try await LivesMediaEngine.inspect(url: fixtureURL)
        XCTAssertGreaterThanOrEqual(info.durationMs, ProjectValidation.minimumSourceDurationMs)

        let asset = SourceAsset(
            displayName: fixtureURL.lastPathComponent,
            relativePath: "media/fixture.mov",
            durationMs: info.durationMs,
            width: info.width,
            height: info.height,
            codec: info.codec
        )
        let placement = Placement(sourceAssetID: asset.id, slotID: "full", audioEnabled: info.hasAudio)
        let project = ProjectDocument(templateID: .single, assets: [asset], placements: [placement])
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("LivesCoreMediaTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let pair = try await LivesMediaEngine.render(
            request: RenderRequest(project: project),
            resolvedURLs: [asset.id: fixtureURL],
            outputDirectory: outputDirectory
        )
        try await LivesMediaEngine.validate(pair: pair)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pair.photoURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pair.videoURL.path))
    }
}
