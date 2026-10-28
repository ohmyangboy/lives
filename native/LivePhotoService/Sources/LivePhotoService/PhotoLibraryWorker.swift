import AppKit
import Foundation
import Photos

private struct PhotoWorkerResponse: Codable {
    var authorized: Bool?
    var identifier: String?
    var statusCode: Int?
    var error: ServiceError?
    var imported: [ImportedLivePhoto]?
}

enum PhotoLibraryWorker {
    static func runIfRequested(arguments: [String]) async -> Bool {
        if let modeIndex = arguments.firstIndex(of: "photo-import"), arguments.indices.contains(modeIndex + 2) {
            PhotoAuthorization.appendDiagnosticsLog("photo-import: worker started")
            let responseURL = URL(fileURLWithPath: arguments[modeIndex + 1])
            let directory = URL(fileURLWithPath: arguments[modeIndex + 2], isDirectory: true)
            do {
                try PhotoAuthorization.validateSigningConfiguration()
                await prepareApplicationForPhotoKit()
                PhotoAuthorization.appendDiagnosticsLog("photo-import: requesting read authorization")
                let status = await requestReadAuthorizationDirect()
                PhotoAuthorization.appendDiagnosticsLog("photo-import: authorization status=\(status.rawValue)")
                if let error = PhotoAuthorization.readError(for: status) { throw error }
                let identifiers = try await LivePhotoLibraryPicker().select(limited: status == .limited)
                PhotoAuthorization.appendDiagnosticsLog("photo-import: selected count=\(identifiers.count)")
                let imported = try await PhotoLibraryImporter.export(identifiers: identifiers, to: directory)
                PhotoAuthorization.appendDiagnosticsLog("photo-import: completed count=\(imported.count)")
                write(PhotoWorkerResponse(imported: imported), to: responseURL)
            } catch let error as ServiceError {
                PhotoAuthorization.appendDiagnosticsLog("photo-import: failed code=\(error.code)")
                write(PhotoWorkerResponse(error: error), to: responseURL)
            } catch {
                write(PhotoWorkerResponse(error: ErrorMapper.map(error)), to: responseURL)
            }
            return true
        }

        if let modeIndex = arguments.firstIndex(of: "photo-status"), arguments.indices.contains(modeIndex + 1) {
            let responseURL = URL(fileURLWithPath: arguments[modeIndex + 1])
            await prepareApplicationForPhotoKit()
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            write(PhotoWorkerResponse(authorized: status == .authorized, identifier: nil, statusCode: status.rawValue, error: nil), to: responseURL)
            return true
        }

        if let modeIndex = arguments.firstIndex(of: "photo-authorize"), arguments.indices.contains(modeIndex + 1) {
            let responseURL = URL(fileURLWithPath: arguments[modeIndex + 1])
            do {
                try PhotoAuthorization.validateSigningConfiguration()
            } catch {
                write(PhotoWorkerResponse(authorized: false, identifier: nil, error: PhotoAuthorization.configurationError), to: responseURL)
                return true
            }
            await prepareApplicationForPhotoKit()
            let outcome = await requestAddOnlyAuthorizationDirect()
            let authorized = outcome.status == .authorized
            let error = outcome.promptSuppressed ? PhotoAuthorization.promptSuppressedError : PhotoAuthorization.error(for: outcome.status)
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
                PhotoAuthorization.appendDiagnosticsLog("photo-save: ok")
                write(PhotoWorkerResponse(authorized: true, identifier: identifier, error: nil), to: responseURL)
            } catch let error as ServiceError {
                PhotoAuthorization.appendDiagnosticsLog("photo-save: failed code=\(error.code)")
                write(PhotoWorkerResponse(authorized: true, identifier: nil, error: error), to: responseURL)
            } catch {
                PhotoAuthorization.appendDiagnosticsLog("photo-save: failed code=UNMAPPED")
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
        application.activate(ignoringOtherApps: true)
    }

    struct AuthorizationOutcome {
        var status: PHAuthorizationStatus
        // 系统没有真正弹窗而是自动拒绝的特征：人工在 2 秒内看到并点击"不允许"
        // 几乎不可能。这种拒绝会把 TCC 记录重新写回 denied，必须走终端命令路径。
        var promptSuppressed: Bool
    }

    @MainActor
    private static func requestAddOnlyAuthorizationDirect() -> AuthorizationOutcome {
        let entryStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        PhotoAuthorization.appendDiagnosticsLog("photo-authorize: enter, status=\(entryStatus.rawValue)")
        var status = entryStatus
        var promptSuppressed = false
        if status == .notDetermined {
            var completed = false
            let requestedAt = Date()
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { requestedStatus in
                status = requestedStatus
                completed = true
            }
            while !completed {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
            let elapsed = Date().timeIntervalSince(requestedAt)
            promptSuppressed = elapsed < 2.0 && status == .denied
            PhotoAuthorization.appendDiagnosticsLog("photo-authorize: handler after \(Int(elapsed * 1000))ms, status=\(status.rawValue), promptSuppressed=\(promptSuppressed)")
        } else {
            PhotoAuthorization.appendDiagnosticsLog("photo-authorize: skipped prompt, status=\(status.rawValue)")
        }
        return AuthorizationOutcome(status: status, promptSuppressed: promptSuppressed)
    }

    private static func requestReadAuthorizationDirect() async -> PHAuthorizationStatus {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .notDetermined else { return status }
        return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
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
    static func importLivePhotos() async throws -> [ImportedLivePhoto] {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
            .appendingPathComponent("Lives/ImportedLivePhotos", isDirectory: true)
        return try await withImportDirectory(root: root) { directory in
            let response = try await launch(mode: "photo-import", resourcePaths: [directory.path])
            if let error = response.error { throw error }
            guard let imported = response.imported else {
                throw ServiceError(code: "PHOTO_IMPORT_FAILED", message: "照片服务没有返回导入结果", recovery: "请重新尝试，或使用文件配对导入")
            }
            return imported
        }
    }

    /// Only a successful nonempty import owns durable resources. Cancel/error paths discard this batch.
    static func withImportDirectory(root: URL, operation: (URL) async throws -> [ImportedLivePhoto]) async throws -> [ImportedLivePhoto] {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var keepResources = false
        defer { if !keepResources { try? FileManager.default.removeItem(at: directory) } }
        let imported = try await operation(directory)
        keepResources = !imported.isEmpty
        return imported
    }

    // 常驻 serve 进程内的 PhotoKit 状态可能滞后；需要权威状态时
    // 启动全新 helper 进程读取（与授权弹窗同一身份通道）。
    static func readAuthorizationStatus() async -> PHAuthorizationStatus? {
        guard let response = try? await launch(mode: "photo-status", resourcePaths: []),
              let rawValue = response.statusCode,
              let status = PHAuthorizationStatus(rawValue: rawValue) else { return nil }
        return status
    }

    static func requestAuthorization() async throws {
        let response = try await launch(mode: "photo-authorize", resourcePaths: [])
        if let error = response.error { throw error }
        guard response.authorized == true else {
            throw ServiceError(code: "PHOTO_PERMISSION_DENIED", message: "没有照片写入权限", recovery: "请点击“重新授权并保存”唤起系统授权框并允许添加照片；也可以改为导出到文件夹")
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
        let application: NSRunningApplication
        do {
            application = try await NSWorkspace.shared.openApplication(at: try helperBundleURL(), configuration: configuration)
        } catch {
            if let serviceError = error as? ServiceError { throw serviceError }
            throw ServiceError(code: "PHOTO_WORKER_FAILED", message: "无法启动照片导入服务", recovery: "请重新启动 Lives 后重试，或使用文件配对导入")
        }
        if mode == "photo-import" { PhotoAuthorization.appendDiagnosticsLog("photo-import: launched pid=\(application.processIdentifier)") }

        // Picker interaction and iCloud downloads may take longer than a save operation.
        // On failure terminate the worker before the caller removes its partial resource directory.
        var receivedResponse = false
        defer {
            if mode == "photo-import" && !receivedResponse && !application.isTerminated {
                application.forceTerminate()
            }
        }
        let polls = 1_200
        for _ in 0..<polls {
            try Task.checkCancellation()
            if fileManager.fileExists(atPath: responseURL.path) {
                let data = try Data(contentsOf: responseURL)
                let response = try JSONDecoder().decode(PhotoWorkerResponse.self, from: data)
                receivedResponse = true
                return response
            }
            if application.isTerminated {
                throw ServiceError(code: "PHOTO_WORKER_FAILED", message: "照片导入服务意外退出", recovery: "请重试，或使用文件配对导入")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if mode == "photo-import" {
            throw ServiceError(code: "PHOTO_IMPORT_TIMEOUT", message: "照片导入等待超过 2 分钟", recovery: "请检查照片选择器和 iCloud 下载后重试，或使用文件配对导入")
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
