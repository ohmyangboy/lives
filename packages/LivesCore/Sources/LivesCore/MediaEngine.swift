import AVFoundation
import VideoToolbox
import CoreImage
import CoreMedia
import CoreVideo
import CoreText
import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

public struct MediaProgress: Sendable, Equatable {
    public let stage: String
    public let fraction: Double

    public init(stage: String, fraction: Double) {
        self.stage = stage
        self.fraction = fraction
    }
}

/// Native decode and audio work can report from different tasks. Keep the
/// externally visible fraction monotonic before it reaches a UI progress ring
/// or another platform client.
private final class MonotonicMediaProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var lastFraction = 0.0
    private let sink: @Sendable (MediaProgress) -> Void

    init(_ sink: @escaping @Sendable (MediaProgress) -> Void) {
        self.sink = sink
    }

    func send(_ value: MediaProgress) {
        lock.lock()
        defer { lock.unlock() }
        let fraction = min(1, max(lastFraction, value.fraction.isFinite ? value.fraction : lastFraction))
        lastFraction = fraction
        sink(MediaProgress(stage: value.stage, fraction: fraction))
    }
}

public struct LivePhotoPair: Sendable {
    public let photoURL: URL
    public let videoURL: URL
    public let contentIdentifier: String

    public init(photoURL: URL, videoURL: URL, contentIdentifier: String) {
        self.photoURL = photoURL
        self.videoURL = videoURL
        self.contentIdentifier = contentIdentifier
    }
}

/// 共享的媒体实现。平台适配层只负责把用户选择的 URL 解析给它，以及把
/// 生成的 pair 交给 PhotoKit；编辑器永远只传递不可变的 RenderRequest。
public enum LivesMediaEngine {
    public static func inspect(url: URL) async throws -> MediaInfo {
        try await inspectVideo(url: url, minimumDurationMs: ProjectValidation.minimumSourceDurationMs)
    }

    public static func inspect(source: ResolvedMediaSource) async throws -> MediaInfo {
        switch source {
        case .video(let url):
            return try await inspect(url: url)
        case .photo(let url):
            return try inspectImage(url: url)
        case .livePhoto(let photoURL, let pairedVideoURL):
            let motion = try await inspectVideo(url: pairedVideoURL, minimumDurationMs: 1)
            guard let imageSource = CGImageSourceCreateWithURL(photoURL as CFURL, nil),
                  CGImageSourceGetCount(imageSource) > 0 else {
                throw LivesCoreError.invalidLivePhoto
            }
            let coverTime = await inspectStillImageTime(url: pairedVideoURL)
            return MediaInfo(
                durationMs: motion.durationMs,
                width: motion.width,
                height: motion.height,
                codec: motion.codec,
                hasAudio: motion.hasAudio,
                nativeCoverTimeMs: coverTime
            )
        }
    }

    public static func inspectVideo(url: URL, minimumDurationMs: Int = ProjectValidation.minimumSourceDurationMs) async throws -> MediaInfo {
        guard ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) else {
            throw LivesCoreError.unsupportedFileType
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationMs = max(0, Int((duration.seconds * 1000).rounded(.down)))
        guard durationMs >= minimumDurationMs else {
            throw LivesCoreError.sourceTooShort
        }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw LivesCoreError.renderFailed("视频没有可用画面")
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let descriptions = try await track.load(.formatDescriptions)
        let codec = descriptions.first.map { codecName(CMFormatDescriptionGetMediaSubType($0)) } ?? "unknown"
        let audio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        return MediaInfo(
            durationMs: durationMs,
            width: Int(abs(transformed.width).rounded()),
            height: Int(abs(transformed.height).rounded()),
            codec: codec,
            hasAudio: audio
        )
    }

    public static func inspectStillImageTime(url: URL) async -> Int? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { return nil }
        for item in items {
            if item.identifier?.rawValue == "mdta/com.apple.quicktime.still-image-time" {
                if let number = try? await item.load(.numberValue) {
                    return Int(number.int64Value)
                } else if let data = try? await item.load(.dataValue), data.count >= 4 {
                    var value: Int32 = 0
                    _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0) }
                    return Int(value)
                }
            }
        }
        return nil
    }

    private static func inspectImage(url: URL) throws -> MediaInfo {
        guard ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"].contains(url.pathExtension.lowercased()),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            throw LivesCoreError.unsupportedFileType
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = (5...8).contains(orientation)
        return MediaInfo(durationMs: 0, width: rotated ? height : width, height: rotated ? width : height, codec: url.pathExtension.lowercased(), hasAudio: false)
    }

    public static func render(
        request: RenderRequest,
        resolvedURLs: [UUID: URL],
        outputDirectory: URL,
        cancellation: RenderCancellation = RenderCancellation(),
        progress: @escaping @Sendable (MediaProgress) -> Void = { _ in }
    ) async throws -> LivePhotoPair {
        try await render(
            request: request,
            resolvedSources: resolvedURLs.mapValues { .video($0) },
            outputDirectory: outputDirectory,
            cancellation: cancellation,
            progress: progress
        )
    }

    public static func render(
        request: RenderRequest,
        resolvedSources: [UUID: ResolvedMediaSource],
        outputDirectory: URL,
        cancellation: RenderCancellation = RenderCancellation(),
        progress: @escaping @Sendable (MediaProgress) -> Void = { _ in }
    ) async throws -> LivePhotoPair {
        let watchdog = RenderWatchdog(cancellation: cancellation)
        defer { watchdog.finish() }
        return try await withTaskCancellationHandler {
            do {
                return try await renderImpl(request: request, resolvedSources: resolvedSources,
                    outputDirectory: outputDirectory, cancellation: cancellation) { value in
                    watchdog.recordActivity()
                    progress(value)
                }
            } catch {
                try cancellation.check()
                throw error
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func renderImpl(
        request: RenderRequest, resolvedSources: [UUID: ResolvedMediaSource],
        outputDirectory: URL, cancellation: RenderCancellation,
        progress: @escaping @Sendable (MediaProgress) -> Void
    ) async throws -> LivePhotoPair {
        let wallpaper = request.purpose == .lockScreenWallpaper
        let progressReporter = MonotonicMediaProgress(progress)
        var normalizedProject = request.project
        if wallpaper {
            // Normalize before validating so legacy drafts with a stale
            // duration still enter the fixed editor timeline.
            normalizedProject.outputDurationMs = WallpaperExportProfile.editDurationMs
        }
        ProjectTimeline.normalizeCovers(&normalizedProject)
        try ProjectValidation.validate(normalizedProject)
        try cancellation.check()
        progressReporter.send(MediaProgress(stage: "preparing", fraction: 0.01))
        if wallpaper && !WallpaperExportProfile.hasMotion(in: normalizedProject) {
            throw LivesCoreError.renderFailed("请添加视频或实况素材")
        }
        let wallpaperGeometry = WallpaperOutputGeometry(canvas: CanvasGeometry.size(for: normalizedProject.canvas))
        let requestedCover = wallpaper ? wallpaperGeometry.encoded : request.coverSize
        guard requestedCover.width >= 2, requestedCover.height >= 2,
              max(requestedCover.width, requestedCover.height) <= 8192,
              Double(requestedCover.width) * Double(requestedCover.height) <= (wallpaper ? 24_473_088 : 24_000_000) else {
            throw LivesCoreError.renderFailed("封面尺寸超过安全输出上限")
        }
        // Wallpaper editing always keeps a two-second source window; the
        // encoder applies the profile's average two-times compression, and the
        // selected motion curve decides how that compression is distributed.
        let request = RenderRequest(project: normalizedProject, canvasSize: request.canvasSize, audioPolicy: request.audioPolicy, coverSize: request.coverSize, dynamicRange: request.dynamicRange, purpose: request.purpose)
        let timelineDurationMs = request.project.outputDurationMs
        let encodedDurationMs = wallpaper ? WallpaperExportProfile.outputDurationMs : timelineDurationMs
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let videoURL = outputDirectory.appendingPathComponent("paired.mov")
        let ranges = try await outputDynamicRanges(project: request.project, resolvedSources: resolvedSources, policy: wallpaper ? .sdr : request.dynamicRange, cancellation: cancellation)
        let videoHDR = ranges.video
        let photoURL = outputDirectory.appendingPathComponent((wallpaper || ranges.cover) ? "cover.heic" : "cover.jpg")
        var completed = false
        defer {
            if !completed {
                for url in [photoURL, videoURL] where FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        let identifier = UUID().uuidString

        progressReporter.send(MediaProgress(stage: "preparing", fraction: 0.02))
        let composition = AVMutableComposition()
        let canvas = wallpaper ? wallpaperGeometry.displaySize : CGSize(width: request.canvasSize.width, height: request.canvasSize.height)
        let wallpaperContent = CGRect(origin: .zero, size: canvas)
        var audioTracks: [AVMutableCompositionTrack] = []
        var colorSlots: [ColorVideoSlot] = []
        var clockIDs: [CMPersistentTrackID] = []
        let definition = TemplateCatalog.definition(for: request.project.templateID)

        for (index, placement) in request.project.placements.enumerated() {
            try cancellation.check()
            guard let source = request.project.assets.first(where: { $0.id == placement.sourceAssetID }),
                  let resolved = resolvedSources[placement.sourceAssetID] else {
                throw LivesCoreError.renderFailed("找不到素材文件")
            }
            let slot = try definition.rect(for: placement.slotID, canvas: wallpaper ? wallpaperContent.size : canvas)
            let target = wallpaper ? slot.offsetBy(dx: wallpaperContent.minX, dy: wallpaperContent.minY) : slot
            switch source.kind {
            case .photo:
                guard case .photo(let photoURL) = resolved else {
                    throw LivesCoreError.renderFailed("照片资源类型不匹配")
                }
                let image = try MediaColorPipeline.photo(photoURL, preserveHDR: videoHDR,
                    maxPixel: decodePixelBudget(target: target, crop: placement.crop, sourceWidth: source.width, sourceHeight: source.height))
                colorSlots.append(ColorVideoSlot(trackID: nil, image: image, transform: .identity, target: target, crop: placement.crop, rotation: placement.rotation))
            case .video, .livePhoto:
                // Keep the persisted kind and the platform-resolved resource
                // coupled. In particular, a Live Photo must never be rendered
                // through a video-only URL: that would lose its still resource
                // and make a later preview/save path look static.
                let motionURL: URL
                switch (source.kind, resolved) {
                case (.video, .video(let url)), (.livePhoto, .livePhoto(_, let url)):
                    motionURL = url
                case (.livePhoto, _):
                    throw LivesCoreError.invalidLivePhoto
                default:
                    throw LivesCoreError.renderFailed("动态资源类型不匹配")
                }
                let asset = AVURLAsset(url: motionURL)
                let loading = cancellation.onCancel { asset.cancelLoading() }
                defer { cancellation.removeHandler(loading) }
                guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first,
                      let compositionVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw LivesCoreError.renderFailed("无法读取视频轨道")
                }
                let sourceRange = try await sourceVideo.load(.timeRange)
                let sourceDuration = Int((sourceRange.duration.seconds * 1000).rounded(.down))
                let startMs = min(max(0, placement.startTimeMs), ProjectTimeline.maximumStartMs(sourceDurationMs: sourceDuration))
                let contentMs = ProjectValidation.contentDurationMs(sourceDurationMs: sourceDuration, startTimeMs: startMs, outputDurationMs: timelineDurationMs)
                guard contentMs > 0 else { throw LivesCoreError.sourceTooShort }
                let start = CMTime(value: CMTimeValue(startMs), timescale: 1000)
                let content = CMTime(value: CMTimeValue(contentMs), timescale: 1000)
                if wallpaper {
                    try insertWallpaperMotion(sourceVideo, into: compositionVideo, sourceRange: sourceRange,
                        offsetTicks: WallpaperExportProfile.sourceOffsetTicks(startTimeMs: startMs,
                            coverTimeMs: placement.coverTimeMs, durationMs: sourceDuration,
                            curve: request.project.motionCurve),
                        curve: request.project.motionCurve)
                } else {
                    try compositionVideo.insertTimeRange(CMTimeRange(start: start, duration: content), of: sourceVideo, at: .zero)
                    if contentMs < timelineDurationMs {
                        let frame = CMTime(value: 1, timescale: 30)
                        let repeated = CMTimeCompare(content, frame) < 0 ? content : frame
                        let repeatedStart = CMTimeAdd(start, CMTimeSubtract(content, repeated))
                        try compositionVideo.insertTimeRange(CMTimeRange(start: repeatedStart, duration: repeated), of: sourceVideo, at: content)
                        compositionVideo.scaleTimeRange(CMTimeRange(start: content, duration: repeated), toDuration: CMTime(value: CMTimeValue(timelineDurationMs - contentMs), timescale: 1000))
                    }

                }

                let transform = try await sourceVideo.load(.preferredTransform)
                colorSlots.append(ColorVideoSlot(trackID: compositionVideo.trackID, image: nil, transform: transform, target: target, crop: placement.crop, rotation: placement.rotation))

                if !wallpaper, request.audioPolicy == .perPlacement,
                   placement.audioEnabled,
                   let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first,
                   let compositionAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    let audioRange = try await sourceAudio.load(.timeRange)
                    let audioStart = CMTime(value: CMTimeValue(startMs), timescale: 1000)
                    let available = max(0, Int((audioRange.duration.seconds * 1000).rounded(.down)) - startMs)
                    let audioMs = min(contentMs, available)
                    if audioMs > 0 {
                        try compositionAudio.insertTimeRange(CMTimeRange(start: audioStart, duration: CMTime(value: CMTimeValue(audioMs), timescale: 1000)), of: sourceAudio, at: .zero)
                        audioTracks.append(compositionAudio)
                    }
                }
            }
            progressReporter.send(MediaProgress(stage: "preparing", fraction: 0.04 + 0.16 * Double(index + 1) / Double(request.project.placements.count)))
        }

        // 录屏的可变帧率可能让剪辑尾部少帧。所有输出都靠一条黑色时钟视频补齐
        // 完整时间轴，它只提供时钟、不进入最终画面，帧率由调用方按目标输出指定。
        var clockURL: URL?
        defer {
            if let clockURL { try? FileManager.default.removeItem(at: clockURL) }
        }
        do {
            let url = outputDirectory.appendingPathComponent(".clock-\(UUID().uuidString).mov")
            // 时钟轨道的采样节奏决定渲染帧边界（sourceTrackIDForFrameTiming），
            // 因此必须与输出的目标帧率一致：锁屏用 60 fps，普通实况仍是 30 fps。
            try await makeClockVideo(at: url, durationMs: encodedDurationMs,
                                     frameRate: wallpaper ? WallpaperExportProfile.frameRate : 30,
                                     cancellation: cancellation)
            clockURL = url
            let clockAsset = AVURLAsset(url: url)
            let loading = cancellation.onCancel { clockAsset.cancelLoading() }
            defer { cancellation.removeHandler(loading) }
            try cancellation.check()
            guard let clockTrack = try await clockAsset.loadTracks(withMediaType: .video).first,
                  let clockCompositionTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw LivesCoreError.renderFailed("无法建立时间轴时钟")
            }
            let duration = CMTime(value: CMTimeValue(encodedDurationMs), timescale: 1000)
            try clockCompositionTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: clockTrack, at: .zero)
            clockIDs.append(clockCompositionTrack.trackID)
        }

        let instruction = ColorVideoInstruction(
            duration: CMTime(value: CMTimeValue(encodedDurationMs), timescale: 1000), slots: colorSlots,
            clockIDs: clockIDs, watermark: try MediaColorPipeline.watermark(request.project.canvas.watermark, size: wallpaper ? wallpaperContent.size : canvas)?.transformed(by: CGAffineTransform(translationX: wallpaper ? wallpaperContent.minX : 0, y: wallpaper ? canvas.height - wallpaperContent.maxY : 0)), hdr: videoHDR, displayP3: wallpaper)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = ColorVideoCompositor.self
        videoComposition.instructions = [instruction]
        videoComposition.renderSize = canvas
        videoComposition.frameDuration = wallpaper
            ? CMTime(value: WallpaperExportProfile.frameDurationTicks, timescale: WallpaperExportProfile.timescale)
            : CMTime(value: 1, timescale: 30)
        videoComposition.sourceTrackIDForFrameTiming = clockIDs.first ?? kCMPersistentTrackID_Invalid
        videoComposition.colorPrimaries = videoHDR ? AVVideoColorPrimaries_ITU_R_2020 : AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = videoHDR ? AVVideoTransferFunction_ITU_R_2100_HLG : AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = videoHDR ? AVVideoYCbCrMatrix_ITU_R_2020 : AVVideoYCbCrMatrix_ITU_R_709_2

        if wallpaper {
            videoComposition.colorPrimaries = AVVideoColorPrimaries_P3_D65
            videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_601_4
            let pair = try await renderWallpaper(composition: composition, videoComposition: videoComposition,
                outputDirectory: outputDirectory, identifier: identifier, geometry: wallpaperGeometry, cancellation: cancellation,
                progress: { value in progressReporter.send(value) })
            completed = true
            return pair
        }

        let reader = try AVAssetReader(asset: composition)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: composition.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]
        )
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw LivesCoreError.renderFailed("无法建立视频合成任务") }
        reader.add(videoOutput)

        let audioReader: AVAssetReader?
        let audioOutput: AVAssetReaderAudioMixOutput?
        if audioTracks.isEmpty {
            audioReader = nil
            audioOutput = nil
        } else {
            // AVAssetReader only advances one interleaved output reliably on
            // iOS. Keep audio on its own reader so a long AAC track cannot
            // block the video reader while the writer is waiting for samples.
            let reader = try AVAssetReader(asset: composition)
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw LivesCoreError.renderFailed("无法建立音频合成任务") }
            reader.add(output)
            audioReader = reader
            audioOutput = output
        }

        try? FileManager.default.removeItem(at: videoURL)
        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
        let nativeCancellation = cancellation.onCancel {
            reader.cancelReading()
            audioReader?.cancelReading()
            writer.cancelWriting()
        }
        defer {
            cancellation.removeHandler(nativeCancellation)
            reader.cancelReading()
            audioReader?.cancelReading()
            if writer.status == .writing { writer.cancelWriting() }
        }
        let contentMetadata = AVMutableMetadataItem()
        contentMetadata.identifier = .quickTimeMetadataContentIdentifier
        contentMetadata.value = identifier as NSString
        writer.metadata = [contentMetadata]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: videoHDR ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: request.canvasSize.width,
            AVVideoHeightKey: request.canvasSize.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: videoComposition.colorPrimaries!,
                AVVideoTransferFunctionKey: videoComposition.colorTransferFunction!,
                AVVideoYCbCrMatrixKey: videoComposition.colorYCbCrMatrix!,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: adaptiveBitRate(size: request.canvasSize),
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoProfileLevelKey: videoHDR ? kVTProfileLevel_HEVC_Main10_AutoLevel as String : AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw LivesCoreError.renderFailed("系统无法使用 H.264 编码") }
        writer.add(videoInput)

        let audioInput: AVAssetWriterInput?
        if audioOutput == nil {
            audioInput = nil
        } else {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw LivesCoreError.renderFailed("系统无法写入音频") }
            writer.add(input)
            audioInput = input
        }

        let metadata = try makeStillImageMetadataInput()
        guard writer.canAdd(metadata.input) else { throw LivesCoreError.renderFailed("无法写入 Live Photo 时间信息") }
        writer.add(metadata.input)
        guard writer.startWriting(), reader.startReading(), audioReader?.startReading() ?? true else {
            throw writer.error ?? reader.error ?? LivesCoreError.renderFailed("无法开始生成视频")
        }
        writer.startSession(atSourceTime: .zero)
        let still = AVMutableMetadataItem()
        still.identifier = AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.still-image-time")
        still.dataType = "com.apple.metadata.datatype.int8"
        still.value = NSNumber(value: Int8(0))
        let coverMs = min(timelineDurationMs - 100, max(0, request.project.placements.map(\.coverTimeMs).min() ?? 1500))
        guard metadata.adaptor.append(AVTimedMetadataGroup(items: [still], timeRange: CMTimeRange(start: CMTime(value: CMTimeValue(coverMs), timescale: 1000), duration: CMTime(value: 1, timescale: 30)))) else {
            throw LivesCoreError.renderFailed("无法写入封面时间")
        }
        metadata.input.markAsFinished()

        let audioWritingTask: Task<Void, Error>?
        if let audioOutput, let audioInput {
            audioWritingTask = Task {
                defer { audioInput.markAsFinished() }
                while let sample = audioOutput.copyNextSampleBuffer() {
                    try cancellation.check()
                    while !audioInput.isReadyForMoreMediaData {
                        try cancellation.check()
                        guard writer.status == .writing else { throw writer.error ?? LivesCoreError.renderFailed("音频写入已停止") }
                        try await Task.sleep(nanoseconds: 2_000_000)
                    }
                    guard audioInput.append(sample) else {
                        throw writer.error ?? LivesCoreError.renderFailed("写入音频失败")
                    }
                }
            }
        } else {
            audioWritingTask = nil
        }
        defer { audioWritingTask?.cancel() }
        var frameCount = 0
        while let sample = videoOutput.copyNextSampleBuffer() {
            try cancellation.check()

            while !videoInput.isReadyForMoreMediaData {
                try cancellation.check()
                guard writer.status == .writing else { throw writer.error ?? LivesCoreError.renderFailed("视频写入已停止") }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard videoInput.append(sample) else { throw writer.error ?? LivesCoreError.renderFailed("写入视频帧失败") }
            frameCount += 1
            progressReporter.send(MediaProgress(stage: "rendering", fraction: min(0.88, 0.22 + Double(CMSampleBufferGetPresentationTimeStamp(sample).seconds / (Double(timelineDurationMs) / 1000)) * 0.66)))
        }
        videoInput.markAsFinished()
        try await audioWritingTask?.value
        if audioReader?.status == .failed {
            throw audioReader?.error ?? LivesCoreError.renderFailed("读取音频失败")
        }
        guard reader.status == .completed else { throw reader.error ?? LivesCoreError.renderFailed("视频解码未完成") }
        guard frameCount > 0 else { throw LivesCoreError.renderFailed("未生成视频帧") }
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(timelineDurationMs), timescale: 1000))
        progressReporter.send(MediaProgress(stage: "finalizing", fraction: 0.90))
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw writer.error ?? LivesCoreError.renderFailed("视频生成失败") }

        progressReporter.send(MediaProgress(stage: "cover", fraction: 0.94))
        try cancellation.check()
        try await writeColorCover(request: request, resolvedSources: resolvedSources, hdr: ranges.cover, to: photoURL, contentIdentifier: identifier, cancellation: cancellation)
        try cancellation.check()
        let pair = LivePhotoPair(photoURL: photoURL, videoURL: videoURL, contentIdentifier: identifier)
        progressReporter.send(MediaProgress(stage: "validating", fraction: 0.98))
        try await validate(pair: pair, expectedDurationMs: timelineDurationMs, cancellation: cancellation)
        try cancellation.check()
        completed = true
        progressReporter.send(MediaProgress(stage: "completed", fraction: 1))
        return LivePhotoPair(photoURL: photoURL, videoURL: videoURL, contentIdentifier: identifier)
    }

    public static func validate(pair: LivePhotoPair, expectedDurationMs: Int = 3000, cancellation: RenderCancellation? = nil) async throws {
        try cancellation?.check()
        guard FileManager.default.fileExists(atPath: pair.photoURL.path), FileManager.default.fileExists(atPath: pair.videoURL.path) else {
            throw LivesCoreError.renderFailed("Live Photo 配对文件不存在")
        }
        guard let source = CGImageSourceCreateWithURL(pair.photoURL as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw LivesCoreError.renderFailed("无法读取 Live Photo 封面")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let maker = props?[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any]
        guard maker?["17"] as? String == pair.contentIdentifier else { throw LivesCoreError.renderFailed("照片配对标识不匹配") }
        let asset = AVURLAsset(url: pair.videoURL)
        let loading = cancellation?.onCancel { asset.cancelLoading() }
        defer { if let loading { cancellation?.removeHandler(loading) } }
        let metadata = try await asset.load(.metadata)
        let matching = metadata.first { $0.identifier == .quickTimeMetadataContentIdentifier }
        let identifier = try await matching?.load(.stringValue)
        guard identifier == pair.contentIdentifier else { throw LivesCoreError.renderFailed("视频配对标识不匹配") }
        let loadedDuration = try? await asset.load(.duration)
        let loadedTracks = try? await asset.loadTracks(withMediaType: .video)
        guard let duration = loadedDuration, abs(duration.seconds - Double(expectedDurationMs) / 1000) <= 1.0 / 30.0 + 0.001,
              let tracks = loadedTracks, !tracks.isEmpty else {
            let actualDuration = loadedDuration?.seconds ?? -1
            let trackCount = loadedTracks?.count ?? -1
            throw LivesCoreError.renderFailed("Live Photo 视频轨道或时长无效 (duration=\(actualDuration), tracks=\(trackCount))")
        }
        let metadataTracks = try await asset.loadTracks(withMediaType: .metadata)
        var foundStillTime = false
        for track in metadataTracks {
            let reader = try AVAssetReader(asset: asset)
            let nativeCancellation = cancellation?.onCancel { reader.cancelReading() }
            defer {
                if let nativeCancellation { cancellation?.removeHandler(nativeCancellation) }
                reader.cancelReading()
            }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            guard reader.startReading() else { throw reader.error ?? LivesCoreError.invalidLivePhoto }
            while let group = adaptor.nextTimedMetadataGroup() {
                try cancellation?.check()
                if group.items.contains(where: { $0.identifier?.rawValue == "mdta/com.apple.quicktime.still-image-time" }) {
                    let time = group.timeRange.start.seconds
                    guard time.isFinite, time >= 0, time < duration.seconds else {
                        throw LivesCoreError.renderFailed("Live Photo 封面时间超出视频范围")
                    }
                    foundStillTime = true
                }
            }
            guard reader.status == .completed else { throw reader.error ?? LivesCoreError.invalidLivePhoto }
        }
        guard foundStillTime else { throw LivesCoreError.renderFailed("Live Photo 缺少封面时间标记") }
    }

    public static func outputDynamicRanges(project: ProjectDocument, resolvedSources: [UUID: ResolvedMediaSource], policy: RenderDynamicRange, cancellation: RenderCancellation? = nil) async throws -> (cover: Bool, video: Bool) {
        guard policy == .preserveHDR else { return (false, false) }
        var cover = false, video = false
        var photoRanges: [URL: Bool] = [:]
        var motionRanges: [URL: Bool] = [:]
        for placement in project.placements {
            try cancellation?.check()
            guard let asset = project.assets.first(where: { $0.id == placement.sourceAssetID }),
                  let source = resolvedSources[asset.id] else { continue }
            if let url = source.photoURL, photoRanges[url] == nil {
                photoRanges[url] = MediaColorPipeline.photoIsHDR(url)
            }
            let photoHDR = source.photoURL.flatMap { photoRanges[$0] } ?? false
            let motionHDR: Bool
            if let url = source.motionURL {
                if motionRanges[url] == nil {
                    motionRanges[url] = try await MediaColorPipeline.videoIsHDR(url, cancellation: cancellation)
                }
                motionHDR = motionRanges[url] ?? false
            } else { motionHDR = false }
            cover = cover || (placement.usesOriginalPhoto(asset: asset) ? photoHDR : motionHDR)
            video = video || (asset.kind == .photo ? photoHDR : motionHDR)
        }
        return (cover, video)
    }

    private static func writeColorCover(request: RenderRequest, resolvedSources: [UUID: ResolvedMediaSource], hdr: Bool, to url: URL, contentIdentifier: String, cancellation: RenderCancellation) async throws {
        let size = CGSize(width: request.coverSize.width, height: request.coverSize.height)
        let bounds = CGRect(origin: .zero, size: size)
        let definition = TemplateCatalog.definition(for: request.project.templateID)
        func compose(preserveHDR: Bool) async throws -> CIImage {
            var result = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.05)).cropped(to: bounds)
            let context = MediaColorPipeline.context()
            for placement in request.project.placements {
                try cancellation.check()
                guard let asset = request.project.assets.first(where: { $0.id == placement.sourceAssetID }),
                      let source = resolvedSources[asset.id] else { throw LivesCoreError.renderFailed("找不到封面素材") }
                let target = try definition.rect(for: placement.slotID, canvas: size)
                let image: CIImage
                let sourceWidth = placement.isTransposed ? asset.height : asset.width
                let sourceHeight = placement.isTransposed ? asset.width : asset.height
                if placement.usesOriginalPhoto(asset: asset), let url = source.photoURL {
                    image = try MediaColorPipeline.photo(url, preserveHDR: preserveHDR, maxPixel: decodePixelBudget(target: target, crop: placement.crop, sourceWidth: sourceWidth, sourceHeight: sourceHeight))
                } else if let url = source.motionURL {
                    image = try await MediaColorPipeline.frame(url, timeMs: min(max(0, asset.durationMs - 34), placement.startTimeMs + placement.coverTimeMs), preserveHDR: preserveHDR, cancellation: cancellation)
                } else { throw LivesCoreError.renderFailed("封面来源无效") }
                let rotated = MediaColorPipeline.rotateImage(image, degrees: placement.rotation)
                let fitted = MediaColorPipeline.fitted(rotated, target: target, crop: placement.crop, canvasHeight: size.height)
                // 逐格实体化，释放原始文件解码图，避免整组高像素源同时驻留。
                guard let tile = context.createCGImage(fitted, from: fitted.extent, format: preserveHDR ? .RGBAh : .RGBA8,
                                                       colorSpace: preserveHDR ? MediaColorPipeline.workingSpace : MediaColorPipeline.sdrSpace) else {
                    throw LivesCoreError.renderFailed("内存不足，无法生成封面画格")
                }
                result = CIImage(cgImage: tile).transformed(by: CGAffineTransform(translationX: fitted.extent.minX, y: fitted.extent.minY)).composited(over: result)
            }
            if let watermark = try MediaColorPipeline.watermark(request.project.canvas.watermark, size: size) { result = watermark.composited(over: result) }
            return result
        }
        let sdr = try await compose(preserveHDR: false)
        let output = hdr ? try await compose(preserveHDR: true) : sdr
        try MediaColorPipeline.writeCover(output, sdrImage: sdr, hdr: hdr, to: url, identifier: contentIdentifier)
    }

    /// Decode only the pixels a rendered slot can use. A 48 MP camera photo
    /// should not be expanded to a full RGBA bitmap when the selected canvas
    /// is 1080p; crop scale is included so zoomed slots retain their detail.
    private static func decodePixelBudget(target: CGRect, crop: CropPosition, sourceWidth: Int, sourceHeight: Int) -> Int {
        let scale = min(3, max(1, crop.scale.isFinite ? crop.scale : 1))
        let width = CGFloat(max(1, sourceWidth)), height = CGFloat(max(1, sourceHeight))
        let required = max(width, height) * min(1, max(target.width / width, target.height / height) * scale)
        // 8192 keeps high-resolution desktop exports sharp while putting a
        // predictable upper bound on peak memory for phone renders.
        return max(64, min(8_192, Int(required.rounded(.up))))
    }

    private static func makeClockVideo(at url: URL, durationMs: Int, frameRate: Int32 = 30,
                                      cancellation: RenderCancellation) async throws {
        let side = 16
        let frameCount = (durationMs * Int(frameRate) + 999) / 1000
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let nativeCancellation = cancellation.onCancel { writer.cancelWriting() }
        defer {
            cancellation.removeHandler(nativeCancellation)
            if writer.status == .writing { writer.cancelWriting() }
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: side,
            AVVideoHeightKey: side,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 32_000],
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw LivesCoreError.renderFailed("无法建立照片时间轴") }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: side,
            kCVPixelBufferHeightKey as String: side,
        ])
        guard let buffer = makeBlackPixelBuffer(width: side, height: side), writer.startWriting() else {
            throw writer.error ?? LivesCoreError.renderFailed("无法开始建立照片时间轴")
        }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<frameCount {
            try cancellation.check()
            while !input.isReadyForMoreMediaData {
                try cancellation.check()
                guard writer.status == .writing else {
                    throw writer.error ?? LivesCoreError.renderFailed("照片时间轴写入已停止")
                }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            let time = CMTime(value: CMTimeValue(index), timescale: frameRate)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? LivesCoreError.renderFailed("无法写入照片时间轴")
            }
        }
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(durationMs), timescale: 1000))
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? LivesCoreError.renderFailed("照片时间轴生成失败")
        }
    }

    private static func makeBlackPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * stride + x * 4
                base[offset] = 0
                base[offset + 1] = 0
                base[offset + 2] = 0
                base[offset + 3] = 255
            }
        }
        return buffer
    }

    private static func watermarkText(for settings: WatermarkSettings) -> String? {
        switch settings.mode {
        case .lives: return "lives"
        case .custom:
            let value = settings.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "lives" : String(value.prefix(32))
        case .none: return nil
        }
    }

    // The watermark is a foreground mark, not part of the cropped source
    // image. The reference preview is 360pt wide, so 14pt becomes 42px on
    // the reference 1080px canvas. Scaling from the canvas width keeps the
    // exported mark at the same visual size when it is viewed in Photos,
    // regardless of the selected output tier or aspect ratio.
    private static let watermarkPreviewWidth: CGFloat = 360
    private static let watermarkPreviewFontSize: CGFloat = 14
    private static let watermarkPreviewBottomInset: CGFloat = 14
    private static let watermarkAppIcon: CGImage? = {
        guard let url = Bundle.module.url(forResource: "WatermarkAppIcon", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }()

    private static func watermarkScale(for canvas: CGSize) -> CGFloat {
        max(0.01, canvas.width / watermarkPreviewWidth)
    }

    private static func watermarkFontSize(for canvas: CGSize) -> CGFloat {
        return watermarkPreviewFontSize * watermarkScale(for: canvas)
    }

    static func drawWatermark(settings: WatermarkSettings, canvas: CGSize, context: CGContext) {
        guard let text = watermarkText(for: settings) else { return }
        let sizeScale = CGFloat(settings.effectiveSizeScale)
        let opacity = CGFloat(settings.effectiveOpacity)
        let fontSize = watermarkFontSize(for: canvas) * sizeScale
        // 调用 Apple 平台内置苹方，只导出文字像素，不分发字体文件。
        let font = CTFontCreateWithName(WatermarkTypography.fontName as CFString, fontSize, nil)
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font,
            NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: opacity),
            NSAttributedString.Key(rawValue: kCTKernAttributeName as String): WatermarkTypography.tracking(for: text, fontSize: fontSize),
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        var line = CTLineCreateWithAttributedString(attributed)
        var bounds = CTLineGetBoundsWithOptions(line, [])
        let scale = watermarkScale(for: canvas)
        let icon: CGImage?
        if settings.mode == .lives {
            icon = watermarkAppIcon
        } else if let data = settings.customIconData,
                  let source = CGImageSourceCreateWithData(data as CFData, nil) {
            icon = CGImageSourceCreateImageAtIndex(source, 0, nil)
        } else {
            icon = nil
        }
        let iconSize = 14 * scale * sizeScale
        let iconGap = icon == nil ? 0 : 4 * scale * sizeScale
        let iconSpacing = icon == nil ? 0 : iconSize + iconGap
        let availableTextWidth = max(1, canvas.width - 28 * scale - iconSpacing)
        if bounds.width > availableTextWidth {
            let fittedFontSize = fontSize * availableTextWidth / bounds.width
            attributes[NSAttributedString.Key(rawValue: kCTFontAttributeName as String)] =
                CTFontCreateCopyWithAttributes(font, fittedFontSize, nil, nil)
            attributes[NSAttributedString.Key(rawValue: kCTKernAttributeName as String)] =
                WatermarkTypography.tracking(for: text, fontSize: fittedFontSize)
            line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            bounds = CTLineGetBoundsWithOptions(line, [])
        }
        let groupWidth = bounds.width + iconSpacing
        let position = settings.position
        let groupX: CGFloat
        let opticalOffset: CGFloat = {
            guard icon != nil, position == .bottomCenter else { return 0 }
            return CGFloat(WatermarkLayout.opticalCenterOffset(
                textWidth: Double(bounds.width), iconSize: Double(iconSize), spacing: Double(iconGap), iconPosition: settings.iconPosition
            ))
        }()
        switch position {
        case .bottomLeft: groupX = 14 * scale
        case .bottomCenter: groupX = (canvas.width - groupWidth) / 2 + opticalOffset
        case .bottomRight: groupX = canvas.width - 14 * scale - groupWidth
        }
        let trailingIcon = settings.iconPosition == .trailing
        let x = groupX + (trailingIcon ? 0 : iconSpacing) - bounds.minX
        // Keep the bottom inset proportional to the same 14pt preview rule;
        // only the video content should respond to crop scaling.
        let y = watermarkPreviewBottomInset * scale - bounds.minY
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -WatermarkTypography.shadowOffset * scale),
            blur: WatermarkTypography.shadowRadius * scale,
            color: CGColor(gray: 0, alpha: WatermarkTypography.shadowOpacity * opacity)
        )
        if let icon {
            let rect = CGRect(x: trailingIcon ? groupX + groupWidth - iconSize : groupX,
                              y: watermarkPreviewBottomInset * scale + (bounds.height - iconSize) / 2,
                              width: iconSize, height: iconSize)
            context.saveGState()
            let radius = iconSize * settings.iconShape.cornerRatio
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
            context.setAlpha(opacity)
            context.draw(icon, in: rect)
            context.restoreGState()
        }
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func makeStillImageMetadataInput() throws -> (input: AVAssetWriterInput, adaptor: AVAssetWriterInputMetadataAdaptor) {
        let specification: [[String: Any]] = [[
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: "com.apple.metadata.datatype.int8",
        ]]
        var formatDescription: CMMetadataFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: specification as CFArray, formatDescriptionOut: &formatDescription)
        guard status == noErr, let formatDescription else { throw LivesCoreError.renderFailed("无法创建 Live Photo 元数据轨") }
        let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: formatDescription)
        return (input, AVAssetWriterInputMetadataAdaptor(assetWriterInput: input))
    }

    private static func adaptiveBitRate(size: CanvasSize) -> Int {
        max(4_000_000, min(48_000_000, Int(12_000_000 * Double(size.width * size.height) / Double(1080 * 1920))))
    }

    private static func codecName(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }
        return String(bytes: bytes, encoding: .macOSRoman) ?? "unknown"
    }
}
