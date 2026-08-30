import AppKit
import Foundation

// 反馈诊断用的真实系统信息。WebView 里的 navigator.platform / userAgent 是
// 固定的假数据（"MacIntel"、"Intel Mac OS X 10_15_7"），必须走本机 API 采集，
// 采集口径与 PaperRss 的 FeedbackDiagnosticsProvider 保持一致。
struct SystemDiagnosticsInfo: Codable {
    let osVersion: String
    let osBuild: String?
    let deviceModel: String?
    let chipName: String?
    let architecture: String?
    let processorCount: Int
    let physicalMemoryBytes: Int?
    let locale: String
    let displayResolution: String?
    let displayScale: Double?
}

enum SystemDiagnostics {
    static func collect(processInfo: ProcessInfo = .processInfo, screen: NSScreen? = NSScreen.main) -> SystemDiagnosticsInfo {
        let version = processInfo.operatingSystemVersion
        let osVersion = [
            version.majorVersion,
            version.minorVersion,
            version.patchVersion,
        ].map(String.init).joined(separator: ".")
        let memoryBytes = processInfo.physicalMemory
        return SystemDiagnosticsInfo(
            osVersion: osVersion,
            osBuild: systemValue("kern.osversion"),
            deviceModel: systemValue("hw.model"),
            chipName: systemValue("machdep.cpu.brand_string"),
            architecture: systemValue("hw.machine"),
            processorCount: processInfo.processorCount,
            physicalMemoryBytes: memoryBytes > 0 ? Int(memoryBytes) : nil,
            locale: Locale.current.identifier,
            displayResolution: screen.map { "\(Int($0.frame.width.rounded())) × \(Int($0.frame.height.rounded()))" },
            displayScale: screen.map { Double($0.backingScaleFactor) }
        )
    }

    private static func systemValue(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        let utf8 = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: utf8, as: UTF8.self)
    }
}
