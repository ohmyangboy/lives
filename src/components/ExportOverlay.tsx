import type { NativeStage } from '../nativeBridge'
import { CheckIcon, CloseIcon, FolderIcon, PhotosIcon } from '../icons'
import { useModalFocus } from './useModalFocus'

const labels: Record<NativeStage, string> = {
  inspecting: '检查素材', transcoding: '转换兼容格式', rendering: '合成视频', writingMetadata: '写入 Live 元数据', validating: '校验 Live Photo',
  requestingPhotoPermission: '请求照片权限', resettingPhotoPermission: '正在恢复照片授权（最多约 3 分钟，通常更快）', saving: '保存到“照片”', exportingFiles: '导出配对文件', verifyingSavedAsset: '确认 Live 状态', completed: '完成',
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
      <div className="export-card">
        {state !== 'running' && <button className="overlay-close" onClick={onClose} aria-label="关闭"><CloseIcon /></button>}
        {state === 'running' && <>
          <div className="processing-orbit"><span /><i /></div>
          <span className="eyebrow">正在生成 Live Photo</span>
          <h2 id="export-status-title">{labels[stage]}</h2>
          <p>{stage === 'requestingPhotoPermission' ? '请在系统弹窗中选择“允许”。所有处理均在这台 Mac 上完成，原始视频不会被修改。' : '所有处理均在这台 Mac 上完成，原始视频不会被修改。'}</p>
          <div className="export-progress" role="progressbar" aria-label={labels[stage]} aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(progress * 100)}><i style={{ width: `${progress * 100}%` }} /></div>
          <div className="export-progress-label"><span>{labels[stage]}</span><b>{Math.round(progress * 100)}%</b></div>
          <button className="secondary-button" onClick={onCancel}>{stage === 'resettingPhotoPermission' ? '取消恢复' : '取消生成'}</button>
        </>}
        {state === 'success' && <>
          <div className="result-icon success"><CheckIcon /></div>
          <span className="eyebrow">{destination === 'photos' ? '保存成功' : '导出成功'}</span>
          <h2 id="export-status-title">{destination === 'photos' ? '你的 Live Photo 已就绪' : '配对文件已保存'}</h2>
          <p>{destination === 'photos' ? '已保存为 Mac“照片”中的一个 Live 资产。开启 iCloud 照片后，它会自动同步到 iPhone。' : '已生成同名的 JPG 封面与 MOV 动态资源。可将两份文件同时拖入 Mac「照片」App 合成 Live Photo，或保留在同一文件夹中。'}</p>
          <button className="primary-button wide" onClick={onRevealResult}>{destination === 'photos' ? <><PhotosIcon />打开“照片”</> : <><FolderIcon />在 Finder 中显示</>}</button>
          <button className="text-button" onClick={onClose}>继续编辑</button>
        </>}
        {state === 'error' && isDenied && !downgraded && <>
          <div className="result-icon permission"><PhotosIcon /></div>
          <span className="eyebrow">需要你的授权</span>
          <h2 id="export-status-title">允许保存到“照片”</h2>
          <p>Lives 仅申请添加生成结果，不读取图库。若此前误点了拒绝，点击下方按钮可重新唤起系统授权弹窗；也可以直接改存到文件夹。</p>
          <button className="primary-button wide" onClick={onResetAndRetry ?? onRetry}>重新授权并保存</button>
          <button className="secondary-button wide" onClick={onFallbackToFolder}><FolderIcon />改存到文件夹</button>
          <button className="text-button" onClick={onCopyRepairCommands}>复制修复命令</button>
        </>}
        {state === 'error' && isDenied && downgraded && <>
          <div className="result-icon permission"><PhotosIcon /></div>
          <span className="eyebrow">需要你的授权</span>
          <h2 id="export-status-title">允许保存到“照片”</h2>
          <p>已多次在系统弹窗中选择了“不允许”。若仍希望保存到“照片”，可点击下方按钮重新唤起授权框；也可以直接改存到文件夹。</p>
          <button className="primary-button wide" onClick={onFallbackToFolder}><FolderIcon />改存到文件夹</button>
          <button className="secondary-button wide" onClick={onResetAndRetry ?? onRetry}>重新授权并保存</button>
          <button className="text-button" onClick={onCopyRepairCommands}>复制修复命令</button>
        </>}
        {state === 'error' && isManualRecovery && <>
          <div className="result-icon permission"><PhotosIcon /></div>
          <span className="eyebrow">需要你的授权</span>
          <h2 id="export-status-title">{errorCode === 'PHOTO_PERMISSION_PROMPT_SUPPRESSED' ? '系统没有弹出授权框' : '未能自动恢复照片授权'}</h2>
          <p>{recovery ?? '请在“终端”中执行修复命令后重试；也可以改为导出到文件夹。'}</p>
          <button className="primary-button wide" onClick={onCopyRepairCommands}>复制修复命令</button>
          <button className="secondary-button wide" onClick={onResetAndRetry ?? onRetry}>重新授权并保存</button>
          <button className="text-button" onClick={onFallbackToFolder}>改存到文件夹</button>
        </>}
        {state === 'error' && isResetPending && <>
          <div className="result-icon permission"><PhotosIcon /></div>
          <span className="eyebrow">系统同步中</span>
          <h2 id="export-status-title">授权状态同步较慢</h2>
          <p>{recovery ?? '重置已提交并继续在后台生效。请稍候后点击“重新尝试”，通常下一次就会弹出授权框。'}</p>
          <button className="primary-button wide" onClick={onRetry}>重新尝试</button>
          <button className="secondary-button wide" onClick={onFallbackToFolder}><FolderIcon />改存到文件夹</button>
          <button className="text-button" onClick={onCopyRepairCommands}>复制修复命令</button>
        </>}
        {state === 'error' && !isPhotoPermissionError && <>
          <div className="result-icon error">!</div>
          <span className="eyebrow">未能完成</span>
          <h2 id="export-status-title">{message ?? '生成 Live Photo 失败'}</h2>
          <p>{recovery ?? '项目仍然保留，你可以检查素材后重试。'}</p>
          <button className="primary-button wide" onClick={onRetry}>重新尝试</button>
          {destination === 'photos' && errorCode?.startsWith('PHOTO_PERMISSION_') && <button className="secondary-button wide" onClick={onFallbackToFolder}><FolderIcon />改存到文件夹</button>}
          <button className="text-button" onClick={onClose}>返回编辑</button>
        </>}
      </div>
    </div>
  )
}
