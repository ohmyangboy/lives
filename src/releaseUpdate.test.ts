import { describe, expect, it, vi, afterEach } from 'vitest'
import {
  compareVersions,
  currentAppVersion,
  fetchLatestRelease,
  UpdateCoordinator,
  type UpdaterPort,
  type UpdateRelease,
  type UpdateState,
} from './releaseUpdate'

describe('release update checks & version comparisons', () => {
  it('compares numeric versions accurately', () => {
    expect(compareVersions('v0.1.10', '0.1.2')).toBeGreaterThan(0)
    expect(compareVersions('0.1.2', '0.1.2')).toBe(0)
    expect(compareVersions('0.1.1', '0.1.2')).toBeLessThan(0)
    expect(compareVersions('0.2.0', '0.1.9')).toBeGreaterThan(0)
    expect(compareVersions('1.0.0', '0.9.9')).toBeGreaterThan(0)
    expect(compareVersions('preview', '0.1.2')).toBeUndefined()
  })

  it('fetches newer stable GitHub release with DMG asset and sha256', async () => {
    const mockRelease = {
      tag_name: 'v0.9.9',
      html_url: 'https://github.com/ohmyangboy/lives/releases/tag/v0.9.9',
      body: 'Bug fixes and performance improvements',
      published_at: '2026-08-28T00:00:00Z',
      assets: [
        {
          name: 'Lives_0.9.9_aarch64.dmg',
          browser_download_url: 'https://github.com/ohmyangboy/lives/releases/download/v0.9.9/Lives_0.9.9_aarch64.dmg',
          digest: 'sha256:abcd1234ef567890',
        },
      ],
    }

    const fetcher = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => mockRelease,
    })

    const release = await fetchLatestRelease(fetcher)
    expect(release).toEqual({
      version: '0.9.9',
      displayVersion: 'v0.9.9',
      releaseNotes: 'Bug fixes and performance improvements',
      dmgUrl: 'https://github.com/ohmyangboy/lives/releases/download/v0.9.9/Lives_0.9.9_aarch64.dmg',
      sha256: 'abcd1234ef567890',
      htmlUrl: 'https://github.com/ohmyangboy/lives/releases/tag/v0.9.9',
      isCritical: false,
      publishedAt: '2026-08-28T00:00:00Z',
    })
  })

  it('silently ignores current version, older versions, drafts, and missing DMG assets', async () => {
    // Current version
    await expect(
      fetchLatestRelease(
        vi.fn().mockResolvedValue({
          ok: true,
          json: async () => ({
            tag_name: `v${currentAppVersion}`,
            html_url: 'https://example.com',
            assets: [{ name: 'Lives.dmg', browser_download_url: 'https://example.com/Lives.dmg' }],
          }),
        })
      )
    ).resolves.toBeUndefined()

    // Prerelease
    await expect(
      fetchLatestRelease(
        vi.fn().mockResolvedValue({
          ok: true,
          json: async () => ({
            tag_name: 'v9.0.0',
            html_url: 'https://example.com',
            prerelease: true,
            assets: [{ name: 'Lives.dmg', browser_download_url: 'https://example.com/Lives.dmg' }],
          }),
        })
      )
    ).resolves.toBeUndefined()

    // Missing DMG
    await expect(
      fetchLatestRelease(
        vi.fn().mockResolvedValue({
          ok: true,
          json: async () => ({
            tag_name: 'v9.0.0',
            html_url: 'https://example.com',
            assets: [{ name: 'Source.zip', browser_download_url: 'https://example.com/Source.zip' }],
          }),
        })
      )
    ).resolves.toBeUndefined()

    // Fetch error
    await expect(
      fetchLatestRelease(vi.fn().mockResolvedValue({ ok: false, json: async () => ({}) }))
    ).resolves.toBeUndefined()
  })
})

describe('UpdateCoordinator state machine', () => {
  const sampleRelease: UpdateRelease = {
    version: '0.9.0',
    displayVersion: 'v0.9.0',
    releaseNotes: 'Awesome update',
    dmgUrl: 'https://example.com/Lives_0.9.0.dmg',
    sha256: 'deadbeef',
    htmlUrl: 'https://example.com/releases/v0.9.0',
  }

  const makeUpdater = (overrides: Partial<UpdaterPort> = {}): UpdaterPort => ({
    checkForUpdate: vi.fn().mockResolvedValue(undefined),
    getStagedUpdate: vi.fn().mockResolvedValue(undefined),
    downloadAndPrepare: vi.fn(),
    installAndRelaunch: vi.fn().mockResolvedValue(undefined),
    cancelActiveDownload: vi.fn().mockResolvedValue(undefined),
    ...overrides,
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('cold boot: silently checks and auto-downloads when update is available', async () => {
    let progressCallback: ((stage: 'downloading' | 'verifying' | 'preparing', progress: number) => void) | undefined
    let resolveDownload: ((val: { stagedAppPath: string; targetAppPath?: string }) => void) | undefined

    const mockUpdater = makeUpdater({
      checkForUpdate: vi.fn().mockResolvedValue(sampleRelease),
      downloadAndPrepare: vi.fn().mockImplementation((_rel, onProg) => {
        progressCallback = onProg
        return new Promise((resolve) => {
          resolveDownload = resolve
        })
      }),
    })

    const coordinator = new UpdateCoordinator(mockUpdater)
    const states: UpdateState[] = []
    coordinator.subscribe((s) => states.push(s))

    expect(coordinator.state).toEqual({ kind: 'idle' })

    // Cold start：先做暂存恢复探测（异步），随后静默检查并自动下载
    coordinator.start()
    await vi.waitFor(() => expect(mockUpdater.downloadAndPrepare).toHaveBeenCalledWith(sampleRelease, expect.any(Function)))
    expect(coordinator.state.kind).toBe('downloading')
    // 状态迁移确实经过静默检查与发现更新
    expect(states.map((s) => s.kind)).toEqual(expect.arrayContaining(['idle', 'checkingSilently', 'updateAvailable', 'downloading']))

    // Wait for checkForUpdate promise
    await vi.waitFor(() => expect(mockUpdater.checkForUpdate).toHaveBeenCalled())
    await vi.waitFor(() => expect(coordinator.state.kind).toBe('downloading'))

    expect(mockUpdater.downloadAndPrepare).toHaveBeenCalledWith(sampleRelease, expect.any(Function))

    // Stream progress
    progressCallback?.('downloading', 0.5)
    expect(coordinator.state).toEqual({
      kind: 'downloading',
      progress: { release: sampleRelease, fractionCompleted: 0.5 },
    })

    progressCallback?.('preparing', 0.8)
    expect(coordinator.state).toEqual({
      kind: 'preparing',
      preparation: { release: sampleRelease, fractionCompleted: 0.8 },
    })

    // Finish preparation -> readyToInstall
    resolveDownload?.({ stagedAppPath: '/tmp/staged/Lives.app', targetAppPath: '/Applications/Lives.app' })
    await vi.waitFor(() => expect(coordinator.state.kind).toBe('readyToInstall'))

    expect(coordinator.state).toEqual({
      kind: 'readyToInstall',
      release: sampleRelease,
      stagedAppPath: '/tmp/staged/Lives.app',
      targetAppPath: '/Applications/Lives.app',
    })

    // Click restart -> installs and relaunches
    coordinator.installAndRelaunch()
    expect(coordinator.state).toEqual({ kind: 'installing', release: sampleRelease })

    await vi.waitFor(() => expect(mockUpdater.installAndRelaunch).toHaveBeenCalledWith('/tmp/staged/Lives.app', '/Applications/Lives.app'))
    await vi.waitFor(() => expect(coordinator.state.kind).toBe('relaunching'))

  })

  it('cold boot: silently checks and remains silent when up to date', async () => {
    const fixedNow = new Date('2026-08-28T10:00:00Z')
    const mockUpdater = makeUpdater({ checkForUpdate: vi.fn().mockResolvedValue(undefined) })

    const coordinator = new UpdateCoordinator(mockUpdater, 'https://fallback.test', () => fixedNow)
    coordinator.start()

    await vi.waitFor(() => expect(coordinator.state.kind).toBe('upToDate'))
    expect(coordinator.state).toEqual({ kind: 'upToDate', checkedAt: fixedNow })
    // In silent check, lastUpToDateNoticeAt is not set (no intrusive toast)
    expect(coordinator.lastUpToDateNoticeAt).toBeUndefined()
  })

  it('manual check: shows up-to-date toast when already on latest version', async () => {
    const fixedNow = new Date('2026-08-28T11:00:00Z')
    const mockUpdater = makeUpdater({ checkForUpdate: vi.fn().mockResolvedValue(undefined) })

    const coordinator = new UpdateCoordinator(mockUpdater, 'https://fallback.test', () => fixedNow)
    coordinator.checkForUpdates(true)

    expect(coordinator.state).toEqual({ kind: 'checking' })

    await vi.waitFor(() => expect(coordinator.state.kind).toBe('upToDate'))
    expect(coordinator.state).toEqual({ kind: 'upToDate', checkedAt: fixedNow })
    expect(coordinator.lastUpToDateNoticeAt).toEqual(fixedNow)
  })

  it('handles download failure with error message, retry, and dismiss', async () => {
    const mockUpdater = makeUpdater({
      checkForUpdate: vi.fn().mockResolvedValue(sampleRelease),
      downloadAndPrepare: vi.fn().mockRejectedValue(new Error('Network connection timeout')),
    })

    const coordinator = new UpdateCoordinator(mockUpdater, 'https://github.com/ohmyangboy/lives/releases')
    coordinator.checkForUpdates(true)

    await vi.waitFor(() => expect(coordinator.state.kind).toBe('failed'))
    expect(coordinator.state).toEqual({
      kind: 'failed',
      failure: {
        message: 'Network connection timeout',
        fallbackUrl: 'https://github.com/ohmyangboy/lives/releases',
      },
    })

    // Dismiss failure returns to idle
    coordinator.dismissFailure()
    expect(coordinator.state).toEqual({ kind: 'idle' })
  })

  // ---- Watchdogs：任何状态必然收尾 ----

  it('watchdog: manual check that never resolves fails with timeout message', async () => {
    const mockUpdater = makeUpdater({
      checkForUpdate: vi.fn().mockImplementation((_signal) => new Promise(() => {})),
    })

    const coordinator = new UpdateCoordinator(mockUpdater, 'https://fallback.test', () => new Date(), { checkTimeoutMs: 20 })
    coordinator.checkForUpdates(true)

    expect(coordinator.state).toEqual({ kind: 'checking' })
    await vi.waitFor(() => expect(coordinator.state.kind).toBe('failed'))
    expect(coordinator.state).toMatchObject({
      kind: 'failed',
      failure: { message: expect.stringContaining('检查更新超时') },
    })
  })

  it('watchdog: silent check that never resolves returns to idle without UI noise', async () => {
    const mockUpdater = makeUpdater({
      checkForUpdate: vi.fn().mockImplementation((_signal) => new Promise(() => {})),
    })

    const coordinator = new UpdateCoordinator(mockUpdater, 'https://fallback.test', () => new Date(), { checkTimeoutMs: 20 })
    coordinator.start()

    await vi.waitFor(() => expect(coordinator.state.kind).toBe('idle'))
  })

  it('watchdog: download stall cancels the download and enters failed state', async () => {
    let progressCallback: ((stage: 'downloading' | 'verifying' | 'preparing', progress: number) => void) | undefined
    const mockUpdater = makeUpdater({
      checkForUpdate: vi.fn().mockResolvedValue(sampleRelease),
      downloadAndPrepare: vi.fn().mockImplementation((_rel, onProg) => {
        progressCallback = onProg
        return new Promise(() => {}) // never resolves
      }),
    })

    const coordinator = new UpdateCoordinator(mockUpdater, 'https://fallback.test', () => new Date(), {
      downloadStallTimeoutMs: 250,
      downloadWatchdogTickMs: 10,
    })
    coordinator.start()
    await vi.waitFor(() => expect(coordinator.state.kind).toBe('downloading'))

    // 一次进度后彻底停滞
    progressCallback?.('downloading', 0.1)
    await vi.waitFor(() => expect(coordinator.state.kind).toBe('failed'), { timeout: 2000 })
    expect(coordinator.state).toMatchObject({
      kind: 'failed',
      failure: { message: expect.stringContaining('下载停滞') },
    })
    expect(mockUpdater.cancelActiveDownload).toHaveBeenCalled()

    // 之后到达的下载错误（取消引起）不会覆盖 failed 态文案
    expect(coordinator.state).toMatchObject({ kind: 'failed', failure: { message: expect.stringContaining('下载停滞') } })
  })

  // ---- 中断恢复（Sparkle stage: .downloaded 语义）----

  it('cold boot: recovers a staged newer update straight to readyToInstall without re-downloading', async () => {
    const staged = {
      stagedAppPath: '/Users/x/Library/Caches/com.yangbukun.lives/Updates/staged/Lives.app',
      targetAppPath: '/Applications/Lives.app',
      version: '9.9.9',
    }
    const mockUpdater = makeUpdater({
      getStagedUpdate: vi.fn().mockResolvedValue(staged),
      checkForUpdate: vi.fn().mockResolvedValue(undefined),
      downloadAndPrepare: vi.fn(),
    })

    const coordinator = new UpdateCoordinator(mockUpdater)
    coordinator.start()

    await vi.waitFor(() => expect(coordinator.state.kind).toBe('readyToInstall'))
    expect(coordinator.state).toMatchObject({
      kind: 'readyToInstall',
      release: { version: '9.9.9', displayVersion: 'v9.9.9' },
      stagedAppPath: staged.stagedAppPath,
      targetAppPath: staged.targetAppPath,
    })
    // 不应再走检查/下载
    expect(mockUpdater.checkForUpdate).not.toHaveBeenCalled()
    expect(mockUpdater.downloadAndPrepare).not.toHaveBeenCalled()

    // 恢复态可直接一键安装
    coordinator.installAndRelaunch()
    await vi.waitFor(() => expect(mockUpdater.installAndRelaunch).toHaveBeenCalledWith(staged.stagedAppPath, staged.targetAppPath))
  })

  it('cold boot: ignores stale staged update and falls back to silent check', async () => {
    const stale = { stagedAppPath: '/x/Lives.app', targetAppPath: '/Applications/Lives.app', version: '0.0.1' }
    const mockUpdater = makeUpdater({
      getStagedUpdate: vi.fn().mockResolvedValue(stale),
      checkForUpdate: vi.fn().mockResolvedValue(undefined),
    })

    const coordinator = new UpdateCoordinator(mockUpdater, 'https://fallback.test', () => new Date('2026-08-28T10:00:00Z'))
    coordinator.start()

    await vi.waitFor(() => expect(coordinator.state.kind).toBe('upToDate'))
    expect(mockUpdater.checkForUpdate).toHaveBeenCalled()
  })

  it('cold boot: getStagedUpdate failure (old sidecar) does not block the silent check', async () => {
    const mockUpdater = makeUpdater({
      getStagedUpdate: vi.fn().mockRejectedValue(new Error('UNKNOWN_COMMAND')),
      checkForUpdate: vi.fn().mockResolvedValue(undefined),
    })

    const coordinator = new UpdateCoordinator(mockUpdater, 'https://fallback.test', () => new Date('2026-08-28T10:00:00Z'))
    coordinator.start()

    await vi.waitFor(() => expect(coordinator.state.kind).toBe('upToDate'))
  })
})
