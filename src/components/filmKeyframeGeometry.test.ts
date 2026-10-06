import { describe, expect, it } from 'vitest'
import { FILM_IMPORT_DURATION_MS, filmKeyframeMotion, fineKeyframeTimeFromPointer, keyframeSelectionKey, keyframeTimeFromPointer } from './filmKeyframeGeometry'

describe('film keyframe inspection', () => {
  it('maps positions to the selected output, independently of its source start', () => {
    expect(keyframeTimeFromPointer(250, 100, 300, 3000, 2900)).toBe(1500)
    expect(keyframeTimeFromPointer(250, 100, 300, 15000, 14900)).toBe(7500)
  })

  it('preserves the grab offset instead of jumping when the loupe is picked up', () => {
    expect(keyframeTimeFromPointer(270, 100, 300, 3000, 2900, 20)).toBe(1500)
  })

  it('clamps the loupe at real source content when the output includes a padded tail', () => {
    expect(keyframeTimeFromPointer(390, 100, 300, 15000, 6000)).toBe(6000)
    expect(keyframeTimeFromPointer(50, 100, 300, 15000, 6000)).toBe(0)
  })

  it('uses 100ms steps and stays below the final output frame', () => {
    expect(keyframeTimeFromPointer(257, 100, 300, 3000, 2900)).toBe(1600)
    expect(keyframeTimeFromPointer(450, 100, 300, 3000, 2900)).toBe(2900)
  })

  it('makes Shift dragging five times finer while retaining its anchor', () => {
    expect(fineKeyframeTimeFromPointer(180, 100, 1500, 300, 15000, 14900)).toBe(2300)
    expect(fineKeyframeTimeFromPointer(100, 100, 2300, 300, 15000, 14900)).toBe(2300)
  })

  it('handles collapsed geometry and nonfinite pointer positions', () => {
    expect(keyframeTimeFromPointer(200, 100, 0, 3000, 2900)).toBe(0)
    expect(keyframeTimeFromPointer(NaN, 100, 300, 3000, 2900)).toBe(0)
    expect(fineKeyframeTimeFromPointer(200, 100, 1500, 0, 3000, 2900)).toBe(1500)
  })

  it('changes reels for a slot or source change, and retains the reel during ordinary editing', () => {
    const clip = { id: 'a', targetSlotId: 'top', previewUrl: 'blob:a', coverTimeMs: 1500, startTimeMs: 1000 }
    const key = keyframeSelectionKey(clip)
    expect(keyframeSelectionKey({ ...clip, coverTimeMs: 2400, startTimeMs: 2000 } as typeof clip)).toBe(key)
    expect(keyframeSelectionKey({ ...clip, targetSlotId: 'bottom' })).not.toBe(key)
    expect(keyframeSelectionKey({ ...clip, previewUrl: 'blob:b' })).not.toBe(key)
    expect(keyframeSelectionKey()).toBe('')
  })

  it('seats both models before extending the film out of the cartridge', () => {
    const seated = filmKeyframeMotion((280 / 1.4) / FILM_IMPORT_DURATION_MS)
    expect(seated.seat).toBe(1)
    expect(seated.unroll).toBe(0)
    expect(seated.reveal).toBe(0)
    const middle = filmKeyframeMotion(.65)
    expect(middle.incomingOffset).toBeLessThan(0)
    expect(middle.incomingOffset + 1).toBeCloseTo(middle.incomingWidth)
    const complete = filmKeyframeMotion(1)
    expect(complete.unroll).toBe(1)
    expect(complete.reveal).toBe(1)
    expect(complete.incomingOffset).toBe(0)
  })

  it('keeps the objects seated while old frames slide out and new frames fill the same rail', () => {
    for (const position of [0, .1, .5, .9, 1]) {
      const motion = filmKeyframeMotion(1, position)
      expect(motion.seat).toBe(1)
      expect(motion.unroll).toBe(1)
      expect(motion.reveal).toBe(1)
      expect(motion.incomingOffset).toBe(0)
      expect(motion.incomingWidth).toBe(motion.outgoingOffset)
    }
    expect(filmKeyframeMotion(1, .5).outgoingOffset).toBe(.5)
    expect(filmKeyframeMotion(1, 1).outgoingOffset).toBe(1)
  })
})
