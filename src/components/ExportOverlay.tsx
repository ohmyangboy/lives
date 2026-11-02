import type { NativeStage } from '../nativeBridge'
import { CheckIcon, CloseIcon, FolderIcon, PhotosIcon } from '../icons'
import { useModalFocus } from './useModalFocus'

const labels: Record<NativeStage, string> = {
  inspecting: '检查素材', transcoding: '转换兼容格式', rendering: '合成视频', writingMetadata: '写入 Live 元数据', validating: '校验 Live Photo',
  requestingPhotoPermission: '请求照片权限', resettingPhotoPermission: '恢复照片授权', saving: '保存到“照片”', exportingFiles: '导出配对文件', verifyingSavedAsset: '确认 Live 状态', completed: '完成',
}

// 渐进降级阈值：用户在系统弹窗中拒绝达到该次数后，恢复卡片主按钮改为"改存到文件夹"。
export const PHOTO_DENY_DOWNGRADE_THRESHOLD = 2

interface Props {
  state: 'running' | 'success' | 'error'
  stage: NativeStage
  progress: number
  message?: string
  recovery?: string
  errorCode?: string
  destination: 'photos' | 'folder'
  outputPath?: string
  photoDenyCount: number
  onClose: () => void
  onCancel: () => void
  onRetry: () => void
  onResetAndRetry?: () => void
  onCopyRepairCommands: () => void
  onOpenPrivacySettings: () => void
  onFallbackToFolder: () => void
  onRevealResult: () => void
}

export function ExportOverlay({ state, stage, progress, message, recovery, errorCode, destination, outputPath, photoDenyCount, onClose, onCancel, onRetry, onResetAndRetry, onCopyRepairCommands, onOpenPrivacySettings, onFallbackToFolder, onRevealResult }: Props) {
  // 自动化恢复失败（含系统未弹窗自动拒绝）：引导复制命令走终端手动路径
  const isManualRecovery = errorCode === 'PHOTO_PERMISSION_PROMPT_SUPPRESSED' || errorCode === 'PHOTO_PERMISSION_RESET_FAILED'
  const isResetPending = errorCode === 'PHOTO_PERMISSION_RESET_PENDING'
  const isDenied = errorCode === 'PHOTO_PERMISSION_DENIED'
  const isPhotoPermissionError = isDenied || isManualRecovery || isResetPending
  const downgraded = photoDenyCount >= PHOTO_DENY_DOWNGRADE_THRESHOLD
  const modalRef = useModalFocus(state === 'running' ? undefined : onClose)
  return (
    <div ref={modalRef} className="overlay" role="dialog" aria-modal="true" aria-labelledby="export-status-title">
      <div className={`export-card${state === 'success' ? ' export-card-success' : ''}`}>
        {state !== 'running' && <button className="overlay-close" onClick={onClose} aria-label="关闭"><CloseIcon /></button>}
        {state === 'running' && <>
          <div className="processing-orbit" aria-hidden="true" />
          <h2 id="export-status-title">正在导出</h2>
          <p>{stage === 'requestingPhotoPermission' ? '请在系统弹窗中选择“允许”。' : stage === 'resettingPhotoPermission' ? '正在等待系统恢复授权，最多约 3 分钟，通常更快。' : '仅在本机处理，原始视频不会被修改。'}</p>
          <div className="export-progress-label"><span>{labels[stage]}</span><b>{Math.round(progress * 100)}%</b></div>
          <div className="export-progress" role="progressbar" aria-label={labels[stage]} aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(progress * 100)}><i style={{ width: `${progress * 100}%` }} /></div>
          <button className="secondary-button" onClick={onCancel}>{stage === 'resettingPhotoPermission' ? '取消恢复' : '取消生成'}</button>
        </>}
        {state === 'success' && <>
          <div className="export-success-heading">
            <div className="result-icon success"><CheckIcon /></div>
            <h2 id="export-status-title">{destination === 'photos' ? '已保存到照片' : '配对文件已保存'}</h2>
          </div>
          <p>{destination === 'photos' ? 'Live Photo 已保存，开启 iCloud 照片可同步到 iPhone。' : 'JPG 与 MOV 已保存。将两份文件同时导入“照片”即可查看 Live Photo。'}</p>
          <div className="export-success-actions">
            <button className="secondary-button" onClick={onClose}>继续编辑</button>
            <button className="primary-button" onClick={onRevealResult}>{destination === 'photos' ? <><PhotosIcon />打开“照片”</> : <><FolderIcon />在 Finder 中显示</>}</button>
          </div>
        </>}
        {state === 'error' && isDenied && !downgraded && <>
          <div className="result-icon permission"><PhotosIcon /></div>
          <h2 id="export-status-title">允许保存到“照片”</h2>
          <p>Lives 仅申请添加生成结果，不读取图库。若此前误点了拒绝，点击下方按钮可重新唤起系统授权弹窗；也可以直接改存到文件夹。</p>
          <button className="primary-button wide" onClick={onResetAndRetry ?? onRetry}>重新授权并保存</button>
          <button className="secondary-button wide" onClick={onFallbackToFolder}><FolderIcon />改存到文件夹</button>
          <button className="text-button" onClick={onCopyRepairCommands}>复制修复命令</button>
        </>}
        {state === 'error' && isDenied && downgraded && <>
          <div className="result-icon permission"><PhotosIcon /></div>
          <h2 id="export-status-title">允许保存到“照片”</h2>
          <p>已多次在系统弹窗中选择了“不允许”。若仍希望保存到“照片”，可点击下方按钮重新唤起授权框；也可以直接改存到文件夹。</p>
          <button className="primary-button wide" onClick={onFallbackToFolder}><FolderIcon />改存到文件夹</button>
          <button className="secondary-button wide" onClick={onResetAndRetry ?? onRetry}>重新授权并保存</button>
          <button className="text-button" onClick={onCopyRepairCommands}>复制修复命令</button>
        </>}
        {state === 'error' && isManualRecovery && <>
          <div className="result-icon permission"><PhotosIcon /></div>
          <h2 id="export-status-title">{errorCode === 'PHOTO_PERMISSION_PROMPT_SUPPRESSED' ? '系统没有弹出授权框' : '未能自动恢复照片授权'}</h2>
          <p>{recovery ?? '请在“终端”中执行修复命令后重试；也可以改为导出到文件夹。'}</p>
          <button className="primary-button wide" onClick={onCopyRepairCommands}>复制修复命令</button>
          <button className="secondary-button wide" onClick={onResetAndRetry ?? onRetry}>重新授权并保存</button>
          <button className="text-button" onClick={onFallbackToFolder}>改存到文件夹</button>
        </>}
        {state === 'error' && isResetPending && <>
          <div className="result-icon permission"><PhotosIcon /></div>
          <h2 id="export-status-title">授权状态同步较慢</h2>
          <p>{recovery ?? '重置已提交并继续在后台生效。请稍候后点击“重新尝试”，通常下一次就会弹出授权框。'}</p>
          <button className="primary-button wide" onClick={onRetry}>重新尝试</button>
          <button className="secondary-button wide" onClick={onFallbackToFolder}><FolderIcon />改存到文件夹</button>
          <button className="text-button" onClick={onCopyRepairCommands}>复制修复命令</button>
        </>}
        {state === 'error' && !isPhotoPermissionError && <>
          <div className="result-icon error">!</div>
          <h2 id="export-status-title">导出失败</h2>
          <p className="export-error-message">{message ?? '生成 Live Photo 失败'}</p>
          <p>{recovery ?? '项目仍然保留，你可以检查素材后重试。'}</p>
          <button className="primary-button wide" onClick={onRetry}>重新尝试</button>
          {destination === 'photos' && errorCode?.startsWith('PHOTO_PERMISSION_') && <button className="secondary-button wide" onClick={onFallbackToFolder}><FolderIcon />改存到文件夹</button>}
          <button className="text-button" onClick={onClose}>返回编辑</button>
        </>}
      </div>
    </div>
  )
}
