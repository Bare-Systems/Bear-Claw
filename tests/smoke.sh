#!/usr/bin/env bash
# BearClaw Smoke Test
#
# Fast sanity checks — no Discord needed:
#   1. Binary exists and shows status
#   2. Ollama is reachable
#   3. Agent responds to a prompt (end-to-end LLM call)
#   4. Zig unit tests pass
#
# Usage:
#   ./tests/smoke.sh
#
# Exit 0 on pass, 1 on fail.

set -euo pipefail

BINARY="${BINARY:-$(dirname "$0")/../zig-out/bin/bareclaw}"
REPO="$(dirname "$0")/.."

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; exit 1; }
info() { echo -e "${YELLOW}→${NC} $1"; }

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  BearClaw Smoke Test"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 1. Binary exists
info "Checking binary..."
[ -f "$BINARY" ] || fail "Binary not found at $BINARY — run: zig build"
pass "Binary exists"

# 2. Status command works
info "Running bareclaw status..."
STATUS=$("$BINARY" status 2>&1)
echo "$STATUS" | grep -q "Provider:" || fail "Status output missing Provider field"
echo "$STATUS" | grep -q "Model:"    || fail "Status output missing Model field"
pass "Status OK"

# 3. Zig unit tests
info "Running zig unit tests..."
cd "$REPO"
if zig build test 2>&1 | grep -q "error:"; then
    fail "Zig unit tests failed"
fi
pass "Zig unit tests passed"

# 4. Ollama reachable
info "Checking Ollama..."
if ! curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
    fail "Ollama is not running — start it with: ollama serve"
fi
pass "Ollama reachable"

# 5. Agent round-trip
info "Running agent round-trip (this may take a few seconds)..."
REPLY=$("$BINARY" agent "respond with exactly one word: PONG" 2>/dev/null || true)
[ -n "$REPLY" ] || fail "Agent returned empty response"
pass "Agent responded: \"${REPLY:0:80}\""

# ── Report ────────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
pass "ALL SMOKE TESTS PASSED"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
exit 0
