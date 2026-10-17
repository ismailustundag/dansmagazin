import { expect, test } from '@playwright/test'

const overview = {
  metrics: {
    users: 1842,
    active_events: 12,
    guest_lists: 8,
    pending_news: 3,
    push_tokens: 1290,
  },
  recent_events: [
    {
      id: 242,
      event_name: 'Vişnelik Dans Geceleri',
      organizer_name: 'Dansmagazin',
      city: 'Ankara',
      status: 'approved',
      event_is_active: true,
      event_date: '2026-07-30',
    },
  ],
  recent_notifications: [
    {
      batch_id: 'batch-1',
      title: 'Etkinlik hatırlatması',
      body: 'Kapı açılışı 20.30',
      recipient_count: 846,
      created_at: '2026-07-29T00:40:00Z',
    },
  ],
  photo_retirement: {
    face_matching_enabled: false,
    event_photo_rows: 0,
    face_match_rows: 0,
  },
}

test.beforeEach(async ({ page }) => {
  await page.route('**/admin/api/v2/me', async (route) => {
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({
        id: 1,
        name: 'İsmail Üstündağ',
        email: 'admin@dansmagazin.net',
        role: 'super_admin',
      }),
    })
  })
  await page.route('**/admin/api/v2/overview', async (route) => {
    await route.fulfill({ contentType: 'application/json', body: JSON.stringify(overview) })
  })
  await page.route('**/admin/api/v2/events?*', async (route) => {
    const requestedStatus = new URL(route.request().url()).searchParams.get('status')
    if (requestedStatus === 'pending') {
      await route.fulfill({
        contentType: 'application/json',
        body: JSON.stringify({
          items: [{ ...overview.recent_events[0], id: 251, event_name: 'Yeni Ankara Etkinliği', status: 'pending', event_is_active: true }],
          total: 1,
        }),
      })
      return
    }
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({ items: overview.recent_events, total: 1 }),
    })
  })
  await page.route('**/admin/api/v2/events/242', async (route) => {
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({
        id: 242,
        event_name: 'Vişnelik Dans Geceleri',
        city: 'Ankara',
        venue: 'Vişnelik',
        start_at: '2026-07-30T20:30:00',
        end_at: '2026-07-31T01:00:00',
        event_date: '2026-07-30T20:30:00',
        event_kind: 'dance_night',
        dance_styles: ['Salsa', 'Bachata'],
        ticket_sales_enabled: true,
        repeat_weekly: true,
        repeat_weekday: 3,
      }),
    })
  })
  await page.route('**/admin/api/v2/events/242/operations', async (route) => {
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({
        event: overview.recent_events[0],
        guest_lists: [{ guest_list_id: 7, name: 'Ankara Listesi', member_count: 28 }],
        invitees: [
          {
            account_id: 91,
            name: 'Arif Atabey',
            email: 'arif@example.com',
            is_verified: true,
            source_guest_list_name: 'Ankara Listesi',
            ticket_id: 3788,
            ticket_used: true,
          },
        ],
        scan_permissions: [
          { permission_id: 3, account_id: 92, name: 'Etkinlik Yetkilisi', email: 'yetkili@example.com' },
        ],
        editor_candidates: [
          { id: 92, name: 'Etkinlik Yetkilisi', email: 'yetkili@example.com', role: 'editor' },
          { id: 93, name: 'Kapı Görevlisi', email: 'kapi@example.com', role: 'customer' },
        ],
      }),
    })
  })
  await page.route('**/admin/api/v2/guest-lists/7', async (route) => {
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({
        guest_list_id: 7,
        name: 'Ankara Listesi',
        members: [
          { account_id: 91, name: 'Arif Atabey', email: 'arif@example.com', is_verified: true },
        ],
      }),
    })
  })
  await page.route('**/admin/api/v2/users/91', async (route) => {
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({
        id: 91,
        name: 'Arif Atabey',
        email: 'arif@example.com',
        role: 'customer',
        username: 'arifatabey',
        is_active: true,
        is_verified: true,
        can_create_mobile_event: false,
        ticket_count: 4,
        feed_post_count: 2,
      }),
    })
  })
  await page.route('**/admin/api/v2/notifications', async (route) => {
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({
        items: overview.recent_notifications,
        targets: {
          events: [{ route: '/events/242', label: 'Vişnelik Dans Geceleri · #242' }],
          news: [{ route: '/news/12', label: 'Dans haberi' }],
          stores: [],
          products: [],
          polls: [],
        },
      }),
    })
  })
})

for (const viewport of [
  { name: 'mobile', width: 390, height: 844 },
  { name: 'tablet', width: 768, height: 1024 },
  { name: 'desktop', width: 1440, height: 900 },
]) {
  test(`overview is usable on ${viewport.name}`, async ({ page }) => {
    await page.setViewportSize(viewport)
    await page.goto('/admin-v2/overview')
    await expect(page.getByRole('heading', { name: 'Genel Bakış' })).toBeVisible()
    await expect(page.getByText('Vişnelik Dans Geceleri')).toBeVisible()

    const overflow = await page.evaluate(() => ({
      document: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      body: document.body.scrollWidth - document.body.clientWidth,
    }))
    expect(overflow.document).toBeLessThanOrEqual(1)
    expect(overflow.body).toBeLessThanOrEqual(1)

    if (viewport.name === 'mobile') {
      await page.getByRole('button', { name: 'Menüyü aç' }).click()
      await expect(page.getByRole('navigation')).toBeVisible()
      await expect(page.getByRole('link', { name: 'Davetli Yönetimi' })).toBeVisible()
      await page.getByRole('button', { name: 'Menüyü kapat' }).first().click()
      await expect(page.locator('.sidebar')).not.toHaveClass(/is-open/)
    }

    await page.screenshot({
      path: `artifacts/admin-v2-${viewport.name}.png`,
      fullPage: true,
    })
  })
}

test('event actions use a real event id', async ({ page }) => {
  await page.goto('/admin-v2/events')
  const edit = page.getByRole('link', { name: 'Düzenle' })
  await expect(edit).toHaveAttribute('href', '/admin-v2/events/242')
  await expect(page.getByText('Etkinlik #undefined')).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Pasife al' })).toBeEnabled()
  await expect(page.getByRole('button', { name: 'Kopyala' })).toBeEnabled()
  await expect(page.getByRole('button', { name: 'Sil' })).toBeEnabled()
  await expect(page.getByRole('link', { name: 'Bilet ve davetli' })).toHaveAttribute(
    'href',
    '/admin-v2/events/242/operations',
  )
})

test('event guest import and scan permissions are available on mobile', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await page.goto('/admin-v2/events/242/operations')
  await expect(page.getByRole('heading', { name: 'Bilet ve Davetli Yönetimi' })).toBeVisible()
  await expect(page.getByLabel('Davetli listesi')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Etkinliğe aktar' })).toBeDisabled()
  await page.getByLabel('Davetli listesi').selectOption('7')
  await expect(page.getByRole('button', { name: 'Etkinliğe aktar' })).toBeEnabled()
  await expect(page.getByText('QR okutuldu')).toBeVisible()
  await expect(page.getByText('Etkinlik Yetkilisi')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Yetkiyi kaldır' })).toBeVisible()
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
  expect(overflow).toBeLessThanOrEqual(1)
  await page.screenshot({ path: 'artifacts/event-operations-mobile.png', fullPage: true })
})

test('event copy sends the selected event id and shows success feedback', async ({ page }) => {
  let copiedId = 0
  await page.route('**/admin/api/v2/actions/event-copy', async (route) => {
    copiedId = Number((await route.request().postDataJSON()).id)
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({ ok: true, submission_id: 300, name: 'Vişnelik Dans Geceleri Kopya' }),
    })
  })
  page.on('dialog', (dialog) => dialog.accept())
  await page.goto('/admin-v2/events')
  await page.getByRole('button', { name: 'Kopyala' }).click()
  await expect.poll(() => copiedId).toBe(242)
  await expect(page.getByRole('status')).toContainText('İşlem başarıyla tamamlandı.')
})

test('pending event can be approved from the event list', async ({ page }) => {
  let approvedId = 0
  await page.route('**/admin/api/v2/actions/event-approve', async (route) => {
    approvedId = Number((await route.request().postDataJSON()).id)
    await route.fulfill({ contentType: 'application/json', body: JSON.stringify({ ok: true }) })
  })
  page.on('dialog', (dialog) => dialog.accept())
  await page.setViewportSize({ width: 390, height: 844 })
  await page.goto('/admin-v2/events')
  await page.getByRole('button', { name: 'Bekleyen' }).click()
  await expect(page.getByText('Onay bekliyor')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Onayla' })).toBeEnabled()
  await expect(page.getByRole('button', { name: 'Reddet' })).toBeEnabled()
  await page.getByRole('button', { name: 'Onayla' }).click()
  await expect.poll(() => approvedId).toBe(251)
  await expect(page.getByRole('status')).toContainText('Etkinlik onaylandı ve aktif duruma alındı.')
  await page.screenshot({ path: 'artifacts/pending-event-actions-mobile.png', fullPage: true })
})

test('event save sends the selected weekly repeat day', async ({ page }) => {
  let submittedBody = ''
  await page.route('**/admin/api/v2/events/242', async (route) => {
    if (route.request().method() !== 'POST') {
      await route.fallback()
      return
    }
    submittedBody = route.request().postData() || ''
    await route.fulfill({ contentType: 'application/json', body: JSON.stringify({ ok: true }) })
  })
  await page.goto('/admin-v2/events/242')
  await page.getByLabel('Başlangıç').fill('2026-08-07T20:00')
  await page.getByLabel('Bitiş').fill('2026-08-08T00:30')
  await page.getByLabel('Etkinlik tarihi').fill('2026-08-07T20:00')
  await page.getByRole('button', { name: 'Kaydet' }).click()
  await expect.poll(() => submittedBody).toContain('name="repeat_weekly"\r\n\r\n1')
  expect(submittedBody).toContain('name="repeat_weekday"\r\n\r\n4')
  await expect(page.getByRole('status')).toContainText('Etkinlik kaydedildi.')
})

test('list actions show global success feedback', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await page.route('**/admin/api/v2/actions/event-active', async (route) => {
    await route.fulfill({ contentType: 'application/json', body: JSON.stringify({ ok: true }) })
  })
  await page.goto('/admin-v2/events')
  await page.getByRole('button', { name: 'Pasife al' }).click()
  await expect(page.getByRole('status')).toContainText('İşlem başarıyla tamamlandı.')
  await page.screenshot({ path: 'artifacts/feedback-success-mobile.png', fullPage: true })
})

test('notification target is selected from live content', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await page.goto('/admin-v2/notifications')
  await page.getByLabel('Yönlendirme türü').selectOption('event')
  await page.getByLabel('Yönlendirme hedefi').selectOption('/events/242')
  await expect(page.locator('input[name="route"]')).toHaveValue('/events/242')
  await page.screenshot({ path: 'artifacts/notifications-target-mobile.png', fullPage: true })
})

for (const route of [
  { path: '/admin-v2/events/242', heading: 'Etkinliği Düzenle' },
  { path: '/admin-v2/events/242/operations', heading: 'Bilet ve Davetli Yönetimi' },
  { path: '/admin-v2/guests/7', heading: 'Ankara Listesi' },
  { path: '/admin-v2/users/91', heading: 'Arif Atabey' },
  { path: '/admin-v2/news/new', heading: 'Haber Oluştur' },
  { path: '/admin-v2/polls/new', heading: 'Anket Oluştur' },
]) {
  test(`${route.path} stays inside Admin V2`, async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 })
    await page.goto(route.path)
    await expect(page.getByRole('heading', { name: route.heading })).toBeVisible()
    const legacyLinks = await page.locator('a').evaluateAll((links) =>
      links
        .map((link) => link.getAttribute('href') || '')
        .filter((href) => href.startsWith('/admin/mobile') || href.startsWith('/admin/users/')),
    )
    expect(legacyLinks).toEqual([])
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
    expect(overflow).toBeLessThanOrEqual(1)
    await page.screenshot({
      path: `artifacts/detail-${route.path.split('/').filter(Boolean).slice(-2).join('-')}.png`,
      fullPage: true,
    })
  })
}
