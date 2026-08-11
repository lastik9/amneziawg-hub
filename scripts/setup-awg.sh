#!/bin/sh
# setup-awg.sh — установка пакетов AmneziaWG и настройка интерфейса + firewall-зоны
# на OpenWrt (24.10.3+ / 25.12.x). Podkop НЕ трогает.
#
# Использование:
#   sh setup-awg.sh                       # интерактивный мастер (если нет awg.env)
#   sh setup-awg.sh -i                    # интерактивный мастер (явно)
#   sh setup-awg.sh --from-conf my.conf   # генерирует awg.env из .conf и выходит (проверь глазами!)
#   sh setup-awg.sh --no-install          # только настройка, без установки пакетов
#   sh setup-awg.sh --env /path/awg.env   # указать другой env-файл
#   sh setup-awg.sh --reboot              # тихо перезагрузить при необходимости (без 15-сек отсчёта)
#   sh setup-awg.sh --mesh                # режим МЕШа (any-to-any LAN<->меш), не podkop
#                                         # LuCI/SSH узла из меша ОТКРЫТЫ по умолчанию (вся 10.0.0.0/24)
#   sh setup-awg.sh --mesh --admin 10.0.0.10,10.0.0.11
#                                         # сузить доступ к LuCI/SSH узла до этих адресов
#   sh setup-awg.sh --mesh --no-admin     # не открывать управление узла из меша (только из LAN узла)
#   sh setup-awg.sh --mesh --admin-ports "22 80 443"
#                                         # какие порты узла открывать из меша (дефолт: 22 80 443 9090;
#                                         # 9090 = Clash-панель, нужен только ssclash-узлам). Также env ADMIN_PORTS=
#   sh setup-awg.sh --mesh --reconnect    # обновить пир (ключ/endpoint/allowed_ips хаба) без пересоздания
#   sh setup-awg.sh --check               # САМОПРОВЕРКА узла (read-only): iface/пир-хаб/маршруты/
#                                         # nft/src_ip(#18)/masq/ping — PASS/FAIL. Ничего не меняет.
#
# Интерактивный мастер спросит имя интерфейса (напр. awg_nl), откроет редактор для
# вставки .conf и создаст всё сам. Несколько серверов = несколько интерфейсов с
# разными именами в ОДНОЙ общей firewall-зоне.
#
# --mesh: узел становится site-узлом меша (LAN за роутером видит меш и наоборот).
#   Отличия от podkop-режима: masq выключен (адреса в меше не переписываем),
#   пересылка lan<->awg в ОБЕ стороны, ICMP по мешу разрешён. Управление узла
#   (LuCI/SSH) из меша по умолчанию ОТКРЫТО для всей mesh-подсети; сузить — --admin,
#   закрыть — --no-admin.
#
# Интерфейс создаётся ТОЛЬКО если его ещё нет (существующий не затирается).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo .)"
ENV_FILE="$SCRIPT_DIR/awg.env"
DO_INSTALL=1
AUTO_REBOOT=0
WIZARD=0
MESH_MODE=0         # 1 = меш (any-to-any), см. --mesh
ADMIN_IPS=''        # кому открыть LuCI/SSH узла из меша (--admin); пусто = вся mesh-подсеть (см. NO_ADMIN)
NO_ADMIN=0          # 1 = НЕ открывать управление узла из меша (--no-admin)
RECONNECT=0         # 1 = обновить существующий интерфейс (ключ хаба/endpoint/allowed_ips), см. --reconnect
CHECK_MODE=0        # 1 = только самопроверка узла (read-only), см. --check
MESH_SUBNET='10.0.0.0/24'  # источник по умолчанию для доступа к управлению узла в mesh-режиме
ADMIN_PORTS="${ADMIN_PORTS:-22 80 443 9090}"  # порты узла из меша (env ADMIN_PORTS= / флаг --admin-ports). Дефолт: SSH(22)/LuCI(80,443)+Clash(9090); 9090 нужен только ssclash-узлам
SHARED_ZONE='awg'   # общая зона для всех awg-интерфейсов
INSTALLER_URL='https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/refs/heads/master/amneziawg-install.sh'

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
ask()  { printf '%s' "$1" >&2; read -r REPLY; }

# ---------- разбор аргументов ----------
FROM_CONF=''
while [ $# -gt 0 ]; do
  case "$1" in
    --from-conf) FROM_CONF="${2:-}"; shift 2 || die "--from-conf требует путь к .conf" ;;
    -i|--wizard) WIZARD=1; shift ;;
    --no-install) DO_INSTALL=0; shift ;;
    --reboot) AUTO_REBOOT=1; shift ;;
    --mesh) MESH_MODE=1; shift ;;
    --admin) ADMIN_IPS="${2:-}"; MESH_MODE=1; shift 2 || die "--admin требует список адресов через запятую" ;;
    --admin-ports) ADMIN_PORTS="${2:-}"; shift 2 || die "--admin-ports требует список портов через пробел (в кавычках)" ;;
    --no-admin) NO_ADMIN=1; shift ;;
    --reconnect) RECONNECT=1; shift ;;
    --check) CHECK_MODE=1; shift ;;
    --env) ENV_FILE="${2:-}"; shift 2 || die "--env требует путь" ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

# ---------- #15: валидация ADMIN_PORTS (непусто, только цифры и пробелы) ----------
case "$ADMIN_PORTS" in
  '')          die "ADMIN_PORTS пуст. Чтобы не открывать управление узла из меша — используй --no-admin." ;;
  *[!0-9\ ]*)  die "ADMIN_PORTS: только номера портов через пробел, а не: '$ADMIN_PORTS'" ;;
esac

# ---------- САМОПРОВЕРКА узла (--check): read-only диагностика ----------
# Ничего НЕ меняет: только awg show / ip route get / nft list / uci show / ping.
# Сворачивает проверки шага 6 (QUICKSTART-node) в PASS/FAIL. Требует env узла
# (IFACE, ALLOWED_IPS, PEER_PUBLIC_KEY, ENDPOINT_HOST, [ZONE_NAME]).
do_check() {
  _c_ok=0; _c_fail=0; _c_warn=0
  _c_p() { printf '  \033[1;32m[PASS]\033[0m %s\n' "$*"; _c_ok=$((_c_ok+1)); }
  _c_f() { printf '  \033[1;31m[FAIL]\033[0m %s\n' "$*"; _c_fail=$((_c_fail+1)); }
  _c_w() { printf '  \033[1;33m[WARN]\033[0m %s\n' "$*"; _c_warn=$((_c_warn+1)); }

  _c_zone="${ZONE_NAME:-$SHARED_ZONE}"
  printf '\n\033[1mСамопроверка узла — iface=%s, зона=%s\033[0m\n' "$IFACE" "$_c_zone"
  printf -- '----------------------------------------------------------------\n'

  # --- 1. интерфейс + пир-хаб (ключ / endpoint / handshake / RX>0 = детект v9) ---
  _c_dump="$(awg show "$IFACE" dump 2>/dev/null)"
  if [ -z "$_c_dump" ]; then
    _c_f "интерфейс $IFACE не поднят (awg show пуст)"
  else
    _c_p "интерфейс $IFACE поднят"
    _c_hub="$(echo "$_c_dump" | awk -v k="$PEER_PUBLIC_KEY" '$1==k{print;exit}')"
    if [ -z "$_c_hub" ]; then
      _c_f "пир-хаб с ключом ${PEER_PUBLIC_KEY%%=*}… НЕ найден в $IFACE"
    else
      _c_ep="$(echo "$_c_hub" | awk '{print $3}')"
      _c_hs="$(echo "$_c_hub" | awk '{print $5}')"
      _c_rx="$(echo "$_c_hub" | awk '{print $6}')"; _c_rx="${_c_rx:-0}"
      case "$_c_ep" in
        "${ENDPOINT_HOST:-x}":*) _c_p "endpoint хаба: $_c_ep" ;;
        *) _c_w "endpoint хаба = $_c_ep (ожидали ${ENDPOINT_HOST:-?}:*)" ;;
      esac
      if [ "${_c_hs:-0}" != 0 ]; then _c_p "handshake с хабом есть"; else _c_f "handshake с хабом НЕТ"; fi
      if [ "$_c_rx" -gt 0 ] 2>/dev/null; then
        _c_p "RX от хаба > 0 ($_c_rx B)"
      else
        _c_f "RX от хаба = 0 — сигнатура неверного pubkey (урок v9): сверь ключ хаба крест-накрест"
      fi
    fi
  fi

  # --- 2. маршруты: своя LAN -> br-lan; чужие LAN -> dev $IFACE (#17) ---
  _c_ownlan="$(ip route show dev br-lan scope link 2>/dev/null | awk '/proto kernel/{print $1; exit}')"
  if [ -n "$_c_ownlan" ]; then
    _c_ownprobe="$(echo "$_c_ownlan" | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3".254"}')"
    _c_dev="$(ip route get "$_c_ownprobe" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')"
    if [ "$_c_dev" = "br-lan" ]; then _c_p "своя LAN $_c_ownlan -> dev br-lan"; else _c_f "своя LAN $_c_ownlan -> dev ${_c_dev:-?} (ожидали br-lan)"; fi
  else
    _c_w "не удалось определить свою LAN (br-lan)"
  fi

  _c_old=$IFS; IFS=','
  for _c_net in $ALLOWED_IPS; do
    _c_net="$(echo "$_c_net" | tr -d ' ')"; [ -n "$_c_net" ] || continue
    case "$_c_net" in 10.0.0.0/24) continue ;; "$_c_ownlan") continue ;; esac
    _c_fgw="$(echo "$_c_net" | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3".1"}')"
    _c_fdev="$(ip route get "$_c_fgw" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')"
    if [ "$_c_fdev" = "$IFACE" ]; then _c_p "чужая LAN $_c_net -> dev $IFACE"; else _c_f "чужая LAN $_c_net -> dev ${_c_fdev:-?} (ожидали $IFACE) — #17?"; fi
  done
  IFS=$_c_old

  # --- 3. nft: цепочка input_$zone + admin-порты ---
  _c_chain="$(nft list chain inet fw4 "input_$_c_zone" 2>/dev/null)"
  if [ -z "$_c_chain" ]; then
    _c_f "nft-цепочка input_$_c_zone не поднята — зона не сработала (#18?)"
  else
    _c_p "nft-цепочка input_$_c_zone есть"
    _c_miss=''
    for _c_port in $ADMIN_PORTS; do
      echo "$_c_chain" | grep -Eq "(^|[^0-9])$_c_port([^0-9]|\$)" || _c_miss="$_c_miss $_c_port"
    done
    if [ -z "$_c_miss" ]; then _c_p "admin-порты открыты: $ADMIN_PORTS"; else _c_f "нет admin-портов в input_$_c_zone:$_c_miss"; fi
  fi

  # --- 4. src_ip admin-правила = СПИСОК (проверка фикса #18) ---
  _c_sec="$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='Allow-$_c_zone-admin'/\1/p" | head -1)"
  if [ -z "$_c_sec" ]; then
    _c_w "admin-правило Allow-$_c_zone-admin не найдено (--no-admin?)"
  else
    _c_src="$(uci -q get "firewall.$_c_sec.src_ip" 2>/dev/null)"
    _c_nwords="$(echo "$_c_src" | wc -w | tr -d ' ')"
    _c_nslash="$(echo "$_c_src" | tr -cd '/' | wc -c | tr -d ' ')"
    if [ "$_c_nwords" -ge 2 ]; then
      _c_p "src_ip admin-правила — список из $_c_nwords сетей (#18 ок)"
    elif [ "$_c_nslash" -ge 2 ]; then
      _c_f "src_ip СЛИПСЯ в один CIDR (#18!) — fw4 не поднимет зону. Hotfix: см. handoff."
    else
      _c_w "src_ip = '$_c_src' (одна сеть — норма для --admin с одним адресом)"
    fi
  fi

  # --- 5. masq зоны = 0 (меш) ---
  _c_zsec="$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='$_c_zone'\$/\1/p" | head -1)"
  [ -n "$_c_zsec" ] || _c_zsec="$_c_zone"
  _c_masq="$(uci -q get "firewall.$_c_zsec.masq" 2>/dev/null)"
  if [ "$_c_masq" = 0 ]; then _c_p "masq зоны $_c_zone = 0 (меш)"
  elif [ "$_c_masq" = 1 ]; then _c_f "masq зоны $_c_zone = 1 — в меше должно быть 0"
  else _c_w "masq зоны $_c_zone не определён ('$_c_masq')"; fi

  # --- 6. ping: хаб (обязателен) + шлюзы чужих LAN (зависят от удалённого узла) ---
  if ping -c1 -W2 10.0.0.1 >/dev/null 2>&1; then _c_p "ping хаба 10.0.0.1 — ок"; else _c_f "ping хаба 10.0.0.1 НЕ проходит"; fi
  _c_old=$IFS; IFS=','
  for _c_net in $ALLOWED_IPS; do
    _c_net="$(echo "$_c_net" | tr -d ' ')"; [ -n "$_c_net" ] || continue
    case "$_c_net" in 10.0.0.0/24) continue ;; "$_c_ownlan") continue ;; esac
    _c_fgw="$(echo "$_c_net" | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3".1"}')"
    if ping -c1 -W2 "$_c_fgw" >/dev/null 2>&1; then _c_p "ping шлюза чужой LAN $_c_fgw — ок"; else _c_w "ping $_c_fgw не прошёл (чужой узел офлайн? маршрут см. выше)"; fi
  done
  IFS=$_c_old

  printf -- '----------------------------------------------------------------\n'
  printf '  Итог: \033[1;32m%d PASS\033[0m / \033[1;31m%d FAIL\033[0m / \033[1;33m%d WARN\033[0m\n' "$_c_ok" "$_c_fail" "$_c_warn"
  [ "$_c_fail" = 0 ]
}

if [ "$CHECK_MODE" = 1 ]; then
  [ -r "$ENV_FILE" ] || die "Нет env-файла: $ENV_FILE (для --check нужен env узла, обычно /root/awg.env)"
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  : "${IFACE:?IFACE не задан в env}"
  : "${ALLOWED_IPS:?ALLOWED_IPS не задан в env}"
  : "${PEER_PUBLIC_KEY:?PEER_PUBLIC_KEY не задан в env}"
  do_check; exit $?
fi

# ---------- парсер .conf -> env (общий для --from-conf и мастера) ----------
# get KEY FILE — значение по ключу из .conf
conf_get() { awk -v k="$1" '
    { line=$0; sub(/#.*/,"",line) }
    line ~ "^[ \t]*"k"[ \t]*=" {
      sub("^[ \t]*"k"[ \t]*=[ \t]*","",line); sub(/[ \t]+$/,"",line)
      print line; exit
    }' "$2"; }
conf_geti1() { awk '/^[ \t]*I1[ \t]*=/{sub(/^[ \t]*I1[ \t]*=[ \t]*/,"");print;exit}' "$1"; }

# write_env CONF IFACE ZONE OUT — собрать env из CONF
write_env() {
  _conf="$1"; _iface="$2"; _zone="$3"; _out="$4"
  _ep=$(conf_get Endpoint "$_conf"); _eh=${_ep%:*}; _epp=${_ep##*:}
  {
    echo "# сгенерировано из $_conf $(date)"
    echo "IFACE='$_iface'"
    echo "PRIVATE_KEY='$(conf_get PrivateKey "$_conf")'"
    echo "ADDRESSES='$(conf_get Address "$_conf")'"
    echo "DNS='$(conf_get DNS "$_conf")'"
    echo "MTU='$(conf_get MTU "$_conf")'"
    for pair in Jc:JC Jmin:JMIN Jmax:JMAX S1:S1 S2:S2 S3:S3 S4:S4 H1:H1 H2:H2 H3:H3 H4:H4; do
      ck=${pair%:*}; ek=${pair#*:}; echo "$ek='$(conf_get "$ck" "$_conf")'"
    done
    echo "I1='$(conf_geti1 "$_conf")'"
    echo "PEER_PUBLIC_KEY='$(conf_get PublicKey "$_conf")'"
    echo "PRESHARED_KEY='$(conf_get PresharedKey "$_conf")'"
    echo "ENDPOINT_HOST='$_eh'"
    echo "ENDPOINT_PORT='$_epp'"
    echo "ALLOWED_IPS='$(conf_get AllowedIPs "$_conf")'"
    echo "KEEPALIVE='$(conf_get PersistentKeepalive "$_conf")'"
    echo "MAKE_ZONE='1'"
    echo "ZONE_NAME='$_zone'"
  } > "$_out"
}

# normalize_iface NAME — привести имя интерфейса к валидному UCI-виду
normalize_iface() {
  _n="$1"
  _clean=$(printf '%s' "$_n" | tr '-' '_' | tr -cd 'A-Za-z0-9_')
  printf '%s' "$_clean" | cut -c1-15
}

# ---------- режим генерации env из .conf ----------
if [ -n "$FROM_CONF" ]; then
  [ -r "$FROM_CONF" ] || die "Не читается файл: $FROM_CONF"
  OUT="$ENV_FILE"
  [ -e "$OUT" ] && { warn "$OUT уже есть — пишу в $OUT.new"; OUT="$OUT.new"; }
  write_env "$FROM_CONF" "awg0" "$SHARED_ZONE" "$OUT"
  log "Записан $OUT"
  warn "ВАЖНО: открой $OUT и проверь значения (особенно I1 и ADDRESSES) перед запуском."
  if ! grep -qE "^KEEPALIVE='[0-9]+'" "$OUT"; then
    warn "KEEPALIVE пуст (в .conf нет PersistentKeepalive). За NAT впиши KEEPALIVE='25':"
    warn "  sed -i \"s/^KEEPALIVE=.*/KEEPALIVE='25'/\" $OUT"
  fi
  exit 0
fi

# ---------- интерактивный мастер ----------
# запускается по -i ЛИБО когда нет awg.env и не заданы флаги настройки
if [ "$WIZARD" = 1 ] || { [ ! -r "$ENV_FILE" ] && [ -t 0 ]; }; then
  command -v uci >/dev/null || die "uci не найден — это точно OpenWrt? Мастер запускается на роутере."
  echo "=== Мастер настройки AmneziaWG ==="

  # 1) имя интерфейса
  while :; do
    ask "Имя интерфейса (напр. awg_nl, awg_de): "
    # берём только ПЕРВЫЙ токен ввода: защита от мусора/typeahead в буфере,
    # иначе tr -cd склеил бы многословный ввод в одно имя.
    raw=$(printf '%s' "$REPLY" | awk '{print $1; exit}')
    [ -z "$raw" ] && { warn "Пусто, попробуй ещё раз."; continue; }
    iface=$(normalize_iface "$raw")
    [ -z "$iface" ] && { warn "Недопустимое имя, попробуй ещё раз."; continue; }
    if [ "$iface" != "$raw" ]; then
      warn "Имя приведено к '$iface' (UCI допускает только буквы/цифры/подчёркивание, максимум 15)."
    fi
    if uci -q get "network.$iface" >/dev/null; then
      warn "Интерфейс '$iface' уже существует. Выбери другое имя."
      continue
    fi
    # подтверждение — последний рубеж против опечаток и мусора из буфера ввода
    ask "Создать интерфейс с именем '$iface'? (Y/n): "
    case "$REPLY" in
      n|N|н|Н|no|NO|нет|НЕТ|Нет) continue ;;
    esac
    break
  done

  # 2) редактор для вставки .conf
  tmpconf="/tmp/awg-wizard.$$.conf"
  {
    echo "# Paste your full .conf below (from [Interface] to the end of [Peer]),"
    echo "# then save and quit. Lines starting with # are ignored."
  } > "$tmpconf"
  ed="${EDITOR:-vi}"
  command -v "$ed" >/dev/null 2>&1 || ed=vi
  log "Открываю $ed — вставь конфиг, затем сохрани и выйди (в vi: Esc, :wq)."
  sleep 1
  "$ed" "$tmpconf"

  # проверим, что что-то ввели
  grep -q '^[ \t]*PrivateKey[ \t]*=' "$tmpconf" || { rm -f "$tmpconf"; die "В конфиге нет PrivateKey — отмена."; }
  grep -q '^[ \t]*PublicKey[ \t]*='  "$tmpconf" || { rm -f "$tmpconf"; die "В конфиге нет PublicKey — отмена."; }

  # 3) собираем env под именем интерфейса, зона общая
  ENV_FILE="/tmp/awg-$iface.env"
  write_env "$tmpconf" "$iface" "$SHARED_ZONE" "$ENV_FILE"
  rm -f "$tmpconf"

  # 4) keepalive
  if ! grep -qE "^KEEPALIVE='[0-9]+'" "$ENV_FILE"; then
    ask "Persistent keepalive в секундах (Enter = 25, за NAT рекомендуется): "
    ka="${REPLY:-25}"
    case "$ka" in ''|*[!0-9]*) ka=25 ;; esac
    sed -i "s/^KEEPALIVE=.*/KEEPALIVE='$ka'/" "$ENV_FILE"
  fi

  log "env собран: $ENV_FILE (интерфейс '$iface', зона '$SHARED_ZONE'). Продолжаю установку..."
fi


# ---------- загрузка env ----------
[ -r "$ENV_FILE" ] || die "Нет env-файла: $ENV_FILE (создай из шаблона или используй --from-conf)"
# shellcheck disable=SC1090
. "$ENV_FILE"

: "${IFACE:=awg0}"
[ -n "${PRIVATE_KEY:-}" ]     || die "PRIVATE_KEY пуст"
[ -n "${PEER_PUBLIC_KEY:-}" ] || die "PEER_PUBLIC_KEY пуст"
[ -n "${ENDPOINT_HOST:-}" ]   || die "ENDPOINT_HOST пуст"
[ -n "${ENDPOINT_PORT:-}" ]   || die "ENDPOINT_PORT пуст"
[ -n "${ADDRESSES:-}" ]       || die "ADDRESSES пуст"

command -v uci >/dev/null || die "uci не найден — это точно OpenWrt?"

# ---------- установка пакетов ----------
if [ "$DO_INSTALL" = 1 ]; then
  if command -v awg >/dev/null 2>&1 && [ -f /lib/netifd/proto/amneziawg.sh ]; then
    log "Пакеты AmneziaWG уже установлены — пропускаю установку."
  else
    log "Ставлю пакеты AmneziaWG через официальный установщик..."
    command -v wget >/dev/null || die "wget не найден"
    TMP_INST="/tmp/amneziawg-install.$$.sh"
    wget -4 -qO "$TMP_INST" "$INSTALLER_URL" || { rm -f "$TMP_INST"; die "Не удалось скачать установщик"; }
    # neutral-режим: отвечаем n на все интерактивные вопросы (язык, настройка интерфейса)
    printf 'n\nn\nn\n' | sh "$TMP_INST" \
      || warn "Установщик вернул ошибку — проверь вывод выше. Если пакеты всё же встали, продолжаю."
    rm -f "$TMP_INST"
  fi
else
  log "--no-install: установку пакетов пропускаю."
fi

command -v awg >/dev/null || die "awg не найден после установки — настройку прервал."

# ---------- проверка: интерфейс уже есть? ----------
if uci -q get "network.$IFACE" >/dev/null; then
  if [ "$RECONNECT" = 1 ]; then
    # --reconnect: интерфейс не пересоздаём (ключ узла/адреса сохраняем), но
    # ОБНОВЛЯЕМ параметры пира из env — на случай смены ключа/endpoint хаба
    # (грабля #10: после пересборки хаба узел смотрит на мёртвый public_key).
    log "--reconnect: обновляю параметры пира интерфейса $IFACE из env..."
    # ищем peer-секцию этого интерфейса (обычно @amneziawg_<iface>[0])
    _psec=""
    for s in $(uci show network 2>/dev/null \
               | sed -n "s/^network\.\(@amneziawg_$IFACE\[[0-9]*\]\)=.*/\1/p"); do
      _psec="$s"; break
    done
    if [ -z "$_psec" ]; then
      warn "peer-секция для $IFACE не найдена — нечего обновлять. Продолжаю как есть."
    else
      uci set "network.$_psec.public_key=$PEER_PUBLIC_KEY"
      uci set "network.$_psec.endpoint_host=$ENDPOINT_HOST"
      uci set "network.$_psec.endpoint_port=$ENDPOINT_PORT"
      [ -n "${KEEPALIVE:-}" ] && uci set "network.$_psec.persistent_keepalive=$KEEPALIVE"
      if [ -n "${PRESHARED_KEY:-}" ]; then uci set "network.$_psec.preshared_key=$PRESHARED_KEY"
      else uci -q delete "network.$_psec.preshared_key"; fi
      # allowed_ips пересобираем из env (топология меша могла измениться)
      uci -q delete "network.$_psec.allowed_ips"
      OLDIFS=$IFS; IFS=','
      for ip in $ALLOWED_IPS; do
        ip=$(echo "$ip" | tr -d ' '); [ -n "$ip" ] && uci add_list "network.$_psec.allowed_ips=$ip"
      done
      IFS=$OLDIFS
      uci commit network
      log "peer обновлён (public_key/endpoint/allowed_ips из env)."
    fi
  else
    warn "Секция network.$IFACE уже существует — НЕ трогаю её (режим 'создать только если нет')."
    warn "Сменился ключ/endpoint хаба? Обнови пир не пересоздавая:  sh setup-awg.sh --mesh --reconnect"
    warn "Пересоздать целиком: uci delete network.$IFACE и её peer-секции, потом запусти снова."
  fi
  SKIP_IFACE=1
else
  SKIP_IFACE=0
fi

# ---------- создание интерфейса ----------
if [ "$SKIP_IFACE" = 0 ]; then
  log "Создаю интерфейс $IFACE..."
  uci set "network.$IFACE=interface"
  uci set "network.$IFACE.proto=amneziawg"
  uci set "network.$IFACE.private_key=$PRIVATE_KEY"
  [ -n "${MTU:-}" ] && uci set "network.$IFACE.mtu=$MTU"
  # ВАЖНО для podkop: не создаём default route, иначе весь трафик уйдёт в туннель
  uci set "network.$IFACE.defaultroute=0"
  # снимаем делегирование IPv6-префиксов — для VPN-интерфейса не нужно
  uci set "network.$IFACE.delegate=0"

  # адреса (может быть несколько через запятую)
  uci -q delete "network.$IFACE.addresses"
  OLDIFS=$IFS; IFS=','
  for a in $ADDRESSES; do
    a=$(echo "$a" | tr -d ' '); [ -n "$a" ] && uci add_list "network.$IFACE.addresses=$a"
  done
  IFS=$OLDIFS

  # DNS (необязательно)
  if [ -n "${DNS:-}" ]; then
    uci -q delete "network.$IFACE.dns"
    OLDIFS=$IFS; IFS=','
    for d in $DNS; do
      d=$(echo "$d" | tr -d ' '); [ -n "$d" ] && uci add_list "network.$IFACE.dns=$d"
    done
    IFS=$OLDIFS
  fi

  # obfuscation-параметры — задаём только непустые.
  # ${VAR:-} чтобы set -u не ронял скрипт на отсутствующей переменной.
  for pair in "awg_jc:${JC:-}" "awg_jmin:${JMIN:-}" "awg_jmax:${JMAX:-}" \
              "awg_s1:${S1:-}" "awg_s2:${S2:-}" "awg_s3:${S3:-}" "awg_s4:${S4:-}" \
              "awg_h1:${H1:-}" "awg_h2:${H2:-}" "awg_h3:${H3:-}" "awg_h4:${H4:-}" \
              "awg_i1:${I1:-}"; do
    key=${pair%%:*}; val=${pair#*:}
    [ -n "$val" ] && uci set "network.$IFACE.$key=$val"
  done

  # ---- peer ----
  log "Создаю peer..."
  peer=$(uci add network amneziawg_$IFACE)
  uci set "network.$peer.public_key=$PEER_PUBLIC_KEY"
  [ -n "${PRESHARED_KEY:-}" ] && uci set "network.$peer.preshared_key=$PRESHARED_KEY"
  uci set "network.$peer.endpoint_host=$ENDPOINT_HOST"
  uci set "network.$peer.endpoint_port=$ENDPOINT_PORT"
  [ -n "${KEEPALIVE:-}" ] && uci set "network.$peer.persistent_keepalive=$KEEPALIVE"
  uci set "network.$peer.route_allowed_ips=0"   # ВАЖНО для podkop: маршруты не создаём
  OLDIFS=$IFS; IFS=','
  for ip in $ALLOWED_IPS; do
    ip=$(echo "$ip" | tr -d ' '); [ -n "$ip" ] && uci add_list "network.$peer.allowed_ips=$ip"
  done
  IFS=$OLDIFS

  uci commit network
  log "network настроен."
fi

# ---------- firewall зона (общая для всех awg-интерфейсов) ----------
if [ "${MAKE_ZONE:-0}" = 1 ]; then
  ZONE_NAME="${ZONE_NAME:-awg}"
  # ищем секцию зоны по имени: сначала именованная, потом анонимная
  zsec=""
  if uci -q get "firewall.$ZONE_NAME" >/dev/null; then
    zsec="$ZONE_NAME"
  else
    for s in $(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='$ZONE_NAME'/\1/p"); do
      zsec="$s"; break
    done
  fi

  if [ -n "$zsec" ]; then
    # зона есть — добавляем интерфейс в её network, если его там ещё нет
    if uci -q get "firewall.$zsec.network" | grep -qw "$IFACE"; then
      log "Интерфейс $IFACE уже в зоне $ZONE_NAME."
    else
      uci add_list "firewall.$zsec.network=$IFACE"
      uci commit firewall
      /etc/init.d/firewall reload >/dev/null 2>&1
      log "Интерфейс $IFACE добавлен в существующую зону $ZONE_NAME."
    fi
  else
    # masq: в podkop-режиме нужен (трафик наружу через туннель); в меше ВРЕДЕН
    # (переписывает адреса — conntrack не находит сессию, ответ = Port Unreachable).
    if [ "$MESH_MODE" = 1 ]; then _masq=0; else _masq=1; fi
    log "Создаю firewall-зону $ZONE_NAME (input/forward REJECT, output ACCEPT, masq=$_masq, mss)..."
    uci set "firewall.$ZONE_NAME=zone"
    uci set "firewall.$ZONE_NAME.name=$ZONE_NAME"
    uci set "firewall.$ZONE_NAME.input=REJECT"
    uci set "firewall.$ZONE_NAME.output=ACCEPT"
    uci set "firewall.$ZONE_NAME.forward=REJECT"
    uci set "firewall.$ZONE_NAME.masq=$_masq"
    uci set "firewall.$ZONE_NAME.mtu_fix=1"
    uci add_list "firewall.$ZONE_NAME.network=$IFACE"
    uci commit firewall
    /etc/init.d/firewall reload >/dev/null 2>&1
    if [ "$MESH_MODE" = 1 ]; then
      log "firewall-зона создана (масштаб меша: masq выключен)."
    else
      log "firewall-зона создана. Пересылку lan->$ZONE_NAME НЕ добавляю (podkop сам)."
    fi
  fi

  # ---- меш-доводка firewall (any-to-any LAN<->меш) ----
  # В podkop-режиме НЕ выполняется: там маршрутизацией рулит podkop, masq нужен.
  if [ "$MESH_MODE" = 1 ]; then
    # на случай, если зона уже существовала с masq=1 (podkop-инсталл раньше) —
    # для меша принудительно снимаем masq.
    if [ "$(uci -q get "firewall.$ZONE_NAME.masq" 2>/dev/null)" = "1" ]; then
      uci set "firewall.$ZONE_NAME.masq=0"
      warn "Зона $ZONE_NAME была с masq=1 — для меша выключил masq."
    fi

    # forwarding lan<->awg в ОБЕ стороны (идемпотентно: не плодим дубли)
    _has_fwd() { # src dest -> 0 если правило src->dest уже есть
      for s in $(uci show firewall 2>/dev/null \
                 | sed -n "s/^firewall\.\(@forwarding\[[0-9]*\]\)\.src='$1'/\1/p"); do
        [ "$(uci -q get "firewall.$s.dest")" = "$2" ] && return 0
      done
      return 1
    }
    _add_fwd() { # src dest
      if _has_fwd "$1" "$2"; then
        log "forwarding $1->$2 уже есть."
      else
        f=$(uci add firewall forwarding)
        uci set "firewall.$f.src=$1"
        uci set "firewall.$f.dest=$2"
        log "forwarding $1->$2 добавлен."
      fi
    }
    _add_fwd lan "$ZONE_NAME"
    _add_fwd "$ZONE_NAME" lan

    # ---- меш-маршруты к ЧУЖИМ LAN (#17) ----
    # route_allowed_ips=0 (для podkop/forkop) НЕ создаёт kernel-маршруты в туннель,
    # поэтому LAN других узлов недостижимы (трафик уходит в WAN). Добавляем точечные
    # UCI-маршруты ко всем меш-LAN из ALLOWED_IPS, КРОМЕ WG-подсети и своей LAN.
    # route_allowed_ips оставляем 0 — forkop/podkop не страдает, маршруты точечные.
    _own_lan="$(ip route show dev br-lan scope link 2>/dev/null | awk '/proto kernel/{print $1; exit}')"
    _has_route() { # $1=подсеть -> 0 если UCI-route на этот target через $IFACE уже есть
      for _rs in $(uci show network 2>/dev/null \
                   | sed -n "s/^network\.\(@route\[[0-9]*\]\)\.target='$1'\$/\1/p"); do
        [ "$(uci -q get "network.$_rs.interface")" = "$IFACE" ] && return 0
      done
      return 1
    }
    OLDIFS=$IFS; IFS=','
    for _net in $ALLOWED_IPS; do
      _net=$(echo "$_net" | tr -d ' '); [ -n "$_net" ] || continue
      # пропускаем WG-подсеть (on-link через $IFACE) и свою LAN (она на br-lan)
      [ "$_net" = "$MESH_SUBNET" ] && continue
      [ -n "$_own_lan" ] && [ "$_net" = "$_own_lan" ] && continue
      if _has_route "$_net"; then
        log "меш-маршрут $_net -> $IFACE уже есть."
      else
        _r=$(uci add network route)
        uci set "network.$_r.interface=$IFACE"
        uci set "network.$_r.target=$_net"
        uci set "network.$_r.gateway=0.0.0.0"
        log "меш-маршрут $_net -> $IFACE добавлен."
      fi
    done
    IFS=$OLDIFS
    uci commit network

    # ICMP по мешу к самому роутеру (узлы должны пинговаться; input зоны=REJECT)
    if ! uci show firewall | grep -q "name='Allow-$ZONE_NAME-ICMP'"; then
      r=$(uci add firewall rule)
      uci set "firewall.$r.name=Allow-$ZONE_NAME-ICMP"
      uci set "firewall.$r.src=$ZONE_NAME"
      uci set "firewall.$r.proto=icmp"
      uci set "firewall.$r.icmp_type=echo-request"
      uci set "firewall.$r.family=ipv4"
      uci set "firewall.$r.target=ACCEPT"
      log "ICMP из меша к роутеру разрешён."
    fi

    # управление узлом (LuCI/SSH) из меша.
    # По умолчанию в mesh-режиме ОТКРЫВАЕМ для всей mesh-подсети ($MESH_SUBNET) —
    # чтобы узел сразу был управляем из меша (грабля #9: input зоны=REJECT рубит TCP).
    #   --admin a,b,c  -> сузить до конкретных адресов;
    #   --no-admin     -> не открывать совсем (доступ только из LAN узла).
    if [ "$NO_ADMIN" = 1 ]; then
      warn "Управление узла из меша НЕ открыто (--no-admin). LuCI/SSH доступны только из LAN узла."
      warn "  Открыть позже:  sh setup-awg.sh --mesh --reconnect   (дефолт = вся $MESH_SUBNET)"
    else
      # чей адрес разрешаем: список из --admin, иначе ВСЕ меш-сети (#18).
      # Раньше был только $MESH_SUBNET (10.0.0.0/24) — тогда устройства из LAN
      # других узлов (192.168.x.x) не попадали под admin и не открывали LuCI/SSH
      # чужого роутера. Берём весь ALLOWED_IPS; список запятых режется циклом ниже (IFS=',').
      if [ -n "$ADMIN_IPS" ]; then _admin_src="$ADMIN_IPS"; else _admin_src="$ALLOWED_IPS"; fi
      if ! uci show firewall | grep -q "name='Allow-$ZONE_NAME-admin'"; then
        r=$(uci add firewall rule)
        uci set "firewall.$r.name=Allow-$ZONE_NAME-admin"
        uci set "firewall.$r.src=$ZONE_NAME"
        uci set "firewall.$r.proto=tcp"
        uci set "firewall.$r.dest_port=$ADMIN_PORTS"
        uci set "firewall.$r.target=ACCEPT"
        OLDIFS=$IFS; IFS=','
        for aip in $_admin_src; do
          aip=$(echo "$aip" | tr -d ' '); [ -n "$aip" ] && uci add_list "firewall.$r.src_ip=$aip"
        done
        IFS=$OLDIFS
        log "Управление узла (порты $ADMIN_PORTS) из меша открыто для: $_admin_src"
      else
        log "Правило Allow-$ZONE_NAME-admin уже есть — не дублирую."
      fi
    fi

    uci commit firewall
    /etc/init.d/firewall reload >/dev/null 2>&1
    log "Меш-доводка firewall применена."
  fi
fi

# ---------- поднять интерфейс ----------
log "Поднимаю интерфейс $IFACE..."
# netifd регистрирует proto-хендлеры только при старте своего процесса.
# При свежей установке пакетов /lib/netifd/proto/amneziawg.sh появляется уже
# ПОСЛЕ старта netifd, поэтому proto ещё не зарегистрирован — и ни reload_config,
# ни "/etc/init.d/network restart" его не подхватывают. Помогает только reboot,
# при котором netifd сканирует /lib/netifd/proto заново. На уже "прогретом"
# роутере (proto зарегистрирован) reboot не нужен — интерфейс встаёт сразу.
reload_config 2>/dev/null
sleep 1
ifup "$IFACE" 2>/dev/null
sleep 3

# Проверяем, что РЕАЛЬНО произошло: если netifd не знает proto amneziawg,
# он подставляет заглушку "none". Это честнее, чем гадать "ставились ли пакеты".
proto_now=$(ubus call network.interface."$IFACE" status 2>/dev/null \
            | sed -n 's/.*"proto": *"\([^"]*\)".*/\1/p')

if [ "$proto_now" != "amneziawg" ]; then
  echo
  warn "netifd пока не знает proto 'amneziawg' (свежая установка пакетов)."
  warn "Конфигурация записана корректно — для её применения нужен ОДИН reboot."
  echo

  # Неинтерактивный режим (--reboot / запуск без терминала): без отсчёта.
  if [ "${AUTO_REBOOT:-0}" = 1 ]; then
    log "AUTO_REBOOT — перезагружаю роутер..."
    reboot
    exit 0
  fi

  # Обратный отсчёт: по таймауту (15с без ответа) — перезагружаем.
  # Отмена — ввести n/н/no/нет и Enter. Пустой Enter = согласие (reboot).
  ans=''
  i=15
  while [ "$i" -gt 0 ]; do
    printf '\r\033[1;33m[!]\033[0m Перезагрузка через %2d сек. Отмена — клавиша [n], затем Enter: ' "$i"
    if read -t 1 -r ans 2>/dev/null; then
      break            # что-то ввели и нажали Enter — прекращаем отсчёт
    fi
    i=$((i - 1))
  done
  echo

  case "$ans" in
    n|N|н|Н|no|NO|нет|НЕТ|Нет)
      warn "Перезагрузка отменена."
      warn "Применить конфигурацию позже вручную:  reboot"
      warn "После загрузки интерфейс $IFACE поднимется сам. Проверка:  awg show $IFACE"
      echo
      if [ "$MESH_MODE" = 1 ]; then
        log "Дальше (после reboot): проверь меш —  awg show $IFACE  и  ping 10.0.0.1 (хаб)."
      else
        log "Дальше (после reboot): Services -> Podkop -> тип VPN, интерфейс $IFACE -> Save & Apply."
      fi
      ;;
    *)
      log "Перезагружаю роутер..."
      reboot
      ;;
  esac
  exit 0
fi

log "netifd знает proto — интерфейс поднят без перезагрузки."

# ---------- проверка ----------
echo
log "Статус:"
awg show "$IFACE" 2>/dev/null | grep -iE 'interface|endpoint|handshake|transfer|keepalive' || \
  warn "awg show ничего не вернул — интерфейс мог не подняться."

if awg show "$IFACE" 2>/dev/null | grep -qi 'latest handshake'; then
  log "УСПЕХ: handshake есть, туннель работает."
elif [ -n "${KEEPALIVE:-}" ] && [ "${KEEPALIVE:-0}" != 0 ]; then
  warn "Handshake пока нет — при keepalive=$KEEPALIVE появится в течение ~${KEEPALIVE}с."
  warn "Подожди и повтори:  awg show $IFACE"
else
  # keepalive=0 и маршрутов в туннель нет (route_allowed_ips=0 для podkop):
  # это НОРМА. Handshake появится, когда podkop направит трафик в туннель.
  log "Интерфейс поднят. Handshake появится, когда в туннель пойдёт трафик"
  log "(через podkop, либо задай PersistentKeepalive>0 в конфиге)."
fi

echo
if [ "$MESH_MODE" = 1 ]; then
  log "Готово (режим меша). Узел в меше: LAN за роутером видит меш и наоборот."
  log "Проверка с хаба:  ping <WG-адрес узла>  и  ping <LAN-адрес роутера>."
  if [ "$NO_ADMIN" = 1 ]; then
    log "Управление узла из меша закрыто (--no-admin) — доступ только из LAN узла."
  elif [ -n "$ADMIN_IPS" ]; then
    log "Управление узла из меша открыто для: $ADMIN_IPS"
  else
    log "Управление узла (порты $ADMIN_PORTS) из меша открыто для всей $MESH_SUBNET."
  fi
else
  log "Готово. Дальше: Services -> Podkop -> тип VPN, интерфейс $IFACE -> Save & Apply."
fi
