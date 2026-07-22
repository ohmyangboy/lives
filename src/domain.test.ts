import { describe, expect, it } from 'vitest'
import { analyzeSourceQuality, createRenderProject, MINIMUM_SOURCE_DURATION_MS, sourceContentDurationMs, sourcePaddingDurationMs, type SlotClip, type VideoClip } from './domain'

const clip = (index: number): VideoClip => ({
  id: `clip-${index}`,
  sourcePath: `/tmp/clip-${index}.mov`,
  name: `clip-${index}.mov`,
  durationMs: 5000,
  width: 1920,
  height: 1080,
  codec: 'avc1',
  startTimeMs: 4000,
  crop: { normalizedCenterX: 0.5, normalizedCenterY: 0.5, scale: 1 },
  previewUrl: '',
})

describe('render project', () => {
  it('clamps each three-second selection to the source duration', () => {
    const project = createRenderProject([clip(1), clip(2), clip(3)], 'stack-3')
    expect(project.clips.map((item) => item.startTimeMs)).toEqual([2000, 2000, 2000])
    expect(project.clips.map((item) => item.targetSlotId)).toEqual(['top', 'middle', 'bottom'])
    expect(project.clips.map((item) => item.audioEnabled)).toEqual([false, false, false])
  })

  it('uses the first slots of the freely selected template', () => {
    const project = createRenderProject([clip(1), clip(2), clip(3)], 'single')
    expect(project.clips).toHaveLength(1)
    expect(project.clips[0].id).toBe('clip-1')
  })

  it('keeps an explicit material assignment for each template slot', () => {
    const project = createRenderProject([clip(1), clip(2), clip(3)], 'stack-2', [clip(3), clip(1)])
    expect(project.clips.map((item) => item.id)).toEqual(['clip-3', 'clip-1'])
    expect(project.clips.map((item) => item.targetSlotId)).toEqual(['top', 'bottom'])
  })

  it('does not let a large source library change explicitly chosen collage material', () => {
    const library = Array.from({ length: 60 }, (_, index) => clip(index + 1))
    const top: SlotClip = { ...clip(42), id: 'chosen-top', sourceClipId: 'clip-42', targetSlotId: 'top', startTimeMs: 600, audioEnabled: true }
    const bottom: SlotClip = { ...clip(7), id: 'chosen-bottom', sourceClipId: 'clip-7', targetSlotId: 'bottom', startTimeMs: 1800, audioEnabled: false }

    const project = createRenderProject(library, 'stack-2', [top, bottom])

    expect(project.clips.map((item) => item.id)).toEqual(['chosen-top', 'chosen-bottom'])
    expect(project.clips.map((item) => item.sourcePath)).toEqual(['/tmp/clip-42.mov', '/tmp/clip-7.mov'])
    expect(project.clips.map((item) => item.startTimeMs)).toEqual([600, 1800])
    expect(project.clips.map((item) => item.audioEnabled)).toEqual([true, false])
  })

  it('maps asymmetric collage templates to their native slot identifiers', () => {
    const project = createRenderProject([clip(1), clip(2), clip(3)], 'hero-left')
    expect(project.clips.map((item) => item.targetSlotId)).toEqual(['hero-left', 'right-top', 'right-bottom'])
  })

  it('maps vertical three-column collage slots from left to right', () => {
    const project = createRenderProject([clip(1), clip(2), clip(3)], 'side-3')
    expect(project.clips.map((item) => item.targetSlotId)).toEqual(['left', 'center', 'right'])
  })

  it('allows one source to be placed in multiple slots with independent edits', () => {
    const top: SlotClip = { ...clip(1), id: 'placed-top', sourceClipId: 'clip-1', targetSlotId: 'top', startTimeMs: 400, crop: { normalizedCenterX: .25, normalizedCenterY: .5, scale: 1 }, audioEnabled: true }
    const bottom: SlotClip = { ...clip(1), id: 'placed-bottom', sourceClipId: 'clip-1', targetSlotId: 'bottom', startTimeMs: 1700, crop: { normalizedCenterX: .75, normalizedCenterY: .5, scale: 1 }, audioEnabled: true }
    const project = createRenderProject([clip(1)], 'stack-2', [top, bottom])

    expect(project.clips.map((item) => item.id)).toEqual(['placed-top', 'placed-bottom'])
    expect(project.clips.map((item) => item.sourcePath)).toEqual(['/tmp/clip-1.mov', '/tmp/clip-1.mov'])
    expect(project.clips.map((item) => item.startTimeMs)).toEqual([400, 1700])
    expect(project.clips.map((item) => item.crop.normalizedCenterX)).toEqual([.25, .75])
    expect(project.clips.map((item) => item.audioEnabled)).toEqual([true, true])
  })

  it('applies the selected aspect ratio and export quality to the render canvas', () => {
    const project = createRenderProject([clip(1)], 'single', undefined, { aspectRatio: '3:4', quality: '720p' })
    expect(project.canvas).toEqual({ width: 720, height: 960, fps: 30, durationMs: 3000 })
  })

  it('uses the short edge as the quality tier when exporting landscape', () => {
    const project = createRenderProject([clip(1)], 'single', undefined, { aspectRatio: '16:9', quality: '1080p' })
    expect(project.canvas).toEqual({ width: 1920, height: 1080, fps: 30, durationMs: 3000 })
  })

  it('uses the chosen Live Photo key frame time', () => {
    const project = createRenderProject([clip(1)], 'single', undefined, { aspectRatio: '9:16', quality: '1080p' }, 2200)
    expect(project.coverTimeMs).toBe(2200)
  })

  it('keeps the Live Photo key frame inside the three-second clip', () => {
    const project = createRenderProject([clip(1)], 'single', undefined, { aspectRatio: '9:16', quality: '1080p' }, 4000)
    expect(project.coverTimeMs).toBe(2900)
  })

  it('keeps a short Live Photo-derived source at the beginning for native end padding', () => {
    const shortLiveVideo = { ...clip(1), durationMs: 2833, startTimeMs: 400 }
    const project = createRenderProject([shortLiveVideo], 'single')

    expect(project.clips[0].startTimeMs).toBe(0)
    expect(project.clips[0].sourceDurationMs).toBe(2833)
    expect(MINIMUM_SOURCE_DURATION_MS).toBe(2500)
    expect(sourceContentDurationMs(shortLiveVideo.durationMs)).toBe(2833)
    expect(sourcePaddingDurationMs(shortLiveVideo.durationMs)).toBe(167)
  })

  it('rejects a template with too few clips', () => {
    expect(() => createRenderProject([clip(1)], 'stack-2')).toThrow('素材数量不足')
  })
})

describe('source-aware export quality', () => {
  it('recommends 1080P when every used source has at least a 1080px short edge', () => {
    const analysis = analyzeSourceQuality([clip(1), { ...clip(2), width: 3840, height: 2160 }])
    expect(analysis.recommendedQuality).toBe('1080p')
    expect(analysis.supports1080p).toBe(true)
    expect(analysis.sourceLabel).toBe('1080P 素材')
  })

  it('uses the lowest-quality source and avoids recommending an upscale', () => {
    const analysis = analyzeSourceQuality([clip(1), { ...clip(2), width: 1280, height: 720 }])
    expect(analysis.recommendedQuality).toBe('720p')
    expect(analysis.supports1080p).toBe(false)
    expect(analysis.limitingSourceName).toBe('clip-2.mov')
  })

  it('reports the effective detail remaining after a crop zoom', () => {
    const analysis = analyzeSourceQuality([{ ...clip(1), width: 3840, height: 2160, crop: { ...clip(1).crop, scale: 2.5 } }])
    expect(analysis.effectiveShortEdge).toBe(864)
  })
})
