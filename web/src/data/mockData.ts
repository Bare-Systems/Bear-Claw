import type {
  ActivityItem,
  AlertItem,
  ChatMessage,
  ClimateSnapshot,
  DashboardSnapshot,
  FinanceMetric,
  HomeDevice,
  KoalaCameraCard,
  KoalaStatItem,
  PolarReading,
  SecurityEvent,
  SummaryCard,
  TimelineItem,
  SystemSummary,
} from '../lib/types'

export const quickPrompts = [
  'Summarize the current Koala security posture.',
  'Compare today’s Polar outlook with the in-home climate trend.',
  'What administrative actions need my approval right now?',
]

export const initialChatMessages: ChatMessage[] = [
  {
    id: crypto.randomUUID(),
    role: 'system',
    content:
      'BearClaw Web is in preview mode. Connect the live services from Settings to turn this shell into the real administrative control plane.',
    timestamp: new Date().toISOString(),
  },
  {
    id: crypto.randomUUID(),
    role: 'assistant',
    content:
      'Koala and Polar are represented as direct admin integrations here. Consumer-facing camera playback should live in Koala Live, not in BearClaw Web.',
    timestamp: new Date().toISOString(),
  },
]

export const initialAlerts: AlertItem[] = [
  {
    id: crypto.randomUUID(),
    title: 'Security write actions need approval',
    body: 'Administrative security actions should stay gated even when BearClaw Web has direct Koala access.',
    tone: 'warning',
  },
  {
    id: crypto.randomUUID(),
    title: 'Blink-first deployment',
    body: 'Current target is Docker on blink Ubuntu. Jetson and Proxmox can follow after the admin shell is stable.',
    tone: 'healthy',
  },
]

export const initialPolarReadings: PolarReading[] = [
  {
    label: 'home temp',
    value: '68 F',
    detail: 'Stable indoor climate profile',
    tone: 'healthy',
  },
  {
    label: 'humidity',
    value: '44%',
    detail: 'Inside recommended range',
    tone: 'healthy',
  },
  {
    label: '7-day outlook',
    value: 'storm Tue, clear weekend',
    detail: 'Public forecast merge placeholder',
    tone: 'warning',
  },
]

export const initialWeatherTimeline: TimelineItem[] = [
  {
    id: crypto.randomUUID(),
    title: 'Forecast cache warm',
    body: 'Latest forecast pulled from Polar and stored for admin display.',
    meta: 'healthy',
    tone: 'healthy',
  },
  {
    id: crypto.randomUUID(),
    title: 'Sensor ingest pending',
    body: 'Live device readings can replace seeded preview values once the feed is wired.',
    meta: 'preview',
    tone: 'neutral',
  },
]

export const initialSecurityEvents: SecurityEvent[] = [
  {
    id: crypto.randomUUID(),
    title: 'Front door perimeter healthy',
    body: 'Camera ingest and lock state checks are passing in the current preview snapshot.',
    timeLabel: '2m ago',
    tone: 'healthy',
  },
  {
    id: crypto.randomUUID(),
    title: 'Lockdown workflow staged',
    body: 'High-risk actions should step through BearClaw approval before Koala executes them.',
    timeLabel: '14m ago',
    tone: 'warning',
  },
  {
    id: crypto.randomUUID(),
    title: 'Media path deferred',
    body: 'Live camera playback is intentionally deferred until Koala media plumbing is ready.',
    timeLabel: 'today',
    tone: 'neutral',
  },
]

export const initialSecurityCards: SummaryCard[] = [
  {
    label: 'Cameras',
    value: 'preview',
    detail: 'Seeded camera state until Koala is connected',
    tone: 'neutral',
  },
  {
    label: 'Inference',
    value: 'preview',
    detail: 'Worker health comes from koala.get_system_health',
    tone: 'neutral',
  },
  {
    label: 'Package',
    value: 'unknown',
    detail: 'check_package_at_door not called yet',
    tone: 'warning',
  },
]

export const initialFinanceMetrics: FinanceMetric[] = [
  {
    label: 'Electric bill',
    value: '+$18',
    delta: 'vs last month',
    detail: 'Spring HVAC usage is driving the change',
    tone: 'warning',
  },
  {
    label: 'Spending',
    value: 'Within budget',
    delta: 'month to date',
    detail: 'No anomalies in recurring spend',
    tone: 'healthy',
  },
  {
    label: 'Cash flow',
    value: 'Healthy',
    delta: '14-day lookahead',
    detail: 'No short-term concerns flagged',
    tone: 'healthy',
  },
]

const summaryCards: SummaryCard[] = [
  {
    label: 'Shell mode',
    value: 'Admin',
    detail: 'Desktop and tablet control plane',
    tone: 'healthy',
  },
  {
    label: 'Koala',
    value: 'Direct admin path',
    detail: 'Consumer-facing UI stays in Koala',
    tone: 'warning',
  },
  {
    label: 'Polar',
    value: 'Embedded domain',
    detail: 'Climate intelligence inside BearClaw Web',
    tone: 'healthy',
  },
  {
    label: 'Deployment',
    value: 'blink first',
    detail: 'Container-first rollout on Ubuntu',
    tone: 'neutral',
  },
]

export const initialSystemSummary: SystemSummary = {
  securityMode: 'armed-home',
  climateSummary: '68 F / 44%',
  financeSummary: 'budget on track',
  lastUpdatedLabel: 'preview',
  cards: summaryCards,
}

// --- Koala Live preview data ---

const previewLiveStats: KoalaStatItem[] = [
  { label: 'System', value: 'Preview', detail: 'Waiting for a live Koala endpoint', tone: 'neutral' },
  { label: 'Package', value: 'Unknown', detail: 'Run a package check when connected', tone: 'warning' },
  { label: 'Cameras', value: '0 online', detail: 'Live camera roster will appear here', tone: 'neutral' },
]

const previewLiveCameras: KoalaCameraCard[] = [
  {
    id: 'preview-front',
    name: 'Front Door',
    zoneLabel: 'front_door',
    statusLabel: 'preview',
    detail: 'Connect Koala to load the real camera roster.',
    tone: 'neutral',
  },
  {
    id: 'preview-drive',
    name: 'Driveway',
    zoneLabel: 'driveway',
    statusLabel: 'preview',
    detail: 'Consumer playback lives here once the media path is ready.',
    tone: 'neutral',
  },
]

const previewLiveDevices: HomeDevice[] = [
  { id: 'lock-front-door', name: 'Front Door', type: 'lock', zone: 'front_door', tone: 'healthy', detail: 'Deadbolt · Last locked 6:02 PM', lockState: 'locked' },
  { id: 'lock-back-door', name: 'Back Door', type: 'lock', zone: 'back_door', tone: 'warning', detail: 'Deadbolt · Last activity 3:15 PM', lockState: 'unlocked' },
  { id: 'lock-garage-side', name: 'Garage Side Entry', type: 'lock', zone: 'garage', tone: 'healthy', detail: 'Keypad lock · Last locked 8:00 AM', lockState: 'locked' },
  { id: 'door-garage', name: 'Garage Door', type: 'door', zone: 'garage', tone: 'warning', detail: 'Overhead · Opened 4:47 PM', openState: 'open' },
  { id: 'door-back', name: 'Back Door', type: 'door', zone: 'back_yard', tone: 'healthy', detail: 'Entry door · Closed 3:15 PM', openState: 'closed' },
  { id: 'window-living-room', name: 'Living Room', type: 'window', zone: 'living_room', tone: 'neutral', detail: 'Left panel · Opened 2:30 PM', openState: 'open' },
  { id: 'window-master', name: 'Master Bedroom', type: 'window', zone: 'master_bedroom', tone: 'healthy', detail: 'Both panels · Closed 9:00 AM', openState: 'closed' },
  { id: 'window-kitchen', name: 'Kitchen', type: 'window', zone: 'kitchen', tone: 'healthy', detail: 'Single panel · Closed 7:45 AM', openState: 'closed' },
]

const previewLiveActivity: ActivityItem[] = [
  {
    id: 'preview-1',
    title: 'Koala Live is ready for connection',
    body: 'This consumer UI is live. Point it at a Koala service to replace the preview feed.',
    timeLabel: 'now',
    tone: 'healthy',
    saveKey: 'preview-1',
  },
  {
    id: 'preview-2',
    title: 'Saved moments are local for now',
    body: 'Until recording APIs exist, saved moments are stored in the browser only.',
    timeLabel: 'preview',
    tone: 'warning',
    saveKey: 'preview-2',
  },
]

export const previewLiveDashboard: DashboardSnapshot = {
  headline: 'Home status ready',
  subheadline: 'Koala Live is the consumer-facing home monitor. Connect a live Koala endpoint to replace this preview data.',
  packageSummary: 'Package state unavailable in preview mode.',
  zoneSummary: 'Front door zone not yet connected.',
  serviceLabel: 'preview',
  serviceTone: 'neutral',
  stats: previewLiveStats,
  cameras: previewLiveCameras,
  devices: previewLiveDevices,
  activity: previewLiveActivity,
  lastUpdatedLabel: 'preview',
}

export const previewClimateSnapshot: ClimateSnapshot = {
  station_id: 'preview',
  generated_at: '',
  indoor: {
    sources: [],
    readings: [
      { name: 'temperature', display_name: 'Temperature', value: 0, unit: '°C', display_value: '--', domain: 'thermal', source: 'preview', quality: 'unavailable', recorded_at: '' },
      { name: 'humidity', display_name: 'Relative Humidity', value: 0, unit: '%', display_value: '--', domain: 'comfort', source: 'preview', quality: 'unavailable', recorded_at: '' },
      { name: 'co2', display_name: 'CO2', value: 0, unit: 'ppm', display_value: '--', domain: 'air_quality', source: 'preview', quality: 'unavailable', recorded_at: '' },
      { name: 'voc', display_name: 'VOCs', value: 0, unit: 'ppb', display_value: '--', domain: 'air_quality', source: 'preview', quality: 'unavailable', recorded_at: '' },
      { name: 'radon', display_name: 'Radon', value: 0, unit: 'Bq/m³', display_value: '--', domain: 'air_quality', source: 'preview', quality: 'unavailable', recorded_at: '' },
    ],
    stale: true,
  },
  outdoor: {
    sources: [],
    current: [
      { name: 'temperature', display_name: 'Temperature', value: 0, unit: '°C', display_value: '--', domain: 'thermal', source: 'preview', quality: 'unavailable', recorded_at: '' },
      { name: 'humidity', display_name: 'Relative Humidity', value: 0, unit: '%', display_value: '--', domain: 'comfort', source: 'preview', quality: 'unavailable', recorded_at: '' },
      { name: 'wind_speed', display_name: 'Wind Speed', value: 0, unit: 'm/s', display_value: '--', domain: 'weather', source: 'preview', quality: 'unavailable', recorded_at: '' },
      { name: 'precipitation', display_name: 'Precipitation', value: 0, unit: 'mm', display_value: '--', domain: 'weather', source: 'preview', quality: 'unavailable', recorded_at: '' },
    ],
    stale: true,
  },
}

export const systemPrompts = {
  general:
    'Preview mode: BearClaw would route this request through the administrative orchestration layer and use Koala or Polar directly where that produces a better admin outcome.',
  weather:
    'Preview mode: Polar currently reports stable indoor conditions with a storm watch on Tuesday and a cleaner weekend window after that.',
  security:
    'Preview mode: Koala reports the perimeter as healthy. Consumer playback remains a separate Koala Live concern, while this shell focuses on administrative status and actions.',
  lockdown:
    'Preview mode: this looks like a high-risk security action. The production path should require explicit approval before BearClaw allows Koala to execute it.',
}
