import { CloseIcon, FolderIcon, PhotosIcon } from '../icons'
import { canvasDimensions, type AspectRatioId, type ExportQuality, type SourceQualityAnalysis } from '../domain'
import { useModalFocus } from './useModalFocus'

export type ExportDestinationChoice = 'photos' | 'folder'

interface Props {
  aspectRatio: AspectRatioId
  customRatio?: { width: number; height: number }
  quality: ExportQuality
  sourceQuality: SourceQualityAnalysis
  cropUpscaleRisk: boolean
  destination: ExportDestinationChoice
  onQualityChange: (quality: ExportQuality) => void
  onDestinationChange: (destination: ExportDestinationChoice) => void
  onExport: () => void
  onClose: () => void
}

const exportLabels: Record<ExportDestinationChoice, string> = {
  photos: '导出到“照片”',
  folder: '选择文件夹并导出',
}

export function ExportDestinationPicker({ aspectRatio, customRatio, quality, sourceQuality, cropUpscaleRisk, destination, onQualityChange, onDestinationChange, onExport, onClose }: Props) {
  const high = canvasDimensions({ aspectRatio, quality: '1080p', customRatio })
  const compact = canvasDimensions({ aspectRatio, quality: '720p', customRatio })
  const modalRef = useModalFocus(onClose)

  return <div ref={modalRef} className="overlay destination-overlay" role="dialog" aria-modal="true" aria-labelledby="export-destination-title">
    <div className="destination-card">
      <button className="overlay-close" onClick={onClose} aria-label="关闭"><CloseIcon /></button>
      <span className="eyebrow">生成前确认</span>
      <h2 id="export-destination-title">导出 Live Photo</h2>
      <p>确认画质并选择保存位置后才会开始生成。</p>
      <section className="export-quality-picker" aria-label="导出质量">
        <header><div><strong>导出质量</strong><small>默认采用当前素材可用的最高画质</small></div><span>{sourceQuality.sourceLabel}</span></header>
        <div className="export-quality-options">
          <button className={quality === '1080p' ? 'selected' : ''} disabled={!sourceQuality.supports1080p} title={sourceQuality.supports1080p ? '保留高清细节' : `${sourceQuality.limitingSourceName ?? '当前素材'}不足 1080P`} onClick={() => onQualityChange('1080p')}><strong>1080P</strong><small>{high.width} × {high.height}</small><em>{sourceQuality.supports1080p ? sourceQuality.minimumShortEdge >= 2160 ? '应用上限' : '最高画质' : '素材不足'}</em></button>
          <button className={quality === '720p' ? 'selected' : ''} onClick={() => onQualityChange('720p')}><strong>720P</strong><small>{compact.width} × {compact.height}</small><em>{sourceQuality.recommendedQuality === '720p' ? '最高可用' : '更小文件'}</em></button>
        </div>
        <small className={cropUpscaleRisk ? 'export-quality-note warning' : 'export-quality-note'}>{cropUpscaleRisk ? '当前分辨率会放大部分素材或裁剪区域，细节可能稍软。' : sourceQuality.minimumShortEdge >= 2160 ? '当前版本最高导出 1080P；4K 素材会高质量缩小输出。' : sourceQuality.supports1080p ? '画质已匹配当前实际使用的素材。' : `受「${sourceQuality.limitingSourceName ?? '最低质量素材'}」限制，未提供 1080P 放大。`}</small>
      </section>
      <h3 className="destination-title">导出目标</h3>
      <div className="destination-choices" role="radiogroup" aria-label="导出目标">
        <button role="radio" aria-checked={destination === 'photos'} className={destination === 'photos' ? 'selected' : ''} onClick={() => onDestinationChange('photos')}><PhotosIcon /><span><strong>保存到“照片”</strong><small>生成可通过 iCloud 同步到 iPhone 的 Live Photo</small></span><i>默认</i></button>
        <button role="radio" aria-checked={destination === 'folder'} className={destination === 'folder' ? 'selected' : ''} onClick={() => onDestinationChange('folder')}><FolderIcon /><span><strong>保存到文件夹</strong><small>导出 JPG + MOV 配对文件，可自行归档</small></span></button>
      </div>
      <button className="primary-button wide destination-export" onClick={onExport}>{exportLabels[destination]}</button>
      <small className="destination-privacy">视频始终只在这台 Mac 上处理，不会上传。首次保存到“照片”会弹出系统授权框，请选择“允许”；若误点“不允许”，之后仍可在导出界面点击“重新授权并保存”恢复。</small>
    </div>
  </div>
}
