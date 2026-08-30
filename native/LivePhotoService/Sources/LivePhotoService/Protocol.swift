import Foundation

struct ServiceRequest: Decodable {
    let requestId: String
    let action: String
    let payload: JSONValue
}

struct ServiceError: Error, Codable {
    let code: String
    let message: String
    let recovery: String

    static let cancelled = ServiceError(code: "TASK_CANCELLED", message: "已取消生成", recovery: "编辑状态已保留")
    static let updateCancelled = ServiceError(code: "UPDATE_CANCELLED", message: "更新下载已取消", recovery: "可随时重新检查更新")
}

struct ServiceResponse: Encodable {
    let requestId: String
    let type: String
    var stage: String? = nil
    var progress: Double? = nil
    var payload: JSONValue? = nil
    var error: ServiceError? = nil
}

enum JSONValue: Codable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }
}

struct VideoInfo: Codable {
    let path: String
    let durationMs: Int
    let width: Int
    let height: Int
    let codec: String
}

struct RenderProject: Codable {
    struct Canvas: Codable { let width: Int; let height: Int; let fps: Int; let durationMs: Int }
    struct Crop: Codable { let normalizedCenterX: Double; let normalizedCenterY: Double; let scale: Double }
    struct Clip: Codable {
        let id: String
        let sourcePath: String
        let sourceDurationMs: Int
        let startTimeMs: Int
        let crop: Crop
        let targetSlotId: String
        let audioEnabled: Bool
        let coverTimeMs: Int
    }
    let id: String
    let templateId: String
    let canvas: Canvas
    let clips: [Clip]
    let coverTimeMs: Int
}

struct RenderEnvelope: Codable { let project: RenderProject }
struct FolderExportEnvelope: Codable { let project: RenderProject; let directoryPath: String }
struct PathEnvelope: Codable { let path: String }
struct CancelEnvelope: Codable { let jobId: String }
struct ResetEnvelope: Codable { let jobId: String }
struct DownloadUpdateEnvelope: Codable {
    let dmgUrl: String
    let expectedSha256: String?
    let expectedSize: Int64?
    let expectedVersion: String?
    let expectedSource: String?
    let releaseNotes: String?
    let htmlUrl: String?
    let publishedAt: String?
    let isCritical: Bool?
}
struct UpdateMetadataEnvelope: Codable {
    let source: String
    let version: String?
}
struct UpdateMetadataResponse: Codable {
    let status: Int
    let body: String
    let retryAfter: Int?
    let rateLimitReset: Int?
}
struct InstallUpdateEnvelope: Codable {
    let stagedAppPath: String
    let targetAppPath: String?
}
struct PreparedUpdateResult: Codable {
    let stagedAppPath: String
    let targetAppPath: String
    let version: String?
    let dmgUrl: String?
    let sha256: String?
    let size: Int64?
    let source: String?
    let releaseNotes: String?
    let htmlUrl: String?
    let publishedAt: String?
    let isCritical: Bool?
}
