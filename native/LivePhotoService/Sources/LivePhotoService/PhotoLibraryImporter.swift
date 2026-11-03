import AppKit
import Photos
import PhotosUI
import UniformTypeIdentifiers

/// UI and PhotoKit stay in the short-lived, bundled Photos worker.
@MainActor
final class LivePhotoLibraryPicker: NSObject, PHPickerViewControllerDelegate, NSWindowDelegate {
    private var continuation: CheckedContinuation<[String], Error>?
    private var window: NSWindow?

    func select(limited: Bool) async throws -> [String] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "(mediaSubtype & %d) != 0", PHAssetMediaSubtype.photoLive.rawValue)
        let count = PHAsset.fetchAssets(with: .image, options: options).count
        PhotoAuthorization.appendDiagnosticsLog("photo-import: accessible live count=\(count)")
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .livePhotos
        configuration.selectionLimit = 10
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = limited ? "添加 Live · 仅能导入已授权的照片" : "从照片添加 Live · 最多 10 项"
        window.isReleasedWhenClosed = false
        let container = NSViewController()
        container.view = NSView()
        container.addChild(picker)
        let guidance = NSTextField(wrappingLabelWithString: Self.guidance(limited: limited, count: count))
        guidance.translatesAutoresizingMaskIntoConstraints = false
        picker.view.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(guidance)
        container.view.addSubview(picker.view)
        NSLayoutConstraint.activate([
            guidance.topAnchor.constraint(equalTo: container.view.topAnchor, constant: 16),
            guidance.leadingAnchor.constraint(equalTo: container.view.leadingAnchor, constant: 20),
            guidance.trailingAnchor.constraint(equalTo: container.view.trailingAnchor, constant: -20),
            picker.view.topAnchor.constraint(equalTo: guidance.bottomAnchor, constant: 12),
            picker.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            picker.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            picker.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor)
        ])
        window.contentViewController = container
        // Assigning the content controller can resize the window to its intrinsic size.
        // Restore a usable picker area after assignment and prevent it collapsing again.
        window.contentMinSize = NSSize(width: 640, height: 480)
        window.setContentSize(NSSize(width: 760, height: 600))
        window.delegate = self
        self.window = window
        window.center()
        // Authorization can change the active app before the picker is ready.
        // Activate the worker again when the actual selection window is shown.
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        PhotoAuthorization.appendDiagnosticsLog("photo-import: picker visible=\(window.isVisible) active=\(NSApplication.shared.isActive)")
        let result = try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
        // Both AppKit delegate references are weak; keep the picker delegate alive
        // until the window has completed its asynchronous selection.
        withExtendedLifetime(self) {}
        return result
    }

    static func guidance(limited: Bool, count: Int) -> String {
        if limited {
            return "在图库中选择最多 10 张 Live Photo。若找不到，请在系统设置的照片权限中允许访问对应照片，或使用“添加素材”导入文件。"
        }
        if count == 0 {
            return "当前可访问的照片图库中没有找到 Live Photo。请检查系统照片图库，或使用“添加素材”导入原始照片和 MOV 文件。可在下方图库中查看。"
        }
        return "在下方图库中选择最多 10 张 Live Photo。"
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        let identifiers = results.compactMap(\.assetIdentifier)
        finish(identifiers.count == results.count ? .success(identifiers) : .failure(PhotoLibraryImporter.unavailableSelection))
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(.success([]))
        return false
    }

    private func finish(_ result: Result<[String], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        continuation.resume(with: result)
    }
}

enum PhotoLibraryImporter {
    static let unavailableSelection = ServiceError(code: "PHOTO_READ_LIMITED",
        message: "无法读取所选 Live Photo", recovery: "请在系统设置的照片权限中允许访问所选照片，或使用文件配对导入")

    // Keep the original still and original motion together, even for edited Live Photos.
    static func originalResourceIndices(types: [PHAssetResourceType]) throws -> (photo: Int, video: Int) {
        let photos = types.indices.filter { types[$0] == .photo }
        let videos = types.indices.filter { types[$0] == .pairedVideo }
        guard photos.count == 1, videos.count == 1 else {
            throw ServiceError(code: "PHOTO_LIVE_RESOURCES_MISSING", message: "所选照片没有完整的原始 Live Photo 资源",
                               recovery: "请选择仍保留动态资源的 Live Photo，或导出未修改原片后使用文件配对导入")
        }
        return (photos[0], videos[0])
    }

    static func export(identifiers: [String], to directory: URL) async throws -> [ImportedLivePhoto] {
        guard !identifiers.isEmpty else { return [] }
        let uniqueIDs = Array(Set(identifiers)).sorted()
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: uniqueIDs, options: nil)
        guard fetched.count == uniqueIDs.count else { throw unavailableSelection }
        var assets: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in assets[asset.localIdentifier] = asset }
        var paths: [String] = []
        for (index, id) in uniqueIDs.enumerated() {
            guard let asset = assets[id], asset.mediaSubtypes.contains(.photoLive) else {
                throw unavailableSelection
            }
            let resources = PHAssetResource.assetResources(for: asset)
            let indices = try originalResourceIndices(types: resources.map(\.type))
            let photo = resources[indices.photo]
            let video = resources[indices.video]
            let photoExtension = UTType(photo.uniformTypeIdentifier)?.preferredFilenameExtension ?? "heic"
            guard ["heic", "heif", "jpeg", "jpg"].contains(photoExtension.lowercased()) else {
                throw ServiceError(code: "PHOTO_LIVE_FORMAT_UNSUPPORTED", message: "暂不支持这张 Live Photo 的原片格式",
                                   recovery: "请选择 HEIC 或 JPEG 原片，或使用文件配对导入")
            }
            // Do not use original filenames or library identifiers as filesystem paths.
            let photoURL = directory.appendingPathComponent("\(index).\(photoExtension)")
            let videoURL = directory.appendingPathComponent("\(index).mov")
            try await write(photo, to: photoURL)
            try await write(video, to: videoURL)
            paths += [photoURL.path, videoURL.path]
        }
        return try await LivePhotoImporter.pair(paths: paths)
    }

    private static func write(_ resource: PHAssetResource, to url: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        } catch {
            throw ServiceError(code: "PHOTO_RESOURCE_DOWNLOAD_FAILED", message: "无法读取或下载 Live Photo 原片",
                               recovery: "请检查照片读取权限、iCloud 网络连接和磁盘空间后重试；也可以使用文件配对导入")
        }
    }
}
