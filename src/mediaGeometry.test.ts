import { describe, expect, it } from 'vitest'
import { aspectFillSourceRect } from './mediaGeometry'

describe('aspectFillSourceRect', () => {
  it('keeps a matching landscape frame unchanged', () => {
    expect(aspectFillSourceRect(1920, 1080, 160, 90)).toEqual({
      x: 0,
      y: 0,
      width: 1920,
      height: 1080,
    })
  })

  it('center-crops a portrait frame without stretching it', () => {
    const rect = aspectFillSourceRect(1080, 1920, 160, 90)
    expect(rect.x).toBe(0)
    expect(rect.y).toBeCloseTo(656.25)
    expect(rect.width).toBe(1080)
    expect(rect.height).toBeCloseTo(607.5)
  })

  it('center-crops a square frame to the timeline aspect ratio', () => {
    const rect = aspectFillSourceRect(1000, 1000, 160, 90)
    expect(rect.x).toBe(0)
    expect(rect.y).toBeCloseTo(218.75)
    expect(rect.width).toBe(1000)
    expect(rect.height).toBeCloseTo(562.5)
  })
})
