import { Box3, Vector3, type Group } from 'three'

export function normalizeFilmModel(model: Group) {
  const bounds = new Box3().setFromObject(model)
  const center = bounds.getCenter(new Vector3())
  const size = bounds.getSize(new Vector3())
  const extent = Math.max(size.x, size.y, size.z)
  if (!Number.isFinite(extent) || extent <= 0) throw new Error('Film model empty')
  const scale = 1 / extent
  // USDLoader already applies metersPerUnit; retain that authored scale.
  model.scale.multiplyScalar(scale)
  model.position.sub(center).multiplyScalar(scale)
}
