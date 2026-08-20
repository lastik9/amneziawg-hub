#!/usr/bin/env bash
#
# verify-registry.sh — сверка боевого реестра хаба с публичной копией в git
# (registry/hub-peers/*.peer.pub).
#
# Подкоманды:
#   verify (по умолчанию) — READ-ONLY сверка. Ничего не пишет. Логика v26,
#                           байт-в-байт (тело внизу файла, НЕ трогать).
#   sync                  — снять свежий реестр с хаба и обновить публичную
#                           копию в дереве. По умолчанию DRY-RUN (только
#                           показывает, что изменилось бы). Запись — c --write,
#                           и даже тогда СТОП перед коммитом: коммит/пуш руками.
#
# Общие принципы (durable):
#   * Guard на хабе: iface awg0, иначе abort. Чужой узел не трогаем.
#   * Маска PSK и leak-check выполняются НА ХАБЕ до передачи по сети —
#     открытый PSK по проводу не идёт. Локально leak-check повторяется.
#   * sync НИКОГДА не коммитит, не пушит и не удаляет пиров (исчезнувший с
#     хаба пир помечается ORPHAN, файл остаётся — решение за человеком).
#
# Коды возврата:
#   verify: 0 синхрон | 1 дрейф | 2 любая операц.ошибка (в т.ч. guard/leak —
#           см. сообщение rc=N). ВНИМАНИЕ: verify схлопывает guard/leak в 2.
#   sync:   0 синхрон/нечего делать | 1 есть изменения к записи или ORPHAN |
#           2 окружение | 3 ssh не на хаб (guard) | 4 leak | 5 нет .peer на хабе
#
# Хаб задаётся через env AWG_HUB_SSH (по умолчанию root@138.16.178.138).
#
set -euo pipefail

HUB="${AWG_HUB_SSH:-root@138.16.178.138}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REG_DIR="$REPO_DIR/registry/hub-peers"

FIELDS='^(NAME|TYPE|PUBKEY|WG_IP|SUBNET|PSK|DESC)='

die() { echo "verify-registry: $*" >&2; exit 2; }

# --- удалённый снимок для VERIFY (НА ХАБЕ). Печатает: PEERSHA <name> <sha256> ---
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
  if printf '%s\n' "$norm" | grep '^PSK=' | grep -qv redacted; then
    echo "ABORT: PSK leak for peer $name" >&2
    exit 4
  fi
  sha=$(printf '%s' "$norm" | sha256sum | awk '{print $1}')
  printf 'PEERSHA %s %s\n' "$name" "$sha"
done
REMOTE

# --- удалённый снимок для SYNC (НА ХАБЕ). Печатает: PEER <name> <base64(masked-body)> ---
# Тело = поля в ФАЙЛОВОМ порядке, PSK замаскирован (для байт-точной записи).
# Маска и leak-check ТУТ, до base64: открытый PSK по сети не идёт.
read -r -d '' SYNC_REMOTE <<'REMOTE' || true
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
  body=$(grep -E '^(NAME|TYPE|PUBKEY|WG_IP|SUBNET|PSK|DESC)=' "$f" \
         | sed -E 's/^PSK=.*/PSK="<redacted>"/')
  if printf '%s\n' "$body" | grep '^PSK=' | grep -qv redacted; then
    echo "ABORT: PSK leak for peer $name" >&2
    exit 4
  fi
  b64=$(printf '%s\n' "$body" | base64 | tr -d '\n')
  printf 'PEER %s %s\n' "$name" "$b64"
done
REMOTE

# base64-декод, переносимо между GNU (Linux) и BSD (macOS): openssl есть на обоих.
b64decode() { printf '%s' "$1" | openssl base64 -d -A; }
valid_name() { printf '%s' "$1" | grep -qE '^[A-Za-z0-9._-]+$'; }
body_has_leak() { printf '%s\n' "$1" | grep '^PSK=' | grep -qv redacted; }

# ===========================================================================
# SYNC — снять реестр с хаба, обновить публичную копию. Dry-run по умолчанию.
# ===========================================================================
cmd_sync() {
  local do_write=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --write)   do_write=1 ;;
      --dry-run) do_write=0 ;;
      -h|--help) echo "usage: verify-registry.sh sync [--write]"; return 0 ;;
      *) die "sync: неизвестный аргумент $1" ;;
    esac
    shift
  done

  [ -d "$REG_DIR" ] || die "нет каталога $REG_DIR"
  command -v openssl >/dev/null 2>&1 || die "нужен openssl для base64-декода"
  command -v git >/dev/null 2>&1 || die "нужен git"

  if [ "$do_write" -eq 1 ]; then
    if [ -n "$(git -C "$REPO_DIR" status --porcelain -- registry/hub-peers/ 2>/dev/null)" ]; then
      die "рабочее дерево registry/hub-peers/ грязное — закоммить/откати вручную, потом sync --write"
    fi
  fi

  local hub_out rc
  if hub_out=$(ssh -o BatchMode=yes "$HUB" "$SYNC_REMOTE" 2>/tmp/vr_hub_err); then
    :
  else
    rc=$?
    sed 's/^/  hub: /' /tmp/vr_hub_err >&2 || true
    rm -f /tmp/vr_hub_err
    if [ "$rc" -ge 3 ] && [ "$rc" -le 5 ]; then exit "$rc"; fi
    die "удалённый снимок не удался (ssh), rc=$rc"
  fi
  rm -f /tmp/vr_hub_err

  echo "hub : $HUB"
  echo "repo: $REPO_DIR"
  echo "режим: $([ "$do_write" -eq 1 ] && echo 'ЗАПИСЬ (--write)' || echo 'DRY-RUN (запись отключена)')"
  echo

  local tmpdir; tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' RETURN

  local seen="$tmpdir/seen"; : > "$seen"
  local changes=0 name b64 content target action tag
  local -a plan_names=() plan_actions=()

  while read -r tag name b64; do
    [ "$tag" = "PEER" ] || continue
    valid_name "$name" || die "sync: небезопасное имя пира '$name' — стоп"
    content=$(b64decode "$b64") || die "sync: base64-декод не удался для $name"
    if body_has_leak "$content"; then
      echo "verify-registry: ABORT — leak PSK в снимке пира $name (маска сломана)" >&2
      exit 4
    fi
    echo "$name" >> "$seen"
    printf '%s\n' "$content" > "$tmpdir/$name.new"

    target="$REG_DIR/$name.peer.pub"
    if [ ! -f "$target" ]; then
      action="CREATE"; changes=1
    elif ! cmp -s "$tmpdir/$name.new" "$target"; then
      action="UPDATE"; changes=1
    else
      action="SAME"
    fi
    plan_names+=("$name"); plan_actions+=("$action")
  done <<< "$hub_out"

  shopt -s nullglob
  local orphans=0 f gname
  for f in "$REG_DIR"/*.peer.pub; do
    gname=$(basename "$f" .peer.pub)
    if ! grep -qxF "$gname" "$seen"; then
      plan_names+=("$gname"); plan_actions+=("ORPHAN"); orphans=1
    fi
  done
  shopt -u nullglob

  printf '%-14s %s\n' "PEER" "ДЕЙСТВИЕ"
  printf '%-14s %s\n' "----" "--------"
  local i
  for i in "${!plan_names[@]}"; do
    printf '%-14s %s\n' "${plan_names[$i]}" "${plan_actions[$i]}"
  done
  echo

  for i in "${!plan_names[@]}"; do
    case "${plan_actions[$i]}" in
      CREATE|UPDATE)
        name="${plan_names[$i]}"
        echo "--- diff ($name, ${plan_actions[$i]}) ---"
        if [ -f "$REG_DIR/$name.peer.pub" ]; then
          diff -u "$REG_DIR/$name.peer.pub" "$tmpdir/$name.new" || true
        else
          diff -u /dev/null "$tmpdir/$name.new" || true
        fi
        echo ;;
    esac
  done

  if [ "$do_write" -eq 1 ] && [ "$changes" -eq 1 ]; then
    for i in "${!plan_names[@]}"; do
      case "${plan_actions[$i]}" in
        CREATE|UPDATE)
          name="${plan_names[$i]}"
          cp "$tmpdir/$name.new" "$REG_DIR/$name.peer.pub" ;;
      esac
    done
    if [ "$(grep -h '^PSK=' "$REG_DIR"/*.peer.pub | grep -vc redacted)" != "0" ]; then
      echo "verify-registry: ABORT — leak PSK в записанных файлах; откатываю" >&2
      git -C "$REPO_DIR" checkout -- registry/hub-peers/ 2>/dev/null || true
      git -C "$REPO_DIR" clean -fq -- registry/hub-peers/ 2>/dev/null || true
      exit 4
    fi
    echo "ЗАПИСАНО в registry/hub-peers/. Коммит НЕ делаю — ниже git diff, коммить/пушь руками."
    echo
    echo "=== git diff -- registry/hub-peers/ ==="
    git -C "$REPO_DIR" --no-pager diff -- registry/hub-peers/ || true
    echo
    echo "=== git status ==="
    git -C "$REPO_DIR" --no-pager status --short -- registry/hub-peers/ || true
  fi

  echo
  if [ "$changes" -eq 0 ] && [ "$orphans" -eq 0 ]; then
    echo "РЕЗУЛЬТАТ: публичная копия уже в синхроне с хабом — делать нечего."
    return 0
  fi
  [ "$orphans" -eq 1 ] && echo "ВНИМАНИЕ: есть ORPHAN-пиры (в git есть, на хабе нет). НЕ удаляю — реши вручную."
  if [ "$do_write" -eq 1 ]; then
    echo "РЕЗУЛЬТАТ: изменения записаны в дерево. СЛЕДУЮЩИЙ ШАГ — git-ворота: diff глазами → add → commit → push (руками)."
  else
    echo "РЕЗУЛЬТАТ: это DRY-RUN. Изменения НЕ записаны. Повтори с 'sync --write', когда согласуешь план."
  fi
  return 1
}

# ===========================================================================
# Ранний диспетчер: sync/help уходят в свои ветки, иначе — оригинальный verify
# ===========================================================================
case "${1:-verify}" in
  sync)          shift; cmd_sync "$@"; exit $? ;;
  -h|--help|help)
    cat <<'USAGE'
usage:
  verify-registry.sh [verify]      read-only сверка реестра (git <-> хаб)
  verify-registry.sh sync          DRY-RUN: показать, что изменилось бы
  verify-registry.sh sync --write  записать в дерево и СТОП перед коммитом
env:
  AWG_HUB_SSH=root@host   переопределить адрес хаба (по умолч. root@138.16.178.138)
USAGE
    exit 0 ;;
  verify) : ;;   # fall through to verify body
  *) die "неизвестная команда: ${1} (verify|sync)" ;;
esac

# =========================== VERIFY (тело v26, байт-в-байт) =================
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
