import { describe, expect, it } from 'vitest'
import type { VideoClip } from './domain'
import { sortMediaClips } from './mediaSorting'
const clip = (id: string, extra: Partial<VideoClip> = {}): VideoClip => ({ id, name: id, sourcePath: id, previewUrl: id, durationMs: 3000, width: 1920, height: 1080, codec: 'h264', startTimeMs: 0, crop: { normalizedCenterX: .5, normalizedCenterY: .5, scale: 1 }, ...extra })
const ids = (clips: VideoClip[]) => clips.map(c => c.id)
describe('media sorting', () => {
  it('puts recent imports first and preserves legacy import order as a fallback', () => {
    const clips = [clip('old-a'), clip('old-b'), clip('new-a', { importedAtMs: 100 }), clip('new-b', { importedAtMs: 200 })]
    expect(ids(sortMediaClips(clips, 'importedAt', 'desc'))).toEqual(['new-b', 'new-a', 'old-b', 'old-a'])
    expect(ids(sortMediaClips(clips, 'importedAt', 'asc'))).toEqual(['old-a', 'old-b', 'new-a', 'new-b'])
    expect(ids(clips)).toEqual(['old-a', 'old-b', 'new-a', 'new-b'])
  })
  it('sorts creation times and keeps unavailable dates last in either direction', () => {
    const clips = [clip('unknown'), clip('new', { createdAtMs: 200 }), clip('old', { createdAtMs: 100 }), clip('missing', { createdAtMs: null })]
    expect(ids(sortMediaClips(clips, 'createdAt', 'desc'))).toEqual(['new', 'old', 'missing', 'unknown'])
    expect(ids(sortMediaClips(clips, 'createdAt', 'asc'))).toEqual(['old', 'new', 'missing', 'unknown'])
  })
  it('uses natural filename ordering', () => {
    const clips = [clip('clip10.mp4'), clip('clip2.mp4'), clip('clip1.mp4')]
    expect(ids(sortMediaClips(clips, 'name', 'asc'))).toEqual(['clip1.mp4', 'clip2.mp4', 'clip10.mp4'])
    expect(ids(sortMediaClips(clips, 'name', 'desc'))).toEqual(['clip10.mp4', 'clip2.mp4', 'clip1.mp4'])
  })
  it('sorts durations while putting the latest import first for equal lengths', () => {
    const clips = [clip('long', { durationMs: 9000 }), clip('short-old', { durationMs: 1000, importedAtMs: 100 }), clip('short-new', { durationMs: 1000, importedAtMs: 200 })]
    expect(ids(sortMediaClips(clips, 'duration', 'desc'))).toEqual(['long', 'short-new', 'short-old'])
    expect(ids(sortMediaClips(clips, 'duration', 'asc'))).toEqual(['short-new', 'short-old', 'long'])
  })
})
