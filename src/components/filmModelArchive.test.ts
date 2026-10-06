import { readFileSync } from 'node:fs'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { Box3, BufferAttribute, Mesh, Vector3 } from 'three'
import { USDLoader } from 'three/addons/loaders/USDLoader.js'
import { filmModelArchiveForLoader } from './filmModelArchive'
import { normalizeFilmModel } from './filmObjectGeometry'

afterEach(() => vi.unstubAllGlobals())

describe('original film model loading', () => {
  it.each(['LivesFilm', 'PreviewLoupe'])('loads finite geometry, normals and UVs from %s.usdz', (name) => {
    // Image decoding is verified in the browser; this checks the real USD data.
    vi.stubGlobal('Image', class { set src(_value: string) {} })
    const bytes = readFileSync(new URL(`../assets/models/${name}.usdz`, import.meta.url))
    const original = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer
    const before = Buffer.from(original).toString('base64')
    const model = new USDLoader().parse(filmModelArchiveForLoader(original))
    let meshes = 0
    let texturedMeshes = 0
    model.traverse((object) => {
      if (!(object instanceof Mesh)) return
      meshes += 1
      for (const attribute of Object.values(object.geometry.attributes)) {
        if (!(attribute instanceof BufferAttribute)) throw new Error('Unexpected USD vertex attribute')
        expect(Array.from(attribute.array).every(Number.isFinite), `${object.name} attribute`).toBe(true)
      }
      if ('map' in object.material && object.material.map) texturedMeshes += 1
      object.geometry.dispose()
    })
    normalizeFilmModel(model)
    const size = new Box3().setFromObject(model).getSize(new Vector3())
    expect(Math.max(size.x, size.y, size.z)).toBeCloseTo(1)
    expect(meshes).toBeGreaterThan(1)
    expect(texturedMeshes).toBeGreaterThan(0)
    expect(Buffer.from(original).toString('base64')).toBe(before)
  })
})
