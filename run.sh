#!/usr/bin/env bash
# run.sh — запускает RSW в режиме разработки.
#
# Режимы:
#   ./run.sh              # debug-сборка, запуск напрямую
#   ./run.sh --release    # release-сборка
#   ./run.sh --test       # только тесты (без запуска)
#   ./run.sh --clean      # очистить .build перед сборкой
#
# Для продакшн-запуска используйте install.sh + open /Applications/RSW.app
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONFIG="debug"
ACTION="run"
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release|-r)   CONFIG="release"; shift ;;
        --test|-t)      ACTION="test"; shift ;;
        --clean)        swift package clean; shift ;;
        -h|--help)
            sed -n '2,12p' "$0"
            exit 0
            ;;
        *)              EXTRA_ARGS+=("$1"); shift ;;
    esac
done

case "$CONFIG" in
    release) SWIFT_FLAGS=("-c" "release") ;;
    debug)   SWIFT_FLAGS=() ;;
esac

case "$ACTION" in
    run)
        echo "→ Сборка (${CONFIG})…"
        swift build "${SWIFT_FLAGS[@]}"
        echo
        echo "→ Запуск RSW. Для остановки: Ctrl-C."
        echo "  (если Accessibility не разрешён — macOS покажет диалог)"
        echo
        exec .build/${CONFIG}/rsw "${EXTRA_ARGS[@]}"
        ;;
    test)
        echo "→ Тесты…"
        swift build "${SWIFT_FLAGS[@]}" >/dev/null
        swift run TestRunner "${EXTRA_ARGS[@]}"
        ;;
esac
