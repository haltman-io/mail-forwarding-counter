# Mail Counter Installation Guide

Mail Counter is a resilient Postfix delivery monitor for Linux systems that use `systemd` and `journald`. It watches Postfix journal entries for `status=sent`, triggers a webhook, optionally sends Telegram and SMTP notifications, persists its journal cursor, and retries failed notifications from a disk-backed queue.

This guide covers installation, configuration, verification, operations, and troubleshooting for production deployments.

## Contents

- [Overview](#overview)
- [Supported Environment](#supported-environment)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Configuration](#configuration)
- [Start and Verify](#start-and-verify)
- [How It Works in Production](#how-it-works-in-production)
- [Operations Reference](#operations-reference)
- [Uninstallation](#uninstallation)
- [Troubleshooting](#troubleshooting)

## Overview

Mail Counter is designed for operators who need a simple, durable way to react to successful Postfix deliveries.

Core behavior:

- Watches Postfix logs from `journald`
- Detects messages containing `status=sent`
- Performs an HTTP request to a configured webhook URL
- Optionally sends Telegram notifications
- Optionally sends email notifications through `swaks`
- Stores the last processed journal cursor to survive restarts
- Queues failed notifications on disk for later retry
- Runs under `systemd` with automatic restart enabled

## Supported Environment

Validated target environment:

- Debian 13 (Trixie) or a compatible `systemd`-based Linux distribution
- Postfix logging to `journald`
- Bash 4.0 or newer
- Root access for installation and service management

Important limitation:

- If Postfix logs only to files such as `/var/log/mail.log` and not to `journald`, Mail Counter will not see events until Postfix or the host logging pipeline is reconfigured.

## Prerequisites

Install required packages:

```bash
apt update
apt install -y bash curl jq
```

Install `swaks` only if you plan to enable SMTP notifications:

```bash
apt install -y swaks
```

Verify the runtime dependencies:

```bash
bash --version
curl --version
jq --version
journalctl --version
swaks --version  # optional
```

## Installation

### 1. Copy the repository to the target host

Example using `scp`:

```bash
scp -r mail-forwarding-counter/ root@your-server:/tmp/mail-forwarding-counter/
```

### 2. Run the installer as root

```bash
cd /tmp/mail-forwarding-counter
chmod +x install.sh
./install.sh
```

The installer performs the following actions:

- Verifies required dependencies
- Warns if `swaks` is missing
- Copies runtime files into `/opt/mail-counter/`
- Installs `/etc/mail-counter.conf` with mode `600` if it does not already exist
- Creates `/var/lib/mail-counter/` and `/var/lib/mail-counter/queue/`
- Installs and enables `mail-counter.service`
- Validates shell syntax and the `systemd` unit file

Re-running the installer is safe for existing configuration:

- `/etc/mail-counter.conf` is preserved if it already exists
- The installer prints a warning instead of overwriting your active configuration

### 3. Review the installed layout

After installation, the main paths are:

| Path | Purpose |
|------|---------|
| `/opt/mail-counter/mail-counter.sh` | Main service script |
| `/opt/mail-counter/lib/` | Notification and queue libraries |
| `/opt/mail-counter/INSTALL.md` | Installed copy of this guide |
| `/etc/mail-counter.conf` | Runtime configuration |
| `/var/lib/mail-counter/` | Persistent state directory |
| `/var/lib/mail-counter/cursor` | Last processed journal cursor |
| `/var/lib/mail-counter/first-run-done` | First-run marker |
| `/var/lib/mail-counter/queue/` | Failed notification retry queue |
| `/etc/systemd/system/mail-counter.service` | Service unit |

## Configuration

Edit the runtime configuration:

```bash
nano /etc/mail-counter.conf
```

### Required: webhook

`WEBHOOK_URL` is mandatory.

```bash
WEBHOOK_URL="https://example.com/mail-counter"
```

Behavior to understand before deploying:

- The current implementation performs an HTTP `GET` to `WEBHOOK_URL`
- A delivery is treated as successful only when the endpoint returns HTTP `200`
- No request body or structured payload is sent

If your downstream integration expects `POST`, authentication headers, or a JSON payload, adapt the script before using it in production.

### Optional: Telegram

1. Create a bot with [@BotFather](https://t.me/BotFather)
2. Send at least one message to the bot or add it to the target group/channel
3. Retrieve the chat ID:

```bash
curl -s "https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates" | jq '.result[0].message.chat.id'
```

4. Set the Telegram options:

```bash
TELEGRAM_ENABLED="true"
TELEGRAM_BOT_TOKEN="123456789:ABCdefGHIjklMNOpqrsTUVwxyz"
TELEGRAM_CHAT_ID="-1001234567890"
```

Notes:

- Telegram messages are sent with `parse_mode=HTML`
- When Telegram is enabled, empty bot token or chat ID will cause service startup validation to fail

### Optional: SMTP email through `swaks`

```bash
SMTP_ENABLED="true"
SMTP_TO="admin@example.com"
SMTP_FROM="alerts@example.com"
SMTP_SERVER="smtp.example.com"
SMTP_PORT="587"
SMTP_USER="smtp-user"
SMTP_PASSWORD="smtp-password"
SMTP_TLS="true"
```

Notes:

- `swaks` must be installed if `SMTP_ENABLED="true"`
- SMTP authentication is used only when both `SMTP_USER` and `SMTP_PASSWORD` are set
- TLS is enabled when `SMTP_TLS="true"`

### Runtime and retry tuning

The following settings control retry behavior and runtime paths:

| Variable | Default | Description |
|----------|---------|-------------|
| `CURL_MAX_RETRIES` | `5` | Immediate webhook retry attempts before queueing |
| `CURL_INITIAL_BACKOFF` | `2` | Initial webhook retry delay in seconds |
| `CURL_MAX_BACKOFF` | `60` | Maximum webhook backoff in seconds |
| `QUEUE_RETRY_INTERVAL` | `300` | Seconds between queue processing cycles |
| `QUEUE_RETRY_DELAY` | `5` | Delay between successful queue item replays |
| `QUEUE_MAX_RETRIES` | `48` | Maximum retries for a queued item before discard |
| `STATE_DIR` | `/var/lib/mail-counter` | Root persistent state directory |
| `CURSOR_FILE` | `${STATE_DIR}/cursor` | Saved `journalctl` cursor |
| `FIRST_RUN_FILE` | `${STATE_DIR}/first-run-done` | Marker for first start |
| `QUEUE_DIR` | `${STATE_DIR}/queue` | Queue directory for failed notifications |
| `LOG_TAG` | `mail-counter` | Syslog/journal tag used by internal logging |
| `POSTFIX_UNIT` | `postfix*` | `journalctl -u` filter used to read Postfix logs |

Operational guidance:

- Keep `POSTFIX_UNIT` aligned with the actual unit names that emit Postfix logs on your host
- Increase `QUEUE_MAX_RETRIES` if downstream integrations may be unavailable for extended periods
- Reduce retry intervals only if you are certain your webhook or notification backends can tolerate more aggressive replay
- Leave `STATE_DIR` and related path settings at their defaults unless you also update `ReadWritePaths` in `mail-counter.service`

## Start and Verify

### 1. Start the service

```bash
systemctl start mail-counter
```

### 2. Confirm the service is healthy

```bash
systemctl status mail-counter
```

Expected state:

```text
Loaded: loaded (/etc/systemd/system/mail-counter.service; enabled)
Active: active (running)
```

### 3. Watch logs during initial startup

```bash
journalctl -u mail-counter -f
```

On first startup, you should see messages indicating:

- Mail Counter startup
- First run detected
- Queue processor started
- Journal tail started

### 4. Generate a verification event

The most reliable validation method is to send a real message through the local Postfix instance and confirm that it produces a `status=sent` journal entry.

If you need a controlled journal-only test, you can emit a synthetic event from a transient unit whose name matches the default `POSTFIX_UNIT` pattern:

```bash
systemd-run --unit=postfix-test --wait --collect \
  /usr/bin/bash -lc 'echo "to=<test@example.com>, relay=mail.example.com[1.2.3.4]:25, dsn=2.0.0, status=sent (250 OK)"'
```

Then inspect recent Mail Counter logs:

```bash
journalctl -u mail-counter --since "5 minutes ago" --no-pager
```

You should see lines similar to:

```text
[INFO] Detected: Mail forwarded via mail.protonmail.ch[185.70.42.128]:25 (dsn=2.0.0)
[INFO] Webhook OK (HTTP 200) -> https://mail.thc.org/api/counter/increment?key={SECRET}
```

If Telegram or SMTP are enabled, corresponding success messages should also appear.

### 5. Validate persisted state

Check the saved journal cursor:

```bash
cat /var/lib/mail-counter/cursor
```

Check the first-run marker:

```bash
ls -l /var/lib/mail-counter/first-run-done
```

## How It Works in Production

Understanding the runtime model helps avoid false assumptions during operations.

### Journal consumption model

- If a saved cursor exists, Mail Counter resumes after that cursor
- If no cursor exists, it starts with `--since=now`
- This means historical Postfix entries are not replayed on first install

### Notification order

For each detected `status=sent` event, Mail Counter:

1. Tries the webhook
2. Tries Telegram if enabled
3. Tries SMTP email if enabled

### Queue behavior

When a notification delivery fails:

- The failed notification is written to a file in `/var/lib/mail-counter/queue/`
- Queue items are retried oldest-first
- Queue processing stops on the first failed replay attempt
- Items are discarded permanently after `QUEUE_MAX_RETRIES`

This design prevents uncontrolled retry floods and preserves retry order.

### First-run behavior

On the first successful service start, Mail Counter creates `first-run-done` and sends:

- A Telegram startup message if Telegram is enabled
- An SMTP startup message if SMTP is enabled

No first-run webhook call is sent.

## Operations Reference

### Common service commands

| Action | Command |
|--------|---------|
| Start | `systemctl start mail-counter` |
| Stop | `systemctl stop mail-counter` |
| Restart | `systemctl restart mail-counter` |
| Enable at boot | `systemctl enable mail-counter` |
| Disable at boot | `systemctl disable mail-counter` |
| Status | `systemctl status mail-counter` |
| Live logs | `journalctl -u mail-counter -f` |
| Recent logs | `journalctl -u mail-counter --since "10 minutes ago"` |

### Queue inspection

List queued notifications:

```bash
ls -la /var/lib/mail-counter/queue/
```

Inspect queued item contents:

```bash
sed -n '1,120p' /var/lib/mail-counter/queue/*.queue
```

### Failure-recovery tests

Crash recovery:

```bash
kill -9 "$(systemctl show -p MainPID --value mail-counter)"
sleep 6
systemctl status mail-counter
```

The service should be running again because the unit uses `Restart=always` and `RestartSec=5`.

Boot persistence:

```bash
systemctl is-enabled mail-counter
```

Expected result:

```text
enabled
```

Queue replay test:

1. Point `WEBHOOK_URL` to a temporary endpoint that does not return HTTP `200`
2. Restart the service
3. Generate a test event
4. Confirm a queue file appears in `/var/lib/mail-counter/queue/`
5. Restore the correct webhook URL
6. Restart the service or wait for the next queue cycle
7. Confirm the queue directory is empty again

### Integration smoke tests

Webhook:

```bash
source /etc/mail-counter.conf
curl -s -o /dev/null -w '%{http_code}\n' "$WEBHOOK_URL"
```

Telegram:

```bash
source /etc/mail-counter.conf
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"Manual Mail Counter test\"}" | jq .ok
```

SMTP:

```bash
source /etc/mail-counter.conf
swaks --to "$SMTP_TO" \
      --from "$SMTP_FROM" \
      --server "${SMTP_SERVER}:${SMTP_PORT}" \
      --auth --auth-user "$SMTP_USER" --auth-password "$SMTP_PASSWORD" \
      --tls \
      --header "Subject: Mail Counter test" \
      --body "Manual Mail Counter test"
```

## Uninstallation

Run the uninstaller as root:

```bash
cd /tmp/mail-forwarding-counter
chmod +x uninstall.sh
./uninstall.sh
```

The uninstaller:

- Stops the service if it is running
- Disables the service if it is enabled
- Removes the installed `systemd` unit
- Removes `/opt/mail-counter/`
- Prompts before removing `/var/lib/mail-counter/`
- Prompts before removing `/etc/mail-counter.conf`

## Troubleshooting

### Service fails to start

Inspect recent service logs:

```bash
journalctl -u mail-counter --since "10 minutes ago" --no-pager
```

Common causes:

- `WEBHOOK_URL` is empty
- Telegram is enabled but `TELEGRAM_BOT_TOKEN` or `TELEGRAM_CHAT_ID` is empty
- SMTP is enabled but `swaks` is not installed
- SMTP is enabled but `SMTP_TO`, `SMTP_FROM`, or `SMTP_SERVER` is empty
- `STATE_DIR` permissions prevent writes

### No events are detected

Confirm that Postfix logs are visible in `journald` under the configured unit filter:

```bash
source /etc/mail-counter.conf
journalctl -u "${POSTFIX_UNIT}" --since "1 hour ago" --no-pager | head -50
```

If this command returns nothing:

- Postfix may be logging to files instead of `journald`
- The `POSTFIX_UNIT` pattern may not match your actual unit names
- Postfix may not have processed any matching deliveries during the time window

### Webhook notifications fail

Validate the target endpoint directly:

```bash
source /etc/mail-counter.conf
curl -v "$WEBHOOK_URL"
```

Remember:

- Only HTTP `200` is treated as success
- Redirects, `204`, and other non-`200` responses are treated as failures

### Telegram notifications fail

Check the bot credentials:

```bash
source /etc/mail-counter.conf
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" | jq .
```

If the bot is valid but sending still fails, verify that:

- The bot can reach the target chat
- The bot has been added to the group or channel if required
- The `TELEGRAM_CHAT_ID` is correct for the destination

### SMTP notifications fail

Run a direct `swaks` test with the configured settings:

```bash
source /etc/mail-counter.conf
swaks --to "$SMTP_TO" \
      --from "$SMTP_FROM" \
      --server "${SMTP_SERVER}:${SMTP_PORT}" \
      --auth --auth-user "$SMTP_USER" --auth-password "$SMTP_PASSWORD" \
      --tls \
      --header "Subject: Mail Counter SMTP test" \
      --body "SMTP validation"
```

Typical `swaks` exit codes:

- `0`: success
- `2`: connection failure
- `23`: `MAIL FROM` failure
- `24`: no recipient accepted
- `28`: authentication failure
- `29`: TLS failure

## Production Readiness Checklist

Before relying on Mail Counter in production, confirm the following:

- `WEBHOOK_URL` returns HTTP `200`
- Postfix logs are visible through `journalctl -u "${POSTFIX_UNIT}"`
- `mail-counter.service` is enabled and running
- Queue files can be created under `/var/lib/mail-counter/queue/`
- Telegram delivery has been validated if enabled
- SMTP delivery has been validated if enabled
- Restart and reboot behavior has been tested on the target host
