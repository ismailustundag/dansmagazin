// @vitest-environment jsdom
import '@testing-library/jest-dom/vitest'
import { act, cleanup, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it } from 'vitest'
import { FeedbackCenter, showFeedback } from './feedback'

afterEach(() => {
  cleanup()
  sessionStorage.clear()
})

describe('global feedback', () => {
  it('shows mutation success messages', () => {
    render(<FeedbackCenter />)
    act(() => showFeedback('Etkinlik kaydedildi.'))
    expect(screen.getByRole('status')).toHaveTextContent('Etkinlik kaydedildi.')
  })

  it('restores feedback after a redirect', () => {
    sessionStorage.setItem('admin-v2-pending-feedback', JSON.stringify({ id: 1, message: 'Haber kaydedildi.', tone: 'success' }))
    render(<FeedbackCenter />)
    expect(screen.getByRole('status')).toHaveTextContent('Haber kaydedildi.')
    expect(sessionStorage.getItem('admin-v2-pending-feedback')).toBeNull()
  })
})
