#!/bin/sh
# Программа проверки для Mac и Windows с Git Bash. Нужны только sh и awk (есть на любом Mac).
# Ограничение формата правил: каждое правило на одной строке, значения без кавычек внутри (так их читает awk без jq).
# Правила — только данные. Проверяются до использования: идентификатор правила ^[A-Za-z0-9_-]{1,40}$, тип и on_fail из короткого списка,
# поле file — простой относительный путь внутри учебной папки (без .., абсолютных путей, диска, ~, ссылок; файл не больше 1 МиБ).
# Использование: sh check.sh --rules <rules.json> --dir <папка ученика>
# Коды выхода: 0 проверка отработала (вердикт в выводе); 2 неверный вызов или недопустимые правила.

rules=""
dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rules) rules="$2"; shift 2 ;;
    --dir) dir="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -z "$rules" ] || [ -z "$dir" ]; then echo "error: usage: --rules <rules.json> --dir <folder>" >&2; exit 2; fi
if [ ! -f "$rules" ]; then echo "error: rules file not found" >&2; exit 2; fi

fname=$(awk '
  { sub(/\r$/, "") }
  !/"type":/ && match($0, /"file": *"[^"]*"/) {
    s = substr($0, RSTART, RLENGTH); sub(/^"[^"]*": */, "", s); print substr(s, 2, length(s) - 2); exit
  }' "$rules")
if [ -z "$fname" ]; then echo "error: rules file is not valid JSON" >&2; exit 2; fi

# Имя файла из правил: простой относительный путь внутри учебной папки
bad_name() { echo "error: bad file name in rules" >&2; exit 2; }
case "$fname" in
  /*|'~'*|.|..|./*|../*|*/.|*/..|*/./*|*/../*|*//*) bad_name ;;
  *\\*|*:*|*'*'*|*'?'*|*'"'*|*'<'*|*'>'*|*'|'*|*'$'*|*'`'*|*'~'*) bad_name ;;
esac
[ "$(printf '%s' "$fname" | LC_ALL=C tr -d '\000-\037\177')" = "$fname" ] || bad_name

target="$dir/$fname"
hasfile=1
if [ ! -f "$target" ]; then
  hasfile=0; target=/dev/null
else
  # Ни сам файл, ни папки на пути к нему не должны быть символическими ссылками (иначе чтение вышло бы за учебную папку)
  _p="$dir"; _rest="$fname"
  while :; do
    _comp=${_rest%%/*}
    _p="$_p/$_comp"
    [ -L "$_p" ] && { echo "error: symbolic link in file path" >&2; exit 2; }
    case "$_rest" in */*) _rest=${_rest#*/} ;; *) break ;; esac
  done
  _size=$(wc -c < "$target" | tr -d ' ')
  if [ "${_size:-0}" -gt 1048576 ]; then echo "error: file is larger than 1 MiB" >&2; exit 2; fi
fi


awk -v hasfile="$hasfile" '
function jstr(line, key,   s) {
  if (!match(line, "\"" key "\": *\"[^\"]*\"")) return ""
  s = substr(line, RSTART, RLENGTH); sub(/^"[^"]*": */, "", s)
  return substr(s, 2, length(s) - 2)
}
function jnum(line, key,   s) {
  if (!match(line, "\"" key "\": *[0-9]+")) return 0
  s = substr(line, RSTART, RLENGTH); sub(/^"[^"]*": */, "", s)
  return s + 0
}
function replace(s, from, to,   out, p) {
  out = ""
  while ((p = index(s, from)) > 0) { out = out substr(s, 1, p - 1) to; s = substr(s, p + length(from)) }
  return out s
}
function die(msg) { print "error: " msg > "/dev/stderr"; failed = 1; exit 2 }
function sev(v) { return v == "almost" ? 1 : v == "disputed" ? 2 : v == "failed" ? 3 : 0 }
# Разбор строки файла ученика: kind = h (заголовок), l (имя списка), b (пункт), "" (прочее); lvl, txt
function classify(l,   n, rest) {
  kind = ""; lvl = 0; txt = ""
  if (match(l, /^#+/)) {
    n = RLENGTH; rest = substr(l, n + 1)
    if (n <= 6 && match(rest, /^[ \t]+[^ \t]/)) {
      sub(/^[ \t]+/, "", rest); sub(/[ \t]+$/, "", rest)
      kind = "h"; lvl = n; txt = rest; return
    }
  }
  if (match(l, /^\*\*.+\*\*[ \t]*$/)) { rest = l; sub(/[ \t]+$/, "", rest); kind = "l"; txt = substr(rest, 3, length(rest) - 4); return }
  if (match(l, /^[^-*# \t].*:[ \t]*$/)) { rest = l; sub(/[ \t]+$/, "", rest); kind = "l"; txt = substr(rest, 1, length(rest) - 1); return }
  if (match(l, /^[ \t]*[-*][ \t]+[^ \t]/)) { kind = "b"; return }
}
function findheading(name,   i) {
  for (i = 1; i <= nl; i++) { classify(lines[i]); if (kind == "h" && txt == name) return i }
  return 0
}
FNR == 1 { sub("^\357\273\277", "") }
{ sub(/\r$/, "") }
NR == FNR {
  if ($0 ~ /"type":/) {
    nr++
    rid[nr] = jstr($0, "id"); rtype[nr] = jstr($0, "type"); rfail_v[nr] = jstr($0, "on_fail")
    rok[nr] = jstr($0, "ok"); rfail[nr] = jstr($0, "fail"); rhead[nr] = jstr($0, "heading")
    if (rid[nr] !~ /^[A-Za-z0-9_-]+$/ || length(rid[nr]) > 40) die("bad rule id")
    if (rtype[nr] !~ /^(file_exists|has_heading|lists_named|max_items|min_lines|forbidden_text)$/) die("unknown rule type")
    if (rfail_v[nr] !~ /^(almost|disputed|failed)$/) die("bad on_fail value")
    rtext[nr] = jstr($0, "text"); rlist[nr] = jstr($0, "list"); rmax[nr] = jnum($0, "max"); rmin[nr] = jnum($0, "min")
    if (match($0, /"names": *\[[^]]*\]/)) {
      s = substr($0, RSTART, RLENGTH); rnn[nr] = split(s, parts, "\"")
      k = 0
      for (j = 4; j <= rnn[nr]; j += 2) rnames[nr, ++k] = parts[j]
      rnn[nr] = k
    }
  } else if ($0 ~ /"skipped":/) skipped = jstr($0, "skipped")
  next
}
{ lines[++nl] = $0; text = text $0 "\n" }
END {
  if (failed) exit 2
  if (nr == 0) die("rules file is not valid JSON")
  scope = ""
  for (i = 1; i <= nr; i++) if (rtype[i] == "has_heading") { if (findheading(rhead[i]) > 0) scope = rhead[i]; break }
  start = 1; end = nl
  h = (scope != "") ? findheading(scope) : 0
  if (h > 0) {
    classify(lines[h]); level = lvl; start = h + 1
    for (i = start; i <= nl; i++) { classify(lines[i]); if (kind == "h" && lvl <= level) { end = i - 1; break } }
  }
  cur = ""; have = 0
  for (i = start; i <= end; i++) {
    classify(lines[i])
    if (kind == "h" || kind == "l") { cur = txt; have = 1 }
    else if (kind == "b" && have) counts[cur]++
  }
  worst = 0; outn = 0
  for (i = 1; i <= nr; i++) {
    t = rtype[i]
    if (!hasfile && t != "file_exists") { out[++outn] = rid[i] ": skipped - " skipped; continue }
    ok = 0; missing = ""; n = 0
    if (t == "file_exists") ok = hasfile
    else if (t == "has_heading") ok = (findheading(rhead[i]) > 0)
    else if (t == "lists_named") {
      for (j = 1; j <= rnn[i]; j++) if (counts[rnames[i, j]] + 0 == 0) missing = (missing == "" ? "" : missing ", ") rnames[i, j]
      ok = (missing == "")
    } else if (t == "max_items") { n = counts[rlist[i]] + 0; ok = (n <= rmax[i]) }
    else if (t == "min_lines") {
      n = 0
      for (j = 1; j <= nl; j++) if (lines[j] ~ /[^ \t]/) n++
      ok = (n >= rmin[i])
    }
    else if (t == "forbidden_text") ok = (index(text, rtext[i]) == 0)
    else die("unknown rule type: " t)
    if (ok) { status = "ok"; msg = rok[i] }
    else { status = rfail_v[i]; msg = rfail[i]; if (sev(status) > worst) worst = sev(status) }
    msg = replace(msg, "{missing}", missing); msg = replace(msg, "{n}", n); msg = replace(msg, "{max}", rmax[i]); msg = replace(msg, "{min}", rmin[i])
    out[++outn] = rid[i] ": " status " - " msg
  }
  v = worst == 0 ? "accepted" : worst == 1 ? "almost" : worst == 2 ? "disputed" : "failed"
  printf "verdict: %s\n", v
  for (i = 1; i <= outn; i++) printf "%s\n", out[i]
}' "$rules" "$target"
