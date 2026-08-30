import { CheckIcon, CloseIcon, FeedbackIcon } from '../icons'
import { useModalFocus } from './useModalFocus'

export const POST_UPDATE_FEEDBACK_KEY = 'lives.postUpdateFeedbackPending'

export function consumePostUpdateFeedbackFlag(): boolean {
  try {
    return localStorage.getItem(POST_UPDATE_FEEDBACK_KEY) === '1'
  } catch {
    return false
  }
}

export function clearPostUpdateFeedbackFlag(): void {
  try {
    localStorage.removeItem(POST_UPDATE_FEEDBACK_KEY)
  } catch {
    // 忽略存储不可用的情况
  }
}

interface Props {
  version: string
  onSendFeedback: () => void
  onClose: () => void
}

// 每次自动更新并重启后的首次启动弹出：告知更新完成，提示有问题可以联系开发者。
// 只在每次更新后出现一次（标记在展示时即被清除）。
export function PostUpdateFeedbackCard({ version, onSendFeedback, onClose }: Props) {
  const modalRef = useModalFocus(onClose)
  return (
    <div ref={modalRef} className="overlay" role="dialog" aria-modal="true" aria-labelledby="post-update-title">
      <div className="export-card">
        <button className="overlay-close" onClick={onClose} aria-label="关闭"><CloseIcon /></button>
        <div className="result-icon success"><CheckIcon /></div>
        <span className="eyebrow">更新完成</span>
        <h2 id="post-update-title">Lives 已更新到 v{version}</h2>
        <p>如果新版本遇到任何问题，或者有功能建议，欢迎随时联系我——每一条反馈我都会认真查看。</p>
        <button className="primary-button wide" onClick={onSendFeedback}><FeedbackIcon />反馈问题或联系开发者</button>
        <button className="text-button" onClick={onClose}>暂不需要</button>
      </div>
    </div>
  )
}
