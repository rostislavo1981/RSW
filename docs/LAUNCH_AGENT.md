# Запуск RSW как Launch Agent

## Зачем

По умолчанию `swift run rsw` работает только в рамках текущей сессии терминала.
Если закрыть окно/терминал — приложение остановится. Для постоянной работы в фоне
используйте `launchd` (macOS Launch Agent).

## Prepare бинарника

```bash
swift build -c release
```

Готовый файл: `.build/release/rsw`

## Плаíst (Launch Agent)

Создайте `~/Library/LaunchAgents/com.yourname.rsw.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.yourname.rsw</string>

    <key>ProgramArguments</key>
    <array>
        <string>/Users/yourname/projects/RSW/.build/release/rsw</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/tmp/rsw-stdout.log</string>

    <key>StandardErrorPath</key>
    <string>/tmp/rsw-stderr.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>RSW_DIAG</key>
        <string>1</string>
        <key>RSW_DIAG_MAX_MB</key>
        <string>50</string>
    </dict>
</dict>
</plist>
```

## Управление

```bash
# Загрузить
launchctl load ~/Library/LaunchAgents/com.yourname.rsw.plist

# Выгрузить
launchctl unload ~/Library/LaunchAgents/com.yourname.rsw.plist

# Перезагрузить после обновления бинарника
launchctl unload ~/Library/LaunchAgents/com.yourname.rsw.plist
launchctl load ~/Library/LaunchAgents/com.yourname.rsw.plist

# Проверить статус
launchctl list | grep rsw
```

## Дополнительно: самоподписанный .app-бандл

Для автозапуска при входе через `SMAppService` соберите подписанный `.app`-бандл
(`Product → Archive` в Xcode или `xcodebuild`). В этом режиме:

- `launchAtLogin` в настройках RSW работает через системный Login Item;
- иконка приложения отображается в Launchpad;
- при первом запуске macOS запросит Accessibility-доступ.

Сырой бинаррь из `swift run` не поддерживает `SMAppService`.
