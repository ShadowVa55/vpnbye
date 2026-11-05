#!/usr/bin/env bash
#
# add-client.sh — добавить или удалить клиента WireGuard на уже настроенном сервере.
#
#   sudo bash add-client.sh laptop            # создать клиента "laptop"
#   sudo bash add-client.sh phone --revoke    # удалить клиента "phone"
#
# Работает «на живую»: существующие подключения не рвутся (wg set вместо рестарта).
#
set -Eeuo pipefail

WG_IFACE="${WG_IFACE:-wg0}"
WG_CONF="${WG_CONF:-/etc/wireguard/$WG_IFACE.conf}"
DNS_SERVERS="${DNS_SERVERS:-1.1.1.1, 8.8.8.8}"
OUT_DIR="${OUT_DIR:-/root/wg-clients}"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

NAME="${1:-}"
REVOKE=0
[[ "${2:-}" == "--revoke" ]] && REVOKE=1

[[ -n "$NAME" ]] || die "Укажите имя клиента: add-client.sh laptop [--revoke]"
[[ "$NAME" =~ ^[a-zA-Z0-9_-]{1,32}$ ]] || die "Имя: только a-z, A-Z, 0-9, _ и - (до 32 символов)"
[[ "$WG_CONF" == /etc/* && $EUID -ne 0 ]] && die "Запустите от root: sudo bash $0 $*"
command -v wg >/dev/null 2>&1 || die "Не найден wg — установите wireguard-tools"
[[ -f "$WG_CONF" ]] || die "Не найден $WG_CONF — сначала запустите install-wireguard.sh"

if grep -q "^# $NAME\$" "$WG_CONF"; then
  if (( REVOKE == 0 )); then
    die "Клиент '$NAME' уже есть в $WG_CONF"
  fi
else
  (( REVOKE == 0 )) || die "Клиент '$NAME' не найден в $WG_CONF"
fi

SUBNET="$(awk -F'[ =/]+' '/^Address/ {split($2,o,"."); print o[1]"."o[2]"."o[3]; exit}' "$WG_CONF")"
[[ -n "$SUBNET" ]] || die "Не смог определить туннельную подсеть из $WG_CONF"

if (( REVOKE == 1 )); then
  log "Удаляю клиента $NAME"
  PUB="$(grep -A1 "^# $NAME\$" "$WG_CONF" | awk -F' = ' '/^PublicKey/ {print $2; exit}')"
  [[ -n "$PUB" ]] || die "Не нашёл PublicKey клиента $NAME"

  if wg show "$WG_IFACE" >/dev/null 2>&1; then
    if wg set "$WG_IFACE" peer "$PUB" remove; then
      log "Пир удалён из работающего интерфейса"
    else
      printf '\033[1;33m[!]\033[0m %s\n' "Не удалось убрать пир из $WG_IFACE — применится после рестарта" >&2
    fi
  fi

  # вырезаем абзац [Peer] целиком (пиры разделены пустой строкой)
  awk -v n="# $NAME" 'BEGIN { RS = ""; ORS = "\n\n" }
  {
    found = 0
    k = split($0, lines, "\n")
    for (i = 1; i <= k; i++) if (lines[i] == n) found = 1
    if (!found) print
  }' "$WG_CONF" >"$WG_CONF.new" && mv "$WG_CONF.new" "$WG_CONF"
  chmod 600 "$WG_CONF"
  rm -f "$OUT_DIR/$NAME.conf" "$OUT_DIR/$NAME.png" "$OUT_DIR/$NAME.qr.txt"
  log "Готово: $NAME отключён и удалён из конфига"
  exit 0
fi

# --- новый клиент ---
USED_MAX="$(grep -E "^AllowedIPs = $SUBNET\." "$WG_CONF" | sed -E "s#.*$SUBNET\.([0-9]+).*#\1#" | sort -n | tail -1)"
NEXT_IP=$(( ${USED_MAX:-1} + 1 ))
(( NEXT_IP <= 254 )) || die "В подсети $SUBNET.0/24 закончились адреса"

SERVER_PUB="$(wg show "$WG_IFACE" public-key 2>/dev/null || true)"
if [[ -z "$SERVER_PUB" ]]; then
  SERVER_PRIV="$(awk -F' = ' '/^PrivateKey/ {print $2; exit}' "$WG_CONF")"
  SERVER_PUB="$(printf '%s' "$SERVER_PRIV" | wg pubkey)"
fi
[[ -n "$SERVER_PUB" ]] || die "Не смог получить публичный ключ сервера"

# Endpoint: можно задать через ENDPOINT=IP:порт, иначе берём из ранее выданных конфигов
if [[ -z "${ENDPOINT:-}" ]]; then
  ENDPOINT="$(awk -F' = ' '/^Endpoint/ {print $2; exit}' "$OUT_DIR"/*.conf 2>/dev/null | head -1 || true)"
fi
if [[ -z "$ENDPOINT" ]]; then
  PORT="$(awk -F' = ' '/^ListenPort/ {print $2; exit}' "$WG_CONF")"
  IP="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$IP" ]] || die "Не определил публичный IP. Задайте ENDPOINT=IP:порт вручную"
  ENDPOINT="$IP:${PORT:-51820}"
fi
MTU="$(awk -F' = ' '/^MTU/ {print $2; exit}' "$WG_CONF")"

# Режим сервера определяем по его же правилам NAT:
# есть MASQUERADE без -d (весь трафик в интернет) -> full, иначе --lan-only.
CLIENT_ALLOWED="0.0.0.0/0, ::/0"
CLIENT_DNS="$DNS_SERVERS"
LAN_ONLY=0
if ! grep -qE "POSTROUTING -s $SUBNET\.0/24 -o [^ ]+ -j MASQUERADE" "$WG_CONF"; then
  LAN_ONLY=1
  CLIENT_ALLOWED="$SUBNET.0/24"
  while read -r lan; do
    [[ -n "$lan" ]] && CLIENT_ALLOWED="$CLIENT_ALLOWED, $lan"
  done < <(grep -oE -- '-d [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' "$WG_CONF" | awk '{print $2}' | sort -u)
  CLIENT_DNS=""     # в режиме только-свои-сети внешний DNS не навязываем
fi

C_PRIV="$(wg genkey)"
C_PUB="$(printf '%s' "$C_PRIV" | wg pubkey)"
C_PSK="$(wg genpsk)"
C_IP="$SUBNET.$NEXT_IP"

mkdir -p "$OUT_DIR"; chmod 700 "$OUT_DIR" 2>/dev/null || true
CFILE="$OUT_DIR/$NAME.conf"
umask 077
{
  echo "[Interface]"
  echo "PrivateKey = $C_PRIV"
  echo "Address = $C_IP/32"
  if [[ -n "$CLIENT_DNS" ]]; then
    echo "DNS = $CLIENT_DNS"
  fi
  echo "MTU = ${MTU:-1420}"
  echo
  echo "[Peer]"
  echo "PublicKey = $SERVER_PUB"
  echo "PresharedKey = $C_PSK"
  echo "Endpoint = $ENDPOINT"
  echo "AllowedIPs = $CLIENT_ALLOWED"
  echo "PersistentKeepalive = 25"
} >"$CFILE"
chmod 600 "$CFILE"

{
  echo "[Peer]"
  echo "# $NAME"
  echo "PublicKey = $C_PUB"
  echo "PresharedKey = $C_PSK"
  echo "AllowedIPs = $C_IP/32"
  echo
} >>"$WG_CONF"

# применяем без рестарта — остальные клиенты не заметят
if wg show "$WG_IFACE" >/dev/null 2>&1; then
  wg set "$WG_IFACE" peer "$C_PUB" preshared-key <(printf '%s' "$C_PSK") allowed-ips "$C_IP/32"
else
  printf '\033[1;33m[!]\033[0m %s\n' "Интерфейс $WG_IFACE не запущен — пир применится при старте: systemctl restart wg-quick@$WG_IFACE" >&2
fi

log "Клиент $NAME добавлен: $C_IP → $CFILE"
if command -v qrencode >/dev/null 2>&1; then
  qrencode -t png -o "$OUT_DIR/$NAME.png" <"$CFILE"
  qrencode -t ansiutf8 <"$CFILE"
else
  cat "$CFILE"
fi
