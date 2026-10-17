import { useEffect, useRef, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { zodResolver } from '@hookform/resolvers/zod'
import { ArrowLeft, KeyRound, Plus, QrCode, Save, Search, TicketCheck, Trash2, UserMinus, UserPlus } from 'lucide-react'
import { useForm } from 'react-hook-form'
import { z } from 'zod'
import { api, apiForm, runAction } from './api'
import { redirectWithFeedback, showFeedback, showMutationError } from './feedback'
import { EmptyState, ErrorState, LoadingState, PageHeader, Section, StatusBadge, formatDate } from './components/ui'
import type { EventItem, UserItem } from './types'

const eventSchema = z.object({
  event_name: z.string(),
  default_language: z.enum(['tr', 'en', 'es']),
  event_name_tr: z.string(),
  description_tr: z.string(),
  program_text_tr: z.string(),
  event_name_en: z.string(),
  description_en: z.string(),
  program_text_en: z.string(),
  event_name_es: z.string(),
  description_es: z.string(),
  program_text_es: z.string(),
  city: z.string().trim().min(2, 'Şehir gerekli'),
  country_code: z.string().trim().regex(/^$|^[A-Za-z]{2}$/, 'İki harfli ülke kodu gerekli'),
  city_id: z.string(),
  event_date: z.string(),
  start_at: z.string(),
  end_at: z.string(),
  venue: z.string(),
  venue_map_url: z.string(),
  event_kind: z.string(),
  dance_styles: z.string(),
  organizer_name: z.string(),
  entry_fee: z.string(),
  description: z.string(),
  program_text: z.string(),
  ticket_sales_enabled: z.boolean(),
  repeat_weekly: z.boolean(),
}).superRefine((values, context) => {
  const baseName = values[`event_name_${values.default_language}`].trim()
  if (baseName.length < 2) {
    context.addIssue({
      code: 'custom',
      path: [`event_name_${values.default_language}`],
      message: 'Ana içerik dilinde etkinlik adı gerekli',
    })
  }
  if (values.repeat_weekly && !(values.start_at || values.event_date)) {
    context.addIssue({
      code: 'custom',
      path: ['start_at'],
      message: 'Haftalık tekrar için başlangıç tarihi gerekli',
    })
  }
})
type EventForm = z.infer<typeof eventSchema>

function toInputDate(value?: string) {
  if (!value) return ''
  return value.replace(' ', 'T').slice(0, 16)
}

export function weekdayFromDateInput(value: string) {
  const datePart = value.slice(0, 10)
  const selectedDate = new Date(`${datePart}T12:00:00`)
  if (!datePart || Number.isNaN(selectedDate.getTime())) return null
  return (selectedDate.getDay() + 6) % 7
}

export function EventFormPage({ itemId }: { itemId?: number }) {
  const formRef = useRef<HTMLFormElement>(null)
  const [activeLanguage, setActiveLanguage] = useState<'tr' | 'en' | 'es'>('tr')
  const query = useQuery({
    queryKey: ['event', itemId],
    queryFn: () => api<EventItem & Record<string, unknown>>(`/events/${itemId}`),
    enabled: Boolean(itemId),
  })
  const mutation = useMutation({
    mutationFn: (form: FormData) => apiForm(itemId ? `/events/${itemId}` : '/events', form),
    onSuccess: () => redirectWithFeedback('/admin-v2/events', itemId ? 'Etkinlik kaydedildi.' : 'Etkinlik oluşturuldu.'),
    onError: showMutationError,
  })
  const { register, handleSubmit, reset, setValue, watch, formState } = useForm<EventForm>({
    resolver: zodResolver(eventSchema),
    defaultValues: {
      event_kind: 'dance_night',
      entry_fee: '0',
      ticket_sales_enabled: false,
      repeat_weekly: false,
      event_date: '',
      start_at: '',
      end_at: '',
      city: '',
      country_code: '',
      city_id: '',
      event_name: '',
      default_language: 'tr',
      event_name_tr: '',
      description_tr: '',
      program_text_tr: '',
      event_name_en: '',
      description_en: '',
      program_text_en: '',
      event_name_es: '',
      description_es: '',
      program_text_es: '',
      venue: '',
      venue_map_url: '',
      dance_styles: '',
      organizer_name: '',
      description: '',
      program_text: '',
    },
  })
  useEffect(() => {
    if (!query.data) return
    const item = query.data
    const defaultLanguage = item.default_language || 'tr'
    const translations = item.translations || {}
    const legacyContent = {
      event_name: String(item.event_name || item.name || ''),
      description: String(item.description || ''),
      program_text: String(item.program_text || ''),
    }
    const content = (language: 'tr' | 'en' | 'es') =>
      translations[language] || (language === defaultLanguage ? legacyContent : {})
    setActiveLanguage(defaultLanguage)
    reset({
      event_name: legacyContent.event_name,
      default_language: defaultLanguage,
      event_name_tr: String(content('tr').event_name || ''),
      description_tr: String(content('tr').description || ''),
      program_text_tr: String(content('tr').program_text || ''),
      event_name_en: String(content('en').event_name || ''),
      description_en: String(content('en').description || ''),
      program_text_en: String(content('en').program_text || ''),
      event_name_es: String(content('es').event_name || ''),
      description_es: String(content('es').description || ''),
      program_text_es: String(content('es').program_text || ''),
      city: String(item.city || ''),
      country_code: String(item.country_code || ''),
      city_id: String(item.city_id || ''),
      event_date: toInputDate(String(item.event_date || '')),
      start_at: toInputDate(item.start_at),
      end_at: toInputDate(String(item.end_at || '')),
      venue: String(item.venue || ''),
      venue_map_url: String(item.venue_map_url || ''),
      event_kind: String(item.event_kind || 'dance_night'),
      dance_styles: Array.isArray(item.dance_styles) ? item.dance_styles.join(', ') : String(item.dance_styles || ''),
      organizer_name: String(item.organizer_name || ''),
      entry_fee: String(item.entry_fee || '0'),
      description: legacyContent.description,
      program_text: legacyContent.program_text,
      ticket_sales_enabled: Boolean(item.ticket_sales_enabled),
      repeat_weekly: Boolean(item.repeat_weekly),
    })
  }, [query.data, reset])

  const submit = handleSubmit((values) => {
    if (!formRef.current) return
    const form = new FormData(formRef.current)
    const translations = Object.fromEntries(
      (['tr', 'en', 'es'] as const).flatMap((language) => {
        const value = {
          event_name: values[`event_name_${language}`].trim(),
          description: values[`description_${language}`].trim(),
          program_text: values[`program_text_${language}`].trim(),
        }
        return value.event_name || value.description || value.program_text ? [[language, value]] : []
      }),
    )
    const base = translations[values.default_language]
    form.set('default_language', values.default_language)
    form.set('translations_json', JSON.stringify(translations))
    form.set('event_name', base.event_name)
    form.set('description', base.description)
    form.set('program_text', base.program_text)
    form.set('ticket_sales_enabled', values.ticket_sales_enabled ? '1' : '0')
    form.set('repeat_weekly', values.repeat_weekly ? '1' : '0')
    if (values.repeat_weekly) {
      const repeatSource = formState.dirtyFields.event_date
        ? values.event_date
        : values.start_at || values.event_date
      const repeatWeekday = weekdayFromDateInput(repeatSource)
      if (repeatWeekday === null) return
      form.set('repeat_weekday', String(repeatWeekday))
    } else {
      form.set('repeat_weekday', '')
    }
    mutation.mutate(form)
  })
  if (itemId && query.isLoading) return <LoadingState label="Etkinlik yükleniyor" />
  if (query.error) return <ErrorState error={query.error} retry={() => query.refetch()} />
  return (
    <>
      <PageHeader
        title={itemId ? 'Etkinliği Düzenle' : 'Etkinlik Oluştur'}
        description="Etkinlik bilgilerini tek ekranda yönetin."
        actions={
          <>
            {itemId && <a className="secondary-button" href={`/admin-v2/events/${itemId}/operations`}><TicketCheck size={17} />Bilet ve davetli</a>}
            <a className="secondary-button" href="/admin-v2/events"><ArrowLeft size={17} />Etkinlikler</a>
          </>
        }
      />
      <Section title="Etkinlik bilgileri">
        <form ref={formRef} className="form-grid" onSubmit={submit}>
          <input type="hidden" {...register('event_name')} />
          <input type="hidden" {...register('description')} />
          <input type="hidden" {...register('program_text')} />
          <label><span>Ana içerik dili</span><select {...register('default_language', { onChange: (event) => setActiveLanguage(event.target.value as 'tr' | 'en' | 'es') })}><option value="tr">Türkçe</option><option value="en">English</option><option value="es">Español</option></select></label>
          <label><span>Ülke kodu (TR, ES, TH, PL)</span><input maxLength={2} {...register('country_code', { onChange: () => setValue('city_id', '') })} />{formState.errors.country_code && <small className="field-error">{formState.errors.country_code.message}</small>}</label>
          <input type="hidden" {...register('city_id')} />
          <label><span>Şehir / yerleşim</span><input {...register('city', { onChange: () => setValue('city_id', '') })} />{formState.errors.city && <small className="field-error">{formState.errors.city.message}</small>}</label>
          <label><span>Başlangıç</span><input type="datetime-local" {...register('start_at')} />{formState.errors.start_at && <small className="field-error">{formState.errors.start_at.message}</small>}</label>
          <label><span>Bitiş</span><input type="datetime-local" {...register('end_at')} /></label>
          <label><span>Etkinlik tarihi</span><input type="datetime-local" {...register('event_date')} /></label>
          <label><span>Etkinlik türü</span><select {...register('event_kind')}><option value="dance_night">Dans gecesi</option><option value="festival">Festival</option><option value="workshop">Workshop</option><option value="promo_lesson">Tanıtım dersi</option></select></label>
          <label><span>Mekan</span><input {...register('venue')} /></label>
          <label><span>Harita bağlantısı</span><input type="url" {...register('venue_map_url')} /></label>
          <label><span>Organizatör</span><input {...register('organizer_name')} /></label>
          <label><span>Giriş ücreti</span><input inputMode="decimal" {...register('entry_fee')} /></label>
          <label className="wide-field"><span>Dans türleri</span><input {...register('dance_styles')} placeholder="Salsa, Bachata" /></label>
          <fieldset className="translation-editor wide-field">
            <legend>Etkinlik metinleri</legend>
            <div className="language-tabs" role="tablist" aria-label="İçerik dili">
              {([['tr', '🇹🇷', 'Türkçe'], ['en', '🇬🇧', 'English'], ['es', '🇪🇸', 'Español']] as const).map(([language, flag, label]) => {
                const hasContent = Boolean(watch(`event_name_${language}`).trim())
                return <button key={language} type="button" role="tab" aria-selected={activeLanguage === language} className={activeLanguage === language ? 'is-active' : ''} onClick={() => setActiveLanguage(language)}><span aria-hidden="true">{flag}</span>{label}{hasContent && <i aria-label="İçerik girildi" />}</button>
              })}
            </div>
            {(['tr', 'en', 'es'] as const).map((language) => (
              <div key={language} className={`translation-fields ${activeLanguage === language ? 'is-active' : ''}`} role="tabpanel">
                <label><span>Etkinlik adı</span><input {...register(`event_name_${language}`)} />{formState.errors[`event_name_${language}`] && <small className="field-error">{formState.errors[`event_name_${language}`]?.message}</small>}</label>
                <label><span>Açıklama</span><textarea rows={5} {...register(`description_${language}`)} /></label>
                <label><span>Program</span><textarea rows={5} {...register(`program_text_${language}`)} /></label>
              </div>
            ))}
            <small>Ana dil zorunludur. Boş bırakılan diğer dillerde ana dildeki içerik gösterilir.</small>
          </fieldset>
          <label><span>Kapak görseli</span><input type="file" name="cover_image" accept="image/*" /></label>
          <label className="check-field"><input type="checkbox" {...register('ticket_sales_enabled')} /><span>Bilet satışı açık</span></label>
          <label className="check-field"><input type="checkbox" {...register('repeat_weekly')} /><span>Her hafta tekrarla</span></label>
          <div className="form-footer wide-field">
            <span>{mutation.error instanceof Error ? mutation.error.message : Object.keys(formState.errors).length ? 'Lütfen işaretli alanları kontrol edin.' : ''}</span>
            <button className="primary-button" type="submit" disabled={mutation.isPending}><Save size={17} />{mutation.isPending ? 'Kaydediliyor' : 'Kaydet'}</button>
          </div>
        </form>
      </Section>
    </>
  )
}

type EventInvitee = {
  account_id: number
  name: string
  email: string
  is_verified: boolean
  source_guest_list_name?: string
  ticket_id?: number | null
  ticket_used?: boolean
  ticket_used_at?: string
  invited_at?: string
}

type ScanPermission = {
  permission_id: number
  account_id: number
  name: string
  email: string
  created_at?: string
}

type EditorCandidate = {
  id: number
  name: string
  email: string
  username?: string
  role: string
}

type EventOperations = {
  event: EventItem
  read_only: boolean
  guest_lists: { guest_list_id: number; name: string; member_count?: number }[]
  invitees: EventInvitee[]
  scan_permissions: ScanPermission[]
  editor_candidates: EditorCandidate[]
}

export function eventTicketMetrics(event: EventItem) {
  return [
    { label: 'Aktif bilet', value: event.active_ticket_count || 0 },
    { label: 'Davetli', value: event.guest_ticket_count || 0 },
    { label: 'Satın alınmış', value: event.paid_ticket_count || 0 },
    { label: 'Kullanılan', value: event.used_ticket_count || 0 },
  ]
}

export function EventOperationsPage({ itemId }: { itemId: number }) {
  const client = useQueryClient()
  const [guestListId, setGuestListId] = useState('')
  const [editorId, setEditorId] = useState('')
  const queryKey = ['event-operations', itemId]
  const query = useQuery({
    queryKey,
    queryFn: () => api<EventOperations>(`/events/${itemId}/operations`),
  })
  const mutate = useMutation({
    mutationFn: ({ action, payload }: { action: string; payload: Record<string, unknown> }) =>
      runAction(action, { id: itemId, ...payload }),
    onSuccess: async (_data, variables) => {
      await client.invalidateQueries({ queryKey })
      if (variables.action === 'event-guest-import') setGuestListId('')
      if (variables.action === 'event-scan-grant') setEditorId('')
      showFeedback(
        variables.action === 'event-guest-import'
          ? 'Davetli listesi etkinliğe aktarıldı ve QR biletleri hazırlandı.'
          : 'Etkinlik yetkileri güncellendi.',
      )
    },
    onError: showMutationError,
  })

  if (query.isLoading) return <LoadingState label="Bilet ve davetli yönetimi yükleniyor" />
  if (query.error || !query.data) return <ErrorState error={query.error} retry={() => query.refetch()} />

  const data = query.data
  const readOnly = data.read_only
  const assignedIds = new Set(data.scan_permissions.map((permission) => permission.account_id))
  const availableEditors = data.editor_candidates.filter((candidate) => !assignedIds.has(candidate.id))

  return (
    <>
      <PageHeader
        title={readOnly ? 'Bilet ve Davetli İzleme' : 'Bilet ve Davetli Yönetimi'}
        description={data.event.event_name || `Etkinlik #${itemId}`}
        actions={
          <>
            <a className="secondary-button" href={`/admin-v2/events/${itemId}`}><Save size={17} />Etkinliği düzenle</a>
            <a className="secondary-button" href="/admin-v2/events"><ArrowLeft size={17} />Etkinlikler</a>
          </>
        }
      />

      <Section title="Bilet özeti" description="Etkinlik için oluşturulan ve kullanılan biletlerin güncel durumu.">
        <div className="report-grid event-ticket-metrics">
          {eventTicketMetrics(data.event).map((metric) => (
            <div className="report-tile" key={metric.label}><span>{metric.label}</span><strong>{metric.value}</strong></div>
          ))}
        </div>
      </Section>

      {!readOnly && <Section
        title="Davetli listesini etkinliğe aktar"
        description="Seçilen listedeki kullanıcılar yalnızca bu etkinliğe eklenir ve her biri için QR bilet hazırlanır."
      >
        <div className="operation-form">
          <label>
            <span>Davetli listesi</span>
            <select value={guestListId} onChange={(event) => setGuestListId(event.target.value)}>
              <option value="">Liste seçin</option>
              {data.guest_lists.map((list) => (
                <option key={list.guest_list_id} value={list.guest_list_id}>
                  {list.name} · {list.member_count || 0} kişi
                </option>
              ))}
            </select>
          </label>
          <button
            className="primary-button"
            type="button"
            disabled={!guestListId || mutate.isPending}
            onClick={() => mutate.mutate({ action: 'event-guest-import', payload: { guest_list_id: Number(guestListId) } })}
          >
            <UserPlus size={17} />Etkinliğe aktar
          </button>
        </div>
        {!data.guest_lists.length && <EmptyState label="Aktarılabilecek davetli listesi yok" />}
      </Section>}

      <Section title={`Etkinlik davetlileri (${data.invitees.length})`}>
        {!data.invitees.length ? <EmptyState label="Bu etkinliğe henüz davetli aktarılmamış" /> : (
          <div className="dense-list">
            {data.invitees.map((invitee) => (
              <div className="dense-row" key={invitee.account_id}>
                <div>
                  <strong>{invitee.name}</strong>
                  <span>
                    {invitee.email || 'E-posta yok'}
                    {invitee.source_guest_list_name ? ` · ${invitee.source_guest_list_name} listesinden` : ' · Manuel davetli'}
                  </span>
                </div>
                <div className="item-actions">
                  {invitee.is_verified && <StatusBadge tone="info">Yönetici / doğrulanmış</StatusBadge>}
                  {invitee.ticket_id && <StatusBadge tone="neutral"><QrCode size={14} />QR hazır</StatusBadge>}
                  {invitee.ticket_used && <StatusBadge tone="success">QR okutuldu</StatusBadge>}
                  {!readOnly && <button
                    className="icon-button danger bordered"
                    type="button"
                    title="Etkinlikten çıkar"
                    disabled={mutate.isPending}
                    onClick={() => {
                      if (window.confirm(`${invitee.name} bu etkinliğin davetlilerinden çıkarılsın mı?`)) {
                        mutate.mutate({ action: 'event-invitee-remove', payload: { account_id: invitee.account_id } })
                      }
                    }}
                  >
                    <UserMinus size={17} />
                  </button>}
                </div>
              </div>
            ))}
          </div>
        )}
      </Section>

      <Section
        title="Bilet kontrol yetkilileri"
        description="Atanan kullanıcı bu etkinliğin ve bağlı tekrar serisinin biletlerini mobil uygulamadaki Bilet Kontrol ekranından okutabilir."
      >
        {!readOnly && <div className="operation-form">
          <label>
            <span>Yetkili kullanıcı</span>
            <select value={editorId} onChange={(event) => setEditorId(event.target.value)}>
              <option value="">Kullanıcı seçin</option>
              {availableEditors.map((editor) => (
                <option key={editor.id} value={editor.id}>
                  {editor.name || editor.username || editor.email} · {editor.email}
                </option>
              ))}
            </select>
          </label>
          <button
            className="primary-button"
            type="button"
            disabled={!editorId || mutate.isPending}
            onClick={() => mutate.mutate({ action: 'event-scan-grant', payload: { account_id: Number(editorId) } })}
          >
            <TicketCheck size={17} />Yetki ver
          </button>
        </div>}
        {!data.scan_permissions.length ? <EmptyState label="Bu etkinlik için atanmış bilet kontrol yetkilisi yok" /> : (
          <div className="dense-list operation-list">
            {data.scan_permissions.map((permission) => (
              <div className="dense-row" key={permission.permission_id}>
                <div><strong>{permission.name}</strong><span>{permission.email} · {formatDate(permission.created_at)}</span></div>
                {!readOnly && <button
                  className="secondary-button danger"
                  type="button"
                  disabled={mutate.isPending}
                  onClick={() => {
                    if (window.confirm(`${permission.name} için bilet kontrol yetkisi kaldırılsın mı?`)) {
                      mutate.mutate({ action: 'event-scan-revoke', payload: { account_id: permission.account_id } })
                    }
                  }}
                >
                  <Trash2 size={17} />Yetkiyi kaldır
                </button>}
              </div>
            ))}
          </div>
        )}
      </Section>
    </>
  )
}

type GuestDetail = {
  guest_list_id: number
  name: string
  members: { account_id: number; name: string; email: string; is_verified: boolean; added_at?: string }[]
}

export function GuestDetailPage({ itemId }: { itemId: number }) {
  const client = useQueryClient()
  const [q, setQ] = useState('')
  const detail = useQuery({ queryKey: ['guest-list', itemId], queryFn: () => api<GuestDetail>(`/guest-lists/${itemId}`) })
  const users = useQuery({
    queryKey: ['guest-user-search', q],
    queryFn: () => api<{ items: UserItem[] }>(`/users?q=${encodeURIComponent(q)}&page=1&page_size=20`),
    enabled: q.trim().length >= 2,
  })
  const mutate = useMutation({
    mutationFn: ({ action, payload }: { action: string; payload: Record<string, unknown> }) => runAction(action, { id: itemId, ...payload }),
    onSuccess: async () => {
      await client.invalidateQueries({ queryKey: ['guest-list', itemId] })
      showFeedback('Davetli listesi güncellendi.')
    },
    onError: showMutationError,
  })
  if (detail.isLoading) return <LoadingState label="Davetli listesi yükleniyor" />
  if (detail.error || !detail.data) return <ErrorState error={detail.error} retry={() => detail.refetch()} />
  const memberIds = new Set(detail.data.members.map((item) => item.account_id))
  return (
    <>
      <PageHeader title={detail.data.name} description={`${detail.data.members.length} kişilik davetli listesi`} actions={<a className="secondary-button" href="/admin-v2/guests"><ArrowLeft size={17} />Listeler</a>} />
      <Section title="Liste adı">
        <form className="inline-form" onSubmit={(event) => { event.preventDefault(); const name = new FormData(event.currentTarget).get('name'); mutate.mutate({ action: 'guest-rename', payload: { name } }) }}>
          <label><span>Ad</span><input name="name" defaultValue={detail.data.name} /></label>
          <button className="primary-button" type="submit"><Save size={17} />Kaydet</button>
        </form>
      </Section>
      <Section title="Kullanıcı ekle">
        <label className="search-field"><Search size={17} /><input value={q} onChange={(event) => setQ(event.target.value)} placeholder="Ad, kullanıcı adı veya e-posta" /></label>
        {users.data && <div className="search-results">{users.data.items.filter((user) => !memberIds.has(user.id)).map((user) => (
          <div className="dense-row" key={user.id}><div><strong>{user.name || user.username || user.email}</strong><span>{user.email}</span></div><button className="icon-button bordered" title="Listeye ekle" type="button" onClick={() => mutate.mutate({ action: 'guest-member-add', payload: { account_id: user.id } })}><UserPlus size={17} /></button></div>
        ))}</div>}
      </Section>
      <Section title="Mevcut davetliler">
        {!detail.data.members.length ? <EmptyState label="Listede kullanıcı yok" /> : <div className="dense-list">{detail.data.members.map((member) => (
          <div className="dense-row" key={member.account_id}><div><strong>{member.name}</strong><span>{member.email} · {formatDate(member.added_at)}</span></div><div className="item-actions"><StatusBadge tone={member.is_verified ? 'success' : 'neutral'}>{member.is_verified ? 'Onaylı' : 'Standart'}</StatusBadge><button className="icon-button danger bordered" title="Listeden çıkar" type="button" onClick={() => { if (window.confirm(`${member.name} listeden çıkarılsın mı?`)) mutate.mutate({ action: 'guest-member-remove', payload: { account_id: member.account_id } }) }}><Trash2 size={17} /></button></div></div>
        ))}</div>}
      </Section>
    </>
  )
}

type UserDetail = UserItem & { feed_post_count?: number }

export function userTicketMetrics(user: UserItem) {
  return [
    { label: 'Tanımlanan bilet', value: user.assigned_ticket_count || 0 },
    { label: 'Satın alınan', value: user.purchased_ticket_count || 0 },
    { label: 'Kullanılan', value: user.used_ticket_count || 0 },
  ]
}

export function UserDetailPage({ itemId }: { itemId: number }) {
  const client = useQueryClient()
  const detail = useQuery({ queryKey: ['user', itemId], queryFn: () => api<UserDetail>(`/users/${itemId}`) })
  const mutate = useMutation({
    mutationFn: ({ action, payload }: { action: string; payload: Record<string, unknown> }) => runAction(action, { id: itemId, ...payload }),
    onSuccess: async () => {
      await client.invalidateQueries({ queryKey: ['user', itemId] })
      showFeedback('Kullanıcı bilgileri güncellendi.')
    },
    onError: showMutationError,
  })
  if (detail.isLoading) return <LoadingState label="Kullanıcı yükleniyor" />
  if (detail.error || !detail.data) return <ErrorState error={detail.error} retry={() => detail.refetch()} />
  const user = detail.data
  return (
    <>
      <PageHeader title={user.name || user.username || user.email} description={`Kullanıcı #${user.id}`} actions={<a className="secondary-button" href="/admin-v2/users"><ArrowLeft size={17} />Kullanıcılar</a>} />
      <Section title="Bilet istatistikleri" description="İptal edilmiş biletler sayımlara dahil edilmez.">
        <div className="report-grid">
          {userTicketMetrics(user).map((metric) => (
            <div className="report-tile" key={metric.label}><span>{metric.label}</span><strong>{metric.value}</strong></div>
          ))}
        </div>
      </Section>
      <Section title="Hesap">
        <dl className="definition-list"><div><dt>E-posta</dt><dd>{user.email}</dd></div><div><dt>Rol</dt><dd>{user.role}</dd></div><div><dt>Akış gönderisi</dt><dd>{user.feed_post_count || 0}</dd></div></dl>
      </Section>
      {user.role !== 'super_admin' && <Section title="Yetkiler ve güvenlik">
        <div className="settings-actions">
          <button className="secondary-button" type="button" onClick={() => mutate.mutate({ action: 'user-active', payload: { active: !user.is_active } })}>{user.is_active ? 'Hesabı pasife al' : 'Hesabı aktifleştir'}</button>
          <button className="secondary-button" type="button" onClick={() => mutate.mutate({ action: 'user-verified', payload: { verified: !user.is_verified } })}>{user.is_verified ? 'Onayı kaldır' : 'Onaylı yap'}</button>
          <button className="secondary-button" type="button" onClick={() => mutate.mutate({ action: 'user-event-permission', payload: { enabled: !user.can_create_mobile_event } })}>{user.can_create_mobile_event ? 'Etkinlik yetkisini kaldır' : 'Etkinlik yetkisi ver'}</button>
          <button className="secondary-button" type="button" onClick={() => { const password = window.prompt('Yeni parola'); if (password) mutate.mutate({ action: 'user-password', payload: { password } }) }}><KeyRound size={17} />Parola değiştir</button>
        </div>
        <form className="inline-form" onSubmit={(event) => { event.preventDefault(); const username = new FormData(event.currentTarget).get('username'); mutate.mutate({ action: 'user-username', payload: { username } }) }}><label><span>Kullanıcı adı</span><input name="username" defaultValue={user.username} /></label><button className="primary-button" type="submit"><Save size={17} />Kaydet</button></form>
        {mutate.error instanceof Error && <p className="field-error">{mutate.error.message}</p>}
      </Section>}
    </>
  )
}

const newsSchema = z.object({
  title: z.string(),
  body_text: z.string(),
  default_language: z.enum(['tr', 'en', 'es']),
  title_tr: z.string(),
  body_text_tr: z.string(),
  title_en: z.string(),
  body_text_en: z.string(),
  title_es: z.string(),
  body_text_es: z.string(),
  source_link: z.string(),
}).superRefine((values, context) => {
  const title = values[`title_${values.default_language}`].trim()
  const body = values[`body_text_${values.default_language}`].trim()
  if (title.length < 3) context.addIssue({ code: 'custom', path: [`title_${values.default_language}`], message: 'Ana içerik dilinde başlık gerekli' })
  if (body.length < 10) context.addIssue({ code: 'custom', path: [`body_text_${values.default_language}`], message: 'Ana içerik dilinde haber metni gerekli' })
})
type NewsForm = z.infer<typeof newsSchema>
type NewsItemDetail = NewsForm & {
  default_language?: 'tr' | 'en' | 'es'
  translations?: Partial<Record<'tr' | 'en' | 'es', { title?: string; body_text?: string }>>
}

export function NewsFormPage({ itemId }: { itemId?: number }) {
  const formRef = useRef<HTMLFormElement>(null)
  const [activeLanguage, setActiveLanguage] = useState<'tr' | 'en' | 'es'>('tr')
  const query = useQuery({ queryKey: ['news-item', itemId], queryFn: () => api<NewsItemDetail>(`/news/${itemId}`), enabled: Boolean(itemId) })
  const mutation = useMutation({
    mutationFn: (form: FormData) => apiForm(itemId ? `/news/${itemId}` : '/news', form),
    onSuccess: () => redirectWithFeedback('/admin-v2/news', itemId ? 'Haber kaydedildi.' : 'Haber oluşturuldu.'),
    onError: showMutationError,
  })
  const { register, handleSubmit, reset, watch, formState } = useForm<NewsForm>({
    resolver: zodResolver(newsSchema),
    defaultValues: {
      title: '', body_text: '', default_language: 'tr', source_link: '',
      title_tr: '', body_text_tr: '', title_en: '', body_text_en: '', title_es: '', body_text_es: '',
    },
  })
  useEffect(() => {
    if (!query.data) return
    const item = query.data
    const defaultLanguage = item.default_language || 'tr'
    const translations = item.translations || {}
    const legacyContent = { title: String(item.title || ''), body_text: String(item.body_text || '') }
    const content = (language: 'tr' | 'en' | 'es') => translations[language] || (language === defaultLanguage ? legacyContent : {})
    setActiveLanguage(defaultLanguage)
    reset({
      title: legacyContent.title,
      body_text: legacyContent.body_text,
      default_language: defaultLanguage,
      title_tr: String(content('tr').title || ''),
      body_text_tr: String(content('tr').body_text || ''),
      title_en: String(content('en').title || ''),
      body_text_en: String(content('en').body_text || ''),
      title_es: String(content('es').title || ''),
      body_text_es: String(content('es').body_text || ''),
      source_link: String(item.source_link || ''),
    })
  }, [query.data, reset])
  const submit = handleSubmit((values) => {
    if (!formRef.current) return
    const form = new FormData(formRef.current)
    const translations = Object.fromEntries(
      (['tr', 'en', 'es'] as const).flatMap((language) => {
        const value = { title: values[`title_${language}`].trim(), body_text: values[`body_text_${language}`].trim() }
        return value.title || value.body_text ? [[language, value]] : []
      }),
    )
    const base = translations[values.default_language]
    form.set('default_language', values.default_language)
    form.set('translations_json', JSON.stringify(translations))
    form.set('title', base.title)
    form.set('body_text', base.body_text)
    mutation.mutate(form)
  })
  if (itemId && query.isLoading) return <LoadingState label="Haber yükleniyor" />
  if (query.error) return <ErrorState error={query.error} retry={() => query.refetch()} />
  return (
    <>
      <PageHeader title={itemId ? 'Haberi Düzenle' : 'Haber Oluştur'} description="Haber içeriğini ve kapak görselini yönetin." actions={<a className="secondary-button" href="/admin-v2/news"><ArrowLeft size={17} />Haberler</a>} />
      <Section title="Haber bilgileri"><form ref={formRef} className="form-grid" onSubmit={submit}>
        <input type="hidden" {...register('title')} />
        <input type="hidden" {...register('body_text')} />
        <label><span>Ana içerik dili</span><select {...register('default_language', { onChange: (event) => setActiveLanguage(event.target.value as 'tr' | 'en' | 'es') })}><option value="tr">Türkçe</option><option value="en">English</option><option value="es">Español</option></select></label>
        <label><span>Kaynak bağlantısı</span><input type="url" {...register('source_link')} /></label>
        <fieldset className="translation-editor wide-field">
          <legend>Haber metinleri</legend>
          <div className="language-tabs" role="tablist" aria-label="İçerik dili">
            {([['tr', '🇹🇷', 'Türkçe'], ['en', '🇬🇧', 'English'], ['es', '🇪🇸', 'Español']] as const).map(([language, flag, label]) => {
              const hasContent = Boolean(watch(`title_${language}`).trim())
              return <button key={language} type="button" role="tab" aria-selected={activeLanguage === language} className={activeLanguage === language ? 'is-active' : ''} onClick={() => setActiveLanguage(language)}><span aria-hidden="true">{flag}</span>{label}{hasContent && <i aria-label="İçerik girildi" />}</button>
            })}
          </div>
          {(['tr', 'en', 'es'] as const).map((language) => (
            <div key={language} className={`translation-fields ${activeLanguage === language ? 'is-active' : ''}`} role="tabpanel">
              <label><span>Başlık</span><input {...register(`title_${language}`)} />{formState.errors[`title_${language}`] && <small className="field-error">{formState.errors[`title_${language}`]?.message}</small>}</label>
              <label><span>Haber metni</span><textarea rows={12} {...register(`body_text_${language}`)} />{formState.errors[`body_text_${language}`] && <small className="field-error">{formState.errors[`body_text_${language}`]?.message}</small>}</label>
            </div>
          ))}
          <small>Ana dil zorunludur. Boş bırakılan diğer dillerde ana dildeki içerik gösterilir.</small>
        </fieldset>
        <label><span>Kapak görseli</span><input type="file" name="cover_image" accept="image/*" /></label>
        <div className="form-footer wide-field"><span>{mutation.error instanceof Error ? mutation.error.message : Object.keys(formState.errors).length ? 'Lütfen işaretli alanları kontrol edin.' : ''}</span><button className="primary-button" type="submit" disabled={mutation.isPending}><Save size={17} />{mutation.isPending ? 'Kaydediliyor' : 'Kaydet'}</button></div>
      </form></Section>
    </>
  )
}

const pollSchema = z.object({ title: z.string().trim().min(3), question: z.string().trim().min(5), options: z.string().trim().min(3), show_results_after_vote: z.boolean() })
type PollForm = z.infer<typeof pollSchema>

export function PollCreatePage() {
  const mutation = useMutation({
    mutationFn: (payload: Record<string, unknown>) => runAction('poll-create', payload),
    onSuccess: () => redirectWithFeedback('/admin-v2/polls', 'Anket oluşturuldu.'),
    onError: showMutationError,
  })
  const { register, handleSubmit } = useForm<PollForm>({ resolver: zodResolver(pollSchema), defaultValues: { show_results_after_vote: true } })
  return (
    <>
      <PageHeader title="Anket Oluştur" description="Soruyu ve seçenekleri belirleyin." actions={<a className="secondary-button" href="/admin-v2/polls"><ArrowLeft size={17} />Anketler</a>} />
      <Section title="Anket bilgileri"><form className="form-grid" onSubmit={handleSubmit((values) => mutation.mutate({ title: values.title, show_results_after_vote: values.show_results_after_vote, questions: [{ question: values.question, options: values.options.split('\n').map((item) => item.trim()).filter(Boolean) }] }))}>
        <label className="wide-field"><span>Anket başlığı</span><input {...register('title')} /></label>
        <label className="wide-field"><span>Soru</span><input {...register('question')} /></label>
        <label className="wide-field"><span>Seçenekler</span><textarea rows={6} {...register('options')} placeholder={'Her satıra bir seçenek'} /></label>
        <label className="check-field"><input type="checkbox" {...register('show_results_after_vote')} /><span>Oy sonrası sonuçları göster</span></label>
        <div className="form-footer wide-field"><span>{mutation.error instanceof Error ? mutation.error.message : ''}</span><button className="primary-button" type="submit"><Plus size={17} />Oluştur</button></div>
      </form></Section>
    </>
  )
}
