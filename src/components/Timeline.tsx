import { useEffect, useMemo, useRef, useState, type WheelEvent } from 'react'
import type { SlotClip, VideoClip } from '../domain'
import { formatDuration } from '../domain'

interface Props {
  clip: VideoClip | SlotClip
  onChange: (startTimeMs: number) => void
}

const MIN_ZOOM = 1
const MAX_ZOOM = 6

export function Timeline({ clip, onChange }: Props) {
  const [frames, setFrames] = useState<string[]>([])
  const [zoom, setZoom] = useState(1)
  const zoomRef = useRef(zoom)
  const viewportRef = useRef<HTMLDivElement>(null)
  const frameCount = useMemo(() => Math.min(48, Math.round(10 * zoom)), [zoom])

  useEffect(() => { zoomRef.current = zoom }, [zoom])

  useEffect(() => {
    let disposed = false
    const video = document.createElement('video')
    video.src = clip.previewUrl
    video.muted = true
    video.preload = 'metadata'
    const waitForSeek = () => new Promise<void>((resolve) => video.addEventListener('seeked', () => resolve(), { once: true }))
    const capture = async () => {
      const results: string[] = []
      const canvas = document.createElement('canvas')
      canvas.width = 160; canvas.height = 90
      const context = canvas.getContext('2d')
      if (!context) return
      for (let index = 0; index < frameCount; index++) {
        const moment = Math.max(.01, (clip.durationMs / 1000) * (index / Math.max(1, frameCount - 1)))
        video.currentTime = moment
        await waitForSeek()
        context.drawImage(video, 0, 0, canvas.width, canvas.height)
        results.push(canvas.toDataURL('image/jpeg', 0.55))
      }
      if (!disposed) setFrames(results)
    }
    video.addEventListener('loadedmetadata', () => { void capture() }, { once: true })
    return () => { disposed = true; video.src = '' }
  }, [clip.id, clip.durationMs, clip.previewUrl, frameCount])

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
            <input aria-label="片段起点" type="range" min={0} max={maxStart} step={100} value={Math.min(clip.startTimeMs, maxStart)} onChange={(event) => onChange(Number(event.target.value))} />
          </div>
        </div>
      </div>
      <div className="timeline-scale"><span>0:00</span><span>{formatDuration(clip.durationMs / 2)}</span><span>{formatDuration(clip.durationMs)}</span></div>
    </section>
  )
}
