import { currentAppVersion } from './releaseUpdate'
import { desktopAvailable, nativeService, type NativeSystemDiagnostics } from './nativeBridge'

// 反馈/关于里的设备信息必须来自本机 API：WebView 的 navigator.platform 恒为
// "MacIntel"、userAgent 恒为 "Intel Mac OS X 10_15_7"，都是假数据。
// 采集口径与 PaperRss 的 FeedbackDiagnosticsProvider 一致（ProcessInfo + sysctl + NSScreen）。

export interface SystemDiagnosticInfo {
  appName: string
  version: string
  environment: string
  nativeServiceStatus: string
  source: 'native' | 'webview'
  platform: string
  language: string
  screenResolution: string
  devicePixelRatio: string
  cpuDescription: string
  memoryDescription?: string
  deviceModel?: string
  userAgent?: string
}

export function getSystemDiagnosticInfo(nativeServiceReady = true): SystemDiagnosticInfo {
  const isDesktop = desktopAvailable()
  return {
    appName: 'Lives',
    version: currentAppVersion,
    environment: isDesktop ? 'macOS (Tauri 桌面应用)' : 'Web 浏览器预览',
    nativeServiceStatus: isDesktop ? (nativeServiceReady ? 'Swift LivePhotoService (已就绪)' : '未就绪 / 异常') : 'N/A (Web 模式)',
    source: 'webview',
    platform: typeof navigator !== 'undefined' ? (navigator.platform || 'macOS') : 'macOS',
    language: typeof navigator !== 'undefined' ? navigator.language : 'zh-CN',
    screenResolution: typeof window !== 'undefined' ? `${window.screen.width} × ${window.screen.height}` : '未知',
    devicePixelRatio: typeof window !== 'undefined' ? `${window.devicePixelRatio || 1}x` : '1x',
    cpuDescription: typeof navigator !== 'undefined' && navigator.hardwareConcurrency ? `${navigator.hardwareConcurrency} 核心` : '未知',
    userAgent: typeof navigator !== 'undefined' ? navigator.userAgent : '未知',
  }
}

function nativeInfoToDiagnostic(native: NativeSystemDiagnostics, nativeServiceReady: boolean): SystemDiagnosticInfo {
  const scale = native.displayScale
  const scaleText = scale === undefined ? '未知' : `${Number.isInteger(scale) ? scale : Number(scale.toFixed(1))}x`
  const memoryGB = native.physicalMemoryBytes !== undefined ? native.physicalMemoryBytes / (1024 * 1024 * 1024) : undefined
  const memoryText = memoryGB === undefined ? undefined : `${Number.isInteger(memoryGB) ? memoryGB : Math.round(memoryGB * 10) / 10} GB`
  const chipText = native.chipName ?? native.architecture ?? '未知'
  const architectureSuffix = native.chipName && native.architecture ? ` (${native.architecture})` : ''
  return {
    appName: 'Lives',
    version: currentAppVersion,
    environment: 'macOS (Tauri 桌面应用)',
    nativeServiceStatus: nativeServiceReady ? 'Swift LivePhotoService (已就绪)' : '未就绪 / 异常',
    source: 'native',
    platform: `macOS ${native.osVersion}${native.osBuild ? ` (${native.osBuild})` : ''}`,
    language: native.locale,
    screenResolution: native.displayResolution ?? '未知',
    devicePixelRatio: scaleText,
    cpuDescription: `${chipText}${architectureSuffix}, ${native.processorCount} 核`,
    memoryDescription: memoryText,
    deviceModel: native.deviceModel,
  }
}

// 原生采集失败或超时时回退到 WebView 数据（并保留标记，UI 会注明"仅供参考"）。
export async function loadSystemDiagnosticInfo(nativeServiceReady = true): Promise<SystemDiagnosticInfo> {
  if (!desktopAvailable()) return getSystemDiagnosticInfo(nativeServiceReady)
  const timeout = new Promise<null>((resolve) => setTimeout(() => resolve(null), 3000))
  const native = await Promise.race([nativeService.systemDiagnostics().catch(() => null), timeout])
  return native ? nativeInfoToDiagnostic(native, nativeServiceReady) : getSystemDiagnosticInfo(nativeServiceReady)
}

export function formatSystemInfoText(info: SystemDiagnosticInfo): string {
  if (info.source === 'native') {
    return [
      `版本: ${info.appName} v${info.version}`,
      `运行环境: ${info.environment}`,
      `原生服务: ${info.nativeServiceStatus}`,
      `操作系统: ${info.platform}`,
      info.deviceModel ? `设备型号: ${info.deviceModel}` : undefined,
      `处理器: ${info.cpuDescription}`,
      info.memoryDescription ? `内存: ${info.memoryDescription}` : undefined,
      `主显示器: ${info.screenResolution} (@${info.devicePixelRatio})`,
      `系统语言/区域: ${info.language}`,
    ].filter(Boolean).join('\n')
  }
  return [
    `版本: ${info.appName} v${info.version}`,
    `运行环境: ${info.environment}`,
    `原生服务: ${info.nativeServiceStatus}`,
    `操作系统/平台: ${info.platform}`,
    `显示分辨率: ${info.screenResolution} (@${info.devicePixelRatio})`,
    `处理器: ${info.cpuDescription}`,
    `系统语言: ${info.language}`,
    `User Agent: ${info.userAgent}`,
  ].join('\n')
}

export async function loadSystemDiagnosticText(nativeServiceReady = true): Promise<string> {
  return formatSystemInfoText(await loadSystemDiagnosticInfo(nativeServiceReady))
}
