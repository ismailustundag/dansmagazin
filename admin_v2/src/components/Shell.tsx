import { useState } from 'react'
import type { PropsWithChildren } from 'react'
import {
  Bell,
  CalendarDays,
  ChartNoAxesCombined,
  ClipboardList,
  FileText,
  LayoutDashboard,
  Menu,
  MessageSquareText,
  Settings,
  ShoppingBag,
  Store,
  Users,
  X,
} from 'lucide-react'
import { useQuery } from '@tanstack/react-query'
import { api } from '../api'
import { FeedbackCenter } from '../feedback'
import type { Account } from '../types'
import { useI18n } from '../i18n'

const navigation = [
  { to: '/overview', label: 'overview', icon: LayoutDashboard },
  { to: '/events', label: 'events', icon: CalendarDays },
  { to: '/guests', label: 'guests', icon: ClipboardList },
  { to: '/users', label: 'users', icon: Users },
  { to: '/feed', label: 'feed', icon: MessageSquareText },
  { to: '/news', label: 'news', icon: FileText },
  { to: '/store', label: 'store', icon: Store },
  { to: '/polls', label: 'polls', icon: ChartNoAxesCombined },
  { to: '/notifications', label: 'notifications', icon: Bell },
  { to: '/reports', label: 'reports', icon: ShoppingBag },
  { to: '/settings', label: 'settings', icon: Settings },
] as const

export default function Shell({ children }: PropsWithChildren) {
  const { language, setLanguage, t } = useI18n()
  const [menuOpen, setMenuOpen] = useState(false)
  const activePath = window.location.pathname.replace(/^\/admin-v2/, '') || '/overview'
  const { data: account } = useQuery({
    queryKey: ['me'],
    queryFn: () => api<Account>('/me'),
  })

  return (
    <div className="app-shell">
      <header className="mobile-header">
        <button
          className="icon-button"
          type="button"
          aria-label={t('openMenu')}
          title={t('menu')}
          onClick={() => setMenuOpen(true)}
        >
          <Menu size={20} />
        </button>
        <div className="mobile-brand">
          <span className="brand-mark">DM</span>
          <strong>{t('managementPanel')}</strong>
        </div>
        <span className="mobile-account">{account?.name || account?.email || ''}</span>
      </header>

      {menuOpen && (
        <button
          type="button"
          className="menu-scrim"
          aria-label={t('closeMenu')}
          onClick={() => setMenuOpen(false)}
        />
      )}

      <aside className={`sidebar ${menuOpen ? 'is-open' : ''}`}>
        <div className="sidebar-head">
          <div className="brand">
            <span className="brand-mark">DM</span>
            <div>
              <strong>Dansmagazin</strong>
              <span>{t('managementPanel')}</span>
            </div>
          </div>
          <button
            className="icon-button sidebar-close"
            type="button"
            aria-label={t('closeMenu')}
            title={t('close')}
            onClick={() => setMenuOpen(false)}
          >
            <X size={20} />
          </button>
        </div>

        <div className="admin-language-switcher" aria-label="Language">
          {([['tr', '🇹🇷'], ['en', '🇬🇧'], ['es', '🇪🇸']] as const).map(([code, flag]) => (
            <button key={code} type="button" className={language === code ? 'is-active' : ''} aria-label={code.toUpperCase()} aria-pressed={language === code} onClick={() => setLanguage(code)}>{flag}</button>
          ))}
        </div>

        <nav className="sidebar-nav" aria-label={t('adminMenu')}>
          {navigation.map(({ to, label, icon: Icon }) => (
            <a
              key={to}
              href={`/admin-v2${to}`}
              onClick={() => setMenuOpen(false)}
              className={activePath === to ? 'active' : ''}
            >
              <Icon size={18} aria-hidden="true" />
              <span>{t(label)}</span>
            </a>
          ))}
        </nav>

        <div className="sidebar-account">
          <span className="account-avatar">{(account?.name || account?.email || 'Y').slice(0, 1)}</span>
          <div>
            <strong>{account?.name || t('administrator')}</strong>
            <span>{account?.email || t('loadingSession')}</span>
          </div>
          <a href="/logout" title={t('signOut')}>{t('signOut')}</a>
        </div>
      </aside>

      <main className="main-content">
        <FeedbackCenter />
        {children}
      </main>
    </div>
  )
}
