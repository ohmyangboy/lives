import Darwin
import Foundation
import Photos

// Only allowlisted technical fields reach disk or feedback. Never serialize NSError.userInfo,
// descriptions, resource URLs, library identifiers, or the existing raw reset log.
struct PhotoDiagnosticEvent: Codable {
    enum Operation: String, Codable { case authorization, save }
    enum Outcome: String, Codable { case started, succeeded, failed, configurationError, missingIdentifier }
    struct ErrorCode: Codable {
        let domain: String
        let code: Int
    }
    struct Resource: Codable {
        let exists: Bool
        let readable: Bool
        let bytes: Int64?

        init(url: URL) {
            exists = FileManager.default.fileExists(atPath: url.path)
            readable = FileManager.default.isReadableFile(atPath: url.path)
            bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        }
    }

    let date: Date
    let processID: Int32
    let operation: Operation
    let outcome: Outcome
    let addOnlyStatus: Int
    let readWriteStatus: Int
    var photo: Resource? = nil
    var video: Resource? = nil
    var errors: [ErrorCode] = []

    static func errorCodes(from error: Error) -> [ErrorCode] {
        let allowedDomains: Set<String> = [
            "PHPhotosErrorDomain", "NSCocoaErrorDomain", "NSPOSIXErrorDomain", "NSOSStatusErrorDomain",
            "AVFoundationErrorDomain", "NSURLErrorDomain", "CloudPhotoLibraryErrorDomain", "PLPhotosErrorDomain",
        ]
        var pending = [error as NSError]
        var visited = Set<ObjectIdentifier>()
        var codes: [ErrorCode] = []
        while !pending.isEmpty && codes.count < 4 {
            let current = pending.removeFirst()
            guard visited.insert(ObjectIdentifier(current)).inserted else { continue }
            codes.append(ErrorCode(domain: allowedDomains.contains(current.domain) ? current.domain : "other", code: current.code))
            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError { pending.append(underlying) }
            if let underlying = current.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] {
                pending.append(contentsOf: underlying.prefix(4))
            }
        }
        return codes
    }
}

struct PhotoDiagnosticsLog {
    let url: URL
    static let maximumEvents = 64
    static let maximumBytes = 65_536
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    // Workers are separate processes. Lock a stable sibling file while atomically replacing
    // the bounded JSON log, so simultaneous feedback reads and saves cannot lose events.
    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func read(now: Date) -> [PhotoDiagnosticEvent] {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
              size.intValue <= Self.maximumBytes,
              let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? decoder.decode([PhotoDiagnosticEvent].self, from: data)) ?? [])
            .filter { now.timeIntervalSince($0.date) <= Self.retention }
            .suffix(Self.maximumEvents).map { $0 }
    }

    func append(_ event: PhotoDiagnosticEvent) throws {
        try withLock {
            var events = Array((read(now: event.date) + [event]).suffix(Self.maximumEvents))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(events)
            while data.count > Self.maximumBytes && events.count > 1 {
                events.removeFirst()
                data = try encoder.encode(events)
            }
            guard data.count <= Self.maximumBytes else { return }
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func feedbackSummary(now: Date = Date()) throws -> String {
        try withLock {
            let events = read(now: now)
            guard !events.isEmpty else { return "No Photos diagnostics in the last 7 days." }
            let formatter = ISO8601DateFormatter()
            func status(_ rawValue: Int) -> String {
                switch PHAuthorizationStatus(rawValue: rawValue) {
                case .notDetermined: return "notDetermined"
                case .restricted: return "restricted"
                case .denied: return "denied"
                case .authorized: return "authorized"
                case .limited: return "limited"
                default: return "unknown(\(rawValue))"
                }
            }
            func resource(_ value: PhotoDiagnosticEvent.Resource) -> String {
                "exists:\(value.exists),readable:\(value.readable),bytes:\(value.bytes.map(String.init) ?? "unknown")"
            }
            // Keep the latest failure even if a few later retries succeeded.
            var indices = Array(events.indices.suffix(6).reversed())
            if let failure = events.lastIndex(where: { $0.outcome != .started && $0.outcome != .succeeded }) {
                indices.removeAll { $0 == failure }
                indices.insert(failure, at: 0)
            }
            var lines: [(index: Int, text: String)] = []
            var byteCount = 0
            for index in indices {
                let event = events[index]
                var line = "\(formatter.string(from: event.date)) \(event.operation.rawValue)/\(event.outcome.rawValue) pid=\(event.processID) add=\(status(event.addOnlyStatus)) read=\(status(event.readWriteStatus))"
                if let photo = event.photo { line += " jpg={\(resource(photo))}" }
                if let video = event.video { line += " mov={\(resource(video))}" }
                if !event.errors.isEmpty { line += " errors=" + event.errors.map { "\($0.domain):\($0.code)" }.joined(separator: ">") }
                guard lines.count < 6, byteCount + line.utf8.count + 1 <= 1500 else { continue }
                lines.append((index, line))
                byteCount += line.utf8.count + 1
            }
            return "Recent Photos diagnostics (\(lines.count)/\(events.count) retained events):\n" + lines.sorted { $0.index < $1.index }.map(\.text).joined(separator: "\n")
        }
    }
}

enum PhotoDiagnostics {
    static let log = PhotoDiagnosticsLog(url: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Lives/photo-diagnostics.json"))

    static func record(_ operation: PhotoDiagnosticEvent.Operation, _ outcome: PhotoDiagnosticEvent.Outcome,
                       photoURL: URL? = nil, videoURL: URL? = nil, error: Error? = nil) {
        let event = PhotoDiagnosticEvent(
            date: Date(), processID: getpid(), operation: operation, outcome: outcome,
            addOnlyStatus: PHPhotoLibrary.authorizationStatus(for: .addOnly).rawValue,
            readWriteStatus: PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue,
            photo: photoURL.map { .init(url: $0) }, video: videoURL.map { .init(url: $0) },
            errors: error.map(PhotoDiagnosticEvent.errorCodes) ?? []
        )
        // Diagnostics must never turn a successful Photos operation into an error.
        try? log.append(event)
    }
}
