import AVFoundation
import Foundation

enum CompatibilityTranscoder {
    typealias ProgressHandler = (Double) async -> Void

    static func prepare(
        project: RenderProject,
        workingDirectory: URL,
        cancellations: CancellationRegistry,
        progress: @escaping ProgressHandler
    ) async throws -> RenderProject {
        let compatibilityDirectory = workingDirectory.appendingPathComponent("compatibility", isDirectory: true)
        var preparedClips: [RenderProject.Clip] = []

        for (index, clip) in project.clips.enumerated() {
            try await cancellations.check(project.id)
            let sourceURL = URL(fileURLWithPath: clip.sourcePath)
            let needsConversion = try await requiresTranscoding(sourceURL: sourceURL)
            guard needsConversion else {
                preparedClips.append(clip)
                continue
            }

            try FileManager.default.createDirectory(at: compatibilityDirectory, withIntermediateDirectories: true)
            await progress(Double(index) / Double(max(1, project.clips.count)))
            let convertedURL = compatibilityDirectory
                .appendingPathComponent("clip-\(index)-\(UUID().uuidString)")
                .appendingPathExtension("mov")
            let segment = MediaConstraints.segmentDurations(
                sourceDurationMilliseconds: clip.sourceDurationMs,
                startTimeMilliseconds: clip.startTimeMs,
                outputDurationMilliseconds: project.canvas.durationMs
            )
            try await transcode(
                sourceURL: sourceURL,
                outputURL: convertedURL,
                startTimeMilliseconds: clip.startTimeMs,
                durationMilliseconds: segment.contentMilliseconds,
                includeAudio: clip.audioEnabled,
                jobId: project.id,
                cancellations: cancellations
            )
            let convertedInfo = try await MediaInspector.inspect(path: convertedURL.path)
            preparedClips.append(
                RenderProject.Clip(
                    id: clip.id,
                    sourcePath: convertedURL.path,
                    sourceDurationMs: convertedInfo.durationMs,
                    startTimeMs: 0,
                    crop: clip.crop,
                    targetSlotId: clip.targetSlotId,
                    audioEnabled: clip.audioEnabled
                )
            )
            await progress(Double(index + 1) / Double(max(1, project.clips.count)))
        }

        return RenderProject(
            id: project.id,
            templateId: project.templateId,
            canvas: project.canvas,
            clips: preparedClips,
            coverTimeMs: project.coverTimeMs
        )
    }

    static func requiresTranscoding(sourceURL: URL) async throws -> Bool {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ServiceError(
                code: "VIDEO_READ_FAILED",
                message: "视频中没有可用画面",
                recovery: "请检查视频文件是否完整"
            )
        }
        let isPlayable = (try? await asset.load(.isPlayable)) ?? false
        let isDecodable = (try? await track.load(.isDecodable)) ?? false
        return !isPlayable || !isDecodable
    }

    private static func transcode(
        sourceURL: URL,
        outputURL: URL,
        startTimeMilliseconds: Int,
        durationMilliseconds: Int,
        includeAudio: Bool,
        jobId: String,
        cancellations: CancellationRegistry
    ) async throws {
        guard durationMilliseconds >= MediaConstraints.minimumSourceDurationMilliseconds else {
            throw ServiceError(
                code: "VIDEO_TOO_SHORT",
                message: "一段视频不足 2.5 秒",
                recovery: "请替换对应素材"
            )
        }
        let executableURL = try converterExecutableURL()
        var arguments = [
            "-y",
            "-v", "error",
            "-ss", seconds(startTimeMilliseconds),
            "-i", sourceURL.path,
            "-t", seconds(durationMilliseconds),
            "-map", "0:v:0",
        ]
        if includeAudio {
            arguments += ["-map", "0:a:0?"]
        } else {
            arguments += ["-an"]
        }
        arguments += [
            "-vf", "scale='min(1920,iw)':'min(1920,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2,format=yuv422p10le",
            "-c:v", "prores_ks",
            "-profile:v", "0",
        ]
        if includeAudio {
            arguments += ["-c:a", "aac", "-b:a", "128000"]
        }
        arguments += ["-movflags", "+faststart", outputURL.path]

        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw ServiceError(
                code: "VIDEO_TRANSCODER_UNAVAILABLE",
                message: "兼容格式转换器无法启动",
                recovery: "请重新安装 Lives 后再试"
            )
        }

        do {
            while process.isRunning {
                try await cancellations.check(jobId)
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        } catch {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: outputURL.path) else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let diagnostic = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(500)
            if let diagnostic, !diagnostic.isEmpty {
                FileHandle.standardError.write(Data("[CompatibilityTranscoder] \(diagnostic)\n".utf8))
            }
            try? FileManager.default.removeItem(at: outputURL)
            throw ServiceError(
                code: "VIDEO_TRANSCODE_FAILED",
                message: "这段视频无法转换为兼容格式",
                recovery: "请确认文件可正常播放，或先转换为 H.264 / HEVC 后重试"
            )
        }
    }

    private static func converterExecutableURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["LIVES_FFMPEG_PATH"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        let serviceExecutable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let bundled = serviceExecutable.deletingLastPathComponent().appendingPathComponent("ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: bundled.path) else {
            throw ServiceError(
                code: "VIDEO_TRANSCODER_UNAVAILABLE",
                message: "兼容格式转换器缺失",
                recovery: "请重新安装 Lives 后再试"
            )
        }
        return bundled
    }

    private static func seconds(_ milliseconds: Int) -> String {
        String(
            format: "%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            Double(milliseconds) / 1_000
        )
    }
}
