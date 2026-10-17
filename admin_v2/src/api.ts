export type ApiError = Error & { status?: number }

export async function api<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`/admin/api/v2${path}`, {
    credentials: 'same-origin',
    headers: {
      Accept: 'application/json',
      ...(init?.body ? { 'Content-Type': 'application/json' } : {}),
      ...(init?.method && init.method !== 'GET' ? { 'X-DMZ-Request': 'admin-v2' } : {}),
      ...init?.headers,
    },
    ...init,
  })
  if (response.status === 401) {
    window.location.assign(`/login?next=${encodeURIComponent(window.location.pathname)}`)
    throw new Error('Oturum süresi doldu')
  }
  if (!response.ok) {
    let message = 'İşlem tamamlanamadı'
    try {
      const payload = await response.json()
      message = payload.detail || payload.error || message
    } catch {
      message = response.statusText || message
    }
    const error: ApiError = new Error(message)
    error.status = response.status
    throw error
  }
  return response.json() as Promise<T>
}

export function runAction<T>(action: string, payload: Record<string, unknown>): Promise<T> {
  return api<T>(`/actions/${action}`, {
    method: 'POST',
    body: JSON.stringify(payload),
  })
}

export async function apiForm<T>(path: string, form: FormData): Promise<T> {
  const response = await fetch(`/admin/api/v2${path}`, {
    method: 'POST',
    credentials: 'same-origin',
    headers: {
      Accept: 'application/json',
      'X-DMZ-Request': 'admin-v2',
    },
    body: form,
  })
  if (response.status === 401) {
    window.location.assign(`/login?next=${encodeURIComponent(window.location.pathname)}`)
    throw new Error('Oturum süresi doldu')
  }
  if (!response.ok) {
    let message = 'İşlem tamamlanamadı'
    try {
      const payload = await response.json()
      message = payload.detail || payload.error || message
    } catch {
      message = response.statusText || message
    }
    const error: ApiError = new Error(message)
    error.status = response.status
    throw error
  }
  return response.json() as Promise<T>
}
