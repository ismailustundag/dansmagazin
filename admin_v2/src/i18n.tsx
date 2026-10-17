import { createContext, useContext, useMemo, useState } from 'react'
import type { PropsWithChildren } from 'react'

export type AdminLanguage = 'tr' | 'en' | 'es'

const dictionaries = {
  tr: {
    managementPanel: 'Yönetim Paneli', overview: 'Genel Bakış', events: 'Etkinlik Yönetimi',
    guests: 'Davetli Yönetimi', users: 'Kullanıcı Yönetimi', feed: 'Akış Yönetimi', news: 'Haber Yönetimi',
    store: 'Mağaza Yönetimi', polls: 'Anket Yönetimi', notifications: 'Bildirim Yönetimi', reports: 'Raporlar',
    settings: 'Sistem Ayarları', openMenu: 'Menüyü aç', closeMenu: 'Menüyü kapat', menu: 'Menü', close: 'Kapat',
    adminMenu: 'Yönetim menüsü', administrator: 'Yönetici', loadingSession: 'Oturum yükleniyor', signOut: 'Çıkış yap',
  },
  en: {
    managementPanel: 'Management Panel', overview: 'Overview', events: 'Event Management',
    guests: 'Guest Management', users: 'User Management', feed: 'Feed Management', news: 'News Management',
    store: 'Store Management', polls: 'Poll Management', notifications: 'Notification Management', reports: 'Reports',
    settings: 'System Settings', openMenu: 'Open menu', closeMenu: 'Close menu', menu: 'Menu', close: 'Close',
    adminMenu: 'Management menu', administrator: 'Administrator', loadingSession: 'Loading session', signOut: 'Sign out',
  },
  es: {
    managementPanel: 'Panel de Administración', overview: 'Resumen', events: 'Gestión de Eventos',
    guests: 'Gestión de Invitados', users: 'Gestión de Usuarios', feed: 'Gestión del Flujo', news: 'Gestión de Noticias',
    store: 'Gestión de Tienda', polls: 'Gestión de Encuestas', notifications: 'Gestión de Notificaciones', reports: 'Informes',
    settings: 'Ajustes del Sistema', openMenu: 'Abrir menú', closeMenu: 'Cerrar menú', menu: 'Menú', close: 'Cerrar',
    adminMenu: 'Menú de administración', administrator: 'Administrador', loadingSession: 'Cargando sesión', signOut: 'Cerrar sesión',
  },
} as const

type DictionaryKey = keyof typeof dictionaries.tr
type I18nContextValue = {
  language: AdminLanguage
  setLanguage: (language: AdminLanguage) => void
  t: (key: DictionaryKey) => string
}

const I18nContext = createContext<I18nContextValue | null>(null)

function initialLanguage(): AdminLanguage {
  const queryLanguage = new URLSearchParams(window.location.search).get('lang')?.toLowerCase()
  const storedLanguage = window.localStorage.getItem('admin-language')?.toLowerCase()
  const browserLanguage = window.navigator.language.toLowerCase().split('-', 1)[0]
  const candidate = queryLanguage || storedLanguage || browserLanguage
  const language = candidate === 'en' || candidate === 'es' ? candidate : 'tr'
  window.localStorage.setItem('admin-language', language)
  document.documentElement.lang = language
  return language
}

export function I18nProvider({ children }: PropsWithChildren) {
  const [language, updateLanguage] = useState<AdminLanguage>(initialLanguage)
  const value = useMemo<I18nContextValue>(() => ({
    language,
    setLanguage: (nextLanguage) => {
      window.localStorage.setItem('admin-language', nextLanguage)
      document.documentElement.lang = nextLanguage
      updateLanguage(nextLanguage)
    },
    t: (key) => dictionaries[language][key],
  }), [language])
  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>
}

export function useI18n() {
  const value = useContext(I18nContext)
  if (!value) throw new Error('useI18n must be used inside I18nProvider')
  return value
}
