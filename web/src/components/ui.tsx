import { useEffect, useState, type ReactNode } from 'react'
import type { ActivityItem, AppTab, KoalaCameraCard, HomeDevice, TimelineItem, Tone } from '../lib/types'

const adminTabs: Array<{ id: AppTab; label: string; eyebrow: string }> = [
  { id: 'chat', label: 'Chat', eyebrow: 'BearClaw' },
  { id: 'weather', label: 'Weather', eyebrow: 'Polar' },
  { id: 'security', label: 'Security', eyebrow: 'Koala' },
  { id: 'finance', label: 'Finance', eyebrow: 'Ops' },
  { id: 'settings', label: 'Settings', eyebrow: 'Admin' },
]

const liveTabs: Array<{ id: AppTab; label: string; eyebrow: string }> = [
  { id: 'live-home', label: 'Home', eyebrow: 'Live' },
  { id: 'live-activity', label: 'Activity', eyebrow: 'Alerts' },
  { id: 'live-cameras', label: 'Cameras', eyebrow: 'Views' },
  { id: 'live-climate', label: 'Climate', eyebrow: 'Air & Weather' },
  { id: 'live-profile', label: 'Profile', eyebrow: 'Household' },
]

type NavRailProps = {
  activeTab: AppTab
  onSelect: (tab: AppTab) => void
}

export function NavRail({ activeTab, onSelect }: NavRailProps) {
  return (
    <aside className="nav-rail">
      <div className="brand-lockup">
        <p>Bear Claw</p>
        <h2>Administrative command surface</h2>
      </div>
      <nav className="nav-list" aria-label="Primary">
        <p className="nav-section-label">Admin</p>
        {adminTabs.map((tab) => (
          <button
            key={tab.id}
            className={tab.id === activeTab ? 'nav-item nav-item-active' : 'nav-item'}
            onClick={() => onSelect(tab.id)}
            type="button"
          >
            <span>{tab.eyebrow}</span>
            <strong>{tab.label}</strong>
          </button>
        ))}
        <p className="nav-section-label nav-section-label-live">Koala Live</p>
        {liveTabs.map((tab) => (
          <button
            key={tab.id}
            className={tab.id === activeTab ? 'nav-item nav-item-active' : 'nav-item'}
            onClick={() => onSelect(tab.id)}
            type="button"
          >
            <span>{tab.eyebrow}</span>
            <strong>{tab.label}</strong>
          </button>
        ))}
      </nav>
      <div className="nav-footnote">
        The web shell mirrors BearClaw iOS information architecture while keeping direct admin access to Koala and Polar.
      </div>
    </aside>
  )
}

type PanelProps = {
  eyebrow: string
  title: string
  subtitle: string
  children: ReactNode
}

export function Panel({ eyebrow, title, subtitle, children }: PanelProps) {
  return (
    <section className="panel">
      <header className="panel-header">
        <p>{eyebrow}</p>
        <h3>{title}</h3>
        <span>{subtitle}</span>
      </header>
      {children}
    </section>
  )
}

type StatCardProps = {
  label: string
  value: string
  detail: string
  tone?: Tone
}

export function StatCard({
  label,
  value,
  detail,
  tone = 'neutral',
}: StatCardProps) {
  return (
    <article className={`stat-card tone-${tone}`}>
      <span>{label}</span>
      <strong>{value}</strong>
      <p>{detail}</p>
    </article>
  )
}

type ServiceBadgeProps = {
  label: string
  value: string
  tone: Tone
}

export function ServiceBadge({ label, value, tone }: ServiceBadgeProps) {
  return (
    <div className={`service-badge tone-${tone}`}>
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  )
}

type QuickActionButtonProps = {
  label: string
  detail: string
  onClick: () => void
}

export function QuickActionButton({
  label,
  detail,
  onClick,
}: QuickActionButtonProps) {
  return (
    <button className="quick-action" onClick={onClick} type="button">
      <strong>{label}</strong>
      <span>{detail}</span>
    </button>
  )
}

type ActivityTimelineProps = {
  items: TimelineItem[]
}

export function ActivityTimeline({ items }: ActivityTimelineProps) {
  return (
    <div className="timeline">
      {items.map((item) => (
        <article key={item.id} className={`timeline-item tone-${item.tone}`}>
          <div className="timeline-marker" />
          <div>
            <header>
              <strong>{item.title}</strong>
              <span>{item.meta}</span>
            </header>
            <p>{item.body}</p>
          </div>
        </article>
      ))}
    </div>
  )
}

// --- Koala Live components ---

type StatusPillProps = {
  label: string
  tone: Tone
}

export function StatusPill({ label, tone }: StatusPillProps) {
  return <span className={`status-pill tone-${tone}`}>{label}</span>
}

type CameraCardViewProps = {
  camera: KoalaCameraCard
}

export function CameraCardView({ camera }: CameraCardViewProps) {
  const [buster, setBuster] = useState(() => Date.now())

  useEffect(() => {
    if (!camera.snapshotUrl) return
    const interval = setInterval(() => setBuster(Date.now()), 5000)
    return () => clearInterval(interval)
  }, [camera.snapshotUrl])

  return (
    <article className={`live-camera-card tone-${camera.tone}`}>
      <header>
        <div>
          <strong>{camera.name}</strong>
          <span>{camera.zoneLabel}</span>
        </div>
        <StatusPill label={camera.statusLabel} tone={camera.tone} />
      </header>
      {camera.snapshotUrl && (
        <img
          className="camera-snapshot"
          src={`${camera.snapshotUrl}&t=${buster}`}
          alt={`${camera.name} live snapshot`}
        />
      )}
      <p>{camera.detail}</p>
    </article>
  )
}

type ActivityListProps = {
  items: ActivityItem[]
  savedKeys: Set<string>
  onToggleSave: (item: ActivityItem) => void
}

export function ActivityList({ items, savedKeys, onToggleSave }: ActivityListProps) {
  return (
    <div className="activity-list">
      {items.map((item) => {
        const isSaved = savedKeys.has(item.saveKey)
        return (
          <article key={item.id} className={`activity-card tone-${item.tone}`}>
            <div className="activity-dot" />
            <div className="activity-body">
              <header>
                <div>
                  <strong>{item.title}</strong>
                  <span>{item.timeLabel}</span>
                </div>
                <button className="ghost-button" onClick={() => onToggleSave(item)} type="button">
                  {isSaved ? 'Saved' : 'Save'}
                </button>
              </header>
              <p>{item.body}</p>
            </div>
          </article>
        )
      })}
    </div>
  )
}

type ToggleRowProps = {
  label: string
  detail: string
  checked: boolean
  onChange: (value: boolean) => void
}

export function ToggleRow({ label, detail, checked, onChange }: ToggleRowProps) {
  return (
    <label className="toggle-row">
      <div>
        <strong>{label}</strong>
        <span>{detail}</span>
      </div>
      <input
        checked={checked}
        onChange={(event) => onChange(event.target.checked)}
        type="checkbox"
      />
    </label>
  )
}

export type DeviceAction = 'lock' | 'unlock' | 'open' | 'close'

type DeviceRowProps = {
  device: HomeDevice
  onAction: (deviceId: string, action: DeviceAction) => void
}

export function DeviceRow({ device, onAction }: DeviceRowProps) {
  const stateLabel = device.lockState ?? device.openState ?? device.statusLabel ?? 'unknown'
  const isLocked = device.lockState === 'locked'
  const isOpen = device.openState === 'open'

  return (
    <div className="device-row">
      <div className="device-row-info">
        <strong>{device.name}</strong>
        <span className="device-zone">{device.zone}</span>
      </div>
      <StatusPill label={stateLabel} tone={device.tone} />
      {device.type === 'lock' && device.lockState !== 'unknown' && (
        <button
          className={isLocked ? 'ghost-button' : 'device-action-warn'}
          onClick={() => onAction(device.id, isLocked ? 'unlock' : 'lock')}
          type="button"
        >
          {isLocked ? 'Unlock' : 'Lock'}
        </button>
      )}
      {(device.type === 'door' || device.type === 'window') && device.openState !== 'unknown' && (
        <button
          className="ghost-button"
          onClick={() => onAction(device.id, isOpen ? 'close' : 'open')}
          type="button"
        >
          {isOpen ? 'Close' : 'Open'}
        </button>
      )}
    </div>
  )
}
