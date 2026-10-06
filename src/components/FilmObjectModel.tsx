import { useEffect, useRef, useState } from 'react'
import type { FilmObjectKind, FilmObjectPose, createFilmObjectRenderer } from './filmObjectRenderer'

interface Props extends FilmObjectPose {
  kind: FilmObjectKind
  onReady: () => void
}

export function FilmObjectModel({ kind, onReady, ...pose }: Props) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const rendererRef = useRef<Awaited<ReturnType<typeof createFilmObjectRenderer>> | undefined>(undefined)
  const poseRef = useRef(pose)
  const readyRef = useRef(onReady)
  const [status, setStatus] = useState('loading')
  poseRef.current = pose
  readyRef.current = onReady

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const controller = new AbortController()
    const fallback = () => {
      if (controller.signal.aborted) return
      setStatus('fallback')
      readyRef.current()
    }
    const deadline = window.setTimeout(() => { fallback(); controller.abort() }, 10_000)
    const contextLost = (event: Event) => { event.preventDefault(); fallback() }
    canvas.addEventListener('webglcontextlost', contextLost)
    const observer = new ResizeObserver(() => rendererRef.current?.render(poseRef.current))
    observer.observe(canvas)
    void import('./filmObjectRenderer').then(async ({ createFilmObjectRenderer }) => {
      if (controller.signal.aborted) return
      const renderer = await createFilmObjectRenderer(canvas, kind, controller.signal)
      if (controller.signal.aborted) { renderer.dispose(); return }
      rendererRef.current = renderer
      renderer.render(poseRef.current)
      setStatus('ready')
      readyRef.current()
    }).catch(fallback).finally(() => window.clearTimeout(deadline))
    return () => {
      controller.abort()
      window.clearTimeout(deadline)
      observer.disconnect()
      canvas.removeEventListener('webglcontextlost', contextLost)
      rendererRef.current?.dispose()
      rendererRef.current = undefined
    }
  }, [kind])

  useEffect(() => { rendererRef.current?.render(pose) }, [pose.reveal, pose.turn, pose.tiltX, pose.tiltY])

  return <div className={`film-object-model ${kind}`} data-model-status={status} aria-hidden="true">
    {status !== 'ready' && <span className={`film-object-fallback ${kind}`}>{kind === 'cartridge' ? <b>Lives<small>400</small></b> : <i />}</span>}
    <canvas ref={canvasRef} style={{ opacity: status === 'ready' ? 1 : 0 }} />
  </div>
}
