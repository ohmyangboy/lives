import { useCallback, useEffect, useMemo, useRef, useState, type PointerEvent as ReactPointerEvent } from 'react'
import { open } from '@tauri-apps/plugin-dialog'
import { getCurrentWebview } from '@tauri-apps/api/webview'
import { getCurrentWindow } from '@tauri-apps/api/window'
import { CollagePreview } from './components/CollagePreview'
import { Timeline } from './components/Timeline'
import { ExportOverlay } from './components/ExportOverlay'
import { analyzeSourceQuality, aspectRatioOptions, canvasDimensions, createRenderProject, formatDuration, templates, type AspectRatioId, type AudioMode, type ExportQuality, type SlotClip, type TemplateId, type VideoClip } from './domain'
import { desktopAvailable, nativeService, previewUrlForPath, type NativeStage } from './nativeBridge'
import { ClearIcon, CloseIcon, ExportIcon, FilmIcon, FolderIcon, LiveIcon, PlusIcon, SoundIcon } from './icons'
import { ExportDestinationPicker, type ExportDestinationChoice } from './components/ExportDestinationPicker'

interface ExportState {
  visible: boolean
  state: 'running' | 'success' | 'error'
  stage: NativeStage
  progress: number
  message?: string
  recovery?: string
  errorCode?: string
  jobId?: string
  outputPath?: string
}

type ExportDestination = ExportDestinationChoice
type CanvasOrientation = 'portrait' | 'landscape'
type SlotPlacements = Partial<Record<string, SlotClip>>
interface SourceDragFeedback {
  materialId: string
  name: string
  previewUrl: string
  x: number
  y: number
  overSlotId?: string
}

interface MediaProject {
  id: string
  name: string
  kind: 'direct' | 'folder'
  folderPath?: string
  clipIds: string[]
}

const initialExport: ExportState = { visible: false, state: 'running', stage: 'inspecting', progress: 0 }
const defaultProjectId = 'direct-imports'
const libraryStorageKey = 'lives.project-media.v2'
const legacyLibraryStorageKey = 'lives.project-media.v1'
const createDefaultProject = (): MediaProject => ({ id: defaultProjectId, name: '已导入', kind: 'direct', clipIds: [] })

function VideoCover({ src }: { src: string }) {
  const hostRef = useRef<HTMLDivElement>(null)
  const [shouldLoad, setShouldLoad] = useState(false)
  const [frame, setFrame] = useState<string>()

  useEffect(() => {
    setShouldLoad(false)
    setFrame(undefined)
    const host = hostRef.current
    if (!host || !('IntersectionObserver' in window)) { setShouldLoad(true); return }
    const observer = new IntersectionObserver((entries) => {
      if (!entries.some((entry) => entry.isIntersecting)) return
      setShouldLoad(true)
      observer.disconnect()
    }, { rootMargin: '180px 0px' })
    observer.observe(host)
    return () => observer.disconnect()
  }, [src])

  useEffect(() => {
    if (!shouldLoad) return
    let disposed = false
    const video = document.createElement('video')
    video.muted = true
    video.playsInline = true
    video.preload = 'metadata'
    const canvas = document.createElement('canvas')
    canvas.width = 160
    canvas.height = 126
    const capture = () => {
      if (disposed || !video.videoWidth || !video.videoHeight) return
      const context = canvas.getContext('2d')
      if (!context) return
      const sourceAspect = video.videoWidth / video.videoHeight
      const targetAspect = canvas.width / canvas.height
      const sourceWidth = sourceAspect > targetAspect ? video.videoHeight * targetAspect : video.videoWidth
      const sourceHeight = sourceAspect > targetAspect ? video.videoHeight : video.videoWidth / targetAspect
      context.drawImage(video, (video.videoWidth - sourceWidth) / 2, (video.videoHeight - sourceHeight) / 2, sourceWidth, sourceHeight, 0, 0, canvas.width, canvas.height)
      setFrame(canvas.toDataURL('image/jpeg', .78))
    }
    const seekPreviewFrame = () => {
      const previewTime = Math.min(.35, Math.max(.04, video.duration - .04))
      if (Math.abs(video.currentTime - previewTime) < .01) capture()
      else video.currentTime = previewTime
    }
    video.addEventListener('loadedmetadata', seekPreviewFrame, { once: true })
    video.addEventListener('seeked', capture, { once: true })
    video.src = src
    return () => { disposed = true; video.src = '' }
  }, [shouldLoad, src])

  return <div ref={hostRef} className={`video-cover ${frame ? 'ready' : ''}`} aria-hidden="true">
    {frame && <img src={frame} alt="" />}
    <i />
  </div>
}

const restoreMediaLibrary = (): { clips: VideoClip[]; projects: MediaProject[]; activeProjectId: string } => {
  if (!desktopAvailable()) return { clips: [], projects: [createDefaultProject()], activeProjectId: defaultProjectId }
  try {
    const saved = JSON.parse(localStorage.getItem(libraryStorageKey) ?? localStorage.getItem(legacyLibraryStorageKey) ?? '{}') as {
      clips?: Array<Omit<VideoClip, 'previewUrl'>>
      projects?: MediaProject[]
      activeProjectId?: string
    }
    const clips = (saved.clips ?? []).filter((clip) => clip.sourcePath).map((clip) => ({ ...clip, previewUrl: previewUrlForPath(clip.sourcePath) }))
    const clipIds = new Set(clips.map((clip) => clip.id))
    const restoredProjects = (saved.projects ?? []).map((project) => ({ ...project, clipIds: project.clipIds.filter((id) => clipIds.has(id)) }))
    const projects = restoredProjects.some((project) => project.id === defaultProjectId)
      ? restoredProjects
      : [createDefaultProject(), ...restoredProjects]
    if (!saved.projects) projects[0] = { ...projects[0], clipIds: clips.map((clip) => clip.id) }
    const activeProjectId = projects.some((project) => project.id === saved.activeProjectId) ? saved.activeProjectId! : projects[0].id
    return { clips, projects, activeProjectId }
  } catch {
    return { clips: [], projects: [createDefaultProject()], activeProjectId: defaultProjectId }
  }
}

export function App() {
  const restoredMedia = useMemo(restoreMediaLibrary, [])
  const [clips, setClips] = useState<VideoClip[]>(restoredMedia.clips)
  const [mediaProjects, setMediaProjects] = useState<MediaProject[]>(restoredMedia.projects)
  const [activeProjectId, setActiveProjectId] = useState(restoredMedia.activeProjectId)
  const [templateId, setTemplateId] = useState<TemplateId>('single')
  const [aspectRatio, setAspectRatio] = useState<AspectRatioId>('9:16')
  const [canvasOrientation, setCanvasOrientation] = useState<CanvasOrientation>('portrait')
  const [exportQuality, setExportQuality] = useState<ExportQuality>('1080p')
  const [coverTimeMs, setCoverTimeMs] = useState(1500)
  const [selectedSlotId, setSelectedSlotId] = useState<string>()
  const [selectedMaterialId, setSelectedMaterialId] = useState<string>()
  const [sourceDragFeedback, setSourceDragFeedback] = useState<SourceDragFeedback>()
  const [notice, setNotice] = useState<string>()
  const [isDragging, setIsDragging] = useState(false)
  const [exportState, setExportState] = useState<ExportState>(initialExport)
  const [exportDestination, setExportDestination] = useState<ExportDestination>('photos')
  const [pickerDestination, setPickerDestination] = useState<ExportDestination>('photos')
  const [exportFolder, setExportFolder] = useState<string>()
  const [audioMode, setAudioMode] = useState<AudioMode>('mute')
  const [audioSourceClipId, setAudioSourceClipId] = useState<string>()
  const [slotPlacements, setSlotPlacements] = useState<SlotPlacements>({})
  const [destinationPickerVisible, setDestinationPickerVisible] = useState(false)
  const [importProgress, setImportProgress] = useState<{ done: number; total: number }>()
  const fileInputRef = useRef<HTMLInputElement>(null)
  const internalDragRef = useRef(false)
  const sourcePointerDragRef = useRef<{ pointerId: number; materialId: string; startX: number; startY: number; active: boolean } | undefined>(undefined)
  const activeMediaProject = mediaProjects.find((project) => project.id === activeProjectId) ?? mediaProjects[0]
  const activeProjectClips = activeMediaProject.clipIds.map((id) => clips.find((clip) => clip.id === id)).filter((clip): clip is VideoClip => Boolean(clip))
  const currentTemplate = templates.find((template) => template.id === templateId)!
  const visibleAspectRatios = (canvasOrientation === 'portrait' ? ['9:16', '3:4', '1:1'] : ['16:9', '4:3', '1:1'])
    .map((id) => aspectRatioOptions.find((option) => option.id === id as AspectRatioId)!)
  const canvas = canvasDimensions({ aspectRatio, quality: exportQuality })
  const slotClips = currentTemplate.slots.map((slot) => slotPlacements[slot.id])
  const selectedSlotClip = selectedSlotId ? slotPlacements[selectedSlotId] : undefined
  const activeClips = slotClips.filter((clip): clip is SlotClip => Boolean(clip))
  const sourceQuality = analyzeSourceQuality(activeClips.length ? activeClips : clips)
  const cropUpscaleRisk = sourceQuality.effectiveShortEdge < Math.min(canvas.width, canvas.height)
  const audioSourceClip = activeClips.find((clip) => clip.id === audioSourceClipId) ?? activeClips[0]
  const canExport = desktopAvailable() && slotClips.length === currentTemplate.requiredClipCount && slotClips.every((clip): clip is SlotClip => clip !== undefined && clip.durationMs >= 3000)
  const placementLabel = (clip: SlotClip) => currentTemplate.slots.find((slot) => slot.id === clip.targetSlotId)?.label ?? '画面格'

  const resolveMaterial = useCallback((materialId: string) => {
    const source = clips.find((clip) => clip.id === materialId)
    return source ? { source, startTimeMs: 0 } : undefined
  }, [clips])

  useEffect(() => {
    if (!desktopAvailable()) return
    nativeService.healthCheck().catch(() => setNotice('原生媒体服务未能启动，请重新打开 App'))
  }, [])

  useEffect(() => {
    if (!desktopAvailable()) return
    const persistentClips = clips.filter((clip) => clip.sourcePath).map(({ previewUrl: _previewUrl, ...clip }) => clip)
    const sourceIds = new Set(persistentClips.map((clip) => clip.id))
    const persistentProjects = mediaProjects.map((project) => ({ ...project, clipIds: project.clipIds.filter((id) => sourceIds.has(id)) }))
    localStorage.setItem(libraryStorageKey, JSON.stringify({ clips: persistentClips, projects: persistentProjects, activeProjectId }))
  }, [activeProjectId, clips, mediaProjects])

  useEffect(() => {
    if (clips.length && !sourceQuality.supports1080p && exportQuality === '1080p') setExportQuality('720p')
  }, [clips.length, exportQuality, sourceQuality.supports1080p])

  const importPaths = useCallback(async (paths: string[], target: Omit<MediaProject, 'clipIds'> = createDefaultProject()) => {
    const existingByPath = new Map(clips.filter((clip) => clip.sourcePath).map((clip) => [clip.sourcePath, clip]))
    const supported = [...new Set(paths.filter((path) => /\.(mov|mp4|m4v)$/i.test(path)))]
    if (!supported.length) { setNotice('请选择 MOV、MP4 或 M4V 视频'); return }
    const accepted = supported.filter((path) => !existingByPath.has(path))
    setNotice(undefined)
    if (accepted.length) setImportProgress({ done: 0, total: accepted.length })
    const imported = new Array<VideoClip | undefined>(accepted.length)
    let cursor = 0
    let finished = 0
    let failed = 0
    const worker = async () => {
      while (cursor < accepted.length) {
        const index = cursor++
        const path = accepted[index]
        try {
          const info = await nativeService.inspect(path)
          if (info.durationMs < 3000) throw new Error('视频不足 3 秒')
          imported[index] = {
            id: crypto.randomUUID(), sourcePath: path, name: path.split('/').pop() ?? '视频', durationMs: info.durationMs,
            width: info.width, height: info.height, codec: info.codec, startTimeMs: 0,
            crop: { normalizedCenterX: 0.5, normalizedCenterY: 0.5, scale: 1 }, previewUrl: previewUrlForPath(path),
          }
        } catch {
          failed += 1
        } finally {
          finished += 1
          setImportProgress({ done: finished, total: accepted.length })
        }
      }
    }
    await Promise.all(Array.from({ length: Math.min(4, accepted.length) }, () => worker()))
    const successful = imported.filter((clip): clip is VideoClip => Boolean(clip))
    if (successful.length) setClips((current) => [...current, ...successful])
    setImportProgress(undefined)
    const importedByPath = new Map(successful.map((clip) => [clip.sourcePath, clip]))
    const projectClipIds = supported.flatMap((path) => {
      const clip = existingByPath.get(path) ?? importedByPath.get(path)
      return clip ? [clip.id] : []
    })
    if (projectClipIds.length) {
      setMediaProjects((current) => {
        const existing = current.find((project) => project.id === target.id)
        if (!existing) return [...current, { ...target, clipIds: projectClipIds }]
        return current.map((project) => project.id === target.id
          ? { ...project, ...target, clipIds: [...new Set([...project.clipIds, ...projectClipIds])] }
          : project)
      })
      setActiveProjectId(target.id)
      setSelectedMaterialId(projectClipIds[0])
    }
    if (failed) setNotice(`已添加 ${successful.length} 段视频；${failed} 段无法读取或不足 3 秒`)
  }, [clips])

  const importBrowserFiles = async (files: FileList) => {
    const next: VideoClip[] = []
    for (const file of Array.from(files)) {
      if (!/\.(mov|mp4|m4v)$/i.test(file.name)) continue
      const url = URL.createObjectURL(file)
      const metadata = await new Promise<{ durationMs: number; width: number; height: number }>((resolve, reject) => {
        const video = document.createElement('video')
        video.preload = 'metadata'; video.src = url
        video.onloadedmetadata = () => resolve({ durationMs: video.duration * 1000, width: video.videoWidth, height: video.videoHeight })
        video.onerror = () => reject(new Error(`无法读取 ${file.name}`))
      })
      if (metadata.durationMs < 3000) { URL.revokeObjectURL(url); setNotice(`${file.name} 不足 3 秒`); continue }
      next.push({ id: crypto.randomUUID(), sourcePath: '', name: file.name, ...metadata, codec: file.type || 'video', startTimeMs: 0, crop: { normalizedCenterX: .5, normalizedCenterY: .5, scale: 1 }, previewUrl: url })
    }
    setClips((current) => [...current, ...next])
    if (next.length) {
      setMediaProjects((current) => current.map((project) => project.id === defaultProjectId
        ? { ...project, clipIds: [...new Set([...project.clipIds, ...next.map((clip) => clip.id)])] }
        : project))
      setActiveProjectId(defaultProjectId)
      setSelectedMaterialId(next[0].id)
    }
  }

  const chooseVideos = async () => {
    if (!desktopAvailable()) { fileInputRef.current?.click(); return }
    const selected = await open({ multiple: true, directory: false, filters: [{ name: '视频', extensions: ['mov', 'mp4', 'm4v'] }] })
    if (selected) await importPaths(Array.isArray(selected) ? selected : [selected], createDefaultProject())
  }

  const chooseSourceFolder = async () => {
    if (!desktopAvailable()) { setNotice('关联文件夹需要在 Mac App 中使用'); return }
    const selected = await open({ multiple: false, directory: true, title: '选择包含视频的文件夹' })
    if (typeof selected !== 'string') return
    setImportProgress({ done: 0, total: 1 })
    try {
      const paths = await nativeService.scanFolder(selected)
      if (!paths.length) { setNotice('这个文件夹中没有 MOV、MP4 或 M4V 视频'); setImportProgress(undefined); return }
      const existingProject = mediaProjects.find((project) => project.kind === 'folder' && project.folderPath === selected)
      const folderName = selected.split('/').filter(Boolean).pop() ?? '视频文件夹'
      await importPaths(paths, { id: existingProject?.id ?? crypto.randomUUID(), name: folderName, kind: 'folder', folderPath: selected })
    } catch (error) {
      setImportProgress(undefined)
      setNotice(error instanceof Error ? error.message : '无法读取这个文件夹')
    }
  }

  const chooseExportFolder = async () => {
    if (!desktopAvailable()) return undefined
    const selected = await open({ multiple: false, directory: true, title: '选择 Live Photo 配对文件的保存位置' })
    if (typeof selected === 'string') {
      setExportFolder(selected)
      return selected
    }
    return undefined
  }

  useEffect(() => {
    if (!desktopAvailable()) return
    let unlisten: (() => void) | undefined
    getCurrentWebview().onDragDropEvent((event) => {
      // Tauri also reports HTML5 drags from our own material cards. Only a
      // Finder drop has filesystem paths and may activate the import overlay.
      const payload = event.payload as { type: 'enter' | 'over' | 'leave' | 'drop'; paths?: string[] }
      if (payload.type === 'leave') { if (!internalDragRef.current) setIsDragging(false); return }
      if (internalDragRef.current || !payload.paths?.length) return
      if (payload.type === 'enter' || payload.type === 'over') setIsDragging(true)
      if (payload.type === 'drop') { setIsDragging(false); void importPaths(payload.paths) }
    }).then((stop) => { unlisten = stop })
    return () => unlisten?.()
  }, [importPaths])

  useEffect(() => () => clips.forEach((clip) => { if (!clip.sourcePath) URL.revokeObjectURL(clip.previewUrl) }), [])

  const placeMaterialInSlot = (slotId: string, materialId: string) => {
    const material = resolveMaterial(materialId)
    if (!material) return
    const { source, startTimeMs } = material
    const placed: SlotClip = {
      ...source,
      id: crypto.randomUUID(),
      sourceClipId: source.id,
      targetSlotId: slotId,
      startTimeMs,
      crop: { ...source.crop },
    }
    setSlotPlacements((current) => ({ ...current, [slotId]: placed }))
    setSelectedSlotId(slotId)
    setSelectedMaterialId(materialId)
    setNotice(undefined)
  }

  const beginSourcePointerDrag = (event: ReactPointerEvent<HTMLDivElement>, materialId: string) => {
    if (event.button !== 0 || (event.target as HTMLElement).closest('button')) return
    internalDragRef.current = true
    sourcePointerDragRef.current = { pointerId: event.pointerId, materialId, startX: event.clientX, startY: event.clientY, active: false }
    event.currentTarget.setPointerCapture(event.pointerId)
    setSelectedMaterialId(materialId)
  }

  const moveSourcePointerDrag = (event: ReactPointerEvent<HTMLDivElement>) => {
    const drag = sourcePointerDragRef.current
    if (!drag || drag.pointerId !== event.pointerId) return
    if (!drag.active && Math.hypot(event.clientX - drag.startX, event.clientY - drag.startY) < 5) return
    drag.active = true
    const material = resolveMaterial(drag.materialId)
    if (!material) return
    const slot = document.elementFromPoint(event.clientX, event.clientY)?.closest<HTMLElement>('[data-collage-slot-id]')
    setSourceDragFeedback({
      materialId: drag.materialId,
      name: material.source.name,
      previewUrl: material.source.previewUrl,
      x: event.clientX,
      y: event.clientY,
      overSlotId: slot?.dataset.collageSlotId,
    })
  }

  const finishSourcePointerDrag = (event: ReactPointerEvent<HTMLDivElement>) => {
    const drag = sourcePointerDragRef.current
    if (!drag || drag.pointerId !== event.pointerId) return
    const slot = document.elementFromPoint(event.clientX, event.clientY)?.closest<HTMLElement>('[data-collage-slot-id]')
    const slotId = slot?.dataset.collageSlotId
    if (slotId) placeMaterialInSlot(slotId, drag.materialId)
    sourcePointerDragRef.current = undefined
    setSourceDragFeedback(undefined)
    internalDragRef.current = false
  }

  const cancelSourcePointerDrag = () => {
    sourcePointerDragRef.current = undefined
    setSourceDragFeedback(undefined)
    internalDragRef.current = false
  }

  const updateSlotClip = (slotId: string, update: (clip: SlotClip) => SlotClip) => setSlotPlacements((current) => current[slotId] ? { ...current, [slotId]: update(current[slotId]!) } : current)

  const clearSlot = (slotId: string) => {
    const nextSelectedSlot = currentTemplate.slots.find((slot) => slot.id !== slotId && slotPlacements[slot.id])?.id
    setSlotPlacements((current) => {
      const next = { ...current }
      delete next[slotId]
      return next
    })
    setSelectedSlotId(nextSelectedSlot)
  }

  const removeClip = (id: string) => {
    const removed = clips.find((clip) => clip.id === id)
    if (removed && !removed.sourcePath) URL.revokeObjectURL(removed.previewUrl)
    const next = clips.filter((clip) => clip.id !== id)
    setClips(next)
    setMediaProjects((current) => current.map((project) => ({ ...project, clipIds: project.clipIds.filter((clipId) => clipId !== id) })))
    setSlotPlacements((current) => Object.fromEntries(Object.entries(current).filter(([, placement]) => placement?.sourceClipId !== id)))
    if (selectedMaterialId === id) setSelectedMaterialId(undefined)
  }

  const closeMediaProject = (projectId: string) => {
    const project = mediaProjects.find((item) => item.id === projectId)
    if (!project) return
    const remainingProjects = projectId === defaultProjectId
      ? mediaProjects.map((item) => item.id === defaultProjectId ? { ...item, clipIds: [] } : item)
      : mediaProjects.filter((item) => item.id !== projectId)
    const retainedClipIds = new Set(remainingProjects.flatMap((item) => item.clipIds))
    const removedClipIds = new Set(project.clipIds.filter((id) => !retainedClipIds.has(id)))
    clips.filter((clip) => removedClipIds.has(clip.id) && !clip.sourcePath).forEach((clip) => URL.revokeObjectURL(clip.previewUrl))
    setMediaProjects(remainingProjects)
    setClips((current) => current.filter((clip) => !removedClipIds.has(clip.id)))
    setSlotPlacements((current) => Object.fromEntries(Object.entries(current).filter(([, placement]) => !placement || !removedClipIds.has(placement.sourceClipId))))
    if (selectedMaterialId && removedClipIds.has(selectedMaterialId)) setSelectedMaterialId(undefined)
    if (activeProjectId === projectId) {
      setActiveProjectId(defaultProjectId)
      setSelectedMaterialId(undefined)
    }
  }

  const clearProject = () => {
    clips.forEach((clip) => { if (!clip.sourcePath) URL.revokeObjectURL(clip.previewUrl) })
    setClips([])
    setTemplateId('single')
    setAspectRatio('9:16')
    setCanvasOrientation('portrait')
    setExportQuality('1080p')
    setCoverTimeMs(1500)
    setSelectedSlotId(undefined)
    setSelectedMaterialId(undefined)
    setMediaProjects([createDefaultProject()])
    setActiveProjectId(defaultProjectId)
    setExportDestination('photos')
    setPickerDestination('photos')
    setExportFolder(undefined)
    setAudioMode('mute')
    setAudioSourceClipId(undefined)
    setSlotPlacements({})
    setDestinationPickerVisible(false)
    setExportState(initialExport)
    setNotice(undefined)
  }

  const exportProject = async (destination = exportDestination, folder = exportFolder) => {
    if (!canExport) { setNotice(desktopAvailable() ? `请把素材拖入“${currentTemplate.name}”的每个画面格` : '浏览器模式仅供预览，请在 Mac App 中导出'); return }
    let destinationFolder = folder
    if (destination === 'folder' && !destinationFolder) {
      destinationFolder = await chooseExportFolder()
      if (!destinationFolder) return
    }
    const project = createRenderProject(clips, templateId, audioMode, audioSourceClip?.id, slotClips, { aspectRatio, quality: exportQuality }, coverTimeMs)
    setExportState({ visible: true, state: 'running', stage: 'inspecting', progress: 0, jobId: project.id })
    try {
      const onProgress = (stage: NativeStage, progress: number) => setExportState((current) => ({ ...current, stage, progress }))
      if (destination === 'photos') {
        await nativeService.renderAndSave(project, onProgress)
        setExportState((current) => ({ ...current, state: 'success', stage: 'completed', progress: 1 }))
      } else {
        const result = await nativeService.renderAndExport(project, destinationFolder!, onProgress)
        setExportState((current) => ({ ...current, state: 'success', stage: 'completed', progress: 1, outputPath: result.photoPath }))
      }
    } catch (error) {
      const typed = (error instanceof Error ? error : new Error(String(error))) as Error & { code?: string; recovery?: string }
      setExportState((current) => ({ ...current, state: 'error', message: typed.message, recovery: typed.recovery, errorCode: typed.code }))
    }
  }

  const exportToFolderInstead = async () => {
    const folder = exportFolder ?? await chooseExportFolder()
    if (!folder) return
    setExportDestination('folder')
    setExportState(initialExport)
    await exportProject('folder', folder)
  }

  const requestExport = () => {
    if (!canExport) {
      setNotice(`请把素材拖入“${currentTemplate.name}”的每个画面格`)
      return
    }
    setExportQuality(sourceQuality.supports1080p ? '1080p' : '720p')
    setPickerDestination('photos')
    setDestinationPickerVisible(true)
  }

  const changeCanvasOrientation = (orientation: CanvasOrientation) => {
    setCanvasOrientation(orientation)
    setAspectRatio((current) => {
      if (orientation === 'portrait') return current === '4:3' ? '3:4' : current === '16:9' ? '9:16' : current === '1:1' ? '9:16' : current
      return current === '3:4' ? '4:3' : current === '9:16' ? '16:9' : current === '1:1' ? '16:9' : current
    })
  }

  const toggleWindowZoom = () => {
    if (desktopAvailable()) void getCurrentWindow().toggleMaximize()
  }

  const exportFromPicker = async () => {
    if (pickerDestination === 'folder') {
      const folder = await chooseExportFolder()
      if (!folder) return
      setDestinationPickerVisible(false)
      setExportDestination('folder')
      await exportProject('folder', folder)
      return
    }
    setDestinationPickerVisible(false)
    setExportDestination(pickerDestination)
    await exportProject(pickerDestination)
  }

  const projectSummary = useMemo(() => clips.length ? `${clips.length} 段素材 · 3.0 秒 · ${canvas.width} × ${canvas.height}` : '本地处理，不上传视频', [clips.length, canvas.width, canvas.height])

  useEffect(() => {
    if (audioSourceClip && audioSourceClip.id !== audioSourceClipId) setAudioSourceClipId(audioSourceClip.id)
  }, [audioSourceClip, audioSourceClipId])

  return (
    <main className={['app', isDragging && 'is-dragging', sourceDragFeedback && 'source-dragging'].filter(Boolean).join(' ')}>
      <header className="titlebar" data-tauri-drag-region onDoubleClick={(event) => {
        if (!(event.target as HTMLElement).closest('button')) toggleWindowZoom()
      }}>
        <div className="brand"><span className="brand-mark"><LiveIcon /></span><div><strong>Lives</strong><small>实况拼贴</small></div></div>
        <div className="project-meta"><span className={clips.length ? 'status-dot active' : 'status-dot'} />{projectSummary}</div>
        <div className="titlebar-actions">
          <button className="clear-project" disabled={!clips.length} onClick={clearProject}><ClearIcon />清除</button>
          <button className="primary-button" disabled={!clips.length} onClick={requestExport}><ExportIcon />生成 Live Photo</button>
        </div>
      </header>

      {!clips.length ? (
        <section className="welcome">
          <div className="welcome-copy">
            <span className="eyebrow">MAC 上的实况工作室</span>
            <h1>把三个瞬间，<br />装进一张 <em>Live</em> 图。</h1>
            <p>批量添加视频，或直接选择一个文件夹。素材按项目整理，再把喜欢的画面拖进拼贴。</p>
            <div className="welcome-media-actions"><button onClick={() => void chooseSourceFolder()}><FolderIcon />导入文件夹</button><span className="support-note welcome-support">使用原文件 · 不复制不上传 · 支持 MOV / MP4 / M4V</span></div>
          </div>
          <button className="drop-composition" onClick={chooseVideos} aria-label="添加或拖入视频">
            <div className="mock-frame frame-a"><span>01</span></div>
            <div className="mock-frame frame-b"><span>02</span></div>
            <div className="mock-frame frame-c"><span>03</span></div>
            <div className="drop-core"><PlusIcon /><strong>添加 / 拖入视频</strong><small>引用原文件</small></div>
            <i className="orbit-line one" /><i className="orbit-line two" />
          </button>
        </section>
      ) : (
        <div className="workspace">
          <aside className="left-panel">
            <div className="panel-heading"><span className="eyebrow">01 / 素材</span><h2>视频素材库</h2></div>
            <div className="media-project-tabs" aria-label="素材项目">
              {mediaProjects.map((project) => <div key={project.id} className={project.id === activeProjectId ? 'media-project-tab selected' : 'media-project-tab'} title={project.folderPath ?? project.name}>
                <button className="media-project-select" onClick={() => { setActiveProjectId(project.id); setSelectedMaterialId(undefined) }}><span>{project.name}</span><b>{project.clipIds.length}</b></button>
                {project.clipIds.length > 0 && <button className="media-project-close" aria-label={`关闭项目 ${project.name}`} onClick={() => closeMediaProject(project.id)}><CloseIcon /></button>}
              </div>)}
            </div>
            {importProgress && <div className="material-import-status"><i style={{ width: `${importProgress.total ? importProgress.done / importProgress.total * 100 : 0}%` }} /><span>正在导入 {importProgress.done} / {importProgress.total}</span></div>}
            <div className="clip-list material-library">
              {activeProjectClips.map((clip, index) => {
                const materialId = clip.id
                return <div key={materialId} className={['clip-card', materialId === selectedMaterialId && 'selected', materialId === sourceDragFeedback?.materialId && 'dragging'].filter(Boolean).join(' ')} onPointerDown={(event) => beginSourcePointerDrag(event, materialId)} onPointerMove={moveSourcePointerDrag} onPointerUp={finishSourcePointerDrag} onPointerCancel={cancelSourcePointerDrag}>
                  <span className="clip-index">{String(index + 1).padStart(2, '0')}</span>
                  <VideoCover src={clip.previewUrl} />
                  <span className="clip-copy"><strong>{clip.name}</strong><small>{formatDuration(clip.durationMs)} · {clip.width}×{clip.height}</small><em>拖入画面格</em></span>
                  <button className="remove-clip" aria-label={`移除 ${clip.name}`} onPointerDown={(event) => event.stopPropagation()} onClick={() => removeClip(clip.id)}><CloseIcon /></button>
                </div>
              })}
              {!activeProjectClips.length && <div className="project-empty"><FilmIcon /><strong>这个项目还没有视频</strong><span>{activeMediaProject.kind === 'folder' ? '重新导入文件夹，或切换其他项目。' : '添加视频后会显示在这里。'}</span></div>}
            </div>
            <div className="material-import-actions"><button onClick={() => void chooseVideos()}><PlusIcon />添加视频</button><button onClick={() => void chooseSourceFolder()}><FolderIcon />导入文件夹</button></div>
            <div className="selection-summary"><FilmIcon /><p><span>素材使用方式</span><strong>拖入画格；同一素材可以重复使用</strong></p><b>3.0s</b></div>
            <div className="privacy-note"><FolderIcon /><p><strong>使用原文件</strong><span>不会复制或修改视频，只保存文件引用。</span></p></div>
          </aside>

          <section className="center-panel">
            <div className="stage-heading"><div><span className="eyebrow">02 / 构图</span><h2>画布预览</h2></div></div>
            <CollagePreview clips={slotClips} template={currentTemplate} canvasWidth={canvas.width} canvasHeight={canvas.height} selectedSlotId={selectedSlotId} selectedSourceId={selectedMaterialId} pointerDropTargetSlotId={sourceDragFeedback?.overSlotId} isSourceDragging={Boolean(sourceDragFeedback)} audioMode={audioMode} audioSourceClipId={audioSourceClip?.id} coverTimeMs={coverTimeMs} onCoverTimeChange={setCoverTimeMs} onSelectSlot={setSelectedSlotId} onDropSource={placeMaterialInSlot} onClearSlot={clearSlot} onScaleChange={(slotId, scale) => updateSlotClip(slotId, (clip) => ({ ...clip, crop: { ...clip.crop, scale } }))} onCropChange={(slotId, x, y) => updateSlotClip(slotId, (clip) => ({ ...clip, crop: { ...clip.crop, normalizedCenterX: x, normalizedCenterY: y } }))} />
          </section>

          <aside className="right-panel">
            <div className="panel-heading"><span className="eyebrow">03 / 配置</span><h2>拼贴与声音</h2></div>
            <div className="video-settings aspect-settings">
              <span className="eyebrow">画面比例</span>
              <div className="setting-row"><span><strong>画布方向</strong><small>横竖屏即时切换</small></span><div className="segmented compact"><button className={canvasOrientation === 'portrait' ? 'selected' : ''} onClick={() => changeCanvasOrientation('portrait')}>竖屏</button><button className={canvasOrientation === 'landscape' ? 'selected' : ''} onClick={() => changeCanvasOrientation('landscape')}>横屏</button></div></div>
              <div className="setting-row"><span><strong>场景比例</strong><small>同步调整预览与导出</small></span><div className="segmented compact">{visibleAspectRatios.map((option) => <button key={option.id} className={aspectRatio === option.id ? 'selected' : ''} onClick={() => setAspectRatio(option.id)}>{option.label}</button>)}</div></div>
            </div>
            <div className="template-list config-templates">
              <span className="eyebrow">拼贴模板</span>
              {templates.map((template) => <button key={template.id} className={template.id === templateId ? 'template-card selected' : 'template-card'} onClick={() => { setTemplateId(template.id); setSelectedSlotId(undefined) }}>
                <span className="template-mini">{template.slots.map((slot) => <i key={slot.id} style={{ left: `${slot.x * 100}%`, top: `${slot.y * 100}%`, width: `${slot.width * 100}%`, height: `${slot.height * 100}%` }} />)}</span>
                <span><strong>{template.name}</strong><small>{template.description}</small></span>
                <b>{template.requiredClipCount}</b>
              </button>)}
            </div>
            <div className="drag-assignment-note"><FilmIcon /><p><strong>拖入画面格</strong><span>从左侧拖入素材；也可点选素材后点击空格。同一视频可多次使用，并分别截取不同瞬间。</span></p></div>
            <div className="audio-settings">
                <span className="eyebrow">预览声音</span>
                <div className="audio-switch" aria-label="声音设置">
                  <button className={audioMode === 'mute' ? 'selected' : ''} onClick={() => setAudioMode('mute')}>静音</button>
                  <button className={audioMode === 'selected' ? 'selected' : ''} onClick={() => setAudioMode('selected')}><SoundIcon />指定原声</button>
                  <button className={audioMode === 'mix' ? 'selected' : ''} onClick={() => setAudioMode('mix')}>混合</button>
                </div>
                {audioMode === 'selected' && <div className="audio-source-picker" aria-label="原声来源">
                  <span>原声来源</span>
                  <div>{activeClips.map((clip, index) => <button key={clip.id} className={clip.id === audioSourceClip?.id ? 'selected' : ''} onClick={() => setAudioSourceClipId(clip.id)}><b>{String(index + 1).padStart(2, '0')}</b><strong>{clip.name}</strong><small>{placementLabel(clip)}</small></button>)}</div>
                </div>}
                <small className="audio-note">{audioMode === 'mute' ? '导出的 Live Photo 不包含声音。' : audioMode === 'selected' ? `使用「${audioSourceClip?.name ?? '—'}」的原声；调整画面选段不会改变它。` : '当前模板内所有原声同步混合，并自动降低音量。'}</small>
            </div>
          </aside>

          {selectedSlotClip && <Timeline clip={selectedSlotClip} onChange={(startTimeMs) => updateSlotClip(selectedSlotClip.targetSlotId, (clip) => ({ ...clip, startTimeMs }))} />}
        </div>
      )}

      {notice && <div className="toast" role="status"><span>!</span>{notice}<button onClick={() => setNotice(undefined)}><CloseIcon /></button></div>}
      {sourceDragFeedback && <div className={sourceDragFeedback.overSlotId ? 'source-drag-ghost over-target' : 'source-drag-ghost'} style={{ left: sourceDragFeedback.x, top: sourceDragFeedback.y }} aria-hidden="true">
        <video src={sourceDragFeedback.previewUrl} muted preload="metadata" />
        <span><strong>{sourceDragFeedback.name}</strong><small>{sourceDragFeedback.overSlotId ? '松开，放入此画面格' : '拖到中间的画面格'}</small></span>
        <b>{sourceDragFeedback.overSlotId ? '✓' : '+'}</b>
      </div>}
      {isDragging && <div className="drag-overlay"><PlusIcon /><strong>放下视频，加入素材库</strong><span>使用原文件，可一次添加多段视频</span></div>}
      <input ref={fileInputRef} hidden type="file" multiple accept="video/quicktime,video/mp4,.m4v" onChange={(event) => event.target.files && void importBrowserFiles(event.target.files)} />
      {destinationPickerVisible && <ExportDestinationPicker aspectRatio={aspectRatio} quality={exportQuality} sourceQuality={sourceQuality} cropUpscaleRisk={cropUpscaleRisk} destination={pickerDestination} onQualityChange={setExportQuality} onDestinationChange={setPickerDestination} onExport={() => void exportFromPicker()} onClose={() => setDestinationPickerVisible(false)} />}
      {exportState.visible && <ExportOverlay {...exportState} destination={exportDestination} onClose={() => setExportState(initialExport)} onCancel={() => { if (exportState.jobId) void nativeService.cancel(exportState.jobId); setExportState(initialExport) }} onRetry={() => void exportProject()} onOpenPrivacySettings={() => void nativeService.openPhotoPrivacySettings()} onFallbackToFolder={() => void exportToFolderInstead()} onRevealResult={() => exportDestination === 'photos' ? void nativeService.openPhotos() : exportState.outputPath ? void nativeService.revealInFinder(exportState.outputPath) : undefined} />}
    </main>
  )
}
