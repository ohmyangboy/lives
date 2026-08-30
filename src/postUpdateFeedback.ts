export const POST_UPDATE_FEEDBACK_KEY = 'lives.postUpdateFeedbackPending'

// 读取不消费，避免 React StrictMode 重复初始化时提前丢失提示。
export function hasPendingPostUpdateFeedback(): boolean {
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
