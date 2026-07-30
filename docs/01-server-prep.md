# 01 · Подготовка сервера (VPS)

Пошаговая подготовка голого VPS на **Ubuntu 24.04 LTS** до состояния «безопасная база, готовая под AmneziaWG».
Здесь только **укрепление ОС**: обновление, SSH-ключи, отключение пароля, файрвол, форвардинг. Установка самого AmneziaWG — в [`02-server-awg.md`](02-server-awg.md).

> Всё можно сделать вручную по шагам ниже **или** одной командой через [`scripts/awg-hub.sh`](../scripts/awg-hub.sh) (пункт 1 меню делает ровно это). Ручной путь нужен, чтобы понимать, что происходит, и чинить нештатные ситуации.

---

## 0. Что понадобится

- VPS с **Ubuntu 24.04**, **белым IPv4 без NAT**, доступом `root` (пароль от провайдера).
- Порт `443/udp` не занят и не режется на площадке (маскировка под QUIC).
- На **своей** машине — SSH-клиент (в macOS/Linux уже есть).

Проверь, что провайдер дал именно белый адрес:

```bash
ip -4 addr show           # адрес на интерфейсе == внешний IP, без 10./100.64./192.168.
ip -4 route get 1.1.1.1   # поле src == публичный адрес
```

Если `src` — приватный адрес, значит NAT: понадобится проброс `443/udp` у провайдера. Дальше исходим из белого IP.

---

## 1. Первый вход

```bash
ssh root@<SERVER_IP>
```

Смени врéменный пароль провайдера (даже если дальше выключим вход по паролю — на всякий случай):

```bash
passwd
```

Зафиксируй базовые вещи:

```bash
hostnamectl                       # версия, ядро
timedatectl set-timezone Europe/Moscow   # свой пояс (по вкусу)
```

---

## 2. Обновление системы

```bash
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y full-upgrade
apt-get -y autoremove --purge
```

Если обновилось **ядро** — перезагрузись, чтобы AmneziaWG собрался под актуальный kernel:

```bash
[ -f /var/run/reboot-required ] && reboot
```

После ребута снова зайди по SSH и продолжай.

**Проверка:** `uname -r` показывает свежее ядро; `apt list --upgradable` пуст.

---

## 3. Загрузка SSH-ключа

Ключ **генерируется на своей машине**, на сервер попадает только публичная часть.

### 3.1 На своём компьютере

**Сначала проверь, нет ли уже ключа** — у большинства он есть (например, для GitHub), и его же можно использовать здесь. Не создавай новый поверх существующего, иначе перезапишешь старый.

```bash
ls -la ~/.ssh/id_ed25519      # есть → ключ уже готов, генерировать не надо
```

Если файл есть — переходи сразу к 3.2 (заливке). Если `No such file or directory` — сгенерируй:

```bash
ssh-keygen -t ed25519 -C "vadim@macbook" -f ~/.ssh/id_ed25519
```

- `ed25519` — современный, короткий, быстрый (не используй RSA-2048).
- `-C` — просто метка внутри ключа (чей/откуда), на работу не влияет; удобно ставить `пользователь@устройство`.
- `-f ~/.ssh/id_ed25519` — стандартное имя: клиент подхватывает такой ключ автоматически, без `-i` и без записи в config.
- Задай пароль на ключ (passphrase) — защита, если ноут украдут.

Алиас в `~/.ssh/config` не обязателен (дефолтный ключ подхватится сам), но с ним удобно ходить `ssh awg`:

```
Host awg
    HostName <SERVER_IP>
    User root
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

### 3.2 Заливка ключа на сервер

На сервере ключи хранятся в `~/.ssh/authorized_keys` — **по одному в строке**. Ключей может быть несколько (свой ноут, рабочая машина, ключ коллеги) — все они добавляются **дополнительно**, старые не трогаются. Поэтому всюду ниже — только **дозапись** (`>>`), никогда не перезапись (`>`).

**Вариант А — `ssh-copy-id` (проще всего, сам дозаписывает).**

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@<SERVER_IP>
```

Умеет добавлять второй ключ на уже настроенный сервер: он проверяет, нет ли такого ключа, и допишет только недостающий.

**Вариант Б — одной строкой по SSH (если `ssh-copy-id` нет).**

```bash
cat ~/.ssh/id_ed25519.pub | ssh root@<SERVER_IP> \
  'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
```

**Вариант В — вручную через Vim на сервере** (когда хочешь видеть содержимое файла — например, добавляя второй ключ и проверяя, что первый на месте).

Сначала на **своей** машине покажи публичный ключ и скопируй строку целиком (начинается с `ssh-ed25519`, заканчивается меткой):

```bash
cat ~/.ssh/id_ed25519.pub
```

Теперь на **сервере** открой файл:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
vim ~/.ssh/authorized_keys
```

В Vim:

1. Нажми `G` (заглавная) — прыгнуть в конец файла (если там уже есть ключи, встанешь на последней строке).
2. Нажми `o` (строчная) — создать **новую строку** под текущей и войти в режим ввода. Так существующие ключи остаются нетронутыми.
3. Вставь скопированный ключ: **Cmd+V** (в Terminal.app обычно работает; если нет — правый клик → Paste).
4. Нажми `Esc` — выйти из режима ввода.
5. Набери `:wq` и `Enter` — сохранить и выйти.

Проверь права и что ключ на новой строке:

```bash
chmod 600 ~/.ssh/authorized_keys
cat ~/.ssh/authorized_keys        # каждый ключ — отдельной строкой, старые на месте
```

> Мини-шпаргалка по Vim: `i` — ввод, `o` — новая строка + ввод, `Esc` — выход из ввода, `:wq` — сохранить+выйти, `:q!` — выйти **без** сохранения (если что-то напортил — так откатишься).

### 3.3 ⚠️ Проверка ДО отключения пароля

Открой **новое** окно терминала и убедись, что ключ работает:

```bash
ssh awg            # или: ssh -i ~/.ssh/id_ed25519 root@<SERVER_IP>
```

Должно пустить **без запроса пароля** (только passphrase ключа, если задавал). Пока это не работает — **шаг 4 не делай.**

---

## 4. Отключение доступа по паролю

Cloud-init на Ubuntu кладёт свой `50-cloud-init.conf` в `/etc/ssh/sshd_config.d/`, который может включать `PasswordAuthentication yes`. Наш файл с префиксом `00-` читается **раньше** и перебивает его (в `sshd_config` для большинства директив побеждает **первое** значение).

На сервере:

```bash
cat > /etc/ssh/sshd_config.d/00-hardening.conf <<'EOF'
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
X11Forwarding no
MaxAuthTries 3
EOF
```

Проверь конфиг **до** перезапуска (иначе рискуешь остаться без входа):

```bash
sshd -t && echo OK
```

Только при `OK` перечитай конфиг (именно `reload`, не `restart` — текущая сессия не рвётся):

```bash
systemctl reload ssh 2>/dev/null || systemctl reload sshd
```

### ⚠️ Проверка

**Не закрывая** текущую сессию, открой ещё одно окно и войди заново:

```bash
ssh awg
```

Пароль больше не должен приниматься. Убедись, что вход по ключу проходит. Теперь можно закрывать старые сессии.

> **Про порт SSH.** Менять `22` на нестандартный — слабая защита (безопасность через неясность), но снижает шум в логах. Если меняешь: добавь `Port <N>` в `00-hardening.conf`, **сначала** открой порт в ufw (шаг 6), только потом `reload`, и обнови `~/.ssh/config`.

> **Опционально — sudo-пользователь вместо root.** Если не хочешь ходить root'ом:
> ```bash
> adduser admin && usermod -aG sudo admin
> rsync --archive --chown=admin:admin ~/.ssh /home/admin
> ```
> и в `00-hardening.conf` поставь `PermitRootLogin no`. Дальнейшие команды тогда — через `sudo`.

---

## 5. Базовые утилиты и снос Docker

```bash
apt-get install -y curl wget ufw fail2ban qrencode software-properties-common
```

### Docker (важно!)

Многие облачные образы идут с предустановленным Docker. Его правила `iptables` в цепочке `FORWARD` **ломают маршрутизацию** между пирами AmneziaWG. Если Docker не нужен на этом сервере — снеси:

```bash
# сначала проверь, стоит ли он вообще
dpkg -l | grep -E 'docker|containerd'
```

Если стоит:

```bash
apt-get -y purge docker.io docker-ce docker-ce-cli containerd containerd.io \
  docker-compose docker-compose-plugin docker-buildx-plugin python3-docker
apt-get -y autoremove --purge
```

> ⚠️ **Не** удаляй `python3-*` целиком — это снесёт системный Python и сломает ОС. Убираем только `python3-docker` (биндинги Docker), если он был.
>
> Если Docker «не хочет» удаляться (юниты остались, а пакеты — нет) — переустанови и снеси заново:
> ```bash
> apt-get install --reinstall docker.io && apt-get -y purge docker.io
> ```

**Проверка:** `iptables -S FORWARD` не содержит `DOCKER`-цепочек.

---

## 6. Файрвол (ufw) и fail2ban

Порядок важен: **сначала** разрешаем SSH, **потом** включаем ufw, иначе отрежем себя.

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp            # SSH (или свой порт из шага 4)
ufw allow 443/udp          # AmneziaWG (маскировка под QUIC)
ufw --force enable
ufw status verbose
```

`fail2ban` со стандартным `sshd`-jail'ом отсекает брутфорс:

```bash
systemctl enable --now fail2ban
fail2ban-client status sshd
```

**Проверка:** `ufw status` показывает `22/tcp` и `443/udp` как `ALLOW`, политика входящих — `deny`.

---

## 7. Форвардинг и IPv6

Хаб маршрутизирует трафик между пирами → нужен `ip_forward`. IPv6 выключаем, чтобы не было утечек мимо туннеля.

```bash
cat > /etc/sysctl.d/99-awg.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

sysctl --system
```

**Проверка:**

```bash
sysctl net.ipv4.ip_forward            # = 1
sysctl net.ipv6.conf.all.disable_ipv6 # = 1
```

---

## 8. Итоговый чеклист

| Пункт | Команда проверки | Ожидание |
|---|---|---|
| Система обновлена | `apt list --upgradable` | пусто |
| Вход по ключу | `ssh awg` | без пароля |
| Пароль отключён | `sshd -T \| grep passwordauth` | `no` |
| `00-` перебивает cloud-init | `sshd -T \| grep permitrootlogin` | `prohibit-password` |
| Docker убран | `iptables -S FORWARD` | без `DOCKER` |
| ufw активен | `ufw status` | `active`, 22/tcp + 443/udp |
| fail2ban | `fail2ban-client status sshd` | jail активен |
| Форвардинг | `sysctl net.ipv4.ip_forward` | `1` |
| IPv6 off | `sysctl net.ipv6.conf.all.disable_ipv6` | `1` |

Всё зелёное → сервер готов. Дальше: **[02 · AmneziaWG на сервере](02-server-awg.md)**.

---

## Если что-то пошло не так

- **Заблокировал себе SSH** — заходи через веб-консоль провайдера (VNC/Serial), правь `/etc/ssh/sshd_config.d/00-hardening.conf`, `sshd -t`, `systemctl reload ssh`.
- **`sshd -t` ругается** — смотри строку в ошибке; частая причина — опечатка в директиве или дубль порта.
- **ufw отрезал доступ** — веб-консоль → `ufw disable` → поправь правила → `ufw enable`.
