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
