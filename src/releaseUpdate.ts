import appPackage from '../package.json'
import { desktopAvailable, exitApplication, nativeService, type UpdateStage } from './nativeBridge'



export const releaseApiUrl = 'https://api.github.com/repos/ohmyangboy/lives/releases/latest'
export const officialReleasePage = 'https://github.com/ohmyangboy/lives/releases/latest'
export const currentAppVersion = appPackage.version

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
  const match = value.trim().match(/^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-.*)?$/i)
  if (!match) return undefined
  return [Number(match[1]), Number(match[2] ?? 0), Number(match[3] ?? 0)]
}

/** Returns a positive number only when `candidate` is newer than `current`. */
export const compareVersions = (candidate: string, current: string) => {
  const candidateParts = numericVersion(candidate)
  const currentParts = numericVersion(current)
  if (!candidateParts || !currentParts) return undefined
  for (let index = 0; index < candidateParts.length; index += 1) {
    if (candidateParts[index] !== currentParts[index]) return candidateParts[index] - currentParts[index]
  }
  return 0
}

export const fetchLatestRelease = async (fetcher: FetchLike = fetch): Promise<UpdateRelease | undefined> => {
  const response = await fetcher(releaseApiUrl, {
    headers: { Accept: 'application/vnd.github+json' },
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
  if (comparison === undefined || comparison <= 0) return undefined

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

export interface UpdaterPort {
  checkForUpdate(): Promise<UpdateRelease | undefined>
  downloadAndPrepare(
    release: UpdateRelease,
    onProgress: (stage: 'downloading' | 'verifying' | 'preparing', progress: number) => void
  ): Promise<{ stagedAppPath: string; targetAppPath?: string }>
  installAndRelaunch(stagedAppPath: string, targetAppPath?: string): Promise<void>
}

export class DefaultUpdaterPort implements UpdaterPort {
  private fetcher: FetchLike

  constructor(fetcher: FetchLike = fetch) {
    this.fetcher = fetcher
  }

  async checkForUpdate(): Promise<UpdateRelease | undefined> {
    return fetchLatestRelease(this.fetcher)
  }

  async downloadAndPrepare(
    release: UpdateRelease,
    onProgress: (stage: 'downloading' | 'verifying' | 'preparing', progress: number) => void
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
    await nativeService.installAndRelaunch(stagedAppPath, targetAppPath)
    await exitApplication()
  }
}

export type UpdateStateListener = (state: UpdateState) => void

export class UpdateCoordinator {
  private _state: UpdateState = { kind: 'idle' }
  private _lastUpToDateNoticeAt?: Date
  private listeners = new Set<UpdateStateListener>()
  private updater: UpdaterPort
  private fallbackUrl: string
  private hasStarted = false
  private now: () => Date

  constructor(
    updater: UpdaterPort = new DefaultUpdaterPort(),
    fallbackUrl: string = officialReleasePage,
    now: () => Date = () => new Date()
  ) {
    this.updater = updater
    this.fallbackUrl = fallbackUrl
    this.now = now
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
   * Cold start silent check (idempotent).
   * Silently checks in background. If update is found, immediately starts background silent download.
   */
  start(): void {
    if (this.hasStarted) return
    this.hasStarted = true
    this.initiateCheck(false)
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

    void this.updater
      .checkForUpdate()
      .then((release) => {
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
        const message = error instanceof Error ? error.message : '检查更新失败'
        if (userInitiated || this._state.kind === 'checking') {
          this.applyFailure(message)
        } else {
          // Silent check failure silently returns to idle
          this.setState({ kind: 'idle' })
        }
      })
  }

  /**
   * Begins downloading and preparing the update.
   */
  beginDownload(targetRelease?: UpdateRelease): void {
    const release = targetRelease ?? (this._state.kind === 'updateAvailable' ? this._state.release : undefined)
    if (!release) return

    this.setState({
      kind: 'downloading',
      progress: { release, fractionCompleted: undefined },
    })

    void this.updater
      .downloadAndPrepare(release, (stage, progress) => {
        if (stage === 'downloading') {
          this.setState({
            kind: 'downloading',
            progress: { release, fractionCompleted: progress },
          })
        } else if (stage === 'preparing' || stage === 'verifying') {
          this.setState({
            kind: 'preparing',
            preparation: { release, fractionCompleted: progress },
          })
        }
      })
      .then(({ stagedAppPath, targetAppPath }) => {
        this.setState({
          kind: 'readyToInstall',
          release,
          stagedAppPath,
          targetAppPath,
        })
      })
      .catch((error) => {
        const message = error instanceof Error ? error.message : '下载或准备更新失败'
        this.applyFailure(message)
      })
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
