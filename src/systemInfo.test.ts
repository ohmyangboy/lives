import { afterEach, describe, expect, it, vi } from 'vitest'
import { desktopAvailable, nativeService } from './nativeBridge'
import { copySystemDiagnosticText, loadSystemDiagnosticText } from './systemInfo'

vi.mock('./nativeBridge', () => ({
  desktopAvailable: vi.fn(() => true),
  nativeService: { systemDiagnostics: vi.fn(), copyDiagnosticText: vi.fn() },
}))

const nativeInfo = {
  osVersion: '26.6.2', osBuild: '25G83', processorCount: 8,
  locale: 'zh_CN', chipName: 'Apple M1',
}

afterEach(() => {
  vi.useRealTimers()
  vi.clearAllMocks()
})

describe('feedback diagnostics', () => {
  it('includes the persisted Photos failure in the feedback text', async () => {
    vi.mocked(nativeService.systemDiagnostics).mockResolvedValue({
      ...nativeInfo,
      photoDiagnostics: 'save/failed add=authorized read=authorized errors=PHPhotosErrorDomain:3302',
    })
    const text = await loadSystemDiagnosticText()
    expect(text).toContain('macOS 26.6.2 (25G83)')
    expect(text).toContain('最近照片保存诊断（不含素材内容、文件名或路径）')
    expect(text).toContain('PHPhotosErrorDomain:3302')
    expect(text).toContain('add=authorized read=authorized')
  })

  it('supports older helpers without Photos diagnostics', async () => {
    vi.mocked(nativeService.systemDiagnostics).mockResolvedValue(nativeInfo)
    expect(await loadSystemDiagnosticText()).not.toContain('最近照片保存诊断')
  })

  it('copies the same device and Photos diagnostics through the native clipboard', async () => {
    vi.mocked(nativeService.systemDiagnostics).mockResolvedValue({ ...nativeInfo, photoDiagnostics: 'save/failed errors=PHPhotosErrorDomain:3302' })
    vi.mocked(nativeService.copyDiagnosticText).mockResolvedValue(undefined)
    await copySystemDiagnosticText()
    expect(nativeService.copyDiagnosticText).toHaveBeenCalledWith(expect.stringContaining('macOS 26.6.2 (25G83)'))
    expect(nativeService.copyDiagnosticText).toHaveBeenCalledWith(expect.stringContaining('PHPhotosErrorDomain:3302'))
  })

  it('reports clipboard failure instead of claiming the log was copied', async () => {
    vi.mocked(nativeService.systemDiagnostics).mockResolvedValue(nativeInfo)
    vi.mocked(nativeService.copyDiagnosticText).mockRejectedValueOnce(new Error('clipboard unavailable'))
    await expect(copySystemDiagnosticText()).rejects.toThrow('clipboard unavailable')
  })

  it('still opens usable feedback when the native service fails or stalls', async () => {
    vi.useFakeTimers()
    vi.mocked(nativeService.systemDiagnostics).mockRejectedValueOnce(new Error('service unavailable'))
    expect(await loadSystemDiagnosticText()).toContain('Lives v')
    vi.mocked(nativeService.systemDiagnostics).mockReturnValueOnce(new Promise(() => {}))
    const pending = loadSystemDiagnosticText()
    await vi.advanceTimersByTimeAsync(3000)
    expect(await pending).toContain('Lives v')
  })

  it('does not start a native service in browser preview', async () => {
    vi.mocked(desktopAvailable).mockReturnValueOnce(false)
    await loadSystemDiagnosticText()
    expect(nativeService.systemDiagnostics).not.toHaveBeenCalled()
  })
})
