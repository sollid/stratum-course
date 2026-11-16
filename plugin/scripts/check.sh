#!/bin/sh
# Программа проверки для Mac и Windows с Git Bash. Нужны только sh и awk (есть на любом Mac). Тот же вывод, что у check.ps1 (формат правил — RULES.md).
# Ограничение формата правил: каждое правило на одной строке, двоеточие сразу после ключа, значения без кавычек и обратной косой черты (так их читает awk без jq).
# Правила — только данные. Проверяются до использования: идентификатор правила ^[A-Za-z0-9_-]{1,40}$, тип, on_fail и поля каждого типа,
# поля file и path — простой относительный путь внутри учебной папки (без .., абсолютных путей, диска, ~, ссылок; файл не больше 1 МиБ).
# Значение из правил никогда не исполняется и не становится регулярным выражением: текст сравнивается как литеральная строка.
# awk запускается с LC_ALL=C: строки читаются как байты, регистр букв (латиница, кириллица) сводится собственной таблицей, а не локалью.
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
name_ok() {
  case "$1" in
    ''|/*|'~'*|.|..|./*|../*|*/.|*/..|*/./*|*/../*|*//*) return 1 ;;
    *\\*|*:*|*'*'*|*'?'*|*'"'*|*'<'*|*'>'*|*'|'*|*'$'*|*'`'*|*'~'*) return 1 ;;
  esac
  [ "$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177')" = "$1" ]
}
name_ok "$fname" || bad_name

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

# Правила file_absent (путь path или, если его нет, file) и file_exists с полем path: сущность на диске проверяет оболочка,
# а awk получает по одному знаку на такое правило в порядке правил (1 — есть, 0 — нет). Ссылки на пути отвергаются (для file_absent — кроме самого последнего звена)
absent=""
tab=$(printf '\t')
absent_paths=$(awk -v fname="$fname" '
  { sub(/\r$/, "") }
  /"type": *"(file_absent|file_exists)"/ {
    p = ""
    if (match($0, /"path": *"[^"]*"/)) { p = substr($0, RSTART, RLENGTH); sub(/^"path": *"/, "", p); sub(/"$/, "", p) }
    isabs = ($0 ~ /"type": *"file_absent"/)
    if (p == "") { if (!isabs) next; p = fname }
    print (isabs ? "A" : "E") "\t" p
  }' "$rules")
if [ -n "$absent_paths" ]; then
  set -f
  _oldifs=$IFS
  IFS='
'
  for _line in $absent_paths; do
    IFS=$_oldifs
    _kind=${_line%%"$tab"*}; _ap=${_line#*"$tab"}
    name_ok "$_ap" || bad_name
    _p="$dir"; _rest="$_ap"
    while :; do
      _comp=${_rest%%/*}
      _p="$_p/$_comp"
      case "$_rest" in
        */*) [ -L "$_p" ] && { echo "error: symbolic link in file path" >&2; exit 2; }; _rest=${_rest#*/} ;;
        *) break ;;
      esac
    done
    if [ "$_kind" = A ]; then
      if [ -e "$_p" ] || [ -L "$_p" ]; then absent="${absent}1"; else absent="${absent}0"; fi
    else
      [ -L "$_p" ] && { echo "error: symbolic link in file path" >&2; exit 2; }
      if [ -f "$_p" ]; then absent="${absent}1"; else absent="${absent}0"; fi
    fi
    IFS='
'
  done
  IFS=$_oldifs
  set +f
fi

LC_ALL=C awk -v hasfile="$hasfile" -v absent="$absent" '
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
function jhasnum(line, key) { return match(line, "\"" key "\": *[0-9]+") > 0 }
function replace(s, from, to,   out, p) {
  out = ""
  while ((p = index(s, from)) > 0) { out = out substr(s, 1, p - 1) to; s = substr(s, p + length(from)) }
  return out s
}
function die(msg) { print "error: " msg > "/dev/stderr"; failed = 1; exit 2 }
function sev(v) { return v == "almost" ? 1 : v == "disputed" ? 2 : v == "failed" ? 3 : 0 }
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

# Регистр: латиница (tolower в локали C) и кириллица (А-Я, Ё, Є, І, Ї, Ґ) по таблице байтов UTF-8 — одинаково во всех awk
function fold(s) {
  s = tolower(s)
  gsub("\320\220", "\320\260", s); gsub("\320\221", "\320\261", s); gsub("\320\222", "\320\262", s); gsub("\320\223", "\320\263", s)
  gsub("\320\224", "\320\264", s); gsub("\320\225", "\320\265", s); gsub("\320\226", "\320\266", s); gsub("\320\227", "\320\267", s)
  gsub("\320\230", "\320\270", s); gsub("\320\231", "\320\271", s); gsub("\320\232", "\320\272", s); gsub("\320\233", "\320\273", s)
  gsub("\320\234", "\320\274", s); gsub("\320\235", "\320\275", s); gsub("\320\236", "\320\276", s); gsub("\320\237", "\320\277", s)
  gsub("\320\240", "\321\200", s); gsub("\320\241", "\321\201", s); gsub("\320\242", "\321\202", s); gsub("\320\243", "\321\203", s)
  gsub("\320\244", "\321\204", s); gsub("\320\245", "\321\205", s); gsub("\320\246", "\321\206", s); gsub("\320\247", "\321\207", s)
  gsub("\320\250", "\321\210", s); gsub("\320\251", "\321\211", s); gsub("\320\252", "\321\212", s); gsub("\320\253", "\321\213", s)
  gsub("\320\254", "\321\214", s); gsub("\320\255", "\321\215", s); gsub("\320\256", "\321\216", s); gsub("\320\257", "\321\217", s)
  gsub("\320\201", "\321\221", s); gsub("\320\204", "\321\224", s); gsub("\320\206", "\321\226", s); gsub("\320\207", "\321\227", s)
  gsub("\322\220", "\322\221", s)
  return s
}
# Название раздела или метки для сравнения: без выделения, без номера в начале, без двоеточий и точек в конце, с одним пробелом, без регистра
function norm(s) {
  gsub(/[*_]/, "", s)
  s = trim(s)
  if (match(s, /^[0-9][0-9]?[0-9]?[.)][ \t]+/)) s = substr(s, RLENGTH + 1)
  while (s ~ /[:. \t]$/) sub(/[:. \t]$/, "", s)
  gsub(/[ \t]+/, " ", s)
  return fold(s)
}
# Значение после метки: без выделения, без точки и пробелов в конце, с одним пробелом, без регистра
function normv(s) {
  gsub(/[*_]/, "", s)
  s = trim(s)
  gsub(/[ \t]+/, " ", s)
  return fold(s)
}
# Значение допустимо, если оно равно разрешённому слову или начинается с него, а дальше (после пробелов) идёт конец строки или один из знаков
# , - . : ; ! ( [ – — и любой комментарий
function value_matches(v, a,   rest, c) {
  if (a == "" || substr(v, 1, length(a)) != a) return 0
  rest = substr(v, length(a) + 1)
  sub(/^[ \t]+/, "", rest)
  if (rest == "") return 1
  c = substr(rest, 1, 1)
  if (index(",-.:;!([", c) > 0) return 1
  c = substr(rest, 1, 3)
  return (c == "\342\200\223" || c == "\342\200\224")
}
BEGIN {
  n = split("a abbr b blockquote br caption center code col dd del details dfn div dl dt em figcaption figure font h1 h2 h3 h4 h5 h6 hr i img ins kbd li mark ol p pre q s samp small span strike strong sub summary sup table tbody td tfoot th thead tr tt u ul var", tg, " ")
  for (k = 1; k <= n; k++) tags[tg[k]] = 1
}
# Заготовка: текст между < и > на одной строке, 1–80 знаков, с буквой (латиница или кириллица), не начинается и не кончается пробелом, «-» или «=»,
# не HTML-тег из списка, не адрес со схемой, mailto: или почта
function is_placeholder(inner,   low, s, nm, rest) {
  if (inner == "" || clen(inner) > 80) return 0
  if (inner ~ /^[ \t=-]/ || inner ~ /[ \t=-]$/) return 0
  if (inner !~ /[A-Za-z]/ && inner !~ "[\320-\323]") return 0
  low = tolower(inner); s = low
  sub(/^\//, "", s)
  if (match(s, /^[a-z][a-z0-9]*/)) {
    nm = substr(s, 1, RLENGTH); rest = substr(s, RLENGTH + 1)
    if ((nm in tags) && (rest == "" || substr(rest, 1, 1) ~ /[ \t\/]/)) return 0
  }
  if (inner ~ /^[A-Za-z][A-Za-z0-9+.-]*:\/\// || substr(low, 1, 7) == "mailto:" || inner ~ /^[^ \t@]+@[^ \t@]+$/) return 0
  return 1
}
function indent_of(l,   n, i, c) {
  n = 0
  for (i = 1; i <= length(l); i++) { c = substr(l, i, 1); if (c == " ") n++; else if (c == "\t") n += 4; else break }
  ipos = i
  return n
}
# Вид строки: h — заголовок, b — пункт списка, l — метка раздела, t — прочее. Для h и l — nm (название для сравнения), для h ещё lvl; ind — отступ
function classify(i,   l, rest, n, m, u, ut, name, p, head, content) {
  l = lines[i]
  ind[i] = indent_of(l)
  rest = substr(l, ipos)
  kind[i] = "t"
  if (match(l, /^#+/)) {
    n = RLENGTH
    if (n <= 6) {
      m = substr(l, n + 1)
      if (match(m, /^[ \t]+[^ \t]/)) { sub(/^[ \t]+/, "", m); sub(/[ \t]+#+[ \t]*$/, "", m); kind[i] = "h"; lvl[i] = n; nm[i] = norm(m); return }
    }
  }
  if (match(rest, /^([-*+]|[0-9][0-9]?[0-9]?[.)])[ \t]+/)) {
    content = substr(rest, RLENGTH + 1)
    if (content ~ /[^-*_ \t]/) { kind[i] = "b"; return }
  }
  if (ind[i] == 0 && l != "") {
    u = l; gsub(/[*_]/, "", u)
    ut = trim(u)
    name = ""
    if (ut ~ /:$/) name = norm(ut)
    else if (l ~ /^(\*\*|__|\*|_)[^*_]+(\*\*|__|\*|_)[ \t]*$/) name = norm(l)
    else {
      p = index(u, ":")
      if (p > 1) { head = norm(substr(u, 1, p - 1)); if (head in known) name = head }
    }
    if (name != "") { kind[i] = "l"; nm[i] = name }
  }
}
function has_section(name,   w, i) {
  w = norm(name)
  for (i = 1; i <= nl; i++) if ((kind[i] == "h" || kind[i] == "l") && nm[i] == w) return 1
  return 0
}
# Пункты по разделам в строках start..last; вложенные пункты и пустые не считаются
function section_counts(start, last,   i, k, cur, havecur, inlist, base, counted) {
  split("", counts)
  cur = ""; havecur = 0; inlist = 0; base = 0
  for (i = start; i <= last; i++) {
    k = kind[i]
    if (k == "h" || k == "l") { cur = nm[i]; havecur = 1; inlist = 0; continue }
    if (k == "b") {
      counted = 0
      if (!inlist) { if (ind[i] <= 3) { counted = 1; base = ind[i]; inlist = 1 } }
      else if (ind[i] <= base) { counted = 1; base = ind[i] }
      if (counted && havecur) counts[cur]++
      continue
    }
    if (lines[i] != "" && ind[i] == 0) inlist = 0
  }
}
function prepare(s, mode) {
  if (mode ~ /nocase/) s = fold(s)
  if (mode ~ /nospace/) gsub(/[ \t\r\n]/, "", s)
  return s
}
function contains_text(i,   mode, needle) {
  mode = rmatch[i]
  needle = prepare(rtext[i], mode)
  if (needle == "") die("bad rule fields")
  if (!(mode in hayd)) { hay[mode] = prepare(text, mode); hayd[mode] = 1 }
  return index(hay[mode], needle) > 0
}
function strip_comments(s,   out, a, b, seg) {
  out = ""
  while ((a = index(s, "<!--")) > 0) {
    out = out substr(s, 1, a - 1)
    s = substr(s, a + 4)
    b = index(s, "-->")
    if (b > 0) { seg = substr(s, 1, b - 1); s = substr(s, b + 3) } else { seg = s; s = "" }
    gsub(/[^\n]/, "", seg)
    out = out seg
  }
  return out s
}
function clen(s,   t, k) { t = s; k = gsub("[\200-\277]", "", t); return length(s) - k }
function count_placeholders(   stripped, arr, nn, q, L, pos, a, i, rest, j1, j2, inner, low, cnt) {
  stripped = strip_comments(text)
  nn = split(stripped, arr, "\n")
  cnt = 0
  for (q = 1; q <= nn; q++) {
    L = arr[q]
    pos = 1
    while (1) {
      a = index(substr(L, pos), "<")
      if (a == 0) break
      i = pos + a - 1
      rest = substr(L, i + 1)
      j1 = index(rest, ">"); j2 = index(rest, "<")
      if (j1 == 0 && j2 == 0) break
      if (j2 > 0 && (j1 == 0 || j2 < j1)) { pos = i + j2; continue }
      inner = substr(rest, 1, j1 - 1)
      if (is_placeholder(inner)) { cnt++; pos = i + 1 + j1 }
      else pos = i + 1
    }
  }
  return cnt
}
function answer_ok(i,   q, s, u, p, v, k, want, found, good) {
  want = rlabeln[i]; found = 0
  for (q = 1; q <= nl; q++) {
    s = lines[q]
    sub(/^[ \t]*([-*+]|[0-9][0-9]?[0-9]?[.)])[ \t]+/, "", s)
    u = s; gsub(/[*_]/, "", u)
    p = index(u, ":")
    if (p > 1 && norm(substr(u, 1, p - 1)) == want) {
      v = normv(substr(u, p + 1))
      if (v == "") return 0
      good = 0
      for (k = 1; k <= rna[i]; k++) if (value_matches(v, normv(rans[i, k]))) good = 1
      if (!good) return 0
      found++
    }
  }
  return found > 0
}
FNR == 1 { sub("^\357\273\277", "") }
{ sub(/\r$/, "") }
NR == FNR {
  if ($0 ~ /"type":/) {
    nr++
    rid[nr] = jstr($0, "id"); rtype[nr] = jstr($0, "type"); rfail_v[nr] = jstr($0, "on_fail")
    rok[nr] = jstr($0, "ok"); rfail[nr] = jstr($0, "fail"); rhead[nr] = jstr($0, "heading")
    if (rid[nr] !~ /^[A-Za-z0-9_-]+$/ || length(rid[nr]) > 40) die("bad rule id")
    if (rtype[nr] !~ /^(file_exists|file_absent|has_heading|lists_named|max_items|min_items|min_lines|forbidden_text|contains_text|no_placeholder|answer)$/) die("unknown rule type (rules newer than this plugin: update the plugin)")
    if (rfail_v[nr] !~ /^(almost|disputed|failed)$/) die("bad on_fail value")
    rtext[nr] = jstr($0, "text"); rlist[nr] = jstr($0, "list"); rmax[nr] = jnum($0, "max"); rmin[nr] = jnum($0, "min")
    rlabel[nr] = jstr($0, "label"); rpathv[nr] = jstr($0, "path")
    rmatch[nr] = "exact"
    if ((rtype[nr] == "contains_text" || rtype[nr] == "forbidden_text") && index($0, "\"match\"") > 0) { rmatch[nr] = jstr($0, "match"); if (rmatch[nr] !~ /^(exact|nocase|nospace|nocase_nospace)$/) die("bad rule fields") }
    rnn[nr] = 0; rna[nr] = 0
    if (match($0, /"names": *\[( *"[^"]*" *,?)* *\]/)) {
      s = substr($0, RSTART, RLENGTH); rnn[nr] = split(s, parts, "\"")
      k = 0
      for (j = 4; j <= rnn[nr]; j += 2) { rnames[nr, ++k] = parts[j]; if (parts[j] == "") die("bad rule fields") }
      rnn[nr] = k
    }
    if (match($0, /"answers": *\[( *"[^"]*" *,?)* *\]/)) {
      s = substr($0, RSTART, RLENGTH); rna[nr] = split(s, parts, "\"")
      k = 0
      for (j = 4; j <= rna[nr]; j += 2) { rans[nr, ++k] = parts[j]; if (parts[j] == "") die("bad rule fields") }
      rna[nr] = k
    }
    t = rtype[nr]
    if (t == "has_heading" && rhead[nr] == "") die("bad rule fields")
    rscope[nr] = jstr($0, "scope")
    if (index($0, "\"scope\"") > 0 && rscope[nr] != "none" && rscope[nr] != "block") die("bad rule fields")
    if (t == "lists_named" && rnn[nr] == 0) die("bad rule fields")
    if (t == "max_items" && (rlist[nr] == "" || !jhasnum($0, "max"))) die("bad rule fields")
    if (t == "min_items" && (rlist[nr] == "" || !jhasnum($0, "min"))) die("bad rule fields")
    if (t == "min_lines" && !jhasnum($0, "min")) die("bad rule fields")
    if ((t == "forbidden_text" || t == "contains_text") && rtext[nr] == "") die("bad rule fields")
    if (t == "answer") {
      hasone = (index($0, "\"expect\"") > 0); haslist = (index($0, "\"answers\"") > 0)
      if (hasone == haslist) die("bad rule fields")
      if (hasone) { if (jstr($0, "expect") == "") die("bad rule fields"); rna[nr] = 1; rans[nr, 1] = jstr($0, "expect") }
      if (rlabel[nr] == "" || rna[nr] == 0) die("bad rule fields")
    }
    if ((t == "contains_text" || t == "forbidden_text") && index($0, "\"loose\"") > 0) {
      if (index($0, "\"match\"") > 0) die("bad rule fields")
      if (match($0, /"loose": *true/)) rmatch[nr] = "nocase_nospace"
      else if (!match($0, /"loose": *false/)) die("bad rule fields")
    }
    if ((t == "file_absent" || t == "file_exists") && index($0, "\"path\"") > 0 && jstr($0, "path") == "") die("bad rule fields")
    if (t == "forbidden_text" || t == "contains_text" || t == "no_placeholder") needtext = 1
    if (rhead[nr] != "") { x = norm(rhead[nr]); if (x != "") known[x] = 1 }
    if (rlist[nr] != "") { x = norm(rlist[nr]); if (x != "") known[x] = 1 }
    if (t == "lists_named") for (k = 1; k <= rnn[nr]; k++) { x = norm(rnames[nr, k]); if (x != "") known[x] = 1 }
    if (t == "answer") rlabeln[nr] = norm(rlabel[nr])
  } else if ($0 ~ /"skipped":/) skipped = jstr($0, "skipped")
  else if ($0 ~ /"engine":/) { if (!jhasnum($0, "engine")) die("bad engine level"); engine = jnum($0, "engine"); engine_set = 1 }
  next
}
{ lines[++nl] = $0; if (needtext) text = text $0 "\n" }
END {
  if (failed) exit 2
  if (engine_set) {
    if (engine < 1) die("bad engine level")
    if (engine > 2) die("rules newer than this plugin: update the plugin (rules need engine level " engine ", this one is 2)")
  }
  if (nr == 0) die("rules file is not valid JSON")
  for (i = 1; i <= nl; i++) classify(i)
  # Область подсчёта: блок первого правила has_heading, если его заголовок найден; иначе весь файл
  sstart = 1; send = nl
  for (i = 1; i <= nr; i++) if (rtype[i] == "has_heading" && rscope[i] != "none") {
    w = norm(rhead[i]); hidx = 0
    for (q = 1; q <= nl; q++) if (kind[q] == "h" && nm[q] == w) { hidx = q; break }
    if (hidx > 0) {
      level = lvl[hidx]; sstart = hidx + 1
      for (q = sstart; q <= nl; q++) if (kind[q] == "h" && lvl[q] <= level) { send = q - 1; break }
    }
    break
  }
  section_counts(sstart, send)
  worst = 0; outn = 0; abk = 0
  for (i = 1; i <= nr; i++) {
    t = rtype[i]
    rpath = ""
    if (t == "file_exists" || t == "file_absent") rpath = rpathv[i]
    fsk = (t == "file_absent" || (t == "file_exists" && rpath != ""))
    if (fsk) abk++
    if (!hasfile && t != "file_exists" && t != "file_absent") { out[++outn] = rid[i] ": skipped - " skipped; continue }
    ok = 0; missing = ""; vn = ""; vmax = ""; vmin = ""
    if (t == "file_exists") ok = (rpath != "") ? (substr(absent, abk, 1) == "1") : hasfile
    else if (t == "file_absent") ok = (substr(absent, abk, 1) == "0")
    else if (t == "has_heading") ok = has_section(rhead[i])
    else if (t == "lists_named") {
      for (j = 1; j <= rnn[i]; j++) if (counts[norm(rnames[i, j])] + 0 == 0) missing = (missing == "" ? "" : missing ", ") rnames[i, j]
      ok = (missing == "")
    } else if (t == "max_items") { vn = counts[norm(rlist[i])] + 0; vmax = rmax[i]; ok = (vn <= rmax[i]) }
    else if (t == "min_items") { vn = counts[norm(rlist[i])] + 0; vmin = rmin[i]; ok = (vn >= rmin[i]) }
    else if (t == "min_lines") {
      vn = 0
      for (j = 1; j <= nl; j++) if (lines[j] ~ /[^ \t]/) vn++
      vmin = rmin[i]; ok = (vn >= rmin[i])
    }
    else if (t == "forbidden_text") ok = !contains_text(i)
    else if (t == "contains_text") ok = contains_text(i)
    else if (t == "no_placeholder") { vn = count_placeholders(); ok = (vn == 0) }
    else if (t == "answer") ok = answer_ok(i)
    else die("unknown rule type: " t)
    if (ok) { status = "ok"; msg = rok[i] }
    else { status = rfail_v[i]; msg = rfail[i]; if (sev(status) > worst) worst = sev(status) }
    msg = replace(msg, "{missing}", missing); msg = replace(msg, "{n}", vn); msg = replace(msg, "{max}", vmax); msg = replace(msg, "{min}", vmin)
    out[++outn] = rid[i] ": " status " - " msg
  }
  v = worst == 0 ? "accepted" : worst == 1 ? "almost" : worst == 2 ? "disputed" : "failed"
  printf "verdict: %s\n", v
  for (i = 1; i <= outn; i++) printf "%s\n", out[i]
}' "$rules" "$target"
