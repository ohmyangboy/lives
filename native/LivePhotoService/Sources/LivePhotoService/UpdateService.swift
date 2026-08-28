import AppKit
import CryptoKit
import Foundation

enum UpdateServiceError: LocalizedError {
    case invalidURL(String)
    case downloadFailed(String)
    case sha256Mismatch(expected: String, actual: String)
    case dmgMountFailed(String)
    case appNotFoundInDMG
    case stagingFailed(String)
    case invalidStagedApp(String)

    var errorDescription: String? {
        switch self {
        case let .invalidURL(url):
            return "无效的更新下载地址：\(url)"
        case let .downloadFailed(reason):
            return "下载更新失败：\(reason)"
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
        }
    }
}

enum UpdateService {
    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let updateDir = base.appendingPathComponent("com.yangbukun.lives/Updates", isDirectory: true)
        try? FileManager.default.createDirectory(at: updateDir, withIntermediateDirectories: true)
        return updateDir
    }

    static func downloadAndPrepare(
        dmgURLString: String,
        expectedSHA256: String?,
        onProgress: @escaping (String, Double) -> Void
    ) async throws -> PreparedUpdateResult {
        guard let url = URL(string: dmgURLString) else {
            throw UpdateServiceError.invalidURL(dmgURLString)
        }

        let updateDir = cacheDirectory
        let dmgPath = updateDir.appendingPathComponent("update-\(UUID().uuidString).dmg")
        defer {
            try? FileManager.default.removeItem(at: dmgPath)
        }

        // 1. Download
        onProgress("downloading", 0.0)
        var hasher = SHA256()

        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration)

        let (asyncBytes, response) = try await session.bytes(from: url)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw UpdateServiceError.downloadFailed("HTTP 状态码 \(status)")
        }

        let expectedLength = response.expectedContentLength
        FileManager.default.createFile(atPath: dmgPath.path, contents: nil)
        guard let fileHandle = try? FileHandle(forWritingTo: dmgPath) else {
            throw UpdateServiceError.downloadFailed("无法创建本地更新缓存文件")
        }

        var receivedBytes: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)

        var lastReportedFraction: Double = 0.0

        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                hasher.update(data: buffer)
                fileHandle.write(buffer)
                receivedBytes += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                if expectedLength > 0 {
                    let fraction = min(max(Double(receivedBytes) / Double(expectedLength), 0.0), 1.0)
                    if fraction - lastReportedFraction >= 0.02 || fraction >= 0.99 {
                        lastReportedFraction = fraction
                        onProgress("downloading", fraction)
                    }
                }
            }
        }

        if !buffer.isEmpty {
            hasher.update(data: buffer)
            fileHandle.write(buffer)
            receivedBytes += Int64(buffer.count)
        }
        try? fileHandle.close()

        onProgress("downloading", 1.0)

        // 2. Verify SHA-256 if provided
        let digest = hasher.finalize()
        let computedHex = digest.map { String(format: "%02x", $0) }.joined()

        if let expected = expectedSHA256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !expected.isEmpty {
            onProgress("verifying", 0.0)
            if computedHex.lowercased() != expected {
                throw UpdateServiceError.sha256Mismatch(expected: expected, actual: computedHex)
            }
            onProgress("verifying", 1.0)
        }

        // 3. Mount DMG and extract Lives.app
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
        let stagedDir = updateDir.appendingPathComponent("staged", isDirectory: true)
        try? FileManager.default.removeItem(at: stagedDir)
        try? FileManager.default.createDirectory(at: stagedDir, withIntermediateDirectories: true)

        let destinationAppURL = stagedDir.appendingPathComponent(appBundleURL.lastPathComponent)
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

        onProgress("preparing", 1.0)

        return PreparedUpdateResult(
            stagedAppPath: destinationAppURL.path,
            targetAppPath: targetAppPath,
            version: stagedVersion
        )
    }

    static func installAndRelaunch(stagedAppPath: String, targetAppPath: String?) throws {
        let stagedURL = URL(fileURLWithPath: stagedAppPath)
        guard FileManager.default.fileExists(atPath: stagedAppPath),
              FileManager.default.fileExists(atPath: stagedURL.appendingPathComponent("Contents/MacOS").path) else {
            throw UpdateServiceError.invalidStagedApp(stagedAppPath)
        }

        let target = targetAppPath ?? locateTargetAppPath()

        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lives_relaunch_\(UUID().uuidString).sh")
        let scriptContent = """
        #!/bin/sh
        PARENT_PID="$1"
        STAGED_APP="$2"
        TARGET_APP="$3"

        # Wait for the current Lives app to exit
        if [ -n "$PARENT_PID" ]; then
          while kill -0 "$PARENT_PID" 2>/dev/null; do
            sleep 0.1
          done
        fi

        sleep 0.2

        # Replace target app with staged app
        rm -rf "$TARGET_APP"
        mkdir -p "$(dirname "$TARGET_APP")"
        cp -R "$STAGED_APP" "$TARGET_APP"

        # Clear quarantine attributes
        xattr -cr "$TARGET_APP" 2>/dev/null || true

        # Relaunch the new app
        open -n "$TARGET_APP"

        # Clean staging and script
        rm -rf "$(dirname "$STAGED_APP")"
        rm -f "$0"
        """

        try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        _ = runCommand("/bin/chmod", arguments: ["+x", scriptURL.path])

        // Find main application PID (parent process or current process)
        let pidToWait = getppid() > 1 ? getppid() : getpid()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path, "\(pidToWait)", stagedAppPath, target]
        try process.run()

        // Exit this helper process
        exit(0)
    }

    private static func locateTargetAppPath() -> String {
        // Look for running Lives.app bundle path
        let executablePath = CommandLine.arguments[0]
        var current = URL(fileURLWithPath: executablePath)
        while current.pathComponents.count > 1 {
            if current.pathExtension == "app" && current.lastPathComponent.contains("Lives") {
                return current.path
            }
            current.deleteLastPathComponent()
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
