import { unzipSync, zipSync } from 'three/addons/libs/fflate.module.js'

export function filmModelArchiveForLoader(buffer: ArrayBuffer): ArrayBuffer {
  const entries = unzipSync(new Uint8Array(buffer))
  let adjusted = false
  for (const name of Object.keys(entries)) {
    if (!name.endsWith('.usda')) continue
    const source = new TextDecoder().decode(entries[name])
    // Three's line parser treats inline array metadata as part of the array.
    // Expand its formatting in memory; retain the original geometry and values.
    const compatible = source.replace(/^(\s*[^\n=]+\[\]\s+[\w:]+\s*=\s*\[[^\n]*\])\s+\(\s*interpolation\s*=\s*"([^"]+)"\s*\)\s*$/gm,
      '$1 (\n                interpolation = "$2"\n            )')
    if (compatible !== source) {
      entries[name] = new TextEncoder().encode(compatible)
      adjusted = true
    }
  }
  if (!adjusted) return buffer
  const archive = zipSync(entries, { level: 0 })
  return archive.buffer.slice(archive.byteOffset, archive.byteOffset + archive.byteLength) as ArrayBuffer
}
