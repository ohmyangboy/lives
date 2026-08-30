import AppKit
import AVFoundation
import ImageIO
import Photos
import UniformTypeIdentifiers

private final class LivePhotoValidationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Error>?
    private var requestID: PHLivePhotoRequestID?
    private var finished = false

    func install(_ continuation: CheckedContinuation<Bool, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func setRequestID(_ requestID: PHLivePhotoRequestID) {
        lock.lock()
        let shouldCancel = finished
        if !finished { self.requestID = requestID }
        lock.unlock()
        if shouldCancel { PHLivePhoto.cancelRequest(withRequestID: requestID) }
    }

    func succeed(_ value: Bool) {
        resolve(.success(value))
    }

    func fail(_ error: Error) {
        resolve(.failure(error))
    }

    func isFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    private func resolve(_ result: Result<Bool, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        let requestID = requestID
        self.requestID = nil
        lock.unlock()

        if case .failure = result, let requestID {
            PHLivePhoto.cancelRequest(withRequestID: requestID)
        }
        continuation?.resume(with: result)
    }
}

struct SavedAssetResult: Codable {
    let localIdentifier: String
    let savedAt: String
}

struct PairValidationResult: Codable {
    let validated: Bool
    let durationMs: Int
}

struct ExportedPairResult: Codable {
    let directoryPath: String
    let photoPath: String
    let videoPath: String
}

enum LivePhotoPipeline {
    static func supportsCanvas(width: Int, height: Int) -> Bool {
        [
            "1080x1920", "1080x1440", "1080x1080",
            "720x1280", "720x960", "720x720",
            "1920x1080", "1440x1080", "1280x720", "960x720",
        ].contains("\(width)x\(height)")
    }

    static func expectedClipCount(for templateId: String) -> Int {
        switch templateId {
        case "single": return 1
        case "stack-2", "side-2": return 2
        case "stack-3", "side-3", "hero-left", "hero-top", "weighted-3": return 3
        default: return 0
        }
    }

    typealias ProgressHandler = (String, Double) async -> Void

    static func run(
        project: RenderProject,
        cancellations: CancellationRegistry,
        progress: @escaping ProgressHandler
    ) async throws -> SavedAssetResult {
        await progress("requestingPhotoPermission", 0.02)
        try await PhotoLibraryWorkerClient.requestAuthorization()
        try await cancellations.check(project.id)

        let pair = try await generateAndValidate(project: project, cancellations: cancellations, progress: progress)
        defer { try? FileManager.default.removeItem(at: pair.directory) }

        await progress("saving", 0.88)
        let identifier = try await PhotoLibraryWorkerClient.savePair(photoURL: pair.photoURL, pairedVideoURL: pair.videoURL)
        await progress("completed", 1)
        return SavedAssetResult(localIdentifier: identifier, savedAt: ISO8601DateFormatter().string(from: Date()))
    }

    static func exportToFolder(
        project: RenderProject,
        directoryPath: String,
        cancellations: CancellationRegistry,
        progress: @escaping ProgressHandler
    ) async throws -> ExportedPairResult {
        let pair = try await generateAndValidate(project: project, cancellations: cancellations, progress: progress)
        defer { try? FileManager.default.removeItem(at: pair.directory) }
        try await cancellations.check(project.id)
        await progress("exportingFiles", 0.88)
        let result = try copyPair(photoURL: pair.photoURL, videoURL: pair.videoURL, toDirectoryPath: directoryPath)
        await progress("completed", 1)
        return result
    }

    static func copyPair(photoURL: URL, videoURL: URL, toDirectoryPath directoryPath: String, now: Date = Date()) throws -> ExportedPairResult {
        let fileManager = FileManager.default
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ServiceError(code: "EXPORT_FOLDER_UNAVAILABLE", message: "无法使用这个文件夹", recovery: "请选择一个可写入的文件夹")
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = "Lives-\(formatter.string(from: now))"
        var suffix = 1
        var photoDestination: URL
        var videoDestination: URL
        repeat {
            let name = suffix == 1 ? stem : "\(stem)-\(suffix)"
            photoDestination = directory.appendingPathComponent(name).appendingPathExtension("jpg")
            videoDestination = directory.appendingPathComponent(name).appendingPathExtension("mov")
            suffix += 1
        } while fileManager.fileExists(atPath: photoDestination.path) || fileManager.fileExists(atPath: videoDestination.path)

        do {
            try fileManager.copyItem(at: photoURL, to: photoDestination)
            try fileManager.copyItem(at: videoURL, to: videoDestination)
        } catch {
            try? fileManager.removeItem(at: photoDestination)
            try? fileManager.removeItem(at: videoDestination)
            throw ServiceError(code: "EXPORT_FOLDER_FAILED", message: "无法保存到所选文件夹", recovery: "请检查文件夹权限和磁盘空间后重试")
        }
        return ExportedPairResult(
            directoryPath: directory.path,
            photoPath: photoDestination.path,
            videoPath: videoDestination.path
        )
    }

    static func validateOnly(
        project: RenderProject,
        cancellations: CancellationRegistry,
        progress: @escaping ProgressHandler
    ) async throws -> PairValidationResult {
        let pair = try await generateAndValidate(project: project, cancellations: cancellations, progress: progress)
        defer { try? FileManager.default.removeItem(at: pair.directory) }
        return PairValidationResult(validated: true, durationMs: project.canvas.durationMs)
    }

    private struct GeneratedPair {
        let directory: URL
        let photoURL: URL
        let videoURL: URL
    }

    private static func generateAndValidate(
        project: RenderProject,
        cancellations: CancellationRegistry,
        progress: @escaping ProgressHandler
    ) async throws -> GeneratedPair {
        try validate(project)
        await progress("inspecting", 0.03)
        for clip in project.clips {
            _ = try await MediaInspector.inspect(path: clip.sourcePath)
            try await cancellations.check(project.id)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lives", isDirectory: true)
            .appendingPathComponent(project.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let videoURL = directory.appendingPathComponent("paired.mov")
        let photoURL = directory.appendingPathComponent("cover.jpg")
        let contentIdentifier = UUID().uuidString
        do {
            await progress("transcoding", 0.08)
            let preparedProject = try await CompatibilityTranscoder.prepare(
                project: project,
                workingDirectory: directory,
                cancellations: cancellations
            ) { value in await progress("transcoding", 0.08 + value * 0.17) }
            try await cancellations.check(project.id)
            await progress("rendering", 0.25)
            try await VideoRenderer.render(
                project: preparedProject,
                outputURL: videoURL,
                contentIdentifier: contentIdentifier,
                cancellations: cancellations
            ) { value in await progress("rendering", 0.25 + value * 0.40) }
            try await cancellations.check(project.id)
            await progress("writingMetadata", 0.68)
            try await writeCover(project: preparedProject, to: photoURL, contentIdentifier: contentIdentifier)
            try await cancellations.check(project.id)
            await progress("validating", 0.75)
            try await validatePair(
                photoURL: photoURL,
                pairedVideoURL: videoURL,
                cancellations: cancellations,
                jobId: project.id
            )
            try await cancellations.check(project.id)
            return GeneratedPair(directory: directory, photoURL: photoURL, videoURL: videoURL)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func validate(_ project: RenderProject) throws {
        guard (1...3).contains(project.clips.count), supportsCanvas(width: project.canvas.width, height: project.canvas.height),
              project.canvas.durationMs == 3000, project.canvas.fps == 30,
              project.coverTimeMs >= 0, project.coverTimeMs < project.canvas.durationMs else {
            throw ServiceError(code: "INVALID_PROJECT", message: "项目参数不符合 MVP 输出规范", recovery: "请返回编辑器并重新生成")
        }
        let expected = expectedClipCount(for: project.templateId)
        guard project.clips.count == expected else {
            throw ServiceError(code: "INVALID_PROJECT", message: "素材数量与模板不匹配", recovery: "请选择对应数量的模板")
        }
    }

    private static func writeCover(project: RenderProject, to photoURL: URL, contentIdentifier: String) async throws {
        let canvasSize = CGSize(width: project.canvas.width, height: project.canvas.height)
        guard let context = CGContext(
            data: nil,
            width: project.canvas.width,
            height: project.canvas.height,
            bitsPerComponent: 8,
            bytesPerRow: project.canvas.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ServiceError(code: "LIVE_METADATA_FAILED", message: "无法创建 Live Photo 封面画布", recovery: "请重试")
        }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: canvasSize))
        context.saveGState()
        context.translateBy(x: 0, y: canvasSize.height)
        context.scaleBy(x: 1, y: -1)

        for clip in project.clips {
            let asset = AVURLAsset(url: URL(fileURLWithPath: clip.sourcePath))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let sourceOffset = min(clip.coverTimeMs, max(0, clip.sourceDurationMs - clip.startTimeMs - 1))
            let sourceTime = CMTime(value: CMTimeValue(clip.startTimeMs + sourceOffset), timescale: 1000)
            let image = try await generator.image(at: sourceTime).image
            let target = try TemplateLayout.rect(for: clip.targetSlotId, templateId: project.templateId, canvas: canvasSize)
            let imageAspect = CGFloat(image.width) / CGFloat(max(1, image.height))
            let targetAspect = target.width / max(1, target.height)
            let userScale = max(1, clip.crop.scale)
            var cropWidth = CGFloat(image.width)
            var cropHeight = CGFloat(image.height)
            if imageAspect > targetAspect {
                cropWidth = CGFloat(image.height) * targetAspect
            } else {
                cropHeight = CGFloat(image.width) / targetAspect
            }
            cropWidth = min(CGFloat(image.width), cropWidth / userScale)
            cropHeight = min(CGFloat(image.height), cropHeight / userScale)
            let cropRect = CGRect(
                x: (CGFloat(image.width) - cropWidth) * min(1, max(0, clip.crop.normalizedCenterX)),
                y: (CGFloat(image.height) - cropHeight) * min(1, max(0, clip.crop.normalizedCenterY)),
                width: cropWidth,
                height: cropHeight
            ).integral
            guard let cropped = image.cropping(to: cropRect) else {
                throw ServiceError(code: "LIVE_METADATA_FAILED", message: "无法裁剪 Live Photo 封面", recovery: "请重试")
            }
            context.draw(cropped, in: target)
        }
        context.restoreGState()
        guard let image = context.makeImage() else {
            throw ServiceError(code: "LIVE_METADATA_FAILED", message: "无法生成 Live Photo 封面", recovery: "请重试")
        }
        guard let destination = CGImageDestinationCreateWithURL(photoURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ServiceError(code: "LIVE_METADATA_FAILED", message: "无法生成 Live Photo 封面", recovery: "请重试")
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyMakerAppleDictionary: ["17": contentIdentifier],
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyPixelWidth: image.width,
            kCGImagePropertyPixelHeight: image.height,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ServiceError(code: "LIVE_METADATA_FAILED", message: "无法写入封面配对信息", recovery: "请重试")
        }
    }

    static func validatePair(
        photoURL: URL,
        pairedVideoURL: URL,
        cancellations: CancellationRegistry,
        jobId: String,
        timeoutNanoseconds: UInt64 = 30_000_000_000
    ) async throws {
        try await cancellations.check(jobId)
        guard let placeholder = NSImage(contentsOf: photoURL) else {
            throw ServiceError(code: "LIVE_VALIDATION_FAILED", message: "无法读取生成的封面", recovery: "请重试")
        }
        let gate = LivePhotoValidationGate()
        let valid = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            gate.install(continuation)
            let requestID = PHLivePhoto.request(
                withResourceFileURLs: [photoURL, pairedVideoURL],
                placeholderImage: placeholder,
                targetSize: CGSize(width: 540, height: 960),
                contentMode: .aspectFit
            ) { livePhoto, info in
                let error = info[PHLivePhotoInfoErrorKey] as? Error
                gate.succeed(livePhoto != nil && error == nil)
            }
            gate.setRequestID(requestID)
            Task.detached {
                var elapsed: UInt64 = 0
                let interval: UInt64 = 100_000_000
                while !gate.isFinished() {
                    if await cancellations.isCancelled(jobId) {
                        gate.fail(ServiceError.cancelled)
                        return
                    }
                    if elapsed >= timeoutNanoseconds {
                        gate.fail(ServiceError(
                            code: "LIVE_VALIDATION_TIMEOUT",
                            message: "Live Photo 校验超时",
                            recovery: "本次任务已停止，请重新启动 App 后重试"
                        ))
                        return
                    }
                    try? await Task.sleep(nanoseconds: interval)
                    elapsed += interval
                }
            }
        }
        guard valid else {
            throw ServiceError(code: "LIVE_VALIDATION_FAILED", message: "生成结果未通过 Live Photo 校验", recovery: "不会写入图库，请重试")
        }
    }

}
