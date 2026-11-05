#!/usr/bin/env bash
#
# add-client.sh — добавить или отозвать клиента VLESS+REALITY на настроенном сервере.
#
#   sudo bash add-client.sh phone            # новый UUID + ссылка + QR
#   sudo bash add-client.sh phone --revoke   # убрать UUID из конфига
#
# Конфиг правится через python3 (валидный JSON), затем Xray перезапускается —
# остальные подключения восстановятся автоматически за пару секунд.
#
set -Eeuo pipefail

CONF="${XRAY_CONF:-/usr/local/etc/xray/config.json}"
OUT_DIR="${OUT_DIR:-/root/xray-clients}"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

NAME="${1:-}"
REVOKE=0
[[ "${2:-}" == "--revoke" ]] && REVOKE=1

[[ -n "$NAME" ]] || die "Укажите имя клиента: add-client.sh phone [--revoke]"
[[ "$NAME" =~ ^[a-zA-Z0-9_-]{1,32}$ ]] || die "Имя: только a-z, A-Z, 0-9, _ и - (до 32 символов)"
[[ "$CONF" == /*etc/* && $EUID -ne 0 ]] && die "Запустите от root: sudo bash $0 $*"
[[ -f "$CONF" ]] || die "Не найден $CONF — сначала запустите install-xray-reality.sh"
have python3 || die "Нужен python3: apt install -y python3"

# --- значения из текущего конфига ---
mapfile -t CFG < <(python3 - "$CONF" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
ib = c['inbounds'][0]
rs = ib['streamSettings']['realitySettings']
print(rs['privateKey'])
print(rs['serverNames'][0])
print(rs['shortIds'][0] if rs['shortIds'] else '')
print(ib['port'])
PY
)
PRIV="${CFG[0]:-}"; SNI="${CFG[1]:-}"; SID="${CFG[2]:-}"; PORT="${CFG[3]:-443}"
[[ -n "$PRIV" && -n "$SNI" ]] || die "Не смог прочитать privateKey/serverNames из $CONF"

if (( REVOKE == 1 )); then
  python3 - "$CONF" "$NAME" <<'PY' || exit 1
import json, sys
path, name = sys.argv[1], sys.argv[2]
c = json.load(open(path))
clients = c['inbounds'][0]['settings']['clients']
left = [x for x in clients if x.get('email') != name]
if len(left) == len(clients):
    sys.exit(f"Клиент {name!r} не найден в конфиге")
if not left:
    sys.exit("Нельзя удалить последнего клиента — иначе вход станет невозможен")
c['inbounds'][0]['settings']['clients'] = left
json.dump(c, open(path, 'w'), indent=2, ensure_ascii=False)
open(path, 'a').write('\n')
print(f"Удалено UUID: {len(clients) - len(left)}")
PY
  chmod 644 "$CONF"
  rm -f "$OUT_DIR/$NAME.vless.txt" "$OUT_DIR/$NAME.png"
  systemctl restart xray 2>/dev/null || true
  log "Клиент $NAME отозван"
  exit 0
fi

# --- новый клиент ---
NEW_ID="$(python3 - "$CONF" "$NAME" <<'PY'
import json, sys, uuid
path, name = sys.argv[1], sys.argv[2]
c = json.load(open(path))
clients = c['inbounds'][0]['settings']['clients']
if any(x.get('email') == name for x in clients):
    sys.exit(f"Клиент {name!r} уже есть в конфиге")
new_id = str(uuid.uuid4())
clients.append({"id": new_id, "flow": "xtls-rprx-vision", "email": name})
json.dump(c, open(path, 'w'), indent=2, ensure_ascii=False)
open(path, 'a').write('\n')
print(new_id)
PY
)" || die "Не удалось добавить клиента в $CONF"

chmod 644 "$CONF"

# публичный ключ REALITY из приватного
if have xray; then
  keys="$(xray x25519 -i "$PRIV" 2>/dev/null || true)"
  PUB="$(printf '%s\n' "$keys" | awk -F': *' 'tolower($1) ~ /(public ?key|password)/ {print $2; exit}')"
  [[ -n "$PUB" ]] || PUB="$(printf '%s\n' "$keys" | sed -n '2p' | awk '{print $NF}')"
  [[ -n "$PUB" ]] || die "Не смог получить публичный ключ: xray x25519 -i (проверьте версию Xray)"
else
  PUB="PUBLIC_KEY_НЕ_ОПРЕДЕЛЁН"
fi

IP="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
IP="${IP:-IP_СЕРВЕРА}"

link="vless://$NEW_ID@$IP:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUB&sid=$SID&spx=%2F&type=tcp&headerType=none#vpnbye-$NAME"

mkdir -p "$OUT_DIR"; chmod 700 "$OUT_DIR" 2>/dev/null || true
printf '%s\n' "$link" >"$OUT_DIR/$NAME.vless.txt"
chmod 600 "$OUT_DIR/$NAME.vless.txt"

systemctl restart xray 2>/dev/null || warn_restart=1
if [[ "${warn_restart:-0}" == "1" ]]; then
  printf '\033[1;33m[!]\033[0m %s\n' "Не удалось перезапустить Xray — сделайте это вручную: systemctl restart xray" >&2
fi

log "Клиент $NAME добавлен: $OUT_DIR/$NAME.vless.txt"
echo "$link"
if have qrencode; then qrencode -t ansiutf8 <"$OUT_DIR/$NAME.vless.txt"; fi
