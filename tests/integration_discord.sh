#!/usr/bin/env bash
# BearClaw Discord Integration Test
#
# Tests the full round-trip:
#   1. Start bareclaw channel discord
#   2. Confirm it logs in (READY event)
#   3. Send a test message via a Discord webhook (not the bot token, so bot won't filter it)
#   4. Wait for the bot to reply in the same channel
#   5. Fetch recent messages and verify bot responded
#   6. Exit 0 on pass, 1 on fail
#
# Usage:
#   ./tests/integration_discord.sh
#   WEBHOOK_URL=https://discord.com/api/webhooks/... ./tests/integration_discord.sh
#
# Requires: curl, jq
# Reads bot token from: ~/.bareclaw/config.toml or DISCORD_BOT_TOKEN env var
# Reads webhook URL from: ~/.bareclaw/config.toml (discord_webhook) or DISCORD_WEBHOOK_URL env var

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

BINARY="${BINARY:-$(dirname "$0")/../zig-out/bin/bareclaw}"
TIMEOUT_LOGIN="${TIMEOUT_LOGIN:-10}"   # seconds to wait for bot login
TIMEOUT_REPLY="${TIMEOUT_REPLY:-60}"   # seconds to wait for bot reply
TEST_MARKER="bareclaw-integration-test-$$"  # unique marker using PID
# Bot ID for the @mention — resolved from READY event but we hardcode for the test
BOT_USER_ID="${BOT_USER_ID:-1473359815958073375}"
TEST_MESSAGE="<@${BOT_USER_ID}> ${TEST_MARKER}"

CONFIG="$HOME/.bareclaw/config.toml"

# Resolve bot token (for reading messages from channel).
# Priority: DISCORD_BOT_TOKEN → DISCORD_TEST_TOKEN → config.toml discord_token
if [ -n "${DISCORD_BOT_TOKEN:-}" ]; then
    TOKEN="$DISCORD_BOT_TOKEN"
elif [ -n "${DISCORD_TEST_TOKEN:-}" ]; then
    TOKEN="$DISCORD_TEST_TOKEN"
else
    TOKEN=$(grep '^discord_token' "$CONFIG" 2>/dev/null | sed 's/.*= *"\(.*\)"/\1/' || true)
fi

# Resolve webhook URL (for sending test messages as non-bot)
if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
    WEBHOOK_URL="$DISCORD_WEBHOOK_URL"
else
    WEBHOOK_URL=$(grep '^discord_webhook' "$CONFIG" 2>/dev/null | sed 's/.*= *"\(.*\)"/\1/' || true)
fi

# Extract channel ID from the webhook URL
# Webhook format: https://discord.com/api/webhooks/<webhook_id>/<token>
# We need the channel ID separately for reading messages — get it via the webhook info endpoint
DISCORD_API="https://discord.com/api/v10"

# ── Helpers ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; exit 1; }
info() { echo -e "${YELLOW}→${NC} $1"; }

BOT_PID=""
LOG_FILE=$(mktemp /tmp/bareclaw-discord-test.XXXXXX)

cleanup() {
    if [ -n "$BOT_PID" ] && kill -0 "$BOT_PID" 2>/dev/null; then
        kill "$BOT_PID" 2>/dev/null || true
        wait "$BOT_PID" 2>/dev/null || true
    fi
    rm -f "$LOG_FILE"
}
trap cleanup EXIT

# ── Pre-flight checks ─────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  BearClaw Discord Integration Test"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

[ -f "$BINARY" ]       || fail "Binary not found at $BINARY — run: zig build"
command -v curl >/dev/null || fail "curl not found"
command -v jq   >/dev/null || fail "jq not found"
[ -n "$TOKEN" ]        || fail "No discord_token found in config or DISCORD_BOT_TOKEN env var"
[ -n "$WEBHOOK_URL" ]  || fail "No discord_webhook found in config or DISCORD_WEBHOOK_URL env var"

# Resolve channel ID from webhook info
info "Resolving channel from webhook..."
WEBHOOK_INFO=$(curl -sf "$WEBHOOK_URL" 2>/dev/null) || fail "Could not reach webhook URL"
CHANNEL_ID=$(echo "$WEBHOOK_INFO" | jq -r '.channel_id // empty')
[ -n "$CHANNEL_ID" ] || fail "Could not extract channel_id from webhook info"
pass "Webhook targets channel $CHANNEL_ID"

# Check Ollama is running
if ! curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
    fail "Ollama is not running — start it with: ollama serve"
fi
pass "Ollama is running"

# ── Step 1: Start the bot ─────────────────────────────────────────────────────

info "Starting bareclaw channel discord..."
"$BINARY" channel discord >"$LOG_FILE" 2>&1 &
BOT_PID=$!

# Wait for "logged in" line
WAITED=0
while [ $WAITED -lt $TIMEOUT_LOGIN ]; do
    if grep -q "logged in as" "$LOG_FILE" 2>/dev/null; then
        BOT_NAME=$(grep "logged in as" "$LOG_FILE" | sed 's/.*logged in as \([^ ]*\).*/\1/')
        pass "Bot logged in as $BOT_NAME"
        break
    fi
    if ! kill -0 "$BOT_PID" 2>/dev/null; then
        echo "Bot output:"
        cat "$LOG_FILE"
        fail "Bot process died before logging in"
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

if [ $WAITED -ge $TIMEOUT_LOGIN ]; then
    echo "Bot output so far:"
    cat "$LOG_FILE"
    fail "Bot did not log in within ${TIMEOUT_LOGIN}s"
fi

# ── Step 2: Send test message via webhook ─────────────────────────────────────
# Webhooks send as a non-bot user so the bot won't filter the message as self.
# The ?wait=true param makes Discord return the created message object with its ID.

info "Sending test message via webhook to #testing..."
SEND_RESPONSE=$(curl -sf -X POST \
    "${WEBHOOK_URL}?wait=true" \
    -H "Content-Type: application/json" \
    -d "{\"content\": \"$TEST_MESSAGE\", \"username\": \"bareclaw-test\"}" 2>&1) \
    || fail "Failed to send test message via webhook"

MESSAGE_ID=$(echo "$SEND_RESPONSE" | jq -r '.id // empty')
[ -n "$MESSAGE_ID" ] || fail "Webhook did not return a message ID — response: $SEND_RESPONSE"
pass "Test message sent (id=$MESSAGE_ID, marker=$TEST_MESSAGE)"

# ── Step 3: Wait for bot reply ────────────────────────────────────────────────

info "Waiting up to ${TIMEOUT_REPLY}s for bot reply..."
WAITED=0
BOT_REPLY=""

while [ $WAITED -lt $TIMEOUT_REPLY ]; do
    sleep 2
    WAITED=$((WAITED + 2))

    # Primary check: bot process log shows it sent a reply (fastest)
    if grep -q "reply sent" "$LOG_FILE" 2>/dev/null; then
        BOT_REPLY=$(grep "sending reply:" "$LOG_FILE" | tail -1 | sed 's/.*sending reply: //')
        [ -n "$BOT_REPLY" ] || BOT_REPLY="(reply logged but content not captured)"
        pass "Bot sent reply after ${WAITED}s (confirmed in process log)"
        break
    fi

    # Secondary check: poll Discord REST API for a bot message after our message ID
    # Discord snowflake IDs are large integers — compare numerically with tonumber
    MESSAGES=$(curl -sf \
        "$DISCORD_API/channels/$CHANNEL_ID/messages?limit=10" \
        -H "Authorization: Bot $TOKEN" 2>/dev/null) || continue

    BOT_REPLY=$(echo "$MESSAGES" | jq -r --arg mid "$MESSAGE_ID" '
        .[] | select(
            (.author.bot == true) and
            ((.id | tonumber) > ($mid | tonumber))
        ) | .content' | head -1)

    if [ -n "$BOT_REPLY" ]; then
        pass "Bot replied after ${WAITED}s (confirmed via Discord API)"
        break
    fi
done

[ -n "$BOT_REPLY" ] || fail "Bot did not reply within ${TIMEOUT_REPLY}s"

# ── Step 4: Report ────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
pass "ALL TESTS PASSED"
echo ""
echo "  Bot reply: \"${BOT_REPLY:0:120}\""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
exit 0
