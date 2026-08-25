import { useEffect, useMemo, useRef, useState, type CSSProperties, type PointerEvent as ReactPointerEvent, type WheelEvent as ReactWheelEvent } from 'react'
import type { CollageTemplate, SlotClip } from '../domain'
import { CloseIcon, CollapseIcon, ExpandIcon, LiveIcon, PauseIcon, PlayIcon, PlusIcon, SoundIcon } from '../icons'

interface Props {
  clips: Array<SlotClip | undefined>
  template: CollageTemplate
  canvasWidth: number
  canvasHeight: number
  selectedSlotId?: string
  selectedSourceId?: string
  pointerDropTargetSlotId?: string
  isSourceDragging?: boolean
  coverTimeMs: number
  onSelectSlot: (slotId: string | undefined) => void
  onCropChange: (slotId: string, x: number, y: number) => void
  onScaleChange: (slotId: string, scale: number) => void
  onClearSlot: (slotId: string) => void
  onAudioEnabledChange: (slotId: string, audioEnabled: boolean) => void
  onDropSource: (slotId: string, sourceClipId: string) => void
  onCoverTimeChange: (milliseconds: number) => void
}

const MIN_SCALE = 1
const MAX_SCALE = 3
const COVER_SETTLE_DURATION_MS = 380

export function CollagePreview({ clips, template, canvasWidth, canvasHeight, selectedSlotId, selectedSourceId, pointerDropTargetSlotId, isSourceDragging, coverTimeMs, onSelectSlot, onCropChange, onScaleChange, onClearSlot, onAudioEnabledChange, onDropSource, onCoverTimeChange }: Props) {
  const videosRef = useRef<Map<string, HTMLVideoElement>>(new Map())
  const coverVideosRef = useRef<Map<string, HTMLVideoElement>>(new Map())
  const stageRef = useRef<HTMLDivElement>(null)
  const sourceMonitorRef = useRef<HTMLDivElement>(null)
  const previewControlsRef = useRef<HTMLDivElement>(null)
  const canvasHintRef = useRef<HTMLParagraphElement>(null)
  const frameRef = useRef(0)
  const settleFrameRef = useRef(0)
  const settleTimerRef = useRef<number | undefined>(undefined)
  const settleSequenceRef = useRef(0)
  const startedAtRef = useRef(0)
  const dragRef = useRef<{ slotId: string; x: number; y: number; cropX: number; cropY: number } | undefined>(undefined)
  const keyframeTimelineRef = useRef<HTMLDivElement>(null)
  const coverFrameDragRef = useRef<{ pointerId: number; grabOffsetX: number; lastValue: number } | undefined>(undefined)
  const [playing, setPlaying] = useState(false)
  const [playhead, setPlayhead] = useState(0)
  const [settledOnCover, setSettledOnCover] = useState(true)
  const [settlingOnCover, setSettlingOnCover] = useState(false)
  const [prefersReducedMotion, setPrefersReducedMotion] = useState(false)
  const [isCoverFrameDragging, setIsCoverFrameDragging] = useState(false)
  const [maximumCanvasHeight, setMaximumCanvasHeight] = useState(360)
  const [dropTargetSlotId, setDropTargetSlotId] = useState<string>()
  const [isFullscreen, setIsFullscreen] = useState(false)
  const clipsKey = useMemo(() => clips.filter((clip): clip is SlotClip => Boolean(clip)).map((clip) => `${clip.id}:${clip.previewUrl}:${clip.startTimeMs}`).join('|'), [clips])
  const selectedClip = clips.find((clip) => clip?.targetSlotId === selectedSlotId)
  const enabledAudioCount = clips.filter((clip) => clip?.audioEnabled).length
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
    // Add a tiny 0.2% bleed to eliminate subpixel rounding gaps in CSS layout
    const renderedWidth = baseWidth * clip.crop.scale * 1.002
    const renderedHeight = baseHeight * clip.crop.scale * 1.002
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

  const seekCoverVideosToOffset = (offsetSeconds: number) => {
    clips.forEach((clip) => {
      if (!clip) return
      const video = coverVideosRef.current.get(clip.id)
      if (!video || video.readyState < 1) return
      video.pause()
      video.currentTime = Math.min(clip.startTimeMs / 1000 + offsetSeconds, Math.max(0, video.duration - .04))
    })
  }

  const cancelCoverSettle = () => {
    settleSequenceRef.current += 1
    if (settleTimerRef.current !== undefined) {
      window.clearTimeout(settleTimerRef.current)
      settleTimerRef.current = undefined
    }
    cancelAnimationFrame(settleFrameRef.current)
    setSettlingOnCover(false)
  }

  useEffect(() => {
    cancelCoverSettle()
    setPlaying(false)
    setSettledOnCover(true)
    setPlayhead(coverTimeMs / 3000)
    seekToOffset(coverTimeMs / 1000)
    seekCoverVideosToOffset(coverTimeMs / 1000)
  }, [selectedSlotId, clipsKey, coverTimeMs])

  useEffect(() => {
    const media = window.matchMedia('(prefers-reduced-motion: reduce)')
    const update = () => setPrefersReducedMotion(media.matches)
    update()
    media.addEventListener('change', update)
    return () => media.removeEventListener('change', update)
  }, [])

  useEffect(() => {
    clips.forEach((clip) => {
      if (!clip) return
      const video = videosRef.current.get(clip.id)
      if (!video) return
      video.muted = !clip.audioEnabled
      video.volume = enabledAudioCount > 1 ? 0.58 : 1
    })
  }, [clips, enabledAudioCount])

  useEffect(() => {
    const stage = stageRef.current
    if (!stage) return
    const outerHeight = (element: HTMLElement | null) => {
      if (!element) return 0
      const style = window.getComputedStyle(element)
      const marginTop = Number.parseFloat(style.marginTop) || 0
      const marginBottom = Number.parseFloat(style.marginBottom) || 0
      return element.getBoundingClientRect().height + marginTop + marginBottom
    }
    const update = () => {
      const style = window.getComputedStyle(stage)
      const paddingTop = Number.parseFloat(style.paddingTop) || 0
      const paddingBottom = Number.parseFloat(style.paddingBottom) || 0
      const reservedHeight = paddingTop + paddingBottom
        + outerHeight(sourceMonitorRef.current)
        + outerHeight(previewControlsRef.current)
        + outerHeight(canvasHintRef.current)
      setMaximumCanvasHeight(Math.max(180, Math.floor(stage.clientHeight - reservedHeight)))
    }
    update()
    const observer = new ResizeObserver(update)
    observer.observe(stage)
    if (sourceMonitorRef.current) observer.observe(sourceMonitorRef.current)
    if (previewControlsRef.current) observer.observe(previewControlsRef.current)
    if (canvasHintRef.current) observer.observe(canvasHintRef.current)
    return () => observer.disconnect()
  }, [isFullscreen])

  useEffect(() => () => {
    settleSequenceRef.current += 1
    if (settleTimerRef.current !== undefined) window.clearTimeout(settleTimerRef.current)
    cancelAnimationFrame(settleFrameRef.current)
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
        setPlaying(false)
        setSettledOnCover(false)
        setSettlingOnCover(true)
        seekCoverVideosToOffset(coverTimeMs / 1000)

        const sequence = ++settleSequenceRef.current
        const duration = prefersReducedMotion ? 0 : COVER_SETTLE_DURATION_MS
        const from = 1
        const to = coverTimeMs / 3000
        const started = performance.now()
        const animatePlayhead = (timestamp: number) => {
          if (sequence !== settleSequenceRef.current) return
          const progress = duration ? Math.min(1, (timestamp - started) / duration) : 1
          const eased = 1 - Math.pow(1 - progress, 3)
          setPlayhead(from + (to - from) * eased)
          if (progress < 1) settleFrameRef.current = requestAnimationFrame(animatePlayhead)
        }
        settleFrameRef.current = requestAnimationFrame(animatePlayhead)
        settleTimerRef.current = window.setTimeout(() => {
          if (sequence !== settleSequenceRef.current) return
          settleTimerRef.current = undefined
          seekToOffset(coverTimeMs / 1000)
          setPlayhead(to)
          setSettlingOnCover(false)
          setSettledOnCover(true)
        }, duration)
        return
      }
      frameRef.current = requestAnimationFrame(tick)
    }
    frameRef.current = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(frameRef.current)
  }, [playing, clips, coverTimeMs, prefersReducedMotion])

  const togglePlayback = () => {
    if (!clips.some(Boolean)) return
    cancelCoverSettle()
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
    cancelCoverSettle()
    setPlaying(false)
    setSettledOnCover(true)
    setPlayhead(next / 3000)
    seekToOffset(next / 1000)
    seekCoverVideosToOffset(next / 1000)
    onCoverTimeChange(next)
  }

  const setCoverFrameFromPointer = (clientX: number, grabOffsetX = 0) => {
    const rect = keyframeTimelineRef.current?.getBoundingClientRect()
    if (!rect || rect.width <= 0) return
    const position = Math.max(0, Math.min(1, (clientX - grabOffsetX - rect.left) / rect.width))
    const next = Math.max(0, Math.min(2900, Math.round((position * 2900) / 100) * 100))
    if (coverFrameDragRef.current?.lastValue === next) return
    if (coverFrameDragRef.current) coverFrameDragRef.current.lastValue = next
    setCoverFrame(next)
  }

  const beginCoverFrameDrag = (event: ReactPointerEvent<HTMLSpanElement>) => {
    if (!event.isPrimary || event.button !== 0) return
    const rect = keyframeTimelineRef.current?.getBoundingClientRect()
    if (!rect) return
    const handleX = rect.left + (coverTimeMs / 2900) * rect.width
    event.preventDefault()
    event.currentTarget.setPointerCapture(event.pointerId)
    coverFrameDragRef.current = {
      pointerId: event.pointerId,
      grabOffsetX: event.clientX - handleX,
      lastValue: coverTimeMs,
    }
    setIsCoverFrameDragging(true)
  }

  const moveCoverFrameDrag = (event: ReactPointerEvent<HTMLSpanElement>) => {
    const drag = coverFrameDragRef.current
    if (!drag || drag.pointerId !== event.pointerId) return
    event.preventDefault()
    setCoverFrameFromPointer(event.clientX, drag.grabOffsetX)
  }

  const endCoverFrameDrag = (event: ReactPointerEvent<HTMLSpanElement>) => {
    const drag = coverFrameDragRef.current
    if (!drag || drag.pointerId !== event.pointerId) return
    if (event.currentTarget.hasPointerCapture(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId)
    coverFrameDragRef.current = undefined
    setIsCoverFrameDragging(false)
  }

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.code !== 'Space' || event.repeat || document.querySelector('[role="dialog"]:not(.preview-stage)')) return
      const target = event.target as HTMLElement | null
      if (target?.closest('button, a, input, textarea, select, [role="button"], [role="radio"], [contenteditable="true"]')) return
      event.preventDefault()
      togglePlayback()
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [playing, clipsKey])

  useEffect(() => {
    if (!isFullscreen) return
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return
      event.preventDefault()
      setIsFullscreen(false)
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [isFullscreen])

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
    <div ref={stageRef} className={isFullscreen ? 'preview-stage is-fullscreen' : 'preview-stage'} role={isFullscreen ? 'dialog' : undefined} aria-modal={isFullscreen || undefined} aria-label={isFullscreen ? '全屏拼贴预览' : undefined} onPointerDown={(event) => { if (event.target === event.currentTarget) onSelectSlot(undefined) }}>
      <div ref={sourceMonitorRef} className="source-monitor-bar">
        <div className="source-monitor-label"><span /> 拼贴预览 · {selectedClip ? `正在调整${slotLabel(selectedClip.targetSlotId)}` : clips.some(Boolean) ? '点击画格继续调整' : '把素材拖入画面格'}</div>
        <div className="source-monitor-actions">
          {selectedClip && <div className="composition-toolbar" aria-label="当前画面构图工具">
            <button onClick={() => changeSelectedScale(-.1)} disabled={selectedClip.crop.scale <= MIN_SCALE} aria-label="缩小画面">−</button>
            <output>{Math.round(selectedClip.crop.scale * 100)}%</output>
            <button onClick={() => changeSelectedScale(.1)} disabled={selectedClip.crop.scale >= MAX_SCALE} aria-label="放大画面">＋</button>
            <button className="reset-crop" onClick={() => { onCropChange(selectedClip.targetSlotId, .5, .5); onScaleChange(selectedClip.targetSlotId, 1) }}>居中</button>
          </div>}
          <button className="preview-fullscreen-button" aria-label={isFullscreen ? '退出全屏预览' : '全屏预览'} aria-pressed={isFullscreen} title={isFullscreen ? '退出全屏预览（Esc）' : '全屏预览'} onClick={() => setIsFullscreen((current) => !current)}>{isFullscreen ? <CollapseIcon /> : <ExpandIcon />}</button>
        </div>
      </div>
      <div className="canvas-shell" style={{ aspectRatio: `${canvasWidth} / ${canvasHeight}`, width: `min(88%, ${isFullscreen ? 1100 : 500}px, ${(maximumCanvasHeight * canvasWidth / canvasHeight).toFixed(1)}px)` }}>
        <div className="collage-canvas" onPointerDown={pointerDown} onPointerMove={pointerMove} onPointerUp={() => { dragRef.current = undefined }} onPointerCancel={() => { dragRef.current = undefined }} onWheel={handleWheel}>
          {template.slots.map((slot, index) => {
            const clip = clips[index]
            const isPointerTarget = slot.id === pointerDropTargetSlotId
            const slotClassName = ['collage-slot', !clip && 'empty', slot.id === selectedSlotId && clip && 'selected', settlingOnCover && clip && 'settling-to-cover', isSourceDragging && 'drop-ready', (slot.id === dropTargetSlotId || isPointerTarget) && 'drop-target'].filter(Boolean).join(' ')
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
            return <div
              key={slot.id}
              role="button"
              tabIndex={0}
              aria-pressed={slot.id === selectedSlotId}
              aria-label={`${slotLabel(slot.id)}，${clip ? `已放入 ${clip.name}` : '空画格'}`}
              data-collage-slot-id={slot.id}
              className={slotClassName}
              style={slotStyle}
              onKeyDown={(event) => {
                if (event.target !== event.currentTarget) return
                if (event.key === 'Enter' || event.key === ' ') {
                  event.preventDefault()
                  if (clip) onSelectSlot(slot.id)
                  else if (selectedSourceId) onDropSource(slot.id, selectedSourceId)
                  return
                }
                if ((event.key === 'Delete' || event.key === 'Backspace') && clip) {
                  event.preventDefault()
                  onClearSlot(slot.id)
                  return
                }
                if (!clip || !['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(event.key)) return
                event.preventDefault()
                const step = event.shiftKey ? .05 : .015
                const nextX = event.key === 'ArrowLeft' ? clip.crop.normalizedCenterX - step : event.key === 'ArrowRight' ? clip.crop.normalizedCenterX + step : clip.crop.normalizedCenterX
                const nextY = event.key === 'ArrowUp' ? clip.crop.normalizedCenterY - step : event.key === 'ArrowDown' ? clip.crop.normalizedCenterY + step : clip.crop.normalizedCenterY
                onCropChange(slot.id, Math.max(0, Math.min(1, nextX)), Math.max(0, Math.min(1, nextY)))
              }}
              onDragOver={(event) => { event.preventDefault(); event.dataTransfer.dropEffect = 'copy'; setDropTargetSlotId(slot.id) }}
              onDragLeave={() => setDropTargetSlotId((current) => current === slot.id ? undefined : current)}
              onDrop={(event) => { event.preventDefault(); const sourceClipId = event.dataTransfer.getData('application/x-livecollage-source'); setDropTargetSlotId(undefined); if (sourceClipId) onDropSource(slot.id, sourceClipId) }}
            >
              {!clip ? <div className="slot-drop-copy"><PlusIcon /><strong>{isPointerTarget ? '松开放入' : '拖入视频'}</strong><small>{isPointerTarget ? '将素材放进这个格子' : template.slots.length === 1 ? '开始构图' : '可重复使用素材'}</small></div> : <>
              <video
                className="motion-preview-video"
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
              <video
                className="cover-frame-video"
                ref={(element) => { if (element) coverVideosRef.current.set(clip.id, element); else coverVideosRef.current.delete(clip.id) }}
                src={clip.previewUrl}
                muted
                playsInline
                preload="auto"
                aria-hidden="true"
                tabIndex={-1}
                onLoadedMetadata={(event) => {
                  event.currentTarget.pause()
                  event.currentTarget.currentTime = Math.min(clip.startTimeMs / 1000 + coverTimeMs / 1000, Math.max(0, event.currentTarget.duration - .04))
                }}
                style={videoStyle(clip, index)}
              />
              <span className="slot-replace-copy">拖入替换</span>
              {slot.id === selectedSlotId && <div className="slot-context-actions">
                <button className={clip.audioEnabled ? 'slot-audio-button enabled' : 'slot-audio-button'} aria-label={`${clip.audioEnabled ? '关闭' : '开启'}${slotLabel(slot.id)}原声`} aria-pressed={clip.audioEnabled === true} title={clip.audioEnabled ? '关闭原声' : '开启原声'} onPointerDown={(event) => event.stopPropagation()} onClick={(event) => { event.stopPropagation(); onAudioEnabledChange(slot.id, !clip.audioEnabled) }}><SoundIcon /></button>
                <button className="slot-clear-button" aria-label={`清空${slotLabel(slot.id)}`} title="清空画面" onPointerDown={(event) => event.stopPropagation()} onClick={(event) => { event.stopPropagation(); onClearSlot(slot.id) }}><CloseIcon /></button>
              </div>}
              </>}
              {isPointerTarget && <span className="slot-drop-target-copy">松开 · {clip ? '替换画面' : '放入画面'}</span>}
            </div>
          })}
        </div>
        <div className="live-badge"><LiveIcon /> LIVE</div>
        <div className="cover-mark"><span /> {playing ? '同步播放' : settlingOnCover ? '正在回到关键帧' : settledOnCover ? `Live 关键帧 ${(coverTimeMs / 1000).toFixed(1)}s` : '预览已暂停'}</div>
      </div>
      <div ref={previewControlsRef} className="preview-controls">
        <button className="round-button" onClick={togglePlayback} aria-label={playing ? '暂停预览' : '播放预览'}>
          {playing ? <PauseIcon /> : <PlayIcon />}
        </button>
        <div className="preview-scrubber">
          <div ref={keyframeTimelineRef} className={`keyframe-timeline${isCoverFrameDragging ? ' is-dragging' : ''}`} style={{ '--keyframe-position': `${coverTimeMs / 30}%` } as CSSProperties}>
            <span className="timeline-ruler" aria-hidden="true" />
            <i style={{ transform: `scaleX(${playhead})` }} />
            <span className="keyframe-handle" aria-hidden="true">
              <span
                className="keyframe-handle-hit-target"
                onPointerDown={beginCoverFrameDrag}
                onPointerMove={moveCoverFrameDrag}
                onPointerUp={endCoverFrameDrag}
                onPointerCancel={endCoverFrameDrag}
                onLostPointerCapture={endCoverFrameDrag}
              />
              <b>关键帧 · {(coverTimeMs / 1000).toFixed(1)}s</b>
            </span>
            <input
              className="keyframe-range-input"
              type="range"
              min="0"
              max="2900"
              step="100"
              value={coverTimeMs}
              aria-label="Live Photo 关键帧"
              onChange={(event) => setCoverFrame(Number(event.target.value))}
            />
          </div>
          <small>{settlingOnCover ? '正在柔和过渡到关键帧' : '播放结束后渐变停留在关键帧'}</small>
        </div>
        <span>{(playhead * 3).toFixed(1)} / 3.0s</span>
      </div>
      <p ref={canvasHintRef} className="canvas-hint">拖动画面移动位置 · 拖动进度条标记 Live 关键帧</p>
    </div>
  )
}
