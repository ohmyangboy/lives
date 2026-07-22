import { useEffect, useRef, useState, type WheelEvent } from 'react'
import type { SlotClip, VideoClip } from '../domain'
import { formatDuration } from '../domain'
import { FilmIcon } from '../icons'
import { aspectFillSourceRect } from '../mediaGeometry'

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
  const zoomRef = useRef(zoom)
  const viewportRef = useRef<HTMLDivElement>(null)
  const frameCount = FRAME_COUNT

  useEffect(() => { zoomRef.current = zoom }, [zoom])

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

  const maxStart = Math.max(0, clip.durationMs - 3000)
  const left = clip.durationMs ? (clip.startTimeMs / clip.durationMs) * 100 : 0
  const width = clip.durationMs ? Math.min(100, (3000 / clip.durationMs) * 100) : 100
  const updateZoom = (next: number) => setZoom(Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, Number(next.toFixed(2)))))
  const handleWheel = (event: WheelEvent<HTMLDivElement>) => {
    if (!event.metaKey && !event.ctrlKey) return
    event.preventDefault()
    const delta = Math.max(-40, Math.min(40, event.deltaY))
    updateZoom(zoomRef.current * Math.exp(-delta * 0.002))
  }

  return (
    <section className="timeline-panel">
      <div className="timeline-heading">
        <div><span className="eyebrow">当前片段</span><strong>{clip.name}</strong></div>
        <span>{formatDuration(clip.startTimeMs)} — {formatDuration(clip.startTimeMs + 3000)}</span>
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
          <div className="filmstrip" style={{ width: `${zoom * 100}%`, gridTemplateColumns: `repeat(${frameCount}, minmax(86px, 1fr))` }}>
            {frames.length ? frames.map((frame, index) => <img src={frame} alt="" key={index} />) : Array.from({ length: frameCount }, (_, index) => <i key={index} />)}
            <div className="selection-window" style={{ left: `${left}%`, width: `${width}%` }}><b>3.0 秒</b></div>
            <input aria-label="片段起点" aria-valuetext={`${formatDuration(clip.startTimeMs)} 到 ${formatDuration(clip.startTimeMs + 3000)}`} type="range" min={0} max={maxStart} step={100} value={Math.min(clip.startTimeMs, maxStart)} onChange={(event) => onChange(Number(event.target.value))} />
          </div>
        </div>
      </div>
      <div className="timeline-scale"><span>0:00</span><span>{formatDuration(clip.durationMs / 2)}</span><span>{formatDuration(clip.durationMs)}</span></div>
    </section>
  )
}
