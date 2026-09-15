import AVFoundation
import CoreImage

struct ColorVideoSlot {
    let trackID: CMPersistentTrackID?
    let image: CIImage?
    let transform: CGAffineTransform
    let target: CGRect
    let crop: CropPosition
    let rotation: Int

    init(trackID: CMPersistentTrackID?, image: CIImage?, transform: CGAffineTransform, target: CGRect, crop: CropPosition, rotation: Int = 0) {
        self.trackID = trackID
        self.image = image
        self.transform = transform
        self.target = target
        self.crop = crop
        self.rotation = rotation
    }
}

final class ColorVideoInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = false
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let slots: [ColorVideoSlot]
    let watermark: CIImage?
    let hdr: Bool
    let displayP3: Bool

    init(duration: CMTime, slots: [ColorVideoSlot], clockIDs: [CMPersistentTrackID], watermark: CIImage?, hdr: Bool, displayP3: Bool = false) {
        timeRange = CMTimeRange(start: .zero, duration: duration)
        self.slots = slots
        self.watermark = watermark
        self.displayP3 = displayP3
        self.hdr = hdr
        requiredSourceTrackIDs = (slots.compactMap(\.trackID) + clockIDs).map { NSNumber(value: $0) }
    }
}

/// 每次只合成一帧，复用 Core Image 上下文与 AVFoundation 有界像素缓冲池。
final class ColorVideoCompositor: NSObject, AVVideoCompositing {
    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_32BGRA]]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }
    let supportsWideColorSourceFrames = true
    let supportsHDRSourceFrames = true
    private let queue = DispatchQueue(label: "lives.color-compositor", qos: .userInitiated)
    private let context = MediaColorPipeline.context()
    private let cancellationLock = NSLock()
    private var generation = 0
    private func currentGeneration() -> Int {
        cancellationLock.lock(); defer { cancellationLock.unlock() }
        return generation
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let token = currentGeneration()
        queue.async {
            autoreleasepool {
                guard token == self.currentGeneration() else { request.finishCancelledRequest(); return }
                guard let instruction = request.videoCompositionInstruction as? ColorVideoInstruction,
                      let buffer = request.renderContext.newPixelBuffer() else {
                    request.finish(with: LivesCoreError.renderFailed("内存不足，无法分配合成帧")); return
                }
                let bounds = CGRect(origin: .zero, size: request.renderContext.size)
                var result = CIImage(color: instruction.displayP3 ? .black : CIColor(red: 0.05, green: 0.05, blue: 0.05)).cropped(to: bounds)
                for slot in instruction.slots {
                    let image: CIImage
                    if let still = slot.image {
                        image = still
                    } else if let id = slot.trackID, let source = request.sourceFrame(byTrackID: id) {
                        var frame = CIImage(cvPixelBuffer: source, options: instruction.displayP3 ? [.toneMapHDRtoSDR: true] : [:])
                        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: frame.extent.height)
                        frame = frame.transformed(by: flip.concatenating(slot.transform))
                        image = frame.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -frame.extent.minX, ty: frame.extent.maxY))
                    } else {
                        request.finish(with: LivesCoreError.renderFailed("合成时缺少视频帧")); return
                    }
                    let rotated = MediaColorPipeline.rotateImage(image, degrees: slot.rotation)
                    result = MediaColorPipeline.fitted(rotated, target: slot.target, crop: slot.crop, canvasHeight: bounds.height).composited(over: result)
                }
                if let watermark = instruction.watermark { result = watermark.composited(over: result) }
                let space = instruction.hdr ? MediaColorPipeline.hdrSpace : (instruction.displayP3 ? MediaColorPipeline.sdrSpace : CGColorSpace(name: CGColorSpace.itur_709)!)
                self.context.render(result, to: buffer, bounds: bounds, colorSpace: space)
                guard token == self.currentGeneration() else { request.finishCancelledRequest(); return }
                request.finish(withComposedVideoFrame: buffer)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        cancellationLock.lock()
        generation &+= 1
        cancellationLock.unlock()
    }
}
