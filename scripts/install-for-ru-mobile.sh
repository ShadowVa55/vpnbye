#!/usr/bin/env bash
#
# install-for-ru-mobile.sh — один сервер, три канала под МТС / Билайн / Мегафон.
#
# Поднимает сразу:
#   1) AmneziaWG на UDP/443   — «непонятный UDP», выглядит как QUIC/HTTP3
#   2) AmneziaWG на UDP/2408  — резерв, если 443/udp душат (отдельный интерфейс awg1)
#   3) Xray VLESS+REALITY на TCP/443 — выглядит как HTTPS к сайту-прикрытию
#
# Клиентам раздаются три профиля: если оператор режет один — переключаются в другой.
# TCP/443 и UDP/443 не конфликтуют, awg0 и awg1 живут параллельно.
#
#   sudo bash scripts/install-for-ru-mobile.sh                    # всё сразу
#   sudo bash scripts/install-for-ru-mobile.sh --no-alt           # без резервного UDP/2408
#   sudo bash scripts/install-for-ru-mobile.sh --sni www.samsung.com --clients 3
#   bash scripts/install-for-ru-mobile.sh --dry-run               # только показать команды
#
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_BASE="${OUT_BASE:-/root/ru-mobile}"
SNI="${SNI:-www.microsoft.com}"
CLIENTS="${CLIENTS:-2}"
NAMES="${NAMES:-}"
WITH_ALT=1
DRY_RUN=0

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Использование: install-for-ru-mobile.sh [опции]

  --sni HOST      сайт-прикрытие для REALITY (по умолчанию www.microsoft.com)
  --clients N     сколько клиентов на каждый AmneziaWG-канал (по умолчанию 2)
  --names LIST    имена клиентов REALITY через запятую (по умолчанию client1..N)
  --out DIR       куда складывать клиентские файлы (по умолчанию /root/ru-mobile)
  --no-alt        не поднимать резервный AmneziaWG на UDP/2408
  --dry-run       показать команды, ничего не выполняя
  -h, --help      эта справка
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sni)      SNI="${2:?}"; shift 2 ;;
    --clients)  CLIENTS="${2:?}"; shift 2 ;;
    --names)    NAMES="${2:?}"; shift 2 ;;
    --out)      OUT_BASE="${2:?}"; shift 2 ;;
    --no-alt)   WITH_ALT=0; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "Неизвестная опция: $1 (см. --help)" ;;
  esac
done

[[ "$CLIENTS" =~ ^[0-9]+$ ]] && (( CLIENTS >= 1 )) || die "--clients должно быть числом >= 1"
if (( DRY_RUN == 0 )); then
  [[ $EUID -eq 0 ]] || die "Запустите от root: sudo bash $0 $*"
fi

# в dry-run печатаем команду, иначе выполняем
run() {
  if (( DRY_RUN == 1 )); then
    printf '  \033[2m$ %s\033[0m\n' "$*"
    return 0
  fi
  "$@"
}

(( DRY_RUN == 1 )) || mkdir -p "$OUT_BASE"
(( DRY_RUN == 1 )) || chmod 700 "$OUT_BASE"

log "Канал 1/3: AmneziaWG на UDP/443 (основной для мобильных операторов)"
run bash "$ROOT/amneziawg/install-amneziawg.sh" \
  --port 443 --clients "$CLIENTS" --mtu 1280 \
  --out "$OUT_BASE/awg-443"

if (( WITH_ALT == 1 )); then
  log "Канал 2/3: AmneziaWG на UDP/2408 (резерв, интерфейс awg1)"
  run env AWG_IFACE=awg1 bash "$ROOT/amneziawg/install-amneziawg.sh" \
    --port 2408 --clients "$CLIENTS" --mtu 1280 --subnet 10.9.9 \
    --out "$OUT_BASE/awg-2408"
fi

log "Канал 3/3: Xray VLESS+REALITY на TCP/443, прикрытие: $SNI"
if [[ -n "$NAMES" ]]; then
  run bash "$ROOT/xray/install-xray-reality.sh" \
    --sni "$SNI" --names "$NAMES" --out "$OUT_BASE/reality"
else
  run bash "$ROOT/xray/install-xray-reality.sh" \
    --sni "$SNI" --clients "$CLIENTS" --out "$OUT_BASE/reality"
fi

log "Диагностика"
run bash "$ROOT/scripts/preflight.sh"

# ------------------------------------------------------------------ шпаргалка ---
CHECKLIST="$OUT_BASE/README.txt"
if (( DRY_RUN == 1 )); then
  printf '  \033[2m$ создать %s\033[0m\n' "$CHECKLIST"
else
  cat >"$CHECKLIST" <<EOF
VPN для клиентов МТС / Билайн / Мегафон — шпаргалка
===================================================

Каналы на этом сервере:
  1) AmneziaWG  UDP/443   файлы: $OUT_BASE/awg-443/client*.conf
  2) AmneziaWG  UDP/2408  файлы: $OUT_BASE/awg-2408/client*.conf   (резерв)
  3) REALITY    TCP/443   ссылки: $OUT_BASE/reality/*.vless.txt

Порядок переключения, если «подключается, но не работает»:
  МТС      : сначала REALITY (TCP/443), затем awg-443, затем awg-2408
  Билайн   : сначала awg-443, затем REALITY, затем awg-2408
  Мегафон  : сначала REALITY, затем awg-443, затем awg-2408

Если ни один не работает:
  - проверьте, что дело не в MTU: поставьте в клиенте MTU 1280
  - смените сайт-прикрытие: --sni www.samsung.com или dl.google.com
  - проверьте IP сервера на блокировки, при необходимости смените IP у хостера
  - в роуминге за границей часто работают «белые списки» — VPN может не пройти

Проверка сервера в любой момент:  sudo bash $ROOT/scripts/preflight.sh
EOF
  chmod 600 "$CHECKLIST"
fi

echo
log "Готово. Клиентские файлы: $OUT_BASE (и шпаргалка $CHECKLIST)"
echo "Раздайте клиентам: awg-443/*.conf (+ PNG рядом), awg-2408/*.conf, reality/*.vless.txt"
