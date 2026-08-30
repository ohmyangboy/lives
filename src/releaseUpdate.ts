import appPackage from '../package.json'
import { desktopAvailable, exitApplication, nativeService, getCurrentWindowSafely, type UpdateStage } from './nativeBridge'



export const releaseApiUrl = 'https://api.github.com/repos/ohmyangboy/lives/releases/latest'
export const ownUpdateMetadataUrl = 'https://download.1leaf.cc/lives-download-stats.json'
export const ownUpdateDownloadUrl = 'https://download.1leaf.cc/Lives-latest.dmg'
export const officialReleasePage = 'https://github.com/ohmyangboy/lives/releases/latest'
export const currentAppVersion = appPackage.version

/** 看门狗常量：任何状态都不允许永久 pending（Sparkle/PaperRss 的「必然收尾」不变式）。 */
export const CHECK_TIMEOUT_MS = 15_000
export const DOWNLOAD_STALL_TIMEOUT_MS = 90_000
export const DOWNLOAD_WATCHDOG_TICK_MS = 10_000
export const FORCE_EXIT_DELAY_MS = 8_000
export const FORCE_EXIT_RETRY_MS = 4_000

/** dev-only：localStorage 设 lives.updates.debugForce=1 时，把任何有效 release 视为可更新，便于不发版验证重启链路。 */
const debugForceUpdateAvailable = (): boolean => {
  try {
    return typeof localStorage !== 'undefined' && localStorage.getItem('lives.updates.debugForce') === '1'
  } catch {
    return false
  }
}

export interface UpdateRelease {
  version: string
  displayVersion: string
  releaseNotes?: string
  dmgUrl: string
  sha256?: string
  htmlUrl: string
  isCritical?: boolean
  publishedAt?: string
  source?: 'oneleaf' | 'github'
  size?: number
}

export interface UpdateDownloadProgress {
  release: UpdateRelease
  fractionCompleted?: number
}

export interface UpdatePreparation {
  release: UpdateRelease
  fractionCompleted: number
}

export interface UpdateFailure {
  message: string
  fallbackUrl: string
}

export interface StagedUpdateInfo {
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

export type UpdateState =
  | { kind: 'idle' }
  | { kind: 'checking' }
  | { kind: 'checkingSilently' }
  | { kind: 'upToDate'; checkedAt: Date }
  | { kind: 'updateAvailable'; release: UpdateRelease }
  | { kind: 'downloading'; progress: UpdateDownloadProgress }
  | { kind: 'preparing'; preparation: UpdatePreparation }
  | { kind: 'readyToInstall'; release: UpdateRelease; stagedAppPath: string; targetAppPath?: string }

  | { kind: 'installing'; release: UpdateRelease }
  | { kind: 'relaunching'; release: UpdateRelease }
  | { kind: 'failed'; failure: UpdateFailure }

interface GitHubAsset {
  name?: string
  browser_download_url?: string
  digest?: string
  size?: number
}

interface GitHubRelease {
  tag_name?: string
  html_url?: string
  name?: string
  body?: string
  published_at?: string
  draft?: boolean
  prerelease?: boolean
  assets?: GitHubAsset[]
}

type ResponseHeaders = { get(name: string): string | null }
type FetchLike = (input: RequestInfo | URL, init?: RequestInit) => Promise<{
  ok: boolean
  status: number
  json: () => Promise<unknown>
  headers?: ResponseHeaders
}>

export interface OwnUpdateMetadata {
  schemaVersion: 1
  currentVersion: string
  downloadUrl: typeof ownUpdateDownloadUrl
  sha256: string
  size: number
  releaseNotes?: string
  updatedAt?: string
}

export class UpdateCheckError extends Error {
  constructor(
    message: string,
    readonly status?: number,
    readonly retryAfter?: string,
    readonly source: 'oneleaf' | 'github' | 'unknown' = 'unknown',
  ) {
    super(message)
    this.name = 'UpdateCheckError'
  }
}

interface NativeMetadataResponse {
  status: number
  body: string
  retryAfter?: number
  rateLimitReset?: number
}

const isSha256 = (value: unknown): value is string => typeof value === 'string' && /^[a-f0-9]{64}$/i.test(value.trim())

const parseOwnMetadata = (value: unknown): OwnUpdateMetadata => {
  const metadata = value as Partial<OwnUpdateMetadata> | null
  if (
    !metadata ||
    metadata.schemaVersion !== 1 ||
    typeof metadata.currentVersion !== 'string' ||
    !/^v?[0-9]+\.[0-9]+\.[0-9]+$/.test(metadata.currentVersion) ||
    metadata.downloadUrl !== ownUpdateDownloadUrl ||
    !isSha256(metadata.sha256) ||
    typeof metadata.size !== 'number' ||
    !Number.isSafeInteger(metadata.size) ||
    metadata.size < 1024 * 1024
  ) {
    throw new UpdateCheckError('自有更新源返回的数据无效', undefined, undefined, 'oneleaf')
  }
  if (compareVersions(metadata.currentVersion, '0.0.0') === undefined) {
    throw new UpdateCheckError('自有更新源返回了无效版本号', undefined, undefined, 'oneleaf')
  }
  return metadata as OwnUpdateMetadata
}

const responseHeader = (response: { headers?: ResponseHeaders }, name: string): string | undefined => {
  try { return response.headers?.get(name) ?? undefined } catch { return undefined }
}

const retryAfterHeader = (response: { headers?: ResponseHeaders }): string | undefined => {
  const retryAfter = responseHeader(response, 'retry-after')
  if (retryAfter) return retryAfter
  const reset = Number(responseHeader(response, 'x-ratelimit-reset'))
  if (!Number.isFinite(reset)) return undefined
  return String(Math.max(0, Math.ceil(reset - Date.now() / 1000)))
}

const ownReleaseFromMetadata = (metadata: OwnUpdateMetadata): UpdateRelease => ({
  version: metadata.currentVersion.replace(/^v/i, ''),
  displayVersion: `v${metadata.currentVersion.replace(/^v/i, '')}`,
  releaseNotes: metadata.releaseNotes,
  dmgUrl: ownUpdateDownloadUrl,
  sha256: metadata.sha256.toLowerCase(),
  size: metadata.size,
  htmlUrl: officialReleasePage,
  isCritical: false,
  publishedAt: metadata.updatedAt,
  source: 'oneleaf',
})

const parseGitHubRelease = (release: GitHubRelease): UpdateRelease | undefined => {
  if (
    release.draft === true ||
    release.prerelease === true ||
    typeof release.tag_name !== 'string' ||
    typeof release.html_url !== 'string'
  ) return undefined
  const comparison = compareVersions(release.tag_name, currentAppVersion)
  const force = debugForceUpdateAvailable()
  if (comparison === undefined || (comparison <= 0 && !force)) return undefined
  const rawVersion = release.tag_name.replace(/^v/i, '')
  const assets = Array.isArray(release.assets) ? release.assets : []
  const dmgAssets = assets.filter((asset) => typeof asset.name === 'string' && asset.name.toLowerCase().endsWith('.dmg'))
  const dmgAsset = dmgAssets.find((asset) => /(?:aarch64|arm64)/i.test(asset.name ?? ''))
    ?? (dmgAssets.length === 1 ? dmgAssets[0] : undefined)
  if (!dmgAsset?.browser_download_url || !isSha256(dmgAsset.digest?.replace(/^sha256:/i, '')) ||
      typeof dmgAsset.size !== 'number' || !Number.isSafeInteger(dmgAsset.size) || dmgAsset.size < 1024 * 1024) return undefined
  return {
    version: rawVersion,
    displayVersion: `v${rawVersion}`,
    releaseNotes: typeof release.body === 'string' ? release.body : undefined,
    dmgUrl: dmgAsset.browser_download_url,
    sha256: dmgAsset.digest!.replace(/^sha256:/i, '').trim().toLowerCase(),
    size: typeof dmgAsset.size === 'number' ? dmgAsset.size : undefined,
    htmlUrl: release.html_url,
    isCritical: false,
    publishedAt: typeof release.published_at === 'string' ? release.published_at : undefined,
    source: 'github',
  }
}

const parseHttpFailure = (status: number, source: 'oneleaf' | 'github', retryAfter?: string): UpdateCheckError => {
  if (status === 403 || status === 429) {
    const wait = retryAfter ? `，请在 ${retryAfter} 后重试` : ''
    return new UpdateCheckError(`${source === 'github' ? 'GitHub' : '自有更新源'}请求受到限流（HTTP ${status}）${wait}`, status, retryAfter, source)
  }
  return new UpdateCheckError(`更新检查失败（HTTP ${status}）`, status, retryAfter, source)
}

const numericVersion = (value: string) => {
  const match = value.trim().match(/^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/i)
  if (!match) return undefined
  return { core: [Number(match[1]), Number(match[2] ?? 0), Number(match[3] ?? 0)], prerelease: match[4]?.split('.') ?? [] }
}

/** Returns a positive number only when `candidate` is newer than `current`. */
export const compareVersions = (candidate: string, current: string) => {
  const candidateParts = numericVersion(candidate)
  const currentParts = numericVersion(current)
  if (!candidateParts || !currentParts) return undefined
  for (let index = 0; index < candidateParts.core.length; index += 1) {
    if (candidateParts.core[index] !== currentParts.core[index]) return candidateParts.core[index] - currentParts.core[index]
  }
  const left = candidateParts.prerelease
  const right = currentParts.prerelease
  if (!left.length || !right.length) return Number(!left.length) - Number(!right.length)
  for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
    const a = left[index], b = right[index]
    if (a === undefined) return -1
    if (b === undefined) return 1
    if (a === b) continue
    const aNumeric = /^\d+$/.test(a), bNumeric = /^\d+$/.test(b)
    if (aNumeric && bNumeric) return Number(a) - Number(b)
    if (aNumeric !== bNumeric) return aNumeric ? -1 : 1
    return a < b ? -1 : 1
  }
  return 0
}

export const fetchLatestRelease = async (fetcher: FetchLike = fetch, signal?: AbortSignal): Promise<UpdateRelease | undefined> => {
  const response = await fetcher(releaseApiUrl, {
    headers: { Accept: 'application/vnd.github+json' },
    signal,
  })
  if (!response.ok) throw parseHttpFailure(response.status, 'github', retryAfterHeader(response))
  return parseGitHubRelease(await response.json() as GitHubRelease)
}

const fetchOwnMetadata = async (fetcher: FetchLike = fetch, signal?: AbortSignal): Promise<OwnUpdateMetadata> => {
  const response = await fetcher(ownUpdateMetadataUrl, { headers: { Accept: 'application/json' }, signal })
  if (!response.ok) throw parseHttpFailure(response.status, 'oneleaf', retryAfterHeader(response))
  return parseOwnMetadata(await response.json())
}

const nativeMetadataError = (response: NativeMetadataResponse, source: 'oneleaf' | 'github'): UpdateCheckError => {
  const retryAfter = response.retryAfter !== undefined
    ? String(response.retryAfter)
    : response.rateLimitReset !== undefined
      ? String(Math.max(0, Math.ceil(response.rateLimitReset - Date.now() / 1000)))
      : undefined
  return parseHttpFailure(response.status, source, retryAfter)
}

const parseNativeMetadata = (response: NativeMetadataResponse, source: 'oneleaf' | 'github'): unknown => {
  try { return JSON.parse(response.body) } catch { throw new UpdateCheckError('更新源返回了无效 JSON', response.status, undefined, source) }
}

const throwIfAborted = (signal?: AbortSignal) => {
  if (signal?.aborted) throw new DOMException('请求已取消', 'AbortError')
}

const isIntegrityFailure = (error: unknown): boolean => {
  const code = typeof error === 'object' && error !== null && 'code' in error
    ? String((error as { code?: unknown }).code)
    : ''
  return code === 'UPDATE_SIZE_MISMATCH' || code === 'UPDATE_SHA256_MISMATCH'
}

const retryAfterMilliseconds = (value: string | undefined, now: number): number | undefined => {
  if (!value) return undefined
  const seconds = Number(value.trim())
  if (Number.isFinite(seconds) && seconds >= 0) return seconds * 1000
  const timestamp = Date.parse(value)
  return Number.isFinite(timestamp) && timestamp > now ? timestamp - now : undefined
}

const isSuccessfulStatus = (status: number) => status >= 200 && status <= 299

export type DownloadStage = 'downloading' | 'verifying' | 'preparing'

export interface UpdaterPort {
  checkForUpdate(signal?: AbortSignal): Promise<UpdateRelease | undefined>
  getStagedUpdate(): Promise<StagedUpdateInfo | undefined>
  downloadAndPrepare(
    release: UpdateRelease,
    onProgress: (stage: DownloadStage, progress: number) => void,
    signal?: AbortSignal,
  ): Promise<{ stagedAppPath: string; targetAppPath?: string; release?: UpdateRelease }>
  installAndRelaunch(stagedAppPath: string, targetAppPath?: string): Promise<void>
  cancelActiveDownload(): Promise<void>
}

export class DefaultUpdaterPort implements UpdaterPort {
  private fetcher: FetchLike
  private ownRetryNotBefore?: number

  constructor(fetcher: FetchLike = fetch) {
    this.fetcher = fetcher
  }

  async checkForUpdate(signal?: AbortSignal): Promise<UpdateRelease | undefined> {
    // Vite Web 预览不应依赖真实更新服务器；生产桌面包始终走原生网络层。
    if (!desktopAvailable() && import.meta.env.DEV && this.fetcher === fetch) return undefined
    let ownError: unknown
    const ownRetryActive = this.ownRetryNotBefore !== undefined && this.ownRetryNotBefore > Date.now()
    if (!ownRetryActive) {
      try {
        const metadata = desktopAvailable()
          ? await (async () => {
            const response = await nativeService.fetchUpdateMetadata('oneleaf', undefined, signal)
            if (!isSuccessfulStatus(response.status)) throw nativeMetadataError(response, 'oneleaf')
            return parseOwnMetadata(parseNativeMetadata(response, 'oneleaf'))
          })()
          : await fetchOwnMetadata(this.fetcher, signal)
        this.ownRetryNotBefore = undefined
        const comparison = compareVersions(metadata.currentVersion, currentAppVersion)
        if (comparison === undefined) throw new UpdateCheckError('自有更新源返回了无效版本号', undefined, undefined, 'oneleaf')
        if (comparison <= 0 && !debugForceUpdateAvailable()) return undefined
        return ownReleaseFromMetadata(metadata)
      } catch (error) {
        ownError = error
        if (error instanceof UpdateCheckError) {
          const delay = retryAfterMilliseconds(error.retryAfter, Date.now())
          if (delay !== undefined) this.ownRetryNotBefore = Date.now() + delay
        }
      }
    }

    // 自有源不可用或处于服务端 Retry-After 冷却期时才访问 GitHub；
    // 合法且版本不新的自有清单已在上面直接返回，不会额外访问 GitHub。
    try {
      return await this.fetchGitHubLatest(signal)
    } catch (githubError) {
      if (githubError instanceof UpdateCheckError && ownError instanceof UpdateCheckError) {
        throw new UpdateCheckError(
          `${ownError.message}；备用源${githubError.message}`,
          githubError.status ?? ownError.status,
          githubError.retryAfter ?? ownError.retryAfter,
          githubError.source,
        )
      }
      throw githubError
    }
  }

  private async fetchGitHubLatest(signal?: AbortSignal): Promise<UpdateRelease | undefined> {
    if (desktopAvailable()) {
      const response = await nativeService.fetchUpdateMetadata('github', undefined, signal)
      if (response.status < 200 || response.status > 299) throw nativeMetadataError(response, 'github')
      const release = parseGitHubRelease(parseNativeMetadata(response, 'github') as GitHubRelease)
      if (!release) throw new UpdateCheckError('GitHub 没有可用的正式版 Apple Silicon DMG', response.status, undefined, 'github')
      return release
    }
    const response = await this.fetcher(releaseApiUrl, {
      headers: { Accept: 'application/vnd.github+json' }, signal,
    })
    if (!response.ok) throw parseHttpFailure(response.status, 'github', retryAfterHeader(response))
    const release = parseGitHubRelease(await response.json() as GitHubRelease)
    if (!release) throw new UpdateCheckError('GitHub 没有可用的正式版 Apple Silicon DMG', response.status, undefined, 'github')
    return release
  }

  private async fetchGitHubForVersion(version: string, signal?: AbortSignal): Promise<UpdateRelease | undefined> {
    const expected = version.replace(/^v/i, '')
    if (desktopAvailable()) {
      const response = await nativeService.fetchUpdateMetadata('github', expected, signal)
      if (response.status < 200 || response.status > 299) throw nativeMetadataError(response, 'github')
      const release = parseGitHubRelease(parseNativeMetadata(response, 'github') as GitHubRelease)
      if (!release || compareVersions(release.version, expected) !== 0) return undefined
      return release
    }
    const response = await this.fetcher(`https://api.github.com/repos/ohmyangboy/lives/releases/tags/v${expected}`, {
      headers: { Accept: 'application/vnd.github+json' }, signal,
    })
    if (!response.ok) throw parseHttpFailure(response.status, 'github', retryAfterHeader(response))
    const release = parseGitHubRelease(await response.json() as GitHubRelease)
    if (!release || compareVersions(release.version, expected) !== 0) return undefined
    return release
  }

  async getStagedUpdate(): Promise<StagedUpdateInfo | undefined> {
    if (!desktopAvailable()) return undefined
    const staged = await nativeService.getStagedUpdate()
    return staged ? {
      ...staged,
      source: staged.source === 'oneleaf' || staged.source === 'github' ? staged.source : undefined,
    } : undefined
  }

  async downloadAndPrepare(
    release: UpdateRelease,
    onProgress: (stage: DownloadStage, progress: number) => void,
    signal?: AbortSignal,
  ): Promise<{ stagedAppPath: string; targetAppPath?: string; release?: UpdateRelease }> {
    throwIfAborted(signal)
    if (!desktopAvailable()) {
      // Mock for web preview / non-Tauri dev
      for (let p = 0; p <= 1; p += 0.2) {
        throwIfAborted(signal)
        onProgress('downloading', p)
        await new Promise((r) => setTimeout(r, 100))
      }
      throwIfAborted(signal)
      onProgress('preparing', 1.0)
      return { stagedAppPath: '/tmp/MockLives.app' }
    }

    if (!release.sha256 || !isSha256(release.sha256) || !release.size) {
      throw new Error('更新候选缺少完整性校验信息，已停止安装')
    }

    const report = (stage: UpdateStage, progress: number) => {
      if (stage === 'downloading' || stage === 'verifying' || stage === 'preparing') onProgress(stage, progress)
    }
    try {
      const result = await nativeService.downloadAndPrepareUpdate(
        release.dmgUrl, release.sha256, release.size, release.version, report, signal,
        { source: release.source, releaseNotes: release.releaseNotes, htmlUrl: release.htmlUrl, publishedAt: release.publishedAt, isCritical: release.isCritical },
      )
      return { stagedAppPath: result.stagedAppPath, targetAppPath: result.targetAppPath, release }
    } catch (primaryError) {
      throwIfAborted(signal)
      if (release.source !== 'oneleaf') throw primaryError
      // latest.dmg 在发布切换窗口可能与清单不一致：先刷新一次清单，最多再尝试同一会话的一次备用源。
      let fallbackRelease = release
      let syncFailure = isIntegrityFailure(primaryError)
      try {
        const refreshed = desktopAvailable()
          ? await (async () => {
            const response = await nativeService.fetchUpdateMetadata('oneleaf', undefined, signal)
            if (!isSuccessfulStatus(response.status)) throw nativeMetadataError(response, 'oneleaf')
            return parseOwnMetadata(parseNativeMetadata(response, 'oneleaf'))
          })()
          : await fetchOwnMetadata(this.fetcher, signal)
        const refreshedRelease = ownReleaseFromMetadata(refreshed)
        const sameCandidate = refreshedRelease.version === release.version && refreshedRelease.sha256 === release.sha256
        const candidate = sameCandidate ? undefined : refreshedRelease
        if (candidate && compareVersions(candidate.version, currentAppVersion)! > 0) {
          fallbackRelease = candidate
          try {
            const result = await nativeService.downloadAndPrepareUpdate(
              candidate.dmgUrl, candidate.sha256, candidate.size, candidate.version, report, signal,
              { source: candidate.source, releaseNotes: candidate.releaseNotes, htmlUrl: candidate.htmlUrl, publishedAt: candidate.publishedAt, isCritical: candidate.isCritical },
            )
            return { stagedAppPath: result.stagedAppPath, targetAppPath: result.targetAppPath, release: candidate }
          } catch (candidateError) {
            throwIfAborted(signal)
            syncFailure ||= isIntegrityFailure(candidateError)
          }
        }
      } catch {
        throwIfAborted(signal)
        // 继续尝试匹配版本的 GitHub 备用包；最终保留主源错误作为上下文。
      }
      if (syncFailure) {
        throw new Error(`${primaryError instanceof Error ? primaryError.message : '自有源下载失败'}；更新源正在同步或安装包校验失败`)
      }
      throwIfAborted(signal)
      const fallback = await this.fetchGitHubForVersion(fallbackRelease.version, signal)
      throwIfAborted(signal)
      if (!fallback?.sha256 || !fallback.size || fallback.version !== fallbackRelease.version || fallback.size !== fallbackRelease.size || fallback.sha256 !== fallbackRelease.sha256) {
        throw new Error(`${primaryError instanceof Error ? primaryError.message : '自有源下载失败'}；GitHub 备用包与自有清单不匹配`)
      }
      const result = await nativeService.downloadAndPrepareUpdate(
        fallback.dmgUrl, fallback.sha256, fallback.size, fallback.version, report, signal,
        { source: fallback.source, releaseNotes: fallback.releaseNotes, htmlUrl: fallback.htmlUrl, publishedAt: fallback.publishedAt, isCritical: fallback.isCritical },
      )
      return { stagedAppPath: result.stagedAppPath, targetAppPath: result.targetAppPath, release: fallback }
    }
  }

  async installAndRelaunch(stagedAppPath: string, targetAppPath?: string): Promise<void> {
    if (!desktopAvailable()) {
      window.location.reload()
      return
    }
    // 重启后的新实例会消费这个标记，弹出"更新完成 + 反馈提示"。
    try { localStorage.setItem('lives.postUpdateFeedbackPending', '1') } catch { /* 忽略 */ }
    await nativeService.installAndRelaunch(stagedAppPath, targetAppPath)
    await exitApplication()
    // 进程应已退出；若我们仍在运行（exit_app 未生效），安排强制退出：
    // 先重试 exit_app，最终 destroy 窗口（后台脚本会照常换包并复活）。
    this.scheduleForceExit()
  }

  private scheduleForceExit(): void {
    setTimeout(() => {
      void exitApplication()
      setTimeout(() => {
        const win = getCurrentWindowSafely()
        try { void win?.destroy() } catch { /* 窗口已不存在 */ }
      }, FORCE_EXIT_RETRY_MS)
    }, FORCE_EXIT_DELAY_MS)
  }

  async cancelActiveDownload(): Promise<void> {
    if (!desktopAvailable()) return
    await nativeService.cancelActiveDownload()
  }
}

export type UpdateStateListener = (state: UpdateState) => void

export interface UpdateCoordinatorOptions {
  checkTimeoutMs?: number
  downloadStallTimeoutMs?: number
  downloadWatchdogTickMs?: number
}

export class UpdateCoordinator {
  private _state: UpdateState = { kind: 'idle' }
  private _lastUpToDateNoticeAt?: Date
  private listeners = new Set<UpdateStateListener>()
  private updater: UpdaterPort
  private fallbackUrl: string
  private hasStarted = false
  private now: () => Date
  private options: Required<UpdateCoordinatorOptions>

  private checkAbort?: AbortController
  private downloadWatchdog?: ReturnType<typeof setTimeout>
  private downloadAbort?: AbortController
  private retryNotBefore?: number
  private lastDownloadProgressAt = 0
  private downloadCancelRequested = false

  constructor(
    updater: UpdaterPort = new DefaultUpdaterPort(),
    fallbackUrl: string = officialReleasePage,
    now: () => Date = () => new Date(),
    options: UpdateCoordinatorOptions = {}
  ) {
    this.updater = updater
    this.fallbackUrl = fallbackUrl
    this.now = now
    this.options = {
      checkTimeoutMs: options.checkTimeoutMs ?? CHECK_TIMEOUT_MS,
      downloadStallTimeoutMs: options.downloadStallTimeoutMs ?? DOWNLOAD_STALL_TIMEOUT_MS,
      downloadWatchdogTickMs: options.downloadWatchdogTickMs ?? DOWNLOAD_WATCHDOG_TICK_MS,
    }
  }

  get state(): UpdateState {
    return this._state
  }

  get lastUpToDateNoticeAt(): Date | undefined {
    return this._lastUpToDateNoticeAt
  }

  get isActiveSession(): boolean {
    switch (this._state.kind) {
      case 'idle':
      case 'upToDate':
      case 'failed':
        return false
      case 'checking':
      case 'checkingSilently':
      case 'updateAvailable':
      case 'downloading':
      case 'preparing':
      case 'readyToInstall':
      case 'installing':
      case 'relaunching':
        return true
    }
  }

  subscribe(listener: UpdateStateListener): () => void {
    this.listeners.add(listener)
    listener(this._state)
    return () => {
      this.listeners.delete(listener)
    }
  }

  private setState(next: UpdateState) {
    this._state = next
    for (const listener of this.listeners) {
      listener(next)
    }
  }

  private applyFailure(message: string) {
    this.setState({
      kind: 'failed',
      failure: { message, fallbackUrl: this.fallbackUrl },
    })
  }

  /**
   * Cold start (idempotent).
   * 1) 先尝试中断恢复：存在「已下载未安装」且比当前版本新的暂存包 → 直接 readyToInstall。
   * 2) 否则静默检查；发现更新即自动开始静默下载。
   */
  start(): void {
    if (this.hasStarted) return
    this.hasStarted = true
    void this.resumeStagedUpdateIfAvailable().then((resumed) => {
      if (!resumed && this._state.kind === 'idle') {
        this.initiateCheck(false)
      }
    })
  }

  /** Sparkle 的 stage: .downloaded 恢复语义：无需重新下载，一键完成安装。 */
  private async resumeStagedUpdateIfAvailable(): Promise<boolean> {
    try {
      const staged = await this.updater.getStagedUpdate()
      if (!staged?.version || this._state.kind !== 'idle') return false
      const stagedVersion = staged.version
      const comparison = compareVersions(stagedVersion, currentAppVersion)
      if (comparison === undefined || comparison <= 0) return false

      const release: UpdateRelease = {
        version: stagedVersion,
        displayVersion: `v${stagedVersion}`,
        releaseNotes: staged.releaseNotes ?? '上次下载的更新已就绪，点击重启完成安装。',
        dmgUrl: staged.dmgUrl ?? '',
        sha256: staged.sha256,
        size: staged.size,
        htmlUrl: staged.htmlUrl ?? this.fallbackUrl,
        isCritical: staged.isCritical ?? false,
        publishedAt: staged.publishedAt,
        source: staged.source,
      }
      if (this._state.kind !== 'idle') return false
      this.setState({
        kind: 'readyToInstall',
        release,
        stagedAppPath: staged.stagedAppPath,
        targetAppPath: staged.targetAppPath,
      })
      return true
    } catch {
      // 恢复失败不阻塞正常检查（旧版 sidecar 无此能力时同样走这里）。
      return false
    }
  }

  /**
   * Manual check triggered by user (from App Menu or Retry button).
   */
  checkForUpdates(userInitiated = true): void {
    if (this._state.kind === 'checkingSilently') {
      this.setState({ kind: 'checking' })
      return
    }
    if (this.isActiveSession && this._state.kind !== 'failed') return
    this.initiateCheck(userInitiated)
  }

  private initiateCheck(userInitiated: boolean): void {
    const now = this.now().getTime()
    if (this.retryNotBefore && this.retryNotBefore > now) {
      if (userInitiated) {
        const seconds = Math.max(1, Math.ceil((this.retryNotBefore - now) / 1000))
        this.applyFailure(`更新源要求稍后重试（约 ${seconds} 秒后可重试）`)
      } else {
        this.setState({ kind: 'idle' })
      }
      return
    }
    this.retryNotBefore = undefined
    this.setState(userInitiated ? { kind: 'checking' } : { kind: 'checkingSilently' })

    const controller = new AbortController()
    this.checkAbort = controller

    // 收尾不变式：检查必须在超时后强制落定（不依赖底层实现是否尊重 AbortSignal）。
    const stillChecking = () => this._state.kind === 'checking' || this._state.kind === 'checkingSilently'
    const timeout = setTimeout(() => {
      controller.abort()
      if (!stillChecking()) return
      const message = `检查更新超时（${Math.round(this.options.checkTimeoutMs / 1000)} 秒），请检查网络后重试`
      if (userInitiated || this._state.kind === 'checking') {
        this.applyFailure(message)
      } else {
        this.setState({ kind: 'idle' })
      }
    }, this.options.checkTimeoutMs)

    void this.updater
      .checkForUpdate(controller.signal)
      .then((release) => {
        if (!stillChecking()) return // 超时已收尾，忽略迟到的结果
        this.retryNotBefore = undefined
        if (!release) {
          const checkTime = this.now()
          const wasManual = this._state.kind === 'checking'
          this.setState({ kind: 'upToDate', checkedAt: checkTime })
          if (wasManual) {
            this._lastUpToDateNoticeAt = checkTime
            for (const listener of this.listeners) listener(this._state)
          }
        } else {
          this.setState({ kind: 'updateAvailable', release })
          // Automatically start silent background download
          this.beginDownload(release)
        }
      })
      .catch((error) => {
        if (!stillChecking()) return // 超时已收尾，忽略迟到的取消/错误
        if (error instanceof UpdateCheckError) {
          const delay = retryAfterMilliseconds(error.retryAfter, this.now().getTime())
          if (delay !== undefined) this.retryNotBefore = this.now().getTime() + delay
        }
        const aborted = controller.signal.aborted
        const message = aborted
          ? `检查更新超时（${Math.round(this.options.checkTimeoutMs / 1000)} 秒），请检查网络后重试`
          : error instanceof Error ? error.message : '检查更新失败'
        if (userInitiated || this._state.kind === 'checking') {
          this.applyFailure(message)
        } else {
          // Silent check failure silently returns to idle
          this.setState({ kind: 'idle' })
        }
      })
      .finally(() => {
        clearTimeout(timeout)
        if (this.checkAbort === controller) this.checkAbort = undefined
      })
  }

  /**
   * Begins downloading and preparing the update.
   */
  beginDownload(targetRelease?: UpdateRelease): void {
    const release = targetRelease ?? (this._state.kind === 'updateAvailable' ? this._state.release : undefined)
    if (!release) return

    this.downloadCancelRequested = false
    const controller = new AbortController()
    this.downloadAbort = controller
    this.lastDownloadProgressAt = Date.now()
    this.setState({
      kind: 'downloading',
      progress: { release, fractionCompleted: undefined },
    })
    this.startDownloadWatchdog()

    void this.updater
      .downloadAndPrepare(release, (stage, progress) => {
        this.lastDownloadProgressAt = Date.now()
        if (stage === 'downloading') {
          if (this._state.kind === 'downloading') {
            this.setState({
              kind: 'downloading',
              progress: { release, fractionCompleted: progress },
            })
          }
        } else if (stage === 'preparing' || stage === 'verifying') {
          if (this._state.kind === 'downloading' || this._state.kind === 'preparing') {
            this.setState({
              kind: 'preparing',
              preparation: { release, fractionCompleted: progress },
            })
          }
        }
      }, controller.signal)
      .then(({ stagedAppPath, targetAppPath, release: preparedRelease }) => {
        this.stopDownloadWatchdog()
        if (this._state.kind !== 'downloading' && this._state.kind !== 'preparing') return
        const completedRelease = preparedRelease ?? release
        this.setState({
          kind: 'readyToInstall',
          release: completedRelease,
          stagedAppPath,
          targetAppPath,
        })
      })
      .catch((error) => {
        this.stopDownloadWatchdog()
        // 看门狗已设置 failed 态时，忽略后续的取消/超时错误。
        if (this.downloadCancelRequested) return
        const message = error instanceof Error ? error.message : '下载或准备更新失败'
        if (this._state.kind === 'downloading' || this._state.kind === 'preparing') {
          this.applyFailure(message)
        }
      })
      .finally(() => {
        if (this.downloadAbort === controller) this.downloadAbort = undefined
      })
  }

  /** 下载停滞看门狗：超过阈值无任何进度 → 取消下载并进入 failed（可重试）。 */
  private startDownloadWatchdog(): void {
    this.stopDownloadWatchdog()
    this.downloadWatchdog = setInterval(() => {
      const idleFor = Date.now() - this.lastDownloadProgressAt
      if (idleFor < this.options.downloadStallTimeoutMs) return
      this.stopDownloadWatchdog()
      if (this._state.kind !== 'downloading' && this._state.kind !== 'preparing') return
      this.downloadCancelRequested = true
      this.downloadAbort?.abort()
      this.applyFailure('下载停滞（长时间无进展），已自动取消，请重试')
      void this.updater.cancelActiveDownload().catch(() => undefined)
    }, this.options.downloadWatchdogTickMs)
  }

  private stopDownloadWatchdog(): void {
    if (this.downloadWatchdog) {
      clearInterval(this.downloadWatchdog)
      this.downloadWatchdog = undefined
    }
  }

  cancelDownload(): void {
    if (this._state.kind !== 'downloading' && this._state.kind !== 'preparing') return
    this.downloadCancelRequested = true
    this.downloadAbort?.abort()
    this.stopDownloadWatchdog()
    this.setState({ kind: 'idle' })
    void this.updater.cancelActiveDownload().catch(() => undefined)
  }

  /**
   * Installs the downloaded update and relaunches the app.
   */
  installAndRelaunch(): void {
    if (this._state.kind !== 'readyToInstall') return
    const { release, stagedAppPath, targetAppPath } = this._state

    this.setState({ kind: 'installing', release })
    void this.updater
      .installAndRelaunch(stagedAppPath, targetAppPath)
      .then(() => {
        this.setState({ kind: 'relaunching', release })
      })
      .catch((error) => {
        const message = error instanceof Error ? error.message : '安装更新失败'
        this.applyFailure(message)
      })
  }


  dismissFailure(): void {
    if (this._state.kind === 'failed') {
      this.setState({ kind: 'idle' })
    }
  }
}

// Global coordinator singleton instance for the app lifecycle
export const defaultUpdateCoordinator = new UpdateCoordinator()
