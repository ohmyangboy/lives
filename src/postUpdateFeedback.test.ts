import { afterEach, describe, expect, it, vi } from 'vitest'
import { clearPostUpdateFeedbackFlag, hasPendingPostUpdateFeedback, POST_UPDATE_FEEDBACK_KEY } from './postUpdateFeedback'

afterEach(() => vi.unstubAllGlobals())

describe('更新后的反馈提示标记', () => {
  it('普通启动不提示，更新后可重复读取，展示并清除后不再提示', () => {
    const values = new Map<string, string>()
    vi.stubGlobal('localStorage', {
      getItem: (key: string) => values.get(key) ?? null,
      removeItem: (key: string) => values.delete(key),
    })
    expect(hasPendingPostUpdateFeedback()).toBe(false)
    values.set(POST_UPDATE_FEEDBACK_KEY, '1')
    expect(hasPendingPostUpdateFeedback()).toBe(true)
    expect(hasPendingPostUpdateFeedback()).toBe(true)
    clearPostUpdateFeedbackFlag()
    expect(hasPendingPostUpdateFeedback()).toBe(false)
  })

  it('存储不可用时不提示且不阻碍启动', () => {
    vi.stubGlobal('localStorage', {
      getItem: () => { throw new Error('storage unavailable') },
      removeItem: () => { throw new Error('storage unavailable') },
    })
    expect(hasPendingPostUpdateFeedback()).toBe(false)
    expect(() => clearPostUpdateFeedbackFlag()).not.toThrow()
  })
})
