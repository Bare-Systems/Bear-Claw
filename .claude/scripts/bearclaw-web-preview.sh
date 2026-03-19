#!/usr/bin/env bash
# Start the BearClaw React/Vite dev server so Claude Preview can inspect it.
# The dev server runs locally at http://localhost:5173 — no homelab deploy needed.

set -euo pipefail

WEB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../web" && pwd)"
PORT=5173

echo "==> Starting BearClaw web dev server in ${WEB_DIR}"
echo "==> Dev UI available at http://localhost:${PORT}"
exec npm --prefix "${WEB_DIR}" run dev -- --port "${PORT}" --host 127.0.0.1
