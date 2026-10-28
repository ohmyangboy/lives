const photoPattern = /\.(heic|heif|jpe?g)$/i
const movPattern = /\.mov$/i
const videoPattern = /\.(mov|mp4|m4v)$/i

// Pair before importing anything, so an unmatched photo never silently becomes a video.
export async function prepareFileImport<T extends { video: { path: string } }>(
  paths: string[],
  pairLivePhotos: (paths: string[]) => Promise<T[]>,
): Promise<{ paths: string[]; livePhotos: Map<string, T> }> {
  const unique = [...new Set(paths)]
  const photos = unique.filter((path) => photoPattern.test(path))
  const pairs = photos.length ? await pairLivePhotos([...photos, ...unique.filter((path) => movPattern.test(path))]) : []
  return {
    paths: unique.filter((path) => videoPattern.test(path)),
    livePhotos: new Map(pairs.map((pair) => [pair.video.path, pair])),
  }
}
