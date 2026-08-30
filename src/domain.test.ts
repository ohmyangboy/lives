import { describe, expect, it } from 'vitest'
import { analyzeSourceQuality, canvasDimensions, createRenderProject, CUSTOM_RATIO_BOUNDS, MINIMUM_SOURCE_DURATION_MS, normalizeCustomRatio, planFolderSync, simplifyRatio, sourceContentDurationMs, sourcePaddingDurationMs, type SlotClip, type VideoClip } from './domain'

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
    const top: SlotClip = { ...clip(42), id: 'chosen-top', sourceClipId: 'clip-42', targetSlotId: 'top', startTimeMs: 600, audioEnabled: true, coverTimeMs: 400 }
    const bottom: SlotClip = { ...clip(7), id: 'chosen-bottom', sourceClipId: 'clip-7', targetSlotId: 'bottom', startTimeMs: 1800, audioEnabled: false, coverTimeMs: 2200 }

    const project = createRenderProject(library, 'stack-2', [top, bottom])

    expect(project.clips.map((item) => item.id)).toEqual(['chosen-top', 'chosen-bottom'])
    expect(project.clips.map((item) => item.sourcePath)).toEqual(['/tmp/clip-42.mov', '/tmp/clip-7.mov'])
    expect(project.clips.map((item) => item.startTimeMs)).toEqual([600, 1800])
    expect(project.clips.map((item) => item.audioEnabled)).toEqual([true, false])
    expect(project.clips.map((item) => item.coverTimeMs)).toEqual([400, 2200])
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
    const top: SlotClip = { ...clip(1), id: 'placed-top', sourceClipId: 'clip-1', targetSlotId: 'top', startTimeMs: 400, crop: { normalizedCenterX: .25, normalizedCenterY: .5, scale: 1 }, audioEnabled: true, coverTimeMs: 700 }
    const bottom: SlotClip = { ...clip(1), id: 'placed-bottom', sourceClipId: 'clip-1', targetSlotId: 'bottom', startTimeMs: 1700, crop: { normalizedCenterX: .75, normalizedCenterY: .5, scale: 1 }, audioEnabled: true, coverTimeMs: 2100 }
    const project = createRenderProject([clip(1)], 'stack-2', [top, bottom])

    expect(project.clips.map((item) => item.id)).toEqual(['placed-top', 'placed-bottom'])
    expect(project.clips.map((item) => item.sourcePath)).toEqual(['/tmp/clip-1.mov', '/tmp/clip-1.mov'])
    expect(project.clips.map((item) => item.startTimeMs)).toEqual([400, 1700])
    expect(project.clips.map((item) => item.crop.normalizedCenterX)).toEqual([.25, .75])
    expect(project.clips.map((item) => item.audioEnabled)).toEqual([true, true])
    expect(project.clips.map((item) => item.coverTimeMs)).toEqual([700, 2100])
  })

  it('preserves distinct coverTimeMs for each slot in multi-clip templates', () => {
    const top: SlotClip = { ...clip(1), id: 'slot-1', sourceClipId: 'clip-1', targetSlotId: 'top', startTimeMs: 0, coverTimeMs: 300 }
    const middle: SlotClip = { ...clip(2), id: 'slot-2', sourceClipId: 'clip-2', targetSlotId: 'middle', startTimeMs: 500, coverTimeMs: 1200 }
    const bottom: SlotClip = { ...clip(3), id: 'slot-3', sourceClipId: 'clip-3', targetSlotId: 'bottom', startTimeMs: 1000, coverTimeMs: 2800 }
    const project = createRenderProject([clip(1), clip(2), clip(3)], 'stack-3', [top, middle, bottom])

    expect(project.clips[0].coverTimeMs).toBe(300)
    expect(project.clips[1].coverTimeMs).toBe(1200)
    expect(project.clips[2].coverTimeMs).toBe(2800)
    expect(project.clips.map((item) => item.targetSlotId)).toEqual(['top', 'middle', 'bottom'])
  })

  it('applies the selected aspect ratio and export quality to the render canvas', () => {
    const project = createRenderProject([clip(1)], 'single', undefined, { aspectRatio: '3:4', quality: '720p' })
    expect(project.canvas).toEqual({ width: 720, height: 960, fps: 30, durationMs: 3000 })
  })

  it('uses the short edge as the quality tier when exporting landscape', () => {
    const project = createRenderProject([clip(1)], 'single', undefined, { aspectRatio: '16:9', quality: '1080p' })
    expect(project.canvas).toEqual({ width: 1920, height: 1080, fps: 30, durationMs: 3000 })
  })

  it('applies a custom ratio to the render canvas', () => {
    const project = createRenderProject([clip(1)], 'single', undefined, { aspectRatio: 'custom', quality: '720p', customRatio: { width: 5, height: 7 } })
    expect(project.canvas).toEqual({ width: 720, height: 1008, fps: 30, durationMs: 3000 })
  })

  it('supports landscape custom ratios at the 3:1 bound', () => {
    expect(canvasDimensions({ aspectRatio: 'custom', quality: '720p', customRatio: { width: 3, height: 1 } })).toEqual({ width: 2160, height: 720 })
  })

  it('aligns odd custom long edges to even pixels for the video encoder', () => {
    expect(canvasDimensions({ aspectRatio: 'custom', quality: '1080p', customRatio: { width: 7, height: 11 } })).toEqual({ width: 1080, height: 1696 })
  })

  it('clamps custom ratios beyond the 1:3 – 3:1 range', () => {
    expect(normalizeCustomRatio({ width: 999, height: 1 })).toEqual({ width: 3, height: 1 })
    expect(normalizeCustomRatio({ width: 1, height: 999 })).toEqual({ width: 1, height: 3 })
    expect(canvasDimensions({ aspectRatio: 'custom', quality: '720p', customRatio: { width: 1, height: 5 } })).toEqual({ width: 720, height: 2160 })
  })

  it('falls back to 9:16 when a custom ratio is missing', () => {
    expect(canvasDimensions({ aspectRatio: 'custom', quality: '1080p' })).toEqual({ width: 1080, height: 1920 })
  })

  it('keeps non-positive custom ratio edges at 1', () => {
    expect(normalizeCustomRatio({ width: 0, height: 0 })).toEqual({ width: 1, height: 1 })
    expect(normalizeCustomRatio({ width: Number.NaN, height: 1 })).toEqual({ width: 1, height: 1 })
    expect(CUSTOM_RATIO_BOUNDS).toEqual({ min: 1 / 3, max: 3 })
  })

  it('reduces drag ratios to their smallest integer representation', () => {
    expect(simplifyRatio({ width: 56, height: 100 })).toEqual({ width: 14, height: 25 })
    expect(simplifyRatio({ width: 100, height: 100 })).toEqual({ width: 1, height: 1 })
    expect(simplifyRatio({ width: 7, height: 13 })).toEqual({ width: 7, height: 13 })
    expect(simplifyRatio({ width: 0.4, height: 0 })).toEqual({ width: 1, height: 1 })
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

describe('planFolderSync', () => {
  const folderProject = (id: string, clipIds: string[]) => ({ id, clipIds })

  it('adds only scanned files that are not in the library yet, without duplicates', () => {
    const plan = planFolderSync(
      [`/tmp/clip-1.mov`, `/tmp/new.mov`, `/tmp/new.mov`],
      [clip(1)],
      folderProject('p1', ['clip-1']),
      [folderProject('p1', ['clip-1'])],
    )
    expect(plan.toAdd).toEqual(['/tmp/new.mov'])
    expect(plan.missingClipIds).toEqual([])
    expect(plan.removeClipIds).toEqual([])
  })

  it('skips scanned files whose extension is not supported', () => {
    const plan = planFolderSync([`/tmp/clip-1.mov`, '/tmp/notes.txt', '/tmp/movie.avi', '/tmp/keep.m4v'], [clip(1)], folderProject('p1', ['clip-1']), [folderProject('p1', ['clip-1'])])
    expect(plan.toAdd).toEqual(['/tmp/keep.m4v'])
    expect(plan.missingClipIds).toEqual([])
  })

  it('marks project clips whose files left the folder as missing and globally removable', () => {
    const plan = planFolderSync(
      [`/tmp/clip-1.mov`],
      [clip(1), clip(2)],
      folderProject('p1', ['clip-1', 'clip-2']),
      [folderProject('p1', ['clip-1', 'clip-2'])],
    )
    expect(plan.missingClipIds).toEqual(['clip-2'])
    expect(plan.removeClipIds).toEqual(['clip-2'])
  })

  it('keeps a missing clip in the library while only unlinking it from this project when another project still references it', () => {
    const projects = [folderProject('p1', ['clip-1', 'clip-2']), folderProject('p2', ['clip-2'])]
    const plan = planFolderSync([`/tmp/clip-1.mov`], [clip(1), clip(2)], projects[0], projects)
    expect(plan.missingClipIds).toEqual(['clip-2'])
    expect(plan.removeClipIds).toEqual([])
  })

  it('reports every project clip as missing when the folder scan comes back empty', () => {
    const plan = planFolderSync([], [clip(1), clip(2)], folderProject('p1', ['clip-1', 'clip-2']), [folderProject('p1', ['clip-1', 'clip-2'])])
    expect(plan.toAdd).toEqual([])
    expect(plan.missingClipIds).toEqual(['clip-1', 'clip-2'])
  })

  it('never plans removal for clips without a source path', () => {
    const browserClip = { ...clip(3), sourcePath: '' }
    const plan = planFolderSync([], [browserClip], folderProject('p1', ['clip-3']), [folderProject('p1', ['clip-3'])])
    expect(plan.missingClipIds).toEqual([])
    expect(plan.removeClipIds).toEqual([])
  })
})
