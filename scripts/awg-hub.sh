#!/usr/bin/env bash
#
# awg-hub.sh — интерактивный bootstrap AmneziaWG-хаба на голой Ubuntu (24.04)
# + меню управления пирами. Идемпотентный: можно перезапускать.
#
# Что делает:
#   1) Готовит систему: apt update/upgrade, (опц.) снос Docker, sysctl (forward + IPv6 off),
#      ufw, fail2ban, SSH-хардненинг (безопасно — не отключает пароль без ключа).
#   2) Ставит AmneziaWG из ppa:amnezia/ppa (kernel-модуль + amneziawg-tools).
#   3) Разворачивает хаб awg0 с единым профилем обфускации AWG 2.0.
#   4) Даёт меню: добавить клиента (роуминг, .conf + QR), добавить site (OpenWrt-узел
#      со своей подсетью), список, удалить. Конфиг awg0.conf всегда рендерится из состояния,
#      поэтому маршруты на LAN-подсети пиров чинятся автоматически (грабля #1 из хэндоффа).
#
# Запуск:  sudo bash awg-hub.sh
#
set -Eeuo pipefail
shopt -s nullglob
umask 077                 # приватные ключи (server.key, пиры) создаются с правами 600, не world-readable

# ─────────────────────────── пути и константы ───────────────────────────
IFACE="awg0"
AWG_DIR="/etc/amnezia/amneziawg"
AWG_CONF="$AWG_DIR/$IFACE.conf"
META_DIR="/etc/awg-hub"
META="$META_DIR/hub.env"
SRV_KEY="$META_DIR/server.key"
PEERS_DIR="$META_DIR/peers"

# ─────────────── дефолты профиля обфускации AWG 2.0 (из хэндоффа) ───────────────
DEF_JC=8;   DEF_JMIN=24;  DEF_JMAX=180
DEF_S1=86;  DEF_S2=128;   DEF_S3=32;   DEF_S4=12
DEF_H1="5000000-9000000"
DEF_H2="15000000-25000000"
DEF_H3="40000000-70000000"
DEF_H4="150000000-400000000"
DEF_I1='<b 0xc000000001><r 64><t>'

# дефолты сети
DEF_WG_NET="10.0.0.0/24"
DEF_WG_ADDR="10.0.0.1"
DEF_PORT="443"

# ─────────────────────────── UI-хелперы ───────────────────────────
if [ -t 1 ]; then
  c_reset=$'\e[0m'; c_bold=$'\e[1m'; c_dim=$'\e[2m'
  c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_red=$'\e[31m'; c_cyan=$'\e[36m'; c_mag=$'\e[35m'
else
  c_reset=; c_bold=; c_dim=; c_grn=; c_ylw=; c_red=; c_cyan=; c_mag=
fi
info(){ printf '%s[*]%s %s\n' "$c_cyan" "$c_reset" "$*"; }
ok(){   printf '%s[+]%s %s\n' "$c_grn"  "$c_reset" "$*"; }
warn(){ printf '%s[!]%s %s\n' "$c_ylw"  "$c_reset" "$*"; }
err(){  printf '%s[x]%s %s\n' "$c_red"  "$c_reset" "$*" >&2; }
die(){  err "$*"; exit 1; }
hr(){   printf '%s────────────────────────────────────────────────────────%s\n' "$c_dim" "$c_reset"; }
title(){ printf '\n%s%s%s\n' "$c_bold$c_mag" "$*" "$c_reset"; hr; }

# ask "вопрос" "дефолт"  → печатает ответ в stdout (промпт идёт в stderr, чтобы не попасть в подстановку)
ask(){
  local p="$1" d="${2:-}" h="${3:-}" a
  if [ -n "$h" ]; then
    if [ -n "$d" ]; then printf '%s  \xe2\x86\xb3 %s (Enter = %s)%s\n' "$c_dim" "$h" "$d" "$c_reset" >&2
    else printf '%s  \xe2\x86\xb3 %s%s\n' "$c_dim" "$h" "$c_reset" >&2; fi
  fi
  if [ -n "$d" ]; then read -rp "$(printf '%s%s%s [%s]: ' "$c_bold" "$p" "$c_reset" "$d")" a; printf '%s' "${a:-$d}"
  else read -rp "$(printf '%s%s%s: ' "$c_bold" "$p" "$c_reset")" a; printf '%s' "$a"; fi
}
# ask_name "вопрос" [дефолт] — как ask, но имя только из [A-Za-z0-9_-].
# Режет мусор/typeahead/склейку/случайную кириллицу ДО попадания в conf и имена
# файлов (#14). Предупреждение шлём в stderr, чтобы не попало в само имя.
ask_name(){
  local raw clean
  raw="$(ask "$1" "${2:-}")"
  clean="${raw//[!A-Za-z0-9_-]/}"
  [ "$clean" != "$raw" ] && warn "Имя очищено от недопустимых символов → '$clean'." >&2
  printf '%s' "$clean"
}
# confirm "вопрос" "y|n"  → 0 если да
confirm(){
  local p="$1" d="${2:-y}" h="${3:-}" a hint edef
  [ "$d" = y ] && { hint="[Y/n]"; edef="да"; } || { hint="[y/N]"; edef="нет"; }
  [ -n "$h" ] && printf '%s  \xe2\x86\xb3 %s (Enter = %s)%s\n' "$c_dim" "$h" "$edef" "$c_reset"
  read -rp "$(printf '%s%s%s %s: ' "$c_bold" "$p" "$c_reset" "$hint")" a
  a="${a:-$d}"
  [[ "$a" =~ ^[YyДд] ]]
}
pause(){ read -rp "$(printf '%sНажми Enter…%s' "$c_dim" "$c_reset")" _; }

# ─────────────────────────── предпроверки ───────────────────────────
[ "$(id -u)" -eq 0 ] || die "Запусти под root:  sudo bash $0"
command -v apt-get >/dev/null || die "Это не Debian/Ubuntu (нет apt-get)."

# ─────────────────────────── состояние ───────────────────────────
# глобальные переменные состояния (заполняются load_meta / bootstrap)
WG_NET=""; WG_ADDR=""; WG_PREFIX=""; PORT=""; ENDPOINT=""; SERVER_PUB=""
JC=""; JMIN=""; JMAX=""; S1=""; S2=""; S3=""; S4=""; H1=""; H2=""; H3=""; H4=""; I1=""

load_meta(){ [ -f "$META" ] && . "$META" || return 1; }

save_meta(){
  mkdir -p "$META_DIR"; chmod 700 "$META_DIR"
  cat > "$META" <<EOF
# сгенерировано awg-hub.sh — метаданные хаба (без приватного ключа)
WG_NET="$WG_NET"
WG_ADDR="$WG_ADDR"
WG_PREFIX="$WG_PREFIX"
PORT="$PORT"
ENDPOINT="$ENDPOINT"
SERVER_PUB="$SERVER_PUB"
JC="$JC"; JMIN="$JMIN"; JMAX="$JMAX"
S1="$S1"; S2="$S2"; S3="$S3"; S4="$S4"
H1="$H1"; H2="$H2"; H3="$H3"; H4="$H4"
I1='$I1'
EOF
  chmod 600 "$META"
}

profile_conf_lines(){   # строки профиля для awg0.conf / клиентского .conf ([Interface])
  cat <<EOF
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
S3 = $S3
S4 = $S4
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4
I1 = $I1
EOF
}
profile_uci_lines(){    # строки профиля для OpenWrt UCI (option ...)
  cat <<EOF
    option awg_jc   '$JC'
    option awg_jmin '$JMIN'
    option awg_jmax '$JMAX'
    option awg_s1   '$S1'
    option awg_s2   '$S2'
    option awg_s3   '$S3'
    option awg_s4   '$S4'
    option awg_h1   '$H1'
    option awg_h2   '$H2'
    option awg_h3   '$H3'
    option awg_h4   '$H4'
    option awg_i1   '$I1'
EOF
}

# ─────────────────────────── работа с пирами (файлы состояния) ───────────────────────────
# каждый пир: $PEERS_DIR/<name>.peer  с полями NAME PUBKEY WG_IP [SUBNET] [PSK] TYPE(client|site)

gather_subnets(){ local f; for f in "$PEERS_DIR"/*.peer; do ( . "$f"; [ -n "${SUBNET:-}" ] && echo "$SUBNET"; true ); done; }
gather_used_ips(){ local f; for f in "$PEERS_DIR"/*.peer; do ( . "$f"; echo "$WG_IP" ); done; }

next_ip(){   # следующий свободный хост в /24 (сервер и занятые исключены)
  local base used cand i
  base="$(echo "$WG_ADDR" | cut -d. -f1-3)"
  used="$(gather_used_ips)"
  for i in $(seq 2 254); do
    cand="$base.$i"
    [ "$cand" = "$WG_ADDR" ] && continue
    if printf '%s\n' "$used" | grep -qx "$cand"; then continue; fi
    echo "$cand"; return 0
  done
  die "Свободных адресов в $WG_NET не осталось."
}

render_config(){   # рендер awg0.conf целиком из состояния
  local priv postup s f
  [ -f "$SRV_KEY" ] || die "Нет приватного ключа сервера ($SRV_KEY). Сначала bootstrap."
  priv="$(cat "$SRV_KEY")"
  mkdir -p "$AWG_DIR"
  postup=""
  while read -r s; do [ -n "$s" ] && postup+="ip route add $s dev %i 2>/dev/null; "; done < <(gather_subnets)

  {
    echo "[Interface]"
    echo "Address = $WG_ADDR/$WG_PREFIX"
    echo "ListenPort = $PORT"
    echo "PrivateKey = $priv"
    [ -n "$postup" ] && echo "PostUp = $postup"
    profile_conf_lines
    for f in "$PEERS_DIR"/*.peer; do
      ( . "$f"
        echo
        echo "[Peer]  # $NAME"
        echo "PublicKey = $PUBKEY"
        [ -n "${PSK:-}" ] && echo "PresharedKey = $PSK"
        if [ -n "${SUBNET:-}" ]; then echo "AllowedIPs = $WG_IP/32, $SUBNET"
        else echo "AllowedIPs = $WG_IP/32"; fi
      )
    done
  } > "$AWG_CONF"
  chmod 600 "$AWG_CONF"
}

apply(){   # применить конфиг вживую без разрыва туннелей + починить маршруты
  render_config
  if awg show "$IFACE" >/dev/null 2>&1; then
    awg syncconf "$IFACE" <(awg-quick strip "$IFACE")
    # syncconf НЕ создаёт системные маршруты — добавляем сами (грабля #1)
    local s
    while read -r s; do [ -n "$s" ] && ip route replace "$s" dev "$IFACE" 2>/dev/null || true; done < <(gather_subnets)
    ok "Конфиг применён (syncconf) + маршруты обновлены."
  else
    systemctl enable --now "awg-quick@$IFACE"
    ok "Интерфейс $IFACE поднят и включён в автозагрузку."
  fi
}

# «внутренние» сети, которые должен видеть КЛИЕНТ: вся WG + все site-подсети
client_allowed_ips(){
  local out="$WG_NET" s
  while read -r s; do [ -n "$s" ] && out+=", $s"; done < <(gather_subnets)
  echo "$out"
}
# для site-пира: вся WG + чужие site-подсети (без своей)
site_allowed_ips(){
  local own="$1" out="$WG_NET" s
  while read -r s; do [ -n "$s" ] && [ "$s" != "$own" ] && out+=", $s"; done < <(gather_subnets)
  echo "$out"
}

# ═══════════════════════════ BOOTSTRAP ═══════════════════════════
step_collect_params(){
  title "Параметры хаба"
  local mode
  echo "Режим:"
  echo "  1) Пересобрать существующий хаб (по возможности сохранить старый ключ сервера)"
  echo "  2) Новый независимый хаб (сгенерировать всё заново)"
  echo "  0) Назад (ничего не менять)"
  mode="$(ask "Выбор" "$([ -f "$META" ] && echo 1 || echo 2)" '1 = сохранить текущий ключ хаба, выданные QR/конфиги продолжат работать. 2 = сгенерировать всё заново, ВСЕ пиры придётся перевыпустить. 0 = вернуться в меню.')"
  [ "$mode" = 0 ] && return 1

  # если метаданные уже есть — подставляем их как дефолты
  load_meta || true
  WG_NET="$(ask 'WG-подсеть (CIDR)' "${WG_NET:-$DEF_WG_NET}" 'Внутренняя сеть меша. Меняй, только если 10.0.0.0/24 конфликтует с локалкой. Enter — оставить как есть.')"
  WG_PREFIX="${WG_NET#*/}"; [ "$WG_PREFIX" = "$WG_NET" ] && WG_PREFIX=24
  WG_ADDR="$(ask 'Адрес сервера в WG' "${WG_ADDR:-$DEF_WG_ADDR}" 'IP хаба внутри меша (обычно .1). Пиры пингуют его как шлюз. Enter — оставить.')"
  PORT="$(ask 'UDP-порт (маскировка под QUIC = 443)' "${PORT:-$DEF_PORT}" 'Порт, куда стучатся пиры. 443 маскирует трафик под QUIC/HTTPS и реже режется DPI. Enter — 443.')"

  local det; det="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  ENDPOINT="$(ask 'Публичный endpoint (белый IP/хост)' "${ENDPOINT:-$det}" 'Белый IP/хост хаба — его пиры пишут в Endpoint. Определён автоматически; меняй, только если он неверный.')"
  [ -n "$ENDPOINT" ] || die "Endpoint обязателен."

  title "Профиль обфускации AWG 2.0"
  info "Дефолты из хэндоффа (проверены на живом DPI). Enter = принять каждый."
  info "ВАЖНО: эти 15 значений должны совпадать БАЙТ-В-БАЙТ на хабе и всех пирах, иначе туннель не поднимется. Не меняй без причины — просто жми Enter."
  JC="$(ask   'Jc'   "${JC:-$DEF_JC}")";     JMIN="$(ask 'Jmin' "${JMIN:-$DEF_JMIN}")"; JMAX="$(ask 'Jmax' "${JMAX:-$DEF_JMAX}")"
  S1="$(ask   'S1'   "${S1:-$DEF_S1}")";     S2="$(ask   'S2'   "${S2:-$DEF_S2}")"
  S3="$(ask   'S3'   "${S3:-$DEF_S3}")";     S4="$(ask   'S4'   "${S4:-$DEF_S4}")"
  H1="$(ask   'H1'   "${H1:-$DEF_H1}")";     H2="$(ask   'H2'   "${H2:-$DEF_H2}")"
  H3="$(ask   'H3'   "${H3:-$DEF_H3}")";     H4="$(ask   'H4'   "${H4:-$DEF_H4}")"
  I1="$(ask   'I1'   "${I1:-$DEF_I1}")"

  # ── ключ сервера ──
  title "Ключ сервера"
  mkdir -p "$META_DIR"; chmod 700 "$META_DIR"
  local reuse_default="n"; [ "$mode" = 1 ] && reuse_default="y"
  if [ -f "$SRV_KEY" ] && confirm "Найден существующий ключ сервера — оставить его?" "y" "Enter/Y = все выданные QR и конфиги продолжат работать. N = ключ сменится, пиров придётся перевыпускать."; then
    :
  elif [ "$mode" = 1 ] && confirm "Вставить СТАРЫЙ приватный ключ (чтобы пиры не переконфигурировать)?" "$reuse_default" "Есть бэкап старого приватного ключа хаба? Вставишь — пиры не трогаем. Нет — будет сгенерирован новый."; then
    local k; k="$(ask 'Приватный ключ сервера (base64)' '')"
    [ -n "$k" ] || die "Пустой ключ."
    printf '%s\n' "$k" > "$SRV_KEY"
  else
    command -v awg >/dev/null || { warn "awg ещё не установлен — ключ сгенерирую после установки пакетов."; : ; }
    if command -v awg >/dev/null; then awg genkey > "$SRV_KEY"; ok "Сгенерирован новый ключ сервера."; fi
  fi
  if [ -f "$SRV_KEY" ]; then chmod 600 "$SRV_KEY"; fi
}

step_system(){
  title "Система: обновление и утилиты"
  if confirm "apt update && full-upgrade сейчас?" "y" "Обновит систему и поставит зависимости (ufw, fail2ban, awg). Безопасно; может занять минуту. N — пропустить, если только что обновлялся."; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get -y full-upgrade
    ok "Система обновлена."
  fi

  # ── снос Docker (грабля #6): сносим только РЕАЛЬНО установленные пакеты ──
  # Не передаём в purge несуществующие имена (containerd.io и ко из docker.com-репо):
  # иначе apt падает 'Unable to locate' и НЕ сносит даже стоящий docker.io.
  mapfile -t _dockpkgs < <(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E \
    '^(docker\.io|docker-ce|docker-ce-cli|containerd|containerd\.io|docker-compose|docker-compose-plugin|docker-buildx-plugin|python3-docker)$' || true)
  if [ "${#_dockpkgs[@]}" -gt 0 ]; then
    if confirm "Обнаружен Docker (мешает FORWARD) — снести?" "y" "Docker ставит свои iptables-правила FORWARD и ломает маршрутизацию меша. Y — удалить (если сервер только под хаб). N — оставить, но меш может не форвардить."; then
      apt-get -y purge "${_dockpkgs[@]}" || warn "Часть docker-пакетов не удалилась — проверь вручную."
      apt-get -y autoremove --purge || true
      # DOCKER-цепочки в FORWARD демон создаёт в рантайме — после purge остаются до ребута
      if iptables -S FORWARD 2>/dev/null | grep -qi docker; then
        warn "DOCKER-цепочки ещё висят в FORWARD — нужен REBOOT, иначе маршрутизация пиров сломается (грабля #6)."
      fi
      ok "Docker удалён (python3-* целиком НЕ трогали)."
    fi
  fi

  info "Ставлю зависимости и AmneziaWG из ppa:amnezia/ppa…"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y software-properties-common python3-launchpadlib gnupg2 \
      "linux-headers-$(uname -r)" ufw fail2ban qrencode curl
  add-apt-repository -y ppa:amnezia/ppa
  apt-get update -y
  apt-get install -y amneziawg amneziawg-tools
  echo amneziawg > /etc/modules-load.d/amneziawg.conf
  modprobe amneziawg && ok "Модуль amneziawg загружен." || die "modprobe amneziawg упал — проверь заголовки ядра/ребут."

  # если ключ ещё не создан (mode=new и awg не был доступен раньше)
  [ -f "$SRV_KEY" ] || { awg genkey > "$SRV_KEY"; chmod 600 "$SRV_KEY"; ok "Сгенерирован ключ сервера."; }
}

step_sysctl(){
  title "sysctl: форвардинг + IPv6 off"
  cat > /etc/sysctl.d/99-awg.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  sysctl --system >/dev/null
  ok "ip_forward=1, IPv6 выключен."
}

step_firewall(){
  title "ufw + fail2ban"
  local sshp="$1"
  ufw --force reset >/dev/null 2>&1 || true
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow "${sshp}/tcp"   >/dev/null   # SSH — разрешаем ДО enable, чтобы не отрезать себя
  ufw allow "${PORT}/udp"   >/dev/null   # AWG
  ufw route allow in on "$IFACE" out on "$IFACE" >/dev/null 2>&1 || true  # peer-to-peer
  ufw --force enable >/dev/null
  ok "ufw: deny incoming, allow ${sshp}/tcp + ${PORT}/udp + awg↔awg."
  systemctl enable --now fail2ban >/dev/null 2>&1 || true
  ok "fail2ban включён."
}

step_ssh_hardening(){
  title "SSH-хардненинг (безопасный)"
  local sshp="$1"
  confirm "Применить SSH-хардненинг (только ключи, root по ключу)?" "y" "Отключит вход по паролю — останется только по SSH-ключу. УБЕДИСЬ, что твой ключ уже работает, иначе закроешь себе доступ! N — оставить как есть." || { warn "Пропущено по запросу."; return; }

  # гарантируем наличие хотя бы одного authorized_key ПЕРЕД отключением пароля
  local akf="/root/.ssh/authorized_keys"
  mkdir -p /root/.ssh; chmod 700 /root/.ssh; touch "$akf"; chmod 600 "$akf"
  if [ ! -s "$akf" ]; then
    warn "В $akf пусто — если отключить пароль сейчас, доступ будет потерян."
    local pk; pk="$(ask 'Вставь свой публичный SSH-ключ (ssh-ed25519 …), пусто = НЕ отключать пароль' '')"
    if [ -n "$pk" ]; then printf '%s\n' "$pk" >> "$akf"; ok "Ключ добавлен."; fi
  fi

  local disable_pw="yes"
  if [ ! -s "$akf" ]; then
    disable_pw="no"
    warn "Ключей всё ещё нет → пароль НЕ отключаю (защита от локаута). Добавь ключ и перезапусти хардненинг."
  fi

  # 00- чтобы перебить 50-cloud-init.conf (грабля #8)
  cat > /etc/ssh/sshd_config.d/00-hardening.conf <<EOF
Port $sshp
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication $([ "$disable_pw" = yes ] && echo no || echo yes)
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
X11Forwarding no
MaxAuthTries 3
EOF
  if sshd -t; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    ok "SSH-хардненинг применён (reload, сессия не разорвана). PasswordAuth=$([ "$disable_pw" = yes ] && echo off || echo on)."
    [ "$sshp" != 22 ] && warn "Порт SSH теперь $sshp — не потеряй его в новом окне перед выходом."
  else
    err "sshd -t не прошёл — откатываю дроп-ин."
    rm -f /etc/ssh/sshd_config.d/00-hardening.conf
  fi
}

bootstrap(){
  step_collect_params || return
  local sshp; sshp="$(ask 'SSH-порт (обычно 22)' '22' 'Порт, который откроем в файрволе под SSH. Оставь 22, если не менял вручную — иначе рискуешь потерять доступ к серверу.')"
  step_system
  # ключ мог появиться только сейчас — дособерём pubkey
  SERVER_PUB="$(awg pubkey < "$SRV_KEY")"
  step_sysctl
  apply                       # рендер + подъём awg0
  save_meta                   # фиксируем мету СРАЗУ (до firewall/ssh — иначе обрыв на хардненинге теряет hub.env)
  step_firewall "$sshp"
  step_ssh_hardening "$sshp"

  title "Хаб готов ✅"
  cat <<EOF
  Endpoint:            ${c_bold}$ENDPOINT:$PORT/udp${c_reset}
  Публичный ключ:      ${c_bold}$SERVER_PUB${c_reset}
  WG-сеть / сервер:    $WG_NET  /  $WG_ADDR
  Интерфейс:           $IFACE ($(systemctl is-enabled awg-quick@$IFACE 2>/dev/null || echo n/a))
EOF
  hr
  info "Дальше: меню «Управление пирами» → добавь клиента (Mac/телефон) или site (деревня/город)."
  pause
}

# ═══════════════════════════ ПИРЫ ═══════════════════════════
require_hub(){ load_meta || die "Хаб ещё не настроен — сначала пункт 1 (bootstrap)."; SERVER_PUB="${SERVER_PUB:-$(awg pubkey < "$SRV_KEY" 2>/dev/null)}"; }

# awg_show_named — вывод `awg show $IFACE`, но над каждым `peer:` подставляет имя
# пира из реестра ($PEERS_DIR/*.peer). Неизвестный пир помечает «(нет в реестре)»
# — заодно детектор чужих ключей в туннеле.
awg_show_named(){
  { for f in "$PEERS_DIR"/*.peer; do [ -e "$f" ] && ( . "$f"; printf 'MAP\t%s\t%s\n' "$PUBKEY" "$NAME" ); done
    awg show "$IFACE"; } | awk '
    /^MAP\t/   { split($0,a,"\t"); name[a[2]]=a[3]; next }
    /^peer: /  { pk=$2; print "### " (name[pk] ? name[pk] : "(нет в реестре)") }
    { print }'
}
peer_list(){
  title "Пиры"
  local f any=0
  printf '%-16s %-6s %-16s %-20s %s\n' "ИМЯ" "ТИП" "WG-IP" "LAN-ПОДСЕТЬ" "PUBKEY"
  hr
  for f in "$PEERS_DIR"/*.peer; do
    any=1
    ( . "$f"; printf '%-16s %-6s %-16s %-20s %s\n' "$NAME" "${TYPE:-?}" "$WG_IP" "${SUBNET:-—}" "${PUBKEY:0:16}…" )
  done
  [ "$any" = 0 ] && echo "  (пусто)"
  echo
  if awg show "$IFACE" >/dev/null 2>&1; then
    info "Живые хендшейки:"; awg_show_named | sed 's/^/    /'
  fi
}

peer_add_client(){
  require_hub
  title "Добавить клиента (роуминг: Mac / телефон / ноут)"
  local name ip priv pub psk="" conf
  name="$(ask_name 'Имя (латиница, без пробелов)' '')"; [ -n "$name" ] || { warn "Пусто."; return; }
  [ -f "$PEERS_DIR/$name.peer" ] && { warn "Пир '$name' уже есть."; return; }
  info "Соглашение: клиенты (Mac/телефон) — с .10; адреса .2–.9 зарезервированы под site-узлы (город/деревня)."
  ip="$(ask 'WG-адрес клиента' "$(next_ip)")"
  priv="$(awg genkey)"; pub="$(printf '%s' "$priv" | awg pubkey)"
  info "PSK — доп. симметричный слой (постквантовая подстраховка). Тот же ключ нужен на ОБЕИХ сторонах. Тест — N, боевой пир — Y."
  if confirm "Использовать PresharedKey (доп. слой)?" "n"; then psk="$(awg genpsk)"; fi

  mkdir -p "$PEERS_DIR"
  cat > "$PEERS_DIR/$name.peer" <<EOF
NAME="$name"
TYPE="client"
PUBKEY="$pub"
WG_IP="$ip"
PSK="$psk"
EOF
  chmod 600 "$PEERS_DIR/$name.peer"
  apply

  # клиентский .conf (формат AmneziaWG native, internal-only)
  conf="$PEERS_DIR/$name.conf"
  {
    echo "[Interface]"
    echo "PrivateKey = $priv"
    echo "Address = $ip/32"
    echo "DNS = $WG_ADDR"
    profile_conf_lines
    echo
    echo "[Peer]"
    echo "PublicKey = $SERVER_PUB"
    [ -n "$psk" ] && echo "PresharedKey = $psk"
    echo "Endpoint = $ENDPOINT:$PORT"
    echo "AllowedIPs = $(client_allowed_ips)"
    echo "PersistentKeepalive = 25"
  } > "$conf"
  chmod 600 "$conf"

  ok "Клиент '$name' добавлен. Конфиг: $conf"
  title "Конфиг клиента $name"
  cat "$conf"
  echo
  if confirm "Показать QR (для AmneziaVPN на телефоне)?" "y"; then
    qrencode -t ansiutf8 < "$conf" || warn "qrencode недоступен."
  fi
  warn "Переноси .conf на устройство НАПРЯМУЮ (scp), не через Clash."
  pause
}

peer_add_site(){
  require_hub
  title "Добавить site-узел (OpenWrt со своей LAN-подсетью)"
  local name ip pub subnet psk=""
  name="$(ask_name 'Имя (напр. derevnya / gorod)' '')"; [ -n "$name" ] || { warn "Пусто."; return; }
  [ -f "$PEERS_DIR/$name.peer" ] && { warn "Пир '$name' уже есть."; return; }
  ip="$(ask 'WG-адрес узла' "$(next_ip)")"
  subnet="$(ask 'LAN-подсеть узла (напр. 192.168.52.0/24)' '')"; [ -n "$subnet" ] || { warn "Подсеть обязательна для site."; return; }
  echo "Приватный ключ site-узла остаётся НА УСТРОЙСТВЕ. Сюда вставь его ПУБЛИЧНЫЙ ключ."
  pub="$(ask 'Публичный ключ узла (base64)' '')"; [ -n "$pub" ] || { warn "Пусто."; return; }
  info "PSK — доп. симметричный слой (постквантовая подстраховка). Тот же ключ нужен на ОБЕИХ сторонах. Тест — N, боевой пир — Y."
  if confirm "Использовать PresharedKey?" "n"; then psk="$(awg genpsk)"; fi

  mkdir -p "$PEERS_DIR"
  cat > "$PEERS_DIR/$name.peer" <<EOF
NAME="$name"
TYPE="site"
PUBKEY="$pub"
WG_IP="$ip"
SUBNET="$subnet"
PSK="$psk"
EOF
  chmod 600 "$PEERS_DIR/$name.peer"
  apply

  title "Параметры для OpenWrt-узла '$name'"
  cat <<EOF
На узле в UCI (интерфейс proto amneziawg, addresses=$ip/24, mtu 1280) — peer к VPS:

  config amneziawg_$IFACE 'wgpeer_vps'
    option public_key   '$SERVER_PUB'
    option endpoint_host '$ENDPOINT'
    option endpoint_port '$PORT'
    option persistent_keepalive '25'
    option route_allowed_ips '1'
    list  allowed_ips   '$(site_allowed_ips "$subnet" | sed "s/, /'\n    list  allowed_ips   '/g")'
$( [ -n "$psk" ] && echo "    option preshared_key '$psk'" )

И профиль обфускации на интерфейсе awg0 (байт-в-байт как на хабе):
$(profile_uci_lines)
EOF
  hr
  info "allowed_ips намеренно БЕЗ своей $subnet и без 0.0.0.0/0 (internal-only)."
  info "Обход перехватчика (Clash/podkop) на узле настраивается отдельно по рецепту хэндоффа."
  pause
}

peer_remove(){
  require_hub
  title "Удалить пир"
  local files=() f i=1 sel base line
  for f in "$PEERS_DIR"/*.peer; do [ -e "$f" ] && files+=("$f"); done
  [ "${#files[@]}" -eq 0 ] && { warn "Пиров нет."; pause; return; }
  # Выбор по НОМЕРУ, а не по имени: снимает и уже битые пиры (#14), чьё имя в
  # файле содержит мусорный байт и с клавиатуры не набирается.
  for f in "${files[@]}"; do
    line="$( . "$f"; printf '%-16s %-6s %-16s %s' "$NAME" "${TYPE:-?}" "${WG_IP:-?}" "${SUBNET:-—}" )"
    printf '  %2d) %s\n' "$i" "$line"
    i=$((i+1))
  done
  echo
  sel="$(ask 'Номер пира для удаления (пусто = отмена)' '')"; [ -n "$sel" ] || return
  case "$sel" in ''|*[!0-9]*) { warn "Нужен номер из списка."; return; };; esac
  { [ "$sel" -ge 1 ] && [ "$sel" -le "${#files[@]}" ]; } || { warn "Нет пункта $sel."; return; }
  f="${files[$((sel-1))]}"; base="$(basename "$f" .peer)"
  confirm "Точно удалить '$base'?" "n" || return
  # снять маршрут, если был
  ( . "$f"; [ -n "${SUBNET:-}" ] && ip route del "$SUBNET" dev "$IFACE" 2>/dev/null || true )
  rm -f "$f" "${f%.peer}.conf"
  apply
  ok "Пир удалён."
  pause
}

peer_show_conf(){
  local files=() f i=1 sel base
  title "Показать сохранённый .conf клиента"
  for f in "$PEERS_DIR"/*.conf; do [ -e "$f" ] && files+=("$f"); done
  [ "${#files[@]}" -eq 0 ] && { warn "Нет сохранённых .conf (site-узлы .conf не хранят)."; pause; return; }
  for f in "${files[@]}"; do printf '  %2d) %s\n' "$i" "$(basename "$f" .conf)"; i=$((i+1)); done
  echo
  sel="$(ask 'Номер клиента (пусто = отмена)' '')"; [ -n "$sel" ] || return
  case "$sel" in ''|*[!0-9]*) { warn "Нужен номер из списка."; return; };; esac
  { [ "$sel" -ge 1 ] && [ "$sel" -le "${#files[@]}" ]; } || { warn "Нет пункта $sel."; return; }
  f="${files[$((sel-1))]}"; base="$(basename "$f" .conf)"
  echo; info "=== $base ==="
  cat "$f"
  echo
  confirm "QR?" "n" && qrencode -t ansiutf8 < "$f"
  pause
}

peers_menu(){
  require_hub
  while true; do
    title "Управление пирами"
    cat <<EOF
  1) Список пиров и хендшейки
  2) + Клиент (роуминг: Mac/телефон) — генерим ключи, .conf + QR
  3) + Site (OpenWrt со своей подсетью) — вводим их pubkey
  4) Показать .conf клиента заново
  5) Удалить пир
  0) Назад
EOF
    case "$(ask 'Выбор' '1')" in
      1) peer_list; pause ;;
      2) peer_add_client ;;
      3) peer_add_site ;;
      4) peer_show_conf ;;
      5) peer_remove ;;
      0) return ;;
      *) warn "Не понял." ;;
    esac
  done
}

# ═══════════════════════════ СТАТУС ═══════════════════════════
status(){
  title "Статус хаба"
  load_meta 2>/dev/null && {
    echo "  Endpoint:   $ENDPOINT:$PORT"
    echo "  Server pub: ${SERVER_PUB:-$(awg pubkey < "$SRV_KEY" 2>/dev/null)}"
    echo "  WG:         $WG_NET  сервер $WG_ADDR"
  } || warn "Метаданных нет (хаб не настроен)."
  echo
  info "awg show:";            if awg show "$IFACE" >/dev/null 2>&1; then awg_show_named | sed 's/^/    /'; else echo "    (интерфейс не поднят)"; fi
  echo
  info "Маршруты в туннель:";  ip route show dev "$IFACE" 2>/dev/null | sed 's/^/    /' || true
  echo
  info "ufw:";                 ufw status verbose 2>/dev/null | sed 's/^/    /' || true
  echo
  info "Автозагрузка:";        systemctl is-enabled "awg-quick@$IFACE" 2>/dev/null | sed 's/^/    awg-quick@'"$IFACE"': /' || true
  pause
}

# ═══════════════════════════ ГЛАВНОЕ МЕНЮ ═══════════════════════════
main_menu(){
  while true; do
    clear 2>/dev/null || true
    printf '%s  AmneziaWG HUB — управление (Ubuntu)%s\n' "$c_mag$c_bold" "$c_reset"
    hr
    if load_meta 2>/dev/null; then
      printf '  %sхаб настроен%s: %s:%s  (%s)\n' "$c_grn" "$c_reset" "$ENDPOINT" "$PORT" "$WG_NET"
    else
      printf '  %sхаб ещё не настроен%s\n' "$c_ylw" "$c_reset"
    fi
    hr
    cat <<EOF
  1) Установить / пересобрать хаб (bootstrap)
  2) Управление пирами
  3) Статус
  0) Выход
EOF
    case "$(ask 'Выбор' '1')" in
      1) bootstrap ;;
      2) peers_menu ;;
      3) status ;;
      0) exit 0 ;;
      *) warn "Не понял."; sleep 1 ;;
    esac
  done
}

main_menu
