import { useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import {
  Bell,
  CalendarCheck,
  Check,
  ClipboardCopy,
  Eye,
  EyeOff,
  ListFilter,
  Pencil,
  Plus,
  RefreshCw,
  Search,
  Send,
  TicketCheck,
  Trash2,
  UserRoundCheck,
  Users,
  XCircle,
} from 'lucide-react'
import { z } from 'zod'
import { api, runAction } from './api'
import { showFeedback, showMutationError } from './feedback'
import {
  EmptyState,
  ErrorState,
  formatDate,
  LoadingState,
  PageHeader,
  Section,
  StatusBadge,
} from './components/ui'
import type { EventItem, GuestList, NotificationItem, UserItem } from './types'

type OverviewData = {
  metrics: {
    users: number
    active_events: number
    guest_lists: number
    pending_news: number
    push_tokens: number
  }
  recent_events: EventItem[]
  recent_notifications: NotificationItem[]
  photo_retirement: {
    face_matching_enabled: boolean
    event_photo_rows: number
    face_match_rows: number
  }
}

function useAction(action: string, invalidates: string[], successMessage = 'İşlem başarıyla tamamlandı.') {
  const client = useQueryClient()
  return useMutation({
    mutationFn: (payload: Record<string, unknown>) => runAction(action, payload),
    onSuccess: async () => {
      await Promise.all(invalidates.map((key) => client.invalidateQueries({ queryKey: [key] })))
      showFeedback(successMessage)
    },
    onError: showMutationError,
  })
}

export function OverviewPage() {
  const query = useQuery({ queryKey: ['overview'], queryFn: () => api<OverviewData>('/overview') })
  if (query.isLoading) return <LoadingState label="Genel bakış hazırlanıyor" />
  if (query.error || !query.data) return <ErrorState error={query.error} retry={() => query.refetch()} />
  const data = query.data
  const metrics = [
    { label: 'Aktif kullanıcı', value: data.metrics.users, icon: Users },
    { label: 'Aktif etkinlik', value: data.metrics.active_events, icon: CalendarCheck },
    { label: 'Davetli listesi', value: data.metrics.guest_lists, icon: UserRoundCheck },
    { label: 'Bekleyen haber', value: data.metrics.pending_news, icon: ListFilter },
    { label: 'Bildirim cihazı', value: data.metrics.push_tokens, icon: Bell },
  ]
  return (
    <>
      <PageHeader
        title="Genel Bakış"
        description="Canlı operasyonun kısa özeti ve bekleyen yönetim işleri."
        actions={
          <button className="icon-button bordered" type="button" title="Yenile" onClick={() => query.refetch()}>
            <RefreshCw size={18} />
          </button>
        }
      />
      <div className="metric-grid">
        {metrics.map(({ label, value, icon: Icon }) => (
          <div className="metric" key={label}>
            <Icon size={19} />
            <span>{label}</span>
            <strong>{value.toLocaleString('tr-TR')}</strong>
          </div>
        ))}
      </div>
      <div className="overview-grid">
        <Section title="Yaklaşan etkinlikler">
          <div className="dense-list">
            {data.recent_events.length === 0 && <EmptyState label="Etkinlik bulunamadı" />}
            {data.recent_events.map((event) => (
              <div className="dense-row" key={event.id}>
                <div>
                  <strong>{event.event_name || `Etkinlik #${event.id}`}</strong>
                  <span>{[event.city, event.venue].filter(Boolean).join(' · ') || 'Konum belirtilmemiş'}</span>
                </div>
                <time>{formatDate(event.start_at)}</time>
              </div>
            ))}
          </div>
        </Section>
        <Section title="Son bildirimler">
          <div className="dense-list">
            {data.recent_notifications.length === 0 && <EmptyState label="Bildirim geçmişi boş" />}
            {data.recent_notifications.map((item, index) => (
              <div className="dense-row" key={item.batch_id || index}>
                <div>
                  <strong>{item.title || 'Bildirim'}</strong>
                  <span>{item.body || item.route || 'İçerik yok'}</span>
                </div>
                <time>{formatDate(item.created_at)}</time>
              </div>
            ))}
          </div>
        </Section>
      </div>
      <Section title="Fotoğraf sistemi emeklilik durumu">
        <div className="retirement-line">
          <StatusBadge tone="success">Yüz eşleştirme kapalı</StatusBadge>
          <span>Etkinlik fotoğrafı: {data.photo_retirement.event_photo_rows}</span>
          <span>Yüz eşleşmesi: {data.photo_retirement.face_match_rows}</span>
        </div>
      </Section>
    </>
  )
}

export function EventsPage() {
  const [q, setQ] = useState('')
  const [status, setStatus] = useState('active')
  const query = useQuery({
    queryKey: ['events', q, status],
    queryFn: () => api<{ items: EventItem[]; total: number }>(`/events?q=${encodeURIComponent(q)}&status=${status}`),
  })
  const activeAction = useAction('event-active', ['events', 'overview'])
  const approveAction = useAction('event-approve', ['events', 'overview'], 'Etkinlik onaylandı ve aktif duruma alındı.')
  const rejectAction = useAction('event-reject', ['events', 'overview'], 'Etkinlik reddedildi.')
  const copyAction = useAction('event-copy', ['events', 'overview'])
  const deleteAction = useAction('event-delete', ['events', 'overview'])

  const toggleActive = (event: EventItem) =>
    activeAction.mutate({ id: event.id, active: !event.event_is_active })
  const approve = (event: EventItem) => {
    if (window.confirm(`${event.event_name || 'Etkinlik'} onaylanıp aktif duruma alınsın mı?`)) {
      approveAction.mutate({ id: event.id })
    }
  }
  const reject = (event: EventItem) => {
    const adminNote = window.prompt('Ret sebebini yazın:', '')
    if (adminNote === null) return
    rejectAction.mutate({ id: event.id, admin_note: adminNote.trim() })
  }
  const copy = (event: EventItem) => {
    if (window.confirm(`${event.event_name || 'Etkinlik'} kopyalansın mı?`)) copyAction.mutate({ id: event.id })
  }
  const remove = (event: EventItem) => {
    if (window.confirm(`${event.event_name || 'Etkinlik'} kalıcı olarak silinsin mi?`)) {
      deleteAction.mutate({ id: event.id })
    }
  }

  return (
    <>
      <PageHeader
        title="Etkinlik Yönetimi"
        description="Etkinlikleri ara, durumlarını değiştir, kopyala ve yönet."
        actions={
          <a className="primary-button" href="/admin-v2/events/new">
            <Plus size={17} />
            Etkinlik oluştur
          </a>
        }
      />
      <div className="toolbar">
        <label className="search-field">
          <Search size={17} />
          <input value={q} onChange={(event) => setQ(event.target.value)} placeholder="Ad, şehir veya ID ara" />
        </label>
        <div className="segmented" aria-label="Etkinlik durumu">
          {[
            ['active', 'Aktif'],
            ['inactive', 'Pasif'],
            ['pending', 'Bekleyen'],
            ['expired', 'Geçmiş'],
            ['all', 'Tümü'],
          ].map(([value, label]) => (
            <button
              type="button"
              className={status === value ? 'active' : ''}
              key={value}
              onClick={() => setStatus(value)}
            >
              {label}
            </button>
          ))}
        </div>
      </div>
      {query.isLoading && <LoadingState label="Etkinlikler yükleniyor" />}
      {query.error && <ErrorState error={query.error} retry={() => query.refetch()} />}
      {query.data && (
        <Section title={`${query.data.total} etkinlik`}>
          {query.data.items.length === 0 ? (
            <EmptyState label="Bu filtreye uygun etkinlik bulunamadı" />
          ) : (
            <div className="responsive-table">
              <table>
                <thead>
                  <tr>
                    <th>Etkinlik</th>
                    <th>Tarih</th>
                    <th>Konum</th>
                    <th>Durum</th>
                    <th className="actions-cell">İşlemler</th>
                  </tr>
                </thead>
                <tbody>
                  {query.data.items.map((event) => (
                    <tr key={event.id}>
                      <td data-label="Etkinlik">
                        <strong>{event.event_name || `Etkinlik #${event.id}`}</strong>
                        <small>#{event.id} · {event.organizer_name || event.submitter_name || 'Organizatör yok'}</small>
                      </td>
                      <td data-label="Tarih">{formatDate(event.start_at)}</td>
                      <td data-label="Konum">{[event.city, event.venue].filter(Boolean).join(' · ') || '-'}</td>
                      <td data-label="Durum">
                        {event.status === 'pending' ? (
                          <StatusBadge tone="warning">Onay bekliyor</StatusBadge>
                        ) : event.status === 'rejected' ? (
                          <StatusBadge tone="danger">Reddedildi</StatusBadge>
                        ) : event.status === 'expired' ? (
                          <StatusBadge tone="neutral">Geçmiş</StatusBadge>
                        ) : (
                          <StatusBadge tone={event.event_is_active ? 'success' : 'warning'}>
                            {event.event_is_active ? 'Aktif' : 'Pasif'}
                          </StatusBadge>
                        )}
                      </td>
                      <td data-label="İşlemler" className="actions-cell">
                        <a className="icon-button" title="Düzenle" href={`/admin-v2/events/${event.id}`}>
                          <Pencil size={17} />
                        </a>
                        {(event.status === 'approved' || event.status === 'expired') && (
                          <a
                            className="icon-button"
                            title={event.status === 'expired' ? 'Bilet ve davetli kayıtlarını izle' : 'Bilet ve davetli'}
                            href={`/admin-v2/events/${event.id}/operations`}
                          >
                            {event.status === 'expired' ? <Eye size={17} /> : <TicketCheck size={17} />}
                          </a>
                        )}
                        {event.status === 'pending' ? (
                          <>
                            <button className="icon-button success bordered" type="button" title="Onayla" onClick={() => approve(event)}>
                              <Check size={17} />
                            </button>
                            <button className="icon-button danger bordered" type="button" title="Reddet" onClick={() => reject(event)}>
                              <XCircle size={17} />
                            </button>
                          </>
                        ) : event.status === 'approved' ? (
                          <button
                            className="icon-button"
                            type="button"
                            title={event.event_is_active ? 'Pasife al' : 'Aktifleştir'}
                            onClick={() => toggleActive(event)}
                          >
                            {event.event_is_active ? <EyeOff size={17} /> : <Eye size={17} />}
                          </button>
                        ) : null}
                        <button className="icon-button" type="button" title="Kopyala" onClick={() => copy(event)}>
                          <ClipboardCopy size={17} />
                        </button>
                        <button className="icon-button danger" type="button" title="Sil" onClick={() => remove(event)}>
                          <Trash2 size={17} />
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </Section>
      )}
    </>
  )
}

const guestSchema = z.object({ name: z.string().trim().min(2, 'Liste adı en az 2 karakter olmalı') })
type GuestForm = z.infer<typeof guestSchema>

export function GuestsPage() {
  const client = useQueryClient()
  const query = useQuery({
    queryKey: ['guest-lists'],
    queryFn: () => api<{ items: GuestList[] }>('/guest-lists'),
  })
  const create = useAction('guest-create', ['guest-lists', 'overview'])
  const copy = useAction('guest-copy', ['guest-lists'])
  const remove = useAction('guest-delete', ['guest-lists', 'overview'])
  const { register, handleSubmit, reset, formState } = useForm<GuestForm>({
    resolver: zodResolver(guestSchema),
  })
  const submit = handleSubmit(async (values) => {
    await create.mutateAsync(values)
    reset()
    await client.invalidateQueries({ queryKey: ['guest-lists'] })
  })
  return (
    <>
      <PageHeader title="Davetli Yönetimi" description="Tekrar kullanılabilir listeleri oluşturun ve etkinliklere aktarın." />
      <Section title="Yeni davetli listesi">
        <form className="inline-form" onSubmit={submit}>
          <label>
            <span>Liste adı</span>
            <input {...register('name')} placeholder="Örn. Ankara Çarşamba" />
          </label>
          <button className="primary-button" type="submit" disabled={create.isPending}>
            <Plus size={17} />
            Oluştur
          </button>
          {formState.errors.name && <span className="field-error">{formState.errors.name.message}</span>}
        </form>
      </Section>
      {query.isLoading && <LoadingState label="Davetli listeleri yükleniyor" />}
      {query.error && <ErrorState error={query.error} retry={() => query.refetch()} />}
      {query.data && (
        <Section title={`${query.data.items?.length || 0} liste`}>
          {!query.data.items?.length ? (
            <EmptyState label="Henüz davetli listesi oluşturulmamış" />
          ) : (
            <div className="item-grid">
              {query.data.items.map((list) => (
                <article className="item-panel" key={list.guest_list_id}>
                  <div>
                    <strong>{list.name}</strong>
                    <span>{list.member_count || 0} kişi · {formatDate(list.updated_at)}</span>
                  </div>
                  <div className="item-actions">
                    <a className="secondary-button" href={`/admin-v2/guests/${list.guest_list_id}`}>
                      <Eye size={16} />
                      Düzenle
                    </a>
                    <button
                      className="icon-button bordered"
                      type="button"
                      title="Listeyi kopyala"
                      onClick={() => {
                        const name = window.prompt('Yeni listenin adı', `${list.name} Kopya`)?.trim()
                        if (name) copy.mutate({ id: list.guest_list_id, name })
                      }}
                    >
                      <ClipboardCopy size={17} />
                    </button>
                    <button
                      className="icon-button danger bordered"
                      type="button"
                      title="Listeyi sil"
                      onClick={() => {
                        if (window.confirm(`${list.name} silinsin mi?`)) remove.mutate({ id: list.guest_list_id })
                      }}
                    >
                      <Trash2 size={17} />
                    </button>
                  </div>
                </article>
              ))}
            </div>
          )}
        </Section>
      )}
    </>
  )
}

export function UsersPage() {
  const [q, setQ] = useState('')
  const [role, setRole] = useState('all')
  const [page, setPage] = useState(1)
  const query = useQuery({
    queryKey: ['users', q, role, page],
    queryFn: () =>
      api<{ items: UserItem[]; total: number; page: number; page_size: number }>(
        `/users?q=${encodeURIComponent(q)}&role=${role}&page=${page}&page_size=30`,
      ),
  })
  return (
    <>
      <PageHeader title="Kullanıcı Yönetimi" description="Hesapları, rolleri ve etkinlik yönetim yetkilerini denetleyin." />
      <div className="toolbar">
        <label className="search-field">
          <Search size={17} />
          <input
            value={q}
            onChange={(event) => {
              setQ(event.target.value)
              setPage(1)
            }}
            placeholder="Ad, e-posta, kullanıcı adı veya ID"
          />
        </label>
        <select value={role} onChange={(event) => setRole(event.target.value)} aria-label="Rol filtresi">
          <option value="all">Tüm roller</option>
          <option value="super_admin">Super admin</option>
          <option value="editor">Editör</option>
          <option value="customer">Kullanıcı</option>
        </select>
      </div>
      {query.isLoading && <LoadingState label="Kullanıcılar yükleniyor" />}
      {query.error && <ErrorState error={query.error} retry={() => query.refetch()} />}
      {query.data && (
        <Section title={`${query.data.total} kullanıcı`}>
          <div className="responsive-table">
            <table>
              <thead>
                <tr>
                  <th>Kullanıcı</th>
                  <th>Rol</th>
                  <th>Yetkiler</th>
                  <th>Kullanılan bilet</th>
                  <th>Durum</th>
                  <th className="actions-cell">İşlem</th>
                </tr>
              </thead>
              <tbody>
                {query.data.items.map((user) => (
                  <tr key={user.id}>
                    <td data-label="Kullanıcı">
                      <strong>{user.name || user.username || `Kullanıcı #${user.id}`}</strong>
                      <small>{user.email} · #{user.id}</small>
                    </td>
                    <td data-label="Rol"><StatusBadge tone="info">{user.role}</StatusBadge></td>
                    <td data-label="Yetkiler">
                      {Boolean(user.is_verified) && <StatusBadge tone="success">Doğrulanmış</StatusBadge>}{' '}
                      {Boolean(user.can_create_mobile_event) && <StatusBadge tone="neutral">Etkinlik</StatusBadge>}
                    </td>
                    <td data-label="Kullanılan bilet">
                      <strong>{user.used_ticket_count || 0}</strong>
                    </td>
                    <td data-label="Durum">
                      <StatusBadge tone={user.is_active ? 'success' : 'danger'}>
                        {user.is_active ? 'Aktif' : 'Pasif'}
                      </StatusBadge>
                    </td>
                    <td data-label="İşlem" className="actions-cell">
                      <a className="icon-button bordered" title="Kullanıcı ayrıntısı" href={`/admin-v2/users/${user.id}`}>
                        <Eye size={17} />
                      </a>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className="pagination">
            <button className="secondary-button" type="button" disabled={page <= 1} onClick={() => setPage((p) => p - 1)}>
              Önceki
            </button>
            <span>Sayfa {page}</span>
            <button
              className="secondary-button"
              type="button"
              disabled={page * query.data.page_size >= query.data.total}
              onClick={() => setPage((p) => p + 1)}
            >
              Sonraki
            </button>
          </div>
        </Section>
      )}
    </>
  )
}

type FeedPost = {
  id: number
  body?: string
  created_at?: string
  author_name?: string
  author_avatar_url?: string
  image_url?: string
}

export function FeedPage() {
  const query = useQuery({ queryKey: ['feed'], queryFn: () => api<{ items: FeedPost[] }>('/feed') })
  const remove = useAction('feed-delete', ['feed', 'overview'])
  return (
    <>
      <PageHeader title="Akış Yönetimi" description="Topluluk paylaşımlarını denetleyin. Etkinlik albümleri bu alana dahil değildir." />
      {query.isLoading && <LoadingState label="Akış yükleniyor" />}
      {query.error && <ErrorState error={query.error} retry={() => query.refetch()} />}
      {query.data && (
        <Section title={`${query.data.items?.length || 0} gönderi`}>
          {!query.data.items?.length ? <EmptyState label="Akışta gönderi yok" /> : (
            <div className="feed-list">
              {query.data.items.map((post) => (
                <article className="feed-row" key={post.id}>
                  {post.image_url && <img src={post.image_url} alt="" loading="lazy" />}
                  <div>
                    <strong>{post.author_name || 'Kullanıcı'}</strong>
                    <p>{post.body || 'Görsel paylaşımı'}</p>
                    <time>{formatDate(post.created_at)}</time>
                  </div>
                  <button
                    className="icon-button danger bordered"
                    type="button"
                    title="Gönderiyi sil"
                    onClick={() => {
                      if (window.confirm('Bu gönderi silinsin mi?')) remove.mutate({ id: post.id })
                    }}
                  >
                    <Trash2 size={17} />
                  </button>
                </article>
              ))}
            </div>
          )}
        </Section>
      )}
    </>
  )
}

type NewsItem = { id?: number; submission_id?: number; title?: string; status?: string; submitter_name?: string; created_at?: string }

export function NewsPage() {
  const query = useQuery({ queryKey: ['news'], queryFn: () => api<{ items: NewsItem[] }>('/news') })
  const approve = useAction('news-approve', ['news', 'overview'])
  const reject = useAction('news-reject', ['news', 'overview'])
  const remove = useAction('news-delete', ['news', 'overview'])
  return (
    <>
      <PageHeader
        title="Haber Yönetimi"
        description="Haber taleplerini inceleyin, yayınlayın veya reddedin."
        actions={<a className="primary-button" href="/admin-v2/news/new"><Plus size={17} />Haber oluştur</a>}
      />
      {query.isLoading && <LoadingState label="Haberler yükleniyor" />}
      {query.error && <ErrorState error={query.error} retry={() => query.refetch()} />}
      {query.data && (
        <Section title={`${query.data.items?.length || 0} haber`}>
          <div className="item-grid">
            {(query.data.items || []).map((item) => (
              <article className="item-panel" key={item.id || item.submission_id}>
                <div>
                  <strong>{item.title || `Haber #${item.id || item.submission_id}`}</strong>
                  <span>{item.submitter_name || 'Gönderen yok'} · {formatDate(item.created_at)}</span>
                  <StatusBadge tone={item.status === 'approved' ? 'success' : item.status === 'rejected' ? 'danger' : 'warning'}>
                    {item.status || 'pending'}
                  </StatusBadge>
                </div>
                <div className="item-actions">
                  <a className="icon-button bordered" title="Haberi düzenle" href={`/admin-v2/news/${item.id || item.submission_id}`}>
                    <Eye size={17} />
                  </a>
                  {item.status !== 'approved' && (
                    <button className="icon-button success bordered" type="button" title="Onayla" onClick={() => approve.mutate({ id: item.id || item.submission_id })}>
                      <Check size={17} />
                    </button>
                  )}
                  {item.status !== 'rejected' && (
                    <button className="secondary-button" type="button" onClick={() => reject.mutate({ id: item.id || item.submission_id })}>Reddet</button>
                  )}
                  <button className="icon-button danger bordered" type="button" title="Sil" onClick={() => remove.mutate({ id: item.id || item.submission_id })}>
                    <Trash2 size={17} />
                  </button>
                </div>
              </article>
            ))}
          </div>
        </Section>
      )}
    </>
  )
}

type StoreData = {
  sellers: { account_id: number; store_title?: string; name?: string; product_count?: number }[]
  products: { id: number; title?: string; price?: string; seller?: { name?: string }; is_sold?: boolean }[]
  event_products: {
    event_id: number
    event_name?: string
    description?: string
    event_date?: string
    status?: string
    ticket_sales_enabled?: boolean
    woo_product_id?: string
    ticket_url?: string
  }[]
}

export function StorePage() {
  const query = useQuery({ queryKey: ['store'], queryFn: () => api<StoreData>('/store') })
  return (
    <>
      <PageHeader title="Mağaza Yönetimi" description="Satıcıları ve yayındaki ürünleri tek ekrandan izleyin." />
      {query.isLoading && <LoadingState label="Mağaza verileri yükleniyor" />}
      {query.error && <ErrorState error={query.error} retry={() => query.refetch()} />}
      {query.data && (
        <>
          <Section title={`Mağazalar · ${query.data.sellers.length}`}>
            <div className="item-grid">
              {query.data.sellers.map((seller) => (
                <article className="item-panel" key={seller.account_id}>
                  <div>
                    <strong>{seller.store_title || seller.name || `Mağaza #${seller.account_id}`}</strong>
                    <span>{seller.product_count || 0} ürün</span>
                  </div>
                  <StatusBadge tone="success">Yayında</StatusBadge>
                </article>
              ))}
            </div>
          </Section>
          <Section title={`Ürünler · ${query.data.products.length}`}>
            <div className="responsive-table">
              <table>
                <thead><tr><th>Ürün</th><th>Satıcı</th><th>Fiyat</th><th>Durum</th></tr></thead>
                <tbody>
                  {query.data.products.map((product) => (
                    <tr key={product.id}>
                      <td data-label="Ürün"><strong>{product.title || `Ürün #${product.id}`}</strong></td>
                      <td data-label="Satıcı">{product.seller?.name || '-'}</td>
                      <td data-label="Fiyat">{product.price || '-'}</td>
                      <td data-label="Durum"><StatusBadge tone={product.is_sold ? 'warning' : 'success'}>{product.is_sold ? 'Satıldı' : 'Yayında'}</StatusBadge></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </Section>
          <Section title={`Etkinlik bilet ürünleri · ${query.data.event_products.length}`} description="Etkinlik biletleri normal mağaza ürünlerinden ayrı tutulur. Açıklama düzeltmek için etkinliği düzenleyin.">
            <div className="responsive-table">
              <table>
                <thead><tr><th>Etkinlik</th><th>Tarih</th><th>Woo ürün</th><th>Durum</th><th>İşlem</th></tr></thead>
                <tbody>
                  {query.data.event_products.map((product) => (
                    <tr key={`${product.event_id}-${product.woo_product_id}`}>
                      <td data-label="Etkinlik"><strong>{product.event_name || `Etkinlik #${product.event_id}`}</strong></td>
                      <td data-label="Tarih">{product.event_date || '-'}</td>
                      <td data-label="Woo ürün">{product.woo_product_id || '-'}</td>
                      <td data-label="Durum"><StatusBadge tone={product.ticket_sales_enabled ? 'success' : 'warning'}>{product.ticket_sales_enabled ? 'Satış açık' : 'Satış kapalı'}</StatusBadge></td>
                      <td data-label="İşlem"><a className="secondary-button" href={`/admin-v2/events/${product.event_id}`}>Etkinliği düzenle</a></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </Section>
        </>
      )}
    </>
  )
}

type PollItem = { id: number; question?: string; is_active?: boolean; total_votes?: number; created_at?: string }

export function PollsPage() {
  const query = useQuery({ queryKey: ['polls'], queryFn: () => api<{ items: PollItem[] }>('/polls') })
  const state = useAction('poll-state', ['polls'])
  const remove = useAction('poll-delete', ['polls'])
  return (
    <>
      <PageHeader
        title="Anket Yönetimi"
        description="Anketleri yayınlayın, durdurun ve sonuçları izleyin."
        actions={<a className="primary-button" href="/admin-v2/polls/new"><Plus size={17} />Anket oluştur</a>}
      />
      {query.isLoading && <LoadingState label="Anketler yükleniyor" />}
      {query.error && <ErrorState error={query.error} retry={() => query.refetch()} />}
      {query.data && (
        <Section title={`${query.data.items?.length || 0} anket`}>
          <div className="item-grid">
            {(query.data.items || []).map((poll) => (
              <article className="item-panel" key={poll.id}>
                <div>
                  <strong>{poll.question || `Anket #${poll.id}`}</strong>
                  <span>{poll.total_votes || 0} yanıt · {formatDate(poll.created_at)}</span>
                </div>
                <div className="item-actions">
                  <StatusBadge tone={poll.is_active ? 'success' : 'warning'}>{poll.is_active ? 'Yayında' : 'Kapalı'}</StatusBadge>
                  <button
                    className="icon-button bordered"
                    type="button"
                    title={poll.is_active ? 'Yayını durdur' : 'Yayınla'}
                    onClick={() => state.mutate({ id: poll.id, active: !poll.is_active })}
                  >
                    {poll.is_active ? <EyeOff size={17} /> : <Eye size={17} />}
                  </button>
                  <button className="icon-button danger bordered" type="button" title="Sil" onClick={() => remove.mutate({ id: poll.id })}>
                    <Trash2 size={17} />
                  </button>
                </div>
              </article>
            ))}
          </div>
        </Section>
      )}
    </>
  )
}

const notificationSchema = z.object({
  title: z.string().trim().min(2, 'Başlık gerekli').max(120),
  body: z.string().trim().min(2, 'Bildirim metni gerekli').max(500),
  route: z.string().trim().startsWith('/', 'Yönlendirme hedefi seçin').max(300),
})
type NotificationForm = z.infer<typeof notificationSchema>

type NotificationTarget = { route: string; label: string }
type NotificationData = {
  items: NotificationItem[]
  targets: {
    events: NotificationTarget[]
    news: NotificationTarget[]
    stores: NotificationTarget[]
    products: NotificationTarget[]
    polls: NotificationTarget[]
  }
}

export function NotificationsPage() {
  const [targetKind, setTargetKind] = useState('notifications')
  const query = useQuery({
    queryKey: ['notifications'],
    queryFn: () => api<NotificationData>('/notifications'),
  })
  const send = useAction('notification-send', ['notifications', 'overview'])
  const { register, handleSubmit, reset, setValue, watch, formState } = useForm<NotificationForm>({
    resolver: zodResolver(notificationSchema),
    defaultValues: { route: '/profile/notifications' },
  })
  const selectedRoute = watch('route')
  const targetGroups = {
    event: query.data?.targets.events || [],
    news: query.data?.targets.news || [],
    store: query.data?.targets.stores || [],
    product: query.data?.targets.products || [],
    poll: query.data?.targets.polls || [],
  }
  const selectedTargets = targetGroups[targetKind as keyof typeof targetGroups] || []
  const changeTargetKind = (kind: string) => {
    setTargetKind(kind)
    setValue('route', kind === 'notifications' ? '/profile/notifications' : '', { shouldValidate: true })
  }
  const submit = handleSubmit(async (values) => {
    if (!window.confirm('Bildirim hedef kullanıcılara gönderilsin mi?')) return
    await send.mutateAsync(values)
    reset({ title: '', body: '', route: '/profile/notifications' })
    setTargetKind('notifications')
  })
  return (
    <>
      <PageHeader title="Bildirim Yönetimi" description="Yönlendirme hedefiyle birlikte uygulama içi ve push bildirimi gönderin." />
      <Section title="Yeni bildirim">
        <form className="form-grid" onSubmit={submit}>
          <label>
            <span>Başlık</span>
            <input {...register('title')} placeholder="Bildirim başlığı" />
            {formState.errors.title && <small className="field-error">{formState.errors.title.message}</small>}
          </label>
          <label className="wide-field">
            <span>Bildirim metni</span>
            <textarea {...register('body')} rows={4} placeholder="Kullanıcılara gösterilecek mesaj" />
            {formState.errors.body && <small className="field-error">{formState.errors.body.message}</small>}
          </label>
          <label>
            <span>Yönlendirme türü</span>
            <select value={targetKind} onChange={(event) => changeTargetKind(event.target.value)}>
              <option value="notifications">Bildirim merkezi</option>
              <option value="event">Etkinlik</option>
              <option value="news">Haber</option>
              <option value="store">Mağaza</option>
              <option value="product">Ürün</option>
              <option value="poll">Anket</option>
              <option value="custom">Özel hedef</option>
            </select>
          </label>
          {targetKind !== 'notifications' && targetKind !== 'custom' && (
            <label>
              <span>Yönlendirme hedefi</span>
              <select value={selectedRoute} onChange={(event) => setValue('route', event.target.value, { shouldValidate: true })}>
                <option value="">Seçin</option>
                {selectedTargets.map((item) => <option key={item.route} value={item.route}>{item.label}</option>)}
              </select>
              {formState.errors.route && <small className="field-error">{formState.errors.route.message}</small>}
            </label>
          )}
          {targetKind === 'custom' && (
            <label>
              <span>Özel hedef</span>
              <input {...register('route')} placeholder="/events/215" />
              {formState.errors.route && <small className="field-error">{formState.errors.route.message}</small>}
            </label>
          )}
          {targetKind !== 'custom' && <input type="hidden" {...register('route')} />}
          <div className="form-footer wide-field">
            <span>{send.error instanceof Error ? send.error.message : ''}</span>
            <button className="primary-button" type="submit" disabled={send.isPending}>
              <Send size={17} />
              {send.isPending ? 'Kuyruğa alınıyor' : 'Gönder'}
            </button>
          </div>
        </form>
      </Section>
      {query.isLoading && <LoadingState label="Bildirim geçmişi yükleniyor" />}
      {query.error && <ErrorState error={query.error} retry={() => query.refetch()} />}
      {query.data && (
        <Section title="Gönderim geçmişi">
          <div className="dense-list">
            {(query.data.items || []).map((item, index) => (
              <div className="dense-row" key={item.batch_id || index}>
                <div>
                  <strong>{item.title || 'Bildirim'}</strong>
                  <span>{item.body || '-'} {item.route ? `· ${item.route}` : ''}</span>
                </div>
                <div className="row-meta">
                  <StatusBadge tone="info">{item.recipient_count || 0} alıcı</StatusBadge>
                  <time>{formatDate(item.created_at)}</time>
                </div>
              </div>
            ))}
          </div>
        </Section>
      )}
    </>
  )
}

type ReportData = {
  accounts: { total: number; active: number; editors: number }
  events: { total: number; approved: number; invitees: number; tickets: number }
  engagement: { feed_posts: number; messages: number; notifications: number }
}

export function ReportsPage() {
  const query = useQuery({ queryKey: ['reports'], queryFn: () => api<ReportData>('/reports') })
  const tiles = useMemo(() => {
    if (!query.data) return []
    return [
      ['Toplam kullanıcı', query.data.accounts.total],
      ['Aktif kullanıcı', query.data.accounts.active],
      ['Yönetici', query.data.accounts.editors],
      ['Etkinlik', query.data.events.total],
      ['Onaylı etkinlik', query.data.events.approved],
      ['Davetli kaydı', query.data.events.invitees],
      ['Bilet', query.data.events.tickets],
      ['Akış gönderisi', query.data.engagement.feed_posts],
      ['Mesaj', query.data.engagement.messages],
      ['Bildirim kaydı', query.data.engagement.notifications],
    ]
  }, [query.data])
  return (
    <>
      <PageHeader title="Raporlar" description="Operasyon, kullanıcı ve etkileşim verilerinin güncel özeti." />
      {query.isLoading && <LoadingState label="Raporlar hazırlanıyor" />}
      {query.error && <ErrorState error={query.error} retry={() => query.refetch()} />}
      <div className="report-grid">
        {tiles.map(([label, value]) => (
          <div className="report-tile" key={String(label)}>
            <span>{label}</span>
            <strong>{Number(value).toLocaleString('tr-TR')}</strong>
          </div>
        ))}
      </div>
    </>
  )
}

type SettingsData = {
  panel_version: string
  legacy_panel_available: boolean
  photo_system: Record<string, number | boolean>
}

export function SettingsPage() {
  const query = useQuery({ queryKey: ['settings'], queryFn: () => api<SettingsData>('/settings') })
  return (
    <>
      <PageHeader title="Sistem Ayarları" description="Panel sürümü, geçiş durumu ve emekliye ayrılan bileşenler." />
      {query.isLoading && <LoadingState label="Sistem durumu okunuyor" />}
      {query.error && <ErrorState error={query.error} retry={() => query.refetch()} />}
      {query.data && (
        <>
          <Section title="Panel">
            <dl className="definition-list">
              <div><dt>Sürüm</dt><dd>{query.data.panel_version}</dd></div>
              <div><dt>Eski panel</dt><dd><StatusBadge tone="warning">{query.data.legacy_panel_available ? 'Geçiş süresince açık' : 'Kapalı'}</StatusBadge></dd></div>
            </dl>
          </Section>
          <Section title="Fotoğraf sistemi">
            <dl className="definition-list">
              {Object.entries(query.data.photo_system).map(([key, value]) => (
                <div key={key}><dt>{key.replaceAll('_', ' ')}</dt><dd>{String(value)}</dd></div>
              ))}
            </dl>
          </Section>
          <Section title="Panel geçişi" description="Yönetim bağlantıları yeni panel içinde çalışır; eski panel bağlantıları kullanıcı arayüzünden kaldırılmıştır.">
            <StatusBadge tone="success">Admin V2 etkin</StatusBadge>
          </Section>
        </>
      )}
    </>
  )
}
