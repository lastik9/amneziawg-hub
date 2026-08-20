#!/usr/bin/env bash
#
# verify-registry.sh — read-only сверка боевого реестра хаба с публичной
# копией в git (registry/hub-peers/*.peer.pub). НИЧЕГО НЕ ПИШЕТ.
#
# Что делает:
#   1. По ssh на хабе: guard (iface awg0) -> по каждому пиру маска PSK,
#      нормализация полей, sha256. Leak-check ПЕРЕД выводом. Открытый PSK
#      по сети не идёт.
#   2. Локально: та же нормализация registry/hub-peers/*.peer.pub, sha256.
#   3. Сравнение sha попарно. Таблица. Exit 0 если всё сошлось, 1 при дрейфе,
#      >=2 при операционной ошибке (нет репозитория, ssh упал, guard, leak).
#
# Хаб задаётся через env AWG_HUB_SSH (по умолчанию root@v3174179) или можно
# прописать Host-алиас в ~/.ssh/config и передать его.
#
set -euo pipefail

HUB="${AWG_HUB_SSH:-root@138.16.178.138}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REG_DIR="$REPO_DIR/registry/hub-peers"

FIELDS='^(NAME|TYPE|PUBKEY|WG_IP|SUBNET|PSK|DESC)='

# --- удалённый снимок (выполняется НА ХАБЕ внутри ssh) ---------------------
# Печатает строки:  PEERSHA <name> <sha256>
# Guard: если iface != awg0 -> exit 3 (не хаб). Leak PSK -> exit 4.
# Путь реестра можно переопределить через AWG_SRC (для отладки); по умолчанию
# боевой /etc/awg-hub/peers.
read -r -d '' REMOTE_SNIPPET <<'REMOTE' || true
set -eu
src="${AWG_SRC:-/etc/awg-hub/peers}"
if [ -z "${AWG_SKIP_GUARD:-}" ]; then
  iface=$(awg show interfaces 2>/dev/null | head -1 || true)
  if [ "$iface" != "awg0" ]; then
    echo "ABORT: not hub (iface=${iface:-none})" >&2
    exit 3
  fi
fi
for f in "$src"/*.peer; do
  [ -e "$f" ] || { echo "ABORT: no peer files in $src" >&2; exit 5; }
  name=$(basename "$f" .peer)
  norm=$(grep -E '^(NAME|TYPE|PUBKEY|WG_IP|SUBNET|PSK|DESC)=' "$f" \
         | sed -E 's/^PSK=.*/PSK="<redacted>"/' \
         | LC_ALL=C sort)
  # leak-check: PSK-строка обязана содержать redacted
  if printf '%s\n' "$norm" | grep '^PSK=' | grep -qv redacted; then
    echo "ABORT: PSK leak for peer $name" >&2
    exit 4
  fi
  sha=$(printf '%s' "$norm" | sha256sum | awk '{print $1}')
  printf 'PEERSHA %s %s\n' "$name" "$sha"
done
REMOTE

die() { echo "verify-registry: $*" >&2; exit 2; }

[ -d "$REG_DIR" ] || die "нет каталога $REG_DIR"

# --- снимок с хаба ---------------------------------------------------------
if hub_out=$(ssh -o BatchMode=yes "$HUB" "$REMOTE_SNIPPET" 2>/tmp/vr_hub_err); then
  :
else
  rc=$?
  sed 's/^/  hub: /' /tmp/vr_hub_err >&2 || true
  rm -f /tmp/vr_hub_err
  die "удалённый снимок не удался (ssh/guard/leak), rc=$rc"
fi
rm -f /tmp/vr_hub_err

# --- снимок из git ---------------------------------------------------------
shopt -s nullglob
git_lines=""
found=0
for f in "$REG_DIR"/*.peer.pub; do
  found=1
  name=$(basename "$f" .peer.pub)
  norm=$(grep -E "$FIELDS" "$f" | sed -E 's/^PSK=.*/PSK="<redacted>"/' | LC_ALL=C sort)
  sha=$(printf '%s' "$norm" | shasum -a 256 | awk '{print $1}')
  git_lines+="$name $sha"$'\n'
done
shopt -u nullglob
[ "$found" -eq 1 ] || die "в $REG_DIR нет *.peer.pub"

# --- сравнение -------------------------------------------------------------
tmp_hub=$(mktemp); tmp_git=$(mktemp)
trap 'rm -f "$tmp_hub" "$tmp_git"' EXIT

printf '%s\n' "$hub_out" | awk '/^PEERSHA/{print $2, $3}' | LC_ALL=C sort > "$tmp_hub"
printf '%s' "$git_lines" | LC_ALL=C sort > "$tmp_git"

echo "hub : $HUB"
echo "repo: $REPO_DIR"
echo
printf '%-14s %-16s %s\n' "PEER" "STATUS" "SHA256"
printf '%-14s %-16s %s\n' "----" "------" "------"

join -a1 -a2 -e MISSING -o '0,1.2,2.2' "$tmp_hub" "$tmp_git" | awk '
{
  name=$1; h=$2; g=$3;
  if (h!="MISSING" && g!="MISSING" && h==g)      { st="OK";              det=substr(h,1,16)"…" }
  else if (h=="MISSING")                          { st="MISSING_ON_HUB";  det="(нет на хабе, есть в git)"; bad++ }
  else if (g=="MISSING")                          { st="MISSING_IN_GIT";  det="(есть на хабе, нет в git)"; bad++ }
  else                                            { st="DRIFT";           det="hub="substr(h,1,12)"… git="substr(g,1,12)"…"; bad++ }
  printf "%-14s %-16s %s\n", name, st, det
}
END { exit (bad>0 ? 1 : 0) }
'
rc=$?

echo
if [ "$rc" -eq 0 ]; then
  echo "РЕЗУЛЬТАТ: реестр в синхроне (registry/ == боевой хаб)."
else
  echo "РЕЗУЛЬТАТ: обнаружен ДРЕЙФ — см. строки выше."
fi
exit "$rc"
