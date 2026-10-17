import type { PropsWithChildren, ReactNode } from 'react'
import { AlertTriangle, Inbox, LoaderCircle, RefreshCw } from 'lucide-react'

export function PageHeader({
  title,
  description,
  actions,
}: {
  title: string
  description: string
  actions?: ReactNode
}) {
  return (
    <div className="page-header">
      <div>
        <h1>{title}</h1>
        <p>{description}</p>
      </div>
      {actions && <div className="page-actions">{actions}</div>}
    </div>
  )
}

export function Section({
  title,
  description,
  actions,
  children,
}: PropsWithChildren<{ title: string; description?: string; actions?: ReactNode }>) {
  return (
    <section className="section">
      <div className="section-header">
        <div>
          <h2>{title}</h2>
          {description && <p>{description}</p>}
        </div>
        {actions && <div className="section-actions">{actions}</div>}
      </div>
      {children}
    </section>
  )
}

export function LoadingState({ label = 'Veriler yükleniyor' }: { label?: string }) {
  return (
    <div className="state-panel" role="status">
      <LoaderCircle className="spin" size={24} />
      <strong>{label}</strong>
    </div>
  )
}

export function ErrorState({ error, retry }: { error: unknown; retry?: () => void }) {
  const message = error instanceof Error ? error.message : 'Beklenmeyen bir hata oluştu'
  return (
    <div className="state-panel error-panel" role="alert">
      <AlertTriangle size={24} />
      <div>
        <strong>Veriler alınamadı</strong>
        <span>{message}</span>
      </div>
      {retry && (
        <button className="secondary-button" type="button" onClick={retry}>
          <RefreshCw size={16} />
          Yeniden dene
        </button>
      )}
    </div>
  )
}

export function EmptyState({ label }: { label: string }) {
  return (
    <div className="state-panel">
      <Inbox size={24} />
      <strong>{label}</strong>
    </div>
  )
}

export function StatusBadge({
  children,
  tone = 'neutral',
}: PropsWithChildren<{ tone?: 'neutral' | 'success' | 'warning' | 'danger' | 'info' }>) {
  return <span className={`status-badge ${tone}`}>{children}</span>
}

export function formatDate(value?: string) {
  if (!value) return '-'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return new Intl.DateTimeFormat('tr-TR', {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(date)
}

