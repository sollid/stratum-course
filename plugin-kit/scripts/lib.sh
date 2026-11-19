#!/bin/sh
# Общее для kit.sh (Mac и Linux; нужны sh, curl, sed, awk, tr, od-подобного не нужно; хеш — sha256sum, shasum или openssl). Подключается через `.`, не запускается.
# Тайны (токен) не печатаются, не попадают в аргументы команд (curl читает заголовок со стандартного ввода) и в адрес.
# Заготовки взяты из плагина курса копированием (site_ok, post, secure_write, kv, say): плагин курса не меняется.
set +x
HERE=$(cd "$(dirname "$0")" && pwd)
TMPD=$(mktemp -d 2>/dev/null || mktemp -d -t kit)
trap 'rm -rf "$TMPD"' EXIT
trap 'exit 130' INT TERM

CMD=""; ARG2=""; SOFT=0; BG=0; QUIET=0
# Уровень движка плагина и предел размера ответа в байтах
ENGINE_LEVEL=1
BODY_MAX=262144
O_data=""; O_probe=""; O_flat=""

# Параметры в виде: <команда> [<аргумент>] --имя значение ... --soft (тот же вид, что у PowerShell-варианта)
parse_opts() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --soft) SOFT=1; shift ;;
      --background) BG=1; shift ;;
      --data|--probe|--flat)
        _n=$1; _v=""
        if [ $# -ge 2 ] && [ "${2#--}" = "$2" ]; then _v=$2; shift 2; else shift; fi
        case "$_n" in --data) O_data=$_v ;; --probe) O_probe=$_v ;; --flat) O_flat=$_v ;; esac ;;
      --*) shift ;;
      *) if [ -z "$CMD" ]; then CMD=$1; elif [ -z "$ARG2" ]; then ARG2=$1; fi; shift ;;
    esac
  done
}

finish() { if [ "$SOFT" = 1 ] || [ "$BG" = 1 ]; then exit 0; else exit "$1"; fi; }

# say <ключ> [имя=значение ...]: текст из messages.txt (общий с PowerShell-вариантом), {имя} заменяется значением
say() {
  [ "$QUIET" = 1 ] && return 0
  _key=$1; shift
  # Ключ идёт через окружение и сравнивается как строка, а не вставляется в текст программы sed
  _text=$(K="$_key=" awk 'index($0, ENVIRON["K"]) == 1 { print substr($0, length(ENVIRON["K"]) + 1); exit }' "$HERE/messages.txt" | head -n 1 | tr -d '\r')
  # Знак \n из шаблона становится переводом строки до подстановки: значения обратную косую черту ничего не значат
  _text=$(printf '%b' "$_text")
  for _kv in "$@"; do
    _k=${_kv%%=*}; _v=${_kv#*=}
    # Подстановка без sed: значение идёт через окружение и сравнивается как строка, поэтому знаки & | / и обратная косая в нём ничего не значат
    _text=$(printf '%s' "$_text" | K="{$_k}" V="$_v" awk '{ s = $0; k = ENVIRON["K"]; v = ENVIRON["V"]; out = ""; while ((i = index(s, k)) > 0) { out = out substr(s, 1, i - 1) v; s = substr(s, i + length(k)) } print out s }')
  done
  printf '%s\n' "$_text"
}
# fail <код> <ключ> [имя=значение ...]
fail() { _code=$1; shift; say "$@"; finish "$_code"; }

is_num() { printf '%s' "$1" | grep -Eq '^[0-9]+$'; }
now() { date +%s; }
iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Папка данных плагина (--data, затем CLAUDE_PLUGIN_DATA, затем папка в профиле для ручных запусков) и папка kit внутри неё
data_dir() {
  _d=$O_data
  case "$_d" in *'${'*) _d="" ;; esac
  [ -z "$_d" ] && _d=${CLAUDE_PLUGIN_DATA:-}
  case "$_d" in *'${'*) _d="" ;; esac
  DATA_FALLBACK=0
  if [ -z "$_d" ]; then _d="$HOME/.stratum-kit"; DATA_FALLBACK=1; fi
  if [ ! -d "$_d/kit" ]; then ( umask 077; mkdir -p "$_d/kit" ); fi
  DATA=$_d
  KD="$DATA/kit"
}

# Настройки-переключатели: значение true из настроек плагина (подстановка ${user_config.…} в навыке) или из окружения хука. Нераскрытая подстановка — выключено
flag_on() { # <значение флага> <имя переменной окружения>
  _fv=$1
  case "$_fv" in *'${'*) _fv="" ;; esac
  # Имя переменной окружения — только из этих двух (без eval: имя в текст программы не подставляется)
  if [ -z "$_fv" ]; then
    case "$2" in
      CLAUDE_PLUGIN_OPTION_PROBE_HOOKS) _fv=${CLAUDE_PLUGIN_OPTION_PROBE_HOOKS:-} ;;
      CLAUDE_PLUGIN_OPTION_FLAT_NAMES) _fv=${CLAUDE_PLUGIN_OPTION_FLAT_NAMES:-} ;;
    esac
  fi
  [ "$_fv" = true ]
}
settings() {
  PROBE=0; LAYOUT=folders
  flag_on "$O_probe" CLAUDE_PLUGIN_OPTION_PROBE_HOOKS && PROBE=1
  flag_on "$O_flat" CLAUDE_PLUGIN_OPTION_FLAT_NAMES && LAYOUT=flat
  return 0
}

# Папка правил человека: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/rules (CLAUDE_CONFIG_DIR — по странице env-vars документации)
rules_root() {
  _c=${CLAUDE_CONFIG_DIR:-}
  [ -z "$_c" ] && _c="$HOME/.claude"
  RULES="$_c/rules"
}

site_ok() {
  case "$1" in *'
'*) return 1 ;; esac
  printf '%s' "$1" | grep -Eq '^(https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?|http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?)$'
}

plugin_version() {
  _v=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HERE/../.claude-plugin/plugin.json" 2>/dev/null | head -n 1)
  if printf '%s' "$_v" | grep -Eq '^[0-9A-Za-z.+-]{1,20}$'; then printf '%s' "$_v"; else printf '0'; fi
}

os_name() {
  case "$(uname -s)" in
    Darwin) printf 'mac' ;;
    MINGW*|MSYS*|CYGWIN*) printf 'windows' ;;
    *) printf 'linux' ;;
  esac
}

# jstr <файл> <ключ>: значение строкового ключа из ответа сайта. Ключ — только маленькие латинские буквы и «_» (вызывающие передают свои слова), иначе пусто
jstr() {
  case "$2" in ''|*[!a-z_]*) return 0 ;; esac
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -n 1
}
# Значение по ключу из файла «ключ=значение»: ключ сравнивается как строка (в программу sed и в регулярное выражение он не попадает)
kv() { awk -v k="$2" 'index($0, k "=") == 1 { sub(/\r$/, ""); print substr($0, length(k) + 2); exit }' "$1" 2>/dev/null; }

# SHA-256 файла: sha256sum, иначе shasum -a 256, иначе openssl (Mac: shasum есть всегда). Файл идёт через стандартный ввод
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 < "$1" | awk '{ print $1 }'
  else openssl dgst -sha256 < "$1" | awk '{ print $NF }'; fi
}

# Файл, который открывает только владелец: создаётся с режимом 600 (umask 077), затем chmod 600 и замена целевого файла. Содержимое — со стандартного ввода.
secure_write() {
  _tmp="$1.tmp"
  # Временный файл создаётся заново: подложенная ссылка на этом имени стирается, запись идёт в новый файл (noclobber не открывает существующий)
  rm -f "$_tmp"
  ( umask 077; set -C; cat > "$_tmp" ) || return 1
  chmod 600 "$_tmp" || return 1
  mv -f "$_tmp" "$1"
}

# ---------- замок запуска: файл .lock с номером процесса (создаётся атомарно: noclobber) ----------
# Занят живым процессом — прямая фраза и код 19. Замок мёртвого процесса или старше 10 минут снимается сразу. Снимается при любом выходе.
acquire_lock() {
  LOCK="$DATA/.lock"
  _tries=0
  while [ "$_tries" -lt 2 ]; do
    if ( set -C; printf '%s\n' "$$" > "$LOCK" ) 2>/dev/null; then
      trap 'rm -rf "$TMPD"; rm -f "$LOCK"' EXIT
      return 0
    fi
    _lp=$(head -n 1 "$LOCK" 2>/dev/null | tr -d '\r')
    _dead=0
    if is_num "$_lp" && [ "${#_lp}" -le 9 ]; then kill -0 "$_lp" 2>/dev/null || _dead=1; fi
    [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ] && _dead=1
    if [ "$_dead" = 1 ]; then rm -f "$LOCK"; else break; fi
    _tries=$((_tries + 1))
  done
  fail 19 kit.busy
}

# ---------- токен и адрес сайта: у плагина курса, не дублируя привязку ----------
# Файл токена лежит в папке данных плагина курса (course-<каталог>), соседней с папкой данных kit. По порядку: KIT_COURSE_DATA (явная папка),
# соседняя папка course-stratum-course; иначе единственная соседняя course-* с токеном (несколько — отказ, код 26); ~/.stratum-course (ручные запуски курса; при запасной папке данных — только он).
find_course_data() {
  COURSE_DATA=""; COURSE_MANY=0
  if [ -n "${KIT_COURSE_DATA:-}" ]; then
    [ -f "$KIT_COURSE_DATA/device-token.txt" ] && COURSE_DATA=$KIT_COURSE_DATA
    return 0
  fi
  _best=""
  # Запасная папка данных (~/.stratum-kit, ручной запуск): «соседей» нет, ищется только ~/.stratum-course
  if [ "$DATA_FALLBACK" != 1 ]; then
    _par=$(dirname "$DATA")
    if [ -f "$_par/course-stratum-course/device-token.txt" ] && [ ! -L "$_par/course-stratum-course/device-token.txt" ]; then
      _best="$_par/course-stratum-course"
    else
      # Точного имени нет: годится единственная папка course-* с токеном; несколько — отказ (какая привязка нужна, решает человек: KIT_COURSE_DATA)
      _cnt=0
      for _c in "$_par"/course-*; do
        [ -f "$_c/device-token.txt" ] && [ ! -L "$_c/device-token.txt" ] || continue
        _cnt=$((_cnt + 1)); _best=$_c
      done
      if [ "$_cnt" -gt 1 ]; then COURSE_MANY=1; return 0; fi
    fi
  fi
  if [ -z "$_best" ] && [ -f "$HOME/.stratum-course/device-token.txt" ]; then _best="$HOME/.stratum-course"; fi
  COURSE_DATA=$_best
  return 0
}

# Адрес сайта из настроек курса: COURSE_SITE_URL, иначе первая строка файла site-url в папке данных курса. SITE_STATE: ok | none | bad
site_setting() {
  SITE_STATE=none; SITE_URL=""
  _v=${COURSE_SITE_URL:-}
  if [ -z "$_v" ] && [ -n "$COURSE_DATA" ] && [ -f "$COURSE_DATA/site-url" ]; then _v=$(head -n 1 "$COURSE_DATA/site-url" | tr -d '\r'); fi
  [ -z "$_v" ] && return 0
  _v=$(printf '%s' "$_v" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  while [ "${_v%/}" != "$_v" ]; do _v=${_v%/}; done
  if site_ok "$_v"; then SITE_STATE=ok; SITE_URL=$_v; else SITE_STATE=bad; fi
}

# ---------- запрос к сайту ----------
# post_kit <путь> <файл с телом> -> HTTP_STATUS (0 — сайт не ответил), BIG (1 — ответ больше предела), ответ в $TMPD/resp.
# Токен curl получает со стандартного ввода (config), а не в аргументах. Первый аргумент -q: ~/.curlrc не читается. Перенаправления не выполняются.
post_kit() {
  : > "$TMPD/resp"; BIG=0
  HTTP_STATUS=$(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl -q -s -K - --max-redirs 0 --max-time 15 --connect-timeout 8 --max-filesize "$BODY_MAX" -A stratum-kit-plugin -X POST -H 'Content-Type: application/json' -H 'Accept: text/plain' --data-binary "@$2" -o "$TMPD/resp" -w '%{http_code}' "$SITE$1" 2>/dev/null)
  _rc=$?
  case "$HTTP_STATUS" in [0-9][0-9][0-9]) ;; *) HTTP_STATUS=000 ;; esac
  [ "$HTTP_STATUS" = 000 ] && HTTP_STATUS=0
  # curl 63: ответ больше предела (заголовки пришли, значит сайт отвечал)
  if [ "$_rc" = 63 ]; then BIG=1; [ "$HTTP_STATUS" = 0 ] && HTTP_STATUS=200; fi
  _sz=$(wc -c < "$TMPD/resp" | tr -d ' ')
  [ "${_sz:-0}" -gt "$BODY_MAX" ] && BIG=1
  return 0
}

# ---------- разбор ответов (общее для sh-кода: awk, байты, без UTF-8-зависимости от локали) ----------

# Общие проверки текста ответа: размер, нет NUL и CR, кончается переводом строки. 0 — годен
body_basic_ok() { # <файл> <предел>
  _sz=$(wc -c < "$1" | tr -d ' ')
  { [ "${_sz:-0}" -gt 0 ] && [ "$_sz" -le "$2" ]; } || return 1
  [ "$(LC_ALL=C tr -d '\000\r' < "$1" | wc -c | tr -d ' ')" = "$_sz" ] || return 1
  [ "$(tail -c 1 "$1" | wc -l | tr -d ' ')" = 1 ] || return 1
  return 0
}

# parse_list <файл> -> LIST_ERR: пусто (годен), version (другая версия формата), format. Разобранное: $TMPD/list (строки «id версия want»), LIST_STATE, LIST_TEAM
parse_list() {
  LIST_ERR=format; LIST_STATE=""; LIST_TEAM=0
  : > "$TMPD/list"
  body_basic_ok "$1" 65536 || return 0
  _r=$(LC_ALL=C awk -v out="$TMPD/list" '
function bad(tag) { print "ERR " tag; failed = 1; exit 1 }
function hidden(s) { return (s ~ /[\001-\010\013-\037\177]/ || s ~ /\302[\200-\237]/ || s ~ /\342\200[\213-\217\250-\256]/ || s ~ /\342\201[\240-\251]/ || s ~ /\330\234/ || s ~ /\357\273\277/ || s ~ /\363\240[\200\201][\200-\277]/) }
function utf8ok(s) { return (s ~ /^([\001-\177]|[\302-\337][\200-\277]|\340[\240-\277][\200-\277]|[\341-\354\356\357][\200-\277][\200-\277]|\355[\200-\237][\200-\277]|\360[\220-\277][\200-\277][\200-\277]|[\361-\363][\200-\277][\200-\277][\200-\277]|\364[\200-\217][\200-\277][\200-\277])*$/) }
function reserved(s,   b, i) { b = tolower(s); i = index(b, "."); if (i > 0) b = substr(b, 1, i - 1); return (b ~ /^(con|prn|aux|nul|com[0-9]|lpt[0-9])$/) }
function id_ok(s) { return (length(s) >= 2 && length(s) <= 30 && s ~ /^[a-z][a-z0-9-]*$/ && !reserved(s)) }
function ver_ok(s,   a, n) { n = split(s, a, "."); return (n == 2 && a[1] ~ /^(0|[1-9][0-9]*)$/ && a[2] ~ /^(0|[1-9][0-9]*)$/ && length(a[1]) <= 3 && length(a[2]) <= 3) }
NR == 1 { if ($0 != "stratum-kit 1") { if ($0 ~ /^stratum-kit [0-9]+$/) bad("version"); bad("format") } next }
{
  if ($0 == "") bad("format")
  i = index($0, "="); if (i < 2) bad("format")
  k = substr($0, 1, i - 1); v = substr($0, i + 1)
  if (k !~ /^[a-z_0-9]+$/ || v ~ /[\001-\037\177]/ || length(v) > 300 || (k in H)) bad("format")
  if (v ~ /[\200-\377]/ && !utf8ok(v)) bad("format")
  if (hidden(v)) bad("format")
  H[k] = v
}
END {
  if (failed) exit
  if (!(H["state"] == "ok" || H["state"] == "none")) bad("format")
  if (!(H["packages"] ~ /^[0-9]+$/ && length(H["packages"]) <= 2 && H["packages"] + 0 <= 16)) bad("format")
  if (("team" in H) && !(H["team"] == "0" || H["team"] == "1")) bad("format")
  np = H["packages"] + 0
  if (H["state"] == "none" && np != 0) bad("format")
  for (k in H) if (k ~ /^pkg_/) { s = substr(k, 5); if (!(s ~ /^[0-9]+$/ && length(s) <= 2 && s + 0 >= 1 && s + 0 <= np)) bad("format") }
  for (j = 1; j <= np; j++) {
    if (!(("pkg_" j) in H)) bad("format")
    c = split(H["pkg_" j], F, / /)
    if (c != 3 || !id_ok(F[1]) || !ver_ok(F[2]) || !(F[3] == "on" || F[3] == "off" || F[3] == "none") || (F[1] in seen)) bad("format")
    seen[F[1]] = 1
    print F[1] " " F[2] " " F[3] > out
  }
  close(out)
  print "STATE " H["state"]
  print "TEAM " (("team" in H) ? H["team"] : "0")
  print "OK"
}' "$1" 2>/dev/null)
  case "$_r" in
    *OK) LIST_ERR=""; LIST_STATE=$(printf '%s\n' "$_r" | sed -n 's/^STATE //p'); LIST_TEAM=$(printf '%s\n' "$_r" | sed -n 's/^TEAM //p') ;;
    *"ERR version"*) LIST_ERR=version ;;
  esac
  return 0
}

# parse_packages <файл> <id через запятую> -> PK_ERR: пусто (структура верна), version (другая версия формата или нужен более новый движок), format.
# Разбирает ответ «stratum-kit-package 1» и ничего не пишет вне $TMPD/pk. Для пакета n: $TMPD/pk/n/info (id=, version=, err=), r<k> (содержимое правила k),
# rules.list (k, имя, sha256 из ответа через табуляцию), deny (запреты) и deny.sha. err пакета: пусто | name | size | paths | deny | denyq (знак «?» в строке запрета) | text | parts; хеши сверяет verify_packages.
# Структурная ошибка (шапка, граница, число пакетов, невидимое в шапке, не UTF-8) отвергает весь ответ; ошибка одного пакета — только этот пакет.
parse_packages() {
  PK_ERR=format; PK_COUNT=0
  rm -rf "$TMPD/pk"; mkdir "$TMPD/pk" || return 0
  # Папки пакетов 1..8 заводит оболочка, а не awk (путь временной папки не попадает в команду оболочки из awk)
  for _d in 1 2 3 4 5 6 7 8; do mkdir "$TMPD/pk/$_d" || return 0; done
  body_basic_ok "$1" "$BODY_MAX" || return 0
  _r=$(LC_ALL=C awk -v out="$TMPD/pk" -v want="$2" -v engine="$ENGINE_LEVEL" '
function bad(tag) { print "ERR " tag; failed = 1; exit 1 }
function hidden(s) { return (s ~ /[\001-\010\013-\037\177]/ || s ~ /\302[\200-\237]/ || s ~ /\342\200[\213-\217\250-\256]/ || s ~ /\342\201[\240-\251]/ || s ~ /\330\234/ || s ~ /\357\273\277/ || s ~ /\363\240[\200\201][\200-\277]/) }
function utf8ok(s) { return (s ~ /^([\001-\177]|[\302-\337][\200-\277]|\340[\240-\277][\200-\277]|[\341-\354\356\357][\200-\277][\200-\277]|\355[\200-\237][\200-\277]|\360[\220-\277][\200-\277][\200-\277]|[\361-\363][\200-\277][\200-\277][\200-\277]|\364[\200-\217][\200-\277][\200-\277])*$/) }
function reserved(s,   b, i) { b = tolower(s); i = index(b, "."); if (i > 0) b = substr(b, 1, i - 1); return (b ~ /^(con|prn|aux|nul|com[0-9]|lpt[0-9])$/) }
function id_ok(s) { return (length(s) >= 2 && length(s) <= 30 && s ~ /^[a-z][a-z0-9-]*$/ && !reserved(s)) }
function ver_ok(s,   a, n) { n = split(s, a, "."); return (n == 2 && a[1] ~ /^(0|[1-9][0-9]*)$/ && a[2] ~ /^(0|[1-9][0-9]*)$/ && length(a[1]) <= 3 && length(a[2]) <= 3) }
function deny_bad(l,   sp, p, q) {
  if (length(l) > 200 || length(l) < 3 || l !~ /^(Read|Edit|Write|Bash) [^ ]/) return 1
  if (l ~ /[^ -~]/) return 1
  if (index(l, "[") || index(l, "]") || index(l, "\\") || index(l, "`") || index(l, "?")) return 1
  sp = index(l, " "); p = substr(l, sp + 1); q = p; gsub(/[* ]/, "", q)
  return (length(q) < 3)
}
function sha_ok(s) { return (length(s) == 64 && s ~ /^[0-9a-f]+$/) }
function name_ok(s,   low) {
  if (length(s) < 4 || length(s) > 43 || s !~ /^[a-z0-9][a-z0-9-]*\.md$/) return 0
  low = tolower(s)
  return !(low == "claude.md" || low == "agents.md" || reserved(s))
}
function perr(e) { if (pe[np] == "") pe[np] = e }
function closecur() { if (cur != "" && cur != "sink") close(cur); cur = "" }
function finish_pkg(   k) {
  if (np == 0) return
  closecur()
  if (nr[np] < 1 || nr[np] > 4) perr("parts")
}
NR == 1 {
  if ($0 != "stratum-kit-package 1") { if ($0 ~ /^stratum-kit-package [0-9]+$/) bad("version"); bad("format") }
  mode = "head"; next
}
mode == "head" {
  if ($0 == "") {
    if (!(H["boundary"] ~ /^[0-9a-f]+$/ && length(H["boundary"]) == 32)) bad("format")
    if (!(H["packages"] ~ /^[0-9]+$/ && length(H["packages"]) == 1 && H["packages"] + 0 >= 1 && H["packages"] + 0 <= 8)) bad("format")
    if (("min_engine" in H) && !(H["min_engine"] ~ /^[0-9]+$/ && length(H["min_engine"]) <= 2)) bad("format")
    if (("min_engine" in H) && H["min_engine"] + 0 > engine + 0) bad("version")
    nw = split(want, W, ","); for (j = 1; j <= nw; j++) WANT[W[j]] = 1
    if (H["packages"] + 0 != nw) bad("format")
    mode = "body"; pre = "--" H["boundary"]; next
  }
  i = index($0, "=")
  if (i < 2) bad("format")
  k = substr($0, 1, i - 1); v = substr($0, i + 1)
  if (k !~ /^[a-z_0-9]+$/ || v ~ /[\001-\037\177]/ || length(v) > 300 || (k in H)) bad("format")
  if (v ~ /[\200-\377]/ && !utf8ok(v)) bad("format")
  if (hidden(v)) bad("format")
  H[k] = v
  next
}
mode == "ended" { bad("format") }
{
  if (substr($0, 1, length(pre)) == pre) {
    rest = substr($0, length(pre) + 1)
    nt = split(rest, T, / /)
    if (rest == " end") { finish_pkg(); mode = "ended"; next }
    if (nt == 4 && T[1] == "" && T[2] == "package") {
      finish_pkg()
      if (!id_ok(T[3]) || !ver_ok(T[4]) || !(T[3] in WANT) || (T[3] in seen)) bad("format")
      seen[T[3]] = 1; np++
      pid[np] = T[3]; pver[np] = T[4]; nr[np] = 0; nd[np] = 0; pb[np] = 0; pe[np] = ""; dn[np] = 0
      cur = "sink"; kind = "sink"
      next
    }
    if (np == 0) bad("format")
    closecur()
    if (nt == 4 && T[1] == "" && T[2] == "rule" && sha_ok(T[4]) && nd[np] == 0) {
      nr[np]++
      if (!name_ok(T[3]) || ((np SUBSEP tolower(T[3])) in rn)) perr("name")
      rn[np, tolower(T[3])] = 1
      cur = out "/" np "/r" nr[np]; printf "" > cur; kind = "rule"; sz = 0
      rname[np, nr[np]] = T[3]; rsha[np, nr[np]] = T[4]
      next
    }
    if (nt == 3 && T[1] == "" && T[2] == "deny" && sha_ok(T[3]) && nd[np] == 0 && nr[np] >= 1) {
      nd[np] = 1
      cur = out "/" np "/deny"; printf "" > cur; kind = "deny"; sz = 0
      dsha[np] = T[3]
      next
    }
    perr("parts"); cur = "sink"; kind = "sink"; next
  }
  if (cur == "") bad("format")
  if ($0 ~ /[\200-\377]/ && !utf8ok($0)) bad("format")
  if (kind == "sink") { perr("parts"); next }
  if (hidden($0)) perr("text")
  len = length($0) + 1
  sz += len; pb[np] += len
  if (kind == "rule") {
    if (sz > 16384 || pb[np] > 40960) perr("size")
    if ($0 ~ /^paths:/) perr("paths")
  } else {
    dn[np]++
    if (index($0, "?") > 0) perr("denyq"); else if (dn[np] > 60 || deny_bad($0) || pb[np] > 40960) perr("deny")
  }
  print $0 > cur
}
END {
  if (failed) exit
  if (mode != "ended") bad("format")
  if (np != H["packages"] + 0) bad("format")
  for (n = 1; n <= np; n++) {
    f = out "/" n "/info"
    print "id=" pid[n] > f; print "version=" pver[n] > f; print "err=" pe[n] > f
    close(f)
    lf = out "/" n "/rules.list"; printf "" > lf
    for (j = 1; j <= nr[n]; j++) print j "\t" rname[n, j] "\t" rsha[n, j] > lf
    close(lf)
    if (nd[n]) { print dsha[n] > (out "/" n "/deny.sha"); close(out "/" n "/deny.sha") }
  }
  print "COUNT " np
  print "OK"
}' "$1" 2>/dev/null)
  case "$_r" in
    *OK) PK_ERR=""; PK_COUNT=$(printf '%s\n' "$_r" | sed -n 's/^COUNT //p') ;;
    *"ERR version"*) PK_ERR=version ;;
  esac
  return 0
}

# verify_packages: сверяет sha256 каждой части с заявленным в ответе; несовпадение — err=hash (если у пакета ошибки ещё нет)
verify_packages() {
  _n=1
  while [ "$_n" -le "$PK_COUNT" ]; do
    _pd="$TMPD/pk/$_n"
    if [ -z "$(kv "$_pd/info" err)" ]; then
      _tab=$(printf '\t'); _bad=0
      while IFS="$_tab" read -r _k _nm _sha; do
        [ "$(sha256_file "$_pd/r$_k")" = "$_sha" ] || _bad=1
      done < "$_pd/rules.list"
      if [ -f "$_pd/deny.sha" ]; then [ "$(sha256_file "$_pd/deny")" = "$(head -n 1 "$_pd/deny.sha")" ] || _bad=1; fi
      if [ "$_bad" = 1 ]; then
        { printf 'id=%s\nversion=%s\nerr=hash\n' "$(kv "$_pd/info" id)" "$(kv "$_pd/info" version)"; } > "$_pd/info.new" && mv -f "$_pd/info.new" "$_pd/info"
      fi
    fi
    _n=$((_n + 1))
  done
}

# ---------- состояние: state.txt («id версия статус sha256-файлов время»), манифест пакета, журнал загрузки ----------
# Файлы лежат в $KD, права 600 (папки 700). state.txt — по строке на пакет; порядок строк — порядок установки.

# Допустимая строка состояния: id версия статус хеш время
st_valid() { printf '%s\n' "$1" | LC_ALL=C awk '{ if (NF != 5) exit 1; if (!($1 ~ /^[a-z][a-z0-9-]*$/ && length($1) >= 2 && length($1) <= 30)) exit 1; if (!($2 ~ /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/ && length($2) <= 7)) exit 1; if (!($3 == "ok" || $3 == "files" || $3 == "not_loaded" || $3 == "absent" || $3 == "off")) exit 1; if (!(length($4) == 64 && $4 ~ /^[0-9a-f]+$/)) exit 1; if (!($5 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/)) exit 1; exit 0 }'; }

# Корректные строки состояния (по одной на id; первая побеждает)
st_lines() { [ -f "$KD/state.txt" ] && LC_ALL=C awk '{ sub(/\r$/, "") } NF == 5 && $1 ~ /^[a-z][a-z0-9-]*$/ && length($1) >= 2 && length($1) <= 30 && $2 ~ /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/ && length($2) <= 7 && ($3 == "ok" || $3 == "files" || $3 == "not_loaded" || $3 == "absent" || $3 == "off") && length($4) == 64 && $4 ~ /^[0-9a-f]+$/ && $5 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/ && !($1 in seen) { seen[$1] = 1; print }' "$KD/state.txt" 2>/dev/null; return 0; }
st_ids() { st_lines | awk '{ print $1 }'; }
st_get() { st_lines | K="$1" F="$2" awk 'BEGIN { f = ENVIRON["F"] + 0 } $1 == ENVIRON["K"] { print $f; exit }'; }
# st_put <id> <версия> <статус> <хеш>: заменяет строку пакета (или добавляет в конец), время — сейчас
st_put() {
  _line="$1 $2 $3 $4 $(iso_now)"
  # порядок: строка пакета остаётся на прежнем месте, новый пакет — в конец
  if [ -n "$(st_get "$1" 1)" ]; then
    st_lines | K="$1" L="$_line" awk '$1 == ENVIRON["K"] { print ENVIRON["L"]; next } { print }' | secure_write "$KD/state.txt"
  else
    { st_lines; printf '%s\n' "$_line"; } | secure_write "$KD/state.txt"
  fi
}

# Манифест пакета $KD/<id>/manifest.txt: «version V», «layout L», «rule имя sha», «deny sha»
man_file() { printf '%s/%s/manifest.txt' "$KD" "$1"; }
man_layout() { [ -f "$(man_file "$1")" ] && awk '$1 == "layout" { print $2; exit }' "$(man_file "$1")"; return 0; }
man_rules() { [ -f "$(man_file "$1")" ] && awk '$1 == "rule" && NF == 3 { print $2 "\t" $3 }' "$(man_file "$1")"; return 0; }
man_deny() { [ -f "$(man_file "$1")" ] && awk '$1 == "deny" && NF == 2 { print $2; exit }' "$(man_file "$1")"; return 0; }

# rule_path <раскладка> <id> <имя>: куда кладётся правило. folders: rules/stratum/<id>/<имя>; flat: rules/stratum-<id>-<имя>
rule_path() {
  case "$1" in
    flat) printf '%s/stratum-%s-%s' "$RULES" "$2" "$3" ;;
    *) printf '%s/stratum/%s/%s' "$RULES" "$2" "$3" ;;
  esac
}
# Путь для показа человеку: без папки пользователя
rule_show() {
  case "$1" in
    flat) printf 'rules/stratum-%s-%s' "$2" "$3" ;;
    *) printf 'rules/stratum/%s/%s' "$2" "$3" ;;
  esac
}

# Журнал загрузки правил $KD/loaded.log: «секунды причина путь» (путь без обратных косых), без содержимого. Есть ли в журнале файлы правил пакета?
loaded_has() { # <раскладка> <id> <имя>
  [ -f "$KD/loaded.log" ] || return 1
  case "$1" in flat) _suffix="/rules/stratum-$2-$3" ;; *) _suffix="/rules/stratum/$2/$3" ;; esac
  S="$_suffix" LC_ALL=C awk 'BEGIN { s = tolower(ENVIRON["S"]) } { p = tolower($3); if (length(p) >= length(s) && substr(p, length(p) - length(s) + 1) == s) f = 1 } END { exit f ? 0 : 1 }' "$KD/loaded.log"
}
loaded_drop() { # <id>: журнал забывает правила пакета (после записи файлов Claude Code должен загрузить их заново)
  [ -f "$KD/loaded.log" ] || return 0
  LC_ALL=C awk -v a="/rules/stratum/$1/" -v b="/rules/stratum-$1-" '{ p = tolower($3); if (index(p, a) > 0 || index(p, b) > 0) next; print }' "$KD/loaded.log" | secure_write "$KD/loaded.log"
}

# local_status <id> -> LS (ok | files | absent | off | not_loaded). Сверка файлов пакета на диске с манифестом
local_status() {
  _st=$(st_get "$1" 3)
  if [ "$_st" = off ]; then LS=off; return 0; fi
  _lay=$(man_layout "$1"); [ -n "$_lay" ] || _lay=folders
  _present=0; _missing=0; _diff=0; _total=0
  _tab=$(printf '\t')
  while IFS="$_tab" read -r _nm _sha; do
    [ -n "$_nm" ] || continue
    _total=$((_total + 1))
    _p=$(rule_path "$_lay" "$1" "$_nm")
    if [ -f "$_p" ] && [ ! -L "$_p" ]; then
      _present=$((_present + 1))
      [ "$(sha256_file "$_p")" = "$_sha" ] || _diff=1
    else
      _missing=1
    fi
  done <<EOF
$(man_rules "$1")
EOF
  if [ "$_total" = 0 ] || [ "$_present" = 0 ]; then LS=absent; return 0; fi
  if [ "$_missing" = 1 ] || [ "$_diff" = 1 ]; then LS=files; return 0; fi
  LS=ok
  if [ "$PROBE" = 1 ]; then
    while IFS="$_tab" read -r _nm _sha; do
      [ -n "$_nm" ] || continue
      loaded_has "$_lay" "$1" "$_nm" || { LS=not_loaded; break; }
    done <<EOF
$(man_rules "$1")
EOF
  fi
  return 0
}

# ver_lt <a> <b>: версия a меньше версии b (числа «мажор.минор»)
ver_lt() { A="$1" B="$2" awk 'BEGIN { split(ENVIRON["A"], a, "."); split(ENVIRON["B"], b, "."); if (a[1] + 0 != b[1] + 0) exit !(a[1] + 0 < b[1] + 0); exit !(a[2] + 0 < b[2] + 0) }'; }

# Имя пакета для человека из messages.txt (pkgname.<id>); нет в списке — сам id
pkg_name() {
  # Ключ идёт через окружение и сравнивается как строка (index), а не вставляется в текст программы sed: имя с «/», «;», переводом строки ничего не значит
  _n=$(K="pkgname.$1=" awk 'index($0, ENVIRON["K"]) == 1 { print substr($0, length(ENVIRON["K"]) + 1); exit }' "$HERE/messages.txt" | head -n 1 | tr -d '\r')
  [ -n "$_n" ] || _n=$1
  printf '%s' "$_n"
}

# Имя пакета из аргумента человека. Перевод строки и возврат каретки отвергаются до grep: он смотрит строки по одной, и «негодная строка + годная» прошла бы
id_ok_arg() {
  case "$1" in
    *'
'*) return 1 ;;
  esac
  case "$1" in *"$(printf '\r')"*) return 1 ;; esac
  printf '%s' "$1" | grep -Eq '^[a-z][a-z0-9-]{1,29}$' && ! printf '%s' "$1" | grep -Eiq '^(con|prn|aux|nul|com[0-9]|lpt[0-9])$'
}

# ---------- запись пакета ----------

# dir_real <путь>: папка внутри rules, настоящая (не ссылка). Создаёт при отсутствии. 0 — годна
dir_real() {
  [ -L "$1" ] && return 1
  if [ -e "$1" ]; then [ -d "$1" ] || return 1; return 0; fi
  mkdir "$1" 2>/dev/null || return 1
  [ -L "$1" ] && return 1
  [ -d "$1" ]
}

# backup_file <путь> <id> <имя>: копия в $KD/backup/<id>/<имя> (одна, последняя)
backup_file() {
  ( umask 077; mkdir -p "$KD/backup/$2" ) 2>/dev/null || return 1
  rm -f "$KD/backup/$2/$3"
  ( umask 077; set -C; cat "$1" > "$KD/backup/$2/$3" ) 2>/dev/null
}

# place_package <номер разобранного пакета>: пишет правила, запреты, манифест и строку состояния. PLACE: placed | occupied | cantwrite; OCC — занятое имя
# Порядок: проверки путей (ничего не меняется) -> временные файлы рядом с целью (имя не .md, Claude Code их не грузит) -> копии в backup -> переименования -> лишние прежние файлы -> запреты, манифест, состояние.
place_package() {
  _pd="$TMPD/pk/$1"
  _id=$(kv "$_pd/info" id); _ver=$(kv "$_pd/info" version)
  PLACE=cantwrite; OCC=""
  _old_lay=$(man_layout "$_id"); _oldp="$TMPD/oldpaths"; : > "$_oldp"
  _tab=$(printf '\t')
  if [ -n "$_old_lay" ]; then
    man_rules "$_id" | while IFS="$_tab" read -r _nm _sha; do rule_path "$_old_lay" "$_id" "$_nm"; printf '\n'; done > "$_oldp"
  fi
  # Сама папка rules может быть ссылкой человека (документация это допускает); stratum и папка пакета — только настоящие
  [ -d "$RULES" ] || mkdir -p "$RULES" 2>/dev/null
  [ -d "$RULES" ] || return 0
  if [ "$LAYOUT" != flat ]; then
    dir_real "$RULES/stratum" && dir_real "$RULES/stratum/$_id" || return 0
  fi
  # 1. занятые пути: свой файл (он в прежнем манифесте) можно заменить, чужой — нет
  while IFS="$_tab" read -r _k _nm _sha; do
    _tgt=$(rule_path "$LAYOUT" "$_id" "$_nm")
    if [ -e "$_tgt" ] || [ -L "$_tgt" ]; then
      if [ -L "$_tgt" ] || [ ! -f "$_tgt" ] || ! grep -Fxq -- "$_tgt" "$_oldp"; then PLACE=occupied; OCC=$(rule_show "$LAYOUT" "$_id" "$_nm"); return 0; fi
    fi
  done < "$_pd/rules.list"
  # 2. временные файлы
  _made=""
  while IFS="$_tab" read -r _k _nm _sha; do
    _tgt=$(rule_path "$LAYOUT" "$_id" "$_nm"); _tmp="$_tgt.kit-tmp"
    rm -f "$_tmp"
    if ! ( set -C; cat "$_pd/r$_k" > "$_tmp" ) 2>/dev/null; then
      while IFS="$_tab" read -r _k2 _nm2 _s2; do rm -f "$(rule_path "$LAYOUT" "$_id" "$_nm2").kit-tmp"; done < "$_pd/rules.list"
      return 0
    fi
  done < "$_pd/rules.list"
  # 3. копии заменяемого (сбой копии — ничего не меняется) и 4. переименования; сбой переименования — файлы возвращаются из копий, временные убираются
  _rb=""
  while IFS="$_tab" read -r _k _nm _sha; do
    _tgt=$(rule_path "$LAYOUT" "$_id" "$_nm")
    if [ -f "$_tgt" ]; then
      if ! backup_file "$_tgt" "$_id" "$_nm"; then place_cleanup "$_id"; return 0; fi
      _rb="$_rb $_nm"
    fi
  done < "$_pd/rules.list"
  _done=""
  while IFS="$_tab" read -r _k _nm _sha; do
    _tgt=$(rule_path "$LAYOUT" "$_id" "$_nm")
    if ! mv -f "$_tgt.kit-tmp" "$_tgt"; then
      for _d2 in $_done; do
        _t2=$(rule_path "$LAYOUT" "$_id" "$_d2")
        case " $_rb " in
          *" $_d2 "*) cat "$KD/backup/$_id/$_d2" > "$_t2" 2>/dev/null ;;
          *) rm -f "$_t2" ;;
        esac
      done
      place_cleanup "$_id"; return 0
    fi
    _done="$_done $_nm"
  done < "$_pd/rules.list"
  while IFS="$_tab" read -r _k _nm _sha; do rule_path "$LAYOUT" "$_id" "$_nm"; printf '%s\n' ""; done < "$_pd/rules.list" > "$TMPD/newpaths"
  # 5. прежние файлы пакета, которых в новой версии нет: копия и удаление (только свои, из прежнего манифеста)
  if [ -n "$_old_lay" ]; then
    man_rules "$_id" | while IFS="$_tab" read -r _nm _sha; do
      _op=$(rule_path "$_old_lay" "$_id" "$_nm")
      if ! grep -Fxq -- "$_op" "$TMPD/newpaths"; then
        if [ -f "$_op" ] && [ ! -L "$_op" ]; then backup_file "$_op" "$_id" "$_nm"; rm -f "$_op"; fi
      fi
    done
  fi
  # 6. запреты пакета, манифест, состояние
  ( umask 077; mkdir -p "$KD/$_id" ) 2>/dev/null || return 0
  if [ -f "$_pd/deny" ]; then
    [ -f "$KD/$_id/deny.txt" ] && backup_file "$KD/$_id/deny.txt" "$_id" deny.txt
    secure_write "$KD/$_id/deny.txt" < "$_pd/deny" || return 0
  else
    [ -f "$KD/$_id/deny.txt" ] && { backup_file "$KD/$_id/deny.txt" "$_id" deny.txt; rm -f "$KD/$_id/deny.txt"; }
  fi
  {
    printf 'version %s\nlayout %s\n' "$_ver" "$LAYOUT"
    while IFS="$_tab" read -r _k _nm _sha; do printf 'rule %s %s\n' "$_nm" "$_sha"; done < "$_pd/rules.list"
    [ -f "$_pd/deny.sha" ] && printf 'deny %s\n' "$(head -n 1 "$_pd/deny.sha")"
  } | secure_write "$(man_file "$_id")" || return 0
  loaded_drop "$_id"
  st_put "$_id" "$_ver" ok "$(sha256_file "$(man_file "$_id")")" || return 0
  PLACE=placed
  return 0
}

# place_cleanup <id>: убирает временные файлы .kit-tmp пакета (по списку частей разобранного пакета)
place_cleanup() {
  while IFS="$_tab" read -r _k2 _nm2 _s2; do rm -f "$(rule_path "$LAYOUT" "$1" "$_nm2").kit-tmp"; done < "$_pd/rules.list"
}

# remove_package <id> <статус off>: файлы пакета уходят в backup (только свои, из манифеста), запреты тоже; состояние — off
remove_package() {
  _id=$1
  _lay=$(man_layout "$_id"); [ -n "$_lay" ] || _lay=folders
  _tab=$(printf '\t')
  man_rules "$_id" | while IFS="$_tab" read -r _nm _sha; do
    _p=$(rule_path "$_lay" "$_id" "$_nm")
    if [ -f "$_p" ] && [ ! -L "$_p" ]; then backup_file "$_p" "$_id" "$_nm"; rm -f "$_p"; fi
  done
  if [ -f "$KD/$_id/deny.txt" ]; then backup_file "$KD/$_id/deny.txt" "$_id" deny.txt; rm -f "$KD/$_id/deny.txt"; fi
  loaded_drop "$_id"
  _ver=$(st_get "$_id" 2); _h=$(st_get "$_id" 4)
  [ -n "$_ver" ] || _ver=0.0
  [ -n "$_h" ] || _h=$(printf '%064d' 0)
  st_put "$_id" "$_ver" off "$_h"
}

# ---------- отчёт на сайт: только id, версия, статус, время ----------
# report_body <файл>: тело запроса 1 по строкам состояния (до 16 пакетов). Статусы берутся из LSTAT_<id>, если заданы файлом $TMPD/lstat («id статус»), иначе из state.txt
report_body() {
  _first=1
  _out='{"plugin_version":"'$(plugin_version)'","os":"'$(os_name)'","engine":'$ENGINE_LEVEL',"packages":['
  _cnt=0
  _lines=$(st_lines)
  while IFS=' ' read -r _i _v _s _h _t; do
    [ -n "$_i" ] || continue
    [ "$_cnt" -ge 16 ] && break
    _cnt=$((_cnt + 1))
    [ "$_first" = 1 ] || _out="$_out,"
    _first=0
    _out="$_out"'{"id":"'$_i'","version":"'$_v'","status":"'$_s'","checked_at":"'$_t'"}'
  done <<EOF
$_lines
EOF
  printf '%s]}' "$_out" > "$1"
}
