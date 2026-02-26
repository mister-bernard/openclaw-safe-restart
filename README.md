# OpenClaw Safe Restart with Auto-Rollback

A dead-simple safety net for OpenClaw gateway restarts. Never brick your agent again.

## The Problem

Your agent edits `openclaw.json`, restarts the gateway, and the new config is broken. Gateway won't start. Agent is now offline and can't fix itself. You SSH in at 2am.

## The Solution

A wrapper script that:

1. **Saves the currently-running config** as "last known good" (only if gateway is healthy)
2. **Validates the new config** (JSON syntax check before restart)
3. **Restarts the gateway**
4. **Health-checks** for up to 60 seconds
5. **Auto-rolls back** to last-known-good if the gateway doesn't come up
6. **Keeps timestamped backups** (last 10) for forensics

## Install

```bash
# Copy the script into your workspace
mkdir -p ~/.openclaw/workspace/scripts
curl -o ~/.openclaw/workspace/scripts/restart-gateway.sh \
  https://raw.githubusercontent.com/mr-bernard-1969/openclaw-safe-restart/main/restart-gateway.sh
chmod +x ~/.openclaw/workspace/scripts/restart-gateway.sh
```

## Usage

**Always restart via the script, never directly:**

```bash
# Instead of: openclaw gateway restart
bash scripts/restart-gateway.sh "added new telegram channel"
```

The context string gets logged so your agent (or you) can trace what change triggered a restart.

## How It Works

```
Gateway healthy? ──yes──► Save config as last-known-good
       │
       ▼
Validate new JSON ──invalid──► Restore last-good, warn
       │
       ▼ valid
Restart gateway
       │
       ▼
Health check (60s) ──healthy──► Save as new last-good ✅
       │
       ▼ timeout
Restore last-known-good
       │
       ▼
Restart again (30s) ──healthy──► Rollback complete ⚠️
       │
       ▼ timeout
CRITICAL — manual intervention needed ❌
```

## Agent Integration

Add this to your `AGENTS.md` or equivalent:

```markdown
## Gateway Restart Protocol
**NEVER run `openclaw gateway restart` directly.**
Always use: `bash scripts/restart-gateway.sh "reason for change"`
This backs up config, validates JSON, and auto-rolls back on failure.
```

## What Gets Backed Up

- `~/.openclaw/openclaw.json` (main config)
- `~/.openclaw/cron/jobs.json` (cron jobs)
- Timestamped copies in `~/.openclaw/config-backups/`
- Last 10 backups kept, older ones pruned automatically

## License

MIT
