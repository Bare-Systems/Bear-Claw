import type {
  AlertItem,
  ChatMessage,
  FinanceMetric,
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
