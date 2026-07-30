# 02 · AmneziaWG на сервере (хаб)

Установка AmneziaWG и разворачивание хаба `awg0`. Предполагается, что [`01-server-prep.md`](01-server-prep.md) уже пройден (ключи, ufw, forwarding).

> **Быстрый путь:** запусти [`scripts/awg-hub.sh`](../scripts/awg-hub.sh) → пункт 1. Он делает всё из этого документа интерактивно и потом даёт меню управления пирами. Ниже — что именно он выполняет, для ручного контроля.

---

## 1. Установка из PPA

```bash
apt-get install -y software-properties-common python3-launchpadlib gnupg2 "linux-headers-$(uname -r)"
add-apt-repository -y ppa:amnezia/ppa
apt-get update
apt-get install -y amneziawg amneziawg-tools
echo amneziawg > /etc/modules-load.d/amneziawg.conf
modprobe amneziawg
```

- `amneziawg` — kernel-модуль, `amneziawg-tools` — утилиты `awg` / `awg-quick`.
- Если `modprobe` падает — проверь, что заголовки ядра стоят и ты **перезагружался** после обновления ядра (см. шаг 2 в 01).

---

## 2. Ключи сервера

```bash
mkdir -p /etc/amnezia/amneziawg && cd /etc/amnezia/amneziawg
umask 077
awg genkey | tee server.key | awg pubkey > server.pub
cat server.pub    # публичный ключ — раздаётся пирам
```

> При **пересборке** существующего хаба вставь старый `server.key`, чтобы не переконфигурировать все пиры (они знают публичный ключ сервера).

---

## 3. Профиль обфускации AWG 2.0

Один и тот же профиль **байт-в-байт** на хабе и всех пирах, иначе рукопожатие не проходит. Базовый набор (проверен на живом DPI):

```
Jc = 8
Jmin = 24
Jmax = 180
S1 = 86
S2 = 128
S3 = 32
S4 = 12
H1 = 5000000-9000000
H2 = 15000000-25000000
H3 = 40000000-70000000
H4 = 150000000-400000000
I1 = <b 0xc000000001><r 64><t>
```

---

## 4. Конфиг `awg0.conf`

`/etc/amnezia/amneziawg/awg0.conf` — `[Interface]` + профиль + по одному `[Peer]` на узел. Маршруты на LAN-подсети узлов добавляются в `PostUp` (иначе `syncconf` их не создаёт — это ключевая грабля).

Пример см. [`configs/examples/awg0.conf.example`](../configs/examples/awg0.conf.example).

Скрипт `awg-hub.sh` **рендерит этот файл целиком из состояния** при каждом добавлении/удалении пира, поэтому `PostUp` и живые маршруты всегда синхронны. При ручной правке не забывай сам добавить `ip route add <подсеть> dev %i` в `PostUp`.

---

## 5. Запуск

```bash
systemctl enable --now awg-quick@awg0
awg show awg0
```

Применение изменений **без разрыва** туннелей:

```bash
awg syncconf awg0 <(awg-quick strip awg0)
# syncconf не трогает системные маршруты — при новых подсетях добавь вручную:
ip route add <подсеть> dev awg0
```

---

## 6. Проверка

```bash
awg show awg0                     # есть [Peer]'ы, идут handshakes
ip route show dev awg0            # маршруты на LAN-подсети узлов
ufw status | grep 443             # порт открыт
```

Управление пирами (добавить клиента / site-узел, выдать `.conf` + QR) — через меню `awg-hub.sh` → пункт 2. Дальше: **[03 · Подготовка роутера](03-router-prep.md)**.
