import { useEffect, useLayoutEffect, useRef, useState, type KeyboardEvent, type PointerEvent as ReactPointerEvent, type WheelEvent } from 'react'
import type { SlotClip, VideoClip } from '../domain'
import { formatDuration, MAXIMUM_OUTPUT_DURATION_MS, MINIMUM_OUTPUT_DURATION_MS, sourceContentDurationMs, sourcePaddingDurationMs } from '../domain'
import { FilmIcon } from '../icons'
import { aspectFillSourceRect } from '../mediaGeometry'
import {
  clampTimelineStartMs,
  resizeTimelineSelection,
  scrollLeftPxForZoom,
  selectionGrabOffsetMs,
  timelineSelectionGeometry,
  timelineDurationNotice,
  timelineDragScrollSpeed,
  timelineSourceScale,
  timelineTimestampMsFromPointer,
  timelineTrackWidthPx,
  type TimelinePointerOptions,
  type TimelineDragMode,
} from './timelineGeometry'

interface Props {
  clip: VideoClip | SlotClip
  outputDurationMs: number
  onChange: (startTimeMs: number, durationMs: number, mode: TimelineDragMode) => void
  onEditingChange: (editing: boolean) => void
}

export function TimelineEmpty() {
  return (
    <section className="timeline-panel timeline-empty" aria-label="空时间线">
      <div className="timeline-heading">
        <div><span className="eyebrow">时间线</span><strong>未选中画面</strong></div>
        <span>选择画格后调节 Live 时长，最长 15 秒</span>
      </div>
      <div className="timeline-workbench">
        <div className="timeline-toolbar">
          <span>时间线缩放</span>
          <button aria-label="缩小时间线" disabled>−</button>
          <output>100%</output>
          <button aria-label="放大时间线" disabled>＋</button>
          <small>⌘ / Ctrl + 滚轮</small>
        </div>
        <div className="timeline-viewport timeline-empty-viewport" aria-hidden="true">
          <div className="timeline-empty-grid" />
          <div className="timeline-empty-guide"><FilmIcon /><span>选择画格，拖动选区两侧调节时长</span></div>
        </div>
      </div>
      <div className="timeline-scale"><span>0:00</span><span>—</span><span>—</span></div>
    </section>
  )
}

const MIN_ZOOM = 1
const MAX_ZOOM = 6
const FRAME_COUNT = 24
const timelineFrameCache = new Map<string, string[]>()
const MAX_CACHED_TIMELINES = 8

interface TimelineDragState {
  pointerId: number
  mode: TimelineDragMode
  options: TimelinePointerOptions
  grabOffsetMs: number
  startTimeMs: number
  durationMs: number
  lastValueMs: number
  lastDurationMs: number
  reportedLandmarks: Set<number>
  pointerDownClientX: number
  clientX: number
  clickedStartMs: number
  startedInsideSelection: boolean
  didDrag: boolean
}

const cacheTimelineFrames = (key: string, frames: string[]) => {
  timelineFrameCache.delete(key)
  timelineFrameCache.set(key, frames)
  if (timelineFrameCache.size > MAX_CACHED_TIMELINES) {
    const oldest = timelineFrameCache.keys().next().value
    if (oldest) timelineFrameCache.delete(oldest)
  }
}

export function Timeline({ clip, outputDurationMs, onChange, onEditingChange }: Props) {
  const [frames, setFrames] = useState<string[]>([])
  const [zoom, setZoom] = useState(1)
  const [isDragging, setIsDragging] = useState(false)
  const [visibleStartMs, setVisibleStartMs] = useState(0)
  const [durationNotice, setDurationNotice] = useState<{ message: string }>()
  const zoomRef = useRef(zoom)
  const viewportRef = useRef<HTMLDivElement>(null)
  const dragRef = useRef<TimelineDragState | undefined>(undefined)
  const pendingScrollLeftRef = useRef<number | undefined>(undefined)
  const applyDragRef = useRef<(drag: TimelineDragState) => void>(() => {})
  const frameCount = FRAME_COUNT

  useEffect(() => {
    if (!durationNotice) return
    const timer = window.setTimeout(() => setDurationNotice(undefined), 1800)
    return () => window.clearTimeout(timer)
  }, [durationNotice])

  useEffect(() => { zoomRef.current = zoom }, [zoom])

  useEffect(() => () => onEditingChange(false), [onEditingChange])

  useEffect(() => {
    if (!isDragging) return
    let frame = 0
    let previous = performance.now()
    const scroll = (now: number) => {
      const drag = dragRef.current
      const viewport = viewportRef.current
      if (!drag || !viewport) return
      const elapsed = Math.min(32, now - previous) / 1000
      previous = now
      if (drag.didDrag) {
        const rect = viewport.getBoundingClientRect()
        const speed = timelineDragScrollSpeed(drag.clientX, rect.left, viewport.clientWidth)
        const atBound = drag.mode === 'move'
          ? (speed < 0 ? drag.lastValueMs <= 0 : drag.lastValueMs >= clip.durationMs - MINIMUM_OUTPUT_DURATION_MS)
          : drag.mode === 'trailing'
            ? (speed < 0 ? drag.lastDurationMs <= MINIMUM_OUTPUT_DURATION_MS : drag.lastDurationMs >= MAXIMUM_OUTPUT_DURATION_MS)
            : (speed < 0 ? drag.lastValueMs <= 0 || drag.lastDurationMs >= MAXIMUM_OUTPUT_DURATION_MS : drag.lastDurationMs <= MINIMUM_OUTPUT_DURATION_MS || drag.lastValueMs >= clip.durationMs - MINIMUM_OUTPUT_DURATION_MS)
        if (speed && !atBound) {
          viewport.scrollLeft += speed * elapsed
          applyDragRef.current(drag)
        }
      }
      frame = requestAnimationFrame(scroll)
    }
    frame = requestAnimationFrame(scroll)
    return () => cancelAnimationFrame(frame)
  }, [isDragging, clip.durationMs])

  useLayoutEffect(() => {
    const viewport = viewportRef.current
    const pendingScrollLeft = pendingScrollLeftRef.current
    if (!viewport || pendingScrollLeft === undefined) return
    viewport.scrollLeft = pendingScrollLeft
    pendingScrollLeftRef.current = undefined
  }, [zoom])

  useEffect(() => {
    let disposed = false
    const cacheKey = `${clip.previewUrl}:${clip.durationMs}:${FRAME_COUNT}:aspect-fill-v2`
    const cached = timelineFrameCache.get(cacheKey)
    if (cached) {
      timelineFrameCache.delete(cacheKey)
      timelineFrameCache.set(cacheKey, cached)
      setFrames(cached)
      return
    }
    setFrames([])
    const video = document.createElement('video')
    video.src = clip.previewUrl
    video.muted = true
    video.preload = 'auto'
    const waitForSeek = () => new Promise<void>((resolve) => video.addEventListener('seeked', () => resolve(), { once: true }))
    const capture = async () => {
      const results: string[] = []
      const canvas = document.createElement('canvas')
      canvas.width = 160; canvas.height = 90
      const context = canvas.getContext('2d')
      if (!context) return
      for (let index = 0; index < frameCount; index++) {
        if (disposed) return
        const moment = Math.max(.01, (clip.durationMs / 1000) * (index / Math.max(1, frameCount - 1)))
        video.currentTime = moment
        await waitForSeek()
        const source = aspectFillSourceRect(video.videoWidth, video.videoHeight, canvas.width, canvas.height)
        context.clearRect(0, 0, canvas.width, canvas.height)
        context.drawImage(video, source.x, source.y, source.width, source.height, 0, 0, canvas.width, canvas.height)
        results.push(canvas.toDataURL('image/jpeg', 0.55))
      }
      if (!disposed) {
        cacheTimelineFrames(cacheKey, results)
        setFrames(results)
      }
    }
    video.addEventListener('loadeddata', () => { void capture() }, { once: true })
    return () => { disposed = true; video.src = '' }
  }, [clip.id, clip.durationMs, clip.previewUrl])

  const maxStart = Math.max(0, clip.durationMs - MINIMUM_OUTPUT_DURATION_MS)
  const dragTimelineDurationMs = clip.durationMs + MAXIMUM_OUTPUT_DURATION_MS - MINIMUM_OUTPUT_DURATION_MS
  const timelineDurationMs = isDragging ? dragTimelineDurationMs : Math.max(clip.durationMs, clip.startTimeMs + outputDurationMs)
  const trackZoom = timelineSourceScale(clip.durationMs, timelineDurationMs, zoom)
  const selectionGeometry = timelineSelectionGeometry({
    trackWidthPx: 1,
    durationMs: timelineDurationMs,
    startTimeMs: clip.startTimeMs,
    selectionDurationMs: outputDurationMs,
  })
  const left = selectionGeometry.leftPercent
  const width = selectionGeometry.widthPercent
  const trackWidthPercent = timelineTrackWidthPx({ viewportWidthPx: 100, zoom: trackZoom })
  const contentDurationMs = sourceContentDurationMs(clip.durationMs, clip.startTimeMs, outputDurationMs)
  const paddingDurationMs = sourcePaddingDurationMs(clip.durationMs, clip.startTimeMs, outputDurationMs)
  const endTimeMs = clip.startTimeMs + outputDurationMs
  const selectionDescription = paddingDurationMs
    ? `${formatDuration(clip.startTimeMs)} — ${formatDuration(clip.startTimeMs + contentDurationMs)} · 末帧补齐 ${formatDuration(paddingDurationMs)}`
    : `${formatDuration(clip.startTimeMs)} — ${formatDuration(endTimeMs)}`
  const updateZoom = (next: number, anchorOffsetPx?: number) => {
    if (dragRef.current) return
    const previousZoom = zoomRef.current
    const nextZoom = Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, Number(next.toFixed(2))))
    if (nextZoom === previousZoom) return
    const viewport = viewportRef.current
    if (viewport) {
      pendingScrollLeftRef.current = scrollLeftPxForZoom({
        scrollLeftPx: pendingScrollLeftRef.current ?? viewport.scrollLeft,
        viewportWidthPx: viewport.clientWidth,
        previousZoom: timelineSourceScale(clip.durationMs, timelineDurationMs, previousZoom),
        nextZoom: timelineSourceScale(clip.durationMs, timelineDurationMs, nextZoom),
        anchorOffsetPx,
      })
    }
    zoomRef.current = nextZoom
    setZoom(nextZoom)
  }
  const handleWheel = (event: WheelEvent<HTMLDivElement>) => {
    if (!event.metaKey && !event.ctrlKey) return
    event.preventDefault()
    const delta = Math.max(-40, Math.min(40, event.deltaY))
    const rect = event.currentTarget.getBoundingClientRect()
    updateZoom(zoomRef.current * Math.exp(-delta * 0.002), event.clientX - rect.left)
  }

  const pointerOptions = (clientX: number): TimelinePointerOptions | undefined => {
    const viewport = viewportRef.current
    if (!viewport) return undefined
    const rect = viewport.getBoundingClientRect()
    const viewportWidthPx = viewport.clientWidth || rect.width
    if (viewportWidthPx <= 0) return undefined
    return {
      clientX,
      viewportLeftPx: rect.left,
      viewportWidthPx,
      scrollLeftPx: viewport.scrollLeft,
      zoom: timelineSourceScale(clip.durationMs, dragTimelineDurationMs, zoomRef.current),
      durationMs: dragTimelineDurationMs,
      selectionDurationMs: outputDurationMs,
    }
  }

  const beginSelectionDrag = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (!event.isPrimary || event.button !== 0) return
    const options = pointerOptions(event.clientX)
    if (!options) return
    const edge = (event.target as HTMLElement).closest<HTMLElement>('[data-timeline-edge]')?.dataset.timelineEdge
    const mode: TimelineDragMode = edge === 'leading' || edge === 'trailing' ? edge : 'move'
    const timestampMs = timelineTimestampMsFromPointer(options)
    const currentStartMs = clip.startTimeMs
    const visibleSelectionEndMs = currentStartMs + outputDurationMs
    const isInsideSelection = timestampMs >= currentStartMs && timestampMs <= visibleSelectionEndMs
    const grabOffsetMs = mode === 'leading' ? timestampMs - clip.startTimeMs
      : mode === 'trailing' ? timestampMs - endTimeMs
        : isInsideSelection ? selectionGrabOffsetMs(timestampMs, currentStartMs, outputDurationMs) : 0
    const clickedStartMs = clampTimelineStartMs(timestampMs, clip.durationMs, MINIMUM_OUTPUT_DURATION_MS)
    const nextStartMs = mode !== 'move' || isInsideSelection
      ? currentStartMs
      : clickedStartMs

    event.preventDefault()
    event.currentTarget.setPointerCapture(event.pointerId)
    dragRef.current = {
      pointerId: event.pointerId,
      mode,
      options,
      grabOffsetMs,
      startTimeMs: nextStartMs,
      durationMs: outputDurationMs,
      lastValueMs: nextStartMs,
      lastDurationMs: outputDurationMs,
      reportedLandmarks: new Set(),
      pointerDownClientX: event.clientX,
      clientX: event.clientX,
      clickedStartMs,
      startedInsideSelection: isInsideSelection,
      didDrag: false,
    }
    setIsDragging(true)
    onEditingChange(true)
    if (nextStartMs !== clip.startTimeMs) onChange(nextStartMs, outputDurationMs, 'move')
  }

  const applySelectionDrag = (drag: TimelineDragState) => {
    const options = { ...drag.options, clientX: drag.clientX, scrollLeftPx: viewportRef.current?.scrollLeft ?? drag.options.scrollLeftPx }
    if (drag.mode === 'move') {
      const nextStartMs = clampTimelineStartMs(timelineTimestampMsFromPointer(options) - drag.grabOffsetMs, clip.durationMs, MINIMUM_OUTPUT_DURATION_MS)
      if (nextStartMs === drag.lastValueMs) return
      drag.lastValueMs = nextStartMs
      onChange(nextStartMs, drag.durationMs, 'move')
      return
    }
    const next = resizeTimelineSelection({
      edge: drag.mode,
      timestampMs: timelineTimestampMsFromPointer(options) - drag.grabOffsetMs,
      startTimeMs: drag.startTimeMs,
      selectionDurationMs: drag.durationMs,
      sourceDurationMs: clip.durationMs,
    })
    const message = timelineDurationNotice(drag.lastDurationMs, next.selectionDurationMs, next.requestedDurationMs, drag.reportedLandmarks)
    if (message) setDurationNotice({ message })
    if (next.startTimeMs === drag.lastValueMs && next.selectionDurationMs === drag.lastDurationMs) return
    drag.lastValueMs = next.startTimeMs
    drag.lastDurationMs = next.selectionDurationMs
    onChange(next.startTimeMs, next.selectionDurationMs, drag.mode)
  }
  applyDragRef.current = applySelectionDrag

  const moveSelectionDrag = (event: ReactPointerEvent<HTMLDivElement>) => {
    const drag = dragRef.current
    if (!drag || drag.pointerId !== event.pointerId) return
    event.preventDefault()
    drag.clientX = event.clientX
    if (!drag.didDrag) {
      if (Math.abs(event.clientX - drag.pointerDownClientX) < 2) return
      drag.didDrag = true
    }
    applySelectionDrag(drag)
  }

  const endSelectionDrag = (event: ReactPointerEvent<HTMLDivElement>, commitClick: boolean) => {
    const drag = dragRef.current
    if (!drag || drag.pointerId !== event.pointerId) return
    if (commitClick && drag.didDrag) {
      drag.clientX = event.clientX
      applySelectionDrag(drag)
    }
    dragRef.current = undefined
    setIsDragging(false)
    onEditingChange(false)
    if (commitClick && drag.mode === 'move' && drag.startedInsideSelection && !drag.didDrag && drag.clickedStartMs !== drag.lastValueMs) {
      onChange(drag.clickedStartMs, drag.durationMs, 'move')
    }
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId)
    }
  }

  const resizeFromKeyboard = (event: KeyboardEvent<HTMLSpanElement>, edge: 'leading' | 'trailing') => {
    const currentMs = edge === 'leading' ? clip.startTimeMs : endTimeMs
    const direction = event.key === 'ArrowLeft' || event.key === 'ArrowDown' ? -1 : event.key === 'ArrowRight' || event.key === 'ArrowUp' ? 1 : 0
    const timestampMs = event.key === 'Home' ? (edge === 'leading' ? endTimeMs - MAXIMUM_OUTPUT_DURATION_MS : clip.startTimeMs + MINIMUM_OUTPUT_DURATION_MS)
      : event.key === 'End' ? (edge === 'leading' ? endTimeMs - MINIMUM_OUTPUT_DURATION_MS : clip.startTimeMs + MAXIMUM_OUTPUT_DURATION_MS)
        : direction ? currentMs + direction * (event.shiftKey ? 1000 : 100) : undefined
    if (timestampMs === undefined) return
    event.preventDefault()
    const next = resizeTimelineSelection({ edge, timestampMs, startTimeMs: clip.startTimeMs, selectionDurationMs: outputDurationMs, sourceDurationMs: clip.durationMs })
    const message = timelineDurationNotice(outputDurationMs, next.selectionDurationMs, next.requestedDurationMs, new Set())
    if (message && !event.repeat) setDurationNotice({ message })
    onChange(next.startTimeMs, next.selectionDurationMs, edge)
  }

  return (
    <section className="timeline-panel">
      <div className="timeline-heading">
        <div><span className="eyebrow">当前片段</span><strong>{clip.name}</strong></div>
        <span>{selectionDescription}</span>
      </div>
      <div className="timeline-workbench">
        {durationNotice && <div className="timeline-duration-toast" role="status">{durationNotice.message}</div>}
        <div className="timeline-toolbar">
          <span title="选区整体平移；拖动两侧手柄调节所有画格的 Live 时长">两侧调节时长 · 1–15 秒</span>
          <button aria-label="缩小时间线" disabled={isDragging || zoom <= MIN_ZOOM} onClick={() => updateZoom(zoom - .25)}>−</button>
          <output>{Math.round(zoom * 100)}%</output>
          <button aria-label="放大时间线" disabled={isDragging || zoom >= MAX_ZOOM} onClick={() => updateZoom(zoom + .25)}>＋</button>
          <small>⌘ / Ctrl + 滚轮</small>
        </div>
        <div className="timeline-viewport" ref={viewportRef} onWheel={handleWheel} onScroll={(event) => {
          const viewport = event.currentTarget
          setVisibleStartMs(viewport.clientWidth ? viewport.scrollLeft / (viewport.clientWidth * zoomRef.current) * clip.durationMs : 0)
        }}>
          <div
            className={`filmstrip${isDragging ? ' is-dragging' : ''}`}
            style={{ width: `${trackWidthPercent}%`, gridTemplateColumns: `repeat(${frameCount}, minmax(0, 1fr))` }}
            onPointerDown={beginSelectionDrag}
            onPointerMove={moveSelectionDrag}
            onPointerUp={(event) => endSelectionDrag(event, true)}
            onPointerCancel={(event) => endSelectionDrag(event, false)}
            onLostPointerCapture={(event) => endSelectionDrag(event, false)}
          >
            <div className="filmstrip-frames" style={{ width: `${clip.durationMs / timelineDurationMs * 100}%`, gridTemplateColumns: `repeat(${frameCount}, minmax(0, 1fr))` }}>
              {frames.length ? frames.map((frame, index) => <img src={frame} alt="" draggable={false} key={index} />) : Array.from({ length: frameCount }, (_, index) => <i key={index} />)}
            </div>
            {timelineDurationMs > clip.durationMs && <div className="timeline-padding" style={{ left: `${clip.durationMs / timelineDurationMs * 100}%` }} aria-hidden="true"><span>末帧补齐</span></div>}
            <div className="selection-window" style={{ left: `${left}%`, width: `${width}%` }}>
              <b>{(outputDurationMs / 1000).toFixed(1)} 秒{paddingDurationMs ? ' · 补帧' : ''}</b>
              <span className="timeline-trim-handle leading" data-timeline-edge="leading" role="slider" tabIndex={0} aria-label="片段左侧手柄" aria-valuemin={Math.max(0, endTimeMs - MAXIMUM_OUTPUT_DURATION_MS)} aria-valuemax={Math.min(endTimeMs - MINIMUM_OUTPUT_DURATION_MS, clip.durationMs - MINIMUM_OUTPUT_DURATION_MS)} aria-valuenow={clip.startTimeMs} aria-valuetext={`起点 ${formatDuration(clip.startTimeMs)}，时长 ${(outputDurationMs / 1000).toFixed(1)} 秒`} onKeyDown={(event) => resizeFromKeyboard(event, 'leading')} />
              <span className="timeline-trim-handle trailing" data-timeline-edge="trailing" role="slider" tabIndex={0} aria-label="片段右侧手柄" aria-valuemin={clip.startTimeMs + MINIMUM_OUTPUT_DURATION_MS} aria-valuemax={clip.startTimeMs + MAXIMUM_OUTPUT_DURATION_MS} aria-valuenow={endTimeMs} aria-valuetext={`终点 ${formatDuration(endTimeMs)}，时长 ${(outputDurationMs / 1000).toFixed(1)} 秒`} onKeyDown={(event) => resizeFromKeyboard(event, 'trailing')} />
            </div>
            <input
              className="timeline-range-input"
              style={{ left: `${left}%` }}
              aria-label="片段起点"
              aria-valuetext={selectionDescription}
              type="range"
              min={0}
              max={maxStart}
              step={100}
              value={clampTimelineStartMs(clip.startTimeMs, clip.durationMs, MINIMUM_OUTPUT_DURATION_MS)}
              onChange={(event) => onChange(clampTimelineStartMs(Number(event.target.value), clip.durationMs, MINIMUM_OUTPUT_DURATION_MS), outputDurationMs, 'move')}
            />
          </div>
        </div>
      </div>
      <div className="timeline-scale"><span>{formatDuration(visibleStartMs)}</span><span>{formatDuration(visibleStartMs + clip.durationMs / zoom / 2)}</span><span>{formatDuration(visibleStartMs + clip.durationMs / zoom)}</span></div>
    </section>
  )
}
