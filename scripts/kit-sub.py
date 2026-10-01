#!/usr/bin/env python3
"""Подписка с учётом приложения — посредник перед подпиской 3X-UI.

https://github.com/mihanic89/3x-ui-domain-kit

Слушает публичный адрес подписки (HTTPS) и ходит в подписку 3X-UI на 127.0.0.1:
  * Clash / Mihomo (yaml) и JSON Xray — конфиг 3X-UI плюс зеркальные правила маршрутизации
    (российское напрямую, остальное через прокси, см. RU_SUFFIXES ниже);
  * остальные приложения и браузер — ответ 3X-UI как есть (ссылки или страница);
  * заголовок Subscription-Userinfo: expire=0 («бессрочно») убирается — иначе
    приложения показывают срок «01.01.1970».

Настройки — /etc/kit-sub/config.json. Сертификат перечитывается сам после продления.
"""

import http.server
import json
import os
import re
import socket
import ssl
import threading
import time
import urllib.error
import urllib.request

import yaml

CONFIG = os.environ.get("KIT_SUB_CONFIG", "/etc/kit-sub/config.json")
SUB_ID = re.compile(r"^[A-Za-z0-9_.@-]{1,64}$")
PASS_HEADERS = ("content-type", "content-disposition", "profile-title", "profile-update-interval",
                "profile-web-page-url", "subscription-userinfo", "support-url", "cache-control")

with open(CONFIG, encoding="utf-8") as f:
    CONF = json.load(f)
PATH = "/" + CONF["path"].strip("/") + "/"


def log(msg):
    print(msg, flush=True)


def upstream(sub_id, ua, host, accept):
    """GET к подписке 3X-UI. Возвращает (код, заголовки, тело) или (None, {}, b"")."""
    req = urllib.request.Request(CONF["upstream"].rstrip("/") + PATH + sub_id, headers={
        "User-Agent": ua, "Host": host, "Accept": accept or "*/*"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, {k.lower(): v for k, v in r.getheaders()}, r.read()
    except urllib.error.HTTPError as e:
        return e.code, {k.lower(): v for k, v in e.headers.items()}, e.read()
    except (urllib.error.URLError, OSError, socket.timeout) as e:
        log(f"upstream недоступен: {e}")
        return None, {}, b""


def fix_userinfo(value):
    # «expire=0» значит «бессрочно», но приложения рисуют 01.01.1970 — убираем.
    parts = [p.strip() for p in value.split(";") if p.strip() and p.strip() != "expire=0"]
    return "; ".join(parts)


# Правила клиента — зеркало серверных (сервер блокирует RU-адреса, торренты и т. п.):
# российское клиент открывает напрямую, мимо VPN, остальное идёт через прокси.
# habr.com сервер пропускает (direct), поэтому клиент шлёт его через прокси — правило стоит
# выше российских. Свои исключения: "client_proxy_domains" в /etc/kit-sub/config.json.
RU_SUFFIXES = ("ru", "su", "xn--p1ai")
TORRENT_PROCESSES = ("qbittorrent", "qbittorrent.exe", "transmission-qt", "transmission-gtk",
                     "utorrent.exe", "bittorrent.exe", "deluge", "deluge.exe", "vuze.exe", "tixati.exe")


def proxy_domains():
    return ["habr.com"] + [d for d in CONF.get("client_proxy_domains", []) if isinstance(d, str) and d]


def clash_client_rules(proxy_group):
    rules = []
    if proxy_group:
        rules += [f"DOMAIN-SUFFIX,{d},{proxy_group}" for d in proxy_domains()]
    rules += [f"PROCESS-NAME,{p},DIRECT" for p in TORRENT_PROCESSES]
    rules += [f"DOMAIN-SUFFIX,{s},DIRECT" for s in RU_SUFFIXES]
    rules += ["GEOIP,RU,DIRECT,no-resolve", "GEOIP,LAN,DIRECT,no-resolve"]
    return rules


def add_clash_rules(clash_yaml):
    """Дописывает в начало rules Clash-конфига зеркальные правила. Группа для habr.com — та,
    куда ведёт замыкающее MATCH (иначе первая группа конфига)."""
    cfg = yaml.safe_load(clash_yaml)
    if not isinstance(cfg, dict):
        return clash_yaml
    old = [r for r in (cfg.get("rules") or []) if isinstance(r, str)]
    group = None
    for r in reversed(old):
        parts = r.split(",")
        if parts[0].strip() == "MATCH" and len(parts) > 1:
            group = parts[1].strip()
            break
    if group is None:
        groups = [g.get("name") for g in cfg.get("proxy-groups") or [] if isinstance(g, dict) and g.get("name")]
        group = groups[0] if groups else None
    mine = clash_client_rules(group)
    cfg["rules"] = mine + [r for r in old if r not in mine]
    if not any(r.startswith("MATCH,") for r in cfg["rules"]) and group:
        cfg["rules"].append(f"MATCH,{group}")
    return yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False).encode()


def json_client_rules(proxy_tag):
    rules = [{"type": "field", "domain": [f"domain:{d}" for d in proxy_domains()], "outboundTag": proxy_tag},
             {"type": "field", "protocol": ["bittorrent"], "outboundTag": "direct"},
             {"type": "field", "domain": [f"regexp:.*\\.{s}$" for s in RU_SUFFIXES], "outboundTag": "direct"},
             {"type": "field", "ip": ["geoip:ru", "geoip:private"], "outboundTag": "direct"}]
    return rules


def add_json_rules(body):
    """Подписка 3X-UI в формате JSON (список конфигов Xray): те же правила — в начало routing.rules."""
    data = json.loads(body)
    items = data if isinstance(data, list) else [data]
    for item in items:
        if not isinstance(item, dict):
            continue
        tags = [o.get("tag") for o in item.get("outbounds") or [] if isinstance(o, dict)]
        if "direct" not in tags:
            continue  # без direct правилам не на что сослаться — конфиг не трогаем
        proxy_tag = "proxy" if "proxy" in tags else tags[0]
        routing = item.setdefault("routing", {})
        mine = json_client_rules(proxy_tag)
        routing["rules"] = mine + [r for r in routing.get("rules") or [] if r not in mine]
    return json.dumps(data, ensure_ascii=False).encode()


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "nginx"
    sys_version = ""
    timeout = 20  # зависшие соединения не держим

    def setup(self):
        # TLS-рукопожатие — в потоке запроса, а не в общем цикле приёма соединений.
        # Без сертификата (за nginx, на 127.0.0.1) работаем по обычному HTTP.
        self.request.settimeout(self.timeout)
        if self.server.ssl_ctx is not None:
            self.request = self.server.ssl_ctx.wrap_socket(self.request, server_side=True)
        super().setup()

    def handle(self):
        try:
            super().handle()
        except (ssl.SSLError, ConnectionError, socket.timeout, OSError):
            pass

    def log_message(self, fmt, *args):  # без IP клиентов в логах
        pass

    def send_plain(self, code, text=""):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if not path.startswith(PATH):
            return self.send_plain(404, "404 page not found")
        sub_id = path[len(PATH):]
        if not SUB_ID.match(sub_id):
            return self.send_plain(404, "404 page not found")
        ua = self.headers.get("User-Agent", "")
        host = self.headers.get("Host", CONF.get("host", ""))
        accept = self.headers.get("Accept", "")
        code, headers, body = upstream(sub_id, ua, host, accept)
        if code is None:
            return self.send_plain(502, "subscription backend is unavailable")

        ctype = headers.get("content-type", "")
        # В журнал — только приложение и что ему отдали, без IP.
        log(f"{ua[:80]!r} → {ctype.split(';')[0] or '?'}")
        # Зеркальные правила маршрутизации — для конфигов Clash/Mihomo (yaml) и JSON Xray.
        # Список ссылок (base64) правил не несёт: там маршрутизацию задаёт само приложение.
        if code == 200 and CONF.get("client_rules", True):
            try:
                if "yaml" in ctype:
                    body = add_clash_rules(body)
                elif "json" in ctype:
                    body = add_json_rules(body)
            except (yaml.YAMLError, ValueError, UnicodeError) as e:
                log(f"не удалось добавить правила маршрутизации: {e}")

        self.send_response(code)
        for k in PASS_HEADERS:
            if k in headers:
                v = fix_userinfo(headers[k]) if k == "subscription-userinfo" else headers[k]
                if v:
                    self.send_header(k.title(), v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    ssl_ctx = None

    def handle_error(self, request, client_address):  # обрывы TLS от сканеров — не ошибка
        pass
    address_family = socket.AF_INET6 if ":" in CONF.get("listen", "") else socket.AF_INET


def main():
    cert, key = CONF.get("cert"), CONF.get("key")
    if not cert:
        srv = Server((CONF.get("listen", "127.0.0.1"), int(CONF["port"])), Handler)
        log(f"kit-sub слушает http://{CONF.get('listen', '127.0.0.1')}:{CONF['port']}{PATH} (TLS снимает nginx)")
        srv.serve_forever()
        return
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(cert, key)
    stamp = [os.path.getmtime(cert)]

    def reload_cert():
        # Let's Encrypt на IP живёт 6 дней — после продления берём новый сертификат без перезапуска.
        while True:
            time.sleep(600)
            try:
                m = os.path.getmtime(cert)
                if m != stamp[0]:
                    ctx.load_cert_chain(cert, key)
                    stamp[0] = m
                    log("сертификат обновлён")
            except (OSError, ssl.SSLError) as e:
                log(f"не удалось перечитать сертификат: {e}")

    threading.Thread(target=reload_cert, daemon=True).start()
    srv = Server((CONF.get("listen", "0.0.0.0"), int(CONF["port"])), Handler)
    srv.ssl_ctx = ctx
    log(f"kit-sub слушает {CONF.get('listen', '0.0.0.0')}:{CONF['port']}{PATH}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
