export interface SourceRect {
  x: number
  y: number
  width: number
  height: number
}

/** Returns the centered source rectangle needed to aspect-fill a target. */
export const aspectFillSourceRect = (
  sourceWidth: number,
  sourceHeight: number,
  targetWidth: number,
  targetHeight: number,
): SourceRect => {
  const width = Math.max(1, sourceWidth)
  const height = Math.max(1, sourceHeight)
  const targetAspect = Math.max(1, targetWidth) / Math.max(1, targetHeight)
  const sourceAspect = width / height

  if (sourceAspect > targetAspect) {
    const croppedWidth = height * targetAspect
    return { x: (width - croppedWidth) / 2, y: 0, width: croppedWidth, height }
  }

  const croppedHeight = width / targetAspect
  return { x: 0, y: (height - croppedHeight) / 2, width, height: croppedHeight }
}
