#!/usr/bin/env bash
# Safe gateway restart with config backup + auto-rollback
# Usage: bash scripts/restart-gateway.sh "reason for restart"
#
# Flow:
# 1. Save "last known good" config (the one currently running)
# 2. Validate the NEW config (the one on disk now)
# 3. Restart gateway
# 4. If it doesn't come up in 60s → restore last known good → restart again
# 5. If still broken → CRITICAL, manual intervention needed

set -euo pipefail

CONTEXT="${1:-no context provided}"
CONFIG="$HOME/.openclaw/openclaw.json"
CRON_JOBS="$HOME/.openclaw/cron/jobs.json"
BACKUP_DIR="$HOME/.openclaw/config-backups"
RESTART_CONTEXT="$HOME/.openclaw/workspace/memory/restart-context.json"
LAST_GOOD="$BACKUP_DIR/openclaw.json.last-good"
LAST_GOOD_CRON="$BACKUP_DIR/jobs.json.last-good"
MAX_BACKUPS=10
HEALTH_TIMEOUT=60

mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

echo "[restart] Context: $CONTEXT"
echo "[restart] Timestamp: $TIMESTAMP"

# --- Step 1: Save last known good (the currently running config) ---
# Only save as "last good" if the gateway is currently healthy
if curl -sf -o /dev/null http://127.0.0.1:18789/ 2>/dev/null; then
    echo "[restart] Gateway currently healthy — saving config as last-known-good"
    cp "$CONFIG" "$LAST_GOOD"
    [ -f "$CRON_JOBS" ] && cp "$CRON_JOBS" "$LAST_GOOD_CRON"
else
    echo "[restart] WARNING: Gateway not healthy before restart — skipping last-good save"
fi

# Also keep a timestamped backup for history
cp "$CONFIG" "$BACKUP_DIR/openclaw.json.$TIMESTAMP"
[ -f "$CRON_JOBS" ] && cp "$CRON_JOBS" "$BACKUP_DIR/jobs.json.$TIMESTAMP"
echo "[restart] Timestamped backup: $BACKUP_DIR/*.$TIMESTAMP"

# --- Step 2: Validate config JSON ---
echo "[restart] Validating config JSON..."
if ! python3 -c "import json; json.load(open('$CONFIG'))" 2>/dev/null; then
    echo "[restart] ERROR: Config is invalid JSON!"
    if [ -f "$LAST_GOOD" ]; then
        echo "[restart] Restoring last-known-good config..."
        cp "$LAST_GOOD" "$CONFIG"
        [ -f "$LAST_GOOD_CRON" ] && cp "$LAST_GOOD_CRON" "$CRON_JOBS"
        echo "[restart] Restored. Proceeding with restart using last-good config."
    else
        echo "[restart] FATAL: No last-known-good config exists. Aborting."
        exit 1
    fi
fi

# --- Step 3: Set restart context for session continuity ---
cat > "$RESTART_CONTEXT" << EOF
{
  "pending": true,
  "context": "$CONTEXT",
  "chat_id": "${TELEGRAM_CHAT_ID}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

# --- Step 4: Restart gateway ---
echo "[restart] Restarting gateway..."
systemctl --user restart openclaw-gateway

# --- Step 5: Wait for health check (up to 60s) ---
echo "[restart] Waiting for gateway (max ${HEALTH_TIMEOUT}s)..."
HEALTHY=false
for i in $(seq 1 $HEALTH_TIMEOUT); do
    sleep 1
    if curl -sf -o /dev/null http://127.0.0.1:18789/ 2>/dev/null; then
        HEALTHY=true
        echo "[restart] ✅ Gateway healthy after ${i}s"
        break
    fi
    # Print a dot every 10s so it doesn't look hung
    [ $((i % 10)) -eq 0 ] && echo "[restart] ...${i}s"
done

if [ "$HEALTHY" = true ]; then
    echo "[restart] Success. Saving current config as new last-known-good."
    cp "$CONFIG" "$LAST_GOOD"
    [ -f "$CRON_JOBS" ] && cp "$CRON_JOBS" "$LAST_GOOD_CRON"
else
    echo "[restart] ❌ Gateway failed to start within ${HEALTH_TIMEOUT}s!"
    
    STATUS=$(systemctl --user is-active openclaw-gateway 2>/dev/null || echo "unknown")
    LOGS=$(journalctl --user -u openclaw-gateway --since "-2min" --no-pager 2>&1 | tail -20)
    echo "[restart] Service status: $STATUS"
    echo "[restart] Recent logs:"
    echo "$LOGS"
    
    if [ -f "$LAST_GOOD" ]; then
        echo ""
        echo "[restart] === AUTO-ROLLBACK ==="
        echo "[restart] Restoring last-known-good config..."
        cp "$LAST_GOOD" "$CONFIG"
        [ -f "$LAST_GOOD_CRON" ] && cp "$LAST_GOOD_CRON" "$CRON_JOBS"
        
        echo "[restart] Restarting with last-good config..."
        systemctl --user restart openclaw-gateway
        
        # Wait again
        RECOVERED=false
        for i in $(seq 1 30); do
            sleep 1
            if curl -sf -o /dev/null http://127.0.0.1:18789/ 2>/dev/null; then
                RECOVERED=true
                echo "[restart] ✅ Gateway recovered with last-good config after ${i}s"
                break
            fi
        done
        
        if [ "$RECOVERED" = true ]; then
            cat > "$RESTART_CONTEXT" << ROLLEOF
{
  "pending": true,
  "context": "ROLLBACK: Restart for '$CONTEXT' failed. Auto-rolled back to last-known-good config. The change that broke it is in $BACKUP_DIR/openclaw.json.$TIMESTAMP — investigate.",
  "chat_id": "${TELEGRAM_CHAT_ID}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
ROLLEOF
            echo "[restart] Rollback complete. Broken config saved at: $BACKUP_DIR/openclaw.json.$TIMESTAMP"
        else
            echo "[restart] ❌ CRITICAL: Gateway still failing after rollback!"
            echo "[restart] Manual intervention required."
            echo "[restart] Broken config: $BACKUP_DIR/openclaw.json.$TIMESTAMP"
            echo "[restart] Last-good config: $LAST_GOOD"
            exit 2
        fi
    else
        echo "[restart] ❌ No last-known-good config to roll back to!"
        echo "[restart] Manual intervention required."
        exit 2
    fi
fi

# --- Step 6: Prune old timestamped backups ---
cd "$BACKUP_DIR"
ls -t openclaw.json.2* 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm --
ls -t jobs.json.2* 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm --
echo "[restart] Backup pruning done (keeping last $MAX_BACKUPS + last-good)"

echo "[restart] Done."
