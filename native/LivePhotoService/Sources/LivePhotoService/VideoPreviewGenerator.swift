import AVFoundation
import CryptoKit
import Foundation

private final class ExportSessionBox: @unchecked Sendable {
    let value: AVAssetExportSession

    init(_ value: AVAssetExportSession) {
        self.value = value
    }
}

enum VideoPreviewGenerator {
    static let maximumPreviewDimension: CGFloat = 1920

    static func prepare(path: String, cacheDirectory: URL? = nil) async throws -> PreviewInfo {
        let sourceURL = URL(fileURLWithPath: path)
        guard FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            throw ServiceError(
                code: "VIDEO_PREVIEW_READ_FAILED",
                message: "无法读取 \(sourceURL.lastPathComponent) 的预览",
                recovery: "请检查文件是否完整，或重新选择文件"
            )
        }

        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ServiceError(
                code: "VIDEO_READ_FAILED",
                message: "视频中没有可用画面",
                recovery: "请检查视频文件是否完整"
            )
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        guard shouldGeneratePreview(for: orientedRect.size) else {
            return PreviewInfo(path: sourceURL.path, transcoded: false)
        }

        let root = cacheDirectory ?? defaultCacheDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outputURL = try cacheURL(for: sourceURL, in: root)
        if await isUsablePreview(at: outputURL) {
            return PreviewInfo(path: outputURL.path, transcoded: true)
        }
        try? FileManager.default.removeItem(at: outputURL)

        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080),
              exporter.supportedFileTypes.contains(.mp4) else {
            throw ServiceError(
                code: "VIDEO_PREVIEW_UNAVAILABLE",
                message: "无法为 \(sourceURL.lastPathComponent) 建立预览",
                recovery: "请先将视频转换为 H.264 MP4 后重试"
            )
        }

        try await export(exporter, to: outputURL)
        guard await isUsablePreview(at: outputURL) else {
            try? FileManager.default.removeItem(at: outputURL)
            throw ServiceError(
                code: "VIDEO_PREVIEW_FAILED",
                message: "视频预览生成失败",
                recovery: "请先将视频转换为 H.264 MP4 后重试"
            )
        }
        return PreviewInfo(path: outputURL.path, transcoded: true)
    }

    static func shouldGeneratePreview(for size: CGSize) -> Bool {
        max(abs(size.width), abs(size.height)) > maximumPreviewDimension
    }

    private static func defaultCacheDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.yangbukun.lives", isDirectory: true)
            .appendingPathComponent("previews", isDirectory: true)
    }

    private static func cacheURL(for sourceURL: URL, in root: URL) throws -> URL {
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let signature = [
            sourceURL.standardizedFileURL.path,
            String(values.fileSize ?? 0),
            String(values.contentModificationDate?.timeIntervalSince1970 ?? 0),
        ].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(signature.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return root.appendingPathComponent("\(digest).mp4")
    }

    private static func isUsablePreview(at url: URL) async -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return false }
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true,
              let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first else { return false }
        guard let size = try? await track.load(.naturalSize) else { return false }
        return max(abs(size.width), abs(size.height)) <= maximumPreviewDimension
    }

    private static func export(_ exporter: AVAssetExportSession, to outputURL: URL) async throws {
        let box = ExportSessionBox(exporter)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            box.value.outputURL = outputURL
            box.value.outputFileType = .mp4
            box.value.shouldOptimizeForNetworkUse = true
            box.value.exportAsynchronously {
                switch box.value.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(throwing: ServiceError(
                        code: "VIDEO_PREVIEW_FAILED",
                        message: "视频预览生成失败",
                        recovery: "请先将视频转换为 H.264 MP4 后重试"
                    ))
                }
            }
        }
    }
}
