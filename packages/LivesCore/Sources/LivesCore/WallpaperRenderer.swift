import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

extension LivesMediaEngine {
    static func insertWallpaperMotion(_ source: AVAssetTrack, into target: AVMutableCompositionTrack,
                                      sourceRange: CMTimeRange, offsetTicks: Int64,
                                      curve: WallpaperMotionCurve = .uniform) throws {
        let scale = WallpaperExportProfile.timescale
        // Build the selected editor window first, then map it onto the fixed
        // wallpaper movie. This keeps the selected cover frame aligned while
        // preserving short-source boundary-frame extension.
        let timelineDuration = CMTime(value: Int64(WallpaperExportProfile.editDurationMs) * Int64(scale) / 1000,
                                       timescale: scale)
        let offset = CMTime(value: offsetTicks, timescale: scale)
        let sourceDuration = sourceRange.duration
        // 补边定格只取源素材上的一小段画面，1/30 秒是名义帧长，与输出帧率无关。
        let frame = CMTimeMinimum(CMTime(value: 1, timescale: 30), sourceDuration)
        let leading = CMTimeMinimum(timelineDuration, CMTimeMaximum(.zero, CMTimeMultiply(offset, multiplier: -1)))
        if leading > .zero {
            try target.insertTimeRange(CMTimeRange(start: sourceRange.start, duration: frame), of: source, at: .zero)
            target.scaleTimeRange(CMTimeRange(start: .zero, duration: frame), toDuration: leading)
        }
        let start = CMTimeMaximum(.zero, offset)
        let content = CMTimeMinimum(CMTimeSubtract(timelineDuration, leading), CMTimeSubtract(sourceDuration, start))
        if content > .zero {
            try target.insertTimeRange(CMTimeRange(start: CMTimeAdd(sourceRange.start, start), duration: content),
                                       of: source, at: leading)
        }
        let end = CMTimeAdd(leading, CMTimeMaximum(.zero, content))
        if end < timelineDuration {
            try target.insertTimeRange(CMTimeRange(start: CMTimeSubtract(sourceRange.end, frame), duration: frame),
                                       of: source, at: end)
            target.scaleTimeRange(CMTimeRange(start: end, duration: frame), toDuration: CMTimeSubtract(timelineDuration, end))
        }
        // Composition insertion can carry a one-nanosecond rounding residue
        // from the source track's native timescale. Normalize the assembled
        // window to the exact editor duration so every curve sample below lands
        // on an exact rational time.
        let editDuration = CMTime(value: Int64(WallpaperExportProfile.editDurationMs), timescale: 1000)
        if target.timeRange.duration > .zero {
            target.scaleTimeRange(CMTimeRange(start: .zero, duration: target.timeRange.duration), toDuration: editDuration)
        }
        if CMTimeCompare(target.timeRange.duration, editDuration) > 0 {
            target.removeTimeRange(CMTimeRange(start: editDuration,
                                                duration: CMTimeSubtract(target.timeRange.duration, editDuration)))
        }
        // Give every output frame its own segment of the editor window, so the
        // curve only changes which source content a frame shows. Frame count and
        // total duration stay fixed at the profile values for all four curves.
        let editTicks = Int64(WallpaperExportProfile.editDurationMs) * Int64(scale) / 1000
        let outputFrame = CMTime(value: WallpaperExportProfile.frameDurationTicks, timescale: scale)
        var outputStart = CMTime.zero
        for index in 0..<WallpaperExportProfile.frameCount {
            let from = curve.sourceTicks(atOutputTicks: WallpaperExportProfile.frameTicks[index], editTicks: editTicks)
            let to = curve.sourceTicks(atOutputTicks: WallpaperExportProfile.frameTicks[index] + WallpaperExportProfile.frameDurationTicks,
                                       editTicks: editTicks)
            target.scaleTimeRange(CMTimeRange(start: outputStart, duration: CMTime(value: max(1, to - from), timescale: scale)),
                                  toDuration: outputFrame)
            outputStart = CMTimeAdd(outputStart, outputFrame)
        }
        // Guard against a rounding residue from the per-frame splits.
        let exactOutputDuration = CMTime(value: Int64(WallpaperExportProfile.outputDurationMs), timescale: 1000)
        if CMTimeCompare(target.timeRange.duration, exactOutputDuration) > 0 {
            target.removeTimeRange(CMTimeRange(start: exactOutputDuration,
                                                duration: CMTimeSubtract(target.timeRange.duration, exactOutputDuration)))
        }
    }

    static func renderWallpaper(composition: AVComposition, videoComposition: AVVideoComposition,
                                outputDirectory: URL, identifier: String, geometry: WallpaperOutputGeometry, cancellation: RenderCancellation,
                                progress: @escaping @Sendable (MediaProgress) -> Void) async throws -> LivePhotoPair {
        let encodedURL = outputDirectory.appendingPathComponent(".wallpaper-encoded.mov")
        let videoURL = outputDirectory.appendingPathComponent("paired.mov")
        let photoURL = outputDirectory.appendingPathComponent("cover.heic")
        var complete = false
        defer {
            try? FileManager.default.removeItem(at: encodedURL)
            if !complete {
                try? FileManager.default.removeItem(at: videoURL)
                try? FileManager.default.removeItem(at: photoURL)
            }
        }
        let writer = try AVAssetWriter(outputURL: encodedURL, fileType: .mov)
        writer.movieTimeScale = WallpaperExportProfile.timescale
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: geometry.encoded.width, AVVideoHeightKey: geometry.encoded.height,
            AVVideoCleanApertureKey: [AVVideoCleanApertureWidthKey: geometry.encoded.width, AVVideoCleanApertureHeightKey: geometry.encoded.height,
                AVVideoCleanApertureHorizontalOffsetKey: 0, AVVideoCleanApertureVerticalOffsetKey: 0],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_601_4],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000,
                AVVideoExpectedSourceFrameRateKey: WallpaperExportProfile.frameRate, AVVideoAllowFrameReorderingKey: false]
        ])
        input.transform = geometry.rotation
        input.mediaTimeScale = WallpaperExportProfile.timescale
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: geometry.encoded.width, kCVPixelBufferHeightKey as String: geometry.encoded.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        guard writer.canAdd(input) else { throw LivesCoreError.renderFailed("无法建立动态锁屏编码器") }
        writer.add(input)
        let reader = try AVAssetReader(asset: composition)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: composition.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw LivesCoreError.renderFailed("无法建立动态锁屏解码器") }
        reader.add(videoOutput)
        let nativeCancellation = cancellation.onCancel {
            reader.cancelReading()
            writer.cancelWriting()
        }
        defer {
            cancellation.removeHandler(nativeCancellation)
            reader.cancelReading()
            if writer.status == .writing { writer.cancelWriting() }
        }
        try cancellation.check()
        let writerStarted = writer.startWriting()
        let readerStarted = reader.startReading()
        guard writerStarted, readerStarted else {
            throw writer.error ?? reader.error ?? LivesCoreError.invalidLivePhoto
        }
        writer.startSession(atSourceTime: .zero)
        let context = MediaColorPipeline.context()
        var index = 0
        while let sample = videoOutput.copyNextSampleBuffer() {
            try cancellation.check()
            while !input.isReadyForMoreMediaData {
                try cancellation.check()
                guard writer.status == .writing else { throw writer.error ?? LivesCoreError.invalidLivePhoto }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard index < WallpaperExportProfile.frameCount,
                  let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else {
                throw LivesCoreError.renderFailed("动态锁屏合成帧数量无效")
            }
            let time = CMTime(value: WallpaperExportProfile.frameTicks[index], timescale: WallpaperExportProfile.timescale)
            try autoreleasepool {
                try cancellation.check()
                var buffer: CVPixelBuffer?
                guard let pool = adaptor.pixelBufferPool,
                      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
                    throw LivesCoreError.renderFailed("内存不足，无法生成动态锁屏帧")
                }
                let image = CIImage(cvPixelBuffer: sourceBuffer).oriented(.left)
                let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                context.render(normalized, to: buffer, bounds: CGRect(x: 0, y: 0, width: geometry.encoded.width, height: geometry.encoded.height), colorSpace: MediaColorPipeline.sdrSpace)
                guard adaptor.append(buffer, withPresentationTime: time) else { throw writer.error ?? LivesCoreError.invalidLivePhoto }
            }
            index += 1
            progress(MediaProgress(stage: "rendering", fraction: 0.2 + 0.65 * Double(index) / Double(WallpaperExportProfile.frameCount)))
        }
        guard reader.status == .completed, index == WallpaperExportProfile.frameCount else {
            throw reader.error ?? LivesCoreError.renderFailed("动态锁屏解码未生成完整帧")
        }
        writer.endSession(atSourceTime: WallpaperExportProfile.outputDuration)
        input.markAsFinished()
        progress(MediaProgress(stage: "finalizing", fraction: 0.86))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? LivesCoreError.invalidLivePhoto }
        try cancellation.check()
        try autoreleasepool {
            let output = try WallpaperMOV.mux(Data(contentsOf: encodedURL, options: .mappedIfSafe), id: identifier, size: geometry.encoded)
            try WallpaperMOV.validate(output, id: identifier, size: geometry.encoded)
            try output.write(to: videoURL, options: .atomic)
        }
        progress(MediaProgress(stage: "packaging", fraction: 0.88))
        try await writeWallpaperCover(videoURL: videoURL, photoURL: photoURL, identifier: identifier, geometry: geometry, cancellation: cancellation)
        progress(MediaProgress(stage: "cover", fraction: 0.94))
        let pair = LivePhotoPair(photoURL: photoURL, videoURL: videoURL, contentIdentifier: identifier)
        progress(MediaProgress(stage: "validating", fraction: 0.98))
        try await validateWallpaper(pair, geometry: geometry, cancellation: cancellation)
        try cancellation.check()
        complete = true
        progress(MediaProgress(stage: "completed", fraction: 1))
        return pair
    }

    private static func writeWallpaperCover(videoURL: URL, photoURL: URL, identifier: String, geometry: WallpaperOutputGeometry, cancellation: RenderCancellation) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        let nativeCancellation = cancellation.onCancel { generator.cancelAllCGImageGeneration() }
        defer { cancellation.removeHandler(nativeCancellation) }
        try cancellation.check()
        generator.appliesPreferredTrackTransform = false
        generator.apertureMode = .encodedPixels
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(value: WallpaperExportProfile.coverTick, timescale: WallpaperExportProfile.timescale)
        let frame = try await generator.image(at: time)
        guard CMTimeCompare(frame.actualTime, time) == 0 else { throw LivesCoreError.invalidLivePhoto }
        try cancellation.check()
        try autoreleasepool {
            let image = CIImage(cgImage: frame.image).transformed(by: CGAffineTransform(scaleX: Double(geometry.encoded.width) / Double(frame.image.width), y: Double(geometry.encoded.height) / Double(frame.image.height)))
            guard let cover = MediaColorPipeline.context().createCGImage(image, from: CGRect(x: 0, y: 0, width: geometry.encoded.width, height: geometry.encoded.height), format: .RGBA8, colorSpace: MediaColorPipeline.sdrSpace),
                  let destination = CGImageDestinationCreateWithURL(photoURL as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
                throw LivesCoreError.renderFailed("无法生成动态锁屏封面")
            }
            CGImageDestinationAddImage(destination, cover, [kCGImagePropertyOrientation: 6,
                kCGImagePropertyMakerAppleDictionary: ["17": identifier], kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw LivesCoreError.renderFailed("动态锁屏封面写入失败") }
        }
    }

    public static func validate(_ pair: LivePhotoPair, request: RenderRequest) async throws {
        if request.purpose == .lockScreenWallpaper { try await validateWallpaper(pair, geometry: WallpaperOutputGeometry(canvas: CanvasGeometry.size(for: request.project.canvas))) }
        else { try await validate(pair: pair, expectedDurationMs: request.project.outputDurationMs) }
    }

    static func validateWallpaper(_ pair: LivePhotoPair, geometry: WallpaperOutputGeometry, cancellation: RenderCancellation? = nil) async throws {
        try await validate(pair: pair, expectedDurationMs: WallpaperExportProfile.outputDurationMs, cancellation: cancellation)
        try autoreleasepool { try WallpaperMOV.validate(Data(contentsOf: pair.videoURL, options: .mappedIfSafe), id: pair.contentIdentifier, size: geometry.encoded) }
        guard let source = CGImageSourceCreateWithURL(pair.photoURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              props[kCGImagePropertyPixelWidth as String] as? Int == geometry.encoded.width,
              props[kCGImagePropertyPixelHeight as String] as? Int == geometry.encoded.height,
              props[kCGImagePropertyOrientation as String] as? Int == 6,
              CGImageSourceGetType(source) as String? == UTType.heic.identifier else { throw WallpaperMOV.fail() }
        let asset = AVURLAsset(url: pair.videoURL)
        let loading = cancellation?.onCancel { asset.cancelLoading() }
        defer { if let loading { cancellation?.removeHandler(loading) } }
        try cancellation?.check()
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              try await asset.loadTracks(withMediaType: .audio).isEmpty,
              CMTimeCompare(try await asset.load(.duration), WallpaperExportProfile.outputDuration) == 0,
              try await track.load(.preferredTransform) == geometry.rotation else { throw WallpaperMOV.fail() }
        let descriptions = try await track.load(.formatDescriptions)
        guard let format = descriptions.first, CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC,
              CMVideoFormatDescriptionGetDimensions(format).width == geometry.encoded.width,
              CMVideoFormatDescriptionGetDimensions(format).height == geometry.encoded.height,
              CMVideoFormatDescriptionGetCleanAperture(format, originIsAtTopLeft: true) == CGRect(x: 0, y: 0, width: geometry.encoded.width, height: geometry.encoded.height) else { throw WallpaperMOV.fail() }
    }
}
