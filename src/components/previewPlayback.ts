import type { CollageTemplate, SlotClip } from '../domain'

export function previewPlaybackKey(clips: Array<SlotClip | undefined>, template: CollageTemplate, canvasWidth: number, canvasHeight: number, outputDurationMs: number) {
  return JSON.stringify([
    template.id, template.slots, canvasWidth, canvasHeight, outputDurationMs,
    clips.map((clip) => clip ? [clip.id, clip.previewUrl, clip.targetSlotId, clip.startTimeMs, clip.coverTimeMs,
      clip.crop.normalizedCenterX, clip.crop.normalizedCenterY, clip.crop.scale, Boolean(clip.audioEnabled)] : null),
  ])
}

// Coalesce parameter edits; a held gesture never starts playback mid-scrub.
export class PreviewReplayScheduler {
  private key: string | undefined
  private pending = false
  private timer: ReturnType<typeof setTimeout> | undefined

  constructor(private readonly replay: () => void, private readonly delayMs = 180) {}

  update(key: string, editing: boolean, ready: boolean) {
    if (this.key !== key) {
      this.pending = this.key !== undefined
      this.key = key
    }
    this.clearTimer()
    if (!this.pending || editing || !ready) return
    this.timer = setTimeout(() => {
      this.timer = undefined
      this.pending = false
      this.replay()
    }, this.delayMs)
  }

  cancel() {
    this.pending = false
    this.clearTimer()
  }

  clearTimer() {
    if (this.timer !== undefined) clearTimeout(this.timer)
    this.timer = undefined
  }
}

// A short tap still selects; a stationary 100ms press previews until released.
export class PreviewHoldGesture {
  private origin: { x: number; y: number } | undefined
  private timer: ReturnType<typeof setTimeout> | undefined
  private active = false

  constructor(private readonly start: () => void, private readonly stop: () => void) {}

  get isActive() { return this.active }

  begin(x: number, y: number) {
    this.cancel()
    this.origin = { x, y }
    this.timer = setTimeout(() => {
      this.timer = undefined
      this.active = true
      this.start()
    }, 100)
  }

  move(x: number, y: number) {
    if (this.origin && Math.hypot(x - this.origin.x, y - this.origin.y) > 12) this.cancel()
  }

  release() {
    const tap = Boolean(this.origin && !this.active)
    this.cancel()
    return tap
  }

  cancel() {
    const wasActive = this.active
    this.clear()
    if (wasActive) this.stop()
  }

  clear() {
    if (this.timer !== undefined) clearTimeout(this.timer)
    this.timer = undefined
    this.origin = undefined
    this.active = false
  }
}
