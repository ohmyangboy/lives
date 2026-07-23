import { describe, expect, it, vi } from 'vitest'
import { checkForUpdate, compareVersions, currentAppVersion } from './releaseUpdate'

describe('release update checks', () => {
  it('compares numeric versions without lexicographic mistakes', () => {
    expect(compareVersions('v0.1.10', '0.1.2')).toBeGreaterThan(0)
    expect(compareVersions('0.1.2', '0.1.2')).toBe(0)
    expect(compareVersions('0.1.1', '0.1.2')).toBeLessThan(0)
    expect(compareVersions('preview', '0.1.2')).toBeUndefined()
  })

  it('returns a newer stable GitHub release', async () => {
    const fetcher = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ tag_name: 'v0.1.10', html_url: 'https://github.com/ohmyangboy/lives/releases/tag/v0.1.10', published_at: '2026-07-23T00:00:00Z' }),
    })

    await expect(checkForUpdate(fetcher)).resolves.toEqual({
      version: '0.1.10',
      htmlUrl: 'https://github.com/ohmyangboy/lives/releases/tag/v0.1.10',
      publishedAt: '2026-07-23T00:00:00Z',
    })
  })

  it('silently ignores the current version, prereleases, and unavailable requests', async () => {
    await expect(checkForUpdate(vi.fn().mockResolvedValue({ ok: true, json: async () => ({ tag_name: `v${currentAppVersion}`, html_url: 'https://example.test' }) }))).resolves.toBeUndefined()
    await expect(checkForUpdate(vi.fn().mockResolvedValue({ ok: true, json: async () => ({ tag_name: 'v9.0.0', html_url: 'https://example.test', prerelease: true }) }))).resolves.toBeUndefined()
    await expect(checkForUpdate(vi.fn().mockResolvedValue({ ok: false, json: async () => ({}) }))).resolves.toBeUndefined()
  })
})
