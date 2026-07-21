import { useEffect, useRef } from 'react'

const focusableSelector = [
  'button:not([disabled])',
  '[href]',
  'input:not([disabled])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  '[tabindex]:not([tabindex="-1"])',
].join(',')

export function useModalFocus(onEscape?: () => void) {
  const modalRef = useRef<HTMLDivElement>(null)
  const onEscapeRef = useRef(onEscape)
  onEscapeRef.current = onEscape

  useEffect(() => {
    const modal = modalRef.current
    if (!modal) return
    const opener = document.activeElement instanceof HTMLElement ? document.activeElement : undefined
    const app = modal.closest('.app')
    const siblings = app ? Array.from(app.children).filter((element) => element !== modal) as HTMLElement[] : []
    const previousSiblingState = siblings.map((element) => ({
      element,
      inert: element.inert,
      ariaHidden: element.getAttribute('aria-hidden'),
    }))

    siblings.forEach((element) => {
      element.inert = true
      element.setAttribute('aria-hidden', 'true')
    })

    const focusableElements = () => Array.from(modal.querySelectorAll<HTMLElement>(focusableSelector))
    requestAnimationFrame(() => focusableElements()[0]?.focus())

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && onEscapeRef.current) {
        event.preventDefault()
        onEscapeRef.current()
        return
      }
      if (event.key !== 'Tab') return
      const focusable = focusableElements()
      if (!focusable.length) { event.preventDefault(); return }
      const first = focusable[0]
      const last = focusable[focusable.length - 1]
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault()
        first.focus()
      }
    }

    modal.addEventListener('keydown', handleKeyDown)
    return () => {
      modal.removeEventListener('keydown', handleKeyDown)
      previousSiblingState.forEach(({ element, inert, ariaHidden }) => {
        element.inert = inert
        if (ariaHidden === null) element.removeAttribute('aria-hidden')
        else element.setAttribute('aria-hidden', ariaHidden)
      })
      opener?.focus()
    }
  }, [])

  return modalRef
}
