import { useEffect, useRef, useState, type CSSProperties, type KeyboardEvent, type PointerEvent } from 'react'
import type { SlotClip } from '../domain'
import { FilmObjectModel } from './FilmObjectModel'
import { FILM_IMPORT_DURATION_MS, FILM_SWAP_DURATION_MS, filmKeyframeMotion, fineKeyframeTimeFromPointer, keyframeSelectionKey, keyframeTimeFromPointer, normalizeKeyframeTime } from './filmKeyframeGeometry'

interface Props {
  clip?: SlotClip
  coverTimeMs: number
  maximumCoverMs: number
  outputDurationMs: number
  playhead: number
  reducedMotion: boolean
  onChange: (milliseconds: number) => void
  onEditingChange: (editing: boolean) => void
}

interface Selection { key: string; clip?: SlotClip; coverTimeMs: number; maximumCoverMs: number; outputDurationMs: number }
type Phase = 'empty' | 'rewinding' | 'swapping' | 'unrolling' | 'ready'
interface FilmSnapshot { selection: Selection; frames: string[] }
const FRAME_COUNT = 10
const frameCache = new Map<string, string[]>()

function useFilmFrames(clip: SlotClip | undefined, outputDurationMs: number) {
  const [result, setResult] = useState<{ key: string; frames: string[] }>({ key: '', frames: [] })
  const key = clip ? `${clip.previewUrl}:${clip.startTimeMs}:${outputDurationMs}` : ''
  useEffect(() => {
    if (!clip) return
    const cached = frameCache.get(key)
    if (cached) { setResult({ key, frames: cached }); return }
    const controller = new AbortController()
    const video = document.createElement('video')
    video.muted = true
    video.playsInline = true
    video.crossOrigin = 'anonymous'
    video.preload = 'auto'
    const waitFor = (name: 'loadeddata' | 'seeked') => new Promise<void>((resolve, reject) => {
      const clean = () => {
        window.clearTimeout(timeout)
        video.removeEventListener(name, done)
        video.removeEventListener('error', fail)
        controller.signal.removeEventListener('abort', fail)
      }
      const done = () => { clean(); resolve() }
      const fail = () => { clean(); reject(new Error('Film sample unavailable')) }
      const timeout = window.setTimeout(fail, 4000)
      video.addEventListener(name, done, { once: true })
      video.addEventListener('error', fail, { once: true })
      controller.signal.addEventListener('abort', fail, { once: true })
    })
    const capture = async () => {
      const loaded = waitFor('loadeddata')
      video.src = clip.previewUrl
      await loaded
      const canvas = document.createElement('canvas')
      canvas.width = 80
      canvas.height = 56
      const context = canvas.getContext('2d')
      if (!context) return
      const frames: string[] = []
      let lastTime = -1
      for (let index = 0; index < FRAME_COUNT; index++) {
        controller.signal.throwIfAborted()
        const seconds = Math.min(clip.startTimeMs / 1000 + outputDurationMs / 1000 * index / (FRAME_COUNT - 1), Math.max(0, video.duration - .04))
        if (Math.abs(seconds - lastTime) > .001 && Math.abs(video.currentTime - seconds) > .001) {
          const seeked = waitFor('seeked')
          video.currentTime = seconds
          await seeked
        }
        lastTime = seconds
        const scale = Math.max(canvas.width / video.videoWidth, canvas.height / video.videoHeight)
        const width = video.videoWidth * scale
        const height = video.videoHeight * scale
        context.drawImage(video, (80 - width) / 2, (56 - height) / 2, width, height)
        frames.push(canvas.toDataURL('image/jpeg', .65))
      }
      if (controller.signal.aborted) return
      frameCache.set(key, frames)
      if (frameCache.size > 6) frameCache.delete(frameCache.keys().next().value!)
      setResult({ key, frames })
    }
    void capture().catch(() => { /* Keep the film substrate if decoding is unavailable. */ })
    return () => { controller.abort(); video.removeAttribute('src'); video.load() }
  }, [key])
  return result.key === key ? result.frames : []
}

export function FilmKeyframeControl({ clip, coverTimeMs, maximumCoverMs, outputDurationMs, playhead, reducedMotion, onChange, onEditingChange }: Props) {
  const selectionKey = keyframeSelectionKey(clip)
  const desired: Selection = { key: selectionKey, clip, coverTimeMs, maximumCoverMs, outputDurationMs }
  const desiredRef = useRef(desired)
  desiredRef.current = desired
  const [visual, setVisual] = useState(desired)
  const displayed = visual.key === selectionKey ? desired : visual
  const shownRef = useRef(displayed)
  if (visual.key === selectionKey) shownRef.current = displayed
  const frames = useFilmFrames(displayed.clip, displayed.outputDurationMs)
  const shownFramesRef = useRef<string[]>([])
  if (frames.length) shownFramesRef.current = frames
  const [outgoing, setOutgoing] = useState<FilmSnapshot>()
  const [phase, setPhase] = useState<Phase>('empty')
  const [progress, setProgress] = useState(0)
  const [swap, setSwap] = useState(1)
  const progressRef = useRef(0)
  const lastSelectionRef = useRef<string | undefined>(undefined)
  const [cartridgeReady, setCartridgeReady] = useState(false)
  const [loupeReady, setLoupeReady] = useState(false)
  const ready = cartridgeReady && loupeReady
  const [dragging, setDragging] = useState(false)
  const [fineTuning, setFineTuning] = useState(false)
  const rootRef = useRef<HTMLDivElement>(null)
  const trackRef = useRef<HTMLDivElement>(null)
  const axisRef = useRef<HTMLDivElement>(null)
  const viewerRef = useRef<HTMLDivElement>(null)
  const lensRef = useRef<HTMLVideoElement>(null)
  const desiredLensTimeRef = useRef(0)
  const dragRef = useRef<{ pointerId: number; offset: number; last: number; fine: boolean; anchorX: number; anchorMs: number } | undefined>(undefined)
  const [width, setWidth] = useState(300)

  useEffect(() => () => onEditingChange(false), [onEditingChange])

  useEffect(() => {
    const root = rootRef.current
    if (!root) return
    const observer = new ResizeObserver(() => setWidth(root.clientWidth))
    observer.observe(root)
    return () => observer.disconnect()
  }, [])

  useEffect(() => {
    if (!ready) return
    let cancelled = false
    let frame = 0
    const animate = (duration: number, update: (amount: number) => void, done: () => void) => {
      const started = performance.now()
      const tick = (now: number) => {
        if (cancelled) return
        const amount = Math.min(1, (now - started) / duration)
        update(amount)
        if (amount < 1) frame = requestAnimationFrame(tick)
        else done()
      }
      frame = requestAnimationFrame(tick)
    }
    const move = (amount: number) => { progressRef.current = amount; setProgress(amount) }
    const reveal = () => {
      if (cancelled) return
      const next = desiredRef.current
      setVisual(next)
      setOutgoing(undefined)
      setSwap(1)
      if (!next.clip) { move(0); setPhase('empty'); return }
      setPhase('unrolling')
      const from = progressRef.current
      animate(Math.max(1, FILM_IMPORT_DURATION_MS * (1 - from)), (amount) => move(from + (1 - from) * amount), () => setPhase('ready'))
    }
    const drag = dragRef.current
    if (drag) for (const element of [viewerRef.current, trackRef.current]) {
      if (element?.hasPointerCapture(drag.pointerId)) element.releasePointerCapture(drag.pointerId)
    }
    dragRef.current = undefined
    if (drag) onEditingChange(false)
    setDragging(false)
    setFineTuning(false)
    const before = shownRef.current
    const changed = lastSelectionRef.current !== selectionKey
    lastSelectionRef.current = selectionKey
    if (reducedMotion) {
      setVisual(desiredRef.current)
      setOutgoing(undefined)
      setSwap(1)
      move(clip ? 1 : 0)
      setPhase(clip ? 'ready' : 'empty')
    } else if (changed && before.clip && before.key !== selectionKey && progressRef.current > 0) {
      if (clip) {
        // Keep both 3D objects seated; the outgoing strip slides to the right.
        setOutgoing({ selection: before, frames: shownFramesRef.current })
        shownFramesRef.current = []
        setVisual(desiredRef.current)
        move(1)
        setSwap(0)
        setPhase('swapping')
        animate(FILM_SWAP_DURATION_MS, setSwap, () => { setOutgoing(undefined); setPhase('ready') })
      } else {
        setVisual(before)
        setOutgoing(undefined)
        setPhase('rewinding')
        const from = progressRef.current
        animate(FILM_IMPORT_DURATION_MS * from, (amount) => move(from * (1 - amount)), reveal)
      }
    } else if (clip) reveal()
    else { move(0); setPhase('empty'); setVisual(desiredRef.current) }
    return () => { cancelled = true; cancelAnimationFrame(frame) }
  }, [selectionKey, reducedMotion, ready])

  const applyLensSeek = () => {
    const video = lensRef.current
    if (!video || video.readyState < 2 || video.seeking || !Number.isFinite(video.duration)) return
    const seconds = Math.min(desiredLensTimeRef.current, Math.max(0, video.duration - .04))
    if (Math.abs(video.currentTime - seconds) > .015) video.currentTime = seconds
  }
  useEffect(() => {
    desiredLensTimeRef.current = ((displayed.clip?.startTimeMs ?? 0) + displayed.coverTimeMs) / 1000
    const frame = requestAnimationFrame(applyLensSeek)
    return () => cancelAnimationFrame(frame)
  }, [displayed.key, displayed.clip?.startTimeMs, displayed.coverTimeMs])

  const enabled = Boolean(clip && phase === 'ready' && displayed.key === selectionKey)
  const update = (value: number) => {
    const next = normalizeKeyframeTime(value, maximumCoverMs)
    if (dragRef.current) {
      if (dragRef.current.last === next) return
      dragRef.current.last = next
    }
    onChange(next)
  }
  const beginDrag = (event: PointerEvent<HTMLDivElement>) => {
    if (!enabled || !event.isPrimary || event.button !== 0) return
    const track = axisRef.current?.getBoundingClientRect()
    if (!track?.width) return
    event.preventDefault()
    const onViewer = Boolean((event.target as HTMLElement).closest('.film-keyframe-viewer'))
    const value = onViewer ? coverTimeMs : keyframeTimeFromPointer(event.clientX, track.left, track.width, outputDurationMs, maximumCoverMs)
    viewerRef.current?.focus({ preventScroll: true })
    event.currentTarget.setPointerCapture(event.pointerId)
    dragRef.current = { pointerId: event.pointerId, offset: onViewer ? event.clientX - track.left - coverTimeMs / outputDurationMs * track.width : 0,
      last: -1, fine: event.shiftKey, anchorX: event.clientX, anchorMs: value }
    setDragging(true)
    onEditingChange(true)
    setFineTuning(event.shiftKey)
    update(value)
  }
  const moveDrag = (event: PointerEvent<HTMLDivElement>) => {
    const drag = dragRef.current
    const track = axisRef.current?.getBoundingClientRect()
    if (!drag || drag.pointerId !== event.pointerId || !track?.width) return
    event.preventDefault()
    if (drag.fine !== event.shiftKey) {
      drag.fine = event.shiftKey
      drag.anchorX = event.clientX
      drag.anchorMs = drag.last
      drag.offset = event.clientX - track.left - drag.last / outputDurationMs * track.width
      setFineTuning(event.shiftKey)
    }
    update(drag.fine
      ? fineKeyframeTimeFromPointer(event.clientX, drag.anchorX, drag.anchorMs, track.width, outputDurationMs, maximumCoverMs)
      : keyframeTimeFromPointer(event.clientX, track.left, track.width, outputDurationMs, maximumCoverMs, drag.offset))
  }
  const endDrag = (event: PointerEvent<HTMLDivElement>) => {
    if (dragRef.current?.pointerId !== event.pointerId) return
    dragRef.current = undefined
    if (event.currentTarget.hasPointerCapture(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId)
    setDragging(false)
    onEditingChange(false)
    setFineTuning(false)
  }
  const keyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (!enabled) return
    const step = event.shiftKey ? 500 : 100
    const next = event.key === 'Home' ? 0 : event.key === 'End' ? maximumCoverMs
      : ['ArrowLeft', 'ArrowDown'].includes(event.key) ? coverTimeMs - step
      : ['ArrowRight', 'ArrowUp'].includes(event.key) ? coverTimeMs + step : undefined
    if (next === undefined) return
    event.preventDefault()
    event.stopPropagation()
    update(next)
  }

  const motion = filmKeyframeMotion(progress, swap)
  const { seat, unroll, reveal } = motion
  const trackWidth = Math.max(1, width - 75)
  const contentWidth = Math.max(1, trackWidth - 23.5)
  const fraction = displayed.coverTimeMs / displayed.outputDurationMs
  const beforeFraction = outgoing ? outgoing.selection.coverTimeMs / outgoing.selection.outputDurationMs : fraction
  const targetX = 64 + (beforeFraction + (fraction - beforeFraction) * motion.swap) * contentWidth
  const emptyCenter = width / 2 + 6.5
  const viewerX = emptyCenter + 67 / 3 + (targetX - emptyCenter - 67 / 3) * unroll
  const reelX = (emptyCenter - 67 / 3 - 21) * (1 - seat) + 20 * seat
  const style = { '--film-reveal': unroll, '--viewer-reveal': reveal } as CSSProperties

  return <div ref={rootRef} className={`film-keyframe-control${dragging ? ' is-dragging' : ''}${fineTuning ? ' is-fine-tuning' : ''}`} data-phase={phase} style={style}>
    <div ref={trackRef} className="film-keyframe-strip-viewport"
      onPointerDown={beginDrag} onPointerMove={moveDrag} onPointerUp={endDrag} onPointerCancel={endDrag} onLostPointerCapture={endDrag}>
      <div ref={axisRef} className="film-keyframe-axis" />
      {outgoing && <FilmStrip snapshot={outgoing} className="is-outgoing" offset={motion.outgoingOffset * trackWidth} />}
      <div className="film-keyframe-incoming" style={{ clipPath: `inset(0 ${(1 - motion.incomingWidth) * 100}% 0 0)` }}>
        <FilmStrip snapshot={{ selection: displayed, frames }} offset={motion.incomingOffset * trackWidth} />
      </div>
      <i className="film-keyframe-playhead" style={{ left: `${playhead * 100}%` }} aria-hidden="true" />
    </div>
    <div className="film-keyframe-cartridge" style={{ left: reelX, transform: `scale(${.7 + seat * .3})` }}>
      <FilmObjectModel kind="cartridge" reveal={0} turn={0} tiltX={0} tiltY={0} onReady={() => setCartridgeReady(true)} />
    </div>
    <div ref={viewerRef} className="film-keyframe-viewer" style={{ left: viewerX, transform: `translate(-50%, -50%) scale(${dragging ? .7 : .6 + unroll * .03})` }}
      role="slider" tabIndex={clip ? 0 : -1} aria-label="Live Photo 关键帧" aria-valuemin={0} aria-valuemax={maximumCoverMs}
      aria-valuenow={coverTimeMs} aria-valuetext={`${(coverTimeMs / 1000).toFixed(1)} 秒`} aria-disabled={!enabled}
      onKeyDown={keyDown} onPointerDown={beginDrag} onPointerMove={moveDrag} onPointerUp={endDrag} onPointerCancel={endDrag} onLostPointerCapture={endDrag}>
      <FilmObjectModel kind="loupe" reveal={unroll} turn={0} tiltX={dragging ? -.025 : 0} tiltY={dragging ? .025 : 0} onReady={() => setLoupeReady(true)} />
      <div className="film-keyframe-lens" style={{ opacity: reveal, transform: `rotateX(${(1 - reveal) * 65}deg)` }} aria-hidden="true">
        {phase !== 'ready' && <div className="film-keyframe-lens-sample" style={{ width: trackWidth, height: 32,
          transform: `translate(${15.6 - 2.2 * (viewerX - 53)}px, ${15.6 - 2.2 * 16}px) scale(2.2)` }}>
          {outgoing && <FilmStrip snapshot={outgoing} className="is-outgoing" offset={motion.outgoingOffset * trackWidth} />}
          <div className="film-keyframe-incoming" style={{ clipPath: `inset(0 ${(1 - motion.incomingWidth) * 100}% 0 0)` }}>
            <FilmStrip snapshot={{ selection: displayed, frames }} offset={motion.incomingOffset * trackWidth} />
          </div>
        </div>}
        {displayed.clip && <video ref={lensRef} key={displayed.clip.previewUrl} src={displayed.clip.previewUrl} muted playsInline preload="auto"
          style={{ opacity: phase === 'ready' ? 1 : 0 }} onLoadedData={applyLensSeek} onSeeked={applyLensSeek} />}
        <span />
      </div>
    </div>
    <span className="film-keyframe-marker" style={{ opacity: unroll, left: viewerX }} aria-hidden="true" />
    <div className="film-keyframe-readout">
      <span>{clip ? `总长 ${(clip.durationMs / 1000).toFixed(1)}s` : '选择画格后设置关键帧'}</span>
      <small>{fineTuning ? '精细调节' : phase === 'rewinding' ? '收卷' : phase === 'swapping' ? '换卷' : phase === 'unrolling' ? '展开胶片' : clip ? `关键帧 ${(coverTimeMs / 1000).toFixed(1)}s` : ''}</small>
    </div>
  </div>
}

function FilmStrip({ snapshot, offset, className = '' }: { snapshot: FilmSnapshot; offset: number; className?: string }) {
  const { selection, frames } = snapshot
  const fraction = selection.clip ? Math.min(1, (selection.clip.durationMs - selection.clip.startTimeMs) / selection.outputDurationMs) : 0
  return <div className={`film-keyframe-track ${className}`} style={{ transform: `translateX(${offset}px)` }} aria-hidden="true">
    <div className="film-keyframe-frames">
      {Array.from({ length: FRAME_COUNT }, (_, index) => frames[index]
        ? <img key={index} src={frames[index]} alt="" draggable="false" /> : <i key={index} />)}
      {selection.clip && fraction < 1 && <span className="film-keyframe-padding" style={{ left: `${fraction * 100}%` }}><b>末帧补齐</b></span>}
    </div>
  </div>
}
