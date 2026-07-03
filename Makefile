# Makefile для RSW — зеркало install.sh / run.sh / uninstall.sh.
#
# Использование:
#   make build       — release-сборка
#   make test        — запуск тестов (334 проверки)
#   make run         — запуск debug-версии
#   make install     — установить в /Applications
#   make uninstall   — удалить .app и login item
#   make clean       — очистить build/ и .build/

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eo pipefail -c

APP_NAME := RSW
BUNDLE_ID := com.rostislavo.RSW
VERSION := 0.2.19
BUILD_NUMBER := 19
INSTALL_DIR ?= /Applications

# Опции install.sh: --no-login по умолчанию (без сюрпризов с login item);
# LOGIN=1 переопределит это.
LOGIN ?= 0
LOGIN_FLAG := $(if $(filter 1,$(LOGIN)),,--no-login)

.PHONY: all build test run install uninstall clean help

all: build

# ── Сборка ──────────────────────────────────────────────────
build:
	swift build -c release

# ── Тесты ───────────────────────────────────────────────────
test:
	swift build -c release >/dev/null
	swift run TestRunner

# ── Запуск в dev-режиме ─────────────────────────────────────
run:
	swift run rsw

# ── Установка / удаление ────────────────────────────────────
install:
	./install.sh $(LOGIN_FLAG) --prefix $(INSTALL_DIR)

uninstall:
	./uninstall.sh

# ── Очистка ─────────────────────────────────────────────────
clean:
	swift package clean
	rm -rf build/ .build/

# ── Справка ─────────────────────────────────────────────────
help:
	@echo "RSW v$(VERSION) (build $(BUILD_NUMBER))"
	@echo ""
	@echo "Цели:"
	@echo "  make build         release-сборка"
	@echo "  make test          запустить тесты (334 проверки)"
	@echo "  make run           запустить в dev-режиме"
	@echo "  make install       установить в \$$INSTALL_DIR (по умолчанию /Applications)"
	@echo "  make install LOGIN=1   установить + зарегистрировать login item"
	@echo "  make uninstall     удалить .app и login item"
	@echo "  make clean         очистить build/ и .build/"
	@echo "  make help          эта справка"
	@echo ""
	@echo "Переменные:"
	@echo "  INSTALL_DIR=/path  куда ставить (по умолчанию /Applications)"
	@echo "  LOGIN=1            зарегистрировать login item при install"
