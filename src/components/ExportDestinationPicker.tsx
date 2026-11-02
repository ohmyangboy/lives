import { CheckIcon, CloseIcon, FolderIcon, PhotosIcon } from '../icons'
import { canvasDimensions, type AspectRatioId, type ExportQuality, type CanvasSettings, type SourceQualityAnalysis } from '../domain'
import { useModalFocus } from './useModalFocus'

export type ExportDestinationChoice = 'photos' | 'folder'

interface Props {
  aspectRatio: AspectRatioId
  customRatio?: { width: number; height: number }
  quality: ExportQuality
  sourceQuality: SourceQualityAnalysis
  sources: CanvasSettings['sources']
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

export function ExportDestinationPicker({ aspectRatio, customRatio, quality, sourceQuality, sources, cropUpscaleRisk, destination, onQualityChange, onDestinationChange, onExport, onClose }: Props) {
  const balanced = canvasDimensions({ aspectRatio, quality: 'balanced', customRatio, sources })
  const best = canvasDimensions({ aspectRatio, quality: 'best', customRatio, sources })
  const modalRef = useModalFocus(onClose)

  return <div ref={modalRef} className="overlay destination-overlay" role="dialog" aria-modal="true" aria-labelledby="export-destination-title">
    <div className="destination-card">
      <button className="overlay-close" onClick={onClose} aria-label="关闭"><CloseIcon /></button>
      <h2 id="export-destination-title">导出 Live Photo</h2>
      <section className="export-quality-picker" aria-label="导出质量">
        <header><strong>画质</strong><span>素材：{sourceQuality.sourceLabel.replace(/ 素材$/, '')}</span></header>
        <div className="export-quality-options">
          <button aria-pressed={quality === 'balanced'} className={quality === 'balanced' ? 'selected' : ''} onClick={() => onQualityChange('balanced')}><strong>均衡 <em>默认</em></strong><small>{balanced.width} × {balanced.height}</small></button>
          <button aria-pressed={quality === 'best'} className={quality === 'best' ? 'selected' : ''} onClick={() => onQualityChange('best')}><strong>最优</strong><small>{best.width} × {best.height}</small></button>
        </div>
        {cropUpscaleRisk && <small className="export-quality-note warning">部分素材或裁剪区域可能被放大，细节可能稍软。</small>}
        {balanced.width === best.width && balanced.height === best.height && <small className="export-quality-note">当前素材下，两档输出尺寸相同。</small>}
        <details className="export-quality-help"><summary>尺寸如何计算？</summary><p>素材等级按所用素材的最低原始短边标注。实际输出还受模板和裁剪影响；均衡采用 720 或 1080 短边，最优按素材计算，长边最多 3840 像素。</p></details>
      </section>
      <h3 className="destination-title">保存到</h3>
      <div className="destination-choices" role="radiogroup" aria-label="导出目标">
        <button role="radio" aria-checked={destination === 'photos'} className={destination === 'photos' ? 'selected' : ''} onClick={() => onDestinationChange('photos')}><PhotosIcon /><span><strong>照片</strong><small>Live Photo</small></span><i className="destination-selection" aria-hidden="true">{destination === 'photos' && <CheckIcon />}</i></button>
        <button role="radio" aria-checked={destination === 'folder'} className={destination === 'folder' ? 'selected' : ''} onClick={() => onDestinationChange('folder')}><FolderIcon /><span><strong>文件夹</strong><small>JPG + MOV</small></span><i className="destination-selection" aria-hidden="true">{destination === 'folder' && <CheckIcon />}</i></button>
      </div>
      <p className="destination-context">{destination === 'photos' ? '首次保存需照片授权。开启 iCloud 照片后可同步。' : 'JPG 与 MOV 配对保存，请将两份文件保留在同一文件夹。'}</p>
      <button className="primary-button wide destination-export" onClick={onExport}>{exportLabels[destination]}</button>
      <small className="destination-privacy">仅在本机处理</small>
    </div>
  </div>
}
