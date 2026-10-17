export type Account = {
  id: number
  name: string
  email: string
  role: string
}

export type EventItem = {
  id: number
  event_name?: string
  description?: string
  program_text?: string
  default_language?: 'tr' | 'en' | 'es'
  translations?: Partial<Record<'tr' | 'en' | 'es', {
    event_name?: string
    description?: string
    program_text?: string
  }>>
  city?: string
  venue?: string
  start_at?: string
  status?: string
  event_is_active?: boolean
  organizer_name?: string
  submitter_name?: string
  repeat_weekly?: boolean
  repeat_weekday?: number | null
  active_ticket_count?: number
  active_ticket_holder_count?: number
  paid_ticket_count?: number
  guest_ticket_count?: number
  reward_ticket_count?: number
  used_ticket_count?: number
  active_ticket_summary?: string
}

export type GuestList = {
  guest_list_id: number
  name: string
  member_count?: number
  updated_at?: string
}

export type UserItem = {
  id: number
  name: string
  email: string
  role: string
  is_active: boolean
  can_create_mobile_event: boolean
  username: string
  is_verified: boolean
  created_at?: string
  assigned_ticket_count?: number
  purchased_ticket_count?: number
  used_ticket_count?: number
}

export type NotificationItem = {
  batch_id?: string
  title?: string
  body?: string
  route?: string
  created_at?: string
  recipient_count?: number
}
