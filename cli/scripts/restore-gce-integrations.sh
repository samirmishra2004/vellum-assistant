#!/usr/bin/env bash
# Repair post-migration GCE integrations: credential metadata path, OAuth rows
# from legacy DB, HTTPS ingress (cloudflared quick tunnel), and Telegram webhook.
#
# Run on the GCE VM after restore, reboot, or when Telegram stops receiving
# messages. Idempotent — safe to re-run.
#
# Usage:
#   ./restore-gce-integrations.sh [assistant-id]
#
# Optional cron (survives reboot; URL changes each tunnel start):
#   @reboot sleep 120 && $HOME/restore-gce-integrations.sh >>$HOME/.vellum-restore.log 2>&1
set -euo pipefail

export PATH="$HOME/.bun/bin:$HOME/.local/bin:/usr/sbin:/usr/bin:/bin:$PATH"

ASSISTANT_ID="${1:-}"
if [[ -z "$ASSISTANT_ID" ]]; then
  ASSISTANT_ID="$(ls "$HOME/.local/share/vellum/assistants" 2>/dev/null | head -1 || true)"
fi
if [[ -z "$ASSISTANT_ID" ]]; then
  echo "Error: no assistant directory found under ~/.local/share/vellum/assistants"
  exit 1
fi

INSTANCE_DIR="$HOME/.local/share/vellum/assistants/$ASSISTANT_ID"
WORKSPACE="$INSTANCE_DIR/.vellum/workspace"
export VELLUM_WORKSPACE_DIR="$WORKSPACE"
GATEWAY_PORT=7830
RUNTIME_PORT=7821
CLOUDFLARED="$WORKSPACE/bin/cloudflared"
TUNNEL_LOG="$WORKSPACE/data/logs/cloudflared.log"
TUNNEL_URL_RE='https://[a-z0-9-]+\.trycloudflare\.com'

echo "Assistant: $ASSISTANT_ID"
echo "Workspace: $WORKSPACE"

# ── 1. Credential metadata (legacy .vellum/data → workspace/data) ───────────
LEGACY_META="$INSTANCE_DIR/.vellum/data/credentials/metadata.json"
WORKSPACE_META="$WORKSPACE/data/credentials/metadata.json"
if [[ -f "$LEGACY_META" ]]; then
  mkdir -p "$(dirname "$WORKSPACE_META")"
  if [[ ! -f "$WORKSPACE_META" ]] || [[ ! -s "$WORKSPACE_META" ]]; then
    cp "$LEGACY_META" "$WORKSPACE_META"
    echo "Restored credential metadata.json into workspace."
  fi
fi

# ── 1b. OAuth apps/connections (legacy data/db → workspace/data/db) ─────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
if [[ -x "${SCRIPT_DIR}/restore-gce-oauth-from-legacy.sh" ]]; then
  "${SCRIPT_DIR}/restore-gce-oauth-from-legacy.sh" "$ASSISTANT_ID" || true
elif [[ -x "$HOME/restore-gce-oauth-from-legacy.sh" ]]; then
  "$HOME/restore-gce-oauth-from-legacy.sh" "$ASSISTANT_ID" || true
fi

wait_http_health() {
  local port="$1"
  local label="$2"
  for _ in $(seq 1 72); do
    if curl -sf -m 5 "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1; then
      echo "${label} is healthy on port ${port}."
      return 0
    fi
    sleep 5
  done
  echo "Error: ${label} not healthy on port ${port} after 6 minutes."
  return 1
}

# ── 2. Ensure assistant + gateway are running ────────────────────────────────
# On small GCE VMs the daemon can take several minutes (embedding worker, Qdrant).
# The gateway blocks HTTP until runtime IPC is ready, so wake often returns before :7830 listens.
runtime_ok=false
gateway_ok=false
curl -sf -m 5 "http://127.0.0.1:${RUNTIME_PORT}/healthz" >/dev/null 2>&1 && runtime_ok=true
curl -sf -m 5 "http://127.0.0.1:${GATEWAY_PORT}/healthz" >/dev/null 2>&1 && gateway_ok=true

if [[ "$runtime_ok" != true || "$gateway_ok" != true ]]; then
  echo "Waking assistant $ASSISTANT_ID..."
  vellum wake "$ASSISTANT_ID" || true
fi

wait_http_health "$RUNTIME_PORT" "Runtime" || exit 1

if ! wait_http_health "$GATEWAY_PORT" "Gateway"; then
  echo "Gateway still down after runtime is ready — retrying wake once..."
  vellum wake "$ASSISTANT_ID" || true
  wait_http_health "$GATEWAY_PORT" "Gateway" || exit 1
fi

# ── 3. cloudflared quick tunnel (Telegram webhooks need HTTPS) ──────────────
mkdir -p "$(dirname "$TUNNEL_LOG")" "$WORKSPACE/bin"

if [[ ! -x "$CLOUDFLARED" ]]; then
  echo "Installing cloudflared to $CLOUDFLARED..."
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64) CF_ARCH="amd64" ;;
    aarch64|arm64) CF_ARCH="arm64" ;;
    *)
      echo "Error: unsupported architecture for cloudflared: $ARCH"
      exit 1
      ;;
  esac
  TMP="$(mktemp)"
  curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" -o "$TMP"
  chmod +x "$TMP"
  mv "$TMP" "$CLOUDFLARED"
fi

tunnel_running() {
  pgrep -f "cloudflared tunnel --url http://127.0.0.1:${GATEWAY_PORT}" >/dev/null 2>&1
}

extract_tunnel_url() {
  if [[ -f "$TUNNEL_LOG" ]]; then
    grep -Eo "$TUNNEL_URL_RE" "$TUNNEL_LOG" 2>/dev/null | tail -1 || true
  fi
}

PUBLIC_URL=""
if tunnel_running; then
  PUBLIC_URL="$(extract_tunnel_url)"
  if [[ -z "$PUBLIC_URL" ]]; then
    PUBLIC_URL="$(assistant config get ingress.publicBaseUrl 2>/dev/null || true)"
    PUBLIC_URL="${PUBLIC_URL//\"/}"
  fi
  echo "cloudflared already running."
else
  echo "Starting cloudflared quick tunnel..."
  : >"$TUNNEL_LOG"
  nohup "$CLOUDFLARED" tunnel --url "http://127.0.0.1:${GATEWAY_PORT}" --no-autoupdate \
    >>"$TUNNEL_LOG" 2>&1 &
  for _ in $(seq 1 45); do
    PUBLIC_URL="$(extract_tunnel_url)"
    if [[ -n "$PUBLIC_URL" ]]; then
      break
    fi
    sleep 1
  done
fi

if [[ -z "$PUBLIC_URL" ]]; then
  echo "Error: could not obtain Cloudflare quick-tunnel URL (see $TUNNEL_LOG)"
  exit 1
fi

echo "Public ingress: $PUBLIC_URL"
CURRENT_INGRESS="$(assistant config get ingress.publicBaseUrl 2>/dev/null || true)"
if [[ "$CURRENT_INGRESS" != "$PUBLIC_URL" ]]; then
  assistant config set "ingress.publicBaseUrl" "$PUBLIC_URL"
  echo "Updated ingress.publicBaseUrl."
fi

# ── 4. Telegram webhook (if bot is configured) ────────────────────────────────
BOT_USERNAME="$(assistant config get telegram.botUsername 2>/dev/null || true)"
BOT_USERNAME="${BOT_USERNAME//\"/}"
BOT_USERNAME="${BOT_USERNAME//@/}"

if [[ -n "$BOT_USERNAME" ]]; then
  SOURCE="@${BOT_USERNAME}"
  echo "Registering Telegram webhook for $SOURCE..."
  assistant webhooks register telegram --source "$SOURCE"
  echo "Telegram webhook registered."
else
  echo "telegram.botUsername not set — skipping webhook registration."
  echo "Set it with: assistant config set telegram.botUsername <bot_handle>"
fi

echo "Done."

if [[ -z "${SCRIPT_DIR:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
fi
if [[ -x "${SCRIPT_DIR}/restore-gce-guardian-telegram.sh" ]]; then
  "${SCRIPT_DIR}/restore-gce-guardian-telegram.sh" || true
elif [[ -x "$HOME/restore-gce-guardian-telegram.sh" ]]; then
  "$HOME/restore-gce-guardian-telegram.sh" || true
fi
