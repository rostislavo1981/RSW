#!/usr/bin/env bash
# uninstall.sh — удаляет RSW: .app-бандл, login item, локальные данные.
#
# По умолчанию НЕ удаляет пользовательский словарь (~/Library/Application
# Support/RSwitcher/words.json) и логи. Используйте --purge, чтобы
# удалить всё.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="RSW"
BUNDLE_ID="com.rostislavo.RSW"
PURGE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge)  PURGE=1; shift ;;
        -h|--help)
            sed -n '2,9p' "$0"
            exit 0
            ;;
        *)
            echo "Неизвестный аргумент: $1" >&2
            exit 2
            ;;
    esac
done

# ── Удаление .app-бандла ───────────────────────────────────
TARGETS=(
    "/Applications/${APP_NAME}.app"
    "$HOME/Applications/${APP_NAME}.app"
    "$SCRIPT_DIR/build/${APP_NAME}.app"
)
REMOVED=0
for t in "${TARGETS[@]}"; do
    if [[ -d "$t" ]]; then
        echo "→ Удаляю $t"
        if ! rm -rf "$t" 2>/dev/null; then
            echo "  нужен sudo…"
            sudo rm -rf "$t"
        fi
        REMOVED=1
    fi
done

# ── Снятие login item ──────────────────────────────────────
if [[ -d "$HOME/Library/Application Support/com.apple.backgroundtaskmanagementagent" ]]; then
    :
fi
osascript <<'EOF' 2>/dev/null && echo "✓ Login item снят" || echo "  (login item не зарегистрирован)"
tell application "System Events"
    try
        delete login item "RSW"
    end try
end tell
EOF

# ── Остановка, если запущен ────────────────────────────────
if pgrep -f "Applications/RSW.app/Contents/MacOS/rsw" >/dev/null 2>&1; then
    echo "→ Останавливаю запущенный процесс RSW…"
    pkill -f "Applications/RSW.app/Contents/MacOS/rsw" || true
fi

# ── Удаление служебных каталогов (опционально) ─────────────
if [[ $PURGE -eq 1 ]]; then
    PURGE_DIRS=(
        "$HOME/Library/Application Support/RSwitcher"
        "$HOME/Library/Logs/RSW"
        "$HOME/Library/Preferences/${BUNDLE_ID}.plist"
    )
    for d in "${PURGE_DIRS[@]}"; do
        if [[ -e "$d" ]]; then
            echo "→ --purge: $d"
            rm -rf "$d"
        fi
    done
    echo "✓ Все данные удалены (--purge)"
fi

# ── Чистка build-артефактов ────────────────────────────────
if [[ -d "$SCRIPT_DIR/build" ]]; then
    rm -rf "$SCRIPT_DIR/build"
    echo "✓ build/ очищен"
fi

# ── Итог ───────────────────────────────────────────────────
if [[ $REMOVED -eq 0 ]]; then
    echo "(ничего не было установлено)"
fi

cat <<EOF

═══════════════════════════════════════════════════════════
  RSW удалён.
  Словарь и логи оставлены (используйте --purge для полной очистки).
═══════════════════════════════════════════════════════════
EOF
