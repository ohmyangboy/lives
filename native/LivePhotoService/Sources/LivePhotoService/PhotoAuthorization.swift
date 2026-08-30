import Foundation
import Photos
import Security

enum PhotoAuthorization {
    // Hardened Runtime 的资源声明不是用户授权。缺失时系统不会弹框，
    // 也不会生成可在设置里修改的记录，必须报告应用配置错误。
    static func validateSigningConfiguration() throws {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess,
              let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any] else {
            throw configurationError
        }
        let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        if entitlements?["com.apple.security.personal-information.photos-library"] as? Bool != true {
            throw configurationError
        }
    }

    static let configurationError = ServiceError(
        code: "PHOTO_PERMISSION_CONFIGURATION_ERROR",
        message: "此版本的照片权限配置异常",
        recovery: "系统无法为此版本弹出照片授权框。请安装修复后的 Lives，或改为导出到文件夹；在系统设置中无法修复此问题。"
    )

    static let resetFailedError = ServiceError(
        code: "PHOTO_PERMISSION_RESET_FAILED",
        message: "未能自动恢复照片授权",
        recovery: "请点击“复制修复命令”，在“终端”中粘贴执行后再重试；也可以改为导出到文件夹。"
    )

    static let resetPendingError = ServiceError(
        code: "PHOTO_PERMISSION_RESET_PENDING",
        message: "系统同步照片授权状态较慢",
        recovery: "重置已提交并继续在后台生效。请点击“重新尝试”，通常下一次就会弹出授权框；若仍未出现，请再等待约 1 分钟后重试。也可以改为导出到文件夹。"
    )

    static let promptSuppressedError = ServiceError(
        code: "PHOTO_PERMISSION_PROMPT_SUPPRESSED",
        message: "系统没有弹出授权框",
        recovery: "系统似乎直接拒绝了本次授权请求。请点击“复制修复命令”，在“终端”中粘贴执行后再重试；也可以改为导出到文件夹。"
    )

    // 用户手动验证过的完整恢复命令：helper 与主 App 两个身份 × PhotosAdd 与 Photos
    // 两个服务。实测（诊断日志 2026-08-30）只重置 helper 两条时弹窗不会重现，
    // 拒绝记录疑似同时归属主 App（TCC 责任进程归属），四条缺一不可。
    static let repairTargets: [(service: String, bundleIdentifier: String)] = [
        ("PhotosAdd", "com.yangbukun.lives.photos-helper"),
        ("Photos", "com.yangbukun.lives.photos-helper"),
        ("PhotosAdd", "com.yangbukun.lives"),
        ("Photos", "com.yangbukun.lives"),
    ]

    static var repairCommandLines: [String] {
        repairTargets.map { "tccutil reset \($0.service) \($0.bundleIdentifier)" }
    }

    // 误点“不允许”后，macOS 不会在“隐私与安全性 → 照片”面板里显示仅添加（addOnly）
    // 应用的已拒绝记录，也没有 API 能重新弹窗；只能用官方 tccutil 清掉本应用的
    // TCC 记录，让下一次 requestAuthorization 回到未决定状态并重新弹窗。
    // 注意：不做“已是 notDetermined 就跳过”的提前返回——诊断日志显示 helper 身份
    // 可能短暂读到 notDetermined 而主 App 身份仍被拒绝，此时跳过会漏掉真正的记录。
    // jobId 用于前端取消：overlay 被关闭后，旧的轮询循环会被 cancellation 中止，
    // 避免与新发起的重置排队冲突。
    static func resetDeniedAuthorization(cancellations: CancellationRegistry, jobId: String) async throws {
        try await cancellations.check(jobId)
        let before = await PhotoLibraryWorkerClient.readAuthorizationStatus()
            ?? PHPhotoLibrary.authorizationStatus(for: .addOnly)
        appendDiagnosticsLog("reset requested; fresh status before = \(before)")

        var spawnFailed = false
        for target in repairTargets {
            let result = await runTCCUtil(arguments: ["reset", target.service, target.bundleIdentifier])
            appendDiagnosticsLog("tccutil reset \(target.service) \(target.bundleIdentifier) → exit \(result.exitCode) stderr=\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            if result.exitCode != 0 { spawnFailed = true }
        }

        // 轮询校验：吸收 tccd 状态传播延迟，同时把每次结果写入诊断日志作为证据。
        // 即使部分命令失败也先轮询——以全新进程读到的状态为最终裁决。
        let startedAt = Date()
        var attempt = 0
        while attempt < 50 {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
            attempt += 1
            try await cancellations.check(jobId)
            if let status = await PhotoLibraryWorkerClient.readAuthorizationStatus(),
               status == .notDetermined || status == .authorized {
                appendDiagnosticsLog("reset verified after ~\(Int(Date().timeIntervalSince(startedAt)))s (\(attempt) polls)")
                return
            }
        }
        if spawnFailed {
            appendDiagnosticsLog("reset failed: tccutil reported an error; not verified within ~3min")
            throw resetFailedError
        }
        appendDiagnosticsLog("reset not verified within ~3min; treating as pending")
        throw resetPendingError
    }

    private static func runTCCUtil(arguments: [String]) async -> (exitCode: Int32, stderr: String) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(exitCode: Int32, stderr: String), Never>) in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                process.arguments = arguments
                let stderrPipe = Pipe()
                process.standardError = stderrPipe
                let result: (exitCode: Int32, stderr: String)
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    result = (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
                } catch {
                    result = (-1, String(reflecting: error))
                }
                continuation.resume(returning: result)
            }
        }
    }

    // 诊断日志：把重置/授权全过程写入磁盘，便于事后排查（不记录任何个人数据）。
    static func appendDiagnosticsLog(_ line: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] [\(String(format: "%d", getuid()))] \(line)\n"
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Lives", isDirectory: true)
        let url = directory.appendingPathComponent("photo-reset.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(entry.utf8))
        } else {
            try? entry.data(using: .utf8)?.write(to: url)
        }
    }

    static func error(for status: PHAuthorizationStatus) -> ServiceError? {
        switch status {
        case .authorized:
            return nil
        case .denied:
            return ServiceError(code: "PHOTO_PERMISSION_DENIED", message: "没有照片写入权限", recovery: "请点击“重新授权”唤起系统授权框并允许添加照片，或改为导出到文件夹。")
        case .restricted:
            return ServiceError(code: "PHOTO_PERMISSION_RESTRICTED", message: "照片访问受到系统限制", recovery: "请检查屏幕使用时间或设备管理策略，也可以改为导出到文件夹。")
        case .notDetermined, .limited:
            return ServiceError(code: "PHOTO_PERMISSION_UNAVAILABLE", message: "未能完成照片写入授权", recovery: "请重新启动 Lives 后重试；若系统仍未弹出授权框，请改为导出到文件夹并反馈此问题。")
        @unknown default:
            return ServiceError(code: "PHOTO_PERMISSION_UNAVAILABLE", message: "无法确认照片写入权限", recovery: "请重新启动 Lives 后重试，或改为导出到文件夹。")
        }
    }
}
