import { useEffect, useMemo, useRef, useState, type CSSProperties, type PointerEvent as ReactPointerEvent, type WheelEvent as ReactWheelEvent } from 'react'
import type { AudioMode, CollageTemplate, SlotClip } from '../domain'
import { CloseIcon, LiveIcon, PauseIcon, PlayIcon, PlusIcon } from '../icons'

interface Props {
  clips: Array<SlotClip | undefined>
  template: CollageTemplate
  canvasWidth: number
  canvasHeight: number
  selectedSlotId?: string
  selectedSourceId?: string
  pointerDropTargetSlotId?: string
  isSourceDragging?: boolean
  audioMode: AudioMode
  audioSourceClipId?: string
  coverTimeMs: number
  onSelectSlot: (slotId: string | undefined) => void
  onCropChange: (slotId: string, x: number, y: number) => void
  onScaleChange: (slotId: string, scale: number) => void
  onClearSlot: (slotId: string) => void
  onDropSource: (slotId: string, sourceClipId: string) => void
  onCoverTimeChange: (milliseconds: number) => void
}

const MIN_SCALE = 1
const MAX_SCALE = 3

export function CollagePreview({ clips, template, canvasWidth, canvasHeight, selectedSlotId, selectedSourceId, pointerDropTargetSlotId, isSourceDragging, audioMode, audioSourceClipId, coverTimeMs, onSelectSlot, onCropChange, onScaleChange, onClearSlot, onDropSource, onCoverTimeChange }: Props) {
  const videosRef = useRef<Map<string, HTMLVideoElement>>(new Map())
  const stageRef = useRef<HTMLDivElement>(null)
  const frameRef = useRef(0)
  const startedAtRef = useRef(0)
  const dragRef = useRef<{ slotId: string; x: number; y: number; cropX: number; cropY: number } | undefined>(undefined)
  const [playing, setPlaying] = useState(false)
  const [playhead, setPlayhead] = useState(0)
  const [settledOnCover, setSettledOnCover] = useState(true)
  const [maximumCanvasHeight, setMaximumCanvasHeight] = useState(360)
  const [dropTargetSlotId, setDropTargetSlotId] = useState<string>()
  const clipsKey = useMemo(() => clips.filter((clip): clip is SlotClip => Boolean(clip)).map((clip) => `${clip.id}:${clip.previewUrl}:${clip.startTimeMs}`).join('|'), [clips])
  const selectedClip = clips.find((clip) => clip?.targetSlotId === selectedSlotId)
  const slotLabel = (slotId: string) => {
    if (template.slots.length === 1) return '主画面'
    const index = template.slots.findIndex((slot) => slot.id === slotId)
    return index === 0 ? '上方画面' : index === template.slots.length - 1 ? '下方画面' : '中间画面'
  }

  const clampScale = (scale: number) => Math.max(MIN_SCALE, Math.min(MAX_SCALE, Number(scale.toFixed(2))))

  const renderMetrics = (clip: SlotClip, slotIndex: number) => {
    const slot = template.slots[slotIndex]
    const sourceAspect = clip.width / Math.max(1, clip.height)
    const slotAspect = (canvasWidth * slot.width) / (canvasHeight * slot.height)
    const baseWidth = sourceAspect > slotAspect ? sourceAspect / slotAspect : 1
    const baseHeight = sourceAspect > slotAspect ? 1 : slotAspect / sourceAspect
    const renderedWidth = baseWidth * clip.crop.scale
    const renderedHeight = baseHeight * clip.crop.scale
    return {
      renderedWidth,
      renderedHeight,
      overflowX: Math.max(0, renderedWidth - 1),
      overflowY: Math.max(0, renderedHeight - 1),
    }
  }

  const videoStyle = (clip: SlotClip, slotIndex: number): CSSProperties => {
    const metrics = renderMetrics(clip, slotIndex)
    return {
      width: `${metrics.renderedWidth * 100}%`,
      height: `${metrics.renderedHeight * 100}%`,
      left: `${-metrics.overflowX * clip.crop.normalizedCenterX * 100}%`,
      top: `${-metrics.overflowY * clip.crop.normalizedCenterY * 100}%`,
    }
  }

  const seekClipStart = (video: HTMLVideoElement, clip: SlotClip) => {
    if (!Number.isFinite(video.duration)) return
    video.pause()
    video.currentTime = Math.min(clip.startTimeMs / 1000, Math.max(0, video.duration - 3))
  }

  const seekToOffset = (offsetSeconds: number) => {
    clips.forEach((clip) => {
      if (!clip) return
      const video = videosRef.current.get(clip.id)
      if (!video) return
      if (video.readyState >= 1) {
        video.pause()
        video.currentTime = Math.min(clip.startTimeMs / 1000 + offsetSeconds, Math.max(0, video.duration - .04))
      }
    })
  }

  useEffect(() => {
    setPlaying(false)
    setSettledOnCover(true)
    setPlayhead(coverTimeMs / 3000)
    seekToOffset(coverTimeMs / 1000)
  }, [selectedSlotId, clipsKey, coverTimeMs])

  useEffect(() => {
    clips.forEach((clip) => {
      if (!clip) return
      const video = videosRef.current.get(clip.id)
      if (!video) return
      video.muted = audioMode === 'mute' || (audioMode === 'selected' && clip.id !== audioSourceClipId)
      video.volume = audioMode === 'mix' ? 0.35 : 1
    })
  }, [audioMode, clips, audioSourceClipId])

  useEffect(() => {
    const stage = stageRef.current
    if (!stage) return
    const update = () => setMaximumCanvasHeight(Math.max(180, stage.clientHeight - 122))
    update()
    const observer = new ResizeObserver(update)
    observer.observe(stage)
    return () => observer.disconnect()
  }, [])

  useEffect(() => {
    if (!playing) {
      videosRef.current.forEach((video) => video.pause())
      return
    }
    const tick = (now: number) => {
      const elapsed = (now - startedAtRef.current) / 1000
      const position = Math.min(elapsed, 3)
      setPlayhead(position / 3)
      if (elapsed >= 3) {
        // A Live Photo plays its three-second motion once, then settles on
        // the chosen key frame instead of looping back to the first frame.
        setPlaying(false)
        setSettledOnCover(true)
        setPlayhead(coverTimeMs / 3000)
        seekToOffset(coverTimeMs / 1000)
        return
      }
      frameRef.current = requestAnimationFrame(tick)
    }
    frameRef.current = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(frameRef.current)
  }, [playing, clips, coverTimeMs])

  const togglePlayback = () => {
    if (!clips.some(Boolean)) return
    if (playing) { setPlaying(false); setSettledOnCover(false); return }
    clips.forEach((clip) => {
      if (!clip) return
      const video = videosRef.current.get(clip.id)
      if (!video) return
      seekClipStart(video, clip)
      void video.play()
    })
    startedAtRef.current = performance.now()
    setSettledOnCover(false)
    setPlaying(true)
  }

  const setCoverFrame = (milliseconds: number) => {
    const next = Math.max(0, Math.min(2900, Math.round(milliseconds / 100) * 100))
    setPlaying(false)
    setSettledOnCover(true)
    setPlayhead(next / 3000)
    seekToOffset(next / 1000)
    onCoverTimeChange(next)
  }

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.code !== 'Space' || event.repeat || document.querySelector('[role="dialog"]')) return
      const target = event.target as HTMLElement | null
      if (target?.closest('input, textarea, select, [contenteditable="true"]')) return
      event.preventDefault()
      togglePlayback()
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [playing, clipsKey])

  const locate = (event: ReactPointerEvent<HTMLDivElement> | ReactWheelEvent<HTMLDivElement>) => {
    const rect = event.currentTarget.getBoundingClientRect()
    return { x: (event.clientX - rect.left) / rect.width, y: (event.clientY - rect.top) / rect.height }
  }

  const pointerDown = (event: ReactPointerEvent<HTMLDivElement>) => {
    const point = locate(event)
    const slotIndex = template.slots.findIndex((slot) => point.x >= slot.x && point.x <= slot.x + slot.width && point.y >= slot.y && point.y <= slot.y + slot.height)
    if (slotIndex < 0) return
    const clip = clips[slotIndex]
    if (!clip) {
      if (selectedSourceId) onDropSource(template.slots[slotIndex].id, selectedSourceId)
      else onSelectSlot(undefined)
      return
    }
    event.currentTarget.setPointerCapture(event.pointerId)
    onSelectSlot(template.slots[slotIndex].id)
    dragRef.current = { slotId: template.slots[slotIndex].id, x: point.x, y: point.y, cropX: clip.crop.normalizedCenterX, cropY: clip.crop.normalizedCenterY }
  }

  const pointerMove = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (!dragRef.current) return
    const point = locate(event)
    const slotIndex = template.slots.findIndex((slot) => slot.id === dragRef.current?.slotId)
    const clip = clips[slotIndex]
    if (!clip || slotIndex < 0) return
    const slot = template.slots[slotIndex]
    const metrics = renderMetrics(clip, slotIndex)
    const deltaX = (point.x - dragRef.current.x) / slot.width
    const deltaY = (point.y - dragRef.current.y) / slot.height
    onCropChange(
      dragRef.current.slotId,
      metrics.overflowX > .001 ? Math.max(0, Math.min(1, dragRef.current.cropX - deltaX / metrics.overflowX)) : .5,
      metrics.overflowY > .001 ? Math.max(0, Math.min(1, dragRef.current.cropY - deltaY / metrics.overflowY)) : .5,
    )
  }

  const handleWheel = (event: ReactWheelEvent<HTMLDivElement>) => {
    if (!event.ctrlKey && !event.metaKey) return
    const point = locate(event)
    const slotIndex = template.slots.findIndex((slot) => point.x >= slot.x && point.x <= slot.x + slot.width && point.y >= slot.y && point.y <= slot.y + slot.height)
    const clip = clips[slotIndex]
    if (!clip || slotIndex < 0) return
    event.preventDefault()
    onSelectSlot(template.slots[slotIndex].id)
    const delta = Math.max(-40, Math.min(40, event.deltaY))
    onScaleChange(template.slots[slotIndex].id, clampScale(clip.crop.scale * Math.exp(-delta * .004)))
  }

  const changeSelectedScale = (delta: number) => {
    if (!selectedClip) return
    onScaleChange(selectedClip.targetSlotId, clampScale(selectedClip.crop.scale + delta))
  }

  return (
    <div ref={stageRef} className="preview-stage" onPointerDown={(event) => { if (event.target === event.currentTarget) onSelectSlot(undefined) }}>
      <div className="source-monitor-bar">
        <div className="source-monitor-label"><span /> 拼贴预览 · {selectedClip ? `正在调整${slotLabel(selectedClip.targetSlotId)}` : clips.some(Boolean) ? '点击画格继续调整' : '把素材拖入画面格'}</div>
        {selectedClip && <div className="composition-toolbar" aria-label="当前画面构图工具">
          <button onClick={() => changeSelectedScale(-.1)} disabled={selectedClip.crop.scale <= MIN_SCALE} aria-label="缩小画面">−</button>
          <output>{Math.round(selectedClip.crop.scale * 100)}%</output>
          <button onClick={() => changeSelectedScale(.1)} disabled={selectedClip.crop.scale >= MAX_SCALE} aria-label="放大画面">＋</button>
          <button className="reset-crop" onClick={() => { onCropChange(selectedClip.targetSlotId, .5, .5); onScaleChange(selectedClip.targetSlotId, 1) }}>居中</button>
        </div>}
      </div>
      <div className="canvas-shell" style={{ aspectRatio: `${canvasWidth} / ${canvasHeight}`, width: `min(88%, 500px, ${(maximumCanvasHeight * canvasWidth / canvasHeight).toFixed(1)}px)` }}>
        <div className="collage-canvas" onPointerDown={pointerDown} onPointerMove={pointerMove} onPointerUp={() => { dragRef.current = undefined }} onPointerCancel={() => { dragRef.current = undefined }} onWheel={handleWheel}>
          {template.slots.map((slot, index) => {
            const clip = clips[index]
            const isPointerTarget = slot.id === pointerDropTargetSlotId
            const slotClassName = ['collage-slot', !clip && 'empty', slot.id === selectedSlotId && clip && 'selected', isSourceDragging && 'drop-ready', (slot.id === dropTargetSlotId || isPointerTarget) && 'drop-target'].filter(Boolean).join(' ')
            const touchesRightEdge = slot.x + slot.width >= .999
            const touchesBottomEdge = slot.y + slot.height >= .999
            const edgeRadius = '11px'
            const slotStyle: CSSProperties = {
              left: `${slot.x * 100}%`,
              top: `${slot.y * 100}%`,
              width: `${slot.width * 100}%`,
              height: `${slot.height * 100}%`,
              borderTopLeftRadius: slot.x <= .001 && slot.y <= .001 ? edgeRadius : 0,
              borderTopRightRadius: touchesRightEdge && slot.y <= .001 ? edgeRadius : 0,
              borderBottomRightRadius: touchesRightEdge && touchesBottomEdge ? edgeRadius : 0,
              borderBottomLeftRadius: slot.x <= .001 && touchesBottomEdge ? edgeRadius : 0,
            }
            return <div key={slot.id} data-collage-slot-id={slot.id} className={slotClassName} style={slotStyle} onDragOver={(event) => { event.preventDefault(); event.dataTransfer.dropEffect = 'copy'; setDropTargetSlotId(slot.id) }} onDragLeave={() => setDropTargetSlotId((current) => current === slot.id ? undefined : current)} onDrop={(event) => { event.preventDefault(); const sourceClipId = event.dataTransfer.getData('application/x-livecollage-source'); setDropTargetSlotId(undefined); if (sourceClipId) onDropSource(slot.id, sourceClipId) }}>
              {!clip ? <div className="slot-drop-copy"><PlusIcon /><strong>{isPointerTarget ? '松开放入' : '拖入视频'}</strong><small>{isPointerTarget ? '将素材放进这个格子' : template.slots.length === 1 ? '开始构图' : '可重复使用素材'}</small></div> : <>
              <video
                ref={(element) => { if (element) videosRef.current.set(clip.id, element); else videosRef.current.delete(clip.id) }}
                src={clip.previewUrl}
                playsInline
                preload="auto"
                onLoadedMetadata={(event) => {
                  event.currentTarget.pause()
                  event.currentTarget.currentTime = Math.min(clip.startTimeMs / 1000 + coverTimeMs / 1000, Math.max(0, event.currentTarget.duration - .04))
                }}
                style={videoStyle(clip, index)}
              />
              <span className="slot-replace-copy">拖入替换</span>
              {slot.id === selectedSlotId && <button className="slot-clear-button" aria-label={`清空${slotLabel(slot.id)}`} onPointerDown={(event) => event.stopPropagation()} onClick={(event) => { event.stopPropagation(); onClearSlot(slot.id) }}><CloseIcon /></button>}
              </>}
              {isPointerTarget && <span className="slot-drop-target-copy">松开 · {clip ? '替换画面' : '放入画面'}</span>}
            </div>
          })}
        </div>
        <div className="live-badge"><LiveIcon /> LIVE</div>
        <div className="cover-mark"><span /> {playing ? '同步播放' : settledOnCover ? `Live 关键帧 ${(coverTimeMs / 1000).toFixed(1)}s` : '预览已暂停'}</div>
      </div>
      <div className="preview-controls">
        <button className="round-button" onClick={togglePlayback} aria-label={playing ? '暂停预览' : '播放预览'}>
          {playing ? <PauseIcon /> : <PlayIcon />}
        </button>
        <div className="preview-scrubber">
          <div className="keyframe-timeline" style={{ '--keyframe-position': `${coverTimeMs / 30}%` } as CSSProperties}>
            <span className="timeline-ruler" aria-hidden="true" />
            <i style={{ transform: `scaleX(${playhead})` }} />
            <span className="keyframe-handle" aria-hidden="true"><b>关键帧 · {(coverTimeMs / 1000).toFixed(1)}s</b></span>
            <input type="range" min="0" max="2900" step="100" value={coverTimeMs} aria-label="Live Photo 关键帧" onChange={(event) => setCoverFrame(Number(event.target.value))} />
          </div>
          <small>播放结束后停留在关键帧</small>
        </div>
        <span>{(playhead * 3).toFixed(1)} / 3.0s</span>
      </div>
      <p className="canvas-hint">拖动画面移动位置 · 拖动进度条标记 Live 关键帧</p>
    </div>
  )
}
