import type { NativeStage } from '../nativeBridge'
import { CheckIcon, CloseIcon, FolderIcon, PhotosIcon } from '../icons'
import { useModalFocus } from './useModalFocus'

const labels: Record<NativeStage, string> = {
  inspecting: '检查素材', transcoding: '转换兼容格式', rendering: '合成视频', writingMetadata: '写入 Live 元数据', validating: '校验 Live Photo',
  requestingPhotoPermission: '请求照片权限', saving: '保存到“照片”', exportingFiles: '导出配对文件', verifyingSavedAsset: '确认 Live 状态', completed: '完成',
}

interface Props {
  state: 'running' | 'success' | 'error'
  stage: NativeStage
  progress: number
  message?: string
  recovery?: string
  errorCode?: string
  destination: 'photos' | 'folder'
  outputPath?: string
  onClose: () => void
  onCancel: () => void
  onRetry: () => void
  onOpenPrivacySettings: () => void
  onFallbackToFolder: () => void
  onRevealResult: () => void
}

export function ExportOverlay({ state, stage, progress, message, recovery, errorCode, destination, onClose, onCancel, onRetry, onOpenPrivacySettings, onFallbackToFolder, onRevealResult }: Props) {
  const isPhotoPermissionError = errorCode === 'PHOTO_PERMISSION_DENIED'
  const modalRef = useModalFocus(state === 'running' ? undefined : onClose)
  return (
    <div ref={modalRef} className="overlay" role="dialog" aria-modal="true" aria-labelledby="export-status-title">
      <div className="export-card">
        {state !== 'running' && <button className="overlay-close" onClick={onClose} aria-label="关闭"><CloseIcon /></button>}
        {state === 'running' && <>
          <div className="processing-orbit"><span /><i /></div>
          <span className="eyebrow">正在生成 Live Photo</span>
          <h2 id="export-status-title">{labels[stage]}</h2>
          <p>所有处理均在这台 Mac 上完成，原始视频不会被修改。</p>
          <div className="export-progress" role="progressbar" aria-label={labels[stage]} aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(progress * 100)}><i style={{ width: `${progress * 100}%` }} /></div>
          <div className="export-progress-label"><span>{labels[stage]}</span><b>{Math.round(progress * 100)}%</b></div>
          <button className="secondary-button" onClick={onCancel}>取消生成</button>
        </>}
        {state === 'success' && <>
          <div className="result-icon success"><CheckIcon /></div>
          <span className="eyebrow">{destination === 'photos' ? '保存成功' : '导出成功'}</span>
          <h2 id="export-status-title">{destination === 'photos' ? '你的 Live Photo 已就绪' : '配对文件已保存'}</h2>
          <p>{destination === 'photos' ? '已保存为 Mac“照片”中的一个 Live 资产。开启 iCloud 照片后，它会自动同步到 iPhone。' : '已生成同名的 JPG 封面与 MOV 动态资源。请将这两个文件保留在同一文件夹中。'}</p>
          <button className="primary-button wide" onClick={onRevealResult}>{destination === 'photos' ? <><PhotosIcon />打开“照片”</> : <><FolderIcon />在 Finder 中显示</>}</button>
          <button className="text-button" onClick={onClose}>继续编辑</button>
        </>}
        {state === 'error' && isPhotoPermissionError && <>
          <div className="result-icon permission"><PhotosIcon /></div>
          <span className="eyebrow">需要你的授权</span>
          <h2 id="export-status-title">允许保存到“照片”</h2>
          <p>Lives 只请求向“照片”添加生成结果，不能读取、浏览或上传图库中的现有内容。授权会持续有效，直到你在“系统设置”中更改。</p>
          <button className="primary-button wide" onClick={onOpenPrivacySettings}>打开系统设置</button>
          <button className="secondary-button wide" onClick={onFallbackToFolder}><FolderIcon />改存到文件夹</button>
          <button className="text-button" onClick={onRetry}>我已授权，重新尝试</button>
        </>}
        {state === 'error' && !isPhotoPermissionError && <>
          <div className="result-icon error">!</div>
          <span className="eyebrow">未能完成</span>
          <h2 id="export-status-title">{message ?? '生成 Live Photo 失败'}</h2>
          <p>{recovery ?? '项目仍然保留，你可以检查素材后重试。'}</p>
          <button className="primary-button wide" onClick={onRetry}>重新尝试</button>
          <button className="text-button" onClick={onClose}>返回编辑</button>
        </>}
      </div>
    </div>
  )
}
