import appPackage from '../package.json'

const releaseApiUrl = 'https://api.github.com/repos/ohmyangboy/lives/releases/latest'
export const officialReleasePage = 'https://github.com/ohmyangboy/lives/releases/latest'
export const currentAppVersion = appPackage.version

export interface AvailableUpdate {
  version: string
  htmlUrl: string
  publishedAt?: string
}

interface GitHubRelease {
  tag_name?: unknown
  html_url?: unknown
  published_at?: unknown
  draft?: unknown
  prerelease?: unknown
}

type FetchLike = (input: RequestInfo | URL, init?: RequestInit) => Promise<Pick<Response, 'ok' | 'json'>>

const numericVersion = (value: string) => {
  const match = value.trim().match(/^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?$/i)
  if (!match) return undefined
  return [Number(match[1]), Number(match[2] ?? 0), Number(match[3] ?? 0)]
}

/** Returns a positive number only when `candidate` is newer than `current`. */
export const compareVersions = (candidate: string, current: string) => {
  const candidateParts = numericVersion(candidate)
  const currentParts = numericVersion(current)
  if (!candidateParts || !currentParts) return undefined
  for (let index = 0; index < candidateParts.length; index += 1) {
    if (candidateParts[index] !== currentParts[index]) return candidateParts[index] - currentParts[index]
  }
  return 0
}

export const checkForUpdate = async (fetcher: FetchLike = fetch): Promise<AvailableUpdate | undefined> => {
  const response = await fetcher(releaseApiUrl, {
    headers: { Accept: 'application/vnd.github+json' },
  })
  if (!response.ok) return undefined

  const release = await response.json() as GitHubRelease
  if (release.draft === true || release.prerelease === true || typeof release.tag_name !== 'string' || typeof release.html_url !== 'string') return undefined
  const comparison = compareVersions(release.tag_name, currentAppVersion)
  if (comparison === undefined || comparison <= 0) return undefined

  return {
    version: release.tag_name.replace(/^v/i, ''),
    htmlUrl: release.html_url,
    publishedAt: typeof release.published_at === 'string' ? release.published_at : undefined,
  }
}
