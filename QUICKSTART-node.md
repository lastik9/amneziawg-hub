# QUICKSTART · Подключить роутер-узел к мешу

Всё делается **на роутере** (OpenWrt 25.x, apk). Единственное касание хаба —
завести пир: это описано в [`QUICKSTART.md`](QUICKSTART.md) → «Добавь пиров → + Site».
Здесь — только команды роутера. Разбор граблей — в
[`docs/03-router-prep.md`](docs/03-router-prep.md).

**Заполни один раз свои значения:**

```
IP хаба        = 138.16.178.138
Ключ хаба      = <публичный ключ хаба — на хабе: awg show awg0 public-key>
Все сети меша  = 10.0.0.0/24, 192.168.1.0/24, 192.168.52.0/24, 192.168.53.0/24
WG-адрес узла  = город 10.0.0.2 · деревня 10.0.0.3 · тест 10.0.0.4
```

> **Переустановил хаб?** Ключ хаба сменился — возьми новый (`awg show awg0 public-key`
> на хабе) и подставь в `PEER_PUBLIC_KEY` Шага 2. Старые ключи мертвы.

---

## Шаг 1 — поставить пакеты AmneziaWG

Ставим вручную из релизов Slava-Shchipunov — это даёт бинарь `awg`, который нужен
уже на Шаге 2 (генерация ключа узла). `SFX` (архитектура/версия) вычисляется сам.

```sh
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY      # если на роутере ssclash
cd /tmp
. /etc/openwrt_release
VER="$DISTRIB_RELEASE"; ARCH="$DISTRIB_ARCH"
TGT="$(ubus call system board | sed -n 's/.*"target": *"\([^"]*\)".*/\1/p' | tr / _)"
SFX="v${VER}_${ARCH}_${TGT}.apk"
BASE="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v${VER}"
echo "SFX=$SFX"
for p in kmod-amneziawg amneziawg-tools luci-proto-amneziawg; do
  wget -O "$p.apk" "$BASE/${p}_${SFX}"
done
apk add --allow-untrusted /tmp/kmod-amneziawg.apk /tmp/amneziawg-tools.apk /tmp/luci-proto-amneziawg.apk
modprobe amneziawg && awg --version && echo "driver OK"
```

`driver OK` → пакеты встали, `awg` доступен.

> **Не через feeds.** `apk add kmod-amneziawg` из штатных feeds на 25.12.x отдаёт
> `no such package` — пакетов AmneziaWG там нет. Только релизы Slava (команды выше).

---

## Шаг 2 — сгенерировать ключ узла и собрать `awg.env`

**Ключ генерится прямо на роутере** — приватник никуда не уезжает, а его pubkey
пойдёт на хаб (Шаг 3). Профиль обфускации — **байт-в-байт как на хабе**, иначе
туннель не встанет. `ADDRESSES` — WG-адрес узла с `/24`. `ALLOWED_IPS` — все сети меша.

Подставь свой WG-адрес узла в `ADDRESSES` и ключ хаба в `PEER_PUBLIC_KEY`:

```sh
cd /root
NODE_PRIV=$(awg genkey)
NODE_PUB=$(printf '%s' "$NODE_PRIV" | awg pubkey)
cat > /root/awg.env <<EOF
IFACE='awg0'
PRIVATE_KEY='$NODE_PRIV'
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
PEER_PUBLIC_KEY='<публичный ключ хаба>'
PRESHARED_KEY=''
ENDPOINT_HOST='138.16.178.138'
ENDPOINT_PORT='443'
ALLOWED_IPS='10.0.0.0/24, 192.168.1.0/24, 192.168.52.0/24, 192.168.53.0/24'
KEEPALIVE='25'
MAKE_ZONE='1'
ZONE_NAME='awg'
EOF
echo "=== PUBKEY узла для хаба: $NODE_PUB"
```

**Запиши строку `PUBKEY узла для хаба`** — она нужна на Шаге 3. Свериться потом:

```sh
grep -E "^(ADDRESSES|PEER_PUBLIC_KEY)=" /root/awg.env
printf '%s' "$NODE_PRIV" | awg pubkey        # должно совпасть с PUBKEY выше
```

---

## Шаг 3 — на ХАБЕ: завести site-пир (единственное касание хаба)

По [`QUICKSTART.md`](QUICKSTART.md) → «Добавь пиров»: `bash awg-hub.sh` → **2** (пиры)
→ **+ Site**. Вводишь: имя узла, его WG-адрес (напр. `10.0.0.4` — **перебей дефолт**),
его LAN (напр. `192.168.53.0/24`), **pubkey узла из Шага 2**, PSK — нет.

> Пир↔пир форвардинг на хабе (узлы видят друг друга и клиентов) хаб ставит сам.

---

## Шаг 4 — на РОУТЕРЕ: поднять узел

Пакеты уже стоят (Шаг 1) → запускаем с `--no-install`. `awg.env` лежит в `/root` →
скрипт найдёт его сам, без `--env`.

```sh
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY      # если на роутере ssclash
cd /root
wget -O setup-awg.sh "https://raw.githubusercontent.com/lastik9/awg-openwrt-setup/main/setup-awg.sh"
sh setup-awg.sh --mesh --no-install
```

`--mesh` включает меш: устройства за роутером видят весь меш и наоборот (forward,
masq off, ICMP). **Первый прогон попросит `reboot`** (netifd регистрирует протокол) —
соглашайся; после ребута интерфейс поднимется сам.

### Доступ к управлению узла из меша (LuCI / SSH / панель Clash 9090)

По умолчанию `--mesh` **открывает** управление узла — порты `22 80 443 9090` — **всей
mesh-подсети `10.0.0.0/24`**. То есть любой участник меша сможет зайти в LuCI/SSH
узла и в его Clash-панель на `9090`.

| Хочешь | Флаг |
|---|---|
| Открыть всем в меше (по умолчанию) | ничего |
| Сузить до конкретных адресов | `--admin 10.0.0.10,10.0.0.11` |
| Не открывать вовсе (только из LAN узла) | `--no-admin` |

> ⚠️ **Про безопасность — прочитай.** «Открыто всем в меше» удобно для **личного**
> меша, где все пиры — твои устройства. Но как только выдашь клиентский конфиг
> другому человеку, он тоже попадёт в `10.0.0.0/24` и получит доступ к управлению
> **всех** узлов (LuCI/SSH + Clash). Если меш не полностью твой — сузь через
> `--admin` до своих роуминг-адресов или закрой `--no-admin`.

---

## Шаг 5 — проверить

**Сначала ключи** (главная проверка — на ней ловятся 90% проблем):

```sh
# на РОУТЕРЕ: свой pubkey
awg show awg0 public-key
# на ХАБЕ: этот же pubkey должен стоять у пира
awg show awg0 | grep -A4 peer        # ищи строку peer: <pubkey узла>
```

На **хабе** у пира узла должны быть `endpoint:`, `latest handshake:` и
`... received` **≠ 0**. Нет `endpoint` + `0 B received` при живом пире = неверный
ключ (сверь pubkey крест-накрест), **не** лезь в версии драйвера.

**Пинги:**

```sh
# на РОУТЕРЕ
ping -c3 10.0.0.1                    # узел → хаб
# на ХАБЕ
ping -c3 10.0.0.4                    # хаб → узел (свой WG-адрес узла)
ping -c3 192.168.53.1               # хаб → LAN узла (свой LAN-адрес роутера)
```

Все 0% loss = узел в меше.

**Панель Clash с телефона** (если оставил дефолтный открытый доступ): открой в
браузере `http://<LAN-адрес роутера>:9090/ui/` — должно пустить.

**Ребут на устойчивость:** `reboot`, через ~50 сек — `awg show awg0 | grep handshake`
(свежий, received ≠ 0) и `ping -c3 10.0.0.1`. Встало само = узел закреплён.

---

## Добавляешь второй / третий узел?

Повтори Шаги 1–5, подставив его WG-адрес и LAN. Так как в `ALLOWED_IPS` (Шаг 2) у
всех узлов уже прописаны **все** сети меша — старые узлы трогать не надо, новая LAN
уже в списке. (Если держишь урезанный `ALLOWED_IPS` — допиши новую LAN на старых
узлах: `uci add_list network.@amneziawg_awg0[0].allowed_ips='<новая LAN>'` →
`uci commit network && /etc/init.d/network reload`.)

**Сменился ключ/endpoint хаба?** Обнови пир без пересоздания интерфейса:

```sh
sh setup-awg.sh --mesh --no-install --reconnect
```

---

## Если не работает — частые причины

| Симптом | Причина | Лечение |
|---|---|---|
| `no such package` при установке | пакетов AWG нет в feeds | ставь из релизов Slava (Шаг 1), не через `apk add` из feeds |
| Нет хендшейка, `0 B received` у пира | неверный ключ пира ИЛИ профиль обфускации не совпал | сверь pubkey крест-накрест (Шаг 5); сверь `awg show` с хабом байт-в-байт |
| `Port Unreachable` с хаба | masq на зоне awg | `--mesh` уже снял; вручную `uci set firewall.awg.masq=0` |
| Узел↔хаб есть, узел↔узел нет | хаб не форвардит awg↔awg | хаб ставит правило сам; проверь `iptables -L ufw-user-forward -n -v \| grep awg0` (`-v` обязателен) |
| С хаба пинг узла есть, а LAN нет | на хабе нет kernel-маршрута на LAN узла | пересобери хаб (меню) — `PostUp` пропишет маршрут и переживёт ребут |
| Узел отвалился после пересборки хаба | `syncconf` сбросил сессию, узел за NAT | на узле `ifdown awg0; ifup awg0` (пнуть хендшейк) |
| LuCI/SSH/9090 из меша не открывается | запускал с `--no-admin` | подними без `--no-admin`; проверь `nft list chain inet fw4 input_awg \| grep dport` — жди `22, 80, 443, 9090` |
| Клиент (телефон) не видит LAN узла | в конфиге клиента `AllowedIPs` без LAN узла | добавь все сети меша в конфиг клиента и переимпортируй QR |
| Своя LAN видна, чужая нет | `ALLOWED_IPS` без чужих LAN | держи все сети (Шаг 2) |
