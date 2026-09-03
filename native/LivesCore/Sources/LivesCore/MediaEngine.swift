import AVFoundation
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

public final class RenderCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public func check() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw LivesCoreError.renderFailed("生成已取消") }
        if Task.isCancelled { throw CancellationError() }
    }

    public var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value || Task.isCancelled
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
        return MediaInfo(durationMs: 0, width: width, height: height, codec: url.pathExtension.lowercased(), hasAudio: false)
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
        try ProjectValidation.validate(request.project)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let videoURL = outputDirectory.appendingPathComponent("paired.mov")
        let photoURL = outputDirectory.appendingPathComponent("cover.jpg")
        let identifier = UUID().uuidString

        progress(MediaProgress(stage: "preparing", fraction: 0.02))
        let composition = AVMutableComposition()
        let canvas = CGSize(width: request.canvasSize.width, height: request.canvasSize.height)
        var layers: [AVMutableVideoCompositionLayerInstruction] = []
        var audioTracks: [AVMutableCompositionTrack] = []
        var staticPhotoLayers: [CALayer] = []
        var hasMotionTrack = false
        var hasShortMotionTrack = false
        let definition = TemplateCatalog.definition(for: request.project.templateID)

        for (index, placement) in request.project.placements.enumerated() {
            try cancellation.check()
            guard let source = request.project.assets.first(where: { $0.id == placement.sourceAssetID }),
                  let resolved = resolvedSources[placement.sourceAssetID] else {
                throw LivesCoreError.renderFailed("找不到素材文件")
            }
            let target = try definition.rect(for: placement.slotID, canvas: canvas)
            switch source.kind {
            case .photo:
                guard case .photo(let photoURL) = resolved else {
                    throw LivesCoreError.renderFailed("照片资源类型不匹配")
                }
                let image = try loadOrientedImage(
                    url: photoURL,
                    maxPixelSize: decodePixelBudget(target: target, crop: placement.crop)
                )
                staticPhotoLayers.append(try makeStaticPhotoLayer(image: image, target: target, crop: placement.crop))
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
                guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first,
                      let compositionVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw LivesCoreError.renderFailed("无法读取视频轨道")
                }
                hasMotionTrack = true
                let sourceRange = try await sourceVideo.load(.timeRange)
                let sourceDuration = Int((sourceRange.duration.seconds * 1000).rounded(.down))
                let startMs = min(max(0, placement.startTimeMs), max(0, sourceDuration - ProjectValidation.outputDurationMs))
                let contentMs = ProjectValidation.contentDurationMs(sourceDurationMs: sourceDuration, startTimeMs: startMs)
                guard contentMs > 0 else { throw LivesCoreError.sourceTooShort }
                let start = CMTime(value: CMTimeValue(startMs), timescale: 1000)
                let content = CMTime(value: CMTimeValue(contentMs), timescale: 1000)
                try compositionVideo.insertTimeRange(CMTimeRange(start: start, duration: content), of: sourceVideo, at: .zero)
                if contentMs < ProjectValidation.outputDurationMs {
                    hasShortMotionTrack = true
                    let frame = CMTime(value: 1, timescale: 30)
                    let repeated = CMTimeCompare(content, frame) < 0 ? content : frame
                    let repeatedStart = CMTimeAdd(start, CMTimeSubtract(content, repeated))
                    try compositionVideo.insertTimeRange(CMTimeRange(start: repeatedStart, duration: repeated), of: sourceVideo, at: content)
                    compositionVideo.scaleTimeRange(CMTimeRange(start: content, duration: repeated), toDuration: CMTime(value: CMTimeValue(ProjectValidation.outputDurationMs - contentMs), timescale: 1000))
                }

                let natural = try await sourceVideo.load(.naturalSize)
                let transform = try await sourceVideo.load(.preferredTransform)
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideo)
                let aspectTransform = CropGeometry.videoTransform(naturalSize: natural, preferredTransform: transform, target: target, crop: placement.crop)
                layer.setTransform(aspectTransform, at: .zero)
                layer.setCropRectangle(target.applying(aspectTransform.inverted()), at: .zero)
                layers.append(layer)

                if request.audioPolicy == .perPlacement,
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
            progress(MediaProgress(stage: "preparing", fraction: 0.04 + 0.16 * Double(index + 1) / Double(request.project.placements.count)))
        }

        // AVAssetReaderVideoCompositionOutput needs a video clock even for an
        // all-photo project. The tiny black track supplies timing only; the
        // high-resolution photo layers below provide the visible pixels.
        var clockURL: URL?
        defer {
            if let clockURL { try? FileManager.default.removeItem(at: clockURL) }
        }
        let needsClockTrack = !hasMotionTrack || hasShortMotionTrack
        if needsClockTrack {
            let url = outputDirectory.appendingPathComponent(".clock-\(UUID().uuidString).mov")
            try await makeClockVideo(at: url)
            clockURL = url
            let clockAsset = AVURLAsset(url: url)
            guard let clockTrack = try await clockAsset.loadTracks(withMediaType: .video).first,
                  let clockCompositionTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw LivesCoreError.renderFailed("无法建立时间轴时钟")
            }
            let duration = CMTime(value: CMTimeValue(ProjectValidation.outputDurationMs), timescale: 1000)
            try clockCompositionTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: clockTrack, at: .zero)
            let clockLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: clockCompositionTrack)
            clockLayer.setTransform(CGAffineTransform(scaleX: canvas.width / 2, y: canvas.height / 2), at: .zero)
            layers.insert(clockLayer, at: 0)
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: CMTime(value: CMTimeValue(ProjectValidation.outputDurationMs), timescale: 1000))
        instruction.layerInstructions = layers.reversed()
        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [instruction]
        videoComposition.renderSize = canvas
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        if !staticPhotoLayers.isEmpty {
            let containingLayer = CALayer()
            containingLayer.frame = CGRect(origin: .zero, size: canvas)
            containingLayer.isGeometryFlipped = true
            let videoLayer = CALayer()
            videoLayer.frame = containingLayer.bounds
            containingLayer.addSublayer(videoLayer)
            staticPhotoLayers.forEach { containingLayer.addSublayer($0) }
            videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: videoLayer,
                in: containingLayer
            )
        }

        let reader = try AVAssetReader(asset: composition)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: composition.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
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
        let contentMetadata = AVMutableMetadataItem()
        contentMetadata.identifier = .quickTimeMetadataContentIdentifier
        contentMetadata.value = identifier as NSString
        writer.metadata = [contentMetadata]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: request.canvasSize.width,
            AVVideoHeightKey: request.canvasSize.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: adaptiveBitRate(size: request.canvasSize),
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
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
        let coverMs = request.project.placements.map(\.coverTimeMs).min() ?? 1500
        guard metadata.adaptor.append(AVTimedMetadataGroup(items: [still], timeRange: CMTimeRange(start: CMTime(value: CMTimeValue(coverMs), timescale: 1000), duration: CMTime(value: 1, timescale: 30)))) else {
            throw LivesCoreError.renderFailed("无法写入封面时间")
        }
        metadata.input.markAsFinished()

        let audioWritingTask: Task<Void, Error>?
        if let audioOutput, let audioInput {
            audioWritingTask = Task {
                progress(MediaProgress(stage: "audioWriting", fraction: 0.88))
                while let sample = audioOutput.copyNextSampleBuffer() {
                    try cancellation.check()
                    while !audioInput.isReadyForMoreMediaData {
                        try await Task.sleep(nanoseconds: 2_000_000)
                    }
                    guard audioInput.append(sample) else {
                        throw writer.error ?? LivesCoreError.renderFailed("写入音频失败")
                    }
                }
                audioInput.markAsFinished()
                progress(MediaProgress(stage: "audioWriting", fraction: 0.96))
            }
        } else {
            audioWritingTask = nil
        }
        var frameCount = 0
        while let sample = videoOutput.copyNextSampleBuffer() {
            try cancellation.check()
            if let imageBuffer = CMSampleBufferGetImageBuffer(sample) {
                drawWatermark(settings: request.project.canvas.watermark, into: imageBuffer)
            }
            while !videoInput.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard videoInput.append(sample) else { throw writer.error ?? LivesCoreError.renderFailed("写入视频帧失败") }
            frameCount += 1
            progress(MediaProgress(stage: "rendering", fraction: min(0.88, 0.22 + Double(CMSampleBufferGetPresentationTimeStamp(sample).seconds / 3.0) * 0.66)))
        }
        videoInput.markAsFinished()
        try await audioWritingTask?.value
        if audioReader?.status == .failed {
            throw audioReader?.error ?? LivesCoreError.renderFailed("读取音频失败")
        }
        guard frameCount > 0 else { throw LivesCoreError.renderFailed("未生成视频帧") }
        progress(MediaProgress(stage: "finalizing", fraction: 0.98))
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw writer.error ?? LivesCoreError.renderFailed("视频生成失败") }

        progress(MediaProgress(stage: "cover", fraction: 0.9))
        try cancellation.check()
        try writeCover(request: request, resolvedSources: resolvedSources, to: photoURL, contentIdentifier: identifier)
        progress(MediaProgress(stage: "completed", fraction: 1))
        return LivePhotoPair(photoURL: photoURL, videoURL: videoURL, contentIdentifier: identifier)
    }

    public static func validate(pair: LivePhotoPair) async throws {
        guard FileManager.default.fileExists(atPath: pair.photoURL.path), FileManager.default.fileExists(atPath: pair.videoURL.path) else {
            throw LivesCoreError.renderFailed("Live Photo 配对文件不存在")
        }
        guard let source = CGImageSourceCreateWithURL(pair.photoURL as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw LivesCoreError.renderFailed("无法读取 Live Photo 封面")
        }
        let asset = AVURLAsset(url: pair.videoURL)
        let loadedDuration = try? await asset.load(.duration)
        let loadedTracks = try? await asset.loadTracks(withMediaType: .video)
        guard let duration = loadedDuration, abs(duration.seconds - 3.0) < 0.12,
              let tracks = loadedTracks, !tracks.isEmpty else {
            let actualDuration = loadedDuration?.seconds ?? -1
            let trackCount = loadedTracks?.count ?? -1
            throw LivesCoreError.renderFailed("Live Photo 视频轨道或时长无效 (duration=\(actualDuration), tracks=\(trackCount))")
        }
    }

    private static func writeCover(
        request: RenderRequest,
        resolvedSources: [UUID: ResolvedMediaSource],
        to url: URL,
        contentIdentifier: String
    ) throws {
        let width = request.canvasSize.width
        let height = request.canvasSize.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw LivesCoreError.renderFailed("无法创建封面画布")
        }
        context.setFillColor(CGColor(gray: 0.05, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let definition = TemplateCatalog.definition(for: request.project.templateID)
        for placement in request.project.placements {
            guard let sourceAsset = request.project.assets.first(where: { $0.id == placement.sourceAssetID }),
                  let resolved = resolvedSources[placement.sourceAssetID] else { continue }
            let target = try definition.rect(for: placement.slotID, canvas: CGSize(width: width, height: height))
            let image: CGImage
            switch sourceAsset.kind {
            case .photo:
                guard case .photo(let photoURL) = resolved else { continue }
                image = try loadOrientedImage(
                    url: photoURL,
                    maxPixelSize: decodePixelBudget(target: target, crop: placement.crop)
                )
            case .livePhoto:
                guard case .livePhoto(let photoURL, let pairedVideoURL) = resolved else {
                    throw LivesCoreError.invalidLivePhoto
                }
                if let nativeTime = sourceAsset.nativeCoverTimeMs,
                   abs(nativeTime - placement.coverTimeMs) <= 100 {
                    image = try loadOrientedImage(url: photoURL, maxPixelSize: decodePixelBudget(target: target, crop: placement.crop))
                } else {
                    let asset = AVURLAsset(url: pairedVideoURL)
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.requestedTimeToleranceBefore = .zero
                    generator.requestedTimeToleranceAfter = .zero
                    let source = CMTime(value: CMTimeValue(placement.startTimeMs + placement.coverTimeMs), timescale: 1000)
                    image = try generator.copyCGImage(at: source, actualTime: nil)
                }
            case .video:
                guard let motionURL = resolved.motionURL else { continue }
                let asset = AVURLAsset(url: motionURL)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                let source = CMTime(value: CMTimeValue(placement.startTimeMs + placement.coverTimeMs), timescale: 1000)
                image = try generator.copyCGImage(at: source, actualTime: nil)
            }
            drawAspectFill(image: image, in: target, crop: placement.crop, context: context, canvasHeight: CGFloat(height))
        }
        drawWatermark(settings: request.project.canvas.watermark, canvas: CGSize(width: width, height: height), context: context)
        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw LivesCoreError.renderFailed("无法生成 Live Photo 封面")
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyMakerAppleDictionary: ["17": contentIdentifier],
            kCGImagePropertyOrientation: 1,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw LivesCoreError.renderFailed("无法写入封面配对信息") }
    }

    private static func loadOrientedImage(url: URL, maxPixelSize: Int? = nil) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            throw LivesCoreError.renderFailed("无法读取照片")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixelSize ?? max(width, height)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw LivesCoreError.renderFailed("无法解码照片")
        }
        return image
    }

    /// Decode only the pixels a rendered slot can use. A 48 MP camera photo
    /// should not be expanded to a full RGBA bitmap when the selected canvas
    /// is 1080p; crop scale is included so zoomed slots retain their detail.
    private static func decodePixelBudget(target: CGRect, crop: CropPosition) -> Int {
        let scale = min(3, max(1, crop.scale.isFinite ? crop.scale : 1))
        let required = max(target.width, target.height) * scale
        // 8192 keeps high-resolution desktop exports sharp while putting a
        // predictable upper bound on peak memory for phone renders.
        return max(64, min(8_192, Int(required.rounded(.up))))
    }

    private static func makeStaticPhotoLayer(image: CGImage, target: CGRect, crop: CropPosition) throws -> CALayer {
        let width = max(1, Int(target.width.rounded(.up)))
        let height = max(1, Int(target.height.rounded(.up)))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw LivesCoreError.renderFailed("无法创建照片画格")
        }
        context.setFillColor(CGColor(gray: 0.05, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let localTarget = CGRect(x: 0, y: 0, width: width, height: height)
        drawAspectFill(image: image, in: localTarget, crop: crop, context: context, canvasHeight: CGFloat(height))
        guard let rendered = context.makeImage() else {
            throw LivesCoreError.renderFailed("无法生成照片画格")
        }
        let layer = CALayer()
        layer.frame = target
        layer.contents = rendered
        layer.contentsGravity = .resize
        layer.masksToBounds = true
        return layer
    }

    private static func makeClockVideo(at url: URL) async throws {
        let side = 16
        let frameCount = 90
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
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
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            let time = CMTime(value: CMTimeValue(index), timescale: 30)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? LivesCoreError.renderFailed("无法写入照片时间轴")
            }
        }
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

    private static func drawAspectFill(image: CGImage, in target: CGRect, crop: CropPosition, context: CGContext, canvasHeight: CGFloat) {
        let imageSize = CGSize(width: image.width, height: image.height)
        let drawn = CropGeometry.drawnRect(source: imageSize, target: target, crop: crop)
        // CGContext is bottom-up; clip each slot before drawing its aspect-fill source.
        let clip = CGRect(x: target.minX, y: canvasHeight - target.maxY, width: target.width, height: target.height)
        let rect = CGRect(x: drawn.minX, y: canvasHeight - drawn.maxY, width: drawn.width, height: drawn.height)
        context.saveGState()
        context.clip(to: clip)
        context.draw(image, in: rect)
        context.restoreGState()
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
    private static let watermarkFontRegistration: Void = {
        guard let url = Bundle.module.url(forResource: "Caveat-Variable", withExtension: "ttf") else { return }
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    private static func watermarkScale(for canvas: CGSize) -> CGFloat {
        max(0.01, canvas.width / watermarkPreviewWidth)
    }

    private static func watermarkFontSize(for canvas: CGSize) -> CGFloat {
        _ = watermarkFontRegistration
        return watermarkPreviewFontSize * watermarkScale(for: canvas)
    }

    private static func drawWatermark(settings: WatermarkSettings, canvas: CGSize, context: CGContext) {
        guard let text = watermarkText(for: settings) else { return }
        let fontSize = watermarkFontSize(for: canvas)
        // Caveat is distributed under the SIL Open Font License and has a
        // handwritten, naturally slanted shape suitable for the lives mark.
        var italicMatrix = CGAffineTransform(a: 1, b: 0, c: -0.12, d: 1, tx: 0, ty: 0)
        let font = CTFontCreateWithName("Caveat-Regular" as CFString, fontSize, &italicMatrix)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font,
            NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: CGFloat(settings.opacity)),
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        let x = (canvas.width - bounds.width) / 2 - bounds.minX
        let scale = watermarkScale(for: canvas)
        // Keep the bottom inset proportional to the same 14pt preview rule;
        // only the video content should respond to crop scaling.
        let y = watermarkPreviewBottomInset * scale - bounds.minY
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -scale),
            blur: 3 * scale,
            color: CGColor(gray: 0, alpha: 0.45)
        )
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func drawWatermark(settings: WatermarkSettings, into pixelBuffer: CVPixelBuffer) {
        guard watermarkText(for: settings) != nil else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return }
        drawWatermark(settings: settings, canvas: CGSize(width: width, height: height), context: context)
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
