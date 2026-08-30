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

    static func error(for status: PHAuthorizationStatus) -> ServiceError? {
        switch status {
        case .authorized:
            return nil
        case .denied:
            return ServiceError(code: "PHOTO_PERMISSION_DENIED", message: "没有照片写入权限", recovery: "请在“系统设置 → 隐私与安全性 → 照片”中允许 Lives 添加照片；也可以改为导出到文件夹")
        case .restricted:
            return ServiceError(code: "PHOTO_PERMISSION_RESTRICTED", message: "照片访问受到系统限制", recovery: "请检查屏幕使用时间或设备管理策略，也可以改为导出到文件夹。")
        case .notDetermined, .limited:
            return ServiceError(code: "PHOTO_PERMISSION_UNAVAILABLE", message: "未能完成照片写入授权", recovery: "请重新启动 Lives 后重试；若系统仍未弹出授权框，请改为导出到文件夹并反馈此问题。")
        @unknown default:
            return ServiceError(code: "PHOTO_PERMISSION_UNAVAILABLE", message: "无法确认照片写入权限", recovery: "请重新启动 Lives 后重试，或改为导出到文件夹。")
        }
    }
}
