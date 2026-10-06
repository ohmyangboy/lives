import { afterEach, describe, expect, it, vi } from 'vitest'
import { templates, type SlotClip } from '../domain'
import { previewPlaybackKey, PreviewHoldGesture, PreviewReplayScheduler } from './previewPlayback'

const clip: SlotClip = { id: 'test', sourceClipId: 'source', sourcePath: '/tmp/preview.mp4', previewUrl: 'blob:preview', name: 'preview.mp4',
  durationMs: 6_600, width: 240, height: 320, codec: 'avc1', targetSlotId: 'main', startTimeMs: 0, coverTimeMs: 1_500,
  crop: { normalizedCenterX: .5, normalizedCenterY: .5, scale: 1 }, audioEnabled: false }
const key = (clips = [clip], width = 1080, durationMs = 3_000) => previewPlaybackKey(clips, templates[0], width, 1920, durationMs)

afterEach(() => vi.useRealTimers())

describe('preview replay', () => {
  it('waits for the final pointer commit before replaying the latest edit once', () => {
    vi.useFakeTimers()
    const replay = vi.fn()
    const scheduler = new PreviewReplayScheduler(replay)
    scheduler.update('original', false, true)
    scheduler.update('drag-1', true, true)
    vi.advanceTimersByTime(500)
    scheduler.update('drag-2', true, true)
    vi.advanceTimersByTime(500)
    expect(replay).not.toHaveBeenCalled()
    scheduler.update('final', false, true)
    vi.advanceTimersByTime(180)
    expect(replay).toHaveBeenCalledTimes(1)
    scheduler.update('final', false, true)
    vi.advanceTimersByTime(1000)
    expect(replay).toHaveBeenCalledTimes(1)
  })

  it('coalesces successive parameter changes and waits for all media to load', () => {
    vi.useFakeTimers()
    const replay = vi.fn()
    const scheduler = new PreviewReplayScheduler(replay)
    scheduler.update('original', false, true)
    scheduler.update('ratio', false, true)
    vi.advanceTimersByTime(100)
    scheduler.update('new-video', false, false)
    vi.advanceTimersByTime(500)
    expect(replay).not.toHaveBeenCalled()
    scheduler.update('new-video', false, true)
    vi.advanceTimersByTime(180)
    expect(replay).toHaveBeenCalledTimes(1)
  })

  it('respects a manual pause and cancels a pending replay on disposal', () => {
    vi.useFakeTimers()
    const replay = vi.fn()
    const scheduler = new PreviewReplayScheduler(replay)
    scheduler.update('original', false, true)
    scheduler.update('edited', false, true)
    scheduler.cancel()
    scheduler.update('edited', false, true)
    vi.advanceTimersByTime(500)
    expect(replay).not.toHaveBeenCalled()
    scheduler.update('next-edit', false, true)
    scheduler.clearTimer()
    vi.advanceTimersByTime(500)
    expect(replay).not.toHaveBeenCalled()
  })

  it('does not replay for a click without a parameter change', () => {
    vi.useFakeTimers()
    const replay = vi.fn()
    const scheduler = new PreviewReplayScheduler(replay)
    scheduler.update('original', false, true)
    scheduler.update('original', true, true)
    scheduler.update('original', false, true)
    vi.advanceTimersByTime(500)
    expect(replay).not.toHaveBeenCalled()
  })

  it('tracks duration, keyframe, crop, scale, sound, layout and ratio parameters', () => {
    const initial = key()
    const changes: Partial<SlotClip>[] = [
      { startTimeMs: 300 }, { coverTimeMs: 2000 }, { audioEnabled: true },
      { crop: { ...clip.crop, normalizedCenterX: .3 } }, { crop: { ...clip.crop, scale: 1.5 } },
    ]
    changes.forEach((change) => expect(key([{ ...clip, ...change }])).not.toBe(initial))
    expect(key([clip], 1440)).not.toBe(initial)
    expect(key([clip], 1080, 3_900)).not.toBe(initial)
    expect(previewPlaybackKey([clip], templates[1], 1080, 1920, 3_000)).not.toBe(initial)
    expect(key([{ ...clip, crop: { ...clip.crop } }])).toBe(initial)
  })
})

describe('blank-area preview hold', () => {
  it('preserves a short tap without playing', () => {
    vi.useFakeTimers()
    const start = vi.fn(), stop = vi.fn()
    const gesture = new PreviewHoldGesture(start, stop)
    gesture.begin(100, 200)
    vi.advanceTimersByTime(99)
    expect(gesture.release()).toBe(true)
    vi.advanceTimersByTime(1000)
    expect(start).not.toHaveBeenCalled()
    expect(stop).not.toHaveBeenCalled()
  })

  it('plays for the entire hold and stops exactly once on release', () => {
    vi.useFakeTimers()
    const start = vi.fn(), stop = vi.fn()
    const gesture = new PreviewHoldGesture(start, stop)
    gesture.begin(100, 200)
    vi.advanceTimersByTime(100)
    expect(start).toHaveBeenCalledTimes(1)
    vi.advanceTimersByTime(15000)
    expect(gesture.isActive).toBe(true)
    expect(stop).not.toHaveBeenCalled()
    expect(gesture.release()).toBe(false)
    gesture.cancel()
    expect(gesture.isActive).toBe(false)
    expect(stop).toHaveBeenCalledTimes(1)
  })

  it('cancels displaced presses without treating them as taps', () => {
    vi.useFakeTimers()
    const start = vi.fn(), stop = vi.fn()
    const gesture = new PreviewHoldGesture(start, stop)
    gesture.begin(100, 200)
    gesture.move(112, 200)
    vi.advanceTimersByTime(100)
    expect(start).toHaveBeenCalledTimes(1)
    gesture.move(113, 200)
    expect(stop).toHaveBeenCalledTimes(1)
    expect(gesture.release()).toBe(false)
    gesture.begin(100, 200)
    gesture.move(113, 200)
    vi.advanceTimersByTime(1000)
    expect(start).toHaveBeenCalledTimes(1)
    expect(gesture.release()).toBe(false)
  })

  it('cancels pending presses on blur and disposal without a late replay', () => {
    vi.useFakeTimers()
    const start = vi.fn(), stop = vi.fn()
    const gesture = new PreviewHoldGesture(start, stop)
    gesture.begin(100, 200)
    gesture.cancel()
    vi.advanceTimersByTime(500)
    expect(start).not.toHaveBeenCalled()
    gesture.begin(100, 200)
    gesture.clear()
    vi.advanceTimersByTime(500)
    expect(start).not.toHaveBeenCalled()
  })
})
