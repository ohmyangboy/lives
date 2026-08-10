import { describe, expect, it } from 'vitest'
import {
  clampTimelineStartMs,
  scrollLeftPxForZoom,
  selectionGrabOffsetMs,
  timelineSelectionGeometry,
  timelineStartMsFromPointer,
  timelineTimestampMsFromPointer,
  timelineTrackWidthPx,
} from './timelineGeometry'

const OUTPUT_DURATION_MS = 3_000

describe('timelineTrackWidthPx', () => {
  it('fits all 24 frames into the viewport at 100% zoom', () => {
    expect(timelineTrackWidthPx({ viewportWidthPx: 960, zoom: 1 })).toBe(960)
  })

  it('only becomes wider than the viewport above 100% zoom', () => {
    expect(timelineTrackWidthPx({ viewportWidthPx: 960, zoom: 2.5 })).toBe(2_400)
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
