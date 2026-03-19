import {
  initialPolarReadings,
  initialSecurityCards,
  initialSecurityEvents,
  initialWeatherTimeline,
  systemPrompts,
} from '../data/mockData'
import type {
  AppSettings,
  ChatMessage,
  ChatResponse,
  PolarReading,
  SecurityEvent,
  SecuritySnapshot,
  SummaryCard,
  TimelineItem,
  Tone,
  WeatherSnapshot,
} from '../lib/types'

type ToolEnvelope<T> = {
  status: string
  explanation?: string
  next_action?: string
  data: T
}

type KoalaHealth = {
  status: string
  ingest: string
  inference: string
  mcp: string
  uptime_seconds: number
}

type KoalaCamera = {
  id: string
  name: string
  zone_id: string
  front_door: boolean
  status: string
}

type KoalaZoneState = {
  zone_id: string
  observed_at: string
  stale: boolean
  entities: Array<{ label?: string; confidence?: number }>
}

type KoalaPackageState = {
  package_present: boolean
  confidence: number
  observed_at: string
  stale: boolean
}

type KoalaIncident = {
  camera_id: string
  type: string
  severity: string
  message: string
  occurred_at: string
}

type KoalaIngestStatus = {
  cameras: Record<
    string,
    {
      last_status: string
      consecutive_failures: number
      last_error?: string
      last_capture_at?: string
    }
  >
  incidents: KoalaIncident[]
}

type PolarReadingRaw = {
  metric: string
  value: number
  unit: string
  recorded_at: string
}

type PolarForecastPoint = {
  time: string
  temperature_c: number
  humidity_pct: number
  wind_speed_ms: number
  precip_mm: number
}

type PolarForecast = {
  provider: string
  fetched_at: string
  fresh_until: string
  stale: boolean
  stale_reason?: string
  points: PolarForecastPoint[]
}

type PolarStationHealth = {
  overall: string
  generated_at: string
  components: Array<{
    name: string
    status: string
    message: string
    last_success: string
  }>
}

type BearClawChatEnvelope = {
  message: {
    id: string
    role: 'assistant' | 'system' | 'user'
    content: string
    timestamp: number | string
  }
  requires_confirmation?: boolean
  confirmation_reason?: string | null
}

type BearClawHealth = {
  status: string
  service: string
}

async function requestJson<T>(input: string, init: RequestInit): Promise<T> {
  const response = await fetch(input, init)
  if (!response.ok) {
    const detail = await response.text()
    throw new Error(detail || `Request failed with status ${response.status}`)
  }

  return (await response.json()) as T
}

function normalizeBaseUrl(value: string): string {
  return value.trim().replace(/\/+$/, '')
}

function canRequest(value: string): boolean {
  return /^https?:\/\//.test(value.trim())
}

function serviceToken(shared: string, override: string): string {
  return override.trim() || shared.trim()
}

function buildHeaders(token: string, json = true): HeadersInit {
  const headers: HeadersInit = {}

  if (json) {
    headers['Content-Type'] = 'application/json'
  }

  if (token) {
    headers.Authorization = `Bearer ${token}`
  }

  return headers
}

function createAssistantMessage(content: string): ChatMessage {
  return {
    id: crypto.randomUUID(),
    role: 'assistant',
    content,
    timestamp: new Date().toISOString(),
  }
}

function toneFromStatus(status: string): Tone {
  const lowered = status.toLowerCase()
  if (lowered === 'ok' || lowered === 'available' || lowered === 'ready') {
    return 'healthy'
  }
  if (lowered === 'degraded' || lowered === 'stale' || lowered === 'unknown') {
    return 'warning'
  }
  if (lowered === 'error' || lowered === 'unavailable' || lowered === 'failed') {
    return 'critical'
  }
  return 'neutral'
}

function formatNumber(value: number | undefined, digits = 0): string {
  if (value == null || Number.isNaN(value)) {
    return '--'
  }
  return digits === 0 ? Math.round(value).toString() : value.toFixed(digits)
}

function formatIsoLabel(value: string | undefined): string {
  if (!value) {
    return 'unknown'
  }

  const date = new Date(value)
  if (Number.isNaN(date.getTime())) {
    return 'unknown'
  }

  return date.toLocaleString([], {
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  })
}

function normalizeBearClawTimestamp(value: number | string): string {
  if (typeof value === 'string') {
    const parsed = Date.parse(value)
    return Number.isNaN(parsed) ? new Date().toISOString() : new Date(parsed).toISOString()
  }

  const unixMs = (value + 978307200) * 1000
  return new Date(unixMs).toISOString()
}

function previewBearClawReply(message: string): ChatResponse {
  const lowered = message.toLowerCase()

  if (lowered.includes('weather') || lowered.includes('polar')) {
    return {
      message: createAssistantMessage(systemPrompts.weather),
      requiresConfirmation: false,
      confirmationReason: null,
    }
  }

  if (lowered.includes('camera') || lowered.includes('koala')) {
    return {
      message: createAssistantMessage(systemPrompts.security),
      requiresConfirmation: false,
      confirmationReason: null,
    }
  }

  if (lowered.includes('lock')) {
    return {
      message: createAssistantMessage(systemPrompts.lockdown),
      requiresConfirmation: true,
      confirmationReason:
        'High-risk physical security action. Require explicit approval and device verification before execution.',
    }
  }

  return {
    message: createAssistantMessage(systemPrompts.general),
    requiresConfirmation: false,
    confirmationReason: null,
  }
}

export function getDefaultSettings(): AppSettings {
  return {
    authToken: import.meta.env.VITE_ADMIN_TOKEN ?? '',
    bearClaw: {
      baseUrl: import.meta.env.VITE_BEARCLAW_API_BASE_URL ?? '',
      token: import.meta.env.VITE_BEARCLAW_TOKEN ?? '',
    },
    koala: {
      baseUrl: import.meta.env.VITE_KOALA_API_BASE_URL ?? '',
      token: import.meta.env.VITE_KOALA_TOKEN ?? '',
    },
    polar: {
      baseUrl: import.meta.env.VITE_POLAR_API_BASE_URL ?? '',
      token: import.meta.env.VITE_POLAR_TOKEN ?? '',
    },
  }
}

export function createBearClawClient(settings: AppSettings) {
  const baseUrl = normalizeBaseUrl(settings.bearClaw.baseUrl)
  const token = serviceToken(settings.authToken, settings.bearClaw.token)

  return {
    async sendChat(message: string): Promise<ChatResponse> {
      if (!canRequest(baseUrl)) {
        return previewBearClawReply(message)
      }

      const response = await requestJson<BearClawChatEnvelope>(`${baseUrl}/v1/chat`, {
        method: 'POST',
        headers: buildHeaders(token),
        body: JSON.stringify({ message }),
      })

      return {
        message: {
          id: response.message.id,
          role: response.message.role,
          content: response.message.content,
          timestamp: normalizeBearClawTimestamp(response.message.timestamp),
        },
        requiresConfirmation: response.requires_confirmation ?? false,
        confirmationReason: response.confirmation_reason ?? null,
      }
    },

    async getHealth(): Promise<Tone> {
      if (!canRequest(baseUrl)) {
        return 'neutral'
      }

      const response = await requestJson<BearClawHealth>(`${baseUrl}/health`, {
        method: 'GET',
        headers: buildHeaders(token, false),
      })

      return toneFromStatus(response.status)
    },
  }
}

export function createKoalaAdminClient(settings: AppSettings) {
  const baseUrl = normalizeBaseUrl(settings.koala.baseUrl)
  const token = serviceToken(settings.authToken, settings.koala.token)

  async function postTool<T>(tool: string, input: Record<string, unknown> = {}) {
    return requestJson<ToolEnvelope<T>>(`${baseUrl}/mcp/tools/${tool}`, {
      method: 'POST',
      headers: buildHeaders(token),
      body: JSON.stringify({ input }),
    })
  }

  return {
    async loadOverview(): Promise<SecuritySnapshot> {
      if (!canRequest(baseUrl)) {
        return {
          cards: initialSecurityCards,
          events: initialSecurityEvents,
          securityMode: 'preview',
          lastUpdatedLabel: 'preview',
        }
      }

      const [health, cameras, zone, packageState, ingest] = await Promise.all([
        postTool<KoalaHealth>('koala.get_system_health'),
        postTool<{ cameras: KoalaCamera[] }>('koala.list_cameras'),
        postTool<KoalaZoneState>('koala.get_zone_state', { zone_id: 'front_door' }),
        postTool<KoalaPackageState>('koala.check_package_at_door'),
        requestJson<ToolEnvelope<KoalaIngestStatus>>(`${baseUrl}/admin/ingest/status`, {
          method: 'GET',
          headers: buildHeaders(token, false),
        }),
      ])

      const cameraList = cameras.data.cameras
      const availableCount = cameraList.filter((camera) => camera.status === 'available').length
      const packagePresent = packageState.data.package_present
      const incidents = ingest.data.incidents.slice(0, 3)

      const cards: SummaryCard[] = [
        {
          label: 'Cameras',
          value: `${availableCount}/${cameraList.length}`,
          detail: 'Available camera feeds in Koala registry',
          tone: availableCount === cameraList.length ? 'healthy' : 'warning',
        },
        {
          label: 'Inference',
          value: health.data.inference,
          detail: `MCP ${health.data.mcp} · ingest ${health.data.ingest}`,
          tone: toneFromStatus(health.data.inference),
        },
        {
          label: 'Package',
          value: packagePresent ? 'present' : 'clear',
          detail: `Confidence ${formatNumber(packageState.data.confidence * 100)}%`,
          tone: packagePresent ? 'warning' : 'healthy',
        },
      ]

      const events: SecurityEvent[] = [
        {
          id: crypto.randomUUID(),
          title: packagePresent ? 'Package currently detected' : 'No package detected',
          body: `Front door check last observed ${formatIsoLabel(packageState.data.observed_at)}.`,
          timeLabel: formatIsoLabel(packageState.data.observed_at),
          tone: packagePresent ? 'warning' : 'healthy',
        },
        {
          id: crypto.randomUUID(),
          title: 'Zone state refreshed',
          body: `${zone.data.zone_id} has ${zone.data.entities.length} tracked entities in the current Koala snapshot.`,
          timeLabel: formatIsoLabel(zone.data.observed_at),
          tone: zone.status === 'ok' ? 'healthy' : 'warning',
        },
        ...incidents.map((incident) => ({
          id: crypto.randomUUID(),
          title: `${incident.camera_id}: ${incident.type.replaceAll('_', ' ')}`,
          body: incident.message,
          timeLabel: formatIsoLabel(incident.occurred_at),
          tone: toneFromStatus(incident.severity),
        })),
      ]

      return {
        cards,
        events,
        securityMode: `${availableCount}/${cameraList.length} cameras available`,
        lastUpdatedLabel: formatIsoLabel(zone.data.observed_at),
      }
    },

    async checkPackage(): Promise<SecurityEvent> {
      if (!canRequest(baseUrl)) {
        return {
          ...initialSecurityEvents[0],
          id: crypto.randomUUID(),
          title: 'Preview package check completed',
          timeLabel: 'just now',
        }
      }

      const response = await postTool<KoalaPackageState>('koala.check_package_at_door')
      return {
        id: crypto.randomUUID(),
        title: response.data.package_present ? 'Package present at front door' : 'Package check clear',
        body: `Confidence ${formatNumber(response.data.confidence * 100)}% · freshness ${response.status}.`,
        timeLabel: formatIsoLabel(response.data.observed_at),
        tone: response.data.package_present ? 'warning' : 'healthy',
      }
    },
  }
}

export function createPolarAdminClient(settings: AppSettings) {
  const baseUrl = normalizeBaseUrl(settings.polar.baseUrl)
  const token = serviceToken(settings.authToken, settings.polar.token)

  return {
    async loadOverview(): Promise<WeatherSnapshot> {
      if (!canRequest(baseUrl)) {
        return {
          readings: initialPolarReadings,
          timeline: initialWeatherTimeline,
          climateSummary: '68 F / 44%',
          lastUpdatedLabel: 'preview',
        }
      }

      const [latestReadings, forecast, stationHealth] = await Promise.all([
        requestJson<PolarReadingRaw[]>(`${baseUrl}/v1/readings/latest`, {
          method: 'GET',
          headers: buildHeaders(token, false),
        }),
        requestJson<PolarForecast>(`${baseUrl}/v1/forecast/latest`, {
          method: 'GET',
          headers: buildHeaders(token, false),
        }),
        requestJson<PolarStationHealth>(`${baseUrl}/v1/station/health`, {
          method: 'GET',
          headers: buildHeaders(token, false),
        }),
      ])

      const temperature = latestReadings.find((reading) => reading.metric === 'temperature')
      const humidity = latestReadings.find((reading) => reading.metric === 'humidity')
      const nextForecast = forecast.points[0]

      const readings: PolarReading[] = [
        {
          label: 'home temp',
          value: temperature ? `${formatNumber(temperature.value)} ${temperature.unit}` : '--',
          detail: temperature ? `Recorded ${formatIsoLabel(temperature.recorded_at)}` : 'No recent reading',
          tone: temperature ? 'healthy' : 'warning',
        },
        {
          label: 'humidity',
          value: humidity ? `${formatNumber(humidity.value)} ${humidity.unit}` : '--',
          detail: humidity ? `Recorded ${formatIsoLabel(humidity.recorded_at)}` : 'No recent reading',
          tone: humidity ? 'healthy' : 'warning',
        },
        {
          label: '7-day outlook',
          value: nextForecast
            ? `${formatNumber(nextForecast.temperature_c)} C next`
            : 'No forecast',
          detail: forecast.stale
            ? `Forecast stale: ${forecast.stale_reason ?? 'unknown reason'}`
            : `Provider ${forecast.provider}`,
          tone: forecast.stale ? 'warning' : 'healthy',
        },
      ]

      const timeline: TimelineItem[] = [
        {
          id: crypto.randomUUID(),
          title: 'Station health',
          body: `Polar reports overall health ${stationHealth.overall}.`,
          meta: formatIsoLabel(stationHealth.generated_at),
          tone: toneFromStatus(stationHealth.overall),
        },
        ...stationHealth.components.slice(0, 2).map((component) => ({
          id: crypto.randomUUID(),
          title: component.name,
          body: component.message,
          meta: component.status,
          tone: toneFromStatus(component.status),
        })),
      ]

      return {
        readings,
        timeline,
        climateSummary: temperature && humidity
          ? `${formatNumber(temperature.value)} ${temperature.unit} / ${formatNumber(humidity.value)} ${humidity.unit}`
          : 'live partial',
        lastUpdatedLabel: formatIsoLabel(forecast.fetched_at),
      }
    },
  }
}
