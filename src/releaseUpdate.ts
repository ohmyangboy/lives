import appPackage from '../package.json'
import { desktopAvailable, exitApplication, nativeService, getCurrentWindowSafely, type UpdateStage } from './nativeBridge'



export const releaseApiUrl = 'https://api.github.com/repos/ohmyangboy/lives/releases/latest'
export const officialReleasePage = 'https://github.com/ohmyangboy/lives/releases/latest'
export const currentAppVersion = appPackage.version

/** 看门狗常量：任何状态都不允许永久 pending（Sparkle/PaperRss 的「必然收尾」不变式）。 */
export const CHECK_TIMEOUT_MS = 12_000
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

type FetchLike = (input: RequestInfo | URL, init?: RequestInit) => Promise<Pick<Response, 'ok' | 'json' | 'status'>>

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
  if (!response.ok) return undefined

  const release = await response.json() as GitHubRelease
  if (
    release.draft === true ||
    release.prerelease === true ||
    typeof release.tag_name !== 'string' ||
    typeof release.html_url !== 'string'
  ) {
    return undefined
  }

  const comparison = compareVersions(release.tag_name, currentAppVersion)
  const force = debugForceUpdateAvailable()
  if (comparison === undefined || (comparison <= 0 && !force)) return undefined

  const rawVersion = release.tag_name.replace(/^v/i, '')
  const assets = Array.isArray(release.assets) ? release.assets : []
  const dmgAsset = assets.find((asset) => typeof asset.name === 'string' && asset.name.endsWith('.dmg'))
  if (!dmgAsset?.browser_download_url) return undefined

  // Extract optional sha256
  let sha256: string | undefined
  if (dmgAsset.digest?.startsWith('sha256:')) {
    sha256 = dmgAsset.digest.replace(/^sha256:/i, '').trim()
  }

  return {
    version: rawVersion,
    displayVersion: `v${rawVersion}`,
    releaseNotes: typeof release.body === 'string' ? release.body : undefined,
    dmgUrl: dmgAsset.browser_download_url,
    sha256,
    htmlUrl: release.html_url,
    isCritical: false,
    publishedAt: typeof release.published_at === 'string' ? release.published_at : undefined,
  }
}

export type DownloadStage = 'downloading' | 'verifying' | 'preparing'

export interface UpdaterPort {
  checkForUpdate(signal?: AbortSignal): Promise<UpdateRelease | undefined>
  getStagedUpdate(): Promise<StagedUpdateInfo | undefined>
  downloadAndPrepare(
    release: UpdateRelease,
    onProgress: (stage: DownloadStage, progress: number) => void
  ): Promise<{ stagedAppPath: string; targetAppPath?: string }>
  installAndRelaunch(stagedAppPath: string, targetAppPath?: string): Promise<void>
  cancelActiveDownload(): Promise<void>
}

export class DefaultUpdaterPort implements UpdaterPort {
  private fetcher: FetchLike

  constructor(fetcher: FetchLike = fetch) {
    this.fetcher = fetcher
  }

  async checkForUpdate(signal?: AbortSignal): Promise<UpdateRelease | undefined> {
    return fetchLatestRelease(this.fetcher, signal)
  }

  async getStagedUpdate(): Promise<StagedUpdateInfo | undefined> {
    if (!desktopAvailable()) return undefined
    const staged = await nativeService.getStagedUpdate()
    return staged ?? undefined
  }

  async downloadAndPrepare(
    release: UpdateRelease,
    onProgress: (stage: DownloadStage, progress: number) => void
  ): Promise<{ stagedAppPath: string; targetAppPath?: string }> {
    if (!desktopAvailable()) {
      // Mock for web preview / non-Tauri dev
      for (let p = 0; p <= 1; p += 0.2) {
        onProgress('downloading', p)
        await new Promise((r) => setTimeout(r, 100))
      }
      onProgress('preparing', 1.0)
      return { stagedAppPath: '/tmp/MockLives.app' }
    }

    const result = await nativeService.downloadAndPrepareUpdate(
      release.dmgUrl,
      release.sha256,
      (stage: UpdateStage, progress: number) => {
        if (stage === 'downloading' || stage === 'verifying' || stage === 'preparing') {
          onProgress(stage, progress)
        }
      }
    )

    return {
      stagedAppPath: result.stagedAppPath,
      targetAppPath: result.targetAppPath,
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
        releaseNotes: '上次下载的更新已就绪，点击重启完成安装。',
        dmgUrl: '',
        htmlUrl: this.fallbackUrl,
        isCritical: false,
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
    this.setState(userInitiated ? { kind: 'checking' } : { kind: 'checkingSilently' })

    const controller = new AbortController()
    this.checkAbort = controller

    // 收尾不变式：检查必须在超时后强制落定（不依赖底层实现是否尊重 AbortSignal）。
    const stillChecking = () => this._state.kind === 'checking' || this._state.kind === 'checkingSilently'
    const timeout = setTimeout(() => {
      controller.abort()
      if (!stillChecking()) return
      const message = `检查更新超时（${Math.round(this.options.checkTimeoutMs / 1000)} 秒），请检查网络后重试`
      if (userInitiated) {
        this.applyFailure(message)
      } else {
        this.setState({ kind: 'idle' })
      }
    }, this.options.checkTimeoutMs)

    void this.updater
      .checkForUpdate(controller.signal)
      .then((release) => {
        if (!stillChecking()) return // 超时已收尾，忽略迟到的结果
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
        const aborted = controller.signal.aborted
        const message = aborted
          ? `检查更新超时（${Math.round(this.options.checkTimeoutMs / 1000)} 秒），请检查网络后重试`
          : error instanceof Error ? error.message : '检查更新失败'
        if (userInitiated) {
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
      })
      .then(({ stagedAppPath, targetAppPath }) => {
        this.stopDownloadWatchdog()
        if (this._state.kind !== 'downloading' && this._state.kind !== 'preparing') return
        this.setState({
          kind: 'readyToInstall',
          release,
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
