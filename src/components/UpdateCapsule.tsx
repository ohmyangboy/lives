import { useEffect, useState } from 'react'
import { CheckIcon, CloseIcon, RestartIcon, UpdateIcon } from '../icons'
import { UpdateCoordinator, type UpdateState } from '../releaseUpdate'

interface UpdateCapsuleProps {
  coordinator: UpdateCoordinator
}

export function UpdateCapsule({ coordinator }: UpdateCapsuleProps) {
  const [state, setState] = useState<UpdateState>(coordinator.state)
  const [showsUpToDateToast, setShowsUpToDateToast] = useState(false)

  useEffect(() => {
    return coordinator.subscribe(setState)
  }, [coordinator])

  useEffect(() => {
    if (!coordinator.lastUpToDateNoticeAt) return
    setShowsUpToDateToast(true)
    const timer = window.setTimeout(() => {
      setShowsUpToDateToast(false)
    }, 3000)
    return () => window.clearTimeout(timer)
  }, [coordinator.lastUpToDateNoticeAt])

  switch (state.kind) {
    case 'idle':
    case 'checkingSilently':
      if (showsUpToDateToast) {
        return (
          <div className="update-capsule up-to-date" role="status" aria-label="已是最新版本">
            <CheckIcon className="update-icon" />
            <span>已是最新版本</span>
          </div>
        )
      }
      return null

    case 'checking':
      return (
        <div className="update-capsule checking" role="status" aria-label="正在检查更新">
          <span className="update-spinner" aria-hidden="true" />
          <span>检查中...</span>
        </div>
      )

    case 'upToDate':
      if (showsUpToDateToast) {
        return (
          <div className="update-capsule up-to-date" role="status" aria-label="已是最新版本">
            <CheckIcon className="update-icon" />
            <span>已是最新版本</span>
          </div>
        )
      }
      return null

    case 'updateAvailable':
      return (
        <div className="update-capsule update-available" role="region" aria-label={`发现新版本 v${state.release.version}`}>
          <button
            className="update-action-btn"
            onClick={() => coordinator.beginDownload(state.release)}
            title={`发现 Lives v${state.release.version}，点击下载更新`}
          >
            <UpdateIcon className="update-icon" />
            <span>更新</span>
            <b>v{state.release.version}</b>
          </button>
        </div>
      )

    case 'downloading': {
      const fraction = state.progress.fractionCompleted
      const percent = fraction !== undefined ? Math.round(fraction * 100) : undefined
      return (
        <div
          className="update-capsule downloading"
          role="progressbar"
          aria-label={`正在下载 Lives v${state.progress.release.version}`}
          aria-valuenow={percent ?? 0}
          aria-valuemin={0}
          aria-valuemax={100}
          title={`正在下载 Lives v${state.progress.release.version}...`}
        >
          {percent !== undefined ? (
            <>
              <div className="update-progress-bar">
                <div className="update-progress-fill" style={{ width: `${percent}%` }} />
              </div>
              <span className="update-progress-text">{percent}%</span>
            </>
          ) : (
            <>
              <span className="update-spinner" aria-hidden="true" />
              <span>下载中...</span>
            </>
          )}
        </div>
      )
    }

    case 'preparing': {
      const percent = Math.round(state.preparation.fractionCompleted * 100)
      return (
        <div className="update-capsule preparing" role="status" aria-label="正在准备更新">
          <div className="update-progress-bar">
            <div className="update-progress-fill" style={{ width: `${percent}%` }} />
          </div>
          <span>准备中...</span>
        </div>
      )
    }

    case 'readyToInstall':
      return (
        <div
          className="update-capsule ready-to-install"
          role="region"
          aria-label={`新版本 v${state.release.version} 已准备就绪`}
        >
          <button
            className="update-action-btn prominent"
            onClick={() => coordinator.installAndRelaunch()}
            title={`Lives v${state.release.version} 下载完成，点击立即重启并更新到最新版本`}
          >
            <RestartIcon className="update-icon" />
            <span>重启</span>
            <b>v{state.release.version}</b>
          </button>
        </div>
      )

    case 'installing':
    case 'relaunching':
      return (
        <div className="update-capsule installing" role="status" aria-label="正在重启更新">
          <span className="update-spinner" aria-hidden="true" />
          <span>正在重启...</span>
        </div>
      )

    case 'failed':
      return (
        <div className="update-capsule failed" role="alert" title={state.failure.message}>
          <button
            className="update-action-btn"
            onClick={() => coordinator.checkForUpdates(true)}
            title={`更新失败：${state.failure.message}。点击重试`}
          >
            <UpdateIcon className="update-icon" />
            <span>重试</span>
          </button>
          <button
            className="update-dismiss-btn"
            aria-label="关闭更新错误提示"
            onClick={() => coordinator.dismissFailure()}
          >
            <CloseIcon />
          </button>
        </div>
      )
  }
}
