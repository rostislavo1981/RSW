# Анализ диагностических логов

## Методика

Логи собираются с переменными окружения:
- `RSW_DIAG=1` — включить диагностику
- `RSW_DIAG_CAPTURE_TEXT=1` — включить захват текста (ОСТОРОЖНО: пароли, токены)
- `RSW_DIAG_DIR=/path` — директория для логов
- `RSW_DIAG_MAX_MB=N` — размер файла до ротации

## Типы событий

| Событие | Описание | Ожидаемые причины |
|---------|----------|-------------------|
| `keyboard_event` | Клавиатурный ввод | `decision: received/terminal_passthrough` |
| `focused_ax` | Информация об элементе в фокусе | `available: true/false`, `role`, `selectedRange` |
| `correction_accepted` | Коррекция одобрена | `language: russian/english`, `replacementLength` |
| `correction_applied` | Коррекция применена | `path: ax`, `language` |
| `correction_failed` | Ошибка коррекции | `reason: terminal_excluded/no_conversion/ax_failed` |
| `manual_switch_failed` | Ошибка ручного переключения | `reason: no_selection/no_focused_ax/ax_unavailable` |

## Анализ (состояние на 2026-07-03)

### Успешные сценарии

```
ntcn → привет (Safari)
  correction_accepted → correction_applied
  language: russian, path: ax
```

- **Вход**: английскими буквами "ntcn" = "привет" на русской раскладке.
- **Результат**: успешное исправление через AX.

### Корректные отказы

```
привет → nil
  correction_skipped: converter_nil
```

- **Вход**: уже русское слово "привет".
- **Результат**: не исправляется — правильно (не нужно переключать русский текст).

```
go, nt, x (короткие слова)
  correction_skipped: short_word
```

- **Вход**: слова < 3 символов.
- **Результат**: не исправляются — правильно (минимальная длина = 3).

```
manual_switch_failed: no_selection
```

- **Вход**: ручное переключение без выделенного текста.
- **Результат**: ожидаемо. Требуется выделение для работы.

## Рекомендации

1. **UI улучшение**: добавить подсказку "Выделите текст для ручного переключения".
2. **Контекстный анализ**: добавить поле `hasSelection: bool` в `manual_switch_attempted` для различения причин.
3. **FP-слова**: регулярно проверять `correction_failed` с `reason: lowConfidence/suspiciousCharacter` — это кандидаты для словаря.

## Как читать логи

```bash
# Последние события
tail -50 ~/Library/Logs/RSW/rsw-diagnostics-*.jsonl

# Только ошибки
grep -E '"(correction_failed|manual_switch_failed)"' ~/Library/Logs/RSW/rsw-diagnostics-*.jsonl

# Только успешные исправления
grep '"correction_applied"' ~/Library/Logs/RSW/rsw-diagnostics-*.jsonl

# По приложению
grep '"com.apple.Safari"' ~/Library/Logs/RSW/rsw-diagnostics-*.jsonl | grep '"correction"'
```