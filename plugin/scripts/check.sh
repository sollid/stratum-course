#!/bin/sh
# Программа проверки для Mac и Windows с Git Bash. Нужны только sh и awk (есть на любом Mac); для правила file_unchanged ещё одна из программ sha256 (shasum, sha256sum, openssl).
# Тот же вывод, что у check.ps1 (формат правил — RULES.md, правила версии 3 — договор «Правила версии 3 (и 4)»).
# Ограничение формата правил: каждое правило на одной строке, двоеточие сразу после ключа, значения без кавычек и обратной косой черты (так их читает awk без jq).
# Правила — только данные. Проверяются до использования: идентификатор правила ^[A-Za-z0-9_-]{1,40}$, тип, on_fail и поля каждого типа,
# поля file и path — простой относительный путь внутри учебной папки (без .., абсолютных путей, диска, ~, ссылок; файл не больше 1 МиБ, с версии 3 — не больше 256 КиБ).
# Значение из правил никогда не исполняется и не становится регулярным выражением: текст сравнивается как литеральная строка; путь из правил в оболочке всегда в кавычках.
# awk запускается с LC_ALL=C: строки читаются как байты, регистр букв (латиница, кириллица) сводится собственной таблицей, а не локалью.
# Уровень движка 3: версии правил 1…3. Правила версии 4 и выше — «обновите плагин» (код 2, в сообщении «newer than this plugin»).
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

# ---------- программа awk (одна на два прохода) ----------
# Проход 1 (CHECK_PHASE=1) читает только файл правил: проверяет его целиком и печатает план для оболочки:
#   «V<tab>версия» и по строке «S<tab>путь<tab>флаг» на каждый файл ученика, который читают правила версии 3 (флаг 1 — нужен sha256).
# Проход 2 читает правила и главный файл (до версии 3) или читает файлы по плану сам (getline), когда оболочка проверила ссылки, размер и NUL.
# Устройство программы (комментариев внутри неё нет: она уходит в awk одним аргументом, а на Windows он ограничен по длине):
#  - fold, norm, normv, value_matches, is_placeholder, classify, section_counts, answer_ok — сравнение названий, разделы и пункты, как в движке уровня 2;
#  - parse3, check3, take3 — правило версии 3: разбор строки по знакам (деление по кавычкам), проверка по таблице типа (поля, значения, пути, пределы), перенос в массивы;
#  - take2 — правила версий 1 и 2, как в движке уровня 2;
#  - scan_numbers, line_has_number, number_ok — contains_number: проход по знакам каждой строки, целые в десятитысячных долях;
#  - items_of, items_ok — each_item_has: пункты по наименьшему отступу; some_ok — contains_some; filled, fields_ok — fields_filled;
#  - load_doc — документ (главный файл или файл по path): строки (CRLF и одиночный CR — LF, одна метка порядка байтов снимается), виды строк, раздел первого has_heading с тем же path;
#  - END — проверка правил целиком, план для оболочки (проход 1), вердикт и строки правил (проход 2).
# Свёртка регистра — по таблице байтов UTF-8 (fold), пробельные знаки loose — пробел, табуляция, LF, U+00A0, U+2009, U+202F (loosen).
PROG='
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
function die(msg) { printf "error: %s\n", msg | "cat 1>&2"; close("cat 1>&2"); failed = 1; exit 2 }
function sev(v) { return v == "almost" ? 1 : v == "disputed" ? 2 : v == "failed" ? 3 : 0 }
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

function fold(s) {
  s = tolower(s)
  if (s !~ "[\320\322]") return s
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
function norm(s) {
  gsub(/[*_]/, "", s)
  s = trim(s)
  if (match(s, /^[0-9][0-9]?[0-9]?[.)][ \t]+/)) s = substr(s, RLENGTH + 1)
  while (s ~ /[:. \t]$/) sub(/[:. \t]$/, "", s)
  gsub(/[ \t]+/, " ", s)
  return fold(s)
}
function normv(s) {
  gsub(/[*_]/, "", s)
  s = trim(s)
  gsub(/[ \t]+/, " ", s)
  return fold(s)
}
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
  spec["file_exists"] = "|path"; since["file_exists"] = 1
  spec["file_absent"] = "path|"; since["file_absent"] = 2
  spec["has_heading"] = "heading|"; since["has_heading"] = 1
  spec["lists_named"] = "names|"; since["lists_named"] = 1
  spec["max_items"] = "list,max|"; since["max_items"] = 1
  spec["min_items"] = "list,min|"; since["min_items"] = 2
  spec["min_lines"] = "min|"; since["min_lines"] = 1
  spec["forbidden_text"] = "text|"; since["forbidden_text"] = 1
  spec["contains_text"] = "text|loose"; since["contains_text"] = 2
  spec["no_placeholder"] = "|"; since["no_placeholder"] = 2
  spec["answer"] = "label,expect|"; since["answer"] = 2
  spec["contains_number"] = "value|tolerance,list"; since["contains_number"] = 3
  spec["contains_some"] = "texts,min|loose"; since["contains_some"] = 3
  spec["each_item_has"] = "list,any|loose"; since["each_item_has"] = 3
  spec["fields_filled"] = "labels|"; since["fields_filled"] = 3
  spec["file_unchanged"] = "path,sha256|"; since["file_unchanged"] = 3
  n = split("has_heading lists_named max_items min_items min_lines forbidden_text contains_text no_placeholder answer contains_number contains_some each_item_has fields_filled", tg, " ")
  for (k = 1; k <= n; k++) textreader[tg[k]] = 1
  dir = ENVIRON["CHECK_DIR"]
  phase = ENVIRON["CHECK_PHASE"] + 0
  ns = split(ENVIRON["CHECK_SLOTS"], slotl, "\n")
  for (k = 1; k <= ns; k++) if (slotl[k] != "") { split(slotl[k], slotp, "\t"); sstat[slotp[1]] = slotp[2]; ssha[slotp[1]] = slotp[3] }
  ver = 0; ndocs = 0
}
function skipws(s, p) { while (substr(s, p, 1) == " " || substr(s, p, 1) == "\t") p++; return p }
function parse3(nr, s,   n, p, q, c, key, cnt, w) {
  n = length(s); p = skipws(s, 1)
  if (substr(s, p, 1) != "{") return 0
  p++
  nk3[nr] = 0
  while (1) {
    p = skipws(s, p)
    if (substr(s, p, 1) != "\"") return 0
    q = index(substr(s, p + 1), "\""); if (q == 0) return 0
    key = substr(s, p + 1, q - 1); p = p + q + 1
    if (key == "" || key ~ /[^a-z0-9_]/) return 0
    if ((nr, key) in k3) return 0
    p = skipws(s, p)
    if (substr(s, p, 1) != ":") return 0
    p = skipws(s, p + 1)
    c = substr(s, p, 1)
    if (c == "\"") {
      q = index(substr(s, p + 1), "\""); if (q == 0) return 0
      f3[nr, key] = substr(s, p + 1, q - 1); k3[nr, key] = "s"; p = p + q + 1
    } else if (c == "[") {
      p = skipws(s, p + 1); cnt = 0
      if (substr(s, p, 1) == "]") return 0
      while (1) {
        if (substr(s, p, 1) != "\"") return 0
        q = index(substr(s, p + 1), "\""); if (q == 0) return 0
        li3[nr, key, ++cnt] = substr(s, p + 1, q - 1); p = skipws(s, p + q + 1)
        c = substr(s, p, 1)
        if (c == ",") { p = skipws(s, p + 1); continue }
        if (c == "]") { p++; break }
        return 0
      }
      ln3[nr, key] = cnt; k3[nr, key] = "l"; f3[nr, key] = ""
    } else if (substr(s, p, 4) == "true") { f3[nr, key] = "true"; k3[nr, key] = "b"; p += 4 }
    else if (substr(s, p, 5) == "false") { f3[nr, key] = "false"; k3[nr, key] = "b"; p += 5 }
    else {
      w = ""
      while (p <= n && index("0123456789.", substr(s, p, 1)) > 0) { w = w substr(s, p, 1); p++ }
      if (w == "") return 0
      f3[nr, key] = w; k3[nr, key] = "n"
    }
    keys3[nr, ++nk3[nr]] = key
    p = skipws(s, p); c = substr(s, p, 1)
    if (c == ",") { p++; continue }
    if (c == "}") { p++; break }
    return 0
  }
  p = skipws(s, p)
  if (substr(s, p, 1) == ",") p = skipws(s, p + 1)
  return p > n
}
function clen(s,   t, k) { t = s; k = gsub("[\200-\277]", "", t); return length(s) - k }
function loosen(s) {
  gsub(/[ \t\n]/, "", s)
  gsub("\302\240", "", s); gsub("\342\200\211", "", s); gsub("\342\200\257", "", s)
  return fold(s)
}
function strval_bad(v,   t) {
  t = v; gsub(/[ \t]/, "", t); gsub("\302\240", "", t)
  if (t == "") return 1
  if (clen(v) > 200) return 1
  if (v ~ /[\001-\037\177]/ || index(v, "\342\200\250") > 0 || index(v, "\342\200\251") > 0 || index(v, "\\") > 0) return 1
  return 0
}
function path_bad(p,   np, parts, k, seg, dev) {
  if (p == "" || length(p) > 120 || p ~ /[^A-Za-z0-9._\/-]/ || index(p, "..") > 0) return 1
  np = split(p, parts, "/")
  if (np > 4) return 1
  for (k = 1; k <= np; k++) {
    seg = parts[k]
    if (seg == "" || seg == "." || seg ~ /\.$/) return 1
    dev = seg; sub(/\..*$/, "", dev); dev = tolower(dev)
    if (dev == "con" || dev == "prn" || dev == "aux" || dev == "nul" || dev ~ /^(com|lpt)[1-9]$/) return 1
  }
  return 0
}
function intval_ok(nr, key) { return (nr, key) in k3 && k3[nr, key] == "n" && f3[nr, key] ~ /^(0|[1-9][0-9]*)$/ && length(f3[nr, key]) <= 5 }
function numval_ok(nr, key,   w, p) {
  if (!((nr, key) in k3) || k3[nr, key] != "n") return 0
  w = f3[nr, key]
  if (w !~ /^(0|[1-9][0-9]*)(\.[0-9]+)?$/) return 0
  p = index(w, ".")
  if (p == 0) return length(w) <= 9
  return (p - 1) <= 9 && (length(w) - p) <= 4
}
function check3(nr,   t, sp, rq, op, nrq, nop, rl, ol, k, key, allowed, kk, loose, j, m, a, b, seen, x) {
  t = f3[nr, "type"]
  if (!(t in spec)) return "unknown"
  if (since[t] > ver) return "bad"
  split(spec[t], sp, "|")
  nrq = split(sp[1], rl, ",")
  if (sp[1] == "") nrq = 0
  nop = split(sp[2], ol, ",")
  if (sp[2] == "") nop = 0
  for (k = 1; k <= nk3[nr]; k++) {
    key = keys3[nr, k]; allowed = 0
    if (key == "id" || key == "type" || key == "on_fail" || key == "ok" || key == "fail") allowed = 1
    for (j = 1; j <= nrq; j++) if (rl[j] == key) allowed = 1
    for (j = 1; j <= nop; j++) if (ol[j] == key) allowed = 1
    if (key == "path" && (t in textreader)) allowed = 1
    if (!allowed) return "bad"
  }
  if (!((nr, "id") in k3) || !((nr, "on_fail") in k3) || !((nr, "ok") in k3) || !((nr, "fail") in k3)) return "bad"
  for (j = 1; j <= nrq; j++) if (!((nr, rl[j]) in k3)) return "bad"
  if (k3[nr, "id"] != "s" || f3[nr, "id"] !~ /^[A-Za-z0-9_-]+$/ || length(f3[nr, "id"]) > 40) return "id"
  if (k3[nr, "on_fail"] != "s" || f3[nr, "on_fail"] !~ /^(almost|disputed|failed)$/) return "bad"
  for (j = 1; j <= 2; j++) {
    key = (j == 1 ? "ok" : "fail")
    x = f3[nr, key]
    if (k3[nr, key] != "s" || index(x, "\\") > 0) return "bad"
    gsub(/[ \t]/, "", x); gsub("\302\240", "", x)
    if (x == "") return "bad"
  }
  loose = 0
  if ((nr, "loose") in k3) { if (k3[nr, "loose"] != "b") return "bad"; loose = (f3[nr, "loose"] == "true") }
  for (k = 1; k <= nk3[nr]; k++) {
    key = keys3[nr, k]
    if (key == "id" || key == "type" || key == "on_fail" || key == "ok" || key == "fail" || key == "loose") continue
    if (key == "path") { if (k3[nr, key] != "s" || path_bad(f3[nr, key])) return "bad" }
    else if (key == "heading" || key == "list" || key == "text" || key == "label" || key == "expect" || key == "item") { if (k3[nr, key] != "s" || strval_bad(f3[nr, key])) return "bad" }
    else if (key == "names" || key == "texts" || key == "any" || key == "labels") {
      if (k3[nr, key] != "l" || ln3[nr, key] < 1 || ln3[nr, key] > 16) return "bad"
      split("", seen)
      for (m = 1; m <= ln3[nr, key]; m++) {
        x = li3[nr, key, m]
        if (strval_bad(x)) return "bad"
        if ((key == "texts" || key == "any") && loose) x = loosen(x)
        if (x in seen) return "bad"
        seen[x] = 1
      }
    }
    else if (key == "max") { if (!intval_ok(nr, key)) return "bad" }
    else if (key == "min") {
      if (!intval_ok(nr, key)) return "bad"
      if (t == "contains_some" && (f3[nr, key] + 0 < 1 || f3[nr, key] + 0 > ln3[nr, "texts"])) return "bad"
    }
    else if (key == "value" || key == "tolerance") { if (!numval_ok(nr, key)) return "bad" }
    else if (key == "sha256") { if (k3[nr, key] != "s" || f3[nr, key] !~ /^[0-9a-f]+$/ || length(f3[nr, key]) != 64) return "bad" }
    else return "bad"
  }
  return ""
}
function take3(nr,   t, j) {
  rid[nr] = f3[nr, "id"]; rtype[nr] = f3[nr, "type"]; rfail_v[nr] = f3[nr, "on_fail"]
  rok[nr] = f3[nr, "ok"]; rfail[nr] = f3[nr, "fail"]
  t = rtype[nr]
  rhead[nr] = f3[nr, "heading"]; rtext[nr] = f3[nr, "text"]; rlist[nr] = f3[nr, "list"]; rlabel[nr] = f3[nr, "label"]
  rpathv[nr] = f3[nr, "path"]
  rmax[nr] = f3[nr, "max"] + 0; rmin[nr] = f3[nr, "min"] + 0
  rmatch[nr] = "exact"
  if (f3[nr, "loose"] == "true") { rmatch[nr] = "nocase_nospace"; rloose[nr] = 1 } else rloose[nr] = 0
  rscope[nr] = ""
  rnn[nr] = ln3[nr, "names"] + 0; for (j = 1; j <= rnn[nr]; j++) rnames[nr, j] = li3[nr, "names", j]
  rna[nr] = 0
  if (t == "answer") { rna[nr] = 1; rans[nr, 1] = f3[nr, "expect"] }
  rtn[nr] = ln3[nr, "texts"] + 0; for (j = 1; j <= rtn[nr]; j++) rtexts[nr, j] = li3[nr, "texts", j]
  ran[nr] = ln3[nr, "any"] + 0; for (j = 1; j <= ran[nr]; j++) rany[nr, j] = li3[nr, "any", j]
  rlbn[nr] = ln3[nr, "labels"] + 0; for (j = 1; j <= rlbn[nr]; j++) rlabels[nr, j] = li3[nr, "labels", j]
  rvalue[nr] = f3[nr, "value"]; rtol[nr] = ((nr, "tolerance") in k3) ? f3[nr, "tolerance"] : "0"
  rsha[nr] = f3[nr, "sha256"]
}
function take2(nr, line,   t, s, parts, k, j, hasone, haslist) {
  rid[nr] = jstr(line, "id"); rtype[nr] = jstr(line, "type"); rfail_v[nr] = jstr(line, "on_fail")
  rok[nr] = jstr(line, "ok"); rfail[nr] = jstr(line, "fail"); rhead[nr] = jstr(line, "heading")
  if (rid[nr] !~ /^[A-Za-z0-9_-]+$/ || length(rid[nr]) > 40) die("bad rule id")
  if (rtype[nr] ~ /^(contains_number|contains_some|each_item_has|fields_filled|file_unchanged)$/) die("bad rule fields")
  if (rtype[nr] !~ /^(file_exists|file_absent|has_heading|lists_named|max_items|min_items|min_lines|forbidden_text|contains_text|no_placeholder|answer)$/) die("unknown rule type (rules newer than this plugin: update the plugin)")
  if (rfail_v[nr] !~ /^(almost|disputed|failed)$/) die("bad on_fail value")
  rtext[nr] = jstr(line, "text"); rlist[nr] = jstr(line, "list"); rmax[nr] = jnum(line, "max"); rmin[nr] = jnum(line, "min")
  rlabel[nr] = jstr(line, "label"); rpathv[nr] = jstr(line, "path")
  rmatch[nr] = "exact"; rloose[nr] = 0
  if ((rtype[nr] == "contains_text" || rtype[nr] == "forbidden_text") && index(line, "\"match\"") > 0) { rmatch[nr] = jstr(line, "match"); if (rmatch[nr] !~ /^(exact|nocase|nospace|nocase_nospace)$/) die("bad rule fields") }
  rnn[nr] = 0; rna[nr] = 0
  if (match(line, /"names": *\[( *"[^"]*" *,?)* *\]/)) {
    s = substr(line, RSTART, RLENGTH); rnn[nr] = split(s, parts, "\"")
    k = 0
    for (j = 4; j <= rnn[nr]; j += 2) { rnames[nr, ++k] = parts[j]; if (parts[j] == "") die("bad rule fields") }
    rnn[nr] = k
  }
  if (match(line, /"answers": *\[( *"[^"]*" *,?)* *\]/)) {
    s = substr(line, RSTART, RLENGTH); rna[nr] = split(s, parts, "\"")
    k = 0
    for (j = 4; j <= rna[nr]; j += 2) { rans[nr, ++k] = parts[j]; if (parts[j] == "") die("bad rule fields") }
    rna[nr] = k
  }
  t = rtype[nr]
  if (t == "has_heading" && rhead[nr] == "") die("bad rule fields")
  rscope[nr] = jstr(line, "scope")
  if (index(line, "\"scope\"") > 0 && rscope[nr] != "none" && rscope[nr] != "block") die("bad rule fields")
  if (t == "lists_named" && rnn[nr] == 0) die("bad rule fields")
  if (t == "max_items" && (rlist[nr] == "" || !jhasnum(line, "max"))) die("bad rule fields")
  if (t == "min_items" && (rlist[nr] == "" || !jhasnum(line, "min"))) die("bad rule fields")
  if (t == "min_lines" && !jhasnum(line, "min")) die("bad rule fields")
  if ((t == "forbidden_text" || t == "contains_text") && rtext[nr] == "") die("bad rule fields")
  if (t == "answer") {
    hasone = (index(line, "\"expect\"") > 0); haslist = (index(line, "\"answers\"") > 0)
    if (hasone == haslist) die("bad rule fields")
    if (hasone) { if (jstr(line, "expect") == "") die("bad rule fields"); rna[nr] = 1; rans[nr, 1] = jstr(line, "expect") }
    if (rlabel[nr] == "" || rna[nr] == 0) die("bad rule fields")
  }
  if ((t == "contains_text" || t == "forbidden_text") && index(line, "\"loose\"") > 0) {
    if (index(line, "\"match\"") > 0) die("bad rule fields")
    if (match(line, /"loose": *true/)) rmatch[nr] = "nocase_nospace"
    else if (!match(line, /"loose": *false/)) die("bad rule fields")
  }
  if ((t == "file_absent" || t == "file_exists") && index(line, "\"path\"") > 0 && jstr(line, "path") == "") die("bad rule fields")
}
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
function classify(i,   l, rest, n, m, u, ut, name, p, head, content) {
  l = lines[cd, i]
  ind[cd, i] = indent_of(l)
  rest = substr(l, ipos)
  kind[cd, i] = "t"
  if (match(l, /^#+/)) {
    n = RLENGTH
    if (n <= 6) {
      m = substr(l, n + 1)
      if (match(m, /^[ \t]+[^ \t]/)) { sub(/^[ \t]+/, "", m); sub(/[ \t]+#+[ \t]*$/, "", m); kind[cd, i] = "h"; lvl[cd, i] = n; nm[cd, i] = norm(m); return }
    }
  }
  if (match(rest, /^([-*+]|[0-9][0-9]?[0-9]?[.)])[ \t]+/)) {
    content = substr(rest, RLENGTH + 1)
    if (content ~ /[^-*_ \t]/) { kind[cd, i] = "b"; return }
  }
  if (ind[cd, i] == 0 && l != "") {
    u = l; gsub(/[*_]/, "", u)
    ut = trim(u)
    name = ""
    if (ver >= 3 ? (l ~ /:[ \t]*$/) : (ut ~ /:$/)) name = norm(ut)
    else if (l ~ /^(\*\*|__|\*|_)[^*_]+(\*\*|__|\*|_)[ \t]*$/) name = norm(l)
    else {
      p = index(u, ":")
      if (p > 1 && ver < 3) { head = norm(substr(u, 1, p - 1)); if (head in known) name = head }
    }
    if (name != "") { kind[cd, i] = "l"; nm[cd, i] = name }
  }
}
function has_section(name,   w, i) {
  w = norm(name)
  for (i = 1; i <= nl[cd]; i++) if ((kind[cd, i] == "h" || (kind[cd, i] == "l" && ver < 3)) && nm[cd, i] == w) return 1
  return 0
}
function section_counts(start, last,   i, k, cur, havecur, inlist, base, counted) {
  cur = ""; havecur = 0; inlist = 0; base = 0
  for (i = start; i <= last; i++) {
    k = kind[cd, i]
    if (k == "h" || k == "l") { cur = nm[cd, i]; havecur = 1; inlist = 0; continue }
    if (k == "b") {
      counted = 0
      if (ver >= 3) counted = 1
      else if (!inlist) { if (ind[cd, i] <= 3) { counted = 1; base = ind[cd, i]; inlist = 1 } }
      else if (ind[cd, i] <= base) { counted = 1; base = ind[cd, i] }
      if (counted && havecur) counts[cd, cur]++
      continue
    }
    if (lines[cd, i] != "" && ind[cd, i] == 0) inlist = 0
  }
}
function prepare(s, mode) {
  if (mode ~ /nocase/) s = fold(s)
  if (mode ~ /nospace/) gsub(/[ \t\r\n]/, "", s)
  return s
}
function contains_text(i,   mode, needle, key) {
  mode = rmatch[i]
  needle = prepare(rtext[i], mode)
  if (needle == "") die("bad rule fields")
  key = cd SUBSEP mode
  if (!(key in hayd)) { hay[key] = prepare(dtext[cd], mode); hayd[key] = 1 }
  return index(hay[key], needle) > 0
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
function count_placeholders(   stripped, arr, nn, q, L, pos, a, i, rest, j1, j2, inner, low, cnt) {
  if (ver >= 3) { cnt = 0; for (q = 1; q <= nl[cd]; q++) cnt += count_ph3(lines[cd, q]); return cnt }
  stripped = strip_comments(dtext[cd])
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
  for (q = 1; q <= nl[cd]; q++) {
    s = lines[cd, q]
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
function isdig(c) { return c != "" && index("0123456789", c) > 0 }
function sep_len(s, k,   c, t) {
  c = substr(s, k, 1)
  if (c == " ") return 1
  if (c == "\302") return (substr(s, k + 1, 1) == "\240") ? 2 : 0
  if (c == "\342") { t = substr(s, k, 3); return (t == "\342\200\211" || t == "\342\200\257") ? 3 : 0 }
  return 0
}
function letter_before(s, p,   c, pr) {
  if (p <= 1) return 0
  c = substr(s, p - 1, 1)
  if (c ~ /[A-Za-z]/) return 1
  if (p > 2 && c ~ "[\200-\277]") { pr = substr(s, p - 2, 2); return (pr ~ "^(\320[\220-\277]|\321[\200-\217]|\320[\201\204\206\207]|\321[\221\224\226\227]|\322[\220\221])$") }
  return 0
}
function letter_at(s, p,   c, pr) {
  c = substr(s, p, 1)
  if (c == "") return 0
  if (c ~ /[A-Za-z]/) return 1
  if (c ~ "[\320-\322]") { pr = substr(s, p, 2); return (pr ~ "^(\320[\220-\277]|\321[\200-\217]|\320[\201\204\206\207]|\321[\221\224\226\227]|\322[\220\221])$") }
  return 0
}
function scan_numbers(s,   n, i, j, k, m, whole, frac, c, sl, ok) {
  nn = 0; n = length(s); i = 1
  while (i <= n) {
    if (!isdig(substr(s, i, 1))) { i++; continue }
    j = i
    while (j <= n && isdig(substr(s, j, 1))) j++
    whole = substr(s, i, j - i); k = j
    if (j - i <= 3) {
      while (1) {
        sl = sep_len(s, k)
        if (sl == 0) break
        if (!(k + sl + 2 <= n && isdig(substr(s, k + sl, 1)) && isdig(substr(s, k + sl + 1, 1)) && isdig(substr(s, k + sl + 2, 1)))) break
        if (k + sl + 3 <= n && isdig(substr(s, k + sl + 3, 1))) break
        whole = whole substr(s, k + sl, 3); k = k + sl + 3
      }
    }
    frac = ""
    c = substr(s, k, 1)
    if (k + 1 <= n && (c == "." || c == ",") && isdig(substr(s, k + 1, 1))) {
      m = k + 1
      while (m <= n && isdig(substr(s, m, 1))) m++
      frac = substr(s, k + 1, m - k - 1); k = m
    }
    ok = 1
    if (letter_before(s, i)) ok = 0
    else if (i > 1 && index("0123456789-_/", substr(s, i - 1, 1)) > 0) ok = 0
    if (ok && k <= n && (letter_at(s, k) || isdig(substr(s, k, 1)))) ok = 0
    if (ok && length(whole) <= 9 && length(frac) <= 4) nv[++nn] = (whole + 0) * 10000 + (substr(frac "0000", 1, 4) + 0)
    i = k
  }
}
function decv(w,   p, whole, frac) {
  p = index(w, ".")
  if (p == 0) return (w + 0) * 10000
  whole = substr(w, 1, p - 1); frac = substr(w, p + 1)
  return (whole + 0) * 10000 + (substr(frac "0000", 1, 4) + 0)
}
function line_has_number(q, want, tol,   key, k, d) {
  key = cd SUBSEP q
  if (!(key in numdone)) {
    numdone[key] = 1; numcnt[key] = 0
    if (lines[cd, q] ~ /[0-9]/) {
      scan_numbers(lines[cd, q])
      numcnt[key] = nn
      for (k = 1; k <= nn; k++) numval[key, k] = nv[k]
    }
  }
  for (k = 1; k <= numcnt[key]; k++) { d = numval[key, k] - want; if (d < 0) d = -d; if (d <= tol) return 1 }
  return 0
}
function number_ok(i,   want, tol, q, w, cur, found) {
  want = decv(rvalue[i]); tol = decv(rtol[i])
  if (rlist[i] == "") {
    for (q = 1; q <= nl[cd]; q++) if (line_has_number(q, want, tol)) return 1
    return 0
  }
  w = norm(rlist[i]); cur = ""
  for (q = dstart[cd]; q <= dend[cd]; q++) {
    if (kind[cd, q] == "h" || kind[cd, q] == "l") { cur = nm[cd, q]; continue }
    if (cur == w && cur != "" && line_has_number(q, want, tol)) return 1
  }
  return 0
}
function marker_off(l) { sub(/^[ \t]*([-*+]|[0-9][0-9]?[0-9]?[.)])[ \t]+/, "", l); return l }
function lead_ws(l,   n) { n = 0; while (substr(l, n + 1, 1) == " " || substr(l, n + 1, 1) == "\t") n++; return n }
function items_of(name,   w, cur, bs, be, q, k, least, nb, bl, bi, e, t, x, m, ist) {
  w = norm(name); nit = 0; cur = ""; bs = 0
  for (q = dstart[cd]; q <= dend[cd] + 1; q++) {
    if (q <= dend[cd] && kind[cd, q] != "h" && kind[cd, q] != "l") { if (cur == w && cur != "" && bs == 0) bs = q; continue }
    if (bs > 0) {
      be = q - 1
      nb = 0; least = -1
      for (k = bs; k <= be; k++) if (kind[cd, k] == "b") { nb++; bl[nb] = k; bi[nb] = lead_ws(lines[cd, k]); if (least < 0 || bi[nb] < least) least = bi[nb] }
      m = 0
      for (k = 1; k <= nb; k++) if (bi[k] == least) ist[++m] = bl[k]
      for (k = 1; k <= m; k++) {
        e = (k < m) ? ist[k + 1] - 1 : be
        t = marker_off(lines[cd, ist[k]]); sub(/[ \t]+$/, "", t)
        for (x = ist[k] + 1; x <= e; x++) { t = t "\n" lines[cd, x]; }
        itm[++nit] = t
      }
    }
    bs = 0
    if (q <= dend[cd]) cur = nm[cd, q]
  }
}
function item_text_fix(t,   n, parts, k, out) {
  n = split(t, parts, "\n"); out = parts[1]
  for (k = 2; k <= n; k++) { x = parts[k]; sub(/^[ \t]+/, "", x); sub(/[ \t]+$/, "", x); out = out "\n" x }
  return out
}
function items_ok(i,   k, j, it, found, x) {
  items_of(rlist[i])
  if (nit == 0) return 0
  for (k = 1; k <= nit; k++) {
    it = item_text_fix(itm[k])
    it = rloose[i] ? loosen(it) : fold(it)
    found = 0
    for (j = 1; j <= ran[i]; j++) {
      x = rloose[i] ? loosen(rany[i, j]) : fold(rany[i, j])
      if (x == "" || index(it, x) > 0) { found = 1; break }
    }
    if (!found) return 0
  }
  return 1
}
function some_ok(i,   k, cnt, hk, nd) {
  cnt = 0
  if (rloose[i]) { hk = cd SUBSEP "loose"; if (!(hk in hayd)) { hay[hk] = loosen(dtext[cd]); hayd[hk] = 1 } }
  for (k = 1; k <= rtn[i]; k++) {
    if (rloose[i]) { nd = loosen(rtexts[i, k]); if (nd == "" || index(hay[hk], nd) > 0) cnt++ }
    else if (index(dtext[cd], rtexts[i, k]) > 0) cnt++
  }
  return cnt >= rmin[i]
}
function trim3(v,   ch) {
  ch = 1
  while (ch) {
    ch = 0
    if (sub(/^[ \t]+/, "", v)) ch = 1
    if (sub(/[ \t]+$/, "", v)) ch = 1
    if (substr(v, 1, 2) == "\302\240") { v = substr(v, 3); ch = 1 }
    if (length(v) >= 2 && substr(v, length(v) - 1, 2) == "\302\240") { v = substr(v, 1, length(v) - 2); ch = 1 }
  }
  return v
}
function has_ph3(v) { return count_ph3(v) > 0 }
function count_ph3(v,   pos, a, i, rest, j1, j2, inner, cnt) {
  pos = 1; cnt = 0
  while (1) {
    a = index(substr(v, pos), "<")
    if (a == 0) return cnt
    i = pos + a - 1
    rest = substr(v, i + 1)
    j1 = index(rest, ">"); j2 = index(rest, "<")
    if (j1 == 0) return cnt
    if (j2 > 0 && j2 < j1) { pos = i + j2; continue }
    inner = substr(rest, 1, j1 - 1)
    if (inner != "" && clen(inner) <= 200) {
      if (index(inner, "@") == 0 && index(inner, "://") == 0 && substr(inner, 1, 1) !~ /[!=\t -]/) cnt++
      pos = i + 1 + j1
    } else pos = i + 1
  }
}
function filled(v,   t) {
  gsub(/\*/, "", v)
  v = trim3(v)
  if (v == "") return 0
  t = v; gsub(/[ \t._-]/, "", t); gsub("\342\200\223", "", t); gsub("\342\200\224", "", t); gsub("\342\200\246", "", t)
  if (t == "") return 0
  if (has_ph3(v)) return 0
  return 1
}
function fields_ok(i,   k, want, q, s, p, head, found) {
  for (k = 1; k <= rlbn[i]; k++) {
    want = norm(rlabels[i, k]); found = 0
    for (q = 1; q <= nl[cd]; q++) {
      s = marker_off(lines[cd, q])
      p = index(s, ":")
      if (p > 1) {
        head = substr(s, 1, p - 1); sub(/^#[#]?[#]?[#]?[#]?[#]?[ \t]+/, "", head)
        if (norm(head) == want) { if (!filled(substr(s, p + 1))) return 0; found++ }
      }
    }
    if (found == 0) return 0
  }
  return 1
}
function load_doc(d,   full, line, first, np, parts, k, t, hr, q, hidx, level, w, p) {
  if (d in dready) return
  dready[d] = 1
  cd = d
  if (d != 0 || ver >= 3) {
    nl[d] = 0
    if (dstat[d] == "R") {
      full = dir "/" dpath[d]; first = 1
      while ((getline line < full) > 0) {
        if (first) { sub("^\357\273\277", "", line); first = 0 }
        sub(/\r$/, "", line)
        if (index(line, "\r") > 0) { np = split(line, parts, "\r"); for (k = 1; k <= np; k++) lines[d, ++nl[d]] = parts[k] }
        else lines[d, ++nl[d]] = line
      }
      close(full)
    }
  }
  t = ""
  for (q = 1; q <= nl[d]; q++) t = t lines[d, q] "\n"
  dtext[d] = t
  for (q = 1; q <= nl[d]; q++) classify(q)
  dstart[d] = 1; dend[d] = nl[d]
  hr = 0
  for (q = 1; q <= nr; q++) if (rtype[q] == "has_heading" && rscope[q] != "none" && rdoc[q] == d) { hr = q; break }
  if (hr > 0) {
    w = norm(rhead[hr]); hidx = 0
    for (q = 1; q <= nl[d]; q++) if (kind[d, q] == "h" && nm[d, q] == w) { hidx = q; break }
    if (hidx > 0) {
      level = lvl[d, hidx]; dstart[d] = hidx + 1
      for (q = dstart[d]; q <= nl[d]; q++) if (kind[d, q] == "h" && lvl[d, q] <= level) { dend[d] = q - 1; break }
    }
  }
  section_counts(dstart[d], dend[d])
}
FNR == 1 { sub("^\357\273\277", "") }
{ sub(/\r$/, "") }
NR == FNR {
  if ($0 ~ /"type":/) raw[++nr] = $0
  else if ($0 ~ /"skipped":/) skipped = jstr($0, "skipped")
  else if ($0 ~ /"engine":/) { if (!jhasnum($0, "engine")) die("bad engine level"); engine = jnum($0, "engine"); engine_set = 1 }
  else if ($0 ~ /^[ \t]*"version"[ \t]*:/) {
    v = $0; sub(/^[ \t]*"version"[ \t]*:[ \t]*/, "", v); sub(/[ \t]*,?[ \t]*$/, "", v)
    if (v !~ /^[0-9]+$/ || length(v) > 3) die("bad version")
    ver = v + 0
  } else if ($0 ~ /^[ \t]*\{[ \t]*"/) badline = 1
  next
}
{ lines[0, ++nl[0]] = $0 }
END {
  if (failed) exit 2
  if (engine_set) {
    if (engine < 1) die("bad engine level")
    if (engine > 3) die("rules newer than this plugin: update the plugin (rules need engine level " engine ", this one is 3)")
  }
  if (ver > 3) die("rules newer than this plugin: update the plugin (rules need version " ver ", this plugin knows up to 3)")
  if (nr == 0) die("rules file is not valid JSON")
  if (ver >= 3 && (nr > 40 || badline)) die("bad rule fields")
  for (i = 1; i <= nr; i++) {
    if (ver >= 3) {
      if (!parse3(i, raw[i])) die("bad rule fields")
      e = check3(i)
      if (e == "unknown") die("unknown rule type (rules newer than this plugin: update the plugin)")
      if (e == "id") die("bad rule id")
      if (e != "") die("bad rule fields")
      take3(i)
      if (rid[i] in seenid) die("bad rule id")
      seenid[rid[i]] = 1
    } else take2(i, raw[i])
    t = rtype[i]
    if (ver < 3 && (t == "contains_number" || t == "contains_some" || t == "each_item_has" || t == "fields_filled" || t == "file_unchanged")) die("bad rule fields")
    if (t == "forbidden_text" || t == "contains_text" || t == "no_placeholder") needtext = 1
    if (rhead[i] != "") { x = norm(rhead[i]); if (x != "") known[x] = 1 }
    if (rlist[i] != "" && (t == "max_items" || t == "min_items")) { x = norm(rlist[i]); if (x != "") known[x] = 1 }
    if (t == "lists_named") for (k = 1; k <= rnn[i]; k++) { x = norm(rnames[i, k]); if (x != "") known[x] = 1 }
    if (t == "answer") rlabeln[i] = norm(rlabel[i])
  }
  dpath[0] = fname; dstat[0] = sstat[fname]; ndocs = 0
  for (i = 1; i <= nr; i++) {
    rdoc[i] = 0
    if (ver >= 3 && rpathv[i] != "" && (rtype[i] in textreader)) {
      if (!(rpathv[i] in docid)) { docid[rpathv[i]] = ++ndocs; dpath[ndocs] = rpathv[i]; dstat[ndocs] = sstat[rpathv[i]] }
      rdoc[i] = docid[rpathv[i]]
    }
  }
  if (phase == 1) {
    printf "V\t%d\n", ver
    if (ver >= 3) {
      nsl = 1; sorder[1] = fname; seenp[fname] = 1
      for (i = 1; i <= nr; i++) {
        if (rpathv[i] == "") continue
        if (rtype[i] == "file_unchanged") needhash[rpathv[i]] = 1
        else if (!(rtype[i] in textreader)) continue
        if (!(rpathv[i] in seenp)) { seenp[rpathv[i]] = 1; sorder[++nsl] = rpathv[i] }
      }
      for (k = 1; k <= nsl; k++) printf "S\t%s\t%d\n", sorder[k], (sorder[k] in needhash) ? 1 : 0
    }
    exit 0
  }
  worst = 0; outn = 0; abk = 0
  for (i = 1; i <= nr; i++) {
    t = rtype[i]
    rpath = ""
    if (t == "file_exists" || t == "file_absent") rpath = rpathv[i]
    fsk = (t == "file_absent" || (t == "file_exists" && rpath != ""))
    if (fsk) abk++
    own = (ver >= 3 && rpathv[i] != "")
    if (!hasfile && t != "file_exists" && t != "file_absent" && !own) { out[++outn] = rid[i] ": skipped - " skipped; continue }
    ok = 0; missing = ""; vn = ""; vmax = ""; vmin = ""
    if (t == "file_exists") ok = (rpath != "") ? (substr(absent, abk, 1) == "1") : hasfile
    else if (t == "file_absent") ok = (substr(absent, abk, 1) == "0")
    else if (t == "file_unchanged") { fst = sstat[rpathv[i]]; ok = ((fst == "R" || fst == "Z") && (ssha[rpathv[i]] "") == (rsha[i] "")) }
    else {
      load_doc(rdoc[i]); cd = rdoc[i]
      if (ver >= 3 && dstat[cd] != "R") ok = (t == "forbidden_text" && own && dstat[cd] == "N")
      else if (t == "has_heading") ok = has_section(rhead[i])
      else if (t == "lists_named") {
        for (j = 1; j <= rnn[i]; j++) if (counts[cd, norm(rnames[i, j])] + 0 == 0) missing = (missing == "" ? "" : missing ", ") rnames[i, j]
        ok = (missing == "")
      } else if (t == "max_items") { vn = counts[cd, norm(rlist[i])] + 0; vmax = rmax[i]; ok = (vn <= rmax[i]) }
      else if (t == "min_items") { vn = counts[cd, norm(rlist[i])] + 0; vmin = rmin[i]; ok = (vn >= rmin[i]) }
      else if (t == "min_lines") {
        vn = 0
        for (j = 1; j <= nl[cd]; j++) if (lines[cd, j] ~ /[^ \t]/) vn++
        vmin = rmin[i]; ok = (vn >= rmin[i])
      }
      else if (t == "forbidden_text") ok = !contains_text(i)
      else if (t == "contains_text") ok = contains_text(i)
      else if (t == "no_placeholder") { vn = count_placeholders(); ok = (vn == 0) }
      else if (t == "answer") ok = answer_ok(i)
      else if (t == "contains_number") ok = number_ok(i)
      else if (t == "contains_some") ok = some_ok(i)
      else if (t == "each_item_has") ok = items_ok(i)
      else if (t == "fields_filled") ok = fields_ok(i)
      else die("unknown rule type: " t)
    }
    if (ok) { status = "ok"; msg = rok[i] }
    else { status = rfail_v[i]; msg = rfail[i]; if (sev(status) > worst) worst = sev(status) }
    if (ver < 3 || !(t == "contains_number" || t == "contains_some" || t == "each_item_has" || t == "fields_filled" || t == "file_unchanged")) {
      msg = replace(msg, "{missing}", missing); msg = replace(msg, "{n}", vn); msg = replace(msg, "{max}", vmax); msg = replace(msg, "{min}", vmin)
    }
    out[++outn] = rid[i] ": " status " - " msg
  }
  v = worst == 0 ? "accepted" : worst == 1 ? "almost" : worst == 2 ? "disputed" : "failed"
  printf "verdict: %s\n", v
  for (i = 1; i <= outn; i++) printf "%s\n", out[i]
}'

# ---------- проход 1: правила проверяются целиком, awk печатает, какие файлы нужно проверить оболочке ----------
if ! plan=$(CHECK_PHASE=1 CHECK_SLOTS="" CHECK_DIR="" LC_ALL=C awk -v fname="$fname" "$PROG" "$rules"); then exit 2; fi
ver=$(printf '%s\n' "$plan" | awk -F '\t' '$1 == "V" { print $2; exit }')
case "$ver" in ''|*[!0-9]*) echo "error: rules file is not valid JSON" >&2; exit 2 ;; esac

# Ссылки, размер, NUL и sha256 файлов версии 3 проверяет оболочка. Путь всегда в кавычках, ничего из правил не исполняется
sha256_of() {
  _h=""
  for _tool in shasum sha256sum openssl; do
    command -v "$_tool" >/dev/null 2>&1 || continue
    case "$_tool" in
      shasum) _h=$(shasum -a 256 < "$1" 2>/dev/null) ;;
      sha256sum) _h=$(sha256sum < "$1" 2>/dev/null) ;;
      openssl) _h=$(openssl dgst -sha256 -r < "$1" 2>/dev/null) ;;
    esac
    _h=${_h%% *}
    case "$_h" in ''|*[!0-9a-f]*) _h=""; continue ;; esac
    [ "${#_h}" -eq 64 ] && { printf '%s' "$_h"; return 0; }
    _h=""
  done
  return 1
}
# slot_status <путь относительно учебной папки> <нужен ли sha256> -> строка «путь<tab>статус<tab>sha256»; статус: N нет обычного файла, L ссылка, B больше 262144 байт, Z есть NUL, R читается
slot_line() {
  _full="$dir/$1"; _st=R; _sha=""
  if [ ! -f "$_full" ]; then _st=N
  else
    _p="$dir"; _rest="$1"; _lk=0
    while :; do
      _comp=${_rest%%/*}
      _p="$_p/$_comp"
      [ -L "$_p" ] && _lk=1
      case "$_rest" in */*) _rest=${_rest#*/} ;; *) break ;; esac
    done
    if [ "$_lk" = 1 ]; then _st=L
    else
      _size=$(LC_ALL=C wc -c < "$_full" | tr -d ' ')
      if [ "${_size:-0}" -gt 262144 ]; then _st=B
      else
        _nz=$(LC_ALL=C tr -d '\000' < "$_full" | LC_ALL=C wc -c | tr -d ' ')
        [ "${_nz:-0}" = "${_size:-0}" ] || _st=Z
      fi
    fi
  fi
  if [ "$2" = 1 ] && { [ "$_st" = R ] || [ "$_st" = Z ]; }; then
    _sha=$(sha256_of "$_full") || { echo "error: no program for sha256 (shasum, sha256sum or openssl)" >&2; exit 2; }
  fi
  printf '%s\t%s\t%s\n' "$1" "$_st" "$_sha"
}

tab=$(printf '\t')
slots=""
hasfile=1
target="$dir/$fname"
if [ "$ver" -ge 3 ]; then
  nlc='
'
  set -f
  _oldifs=$IFS
  IFS=$nlc
  for _pl in $plan; do
    IFS=$_oldifs
    case "$_pl" in
      S"$tab"*)
        _rest=${_pl#S"$tab"}; _sp=${_rest%%"$tab"*}; _fl=${_rest#*"$tab"}
        name_ok "$_sp" || bad_name
        _sl=$(slot_line "$_sp" "$_fl") || exit 2
        slots="$slots$_sl$nlc"
        ;;
    esac
    IFS=$nlc
  done
  IFS=$_oldifs
  set +f
  # Главный файл: ссылка, больше предела или с NUL — не читается (правила по нему не выполнены), но «файл есть»
  _mst=$(printf '%s' "$slots" | awk -F '\t' -v f="$fname" '$1 == f { print $2; exit }')
  if [ "$_mst" = N ] || [ -z "$_mst" ]; then hasfile=0; fi
  target=/dev/null
else
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
fi

# Правила file_absent (путь path или, если его нет, file) и file_exists с полем path: сущность на диске проверяет оболочка,
# а awk получает по одному знаку на такое правило в порядке правил (1 — есть, 0 — нет). Ссылки на пути отвергаются (для file_absent — кроме самого последнего звена)
absent=""
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

CHECK_PHASE=0 CHECK_SLOTS="$slots" CHECK_DIR="$dir" LC_ALL=C awk -v fname="$fname" -v hasfile="$hasfile" -v absent="$absent" "$PROG" "$rules" "$target"
