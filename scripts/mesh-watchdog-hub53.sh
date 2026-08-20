#!/bin/sh
# mesh-watchdog — hub53 (awg_hub53), дорога A (AWG-in-WSS через clash+wstunnel), как деревня
# hub53 переведён на дорогу A в v24 (2026-08-20). Прямой UDP — ручной резерв, watchdog его НЕ трогает.
# Лесенка: хендшейк протух -> restart clash -> пауза -> restart wstunnel -> пауза
#          -> всё ещё мёртв -> reboot (не чаще 1 раза в час).
# GUARD: если это не awg_hub53 — выходим без единого действия (защита от запуска не на том узле).
EXPECT_IFACE="awg_hub53"
IFACE="awg_hub53"
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

logger -t "$TAG" "stale (age=${age}s hs=${hs}) -> restart clash"
/etc/init.d/clash restart; sleep 90

set -- $(age_of); age=$1; hs=$2
if [ "$hs" -gt 0 ] && [ "$age" -lt "$MAX_AGE" ]; then
  logger -t "$TAG" "recovered after clash restart (age=${age}s)"
  exit 0
fi

logger -t "$TAG" "still stale (age=${age}s) -> restart wstunnel"
/etc/init.d/wstunnel restart; sleep 90

set -- $(age_of); age=$1; hs=$2
if [ "$hs" -gt 0 ] && [ "$age" -lt "$MAX_AGE" ]; then
  logger -t "$TAG" "recovered after wstunnel restart (age=${age}s)"
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
