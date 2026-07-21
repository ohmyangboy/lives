import AppKit
import Foundation
import Photos

private struct PhotoWorkerResponse: Codable {
    var authorized: Bool?
    var identifier: String?
    var error: ServiceError?
}

enum PhotoLibraryWorker {
    static func runIfRequested(arguments: [String]) async -> Bool {
        if let modeIndex = arguments.firstIndex(of: "photo-authorize"), arguments.indices.contains(modeIndex + 1) {
            await prepareApplicationForPhotoKit()
            let responseURL = URL(fileURLWithPath: arguments[modeIndex + 1])
            let status = await requestAddOnlyAuthorizationDirect()
            let authorized = status == .authorized
            let error = authorized ? nil : ServiceError(
                code: "PHOTO_PERMISSION_DENIED",
                message: "没有照片写入权限",
                recovery: "请在“系统设置 → 隐私与安全性 → 照片”中允许 Lives 添加照片；也可以改为导出到文件夹"
            )
            write(PhotoWorkerResponse(authorized: authorized, identifier: nil, error: error), to: responseURL)
            return true
        }

        if let modeIndex = arguments.firstIndex(of: "photo-save"), arguments.indices.contains(modeIndex + 3) {
            await prepareApplicationForPhotoKit()
            let responseURL = URL(fileURLWithPath: arguments[modeIndex + 1])
            let photoURL = URL(fileURLWithPath: arguments[modeIndex + 2])
            let videoURL = URL(fileURLWithPath: arguments[modeIndex + 3])
            do {
                let identifier = try await savePairDirect(photoURL: photoURL, pairedVideoURL: videoURL)
                write(PhotoWorkerResponse(authorized: true, identifier: identifier, error: nil), to: responseURL)
            } catch let error as ServiceError {
                write(PhotoWorkerResponse(authorized: true, identifier: nil, error: error), to: responseURL)
            } catch {
                write(PhotoWorkerResponse(authorized: true, identifier: nil, error: ErrorMapper.map(error)), to: responseURL)
            }
            return true
        }
        return false
    }

    @MainActor
    private static func prepareApplicationForPhotoKit() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        application.activate(ignoringOtherApps: false)
    }

    @MainActor
    private static func requestAddOnlyAuthorizationDirect() -> PHAuthorizationStatus {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            var completed = false
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { requestedStatus in
                status = requestedStatus
                completed = true
            }
            while !completed {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
        }
        return status
    }

    private static func savePairDirect(photoURL: URL, pairedVideoURL: URL) async throws -> String {
        var placeholderIdentifier: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                request.addResource(with: .photo, fileURL: photoURL, options: options)
                request.addResource(with: .pairedVideo, fileURL: pairedVideoURL, options: options)
                placeholderIdentifier = request.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            throw ServiceError(code: "PHOTO_SAVE_FAILED", message: "无法保存到“照片”", recovery: "请检查照片图库状态和磁盘空间后重试")
        }
        guard let placeholderIdentifier else {
            throw ServiceError(code: "PHOTO_SAVE_FAILED", message: "“照片”没有返回保存结果", recovery: "请重试")
        }
        return placeholderIdentifier
    }

    private static func write(_ response: PhotoWorkerResponse, to url: URL) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

enum PhotoLibraryWorkerClient {
    static func requestAuthorization() async throws {
        let response = try await launch(mode: "photo-authorize", resourcePaths: [])
        if let error = response.error { throw error }
        guard response.authorized == true else {
            throw ServiceError(code: "PHOTO_PERMISSION_DENIED", message: "没有照片写入权限", recovery: "请在“系统设置 → 隐私与安全性 → 照片”中允许 Lives 添加照片；也可以改为导出到文件夹")
        }
    }

    static func savePair(photoURL: URL, pairedVideoURL: URL) async throws -> String {
        let response = try await launch(mode: "photo-save", resourcePaths: [photoURL.path, pairedVideoURL.path])
        if let error = response.error { throw error }
        guard let identifier = response.identifier else {
            throw ServiceError(code: "PHOTO_SAVE_FAILED", message: "“照片”没有返回保存结果", recovery: "请重试")
        }
        return identifier
    }

    private static func launch(mode: String, resourcePaths: [String]) async throws -> PhotoWorkerResponse {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("Lives", isDirectory: true)
            .appendingPathComponent("photo-worker-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let responseURL = directory.appendingPathComponent("response.json")

        // Launch as a real, LSUIElement macOS application so the system can present
        // and persist the Photos consent alert. The helper has Lives's display
        // name but no Dock presence.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [mode, responseURL.path] + resourcePaths
        let application = try await NSWorkspace.shared.openApplication(
            at: try helperBundleURL(),
            configuration: configuration
        )

        for _ in 0..<1_200 {
            if fileManager.fileExists(atPath: responseURL.path) {
                let data = try Data(contentsOf: responseURL)
                return try JSONDecoder().decode(PhotoWorkerResponse.self, from: data)
            }
            if application.isTerminated { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ServiceError(code: "PHOTO_WORKER_FAILED", message: "照片后台服务未能完成", recovery: "请重新启动 App 后重试，或改为导出到文件夹")
    }

    private static func helperBundleURL() throws -> URL {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let bundle = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard bundle.pathExtension == "app", FileManager.default.fileExists(atPath: bundle.path) else {
            throw ServiceError(code: "PHOTO_WORKER_MISSING", message: "照片授权服务不可用", recovery: "请重新安装 Lives 后重试")
        }
        return bundle
    }
}
