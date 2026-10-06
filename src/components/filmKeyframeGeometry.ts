export const normalizeKeyframeTime = (value: number, maximumMs: number) =>
  Math.max(0, Math.min(maximumMs, Math.round((Number.isFinite(value) ? value : 0) / 100) * 100))

export const keyframeTimeFromPointer = (clientX: number, left: number, width: number, outputDurationMs: number, maximumMs: number, grabOffset = 0) =>
  normalizeKeyframeTime(width > 0 ? (clientX - grabOffset - left) / width * outputDurationMs : 0, maximumMs)

export const fineKeyframeTimeFromPointer = (clientX: number, anchorX: number, anchorTimeMs: number, width: number, outputDurationMs: number, maximumMs: number) =>
  normalizeKeyframeTime(anchorTimeMs + (width > 0 ? (clientX - anchorX) / width * outputDurationMs * .2 : 0), maximumMs)

export const keyframeSelectionKey = (clip?: { id: string; targetSlotId: string; previewUrl: string }) =>
  clip ? `${clip.targetSlotId}:${clip.id}:${clip.previewUrl}` : ''

export const FILM_IMPORT_DURATION_MS = 960 / 1.4
export const FILM_SWAP_DURATION_MS = 420
const smooth = (value: number) => {
  const clamped = Math.max(0, Math.min(1, value))
  return clamped * clamped * (3 - 2 * clamped)
}

// Seating, unrolling and revealing the lens have separate, overlapping clocks.
export function filmKeyframeMotion(progress: number, swapProgress = 1) {
  const elapsed = progress * FILM_IMPORT_DURATION_MS
  const seat = smooth(elapsed / (280 / 1.4))
  const unroll = smooth((elapsed - 280 / 1.4) / (660 / 1.4))
  const reveal = smooth((elapsed - 420 / 1.4) / (480 / 1.4))
  const swap = smooth(swapProgress)
  return { seat, unroll, reveal, swap, incomingOffset: unroll - 1, incomingWidth: unroll * swap, outgoingOffset: swap }
}
