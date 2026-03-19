import { startTransition, useCallback, useEffect, useMemo, useState } from 'react'
import './App.css'
import {
  createBearClawClient,
  createKoalaAdminClient,
  createPolarAdminClient,
  getDefaultSettings,
} from './api/clients'
import {
  ActivityTimeline,
  NavRail,
  Panel,
  QuickActionButton,
  ServiceBadge,
  StatCard,
} from './components/ui'
import {
  initialAlerts,
  initialChatMessages,
  initialFinanceMetrics,
  initialPolarReadings,
  initialSecurityCards,
  initialSecurityEvents,
  initialSystemSummary,
  initialWeatherTimeline,
  quickPrompts,
} from './data/mockData'
import type {
  AdminActionId,
  AlertItem,
  AppSettings,
  AppTab,
  ChatMessage,
  FinanceMetric,
  PolarReading,
  SecurityEvent,
  SummaryCard,
  SystemSummary,
  TimelineItem,
  Tone,
} from './lib/types'

const storageKey = 'bearclaw-web-settings'

function canRequest(value: string): boolean {
  return /^https?:\/\//.test(value.trim())
}

function mergeSettings(defaults: AppSettings, parsed: Partial<AppSettings>): AppSettings {
  return {
    authToken: parsed.authToken ?? defaults.authToken,
    bearClaw: {
      ...defaults.bearClaw,
      ...parsed.bearClaw,
    },
    koala: {
      ...defaults.koala,
      ...parsed.koala,
    },
    polar: {
      ...defaults.polar,
      ...parsed.polar,
    },
  }
}

function updateSummaryCard(
  cards: SummaryCard[],
  label: string,
  value: string,
  detail: string,
  tone: Tone,
): SummaryCard[] {
  return cards.map((card) =>
    card.label === label ? { ...card, value, detail, tone } : card,
  )
}

function serviceLabel(configured: boolean, tone: Tone): string {
  if (!configured) {
    return 'preview'
  }
  if (tone === 'critical') {
    return 'error'
  }
  if (tone === 'warning') {
    return 'degraded'
  }
  return 'live'
}

function App() {
  const [activeTab, setActiveTab] = useState<AppTab>('chat')
  const [settings, setSettings] = useState<AppSettings>(() => {
    const defaults = getDefaultSettings()
    const stored = globalThis.localStorage?.getItem(storageKey)
    if (!stored) {
      return defaults
    }

    try {
      return mergeSettings(defaults, JSON.parse(stored) as Partial<AppSettings>)
    } catch {
      return defaults
    }
  })
  const [messages, setMessages] = useState<ChatMessage[]>(initialChatMessages)
  const [draft, setDraft] = useState('')
  const [isSending, setIsSending] = useState(false)
  const [alerts, setAlerts] = useState<AlertItem[]>(initialAlerts)
  const [securityEvents, setSecurityEvents] =
    useState<SecurityEvent[]>(initialSecurityEvents)
  const [securityCards, setSecurityCards] =
    useState<SummaryCard[]>(initialSecurityCards)
  const [polarReadings, setPolarReadings] =
    useState<PolarReading[]>(initialPolarReadings)
  const [weatherTimeline, setWeatherTimeline] =
    useState<TimelineItem[]>(initialWeatherTimeline)
  const [financeMetrics] = useState<FinanceMetric[]>(initialFinanceMetrics)
  const [systemSummary, setSystemSummary] =
    useState<SystemSummary>(initialSystemSummary)
  const [serviceTones, setServiceTones] = useState<{
    bearClaw: Tone
    koala: Tone
    polar: Tone
  }>({
    bearClaw: 'neutral',
    koala: 'neutral',
    polar: 'neutral',
  })
  const [lastActionStatus, setLastActionStatus] = useState(
    'Preview mode active. Configure live services in Settings or via environment variables to load real Koala and Polar data.',
  )

  useEffect(() => {
    globalThis.localStorage?.setItem(storageKey, JSON.stringify(settings))
  }, [settings])

  const bearClawClient = useMemo(() => createBearClawClient(settings), [settings])
  const koalaClient = useMemo(() => createKoalaAdminClient(settings), [settings])
  const polarClient = useMemo(() => createPolarAdminClient(settings), [settings])

  const pushAlert = useCallback((title: string, body: string, tone: Tone) => {
    setAlerts((current) => [
      {
        id: crypto.randomUUID(),
        title,
        body,
        tone,
      },
      ...current,
    ])
  }, [])

  const refreshBearClawHealth = useCallback(async (updateStatusMessage: boolean) => {
    if (!canRequest(settings.bearClaw.baseUrl)) {
      setServiceTones((current) => ({ ...current, bearClaw: 'neutral' }))
      return
    }

    try {
      const tone = await bearClawClient.getHealth()
      setServiceTones((current) => ({ ...current, bearClaw: tone }))
      if (updateStatusMessage) {
        setLastActionStatus('BearClaw health check completed.')
      }
    } catch (error) {
      const detail = error instanceof Error ? error.message : 'Unknown error'
      setServiceTones((current) => ({ ...current, bearClaw: 'critical' }))
      pushAlert('BearClaw health check failed', detail, 'critical')
    }
  }, [bearClawClient, pushAlert, settings.bearClaw.baseUrl])

  const refreshKoalaOverview = useCallback(async (updateStatusMessage: boolean) => {
    try {
      const snapshot = await koalaClient.loadOverview()
      setSecurityCards(snapshot.cards)
      setSecurityEvents(snapshot.events)
      setSystemSummary((current) => ({
        ...current,
        securityMode: snapshot.securityMode,
        lastUpdatedLabel: snapshot.lastUpdatedLabel,
        cards: updateSummaryCard(
          current.cards,
          'Koala',
          snapshot.securityMode,
          `Last updated ${snapshot.lastUpdatedLabel}`,
          'healthy',
        ),
      }))
      setServiceTones((current) => ({ ...current, koala: 'healthy' }))
      if (updateStatusMessage) {
        setLastActionStatus('Koala administrative data refreshed.')
      }
    } catch (error) {
      const detail = error instanceof Error ? error.message : 'Unknown error'
      setServiceTones((current) => ({ ...current, koala: 'critical' }))
      pushAlert('Koala refresh failed', detail, 'critical')
    }
  }, [koalaClient, pushAlert])

  const refreshPolarOverview = useCallback(async (updateStatusMessage: boolean) => {
    try {
      const snapshot = await polarClient.loadOverview()
      setPolarReadings(snapshot.readings)
      setWeatherTimeline(snapshot.timeline)
      setSystemSummary((current) => ({
        ...current,
        climateSummary: snapshot.climateSummary,
        lastUpdatedLabel: snapshot.lastUpdatedLabel,
        cards: updateSummaryCard(
          current.cards,
          'Polar',
          snapshot.climateSummary,
          `Last updated ${snapshot.lastUpdatedLabel}`,
          'healthy',
        ),
      }))
      setServiceTones((current) => ({ ...current, polar: 'healthy' }))
      if (updateStatusMessage) {
        setLastActionStatus('Polar data refreshed.')
      }
    } catch (error) {
      const detail = error instanceof Error ? error.message : 'Unknown error'
      setServiceTones((current) => ({ ...current, polar: 'critical' }))
      pushAlert('Polar refresh failed', detail, 'critical')
    }
  }, [polarClient, pushAlert])

  useEffect(() => {
    let cancelled = false

    async function hydrateLiveData() {
      const tasks: Promise<void>[] = []

      if (canRequest(settings.bearClaw.baseUrl)) {
        tasks.push(
          (async () => {
            if (!cancelled) {
              await refreshBearClawHealth(false)
            }
          })(),
        )
      }

      if (canRequest(settings.koala.baseUrl)) {
        tasks.push(
          (async () => {
            if (!cancelled) {
              await refreshKoalaOverview(false)
            }
          })(),
        )
      }

      if (canRequest(settings.polar.baseUrl)) {
        tasks.push(
          (async () => {
            if (!cancelled) {
              await refreshPolarOverview(false)
            }
          })(),
        )
      }

      await Promise.allSettled(tasks)
    }

    void hydrateLiveData()

    return () => {
      cancelled = true
    }
  }, [
    bearClawClient,
    koalaClient,
    polarClient,
    refreshBearClawHealth,
    refreshKoalaOverview,
    refreshPolarOverview,
    settings.authToken,
    settings.bearClaw.baseUrl,
    settings.bearClaw.token,
    settings.koala.baseUrl,
    settings.koala.token,
    settings.polar.baseUrl,
    settings.polar.token,
  ])

  async function handleSend(messageText: string) {
    const trimmed = messageText.trim()
    if (!trimmed || isSending) {
      return
    }

    const userMessage: ChatMessage = {
      id: crypto.randomUUID(),
      role: 'user',
      content: trimmed,
      timestamp: new Date().toISOString(),
    }

    setDraft('')
    setIsSending(true)
    setMessages((current) => [...current, userMessage])

    try {
      const response = await bearClawClient.sendChat(trimmed)

      setMessages((current) => [
        ...current,
        {
          id: crypto.randomUUID(),
          role: 'assistant',
          content: response.message.content,
          timestamp: response.message.timestamp,
        },
      ])

      if (response.requiresConfirmation && response.confirmationReason) {
        pushAlert('Confirmation required', response.confirmationReason, 'warning')
      }
    } catch (error) {
      const detail = error instanceof Error ? error.message : 'Unknown error'
      pushAlert('Chat request failed', detail, 'critical')
    } finally {
      setIsSending(false)
    }
  }

  async function handleAdminAction(action: AdminActionId) {
    try {
      if (action === 'koala-refresh') {
        await refreshKoalaOverview(true)
        return
      }

      if (action === 'koala-package') {
        const event = await koalaClient.checkPackage()
        setSecurityEvents((current) => [event, ...current].slice(0, 6))
        setLastActionStatus('Koala package check completed.')
        return
      }

      if (action === 'polar-refresh') {
        await refreshPolarOverview(true)
      }
    } catch (error) {
      const detail = error instanceof Error ? error.message : 'Unknown error'
      setLastActionStatus(detail)
      pushAlert('Administrative action failed', detail, 'critical')
    }
  }

  const configuredServices = [
    {
      name: 'BearClaw',
      tone: serviceTones.bearClaw,
      label: serviceLabel(canRequest(settings.bearClaw.baseUrl), serviceTones.bearClaw),
    },
    {
      name: 'Koala',
      tone: serviceTones.koala,
      label: serviceLabel(canRequest(settings.koala.baseUrl), serviceTones.koala),
    },
    {
      name: 'Polar',
      tone: serviceTones.polar,
      label: serviceLabel(canRequest(settings.polar.baseUrl), serviceTones.polar),
    },
  ] as const

  function renderMainPanel() {
    switch (activeTab) {
      case 'chat':
        return (
          <div className="content-grid content-grid-chat">
            <Panel
              eyebrow="Assistant"
              title="BearClaw Command Console"
              subtitle="Chat-first administrative control over BearClaw, Koala, and Polar."
            >
              <div className="quick-prompts">
                {quickPrompts.map((prompt) => (
                  <button
                    key={prompt}
                    className="quick-prompt"
                    onClick={() => setDraft(prompt)}
                    type="button"
                  >
                    {prompt}
                  </button>
                ))}
              </div>
              <div className="chat-log" role="log" aria-live="polite">
                {messages.map((message) => (
                  <article
                    key={message.id}
                    className={`chat-message chat-message-${message.role}`}
                  >
                    <header>
                      <span>{message.role}</span>
                      <time dateTime={message.timestamp}>
                        {new Date(message.timestamp).toLocaleTimeString([], {
                          hour: 'numeric',
                          minute: '2-digit',
                        })}
                      </time>
                    </header>
                    <p>{message.content}</p>
                  </article>
                ))}
              </div>
              <form
                className="composer"
                onSubmit={(event) => {
                  event.preventDefault()
                  void handleSend(draft)
                }}
              >
                <textarea
                  aria-label="Message BearClaw"
                  className="composer-input"
                  rows={4}
                  value={draft}
                  onChange={(event) => setDraft(event.target.value)}
                  placeholder="Ask BearClaw to summarize Koala alerts, compare Polar trends, or review system health."
                />
                <div className="composer-footer">
                  <span className="helper-text">
                    {canRequest(settings.bearClaw.baseUrl)
                      ? 'Live BearClaw chat configured.'
                      : 'Preview mode. Configure the BearClaw service in Settings.'}
                  </span>
                  <button className="primary-button" type="submit" disabled={isSending}>
                    {isSending ? 'Sending…' : 'Send'}
                  </button>
                </div>
              </form>
            </Panel>

            <div className="stack">
              <Panel
                eyebrow="Snapshot"
                title="Operational Focus"
                subtitle="The current cross-system posture for the home stack."
              >
                <div className="stats-grid two-up">
                  <StatCard
                    label="Security"
                    value={systemSummary.securityMode}
                    detail="Koala perimeter posture"
                  />
                  <StatCard
                    label="Climate"
                    value={systemSummary.climateSummary}
                    detail="Polar house conditions"
                  />
                  <StatCard
                    label="Finance"
                    value={systemSummary.financeSummary}
                    detail="Monthly household signal"
                  />
                  <StatCard
                    label="Last sync"
                    value={systemSummary.lastUpdatedLabel}
                    detail="Latest live service refresh"
                  />
                </div>
              </Panel>

              <Panel
                eyebrow="Queue"
                title="Approvals and Alerts"
                subtitle="Sensitive actions and degraded states stay visible here."
              >
                <ActivityTimeline
                  items={alerts.map((alert) => ({
                    id: alert.id,
                    title: alert.title,
                    body: alert.body,
                    meta: alert.tone,
                    tone: alert.tone,
                  }))}
                />
              </Panel>
            </div>
          </div>
        )
      case 'weather':
        return (
          <div className="content-grid">
            <Panel
              eyebrow="Polar"
              title="Climate and Forecast Admin"
              subtitle="Live Polar readings and forecast state when the service is configured."
            >
              <div className="stats-grid three-up">
                {polarReadings.map((reading) => (
                  <StatCard
                    key={reading.label}
                    label={reading.label}
                    value={reading.value}
                    detail={reading.detail}
                    tone={reading.tone}
                  />
                ))}
              </div>
              <div className="action-row">
                <QuickActionButton
                  label="Refresh Polar data"
                  detail="Reload readings, forecast, and station health from Polar."
                  onClick={() => void handleAdminAction('polar-refresh')}
                />
              </div>
            </Panel>

            <Panel
              eyebrow="Health"
              title="Weather Service Posture"
              subtitle="Operational quality for the climate stack."
            >
              <ActivityTimeline items={weatherTimeline} />
            </Panel>
          </div>
        )
      case 'security':
        return (
          <div className="content-grid">
            <Panel
              eyebrow="Koala"
              title="Security Administration"
              subtitle="Live Koala admin data and event state. Consumer playback remains in Koala Live."
            >
              <div className="stats-grid three-up">
                {securityCards.map((card) => (
                  <StatCard
                    key={card.label}
                    label={card.label}
                    value={card.value}
                    detail={card.detail}
                    tone={card.tone}
                  />
                ))}
              </div>
              <div className="action-row">
                <QuickActionButton
                  label="Refresh security state"
                  detail="Reload Koala health, cameras, zone state, and ingest incidents."
                  onClick={() => void handleAdminAction('koala-refresh')}
                />
                <QuickActionButton
                  label="Check package at door"
                  detail="Run Koala package detection using the default front door camera."
                  onClick={() => void handleAdminAction('koala-package')}
                />
              </div>
              <ActivityTimeline
                items={securityEvents.map((event) => ({
                  id: event.id,
                  title: event.title,
                  body: event.body,
                  meta: event.timeLabel,
                  tone: event.tone,
                }))}
              />
            </Panel>

            <Panel
              eyebrow="Boundary"
              title="Admin vs Consumer Surface"
              subtitle="BearClaw owns administration. Koala Live owns the home-user experience."
            >
              <ul className="boundary-list">
                <li>BearClaw Web: camera administration, events, system health, approvals.</li>
                <li>Koala Live: read-focused home monitoring, saved recordings, profile edits.</li>
                <li>Live camera playback should remain in Koala-owned product paths.</li>
              </ul>
            </Panel>
          </div>
        )
      case 'finance':
        return (
          <div className="content-grid">
            <Panel
              eyebrow="Financial Signal"
              title="Household Trend Snapshot"
              subtitle="A placeholder admin module aligned with the current iOS surface."
            >
              <div className="stats-grid three-up">
                {financeMetrics.map((metric) => (
                  <StatCard
                    key={metric.label}
                    label={metric.label}
                    value={metric.value}
                    detail={`${metric.delta} · ${metric.detail}`}
                    tone={metric.tone}
                  />
                ))}
              </div>
            </Panel>

            <Panel
              eyebrow="Next"
              title="Admin Direction"
              subtitle="This section can later point at Kodiak or another finance service without changing the BearClaw shell."
            >
              <ActivityTimeline
                items={[
                  {
                    id: 'finance-1',
                    title: 'Parity preserved',
                    body: 'Finance remains in the shell so the web and iOS products evolve with the same information architecture.',
                    meta: 'roadmap',
                    tone: 'neutral',
                  },
                  {
                    id: 'finance-2',
                    title: 'Service boundary open',
                    body: 'The frontend keeps a dedicated module slot for future direct administrative integrations.',
                    meta: 'future',
                    tone: 'healthy',
                  },
                ]}
              />
            </Panel>
          </div>
        )
      case 'settings':
        return (
          <div className="content-grid">
            <Panel
              eyebrow="Connectivity"
              title="Service Endpoints"
              subtitle="Use the shared admin token or override credentials per service when scopes differ."
            >
              <div className="settings-grid">
                <label className="field">
                  <span>BearClaw URL</span>
                  <input
                    value={settings.bearClaw.baseUrl}
                    onChange={(event) =>
                      setSettings((current) => ({
                        ...current,
                        bearClaw: {
                          ...current.bearClaw,
                          baseUrl: event.target.value,
                        },
                      }))
                    }
                    placeholder="https://bearclaw.example.com"
                  />
                </label>
                <label className="field">
                  <span>BearClaw token override</span>
                  <input
                    value={settings.bearClaw.token}
                    onChange={(event) =>
                      setSettings((current) => ({
                        ...current,
                        bearClaw: {
                          ...current.bearClaw,
                          token: event.target.value,
                        },
                      }))
                    }
                    placeholder="Optional"
                  />
                </label>
                <label className="field">
                  <span>Koala URL</span>
                  <input
                    value={settings.koala.baseUrl}
                    onChange={(event) =>
                      setSettings((current) => ({
                        ...current,
                        koala: {
                          ...current.koala,
                          baseUrl: event.target.value,
                        },
                      }))
                    }
                    placeholder="https://koala.example.com"
                  />
                </label>
                <label className="field">
                  <span>Koala token override</span>
                  <input
                    value={settings.koala.token}
                    onChange={(event) =>
                      setSettings((current) => ({
                        ...current,
                        koala: {
                          ...current.koala,
                          token: event.target.value,
                        },
                      }))
                    }
                    placeholder="Optional"
                  />
                </label>
                <label className="field">
                  <span>Polar URL</span>
                  <input
                    value={settings.polar.baseUrl}
                    onChange={(event) =>
                      setSettings((current) => ({
                        ...current,
                        polar: {
                          ...current.polar,
                          baseUrl: event.target.value,
                        },
                      }))
                    }
                    placeholder="https://polar.example.com"
                  />
                </label>
                <label className="field">
                  <span>Polar token override</span>
                  <input
                    value={settings.polar.token}
                    onChange={(event) =>
                      setSettings((current) => ({
                        ...current,
                        polar: {
                          ...current.polar,
                          token: event.target.value,
                        },
                      }))
                    }
                    placeholder="Optional"
                  />
                </label>
                <label className="field">
                  <span>Shared admin token</span>
                  <input
                    value={settings.authToken}
                    onChange={(event) =>
                      setSettings((current) => ({
                        ...current,
                        authToken: event.target.value,
                      }))
                    }
                    placeholder="Fallback token for all services"
                  />
                </label>
              </div>
            </Panel>

            <Panel
              eyebrow="Policy"
              title="Admin Deployment Notes"
              subtitle="The current delivery track is Docker on blink, then Jetson and Proxmox-ready later."
            >
              <ActivityTimeline
                items={[
                  {
                    id: 'settings-1',
                    title: 'First target: blink Ubuntu',
                    body: 'BearClaw Web should be deployable as static assets inside a container-first path.',
                    meta: 'deployment',
                    tone: 'healthy',
                  },
                  {
                    id: 'settings-2',
                    title: 'Live contracts are active',
                    body: 'Koala and Polar tabs now map onto the real repo-defined endpoints when URLs and tokens are configured.',
                    meta: 'integration',
                    tone: 'healthy',
                  },
                  {
                    id: 'settings-3',
                    title: 'Parity required',
                    body: 'BearClaw iOS and BearClaw Web should share feature language, data contracts, and visual tokens.',
                    meta: 'product',
                    tone: 'warning',
                  },
                ]}
              />
            </Panel>
          </div>
        )
      default:
        return null
    }
  }

  return (
    <div className="app-shell">
      <NavRail
        activeTab={activeTab}
        onSelect={(tab) => {
          startTransition(() => {
            setActiveTab(tab)
          })
        }}
      />

      <main className="workspace">
        <header className="hero-banner">
          <div>
            <p className="hero-kicker">BearClaw Admin</p>
            <h1>Home systems, one administrative surface.</h1>
            <p className="hero-copy">
              BearClaw Web is the desktop control plane for the BearClaw runtime,
              with direct administrative integration paths into Koala and Polar.
            </p>
          </div>
          <div className="hero-status">
            <div className="service-badges">
              {configuredServices.map((service) => (
                <ServiceBadge
                  key={service.name}
                  label={service.name}
                  tone={service.tone}
                  value={service.label}
                />
              ))}
            </div>
            <p className="hero-status-text">{lastActionStatus}</p>
          </div>
        </header>

        <section className="summary-strip">
          {systemSummary.cards.map((card) => (
            <StatCard
              key={card.label}
              label={card.label}
              value={card.value}
              detail={card.detail}
              tone={card.tone}
            />
          ))}
        </section>

        {renderMainPanel()}
      </main>
    </div>
  )
}

export default App
