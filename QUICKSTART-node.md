# QUICKSTART · Добавить узел в меш за 5 шагов

Плоская сеть: хаб в центре, роутеры-лучи, все видят всех. Подробности и разбор
граблей — в [`docs/03-router-prep.md`](docs/03-router-prep.md). Здесь только команды.

**Заполни один раз свои значения:**

```
IP хаба        = 138.16.178.138
Ключ хаба      = <публичный ключ хаба — узнать на хабе: awg show awg0 public-key>
Все сети меша  = 10.0.0.0/24, 192.168.1.0/24, 192.168.52.0/24, 192.168.53.0/24
```

WG-адреса узлов по топологии: город `10.0.0.2`, деревня `10.0.0.3`, тест `10.0.0.4`.

> **Ключ хаба забыл / переустановил сервер?** Посмотреть публичный ключ на хабе:
> ```sh
> awg show awg0 public-key
> ```
> Свежая переустановка хаба = новый ключ — перевыпусти его во всех `awg.env` узлов.

---

## Шаг 1 — на ХАБЕ: завести узел

```sh
# сгенерить ключи узла (приватник потом уедет на роутер)
awg genkey | tee /tmp/node.key | awg pubkey | tee /tmp/node.pub
cat /tmp/node.pub /tmp/node.key
# меню: 2 (пиры) → 3 (+ Site) → имя, WG-адрес узла, его LAN, вставить node.pub, PSK=N
cd /root && bash awg-hub.sh
```

> Пир↔пир форвардинг на хабе (чтобы узлы видели друг друга и клиентов) `bootstrap` ставит сам — руками `ufw route allow ... awg0 awg0` добавлять не нужно.

---

## Шаг 2 (опционально) — на РОУТЕРЕ: поставить пакеты вручную

Обычно этот шаг **не нужен**: `setup-awg.sh` из Шага 4 (без `--no-install`) сам скачивает
официальный установщик, который определяет архитектуру/версию и ставит пакеты. Ручная
установка — фолбэк, если авто-установщик не прошёл (например, перехватчик на роутере).

`SFX` определяется сам из `openwrt_release` + `ubus call system board`:

```sh
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY      # если на роутере ssclash
cd /tmp
. /etc/openwrt_release
VER="$DISTRIB_RELEASE"; ARCH="$DISTRIB_ARCH"
TGT="$(ubus call system board | sed -n 's/.*"target": *"\([^"]*\)".*/\1/p' | tr / _)"
SFX="v${VER}_${ARCH}_${TGT}.apk"                          # ← вычислен автоматически
BASE="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v${VER}"
echo "SFX=$SFX"
for p in kmod-amneziawg amneziawg-tools luci-proto-amneziawg; do
  wget -O "$p.apk" "$BASE/${p}_${SFX}"
done
apk add --allow-untrusted /tmp/kmod-amneziawg.apk
apk add --allow-untrusted /tmp/amneziawg-tools.apk
apk add --allow-untrusted /tmp/luci-proto-amneziawg.apk
modprobe amneziawg && echo OK
```

`OK` → пакеты встали. Иначе см. `03-router-prep.md` §2.

---

## Шаг 3 — на РОУТЕРЕ: собрать awg.env

Подставь: `PRIVATE_KEY` (из `/tmp/node.key` с хаба), `ADDRESSES` (WG-адрес узла
с `/24`), профиль обфускации — **байт-в-байт как на хабе**, `ENDPOINT_HOST` = IP хаба.
`ALLOWED_IPS` = **все сети меша** (одинаковый на всех узлах).

```sh
cat > /root/awg.env <<'EOF'
IFACE='awg0'
PRIVATE_KEY='<из /tmp/node.key>'
ADDRESSES='10.0.0.4/24'
DNS=''
MTU='1280'
JC='8'
JMIN='24'
JMAX='180'
S1='86'
S2='128'
S3='32'
S4='12'
H1='5000000-9000000'
H2='15000000-25000000'
H3='40000000-70000000'
H4='150000000-400000000'
I1='<b 0xc000000001><r 64><t>'
PEER_PUBLIC_KEY='<публичный ключ хаба: awg show awg0 public-key>'
PRESHARED_KEY=''
ENDPOINT_HOST='138.16.178.138'
ENDPOINT_PORT='443'
ALLOWED_IPS='10.0.0.0/24, 192.168.1.0/24, 192.168.52.0/24, 192.168.53.0/24'
KEEPALIVE='25'
MAKE_ZONE='1'
ZONE_NAME='awg'
EOF
```

---

## Шаг 4 — на РОУТЕРЕ: поднять узел одной командой

```sh
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY      # если на роутере ssclash
cd /root
wget -O setup-awg.sh "https://raw.githubusercontent.com/lastik9/awg-openwrt-setup/main/setup-awg.sh"
sh setup-awg.sh --mesh
```

> Без `--no-install` скрипт сам поставит пакеты (определит архитектуру/версию, скачает
> официальный установщик). Если ты уже ставил пакеты вручную (Шаг 2), он это увидит и
> установку пропустит. Флаг `--no-install` нужен, только если хочешь запретить установку явно.
> Первый прогон попросит `reboot` — согласись.

`--mesh` включает всё для меша: устройства за роутером видят весь меш и наоборот
(forward, masq off, ICMP). Первый раз попросит **reboot** — соглашайся.

> **Опция.** Если хочешь заходить в админку роутера (LuCI/SSH) удалённо через меш —
> добавь `--admin <адрес>`, напр. `--mesh --admin 10.0.0.10` (откроет только этому
> адресу). Без `--admin` в админку роутера заходишь из его домашней сети как обычно;
> для «все видят все устройства» этот флаг не нужен.

---

## Шаг 5 — проверить

С хаба:

```sh
ping -c3 <WG-адрес узла>     # напр. 10.0.0.4
ping -c3 <LAN-роутера>       # напр. 192.168.53.1 — устройства за узлом
```

Оба 0% loss = **узел в меше, все видят всех.**

---

## Добавляешь второй/третий узел?

Повтори шаги 1–5 для него. Потом **обнови `ALLOWED_IPS` на уже стоящих узлах** —
чтобы они знали новую LAN. На каждом старом роутере:

```sh
# посмотреть текущий список
uci show network | grep allowed_ips
# добавить новую LAN (подставь секцию @amneziawg_awg0[N] и подсеть)
uci add_list network.@amneziawg_awg0[0].allowed_ips='<новая LAN>'
uci commit network && /etc/init.d/network reload
```

> Проще: держи в `ALLOWED_IPS` сразу **все** сети (как в шаге 3) — тогда старые узлы
> трогать не надо, новая LAN уже в списке.

---

## Если не работает — частые причины

| Симптом | Причина | Лечение |
|---|---|---|
| Нет хендшейка | профиль обфускации не совпал | сверь `awg show` с хабом байт-в-байт |
| `Port Unreachable` с хаба | masq на зоне awg | `--mesh` уже снял; вручную `uci set firewall.awg.masq=0` |
| Узел↔хаб есть, узел↔узел нет | хаб не форвардит awg↔awg | `bootstrap` ставит правило сам; проверь `iptables -L ufw-user-forward -n -v \| grep awg0` (флаг `-v` обязателен) |
| С хаба пинг узла есть, а его LAN нет | на хабе нет kernel-маршрута на LAN узла | пересобери хаб (меню 1) — `PostUp` пропишется в `awg0.conf` и переживёт ребут |
| Узел отвалился после пересборки хаба | `syncconf` сбросил сессию, узел за NAT не достучался | на узле `ifdown awg0; ifup awg0` (пнуть новый хендшейк) |
| Пинг узла есть, а LuCI/SSH из меша нет | `input=REJECT` у зоны `awg` (режет TCP на сам роутер) | точечно: правило `src=awg proto=tcp dest_port='22 80 443' target=ACCEPT`; или `uci set firewall.<awg-zone>.input=ACCEPT` |
| Клиент (телефон) не видит LAN узла | клиентский `.conf` выдан до появления узла | в `AllowedIPs` конфига клиента добавь LAN узла и переимпортируй QR |
| LAN своя видна, чужая нет | `ALLOWED_IPS` без чужих LAN | добавь все сети (шаг 3) |
