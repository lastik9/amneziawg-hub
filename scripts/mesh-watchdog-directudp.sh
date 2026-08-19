#!/bin/sh
# mesh-watchdog — ШАБЛОН для DIRECT-UDP узла (AWG-пир смотрит прямо на публичный IP хаба,
# БЕЗ clash/wstunnel в тракте меша). Пример узла: hub53.
# Лесенка (проще деревенской — нет транспортных сервисов для рестарта):
#   хендшейк протух -> ifdown/ifup awg -> пауза -> всё ещё мёртв -> reboot (не чаще 1 раза в час).
#
# УСТАНОВКА: перед развёртыванием подставь реальное имя AWG-интерфейса в ДВА места ниже
#   (EXPECT_IFACE и IFACE). Имя брать из `awg show interfaces` НА САМОМ УЗЛЕ — оно может
#   не совпадать с именем uci-секции (durable-грабли hub53, см. docs/04-watchdog.md).
# GUARD: если живой iface != ожидаемого — выходим без единого действия (защита от запуска
#   не на том узле; введён после инцидента затирания v23).
EXPECT_IFACE="__SET_IFACE__"
IFACE="__SET_IFACE__"
MAX_AGE=300
REBOOT_COOLDOWN=3600
COOLDOWN_MARK="/tmp/mesh-wd-last-reboot"
TAG="mesh-wd"

# --- guard "кто я": никаких действий на чужом узле ---
cur=$(awg show interfaces 2>/dev/null | head -1)
if [ "$cur" != "$EXPECT_IFACE" ]; then
  logger -t "$TAG" "GUARD: iface '$cur' != '$EXPECT_IFACE' -> no-op"
  exit 0
fi

age_of() {                       # печатает: <age_sec> <handshake_unixtime>
  now=$(date +%s)
  hs=$(awg show "$IFACE" latest-handshakes 2>/dev/null | awk 'NF>=2{print $2; exit}')
  [ -n "$hs" ] || hs=0
  echo $(( now - hs )) "$hs"
}

set -- $(age_of); age=$1; hs=$2
if [ "$hs" -gt 0 ] && [ "$age" -lt "$MAX_AGE" ]; then
  exit 0                         # жив — молчим (пустой logread = норма)
fi

logger -t "$TAG" "stale (age=${age}s hs=${hs}) -> ifdown/ifup $IFACE"
ifdown "$IFACE"; sleep 3; ifup "$IFACE"; sleep 90

set -- $(age_of); age=$1; hs=$2
if [ "$hs" -gt 0 ] && [ "$age" -lt "$MAX_AGE" ]; then
  logger -t "$TAG" "recovered after ifup (age=${age}s)"
  exit 0
fi

now=$(date +%s); last=0
[ -f "$COOLDOWN_MARK" ] && last=$(cat "$COOLDOWN_MARK" 2>/dev/null || echo 0)
if [ $(( now - last )) -ge "$REBOOT_COOLDOWN" ]; then
  echo "$now" > "$COOLDOWN_MARK"
  logger -t "$TAG" "still stale (age=${age}s) -> REBOOT"
  sync; reboot
else
  logger -t "$TAG" "still stale, reboot on cooldown ($(( now - last ))s < ${REBOOT_COOLDOWN}s)"
fi
exit 0
