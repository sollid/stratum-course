#!/bin/sh
# Самопроверка установки, Mac и Linux (sh). То же поведение и вывод, что у selfcheck.ps1 (кроме строки об оболочке).
#   selfcheck.sh [--soft]
# Проверяет: нужные системные программы, версию Claude Code, программу проверки на встроенном служебном правиле
# (selfcheck/selfcheck.json: в папке есть README.md и в нём не меньше одной непустой строки). Папки для проверки создаются во временной папке и удаляются.
# Коды выхода: 0 работает; 41 не хватает программ; 42 версия Claude Code не определена; 43 старая версия; 44 встроенная проверка отработала неверно; 45 awk считает длину не в байтах.
# --soft: всегда код 0 (для строки внутри навыка).
. "$(dirname "$0")/lib.sh"

parse_opts "$@"
MIN=2.1.287

missing=""
for t in sh awk sed curl; do
  command -v "$t" >/dev/null 2>&1 || missing="$missing${missing:+, }$t"
done
# Правило file_unchanged (модули 4 и дальше) считает sha256 одной из трёх программ (shasum есть на любом Mac, sha256sum — в Git Bash и на Linux). Без неё модули 1–3 работают, поэтому только предупреждение; отказ даст check.sh на первом file_unchanged
nosha=0
command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1 || command -v openssl >/dev/null 2>&1 || nosha=1
[ -z "$missing" ] || fail 41 selfcheck.noshell "tools=$missing"

# Разбор пакета задания считает длину строк в байтах (LC_ALL=C awk): «я» в UTF-8 — два байта. Если awk этого компьютера считает знаки, каждый пакет с кириллицей был бы отвергнут
_awklen=$(printf '\321\217\n' | LC_ALL=C awk '{ print length($0) }' 2>/dev/null)
[ "$_awklen" = 2 ] || fail 45 selfcheck.awkbytes "value=$_awklen"

cl=$(command -v claude 2>/dev/null) || cl=""
[ -n "$cl" ] || fail 42 selfcheck.noclaude
raw=$("$cl" --version 2>/dev/null | head -n 1)
ver=$(printf '%s' "$raw" | sed -En 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')
[ -n "$ver" ] || fail 42 selfcheck.noclaude
older=$(printf '%s\n%s\n' "$ver" "$MIN" | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1)
[ "$older" = "$MIN" ] || fail 43 selfcheck.oldclaude "version=$ver" "min=$MIN"

work="$TMPD/selfcheck"
mkdir -p "$work/ok" "$work/empty" || fail 44 selfcheck.enginefail
printf 'Stratum course install self-check\n' > "$work/ok/README.md" || fail 44 selfcheck.enginefail
rules="$HERE/../selfcheck/selfcheck.json"
good=$(sh "$HERE/check.sh" --rules "$rules" --dir "$work/ok" 2>/dev/null) && c1=0 || c1=$?
bad=$(sh "$HERE/check.sh" --rules "$rules" --dir "$work/empty" 2>/dev/null) && c2=0 || c2=$?
[ "$c1" = 0 ] && [ "$c2" = 0 ] || fail 44 selfcheck.enginefail
printf '%s\n' "$good" | grep -q '^verdict: accepted$' || fail 44 selfcheck.enginefail
printf '%s\n' "$bad" | grep -q '^verdict: failed$' || fail 44 selfcheck.enginefail

[ "$nosha" = 0 ] || say selfcheck.nosha
say selfcheck.ok "version=$ver" "min=$MIN" "shell=sh, awk, sed, curl"
finish 0
