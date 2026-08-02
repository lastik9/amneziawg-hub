# 03 · Подготовка роутера (site-узел)

Пошаговая подготовка OpenWrt-роутера как **site-узла** меша: пакеты AmneziaWG,
интерфейс с профилем обфускации, peer к хабу, firewall под меш и сосуществование с
обходом перехватчика (ssclash / podkop). Инструкция написана по **живому прогону**
Тест-узла (`10.0.0.4` / `192.168.53.0/24`) на OpenWrt 25.12.5, apk, mediatek/filogic.

Параметры конкретного узла (WG-адрес, `allowed_ips`, серверный pubkey, UCI-блок
профиля обфускации) выдаёт `scripts/awg-hub.sh` → меню пиров → **+ Site**. Сначала
заводишь узел на хабе (получаешь эти параметры), потом настраиваешь роутер.

> **Модели «меш» vs «podkop».** Установочный скрипт
> [`awg-openwrt-setup`](https://github.com/lastik9/awg-openwrt-setup) поддерживает
> флаг **`--mesh`**: один прогон делает всё для меша any-to-any — `masq=0`,
> пересылка `lan↔awg` в обе стороны, ICMP по мешу, и (с `--admin`) доступ к
> управлению узла только с заданных адресов. Без `--mesh` скрипт работает в
> podkop-режиме (masq включён, forward не добавляется). Ручные команды из секции 5
> оставлены как справочник — что именно делает `--mesh` под капотом.

---

## 0. Что должно быть готово на хабе

- Хаб поднят (`docs/02-server-awg.md`), известны его **публичный ключ** и
  **endpoint** (`IP:443`).
- Узел заведён на хабе через **+ Site**: имя, WG-адрес (по топологии — деревня
  `.3` / город `.2` / тест `.4`), LAN-подсеть узла. Хаб выдал **UCI-блок** и сам
  добавил маршрут на LAN узла (проверь `ip route | grep <подсеть>` на хабе).
- Приватный ключ узла **остаётся на роутере** — на хаб уходит только pubkey.
  Пару генерируем на роутере (после установки пакетов) либо временно на хабе с
  последующим переносом приватника в `awg.env` (и удалением с хаба).

> **Форвардинг пир↔пир на хабе — обязателен для меша.** По умолчанию хаб не
> пересылает трафик между двумя пирами (например, клиент → site-узел, или узел →
> узел): это разные пиры одного интерфейса `awg0`, и firewall хаба должен явно
> разрешить `awg0 → awg0`. Без этого узел↔хаб работает, а узел↔узел и клиент↔узел —
> нет. На хабе (ufw): `ufw route allow in on awg0 out on awg0`. Проверка:
> `iptables -L ufw-user-forward -n | grep awg0` — должна быть строка `ACCEPT awg0 awg0`.

> **Any-to-any: каждый узел должен знать ЧУЖИЕ LAN.** `allowed_ips` пира-хаба на
> узле = вся меш-сеть **плюс все чужие site-подсети**, иначе ответ в чужую LAN не
> уйдёт в туннель. Проще всего держать единый список на всех узлах — вся меш + все
> LAN; свою подсеть узел просто проигнорирует. Пример для трёх LAN:
> `10.0.0.0/24, 192.168.1.0/24, 192.168.52.0/24, 192.168.53.0/24`. При добавлении
> нового узла список обновляется на всех (это ручной шаг — хаб не рассылает его сам).

---

## 1. Требования и прошивка

- **OpenWrt 24.10+ / 25.12.x**, официальная ванильная прошивка (kmod-amneziawg на
  кастом-сборки не встаёт — привязан к vermagic ядра).
- Пакетный менеджер: на 25.x — **apk**, на 24.10 и старее — opkg.
- Модемный узел (город/деревня за LTE) — WAN обычно `wwan0`; из-за оверхеда несущей
  **MTU на awg-интерфейсе = 1280** (секция 3).
- Доступ по SSH, root, интернет на роутере на момент установки.

Определи target/subtarget устройства (нужно для выбора пакетов). Быстро — из вывода
`apk update` (строки репозиториев содержат `<target>/<subtarget>` и арх), либо
`ubus call system board`. Пример Тест-узла: `mediatek/filogic`,
`aarch64_cortex-a53`, ядро `6.12.94-1-<hash>`.

---

## 2. Пакеты AmneziaWG

В официальном фиде OpenWrt пакетов AmneziaWG нет — берём сборку из
[Slava-Shchipunov/awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt)
(релизы по версиям OpenWrt, отдельный `.apk` под каждый target/subtarget).

> ⚠️ **Две грабли, пойманные вживую — важно.**
>
> 1. **Апстрим-инсталлер не всегда находит kmod.** `amneziawg-install.sh` (и
>    вызывающий его `setup-awg.sh`) может упасть с
>    `Error downloading kmod-amneziawg` даже когда релиз под твою версию **есть**.
>    Обход — качать три `.apk` из релиза напрямую.
> 2. **Активный ssclash ломает скачивание с GitHub.** Если на роутере включён
>    проксирующий профиль ssclash (`/etc/profile.d/ssclash-proxy.sh` экспортит
>    `http_proxy=127.0.0.1:7890`), `wget` идёт через Clash, и на GitHub-редиректе
>    (`release-assets.githubusercontent.com`) отдаёт `HTTP error 400`. Лечится
>    снятием прокси на время скачивания: `unset http_proxy https_proxy`.

**2.1. Проверить, что релиз под твою версию/таргет существует** (пример — 25.12.5,
filogic; подставь свои):

```sh
wget -qO- "https://api.github.com/repos/Slava-Shchipunov/awg-openwrt/releases/tags/v25.12.5" \
  | grep -o '"browser_download_url":[^,]*filogic[^,]*' | grep -iE 'amnezia'
```

Ждём три ссылки: `kmod-amneziawg`, `amneziawg-tools`, `luci-proto-amneziawg`
(`luci-i18n-amneziawg-ru` — опционально). Если релиза под твою версию нет — берётся
ближайший с **тем же vermagic ядра**, иначе kmod не встанет; в крайнем случае —
пересборка через форк + GitHub Actions (описано в README апстрим-репо).

**2.2. Скачать напрямую (мимо Clash-прокси):**

```sh
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
cd /tmp
BASE="https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v25.12.5"
SFX="v25.12.5_aarch64_cortex-a53_mediatek_filogic.apk"   # ← подставь свой arch_target_subtarget
for p in kmod-amneziawg amneziawg-tools luci-proto-amneziawg; do
  wget -O "$p.apk" "$BASE/${p}_${SFX}" && echo "ok: $p" || echo "FAIL: $p"
done
ls -la /tmp/*.apk
```

Проверь размеры: не нули и не ~1 КБ (html-заглушка), а десятки КБ. Если busybox
`wget` спотыкается на TLS/редиректе — поставь `apk add curl` и качай
`curl -fL -o "$p.apk" ...`.

**2.3. Установить строго в порядке kmod → tools → luci-proto** (сторонний репо без
подписи OpenWrt → `--allow-untrusted`):

```sh
apk add --allow-untrusted /tmp/kmod-amneziawg.apk
apk add --allow-untrusted /tmp/amneziawg-tools.apk
apk add --allow-untrusted /tmp/luci-proto-amneziawg.apk
```

**2.4. Проверить, что модуль грузится под текущее ядро** (главный индикатор
совпадения vermagic):

```sh
apk list --installed | grep -i amnezia
modprobe amneziawg && echo "MODULE OK" || echo "MODULE FAIL"
awg --version
```

`MODULE OK` + версия от `awg` = пакеты готовы. `MODULE FAIL` — vermagic не совпал
(взят пакет не под то ядро), ищи релиз ровно под свою сборку.

---

## 3. Интерфейс `awg0` + профиль обфускации

Настройку интерфейса выполняет `awg-openwrt-setup` из файла `awg.env`. Пакеты уже
стоят (секция 2), поэтому запускаем скрипт с `--no-install`.

**3.1. Подготовить пару ключей узла** (если ещё нет). Приватник остаётся на
роутере:

```sh
awg genkey | tee /tmp/awg.key | awg pubkey | tee /tmp/awg.pub
cat /tmp/awg.pub     # этот pubkey уходит на хаб в «+ Site», если узел ещё не заведён
```

**3.2. Собрать `/root/awg.env`.** Значения профиля обфускации — **байт-в-байт как на
хабе** (иначе нет рукопожатия); берутся из UCI-блока, который выдал хаб. Ключевые
отличия от шаблона под меш:

- `ADDRESSES` — с маской **`/24`**, не `/32`: тогда маршрут на всю WG-сеть
  (`10.0.0.0/24`) появится через интерфейс сам, без `route_allowed_ips`.
- `MTU='1280'` — модемный узел.
- `ALLOWED_IPS='10.0.0.0/24'` (+ через запятую **чужие** site-LAN, когда появятся);
  **без** `0.0.0.0/0` — меш internal-only.

```sh
cat > /root/awg.env <<'EOF'
IFACE='awg0'
PRIVATE_KEY='<приватник_узла из /tmp/awg.key>'
ADDRESSES='10.0.0.4/24'
DNS=''
MTU='1280'
# профиль обфускации — байт-в-байт с хабом
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
# peer = хаб
PEER_PUBLIC_KEY='<публичный_ключ_сервера>'
PRESHARED_KEY=''                 # 'Y'-вариант: сюда PSK, тот же, что на хабе
ENDPOINT_HOST='<IP_хаба>'
ENDPOINT_PORT='443'
ALLOWED_IPS='10.0.0.0/24'
KEEPALIVE='25'
MAKE_ZONE='1'
ZONE_NAME='awg'
EOF
```

> Heredoc с `'EOF'` в **одинарных** кавычках обязателен — иначе шелл съест `$` и
> угловые скобки в `I1`. После — сверь: `grep -E 'I1|PRIVATE_KEY|ADDRESSES' /root/awg.env`.

**3.3. Создать интерфейс:**

```sh
cd /root
wget -O setup-awg.sh "https://raw.githubusercontent.com/lastik9/awg-openwrt-setup/main/setup-awg.sh"
sh setup-awg.sh --no-install
```

Скрипт создаст `network.awg0` (`proto amneziawg`, адрес, MTU, профиль), peer, зону
`awg` и поднимет интерфейс.

> ⚠️ **Первый запуск = один reboot.** `proto amneziawg` регистрируется в netifd
> только после перезагрузки (свежепоставленный `/lib/netifd/proto/amneziawg.sh` не
> подхватывается на лету). Скрипт это определит и предложит reboot с 15-сек
> отсчётом — соглашайся. На повторных запусках reboot не нужен.

---

## 4. Peer к хабу

Peer создаётся тем же `awg.env`/скриптом (секция 3), отдельных действий не требует.
Что проверить в результате (`awg show awg0`):

- `endpoint: <IP_хаба>:443`, `persistent keepalive: every 25 seconds`;
- `allowed ips: 10.0.0.0/24` (+ чужие site-LAN) — **без** `0.0.0.0/0`;
- профиль (jc/jmin/jmax, s1–s4, h1–h4, i1) совпадает с хабом.

`route_allowed_ips` в UCI-блоке хаба стоит `1`, но в меш-модели мы полагаемся на
адрес `/24` и держим маршруты явными — скрипт ставит `route_allowed_ips=0`. Не
смешивай модели: одна из двух (маска `/24` **или** `route_allowed_ips=1`) даёт
маршрут на меш; мы берём первую.

---

## 5. Firewall под меш

**Проще всего — флаг `--mesh`** (делает всё из этой секции автоматически):

```sh
sh setup-awg.sh --no-install --mesh --admin 10.0.0.10
```

`--mesh` ставит `masq=0`, пересылку `lan↔awg` в обе стороны и ICMP по мешу;
`--admin <ip[,ip]>` открывает SSH/LuCI узла из меша **только** указанным адресам
(без `--admin` управление из меша закрыто — доступно лишь из LAN узла). Ниже — что
именно делают правки, если нужно вручную или для понимания.

Скрипт создаёт зону `awg`: `input/forward REJECT`, `output ACCEPT`. Для меша LAN↔LAN
нужны **три** правки. Без них симптом — с хаба `ping <узел>` даёт
**`Destination Port Unreachable`** (пакет доходит, но masq/reject ломает ответ).

**5.1. Пересылка `lan↔awg`** (any-to-any: клиенты узла в меш и встречная инициатива
из меша в LAN узла):

```sh
uci add firewall forwarding; uci set firewall.@forwarding[-1].src='awg'; uci set firewall.@forwarding[-1].dest='lan'
uci add firewall forwarding; uci set firewall.@forwarding[-1].src='lan'; uci set firewall.@forwarding[-1].dest='awg'
uci commit firewall && /etc/init.d/firewall reload
```

**5.2. Снять masquerade с зоны `awg`.** Для internal-only меша masq **вреден** — он
переписывает source-адреса, и conntrack не находит сессию для ответа (это и есть
`Port Unreachable`). Masq нужен только в podkop-режиме (трафик наружу через туннель).

```sh
uci set firewall.awg.masq='0'
uci commit firewall && /etc/init.d/firewall reload
nft list ruleset | grep -c "awg traffic"   # ждём 0 — правило masq ушло
```

**5.3. Разрешить ICMP на input зоны `awg`.** `input REJECT` режет ping к самому
роутеру по его WG-адресу — узлы меша должны пинговаться:

```sh
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-awg-ICMP'
uci set firewall.@rule[-1].src='awg'
uci set firewall.@rule[-1].proto='icmp'
uci set firewall.@rule[-1].icmp_type='echo-request'
uci set firewall.@rule[-1].target='ACCEPT'
uci commit firewall && /etc/init.d/firewall reload
```

> Порядок диагностики, если пинг не идёт: сначала `masq=0` (лечит `Port
> Unreachable` к WG-адресу узла и к LAN за ним), затем ICMP-allow (лечит остаточный
> reject именно к самому роутеру). На живом прогоне понадобились **обе** правки.

---

## 6. Сосуществование с обходом перехватчика (ssclash / podkop)

AmneziaWG (меш-транспорт) и Clash/ssclash (обход DPI для LAN-клиентов) — **две
параллельные системы, не матрёшка.** Заворачивать AWG в Clash не нужно: обфускация
AWG 2.0 пробивает DPI провайдера сама (проверено — хендшейк встаёт напрямую через
LTE-оператора). Clash нужен только чтобы LAN-клиенты за роутером ходили на
заблокированные сайты.

Почему они не конфликтуют (на примере ssclash с TPROXY, `nft table inet clash`):

- захват в Clash идёт только из `iifname "br-lan"` (форвард LAN-клиентов); цепочка
  `output` роутера пустая — **собственный AWG-хендшейк роутера (его OUTPUT) в Clash
  не попадает**;
- в `CLASH_MARK` есть `ip daddr 10.0.0.0/8 return` и `192.168.0.0/16 return` — весь
  меш и чужие site-LAN идут мимо прокси (DIRECT на уровне пакетов);
- `tun: auto-route/auto-redirect: false` — TUN Mihomo не перехватывает маршруты, не
  дерётся с awg0.

**Портируемая страховка в `config.yaml` Mihomo** (нужна прежде всего на площадках,
где обвязка ловит и OUTPUT роутера, напр. Keenetic/XKeen; на ssclash безвредна):
рядом с `GEOIP,private,DIRECT` добавить эндпоинт хаба явным DIRECT, выше catch-all
`MATCH`:

```yaml
- IP-CIDR,<IP_хаба>/32,DIRECT,no-resolve   # AWG-хаб: транспорт всегда напрямую
```

Иначе публичный IP хаба не ловится `GEOIP,private` и рискует уйти в `MATCH,PROXY`.
При смене хаба (боевой vs тест) — обнови адрес.

> **Заворачивать AWG *в* Clash** — только фолбэк, если конкретный ISP душит эндпоинт
> так, что даже обфусцированный хендшейк не встаёт. Требует рабочего UDP-relay в
> прокси, добавляет латентность и MTU-боль. Порядок: сначала AWG напрямую → смотрим
> хендшейк → вложенность только если молчит.

---

## 7. Проверка

**На роутере:**

```sh
ifstatus awg0 | grep '"up"'          # "up": true
awg show awg0                        # у пира-хаба: latest handshake свежий, transfer растёт
ping -c3 10.0.0.1                     # хаб по WG
pidof clash && echo "clash up"       # обход перехватчика жив
```

**На хабе** (встречное направление — доказывает маршрут + forward `awg→lan`):

```sh
ping -c3 <WG-адрес узла>             # напр. 10.0.0.4 — к роутеру
ping -c3 <LAN-роутера>              # напр. 192.168.53.1 — в LAN за узлом через меш
```

Все пинги 0% loss = **site-узел в меше**, any-to-any работает, Clash рядом жив.
Ориентир задержки на LTE-узле — десятки мс (в живом прогоне ~35–45 ms).

---

## Приложение: контрольный список граблей

- **kmod ≠ ядро** → `MODULE FAIL`; бери релиз строго под свой vermagic.
- **Апстрим-инсталлер не находит kmod** → качай `.apk` из релиза напрямую.
- **ssclash-прокси ломает GitHub-редирект** (`HTTP 400`) → `unset http_proxy https_proxy`
  перед скачиванием.
- **Профиль обфускации не байт-в-байт** → нет хендшейка. Сверяй `awg show` с хабом.
- **`masq=1` на зоне awg** → `Port Unreachable`; для меша `masq=0`.
- **Форвардинг пир↔пир на хабе не разрешён** → узел↔хаб работает, а узел↔узел и
  клиент↔узел — нет. На хабе: `ufw route allow in on awg0 out on awg0`.
- **`allowed_ips` узла без чужих LAN** → доступ к своей LAN есть, к чужим site-LAN
  нет. Держи в `allowed_ips` вся меш + все site-подсети.
- **`input REJECT` зоны awg** → не пингуется сам роутер по WG; добавь Allow-awg-ICMP.
- **MTU не 1280** на модемном узле → фрагментация/обрывы под нагрузкой.
- **`0.0.0.0/0` в allowed_ips** → весь трафик в туннель мимо обхода; меш — только
  internal (`10.0.0.0/24` + чужие site-LAN).
- **PSK (если включён)** — одинаковый на обеих сторонах, иначе молча нет хендшейка.
