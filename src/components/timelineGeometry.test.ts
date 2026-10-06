import { describe, expect, it } from 'vitest'
import {
  clampTimelineStartMs,
  resizeTimelineSelection,
  scrollLeftPxForZoom,
  selectionGrabOffsetMs,
  timelineSelectionGeometry,
  timelineStartMsFromPointer,
  timelineTimestampMsFromPointer,
  timelineTrackWidthPx,
  timelineDurationNotice,
  timelineSourceScale,
  timelineDragScrollSpeed,
} from './timelineGeometry'

const OUTPUT_DURATION_MS = 3_000

describe('duration handles', () => {
  it('keeps the right endpoint fixed when resizing from the left', () => {
    const next = resizeTimelineSelection({ edge: 'leading', timestampMs: 3_000, startTimeMs: 2_000, selectionDurationMs: 3_000, sourceDurationMs: 8_000 })
    expect(next.startTimeMs).toBe(3_000)
    expect(next.selectionDurationMs).toBe(2_000)
    expect(next.startTimeMs + next.selectionDurationMs).toBe(5_000)
  })

  it('keeps the left endpoint fixed and caps output at 15 seconds', () => {
    const next = resizeTimelineSelection({ edge: 'trailing', timestampMs: 20_000, startTimeMs: 2_000, selectionDurationMs: 3_000, sourceDurationMs: 8_000 })
    expect(next.startTimeMs).toBe(2_000)
    expect(next.selectionDurationMs).toBe(15_000)
    expect(next.requestedDurationMs).toBe(18_000)
  })

  it('caps both handles at a one-second minimum', () => {
    for (const edge of ['leading', 'trailing'] as const) {
      const next = resizeTimelineSelection({ edge, timestampMs: edge === 'leading' ? 5_500 : 500, startTimeMs: 2_000, selectionDurationMs: 3_000, sourceDurationMs: 8_000 })
      expect(next.selectionDurationMs).toBe(1_000)
      expect(edge === 'leading' ? next.startTimeMs + next.selectionDurationMs : next.startTimeMs).toBe(edge === 'leading' ? 5_000 : 2_000)
    }
  })

  it('preserves a legacy fractional endpoint while quantizing duration', () => {
    const next = resizeTimelineSelection({ edge: 'leading', timestampMs: 1_540, startTimeMs: 1_234, selectionDurationMs: 3_000, sourceDurationMs: 8_000 })
    expect(next.selectionDurationMs).toBe(2_700)
    expect(next.startTimeMs + next.selectionDurationMs).toBe(4_234)
  })

  it('retains source content when the fixed right endpoint is in the padding lane', () => {
    const next = resizeTimelineSelection({ edge: 'leading', timestampMs: 15_000, startTimeMs: 1_300, selectionDurationMs: 15_000, sourceDurationMs: 6_600 })
    expect(next.startTimeMs).toBe(5_600)
    expect(next.selectionDurationMs).toBe(10_700)
    expect(next.startTimeMs + next.selectionDurationMs).toBe(16_300)
  })

  it('ignores non-finite pointer values', () => {
    const next = resizeTimelineSelection({ edge: 'trailing', timestampMs: Number.NaN, startTimeMs: 2_000, selectionDurationMs: 3_000, sourceDurationMs: 8_000 })
    expect(next.startTimeMs).toBe(2_000)
    expect(next.selectionDurationMs).toBe(3_000)
  })

  it('keeps a padded fifteen-second selection movable on a short source', () => {
    const timestamp = timelineTimestampMsFromPointer({ clientX: 350, viewportLeftPx: 100, viewportWidthPx: 1_000,
      scrollLeftPx: 0, zoom: 1, durationMs: 20_600, selectionDurationMs: 15_000 })
    expect(clampTimelineStartMs(timestamp, 6_600, 1_000)).toBe(5_200)
    const selection = timelineSelectionGeometry({ trackWidthPx: 1_000, durationMs: 20_600,
      startTimeMs: 5_200, selectionDurationMs: 15_000 })
    expect(selection.leftPx + selection.widthPx).toBeLessThanOrEqual(1_000)
  })
})

describe('duration landmark feedback', () => {
  it('reports skipped landmarks and suppresses repeated crossings in a gesture', () => {
    const reported = new Set<number>()
    expect(timelineDurationNotice(3_700, 4_100, 4_100, reported)).toBe('Live 时长 3.9 秒')
    expect(timelineDurationNotice(4_100, 3_800, 3_800, reported)).toBeUndefined()
    expect(timelineDurationNotice(3_800, 3_900, 3_900, reported)).toBeUndefined()
    expect(timelineDurationNotice(3_200, 2_900, 2_900, reported)).toBe('Live 时长 3 秒 · 默认')
  })

  it('reports a bound once, even if the pointer keeps moving beyond it', () => {
    const reported = new Set<number>()
    expect(timelineDurationNotice(14_900, 15_000, 16_000, reported)).toBe('Live 时长最长 15 秒')
    expect(timelineDurationNotice(15_000, 15_000, 20_000, reported)).toBeUndefined()
    expect(timelineDurationNotice(1_100, 1_000, 500, reported)).toBe('Live 时长最短 1 秒')
  })
})

describe('timelineTrackWidthPx', () => {
  it('fits all 24 frames into the viewport at 100% zoom', () => {
    expect(timelineTrackWidthPx({ viewportWidthPx: 960, zoom: 1 })).toBe(960)
  })

  it('only becomes wider than the viewport above 100% zoom', () => {
    expect(timelineTrackWidthPx({ viewportWidthPx: 960, zoom: 2.5 })).toBe(2_400)
  })
})

describe('source fit with duration extension', () => {
  it('fills the viewport with a short source at the default zoom', () => {
    const zoom = timelineSourceScale(6_600, 6_600, 1)
    const trackWidthPx = timelineTrackWidthPx({ viewportWidthPx: 660, zoom })
    expect(trackWidthPx).toBe(660)
    expect(timelineTimestampMsFromPointer({ clientX: 430, viewportLeftPx: 100, viewportWidthPx: 660,
      scrollLeftPx: 0, zoom, durationMs: 6_600, selectionDurationMs: 3_000 })).toBe(3_300)
    expect(timelineSelectionGeometry({ trackWidthPx, durationMs: 6_600, startTimeMs: 0, selectionDurationMs: 3_000 }).widthPx).toBe(300)
  })

  it('extends the padding lane without changing the source or pointer scale', () => {
    const zoom = timelineSourceScale(6_600, 20_600, 1)
    const trackWidthPx = timelineTrackWidthPx({ viewportWidthPx: 660, zoom })
    expect(trackWidthPx * 6_600 / 20_600).toBeCloseTo(660)
    expect(timelineTimestampMsFromPointer({ clientX: 430, viewportLeftPx: 100, viewportWidthPx: 660,
      scrollLeftPx: 0, zoom, durationMs: 20_600, selectionDurationMs: 3_000 })).toBeCloseTo(3_300)
    const end = timelineTimestampMsFromPointer({ clientX: 700, viewportLeftPx: 100, viewportWidthPx: 660,
      scrollLeftPx: 900, zoom, durationMs: 20_600, selectionDurationMs: 3_000 })
    expect(resizeTimelineSelection({ edge: 'trailing', timestampMs: end, startTimeMs: 0, selectionDurationMs: 3_000, sourceDurationMs: 6_600 }).selectionDurationMs).toBe(15_000)
  })

  it('keeps the scrolled padding timestamp anchored when zooming', () => {
    const previousZoom = timelineSourceScale(6_600, 15_000, 1)
    const nextZoom = timelineSourceScale(6_600, 15_000, 2)
    const scrollLeftPx = scrollLeftPxForZoom({ scrollLeftPx: 500, viewportWidthPx: 660, previousZoom, nextZoom })
    const pointer = { clientX: 430, viewportLeftPx: 100, viewportWidthPx: 660, durationMs: 15_000, selectionDurationMs: 15_000 }
    expect(timelineTimestampMsFromPointer({ ...pointer, scrollLeftPx, zoom: nextZoom })).toBeCloseTo(
      timelineTimestampMsFromPointer({ ...pointer, scrollLeftPx: 500, zoom: previousZoom }))
  })

  it('only scrolls while dragging near a viewport edge', () => {
    expect(timelineDragScrollSpeed(430, 100, 660)).toBe(0)
    expect(timelineDragScrollSpeed(116, 100, 660)).toBe(-250)
    expect(timelineDragScrollSpeed(744, 100, 660)).toBe(250)
    expect(timelineDragScrollSpeed(800, 100, 660)).toBe(500)
  })
})

describe('timeline pointer mapping', () => {
  it('maps an 8.5 second timeline against the complete media duration', () => {
    expect(timelineTimestampMsFromPointer({
      clientX: 525,
      viewportLeftPx: 100,
      viewportWidthPx: 850,
      scrollLeftPx: 0,
      zoom: 1,
      durationMs: 8_500,
      selectionDurationMs: OUTPUT_DURATION_MS,
    })).toBe(4_250)
  })

  it('selects a clicked timestamp using the 100ms step', () => {
    expect(timelineStartMsFromPointer({
      clientX: 525,
      viewportLeftPx: 100,
      viewportWidthPx: 850,
      scrollLeftPx: 0,
      zoom: 1,
      durationMs: 8_500,
      selectionDurationMs: OUTPUT_DURATION_MS,
    })).toBe(4_300)
  })

  it('includes horizontal scroll when mapping a zoomed 96 second timeline', () => {
    expect(timelineTimestampMsFromPointer({
      clientX: 600,
      viewportLeftPx: 100,
      viewportWidthPx: 1_000,
      scrollLeftPx: 500,
      zoom: 2,
      durationMs: 96_000,
      selectionDurationMs: OUTPUT_DURATION_MS,
    })).toBe(48_000)
  })

  it('clamps a click at the far right to the latest valid 3 second start', () => {
    expect(timelineStartMsFromPointer({
      clientX: 1_100,
      viewportLeftPx: 100,
      viewportWidthPx: 1_000,
      scrollLeftPx: 0,
      zoom: 1,
      durationMs: 8_500,
      selectionDurationMs: OUTPUT_DURATION_MS,
    })).toBe(5_500)
  })

  it('rounds clicks to 100ms and clamps direct keyboard values to the same domain', () => {
    expect(clampTimelineStartMs(4_249, 8_500, OUTPUT_DURATION_MS)).toBe(4_200)
    expect(clampTimelineStartMs(8_500, 8_500, OUTPUT_DURATION_MS)).toBe(5_500)
  })

  it('preserves the grabbed point inside the selection while dragging', () => {
    const grabOffsetMs = selectionGrabOffsetMs(2_600, 2_000, OUTPUT_DURATION_MS)
    expect(grabOffsetMs).toBe(600)
    expect(timelineStartMsFromPointer({
      clientX: 560,
      viewportLeftPx: 100,
      viewportWidthPx: 850,
      scrollLeftPx: 0,
      zoom: 1,
      durationMs: 8_500,
      selectionDurationMs: OUTPUT_DURATION_MS,
      grabOffsetMs,
    })).toBe(4_000)
  })
})

describe('timelineSelectionGeometry', () => {
  it('keeps a 3 second selection proportional on a 96 second clip', () => {
    const geometry = timelineSelectionGeometry({
      trackWidthPx: 960,
      durationMs: 96_000,
      startTimeMs: 93_000,
      selectionDurationMs: OUTPUT_DURATION_MS,
    })
    expect(geometry.widthPx).toBe(30)
    expect(geometry.leftPx + geometry.widthPx).toBe(960)
  })

  it('does not inflate or overflow the selection on an hour-long clip', () => {
    const geometry = timelineSelectionGeometry({
      trackWidthPx: 1_200,
      durationMs: 3_600_000,
      startTimeMs: 3_597_000,
      selectionDurationMs: OUTPUT_DURATION_MS,
    })
    expect(geometry.widthPx).toBe(1)
    expect(geometry.leftPx + geometry.widthPx).toBeCloseTo(1_200)
  })
})

describe('scrollLeftPxForZoom', () => {
  it('keeps the visible center stable while zooming and returns to zero at fit zoom', () => {
    expect(scrollLeftPxForZoom({
      scrollLeftPx: 0,
      viewportWidthPx: 1_000,
      previousZoom: 1,
      nextZoom: 2,
    })).toBe(500)
    expect(scrollLeftPxForZoom({
      scrollLeftPx: 500,
      viewportWidthPx: 1_000,
      previousZoom: 2,
      nextZoom: 1,
    })).toBe(0)
  })
})
