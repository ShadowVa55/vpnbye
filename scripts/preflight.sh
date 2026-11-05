#!/usr/bin/env bash
#
# preflight.sh — проверка «готов ли сервер к работе с клиентами из России».
# Только читает, ничего не меняет в системе.
#
#   sudo bash scripts/preflight.sh            # полный отчёт
#   bash scripts/preflight.sh --quiet         # только WARN/FAIL
#   bash scripts/preflight.sh --strict        # exit 1, если есть FAIL
#
# Проверяет: часы (критично для REALITY), ip_forward, NAT, слушающие порты,
# сервисы wg/awg/xray, валидность конфигов, доступность сайта-прикрытия,
# внешний IP, PMTU, последние рукопожатия клиентов, firewall.
#
set -uo pipefail

QUIET=0
STRICT=0
for a in "$@"; do
  case "$a" in
    --quiet|-q) QUIET=1 ;;
    --strict)   STRICT=1 ;;
    -h|--help)  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Неизвестная опция: $a" >&2; exit 2 ;;
  esac
done

OK=0; WARN=0; FAIL=0
has()  { command -v "$1" >/dev/null 2>&1; }
ok()   { OK=$((OK+1));   (( QUIET == 1 )) || printf '  \033[1;32mOK\033[0m    %s\n' "$*"; }
wrn()  { WARN=$((WARN+1)); printf '  \033[1;33mWARN\033[0m  %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; }
sect() { (( QUIET == 1 )) || printf '\n\033[1m%s\033[0m\n' "$*"; }
# текстовый вывод без счётчиков (только в полном режиме)
info() { (( QUIET == 1 )) || printf '        %s\n' "$*"; }

WG_CONF="${WG_CONF:-}"
AWG_CONF="${AWG_CONF:-}"
WG_DIR="${WG_DIR:-/etc/wireguard}"
AWG_DIR="${AWG_DIR:-/etc/amnezia/amneziawg}"
XRAY_CONF="${XRAY_CONF:-/usr/local/etc/xray/config.json}"

# находим все интерфейсы (может быть и wg0, и awg0, и awg1 — оркестратор поднимает несколько)
shopt -s nullglob
if [[ -n "$WG_CONF" && -f "$WG_CONF" ]]; then WG_CONFS=("$WG_CONF"); else WG_CONFS=("$WG_DIR"/*.conf); fi
if [[ -n "$AWG_CONF" && -f "$AWG_CONF" ]]; then AWG_CONFS=("$AWG_CONF"); else AWG_CONFS=("$AWG_DIR"/*.conf); fi
shopt -u nullglob

# ------------------------------------------------------------------ система ---
sect "1. Система"
info "ОС: $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-?}")  ядро: $(uname -r)"
mem_mb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 ))
if (( mem_mb >= 400 )); then ok "память ${mem_mb} МБ"; else wrn "памяти всего ${mem_mb} МБ — может не хватить"; fi
diskw=$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}')
if [[ -n "${diskw:-}" ]] && (( diskw > 500 )); then ok "свободно на / ${diskw} МБ"; else wrn "мало места на / (${diskw:-?} МБ)"; fi

sect "2. Часы (REALITY и TLS ломаются при расхождении > 30 c)"
if has curl; then
  remote_date="$(curl -fsSI --max-time 8 https://www.google.com 2>/dev/null \
                  | awk -F': ' 'tolower($1)=="date" {print $2}' | tr -d '\r')"
  if [[ -n "$remote_date" ]]; then
    remote_ts="$(date -u -d "$remote_date" +%s 2>/dev/null || echo '')"
    local_ts="$(date -u +%s)"
    if [[ -n "$remote_ts" ]]; then
      diff=$(( local_ts - remote_ts )); abs=${diff#-}
      if (( abs <= 30 )); then
        ok "расхождение с точным временем ${diff} c"
      else
        bad "часы расходятся на ${diff} c — включите синхронизацию: systemctl enable --now systemd-timesyncd"
      fi
    else
      wrn "не смог разобрать дату из ответа google: $remote_date"
    fi
  else
    wrn "нет ответа от google (нет выхода в интернет?)"
  fi
else
  wrn "нет curl — проверка часов пропущена"
fi

sect "3. Маршрутизация и NAT"
fwd="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '?')"
[[ "$fwd" == "1" ]] && ok "net.ipv4.ip_forward = 1" || bad "net.ipv4.ip_forward = ${fwd} — туннель не выпустит трафик в интернет"
if has iptables; then
  nat_rules="$(iptables -t nat -S POSTROUTING 2>/dev/null | grep -c MASQUERADE || true)"
  if (( nat_rules > 0 )); then ok "правил MASQUERADE: ${nat_rules}"; else wrn "нет правил MASQUERADE — клиенты не выйдут в интернет (норма для --lan-only)"; fi
  if iptables -t nat -S POSTROUTING 2>/dev/null | grep -q -- '-d .*/'; then
    info "ограничения по адресату есть — похоже на режим --lan-only"
  fi
else
  wrn "нет iptables — проверка NAT пропущена"
fi

# --------------------------------------------------------------- сервисы ---
sect "4. WireGuard / AmneziaWG"
ports=()
if (( ${#WG_CONFS[@]} == 0 )); then
  info "WireGuard не настроен (${WG_DIR}/*.conf отсутствует)"
fi
for conf in "${WG_CONFS[@]}"; do
  iface="$(basename "$conf" .conf)"
  port="$(awk -F' = ' '/^ListenPort/ {print $2; exit}' "$conf")"
  ok "WireGuard: $conf (порт ${port:-?})"
  [[ -n "$port" ]] && ports+=("$port")
  if systemctl is-active --quiet "wg-quick@$iface" 2>/dev/null; then
    ok "сервис wg-quick@$iface активен"
    if has wg; then
      info "пиров: $(wg show "$iface" peers 2>/dev/null | wc -l)"
      now="$(date +%s)"; stale=0
      while read -r _pub hs; do
        [[ -z "${hs:-}" || "$hs" == "0" ]] && continue
        (( now - hs > 300 )) && stale=$((stale+1))
      done < <(wg show "$iface" latest-handshakes 2>/dev/null)
      (( stale == 0 )) && ok "$iface: у активных пиров свежее рукопожатие" \
                       || wrn "$iface: пиров без рукопожатия > 5 мин: ${stale} (клиент не подключается?)"
    fi
  else
    bad "сервис wg-quick@$iface не активен: journalctl -u wg-quick@$iface -n 30"
  fi
done

if (( ${#AWG_CONFS[@]} == 0 )); then
  info "AmneziaWG не настроен (${AWG_DIR}/*.conf отсутствует)"
fi
for conf in "${AWG_CONFS[@]}"; do
  iface="$(basename "$conf" .conf)"
  port="$(awk -F' = ' '/^ListenPort/ {print $2; exit}' "$conf")"
  ok "AmneziaWG: $conf (порт ${port:-?})"
  [[ -n "$port" ]] && ports+=("$port")
  if systemctl is-active --quiet "awg-quick@$iface" 2>/dev/null; then
    ok "сервис awg-quick@$iface активен"
  else
    bad "сервис awg-quick@$iface не активен: journalctl -u awg-quick@$iface -n 30"
  fi
  if has awg; then
    hs="$(awg show "$iface" latest-handshakes 2>/dev/null | awk '$2>0 {print $2}' | sort -n | tail -1)"
    if [[ -n "$hs" ]]; then
      age=$(( $(date +%s) - hs ))
      (( age < 300 )) && ok "$iface: недавнее рукопожатие (${age} c назад)" \
                      || wrn "$iface: последнее рукопожатие ${age} c назад — клиенты не проходят DPI?"
    else
      wrn "$iface: рукопожатий ещё не было (клиенты не подключались)"
    fi
  fi
done

sect "5. Слушающие порты"
if (( ${#ports[@]} > 0 )); then
  # убираем дубликаты
  mapfile -t ports < <(printf '%s\n' "${ports[@]}" | sort -un)
fi
if has ss; then
  for p in "${ports[@]:-}"; do
    [[ -z "$p" ]] && continue
    if ss -lun 2>/dev/null | grep -q ":${p} "; then ok "UDP/${p} слушается"; else wrn "UDP/${p} не слушается"; fi
  done
  if ss -ltn 2>/dev/null | grep -q ':443 '; then ok "TCP/443 слушается"; else info "TCP/443 не слушается (норма, если Xray не используется)"; fi
else
  wrn "нет ss (iproute2) — проверка портов пропущена"
fi

# ------------------------------------------------------------------ xray ---
sect "6. Xray VLESS+REALITY"
if [[ -f "$XRAY_CONF" ]]; then
  ok "конфиг найден: $XRAY_CONF"
  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$XRAY_CONF" 2>/dev/null; then
    ok "JSON валиден"
  else
    bad "JSON невалиден — xray не запустится"
  fi
  if has xray; then
    if xray -test -config "$XRAY_CONF" >/dev/null 2>&1; then ok "xray -test прошёл"; else bad "xray -test не прошёл: xray -test -config $XRAY_CONF"; fi
    info "версия: $(xray version 2>/dev/null | head -1)"
  fi
  if systemctl is-active --quiet xray 2>/dev/null; then ok "сервис xray активен"; else bad "сервис xray не активен: journalctl -u xray -n 30"; fi
  sni="$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print(c["inbounds"][0]["streamSettings"]["realitySettings"]["serverNames"][0])' "$XRAY_CONF" 2>/dev/null || echo '')"
  if [[ -n "$sni" ]]; then
    if has curl; then
      code="$(curl -fsSI --max-time 8 "https://$sni" -o /dev/null -w '%{http_code}' 2>/dev/null || echo '000')"
      case "$code" in
        2*|3*|4*) ok "сайт-прикрытие $sni отвечает (HTTP $code)" ;;
        000) bad "сайт-прикрытие $sni недоступен с сервера — REALITY не заработает, выберите другой --sni" ;;
        *) wrn "сайт-прикрытие $sni ответил HTTP $code — проверьте, что это обычный сайт с TLS 1.3" ;;
      esac
    fi
    if has openssl; then
      if echo | timeout 8 openssl s_client -connect "$sni:443" -tls1_3 -alpn h2 -servername "$sni" 2>/dev/null \
           | grep -q 'ALPN protocol: h2'; then
        ok "$sni поддерживает TLS 1.3 + HTTP/2 (то, что нужно REALITY)"
      else
        wrn "$sni: не подтвердились TLS 1.3 + h2 — REALITY может работать нестабильно"
      fi
    fi
  fi
else
  info "Xray не настроен ($XRAY_CONF отсутствует)"
fi


# ------------------------------------------------------------ сеть и PMTU ---
sect "7. Внешний IP и связность"
if has curl; then
  ext="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || echo '')"
  if [[ -n "$ext" ]]; then
    ok "внешний IPv4: $ext"
    info "убедитесь, что клиенты в РФ видят именно этот адрес и он не в чёрных списках"
  else
    bad "не удалось определить внешний IPv4 (нет выхода в интернет?)"
  fi
else
  wrn "нет curl — проверка внешнего IP пропущена"
fi

if has ping; then
  if ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then ok "ICMP до 1.1.1.1 проходит"; else wrn "ICMP заблокирован (часто нормально, но проверьте связь)"; fi
  # максимальный размер пакета без фрагментации: 1472 = 1500 - 20(IP) - 8(ICMP)
  pmtu=0
  for sz in 1472 1452 1412 1372 1332 1292 1252; do
    if ping -c1 -W2 -M do -s "$sz" 1.1.1.1 >/dev/null 2>&1; then pmtu=$((sz + 28)); break; fi
  done
  if (( pmtu > 0 )); then
    ok "PMTU до 1.1.1.1 ≈ ${pmtu} байт"
    if (( pmtu < 1400 )); then
      wrn "узкий MTU: для клиентов ставьте MTU = $((pmtu - 80)) вместо 1420"
    fi
  else
    wrn "не удалось определить PMTU (ICMP закрыт) — при проблемах с сайтами уменьшайте MTU клиента"
  fi
else
  wrn "нет ping — проверка PMTU пропущена"
fi

sect "8. Firewall"
if has ufw; then
  if ufw status 2>/dev/null | grep -q '^Status: active'; then
    ok "ufw активен"
    for p in "$wg_port" "$awg_port"; do
      ufw status 2>/dev/null | grep -q "^${p}/udp" && ok "в ufw открыт ${p}/udp" || wrn "в ufw не открыт ${p}/udp"
    done
    [[ -f "$XRAY_CONF" ]] && { ufw status 2>/dev/null | grep -q '^443/tcp' && ok "в ufw открыт 443/tcp" || wrn "в ufw не открыт 443/tcp"; }
  else
    info "ufw установлен, но не активен — порты должны быть открыты у хостера"
  fi
else
  info "ufw не установлен"
fi

# -------------------------------------------------------------------- итог ---
(( QUIET == 1 )) || printf '\n\033[1mИтог\033[0m\n'
printf '  OK: %s, WARN: %s, FAIL: %s\n' "$OK" "$WARN" "$FAIL"
if (( FAIL > 0 )); then
  printf '\033[1;31mЕсть проблемы, которые сломают подключение — см. FAIL выше\033[0m\n'
elif (( WARN > 0 )); then
  printf '\033[1;33mРаботает, но есть замечания — обычно это и есть причина «то работает, то нет»\033[0m\n'
else
  printf '\033[1;32mВсё в порядке\033[0m\n'
fi
(( STRICT == 1 && FAIL > 0 )) && exit 1
exit 0

