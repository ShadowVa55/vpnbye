# vpnbye — свой VPN на своём сервере

Поднимаем **личный VPN** на обычном VPS за 3–5 €/мес: без подписок, лимитов
и «доверия» чужому оператору. Три варианта на выбор, каждый ставится одним скриптом.

```
wireguard/        WireGuard — быстро и просто
amneziawg/        AmneziaWG — тот же WireGuard, но с обфускацией (обход DPI)
xray/             VLESS + REALITY — маскировка под обычный HTTPS
docker/wg-easy/   WireGuard с веб-панелью и QR-кодами
docs/             выбор протокола, сервер, клиенты, диагностика, сервер в РФ
scripts/check.sh  самопроверка всего репозитория
```

## Быстрый старт (10 минут)

**1. Купите VPS** — 1 vCPU / 1 ГБ / 10 ГБ, локация NL, DE, FI или SE.
Подойдёт Hetzner, Aeza, 4vps, Vultr. Подробнее: [docs/02-vps.md](docs/02-vps.md).

**2. Зайдите на сервер по SSH и клонируйте репозиторий:**

```bash
ssh root@ВАШ_IP
apt update && apt install -y git
git clone https://github.com/ShadowVa55/vpnbye.git
cd vpnbye
```

**3. Выберите вариант и запустите установку:**

```bash
# A. WireGuard — если провайдер не мешает VPN
sudo bash wireguard/install-wireguard.sh --clients 2

# B. AmneziaWG — если WireGuard блокируется (РФ, мобильные операторы)
sudo bash amneziawg/install-amneziawg.sh --clients 2 --port 443

# C. Xray REALITY — максимальная незаметность
sudo bash xray/install-xray-reality.sh --names phone,laptop
```

**4. Заберите клиентский конфиг.** Скрипт покажет QR-код прямо в терминале
и сохранит файлы в `~/wg-clients/`, `~/awg-clients/` или `~/xray-clients/`.
Импортируйте их в приложение — [docs/03-clients.md](docs/03-clients.md).

Не знаете, что выбрать? → [docs/01-choose-protocol.md](docs/01-choose-protocol.md)

## Если сервер будет в России

Сразу важное: VPN-сервер **в РФ не обходит блокировки РКН** — трафик всё равно
выходит через российского провайдера, просто в шифрованном виде. Зато он хорошо
решает другие задачи: доступ к домашней/офисной сети, шифрование в чужом Wi-Fi,
российский IP из-за границы (банки, Госуслуги).

```bash
# только свои сети, интернет идёт напрямую (для сервера в РФ это то, что нужно)
sudo bash wireguard/install-wireguard.sh --lan-only --lan 192.168.1.0/24 --clients 2
```

Для обхода блокировок сервер нужен **за границей** (NL/DE/FI/SE) + AmneziaWG или
REALITY. Разбор обоих сценариев, юридических нюансов и выбора хостера:
[docs/05-server-in-russia.md](docs/05-server-in-russia.md)

## Что умеют скрипты

* определяют ОС и ставят нужные пакеты (Debian 11+/Ubuntu 20.04+);
* генерируют ключи (`wg genkey`, `xray uuid`/`xray x25519`), адреса и параметры обфускации;
* включают `ip_forward` и NAT через внешний интерфейс;
* открывают порт в `ufw`, если он включён;
* запускают systemd-сервис с автозапуском (`wg-quick@wg0`, `awg-quick@awg0`, `xray`);
* выдают клиентские конфиги с правами `600` + QR-коды;
* поддерживают `--dry-run` — можно посмотреть результат, ничего не меняя в системе.

Добавление и отзыв клиентов «на живую», без разрыва остальных подключений:

```bash
sudo bash wireguard/add-client.sh laptop           # добавить пир
sudo bash wireguard/add-client.sh laptop --revoke  # отозвать пир

sudo bash xray/add-client.sh phone                 # новый UUID + ссылка + QR
sudo bash xray/add-client.sh phone --revoke        # убрать UUID из конфига
```

## Проверка проекта

```bash
make check      # bash -n, shellcheck (если есть), dry-run всех установщиков,
                # валидация JSON-конфига Xray и YAML docker-compose
make wg-dry     # примеры конфигов в ./out/wg
```

## Вариант с веб-панелью

```bash
cd docker/wg-easy
cp .env.example .env     # при желании поменять порты / INSECURE
docker compose up -d     # панель на http://IP:51821 — создать администратора при первом входе
```

Это wg-easy v15: панель сама создаёт клиентов, отдаёт конфиги и QR-коды.
Для постоянного использования закройте её за reverse-proxy с TLS (`INSECURE=false`).

## Обслуживание

```bash
wg show                                        # кто подключён и сколько скачал
systemctl status wg-quick@wg0                  # состояние сервиса
journalctl -u wg-quick@wg0 -n 50 --no-pager    # логи
```

Резервная копия — это буквально два каталога:
`/etc/wireguard/`, `/usr/local/etc/xray/` (плюс ваши клиентские файлы).

## Диагностика проблем

* Подключается, но интернета нет → NAT/`ip_forward`/имя интерфейса.
* Handshake не появляется → порт закрыт или провайдер режет UDP.
* Работает пару минут и рвётся → DPI распознал WireGuard, переходите на AmneziaWG.

Полный разбор: [docs/04-troubleshooting.md](docs/04-troubleshooting.md)

## Лицензия и ответственность

Скрипты — для личного использования. Перед запуском на «чужом» сервере убедитесь,
что использование VPN и обхода блокировок не нарушает правила хостера и законы
вашей страны. Ключи, которые генерируют скрипты, — это доступ к вашему серверу:
не публикуйте их.

