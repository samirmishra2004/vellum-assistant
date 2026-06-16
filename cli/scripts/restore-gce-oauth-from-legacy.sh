#!/usr/bin/env bash
# Copy OAuth apps/connections from legacy .vellum/data/db into workspace/data/db.
#
# After GCE migration the live assistant reads workspace/data/db/assistant.db,
# but pre-migration OAuth rows (e.g. GitHub) often remain only in
# .vellum/data/db/assistant.db. Idempotent — skips providers already present.
#
# Usage:
#   ./restore-gce-oauth-from-legacy.sh [assistant-id]
set -euo pipefail

export PATH="$HOME/.bun/bin:$HOME/.local/bin:/usr/sbin:/usr/bin:/bin:$PATH"

ASSISTANT_ID="${1:-}"
if [[ -z "$ASSISTANT_ID" ]]; then
  ASSISTANT_ID="$(ls "$HOME/.local/share/vellum/assistants" 2>/dev/null | head -1 || true)"
fi
if [[ -z "$ASSISTANT_ID" ]]; then
  echo "Error: no assistant directory found."
  exit 1
fi

INSTANCE_DIR="$HOME/.local/share/vellum/assistants/$ASSISTANT_ID"
LEGACY_DB="$INSTANCE_DIR/.vellum/data/db/assistant.db"
WORKSPACE_DB="$INSTANCE_DIR/.vellum/workspace/data/db/assistant.db"
LEGACY_META="$INSTANCE_DIR/.vellum/data/credentials/metadata.json"
WORKSPACE_META="$INSTANCE_DIR/.vellum/workspace/data/credentials/metadata.json"

if [[ ! -f "$LEGACY_DB" ]]; then
  echo "No legacy DB at $LEGACY_DB — skipping OAuth restore."
  exit 0
fi
if [[ ! -f "$WORKSPACE_DB" ]]; then
  echo "No workspace DB at $WORKSPACE_DB — skipping OAuth restore."
  exit 0
fi

bun -e "
import { Database } from 'bun:sqlite';

const legacyPath = process.argv[1];
const workspacePath = process.argv[2];
const legacy = new Database(legacyPath);
const workspace = new Database(workspacePath);

const apps = legacy.query('SELECT * FROM oauth_apps').all();
let appsInserted = 0;
for (const app of apps) {
  const existing = workspace
    .query('SELECT id FROM oauth_apps WHERE provider_key = ?')
    .get(app.provider_key);
  if (existing) continue;
  workspace
    .prepare(
      'INSERT INTO oauth_apps (id, provider_key, client_id, client_secret_credential_path, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)',
    )
    .run(
      app.id,
      app.provider_key,
      app.client_id,
      app.client_secret_credential_path,
      app.created_at,
      app.updated_at,
    );
  appsInserted++;
  console.log('Inserted oauth_app for provider:', app.provider_key);
}

const connections = legacy.query('SELECT * FROM oauth_connections').all();
let connsInserted = 0;
for (const conn of connections) {
  const existing = workspace
    .query('SELECT id FROM oauth_connections WHERE id = ?')
    .get(conn.id);
  if (existing) continue;
  const appPresent = workspace
    .query('SELECT id FROM oauth_apps WHERE id = ?')
    .get(conn.oauth_app_id);
  if (!appPresent) {
    console.warn('Skipping connection', conn.id, '— oauth_app', conn.oauth_app_id, 'missing');
    continue;
  }
  workspace
    .prepare(
      'INSERT INTO oauth_connections (id, oauth_app_id, provider_key, account_info, granted_scopes, expires_at, has_refresh_token, status, label, metadata, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    )
    .run(
      conn.id,
      conn.oauth_app_id,
      conn.provider_key,
      conn.account_info,
      conn.granted_scopes,
      conn.expires_at,
      conn.has_refresh_token,
      conn.status,
      conn.label,
      conn.metadata,
      conn.created_at,
      conn.updated_at,
    );
  connsInserted++;
  console.log('Inserted oauth_connection for provider:', conn.provider_key);
}

if (appsInserted === 0 && connsInserted === 0) {
  console.log('OAuth rows already present in workspace DB — nothing to merge.');
}
" "$LEGACY_DB" "$WORKSPACE_DB"

if [[ -f "$LEGACY_META" ]]; then
  mkdir -p "$(dirname "$WORKSPACE_META")"
  bun -e "
import fs from 'fs';

const legPath = process.argv[1];
const wsPath = process.argv[2];
const leg = JSON.parse(fs.readFileSync(legPath, 'utf8'));
const ws = fs.existsSync(wsPath) ? JSON.parse(fs.readFileSync(wsPath, 'utf8')) : {};
let merged = 0;
for (const [key, value] of Object.entries(leg)) {
  if (ws[key] !== undefined) continue;
  ws[key] = value;
  merged++;
}
if (merged > 0) {
  fs.writeFileSync(wsPath, JSON.stringify(ws, null, 2));
  console.log('Merged', merged, 'credential metadata keys from legacy into workspace.');
} else {
  console.log('No new credential metadata keys to merge.');
}
" "$LEGACY_META" "$WORKSPACE_META"
fi
