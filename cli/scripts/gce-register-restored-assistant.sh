#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.bun/bin:/usr/sbin:/usr/bin:/bin:$PATH"
ASSISTANT_ID="${1:-vellum-just-bear-qqenbi}"
LOCKFILE="$HOME/.vellum.lock.json"
python3 - "$ASSISTANT_ID" "$LOCKFILE" <<'PY'
import json, sys
assistant_id = sys.argv[1]
path = sys.argv[2]
with open(path) as f:
    data = json.load(f)
wild = next(a for a in data["assistants"] if "resources" in a)
entry = json.loads(json.dumps(wild))
entry["assistantId"] = assistant_id
entry["resources"]["instanceDir"] = f"/home/{__import__('os').environ.get('USER','samir')}/.local/share/vellum/assistants/{assistant_id}"
data["assistants"] = [a for a in data["assistants"] if a.get("assistantId") != wild["assistantId"]]
data["assistants"].append(entry)
data["activeAssistant"] = assistant_id
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(f"Registered {assistant_id} in lockfile")
PY
for other in "$HOME/.local/share/vellum/assistants"/vellum-*; do
  base="$(basename "$other")"
  if [ "$base" != "$ASSISTANT_ID" ]; then
    vellum sleep "$base" 2>/dev/null || true
    rm -rf "$other"
  fi
done
vellum wake "$ASSISTANT_ID"
sleep 15
vellum ps
curl -s -m 15 http://127.0.0.1:7830/healthz || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "$SCRIPT_DIR/restore-gce-integrations.sh" ]]; then
  "$SCRIPT_DIR/restore-gce-integrations.sh" "$ASSISTANT_ID"
elif [[ -x "$HOME/restore-gce-integrations.sh" ]]; then
  "$HOME/restore-gce-integrations.sh" "$ASSISTANT_ID"
fi
