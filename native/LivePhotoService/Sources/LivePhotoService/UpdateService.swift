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

/// 暂存更新的持久化清单：用于冷启动恢复「已下载未安装」的更新（Sparkle 语义）。
struct StagedUpdateManifest: Codable {
    let version: String
    let stagedAppPath: String
    let targetAppPath: String
    let sha256: String?
    let downloadedAt: Date
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

    // MARK: - 下载与暂存

    static func downloadAndPrepare(
        dmgURLString: String,
        expectedSHA256: String?,
        cancellations: CancellationRegistry? = nil,
        requestId: String? = nil,
        onProgress: @escaping (String, Double) -> Void
    ) async throws -> PreparedUpdateResult {
        guard let url = URL(string: dmgURLString) else {
            throw UpdateServiceError.invalidURL(dmgURLString)
        }

        let updateDir = updatesDirectory
        let dmgPath = updateDir.appendingPathComponent("update-\(UUID().uuidString).dmg")
        defer {
            try? FileManager.default.removeItem(at: dmgPath)
            if let cancellations, let requestId {
                Task { await cancellations.finish(requestId) }
            }
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

        // 停滞保护：URLSession 的 timeoutIntervalForRequest 是空闲计时器，
        // 数据传输阶段同样生效（每次收到数据重置），静默超过 60s 会原生抛出超时。

        var receivedBytes: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)

        var lastReportedFraction: Double = 0.0

        for try await byte in asyncBytes {
            if let cancellations, let requestId {
                try await cancellations.check(requestId, throwing: .updateCancelled)
            }
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

        // 4. 写入恢复清单：下次冷启动若发现未安装的更新，可直接进入 readyToInstall。
        if let stagedVersion, !stagedVersion.isEmpty {
            let manifest = StagedUpdateManifest(
                version: stagedVersion,
                stagedAppPath: destinationAppURL.path,
                targetAppPath: targetAppPath,
                sha256: expectedSHA256,
                downloadedAt: Date()
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted]
            if let data = try? encoder.encode(manifest) {
                try? data.write(to: stagedManifestURL, options: .atomic)
            }
        }

        return PreparedUpdateResult(
            stagedAppPath: destinationAppURL.path,
            targetAppPath: targetAppPath,
            version: stagedVersion
        )
    }

    // MARK: - 中断恢复（Sparkle 的 stage: .downloaded 语义）

    /// 校验暂存清单：bundle 完整且版本比当前运行版本新时返回可安装信息，否则清理残留。
    static func stagedUpdate() -> PreparedUpdateResult? {
        let fileManager = FileManager.default
        guard let data = try? Data(contentsOf: stagedManifestURL),
              let manifest = try? JSONDecoder.makeWithISODate().decode(StagedUpdateManifest.self, from: data),
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

        return PreparedUpdateResult(
            stagedAppPath: manifest.stagedAppPath,
            targetAppPath: manifest.targetAppPath,
            version: manifest.version
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
        for index in 0..<max(pa.count, pb.count) {
            let left = index < pa.count ? pa[index] : 0
            let right = index < pb.count ? pb[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func versionParts(_ value: String) -> [Int]? {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed = String(trimmed.dropFirst())
        }
        let components = trimmed.split(whereSeparator: { $0 == "." || $0 == "-" })
        guard !components.isEmpty else { return nil }
        let parts = components.compactMap { Int($0) }
        guard parts.count == components.count else { return nil }
        return parts
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
