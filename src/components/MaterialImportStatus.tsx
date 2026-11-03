export type MaterialImportProgress =
  | { stage: 'scanning' | 'preparing' | 'photos' }
  | { stage: 'importing'; done: number; total: number }

interface MaterialImportStatusProps {
  progress: MaterialImportProgress
  onCancel: () => void
}

export function MaterialImportStatus({ progress, onCancel }: MaterialImportStatusProps) {
  const batch = progress.stage === 'importing' ? progress : undefined
  const message = batch
    ? `正在导入 ${batch.done} / ${batch.total}`
    : progress.stage === 'scanning'
      ? '正在扫描文件夹…'
      : progress.stage === 'photos'
        ? '等待照片选择或 iCloud 下载…'
        : '正在读取素材…'
  const busy = !batch || batch.done < batch.total

  return (
    <div className={`material-import-status${busy ? ' is-busy' : ''}`} title={progress.stage === 'photos' ? '正在等待照片选择或 iCloud 原片下载（最长 2 分钟）' : message}>
      <div
        className="material-import-track"
        role="progressbar"
        aria-label="素材导入进度"
        aria-valuemin={0}
        aria-valuemax={batch?.total}
        aria-valuenow={batch?.done}
        aria-valuetext={message}
      >
        <i className="material-import-fill" style={{ width: `${batch?.total ? batch.done / batch.total * 100 : 0}%` }} />
        {busy && <i className="material-import-sweep" />}
      </div>
      {busy && <span className="material-import-spinner" aria-hidden="true" />}
      <span className="material-import-message" role="status">{message}</span>
      {progress.stage === 'photos' && <button onClick={onCancel}>取消</button>}
    </div>
  )
}
