#!/usr/bin/env bash
# 3X-UI со всеми протоколами одной командой — https://github.com/mihanic89/3x-ui-domain-kit
#
# Установка (из клона репозитория — kit.sh и kit-sub.py берутся из этой же папки, без загрузок
# с чужих адресов):
#   git clone <ваш-репозиторий> && cd <репозиторий>
#   bash scripts/3x-ui.sh --domain vpn.example.com [--email you@example.com]
#
# Ставит официальную панель 3X-UI (версия закреплена ниже) её собственным
# установщиком, выпускает сертификат Let's Encrypt на ваш домен (acme.sh, автопродление),
# создаёт подключения REALITY, XHTTP, VLESS WS (всё TCP на 443 через nginx) и Hysteria2 (UDP 443),
# включает единую подписку с форматом под каждый клиент, кладёт серверные правила маршрутизации Xray
# (блок торрентов и российских адресов), ставит заглушку «Nextcloud» на сам домен
# и настраивает ufw.

set -Eeuo pipefail

XUI_VERSION="v3.8.5"
# Ядро Xray для панели. С 26.7.x клиенты на Mihomo и sing-box (Hiddify, FlClash,
# Clash Verge, Mihomo в XKeen) не проходят REALITY — проверено 2026-09-25.
# 26.6.27 — последняя версия, с которой работают все клиенты и которую принимает 3X-UI.
XRAY_CORE="v26.6.27"
XUI_REPO="MHSanaei/3x-ui"
RESULT=/root/3x-ui.txt
XUI_ENV=/etc/x-ui/install-result.env
# Сайты для маскировки REALITY: нужны TLS 1.3 и HTTP/2. Берём первый доступный.
# Apple, iCloud, Microsoft и домены .ru сам Xray не советует — их тут нет.
SNI_CANDIDATES=(dl.google.com www.amazon.com www.samsung.com www.yahoo.com)

# Форк оставляет четыре протокола: REALITY, XHTTP, VLESS-WS (TCP, за nginx на 443) и Hysteria2 (UDP 443).
ALL_PROTOS=(reality xhttp ws hy2)
DEFAULT_PROTOS=(reality xhttp ws hy2)
PROTOS=(); CREATED=(); OPEN=()
# Всё TCP — через порт 443: nginx разводит по SNI и путям, подключения слушают только localhost.
# (Режима с отдельными портами в форке нет; переменная осталась для kit.sh и проверок ниже.)
SINGLE=yes
declare -A INNER=([reality]=10443 [xhttp]=10444 [web]=10446 [ws]=10451 [sub]=10460)
SNI2=""
# Форк: работа по домену. Сертификат выпускает acme.sh (или свой через --cert/--key),
# маршрутизация Xray (серверные правила) кладётся в настройки панели.
EMAIL=""; ALLOW_PRIVATE=no
GEO_DIR=/usr/local/x-ui/bin
GEO_BASE="https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download"
CERT_DIR=/root/cert/custom

if [[ -t 1 ]]; then
  G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
else
  G=; Y=; R=; B=; D=; N=
fi
say()  { printf '%s\n' "${G}==>${N} $*"; }
warn() { printf '%s\n' "${Y}!${N}  $*" >&2; }
die()  { printf '%s\n' "${R}✗${N}  $*" >&2; exit 1; }
trap 'die "Ошибка в строке $LINENO. Исправьте причину и запустите скрипт ещё раз."' ERR

rand_str() { openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c "$1"; }
port_busy() { ss -H -ln"${2:0:1}" "sport = :$1" 2>/dev/null | grep -q .; }

public_ip() {
  local ip
  for u in https://api.ipify.org https://ifconfig.me/ip https://ipv4.icanhazip.com; do
    ip=$(curl -4 -fsS -m 6 "$u" 2>/dev/null | tr -d '[:space:]') || true
    [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return; }
  done
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}'
}

free_port() {
  local p
  for _ in $(seq 1 50); do
    p=$(shuf -i 20000-60000 -n 1)
    port_busy "$p" tcp || { echo "$p"; return; }
  done
  die "Не нашёл свободный порт для панели."
}

# REALITY маскируется под чужой сайт: он должен отвечать по TLS 1.3 и HTTP/2.
sni_ok() {
  echo | timeout 8 openssl s_client -connect "$1:443" -servername "$1" -tls1_3 -alpn h2 2>/dev/null \
    | grep -q 'ALPN protocol: h2'
}

# ---------- API панели ----------

api() { # METHOD path [json]
  local url="$API/$2" out
  if [[ $1 == GET ]]; then
    out=$(curl -fsSk -m 20 -H "Authorization: Bearer $TOKEN" "$url")
  else
    out=$(curl -fsSk -m 20 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -X "$1" -d "$3" "$url")
  fi
  [[ $(jq -r '.success' <<<"$out") == true ]] || die "Панель ответила ошибкой на $2: $(jq -r '.msg // .' <<<"$out" | head -c 300)"
  jq -c '.obj' <<<"$out"
}

wait_panel() {
  local i
  for i in $(seq 1 60); do
    curl -fsk -m 5 -o /dev/null -H "Authorization: Bearer $TOKEN" "$API/server/getNewUUID" 2>/dev/null && return 0
    sleep 2
  done
  die "Панель не отвечает. Лог: journalctl -u x-ui -n 50"
}

# ---------- установка ----------

# Пасхалка — только в конце установки.
kit_banner() {
  echo
  printf '%s' "$G"
  printf '%s' "$N"
  echo
  echo "${B}3x-ui-domain-kit${N} — панель 3X-UI (MHSanaei/3x-ui) и ядро Xray"
  echo
  echo "  https://github.com/mihanic89/3x-ui-domain-kit"
  echo
  echo "Ниже — данные для входа в панель и подключения."
}

main() {
  [[ $EUID -eq 0 ]] || die "Запустите от root: sudo -i, затем команду ещё раз."
  # Вспомогательные файлы лежат рядом со скриптом: запуск через bash <(curl …) не поддерживается.
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || SCRIPT_DIR=""
  if [[ -z $SCRIPT_DIR || ${BASH_SOURCE[0]} == /dev/fd/* || ! -f $SCRIPT_DIR/kit.sh || ! -f $SCRIPT_DIR/kit-sub.py ]]; then
    die "Запускайте скрипт из клона репозитория (нужны kit.sh и kit-sub.py рядом): git clone … && bash scripts/3x-ui.sh --domain …"
  fi
  command -v systemctl >/dev/null || die "Нужен systemd."
  if [[ -f $RESULT && -x /usr/local/x-ui/x-ui ]]; then
    die "3X-UI уже установлена этим скриптом. Управление: команда x-ui, данные для входа: cat $RESULT"
  fi
  # Панель удалили через меню x-ui, а наши файлы остались — убираем их и ставим заново.
  if [[ -f $RESULT ]]; then
    warn "Панель 3X-UI удалена, но остались файлы прошлой установки — убираю их."
    systemctl disable --now kit-sub >/dev/null 2>&1 || true
    rm -rf /etc/systemd/system/kit-sub.service /usr/local/lib/kit-sub /etc/kit-sub /etc/kit /usr/local/bin/kit \
      /etc/cron.d/kit-nginx-reload /etc/cron.d/kit-xui-menu "$RESULT"
    systemctl daemon-reload
    # Наш nginx держит 443 — без этого проверка порта ниже не пустит REALITY.
    if [[ -f /etc/nginx/kit-stream.conf ]]; then
      systemctl stop nginx >/dev/null 2>&1 || true
      rm -f /etc/nginx/kit-stream.conf /etc/nginx/conf.d/kit.conf
      sed -i '/kit-stream\.conf/d' /etc/nginx/nginx.conf
    fi
  fi
  if [[ -d /usr/local/x-ui && ! -f $XUI_ENV ]]; then
    die "3X-UI уже установлена другим способом — не трогаю её. Удалите её (x-ui uninstall) или добавьте REALITY в панели вручную."
  fi

  local PORT=443 SNI="" PANEL_SSL=auto HOST="" UFW=yes NAME="admin" yes=no protos=all ucert="" ukey="" dns_check=yes
  while [[ $# -gt 0 ]]; do
    case $1 in
      --port) PORT=$2; shift 2 ;;
      --sni) SNI=$2; shift 2 ;;
      --panel-ssl) die "--panel-ssl в форке убран: сертификат всегда на домен (acme.sh или --cert/--key), панель без сертификата не поддерживается." ;;
      --host|--domain) HOST=$2; shift 2 ;;
      --email) EMAIL=$2; shift 2 ;;
      --allow-private) ALLOW_PRIVATE=yes; shift ;;
      --no-dns-check) dns_check=no; shift ;;
      --user) NAME=$2; shift 2 ;;
      --protocols) protos=$2; shift 2 ;;
      --cert) ucert=$2; shift 2 ;;
      --key) ukey=$2; shift 2 ;;
      --no-ufw) UFW=no; shift ;;
      -y|--yes) yes=yes; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Неизвестный параметр: $1 (см. --help)" ;;
    esac
  done
  [[ $PORT =~ ^[0-9]+$ ]] && ((PORT > 0 && PORT < 65536)) || die "Неверный порт: $PORT"
  [[ $NAME =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || die "Имя: латиница, цифры, _ . - (до 32 символов)."
  # Форк: только домен. Без IP, без Let's Encrypt на IP, без «панель без сертификата».
  [[ -n $HOST ]] || die "Укажите домен: --domain vpn.example.com (A-запись должна указывать на этот сервер)."
  [[ $HOST =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || die "«$HOST» не похоже на домен. IP-адреса форк не принимает."
  HOST=${HOST,,}
  if [[ -n $ucert || -n $ukey ]]; then
    [[ -s $ucert && -s $ukey ]] || die "Нужны оба файла: --cert fullchain.pem --key privkey.pem"
    openssl x509 -in "$ucert" -noout 2>/dev/null || die "$ucert — не сертификат в формате PEM"
    openssl x509 -in "$ucert" -noout -checkhost "$HOST" 2>/dev/null | grep -q 'does match' || die "Сертификат $ucert не выписан на $HOST."
  fi
  PANEL_SSL=custom   # сертификат всегда есть: свой (--cert) или выпущенный acme.sh ниже
  case $protos in
    all) PROTOS=("${DEFAULT_PROTOS[@]}") ;;
    minimal) PROTOS=(reality) ;;
    *) IFS=, read -ra PROTOS <<<"$protos"
       local x
       for x in "${PROTOS[@]}"; do [[ " ${ALL_PROTOS[*]} " == *" $x "* ]] || die "Неизвестный протокол: $x. Доступны: ${ALL_PROTOS[*]}"; done ;;
  esac
  if port_busy "$PORT" tcp && ! { [[ -f $XUI_ENV ]] && ss -H -ltnp "sport = :$PORT" | grep -q -E 'xray|nginx'; }; then
    die "Порт $PORT/tcp уже занят. REALITY нужен свободный порт — укажите другой: --port 8443"
  fi

  # Сертификат на домен всегда доверенный — панель и подписка доступны снаружи по HTTPS.
  TRUSTED=yes
  if [[ -n $ucert ]]; then
    mkdir -p "$CERT_DIR"
    install -m 644 "$ucert" "$CERT_DIR/fullchain.pem"
    install -m 600 "$ukey" "$CERT_DIR/privkey.pem"
    warn "Свой сертификат не продлевается сам: после обновления положите файлы в $CERT_DIR и выполните kit-cert-reload."
  fi

  say "Ставлю пакеты: curl, jq, openssl, qrencode, ufw"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl jq openssl qrencode ca-certificates iproute2 ufw socat cron >/dev/null

  [[ $dns_check == yes ]] && check_dns
  install_cert_reload
  [[ -z $ucert ]] && issue_domain_cert

  if [[ -z $SNI ]]; then
    say "Выбираю сайт для маскировки REALITY"
    for s in "${SNI_CANDIDATES[@]}"; do
      if sni_ok "$s"; then SNI=$s; break; fi
    done
    [[ -n $SNI ]] || die "Ни один сайт из списка не ответил по TLS 1.3 + HTTP/2. Укажите свой: --sni example.com"
  elif ! sni_ok "$SNI"; then
    die "$SNI не отвечает по TLS 1.3 + HTTP/2 — REALITY с ним работать не будет. Выберите другой сайт."
  fi
  say "Маскировка: ${B}$SNI${N}"
  # XHTTP нужен свой сайт маскировки: nginx различает его и REALITY по SNI.
  for s in "${SNI_CANDIDATES[@]}"; do
    [[ $s == "$SNI" ]] && continue
    if sni_ok "$s"; then SNI2=$s; break; fi
  done
  SNI2=${SNI2:-$SNI}

  # --- официальный установщик 3X-UI с закреплённой версией ---
  local panel_port panel_path panel_user panel_pass tmp
  panel_port=$(free_port)
  panel_path=$(rand_str 18)
  panel_user=$(rand_str 10)
  panel_pass=$(rand_str 20)
  if [[ -f $XUI_ENV ]]; then
    say "3X-UI уже стоит после прошлого запуска — продолжаю с создания подключений"
  else
  tmp=$(mktemp)
  say "Ставлю 3X-UI $XUI_VERSION официальным установщиком (пара минут)"
  curl -fsSL --retry 3 -o "$tmp" "https://raw.githubusercontent.com/$XUI_REPO/$XUI_VERSION/install.sh"
  if ! XUI_NONINTERACTIVE=1 XUI_SSL_MODE="${PANEL_SSL/custom/none}" XUI_SERVER_IP="$HOST" \
      XUI_PANEL_PORT="$panel_port" XUI_WEB_BASE_PATH="$panel_path" \
      XUI_USERNAME="$panel_user" XUI_PASSWORD="$panel_pass" \
      bash "$tmp" "$XUI_VERSION" </dev/null >/var/log/3x-ui-install.log 2>&1; then
    tail -20 /var/log/3x-ui-install.log >&2
    die "Установщик 3X-UI завершился с ошибкой. Полный лог: /var/log/3x-ui-install.log"
  fi
  rm -f "$tmp"
  fi
  [[ -f $XUI_ENV ]] || die "Установщик не сохранил данные входа. Лог: /var/log/3x-ui-install.log"

  # Данные для входа — из файла, который пишет сам установщик.
  # shellcheck disable=SC1090
  . "$XUI_ENV"
  TOKEN=$XUI_API_TOKEN
  # Панель может уже работать по HTTPS (сертификат ставится после установщика) — пробуем оба.
  local scheme
  for scheme in https http; do
    API="$scheme://127.0.0.1:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH/panel/api"
    curl -fsk -m 5 -o /dev/null -H "Authorization: Bearer $XUI_API_TOKEN" "$API/server/getNewUUID" 2>/dev/null && break
  done
  wait_panel

  if [[ $PANEL_SSL == custom ]]; then
    say "Подключаю ваш сертификат к панели"
    /usr/local/x-ui/x-ui cert -webCert /root/cert/custom/fullchain.pem -webCertKey /root/cert/custom/privkey.pem >/dev/null 2>&1
    systemctl restart x-ui
    API="https://127.0.0.1:$XUI_PANEL_PORT/$XUI_WEB_BASE_PATH/panel/api"
    wait_panel
  fi

  # Без сертификата панель и подписки не должны торчать наружу по HTTP.
  if [[ $PANEL_SSL == none ]]; then
    say "Панель без сертификата — открываю её только для SSH-туннеля (127.0.0.1)"
    local all
    all=$(api POST setting/all '{}')
    api POST setting/update "$(jq -c '.webListen = "127.0.0.1" | .subListen = "127.0.0.1"' <<<"$all")" >/dev/null
    systemctl restart x-ui
    wait_panel
  fi

  # --- ядро Xray, совместимое со всеми клиентами ---
  local cur_core
  cur_core=$(/usr/local/x-ui/bin/xray-linux-* version 2>/dev/null | awk 'NR==1 {print "v" $2}')
  if [[ $cur_core != "$XRAY_CORE" ]]; then
    say "Ставлю ядро Xray $XRAY_CORE (совместимо с Hiddify, Mihomo и другими клиентами)"
    api POST "server/installXray/$XRAY_CORE" '{}' >/dev/null
    for _ in $(seq 1 30); do
      cur_core=$(/usr/local/x-ui/bin/xray-linux-* version 2>/dev/null | awk 'NR==1 {print "v" $2}')
      [[ $cur_core == "$XRAY_CORE" ]] && break
      sleep 2
    done
    [[ $cur_core == "$XRAY_CORE" ]] || warn "Не удалось сменить ядро Xray (сейчас $cur_core). Клиенты на Mihomo и sing-box могут не подключиться."
  fi

  # --- сертификат для протоколов с TLS ---
  setup_tls_cert

  # --- подключения: все выбранные протоколы, один subId на пользователя ---
  EXISTING=$(api GET inbounds/list)
  SUBID=""
  # Установку с отдельными портами (оригинальный режим) форк не переделывает и не поддерживает.
  if jq -e 'any(.[]; .remark == "REALITY" and (.listen // "") != "127.0.0.1")' <<<"$EXISTING" >/dev/null; then
    die "В панели уже есть подключения оригинального KIT с отдельными портами — форк с ними не работает. Поставьте на чистый сервер."
  fi
  local p
  for p in "${PROTOS[@]}"; do "proto_$p"; done
  # Первый пользователь — сразу на всех протоколах (как «kit user add»).
  ensure_user
  # Серверные правила маршрутизации (блок торрентов и RU, исключения, private).
  apply_routing

  # --- подписка: ссылки, Clash/Mihomo и JSON с автоопределением клиента ---
  setup_subscription
  setup_nginx
  install_kit_cli
  brand_xui_menu

  # --- файрвол ---
  if [[ $UFW == yes ]]; then
    local ssh_port
    ssh_port=$(ss -H -ltnp 2>/dev/null | awk '/sshd/ {sub(/.*:/,"",$4); print $4; exit}')
    ssh_port=${ssh_port:-22}
    OPEN+=("$ssh_port/tcp")
    OPEN+=("443/tcp" "80/tcp")   # acme.sh продлевает сертификат через порт 80
    say "Настраиваю ufw: ${OPEN[*]}"
    local o
    for o in "${OPEN[@]}"; do ufw allow "$o" >/dev/null; done
    ufw --force enable >/dev/null || warn "ufw не включился (так бывает в контейнерах) — откройте порты у хостера вручную."
  fi

  # --- итог ---
  local panel_url links
  panel_url="https://$HOST/${XUI_WEB_BASE_PATH#/}"
  panel_url="${panel_url%/}/"
  links=$(sub_links "$SUBID")
  umask 077
  {
    echo "3x-ui-domain-kit (3X-UI $XUI_VERSION) — данные для входа (файл виден только root)"
    echo
    echo "Панель:  $panel_url"
    echo "Логин:   $XUI_USERNAME"
    echo "Пароль:  $XUI_PASSWORD"
    echo
    [[ $TRUSTED == yes ]] && { echo "Подписка ($NAME) — все протоколы одной ссылкой:"; echo "$SUB_URL"; echo; }
    echo "Отдельные подключения ($NAME):"
    echo "$links"
  } >"$RESULT"

  kit_banner
  echo
  echo "${G}${B}Готово! 3X-UI работает: ${#CREATED[@]} протоколов.${N}"
  echo "${D}${CREATED[*]}${N}"
  echo
  echo "Панель:  ${B}$panel_url${N}"
  echo "Логин:   ${B}$XUI_USERNAME${N}"
  echo "Пароль:  ${B}$XUI_PASSWORD${N}"
  echo
  echo "Подписка для ${B}$NAME${N} — все протоколы одной ссылкой. Вставьте её в Hiddify, v2rayN, Happ,"
  echo "Clash Verge или FlClash: приложение само получит подходящий формат."
  echo
  echo "$SUB_URL"
  echo
  qrencode -t ANSIUTF8 -m 1 "$SUB_URL" || true
  echo
  echo "Всё это сохранено в ${B}$RESULT${N}."
  echo
  echo "Дополнительные пользователи — одной командой, сразу во все протоколы, со своей подпиской:"
  echo "  ${B}kit user add sasha --gb 50 --days 30${N}"
  echo "  ${B}kit user list${N}     — кто сколько израсходовал и до какого числа"
}

# ---------- сертификат ----------

# Домен должен уже указывать на этот сервер, иначе выпуск сертификата упадёт с неочевидной ошибкой.
# За Cloudflare с включённым проксированием проверка не пройдёт — тогда --no-dns-check
# (но и HTTP-01 за прокси не заработает: положите сертификат через --cert/--key).
check_dns() {
  local mine resolved
  mine=$(public_ip)
  # getent при отсутствии записи отдаёт код 2 — под pipefail это убило бы скрипт до нашего die.
  resolved=$(getent ahostsv4 "$HOST" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ') || resolved=""
  [[ -n $resolved ]] || die "Домен $HOST не резолвится. Создайте A-запись на $mine у регистратора и повторите (или --no-dns-check)."
  if [[ -n $mine && " $resolved" != *" $mine "* ]]; then
    die "$HOST указывает на ${resolved% }, а этот сервер — $mine. Поправьте A-запись и подождите обновления DNS (или --no-dns-check)."
  fi
  # Let's Encrypt предпочитает IPv6: AAAA, ведущая на другой хост, ломает выпуск, хотя A-запись верна.
  local v6 mine6
  v6=$(getent ahostsv6 "$HOST" 2>/dev/null | awk '$1 !~ /^::ffff:/ {print $1}' | sort -u | tr '\n' ' ') || v6=""
  if [[ -n $v6 ]]; then
    mine6=$(curl -6 -fsS -m 6 https://api64.ipify.org 2>/dev/null | tr -d '[:space:]') || true
    if [[ -z $mine6 || " $v6" != *" $mine6 "* ]]; then
      die "У $HOST есть AAAA-запись (${v6% }), но она не совпадает с IPv6 этого сервера${mine6:+ ($mine6)}. Удалите AAAA или направьте её на этот сервер (или --no-dns-check)."
    fi
  fi
  say "DNS: $HOST → $mine"
}

# Хук после выпуска и каждого продления: свежий сертификат подхватывают nginx и ядро Xray
# (панель и Hysteria2 читают те же файлы из $CERT_DIR).
install_cert_reload() {
  cat >/usr/local/bin/kit-cert-reload <<RELOAD
#!/bin/sh
# Вызывается acme.sh после выпуска/продления сертификата (3x-ui-domain-kit).
chmod 600 $CERT_DIR/privkey.pem 2>/dev/null
if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then systemctl reload nginx >/dev/null 2>&1; fi
systemctl is-active --quiet x-ui && systemctl restart x-ui >/dev/null 2>&1
systemctl is-active --quiet kit-sub && systemctl restart kit-sub >/dev/null 2>&1
exit 0
RELOAD
  chmod 755 /usr/local/bin/kit-cert-reload
}

issue_domain_cert() {
  if [[ -s $CERT_DIR/fullchain.pem && -s $CERT_DIR/privkey.pem ]] \
     && openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -checkhost "$HOST" 2>/dev/null | grep -q 'does match' \
     && openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -checkend $((20*86400)) >/dev/null 2>&1; then
    say "Сертификат на $HOST уже есть — использую его"
    return 0
  fi
  port_busy 80 tcp && die "Для выпуска сертификата нужен свободный порт 80/tcp."
  # Если ufw уже включён и закрывает входящие, Let's Encrypt не достучится до порта 80.
  if [[ $UFW == yes ]] && command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow 80/tcp >/dev/null
  fi
  local acme=/root/.acme.sh/acme.sh
  if [[ ! -x $acme ]]; then
    say "Ставлю acme.sh"
    curl -fsSL --retry 3 https://get.acme.sh | sh -s ${EMAIL:+email="$EMAIL"} >/var/log/acme-install.log 2>&1 \
      || { tail -10 /var/log/acme-install.log >&2; die "Не удалось установить acme.sh. Лог: /var/log/acme-install.log"; }
  fi
  say "Выпускаю сертификат Let's Encrypt на ${B}$HOST${N}"
  "$acme" --set-default-ca --server letsencrypt >/dev/null 2>&1
  "$acme" --issue -d "$HOST" --standalone --keylength ec-256 --force >/var/log/acme-issue.log 2>&1 \
    || { tail -15 /var/log/acme-issue.log >&2; die "Сертификат не выпущен. Проверьте DNS и порт 80. Лог: /var/log/acme-issue.log"; }
  install -d -m 755 "$CERT_DIR"
  "$acme" --install-cert -d "$HOST" --ecc \
    --fullchain-file "$CERT_DIR/fullchain.pem" --key-file "$CERT_DIR/privkey.pem" \
    --reloadcmd /usr/local/bin/kit-cert-reload >>/var/log/acme-issue.log 2>&1 \
    || die "acme.sh не смог установить сертификат. Лог: /var/log/acme-issue.log"
  chmod 600 "$CERT_DIR/privkey.pem"
}

setup_tls_cert() {
  PIN=""
  if [[ $PANEL_SSL == custom ]]; then
    CERT=/root/cert/custom/fullchain.pem; KEY=/root/cert/custom/privkey.pem
  elif [[ $PANEL_SSL == ip && -s /root/cert/ip/fullchain.pem ]]; then
    CERT=/root/cert/ip/fullchain.pem; KEY=/root/cert/ip/privkey.pem
  else
    # Без Let's Encrypt — свой сертификат, а его отпечаток уходит в ссылки (pcs),
    # чтобы клиенты доверяли именно ему.
    CERT=/root/cert/self/fullchain.pem; KEY=/root/cert/self/privkey.pem
    if [[ ! -s $CERT ]]; then
      mkdir -p /root/cert/self
      local san="DNS:$HOST"
      [[ $HOST =~ ^[0-9.]+$ ]] && san="IP:$HOST"
      openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout "$KEY" -out "$CERT" \
        -subj "/CN=$HOST" -addext "subjectAltName=$san" -days 3650 2>/dev/null
      chmod 600 "$KEY"
    fi
    PIN=$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')
  fi
}

tls_json() { # alpn(JSON-массив)
  jq -nc --arg sni "$HOST" --arg c "$CERT" --arg k "$KEY" --arg pin "$PIN" --argjson alpn "$1" '{
    serverName: $sni, alpn: $alpn, certificates: [{certificateFile: $c, keyFile: $k}],
    settings: ({fingerprint: "chrome"} + (if $pin != "" then {pinnedPeerCertSha256: [$pin]} else {} end))}'
}

# ---------- протоколы ----------

client_base() { # суффикс
  local sid=$SUBID
  jq -nc --arg e "$NAME-$1" --arg s "$sid" '{email: $e, limitIp: 0, totalGB: 0, expiryTime: 0, enable: true, tgId: 0, subId: $s, comment: "", reset: 0}'
}
uuid() { cat /proc/sys/kernel/random/uuid; }
rnd() { shuf -i "$1-$2" -n 1; }

# add_inbound remark port proto(tcp|udp|both|inner) protocol settings stream
# inner — подключение за nginx: слушает 127.0.0.1, наружу порт не открываем.
add_inbound() {
  local remark=$1 port=$2 net=$3 protocol=$4 settings=$5 stream=$6 body listen=""
  [[ $net == inner ]] && listen=127.0.0.1
  if jq -e --arg r "$remark" 'any(.[]; .remark == $r)' <<<"$EXISTING" >/dev/null; then
    CREATED+=("$remark"); open_port "$port" "$net"; return
  fi
  # Клиентов в подключение не кладём: пользователь добавляется потом сразу во все подключения.
  settings=$(jq -c 'if has("clients") then .clients = [] else . end' <<<"$settings")
  local n
  local nets=$net
  [[ $net == both ]] && nets="tcp udp"
  [[ $net == inner ]] && nets=tcp
  for n in $nets; do
    if port_busy "$port" "$n"; then warn "$remark пропущен: порт $port/$n занят"; return; fi
  done
  body=$(jq -nc --arg rm "$remark" --argjson port "$port" --arg p "$protocol" --arg s "$settings" --arg st "$stream" --arg l "$listen" '{
    remark: $rm, enable: true, listen: $l, port: $port, protocol: $p, settings: $s, streamSettings: $st,
    sniffing: "{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"],\"metadataOnly\":false,\"routeOnly\":false}",
    expiryTime: 0, total: 0}')
  local out
  out=$(curl -sSk -m 20 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -X POST -d "$body" "$API/inbounds/add")
  if [[ $(jq -r '.success' <<<"$out") != true ]] && grep -q 'Duplicate email' <<<"$out"; then
    # Клиент с таким именем остался от удалённого подключения — берём уникальное имя.
    body=$(jq -c --arg sfx "-$(openssl rand -hex 2)" '.settings |= (fromjson | .clients[0].email += $sfx | tojson)' <<<"$body")
    out=$(curl -sSk -m 20 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -X POST -d "$body" "$API/inbounds/add")
  fi
  [[ $(jq -r '.success' <<<"$out") == true ]] || die "Панель не создала $remark: $(jq -r '.msg // .' <<<"$out" | head -c 300)"
  CREATED+=("$remark"); open_port "$port" "$net"
}

open_port() { # port net
  case $2 in
    inner) ;;
    tcp|udp) OPEN+=("$1/$2") ;;
    both) OPEN+=("$1/tcp" "$1/udp") ;;
  esac
}

# External Proxy 3X-UI: ссылки ведут на HOST:443, хотя подключение слушает localhost.
# SNI — только для TLS через nginx: у REALITY своё имя сайта маскировки, его не трогаем.
ext_proxy() { # forceTls(same|tls) alpn(JSON)
  local sni=""
  [[ $HOST =~ ^[0-9.]+$ ]] || sni=$HOST
  jq -nc --arg f "$1" --arg h "$HOST" --arg sni "$sni" --argjson alpn "${2:-null}" '[{forceTls: $f, dest: $h, port: 443, remark: ""}
    + (if $f == "tls" then {fingerprint: "chrome", alpn: $alpn} + (if $sni != "" then {sni: $sni} else {} end) else {} end)]'
}

proto_reality() {
  local keys stream settings
  keys=$(api GET server/getNewX25519Cert)
  settings=$(jq -nc --arg id "$(uuid)" --argjson c "$(client_base reality)" '{clients: [$c + {id: $id, flow: "xtls-rprx-vision"}], decryption: "none", fallbacks: []}')
  stream=$(jq -nc --arg sni "$SNI" --argjson k "$keys" --arg sid "$(openssl rand -hex 8)" '{
    network: "tcp", security: "reality", externalProxy: [],
    realitySettings: {show: false, xver: 0, target: ($sni + ":443"), serverNames: [$sni], privateKey: $k.privateKey,
      minClientVer: "", maxClientVer: "", maxTimediff: 0, shortIds: [$sid],
      settings: {publicKey: $k.publicKey, fingerprint: "chrome", serverName: "", spiderX: "/"}},
    tcpSettings: {acceptProxyProtocol: false, header: {type: "none"}}}')
  stream=$(jq -c --argjson e "$(ext_proxy same)" '.externalProxy = $e | .tcpSettings.acceptProxyProtocol = true' <<<"$stream")
  add_inbound "REALITY" "${INNER[reality]}" inner vless "$settings" "$stream"
}

proto_xhttp() {
  local keys stream settings
  keys=$(api GET server/getNewX25519Cert)
  settings=$(jq -nc --arg id "$(uuid)" --argjson c "$(client_base xhttp)" '{clients: [$c + {id: $id, flow: ""}], decryption: "none"}')
  stream=$(jq -nc --arg sni "$SNI" --argjson k "$keys" --arg sid "$(openssl rand -hex 8)" --arg path "/$(rand_str 10 | tr 'A-Z' 'a-z')" '{
    network: "xhttp", security: "reality", xhttpSettings: {path: $path, mode: "auto"},
    realitySettings: {target: ($sni + ":443"), serverNames: [$sni], privateKey: $k.privateKey, shortIds: [$sid],
      settings: {publicKey: $k.publicKey, fingerprint: "chrome", spiderX: "/"}}}')
  stream=$(jq -c --arg sni "$SNI2" --argjson e "$(ext_proxy same)" '.realitySettings.target = ($sni + ":443") | .realitySettings.serverNames = [$sni]
    | .externalProxy = $e | .sockopt = {acceptProxyProtocol: true}' <<<"$stream")
  add_inbound "XHTTP" "${INNER[xhttp]}" inner vless "$settings" "$stream"
}

proto_ws() {
  local settings stream
  settings=$(jq -nc --arg id "$(uuid)" --argjson c "$(client_base ws)" '{clients: [$c + {id: $id, flow: ""}], decryption: "none"}')
  stream=$(jq -nc --argjson t "$(tls_json '["http/1.1"]')" --arg path "/$(rand_str 10 | tr 'A-Z' 'a-z')" '{network: "ws", security: "tls", wsSettings: {path: $path}, tlsSettings: $t}')
  stream=$(jq -c --argjson e "$(ext_proxy tls '["http/1.1"]')" '{network, wsSettings, security: "none", externalProxy: $e}' <<<"$stream")
  add_inbound "VLESS-WS" "${INNER[ws]}" inner vless "$settings" "$stream"
}

proto_hy2() {
  local settings stream
  settings=$(jq -nc --arg a "$(rand_str 16)" --argjson c "$(client_base hy2)" '{version: 2, clients: [$c + {auth: $a}]}')
  stream=$(jq -nc --argjson t "$(tls_json '["h3"]')" '{network: "hysteria", hysteriaSettings: {version: 2}, security: "tls", tlsSettings: $t}')
  add_inbound "Hysteria2" "$PORT" udp hysteria "$settings" "$stream"
}

# ---------- пользователи ----------

# Один клиент 3X-UI на все подключения: общие трафик, лимиты и срок, одна подписка.
ensure_user() {
  local list me ids missing
  list=$(api GET clients/list | jq -c 'if type == "array" then . else .clients end')
  ids=$(api GET inbounds/list | jq -c '[.[].id]')
  me=$(jq -c --arg e "$NAME" 'map(select(.email == $e))[0] // empty' <<<"$list")
  if [[ -n $me ]]; then
    SUBID=$(jq -r '.subId' <<<"$me")
    missing=$(jq -c --argjson all "$ids" '$all - (.inboundIds // [])' <<<"$me")
    [[ $missing == "[]" ]] || api POST "clients/$NAME/attach" "$(jq -nc --argjson i "$missing" '{inboundIds: $i}')" >/dev/null
  else
    SUBID=$(rand_str 16 | tr 'A-Z' 'a-z')
    api POST clients/add "$(jq -nc --arg e "$NAME" --arg s "$SUBID" --argjson ids "$ids" \
      '{client: {email: $e, subId: $s, totalGB: 0, expiryTime: 0, limitIp: 0, enable: true, comment: "kit"}, inboundIds: $ids}')" >/dev/null
  fi
}

install_kit_cli() {
  install -d -m 700 /etc/kit
  {
    printf 'HOST=%q\n' "$HOST"
    printf 'SUB_BASE=%q\n' "${SUB_URL%$SUBID}"
    printf 'SUB_PATH=%q\n' "$SUB_PATH"
    printf 'SUB_INTERNAL=%q\n' "${SUB_INTERNAL:-$SUB_PORT}"
    printf 'SINGLE=%q\n' "$SINGLE"
  } >/etc/kit/kit.env
  chmod 600 /etc/kit/kit.env
  install -m 755 "$SCRIPT_DIR/kit.sh" /usr/local/bin/kit
  bash -n /usr/local/bin/kit || die "Команда kit повреждена"
  # Копия установщика для переустановки после «x-ui → Uninstall» (подсказка в меню x-ui).
  install -d -m 755 /usr/local/lib/kit
  # При переустановке из этой же папки копировать нечего (install не копирует файл сам в себя).
  if [[ $(realpath "$SCRIPT_DIR") != "$(realpath /usr/local/lib/kit)" ]]; then
    install -m 755 "${BASH_SOURCE[0]}" /usr/local/lib/kit/3x-ui.sh
    install -m 644 "$SCRIPT_DIR/kit.sh" "$SCRIPT_DIR/kit-sub.py" /usr/local/lib/kit/
  fi
}


# После «x-ui → Uninstall» меню подсказывает команду официального установщика —
# меняем её на нашу. Только в echo: вызов установщика в «Update» не трогаем.
# Меню обновляется вместе с панелью, поэтому раз в сутки подсказку правит cron.
brand_xui_menu() {
  local KIT_INSTALL_CMD="bash /usr/local/lib/kit/3x-ui.sh --domain $HOST"
  printf '%s\n' '/echo.*mhsanaei\/3x-ui\/[a-z]*\/install\.sh/ s#bash <(curl -Ls https://raw\.githubusercontent\.com/mhsanaei/3x-ui/[a-z]*/install\.sh)#'"$KIT_INSTALL_CMD"'#' \
    >/etc/kit/xui-menu.sed
  local f
  for f in /usr/bin/x-ui /usr/local/x-ui/x-ui.sh; do
    [[ -f $f ]] && sed -i -f /etc/kit/xui-menu.sed "$f"
  done
  echo '23 4 * * * root for f in /usr/bin/x-ui /usr/local/x-ui/x-ui.sh; do [ -f "$f" ] && sed -i -f /etc/kit/xui-menu.sed "$f"; done' \
    >/etc/cron.d/kit-xui-menu
}

# ---------- маршрутизация Xray (серверная сторона) ----------

# Правила идут сверху вниз, срабатывает первое совпадение — поэтому исключение habr.com
# стоит выше блокировки .ru и geoip RU. Клиентам kit-sub отдаёт зеркальные правила
# (российское — напрямую мимо VPN, остальное — через прокси).
# geoip:private на сервере по умолчанию «blocked»: иначе любой клиент VPN дошёл бы до
# localhost и внутренней сети сервера — в том числе до API ядра Xray (127.0.0.1:62789, без
# авторизации: HandlerService позволяет менять inbound'ы и пользователей), панели и kit-sub.
# --allow-private делает private-диапазоны «direct», но loopback блокируется всегда.
# Чтобы домен, резолвящийся в 127.0.0.1 (localtest.me и т. п.), не обходил IP-правила,
# routing.domainStrategy ставится IPIfNonMatch (см. apply_routing).
routing_rules() {
  local private=blocked
  [[ $ALLOW_PRIVATE == yes ]] && private=direct
  jq -n --arg private "$private" '[
    {type: "field", protocol: ["bittorrent"], outboundTag: "blocked"},
    {type: "field", inboundTag: ["api"], outboundTag: "api"},
    {type: "field", ip: ["127.0.0.0/8", "::1/128"], outboundTag: "blocked"},
    {type: "field", domain: ["habr.com"], outboundTag: "direct"},
    {type: "field", ip: ["ext:geoip_RU.dat:ru"], outboundTag: "blocked"},
    {type: "field", domain: ["ext:geosite_RU.dat:ru-available-only-inside", "regexp:.*\\.ru$", "regexp:.*\\.xn--p1ai$", "regexp:.*\\.su$"], outboundTag: "blocked"},
    {type: "field", ip: ["geoip:private"], outboundTag: $private}
  ]'
}

# Файлы geoip_RU.dat / geosite_RU.dat лежат рядом с ядром Xray. Без них Xray не стартует
# (ext:… на несуществующий файл), поэтому при неудаче загрузки установка останавливается.
fetch_geo() { # имя-в-репозитории имя-файла
  local tmp; tmp=$(mktemp)
  curl -fsSL --retry 3 -m 120 -o "$tmp" "$GEO_BASE/$1" && [[ -s $tmp ]] || { rm -f "$tmp"; return 1; }
  if ! cmp -s "$tmp" "$GEO_DIR/$2"; then install -m 644 "$tmp" "$GEO_DIR/$2"; GEO_CHANGED=yes; fi
  rm -f "$tmp"
}

install_geo() {
  say "Скачиваю гео-базы для маршрутизации (geoip_RU.dat, geosite_RU.dat)"
  GEO_CHANGED=no
  fetch_geo geoip.dat geoip_RU.dat   || die "Не скачался $GEO_BASE/geoip.dat — без него правила RU не заработают."
  fetch_geo geosite.dat geosite_RU.dat || die "Не скачался $GEO_BASE/geosite.dat."
  # Обновление раз в неделю; ядро перезапускаем, только если файлы изменились.
  cat >/usr/local/bin/kit-geo-update <<UPD
#!/bin/sh
# Обновляет geoip_RU.dat и geosite_RU.dat (3x-ui-domain-kit).
changed=0
for p in geoip.dat:geoip_RU.dat geosite.dat:geosite_RU.dat; do
  src=\${p%%:*}; dst=\${p##*:}; tmp=\$(mktemp)
  if curl -fsSL --retry 3 -m 120 -o "\$tmp" "$GEO_BASE/\$src" && [ -s "\$tmp" ]; then
    cmp -s "\$tmp" "$GEO_DIR/\$dst" || { install -m 644 "\$tmp" "$GEO_DIR/\$dst"; changed=1; }
  fi
  rm -f "\$tmp"
done
[ \$changed = 1 ] && systemctl restart x-ui
exit 0
UPD
  chmod 755 /usr/local/bin/kit-geo-update
  echo '37 4 * * 0 root /usr/local/bin/kit-geo-update >/dev/null 2>&1' >/etc/cron.d/kit-geo-update
}

# Кладёт правила в xrayTemplateConfig — настройки Xray в панели («Xray → Маршрутизация»).
# Берёт уже сохранённый шаблон (ручные правки outbound'ов не теряются) или, если его нет,
# шаблон по умолчанию из закреплённой версии 3X-UI; меняет только routing.rules.
apply_routing() {
  say "Применяю правила маршрутизации Xray"
  install_geo
  local db=/etc/x-ui/x-ui.db tmpl rules
  [[ -f $db ]] || die "Не нашёл базу панели $db."
  apt-get install -y -qq python3 >/dev/null
  tmpl=$(python3 - "$db" <<'PY'
import sqlite3, sys
r = sqlite3.connect(sys.argv[1]).execute("select value from settings where key='xrayTemplateConfig'").fetchone()
print(r[0] if r and r[0] else "")
PY
)
  if [[ -z $tmpl ]]; then
    tmpl=$(curl -fsSL --retry 3 "https://raw.githubusercontent.com/$XUI_REPO/$XUI_VERSION/web/service/config.json" 2>/dev/null) || tmpl=""
    if [[ -z $tmpl ]] || ! jq -e '.routing' <<<"$tmpl" >/dev/null 2>&1; then
      # Не рушим установку: панель уже работает, правила можно вставить вручную.
      install -d -m 755 /etc/kit
      routing_rules >/etc/kit/routing-server.json
      warn "Не получил шаблон Xray по умолчанию для $XUI_VERSION. Правила маршрутизации НЕ применены."
      warn "Вставьте массив из /etc/kit/routing-server.json в панели: Настройки Xray → Маршрутизация (routing.rules)."
      return 0
    fi
  fi
  jq -e '.routing' <<<"$tmpl" >/dev/null || die "В шаблоне Xray нет секции routing — формат панели изменился."
  rules=$(routing_rules)
  # outbound'ы direct, blocked и inbound «api» должны существовать — на них ссылаются правила.
  jq -e '[.outbounds[].tag] | (index("direct") != null and index("blocked") != null)' <<<"$tmpl" >/dev/null \
    || die "В шаблоне Xray нет outbound'ов direct/blocked — правила на них сослаться не смогут."
  install -d -m 755 /etc/kit
  echo "$rules" >/etc/kit/routing-server.json
  jq -c --argjson rules "$rules" '.routing.rules = $rules | .routing.domainStrategy = "IPIfNonMatch"' <<<"$tmpl" >/etc/kit/xray-template.json
  python3 - "$db" /etc/kit/xray-template.json <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
val = open(sys.argv[2], encoding="utf-8").read()
cur = con.execute("update settings set value=? where key='xrayTemplateConfig'", (val,))
if cur.rowcount == 0:
    con.execute("insert into settings(key, value) values('xrayTemplateConfig', ?)", (val,))
con.commit()
PY
  systemctl restart x-ui
  wait_panel
  # Ядро не поднимется с битым шаблоном (например, нет файла гео-базы) — проверяем сразу.
  sleep 3
  pgrep -f 'xray-linux' >/dev/null || { journalctl -u x-ui -n 20 --no-pager >&2 || true; die "Ядро Xray не запустилось с новыми правилами — лог выше."; }
}

# ---------- заглушка «Nextcloud» ----------

# При заходе на домен без секретного пути (браузер, сканер, проверка «что тут за сайт»)
# отвечает выглядящий как Nextcloud сервер: редирект / → /login, страница входа, на POST —
# «Wrong username or password», /status.php, robots.txt, WebDAV с 401, 404 в стиле Nextcloud.
# Версия — в одном месте, чтобы /status.php и страницы не расходились.
NC_VERSION="29.0.7.1"
NC_VERSION_STR="29.0.7"

install_stub() {
  local d=/var/www/kit/nc
  install -d -m 755 /var/www/kit "$d"

  local css='*{box-sizing:border-box}body{margin:0;min-height:100vh;font:15px/1.4 -apple-system,"Segoe UI",Roboto,Oxygen,Ubuntu,Cantarell,"Helvetica Neue",sans-serif;color:#fff;background:linear-gradient(40deg,#0082c9 0%,#1e5d8c 100%) no-repeat;display:flex;flex-direction:column;align-items:center;justify-content:center}.logo{margin-bottom:28px}.box{width:320px;padding:0 0 12px;text-align:center}h2{font-weight:300;font-size:20px;margin:0 0 18px}input{display:block;width:100%;margin:0 0 12px;padding:14px 16px;border:2px solid transparent;border-radius:12px;font-size:15px;background:#fff;color:#222;outline:none}input:focus{border-color:#fff;box-shadow:0 0 0 2px rgba(255,255,255,.4)}button{width:100%;padding:13px;border:0;border-radius:12px;background:#fff;color:#0082c9;font-size:15px;font-weight:600;cursor:pointer}.warning{margin:0 0 14px;padding:10px 12px;border-radius:12px;background:rgba(0,0,0,.25);font-size:14px}footer{position:fixed;bottom:18px;font-size:13px;opacity:.85}'
  local logo='<svg class="logo" width="146" height="70" viewBox="0 0 146 70" xmlns="http://www.w3.org/2000/svg"><g fill="none" stroke="#fff" stroke-width="9"><circle cx="30" cy="35" r="19"/><circle cx="73" cy="35" r="26"/><circle cx="116" cy="35" r="19"/></g></svg>'
  local head='<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex, nofollow"><meta name="theme-color" content="#0082c9"><link rel="icon" href="/favicon.ico">'

  _login_page() { # сообщение-об-ошибке
    cat <<HTML
<!DOCTYPE html>
<html lang="en" data-locale="en"><head>${head}<title>Nextcloud</title><style>${css}</style></head>
<body>${logo}
<form class="box" method="post" action="/login" name="login">
<h2>Log in to Nextcloud</h2>
$1<input type="text" name="user" placeholder="Account name or email" autocomplete="username" autocapitalize="none" autofocus required>
<input type="password" name="password" placeholder="Password" autocomplete="current-password" required>
<button type="submit">Log in</button>
</form>
<footer>Nextcloud – a safe home for all your data</footer>
</body></html>
HTML
  }
  _login_page '' >"$d/login.html"
  _login_page '<p class="warning wrongPasswordMsg">Wrong account name or password.</p>
' >"$d/login-failed.html"
  unset -f _login_page

  cat >"$d/404.html" <<HTML
<!DOCTYPE html>
<html lang="en"><head>${head}<title>Page not found – Nextcloud</title><style>${css}</style></head>
<body>${logo}<div class="box"><h2>Page not found</h2><p>The page could not be found on the server or you may not be allowed to view it.</p><p><a style="color:#fff" href="/">← Back to Nextcloud</a></p></div>
<footer>Nextcloud – a safe home for all your data</footer></body></html>
HTML

  printf '{"installed":true,"maintenance":false,"needsDbUpgrade":false,"version":"%s","versionstring":"%s","edition":"","productname":"Nextcloud","extendedSupport":false}' \
    "$NC_VERSION" "$NC_VERSION_STR" >"$d/status.json"
  printf 'User-agent: *\nDisallow: /\n' >"$d/robots.txt"
  cat >"$d/dav401.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<d:error xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns">
  <s:exception>Sabre\DAV\Exception\NotAuthenticated</s:exception>
  <s:message>No public access to this resource., No 'Authorization: Basic' header found. Either the client didn't send one, or the server is misconfigured</s:message>
</d:error>
XML
  cat >"$d/favicon.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="6" fill="#0082c9"/><g fill="none" stroke="#fff" stroke-width="3"><circle cx="8" cy="16" r="5"/><circle cx="16" cy="16" r="7"/><circle cx="24" cy="16" r="5"/></g></svg>
SVG

  # Заголовки безопасности — как у настоящего Nextcloud.
  cat >/etc/nginx/kit-nc-headers.conf <<'NGX'
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Permitted-Cross-Domain-Policies "none" always;
add_header X-Robots-Tag "noindex, nofollow" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header X-Download-Options "noopen" always;
add_header Referrer-Policy "no-referrer" always;
add_header Content-Security-Policy "default-src 'none';base-uri 'none';manifest-src 'self';script-src 'self';style-src 'self' 'unsafe-inline';img-src 'self' data: blob:;font-src 'self' data:;connect-src 'self';form-action 'self'" always;
NGX

  # Cookie «сессии» — случайная при каждой установке, как у Nextcloud (имя oc + 10 символов).
  local sess pass
  sess="oc$(rand_str 10 | tr 'A-Z' 'a-z')"; pass=$(rand_str 48)
  cat >/etc/nginx/kit-stub.conf <<NGX
# Сгенерировано 3x-ui.sh (3x-ui-domain-kit) — перезаписывается при повторном запуске.
root /var/www/kit/nc;
index login.html;
include /etc/nginx/kit-nc-headers.conf;
error_page 404 /404.html;
error_page 405 =200 \$uri;

location = /404.html { internal; include /etc/nginx/kit-nc-headers.conf; }
location = /login-failed.html { internal; include /etc/nginx/kit-nc-headers.conf; }

location = / { return 302 /login; }
location = /index.php { return 302 /login; }
location = /index.php/ { return 302 /login; }

location ~ ^/(index\.php/)?login/?\$ {
    include /etc/nginx/kit-nc-headers.conf;
    add_header Set-Cookie "nc_sameSiteCookielax=true; path=/; httponly; expires=Fri, 31-Dec-2100 23:59:59 GMT; SameSite=lax" always;
    add_header Set-Cookie "nc_sameSiteCookiestrict=true; path=/; httponly; expires=Fri, 31-Dec-2100 23:59:59 GMT; SameSite=strict" always;
    add_header Set-Cookie "$sess=$pass; path=/; secure; HttpOnly; SameSite=Lax" always;
    add_header Cache-Control "no-cache, no-store, must-revalidate" always;
    default_type text/html;
    if (\$request_method = POST) { rewrite ^ /login-failed.html last; }
    try_files /login.html =404;
}

location = /status.php {
    include /etc/nginx/kit-nc-headers.conf;
    default_type application/json;
    try_files /status.json =404;
}
location = /robots.txt { default_type text/plain; try_files /robots.txt =404; }
location = /favicon.ico { default_type image/svg+xml; try_files /favicon.svg =404; }
location = /core/img/favicon.ico { default_type image/svg+xml; try_files /favicon.svg =404; }

location ~ ^/\.well-known/(caldav|carddav)\$ { return 301 /remote.php/dav/; }
location = /.well-known/webfinger { return 404; }
location ~ ^/(remote\.php|public\.php|ocs|ocm-provider|dav)(/|\$) {
    error_page 401 /dav401.xml;
    return 401;
}
location = /dav401.xml {
    internal;
    include /etc/nginx/kit-nc-headers.conf;
    add_header WWW-Authenticate 'Basic realm="Nextcloud", charset="UTF-8"' always;
    default_type application/xml;
}

# Всё прочее — 404 в стиле Nextcloud (error_page выше), а не голый nginx.
location / { return 404; }
NGX
}

# ---------- всё на 443: nginx ----------

setup_nginx() {
  say "Настраиваю nginx: всё TCP через порт 443"
  apt-get install -y -qq nginx libnginx-mod-stream >/dev/null
  # Порт 80 нужен Let's Encrypt для продления сертификата — сайт nginx по умолчанию убираем.
  rm -f /etc/nginx/sites-enabled/default

  # Панель — только через nginx.
  local all
  all=$(api POST setting/all '{}')
  if [[ $(jq -r '.webListen' <<<"$all") != 127.0.0.1 ]]; then
    api POST setting/update "$(jq -c '.webListen = "127.0.0.1"' <<<"$all")" >/dev/null
    systemctl restart x-ui
    wait_panel
  fi

  install_stub

  # Маршруты — из текущих подключений панели: сайты REALITY и XHTTP, пути WebSocket.
  local list reality_sni xhttp_sni locs="" kind path port
  list=$(api GET inbounds/list)
  reality_sni=$(jq -r '.[] | select(.remark == "REALITY" and .listen == "127.0.0.1") | (.streamSettings | if type == "string" then fromjson else . end).realitySettings.serverNames[0]' <<<"$list")
  xhttp_sni=$(jq -r '.[] | select(.remark == "XHTTP" and .listen == "127.0.0.1") | (.streamSettings | if type == "string" then fromjson else . end).realitySettings.serverNames[0]' <<<"$list")
  while IFS=$'\t' read -r kind path port; do
    [[ -n $path ]] || continue
    if [[ $kind == ws ]]; then
      locs+="
    location = $path {
        proxy_pass http://127.0.0.1:$port;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_protocol_addr;
        proxy_read_timeout 1h;
    }"
    else
      locs+="
    location /$path/ {
        grpc_pass grpc://127.0.0.1:$port;
        grpc_set_header X-Real-IP \$proxy_protocol_addr;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        client_max_body_size 0;
    }"
    fi
  done < <(jq -r '.[] | select(.listen == "127.0.0.1") | (.streamSettings | if type == "string" then fromjson else . end) as $st
    | if $st.network == "ws" then ["ws", $st.wsSettings.path, .port]
      elif $st.network == "grpc" then ["grpc", $st.grpcSettings.serviceName, .port]
      else empty end | @tsv' <<<"$list")

  local panel_path=/${XUI_WEB_BASE_PATH#/}
  panel_path=${panel_path%/}/
  {
    echo "# Сгенерировано 3x-ui.sh (3x-ui-domain-kit) — перезаписывается при повторном запуске."
    echo "stream {"
    echo "    map \$ssl_preread_server_name \$kit_upstream {"
    [[ -n $reality_sni ]] && echo "        $reality_sni 127.0.0.1:${INNER[reality]};"
    [[ -n $xhttp_sni && $xhttp_sni != "$reality_sni" ]] && echo "        $xhttp_sni 127.0.0.1:${INNER[xhttp]};"
    echo "        default 127.0.0.1:${INNER[web]};"
    echo "    }"
    echo "    server {"
    echo "        listen 443;"
    echo "        listen [::]:443;"
    echo "        ssl_preread on;"
    echo "        proxy_pass \$kit_upstream;"
    echo "        proxy_protocol on;"
    echo "        proxy_connect_timeout 10s;"
    echo "        proxy_timeout 1h;"
    echo "    }"
    echo "}"
  } >/etc/nginx/kit-stream.conf
  cat >/etc/nginx/conf.d/kit.conf <<NGX
# Сгенерировано 3x-ui.sh (3x-ui-domain-kit) — перезаписывается при повторном запуске.
server {
    listen 127.0.0.1:${INNER[web]} ssl http2 proxy_protocol;
    server_name _;
    ssl_certificate $CERT;
    ssl_certificate_key $KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;
    server_tokens off;
    # Иначе редирект «добавить слеш» уйдёт на внутренний порт nginx.
    absolute_redirect off;
    access_log off;
$locs
    location $SUB_PATH {
        proxy_pass http://127.0.0.1:${INNER[sub]};
        proxy_set_header Host \$host;
    }
    location $panel_path {
        proxy_pass https://127.0.0.1:$XUI_PANEL_PORT;
        proxy_ssl_verify off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$proxy_protocol_addr;
        proxy_set_header X-Forwarded-For \$proxy_protocol_addr;
        proxy_set_header X-Forwarded-Proto https;
    }
    # Всё остальное — заглушка «Nextcloud» (kit-stub.conf).
    include /etc/nginx/kit-stub.conf;
}
NGX
  grep -q 'kit-stream.conf' /etc/nginx/nginx.conf || echo 'include /etc/nginx/kit-stream.conf;' >>/etc/nginx/nginx.conf
  nginx -t >/tmp/nginx-test.log 2>&1 || { cat /tmp/nginx-test.log >&2; die "nginx не принял конфиг — лог выше."; }
  systemctl enable nginx >/dev/null 2>&1
  systemctl restart nginx
  # Let's Encrypt на IP продлевается каждые несколько дней — nginx раз в сутки перечитывает сертификат.
  echo '17 4 * * * root systemctl reload nginx >/dev/null 2>&1' >/etc/cron.d/kit-nginx-reload
  OPEN+=("443/tcp")
  local i
  for i in $(seq 1 10); do port_busy 443 tcp && return 0; sleep 1; done
  die "nginx не открыл порт 443."
}

# ---------- подписка ----------

setup_subscription() {
  local all upd
  all=$(api POST setting/all '{}')
  SUB_PATH=$(jq -r '.subPath // "/sub/"' <<<"$all")
  if [[ $SUB_PATH == /sub/ || -z $SUB_PATH ]]; then SUB_PATH="/$(rand_str 12 | tr 'A-Z' 'a-z')/"; fi
  if [[ $TRUSTED == yes ]]; then
    # Наружу смотрит kit-sub (подписка с учётом приложения), 3X-UI — только на 127.0.0.1.
    SUB_PORT=2096; SUB_INTERNAL=2097
    # Без subURI панель показывает ссылку на внутренний порт 2097, до которого снаружи не достучаться.
    local uri="https://$HOST:$SUB_PORT$SUB_PATH"
    [[ $SINGLE == yes ]] && uri="https://$HOST$SUB_PATH"
    upd=$(jq -c --arg path "$SUB_PATH" --argjson ip "$SUB_INTERNAL" --arg title "3x-ui-domain-kit" --arg uri "$uri" '
      .subEnable = true | .subPath = $path | .subTitle = $title | .subListen = "127.0.0.1" | .subPort = $ip
      | .subURI = $uri
      | .subCertFile = "" | .subKeyFile = ""
      | .subClashEnable = true | .subClashAutoDetect = true | .subJsonEnable = true | .subJsonAutoDetect = true' <<<"$all")
  else
    SUB_PORT=$(jq -r '.subPort // 2096' <<<"$all")
    upd=$(jq -c --arg path "$SUB_PATH" --arg title "3x-ui-domain-kit" '
      .subEnable = true | .subPath = $path | .subTitle = $title
      | .subClashEnable = true | .subClashAutoDetect = true | .subJsonEnable = true | .subJsonAutoDetect = true' <<<"$all")
  fi
  if [[ $upd != "$all" ]]; then
    api POST setting/update "$upd" >/dev/null
    systemctl restart x-ui
    wait_panel
  fi
  [[ $TRUSTED == yes ]] && install_kit_sub
  if [[ $SINGLE == yes ]]; then SUB_URL="https://$HOST$SUB_PATH$SUBID"
  elif [[ $TRUSTED == yes ]]; then SUB_URL="https://$HOST:$SUB_PORT$SUB_PATH$SUBID"; else SUB_URL="http://127.0.0.1:$SUB_PORT$SUB_PATH$SUBID"; fi
  SUB_FETCH="$(if [[ $TRUSTED == yes ]]; then echo https; else echo http; fi)://$HOST:$SUB_PORT$SUB_PATH$SUBID"
}

install_kit_sub() {
  say "Ставлю подписку с учётом приложения (kit-sub)"
  apt-get install -y -qq python3 python3-yaml >/dev/null
  install -d -m 755 /usr/local/lib/kit-sub /etc/kit-sub
  install -m 644 "$SCRIPT_DIR/kit-sub.py" /usr/local/lib/kit-sub/kit_sub.py
  python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" /usr/local/lib/kit-sub/kit_sub.py || die "kit-sub.py повреждён (синтаксическая ошибка)"
  if [[ $SINGLE == yes ]]; then
    # За nginx: слушаем только localhost, TLS снимает nginx на 443.
    jq -n --arg path "$SUB_PATH" --argjson port "${INNER[sub]}" --arg up "http://127.0.0.1:$SUB_INTERNAL" --arg host "$HOST" \
      '{listen: "127.0.0.1", port: $port, path: $path, upstream: $up, host: $host}' >/etc/kit-sub/config.json
  else
    jq -n --arg path "$SUB_PATH" --argjson port "$SUB_PORT" --arg up "http://127.0.0.1:$SUB_INTERNAL" \
      --arg cert "$CERT" --arg key "$KEY" --arg host "$HOST" \
      '{listen: "0.0.0.0", port: $port, path: $path, upstream: $up, cert: $cert, key: $key, host: $host}' >/etc/kit-sub/config.json
  fi
  chmod 600 /etc/kit-sub/config.json
  cat >/etc/systemd/system/kit-sub.service <<'UNIT'
[Unit]
Description=kit-sub: подписка с учётом приложения (3x-ui-domain-kit)
After=network-online.target x-ui.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/lib/kit-sub/kit_sub.py
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
MemoryMax=64M

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable kit-sub >/dev/null 2>&1
  systemctl restart kit-sub
  local i
  local kp=$SUB_PORT
  [[ $SINGLE == yes ]] && kp=${INNER[sub]}
  for i in $(seq 1 20); do port_busy "$kp" tcp && return 0; sleep 1; done
  journalctl -u kit-sub -n 20 --no-pager >&2 || true
  die "kit-sub не запустился — лог выше."
}

# Ссылки пользователя — из его же подписки (её собирает сама 3X-UI).
# Ссылки пользователя — прямо из подписки 3X-UI внутри сервера (мимо kit-sub, который
# прячет от VPN-приложений vpn:// и tg://). sub_links subId [попыток]
sub_links() {
  local id=$1 tries=${2:-20} raw="" i port=${SUB_INTERNAL:-$SUB_PORT} scheme=http
  [[ -z ${SUB_INTERNAL:-} && $TRUSTED == yes ]] && scheme=https
  for i in $(seq 1 "$tries"); do
    # Настоящий адрес в Host — 3X-UI подставит его в ссылки.
    raw=$(curl -fsSk -m 10 -A "v2rayN/7.0" -H "Host: $HOST:$SUB_PORT" "$scheme://127.0.0.1:$port$SUB_PATH$id" 2>/dev/null) && [[ -n $raw ]] && break
    raw=""; sleep 2
  done
  if grep -q '://' <<<"$raw"; then echo "$raw"; else base64 -d <<<"$raw" 2>/dev/null || true; fi
}

usage() {
  cat <<EOF
3X-UI со всеми протоколами одной командой

  --protocols all     all (по умолчанию: reality, xhttp, ws, hy2), minimal (только REALITY)
                      или список через запятую из: reality,xhttp,ws,hy2
  --port 443          порт REALITY (TCP) и Hysteria2 (UDP), по умолчанию 443
  --sni сайт          сайт для маскировки (по умолчанию подбирается сам)
  --domain vpn.example.com  ОБЯЗАТЕЛЬНО: домен сервера (A-запись уже на этот VPS, порт 80 свободен).
                      Сертификат Let's Encrypt выпускает и продлевает acme.sh
  --email you@example.com   почта для Let's Encrypt (по желанию)
  --cert файл --key файл  свой сертификат на этот домен вместо выпуска через acme.sh
  --no-dns-check      не сверять A-запись домена с IP сервера (домен за Cloudflare-прокси и т. п.)
  --allow-private     в серверных правилах geoip:private → direct (по умолчанию blocked; loopback блокируется всегда)
  --user admin        имя первого клиента
  --no-ufw            не трогать файрвол
  -y                  не задавать вопросов
EOF
}

main "$@"
