#!/usr/bin/env sh
set -eu

REPO="${CC_MANAGE_REPO:-ig-vikas/cc-manage}"
REF="${CC_MANAGE_REF:-main}"
INSTALL_DIR="${CC_MANAGE_HOME:-$HOME/.claude-profiles}"
ARCHIVE_URL="https://github.com/$REPO/archive/refs/heads/$REF.tar.gz"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-manage-install.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

add_path_marker() {
  shell_rc="$HOME/.profile"
  case "${SHELL:-}" in
    *zsh) shell_rc="$HOME/.zshrc" ;;
    *bash) shell_rc="$HOME/.bashrc" ;;
  esac

  marker="# cc-manage PATH"
  if [ ! -f "$shell_rc" ] || ! grep -Fq "$marker" "$shell_rc"; then
    {
      printf '\n%s\n' "$marker"
      printf 'export PATH="$HOME/.claude-profiles:$PATH"\n'
    } >> "$shell_rc"
    printf 'Added PATH entry to %s\n' "$shell_rc"
  fi
}

printf 'Downloading %s\n' "$ARCHIVE_URL"
curl -fsSL "$ARCHIVE_URL" -o "$TMP_DIR/source.tar.gz"
tar -xzf "$TMP_DIR/source.tar.gz" -C "$TMP_DIR"

SOURCE_DIR="$(find "$TMP_DIR" -mindepth 2 -maxdepth 2 -type d -path '*/src/cc-manage' | head -n 1)"
if [ -z "$SOURCE_DIR" ] || [ ! -d "$SOURCE_DIR" ]; then
  echo "Installer payload not found: src/cc-manage" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
cp -R "$SOURCE_DIR"/. "$INSTALL_DIR"/
mkdir -p "$INSTALL_DIR/profiles"
chmod +x "$INSTALL_DIR/cc" "$INSTALL_DIR/cc-switch" "$INSTALL_DIR/cc-status" "$INSTALL_DIR/cc-manage" "$INSTALL_DIR/claude" 2>/dev/null || true
add_path_marker

printf 'Installed cc-manage to %s\n' "$INSTALL_DIR"

if ! command -v pwsh >/dev/null 2>&1; then
  echo "Warning: pwsh was not found. Install PowerShell Core before using cc-manage on macOS/Linux." >&2
fi

if ! command -v node >/dev/null 2>&1; then
  echo "Warning: node was not found. Install Node.js before using proxy providers." >&2
fi

if ! command -v claude >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/claude" ]; then
  echo "Warning: Claude Code was not found. Install Claude Code before launching cc." >&2
fi

if command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -File "$INSTALL_DIR/cc-manage-entry.ps1" doctor || true
fi

cat <<'NEXT'

Next:
  cc-manage add
  cc-switch
  cc

Open a new terminal if the commands are not available in this shell yet.
NEXT
