#!/usr/bin/env bash
#
# install-wireguard.sh — поднимает собственный WireGuard-сервер на VPS (Debian 11+/Ubuntu 20.04+).
#
# Что делает:
#   1. ставит wireguard-tools и qrencode;
#   2. включает маршрутизацию IPv4 (и IPv6, если указан --ipv6);
#   3. генерирует ключи сервера и клиентов;
#   4. пишет /etc/wireguard/wg0.conf и открывает UDP-порт в ufw (если ufw активен);
#   5. складывает клиентские конфиги + QR-коды в ~/wg-clients и запускает wg-quick@wg0.
#
# Примеры:
#   sudo bash install-wireguard.sh
#   sudo bash install-wireguard.sh --clients 3 --port 51820
#   bash install-wireguard.sh --dry-run --clients 2 --out ./out   # ничего не меняет в системе
#
set -Eeuo pipefail

WG_IFACE="${WG_IFACE:-wg0}"
WG_PORT="${WG_PORT:-51820}"
WG_SUBNET="${WG_SUBNET:-10.66.66}"   # туннельная сеть 10.66.66.0/24
WG_MTU="${WG_MTU:-1420}"
CLIENTS="${CLIENTS:-1}"
DNS_SERVERS="${DNS_SERVERS:-1.1.1.1, 8.8.8.8}"
ENDPOINT="${ENDPOINT:-}"             # можно задать вручную: 203.0.113.10:51820
OUT_DIR="${OUT_DIR:-$HOME/wg-clients}"
DRY_RUN=0
FORCE=0
USE_IPV6=0

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Использование: install-wireguard.sh [опции]

  --clients N      сколько клиентских конфигов создать (по умолчанию 1)
  --port N         UDP-порт WireGuard (по умолчанию 51820)
  --subnet P       первые три октета туннельной сети (по умолчанию 10.66.66)
  --mtu N          MTU клиентов (по умолчанию 1420)
  --dns "A, B"     DNS для клиентов (по умолчанию "1.1.1.1, 8.8.8.8")
  --endpoint H:P   публичный адрес сервера (по умолчанию определяется автоматически)
  --out DIR        куда писать клиентские конфиги (по умолчанию ~/wg-clients)
  --ipv6           включить двойной стек IPv4+IPv6 в туннеле
  --dry-run        сгенерировать конфиги в --out, не трогая систему
  --force          перезаписать существующий /etc/wireguard/wg0.conf
  -h, --help       эта справка
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clients)  CLIENTS="${2:?}"; shift 2 ;;
    --port)     WG_PORT="${2:?}"; shift 2 ;;
    --subnet)   WG_SUBNET="${2:?}"; shift 2 ;;
    --mtu)      WG_MTU="${2:?}"; shift 2 ;;
    --dns)      DNS_SERVERS="${2:?}"; shift 2 ;;
    --endpoint) ENDPOINT="${2:?}"; shift 2 ;;
    --out)      OUT_DIR="${2:?}"; shift 2 ;;
    --ipv6)     USE_IPV6=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --force)    FORCE=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "Неизвестная опция: $1 (см. --help)" ;;
  esac
done

[[ "$CLIENTS" =~ ^[0-9]+$ ]] && (( CLIENTS >= 1 )) || die "--clients должно быть числом >= 1"
[[ "$WG_PORT" =~ ^[0-9]+$ ]] && (( WG_PORT > 0 && WG_PORT < 65536 )) || die "Некорректный порт: $WG_PORT"

if (( DRY_RUN == 0 )); then
  [[ $EUID -eq 0 ]] || die "Запустите от root: sudo bash $0 $*"
  [[ -r /etc/os-release ]] || die "Не найден /etc/os-release — поддерживаются Debian/Ubuntu"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) warn "Дистрибутив '$ID' официально не тестировался (ожидаются debian/ubuntu)" ;;
  esac
fi

# ---------------------------------------------------------------- утилиты ---
have() { command -v "$1" >/dev/null 2>&1; }

gen_privkey() {
  if have wg; then wg genkey
  else openssl rand -base64 32 | tr -d '\n'   # только для --dry-run
  fi
}

gen_pubkey() {                # $1 — приватный ключ
  if have wg; then printf '%s' "$1" | wg pubkey
  else openssl rand -base64 32 | tr -d '\n'   # только для --dry-run
  fi
}

gen_psk() {
  if have wg; then wg genpsk
  else openssl rand -base64 32 | tr -d '\n'
  fi
}

detect_endpoint() {
  if [[ -n "$ENDPOINT" ]]; then printf '%s' "$ENDPOINT"; return 0; fi
  local ip=""
  for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip="$(curl -4 -fsS --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { printf '%s:%s' "$ip" "$WG_PORT"; return 0; }
  done
  return 1
}

default_iface() { ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}'; }

# ------------------------------------------------------- установка пакетов ---
install_packages() {
  log "Обновляю список пакетов и ставлю wireguard-tools + qrencode"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends wireguard-tools qrencode iptables curl ca-certificates
  have wg || die "wg не установился — проверьте apt"
}

enable_forwarding() {
  log "Включаю IP-форвардинг"
  local f=/etc/sysctl.d/99-vpnbye-wireguard.conf
  {
    echo 'net.ipv4.ip_forward = 1'
    if (( USE_IPV6 == 1 )); then
      echo 'net.ipv6.conf.all.forwarding = 1'
    fi
  } >"$f"
  sysctl -q --system >/dev/null 2>&1 || sysctl -q -p "$f"
}

open_firewall() {
  if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    log "Открываю UDP/$WG_PORT в ufw"
    ufw allow "$WG_PORT"/udp >/dev/null
  else
    warn "ufw не активен — убедитесь, что UDP/$WG_PORT открыт в firewall провайдера"
  fi
}


# ---------------------------------------------------------------- основное ---
# Пакеты ставим ДО генерации ключей: на чистом сервере wg ещё нет,
# иначе вместо настоящих ключей WireGuard получится заглушка.
if (( DRY_RUN == 0 )); then
  install_packages
  enable_forwarding
  open_firewall
fi

SERVER_PRIV="$(gen_privkey)"
SERVER_PUB="$(gen_pubkey "$SERVER_PRIV")"
(( DRY_RUN == 0 )) || warn "Режим --dry-run: ключи и адрес сервера условные"

ENDPOINT_ADDR="$(detect_endpoint || true)"
if [[ -z "$ENDPOINT_ADDR" ]]; then
  if (( DRY_RUN == 1 )); then
    ENDPOINT_ADDR="198.51.100.10:$WG_PORT"
    warn "Публичный IP не определён, использую заглушку $ENDPOINT_ADDR"
  else
    die "Не удалось определить публичный IP. Укажите вручную: --endpoint IP:$WG_PORT"
  fi
fi

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR" 2>/dev/null || true

SERVER_DIR=/etc/wireguard
SERVER_CONF="$SERVER_DIR/$WG_IFACE.conf"
if (( DRY_RUN == 1 )); then
  SERVER_DIR="$OUT_DIR/server"
  SERVER_CONF="$SERVER_DIR/$WG_IFACE.conf"
fi
mkdir -p "$SERVER_DIR"

if (( DRY_RUN == 0 )) && [[ -f "$SERVER_CONF" ]] && (( FORCE == 0 )); then
  die "$SERVER_CONF уже существует. Добавляйте клиентов через add-client.sh или используйте --force"
fi

WAN_IF="$(default_iface || true)"
if [[ -z "$WAN_IF" ]]; then
  WAN_IF="eth0"
  warn "Не определил внешний интерфейс, предполагаю $WAN_IF (проверьте PostUp/PostDown в $SERVER_CONF)"
fi

if (( USE_IPV6 == 1 )); then
  SERVER_ADDRS="$WG_SUBNET.1/24, fd42:42:42::1/64"
else
  SERVER_ADDRS="$WG_SUBNET.1/24"
fi

# --- серверный конфиг ---
{
  echo "[Interface]"
  echo "Address = $SERVER_ADDRS"
  echo "ListenPort = $WG_PORT"
  echo "PrivateKey = $SERVER_PRIV"
  echo "MTU = $WG_MTU"
  echo "SaveConfig = false"
  echo "PostUp = iptables -I INPUT -p udp --dport $WG_PORT -j ACCEPT"
  echo "PostUp = iptables -t nat -A POSTROUTING -s $WG_SUBNET.0/24 -o $WAN_IF -j MASQUERADE"
  echo "PostDown = iptables -D INPUT -p udp --dport $WG_PORT -j ACCEPT"
  echo "PostDown = iptables -t nat -D POSTROUTING -s $WG_SUBNET.0/24 -o $WAN_IF -j MASQUERADE"
  if (( USE_IPV6 == 1 )); then
    echo "PostUp = ip6tables -I INPUT -p udp --dport $WG_PORT -j ACCEPT"
    echo "PostUp = ip6tables -t nat -A POSTROUTING -s fd42:42:42::/64 -o $WAN_IF -j MASQUERADE"
    echo "PostDown = ip6tables -D INPUT -p udp --dport $WG_PORT -j ACCEPT"
    echo "PostDown = ip6tables -t nat -D POSTROUTING -s fd42:42:42::/64 -o $WAN_IF -j MASQUERADE"
  fi
  echo
} >"$SERVER_CONF"
chmod 600 "$SERVER_CONF"

log "Серверный конфиг: $SERVER_CONF"

# --- клиенты ---
declare -a CLIENT_CONFS=()
for i in $(seq 1 "$CLIENTS"); do
  name="client$i"
  c_priv="$(gen_privkey)"
  c_pub="$(gen_pubkey "$c_priv")"
  c_psk="$(gen_psk)"
  c_ip="$WG_SUBNET.$((i + 1))"
  c_addrs="$c_ip/32"
  if (( USE_IPV6 == 1 )); then
    c_addrs="$c_addrs, fd42:42:42::$((i + 1))/128"
  fi

  # клиентский конфиг
  cfile="$OUT_DIR/$name.conf"
  {
    echo "[Interface]"
    echo "PrivateKey = $c_priv"
    echo "Address = $c_addrs"
    echo "DNS = $DNS_SERVERS"
    echo "MTU = $WG_MTU"
    echo
    echo "[Peer]"
    echo "PublicKey = $SERVER_PUB"
    echo "PresharedKey = $c_psk"
    echo "Endpoint = $ENDPOINT_ADDR"
    echo "AllowedIPs = 0.0.0.0/0, ::/0"
    echo "PersistentKeepalive = 25"
  } >"$cfile"
  chmod 600 "$cfile"
  CLIENT_CONFS+=("$cfile")

  # секция peer в серверном конфиге
  {
    echo "[Peer]"
    echo "# $name"
    echo "PublicKey = $c_pub"
    echo "PresharedKey = $c_psk"
    echo "AllowedIPs = $c_addrs"
    echo
  } >>"$SERVER_CONF"

  # QR-код (нужен qrencode; в dry-run просто пропускаем)
  if (( DRY_RUN == 0 )) && have qrencode; then
    qrencode -t png -o "$OUT_DIR/$name.png" <"$cfile" && \
    qrencode -t ansiutf8 <"$cfile" >"$OUT_DIR/$name.qr.txt" || warn "QR для $name не создан"
  fi
  log "Клиент $name: $c_ip -> $cfile"
done

if (( DRY_RUN == 1 )); then
  log "Готово (dry-run). Файлы в $OUT_DIR"
  for f in "${CLIENT_CONFS[@]}"; do echo "  - $f"; done
  echo "  - $SERVER_CONF"
  exit 0
fi

# --- запуск ---
log "Запускаю интерфейс $WG_IFACE"
if wg show "$WG_IFACE" >/dev/null 2>&1; then
  wg-quick down "$WG_IFACE" || true
fi
systemctl enable --now "wg-quick@$WG_IFACE" >/dev/null 2>&1 || wg-quick up "$WG_IFACE"
sleep 1
systemctl is-active --quiet "wg-quick@$WG_IFACE" || die "Сервис wg-quick@$WG_IFACE не поднялся: journalctl -u wg-quick@$WG_IFACE -n 50"

log "Готово! Порт UDP/$WG_PORT, endpoint $ENDPOINT_ADDR"
echo
echo "Клиентские конфиги (не публикуйте их, это ваши ключи):"
for f in "${CLIENT_CONFS[@]}"; do echo "  $f"; done
echo
echo "Первый клиент, QR-код для телефона:"
if have qrencode; then qrencode -t ansiutf8 <"${CLIENT_CONFS[0]}"; else cat "${CLIENT_CONFS[0]}"; fi
echo
echo "Статус:     wg show"
echo "Логи:       journalctl -u wg-quick@$WG_IFACE -n 50 --no-pager"
echo "Новый пир:  sudo bash add-client.sh laptop"
