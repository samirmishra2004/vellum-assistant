#!/usr/bin/env bash
# Restore guardian Telegram binding after GCE migration (lost contact_channels row).
#
# Usage:
#   ./restore-gce-guardian-telegram.sh [telegram-user-id] [telegram-chat-id]
#
# Defaults telegram user/chat id to 1857991362 when omitted.
set -euo pipefail

export PATH="$HOME/.bun/bin:$HOME/.local/bin:/usr/sbin:/usr/bin:/bin:$PATH"

ASSISTANT_ID="${VELLUM_ASSISTANT_ID:-$(ls "$HOME/.local/share/vellum/assistants" 2>/dev/null | head -1)}"
WORKSPACE="$HOME/.local/share/vellum/assistants/${ASSISTANT_ID}/.vellum/workspace"
export VELLUM_WORKSPACE_DIR="$WORKSPACE"

if [[ -f "$WORKSPACE/data/db/assistant.db" ]]; then
  DB="$WORKSPACE/data/db/assistant.db"
elif [[ -f "$WORKSPACE/db/memory.db" ]]; then
  DB="$WORKSPACE/db/memory.db"
else
  echo "Error: could not find assistant database under $WORKSPACE"
  exit 1
fi

TG_USER="${1:-1857991362}"
TG_CHAT="${2:-$TG_USER}"

GUARDIAN_JSON="$(assistant contacts list --role guardian --json)"
GUARDIAN_ID="$(python3 -c "import json,sys; d=json.load(sys.stdin); cs=d.get('contacts') or []; print(cs[0]['id'] if cs else '')" <<<"$GUARDIAN_JSON")"

if [[ -z "$GUARDIAN_ID" ]]; then
  echo "Error: no guardian contact found. Complete guardian bootstrap first."
  exit 1
fi

python3 - "$DB" "$GUARDIAN_ID" "$TG_USER" "$TG_CHAT" <<'PY'
import sqlite3
import sys
import time
import uuid

db_path, guardian_id, tg_user, tg_chat = sys.argv[1:5]
now = int(time.time() * 1000)

conn = sqlite3.connect(db_path)
try:
    row = conn.execute(
        "SELECT id FROM contact_channels WHERE type = ? AND external_user_id = ? LIMIT 1",
        ("telegram", tg_user),
    ).fetchone()
    if row:
        channel_id = row[0]
        conn.execute(
            """
            UPDATE contact_channels
            SET contact_id = ?, external_chat_id = ?, status = 'active', policy = 'allow',
                verified_at = ?, verified_via = 'migration_restore', updated_at = ?
            WHERE id = ?
            """,
            (guardian_id, tg_chat, now, now, channel_id),
        )
        print(f"Updated existing Telegram channel {channel_id} for guardian.")
    else:
        channel_id = str(uuid.uuid4())
        conn.execute(
            """
            INSERT INTO contact_channels (
              id, contact_id, type, address, is_primary, external_user_id, external_chat_id,
              status, policy, verified_at, verified_via, interaction_count, created_at, updated_at
            ) VALUES (?, ?, 'telegram', ?, 0, ?, ?, 'active', 'allow', ?, 'migration_restore', 0, ?, ?)
            """,
            (channel_id, guardian_id, tg_user, tg_user, tg_chat, now, now, now),
        )
        print(f"Inserted Telegram guardian channel {channel_id}.")

    conn.execute(
        "UPDATE contacts SET display_name = ?, updated_at = ? WHERE id = ?",
        ("Samir", now, guardian_id),
    )
    conn.commit()
finally:
    conn.close()
PY

echo "Verifying binding..."
assistant channel-verification-sessions status --channel telegram --json || true
echo ""
echo "Done. Send a test message to @samirpa_2026_bot on Telegram."
