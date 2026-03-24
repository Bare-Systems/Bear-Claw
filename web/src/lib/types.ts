export type Tone = 'healthy' | 'warning' | 'critical' | 'neutral'

export type AppTab =
  | 'chat'
  | 'weather'
  | 'security'
  | 'finance'
  | 'settings'
  | 'live-home'
  | 'live-activity'
  | 'live-cameras'
  | 'live-climate'
  | 'live-profile'

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
  koalaLive: {
    viewerName: string
    notificationsEnabled: boolean
  }
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

// --- Koala Live types ---

export type DeviceType = 'camera' | 'lock' | 'door' | 'window'

export type LockState = 'locked' | 'unlocked' | 'unknown'

export type OpenState = 'open' | 'closed' | 'unknown'

export type HomeDevice = {
  id: string
  name: string
  type: DeviceType
  zone: string
  tone: Tone
  detail: string
  lockState?: LockState
  openState?: OpenState
  statusLabel?: string
  snapshotUrl?: string
}

export type KoalaCameraCard = {
  id: string
  name: string
  zoneLabel: string
  statusLabel: string
  detail: string
  tone: Tone
  snapshotUrl?: string
}

export type ActivityItem = {
  id: string
  title: string
  body: string
  timeLabel: string
  tone: Tone
  saveKey: string
}

export type KoalaStatItem = {
  label: string
  value: string
  detail: string
  tone: Tone
}

export type DashboardSnapshot = {
  headline: string
  subheadline: string
  packageSummary: string
  zoneSummary: string
  serviceLabel: string
  serviceTone: Tone
  stats: KoalaStatItem[]
  cameras: KoalaCameraCard[]
  devices: HomeDevice[]
  activity: ActivityItem[]
  lastUpdatedLabel: string
}

export type PolarQualityFlag = 'good' | 'estimated' | 'outlier' | 'unavailable'

export type PolarClimateMetric = {
  name: string
  display_name: string
  value: number
  unit: string
  display_value: string
  domain: string
  source: string
  quality: PolarQualityFlag
  recorded_at: string
}

export type PolarIndoorClimate = {
  sources: string[]
  readings: PolarClimateMetric[]
  last_reading_at?: string
  stale: boolean
}

export type PolarOutdoorClimate = {
  sources: string[]
  current: PolarClimateMetric[]
  forecast?: Array<{
    time: string
    temperature_c: number
    humidity_pct: number
    wind_speed_ms: number
    precip_mm: number
  }>
  last_fetched_at?: string
  fresh_until?: string
  stale: boolean
}

export type ClimateSnapshot = {
  station_id: string
  generated_at: string
  indoor: PolarIndoorClimate
  outdoor: PolarOutdoorClimate
}
