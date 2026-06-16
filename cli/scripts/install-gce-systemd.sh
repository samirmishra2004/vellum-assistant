#!/usr/bin/env bash
# Install vellum.service + vellum-integrations.service on a GCE VM.
#
# Usage (on the VM):
#   ./install-gce-systemd.sh [assistant-id]
#
# Requires sudo. Re-run after changing the active assistant id.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCKFILE="${HOME}/.vellum.lock.json"

resolve_assistant_id() {
  if [[ -n "${1:-}" ]]; then
    echo "$1"
    return
  fi
  if [[ ! -f "$LOCKFILE" ]]; then
    echo "Error: no assistant id argument and $LOCKFILE not found" >&2
    exit 1
  fi
  python3 - <<'PY'
import json, os
path = os.path.expanduser("~/.vellum.lock.json")
with open(path) as f:
    data = json.load(f)
aid = data.get("activeAssistant")
if not aid:
    aids = [a.get("assistantId") for a in data.get("assistants", []) if a.get("assistantId")]
    aid = aids[0] if aids else None
if not aid:
    raise SystemExit("Could not resolve assistant id from lockfile")
print(aid)
PY
}

ASSISTANT_ID="$(resolve_assistant_id "${1:-}")"
echo "Installing systemd units for assistant: $ASSISTANT_ID"

RESTORE_SCRIPT="${HOME}/restore-gce-integrations.sh"
for helper in restore-gce-integrations.sh restore-gce-oauth-from-legacy.sh restore-gce-guardian-telegram.sh; do
  dest="${HOME}/${helper}"
  if [[ ! -x "$dest" ]] && [[ -f "$SCRIPT_DIR/$helper" ]]; then
    cp "$SCRIPT_DIR/$helper" "$dest"
    chmod +x "$dest"
  fi
done
if [[ ! -x "$RESTORE_SCRIPT" ]]; then
  echo "Error: $RESTORE_SCRIPT is missing. Copy restore-gce-integrations.sh to \$HOME first." >&2
  exit 1
fi

render_unit() {
  local template="$1"
  local dest="$2"
  sed "s/@VELLUM_ASSISTANT_ID@/${ASSISTANT_ID}/g" "$template" | sudo tee "$dest" >/dev/null
}

render_unit "$SCRIPT_DIR/gce-vellum.service" /etc/systemd/system/vellum.service
render_unit "$SCRIPT_DIR/gce-vellum-integrations.service" /etc/systemd/system/vellum-integrations.service

sudo systemctl daemon-reload
sudo systemctl enable vellum.service vellum-integrations.service
echo "Enabled vellum.service and vellum-integrations.service"
echo ""
echo "Start or restart with:"
echo "  sudo systemctl restart vellum.service"
echo "  sudo systemctl restart vellum-integrations.service"
echo ""
echo "Status:"
echo "  sudo systemctl status vellum.service vellum-integrations.service"
