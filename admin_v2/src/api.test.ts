import { afterEach, describe, expect, it, vi } from 'vitest'
import { api, apiForm, runAction } from './api'

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('admin API client', () => {
  it('adds the mutation guard header and JSON content type', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)

    await runAction('event-active', { id: 42, active: false })

    expect(fetchMock).toHaveBeenCalledOnce()
    expect(fetchMock).toHaveBeenCalledWith(
      '/admin/api/v2/actions/event-active',
      expect.objectContaining({
        method: 'POST',
        credentials: 'same-origin',
        headers: expect.objectContaining({
          'Content-Type': 'application/json',
          'X-DMZ-Request': 'admin-v2',
        }),
      }),
    )
  })

  it('surfaces the backend detail and status for failed requests', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue(
        new Response(JSON.stringify({ detail: 'Yetki gerekli' }), {
          status: 403,
          headers: { 'Content-Type': 'application/json' },
        }),
      ),
    )

    await expect(api('/settings')).rejects.toMatchObject({
      message: 'Yetki gerekli',
      status: 403,
    })
  })

  it('sends multipart forms without overriding their content type', async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    )
    vi.stubGlobal('fetch', fetchMock)
    const form = new FormData()
    form.set('title', 'Yeni haber')

    await apiForm('/news', form)

    expect(fetchMock).toHaveBeenCalledWith(
      '/admin/api/v2/news',
      expect.objectContaining({
        method: 'POST',
        body: form,
        headers: {
          Accept: 'application/json',
          'X-DMZ-Request': 'admin-v2',
        },
      }),
    )
  })
})
