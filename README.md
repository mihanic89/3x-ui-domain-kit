# 3x-ui-domain-kit

Установщик VPN-сервера на панели [3X-UI](https://github.com/MHSanaei/3x-ui): **работает по домену**, на самом домене показывает **заглушку «Nextcloud»**, весь TCP-трафик идёт через nginx на порту 443, а каждому пользователю выдаётся **одна подписка на все протоколы**.

> [!WARNING]
> Код проверен только на синтаксис, на реальном сервере он ещё не запускался. Первый запуск делайте на тестовом VPS.

---

## Что делает

- Ставит панель 3X-UI (версия закреплена), ядро Xray и четыре протокола: VLESS REALITY, XHTTP, VLESS WebSocket (всё TCP на 443 через nginx) и Hysteria2 (UDP 443).
- Выпускает сертификат Let's Encrypt **на ваш домен** (acme.sh) и сам продлевает его; после продления перезагружает nginx и x-ui.
- Ставит nginx: на 443 он разводит трафик по SNI и секретным путям. Любой заход на домен без секретного пути получает заглушку Nextcloud (страница входа, ошибка при логине, `/status.php`, `robots.txt`, 404 в стиле Nextcloud).
- Кладёт в панель серверные правила маршрутизации: блокируются торренты, российские адреса (`geoip`, `geosite`, `.ru`, `.su`, `.рф`), loopback и private-диапазоны; `habr.com` идёт напрямую.
- В подписках для Clash/Mihomo и JSON добавляет зеркальные правила для клиента: российское — напрямую, остальное — через VPN.
- `kit user add` создаёт пользователя сразу во всех протоколах с общей подпиской.

## Что понадобится

- VPS с **Ubuntu 22.04/24.04** или **Debian 12/13**, root по SSH.
- **Домен**, у которого A-запись уже указывает на IP сервера (проверка: `dig +short vpn.example.com`). Если есть AAAA-запись, она должна вести на этот же сервер, иначе её нужно удалить.
- Свободные порты **80** и **443** (80 нужен для выпуска и продления сертификата).
- Домен не должен быть за проксированием Cloudflare (оранжевое облако), иначе сертификат не выпустится.

---

## Установка

Подключитесь к серверу по SSH и выполните:

```bash
sudo -i
apt-get update && apt-get install -y git
git clone https://github.com/mihanic89/3x-ui-domain-kit.git
cd 3x-ui-domain-kit
bash scripts/3x-ui.sh --domain vpn.example.com --email you@example.com
```

Скрипт запускается только из клона репозитория: рядом с ним должны лежать `kit.sh` и `kit-sub.py` (запуск через `bash <(curl …)` не поддерживается).

Через несколько минут скрипт покажет адрес панели, логин, пароль и ссылку-подписку с QR-кодом. Всё это сохраняется в `/root/3x-ui.txt` (виден только root).

| Параметр | Что делает |
|---|---|
| `--domain` | **обязателен**, IP не принимается |
| `--email` | почта для Let's Encrypt |
| `--cert файл --key файл` | свой сертификат вместо acme.sh (сам не продлевается) |
| `--no-dns-check` | не сверять A-запись с IP сервера |
| `--allow-private` | пускать клиентов в private-диапазоны сервера (по умолчанию заблокированы; loopback закрыт всегда) |
| `--protocols` | `all` (reality, xhttp, ws, hy2), `minimal` (только REALITY) или список через запятую из этих четырёх |
| `--user admin` | имя первого пользователя |
| `--port 443` | порт Hysteria2 (UDP) |
| `--sni сайт` | сайт для маскировки REALITY (по умолчанию подбирается сам) |
| `--no-ufw` | не трогать файрвол |

Повторный запуск на уже установленном сервере скрипт отказывается делать. Чтобы поставить заново, удалите панель через меню `x-ui` → Uninstall: подсказка с командой переустановки показывается там же.

---

## После установки

### Проверка заглушки

```bash
curl -sI https://vpn.example.com/            # 302 → /login
curl -s  https://vpn.example.com/status.php  # JSON с версией Nextcloud
curl -s -X POST -d 'user=a&password=b' https://vpn.example.com/login | grep -i wrong
```

### Пользователи

```bash
kit user add sasha --gb 50 --days 30   # создаёт во всех протоколах, печатает ссылку подписки
kit user list
kit user link sasha
kit user limit sasha --gb 100
kit user off sasha / kit user on sasha
kit user del sasha
```

Ссылка подписки вставляется в приложение (Hiddify, Happ, v2rayN, Karing, Clash Verge, FlClash): оно само получит подходящий формат.

Пользователя можно создать и в веб-панели, но тогда его нужно вручную добавить в каждое подключение с одинаковым `subId`. `kit user add` делает это одной командой.

### Сертификат

Продлевается сам (cron от acme.sh). Проверка: `/root/.acme.sh/acme.sh --list`. После продления вызывается `/usr/local/bin/kit-cert-reload`. Если сертификат когда-то нужно перевыпустить вручную: `/root/.acme.sh/acme.sh --renew -d vpn.example.com --ecc --force`.

### Правила маршрутизации

- Серверные правила записаны в `/etc/kit/routing-server.json`, применённый шаблон — `/etc/kit/xray-template.json`; их можно смотреть и править в панели: **Настройки Xray → Маршрутизация**.
- Гео-базы `geoip_RU.dat` и `geosite_RU.dat` (из [runetfreedom/russia-v2ray-rules-dat](https://github.com/runetfreedom/russia-v2ray-rules-dat)) обновляются раз в неделю (`/usr/local/bin/kit-geo-update`).
- Своё исключение для клиентов (идти через VPN, а не напрямую): добавьте домен в `client_proxy_domains` в `/etc/kit-sub/config.json` и выполните `systemctl restart kit-sub`.
- Отключить зеркальные правила в подписках: `"client_rules": false` в том же файле.

---

## Обновление

Код на сервере нужен только для установки. Подтянуть изменения в склонированную папку:

```bash
cd 3x-ui-domain-kit && git pull
```

Уже установленный сервер этим не обновляется: скрипт ставит один раз.

## Клиент на роутере OpenWrt (podkop)

Роутер с OpenWrt и podkop в этом репозитории не настраивается и не проверялся. Серверная сторона уже блокирует российский трафик и торренты, а разделение «что идёт через VPN» на роутере делает podkop. В podkop подставляются ссылки подключений (`vless://…`), их можно взять из подписки (`kit user link имя`) или из панели. Какие форматы подписки и протоколы (в том числе Hysteria2) поддерживает установленная у вас версия podkop, смотрите в её документации.

## Благодарности

Построено на работе авторов проектов:
[3X-UI](https://github.com/MHSanaei/3x-ui) ·
[Xray-core](https://github.com/XTLS/Xray-core) ·
[Hysteria](https://github.com/apernet/hysteria) ·
[acme.sh](https://github.com/acmesh-official/acme.sh) ·
[runetfreedom/russia-v2ray-rules-dat](https://github.com/runetfreedom/russia-v2ray-rules-dat)

> [!NOTE]
> Проект создан в образовательных целях. Убедитесь, что ваши действия соответствуют законодательству вашей страны.
