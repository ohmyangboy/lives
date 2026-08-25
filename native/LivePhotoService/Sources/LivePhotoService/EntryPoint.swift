import AppKit
import AVFoundation
import Darwin
import Foundation

private func relaunchInsideHelperBundleIfNeeded() {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    if executable.path.contains("/LiveCollagePhotosHelper.app/Contents/MacOS/") { return }

    let contentsDirectory = executable.deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [
        contentsDirectory.appendingPathComponent("Resources/LiveCollagePhotosHelper.app/Contents/MacOS/live-photo-service"),
        contentsDirectory.appendingPathComponent("resources/LiveCollagePhotosHelper.app/Contents/MacOS/live-photo-service"),
    ]
    guard let helperExecutable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
        FileHandle.standardError.write(Data("Lives helper bundle is missing.\n".utf8))
        return
    }

    var arguments: [UnsafeMutablePointer<CChar>?] = [strdup(helperExecutable.path)]
    arguments.append(contentsOf: CommandLine.arguments.dropFirst().map { strdup($0) })
    arguments.append(nil)
    defer { arguments.compactMap { $0 }.forEach { free($0) } }
    _ = arguments.withUnsafeMutableBufferPointer { buffer in
        execv(helperExecutable.path, buffer.baseAddress)
    }
    FileHandle.standardError.write(Data("Lives helper bundle could not be started.\n".utf8))
}

actor ResponseWriter {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    func send(_ response: ServiceResponse) {
        guard let data = try? encoder.encode(response) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
        fflush(stdout)
    }
}

actor CancellationRegistry {
    private var cancelled = Set<String>()
    func cancel(_ jobId: String) { cancelled.insert(jobId) }
    func isCancelled(_ jobId: String) -> Bool { cancelled.contains(jobId) }
    func check(_ jobId: String) throws {
        if cancelled.contains(jobId) { throw ServiceError.cancelled }
    }
    func finish(_ jobId: String) { cancelled.remove(jobId) }
}

final class ServiceRuntime {
    private let writer = ResponseWriter()
    private let cancellations = CancellationRegistry()

    func submit(_ request: ServiceRequest) {
        Task.detached { [self] in await handle(request) }
    }

    private func handle(_ request: ServiceRequest) async {
        do {
            switch request.action {
            case "ping":
                await writer.send(ServiceResponse(requestId: request.requestId, type: "result", payload: .string("pong")))
            case "inspect":
                let envelope = try request.payload.decode(PathEnvelope.self)
                let info = try await MediaInspector.inspect(path: envelope.path)
                await writer.send(ServiceResponse(requestId: request.requestId, type: "result", payload: try encodeValue(info)))
            case "scanFolder":
                let envelope = try request.payload.decode(PathEnvelope.self)
                let paths = try MediaLibraryScanner.scan(path: envelope.path)
                await writer.send(ServiceResponse(requestId: request.requestId, type: "result", payload: try encodeValue(paths)))
            case "renderAndSave":
                let envelope = try request.payload.decode(RenderEnvelope.self)
                let project = envelope.project
                defer { Task { await cancellations.finish(project.id) } }
                let result = try await LivePhotoPipeline.run(project: project, cancellations: cancellations) { [writer] stage, progress in
                    await writer.send(ServiceResponse(requestId: request.requestId, type: "progress", stage: stage, progress: progress))
                }
                await writer.send(ServiceResponse(requestId: request.requestId, type: "result", payload: try encodeValue(result)))
            case "renderAndValidate":
                let envelope = try request.payload.decode(RenderEnvelope.self)
                let project = envelope.project
                defer { Task { await cancellations.finish(project.id) } }
                let result = try await LivePhotoPipeline.validateOnly(project: project, cancellations: cancellations) { [writer] stage, progress in
                    await writer.send(ServiceResponse(requestId: request.requestId, type: "progress", stage: stage, progress: progress))
                }
                await writer.send(ServiceResponse(requestId: request.requestId, type: "result", payload: try encodeValue(result)))
            case "renderAndExport":
                let envelope = try request.payload.decode(FolderExportEnvelope.self)
                let project = envelope.project
                defer { Task { await cancellations.finish(project.id) } }
                let result = try await LivePhotoPipeline.exportToFolder(
                    project: project,
                    directoryPath: envelope.directoryPath,
                    cancellations: cancellations
                ) { [writer] stage, progress in
                    await writer.send(ServiceResponse(requestId: request.requestId, type: "progress", stage: stage, progress: progress))
                }
                await writer.send(ServiceResponse(requestId: request.requestId, type: "result", payload: try encodeValue(result)))
            case "cancel":
                let envelope = try request.payload.decode(CancelEnvelope.self)
                await cancellations.cancel(envelope.jobId)
                await writer.send(ServiceResponse(requestId: request.requestId, type: "result", payload: .null))
            case "openPhotos":
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") else {
                    throw ServiceError(code: "PHOTO_APP_UNAVAILABLE", message: "无法打开“照片”", recovery: "请从程序坞或应用程序文件夹打开“照片”")
                }
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
                await writer.send(ServiceResponse(requestId: request.requestId, type: "result", payload: .null))
            case "openPhotoPrivacySettings":
                guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"),
                      NSWorkspace.shared.open(url) else {
                    throw ServiceError(code: "SETTINGS_UNAVAILABLE", message: "无法打开照片权限设置", recovery: "请手动打开“系统设置 → 隐私与安全性 → 照片”")
                }
                await writer.send(ServiceResponse(requestId: request.requestId, type: "result", payload: .null))
            case "revealInFinder":
                let envelope = try request.payload.decode(PathEnvelope.self)
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: envelope.path)])
                await writer.send(ServiceResponse(requestId: request.requestId, type: "result", payload: .null))
            default:
                throw ServiceError(code: "UNKNOWN_COMMAND", message: "无法识别这个操作", recovery: "请重新启动 App")
            }
        } catch let error as ServiceError {
            await writer.send(ServiceResponse(requestId: request.requestId, type: "error", error: error))
        } catch {
            FileHandle.standardError.write(Data("[LivePhotoService] \(String(reflecting: error))\n".utf8))
            let mapped = ErrorMapper.map(error)
            await writer.send(ServiceResponse(requestId: request.requestId, type: "error", error: mapped))
        }
    }

    private func encodeValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

enum ErrorMapper {
    static func map(_ error: Error) -> ServiceError {
        let nsError = error as NSError
        if nsError.domain == AVFoundationErrorDomain {
            return ServiceError(code: "RENDER_FAILED", message: "视频生成失败", recovery: "请确认素材可正常播放后重试")
        }
        return ServiceError(code: "UNEXPECTED_ERROR", message: "未能完成 Live Photo", recovery: "项目仍然保留，请重试。错误编号：\(nsError.code)")
    }
}

@main
struct LivePhotoServiceMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if await PhotoLibraryWorker.runIfRequested(arguments: arguments) { return }
        guard CommandLine.arguments.dropFirst().first == "serve" else {
            FileHandle.standardError.write(Data("LivePhotoService must be started with 'serve'.\n".utf8))
            return
        }
        relaunchInsideHelperBundleIfNeeded()
        let runtime = ServiceRuntime()
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard let data = line.data(using: .utf8), let request = try? JSONDecoder().decode(ServiceRequest.self, from: data) else { continue }
                runtime.submit(request)
            }
        } catch {
            FileHandle.standardError.write(Data("LivePhotoService input failed: \(String(reflecting: error))\n".utf8))
        }
    }
}
