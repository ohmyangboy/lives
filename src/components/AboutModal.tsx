import { useEffect, useState } from 'react'
import { CloseIcon, InfoIcon, CopyIcon, CheckIcon } from '../icons'
import { loadSystemDiagnosticInfo, type SystemDiagnosticInfo } from '../systemInfo'

interface AboutModalProps {
  onClose: () => void
  onNotice?: (msg: string) => void
}

export function AboutModal({ onClose, onNotice }: AboutModalProps) {
  const [copied, setCopied] = useState(false)
  const [info, setInfo] = useState<SystemDiagnosticInfo | null>(null)

  useEffect(() => {
    let cancelled = false
    void loadSystemDiagnosticInfo(true).then((loaded) => {
      if (!cancelled) setInfo(loaded)
    })
    return () => { cancelled = true }
  }, [])

  const handleCopy = async () => {
    if (!info) return
    try {
      await navigator.clipboard.writeText(
        [
          `版本: ${info.appName} v${info.version}`,
          `运行环境: ${info.environment}`,
          `原生服务: ${info.nativeServiceStatus}`,
          `操作系统: ${info.platform}`,
          info.deviceModel ? `设备型号: ${info.deviceModel}` : undefined,
          `处理器: ${info.cpuDescription}`,
          info.memoryDescription ? `内存: ${info.memoryDescription}` : undefined,
          `主显示器: ${info.screenResolution} (@${info.devicePixelRatio})`,
          `系统语言/区域: ${info.language}`,
        ].filter(Boolean).join('\n'),
      )
      setCopied(true)
      onNotice?.('已复制版本与设备诊断信息')
      setTimeout(() => setCopied(false), 2000)
    } catch {
      onNotice?.('复制失败，请手动选择复制')
    }
  }

  return (
    <div className="about-overlay" onClick={onClose} role="dialog" aria-modal="true" aria-labelledby="about-title">
      <div className="about-dialog" onClick={(e) => e.stopPropagation()}>
        <button className="about-close" aria-label="关闭关于对话框" onClick={onClose}>
          <CloseIcon />
        </button>

        <div className="about-header">
          <div className="about-icon-badge">
            <InfoIcon />
          </div>
          <div className="about-title-group">
            <h2 id="about-title">Lives</h2>
            <p className="about-subtitle">从多个视频中截取 3 秒瞬间，拼贴为 Live Photo</p>
          </div>
        </div>

        <div className="about-body">
          <dl className="about-info-list">
            <div className="about-info-row">
              <dt>版本:</dt>
              <dd>Lives v{info?.version ?? '…'}</dd>
            </div>
            <div className="about-info-row">
              <dt>运行环境:</dt>
              <dd>{info?.environment ?? '…'}</dd>
            </div>
            <div className="about-info-row">
              <dt>原生服务:</dt>
              <dd>{info?.nativeServiceStatus ?? '…'}</dd>
            </div>
            <div className="about-info-row">
              <dt>操作系统:</dt>
              <dd>{info?.platform ?? '…'}</dd>
            </div>
            {info?.deviceModel && (
              <div className="about-info-row">
                <dt>设备型号:</dt>
                <dd>{info.deviceModel}</dd>
              </div>
            )}
            <div className="about-info-row">
              <dt>处理器:</dt>
              <dd>{info?.cpuDescription ?? '…'}</dd>
            </div>
            {info?.memoryDescription && (
              <div className="about-info-row">
                <dt>内存:</dt>
                <dd>{info.memoryDescription}</dd>
              </div>
            )}
            <div className="about-info-row">
              <dt>主显示器:</dt>
              <dd>{info ? `${info.screenResolution} (@${info.devicePixelRatio})` : '…'}</dd>
            </div>
            <div className="about-info-row">
              <dt>语言区域:</dt>
              <dd>{info?.language ?? '…'}</dd>
            </div>
          </dl>
        </div>

        <div className="about-footer">
          <button className="about-button secondary" onClick={onClose}>
            确定
          </button>
          <button className="about-button primary" onClick={() => void handleCopy()} disabled={!info}>
            {copied ? <CheckIcon /> : <CopyIcon />}
            <span>{copied ? '已复制' : '复制'}</span>
          </button>
        </div>
      </div>
    </div>
  )
}
