# BearClaw Web

BearClaw Web is the administrative web surface for the BearClaw home runtime.

It mirrors the current BearClaw iOS information architecture:

- Chat
- Weather
- Security
- Finance
- Settings

It is designed to keep direct administrative integration paths to:

- BearClaw
- Koala
- Polar

Consumer-facing live security playback belongs in Koala-owned product surfaces, not in this app.

## Stack

- React
- TypeScript
- Vite
- CSS variables with a token-oriented visual system

## Run

```bash
npm install
npm run dev
```

## Build

```bash
npm run build
npm run lint
```

## Environment

The app runs in preview mode by default. To point it at live services, set any of the following:

```bash
VITE_ADMIN_TOKEN=
VITE_BEARCLAW_API_BASE_URL=
VITE_BEARCLAW_TOKEN=
VITE_KOALA_API_BASE_URL=
VITE_KOALA_TOKEN=
VITE_POLAR_API_BASE_URL=
VITE_POLAR_TOKEN=
```

`VITE_ADMIN_TOKEN` acts as the shared fallback token. Each service can also override that token independently from the Settings screen or with its own env var.

## Notes

- Current first deployment target: Docker on `blink` Ubuntu
- Live camera playback is intentionally out of scope for this app
- Product and architecture direction live in `PLAN.md`
