import { useEffect, useState } from 'react'
import { AlertCircle, CheckCircle2, X } from 'lucide-react'

type FeedbackTone = 'success' | 'error'
type Feedback = { id: number; message: string; tone: FeedbackTone }

const FEEDBACK_EVENT = 'admin-v2-feedback'
const FEEDBACK_STORAGE_KEY = 'admin-v2-pending-feedback'

function createFeedback(message: string, tone: FeedbackTone): Feedback {
  return { id: Date.now(), message, tone }
}

export function showFeedback(message: string, tone: FeedbackTone = 'success') {
  window.dispatchEvent(new CustomEvent<Feedback>(FEEDBACK_EVENT, { detail: createFeedback(message, tone) }))
}

export function showMutationError(error: unknown) {
  showFeedback(error instanceof Error ? error.message : 'İşlem tamamlanamadı.', 'error')
}

export function redirectWithFeedback(path: string, message: string) {
  sessionStorage.setItem(FEEDBACK_STORAGE_KEY, JSON.stringify(createFeedback(message, 'success')))
  window.location.assign(path)
}

export function FeedbackCenter() {
  const [feedback, setFeedback] = useState<Feedback | null>(null)

  useEffect(() => {
    const pending = sessionStorage.getItem(FEEDBACK_STORAGE_KEY)
    if (pending) {
      sessionStorage.removeItem(FEEDBACK_STORAGE_KEY)
      try {
        setFeedback(JSON.parse(pending) as Feedback)
      } catch {
        sessionStorage.removeItem(FEEDBACK_STORAGE_KEY)
      }
    }
    const receive = (event: Event) => setFeedback((event as CustomEvent<Feedback>).detail)
    window.addEventListener(FEEDBACK_EVENT, receive)
    return () => window.removeEventListener(FEEDBACK_EVENT, receive)
  }, [])

  useEffect(() => {
    if (!feedback) return
    const timer = window.setTimeout(() => setFeedback(null), 5000)
    return () => window.clearTimeout(timer)
  }, [feedback])

  if (!feedback) return null
  const Icon = feedback.tone === 'success' ? CheckCircle2 : AlertCircle
  return (
    <div
      className={`feedback-toast ${feedback.tone}`}
      role={feedback.tone === 'error' ? 'alert' : 'status'}
      aria-live={feedback.tone === 'error' ? 'assertive' : 'polite'}
    >
      <Icon size={20} aria-hidden="true" />
      <strong>{feedback.message}</strong>
      <button className="icon-button" type="button" title="Bildirimi kapat" aria-label="Bildirimi kapat" onClick={() => setFeedback(null)}>
        <X size={17} />
      </button>
    </div>
  )
}
