import { convertFileSrc, invoke, isTauri } from '@tauri-apps/api/core'
import { getCurrentWindow } from '@tauri-apps/api/window'
import { Command, type Child } from '@tauri-apps/plugin-shell'

import type { RenderProject } from './domain'

export interface VideoInfo {
  path: string
  durationMs: number
  width: number
  height: number
  codec: string
}

export interface PreviewInfo {
  path: string
  transcoded: boolean
}

export type NativeStage = 'inspecting' | 'transcoding' | 'rendering' | 'writingMetadata' | 'validating' | 'requestingPhotoPermission' | 'resettingPhotoPermission' | 'saving' | 'exportingFiles' | 'verifyingSavedAsset' | 'completed'

export type UpdateStage = 'downloading' | 'verifying' | 'preparing' | 'completed'

export interface ExportedPairResult {
  directoryPath: string
  photoPath: string
  videoPath: string
}

export interface PreparedUpdateInfo {
  stagedAppPath: string
  targetAppPath: string
  version?: string
  dmgUrl?: string
  sha256?: string
  size?: number
  source?: 'oneleaf' | 'github'
  releaseNotes?: string
  htmlUrl?: string
  publishedAt?: string
  isCritical?: boolean
}

export interface NativeSystemDiagnostics {
  osVersion: string
  osBuild?: string
  deviceModel?: string
  chipName?: string
  architecture?: string
  processorCount: number
  physicalMemoryBytes?: number
  locale: string
  displayResolution?: string
  displayScale?: number
}

interface NativeEnvelope {
  requestId: string
  type: 'result' | 'progress' | 'error'
  stage?: string
  progress?: number
  payload?: unknown
  error?: { code: string; message: string; recovery: string }
}

type PendingRequest = {
  resolve: (value: unknown) => void
  reject: (reason: Error) => void
  onProgress?: (stage: any, progress: number) => void
  abortCleanup?: () => void
}


class LivePhotoService {
  private child?: Child
  private pending = new Map<string, PendingRequest>()
  private starting?: Promise<void>
  private activeDownloadRequestId?: string

  private async start() {
    if (this.child) return
    if (this.starting) return this.starting
    this.starting = (async () => {
      const command = Command.sidecar('binaries/live-photo-service', ['serve'])
      command.stdout.on('data', (line) => this.receive(line))
      command.stderr.on('data', (line) => console.warn('[LivePhotoService]', line))
      command.on('close', () => {
        this.child = undefined
        for (const pending of this.pending.values()) {
          pending.abortCleanup?.()
          pending.reject(new Error('原生媒体服务已停止'))
        }
        this.pending.clear()
      })
      this.child = await command.spawn()
    })()
    try { await this.starting } finally { this.starting = undefined }
  }

  private receive(line: string) {
    let message: NativeEnvelope
    try { message = JSON.parse(line) as NativeEnvelope } catch { return }
    const pending = this.pending.get(message.requestId)
    if (!pending) return
    if (message.type === 'progress' && message.stage) {
      pending.onProgress?.(message.stage, message.progress ?? 0)
      return
    }
    this.pending.delete(message.requestId)
    pending.abortCleanup?.()
    if (message.type === 'error') {
      const error = new Error(message.error?.message ?? '操作失败')
      Object.assign(error, { code: message.error?.code, recovery: message.error?.recovery })
      pending.reject(error)
    } else {
      pending.resolve(message.payload)
    }
  }

  private async request<T>(action: string, payload: unknown, onProgress?: PendingRequest['onProgress'], requestId: string = crypto.randomUUID(), signal?: AbortSignal): Promise<T> {
    await this.start()
    return new Promise<T>((resolve, reject) => {
      if (signal?.aborted) {
        reject(new DOMException('请求已取消', 'AbortError'))
        return
      }
      const abort = () => {
        this.pending.delete(requestId)
        reject(new DOMException('请求已取消', 'AbortError'))
        void this.cancel(requestId)
      }
      signal?.addEventListener('abort', abort, { once: true })
      this.pending.set(requestId, {
        resolve: resolve as (value: unknown) => void,
        reject,
        onProgress,
        abortCleanup: signal ? () => signal.removeEventListener('abort', abort) : undefined,
      })
      this.child!.write(`${JSON.stringify({ requestId, action, payload })}\n`).catch((error) => {
        const pending = this.pending.get(requestId)
        this.pending.delete(requestId)
        pending?.abortCleanup?.()
        reject(error)
      })
    })
  }

  inspect(path: string) { return this.request<VideoInfo>('inspect', { path }) }
  preparePreview(path: string) { return this.request<PreviewInfo>('preparePreview', { path }) }
  scanFolder(path: string) { return this.request<string[]>('scanFolder', { path }) }
  healthCheck() { return this.request<string>('ping', {}) }
  renderAndSave(project: RenderProject, onProgress: PendingRequest['onProgress']) {
    return this.request<{ localIdentifier: string; savedAt: string }>('renderAndSave', { project }, onProgress)
  }
  renderAndExport(project: RenderProject, directoryPath: string, onProgress: PendingRequest['onProgress']) {
    return this.request<ExportedPairResult>('renderAndExport', { project, directoryPath }, onProgress)
  }
  cancel(jobId: string) { return this.request<void>('cancel', { jobId }) }
  openPhotos() { return this.request<void>('openPhotos', {}) }
  openPhotoPrivacySettings() { return this.request<void>('openPhotoPrivacySettings', {}) }
  resetPhotoAuthorization(jobId: string) { return this.request<void>('resetPhotoAuthorization', { jobId }) }
  copyRepairCommands() { return this.request<void>('copyRepairCommands', {}) }
  systemDiagnostics() { return this.request<NativeSystemDiagnostics>('systemDiagnostics', {}) }
  revealInFinder(path: string) { return this.request<void>('revealInFinder', { path }) }
  fetchUpdateMetadata(source: 'oneleaf' | 'github', version?: string, signal?: AbortSignal) {
    // The sidecar owns the allowlist and URL construction. The abort signal
    // sends the same request id to the sidecar's cancellation registry.
    const requestId = crypto.randomUUID()
    return this.request<{ status: number; body: string; retryAfter?: number; rateLimitReset?: number }>(
      'fetchUpdateMetadata',
      { source, version },
      undefined,
      requestId,
      signal,
    )
  }
  downloadAndPrepareUpdate(
    dmgUrl: string,
    expectedSha256?: string,
    expectedSize?: number,
    expectedVersion?: string,
    onProgress?: PendingRequest['onProgress'],
    signal?: AbortSignal,
    candidate?: Omit<PreparedUpdateInfo, 'stagedAppPath' | 'targetAppPath' | 'version' | 'sha256' | 'size'>,
  ) {
    const requestId = crypto.randomUUID()
    this.activeDownloadRequestId = requestId
    return this.request<PreparedUpdateInfo>('downloadAndPrepareUpdate', {
      dmgUrl,
      expectedSha256,
      expectedSize,
      expectedVersion,
      expectedSource: candidate?.source,
      releaseNotes: candidate?.releaseNotes,
      htmlUrl: candidate?.htmlUrl,
      publishedAt: candidate?.publishedAt,
      isCritical: candidate?.isCritical,
    }, onProgress, requestId, signal)
      .finally(() => {
        if (this.activeDownloadRequestId === requestId) this.activeDownloadRequestId = undefined
      })
  }
  cancelActiveDownload() {
    const requestId = this.activeDownloadRequestId
    if (!requestId) return Promise.resolve()
    return this.request<void>('cancel', { jobId: requestId }).catch(() => undefined)
  }
  getStagedUpdate() {
    return this.request<PreparedUpdateInfo | null>('getStagedUpdate', {})
  }
  installAndRelaunch(stagedAppPath: string, targetAppPath?: string) {
    return this.request<void>('installAndRelaunch', { stagedAppPath, targetAppPath })
  }
}


const service = new LivePhotoService()

export const desktopAvailable = () => isTauri()
export const previewUrlForPath = (path: string) => isTauri() ? convertFileSrc(path) : path
export const nativeService = service

/** 获取当前窗口；Web 预览环境返回 null（调用方自行兜底）。 */
export const getCurrentWindowSafely = () => {
  if (!isTauri()) return null
  try {
    return getCurrentWindow()
  } catch {
    return null
  }
}

export const exitApplication = async () => {
  if (!isTauri()) {
    window.close()
    return
  }
  try {
    await invoke('exit_app')
  } catch {
    window.close()
  }
}
