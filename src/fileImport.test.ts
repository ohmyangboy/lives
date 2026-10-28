import { describe, expect, it, vi } from 'vitest'
import { prepareFileImport } from './fileImport'

describe('mixed file import', () => {
  it('imports ordinary videos without requesting Live pairing', async () => {
    const pair = vi.fn()
    const result = await prepareFileImport(['/a.MOV', '/b.mp4', '/c.m4v', '/a.MOV'], pair)
    expect(result.paths).toEqual(['/a.MOV', '/b.mp4', '/c.m4v'])
    expect(result.livePhotos.size).toBe(0)
    expect(pair).not.toHaveBeenCalled()
  })

  it('pairs photos against MOVs and retains all selected videos in order', async () => {
    const live = { video: { path: '/live.mov' }, livePhoto: { id: 'live' } }
    const pair = vi.fn().mockResolvedValue([live])
    const result = await prepareFileImport(['/plain.mp4', '/live.HEIC', '/plain.mov', '/live.mov'], pair)
    expect(pair).toHaveBeenCalledWith(['/live.HEIC', '/plain.mov', '/live.mov'])
    expect(result.paths).toEqual(['/plain.mp4', '/plain.mov', '/live.mov'])
    expect(result.livePhotos.get('/live.mov')).toEqual(live)
  })

  it('propagates an unmatched photo error before importing videos', async () => {
    const pair = vi.fn().mockRejectedValue(new Error('照片缺少配对 MOV'))
    await expect(prepareFileImport(['/plain.mp4', '/photo.jpg'], pair)).rejects.toThrow('照片缺少配对 MOV')
    expect(pair).toHaveBeenCalledWith(['/photo.jpg'])
  })
})
