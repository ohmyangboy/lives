import { currentAppVersion } from './releaseUpdate'
import { desktopAvailable } from './nativeBridge'

export interface SystemDiagnosticInfo {
  appName: string
  version: string
  environment: string
  nativeServiceStatus: string
  userAgent: string
  platform: string
  language: string
  screenResolution: string
  devicePixelRatio: string
  cpuThreads: string
}

export function getSystemDiagnosticInfo(nativeServiceReady = true): SystemDiagnosticInfo {
  const isDesktop = desktopAvailable()
  return {
    appName: 'Lives',
    version: currentAppVersion,
    environment: isDesktop ? 'macOS (Tauri 桌面应用)' : 'Web 浏览器预览',
    nativeServiceStatus: isDesktop ? (nativeServiceReady ? 'Swift LivePhotoService (已就绪)' : '未就绪 / 异常') : 'N/A (Web 模式)',
    userAgent: typeof navigator !== 'undefined' ? navigator.userAgent : '未知',
    platform: typeof navigator !== 'undefined' ? (navigator.platform || 'macOS') : 'macOS',
    language: typeof navigator !== 'undefined' ? navigator.language : 'zh-CN',
    screenResolution: typeof window !== 'undefined' ? `${window.screen.width} × ${window.screen.height}` : '未知',
    devicePixelRatio: typeof window !== 'undefined' ? `${window.devicePixelRatio || 1}x` : '1x',
    cpuThreads: typeof navigator !== 'undefined' && navigator.hardwareConcurrency ? `${navigator.hardwareConcurrency} 核心` : '未知',
  }
}

export function formatSystemInfoText(info: SystemDiagnosticInfo): string {
  return [
    `版本: ${info.appName} v${info.version}`,
    `运行环境: ${info.environment}`,
    `原生服务: ${info.nativeServiceStatus}`,
    `操作系统/平台: ${info.platform}`,
    `显示分辨率: ${info.screenResolution} (@${info.devicePixelRatio})`,
    `处理器: ${info.cpuThreads}`,
    `系统语言: ${info.language}`,
    `User Agent: ${info.userAgent}`,
  ].join('\n')
}
