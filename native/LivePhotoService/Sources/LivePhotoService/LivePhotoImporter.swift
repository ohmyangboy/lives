import AVFoundation
import Foundation
import ImageIO
import LivesCore

struct LivePhotoPathsEnvelope: Codable { let paths: [String] }

struct LivePhotoSource: Codable {
    let photoPath: String
    let contentIdentifier: String
    let width: Int
    let height: Int
    let motionWidth: Int
    let motionHeight: Int
}

struct ImportedLivePhoto: Codable {
    let video: VideoInfo
    let livePhoto: LivePhotoSource
}

enum LivePhotoImporter {
    private static func invalid(_ message: String) -> ServiceError {
        ServiceError(code: "INVALID_LIVE_PHOTO", message: message,
                     recovery: "请从“照片”导出未修改的原片，同时选择照片和 MOV；同名文件不一定是 Live Photo")
    }

    // Match resource identifiers, never filenames: exports can rename either half.
    static func matchedIndices(photoIDs: [String], videoIDs: [String], allowUnmatchedVideos: Bool = false) throws -> [Int] {
        guard !photoIDs.isEmpty, Set(photoIDs).count == photoIDs.count,
              !photoIDs.contains(""),
              (allowUnmatchedVideos || photoIDs.count == videoIDs.count) else {
            throw invalid("所选文件缺少配对资源、配对标识不一致或存在重复资源")
        }
        return try photoIDs.map { id in
            let matches = videoIDs.indices.filter { videoIDs[$0] == id }
            guard matches.count == 1 else {
                throw invalid("所选照片缺少唯一配对 MOV 或存在重复资源")
            }
            return matches[0]
        }
    }

    static func pair(paths: [String]) async throws -> [ImportedLivePhoto] {
        let urls = Array(Set(paths)).sorted().map { URL(fileURLWithPath: $0) }
        let photos = urls.filter { ["heic", "heif", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
        let videos = urls.filter { $0.pathExtension.lowercased() == "mov" }
        guard urls.count == photos.count + videos.count else { throw invalid("请选择 HEIC/JPG 和 MOV 配对文件") }
        var photoIDs: [String] = []
        var dimensions: [(Int, Int)] = []
        for url in photos {
            guard FileManager.default.isReadableFile(atPath: url.path),
                  let image = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any],
                  let maker = props[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any],
                  let identifier = maker["17"] as? String,
                  let width = props[kCGImagePropertyPixelWidth as String] as? Int,
                  let height = props[kCGImagePropertyPixelHeight as String] as? Int else {
                throw invalid("无法读取 \(url.lastPathComponent) 的 Live Photo 配对信息，请检查文件及读取权限")
            }
            photoIDs.append(identifier)
            dimensions.append((width, height))
        }
        var videoIDs: [String] = []
        for url in videos {
            // Non-matching MOVs are imported as ordinary videos by the caller.
            // A missing or unreadable candidate cannot match a photo identifier.
            let metadata = (try? await AVURLAsset(url: url).load(.metadata)) ?? []
            let item = metadata.first { $0.identifier == .quickTimeMetadataContentIdentifier }
            videoIDs.append((try? await item?.load(.stringValue)) ?? "")
        }
        let indices = try matchedIndices(photoIDs: photoIDs, videoIDs: videoIDs, allowUnmatchedVideos: true)
        var results: [ImportedLivePhoto] = []
        for (index, videoIndex) in indices.enumerated() {
            let info = try await MediaInspector.inspect(path: videos[videoIndex].path, minimumDurationMilliseconds: 1000)
            let source = LivePhotoSource(photoPath: photos[index].path, contentIdentifier: photoIDs[index],
                                         width: dimensions[index].0, height: dimensions[index].1,
                                         motionWidth: info.width, motionHeight: info.height)
            try await validate(source: source, videoPath: info.path, durationMs: info.durationMs)
            results.append(ImportedLivePhoto(video: info, livePhoto: source))
        }
        return results
    }

    static func validate(source: LivePhotoSource, videoPath: String, durationMs: Int? = nil) async throws {
        let duration: Int
        if let durationMs { duration = durationMs }
        else { duration = try await MediaInspector.inspect(path: videoPath, minimumDurationMilliseconds: 1000).durationMs }
        do {
            try await LivesMediaEngine.validate(pair: LivePhotoPair(
                photoURL: URL(fileURLWithPath: source.photoPath), videoURL: URL(fileURLWithPath: videoPath),
                contentIdentifier: source.contentIdentifier), expectedDurationMs: duration)
        } catch {
            throw invalid("Live Photo 配对校验失败：\(error.localizedDescription)")
        }
    }
}
