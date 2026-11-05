#!/usr/bin/env bash
#
# check.sh — самопроверка репозитория без изменения системы.
#   bash scripts/check.sh
#
# Что делает:
#   1. bash -n для всех скриптов (+ shellcheck, если установлен);
#   2. прогоняет все установщики в режиме --dry-run во временный каталог;
#   3. проверяет, что конфиги содержат обязательные поля и валидный JSON;
#   4. проверяет синтаксис docker-compose.
#
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  \033[1;32mOK\033[0m   %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

head_ "1. Синтаксис shell-скриптов"
while IFS= read -r f; do
  if bash -n "$f" 2>"$TMP/err"; then
    ok "bash -n ${f#$ROOT/}"
  else
    bad "bash -n ${f#$ROOT/}: $(cat "$TMP/err")"
  fi
done < <(find "$ROOT" -name '*.sh' -not -path '*/.git/*' | sort)

if command -v shellcheck >/dev/null 2>&1; then
  head_ "1b. shellcheck"
  while IFS= read -r f; do
    if shellcheck -S warning "$f" >"$TMP/sc" 2>&1; then
      ok "shellcheck ${f#$ROOT/}"
    else
      bad "shellcheck ${f#$ROOT/}:"
      sed 's/^/       /' "$TMP/sc" | head -20
    fi
  done < <(find "$ROOT" -name '*.sh' -not -path '*/.git/*' | sort)
fi

head_ "2. WireGuard: dry-run"
WG_OUT="$TMP/wg"
if bash "$ROOT/wireguard/install-wireguard.sh" --dry-run --clients 2 \
     --out "$WG_OUT" --endpoint 203.0.113.10:51820 >"$TMP/wg.log" 2>&1; then
  ok "install-wireguard.sh --dry-run"
  srv="$WG_OUT/server/wg0.conf"
  grep -q '^\[Interface\]' "$srv"              && ok "сервер: секция [Interface]" || bad "сервер: нет [Interface]"
  grep -q '^ListenPort = 51820' "$srv"         && ok "сервер: ListenPort"         || bad "сервер: нет ListenPort"
  grep -q '^PrivateKey = ' "$srv"              && ok "сервер: PrivateKey"         || bad "сервер: нет PrivateKey"
  grep -q 'MASQUERADE' "$srv"                  && ok "сервер: NAT MASQUERADE"     || bad "сервер: нет MASQUERADE"
  [[ "$(grep -c '^\[Peer\]' "$srv")" == "2" ]] && ok "сервер: 2 пира"             || bad "сервер: ожидалось 2 пира"
  for c in client1 client2; do
    cf="$WG_OUT/$c.conf"
    if grep -q '^Endpoint = 203.0.113.10:51820' "$cf" \
       && grep -q "^Address = 10.66.66.$((${c#client} + 1))/32" "$cf" \
       && grep -q '^AllowedIPs = 0.0.0.0/0, ::/0' "$cf"; then
      ok "$c: адрес, endpoint и AllowedIPs"
    else
      bad "$c: некорректный конфиг"
    fi
  done
else
  bad "install-wireguard.sh --dry-run упал:"
  sed 's/^/       /' "$TMP/wg.log" | tail -15
fi


head_ "2b. WireGuard: режим --lan-only (сервер в РФ, доступ к своим сетям)"
WL_OUT="$TMP/wg-lan"
if bash "$ROOT/wireguard/install-wireguard.sh" --dry-run --lan-only --lan 192.168.1.0/24 \
     --clients 1 --out "$WL_OUT" --endpoint 203.0.113.10:51820 >"$TMP/wg-lan.log" 2>&1; then
  ok "install-wireguard.sh --dry-run --lan-only"
  allowed="$(grep '^AllowedIPs' "$WL_OUT/client1.conf" | head -1)"
  [[ "$allowed" == "AllowedIPs = 10.66.66.0/24, 192.168.1.0/24" ]] \
    && ok "клиент: AllowedIPs ограничен туннелем и LAN" || bad "клиент: $allowed"
  grep -q '^DNS = ' "$WL_OUT/client1.conf" \
    && bad "--lan-only не должен навязывать внешний DNS" || ok "DNS не навязан"
  if grep -q 'POSTROUTING -s 10.66.66.0/24 -o .* -j MASQUERADE' "$WL_OUT/server/wg0.conf"; then
    bad "в --lan-only не должно быть NAT в интернет"
  else
    ok "нет NAT в интернет"
  fi
  grep -q -- '-d 192.168.1.0/24 -o' "$WL_OUT/server/wg0.conf" \
    && ok "NAT только в сторону LAN" || bad "нет NAT в сторону LAN"
else
  bad "install-wireguard.sh --lan-only упал:"
  sed 's/^/       /' "$TMP/wg-lan.log" | tail -15
fi

head_ "2c. WireGuard: add-client.sh учитывает режим сервера"
AC="$TMP/ac"
mkdir -p "$AC/stub" "$AC/c-full" "$AC/c-lan"
printf '%s\n' '#!/usr/bin/env bash' \
  'case "$1" in' \
  '  genkey|genpsk|pubkey) openssl rand -base64 32 ;;' \
  '  show) exit 1 ;;' \
  '  *) exit 1 ;;' \
  'esac' >"$AC/stub/wg"
chmod +x "$AC/stub/wg"
cp "$WG_OUT/server/wg0.conf" "$AC/full.conf"
bash "$ROOT/wireguard/install-wireguard.sh" --dry-run --lan-only --lan 192.168.1.0/24 \
  --clients 1 --out "$AC/lansrv" --endpoint 203.0.113.10:51820 >/dev/null 2>&1 || true
cp "$AC/lansrv/server/wg0.conf" "$AC/lan.conf" 2>/dev/null || true

ac_run() { PATH="$AC/stub:$PATH" WG_CONF="$1" OUT_DIR="$2" \
           bash "$ROOT/wireguard/add-client.sh" "$3" >/dev/null 2>&1; }

if ac_run "$AC/full.conf" "$AC/c-full" laptop && [[ -f "$AC/c-full/laptop.conf" ]]; then
  grep -q '^AllowedIPs = 0.0.0.0/0, ::/0$' "$AC/c-full/laptop.conf" \
    && grep -q '^DNS = ' "$AC/c-full/laptop.conf" \
    && ok "full-режим: полный туннель + DNS" || bad "full-режим: неверный клиентский конфиг"
else
  bad "add-client.sh не отработал в full-режиме"
fi

if ac_run "$AC/lan.conf" "$AC/c-lan" phone && [[ -f "$AC/c-lan/phone.conf" ]]; then
  if grep -q '^AllowedIPs = 10.66.66.0/24, 192.168.1.0/24$' "$AC/c-lan/phone.conf" \
     && ! grep -q '^DNS = ' "$AC/c-lan/phone.conf"; then
    ok "lan-only: только туннель и LAN, DNS не навязан"
  else
    bad "lan-only: неверный клиентский конфиг: $(grep -E '^(DNS|AllowedIPs)' "$AC/c-lan/phone.conf" | tr '\n' ' ')"
  fi
else
  bad "add-client.sh не отработал в режиме --lan-only"
fi

head_ "3. AmneziaWG: dry-run"
AWG_OUT="$TMP/awg"
if bash "$ROOT/amneziawg/install-amneziawg.sh" --dry-run --clients 1 \
     --out "$AWG_OUT" --endpoint 203.0.113.10:51820 >"$TMP/awg.log" 2>&1; then
  ok "install-amneziawg.sh --dry-run"
  cf="$AWG_OUT/client1.conf"
  missing=""
  for k in Jc Jmin Jmax S1 S2 H1 H2 H3 H4; do
    grep -q "^$k = " "$cf" || missing="$missing $k"
  done
  [[ -z "$missing" ]] && ok "клиент: все параметры обфускации на месте" \
                      || bad "клиент: не хватает:$missing"
  if python3 - "$cf" <<'PY'
import re, sys
cfg = open(sys.argv[1]).read()
def g(k):
    m = re.search(rf'^{k} = (\d+)$', cfg, re.M)
    return int(m.group(1)) if m else None
H1, H2, H3, H4 = g('H1'), g('H2'), g('H3'), g('H4')
S1, S2, Jmin, Jmax = g('S1'), g('S2'), g('Jmin'), g('Jmax')
assert all(v is not None for v in (H1, H2, H3, H4, S1, S2, Jmin, Jmax)), 'не все параметры найдены'
assert len({H1, H2, H3, H4}) == 4, 'H1..H4 должны быть уникальны'
assert H4 > H1 + H2 + H3, f'H4 ({H4}) должен быть больше H1+H2+H3 ({H1+H2+H3})'
assert S1 + 56 != S2, 'S1+56 не должен равняться S2'
assert S1 > 0 and S2 > 0, 'S1/S2 должны быть > 0'
assert Jmin < Jmax, 'Jmin должен быть меньше Jmax'
PY
  then ok "клиент: параметры обфускации согласованы"
  else bad "клиент: параметры обфускации нарушают правила протокола"; fi
else
  bad "install-amneziawg.sh --dry-run упал:"
  sed 's/^/       /' "$TMP/awg.log" | tail -15
fi

head_ "4. Xray REALITY: dry-run"
XR_OUT="$TMP/xray"
if bash "$ROOT/xray/install-xray-reality.sh" --dry-run --clients 2 \
     --out "$XR_OUT" >"$TMP/xr.log" 2>&1; then
  ok "install-xray-reality.sh --dry-run"
  cfg="$XR_OUT/config.json"
  if python3 - "$cfg" <<'PY'
import json, sys, re
c = json.load(open(sys.argv[1]))
ib = c['inbounds'][0]
assert ib['protocol'] == 'vless', 'протокол должен быть vless'
ss = ib['streamSettings']
assert ss['security'] == 'reality', 'security должно быть reality'
assert ss['network'] == 'tcp', 'network должен быть tcp'
rs = ss['realitySettings']
assert rs['dest'].endswith(':443'), 'dest должен указывать на порт 443'
assert rs['privateKey'], 'нет privateKey'
assert rs['serverNames'], 'нет serverNames'
assert rs['shortIds'], 'нет shortIds'
assert len(ib['settings']['clients']) == 2, 'ожидалось 2 клиента'
for cl in ib['settings']['clients']:
    assert re.fullmatch(r'[0-9a-f-]{36}', cl['id']), f"некорректный UUID: {cl['id']}"
    assert cl['flow'] == 'xtls-rprx-vision', 'flow должен быть xtls-rprx-vision'
PY
  then ok "config.json валиден и соответствует схеме VLESS+REALITY"
  else bad "config.json не проходит проверку"; fi
  if grep -Eq '^vless://[0-9a-f-]{36}@[0-9.]+:443\?[^ ]*flow=xtls-rprx-vision&security=reality' \
       "$XR_OUT/client1.vless.txt"; then
    ok "ссылка client1.vless.txt корректного формата"
  else
    bad "ссылка client1.vless.txt некорректна: $(cat "$XR_OUT/client1.vless.txt" 2>/dev/null)"
  fi
else
  bad "install-xray-reality.sh --dry-run упал:"
  sed 's/^/       /' "$TMP/xr.log" | tail -15
fi

head_ "5. docker-compose"
dc="$ROOT/docker/wg-easy/docker-compose.yml"
if [[ -f "$dc" ]]; then
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    if (cd "$(dirname "$dc")" && cp .env.example .env && docker compose config -q); then
      ok "docker compose config"
    else
      bad "docker compose config"
    fi
    rm -f "$(dirname "$dc")/.env"
  elif python3 -c 'import yaml' 2>/dev/null; then
    if python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$dc"; then
      ok "YAML синтаксис docker-compose.yml"
    else
      bad "YAML синтаксис docker-compose.yml"
    fi
  else
    printf '  \033[1;33mSKIP\033[0m нет docker и PyYAML — пропускаю\n'
  fi
fi

head_ "6. Xray: добавление и отзыв клиента"
XT="$TMP/xt"
mkdir -p "$XT/stub" "$XT/clients"
if [[ -f "$XR_OUT/config.json" ]]; then
  cp "$XR_OUT/config.json" "$XT/cfg.json"
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [[ "$1" == x25519 && "$2" == -i ]]; then' \
    '  echo "PrivateKey: stubpriv"' \
    '  echo "Password: stubpublickey123"' \
    '  exit 0' \
    'fi' \
    'exit 1' >"$XT/stub/xray"
  chmod +x "$XT/stub/xray"

  xt_run() { PATH="$XT/stub:$PATH" XRAY_CONF="$XT/cfg.json" OUT_DIR="$XT/clients" \
             bash "$ROOT/xray/add-client.sh" "$@" 2>/dev/null; }
  emails() { python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print(",".join(x["email"] for x in c["inbounds"][0]["settings"]["clients"]))' "$XT/cfg.json"; }

  if xt_run phone >/dev/null; then
    [[ "$(emails)" == "client1,client2,phone" ]] && ok "клиент phone добавлен в JSON" || bad "ожидались client1,client2,phone, получено: $(emails)"
    grep -q '^vless://.*#vpnbye-phone$' "$XT/clients/phone.vless.txt" 2>/dev/null \
      && ok "ссылка для phone создана" || bad "ссылка для phone не создана"
  else
    bad "add-client.sh phone завершился ошибкой"
  fi

  if xt_run phone >/dev/null; then bad "повторное добавление того же имени должно падать"; else ok "повторное добавление отклонено"; fi

  if xt_run phone --revoke >/dev/null; then
    [[ "$(emails)" == "client1,client2" ]] && ok "клиент phone отозван" || bad "после отзыва получено: $(emails)"
    [[ -f "$XT/clients/phone.vless.txt" ]] && bad "файл ссылки отозванного клиента остался" || ok "файл ссылки удалён"
  else
    bad "add-client.sh phone --revoke завершился ошибкой"
  fi

  xt_run client1 --revoke >/dev/null
  if xt_run client2 --revoke >/dev/null; then bad "нельзя удалять последнего клиента"; else ok "удаление последнего клиента заблокировано"; fi
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$XT/cfg.json" \
    && ok "config.json остаётся валидным JSON" || bad "config.json сломан"
else
  bad "нет $XR_OUT/config.json — пропускаю тест add-client.sh"
fi

head_ "Итог"
printf '  пройдено: %s, провалено: %s\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
printf '\033[1;32mВсе проверки прошли\033[0m\n'
