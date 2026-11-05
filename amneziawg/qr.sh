#!/usr/bin/env bash
#
# qr.sh — QR-код для клиентского конфига AmneziaWG (приложения AmneziaVPN / AmneziaWG).
#
#   bash amneziawg/qr.sh client1                 # найдёт client1.conf сам
#   bash amneziawg/qr.sh /root/awg-clients/vanya.conf
#   bash amneziawg/qr.sh client1 --png ~/vanya.png
#   bash amneziawg/qr.sh client1 --text          # только текст конфига (для ручного ввода)
#
# Печатает QR прямо в терминал (можно сканировать с экрана телефона) и сохраняет PNG,
# чтобы отправить в мессенджер.
#
set -Eeuo pipefail

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
shift || true

PNG_OUT=""
SHOW_TEXT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --png)  PNG_OUT="${2:?--png требует путь}"; shift 2 ;;
    --text) SHOW_TEXT=1; shift ;;
    -h|--help) sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Неизвестная опция: $1" ;;
  esac
done

# --- ищем конфиг ---
CONF=""
if [[ -f "$TARGET" ]]; then
  CONF="$TARGET"
else
  name="${TARGET%.conf}"
  candidates=(
    "$PWD/$name.conf"
    "$HOME/awg-clients/$name.conf"
    "/root/awg-clients/$name.conf"
    "$HOME/ru-mobile/awg-443/$name.conf"
    "/root/ru-mobile/awg-443/$name.conf"
    "$HOME/ru-mobile/awg-2408/$name.conf"
    "/root/ru-mobile/awg-2408/$name.conf"
  )
  found=()
  for c in "${candidates[@]}"; do
    [[ -f "$c" ]] && found+=("$c")
  done
  case "${#found[@]}" in
    0) die "Не нашёл '$name.conf'. Укажите путь явно: bash amneziawg/qr.sh /путь/к/client.conf" ;;
    1) CONF="${found[0]}" ;;
    *) printf '[x] Найдено несколько конфигов, уточните путь:\n' >&2
       printf '    %s\n' "${found[@]}" >&2
       exit 1 ;;
  esac
fi

# --- проверяем, что конфиг годится для AmneziaWG ---
missing=()
for key in '[Interface]' 'PrivateKey' 'Address' '[Peer]' 'PublicKey' 'Endpoint'; do
  grep -qF -- "$key" "$CONF" || missing+=("$key")
done
(( ${#missing[@]} == 0 )) || die "В $CONF не хватает: ${missing[*]}"

OBF=0
for key in Jc Jmin Jmax S1 S2 H1 H2 H3 H4; do
  grep -qE "^$key *= *[0-9]+" "$CONF" && OBF=$((OBF + 1))
done
if (( OBF == 9 )); then
  log "Параметры обфускации на месте (Jc/Jmin/Jmax/S1/S2/H1–H4)"
elif (( OBF == 0 )); then
  warn "В конфиге нет параметров обфускации — это обычный WireGuard."
  warn "AmneziaWG-клиент его примет, но DPI-устойчивости не будет. Для обфускации пересоздайте конфиг:"
  warn "  sudo bash amneziawg/install-amneziawg.sh --force"
else
  warn "Найдено только $OBF из 9 параметров обфускации — возможно, конфиг повреждён."
fi
grep -qE '^Endpoint *= *[0-9a-zA-Z.-]+:[0-9]+' "$CONF" \
  || warn "Endpoint выглядит странно — проверьте строку 'Endpoint = IP:порт'"

# --- генерируем QR ---
if ! have qrencode; then
  warn "Не установлен qrencode. Поставьте: apt install -y qrencode"
  warn "Пока показываю текст конфига — его можно вставить вручную в приложении:"
  echo
  cat "$CONF"
  exit 1
fi

[[ -n "$PNG_OUT" ]] || PNG_OUT="${CONF%.conf}.png"
qrencode -t png -o "$PNG_OUT" -r "$CONF" || die "Не удалось создать PNG: $PNG_OUT"
log "PNG: $PNG_OUT"

if (( SHOW_TEXT == 1 )); then
  echo
  cat "$CONF"
  exit 0
fi

echo
echo "Сканируйте с экрана: приложение AmneziaVPN → «+» / «Добавить туннель» → сканер QR,"
echo "или AmneziaWG → «+» → «Сканировать QR-код»."
echo
qrencode -t ansiutf8 -r "$CONF"
