#!/usr/bin/env bash
#
# install-amneziawg.sh — AmneziaWG (WireGuard с обфускацией) на VPS.
#
# Зачем: обычный WireGuard в РФ и ряде стран распознаётся DPI по сигнатуре хендшейка.
# AmneziaWG добавляет junk-пакеты, рандомизацию размеров и подмену заголовков,
# поэтому для провайдера трафик выглядит как «непонятный UDP», а не WireGuard.
#
# Примеры:
#   sudo bash install-amneziawg.sh
#   sudo bash install-amneziawg.sh --clients 2 --port 443
#   bash install-amneziawg.sh --dry-run --out ./out
#
set -Eeuo pipefail

AWG_IFACE="${AWG_IFACE:-awg0}"
AWG_PORT="${AWG_PORT:-51820}"
AWG_SUBNET="${AWG_SUBNET:-10.8.1}"
AWG_MTU="${AWG_MTU:-1280}"
CLIENTS="${CLIENTS:-1}"
DNS_SERVERS="${DNS_SERVERS:-1.1.1.1, 8.8.8.8}"
ENDPOINT="${ENDPOINT:-}"
OUT_DIR="${OUT_DIR:-$HOME/awg-clients}"
DRY_RUN=0
FORCE=0

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Использование: install-amneziawg.sh [опции]

  --clients N      количество клиентов (по умолчанию 1)
  --port N         UDP-порт (по умолчанию 51820; 443 выглядит безобиднее)
  --subnet P       первые три октета сети (по умолчанию 10.8.1)
  --mtu N          MTU (по умолчанию 1280 — безопасно для мобильных сетей)
  --dns "A, B"     DNS клиентов
  --endpoint H:P   публичный адрес сервера
  --out DIR        каталог для клиентских конфигов
  --dry-run        только сгенерировать конфиги
  --force          перезаписать существующий конфиг интерфейса
  -h, --help       справка
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clients)  CLIENTS="${2:?}"; shift 2 ;;
    --port)     AWG_PORT="${2:?}"; shift 2 ;;
    --subnet)   AWG_SUBNET="${2:?}"; shift 2 ;;
    --mtu)      AWG_MTU="${2:?}"; shift 2 ;;
    --dns)      DNS_SERVERS="${2:?}"; shift 2 ;;
    --endpoint) ENDPOINT="${2:?}"; shift 2 ;;
    --out)      OUT_DIR="${2:?}"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --force)    FORCE=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "Неизвестная опция: $1 (см. --help)" ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }
rand() { echo $(( RANDOM % ($2 - $1 + 1) + $1 )); }

awg_privkey() {
  if have awg; then awg genkey
  elif have wg; then wg genkey
  else openssl rand -base64 32 | tr -d '\n'   # заглушка для --dry-run
  fi
}

awg_pubkey() {                # $1 — приватный ключ
  if have awg; then printf '%s' "$1" | awg pubkey
  elif have wg; then printf '%s' "$1" | wg pubkey
  else openssl rand -base64 32 | tr -d '\n'   # заглушка для --dry-run
  fi
}

install_amneziawg() {
  export DEBIAN_FRONTEND=noninteractive
  log "Ставлю зависимости и linux-headers"
  apt-get update -qq
  apt-get install -y --no-install-recommends \
    software-properties-common gnupg2 curl ca-certificates qrencode iptables \
    "linux-headers-$(uname -r)" || warn "linux-headers не установились — модуль может не собраться"

  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" == "ubuntu" ]]; then
    log "Добавляю PPA amnezia"
    add-apt-repository -y ppa:amnezia/ppa
  else
    log "Добавляю репозиторий amnezia (Debian)"
    apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 57290828 >/dev/null 2>&1 || \
      warn "apt-key не сработал, проверьте подпись репозитория вручную"
    echo "deb https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main" \
      >/etc/apt/sources.list.d/amneziawg.list
  fi
  apt-get update -qq
  apt-get install -y amneziawg amneziawg-tools || {
    warn "Пакет amneziawg не встал. Проверьте: apt-cache policy amneziawg"
    die "Установка прервана"
  }
  modinfo amneziawg >/dev/null 2>&1 || warn "Модуль ядра amneziawg не загружен — возможен перезапуск сервера с другим ядром"
}

awg_conf_dir() {
  # awg-quick во форке Amnezia хранит конфиги отдельно от WireGuard — определяем путь из скрипта
  local bin dir=""
  bin="$(command -v awg-quick || true)"
  if [[ -n "$bin" ]]; then
    dir="$(grep -oE '/etc/[A-Za-z0-9_/-]*amneziawg' "$bin" | head -n1 || true)"
  fi
  printf '%s' "${dir:-/etc/amnezia/amneziawg}"
}

detect_endpoint() {
  if [[ -n "$ENDPOINT" ]]; then printf '%s' "$ENDPOINT"; return 0; fi
  local ip=""
  for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip="$(curl -4 -fsS --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { printf '%s:%s' "$ip" "$AWG_PORT"; return 0; }
  done
  return 1
}

# --- параметры обфускации (должны совпадать на сервере и у клиентов) ---
# Диапазоны выбраны консервативно, чтобы проходила валидация в приложении AmneziaVPN:
# H1..H3 уникальны и малы, H4 больше их суммы (это требование протокола).
JC="$(rand 4 7)"                  # количество junk-пакетов перед хендшейком
JMIN="$(rand 40 70)"              # минимальный размер junk-пакета
JMAX="$(( JMIN + $(rand 300 900) ))"
S1="$(rand 15 120)"               # «мусорный» префикс в handshake init
S2="$(rand 15 120)"
while [[ $(( S1 + 56 )) -eq $S2 ]]; do S2="$(rand 15 120)"; done   # требование протокола
H1="$(rand 5 900)"
H2="$(( H1 + $(rand 5 900) ))"
H3="$(( H2 + $(rand 5 900) ))"
H4="$(( H1 + H2 + H3 + $(rand 500 50000) ))"

# ---------------------------------------------------------------- основное ---
if (( DRY_RUN == 0 )); then
  [[ $EUID -eq 0 ]] || die "Запустите от root: sudo bash $0"
  install_amneziawg
  have awg || die "awg не найден после установки (пакет amneziawg-tools)"
  have awg-quick || die "awg-quick не найден после установки (пакет amneziawg-tools)"
  {
    echo 'net.ipv4.ip_forward = 1'
  } >/etc/sysctl.d/99-vpnbye-amneziawg.conf
  sysctl -q -p /etc/sysctl.d/99-vpnbye-amneziawg.conf
  if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "$AWG_PORT"/udp >/dev/null && log "Открыл UDP/$AWG_PORT в ufw"
  fi
  CONF_DIR="$(awg_conf_dir)"
else
  CONF_DIR="$OUT_DIR/server"
fi

ENDPOINT_ADDR="$(detect_endpoint || true)"
[[ -n "$ENDPOINT_ADDR" ]] || ENDPOINT_ADDR="198.51.100.10:$AWG_PORT"

mkdir -p "$CONF_DIR" "$OUT_DIR"
chmod 700 "$OUT_DIR" 2>/dev/null || true
SRV_CONF="$CONF_DIR/$AWG_IFACE.conf"
if (( DRY_RUN == 0 )) && [[ -f "$SRV_CONF" ]] && (( FORCE == 0 )); then
  die "$SRV_CONF уже существует — используйте --force, чтобы перезаписать"
fi

WAN_IF="$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}' || true)"
WAN_IF="${WAN_IF:-eth0}"

SRV_PRIV="$(awg_privkey)"
SRV_PUB="$(awg_pubkey "$SRV_PRIV")"

# --- серверный конфиг ---
{
  echo "[Interface]"
  echo "Address = $AWG_SUBNET.1/24"
  echo "ListenPort = $AWG_PORT"
  echo "PrivateKey = $SRV_PRIV"
  echo "MTU = $AWG_MTU"
  echo "Jc = $JC"
  echo "Jmin = $JMIN"
  echo "Jmax = $JMAX"
  echo "S1 = $S1"
  echo "S2 = $S2"
  echo "H1 = $H1"
  echo "H2 = $H2"
  echo "H3 = $H3"
  echo "H4 = $H4"
  echo "PostUp = iptables -I INPUT -p udp --dport $AWG_PORT -j ACCEPT"
  echo "PostUp = iptables -t nat -A POSTROUTING -s $AWG_SUBNET.0/24 -o $WAN_IF -j MASQUERADE"
  echo "PostDown = iptables -D INPUT -p udp --dport $AWG_PORT -j ACCEPT"
  echo "PostDown = iptables -t nat -D POSTROUTING -s $AWG_SUBNET.0/24 -o $WAN_IF -j MASQUERADE"
  echo
} >"$SRV_CONF"
chmod 600 "$SRV_CONF"
log "Серверный конфиг: $SRV_CONF"

# --- клиенты ---
for i in $(seq 1 "$CLIENTS"); do
  name="client$i"
  c_priv="$(awg_privkey)"
  c_pub="$(awg_pubkey "$c_priv")"
  c_ip="$AWG_SUBNET.$((i + 1))"
  cfile="$OUT_DIR/$name.conf"

  {
    echo "[Interface]"
    echo "PrivateKey = $c_priv"
    echo "Address = $c_ip/32"
    echo "DNS = $DNS_SERVERS"
    echo "MTU = $AWG_MTU"
    echo "Jc = $JC"
    echo "Jmin = $JMIN"
    echo "Jmax = $JMAX"
    echo "S1 = $S1"
    echo "S2 = $S2"
    echo "H1 = $H1"
    echo "H2 = $H2"
    echo "H3 = $H3"
    echo "H4 = $H4"
    echo
    echo "[Peer]"
    echo "PublicKey = $SRV_PUB"
    echo "Endpoint = $ENDPOINT_ADDR"
    echo "AllowedIPs = 0.0.0.0/0, ::/0"
    echo "PersistentKeepalive = 25"
  } >"$cfile"
  chmod 600 "$cfile"

  {
    echo "[Peer]"
    echo "# $name"
    echo "PublicKey = $c_pub"
    echo "AllowedIPs = $c_ip/32"
    echo
  } >>"$SRV_CONF"
  log "Клиент $name: $c_ip -> $cfile"
done

if (( DRY_RUN == 1 )); then
  log "Готово (dry-run). Конфиги в $OUT_DIR"
  exit 0
fi

log "Запускаю $AWG_IFACE"
systemctl enable --now "awg-quick@$AWG_IFACE" >/dev/null 2>&1 || awg-quick up "$AWG_IFACE"
sleep 1
if ! systemctl is-active --quiet "awg-quick@$AWG_IFACE"; then
  die "Интерфейс не поднялся: journalctl -u awg-quick@$AWG_IFACE -n 50 --no-pager"
fi

log "Готово! AmneziaWG слушает UDP/$AWG_PORT, endpoint $ENDPOINT_ADDR"
echo
echo "Дальше: установите приложение AmneziaVPN (Windows/macOS/Linux/Android/iOS),"
echo "добавьте сервер вручную ('Я хочу настроить свой VPN' -> протокол AmneziaWG)"
echo "или импортируйте файл $OUT_DIR/client1.conf / отсканируйте QR."
echo "Статус: awg show"

