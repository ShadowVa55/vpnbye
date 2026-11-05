#!/usr/bin/env bash
#
# install-xray-reality.sh — VLESS + XTLS-Vision + REALITY на VPS.
#
# Это самый устойчивый к DPI вариант: трафик ходит по TCP/443 и с точки зрения
# провайдера неотличим от обычного HTTPS к выбранному сайту-«прикрытию» (dest).
# Сертификат и домен не нужны — REALITY «заимствует» TLS реального сайта.
#
# Примеры:
#   sudo bash install-xray-reality.sh
#   sudo bash install-xray-reality.sh --port 443 --sni www.microsoft.com
#   bash install-xray-reality.sh --dry-run --out ./out
#
set -Eeuo pipefail

XRAY_PORT="${XRAY_PORT:-443}"
SNI="${SNI:-www.microsoft.com}"       # сайт-прикрытие: зарубежный, TLS 1.3 + H2, без редиректов
CLIENTS="${CLIENTS:-1}"
NAMES=""                              # имена клиентов через запятую: phone,laptop,...
OUT_DIR="${OUT_DIR:-$HOME/xray-clients}"
CONF="/usr/local/etc/xray/config.json"
DRY_RUN=0
FORCE=0

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Использование: install-xray-reality.sh [опции]

  --port N       TCP-порт (по умолчанию 443)
  --sni HOST     сайт-прикрытие для REALITY (по умолчанию www.microsoft.com)
  --clients N    сколько UUID создать (по умолчанию 1)
  --names LIST   имена клиентов через запятую (phone,laptop); заменяет --clients
  --out DIR      каталог для ссылок/QR клиентов
  --dry-run      сгенерировать config.json и ссылки, не трогая систему
  --force        перезаписать существующий config.json
  -h, --help     справка
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)     XRAY_PORT="${2:?}"; shift 2 ;;
    --sni)      SNI="${2:?}"; shift 2 ;;
    --clients)  CLIENTS="${2:?}"; shift 2 ;;
    --names)    NAMES="${2:?}"; shift 2 ;;
    --out)      OUT_DIR="${2:?}"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --force)    FORCE=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "Неизвестная опция: $1 (см. --help)" ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }

install_xray() {
  log "Устанавливаю Xray-core официальным скриптом"
  apt-get update -qq
  apt-get install -y --no-install-recommends curl ca-certificates qrencode openssl python3
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  have xray || die "xray не установился"
  xray version | head -1
}

# xray x25519 печатает в разных версиях "Private key:"/"Public key:" или "PrivateKey:"/"Password:"
gen_keys() {
  if ! have xray; then
    # заглушка для --dry-run: 32 случайных байта в base64url (не настоящая пара X25519)
    printf '%s %s' \
      "$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')" \
      "$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"
    return 0
  fi
  local out priv pub
  out="$(xray x25519)"
  priv="$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /private ?key/ {print $2; exit}')"
  pub="$(printf '%s\n' "$out" | awk -F': *' 'tolower($1) ~ /(public ?key|password)/ {print $2; exit}')"
  if [[ -z "$priv" || -z "$pub" ]]; then
    # старый формат: первая строка приватный, вторая публичный
    priv="$(printf '%s\n' "$out" | sed -n '1p' | awk '{print $NF}')"
    pub="$(printf '%s\n' "$out" | sed -n '2p' | awk '{print $NF}')"
  fi
  [[ -n "$priv" && -n "$pub" ]] || die "Не смог разобрать вывод 'xray x25519': $out"
  printf '%s %s' "$priv" "$pub"
}

gen_uuid() {
  if have xray; then xray uuid
  else python3 -c 'import uuid; print(uuid.uuid4())'
  fi
}

detect_ip() {
  local ip=""
  for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip="$(curl -4 -fsS --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { printf '%s' "$ip"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------- основное ---
if (( DRY_RUN == 0 )); then
  [[ $EUID -eq 0 ]] || die "Запустите от root: sudo bash $0"
  if [[ -f "$CONF" ]] && (( FORCE == 0 )); then
    die "$CONF уже существует — добавьте --force, чтобы перезаписать (старые UUID потеряются)"
  fi
  install_xray
  if ss -ltnp 2>/dev/null | grep -q ":$XRAY_PORT "; then
    warn "Порт TCP/$XRAY_PORT уже занят — REALITY не сможет слушать"
  fi
else
  CONF="$OUT_DIR/config.json"
  mkdir -p "$OUT_DIR"
fi

PUB_IP="$(detect_ip || true)"
[[ -n "$PUB_IP" ]] || PUB_IP="198.51.100.10"

# имена клиентов: --names phone,laptop или client1..clientN
CLIENT_NAMES=()
if [[ -n "$NAMES" ]]; then
  IFS=',' read -r -a CLIENT_NAMES <<<"$NAMES"
  CLIENTS="${#CLIENT_NAMES[@]}"
  for nm in "${CLIENT_NAMES[@]}"; do
    [[ "$nm" =~ ^[a-zA-Z0-9_-]{1,32}$ ]] || die "Некорректное имя клиента: '$nm'"
  done
fi
(( CLIENTS >= 1 )) || die "Нужен хотя бы один клиент (--clients N или --names a,b)"

KEYS_OUT="$(gen_keys)"
PRIV="${KEYS_OUT%% *}"
PUB="${KEYS_OUT##* }"
[[ -n "$PRIV" && -n "$PUB" ]] || die "Ключи REALITY не сгенерированы"

SHORT_ID="$(openssl rand -hex 8)"

UUIDS=()
for _ in $(seq 1 "$CLIENTS"); do
  UUIDS+=("$(gen_uuid)")
done

# --- config.json ---
CLIENTS_JSON=""
n=0
for u in "${UUIDS[@]}"; do
  n=$((n + 1))
  if (( n <= ${#CLIENT_NAMES[@]} )); then
    email="${CLIENT_NAMES[$((n - 1))]}"
  else
    email="client$n"
  fi
  entry=$(printf '{"id":"%s","flow":"xtls-rprx-vision","email":"%s"}' "$u" "$email")
  CLIENTS_JSON="${CLIENTS_JSON:+$CLIENTS_JSON,}$entry"
done

mkdir -p "$(dirname "$CONF")"
cat >"$CONF" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $XRAY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [ $CLIENTS_JSON ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$SNI:443",
          "xver": 0,
          "serverNames": [ "$SNI" ],
          "privateKey": "$PRIV",
          "shortIds": [ "$SHORT_ID" ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
JSON
# xray в официальном systemd-юните работает не от root (User=nobody),
# поэтому конфиг должен быть читаем не только владельцем.
chmod 644 "$CONF"

python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CONF" || die "Сгенерированный JSON невалиден: $CONF"
log "Конфиг Xray: $CONF"

if (( DRY_RUN == 0 )); then
  if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "$XRAY_PORT"/tcp >/dev/null && log "Открыл TCP/$XRAY_PORT в ufw"
  fi
fi

# --- клиентские ссылки ---
mkdir -p "$OUT_DIR"; chmod 700 "$OUT_DIR" 2>/dev/null || true
i=0
for u in "${UUIDS[@]}"; do
  i=$((i + 1))
  if (( i <= ${#CLIENT_NAMES[@]} )); then name="${CLIENT_NAMES[$((i - 1))]}"; else name="client$i"; fi
  link="vless://$u@$PUB_IP:$XRAY_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUB&sid=$SHORT_ID&spx=%2F&type=tcp&headerType=none#vpnbye-$name"
  printf '%s\n' "$link" >"$OUT_DIR/$name.vless.txt"
  chmod 600 "$OUT_DIR/$name.vless.txt"
  FIRST_LINK="${FIRST_LINK:-$OUT_DIR/$name.vless.txt}"
  log "Клиент $name: $OUT_DIR/$name.vless.txt"
done

if (( DRY_RUN == 1 )); then
  log "Готово (dry-run). Конфиг и ссылки в $OUT_DIR"
  cat "$FIRST_LINK"
  exit 0
fi

log "Запускаю Xray"
systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray
sleep 1
systemctl is-active --quiet xray || die "Xray не запустился: journalctl -u xray -n 50 --no-pager"

echo
log "Готово! VLESS+REALITY слушает TCP/$XRAY_PORT, masquerade SNI: $SNI"
echo
echo "Ссылка для клиента (v2rayNG, v2rayN, Hiddify, NekoBox, Streisand, FoXray):"
cat "$FIRST_LINK"
if have qrencode; then
  qrencode -t ansiutf8 <"$FIRST_LINK"
fi
echo
echo "Проверка логов: journalctl -u xray -f"
echo "Проверка конфига: xray -test -config $CONF"

