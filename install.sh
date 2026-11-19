#!/usr/bin/env sh
# Install the KOReader AI Reading customizations into a mounted Kindle.
# Usage: ./install.sh /Volumes/Kindle/koreader
set -eu

KOREADER="${1:-}"
if [ -z "$KOREADER" ] || [ ! -d "$KOREADER/plugins" ]; then
    echo "Usage: $0 /path/to/koreader" >&2
    echo "Example: $0 /Volumes/Kindle/koreader" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$(dirname "$KOREADER")/koreader-ai-reading-backup-$STAMP"
mkdir -p "$BACKUP/plugins"
echo "Backup: $BACKUP"

# Back up the files we may modify.
[ -d "$KOREADER/plugins/weread.koplugin" ] && cp -R "$KOREADER/plugins/weread.koplugin" "$BACKUP/plugins/"
[ -f "$KOREADER/frontend/ui/data/creoptions.lua" ] && mkdir -p "$BACKUP/frontend/ui/data" && cp "$KOREADER/frontend/ui/data/creoptions.lua" "$BACKUP/frontend/ui/data/"

# Install our plugins.
for plugin in ai_bridge.koplugin weread_home.koplugin top_status.koplugin; do
    target="$KOREADER/plugins/$plugin"
    if [ "$plugin" = "ai_bridge.koplugin" ] && [ -f "$target/config.lua" ]; then
        cp "$target/config.lua" "$BACKUP/ai_bridge.config.lua"
    fi
    if [ -e "$target" ]; then
        old="$BACKUP/plugins/$plugin.old"
        [ -e "$old" ] && old="$old-$(date +%s)"
        mv "$target" "$old"
    fi
    cp -R "$ROOT/plugins/$plugin" "$target"
done

# Keep the user's bridge config; otherwise start from the example.
if [ -f "$BACKUP/ai_bridge.config.lua" ]; then
    cp "$BACKUP/ai_bridge.config.lua" "$KOREADER/plugins/ai_bridge.koplugin/config.lua"
elif [ ! -f "$KOREADER/plugins/ai_bridge.koplugin/config.lua" ]; then
    cp "$ROOT/plugins/ai_bridge.koplugin/config.example.lua" \
       "$KOREADER/plugins/ai_bridge.koplugin/config.lua"
fi

# Patch weread.koplugin 1.7.0 (Settings/Exit menu + direct open of cached books).
if [ -d "$KOREADER/plugins/weread.koplugin" ]; then
    if grep -q 'version = "1.7.0"' "$KOREADER/plugins/weread.koplugin/main.lua" 2>/dev/null; then
        if patch --batch --forward -p1 -d "$KOREADER/plugins/weread.koplugin" --dry-run \
            < "$ROOT/patches/weread-1.7.0.patch" >/dev/null 2>&1; then
            patch --batch --forward -p1 -d "$KOREADER/plugins/weread.koplugin" \
                < "$ROOT/patches/weread-1.7.0.patch"
            echo "Patched weread.koplugin 1.7.0"
        else
            echo "WARN: weread.koplugin patch did not apply. Is it exactly 1.7.0?" >&2
        fi
    else
        echo "WARN: weread.koplugin is not 1.7.0; skipped patch." >&2
    fi
else
    echo "WARN: weread.koplugin not found; install it first if you want WeRead integration." >&2
fi

# Release stale WeRead standby guards so Kindle can auto suspend again.
GUARD_FILE="$KOREADER/plugins/weread.koplugin/weread/lib/standby_guard.lua"
GUARD_PATCH="$ROOT/patches/weread-1.7.0-standby-guard.patch"
if [ -f "$GUARD_FILE" ] && [ -f "$GUARD_PATCH" ]; then
    if grep -q 'GUARD_TIMEOUT_SECONDS' "$GUARD_FILE"; then
        echo "WeRead standby guard already patched"
    elif patch --batch --forward -p1 -d "$KOREADER/plugins/weread.koplugin" --dry-run \
        < "$GUARD_PATCH" >/dev/null 2>&1; then
        patch --batch --forward -p1 -d "$KOREADER/plugins/weread.koplugin" \
            < "$GUARD_PATCH"
        echo "Patched WeRead standby guard"
    else
        echo "WARN: standby guard patch did not apply." >&2
    fi
fi

# Enable the native top status bar by default for new books.
if [ -f "$KOREADER/frontend/ui/data/creoptions.lua" ]; then
    if patch --batch --forward -p1 -d "$KOREADER" --dry-run \
        < "$ROOT/patches/koreader-creoptions-status-line.patch" >/dev/null 2>&1; then
        patch --batch --forward -p1 -d "$KOREADER" < "$ROOT/patches/koreader-creoptions-status-line.patch"
        echo "Patched KOReader alt status bar default"
    else
        echo "WARN: creoptions patch already applied or version mismatch." >&2
    fi
fi

echo
echo "Done. Next:"
echo "1. Edit $KOREADER/plugins/ai_bridge.koplugin/config.lua"
echo "   Set url to your iPhone bridge and the same token as the app."
echo "2. Restart KOReader."
echo "3. Open a book and turn a page."
