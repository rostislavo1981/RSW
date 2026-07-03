#!/usr/bin/env bash
# install.sh — устанавливает RSW как .app-бандл в /Applications.
#
# Что делает:
#   1. Проверяет, что мы на macOS и есть Swift toolchain.
#   2. Собирает release-бинарь (`swift build -c release`).
#   3. Упаковывает его в .app-бандл с минимальной Info.plist.
#   4. Копирует в /Applications/RSW.app (или $RSW_INSTALL_DIR).
#   5. (Опционально) Регистрирует login item через launchd.
#
# Использование:
#   ./install.sh                 # установить в /Applications
#   ./install.sh --no-login      # не регистрировать login item
#   ./install.sh --prefix ~/Apps # установить в свой каталог
#
# Требования:
#   • macOS 13+ (Ventura)
#   • Swift 5.9+ (Xcode Command Line Tools или полный Xcode)
#   • Для login item: подписанный .app (опционально)
set -eo pipefail

# ── Конфигурация ────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="RSW"
BUNDLE_ID="com.rostislavo.RSW"
VERSION="0.2.19"
BUILD_NUMBER="19"

INSTALL_DIR="/Applications"
REGISTER_LOGIN=1
LAUNCH_AFTER=0

# ── Разбор аргументов ───────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-login)         REGISTER_LOGIN=0; shift ;;
        --prefix)          INSTALL_DIR="$2"; shift 2 ;;
        --launch)           LAUNCH_AFTER=1; shift ;;
        -h|--help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *)
            echo "Неизвестный аргумент: $1" >&2
            exit 2
            ;;
    esac
done

# ── Предусловия ─────────────────────────────────────────────
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Ошибка: RSW работает только на macOS." >&2
    exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
    echo "Ошибка: swift не найден. Установите Command Line Tools:" >&2
    echo "    xcode-select --install" >&2
    exit 1
fi

SWIFT_VERSION=$(swift --version 2>/dev/null | head -1 | awk '{print $NF}')
echo "→ Swift: $SWIFT_VERSION"
echo "→ Целевой каталог: $INSTALL_DIR"
echo

# ── Сборка ──────────────────────────────────────────────────
echo "→ Сборка release…"
swift build -c release

BIN_PATH=".build/release/rsw"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "Ошибка: бинарь не найден после сборки: $BIN_PATH" >&2
    exit 1
fi
echo "✓ Бинарь собран ($(du -h "$BIN_PATH" | cut -f1))"
echo

# ── Упаковка .app-бандла ─────────────────────────────────────
APP_DIR="$SCRIPT_DIR/build/${APP_NAME}.app"
echo "→ Создание .app-бандла: $APP_DIR"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/rsw"
chmod +x "$APP_DIR/Contents/MacOS/rsw"

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
                       "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>         <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>          <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>             <string>${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key>  <string>${VERSION}</string>
    <key>CFBundleExecutable</key>          <string>rsw</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleSignature</key>           <string>????</string>
    <key>LSMinimumSystemVersion</key>      <string>13.0</string>
    <key>LSUIElement</key>                 <true/>
    <key>NSHighResolutionCapable</key>     <true/>
    <key>NSHumanReadableCopyright</key>    <string>© 2026 rostislavo</string>
    <key>NSAppleEventsUsageDescription</key>
        <string>RSW использует Apple Events для управления вводом.</string>
    <key>NSDesktopFolderUsageDescription</key>
        <string>RSW сохраняет локальный словарь в Application Support.</string>
    <key>NSDocumentsFolderUsageDescription</key>
        <string>RSW сохраняет локальный словарь в Application Support.</string>
</dict>
</plist>
EOF

# PkgInfo — минимальный, но macOS ожидает его
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

# ── Копирование в целевой каталог ───────────────────────────
TARGET="$INSTALL_DIR/${APP_NAME}.app"
echo "→ Установка: $TARGET"

# Попытка установить в /Applications (нужны sudo-права, если не свой каталог)
if [[ ! -d "$INSTALL_DIR" ]]; then
    echo "Создаю $INSTALL_DIR…" >&2
    mkdir -p "$INSTALL_DIR" 2>/dev/null || {
        echo "Ошибка: не удалось создать $INSTALL_DIR. Используйте --prefix." >&2
        exit 1
    }
fi

# Удалить предыдущую установку (если есть)
if [[ -d "$TARGET" ]]; then
    rm -rf "$TARGET"
fi

if ! cp -R "$APP_DIR" "$TARGET" 2>/dev/null; then
    echo "Не удалось скопировать в $TARGET (нужны sudo-права)." >&2
    echo "Повторная попытка через sudo…" >&2
    sudo rm -rf "$TARGET"
    sudo cp -R "$APP_DIR" "$TARGET"
fi

echo "✓ Установлено: $TARGET"
echo

# ── Регистрация login item (опционально) ────────────────────
if [[ $REGISTER_LOGIN -eq 1 ]]; then
    echo "→ Регистрация login item…"
    OSASCRIPT_OUT=$(osascript <<EOF 2>&1
tell application "System Events"
    make login item at end with properties {path:"$TARGET", hidden:false}
end tell
EOF
)
    if [[ $? -eq 0 ]]; then
        echo "✓ Login item зарегистрирован: $TARGET"
    else
        echo "⚠ Не удалось зарегистрировать login item. Сделайте вручную:" >&2
        echo "  System Settings → General → Login Items → Open at Login" >&2
        echo "  (добавьте $TARGET)" >&2
    fi
    echo
fi

# ── Запуск ──────────────────────────────────────────────────
if [[ $LAUNCH_AFTER -eq 1 ]]; then
    echo "→ Запуск…"
    open "$TARGET"
fi

# ── Первый запуск: подсказка про Accessibility ──────────────
cat <<EOF

═══════════════════════════════════════════════════════════
  Установка завершена: $TARGET
═══════════════════════════════════════════════════════════

  При ПЕРВОМ запуске macOS попросит доступ в
  System Settings → Privacy & Security → Accessibility.
  После выдачи доступа — запустите приложение ещё раз.

  Запуск:        open $TARGET
  Или двойной клик в Finder: $TARGET

  Удаление:      ./uninstall.sh

═══════════════════════════════════════════════════════════
EOF
