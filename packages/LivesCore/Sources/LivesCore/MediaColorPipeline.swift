import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

/// Coordinates cooperative task cancellation and a wall-clock deadline with
/// native reader cancellation. The caller still waits for native work to
/// return before releasing its resource permit.
final class PreviewReaderCancellationController: @unchecked Sendable {
    enum Failure: Error, Equatable { case timedOut }

    private enum StopReason { case cancelled, timedOut }
    private let lock = NSLock()
    private var cancelNative: (() -> Void)?
    private var timer: Task<Void, Never>?
    private var reason: StopReason?
    private var finished = false

    init(timeout: Duration?) {
        if let timeout {
            timer = Task.detached(priority: .utility) { [weak self] in
                do { try await Task.sleep(for: timeout) }
                catch { return }
                self?.stop(.timedOut)
            }
        }
    }

    func install(cancelNative: @escaping () -> Void) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        self.cancelNative = cancelNative
        let shouldCancel = reason != nil
        lock.unlock()
        if shouldCancel { cancelNative() }
    }

    func cancel() {
        stop(.cancelled)
    }

    private func stop(_ requestedReason: StopReason) {
        lock.lock()
        guard !finished, reason == nil else {
            lock.unlock()
            return
        }
        reason = requestedReason
        let cancel = cancelNative
        lock.unlock()
        cancel?()
    }

    func check() throws {
        lock.lock()
        let currentReason = reason
        lock.unlock()
        switch currentReason {
        case .timedOut: throw Failure.timedOut
        case .cancelled: throw CancellationError()
        case nil: try Task.checkCancellation()
        }
    }

    func finish() {
        lock.lock()
        finished = true
        timer?.cancel()
        timer = nil
        cancelNative = nil
        lock.unlock()
    }

    deinit { timer?.cancel() }
}

/// 封面和视频共用线性合成；UI 图层的白色始终为 SDR 参考白。
public enum MediaColorPipeline {
    static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    // 静态照片保留 Display P3 色域；SDR 视频仍由合成器明确输出 Rec.709。
    static let sdrSpace = CGColorSpace(name: CGColorSpace.displayP3)!
    static let hdrSpace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
    static func context() -> CIContext {
        CIContext(options: [.workingColorSpace: workingSpace, .workingFormat: CIFormat.RGBAh,
                            .cacheIntermediates: false])
    }

    public static func photoIsHDR(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil { return true }
        if #available(iOS 18, macOS 15, *),
           CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil { return true }
        if let space = CIImage(contentsOf: url)?.colorSpace, CGColorSpaceUsesITUR_2100TF(space) { return true }
        return false
    }

    public static func videoIsHDR(_ url: URL, cancellation: RenderCancellation? = nil) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        let loading = cancellation?.onCancel { asset.cancelLoading() }
        defer { if let loading { cancellation?.removeHandler(loading) } }
        try cancellation?.check()
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return false }
        let descriptions = try await track.load(.formatDescriptions)
        return descriptions.contains { description in
            let value = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            return value == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String || value == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
        }
    }

    public static func photo(_ url: URL, preserveHDR: Bool, maxPixel: Int) throws -> CIImage {
        var options: [CIImageOption: Any] = [.applyOrientationProperty: true, .toneMapHDRtoSDR: !preserveHDR]
        if #available(iOS 17, macOS 14, *) { options[.expandToHDR] = preserveHDR }
        guard let image = CIImage(contentsOf: url, options: options), !image.extent.isEmpty else {
            throw LivesCoreError.renderFailed("无法解码照片")
        }
        let scale = min(1, CGFloat(max(64, maxPixel)) / max(image.extent.width, image.extent.height))
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    /// AVAssetReader 保留 10 位源帧；iOS 17 也不经过默认 SDR 的 ImageGenerator。
    public static func frame(_ url: URL, timeMs: Int, preserveHDR: Bool, cancellation: RenderCancellation? = nil) async throws -> CIImage {
        let asset = AVURLAsset(url: url)
        let loading = cancellation?.onCancel { asset.cancelLoading() }
        defer { if let loading { cancellation?.removeHandler(loading) } }
        try cancellation?.check()
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw LivesCoreError.invalidLivePhoto }
        let reader = try AVAssetReader(asset: asset)
        let nativeCancellation = cancellation?.onCancel { reader.cancelReading() }
        defer { if let nativeCancellation { cancellation?.removeHandler(nativeCancellation) } }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw LivesCoreError.renderFailed("无法读取封面视频帧") }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(value: CMTimeValue(max(0, timeMs)), timescale: 1000), duration: .positiveInfinity)
        let transform = try await track.load(.preferredTransform)
        guard reader.startReading() else { throw reader.error ?? LivesCoreError.invalidLivePhoto }
        defer { reader.cancelReading() }
        guard let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) else {
            throw reader.error ?? LivesCoreError.renderFailed("无法读取指定封面帧")
        }
        try cancellation?.check()
        var image = CIImage(cvPixelBuffer: buffer, options: [.toneMapHDRtoSDR: !preserveHDR])
        // AV 变换使用左上坐标；Core Image 使用左下坐标。
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: image.extent.height)
        image = image.transformed(by: flip.concatenating(transform))
        image = image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -image.extent.minX, ty: image.extent.maxY))
        // 脱离 reader 的缓冲池，只保留这一帧。
        let context = context()
        let space = preserveHDR ? workingSpace : sdrSpace
        guard let cg = context.createCGImage(image, from: image.extent, format: preserveHDR ? .RGBAh : .RGBA8, colorSpace: space) else {
            throw LivesCoreError.renderFailed("无法解码封面视频帧")
        }
        return CIImage(cgImage: cg)
    }

    static func fitted(_ image: CIImage, target: CGRect, crop: CropPosition, canvasHeight: CGFloat) -> CIImage {
        let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let rect = CropGeometry.drawnRect(source: normalized.extent.size, target: target, crop: crop)
        let bottomRect = CGRect(x: rect.minX, y: canvasHeight - rect.maxY, width: rect.width, height: rect.height)
        let clip = CGRect(x: target.minX, y: canvasHeight - target.maxY, width: target.width, height: target.height)
        return normalized.clampedToExtent().transformed(by: CGAffineTransform(scaleX: rect.width / normalized.extent.width, y: rect.height / normalized.extent.height))
            .transformed(by: CGAffineTransform(translationX: bottomRect.minX, y: bottomRect.minY)).cropped(to: clip)
    }

    public static func rotateImage(_ image: CIImage, degrees: Int) -> CIImage {
        let normalized = (degrees % 360 + 360) % 360
        guard normalized != 0 else { return image }
        let radians: CGFloat = switch normalized {
        case 90: .pi / 2
        case 180: .pi
        case 270: 3 * .pi / 2
        default: 0
        }
        let rotated = image.transformed(by: CGAffineTransform(rotationAngle: radians))
        return rotated.transformed(by: CGAffineTransform(translationX: -rotated.extent.minX, y: -rotated.extent.minY))
    }

    static func watermark(_ settings: WatermarkSettings, size: CGSize) throws -> CIImage? {
        guard settings.mode != .none else { return nil }
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: sdrSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw LivesCoreError.renderFailed("内存不足，无法生成水印")
        }
        LivesMediaEngine.drawWatermark(settings: settings, canvas: size, context: context)
        guard let image = context.makeImage() else { throw LivesCoreError.renderFailed("无法生成水印") }
        return CIImage(cgImage: image)
    }

    public static func playbackComposition(asset: AVAsset, preserveHDR: Bool, rotation: Int = 0) async throws -> AVVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw LivesCoreError.invalidLivePhoto }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let size = CGRect(origin: .zero, size: natural).applying(transform).size
        let duration = try await asset.load(.duration)
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = ColorVideoCompositor.self
        let orientedSize = CropGeometry.orientedSourceSize(source: size, rotation: rotation)
        composition.renderSize = orientedSize
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.colorPrimaries = preserveHDR ? AVVideoColorPrimaries_ITU_R_2020 : AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = preserveHDR ? AVVideoTransferFunction_ITU_R_2100_HLG : AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = preserveHDR ? AVVideoYCbCrMatrix_ITU_R_2020 : AVVideoYCbCrMatrix_ITU_R_709_2
        composition.instructions = [ColorVideoInstruction(duration: duration, slots: [ColorVideoSlot(trackID: track.trackID, image: nil,
            transform: transform, target: CGRect(origin: .zero, size: orientedSize), crop: CropPosition(), rotation: rotation)], clockIDs: [], watermark: nil, hdr: preserveHDR)]
        return composition
    }

    public struct PreviewFrameResult: Sendable {
        public let image: CGImage
        public let actualTimeMs: Int

        public init(image: CGImage, actualTimeMs: Int) {
            self.image = image
            self.actualTimeMs = actualTimeMs
        }
    }

    public static func previewFrameDirect(
        _ url: URL,
        timeMs: Int,
        preserveHDR: Bool,
        maxPixel: Int,
        context: CIContext? = nil,
        timeout: Duration? = nil
    ) async throws -> PreviewFrameResult {
        let cancellation = PreviewReaderCancellationController(timeout: timeout)
        defer { cancellation.finish() }
        return try await withTaskCancellationHandler {
            try cancellation.check()
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw LivesCoreError.invalidLivePhoto
            }
            try cancellation.check()
            let reader = try AVAssetReader(asset: asset)
            cancellation.install { reader.cancelReading() }
            try cancellation.check()
            let outputFormat: OSType = preserveHDR ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: outputFormat
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw LivesCoreError.renderFailed("无法读取封面视频帧") }
            reader.add(output)
            reader.timeRange = CMTimeRange(start: CMTime(value: CMTimeValue(max(0, timeMs)), timescale: 1000), duration: .positiveInfinity)
            let transform = try await track.load(.preferredTransform)
            try cancellation.check()
            guard reader.startReading() else { throw reader.error ?? LivesCoreError.invalidLivePhoto }
            defer { reader.cancelReading() }
            guard let sample = output.copyNextSampleBuffer() else {
                try cancellation.check()
                throw reader.error ?? LivesCoreError.renderFailed("无法读取指定封面帧")
            }
            try cancellation.check()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
                throw LivesCoreError.renderFailed("无法读取指定封面帧")
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let actualMs = Int((pts.seconds * 1000).rounded())

            var image = CIImage(cvPixelBuffer: buffer, options: preserveHDR ? [:] : [.toneMapHDRtoSDR: false])
            let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: image.extent.height)
            image = image.transformed(by: flip.concatenating(transform))
            image = image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -image.extent.minX, ty: image.extent.maxY))
            try cancellation.check()

            let scale = min(1, CGFloat(max(64, maxPixel)) / max(image.extent.width, image.extent.height))
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let renderContext = context ?? Self.context()
            let space = preserveHDR ? hdrSpace : sdrSpace
            guard let cg = renderContext.createCGImage(scaled, from: scaled.extent,
                format: preserveHDR ? .RGBAh : .RGBA8, colorSpace: space) else {
                throw LivesCoreError.renderFailed("无法生成视频预览")
            }
            try cancellation.check()
            return PreviewFrameResult(image: cg, actualTimeMs: actualMs)
        } onCancel: {
            cancellation.cancel()
        }
    }

    public static func previewFrame(_ url: URL, timeMs: Int, preserveHDR: Bool, maxPixel: Int) async throws -> CGImage {
        try await previewFrameDirect(url, timeMs: timeMs, preserveHDR: preserveHDR, maxPixel: maxPixel).image
    }

    public static func previewPhoto(_ url: URL, preserveHDR: Bool, maxPixel: Int, context: CIContext? = nil) throws -> CGImage {
        let image = try photo(url, preserveHDR: preserveHDR, maxPixel: maxPixel)
        let renderContext = context ?? Self.context()
        guard let cg = renderContext.createCGImage(image, from: image.extent, format: preserveHDR ? .RGBAh : .RGBA8,
                                              colorSpace: preserveHDR ? hdrSpace : sdrSpace) else {
            throw LivesCoreError.renderFailed("无法生成照片预览")
        }
        return cg
    }

    static func writeCover(_ image: CIImage, sdrImage: CIImage, hdr: Bool, to url: URL, identifier: String) throws {
        let metadata = [kCGImagePropertyMakerAppleDictionary as String: ["17": identifier], kCGImagePropertyOrientation as String: 1] as [String: Any]
        let output = image.settingProperties(metadata)
        let context = context()
        let quality: [CIImageRepresentationOption: Any] = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.95]
        if hdr {
            if #available(iOS 18, macOS 15, *) {
                var options = quality
                options[.hdrImage] = output
                try context.writeHEIFRepresentation(of: sdrImage.settingProperties(metadata), to: url, format: .RGBA8, colorSpace: sdrSpace, options: options)
            } else {
                try context.writeHEIF10Representation(of: output, to: url, colorSpace: hdrSpace, options: quality)
            }
        } else {
            try context.writeJPEGRepresentation(of: sdrImage.settingProperties(metadata), to: url, colorSpace: sdrSpace, options: quality)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let maker = props[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any],
              maker["17"] as? String == identifier else { throw LivesCoreError.renderFailed("封面配对信息写入失败") }
        if hdr && !photoIsHDR(url) { throw LivesCoreError.renderFailed("HDR 封面数据校验失败") }
    }
}
