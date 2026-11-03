import type { VideoClip } from './domain'

export type MediaSortKey = 'importedAt' | 'createdAt' | 'name' | 'duration'
export type SortDirection = 'asc' | 'desc'
export const mediaSortOptions: Array<{ key: MediaSortKey; label: string }> = [
  { key: 'importedAt', label: '导入时间' },
  { key: 'createdAt', label: '创建时间' },
  { key: 'name', label: '名称' },
  { key: 'duration', label: '时长' },
]
const names = new Intl.Collator('zh-CN', { numeric: true, sensitivity: 'base' })

export function sortMediaClips(clips: VideoClip[], key: MediaSortKey, direction: SortDirection): VideoClip[] {
  const sign = direction === 'asc' ? 1 : -1
  return clips.map((clip, index) => ({ clip, index })).sort((a, b) => {
    if (key === 'name') return names.compare(a.clip.name, b.clip.name) * sign || b.index - a.index
    if (key === 'createdAt') {
      const aDate = a.clip.createdAtMs, bDate = b.clip.createdAtMs
      const aKnown = typeof aDate === 'number' && Number.isFinite(aDate)
      const bKnown = typeof bDate === 'number' && Number.isFinite(bDate)
      if (aKnown !== bKnown) return aKnown ? -1 : 1
      if (aKnown && bKnown && aDate !== bDate) return (aDate - bDate) * sign
    } else if (key === 'duration' && a.clip.durationMs !== b.clip.durationMs) {
      return (a.clip.durationMs - b.clip.durationMs) * sign
    } else if (key === 'importedAt') {
      return ((a.clip.importedAtMs ?? 0) - (b.clip.importedAtMs ?? 0) || a.index - b.index) * sign
    }
    return (b.clip.importedAtMs ?? 0) - (a.clip.importedAtMs ?? 0) || b.index - a.index
  }).map(({ clip }) => clip)
}
