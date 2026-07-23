import { useState } from 'react'
import { CloseIcon, InfoIcon, CopyIcon, CheckIcon } from '../icons'
import { getSystemDiagnosticInfo, formatSystemInfoText } from '../systemInfo'

interface AboutModalProps {
  onClose: () => void
  onNotice?: (msg: string) => void
}

export function AboutModal({ onClose, onNotice }: AboutModalProps) {
  const [copied, setCopied] = useState(false)
  const info = getSystemDiagnosticInfo(true)

  const handleCopy = async () => {
    const text = formatSystemInfoText(info)
    try {
      await navigator.clipboard.writeText(text)
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
              <dd>Lives v{info.version}</dd>
            </div>
            <div className="about-info-row">
              <dt>运行环境:</dt>
              <dd>{info.environment}</dd>
            </div>
            <div className="about-info-row">
              <dt>原生服务:</dt>
              <dd>{info.nativeServiceStatus}</dd>
            </div>
            <div className="about-info-row">
              <dt>系统平台:</dt>
              <dd>{info.platform}</dd>
            </div>
            <div className="about-info-row">
              <dt>显示分辨率:</dt>
              <dd>{info.screenResolution} (@{info.devicePixelRatio})</dd>
            </div>
            <div className="about-info-row">
              <dt>硬件架构:</dt>
              <dd>{info.cpuThreads}</dd>
            </div>
            <div className="about-info-row">
              <dt>语言区域:</dt>
              <dd>{info.language}</dd>
            </div>
            <div className="about-info-row user-agent-row">
              <dt>User Agent:</dt>
              <dd title={info.userAgent}>{info.userAgent}</dd>
            </div>
          </dl>
        </div>

        <div className="about-footer">
          <button className="about-button secondary" onClick={onClose}>
            确定
          </button>
          <button className="about-button primary" onClick={() => void handleCopy()}>
            {copied ? <CheckIcon /> : <CopyIcon />}
            <span>{copied ? '已复制' : '复制'}</span>
          </button>
        </div>
      </div>
    </div>
  )
}
