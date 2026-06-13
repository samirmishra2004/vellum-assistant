#!/usr/bin/env bash
set -e
MARKER_BEGIN="# >>> vellum-assistant shell >>>"
MARKER_END="# <<< vellum-assistant shell <<<"
for f in "$HOME/.bashrc" "$HOME/.profile"; do
  [ -f "$f" ] || continue
  grep -v 'C:\\Users\\samir' "$f" | grep -v '\\C:' > "${f}.tmp" || true
  mv "${f}.tmp" "$f"
done
strip_block() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" '$0 == begin { skip=1; next } $0 == end { skip=0; next } !skip { print }' "$file" > "${file}.tmp"
  mv "${file}.tmp" "$file"
}
strip_block "$HOME/.bashrc"
strip_block "$HOME/.profile"
printf '\n%s\n' "$MARKER_BEGIN" >> "$HOME/.bashrc"
printf '%s\n' 'export BUN_INSTALL="$HOME/.bun"' >> "$HOME/.bashrc"
printf '%s\n' 'export PATH="$HOME/.local/bin:$BUN_INSTALL/bin:$PATH"' >> "$HOME/.bashrc"
printf '%s\n' 'export VELLUM_WORKSPACE_DIR="$HOME/.local/share/vellum/assistants/vellum-just-bear-qqenbi/.vellum/workspace"' >> "$HOME/.bashrc"
printf '%s\n' "$MARKER_END" >> "$HOME/.bashrc"
printf '\n%s\n' "$MARKER_BEGIN" >> "$HOME/.profile"
printf '%s\n' 'export BUN_INSTALL="$HOME/.bun"' >> "$HOME/.profile"
printf '%s\n' 'export PATH="$HOME/.local/bin:$BUN_INSTALL/bin:$PATH"' >> "$HOME/.profile"
printf '%s\n' 'export VELLUM_WORKSPACE_DIR="$HOME/.local/share/vellum/assistants/vellum-just-bear-qqenbi/.vellum/workspace"' >> "$HOME/.profile"
printf '%s\n' "$MARKER_END" >> "$HOME/.profile"
printf '%s\n' 'if [ -f "$HOME/.bashrc" ]; then' > "$HOME/.bash_profile"
printf '%s\n' '  . "$HOME/.bashrc"' >> "$HOME/.bash_profile"
printf '%s\n' 'fi' >> "$HOME/.bash_profile"
. "$HOME/.bashrc"
echo "vellum=$(command -v vellum)"
echo "assistant=$(command -v assistant)"
echo "VELLUM_WORKSPACE_DIR=$VELLUM_WORKSPACE_DIR"
