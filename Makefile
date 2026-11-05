.DEFAULT_GOAL := help
SHELL := /bin/bash
OUT ?= ./out

.PHONY: help check wg awg xray clean

help: ## Показать список целей
	@echo "vpnbye — свой VPN на своём сервере"
	@echo
	@echo "Подготовка (ничего не меняет в системе):"
	@echo "  make check          прогнать самопроверку всех скриптов"
	@echo "  make preflight      диагностика настроенного сервера (нужен root)"
	@echo "  make wg-dry         сгенерировать примеры WireGuard-конфигов"
	@echo "  make wg-lan-dry     примеры для сервера в РФ (--lan-only, без выхода в интернет)"
	@echo "  make awg-dry        сгенерировать примеры AmneziaWG-конфигов"
	@echo "  make xray-dry       сгенерировать пример config.json + ссылку VLESS"
	@echo "  make clean          удалить каталог $(OUT)"
	@echo
	@echo "Установка на сервере (нужен root):"
	@echo "  make ru-mobile      все каналы для МТС/Билайн/Мегафон (3 профиля клиентам)"
	@echo "  make qr C=client1   QR-код для клиента AmneziaWG (PNG + в терминале)"
	@echo "  make wg             WireGuard"
	@echo "  make awg            AmneziaWG (обфускация)"
	@echo "  make xray           Xray VLESS+REALITY"

check: ## Самопроверка репозитория
	bash scripts/check.sh

preflight: ## Диагностика сервера (что сломает подключение из РФ)
	sudo bash scripts/preflight.sh

ru-mobile: ## Поднять сразу 3 канала под МТС/Билайн/Мегафон (UDP/443 + UDP/2408 + REALITY)
	sudo bash scripts/install-for-ru-mobile.sh

ru-mobile-dry: ## Показать, что сделает ru-mobile, ничего не меняя
	bash scripts/install-for-ru-mobile.sh --dry-run

qr: ## QR для клиента AmneziaWG: make qr C=client1
	bash amneziawg/qr.sh "$(or $(C),client1)"

wg-dry: ## Примеры WireGuard-конфигов
	bash wireguard/install-wireguard.sh --dry-run --clients 2 --out "$(OUT)/wg"

wg-lan-dry: ## Примеры для сервера в РФ: только свои сети, без выхода в интернет
	bash wireguard/install-wireguard.sh --dry-run --lan-only --lan 192.168.1.0/24 \
		--clients 2 --out "$(OUT)/wg-lan"

awg-dry: ## Примеры AmneziaWG-конфигов
	bash amneziawg/install-amneziawg.sh --dry-run --clients 2 --out "$(OUT)/awg"

xray-dry: ## Пример config.json и VLESS-ссылки
	bash xray/install-xray-reality.sh --dry-run --clients 2 --out "$(OUT)/xray"

wg: ## Установить WireGuard на этот сервер
	sudo bash wireguard/install-wireguard.sh

awg: ## Установить AmneziaWG на этот сервер
	sudo bash amneziawg/install-amneziawg.sh

xray: ## Установить Xray VLESS+REALITY на этот сервер
	sudo bash xray/install-xray-reality.sh

clean: ## Удалить сгенерированные примеры
	rm -rf "$(OUT)"
