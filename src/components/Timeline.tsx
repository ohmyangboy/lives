import { useEffect, useLayoutEffect, useRef, useState, type PointerEvent as ReactPointerEvent, type WheelEvent } from 'react'
import type { SlotClip, VideoClip } from '../domain'
import { formatDuration, OUTPUT_DURATION_MS, sourceContentDurationMs, sourcePaddingDurationMs } from '../domain'
import { FilmIcon } from '../icons'
import { aspectFillSourceRect } from '../mediaGeometry'
import {
  clampTimelineStartMs,
  scrollLeftPxForZoom,
  selectionGrabOffsetMs,
  timelineSelectionGeometry,
  timelineStartMsFromPointer,
  timelineTimestampMsFromPointer,
  timelineTrackWidthPx,
  type TimelinePointerOptions,
} from './timelineGeometry'

interface Props {
  clip: VideoClip | SlotClip
  onChange: (startTimeMs: number) => void
}

export function TimelineEmpty() {
  return (
    <section className="timeline-panel timeline-empty" aria-label="空时间线">
      <div className="timeline-heading">
        <div><span className="eyebrow">时间线</span><strong>未选中画面</strong></div>
        <span>选择画格后编辑其 3 秒片段</span>
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
          <div className="timeline-empty-guide"><FilmIcon /><span>点击预览中的任一画格，在这里截取 3 秒片段</span></div>
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
  grabOffsetMs: number
  lastValueMs: number
  pointerDownClientX: number
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

export function Timeline({ clip, onChange }: Props) {
  const [frames, setFrames] = useState<string[]>([])
  const [zoom, setZoom] = useState(1)
  const [isDragging, setIsDragging] = useState(false)
  const zoomRef = useRef(zoom)
  const viewportRef = useRef<HTMLDivElement>(null)
  const dragRef = useRef<TimelineDragState | undefined>(undefined)
  const pendingScrollLeftRef = useRef<number | undefined>(undefined)
  const frameCount = FRAME_COUNT

  useEffect(() => { zoomRef.current = zoom }, [zoom])

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

  const maxStart = Math.max(0, clip.durationMs - OUTPUT_DURATION_MS)
  const selectionGeometry = timelineSelectionGeometry({
    trackWidthPx: 1,
    durationMs: clip.durationMs,
    startTimeMs: clip.startTimeMs,
    selectionDurationMs: OUTPUT_DURATION_MS,
  })
  const left = selectionGeometry.leftPercent
  const width = selectionGeometry.widthPercent
  const trackWidthPercent = timelineTrackWidthPx({ viewportWidthPx: 100, zoom })
  const contentDurationMs = sourceContentDurationMs(clip.durationMs, clip.startTimeMs)
  const paddingDurationMs = sourcePaddingDurationMs(clip.durationMs, clip.startTimeMs)
  const selectionDescription = paddingDurationMs
    ? `${formatDuration(clip.startTimeMs)} — ${formatDuration(clip.startTimeMs + contentDurationMs)} · 末帧补齐 ${formatDuration(paddingDurationMs)}`
    : `${formatDuration(clip.startTimeMs)} — ${formatDuration(clip.startTimeMs + OUTPUT_DURATION_MS)}`
  const updateZoom = (next: number, anchorOffsetPx?: number) => {
    const previousZoom = zoomRef.current
    const nextZoom = Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, Number(next.toFixed(2))))
    if (nextZoom === previousZoom) return
    const viewport = viewportRef.current
    if (viewport) {
      pendingScrollLeftRef.current = scrollLeftPxForZoom({
        scrollLeftPx: pendingScrollLeftRef.current ?? viewport.scrollLeft,
        viewportWidthPx: viewport.clientWidth,
        previousZoom,
        nextZoom,
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
      zoom: zoomRef.current,
      durationMs: clip.durationMs,
      selectionDurationMs: OUTPUT_DURATION_MS,
    }
  }

  const beginSelectionDrag = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (!event.isPrimary || event.button !== 0) return
    const options = pointerOptions(event.clientX)
    if (!options) return
    const timestampMs = timelineTimestampMsFromPointer(options)
    const currentStartMs = clampTimelineStartMs(clip.startTimeMs, clip.durationMs, OUTPUT_DURATION_MS)
    const visibleSelectionEndMs = Math.min(clip.durationMs, currentStartMs + OUTPUT_DURATION_MS)
    const isInsideSelection = timestampMs >= currentStartMs && timestampMs <= visibleSelectionEndMs
    const grabOffsetMs = isInsideSelection
      ? selectionGrabOffsetMs(timestampMs, currentStartMs, OUTPUT_DURATION_MS)
      : 0
    const nextStartMs = isInsideSelection
      ? currentStartMs
      : timelineStartMsFromPointer(options)

    event.preventDefault()
    event.currentTarget.setPointerCapture(event.pointerId)
    dragRef.current = {
      pointerId: event.pointerId,
      grabOffsetMs,
      lastValueMs: nextStartMs,
      pointerDownClientX: event.clientX,
      clickedStartMs: timelineStartMsFromPointer(options),
      startedInsideSelection: isInsideSelection,
      didDrag: false,
    }
    setIsDragging(true)
    if (nextStartMs !== currentStartMs) onChange(nextStartMs)
  }

  const moveSelectionDrag = (event: ReactPointerEvent<HTMLDivElement>) => {
    const drag = dragRef.current
    if (!drag || drag.pointerId !== event.pointerId) return
    const options = pointerOptions(event.clientX)
    if (!options) return
    event.preventDefault()
    if (!drag.didDrag) {
      if (Math.abs(event.clientX - drag.pointerDownClientX) < 2) return
      drag.didDrag = true
    }
    const nextStartMs = timelineStartMsFromPointer({ ...options, grabOffsetMs: drag.grabOffsetMs })
    if (nextStartMs === drag.lastValueMs) return
    drag.lastValueMs = nextStartMs
    onChange(nextStartMs)
  }

  const endSelectionDrag = (event: ReactPointerEvent<HTMLDivElement>, commitClick: boolean) => {
    const drag = dragRef.current
    if (!drag || drag.pointerId !== event.pointerId) return
    dragRef.current = undefined
    setIsDragging(false)
    if (commitClick && drag.startedInsideSelection && !drag.didDrag && drag.clickedStartMs !== drag.lastValueMs) {
      onChange(drag.clickedStartMs)
    }
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId)
    }
  }

  return (
    <section className="timeline-panel">
      <div className="timeline-heading">
        <div><span className="eyebrow">当前片段</span><strong>{clip.name}</strong></div>
        <span>{selectionDescription}</span>
      </div>
      <div className="timeline-workbench">
        <div className="timeline-toolbar">
          <span>时间线缩放</span>
          <button aria-label="缩小时间线" disabled={zoom <= MIN_ZOOM} onClick={() => updateZoom(zoom - .25)}>−</button>
          <output>{Math.round(zoom * 100)}%</output>
          <button aria-label="放大时间线" disabled={zoom >= MAX_ZOOM} onClick={() => updateZoom(zoom + .25)}>＋</button>
          <small>⌘ / Ctrl + 滚轮</small>
        </div>
        <div className="timeline-viewport" ref={viewportRef} onWheel={handleWheel}>
          <div
            className={`filmstrip${isDragging ? ' is-dragging' : ''}`}
            style={{ width: `${trackWidthPercent}%`, gridTemplateColumns: `repeat(${frameCount}, minmax(0, 1fr))` }}
            onPointerDown={beginSelectionDrag}
            onPointerMove={moveSelectionDrag}
            onPointerUp={(event) => endSelectionDrag(event, true)}
            onPointerCancel={(event) => endSelectionDrag(event, false)}
            onLostPointerCapture={(event) => endSelectionDrag(event, false)}
          >
            {frames.length ? frames.map((frame, index) => <img src={frame} alt="" draggable={false} key={index} />) : Array.from({ length: frameCount }, (_, index) => <i key={index} />)}
            <div className="selection-window" style={{ left: `${left}%`, width: `${width}%` }}><b>{paddingDurationMs ? `${formatDuration(contentDurationMs)} + 补帧` : '3.0 秒'}</b></div>
            <input
              className="timeline-range-input"
              style={{ left: `${left}%` }}
              aria-label="片段起点"
              aria-valuetext={selectionDescription}
              type="range"
              min={0}
              max={maxStart}
              step={100}
              value={clampTimelineStartMs(clip.startTimeMs, clip.durationMs, OUTPUT_DURATION_MS)}
              onChange={(event) => onChange(clampTimelineStartMs(Number(event.target.value), clip.durationMs, OUTPUT_DURATION_MS))}
            />
          </div>
        </div>
      </div>
      <div className="timeline-scale"><span>0:00</span><span>{formatDuration(clip.durationMs / 2)}</span><span>{formatDuration(clip.durationMs)}</span></div>
    </section>
  )
}
