import AppKit
import CryptoKit
import Foundation

enum UpdateServiceError: LocalizedError {
    case invalidURL(String)
    case downloadFailed(String)
    case missingIntegrity
    case sizeMismatch(expected: Int64, actual: Int64)
    case sha256Mismatch(expected: String, actual: String)
    case dmgMountFailed(String)
    case appNotFoundInDMG
    case stagingFailed(String)
    case invalidStagedApp(String)
    case signatureValidationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidURL(url):
            return "无效的更新下载地址：\(url)"
        case let .downloadFailed(reason):
            return "下载更新失败：\(reason)"
        case .missingIntegrity:
            return "更新源没有提供完整性校验信息，已停止安装"
        case let .sizeMismatch(expected, actual):
            return "更新包大小不匹配（预期：\(expected)，实际：\(actual)）"
        case let .sha256Mismatch(expected, actual):
            return "更新包校验失败（SHA256 不匹配，预期：\(expected)，实际：\(actual)）"
        case let .dmgMountFailed(reason):
            return "挂载更新磁盘映像失败：\(reason)"
        case .appNotFoundInDMG:
            return "更新安装包中未找到 Lives.app"
        case let .stagingFailed(reason):
            return "解压暂存更新文件失败：\(reason)"
        case let .invalidStagedApp(path):
            return "暂存的更新应用损坏或不完整：\(path)"
        case let .signatureValidationFailed(reason):
            return "更新应用签名校验失败：\(reason)"
        }
    }
}

/// 暂存更新的持久化清单：用于冷启动恢复「已下载未安装」的更新（Sparkle 语义）。
struct StagedUpdateManifest: Codable {
    let version: String
    let stagedAppPath: String
    let targetAppPath: String
    let dmgUrl: String?
    let sha256: String?
    let size: Int64?
    let source: String?
    let releaseNotes: String?
    let htmlUrl: String?
    let publishedAt: String?
    let isCritical: Bool?
    let downloadedAt: Date
}

private final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var completedURL: URL?
    private var finishError: Error?

    init(destination: URL, onProgress: @escaping (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func start(_ task: URLSessionDownloadTask, continuation: CheckedContinuation<URL, Error>) {
        self.continuation = continuation
        task.resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            onProgress(min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1))
        } else {
            // 没有 Content-Length 时无法给出百分比，但每个回调仍会刷新上层停滞计时。
            onProgress(0)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // 只接受自有域名或 GitHub 官方下载跳转，避免下载清单被篡改后跟随任意外链。
        let redirectURL = request.url
        let allowed = redirectURL?.scheme == "https" && (
            (redirectURL?.host == "download.1leaf.cc" && redirectURL?.path == "/Lives-latest.dmg")
                || ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"].contains(redirectURL?.host ?? "")
        )
        completionHandler(allowed ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            finishError = UpdateServiceError.downloadFailed("HTTP 状态码 \(response.statusCode)")
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: location, to: destination)
            completedURL = destination
        } catch {
            finishError = UpdateServiceError.downloadFailed("无法保存下载文件：\(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else if let finishError {
            continuation.resume(throwing: finishError)
        } else if let completedURL {
            continuation.resume(returning: completedURL)
        } else {
            continuation.resume(throwing: UpdateServiceError.downloadFailed("下载任务未产生文件"))
        }
        session.invalidateAndCancel()
    }
}

private final class UpdateMetadataDelegate: NSObject, URLSessionDataDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https" else {
            completionHandler(nil)
            return
        }
        let allowed = (url.host == "download.1leaf.cc" && url.path == "/lives-download-stats.json")
            || (url.host == "api.github.com" && url.path.hasPrefix("/repos/ohmyangboy/lives/releases"))
        completionHandler(allowed ? request : nil)
    }
}

enum UpdateService {
    static var updatesDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let updateDir = base.appendingPathComponent("com.yangbukun.lives/Updates", isDirectory: true)
        try? FileManager.default.createDirectory(at: updateDir, withIntermediateDirectories: true)
        return updateDir
    }

    static var stagedDirectory: URL {
        updatesDirectory.appendingPathComponent("staged", isDirectory: true)
    }

    static var stagedManifestURL: URL {
        updatesDirectory.appendingPathComponent("staged.json")
    }

    static var relaunchLogURL: URL {
        updatesDirectory.appendingPathComponent("relaunch.log")
    }

    private static let ownMetadataURL = URL(string: "https://download.1leaf.cc/lives-download-stats.json")!
    private static let ownDownloadURL = URL(string: "https://download.1leaf.cc/Lives-latest.dmg")!
    private static let githubMetadataBase = "https://api.github.com/repos/ohmyangboy/lives/releases"

    /// 获取受限的更新元数据。URL 由 source/version 构造，调用方不能传入任意地址。
    static func fetchMetadata(
        source: String,
        version: String?,
        cancellations: CancellationRegistry,
        requestId: String
    ) async throws -> UpdateMetadataResponse {
        let url: URL
        switch source {
        case "oneleaf":
            guard version == nil else { throw UpdateServiceError.invalidURL("自有源不接受版本参数") }
            url = ownMetadataURL
        case "github":
            if let version {
                let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "^v", with: "", options: .regularExpression)
                guard trimmed.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else {
                    throw UpdateServiceError.invalidURL("无效的 GitHub 版本")
                }
                url = URL(string: "\(githubMetadataBase)/tags/v\(trimmed)")!
            } else {
                url = URL(string: "\(githubMetadataBase)/latest")!
            }
        default:
            throw UpdateServiceError.invalidURL("不支持的更新源")
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 6
        request.setValue(source == "github" ? "application/vnd.github+json" : "application/json", forHTTPHeaderField: "Accept")
        request.setValue("Lives-Updater/1", forHTTPHeaderField: "User-Agent")

        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 6
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: UpdateMetadataDelegate(), delegateQueue: nil)

        defer { Task { await cancellations.finish(requestId) } }
        let result: (Data, URLResponse) = try await withTaskCancellationHandler(operation: { () -> (Data, URLResponse) in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, let response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: UpdateServiceError.downloadFailed("更新源没有返回内容"))
                    }
                }
                Task {
                    await cancellations.registerCancellation(requestId) { task.cancel() }
                }
                task.resume()
            }
        }, onCancel: {
            Task { await cancellations.cancel(requestId) }
        })
        session.invalidateAndCancel()

        let (data, response) = result
        guard data.count <= 2 * 1024 * 1024 else {
            throw UpdateServiceError.downloadFailed("更新元数据超过 2 MiB，已停止处理")
        }
        let http = response as? HTTPURLResponse
        return UpdateMetadataResponse(
            status: http?.statusCode ?? -1,
            body: String(decoding: data, as: UTF8.self),
            retryAfter: Int(http?.value(forHTTPHeaderField: "Retry-After") ?? ""),
            rateLimitReset: Int(http?.value(forHTTPHeaderField: "X-RateLimit-Reset") ?? "")
        )
    }

    // MARK: - 下载与暂存

    static func downloadAndPrepare(
        dmgURLString: String,
        expectedSHA256: String?,
        expectedSize: Int64?,
        expectedVersion: String?,
        expectedSource: String?,
        releaseNotes: String?,
        htmlURL: String?,
        publishedAt: String?,
        isCritical: Bool?,
        cancellations: CancellationRegistry? = nil,
        requestId: String? = nil,
        onProgress: @escaping (String, Double) -> Void
    ) async throws -> PreparedUpdateResult {
        guard let url = URL(string: dmgURLString) else {
            throw UpdateServiceError.invalidURL(dmgURLString)
        }
        guard url == ownDownloadURL ||
                (url.scheme == "https" && url.host == "github.com" && url.path.hasPrefix("/ohmyangboy/lives/releases/download/")) else {
            throw UpdateServiceError.invalidURL(dmgURLString)
        }
        let source = expectedSource ?? (url == ownDownloadURL ? "oneleaf" : "github")
        guard source == "oneleaf" || source == "github" else {
            throw UpdateServiceError.invalidURL("不支持的更新来源")
        }

        let updateDir = updatesDirectory
        let dmgPath = updateDir.appendingPathComponent("update-\(UUID().uuidString).dmg")
        var stagedReady = false
        defer {
            try? FileManager.default.removeItem(at: dmgPath)
            if !stagedReady {
                try? FileManager.default.removeItem(at: stagedDirectory)
                try? FileManager.default.removeItem(at: stagedManifestURL)
            }
            if let cancellations, let requestId {
                Task { await cancellations.finish(requestId) }
            }
        }

        guard let expectedSHA256, expectedSHA256.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil,
              let expectedSize, expectedSize > 0,
              let expectedVersion, expectedVersion.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else {
            throw UpdateServiceError.missingIntegrity
        }

        // 1. Download: URLSessionDownloadTask 从头开始，不复用旧临时文件，也不发送 Range。
        onProgress("downloading", 0.0)
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = false
        let delegate = UpdateDownloadDelegate(destination: dmgPath) { progress in
            onProgress("downloading", progress)
        }
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        if let cancellations, let requestId {
            await cancellations.registerCancellation(requestId) { task.cancel() }
        }
        _ = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(task, continuation: continuation)
            }
        }, onCancel: {
            task.cancel()
        })
        session.invalidateAndCancel()

        if let cancellations, let requestId {
            try await cancellations.check(requestId, throwing: .updateCancelled)
        }
        var hasher = SHA256()
        var receivedBytes: Int64 = 0
        onProgress("downloading", 1.0)
        guard let fileHandle = try? FileHandle(forReadingFrom: dmgPath) else {
            throw UpdateServiceError.downloadFailed("无法读取本地更新缓存文件")
        }
        defer { try? fileHandle.close() }
        while let chunk = try? fileHandle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            if let cancellations, let requestId {
                try await cancellations.check(requestId, throwing: .updateCancelled)
            }
            hasher.update(data: chunk)
            receivedBytes += Int64(chunk.count)
        }
        guard receivedBytes == expectedSize else {
            throw UpdateServiceError.sizeMismatch(expected: expectedSize, actual: receivedBytes)
        }

        // 2. Verify SHA-256
        onProgress("verifying", 0.0)
        let digest = hasher.finalize()
        let computedHex = digest.map { String(format: "%02x", $0) }.joined()
        if computedHex.lowercased() != expectedSHA256.lowercased() {
            throw UpdateServiceError.sha256Mismatch(expected: expectedSHA256, actual: computedHex)
        }
        onProgress("verifying", 1.0)

        // 3. Mount DMG and extract Lives.app
        if let cancellations, let requestId {
            try await cancellations.check(requestId, throwing: .updateCancelled)
        }
        onProgress("preparing", 0.1)
        let mountPoint = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("LivesMount-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        defer {
            _ = runCommand("/usr/bin/hdiutil", arguments: ["detach", mountPoint.path, "-force"])
            try? FileManager.default.removeItem(at: mountPoint)
        }

        let attachResult = runCommand("/usr/bin/hdiutil", arguments: [
            "attach", dmgPath.path,
            "-nobrowse",
            "-readonly",
            "-mountpoint", mountPoint.path
        ])

        guard attachResult.exitCode == 0 else {
            throw UpdateServiceError.dmgMountFailed(attachResult.error ?? "hdiutil attach exited with \(attachResult.exitCode)")
        }

        onProgress("preparing", 0.4)

        // Find .app bundle inside mount point
        guard let mountedItems = try? FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil),
              let appBundleURL = mountedItems.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateServiceError.appNotFoundInDMG
        }

        onProgress("preparing", 0.6)

        // Stage to persistent updates directory
        let stagedDir = stagedDirectory
        try? FileManager.default.removeItem(at: stagedDir)
        try? FileManager.default.createDirectory(at: stagedDir, withIntermediateDirectories: true)

        let destinationAppURL = stagedDir.appendingPathComponent(appBundleURL.lastPathComponent)
        if let cancellations, let requestId {
            try await cancellations.check(requestId, throwing: .updateCancelled)
        }
        do {
            try FileManager.default.copyItem(at: appBundleURL, to: destinationAppURL)
        } catch {
            throw UpdateServiceError.stagingFailed(error.localizedDescription)
        }

        onProgress("preparing", 0.9)

        // Read version from staged Info.plist
        let infoPlistPath = destinationAppURL.appendingPathComponent("Contents/Info.plist")
        var stagedVersion: String? = nil
        if let infoDict = NSDictionary(contentsOf: infoPlistPath) {
            stagedVersion = infoDict["CFBundleShortVersionString"] as? String
        }

        let targetAppPath = locateTargetAppPath()

        // 4. 写入恢复清单：下次冷启动若发现未安装的更新，可直接进入 readyToInstall。
        guard stagedVersion == expectedVersion else {
            throw UpdateServiceError.invalidStagedApp("版本不匹配：预期 v\(expectedVersion)，实际 \(stagedVersion ?? "未知")")
        }
        try validateStagedBundle(destinationAppURL, expectedVersion: expectedVersion)

        if let stagedVersion, !stagedVersion.isEmpty {
            let manifest = StagedUpdateManifest(
                version: stagedVersion,
                stagedAppPath: destinationAppURL.path,
                targetAppPath: targetAppPath,
                dmgUrl: dmgURLString,
                sha256: expectedSHA256.lowercased(),
                size: expectedSize,
                source: source,
                releaseNotes: releaseNotes,
                htmlUrl: htmlURL,
                publishedAt: publishedAt,
                isCritical: isCritical,
                downloadedAt: Date()
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(manifest)
            try data.write(to: stagedManifestURL, options: .atomic)
        }
        onProgress("preparing", 1.0)
        stagedReady = true

        return PreparedUpdateResult(
            stagedAppPath: destinationAppURL.path,
            targetAppPath: targetAppPath,
            version: stagedVersion,
            dmgUrl: dmgURLString,
            sha256: expectedSHA256.lowercased(),
            size: expectedSize,
            source: source,
            releaseNotes: releaseNotes,
            htmlUrl: htmlURL,
            publishedAt: publishedAt,
            isCritical: isCritical
        )
    }

    /// 安装前的最低身份边界：Bundle ID、候选版本、arm64 和公证/Developer ID 签名。
    private static func validateStagedBundle(_ bundleURL: URL, expectedVersion: String) throws {
        let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL),
              info["CFBundleIdentifier"] as? String == "com.yangbukun.lives",
              info["CFBundleShortVersionString"] as? String == expectedVersion,
              let executableName = info["CFBundleExecutable"] as? String else {
            throw UpdateServiceError.invalidStagedApp("Bundle ID 或版本不匹配")
        }
        let executableURL = bundleURL.appendingPathComponent("Contents/MacOS").appendingPathComponent(executableName)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw UpdateServiceError.invalidStagedApp("主可执行文件不存在")
        }

        let architecture = runCommand("/usr/bin/lipo", arguments: ["-archs", executableURL.path])
        guard architecture.exitCode == 0,
              architecture.output?.split(whereSeparator: { $0 == " " || $0 == "\n" }).contains("arm64") == true else {
            throw UpdateServiceError.invalidStagedApp("更新包不是 Apple Silicon arm64 架构")
        }

        let verification = runCommand("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", bundleURL.path])
        guard verification.exitCode == 0 else {
            throw UpdateServiceError.signatureValidationFailed(verification.error ?? "codesign verify 失败")
        }
        let details = runCommand("/usr/bin/codesign", arguments: ["-dv", "--verbose=4", bundleURL.path])
        let signatureText = (details.output ?? "") + (details.error ?? "")
        guard details.exitCode == 0,
              signatureText.contains("TeamIdentifier=LGKLTGNTY2"),
              signatureText.contains("Authority=Developer ID Application") else {
            throw UpdateServiceError.signatureValidationFailed("不是预期的 Developer ID Team（LGKLTGNTY2）")
        }
    }

    // MARK: - 中断恢复（Sparkle 的 stage: .downloaded 语义）

    /// 校验暂存清单：bundle 完整且版本比当前运行版本新时返回可安装信息，否则清理残留。
    static func stagedUpdate() -> PreparedUpdateResult? {
        let fileManager = FileManager.default
        guard let data = try? Data(contentsOf: stagedManifestURL),
              let manifest = try? JSONDecoder.makeWithISODate().decode(StagedUpdateManifest.self, from: data),
              manifest.sha256?.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil,
              (manifest.size ?? 0) > 0,
              manifest.dmgUrl != nil,
              manifest.source == "oneleaf" || manifest.source == "github",
              fileManager.fileExists(atPath: manifest.stagedAppPath),
              fileManager.fileExists(atPath: (manifest.stagedAppPath as NSString).appendingPathComponent("Contents/MacOS"))
        else {
            cleanupStaleStaging()
            return nil
        }

        if let currentVersion = currentRunningAppVersion(),
           let newer = isVersion(manifest.version, newerThan: currentVersion), !newer {
            // 暂存版本不比当前新（已安装过或过旧）→ 清理。
            cleanupStaleStaging()
            return nil
        }

        guard (try? validateStagedBundle(URL(fileURLWithPath: manifest.stagedAppPath), expectedVersion: manifest.version)) != nil else {
            cleanupStaleStaging()
            return nil
        }

        return PreparedUpdateResult(
            stagedAppPath: manifest.stagedAppPath,
            targetAppPath: manifest.targetAppPath,
            version: manifest.version,
            dmgUrl: manifest.dmgUrl,
            sha256: manifest.sha256,
            size: manifest.size,
            source: manifest.source,
            releaseNotes: manifest.releaseNotes,
            htmlUrl: manifest.htmlUrl,
            publishedAt: manifest.publishedAt,
            isCritical: manifest.isCritical
        )
    }

    static func cleanupStaleStaging() {
        try? FileManager.default.removeItem(at: stagedDirectory)
        try? FileManager.default.removeItem(at: stagedManifestURL)
    }

    // MARK: - 安装与重启

    static func installAndRelaunch(stagedAppPath: String, targetAppPath: String?) throws {
        let stagedURL = URL(fileURLWithPath: stagedAppPath)
        guard FileManager.default.fileExists(atPath: stagedAppPath),
              FileManager.default.fileExists(atPath: stagedURL.appendingPathComponent("Contents/MacOS").path) else {
            throw UpdateServiceError.invalidStagedApp(stagedAppPath)
        }
        guard let info = NSDictionary(contentsOf: stagedURL.appendingPathComponent("Contents/Info.plist")),
              let stagedVersion = info["CFBundleShortVersionString"] as? String else {
            throw UpdateServiceError.invalidStagedApp(stagedAppPath)
        }
        guard let manifestData = try? Data(contentsOf: stagedManifestURL),
              let manifest = try? JSONDecoder.makeWithISODate().decode(StagedUpdateManifest.self, from: manifestData),
              manifest.stagedAppPath == stagedAppPath,
              manifest.version == stagedVersion,
              manifest.sha256?.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil,
              (manifest.size ?? 0) > 0,
              manifest.dmgUrl != nil,
              manifest.source == "oneleaf" || manifest.source == "github" else {
            throw UpdateServiceError.invalidStagedApp("暂存清单与更新应用不匹配")
        }
        try validateStagedBundle(stagedURL, expectedVersion: stagedVersion)

        let target = targetAppPath ?? locateTargetAppPath()
        let updateDir = updatesDirectory

        // 日志超过 256KB 时轮转，保留最近一次尝试的完整记录。
        let logURL = relaunchLogURL
        if let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let size = attributes[.size] as? Int, size > 256 * 1024 {
            try? FileManager.default.removeItem(at: logURL)
        }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }

        let scriptURL = updateDir.appendingPathComponent("relaunch-\(UUID().uuidString).sh")
        try relaunchScript().write(to: scriptURL, atomically: true, encoding: .utf8)
        _ = runCommand("/bin/chmod", arguments: ["+x", scriptURL.path])

        // 等待的是 Tauri 主进程（sidecar 的父进程）。
        let pidToWait = getppid() > 1 ? getppid() : getpid()

        // nohup + 三向 stdio 重定向：父进程树（Tauri → sidecar）退出后脚本以孤儿进程
        // 继续存活，不受断管道/SIGHUP 影响；脚本自身把过程写入 relaunch.log。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        process.arguments = [
            "/bin/sh",
            scriptURL.path,
            logURL.path,
            String(pidToWait),
            stagedAppPath,
            target,
            updateDir.path
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// 生成 relaunch 安装脚本（纯函数，便于测试与审查）。
    /// 语义：温和等待父进程退出（TERM 升级 KILL）→ rename 原子换包（可回滚）→
    /// 启动并验证进程存在 → 降级链 → 全程日志。
    static func relaunchScript() -> String {
        """
        #!/bin/sh
        # Lives relaunch installer (generated by UpdateService).
        # Args: 1=LOG 2=PARENT_PID 3=STAGED_APP 4=TARGET_APP 5=UPDATES_DIR
        LOG="$1"
        PARENT_PID="$2"
        STAGED_APP="$3"
        TARGET_APP="$4"
        UPDATES_DIR="$5"

        log() {
          printf '[%s] %s\\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
        }

        fail() {
          log "FAILED: $*"
          log "hint: staged bundle kept at $STAGED_APP for manual recovery"
          exit 1
        }

        log "=== relaunch begin (script pid $$, parent=$PARENT_PID) ==="
        log "staged=$STAGED_APP"
        log "target=$TARGET_APP"
        log "updates_dir=$UPDATES_DIR"

        [ -d "$STAGED_APP/Contents/MacOS" ] || fail "staged bundle invalid: $STAGED_APP"

        # --- 1. 等待父进程退出：10s 宽限 -> SIGTERM 3s -> SIGKILL 5s 后放行
        if [ -n "$PARENT_PID" ] && [ "$PARENT_PID" -gt 1 ] 2>/dev/null; then
          COUNT=0
          PHASE=0
          while kill -0 "$PARENT_PID" 2>/dev/null; do
            sleep 0.2
            COUNT=$((COUNT + 1))
            if [ "$PHASE" -eq 0 ] && [ "$COUNT" -ge 50 ]; then
              log "parent alive after 10s, sending SIGTERM"
              kill "$PARENT_PID" 2>/dev/null
              PHASE=1
              COUNT=0
            elif [ "$PHASE" -eq 1 ] && [ "$COUNT" -ge 15 ]; then
              log "parent alive after SIGTERM, sending SIGKILL"
              kill -9 "$PARENT_PID" 2>/dev/null
              PHASE=2
            elif [ "$PHASE" -eq 2 ] && [ "$COUNT" -ge 25 ]; then
              log "parent still alive after SIGKILL, proceeding anyway"
              break
            fi
          done
          log "parent exited"
        else
          log "no parent pid to wait for"
        fi

        sleep 0.3

        # --- 2. 原子换包：同卷 rename 优先，失败回滚；跨卷 ditto；最终兜底 ~/Applications
        OLD_BUNDLE="$TARGET_APP.old-$$-$(date +%s)"

        swap_same_volume() {
          if [ ! -d "$TARGET_APP" ]; then
            if mv "$STAGED_APP" "$TARGET_APP" 2>>"$LOG"; then return 0; fi
            return 1
          fi
          if ! mv "$TARGET_APP" "$OLD_BUNDLE" 2>>"$LOG"; then return 1; fi
          if mv "$STAGED_APP" "$TARGET_APP" 2>>"$LOG"; then return 0; fi
          log "mv staged->target failed, rolling back"
          mv "$OLD_BUNDLE" "$TARGET_APP" 2>>"$LOG" || log "ROLLBACK FAILED: old bundle at $OLD_BUNDLE"
          return 1
        }

        swap_copy() {
          NEW_BUNDLE="${TARGET_APP}.new-$$"
          if ! ditto "$STAGED_APP" "$NEW_BUNDLE" 2>>"$LOG"; then
            rm -rf "$NEW_BUNDLE" 2>/dev/null
            return 1
          fi
          if [ -d "$TARGET_APP" ]; then
            if ! mv "$TARGET_APP" "$OLD_BUNDLE" 2>>"$LOG"; then
              rm -rf "$NEW_BUNDLE" 2>/dev/null
              return 1
            fi
          fi
          if mv "$NEW_BUNDLE" "$TARGET_APP" 2>>"$LOG"; then return 0; fi
          log "mv new->target failed, rolling back"
          if [ -d "$OLD_BUNDLE" ]; then mv "$OLD_BUNDLE" "$TARGET_APP" 2>>"$LOG" || log "ROLLBACK FAILED: old bundle at $OLD_BUNDLE"; fi
          rm -rf "$NEW_BUNDLE" 2>/dev/null
          return 1
        }

        SWAPPED=0
        TARGET_DIR="$(dirname "$TARGET_APP")"
        mkdir -p "$TARGET_DIR" 2>>"$LOG"
        if swap_same_volume; then
          SWAPPED=1
          log "swap: rename ok"
        elif swap_copy; then
          SWAPPED=1
          log "swap: ditto copy ok"
        else
          USER_TARGET="$HOME/Applications/Lives.app"
          log "primary target not writable, falling back to $USER_TARGET"
          TARGET_APP="$USER_TARGET"
          TARGET_DIR="$(dirname "$TARGET_APP")"
          mkdir -p "$TARGET_DIR" 2>>"$LOG"
          rm -rf "$TARGET_APP" 2>/dev/null
          if swap_same_volume || swap_copy; then
            SWAPPED=1
            log "swap: ok in fallback location"
          else
            fail "all swap strategies failed"
          fi
        fi

        xattr -cr "$TARGET_APP" 2>>"$LOG" || log "xattr clear failed (non-fatal)"
        log "swap complete: $TARGET_APP"

        # --- 3. 启动并验证进程存在（pgrep 轮询 6s），失败逐级降级
        launch_and_verify() {
          COUNT=0
          while [ "$COUNT" -lt 30 ]; do
            sleep 0.2
            COUNT=$((COUNT + 1))
            if pgrep -f "$TARGET_APP/Contents/MacOS" >/dev/null 2>&1; then
              return 0
            fi
          done
          return 1
        }

        RELAUNCHED=0
        if open -n "$TARGET_APP" 2>>"$LOG" && launch_and_verify; then
          RELAUNCHED=1
          log "relaunch: open -n verified"
        else
          log "open -n did not yield a running process, trying plain open"
          if open "$TARGET_APP" 2>>"$LOG" && launch_and_verify; then
            RELAUNCHED=1
            log "relaunch: open verified"
          else
            log "open fallback failed, launching executable directly"
            EXEC_BIN="$(ls "$TARGET_APP/Contents/MacOS/" 2>/dev/null | head -n 1)"
            if [ -n "$EXEC_BIN" ]; then
              nohup "$TARGET_APP/Contents/MacOS/$EXEC_BIN" >/dev/null 2>&1 &
              sleep 2
              if pgrep -f "$TARGET_APP/Contents/MacOS" >/dev/null 2>&1; then
                RELAUNCHED=1
                log "relaunch: direct exec verified"
              fi
            else
              log "no executable found under $TARGET_APP/Contents/MacOS"
            fi
          fi
        fi

        # --- 4. 清理：仅在复活验证通过后删除旧包、暂存目录与清单；
        #         失败时保留现场（日志 + staging）供诊断与恢复。
        if [ "$RELAUNCHED" -eq 1 ]; then
          if [ -d "$OLD_BUNDLE" ]; then
            rm -rf "$OLD_BUNDLE" 2>>"$LOG" || log "warning: failed to remove old bundle $OLD_BUNDLE"
          fi
          rm -rf "$UPDATES_DIR/staged" 2>>"$LOG"
          rm -f "$UPDATES_DIR/staged.json" 2>>"$LOG"
          log "SUCCESS: relaunched $TARGET_APP"
          rm -f "$0" 2>/dev/null
          exit 0
        fi

        fail "swap ok but relaunch could not be verified"
        """
    }

    // MARK: - 路径与版本工具

    static func locateTargetAppPath() -> String {
        // Look for running Lives.app outer bundle path
        let executablePath = CommandLine.arguments[0]
        var current = URL(fileURLWithPath: executablePath)
        var candidate: String? = nil
        while current.pathComponents.count > 1 {
            if current.pathExtension == "app" {
                if !current.lastPathComponent.contains("Helper") {
                    candidate = current.path
                }
            }
            current.deleteLastPathComponent()
        }
        if let found = candidate {
            return found
        }

        let defaultApp = "/Applications/Lives.app"
        if FileManager.default.fileExists(atPath: defaultApp) {
            return defaultApp
        }

        let userApp = (NSHomeDirectory() as NSString).appendingPathComponent("Applications/Lives.app")
        if FileManager.default.fileExists(atPath: userApp) {
            return userApp
        }

        return defaultApp
    }

    /// 当前运行 Lives.app 的 CFBundleShortVersionString（供暂存恢复比较用）。
    static func currentRunningAppVersion() -> String? {
        let executablePath = CommandLine.arguments[0]
        var current = URL(fileURLWithPath: executablePath)
        while current.pathComponents.count > 1 {
            if current.pathExtension == "app", !current.lastPathComponent.contains("Helper") {
                let infoPlist = current.appendingPathComponent("Contents/Info.plist")
                if let infoDict = NSDictionary(contentsOf: infoPlist),
                   let version = infoDict["CFBundleShortVersionString"] as? String {
                    return version
                }
            }
            current.deleteLastPathComponent()
        }
        return nil
    }

    /// 返回 a 是否比 b 新；无法解析时返回 nil。
    static func isVersion(_ a: String, newerThan b: String) -> Bool? {
        guard let pa = versionParts(a), let pb = versionParts(b) else { return nil }
        for index in 0..<3 {
            let left = pa.core[index]
            let right = pb.core[index]
            if left != right { return left > right }
        }
        if pa.prerelease.isEmpty || pb.prerelease.isEmpty {
            return pa.prerelease.isEmpty && !pb.prerelease.isEmpty
        }
        for index in 0..<max(pa.prerelease.count, pb.prerelease.count) {
            guard index < pa.prerelease.count else { return false }
            guard index < pb.prerelease.count else { return true }
            let left = pa.prerelease[index], right = pb.prerelease[index]
            if left == right { continue }
            if let a = Int(left), let b = Int(right) { return a > b }
            if Int(left) != nil { return false }
            if Int(right) != nil { return true }
            return left > right
        }
        return false
    }

    private static func versionParts(_ value: String) -> (core: [Int], prerelease: [String])? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^[vV]?([0-9]+)(?:\.([0-9]+))?(?:\.([0-9]+))?(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) else { return nil }
        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: trimmed) else { return nil }
            return String(trimmed[range])
        }
        let core = (1...3).compactMap { Int(group($0) ?? "0") }
        guard core.count == 3 else { return nil }
        return (core, group(4)?.components(separatedBy: ".") ?? [])
    }

    private static func runCommand(_ executable: String, arguments: [String]) -> (exitCode: Int32, output: String?, error: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outData, encoding: .utf8)
            let error = String(data: errData, encoding: .utf8)
            return (process.terminationStatus, output, error)
        } catch {
            return (-1, nil, error.localizedDescription)
        }
    }
}

extension JSONDecoder {
    static func makeWithISODate() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
