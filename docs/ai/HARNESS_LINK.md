# Связь с Hermes Global Harness

Дата подключения: 2026-06-29

## Идентификатор проекта

- `project_id`: `rsw`
- `memory_namespace`: `rsw`
- `class`: `code`
- `role`: `programming-project`

## Глобальные контуры

- Harness: `/Users/rostislav/projects/hermes-agent-harness`
- Memory: `/Users/rostislav/projects/hermes-memory`
- Registry: `/Users/rostislav/projects/hermes-agent-harness/projects/registry.yaml`
- Agent rules: `/Users/rostislav/projects/hermes-agent-harness/AGENTS.md`

## Правила использования

- Проектные инструкции этого repo имеют приоритет для локальной работы.
- Global Harness добавляет общие правила, память, навыки и model/router contracts.
- Этот файл является add-only ссылкой и не заменяет `AGENTS.md`, `CURRENT_STATE.md`, `HANDOFF.md` или `TASKS.md`.
- Память писать только через `/Users/rostislav/projects/hermes-memory/bin/mem`.
- Для записей памяти использовать `--project rsw`.
- Model/router telemetry писать только через `bin/mem telemetry` и только как `safe_metadata`.
- Smart-router является выбираемым маршрутом, а не обязательным шлюзом.
- PROD не менять без отдельной явной команды на apply/deploy/restart.

## Быстрые команды

```bash
HERMES_PROJECT_ID=rsw /Users/rostislav/projects/hermes-memory/bin/mem status
/Users/rostislav/projects/hermes-memory/bin/mem verify --project rsw
```

