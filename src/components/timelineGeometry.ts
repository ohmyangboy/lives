import { MAXIMUM_OUTPUT_DURATION_MS, MINIMUM_OUTPUT_DURATION_MS, normalizeOutputDurationMs } from '../domain'

export const TIMELINE_STEP_MS = 100

const clamp = (value: number, minimum: number, maximum: number) => Math.min(maximum, Math.max(minimum, value))

export interface TimelineTrackWidthOptions {
  viewportWidthPx: number
  zoom: number
}

export function timelineTrackWidthPx({
  viewportWidthPx,
  zoom,
}: TimelineTrackWidthOptions) {
  return Math.max(0, viewportWidthPx) * Math.max(1, zoom)
}

// Fit the source to the viewport, then extend the track without compressing it.
export function timelineSourceScale(sourceDurationMs: number, timelineDurationMs: number, zoom: number) {
  return Math.max(1, zoom) * Math.max(1, timelineDurationMs / Math.max(1, sourceDurationMs))
}

export function timelineDragScrollSpeed(clientX: number, viewportLeftPx: number, viewportWidthPx: number) {
  const margin = Math.min(32, viewportWidthPx / 4)
  if (margin <= 0) return 0
  const x = clientX - viewportLeftPx
  if (x < margin) return -500 * Math.min(1, (margin - x) / margin)
  if (x > viewportWidthPx - margin) return 500 * Math.min(1, (x - viewportWidthPx + margin) / margin)
  return 0
}

export interface TimelinePointerOptions {
  clientX: number
  viewportLeftPx: number
  viewportWidthPx: number
  scrollLeftPx: number
  zoom: number
  durationMs: number
  selectionDurationMs: number
}

export function timelineTimestampMsFromPointer({
  clientX,
  viewportLeftPx,
  viewportWidthPx,
  scrollLeftPx,
  zoom,
  durationMs,
}: TimelinePointerOptions) {
  const trackWidthPx = Math.max(0, viewportWidthPx * zoom)
  if (!trackWidthPx || durationMs <= 0) return 0
  const pointerOffsetPx = clamp(clientX - viewportLeftPx + scrollLeftPx, 0, trackWidthPx)
  return (pointerOffsetPx / trackWidthPx) * durationMs
}

export function clampTimelineStartMs(
  valueMs: number,
  durationMs: number,
  selectionDurationMs: number,
  stepMs = TIMELINE_STEP_MS,
) {
  const maxStartMs = Math.max(0, durationMs - selectionDurationMs)
  const snappedMs = stepMs > 0 ? Math.round(valueMs / stepMs) * stepMs : valueMs
  return clamp(snappedMs, 0, maxStartMs)
}

export function timelineStartMsFromPointer(
  options: TimelinePointerOptions & { grabOffsetMs?: number; stepMs?: number },
) {
  const timestampMs = timelineTimestampMsFromPointer(options)
  return clampTimelineStartMs(
    timestampMs - (options.grabOffsetMs ?? 0),
    options.durationMs,
    options.selectionDurationMs,
    options.stepMs,
  )
}

export function selectionGrabOffsetMs(
  pointerTimestampMs: number,
  selectionStartMs: number,
  selectionDurationMs: number,
) {
  return clamp(pointerTimestampMs - selectionStartMs, 0, selectionDurationMs)
}

export type TimelineDragMode = 'move' | 'leading' | 'trailing'

export function resizeTimelineSelection({
  edge,
  timestampMs,
  startTimeMs,
  selectionDurationMs,
  sourceDurationMs,
}: {
  edge: 'leading' | 'trailing'
  timestampMs: number
  startTimeMs: number
  selectionDurationMs: number
  sourceDurationMs: number
}) {
  const endTimeMs = startTimeMs + selectionDurationMs
  const requestedDurationMs = edge === 'leading' ? endTimeMs - timestampMs : timestampMs - startTimeMs
  if (!Number.isFinite(timestampMs)) return { startTimeMs, selectionDurationMs, requestedDurationMs }
  if (edge === 'trailing') {
    return { startTimeMs, selectionDurationMs: normalizeOutputDurationMs(requestedDurationMs), requestedDurationMs }
  }
  const maximumStartMs = Math.max(0, sourceDurationMs - MINIMUM_OUTPUT_DURATION_MS)
  const minimumDurationMs = Math.max(MINIMUM_OUTPUT_DURATION_MS, Math.ceil((endTimeMs - maximumStartMs) / TIMELINE_STEP_MS) * TIMELINE_STEP_MS)
  const maximumDurationMs = Math.min(MAXIMUM_OUTPUT_DURATION_MS, Math.floor(endTimeMs / TIMELINE_STEP_MS) * TIMELINE_STEP_MS)
  if (minimumDurationMs > maximumDurationMs) return { startTimeMs, selectionDurationMs, requestedDurationMs }
  const durationMs = clamp(normalizeOutputDurationMs(requestedDurationMs), minimumDurationMs, maximumDurationMs)
  return { startTimeMs: endTimeMs - durationMs, selectionDurationMs: durationMs, requestedDurationMs }
}

export function timelineDurationNotice(
  previousDurationMs: number,
  durationMs: number,
  requestedDurationMs: number,
  reported: Set<number>,
) {
  const landmarks = [MINIMUM_OUTPUT_DURATION_MS, 3_000, 3_900, MAXIMUM_OUTPUT_DURATION_MS]
  const crossed = landmarks.filter((value) => (previousDurationMs < value && durationMs >= value)
    || (previousDurationMs > value && durationMs <= value))
  const landmark = requestedDurationMs <= MINIMUM_OUTPUT_DURATION_MS ? MINIMUM_OUTPUT_DURATION_MS
    : requestedDurationMs >= MAXIMUM_OUTPUT_DURATION_MS ? MAXIMUM_OUTPUT_DURATION_MS
      : durationMs >= previousDurationMs ? crossed.at(-1) : crossed[0]
  if (landmark === undefined || reported.has(landmark)) return undefined
  reported.add(landmark)
  if (landmark === MINIMUM_OUTPUT_DURATION_MS) return 'Live 时长最短 1 秒'
  if (landmark === MAXIMUM_OUTPUT_DURATION_MS) return 'Live 时长最长 15 秒'
  return landmark === 3_000 ? 'Live 时长 3 秒 · 默认' : 'Live 时长 3.9 秒'
}

export interface TimelineSelectionGeometryOptions {
  trackWidthPx: number
  durationMs: number
  startTimeMs: number
  selectionDurationMs: number
}

export function timelineSelectionGeometry({
  trackWidthPx,
  durationMs,
  startTimeMs,
  selectionDurationMs,
}: TimelineSelectionGeometryOptions) {
  if (trackWidthPx <= 0 || durationMs <= 0) {
    return { leftPx: 0, widthPx: 0, leftPercent: 0, widthPercent: 100 }
  }
  const visibleSelectionDurationMs = clamp(selectionDurationMs, 0, durationMs)
  const visibleStartTimeMs = clamp(startTimeMs, 0, durationMs - visibleSelectionDurationMs)
  const leftPercent = (visibleStartTimeMs / durationMs) * 100
  const widthPercent = (visibleSelectionDurationMs / durationMs) * 100
  const leftPx = trackWidthPx * (leftPercent / 100)
  const widthPx = trackWidthPx * (widthPercent / 100)
  return { leftPx, widthPx, leftPercent, widthPercent }
}

export interface ZoomScrollOptions {
  scrollLeftPx: number
  viewportWidthPx: number
  previousZoom: number
  nextZoom: number
  anchorOffsetPx?: number
}

export function scrollLeftPxForZoom({
  scrollLeftPx,
  viewportWidthPx,
  previousZoom,
  nextZoom,
  anchorOffsetPx = viewportWidthPx / 2,
}: ZoomScrollOptions) {
  if (viewportWidthPx <= 0 || previousZoom <= 0 || nextZoom <= 0) return 0
  const previousTrackWidthPx = viewportWidthPx * previousZoom
  const nextTrackWidthPx = viewportWidthPx * nextZoom
  const anchorRatio = (scrollLeftPx + anchorOffsetPx) / previousTrackWidthPx
  const desiredScrollLeftPx = anchorRatio * nextTrackWidthPx - anchorOffsetPx
  return clamp(desiredScrollLeftPx, 0, Math.max(0, nextTrackWidthPx - viewportWidthPx))
}
