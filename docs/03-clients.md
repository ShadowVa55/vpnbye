# 3. Подключение клиентов

## WireGuard (файлы `client*.conf` из `~/wg-clients/`)

| Платформа | Приложение | Как импортировать |
|---|---|---|
| iOS | WireGuard (App Store, бесплатно) | «+» → «Создать из QR-кода» → сканировать `client1.png` |
| Android | WireGuard (Google Play / F-Droid) | «+» → «Сканировать QR-код» |
| Windows | WireGuard for Windows | «Add Tunnel» → «Import tunnel(s) from file» → `client1.conf` |
| macOS | WireGuard (App Store) | «+» → «Импорт туннеля из файла» |
| Linux | `sudo apt install wireguard` | `sudo cp client1.conf /etc/wireguard/wg0.conf && sudo wg-quick up wg0` |
| Роутер Keenetic | «WireGuard VPN» в веб-интерфейсе | загрузить `.conf` |
| OpenWrt | `opkg install wireguard-tools` | тот же `.conf` в `/etc/wireguard/` |

Проверка: в приложении должен появиться «Последнее рукопожатие» (latest handshake)
и счётчик трафика. На сервере — `wg show`.

## AmneziaWG

Один и тот же клиент — приложение **AmneziaVPN** (Windows, macOS, Linux, Android, iOS):

1. «Я хочу настроить свой VPN» → «Добавить сервер вручную».
2. Протокол — **AmneziaWG**.
3. Поля: IP сервера, порт, приватный ключ, публичный ключ сервера, адрес клиента
   (например `10.8.1.2`) — всё есть в `client1.conf`.
4. Либо проще: в приложении «Добавить сервер» → «Импорт из файла»/QR и выбрать
   `client1.conf` — параметры обфускации (Jc, Jmin, Jmax, S1, S2, H1–H4) подставятся сами.

## VLESS + REALITY

Ссылка выглядит так:

```
vless://UUID@IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=ПУБЛИЧНЫЙ_КЛЮЧ&sid=SHORTID&spx=%2F&type=tcp#vpnbye-1
```

| Платформа | Приложение | Как импортировать |
|---|---|---|
| Android | v2rayNG, NekoBox, Hiddify | «+» → «Импорт из буфера обмена» или скрин QR |
| iOS | Streisand, FoXray, Hiddify | то же (бесплатных в RU App Store может не быть — нужен зарубежный Apple ID) |
| Windows | Hiddify, v2rayN, NekoRay | Ctrl+V в окне приложения |
| macOS | Hiddify, FoXray | вставить ссылку |
| Linux | Hiddify, nekoray, xray-core | `xray run -c client.json` (тот же inbound/outbound) |

Импорт ссылки — самый удобный путь: ничего вручную не переносите.

## Полезные советы

* **Kill switch.** В WireGuard-клиентах для Android/iOS включите «Block non-tunnel
  traffic» / «On-demand», чтобы при обрыве трафик не уходил в открытую сеть.
* **Split tunneling.** `AllowedIPs = 0.0.0.0/0` — весь трафик в VPN.
  Нужен доступ только к домашней сети? Замените на `AllowedIPs = 192.168.1.0/24`.
* **Один конфиг = один человек.** Не передавайте друзьям свой `client1.conf`:
  у каждого должен быть свой пир (в WG это `add-client.sh`, у Xray — свой UUID),
  иначе невозможно отозвать доступ без «перевыпуска» всем.
* **MTU.** Если сайты открываются «наполовину» (страница грузится, картинки нет) —
  уменьшите `MTU` в конфиге клиента: 1420 → 1380 → 1280.
