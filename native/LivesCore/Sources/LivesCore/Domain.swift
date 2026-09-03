import CoreGraphics
import Foundation

public enum TemplateID: String, Codable, CaseIterable, Sendable {
    case single
    case stack2 = "stack-2"
    case side2 = "side-2"
    case stack3 = "stack-3"
    case side3 = "side-3"
    case heroLeft = "hero-left"
    case heroTop = "hero-top"
    case weighted3 = "weighted-3"
}

public enum AspectRatioID: String, Codable, CaseIterable, Sendable {
    case portrait916 = "9:16"
    case portrait34 = "3:4"
    case square = "1:1"
    case landscape43 = "4:3"
    case landscape169 = "16:9"
    case custom
}

public enum ExportQuality: String, Codable, CaseIterable, Sendable {
    case p480 = "480p"
    case p1080 = "1080p"
    /// Legacy value kept so existing macOS/iOS drafts remain readable.
    case p720 = "720p"
    case automatic = "automatic"
    case p4k = "4K"

    public var shortEdge: Int {
        switch self {
        case .p480: 480
        case .p720: 720
        case .p1080, .automatic: 1080
        case .p4k: 2160
        }
    }

    public var requiresPro: Bool { self == .automatic || self == .p4k }
}

public enum WatermarkMode: String, Codable, CaseIterable, Sendable {
    case lives
    case none
    case custom

    public var requiresPro: Bool { self != .lives }
}

public struct WatermarkSettings: Codable, Equatable, Sendable {
    public var mode: WatermarkMode
    public var text: String
    public var opacity: Double

    public init(mode: WatermarkMode = .lives, text: String = "lives", opacity: Double = 0.5) {
        self.mode = mode
        self.text = text.isEmpty ? "lives" : String(text.prefix(32))
        self.opacity = min(1, max(0.1, opacity.isFinite ? opacity : 0.5))
    }

    public static let `default` = WatermarkSettings()
}

public struct CustomRatio: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct CanvasSettings: Codable, Equatable, Sendable {
    public var aspectRatio: AspectRatioID
    public var quality: ExportQuality
    public var customRatio: CustomRatio?
    public var watermark: WatermarkSettings

    private enum CodingKeys: String, CodingKey {
        case aspectRatio
        case quality
        case customRatio
        case watermark
    }

    public init(
        aspectRatio: AspectRatioID = .portrait916,
        quality: ExportQuality = .p1080,
        customRatio: CustomRatio? = nil,
        watermark: WatermarkSettings = .default
    ) {
        self.aspectRatio = aspectRatio
        self.quality = quality
        self.customRatio = customRatio
        self.watermark = watermark
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        aspectRatio = try values.decodeIfPresent(AspectRatioID.self, forKey: .aspectRatio) ?? .portrait916
        quality = try values.decodeIfPresent(ExportQuality.self, forKey: .quality) ?? .p1080
        customRatio = try values.decodeIfPresent(CustomRatio.self, forKey: .customRatio)
        watermark = try values.decodeIfPresent(WatermarkSettings.self, forKey: .watermark) ?? .default
    }
}

public struct CanvasSize: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum CanvasGeometry {
    public static let customRatioBounds = (min: 1.0 / 3.0, max: 3.0)

    public static func normalize(_ ratio: CustomRatio) -> CustomRatio {
        let width = max(1, ratio.width)
        let height = max(1, ratio.height)
        let value = Double(width) / Double(height)
        if value > customRatioBounds.max {
            return CustomRatio(width: max(1, Int((Double(height) * customRatioBounds.max).rounded())), height: height)
        }
        if value < customRatioBounds.min {
            return CustomRatio(width: width, height: max(1, Int((Double(width) / customRatioBounds.min).rounded())))
        }
        return CustomRatio(width: width, height: height)
    }

    public static func size(for settings: CanvasSettings) -> CanvasSize {
        let ratio: (width: Int, height: Int)
        switch settings.aspectRatio {
        case .portrait916: ratio = (9, 16)
        case .portrait34: ratio = (3, 4)
        case .square: ratio = (1, 1)
        case .landscape43: ratio = (4, 3)
        case .landscape169: ratio = (16, 9)
        case .custom:
            let custom = normalize(settings.customRatio ?? CustomRatio(width: 9, height: 16))
            ratio = (custom.width, custom.height)
        }
        let short = settings.quality.shortEdge
        let long = min(short * 3, Int((Double(short) * Double(max(ratio.width, ratio.height)) / Double(min(ratio.width, ratio.height))).rounded()))
        let evenLong = long.isMultiple(of: 2) ? long : long - 1
        return ratio.width <= ratio.height
            ? CanvasSize(width: short, height: max(short, evenLong))
            : CanvasSize(width: max(short, evenLong), height: short)
    }
}

public struct CropPosition: Codable, Equatable, Sendable {
    public var normalizedCenterX: Double
    public var normalizedCenterY: Double
    public var scale: Double

    public init(normalizedCenterX: Double = 0.5, normalizedCenterY: Double = 0.5, scale: Double = 1) {
        self.normalizedCenterX = min(1, max(0, normalizedCenterX))
        self.normalizedCenterY = min(1, max(0, normalizedCenterY))
        self.scale = min(3, max(1, scale))
    }
}

public enum SourceAssetKind: String, Codable, CaseIterable, Sendable {
    case video
    case photo
    case livePhoto

    public var isMotion: Bool {
        switch self {
        case .video, .livePhoto: true
        case .photo: false
        }
    }
}

/// Runtime resource URLs resolved by the platform adapter. PhotoKit stays out
/// of LivesCore; iOS and macOS only provide local files at this seam.
public enum ResolvedMediaSource: Sendable, Equatable {
    case video(URL)
    case photo(URL)
    case livePhoto(photoURL: URL, pairedVideoURL: URL)

    public var motionURL: URL? {
        switch self {
        case .video(let url), .livePhoto(_, let url): url
        case .photo: nil
        }
    }

    public var photoURL: URL? {
        switch self {
        case .video: nil
        case .photo(let url), .livePhoto(let url, _): url
        }
    }
}

public struct SourceAsset: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var displayName: String
    public var relativePath: String
    public var durationMs: Int
    public var width: Int
    public var height: Int
    public var codec: String
    public var kind: SourceAssetKind
    /// For a Live Photo this is the paired motion resource. It is nil for
    /// ordinary videos and photos.
    public var pairedRelativePath: String?
    public var hasAudio: Bool
    /// The key-photo time in the paired video, when the source exposed it.
    public var nativeCoverTimeMs: Int?
    /// Motion dimensions can differ from the still image dimensions of a Live
    /// Photo. Old video records default these to width/height.
    public var motionWidth: Int
    public var motionHeight: Int

    private enum CodingKeys: String, CodingKey {
        case id, displayName, relativePath, durationMs, width, height, codec
        case kind, pairedRelativePath, hasAudio, nativeCoverTimeMs
        case motionWidth, motionHeight
    }

    public init(
        id: UUID = UUID(), displayName: String, relativePath: String,
        durationMs: Int, width: Int, height: Int, codec: String,
        kind: SourceAssetKind = .video,
        pairedRelativePath: String? = nil,
        hasAudio: Bool = false,
        nativeCoverTimeMs: Int? = nil,
        motionWidth: Int? = nil,
        motionHeight: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.relativePath = relativePath
        self.durationMs = max(0, durationMs)
        self.width = max(0, width)
        self.height = max(0, height)
        self.codec = codec
        self.kind = kind
        self.pairedRelativePath = pairedRelativePath
        self.hasAudio = hasAudio
        self.nativeCoverTimeMs = nativeCoverTimeMs.map { min(2_900, max(0, $0)) }
        self.motionWidth = max(0, motionWidth ?? width)
        self.motionHeight = max(0, motionHeight ?? height)
    }

    public init(
        id: UUID = UUID(), displayName: String, relativePath: String,
        width: Int, height: Int, contentType: String = "image"
    ) {
        self.init(
            id: id,
            displayName: displayName,
            relativePath: relativePath,
            durationMs: 0,
            width: width,
            height: height,
            codec: contentType,
            kind: .photo,
            hasAudio: false,
            motionWidth: 0,
            motionHeight: 0
        )
    }

    public init(
        id: UUID = UUID(), displayName: String,
        photoRelativePath: String, pairedVideoRelativePath: String,
        durationMs: Int, photoWidth: Int, photoHeight: Int,
        motionWidth: Int, motionHeight: Int, codec: String,
        hasAudio: Bool, nativeCoverTimeMs: Int? = nil
    ) {
        self.init(
            id: id,
            displayName: displayName,
            relativePath: photoRelativePath,
            durationMs: durationMs,
            width: photoWidth,
            height: photoHeight,
            codec: codec,
            kind: .livePhoto,
            pairedRelativePath: pairedVideoRelativePath,
            hasAudio: hasAudio,
            nativeCoverTimeMs: nativeCoverTimeMs,
            motionWidth: motionWidth,
            motionHeight: motionHeight
        )
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        displayName = try values.decode(String.self, forKey: .displayName)
        relativePath = try values.decode(String.self, forKey: .relativePath)
        durationMs = max(0, try values.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0)
        width = max(0, try values.decodeIfPresent(Int.self, forKey: .width) ?? 0)
        height = max(0, try values.decodeIfPresent(Int.self, forKey: .height) ?? 0)
        codec = try values.decodeIfPresent(String.self, forKey: .codec) ?? "unknown"
        // A short-lived schema-v2 build wrote the paired path before it
        // persisted `kind`. Infer the stronger type for those drafts so a
        // previously imported Live Photo cannot silently become a video (or
        // a static image) after relaunch.
        pairedRelativePath = try values.decodeIfPresent(String.self, forKey: .pairedRelativePath)
        if let decodedKind = try values.decodeIfPresent(SourceAssetKind.self, forKey: .kind) {
            kind = decodedKind
        } else if let pairedRelativePath, !pairedRelativePath.isEmpty {
            kind = .livePhoto
        } else {
            kind = .video
        }
        hasAudio = try values.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? false
        nativeCoverTimeMs = try values.decodeIfPresent(Int.self, forKey: .nativeCoverTimeMs)
            .map { min(2_900, max(0, $0)) }
        motionWidth = max(0, try values.decodeIfPresent(Int.self, forKey: .motionWidth) ?? width)
        motionHeight = max(0, try values.decodeIfPresent(Int.self, forKey: .motionHeight) ?? height)
    }
}

public struct Placement: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var sourceAssetID: UUID
    public var slotID: String
    public var startTimeMs: Int
    public var crop: CropPosition
    public var audioEnabled: Bool
    public var coverTimeMs: Int

    public init(
        id: UUID = UUID(), sourceAssetID: UUID, slotID: String,
        startTimeMs: Int = 0, crop: CropPosition = CropPosition(),
        audioEnabled: Bool = false, coverTimeMs: Int = 1500
    ) {
        self.id = id
        self.sourceAssetID = sourceAssetID
        self.slotID = slotID
        self.startTimeMs = max(0, startTimeMs)
        self.crop = crop
        self.audioEnabled = audioEnabled
        self.coverTimeMs = min(2900, max(0, (coverTimeMs / 100) * 100))
    }
}

public struct ProjectDocument: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 2
    public let id: UUID
    public var schemaVersion: Int
    public var name: String
    public var templateID: TemplateID
    public var canvas: CanvasSettings
    public var assets: [SourceAsset]
    public var placements: [Placement]
    public var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, name, templateID, canvas, assets, placements, updatedAt
    }

    public init(
        id: UUID = UUID(), name: String = "未命名作品", templateID: TemplateID = .single,
        canvas: CanvasSettings = CanvasSettings(), assets: [SourceAsset] = [],
        placements: [Placement] = [], updatedAt: Date = Date()
    ) {
        self.id = id
        self.schemaVersion = Self.currentSchemaVersion
        self.name = name
        self.templateID = templateID
        self.canvas = canvas
        self.assets = assets
        self.placements = placements
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        let storedVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        // Version 1 had video-only SourceAsset records. SourceAsset's decoder
        // supplies .video defaults; promote readable legacy drafts to v2 on
        // the next save while preserving future versions for validation.
        schemaVersion = storedVersion <= Self.currentSchemaVersion ? Self.currentSchemaVersion : storedVersion
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "未命名作品"
        templateID = try values.decodeIfPresent(TemplateID.self, forKey: .templateID) ?? .single
        canvas = try values.decodeIfPresent(CanvasSettings.self, forKey: .canvas) ?? CanvasSettings()
        assets = try values.decodeIfPresent([SourceAsset].self, forKey: .assets) ?? []
        placements = try values.decodeIfPresent([Placement].self, forKey: .placements) ?? []
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

/// Controls how audio is handled during a render. The default keeps the
/// per-placement switches in the project document intact; `.muted` is an
/// ephemeral export override and never changes those switches.
public enum RenderAudioPolicy: String, Codable, Equatable, Sendable {
    case perPlacement
    case muted
}

public struct RenderRequest: Codable, Equatable, Sendable {
    public let project: ProjectDocument
    public let canvasSize: CanvasSize
    public let audioPolicy: RenderAudioPolicy

    private enum CodingKeys: String, CodingKey {
        case project
        case canvasSize
        case audioPolicy
    }

    public init(
        project: ProjectDocument,
        canvasSize: CanvasSize? = nil,
        audioPolicy: RenderAudioPolicy = .perPlacement
    ) {
        self.project = project
        self.canvasSize = canvasSize ?? CanvasGeometry.size(for: project.canvas)
        self.audioPolicy = audioPolicy
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        project = try values.decode(ProjectDocument.self, forKey: .project)
        canvasSize = try values.decode(CanvasSize.self, forKey: .canvasSize)
        // RenderRequest was persisted before the global mute override existed.
        // Missing data must retain the historical per-placement behavior.
        audioPolicy = try values.decodeIfPresent(RenderAudioPolicy.self, forKey: .audioPolicy) ?? .perPlacement
    }
}

public struct MediaInfo: Codable, Equatable, Sendable {
    public let durationMs: Int
    public let width: Int
    public let height: Int
    public let codec: String
    public let hasAudio: Bool
    public let nativeCoverTimeMs: Int?

    public init(durationMs: Int, width: Int, height: Int, codec: String, hasAudio: Bool, nativeCoverTimeMs: Int? = nil) {
        self.durationMs = durationMs
        self.width = width
        self.height = height
        self.codec = codec
        self.hasAudio = hasAudio
        self.nativeCoverTimeMs = nativeCoverTimeMs
    }
}

public struct TemplateSlot: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let labelKey: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(id: String, labelKey: String, x: Double, y: Double, width: Double, height: Double) {
        self.id = id
        self.labelKey = labelKey
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct TemplateDefinition: Codable, Equatable, Sendable, Identifiable {
    public let id: TemplateID
    public let nameKey: String
    public let requiredAssetCount: Int
    public let slots: [TemplateSlot]

    public init(id: TemplateID, nameKey: String, requiredAssetCount: Int, slots: [TemplateSlot]) {
        self.id = id
        self.nameKey = nameKey
        self.requiredAssetCount = requiredAssetCount
        self.slots = slots
    }

    public func rect(for slotID: String, canvas: CGSize) throws -> CGRect {
        guard let slot = slots.first(where: { $0.id == slotID }) else {
            throw LivesCoreError.invalidSlot(slotID)
        }
        return CGRect(x: slot.x * canvas.width, y: slot.y * canvas.height,
                      width: slot.width * canvas.width, height: slot.height * canvas.height)
    }
}

public enum TemplateCatalog {
    public static let all: [TemplateDefinition] = [
        TemplateDefinition(id: .single, nameKey: "template.single", requiredAssetCount: 1,
                           slots: [slot("full", "slot.main", 0, 0, 1, 1)]),
        TemplateDefinition(id: .stack2, nameKey: "template.stack2", requiredAssetCount: 2,
                           slots: [slot("top", "slot.top", 0, 0, 1, 0.5), slot("bottom", "slot.bottom", 0, 0.5, 1, 0.5)]),
        TemplateDefinition(id: .side2, nameKey: "template.side2", requiredAssetCount: 2,
                           slots: [slot("left", "slot.left", 0, 0, 0.5, 1), slot("right", "slot.right", 0.5, 0, 0.5, 1)]),
        TemplateDefinition(id: .stack3, nameKey: "template.stack3", requiredAssetCount: 3,
                           slots: [slot("top", "slot.top", 0, 0, 1, 1.0 / 3.0), slot("middle", "slot.middle", 0, 1.0 / 3.0, 1, 1.0 / 3.0), slot("bottom", "slot.bottom", 0, 2.0 / 3.0, 1, 1.0 / 3.0)]),
        TemplateDefinition(id: .side3, nameKey: "template.side3", requiredAssetCount: 3,
                           slots: [slot("left", "slot.left", 0, 0, 1.0 / 3.0, 1), slot("center", "slot.center", 1.0 / 3.0, 0, 1.0 / 3.0, 1), slot("right", "slot.right", 2.0 / 3.0, 0, 1.0 / 3.0, 1)]),
        TemplateDefinition(id: .heroLeft, nameKey: "template.heroLeft", requiredAssetCount: 3,
                           slots: [slot("hero-left", "slot.hero", 0, 0, 2.0 / 3.0, 1), slot("right-top", "slot.top", 2.0 / 3.0, 0, 1.0 / 3.0, 0.5), slot("right-bottom", "slot.bottom", 2.0 / 3.0, 0.5, 1.0 / 3.0, 0.5)]),
        TemplateDefinition(id: .heroTop, nameKey: "template.heroTop", requiredAssetCount: 3,
                           slots: [slot("hero-top", "slot.hero", 0, 0, 1, 2.0 / 3.0), slot("bottom-left", "slot.left", 0, 2.0 / 3.0, 0.5, 1.0 / 3.0), slot("bottom-right", "slot.right", 0.5, 2.0 / 3.0, 0.5, 1.0 / 3.0)]),
        TemplateDefinition(id: .weighted3, nameKey: "template.weighted3", requiredAssetCount: 3,
                           slots: [slot("large", "slot.large", 0, 0, 1, 0.5), slot("medium", "slot.medium", 0, 0.5, 1, 0.3), slot("small", "slot.small", 0, 0.8, 1, 0.2)]),
    ]

    public static func definition(for id: TemplateID) -> TemplateDefinition {
        all.first(where: { $0.id == id })!
    }

    private static func slot(_ id: String, _ labelKey: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> TemplateSlot {
        TemplateSlot(id: id, labelKey: labelKey, x: x, y: y, width: width, height: height)
    }
}

public enum LivesCoreError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedFileType
    case sourceTooShort
    case invalidLivePhoto
    case invalidProject(String)
    case invalidSlot(String)
    case renderFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFileType: return "暂不支持这个素材格式"
        case .sourceTooShort: return "视频至少需要 2.5 秒"
        case .invalidLivePhoto: return "Live Photo 缺少匹配的照片或动态资源"
        case .invalidProject(let value): return value
        case .invalidSlot(let value): return "找不到画格：\(value)"
        case .renderFailed(let value): return value
        }
    }
}

public enum ProjectValidation {
    public static let outputDurationMs = 3_000
    public static let minimumSourceDurationMs = 2_500

    public static func validate(_ project: ProjectDocument) throws {
        let definition = TemplateCatalog.definition(for: project.templateID)
        guard project.schemaVersion == ProjectDocument.currentSchemaVersion else {
            throw LivesCoreError.invalidProject("项目版本不受支持")
        }
        guard project.placements.count == definition.requiredAssetCount else {
            throw LivesCoreError.invalidProject("素材数量与模板不匹配")
        }
        guard Set(project.placements.map(\.slotID)).count == definition.requiredAssetCount else {
            throw LivesCoreError.invalidProject("模板画格不能重复")
        }
        let assetIDs = Set(project.assets.map(\.id))
        for placement in project.placements {
            guard assetIDs.contains(placement.sourceAssetID), definition.slots.contains(where: { $0.id == placement.slotID }) else {
                throw LivesCoreError.invalidProject("画格素材引用无效")
            }
            guard let asset = project.assets.first(where: { $0.id == placement.sourceAssetID }) else {
                throw LivesCoreError.invalidProject("画格素材引用无效")
            }
            switch asset.kind {
            case .photo:
                guard asset.width > 0, asset.height > 0 else {
                    throw LivesCoreError.invalidProject("照片尺寸无效")
                }
            case .video:
                guard asset.durationMs >= minimumSourceDurationMs else {
                    throw LivesCoreError.sourceTooShort
                }
            case .livePhoto:
                guard asset.durationMs > 0,
                      asset.width > 0, asset.height > 0,
                      asset.motionWidth > 0, asset.motionHeight > 0,
                      let paired = asset.pairedRelativePath,
                      !paired.isEmpty else {
                    throw LivesCoreError.invalidLivePhoto
                }
            }
        }
    }

    public static func contentDurationMs(sourceDurationMs: Int, startTimeMs: Int) -> Int {
        min(outputDurationMs, max(0, sourceDurationMs - max(0, startTimeMs)))
    }

    public static func paddingDurationMs(sourceDurationMs: Int, startTimeMs: Int) -> Int {
        max(0, outputDurationMs - contentDurationMs(sourceDurationMs: sourceDurationMs, startTimeMs: startTimeMs))
    }
}
