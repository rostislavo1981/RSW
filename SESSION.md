# Сессия Kilo — RSW

- **Дата/время:** 2026-06-17 21:53 (MSK)
- **Рабочая директория:** `/Users/rostislav/projects/RSW`
- **Корень workspace:** `/Users/rostislav/projects/RSW`

## Задачи сессии

1. Изучить код RSW v0.2.15 (SwitcherCore + RSW + TestRunner).
2. Проанализировать диагностические логи `RSW_DIAG=1` и `RSW_DIAG_CAPTURE_TEXT=1` из `~/Library/Logs/RSW/`.
3. Выявить источники артефактов (лишние буквы при ручном переключении, `converter_nil`).
4. Подготовить информацию для последующего исправления.

## Собранные логи

| Файл | Событий | Примечание |
|---|---|---|
| `rsw-diagnostics-20260617-095503-892.jsonl` | 14 407 | Старая сессия без `CAPTURE_TEXT` |
| `rsw-diagnostics-20260617-213628-886.jsonl` | 275 | Сессия без `CAPTURE_TEXT` |
| `rsw-diagnostics-20260617-214228-793.jsonl` | 964+ | Сессия с `RSW_DIAG_CAPTURE_TEXT=1` (пишется сейчас) |

## Ключевые наблюдения

- Ошибок замены (`correction_failed`, `ax_set_failed`) в логах **нет**.
- Основная причина пропусков исправлений — `converter_nil` (312 за ~12 ч) и `short_word` (512 за ~12 ч).
- `short_word` — штатное поведение (слова короче `minWordLength`, по умолчанию 3).
- Ручное переключение: 16 применённых операций, 11 через AX (`last_word_ax`), 5 через synthetic (`last_word_synthetic`).
- Fallbacks `no_selection` (9) и `no_focused_ax` (2) участвуют в артефактах.

## Гипотезы по артефактам

*(Замечания ниже относятся к версиям до v0.2.17, в которой synthetic fallback был заблокирован без AX-подтверждения.)*

- **Лишняя первая буква** после ручного переключения:
   1. Synthetic fallback удаляет ровно `wordLength` backspace, затем вставляет `replacement`. При рассинхронизации длины или лишнем backspace съедается первая буква следующего слова.
   2. AX-замена выделения оставляет новое слово выделенным; следующий ввод пользователя overwrite-ит его, создавая "лишнюю" букву.

## Запуск для диагностики

```bash
RSW_DIAG=1 RSW_DIAG_CAPTURE_TEXT=1 .build/release/rsw
```

Логи: `~/Library/Logs/RSW/rsw-diagnostics-YYYYMMDD-HHMMSS-SSS.jsonl`
