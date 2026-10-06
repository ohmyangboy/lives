import { describe, expect, it } from 'vitest'
import { Box3, BoxGeometry, Group, Mesh, Vector3 } from 'three'
import { normalizeFilmModel } from './filmObjectGeometry'

describe('original USDZ model framing', () => {
  it.each([.001, .01])('retains authored unit scaling (%s meters per unit)', (metersPerUnit) => {
    const model = new Group()
    const geometry = new BoxGeometry(26, 48, 34)
    const mesh = new Mesh(geometry)
    mesh.position.set(8, 24, -5)
    model.add(mesh)
    model.scale.setScalar(metersPerUnit)
    normalizeFilmModel(model)
    const bounds = new Box3().setFromObject(model)
    const size = bounds.getSize(new Vector3())
    const center = bounds.getCenter(new Vector3())
    expect(Math.max(size.x, size.y, size.z)).toBeCloseTo(1)
    expect(center.length()).toBeCloseTo(0)
    expect(size.x / size.y).toBeCloseTo(26 / 48)
    geometry.dispose()
  })
})
