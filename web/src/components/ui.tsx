import type { ReactNode } from 'react'
import type { AppTab, TimelineItem, Tone } from '../lib/types'

const tabs: Array<{ id: AppTab; label: string; eyebrow: string }> = [
  { id: 'chat', label: 'Chat', eyebrow: 'BearClaw' },
  { id: 'weather', label: 'Weather', eyebrow: 'Polar' },
  { id: 'security', label: 'Security', eyebrow: 'Koala' },
  { id: 'finance', label: 'Finance', eyebrow: 'Ops' },
  { id: 'settings', label: 'Settings', eyebrow: 'Admin' },
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
        {tabs.map((tab) => (
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
