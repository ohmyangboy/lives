import { convertFileSrc, invoke, isTauri } from '@tauri-apps/api/core'
import { Command, type Child } from '@tauri-apps/plugin-shell'

import type { RenderProject } from './domain'

export interface VideoInfo {
  path: string
  durationMs: number
  width: number
  height: number
  codec: string
}

export type NativeStage = 'inspecting' | 'transcoding' | 'rendering' | 'writingMetadata' | 'validating' | 'requestingPhotoPermission' | 'saving' | 'exportingFiles' | 'verifyingSavedAsset' | 'completed'

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
}


class LivePhotoService {
  private child?: Child
  private pending = new Map<string, PendingRequest>()
  private starting?: Promise<void>

  private async start() {
    if (this.child) return
    if (this.starting) return this.starting
    this.starting = (async () => {
      const command = Command.sidecar('binaries/live-photo-service', ['serve'])
      command.stdout.on('data', (line) => this.receive(line))
      command.stderr.on('data', (line) => console.warn('[LivePhotoService]', line))
      command.on('close', () => {
        this.child = undefined
        for (const pending of this.pending.values()) pending.reject(new Error('原生媒体服务已停止'))
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
    if (message.type === 'error') {
      const error = new Error(message.error?.message ?? '操作失败')
      Object.assign(error, { code: message.error?.code, recovery: message.error?.recovery })
      pending.reject(error)
    } else {
      pending.resolve(message.payload)
    }
  }

  private async request<T>(action: string, payload: unknown, onProgress?: PendingRequest['onProgress']): Promise<T> {
    await this.start()
    const requestId = crypto.randomUUID()
    return new Promise<T>((resolve, reject) => {
      this.pending.set(requestId, { resolve: resolve as (value: unknown) => void, reject, onProgress })
      this.child!.write(`${JSON.stringify({ requestId, action, payload })}\n`).catch((error) => {
        this.pending.delete(requestId)
        reject(error)
      })
    })
  }

  inspect(path: string) { return this.request<VideoInfo>('inspect', { path }) }
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
  revealInFinder(path: string) { return this.request<void>('revealInFinder', { path }) }
  downloadAndPrepareUpdate(dmgUrl: string, expectedSha256?: string, onProgress?: PendingRequest['onProgress']) {
    return this.request<PreparedUpdateInfo>('downloadAndPrepareUpdate', { dmgUrl, expectedSha256 }, onProgress)
  }
  installAndRelaunch(stagedAppPath: string, targetAppPath?: string) {
    return this.request<void>('installAndRelaunch', { stagedAppPath, targetAppPath })
  }
}


const service = new LivePhotoService()

export const desktopAvailable = () => isTauri()
export const previewUrlForPath = (path: string) => isTauri() ? convertFileSrc(path) : path
export const nativeService = service
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

