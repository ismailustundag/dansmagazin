import { describe, expect, it } from 'vitest'
import { eventTicketMetrics, userTicketMetrics, weekdayFromDateInput } from './detailPages'

describe('event repeat schedule', () => {
  it('maps Friday to the backend weekday value', () => {
    expect(weekdayFromDateInput('2026-08-07T20:00')).toBe(4)
  })

  it('maps Saturday to the backend weekday value', () => {
    expect(weekdayFromDateInput('2026-08-01T20:00')).toBe(5)
  })
})

describe('event ticket metrics', () => {
  it('shows the four operational counts without the ambiguous holder count', () => {
    expect(eventTicketMetrics({
      id: 42,
      active_ticket_count: 8,
      guest_ticket_count: 4,
      paid_ticket_count: 7,
      used_ticket_count: 3,
      active_ticket_holder_count: 6,
    })).toEqual([
      { label: 'Aktif bilet', value: 8 },
      { label: 'Davetli', value: 4 },
      { label: 'Satın alınmış', value: 7 },
      { label: 'Kullanılan', value: 3 },
    ])
  })
})

describe('user ticket metrics', () => {
  it('shows assigned, purchased and used ticket totals', () => {
    expect(userTicketMetrics({
      id: 12,
      name: 'Düzenli Katılımcı',
      email: 'user@example.com',
      role: 'customer',
      is_active: true,
      can_create_mobile_event: false,
      username: 'regular',
      is_verified: false,
      assigned_ticket_count: 9,
      purchased_ticket_count: 4,
      used_ticket_count: 7,
    })).toEqual([
      { label: 'Tanımlanan bilet', value: 9 },
      { label: 'Satın alınan', value: 4 },
      { label: 'Kullanılan', value: 7 },
    ])
  })
})
