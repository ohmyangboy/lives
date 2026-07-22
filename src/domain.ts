export type TemplateId = 'single' | 'stack-2' | 'side-2' | 'stack-3' | 'side-3' | 'hero-left' | 'hero-top' | 'weighted-3'
export type AspectRatioId = '9:16' | '3:4' | '1:1' | '4:3' | '16:9'
export type ExportQuality = '1080p' | '720p'

export interface CanvasSettings {
  aspectRatio: AspectRatioId
  quality: ExportQuality
}

export interface SourceQualityAnalysis {
  recommendedQuality: ExportQuality
  supports1080p: boolean
  minimumShortEdge: number
  effectiveShortEdge: number
  limitingSourceName?: string
  sourceLabel: string
}

export const aspectRatioOptions: Array<{ id: AspectRatioId; label: string; width: number; height: number }> = [
  { id: '9:16', label: '9:16', width: 9, height: 16 },
  { id: '3:4', label: '3:4', width: 3, height: 4 },
  { id: '1:1', label: '1:1', width: 1, height: 1 },
  { id: '4:3', label: '4:3', width: 4, height: 3 },
  { id: '16:9', label: '16:9', width: 16, height: 9 },
]

export const canvasDimensions = ({ aspectRatio, quality }: CanvasSettings) => {
  const ratio = aspectRatioOptions.find((option) => option.id === aspectRatio)!
  const shortEdge = quality === '1080p' ? 1080 : 720
  return ratio.width <= ratio.height
    ? { width: shortEdge, height: Math.round(shortEdge * ratio.height / ratio.width) }
    : { width: Math.round(shortEdge * ratio.width / ratio.height), height: shortEdge }
}

export function analyzeSourceQuality(
  clips: Array<Pick<VideoClip, 'name' | 'width' | 'height' | 'crop'>>,
): SourceQualityAnalysis {
  if (!clips.length) {
    return {
      recommendedQuality: '1080p', supports1080p: true, minimumShortEdge: 1080,
      effectiveShortEdge: 1080, sourceLabel: '等待素材',
    }
  }

  const limitingSource = clips.reduce((lowest, clip) => (
    Math.min(clip.width, clip.height) < Math.min(lowest.width, lowest.height) ? clip : lowest
  ))
  const minimumShortEdge = Math.min(limitingSource.width, limitingSource.height)
  const effectiveShortEdge = Math.floor(Math.min(...clips.map((clip) => (
    Math.min(clip.width, clip.height) / Math.max(1, clip.crop.scale)
  ))))
  const supports1080p = minimumShortEdge >= 1080
  const sourceLabel = minimumShortEdge >= 2160 ? '4K 素材' : minimumShortEdge >= 1080 ? '1080P 素材' : minimumShortEdge >= 720 ? '720P 素材' : '低于 720P'

  return {
    recommendedQuality: supports1080p ? '1080p' : '720p',
    supports1080p,
    minimumShortEdge,
    effectiveShortEdge,
    limitingSourceName: limitingSource.name,
    sourceLabel,
  }
}

export interface CropPosition {
  normalizedCenterX: number
  normalizedCenterY: number
  scale: number
}

export interface VideoClip {
  id: string
  sourcePath: string
  name: string
  durationMs: number
  width: number
  height: number
  codec: string
  startTimeMs: number
  crop: CropPosition
  previewUrl: string
}

/** A video source after it has been placed in a particular canvas cell.
 *
 * Placements intentionally have their own identity: one source may appear in
 * several cells, with a different three-second selection and crop in each.
 */
export interface SlotClip extends VideoClip {
  sourceClipId: string
  targetSlotId: string
  /** Sound is controlled by the placed cell, so one source can be silent in
   * one slot and audible in another. */
  audioEnabled?: boolean
}

export interface Slot {
  id: string
  label: string
  x: number
  y: number
  width: number
  height: number
}

export interface CollageTemplate {
  id: TemplateId
  name: string
  description: string
  requiredClipCount: number
  slots: Slot[]
}

export interface RenderProject {
  id: string
  templateId: TemplateId
  canvas: { width: number; height: number; fps: 30; durationMs: 3000 }
  clips: Array<{
    id: string
    sourcePath: string
    sourceDurationMs: number
    startTimeMs: number
    crop: CropPosition
    targetSlotId: string
    audioEnabled: boolean
  }>
  coverTimeMs: number
}

export const OUTPUT_DURATION_MS = 3000
export const MINIMUM_SOURCE_DURATION_MS = 2500

export const sourceContentDurationMs = (sourceDurationMs: number, startTimeMs = 0) =>
  Math.min(OUTPUT_DURATION_MS, Math.max(0, sourceDurationMs - startTimeMs))

export const sourcePaddingDurationMs = (sourceDurationMs: number, startTimeMs = 0) =>
  Math.max(0, OUTPUT_DURATION_MS - sourceContentDurationMs(sourceDurationMs, startTimeMs))

export const templates: CollageTemplate[] = [
  {
    id: 'single', name: '单画面', description: '完整画布', requiredClipCount: 1,
    slots: [{ id: 'full', label: '主画面', x: 0, y: 0, width: 1, height: 1 }],
  },
  {
    id: 'stack-2', name: '上下二拼', description: '两格同步', requiredClipCount: 2,
    slots: [
      { id: 'top', label: '上方画面', x: 0, y: 0, width: 1, height: 0.5 },
      { id: 'bottom', label: '下方画面', x: 0, y: 0.5, width: 1, height: 0.5 },
    ],
  },
  {
    id: 'side-2', name: '左右二拼', description: '左右并列', requiredClipCount: 2,
    slots: [
      { id: 'left', label: '左侧画面', x: 0, y: 0, width: 0.5, height: 1 },
      { id: 'right', label: '右侧画面', x: 0.5, y: 0, width: 0.5, height: 1 },
    ],
  },
  {
    id: 'stack-3', name: '经典三拼', description: '三格同步', requiredClipCount: 3,
    slots: [
      { id: 'top', label: '上方画面', x: 0, y: 0, width: 1, height: 1 / 3 },
      { id: 'middle', label: '中间画面', x: 0, y: 1 / 3, width: 1, height: 1 / 3 },
      { id: 'bottom', label: '下方画面', x: 0, y: 2 / 3, width: 1, height: 1 / 3 },
    ],
  },
  {
    id: 'side-3', name: '垂直三拼', description: '三列并排', requiredClipCount: 3,
    slots: [
      { id: 'left', label: '左侧画面', x: 0, y: 0, width: 1 / 3, height: 1 },
      { id: 'center', label: '中间画面', x: 1 / 3, y: 0, width: 1 / 3, height: 1 },
      { id: 'right', label: '右侧画面', x: 2 / 3, y: 0, width: 1 / 3, height: 1 },
    ],
  },
  {
    id: 'hero-left', name: '左大右双', description: '主次分明', requiredClipCount: 3,
    slots: [
      { id: 'hero-left', label: '左侧主画面', x: 0, y: 0, width: 2 / 3, height: 1 },
      { id: 'right-top', label: '右上画面', x: 2 / 3, y: 0, width: 1 / 3, height: 0.5 },
      { id: 'right-bottom', label: '右下画面', x: 2 / 3, y: 0.5, width: 1 / 3, height: 0.5 },
    ],
  },
  {
    id: 'hero-top', name: '上大下双', description: '主图在上', requiredClipCount: 3,
    slots: [
      { id: 'hero-top', label: '上方主画面', x: 0, y: 0, width: 1, height: 2 / 3 },
      { id: 'bottom-left', label: '左下画面', x: 0, y: 2 / 3, width: 0.5, height: 1 / 3 },
      { id: 'bottom-right', label: '右下画面', x: 0.5, y: 2 / 3, width: 0.5, height: 1 / 3 },
    ],
  },
  {
    id: 'weighted-3', name: '大中小三拼', description: '50 · 30 · 20', requiredClipCount: 3,
    slots: [
      { id: 'large', label: '大画面', x: 0, y: 0, width: 1, height: 0.5 },
      { id: 'medium', label: '中画面', x: 0, y: 0.5, width: 1, height: 0.3 },
      { id: 'small', label: '小画面', x: 0, y: 0.8, width: 1, height: 0.2 },
    ],
  },
]

export function createRenderProject(
  clips: VideoClip[],
  templateId: TemplateId,
  slotClips?: Array<SlotClip | VideoClip | undefined>,
  canvasSettings: CanvasSettings = { aspectRatio: '9:16', quality: '1080p' },
  coverTimeMs = 1500,
): RenderProject {
  const template = templates.find((item) => item.id === templateId)!
  const renderedClips = slotClips ?? clips.slice(0, template.requiredClipCount)
  if (renderedClips.length !== template.requiredClipCount || renderedClips.some((clip) => !clip)) throw new Error('素材数量不足，无法填满当前模板')
  const filledClips = renderedClips as Array<SlotClip | VideoClip>
  const dimensions = canvasDimensions(canvasSettings)
  return {
    id: crypto.randomUUID(),
    templateId,
    canvas: { ...dimensions, fps: 30, durationMs: OUTPUT_DURATION_MS },
    clips: filledClips.map((clip, index) => ({
      id: clip.id,
      sourcePath: clip.sourcePath,
      sourceDurationMs: clip.durationMs,
      startTimeMs: Math.min(clip.startTimeMs, Math.max(0, clip.durationMs - OUTPUT_DURATION_MS)),
      crop: clip.crop,
      targetSlotId: template.slots[index].id,
      audioEnabled: 'audioEnabled' in clip && clip.audioEnabled === true,
    })),
    coverTimeMs: Math.max(0, Math.min(2900, Math.round(coverTimeMs / 100) * 100)),
  }
}

export const formatDuration = (milliseconds: number) => {
  const seconds = Math.max(0, milliseconds) / 1000
  const minutes = Math.floor(seconds / 60)
  return `${minutes}:${(seconds % 60).toFixed(1).padStart(4, '0')}`
}
