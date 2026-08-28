import { describe, expect, it, vi } from 'vitest'
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

  it('cold boot: silently checks and auto-downloads when update is available', async () => {
    let progressCallback: ((stage: 'downloading' | 'verifying' | 'preparing', progress: number) => void) | undefined
    let resolveDownload: ((val: { stagedAppPath: string; targetAppPath?: string }) => void) | undefined


    const mockUpdater: UpdaterPort = {
      checkForUpdate: vi.fn().mockResolvedValue(sampleRelease),
      downloadAndPrepare: vi.fn().mockImplementation((_rel, onProg) => {
        progressCallback = onProg
        return new Promise((resolve) => {
          resolveDownload = resolve
        })
      }),
      installAndRelaunch: vi.fn().mockResolvedValue(undefined),
    }

    const coordinator = new UpdateCoordinator(mockUpdater)
    const states: UpdateState[] = []
    coordinator.subscribe((s) => states.push(s))

    expect(coordinator.state).toEqual({ kind: 'idle' })

    // Cold start
    coordinator.start()
    expect(coordinator.state).toEqual({ kind: 'checkingSilently' })

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
    const mockUpdater: UpdaterPort = {
      checkForUpdate: vi.fn().mockResolvedValue(undefined),
      downloadAndPrepare: vi.fn(),
      installAndRelaunch: vi.fn(),
    }

    const coordinator = new UpdateCoordinator(mockUpdater, 'https://fallback.test', () => fixedNow)
    coordinator.start()

    await vi.waitFor(() => expect(coordinator.state.kind).toBe('upToDate'))
    expect(coordinator.state).toEqual({ kind: 'upToDate', checkedAt: fixedNow })
    // In silent check, lastUpToDateNoticeAt is not set (no intrusive toast)
    expect(coordinator.lastUpToDateNoticeAt).toBeUndefined()
  })

  it('manual check: shows up-to-date toast when already on latest version', async () => {
    const fixedNow = new Date('2026-08-28T11:00:00Z')
    const mockUpdater: UpdaterPort = {
      checkForUpdate: vi.fn().mockResolvedValue(undefined),
      downloadAndPrepare: vi.fn(),
      installAndRelaunch: vi.fn(),
    }

    const coordinator = new UpdateCoordinator(mockUpdater, 'https://fallback.test', () => fixedNow)
    coordinator.checkForUpdates(true)

    expect(coordinator.state).toEqual({ kind: 'checking' })

    await vi.waitFor(() => expect(coordinator.state.kind).toBe('upToDate'))
    expect(coordinator.state).toEqual({ kind: 'upToDate', checkedAt: fixedNow })
    expect(coordinator.lastUpToDateNoticeAt).toEqual(fixedNow)
  })

  it('handles download failure with error message, retry, and dismiss', async () => {
    const mockUpdater: UpdaterPort = {
      checkForUpdate: vi.fn().mockResolvedValue(sampleRelease),
      downloadAndPrepare: vi.fn().mockRejectedValue(new Error('Network connection timeout')),
      installAndRelaunch: vi.fn(),
    }

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
})
