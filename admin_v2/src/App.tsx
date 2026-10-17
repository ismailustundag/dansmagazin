import type { ReactNode } from 'react'
import { I18nProvider } from './i18n'
import Shell from './components/Shell'
import {
  EventsPage,
  FeedPage,
  GuestsPage,
  NewsPage,
  NotificationsPage,
  OverviewPage,
  PollsPage,
  ReportsPage,
  SettingsPage,
  StorePage,
  UsersPage,
} from './pages'
import {
  EventFormPage,
  EventOperationsPage,
  GuestDetailPage,
  NewsFormPage,
  PollCreatePage,
  UserDetailPage,
} from './detailPages'

export default function App() {
  const path = window.location.pathname.replace(/^\/admin-v2\/?/, '/') || '/overview'
  const pages: Record<string, ReactNode> = {
    '/overview': <OverviewPage />,
    '/events': <EventsPage />,
    '/guests': <GuestsPage />,
    '/users': <UsersPage />,
    '/feed': <FeedPage />,
    '/news': <NewsPage />,
    '/store': <StorePage />,
    '/polls': <PollsPage />,
    '/notifications': <NotificationsPage />,
    '/reports': <ReportsPage />,
    '/settings': <SettingsPage />,
  }
  let page = pages[path]
  if (path === '/events/new') page = <EventFormPage />
  if (path === '/news/new') page = <NewsFormPage />
  if (path === '/polls/new') page = <PollCreatePage />

  const eventOperationsMatch = path.match(/^\/events\/(\d+)\/operations$/)
  if (eventOperationsMatch) page = <EventOperationsPage itemId={Number(eventOperationsMatch[1])} />

  const detailMatch = path.match(/^\/(events|guests|users|news)\/(\d+)$/)
  if (detailMatch) {
    const itemId = Number(detailMatch[2])
    if (detailMatch[1] === 'events') page = <EventFormPage itemId={itemId} />
    if (detailMatch[1] === 'guests') page = <GuestDetailPage itemId={itemId} />
    if (detailMatch[1] === 'users') page = <UserDetailPage itemId={itemId} />
    if (detailMatch[1] === 'news') page = <NewsFormPage itemId={itemId} />
  }

  return <I18nProvider><Shell>{page || <OverviewPage />}</Shell></I18nProvider>
}
