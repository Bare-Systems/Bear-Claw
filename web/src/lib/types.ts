export type Tone = 'healthy' | 'warning' | 'critical' | 'neutral'

export type AppTab = 'chat' | 'weather' | 'security' | 'finance' | 'settings'

export type AdminActionId = 'koala-refresh' | 'koala-package' | 'polar-refresh'

export type ChatRole = 'user' | 'assistant' | 'system'

export type ServiceSettings = {
  baseUrl: string
  token: string
}

export type AppSettings = {
  authToken: string
  bearClaw: ServiceSettings
  koala: ServiceSettings
  polar: ServiceSettings
}

export type ChatMessage = {
  id: string
  role: ChatRole
  content: string
  timestamp: string
}

export type ChatResponse = {
  message: ChatMessage
  requiresConfirmation: boolean
  confirmationReason: string | null
}

export type AlertItem = {
  id: string
  title: string
  body: string
  tone: Tone
}

export type PolarReading = {
  label: string
  value: string
  detail: string
  tone: Tone
}

export type SecurityEvent = {
  id: string
  title: string
  body: string
  timeLabel: string
  tone: Tone
}

export type FinanceMetric = {
  label: string
  value: string
  delta: string
  detail: string
  tone: Tone
}

export type SummaryCard = {
  label: string
  value: string
  detail: string
  tone: Tone
}

export type SystemSummary = {
  securityMode: string
  climateSummary: string
  financeSummary: string
  lastUpdatedLabel: string
  cards: SummaryCard[]
}

export type TimelineItem = {
  id: string
  title: string
  body: string
  meta: string
  tone: Tone
}

export type WeatherSnapshot = {
  readings: PolarReading[]
  timeline: TimelineItem[]
  climateSummary: string
  lastUpdatedLabel: string
}

export type SecuritySnapshot = {
  cards: SummaryCard[]
  events: SecurityEvent[]
  securityMode: string
  lastUpdatedLabel: string
}
