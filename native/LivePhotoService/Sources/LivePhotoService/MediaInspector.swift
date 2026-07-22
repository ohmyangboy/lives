import AVFoundation
import CoreMedia
import Foundation

enum MediaInspector {
    static func inspect(path: String) async throws -> VideoInfo {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw ServiceError(code: "VIDEO_READ_FAILED", message: "无法读取 \(url.lastPathComponent)", recovery: "请检查文件是否完整，或重新选择文件")
        }
        guard ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) else {
            throw ServiceError(code: "VIDEO_UNSUPPORTED", message: "暂不支持这个视频格式", recovery: "请使用 MOV、MP4 或 M4V 视频")
        }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationMilliseconds = duration.isNumeric ? Int((duration.seconds * 1000).rounded(.down)) : 0
        guard durationMilliseconds >= MediaConstraints.minimumSourceDurationMilliseconds else {
            let displayedDuration = String(format: "%.1f", Double(durationMilliseconds) / 1000)
            throw ServiceError(
                code: "VIDEO_TOO_SHORT",
                message: "\(url.lastPathComponent) 只有 \(displayedDuration) 秒，至少需要 2.5 秒",
                recovery: "请选择更长的视频；接近 3 秒的 Live Photo 视频会自动补齐末帧"
            )
        }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ServiceError(code: "VIDEO_READ_FAILED", message: "\(url.lastPathComponent) 没有可用画面", recovery: "请检查视频文件是否完整")
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformed = CGRect(origin: .zero, size: size).applying(transform)
        let descriptions = try await track.load(.formatDescriptions)
        let codec = descriptions.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "unknown"
        return VideoInfo(
            path: path,
            durationMs: durationMilliseconds,
            width: Int(abs(transformed.width).rounded()),
            height: Int(abs(transformed.height).rounded()),
            codec: codec
        )
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(format: "%08x", value)
    }
}
