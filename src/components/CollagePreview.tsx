import { useEffect, useMemo, useRef, useState, type CSSProperties, type PointerEvent as ReactPointerEvent, type WheelEvent as ReactWheelEvent } from 'react'
import { CUSTOM_RATIO_BOUNDS, maximumCoverTimeMs, simplifyRatio, type CollageTemplate, type SlotClip } from '../domain'
import { CloseIcon, CollapseIcon, ExpandIcon, LiveIcon, PlusIcon, SoundIcon } from '../icons'
import { FilmKeyframeControl } from './FilmKeyframeControl'
import { previewPlaybackKey, PreviewHoldGesture, PreviewReplayScheduler } from './previewPlayback'

interface Props {
  clips: Array<SlotClip | undefined>
  template: CollageTemplate
  canvasWidth: number
  canvasHeight: number
  selectedSlotId?: string
  selectedSourceId?: string
  pointerDropTargetSlotId?: string
  isSourceDragging?: boolean
  isTimelineEditing?: boolean
  coverTimeMs: number
  outputDurationMs: number
  customRatio?: { width: number; height: number }
  onCanvasRatioChange?: (ratio: { width: number; height: number }) => void
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

// 四角比例手柄：18px 圆点跨在画布角上（配合 .canvas-shell.ratio-editable 放开裁切）
const RATIO_HANDLE_CORNERS = ['nw', 'ne', 'sw', 'se'] as const
const ratioHandleStyle: Record<(typeof RATIO_HANDLE_CORNERS)[number], CSSProperties> = {
  nw: { top: -9, left: -9 },
  ne: { top: -9, right: -9 },
  sw: { bottom: -9, left: -9 },
  se: { bottom: -9, right: -9 },
}

export function CollagePreview({ clips, template, canvasWidth, canvasHeight, selectedSlotId, selectedSourceId, pointerDropTargetSlotId, isSourceDragging, isTimelineEditing, coverTimeMs, outputDurationMs, customRatio, onCanvasRatioChange, onSelectSlot, onCropChange, onScaleChange, onClearSlot, onAudioEnabledChange, onDropSource, onCoverTimeChange }: Props) {
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
  const playbackSequenceRef = useRef(0)
  const dragRef = useRef<{ slotId: string; x: number; y: number; cropX: number; cropY: number } | undefined>(undefined)
  const canvasShellRef = useRef<HTMLDivElement>(null)
  const ratioDragRef = useRef<{ pointerId: number; centerX: number; centerY: number; ratio0: number; dx0: number; dy0: number } | undefined>(undefined)
  const [playing, setPlaying] = useState(false)
  const [playhead, setPlayhead] = useState(0)
  const [settledOnCover, setSettledOnCover] = useState(true)
  const [settlingOnCover, setSettlingOnCover] = useState(false)
  const [prefersReducedMotion, setPrefersReducedMotion] = useState(false)
  const [maximumCanvasHeight, setMaximumCanvasHeight] = useState(360)
  const [dropTargetSlotId, setDropTargetSlotId] = useState<string>()
  const [isRatioDragging, setIsRatioDragging] = useState(false)
  const [isCropDragging, setIsCropDragging] = useState(false)
  const [isCoverEditing, setIsCoverEditing] = useState(false)
  const [isHoldingPreview, setIsHoldingPreview] = useState(false)
  const [mediaReadyRevision, setMediaReadyRevision] = useState(0)
  const startPlaybackRef = useRef<() => void>(() => {})
  const stopPlaybackRef = useRef<() => void>(() => {})
  const holdPointerRef = useRef<number | undefined>(undefined)
  const holdGestureRef = useRef<PreviewHoldGesture | undefined>(undefined)
  if (!holdGestureRef.current) holdGestureRef.current = new PreviewHoldGesture(
    () => { setIsHoldingPreview(true); startPlaybackRef.current() },
    () => { setIsHoldingPreview(false); stopPlaybackRef.current() },
  )
  const holdGesture = holdGestureRef.current
  const replaySchedulerRef = useRef<PreviewReplayScheduler | undefined>(undefined)
  if (!replaySchedulerRef.current) replaySchedulerRef.current = new PreviewReplayScheduler(() => startPlaybackRef.current())
  const replayScheduler = replaySchedulerRef.current
  const isEditing = Boolean(isTimelineEditing || isSourceDragging || isRatioDragging || isCropDragging || isCoverEditing)
  const [isFullscreen, setIsFullscreen] = useState(false)
  const clipsKey = useMemo(() => clips.filter((clip): clip is SlotClip => Boolean(clip)).map((clip) => `${clip.id}:${clip.previewUrl}:${clip.startTimeMs}:${clip.coverTimeMs}`).join('|'), [clips])
  const playbackKey = useMemo(() => previewPlaybackKey(clips, template, canvasWidth, canvasHeight, outputDurationMs), [clips, template, canvasWidth, canvasHeight, outputDurationMs])
  const coverTimeForClip = (clip: SlotClip) => clip.coverTimeMs ?? 1500
  const selectedClip = clips.find((clip) => clip?.targetSlotId === selectedSlotId)
  const coverClip = selectedClip ?? clips.find(Boolean)
  const maximumCoverMs = coverClip ? maximumCoverTimeMs(coverClip.durationMs, coverClip.startTimeMs, outputDurationMs) : outputDurationMs - 100
  const outputDurationSeconds = outputDurationMs / 1000
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
    video.currentTime = Math.min(clip.startTimeMs / 1000, Math.max(0, video.duration - .04))
  }

  const seekToOffset = (offsetSeconds?: number, targetSlotId?: string) => {
    clips.forEach((clip) => {
      if (!clip) return
      const video = videosRef.current.get(clip.id)
      if (!video) return
      if (video.readyState >= 1) {
        video.pause()
        const offset = offsetSeconds !== undefined
          ? (targetSlotId ? (clip.targetSlotId === targetSlotId ? offsetSeconds : coverTimeForClip(clip) / 1000) : offsetSeconds)
          : coverTimeForClip(clip) / 1000
        video.currentTime = Math.min(clip.startTimeMs / 1000 + offset, Math.max(0, video.duration - .04))
      }
    })
  }

  const seekCoverVideosToOffset = (offsetSeconds?: number, targetSlotId?: string) => {
    clips.forEach((clip) => {
      if (!clip) return
      const video = coverVideosRef.current.get(clip.id)
      if (!video || video.readyState < 1) return
      video.pause()
      const offset = offsetSeconds !== undefined
        ? (targetSlotId ? (clip.targetSlotId === targetSlotId ? offsetSeconds : coverTimeForClip(clip) / 1000) : offsetSeconds)
        : coverTimeForClip(clip) / 1000
      video.currentTime = Math.min(clip.startTimeMs / 1000 + offset, Math.max(0, video.duration - .04))
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
    const pointerId = holdPointerRef.current
    holdGesture.clear()
    holdPointerRef.current = undefined
    if (pointerId !== undefined && stageRef.current?.hasPointerCapture(pointerId)) stageRef.current.releasePointerCapture(pointerId)
    setIsHoldingPreview(false)
    playbackSequenceRef.current += 1
    cancelCoverSettle()
    setPlaying(false)
    setSettledOnCover(true)
    setPlayhead(coverTimeMs / outputDurationMs)
    seekToOffset()
    seekCoverVideosToOffset()
  }, [selectedSlotId, clipsKey, coverTimeMs, outputDurationMs, playbackKey, isEditing])

  useEffect(() => {
    const filledClips = clips.filter((clip): clip is SlotClip => Boolean(clip))
    const ready = filledClips.length > 0 && filledClips.every((clip) => (videosRef.current.get(clip.id)?.readyState ?? 0) >= 2)
    replayScheduler.update(playbackKey, isEditing, ready)
    return () => replayScheduler.clearTimer()
  }, [playbackKey, isEditing, mediaReadyRevision, replayScheduler])

  useEffect(() => () => replayScheduler.cancel(), [replayScheduler])

  useEffect(() => {
    const cancelHold = () => holdGesture.cancel()
    window.addEventListener('blur', cancelHold)
    return () => { window.removeEventListener('blur', cancelHold); holdGesture.clear() }
  }, [holdGesture])

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
    playbackSequenceRef.current += 1
    settleSequenceRef.current += 1
    if (settleTimerRef.current !== undefined) window.clearTimeout(settleTimerRef.current)
    cancelAnimationFrame(settleFrameRef.current)
  }, [])

  const settleOnCover = (from = playhead) => {
    playbackSequenceRef.current += 1
    cancelCoverSettle()
    videosRef.current.forEach((video) => video.pause())
    setPlaying(false)
    setSettledOnCover(false)
    setSettlingOnCover(true)
    seekCoverVideosToOffset()

    const sequence = ++settleSequenceRef.current
    const duration = prefersReducedMotion ? 0 : COVER_SETTLE_DURATION_MS
    const to = coverTimeMs / outputDurationMs
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
      seekToOffset()
      setPlayhead(to)
      setSettlingOnCover(false)
      setSettledOnCover(true)
    }, duration)
  }
  stopPlaybackRef.current = settleOnCover

  useEffect(() => {
    if (!playing) {
      videosRef.current.forEach((video) => video.pause())
      return
    }
    const activeVideos = Array.from(videosRef.current.values())
    const tick = (now: number) => {
      const elapsed = (now - startedAtRef.current) / 1000
      const position = Math.min(elapsed, outputDurationSeconds)
      setPlayhead(position / outputDurationSeconds)
      if (elapsed >= outputDurationSeconds) {
        if (holdGesture.isActive) {
          startPlaybackRef.current()
          frameRef.current = requestAnimationFrame(tick)
        } else settleOnCover(1)
        return
      }
      frameRef.current = requestAnimationFrame(tick)
    }
    frameRef.current = requestAnimationFrame(tick)
    return () => { cancelAnimationFrame(frameRef.current); activeVideos.forEach((video) => video.pause()) }
  }, [playing, clips, coverTimeMs, prefersReducedMotion, outputDurationMs, holdGesture])

  const startPlayback = () => {
    if (!clips.some(Boolean)) return
    const sequence = ++playbackSequenceRef.current
    cancelCoverSettle()
    clips.forEach((clip) => {
      if (!clip) return
      const video = videosRef.current.get(clip.id)
      if (!video) return
      seekClipStart(video, clip)
      void video.play().catch(() => {
        if (sequence !== playbackSequenceRef.current) return
        setPlaying(false)
        setSettledOnCover(true)
        seekToOffset()
      })
    })
    startedAtRef.current = performance.now()
    setSettledOnCover(false)
    setPlaying(true)
  }
  startPlaybackRef.current = startPlayback

  const togglePlayback = () => {
    replayScheduler.cancel()
    holdGesture.clear()
    setIsHoldingPreview(false)
    if (playing) { settleOnCover(); return }
    startPlayback()
  }

  const beginPreviewHold = (event: ReactPointerEvent<HTMLDivElement>) => {
    const target = event.target as HTMLElement
    const blank = target === event.currentTarget || ['preview-controls', 'preview-scrubber', 'film-keyframe-control', 'source-monitor-bar'].some((name) => target.classList.contains(name))
    if (!blank || !event.isPrimary || event.button !== 0 || isEditing) return
    if (!clips.some(Boolean)) { onSelectSlot(undefined); return }
    event.preventDefault()
    replayScheduler.cancel()
    event.currentTarget.focus({ preventScroll: true })
    holdPointerRef.current = event.pointerId
    event.currentTarget.setPointerCapture(event.pointerId)
    holdGesture.begin(event.clientX, event.clientY)
  }
  const movePreviewHold = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (holdPointerRef.current === event.pointerId) holdGesture.move(event.clientX, event.clientY)
  }
  const endPreviewHold = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (holdPointerRef.current !== event.pointerId) return
    holdPointerRef.current = undefined
    let tap = false
    if (event.type === 'pointerup') tap = holdGesture.release()
    else holdGesture.cancel()
    if (event.currentTarget.hasPointerCapture(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId)
    if (tap) onSelectSlot(undefined)
  }

  const setCoverFrame = (milliseconds: number) => {
    const next = Math.max(0, Math.min(maximumCoverMs, Math.round(milliseconds / 100) * 100))
    const effectiveSlotId = coverClip?.targetSlotId
    if (selectedSlotId !== effectiveSlotId && effectiveSlotId) onSelectSlot(effectiveSlotId)
    cancelCoverSettle()
    setPlaying(false)
    setSettledOnCover(true)
    setPlayhead(next / outputDurationMs)
    seekToOffset(next / 1000, effectiveSlotId)
    seekCoverVideosToOffset(next / 1000, effectiveSlotId)
    onCoverTimeChange(next)
  }

  const canEditCanvasRatio = Boolean(onCanvasRatioChange && customRatio)

  const beginRatioDrag = (event: ReactPointerEvent<HTMLSpanElement>) => {
    if (!canEditCanvasRatio || !event.isPrimary || event.button !== 0) return
    const rect = canvasShellRef.current?.getBoundingClientRect()
    if (!rect || rect.width <= 0 || rect.height <= 0) return
    event.preventDefault()
    event.stopPropagation()
    const centerX = rect.left + rect.width / 2
    const centerY = rect.top + rect.height / 2
    event.currentTarget.setPointerCapture(event.pointerId)
    ratioDragRef.current = {
      pointerId: event.pointerId,
      centerX,
      centerY,
      ratio0: customRatio!.width / customRatio!.height,
      dx0: Math.max(10, Math.abs(event.clientX - centerX)),
      dy0: Math.max(10, Math.abs(event.clientY - centerY)),
    }
    setIsRatioDragging(true)
  }

  const moveRatioDrag = (event: ReactPointerEvent<HTMLSpanElement>) => {
    const drag = ratioDragRef.current
    if (!drag || drag.pointerId !== event.pointerId || !onCanvasRatioChange) return
    event.preventDefault()
    // 以画布中心为锚的增量式换算：横向拉伸变宽、纵向拉伸变高，起拖瞬间增量为 1，比例连续无跳变
    const stretchX = Math.abs(event.clientX - drag.centerX) / drag.dx0
    const stretchY = Math.max(.12, Math.abs(event.clientY - drag.centerY) / drag.dy0)
    const ratio = Math.max(CUSTOM_RATIO_BOUNDS.min, Math.min(CUSTOM_RATIO_BOUNDS.max, drag.ratio0 * stretchX / stretchY))
    onCanvasRatioChange(simplifyRatio({ width: Math.round(ratio * 100), height: 100 }))
  }

  const endRatioDrag = (event: ReactPointerEvent<HTMLSpanElement>) => {
    const drag = ratioDragRef.current
    if (!drag || drag.pointerId !== event.pointerId) return
    if (event.currentTarget.hasPointerCapture(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId)
    ratioDragRef.current = undefined
    setIsRatioDragging(false)
  }

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.code !== 'Space' || event.repeat || document.querySelector('[role="dialog"]:not(.preview-stage)')) return
      const target = event.target as HTMLElement | null
      if (target?.closest('button, a, input, textarea, select, [role="button"], [role="radio"], [role="slider"], [contenteditable="true"]')) return
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
    setIsCropDragging(true)
    dragRef.current = { slotId: template.slots[slotIndex].id, x: point.x, y: point.y, cropX: clip.crop.normalizedCenterX, cropY: clip.crop.normalizedCenterY }
  }

  const endCropDrag = () => {
    dragRef.current = undefined
    setIsCropDragging(false)
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
    <div ref={stageRef} className={`preview-stage${isFullscreen ? ' is-fullscreen' : ''}${isHoldingPreview ? ' is-holding-preview' : ''}`} data-playback={playing ? 'playing' : settlingOnCover ? 'settling' : settledOnCover ? 'cover' : 'paused'}
      role={isFullscreen ? 'dialog' : 'region'} aria-modal={isFullscreen || undefined} aria-label={isFullscreen ? '全屏拼贴预览' : '拼贴预览，按住空白处播放'}
      tabIndex={clips.some(Boolean) ? 0 : -1} aria-keyshortcuts="Space"
      onPointerDown={beginPreviewHold} onPointerMove={movePreviewHold} onPointerUp={endPreviewHold} onPointerCancel={endPreviewHold} onLostPointerCapture={endPreviewHold}>
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
      <div ref={canvasShellRef} className={`canvas-shell${canEditCanvasRatio ? ' ratio-editable' : ''}${isRatioDragging ? ' ratio-dragging' : ''}`} style={{ aspectRatio: `${canvasWidth} / ${canvasHeight}`, width: `min(88%, ${isFullscreen ? 1100 : 500}px, ${(maximumCanvasHeight * canvasWidth / canvasHeight).toFixed(1)}px)` }}>
        <div className="collage-canvas" onPointerDown={pointerDown} onPointerMove={pointerMove} onPointerUp={endCropDrag} onPointerCancel={endCropDrag} onLostPointerCapture={endCropDrag} onWheel={handleWheel}>
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
                onLoadedData={() => setMediaReadyRevision((current) => current + 1)}
                onSeeked={() => setMediaReadyRevision((current) => current + 1)}
                onLoadedMetadata={(event) => {
                  event.currentTarget.pause()
                  event.currentTarget.currentTime = Math.min(clip.startTimeMs / 1000 + coverTimeForClip(clip) / 1000, Math.max(0, event.currentTarget.duration - .04))
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
                  event.currentTarget.currentTime = Math.min(clip.startTimeMs / 1000 + coverTimeForClip(clip) / 1000, Math.max(0, event.currentTarget.duration - .04))
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
        {canEditCanvasRatio && <>
          {RATIO_HANDLE_CORNERS.map((corner) => <span
            key={corner}
            className={`canvas-ratio-handle ${corner}${isRatioDragging ? ' active' : ''}`}
            style={ratioHandleStyle[corner]}
            aria-hidden="true"
            onPointerDown={beginRatioDrag}
            onPointerMove={moveRatioDrag}
            onPointerUp={endRatioDrag}
            onPointerCancel={endRatioDrag}
            onLostPointerCapture={endRatioDrag}
          />)}
          {isRatioDragging && customRatio && <output className="canvas-ratio-badge">{customRatio.width} : {customRatio.height}</output>}
        </>}
      </div>
      <div ref={previewControlsRef} className="preview-controls">
        <div className="preview-scrubber">
          <FilmKeyframeControl clip={coverClip} coverTimeMs={coverTimeMs} maximumCoverMs={maximumCoverMs} outputDurationMs={outputDurationMs}
            playhead={playhead} reducedMotion={prefersReducedMotion} onChange={setCoverFrame} onEditingChange={setIsCoverEditing} />
          <small>{settlingOnCover ? '正在柔和过渡到关键帧' : isHoldingPreview ? '松手回到关键帧' : playing ? '同步播放 · 结束后停留在关键帧' : '按住空白处预览 · Shift 拖动精细调节'}</small>
        </div>
      </div>
      <p ref={canvasHintRef} className="canvas-hint">拖动画面移动位置 · 拖动观片器设置 Live 关键帧</p>
    </div>
  )
}
