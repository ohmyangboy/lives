import { useCallback, useEffect, useMemo, useRef, useState, type KeyboardEvent as ReactKeyboardEvent, type PointerEvent as ReactPointerEvent } from 'react'
import { open } from '@tauri-apps/plugin-dialog'
import { openUrl } from '@tauri-apps/plugin-opener'
import { getCurrentWebview } from '@tauri-apps/api/webview'
import { getCurrentWindow } from '@tauri-apps/api/window'
import { CollagePreview } from './components/CollagePreview'
import { Timeline, TimelineEmpty } from './components/Timeline'
import { ExportOverlay } from './components/ExportOverlay'
import { analyzeSourceQuality, aspectRatioOptions, canvasDimensions, createRenderProject, formatDuration, MINIMUM_SOURCE_DURATION_MS, templates, type AspectRatioId, type ExportQuality, type SlotClip, type TemplateId, type VideoClip } from './domain'
import { desktopAvailable, nativeService, previewUrlForPath, type NativeStage } from './nativeBridge'
import { ClearIcon, CloseIcon, ExportIcon, FeedbackIcon, FilmIcon, FolderIcon, InfoIcon, IssueIcon, LiveIcon, PlusIcon, UpdateIcon, ChevronDownIcon, GithubIcon } from './icons'
import { ExportDestinationPicker, type ExportDestinationChoice } from './components/ExportDestinationPicker'
import { currentAppVersion, defaultUpdateCoordinator } from './releaseUpdate'
import { UpdateCapsule } from './components/UpdateCapsule'
import { AboutModal } from './components/AboutModal'

import { getSystemDiagnosticInfo, formatSystemInfoText } from './systemInfo'
import xiaohongshuContactImage from './assets/xiaohongshu-contact.jpg'
import wechatSponsorImage from './assets/wechat-sponsor.jpg'

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
const onboardingStorageKey = 'lives.onboarding.import-guide.v1'
const createDefaultProject = (): MediaProject => ({ id: defaultProjectId, name: '已导入', kind: 'direct', clipIds: [] })

const shouldShowFirstRunGuide = () => {
  try {
    return localStorage.getItem(onboardingStorageKey) !== 'completed'
  } catch {
    return true
  }
}

const coverFrameCache = new Map<string, string>()
const coverFrameJobs = new Map<string, { controller: AbortController; consumers: number; promise: Promise<string | undefined> }>()
const coverFrameQueue: Array<() => void> = []
const maximumCoverFrameCacheSize = 96
const maximumConcurrentCoverFrames = 2
let activeCoverFrameJobs = 0

const rememberCoverFrame = (src: string, frame: string) => {
  coverFrameCache.delete(src)
  coverFrameCache.set(src, frame)
  if (coverFrameCache.size > maximumCoverFrameCacheSize) {
    const oldestSource = coverFrameCache.keys().next().value
    if (oldestSource) coverFrameCache.delete(oldestSource)
  }
}

const scheduleCoverFrame = (task: () => Promise<string | undefined>) => new Promise<string | undefined>((resolve) => {
  const run = () => {
    activeCoverFrameJobs += 1
    void task().then(resolve).finally(() => {
      activeCoverFrameJobs -= 1
      coverFrameQueue.shift()?.()
    })
  }
  if (activeCoverFrameJobs < maximumConcurrentCoverFrames) run()
  else coverFrameQueue.push(run)
})

const renderCoverFrame = (src: string, signal: AbortSignal) => new Promise<string | undefined>((resolve) => {
  const video = document.createElement('video')
  let settled = false
  let seekingPreview = false
  const timeout = window.setTimeout(() => finish(), 8000)

  const finish = (frame?: string) => {
    if (settled) return
    settled = true
    window.clearTimeout(timeout)
    signal.removeEventListener('abort', abort)
    video.removeEventListener('loadeddata', handleLoadedData)
    video.removeEventListener('seeked', capture)
    video.removeEventListener('error', fail)
    video.pause()
    video.removeAttribute('src')
    video.load()
    resolve(frame)
  }

  const abort = () => finish()
  const fail = () => finish()

  const capture = () => {
    if (signal.aborted || !video.videoWidth || !video.videoHeight) { finish(); return }
    const canvas = document.createElement('canvas')
    canvas.width = 124
    canvas.height = 98
    const context = canvas.getContext('2d')
    if (!context) { finish(); return }
    const sourceAspect = video.videoWidth / video.videoHeight
    const targetAspect = canvas.width / canvas.height
    const sourceWidth = sourceAspect > targetAspect ? video.videoHeight * targetAspect : video.videoWidth
    const sourceHeight = sourceAspect > targetAspect ? video.videoHeight : video.videoWidth / targetAspect
    try {
      context.drawImage(video, (video.videoWidth - sourceWidth) / 2, (video.videoHeight - sourceHeight) / 2, sourceWidth, sourceHeight, 0, 0, canvas.width, canvas.height)
      finish(canvas.toDataURL('image/jpeg', .76))
    } catch {
      finish()
    }
  }

  const handleLoadedData = () => {
    if (signal.aborted) { finish(); return }
    const previewTime = Math.min(.35, Math.max(.04, (Number.isFinite(video.duration) ? video.duration : .04) - .04))
    if (!seekingPreview && previewTime > .04 && Math.abs(video.currentTime - previewTime) > .01) {
      seekingPreview = true
      try { video.currentTime = previewTime; return } catch { /* Use the decoded first frame below. */ }
    }
    capture()
  }

  video.muted = true
  video.defaultMuted = true
  video.playsInline = true
  video.preload = 'auto'
  video.addEventListener('loadeddata', handleLoadedData, { once: true })
  video.addEventListener('seeked', capture, { once: true })
  video.addEventListener('error', fail, { once: true })
  signal.addEventListener('abort', abort, { once: true })
  if (signal.aborted) { finish(); return }
  video.src = src
  video.load()
})

const acquireCoverFrame = (src: string) => {
  const cached = coverFrameCache.get(src)
  if (cached) {
    rememberCoverFrame(src, cached)
    return { promise: Promise.resolve(cached), release: () => undefined }
  }
  let job = coverFrameJobs.get(src)
  if (!job) {
    const controller = new AbortController()
    const promise = scheduleCoverFrame(() => renderCoverFrame(src, controller.signal))
      .then((frame) => {
        if (frame) rememberCoverFrame(src, frame)
        return frame
      })
      .finally(() => coverFrameJobs.delete(src))
    job = { controller, consumers: 0, promise }
    coverFrameJobs.set(src, job)
  }
  job.consumers += 1
  let released = false
  return {
    promise: job.promise,
    release: () => {
      if (released) return
      released = true
      job!.consumers -= 1
      if (job!.consumers === 0) job!.controller.abort()
    },
  }
}

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
    const request = acquireCoverFrame(src)
    void request.promise.then((nextFrame) => {
      if (!disposed && nextFrame) setFrame(nextFrame)
    })
    return () => { disposed = true; request.release() }
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
  const [slotPlacements, setSlotPlacements] = useState<SlotPlacements>({})
  const [destinationPickerVisible, setDestinationPickerVisible] = useState(false)
  const [importProgress, setImportProgress] = useState<{ done: number; total: number }>()
  const [startupPhase, setStartupPhase] = useState<'visible' | 'leaving' | 'hidden'>('visible')
  const [firstRunGuideVisible, setFirstRunGuideVisible] = useState(shouldShowFirstRunGuide)
  const [openHelpPopover, setOpenHelpPopover] = useState<'library' | 'templates'>()
  const [feedbackPopoverOpen, setFeedbackPopoverOpen] = useState(false)
  const [appMenuOpen, setAppMenuOpen] = useState(false)
  const [aboutModalOpen, setAboutModalOpen] = useState(false)

  const [materialContextMenu, setMaterialContextMenu] = useState<{ x: number; y: number; clip: VideoClip }>()
  const fileInputRef = useRef<HTMLInputElement>(null)
  const firstRunDialogRef = useRef<HTMLDivElement>(null)
  const firstRunPrimaryRef = useRef<HTMLButtonElement>(null)
  const libraryHelpRef = useRef<HTMLDivElement>(null)
  const templateHelpRef = useRef<HTMLDivElement>(null)
  const feedbackPopoverRef = useRef<HTMLDivElement>(null)
  const appMenuRef = useRef<HTMLDivElement>(null)
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
  const canExport = desktopAvailable() && slotClips.length === currentTemplate.requiredClipCount && slotClips.every((clip): clip is SlotClip => clip !== undefined && clip.durationMs >= MINIMUM_SOURCE_DURATION_MS)

  useEffect(() => {
    const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    const leaveTimer = window.setTimeout(() => setStartupPhase('leaving'), reducedMotion ? 100 : 680)
    const hideTimer = window.setTimeout(() => setStartupPhase('hidden'), reducedMotion ? 180 : 920)
    return () => {
      window.clearTimeout(leaveTimer)
      window.clearTimeout(hideTimer)
    }
  }, [])

  useEffect(() => {
    if (startupPhase !== 'hidden' || !firstRunGuideVisible) return
    firstRunPrimaryRef.current?.focus()
  }, [firstRunGuideVisible, startupPhase])

  useEffect(() => {
    if (!openHelpPopover) return
    const activeRef = openHelpPopover === 'library' ? libraryHelpRef : templateHelpRef
    const dismissOnOutsidePress = (event: PointerEvent) => {
      if (!activeRef.current?.contains(event.target as Node)) setOpenHelpPopover(undefined)
    }
    const dismissOnEscape = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setOpenHelpPopover(undefined)
    }
    document.addEventListener('pointerdown', dismissOnOutsidePress)
    window.addEventListener('keydown', dismissOnEscape)
    return () => {
      document.removeEventListener('pointerdown', dismissOnOutsidePress)
      window.removeEventListener('keydown', dismissOnEscape)
    }
  }, [openHelpPopover])

  useEffect(() => {
    if (!feedbackPopoverOpen) return
    const dismissOnOutsidePress = (event: PointerEvent) => {
      if (!feedbackPopoverRef.current?.contains(event.target as Node)) setFeedbackPopoverOpen(false)
    }
    const dismissOnEscape = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setFeedbackPopoverOpen(false)
    }
    document.addEventListener('pointerdown', dismissOnOutsidePress)
    window.addEventListener('keydown', dismissOnEscape)
    return () => {
      document.removeEventListener('pointerdown', dismissOnOutsidePress)
      window.removeEventListener('keydown', dismissOnEscape)
    }
  }, [feedbackPopoverOpen])

  const resolveMaterial = useCallback((materialId: string) => {
    const source = clips.find((clip) => clip.id === materialId)
    return source ? { source, startTimeMs: 0 } : undefined
  }, [clips])

  useEffect(() => {
    if (!desktopAvailable()) return
    nativeService.healthCheck().catch(() => setNotice('原生媒体服务未能启动，请重新打开 App'))
  }, [])

  useEffect(() => {
    defaultUpdateCoordinator.start()
  }, [])

  const handleManualCheckUpdate = useCallback(() => {
    defaultUpdateCoordinator.checkForUpdates(true)
  }, [])


  const openFeedback = useCallback(async () => {
    const diagInfo = getSystemDiagnosticInfo(true)
    const formattedDiag = formatSystemInfoText(diagInfo)
    const subject = encodeURIComponent(`[Lives v${currentAppVersion}] 反馈`)
    const body = encodeURIComponent(`请描述你遇到的问题或功能建议：\n\n复现步骤：\n1. \n2. \n\n预期结果：\n\n实际结果：\n\n----------------------------------------\n设备与环境信息：\n${formattedDiag}\n----------------------------------------`)
    try {
      await openUrl(`mailto:ohmyangboy@gmail.com?subject=${subject}&body=${body}`, 'Mail')
      setFeedbackPopoverOpen(false)
    } catch {
      setNotice('无法打开邮件应用，请手动发送邮件至 ohmyangboy@gmail.com')
    }
  }, [])

  const openIssueFeedback = useCallback(async () => {
    const diagInfo = getSystemDiagnosticInfo(true)
    const formattedDiag = formatSystemInfoText(diagInfo)
    const issueTitle = encodeURIComponent(`[反馈] Lives v${currentAppVersion}`)
    const issueBody = encodeURIComponent(`### 问题描述 / 建议\n\n\n### 复现步骤\n1. \n2. \n\n### 预期效果与实际结果\n\n\n---\n### 设备与环境诊断信息\n\`\`\`text\n${formattedDiag}\n\`\`\``)
    try {
      await openUrl(`https://github.com/ohmyangboy/lives/issues/new?title=${issueTitle}&body=${issueBody}`)
      setFeedbackPopoverOpen(false)
    } catch {
      setNotice('无法打开 GitHub Issues，请访问 github.com/ohmyangboy/lives/issues')
    }
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
    const failureMessages: string[] = []
    const worker = async () => {
      while (cursor < accepted.length) {
        const index = cursor++
        const path = accepted[index]
        try {
          const info = await nativeService.inspect(path)
          if (info.durationMs < MINIMUM_SOURCE_DURATION_MS) throw new Error(`${path.split('/').pop() ?? '视频'} 只有 ${formatDuration(info.durationMs)}，至少需要 ${formatDuration(MINIMUM_SOURCE_DURATION_MS)}`)
          imported[index] = {
            id: crypto.randomUUID(), sourcePath: path, name: path.split('/').pop() ?? '视频', durationMs: info.durationMs,
            width: info.width, height: info.height, codec: info.codec, startTimeMs: 0,
            crop: { normalizedCenterX: 0.5, normalizedCenterY: 0.5, scale: 1 }, previewUrl: previewUrlForPath(path),
          }
        } catch (error) {
          failed += 1
          failureMessages.push(error instanceof Error ? error.message : '无法读取视频')
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
    if (failed) {
      const reason = [...new Set(failureMessages)].slice(0, 2).join('；')
      setNotice(successful.length ? `已添加 ${successful.length} 段视频；${failed} 段未添加：${reason}` : reason)
    }
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
      if (metadata.durationMs < MINIMUM_SOURCE_DURATION_MS) { URL.revokeObjectURL(url); setNotice(`${file.name} 只有 ${formatDuration(metadata.durationMs)}，至少需要 ${formatDuration(MINIMUM_SOURCE_DURATION_MS)}`); continue }
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

  const dismissFirstRunGuide = () => {
    try { localStorage.setItem(onboardingStorageKey, 'completed') } catch { /* The guide still closes for this session. */ }
    setFirstRunGuideVisible(false)
  }

  const handleFirstRunGuideKeyDown = (event: ReactKeyboardEvent<HTMLDivElement>) => {
    if (event.key === 'Escape') {
      event.preventDefault()
      dismissFirstRunGuide()
      return
    }
    if (event.key !== 'Tab') return
    const focusable = Array.from(firstRunDialogRef.current?.querySelectorAll<HTMLButtonElement>('button:not(:disabled)') ?? [])
    if (!focusable.length) return
    const first = focusable[0]
    const last = focusable[focusable.length - 1]
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault()
      first.focus()
    }
  }

  const importVideosFromFirstRunGuide = () => {
    dismissFirstRunGuide()
    void chooseVideos()
  }

  const importFolderFromFirstRunGuide = () => {
    dismissFirstRunGuide()
    void chooseSourceFolder()
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
      audioEnabled: false,
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
    if (!drag.active && Math.hypot(event.clientX - drag.startX, event.clientY - drag.startY) < 9) return
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

  useEffect(() => {
    const cancelDragOnEscape = (event: KeyboardEvent) => {
      if (event.key !== 'Escape' || !sourcePointerDragRef.current) return
      event.preventDefault()
      cancelSourcePointerDrag()
    }
    window.addEventListener('keydown', cancelDragOnEscape)
    return () => window.removeEventListener('keydown', cancelDragOnEscape)
  }, [])

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

  const handleClipContextMenu = useCallback((event: React.MouseEvent, clip: VideoClip) => {
    event.preventDefault()
    event.stopPropagation()
    const menuWidth = 170
    const menuHeight = 85
    const x = Math.min(event.clientX, window.innerWidth - menuWidth - 8)
    const y = Math.min(event.clientY, window.innerHeight - menuHeight - 8)
    setMaterialContextMenu({ x, y, clip })
  }, [])

  const handleRevealInFinder = useCallback(async (sourcePath: string) => {
    setMaterialContextMenu(undefined)
    if (!desktopAvailable()) {
      setNotice('关联本地文件需要在 Mac App 中使用')
      return
    }
    if (!sourcePath) {
      setNotice('无法定位该素材的原文件路径')
      return
    }
    try {
      await nativeService.revealInFinder(sourcePath)
    } catch (error) {
      setNotice(error instanceof Error ? error.message : '无法在 Finder 中定位该文件')
    }
  }, [])

  useEffect(() => {
    if (!appMenuOpen) return
    const handlePointerDown = (event: PointerEvent) => {
      if (appMenuRef.current && !appMenuRef.current.contains(event.target as Node)) {
        setAppMenuOpen(false)
      }
    }
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setAppMenuOpen(false)
    }
    window.addEventListener('pointerdown', handlePointerDown)
    window.addEventListener('keydown', handleKeyDown)
    return () => {
      window.removeEventListener('pointerdown', handlePointerDown)
      window.removeEventListener('keydown', handleKeyDown)
    }
  }, [appMenuOpen])

  useEffect(() => {
    if (!materialContextMenu) return
    const handleDismiss = () => setMaterialContextMenu(undefined)
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setMaterialContextMenu(undefined)
    }
    window.addEventListener('click', handleDismiss)
    window.addEventListener('contextmenu', handleDismiss)
    window.addEventListener('scroll', handleDismiss, true)
    window.addEventListener('keydown', handleKeyDown)
    return () => {
      window.removeEventListener('click', handleDismiss)
      window.removeEventListener('contextmenu', handleDismiss)
      window.removeEventListener('scroll', handleDismiss, true)
      window.removeEventListener('keydown', handleKeyDown)
    }
  }, [materialContextMenu])

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

  const clearCollage = () => {
    // Start a new collage while keeping the user's imported media and canvas preferences.
    // Slot placements contain the per-slot trim and crop state, so clearing them also
    // resets every assigned video's composition adjustments.
    setCoverTimeMs(1500)
    setSelectedSlotId(undefined)
    setSelectedMaterialId(undefined)
    setSourceDragFeedback(undefined)
    setSlotPlacements({})
    setDestinationPickerVisible(false)
    setNotice(undefined)
  }

  const exportProject = async (destination = exportDestination, folder = exportFolder) => {
    if (!canExport) { setNotice(desktopAvailable() ? `请把素材拖入“${currentTemplate.name}”的每个画面格` : '浏览器模式仅供预览，请在 Mac App 中导出'); return }
    let destinationFolder = folder
    if (destination === 'folder' && !destinationFolder) {
      destinationFolder = await chooseExportFolder()
      if (!destinationFolder) return
    }
    const project = createRenderProject(clips, templateId, slotClips, { aspectRatio, quality: exportQuality }, coverTimeMs)
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

  const handleTitlebarMouseDown = (event: React.MouseEvent<HTMLElement>) => {
    if (event.button !== 0) return
    if ((event.target as HTMLElement).closest('button, a, input, select, textarea, [role="menuitem"], [role="dialog"]')) return
    if (desktopAvailable()) void getCurrentWindow().startDragging()
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
  const canClearCollage = Boolean(Object.keys(slotPlacements).length || selectedSlotId || selectedMaterialId || coverTimeMs !== 1500)

  return (
    <main className={['app', isDragging && 'is-dragging', sourceDragFeedback && 'source-dragging'].filter(Boolean).join(' ')}>
      <header className="titlebar" data-tauri-drag-region onMouseDown={handleTitlebarMouseDown} onDoubleClick={(event) => {
        if (!(event.target as HTMLElement).closest('button')) toggleWindowZoom()
      }}>
        <div className="brand-menu-anchor" ref={appMenuRef}>
          <button className="brand-menu-button" onClick={() => setAppMenuOpen((current) => !current)} aria-expanded={appMenuOpen} aria-controls="app-menu-popover" title="展开 Lives 应用菜单">
            <span className="brand-mark"><LiveIcon /></span>
            <div><strong>Lives</strong><small>实况拼贴</small></div>
            <ChevronDownIcon className="brand-chevron" />
          </button>
          {appMenuOpen && <div className="app-menu-popover" id="app-menu-popover" role="menu" aria-label="Lives 应用程序菜单">
            <button className="app-menu-item" role="menuitem" onClick={() => { setAppMenuOpen(false); setAboutModalOpen(true) }}>
              <InfoIcon />
              <span>关于 Lives</span>
            </button>
            <button className="app-menu-item" role="menuitem" onClick={() => { setAppMenuOpen(false); void handleManualCheckUpdate() }}>
              <UpdateIcon />
              <span>检查更新...</span>
              <b className="app-menu-version">v{currentAppVersion}</b>
            </button>
            <div className="app-menu-divider" />
            <button className="app-menu-item" role="menuitem" onClick={() => { setAppMenuOpen(false); setFeedbackPopoverOpen(true) }}>
              <FeedbackIcon />
              <span>反馈与支持</span>
            </button>
            <button className="app-menu-item" role="menuitem" onClick={() => { setAppMenuOpen(false); void openUrl('https://github.com/ohmyangboy/lives') }}>
              <GithubIcon />
              <span>GitHub 仓库</span>
            </button>
          </div>}
        </div>
        <div className="project-meta"><span className={clips.length ? 'status-dot active' : 'status-dot'} />{projectSummary}</div>
        <div className="titlebar-actions">
          <UpdateCapsule coordinator={defaultUpdateCoordinator} />
          <div className="feedback-menu-anchor" ref={feedbackPopoverRef}>
            <button className="feedback-button" onClick={() => setFeedbackPopoverOpen((current) => !current)} aria-expanded={feedbackPopoverOpen} aria-controls="feedback-popover" title="联系 Lives"><FeedbackIcon />反馈</button>
            {feedbackPopoverOpen && <div className="feedback-popover" id="feedback-popover" role="dialog" aria-label="反馈与联系">
              <div className="feedback-popover-heading"><span className="eyebrow">反馈与联系</span><strong>选择联系我的方式</strong></div>
              <div className="feedback-channel-list">
                <button className="feedback-email-card" onClick={openFeedback}><FeedbackIcon /><span><strong>发送邮件</strong><small>ohmyangboy@gmail.com</small></span><b>打开 Mail</b></button>
                <button className="feedback-email-card feedback-issue-card" onClick={openIssueFeedback}><IssueIcon /><span><strong>GitHub Issue</strong><small>Bug 报告与功能建议</small></span><b>公开反馈</b></button>
              </div>
              <div className="feedback-social-card">
                <p className="feedback-support-hint">也可以在小红书联系我；如果 Lives 对你有帮助，欢迎通过微信赞赏支持后续开发。</p>
                <div className="feedback-code-grid">
                  <section className="feedback-code-card">
                    <span className="feedback-social-label">小红书</span>
                    <img className="feedback-qr-image" src={xiaohongshuContactImage} alt="小红书账号 oi一页风 的个人页二维码" />
                    <strong>oi一页风</strong>
                    <small>小红书号：<b>95393080312</b></small>
                  </section>
                  <section className="feedback-code-card feedback-wechat-card">
                    <span className="feedback-wechat-label">微信赞赏</span>
                    <img className="feedback-qr-image feedback-wechat-qr-image" src={wechatSponsorImage} alt="mugu 的微信赞赏码" />
                    <strong>支持 Lives</strong>
                    <small>微信扫一扫，感谢你的支持</small>
                  </section>
                </div>
              </div>
              <small className="feedback-privacy-note">发送截图或日志前，请先移除私人素材和个人信息。</small>
            </div>}
          </div>
          <button className="clear-project" disabled={!canClearCollage} onClick={clearCollage} title="保留素材，仅清除当前拼贴"><ClearIcon />清除拼贴</button>
          <button className="primary-button" disabled={!clips.length} onClick={requestExport}><ExportIcon />生成 Live Photo</button>
        </div>
      </header>

      <div className="workspace has-timeline">
          <aside className="left-panel">
            <div className="panel-heading material-panel-heading"><span className="eyebrow">01 / 素材</span><div className="panel-title-row"><h2>视频素材库</h2><div ref={libraryHelpRef} className="context-help-anchor">
              <button className="context-help-button" aria-label="查看素材库使用说明" aria-expanded={openHelpPopover === 'library'} aria-controls="library-help-popover" onClick={() => setOpenHelpPopover((current) => current === 'library' ? undefined : 'library')}><InfoIcon /></button>
              {openHelpPopover === 'library' && <div id="library-help-popover" className="context-help-popover library-help-popover">
                <div><FilmIcon /><p><strong>拖入画格</strong><span>同一素材可以重复使用，每个画格分别截取 3 秒片段。</span></p></div>
                <div><FolderIcon /><p><strong>只引用原文件</strong><span>不会复制、上传或修改视频。</span></p></div>
              </div>}
            </div></div></div>
            <div className="media-project-tabs" role="tablist" aria-label="素材项目">
              {mediaProjects.map((project) => <div key={project.id} className={project.id === activeProjectId ? 'media-project-tab selected' : 'media-project-tab'} title={project.folderPath ?? project.name}>
                <button role="tab" aria-selected={project.id === activeProjectId} className="media-project-select" onClick={() => { setActiveProjectId(project.id); setSelectedMaterialId(undefined) }}><span>{project.name}</span><b>{project.clipIds.length}</b></button>
                {project.clipIds.length > 0 && <button className="media-project-close" aria-label={`关闭项目 ${project.name}`} onClick={() => closeMediaProject(project.id)}><CloseIcon /></button>}
              </div>)}
            </div>
            {importProgress && <div className="material-import-status" role="progressbar" aria-label="导入视频" aria-valuemin={0} aria-valuemax={importProgress.total} aria-valuenow={importProgress.done}><i style={{ width: `${importProgress.total ? importProgress.done / importProgress.total * 100 : 0}%` }} /><span>正在导入 {importProgress.done} / {importProgress.total}</span></div>}
            <div className="clip-list material-library">
              {activeProjectClips.map((clip, index) => {
                const materialId = clip.id
                return <div key={materialId} role="button" tabIndex={0} aria-pressed={materialId === selectedMaterialId} aria-label={`${clip.name}，${formatDuration(clip.durationMs)}`} className={['clip-card', materialId === selectedMaterialId && 'selected', materialId === sourceDragFeedback?.materialId && 'dragging'].filter(Boolean).join(' ')} onKeyDown={(event) => { if ((event.key === 'Enter' || event.key === ' ') && !(event.target as HTMLElement).closest('button')) { event.preventDefault(); setSelectedMaterialId(materialId) } }} onPointerDown={(event) => beginSourcePointerDrag(event, materialId)} onPointerMove={moveSourcePointerDrag} onPointerUp={finishSourcePointerDrag} onPointerCancel={cancelSourcePointerDrag} onContextMenu={(event) => handleClipContextMenu(event, clip)}>
                  <span className="clip-index">{String(index + 1).padStart(2, '0')}</span>
                  <VideoCover src={clip.previewUrl} />
                  <span className="clip-copy"><strong>{clip.name}</strong><small>{formatDuration(clip.durationMs)} · {clip.width}×{clip.height}</small><em>拖入画面格</em></span>
                  <button className="remove-clip" aria-label={`移除 ${clip.name}`} onPointerDown={(event) => event.stopPropagation()} onClick={() => removeClip(clip.id)}><CloseIcon /></button>
                </div>
              })}
              {!activeProjectClips.length && <div className="project-empty"><FilmIcon /><strong>这个项目还没有视频</strong><span>{activeMediaProject.kind === 'folder' ? '重新导入文件夹，或切换其他项目。' : '添加视频后会显示在这里。'}</span></div>}
            </div>
            <div className="material-import-actions"><button onClick={() => void chooseVideos()}><PlusIcon />添加视频</button><button onClick={() => void chooseSourceFolder()}><FolderIcon />导入文件夹</button></div>
          </aside>

          <section className="center-panel">
            <div className="stage-heading"><div><span className="eyebrow">02 / 构图</span><h2>画布预览</h2></div></div>
            <CollagePreview clips={slotClips} template={currentTemplate} canvasWidth={canvas.width} canvasHeight={canvas.height} selectedSlotId={selectedSlotId} selectedSourceId={selectedMaterialId} pointerDropTargetSlotId={sourceDragFeedback?.overSlotId} isSourceDragging={Boolean(sourceDragFeedback)} coverTimeMs={coverTimeMs} onCoverTimeChange={setCoverTimeMs} onSelectSlot={setSelectedSlotId} onDropSource={placeMaterialInSlot} onClearSlot={clearSlot} onAudioEnabledChange={(slotId, audioEnabled) => updateSlotClip(slotId, (clip) => ({ ...clip, audioEnabled }))} onScaleChange={(slotId, scale) => updateSlotClip(slotId, (clip) => ({ ...clip, crop: { ...clip.crop, scale } }))} onCropChange={(slotId, x, y) => updateSlotClip(slotId, (clip) => ({ ...clip, crop: { ...clip.crop, normalizedCenterX: x, normalizedCenterY: y } }))} />
          </section>

          <aside className="right-panel">
            <div className="panel-heading"><span className="eyebrow">03 / 配置</span><h2>拼贴设置</h2></div>
            <div className="video-settings aspect-settings">
              <span className="eyebrow">画面比例</span>
              <div className="setting-row"><span><strong>画布方向</strong><small>横竖屏即时切换</small></span><div className="segmented compact" role="group" aria-label="画布方向"><button aria-pressed={canvasOrientation === 'portrait'} className={canvasOrientation === 'portrait' ? 'selected' : ''} onClick={() => changeCanvasOrientation('portrait')}>竖屏</button><button aria-pressed={canvasOrientation === 'landscape'} className={canvasOrientation === 'landscape' ? 'selected' : ''} onClick={() => changeCanvasOrientation('landscape')}>横屏</button></div></div>
              <div className="setting-row"><span><strong>场景比例</strong><small>同步调整预览与导出</small></span><div className="segmented compact" role="group" aria-label="场景比例">{visibleAspectRatios.map((option) => <button key={option.id} aria-pressed={aspectRatio === option.id} className={aspectRatio === option.id ? 'selected' : ''} onClick={() => setAspectRatio(option.id)}>{option.label}</button>)}</div></div>
            </div>
            <div className="template-list config-templates">
              <div className="section-label-with-help"><span className="eyebrow">拼贴模板</span><div ref={templateHelpRef} className="context-help-anchor">
                <button className="context-help-button compact" aria-label="查看拼贴模板使用说明" aria-expanded={openHelpPopover === 'templates'} aria-controls="template-help-popover" onClick={() => setOpenHelpPopover((current) => current === 'templates' ? undefined : 'templates')}><InfoIcon /></button>
                {openHelpPopover === 'templates' && <div id="template-help-popover" className="context-help-popover template-help-popover"><div><FilmIcon /><p><strong>自由安排素材</strong><span>从左侧拖入任意画格；同一视频可多次使用并截取不同瞬间。</span></p></div></div>}
              </div></div>
              {templates.map((template) => <button key={template.id} aria-pressed={template.id === templateId} className={template.id === templateId ? 'template-card selected' : 'template-card'} onClick={() => { setTemplateId(template.id); setSelectedSlotId(undefined) }}>
                <span className="template-mini">{template.slots.map((slot) => <i key={slot.id} style={{ left: `${slot.x * 100}%`, top: `${slot.y * 100}%`, width: `${slot.width * 100}%`, height: `${slot.height * 100}%` }} />)}</span>
                <span><strong>{template.name}</strong><small>{template.description}</small></span>
                <b>{template.requiredClipCount}</b>
              </button>)}
            </div>
          </aside>

          {selectedSlotClip ? <Timeline clip={selectedSlotClip} onChange={(startTimeMs) => updateSlotClip(selectedSlotClip.targetSlotId, (clip) => ({ ...clip, startTimeMs }))} /> : <TimelineEmpty />}
      </div>

      {startupPhase !== 'hidden' && <div className={startupPhase === 'leaving' ? 'startup-splash leaving' : 'startup-splash'} role="status" aria-label="Lives 正在启动">
        <span className="startup-mark" aria-hidden="true"><LiveIcon /></span>
      </div>}

      {startupPhase === 'hidden' && firstRunGuideVisible && <div className="first-run-overlay" onKeyDown={handleFirstRunGuideKeyDown}>
        <div ref={firstRunDialogRef} className="first-run-dialog" role="dialog" aria-modal="true" aria-labelledby="first-run-title" aria-describedby="first-run-description">
          <button className="first-run-close" aria-label="关闭引导" onClick={dismissFirstRunGuide}><CloseIcon /></button>
          <span className="first-run-mark" aria-hidden="true"><LiveIcon /></span>
          <span className="eyebrow">欢迎使用 Lives</span>
          <h2 id="first-run-title">导入素材，开始拼贴</h2>
          <p id="first-run-description">添加视频，或按文件夹创建素材项目。所有处理都在这台 Mac 上完成。</p>
          <div className="first-run-actions">
            <button ref={firstRunPrimaryRef} className="first-run-primary" onClick={importVideosFromFirstRunGuide}><PlusIcon /><span><strong>添加视频</strong><small>选择一个或多个视频</small></span></button>
            <button className="first-run-secondary" onClick={importFolderFromFirstRunGuide}><FolderIcon /><span><strong>导入文件夹</strong><small>按文件夹创建素材项目</small></span></button>
          </div>
          <small className="first-run-privacy">只引用原文件，不复制、不上传、不修改</small>
        </div>
      </div>}

      {notice && <div className="toast" role="status"><span>!</span>{notice}<button aria-label="关闭通知" onClick={() => setNotice(undefined)}><CloseIcon /></button></div>}
      {sourceDragFeedback && <div className={sourceDragFeedback.overSlotId ? 'source-drag-ghost over-target' : 'source-drag-ghost'} style={{ left: sourceDragFeedback.x, top: sourceDragFeedback.y }} aria-hidden="true">
        <video src={sourceDragFeedback.previewUrl} muted preload="metadata" />
        <span><strong>{sourceDragFeedback.name}</strong><small>{sourceDragFeedback.overSlotId ? '松开，放入此画面格' : '拖到中间的画面格'}</small></span>
        <b>{sourceDragFeedback.overSlotId ? '✓' : '+'}</b>
      </div>}
      {isDragging && <div className="drag-overlay"><PlusIcon /><strong>放下视频，加入素材库</strong><span>使用原文件，可一次添加多段视频</span></div>}
      <input ref={fileInputRef} hidden type="file" multiple accept="video/quicktime,video/mp4,.m4v" onChange={(event) => event.target.files && void importBrowserFiles(event.target.files)} />
      {destinationPickerVisible && <ExportDestinationPicker aspectRatio={aspectRatio} quality={exportQuality} sourceQuality={sourceQuality} cropUpscaleRisk={cropUpscaleRisk} destination={pickerDestination} onQualityChange={setExportQuality} onDestinationChange={setPickerDestination} onExport={() => void exportFromPicker()} onClose={() => setDestinationPickerVisible(false)} />}
      {exportState.visible && <ExportOverlay {...exportState} destination={exportDestination} onClose={() => setExportState(initialExport)} onCancel={() => { if (exportState.jobId) void nativeService.cancel(exportState.jobId); setExportState(initialExport) }} onRetry={() => void exportProject()} onOpenPrivacySettings={() => void nativeService.openPhotoPrivacySettings()} onFallbackToFolder={() => void exportToFolderInstead()} onRevealResult={() => exportDestination === 'photos' ? void nativeService.openPhotos() : exportState.outputPath ? void nativeService.revealInFinder(exportState.outputPath) : undefined} />}
      {materialContextMenu && (
        <div
          className="material-context-menu"
          style={{ left: materialContextMenu.x, top: materialContextMenu.y }}
          onContextMenu={(e) => e.preventDefault()}
        >
          <button
            className="context-menu-item"
            onClick={() => void handleRevealInFinder(materialContextMenu.clip.sourcePath)}
          >
            <FolderIcon />
            <span>在 Finder 中的位置</span>
          </button>
          <button
            className="context-menu-item danger"
            onClick={() => {
              const id = materialContextMenu.clip.id
              setMaterialContextMenu(undefined)
              removeClip(id)
            }}
          >
            <CloseIcon />
            <span>从素材库移除</span>
          </button>
        </div>
      )}
      {aboutModalOpen && <AboutModal onClose={() => setAboutModalOpen(false)} onNotice={setNotice} />}
    </main>
  )
}
