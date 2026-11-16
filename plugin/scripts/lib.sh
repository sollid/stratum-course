#!/bin/sh
# Общее для connect.sh и step-report.sh (Mac и Linux; нужны sh, curl, sed, awk, tr — всё есть на Mac). Подключается через `.`, не запускается.
# Тайны (device_code, токен) не печатаются, не попадают в аргументы команд (curl читает заголовок со стандартного ввода) и в адрес.
set +x
HERE=$(cd "$(dirname "$0")" && pwd)
TMPD=$(mktemp -d 2>/dev/null || mktemp -d -t course)
trap 'rm -rf "$TMPD"' EXIT
trap 'exit 130' INT TERM

CMD=""; SOFT=0; SHOWONLY=0; ARG2=""
# Уровень движка проверки (тот же, что в check.sh и check.ps1) и предел размера пакета задания в байтах
ENGINE_LEVEL=2
TASK_MAX=262144
O_data=""; O_window=""; O_label=""; O_module=""; O_step=""; O_passed=""; O_reason=""; O_rules=""; O_dir=""; O_checkversion=""

# Параметры в виде: <команда> --имя значение ... --soft (тот же вид, что у PowerShell-варианта)
parse_opts() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --soft) SOFT=1; shift ;;
      --show-only) SHOWONLY=1; shift ;;
      --data|--window|--label|--module|--step|--passed|--reason|--rules|--dir|--check-version)
        _n=$1; _v=""
        if [ $# -ge 2 ] && [ "${2#--}" = "$2" ]; then _v=$2; shift 2; else shift; fi
        case "$_n" in
          --data) O_data=$_v ;; --window) O_window=$_v ;; --label) O_label=$_v ;; --module) O_module=$_v ;;
          --step) O_step=$_v ;; --passed) O_passed=$_v ;; --reason) O_reason=$_v ;; --rules) O_rules=$_v ;;
          --dir) O_dir=$_v ;; --check-version) O_checkversion=$_v ;;
        esac ;;
      --*) shift ;;
      *) if [ -z "$CMD" ]; then CMD=$1; elif [ -z "$ARG2" ]; then ARG2=$1; fi; shift ;;
    esac
  done
}

finish() { if [ "$SOFT" = 1 ]; then exit 0; else exit "$1"; fi; }

# say <ключ> [имя=значение ...]: текст из messages.txt (общий с PowerShell-вариантом), {имя} заменяется значением
say() {
  _key=$1; shift
  _text=$(sed -n "s/^$_key=//p" "$HERE/messages.txt" | head -n 1 | tr -d '\r')
  # Знак \n из шаблона становится переводом строки до подстановки: значения (например, названия шагов с сайта) обратную косую черту ничего не значат
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

data_dir() {
  _d=$O_data
  case "$_d" in *'${'*) _d="" ;; esac
  [ -z "$_d" ] && _d=${CLAUDE_PLUGIN_DATA:-}
  case "$_d" in *'${'*) _d="" ;; esac
  [ -z "$_d" ] && _d="$HOME/.stratum-course"
  if [ ! -d "$_d" ]; then ( umask 077; mkdir -p "$_d" ); fi
  DATA=$_d
}

site_ok() {
  case "$1" in *'
'*) return 1 ;; esac
  printf '%s' "$1" | grep -Eq '^(https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?|http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?)$'
}

# Настройка адреса: COURSE_SITE_URL, иначе первая строка файла site-url в данных плагина. SITE_STATE: ok | none | bad
site_setting() {
  SITE_STATE=none; SITE_URL=""
  _v=${COURSE_SITE_URL:-}
  if [ -z "$_v" ] && [ -f "$DATA/site-url" ]; then _v=$(head -n 1 "$DATA/site-url" | tr -d '\r'); fi
  [ -z "$_v" ] && return 0
  _v=$(printf '%s' "$_v" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  while [ "${_v%/}" != "$_v" ]; do _v=${_v%/}; done
  if site_ok "$_v"; then SITE_STATE=ok; SITE_URL=$_v; else SITE_STATE=bad; fi
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

# Плоский JSON из файла: строка и число по имени ключа
jstr() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -n 1; }
jnum() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$1" | head -n 1; }
# Значение по ключу из файла «ключ=значение»: ключ сравнивается как строка (в программу sed и в регулярное выражение он не попадает)
kv() { awk -v k="$2" 'index($0, k "=") == 1 { sub(/\r$/, ""); print substr($0, length(k) + 2); exit }' "$1" 2>/dev/null; }
# Тип правила с данным id в файле правил (id уже проверен по ^[A-Za-z0-9_-]{1,40}$, поэтому в регулярное выражение он попасть может только безопасным)
rule_type() { awk -v id="$2" '{ sub(/\r$/, "") } match($0, "\"id\": *\"" id "\"") && match($0, /"type": *"[^"]*"/) { s = substr($0, RSTART, RLENGTH); sub(/^"type": *"/, "", s); sub(/"$/, "", s); print s; exit }' "$1" 2>/dev/null; }
# Код причины по умолчанию у новых типов правил (если в файле причин для правила кода нет). У прежних типов кода по умолчанию нет
default_reason() {
  case "$(rule_type "$1" "$2")" in
    contains_text) printf 'text_missing' ;;
    file_absent) printf 'file_present' ;;
    min_items) printf 'too_few_items' ;;
    answer) printf 'answer_mismatch' ;;
    no_placeholder) printf 'placeholder_left' ;;
  esac
}

# post <путь> <файл с телом> [токен] -> HTTP_STATUS (0 — сайт не ответил), HTTP_RETRY (секунды из Retry-After или 0), ответ в $TMPD/resp.
# Токен curl получает со стандартного ввода (config), а не в аргументах. Первый аргумент -q: ~/.curlrc не читается (там мог бы стоять insecure или location-trusted).
# Перенаправления не выполняются (нет -L, --max-redirs 0).
post() {
  : > "$TMPD/resp"; rm -f "$TMPD/hdr"
  if [ -n "$3" ]; then
    HTTP_STATUS=$(printf 'header = "Authorization: Bearer %s"\n' "$3" | curl -q -s -K - --max-redirs 0 --max-time 15 --connect-timeout 8 --max-filesize 65536 -A stratum-course-plugin -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' --data-binary "@$2" -o "$TMPD/resp" -D "$TMPD/hdr" -w '%{http_code}' "$SITE$1" 2>/dev/null)
  else
    HTTP_STATUS=$(curl -q -s --max-redirs 0 --max-time 15 --connect-timeout 8 --max-filesize 65536 -A stratum-course-plugin -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' --data-binary "@$2" -o "$TMPD/resp" -D "$TMPD/hdr" -w '%{http_code}' "$SITE$1" 2>/dev/null)
  fi
  case "$HTTP_STATUS" in [0-9][0-9][0-9]) ;; *) HTTP_STATUS=000 ;; esac
  [ "$HTTP_STATUS" = 000 ] && HTTP_STATUS=0
  HTTP_RETRY=0
  _r=$(sed -n 's/^[Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$TMPD/hdr" 2>/dev/null | tail -n 1)
  if is_num "$_r"; then
    HTTP_RETRY=$_r
    [ "$HTTP_RETRY" -lt 1 ] && HTTP_RETRY=1
    [ "$HTTP_RETRY" -gt 120 ] && HTTP_RETRY=120
  fi
  return 0
}

# Файл, который открывает только владелец: создаётся с режимом 600 (umask 077), затем chmod 600 и замена целевого файла. Содержимое — со стандартного ввода.
secure_write() {
  _tmp="$1.tmp"
  # Временный файл создаётся заново: подложенная ссылка (в том числе жёсткая) на этом имени стирается, запись идёт в новый файл (noclobber не открывает существующий)
  rm -f "$_tmp"
  ( umask 077; set -C; cat > "$_tmp" ) || return 1
  chmod 600 "$_tmp" || return 1
  mv -f "$_tmp" "$1"
}

# Текст для строки JSON: без кавычек, обратной косой черты и управляющих знаков, без пробелов по краям, не больше $2 знаков (знак — символ UTF-8, а не байт)
json_text() {
  printf '%s' "$1" | sed 's/["\\]/ /g' | LC_ALL=C tr -d '\000-\037\177' | LC_ALL=C awk -v max="$2" '
    function cut(s, m,   i, n, c, chars) {
      chars = 0; n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (!(c >= "\200" && c < "\300")) { chars++; if (chars > m) return substr(s, 1, i - 1) }
      }
      return s
    }
    { s = s $0 }
    END { sub(/^ +/, "", s); sub(/ +$/, "", s); s = cut(s, max); sub(/ +$/, "", s); printf "%s", s }'
}

os_label() {
  case "$(os_name)" in mac) printf 'Mac' ;; windows) printf 'Windows' ;; *) printf 'Linux' ;; esac
}

# Подпись устройства для карточки на сайте: имя компьютера без имени пользователя и без путей, до 40 знаков (то же правило, что в lib.ps1).
# Источник: --label, затем COURSE_DEVICE_LABEL, затем имя компьютера. Имя пользователя вырезается везде; если ничего не осталось — название системы.
device_label() {
  _raw=$O_label
  [ -z "$_raw" ] && _raw=${COURSE_DEVICE_LABEL:-}
  if [ -z "$_raw" ]; then
    case "$(uname -s)" in
      Darwin) _raw=$(scutil --get ComputerName 2>/dev/null || hostname -s 2>/dev/null) ;;
      *) _raw=$(hostname 2>/dev/null) ;;
    esac
  fi
  _user=${USER:-${USERNAME:-$(id -un 2>/dev/null)}}
  _lab=$(printf '%s' "$_raw" | LC_ALL=C tr -d '\000-\037\177' | sed 's#[&|\/"`$<>;{}*~]# #g; s#\[# #g; s#\]# #g' | LC_ALL=C awk -v u="$_user" '
    function edge(c) { return c == " " || c == "." || c == "_" || c == "-" || c == "\047" }
    { s = s $0 }
    END {
      lu = tolower(u)
      if (length(u) >= 3) {
        while ((i = index(tolower(s), lu)) > 0) {
          rest = substr(s, i + length(u))
          if (substr(rest, 1, 2) == "\047s") rest = substr(rest, 3)
          else if (substr(rest, 1, 4) == "\342\200\231s") rest = substr(rest, 5)
          s = substr(s, 1, i - 1) " " rest
        }
      }
      if (tolower(substr(s, length(s) - 5)) == ".local") s = substr(s, 1, length(s) - 6)
      gsub(/ +/, " ", s)
      while (length(s) > 0 && edge(substr(s, 1, 1))) s = substr(s, 2)
      while (length(s) > 0 && edge(substr(s, length(s), 1))) s = substr(s, 1, length(s) - 1)
      printf "%s", s }')
  _lab=$(json_text "$_lab" 40)
  _lab=$(printf '%s' "$_lab" | sed "s/^[ ._'-]*//; s/[ ._'-]*\$//")
  [ -z "$_lab" ] && _lab=$(os_label)
  printf '%s' "$_lab"
}

# ---------- проверка работы и код причины (общее для step-report.sh и next.sh) ----------

# check_run <правила> <папка> -> CK_OUT (вывод проверки), CK_CODE (код выхода), CK_VERDICT (accepted|almost|disputed|failed или пусто), CK_NEWER (1 — правила новее плагина)
check_run() {
  CK_OUT=$(sh "$HERE/check.sh" --rules "$1" --dir "$2" 2>"$TMPD/err") && CK_CODE=0 || CK_CODE=$?
  CK_VERDICT=$(printf '%s\n' "$CK_OUT" | sed -En 's/^verdict: (accepted|almost|disputed|failed)[[:space:]]*$/\1/p' | head -n 1)
  CK_NEWER=0
  if [ "$CK_CODE" = 2 ] && grep -q "newer than this plugin" "$TMPD/err" 2>/dev/null; then CK_NEWER=1; fi
  return 0
}

# reason_code <правила> <файл причин> <вывод проверки> <вердикт>: код причины первого невыполненного правила, строгость которого равна вердикту (пусто, если кода нет).
# Порядок правил в файле значим: так плагин и сайт одинаково понимают «спорно» (RULES.md).
# Идентификатор правила из вывода проверки допускается только вида ^[A-Za-z0-9_-]{1,40}$, иначе пропускается; имена файлов по знаку * не раскрываются.
# Код берётся из файла причин; если для правила кода там нет, у новых типов правил есть код по умолчанию (см. default_reason)
reason_code() {
  case "$4" in almost|disputed|failed) ;; *) return 0 ;; esac
  set -f
  for _rid in $(printf '%s\n' "$3" | sed -En "s/^([^:]+): $4 - .*\$/\\1/p"); do
    case "$_rid" in ''|*[!A-Za-z0-9_-]*) continue ;; esac
    [ "${#_rid}" -le 40 ] || continue
    _rs=""
    if [ -n "$2" ] && [ -f "$2" ]; then _rs=$(kv "$2" "$_rid"); fi
    [ -n "$_rs" ] || _rs=$(default_reason "$1" "$_rid")
    if [ -n "$_rs" ]; then printf '%s' "$_rs"; return 0; fi
  done
  return 0
}

# Главный файл из файла правил (как его читает check.sh)
rules_file_field() { awk '{ sub(/\r$/, "") } !/"type":/ && match($0, /"file": *"[^"]*"/) { s = substr($0, RSTART, RLENGTH); sub(/^"[^"]*": */, "", s); print substr(s, 2, length(s) - 2); exit }' "$1" 2>/dev/null; }

# ---------- состояние курса в данных плагина (файл course-state.txt: строки «ключ=значение»; права как у файла токена) ----------
# workdir — путь учебной папки; shown — «модуль/шаг», задание которого уже показывалось; disputed — «модуль/шаг», ждущие куратора (их правила лежат в steps/)
state_values() { awk -v k="$1" 'index($0, k "=") == 1 { sub(/\r$/, ""); print substr($0, length(k) + 2) }' "$STATE" 2>/dev/null; }
state_has() { state_values "$1" | grep -Fxq -- "$2"; }
state_put() { state_has "$1" "$2" && return 0; { cat "$STATE" 2>/dev/null; printf '%s=%s\n' "$1" "$2"; } | secure_write "$STATE"; }
state_set() { { awk -v k="$1" 'index($0, k "=") != 1' "$STATE" 2>/dev/null; printf '%s=%s\n' "$1" "$2"; } | secure_write "$STATE"; }
state_drop() { K="$1" V="$2" awk 'BEGIN { l = ENVIRON["K"] "=" ENVIRON["V"] } $0 != l' "$STATE" 2>/dev/null | secure_write "$STATE"; }

# text_hidden <текст>: 0, если в тексте есть невидимые и управляющие знаки (как в разборе пакета: C0 без табуляции, DEL, C1, нулевой ширины, направления текста,
# разделители строк и абзацев, метка порядка байтов, знаки-теги)
text_hidden() {
  printf '%s\n' "$1" | LC_ALL=C awk '{ s = $0; if (s ~ /[\001-\010\013-\037\177]/ || s ~ /\302[\200-\237]/ || s ~ /\342\200[\213-\217\250-\256]/ || s ~ /\342\201[\240-\251]/ || s ~ /\330\234/ || s ~ /\357\273\277/ || s ~ /\363\240[\200\201][\200-\277]/) f = 1 } END { exit f ? 0 : 1 }'
}

# text_symbols <текст>: 0, если среди байтов UTF-8 есть знаки препинания и символы (кавычки «» “ ” „, тире, знаки валют и математики, стрелки, эмодзи, знаки CJK и полной ширины).
# sh не умеет различать буквы всех языков, поэтому исключает блоки знаков, а остальные байты >= 0x80 считает буквами; PowerShell проверяет свойства букв Юникода точно.
text_symbols() {
  printf '%s\n' "$1" | LC_ALL=C awk '{ s = $0; if (s ~ /\302[\200-\277]/ || s ~ /\303\227/ || s ~ /\303\267/ || s ~ /\342[\200-\257]/ || s ~ /\342[\270-\271]/ || s ~ /\343\200[\200-\277]/ || s ~ /\357\274[\200-\217]/ || s ~ /\360\237/) f = 1 } END { exit f ? 0 : 1 }'
}

# state_switch_workdir <путь>: запоминает путь учебной папки; если папка сменилась, показанные и спорные шаги прежней забываются (их правила и файлы относились к ней)
state_switch_workdir() {
  _old=$(state_values workdir | head -n 1)
  [ "$_old" = "$1" ] && return 0
  if [ -n "$_old" ]; then awk 'index($0, "shown=") != 1 && index($0, "disputed=") != 1' "$STATE" 2>/dev/null | secure_write "$STATE"; fi
  state_set workdir "$1"
}

# acquire_lock: замок каталогом .lock в папке данных на время запуска (два окна Claude Code не теряют записи состояния друг у друга).
# Замок старше 10 минут считается забытым и снимается; занят — прямая фраза и код 19. Замок снимается при любом выходе.
acquire_lock() {
  LOCK="$DATA/.lock"
  if ! mkdir "$LOCK" 2>/dev/null; then
    if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
      rmdir "$LOCK" 2>/dev/null
      mkdir "$LOCK" 2>/dev/null || fail 19 course.busy
    else
      fail 19 course.busy
    fi
  fi
  trap 'rm -rf "$TMPD"; rmdir "$LOCK" 2>/dev/null' EXIT
}

# Метка учебной папки: обычный файл .stratum-course (не ссылка) с первой строкой «stratum-course-folder 1». Её ставит /course:start
is_course_dir() {
  _mf="$1/.stratum-course"
  [ -d "$1" ] && [ -f "$_mf" ] && [ ! -L "$_mf" ] && [ "$(head -n 1 "$_mf" 2>/dev/null | tr -d '\r')" = "stratum-course-folder 1" ]
}

# Номер модуля для заголовка: цифры из его названия (m1 -> 1)
module_number() { _mn=$(printf '%s' "$1" | sed 's/^[^0-9]*//'); [ -n "$_mn" ] || _mn=$1; printf '%s' "$_mn"; }

# ---------- задание шага: запрос, разбор пакета, стартовые файлы ----------

# post_task <файл с телом> <токен> -> HTTP_STATUS (0 — сайт не ответил), TASK_BIG (1 — ответ больше предела), ответ в $TMPD/task.
# Токен curl получает со стандартного ввода (config), а не в аргументах; перенаправления не выполняются; читается не больше TASK_MAX байт.
post_task() {
  : > "$TMPD/task"; rm -f "$TMPD/hdr"; TASK_BIG=0
  HTTP_STATUS=$(printf 'header = "Authorization: Bearer %s"\n' "$2" | curl -q -s -K - --max-redirs 0 --max-time 15 --connect-timeout 8 --max-filesize "$TASK_MAX" -A stratum-course-plugin -X POST -H 'Content-Type: application/json' -H 'Accept: text/plain' --data-binary "@$1" -o "$TMPD/task" -D "$TMPD/hdr" -w '%{http_code}' "$SITE/api/plugin/task" 2>/dev/null)
  _rc=$?
  case "$HTTP_STATUS" in [0-9][0-9][0-9]) ;; *) HTTP_STATUS=000 ;; esac
  [ "$HTTP_STATUS" = 000 ] && HTTP_STATUS=0
  # curl 63: ответ больше предела (заголовки пришли, значит сайт отвечал)
  if [ "$_rc" = 63 ]; then TASK_BIG=1; [ "$HTTP_STATUS" = 0 ] && HTTP_STATUS=200; fi
  _sz=$(wc -c < "$TMPD/task" | tr -d ' ')
  [ "${_sz:-0}" -gt "$TASK_MAX" ] && TASK_BIG=1
  return 0
}

# parse_package <файл> -> PKG_ERR: пусто (пакет верен), version (другая версия формата), start (стартовый файл не по правилам), format (всё остальное).
# Ничего не пишет вне временной папки $TMPD/pkg: разобранные части лежат там (head.txt, task, rules, reasons, start.<n>, start.list).
# Проверки: размер, нет NUL и CR, текст кончается переводом строки, первая строка stratum-task 1, шапка (ключи, значения, обязательные поля, повторов нет),
# границы частей, виды и число частей, корректный UTF-8, правила пути и размер стартовых файлов (путь по договору: плагин сайту не доверяет).
parse_package() {
  PKG_ERR=format
  rm -rf "$TMPD/pkg"; mkdir "$TMPD/pkg" || return 0
  _sz=$(wc -c < "$1" | tr -d ' ')
  { [ "${_sz:-0}" -gt 0 ] && [ "$_sz" -le "$TASK_MAX" ]; } || return 0
  [ "$(LC_ALL=C tr -d '\000\r' < "$1" | wc -c | tr -d ' ')" = "$_sz" ] || return 0
  [ "$(tail -c 1 "$1" | wc -l | tr -d ' ')" = 1 ] || return 0
  _r=$(LC_ALL=C awk -v out="$TMPD/pkg" '
function bad(tag) { print "ERR " tag; failed = 1; exit 1 }
function hidden(s) {
  # управляющие знаки (кроме перевода строки и табуляции), DEL, C1, нулевой ширины, направления текста, разделители строк и абзацев, метка порядка байтов, знаки-теги U+E0000-E007F
  return (s ~ /[\001-\010\013-\037\177]/ || s ~ /\302[\200-\237]/ || s ~ /\342\200[\213-\217\250-\256]/ || s ~ /\342\201[\240-\251]/ || s ~ /\330\234/ || s ~ /\357\273\277/ || s ~ /\363\240[\200\201][\200-\277]/)
}
function utf8ok(s) {
  return (s ~ /^([\001-\177]|[\302-\337][\200-\277]|\340[\240-\277][\200-\277]|[\341-\354\356\357][\200-\277][\200-\277]|\355[\200-\237][\200-\277]|\360[\220-\277][\200-\277][\200-\277]|[\361-\363][\200-\277][\200-\277][\200-\277]|\364[\200-\217][\200-\277][\200-\277])*$/)
}
function seg_ok(s) { return (s ~ /^[A-Za-z0-9_-][A-Za-z0-9._-]*$/) }
function reserved(s,   b, i) { b = toupper(s); i = index(b, "."); if (i > 0) b = substr(b, 1, i - 1); return (b ~ /^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$/) }
function start_ok(p,   n, a, i, base, low) {
  if (length(p) < 1 || length(p) > 120) return 0
  n = split(p, a, "/")
  if (n > 4) return 0
  for (i = 1; i <= n; i++) { if (!seg_ok(a[i]) || a[i] ~ /\.$/ || reserved(a[i])) return 0 }
  base = a[n]
  if (base !~ /\.(md|txt)$/) return 0
  low = tolower(base)
  if (low == "claude.md" || low == "claude.local.md" || low == "agents.md") return 0
  return 1
}
function main_ok(p,   n, a, i) {
  if (length(p) < 1 || length(p) > 120) return 0
  n = split(p, a, "/")
  if (n > 4) return 0
  for (i = 1; i <= n; i++) { if (a[i] !~ /^[A-Za-z0-9._-]+$/ || a[i] == "." || a[i] == "..") return 0 }
  return 1
}
function num(v, m) { return (v ~ /^[0-9]+$/ && length(v) <= m) }
function ident(v) { return (v ~ /^[a-z0-9]+$/ && length(v) <= 10) }
function title(v) { return (length(v) >= 1 && length(v) <= 300) }
function check_head(   st) {
  st = H["state"]
  if (!(H["boundary"] ~ /^[0-9a-f]+$/ && length(H["boundary"]) == 32)) bad("format")
  if (!num(H["waiting"], 4)) bad("format")
  if (st == "done") return
  if (st != "step") bad("format")
  if (!ident(H["module"]) || !ident(H["step"])) bad("format")
  if (!title(H["module_title"]) || !title(H["step_title"])) bad("format")
  if (!num(H["number"], 3) || !num(H["of"], 3)) bad("format")
  if (!main_ok(H["file"])) bad("format")
  if (!num(H["check_version"], 2) || !num(H["min_engine"], 2) || H["check_version"] != H["min_engine"] || H["check_version"] + 0 < 1) bad("format")
  if (("story_path" in H) && H["story_path"] !~ /^\/[A-Za-z0-9\/_-]+$/) bad("format")
}
NR == 1 {
  if ($0 != "stratum-task 1") { if ($0 ~ /^stratum-task [0-9]+$/) bad("version"); bad("format") }
  mode = "head"; next
}
mode == "head" {
  if ($0 == "") { check_head(); mode = "body"; pre = "--" H["boundary"]; next }
  i = index($0, "=")
  if (i < 2) bad("format")
  k = substr($0, 1, i - 1); v = substr($0, i + 1)
  if (k !~ /^[a-z_]+$/ || v ~ /[\001-\037\177]/ || length(v) > 300 || (k in H)) bad("format")
  if (v ~ /[\200-\377]/ && !utf8ok(v)) bad("format")
  if (hidden(v)) bad("format")
  H[k] = v
  next
}
mode == "ended" { bad("format") }
{
  if (substr($0, 1, length(pre)) == pre) {
    rest = substr($0, length(pre) + 1)
    if (rest == " end") { mode = "ended"; next }
    if (H["state"] == "done") bad("format")
    if (rest ~ /^ (task|rules|reasons)$/) {
      kind = substr(rest, 2)
      if (cnt[kind]++) bad("format")
      cur = out "/" kind; printf "" > cur; size[cur] = 0; curstart = 0; curchk = (kind == "task"); next
    }
    if (rest ~ /^ start [^ ]+$/) {
      p = substr(rest, 8)
      nstart++
      if (nstart > 8 || !start_ok(p) || (tolower(p) in seen) || tolower(p) == tolower(H["file"])) bad("start")
      seen[tolower(p)] = 1
      cur = out "/start." nstart; printf "" > cur; size[cur] = 0; curstart = 1; curchk = 1; spath[nstart] = p; next
    }
    bad("format")
  }
  if (cur == "") bad("format")
  if ($0 ~ /[\200-\377]/ && !utf8ok($0)) bad("format")
  if (curchk && hidden($0)) bad("format")
  size[cur] += length($0) + 1
  if (curstart && size[cur] > 16384) bad("start")
  print $0 > cur
}
END {
  if (failed) exit
  if (mode != "ended") bad("format")
  # путь стартового файла не бывает папкой другого стартового файла (без учёта регистра)
  for (j = 1; j <= nstart; j++) for (q = 1; q <= nstart; q++) if (q != j && index(tolower(spath[q]), tolower(spath[j]) "/") == 1) bad("start")
  if (H["state"] == "done") { if (cnt["task"] + cnt["rules"] + cnt["reasons"] + nstart > 0) bad("format") }
  else {
    if (cnt["task"] != 1 || cnt["rules"] != 1 || cnt["reasons"] != 1) bad("format")
    if (size[out "/task"] < 2 || size[out "/rules"] < 2) bad("format")
  }
  n = split("state lang module step module_title step_title number of file check_version min_engine waiting boundary story_path", keys, " ")
  for (j = 1; j <= n; j++) if (keys[j] in H) print keys[j] "=" H[keys[j]] > (out "/head.txt")
  for (j = 1; j <= nstart; j++) print j "\t" spath[j] > (out "/start.list")
  close(out "/head.txt"); close(out "/start.list")
  print "OK"
}' "$1" 2>/dev/null)
  case "$_r" in
    OK) PKG_ERR="" ;;
    "ERR version") PKG_ERR=version ;;
    "ERR start") PKG_ERR=start ;;
  esac
  return 0
}

# start_path_ok <путь>: путь стартового файла по договору (те же проверки, что у разбора пакета в parse_package): 1–4 части из букв, цифр, . _ -, часть не начинается с точки
# и не кончается точкой, не имя устройства Windows; расширение .md или .txt; имя без учёта регистра не CLAUDE.md и не AGENTS.md; до 120 знаков
start_path_ok() {
  printf '%s' "$1" | LC_ALL=C grep -Eq '^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*){0,3}$' || return 1
  [ "${#1}" -le 120 ] || return 1
  case "$1" in *.md|*.txt) ;; *) return 1 ;; esac
  _sb=${1##*/}
  case "$(printf '%s' "$_sb" | LC_ALL=C tr 'A-Z' 'a-z')" in claude.md|claude.local.md|agents.md) return 1 ;; esac
  _pr=$1
  while :; do
    _seg=${_pr%%/*}
    case "$_seg" in *.) return 1 ;; esac
    case "$(printf '%s' "${_seg%%.*}" | LC_ALL=C tr 'a-z' 'A-Z')" in CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9]) return 1 ;; esac
    case "$_pr" in */*) _pr=${_pr#*/} ;; *) break ;; esac
  done
  return 0
}

# place_start_file <учебная папка> <путь> <файл с содержимым>: кладёт один стартовый файл. Возвращает 0, если файл на месте (положен или уже был обычным файлом человека), 1 — не удалось.
# Каждая папка на пути должна быть настоящей папкой внутри учебной (не ссылкой); нет — создаётся (и проверяется ещё раз). Существующий файл не перезаписывается.
# Ссылка (в том числе висячая) или не-файл на месте файла — отказ. Запись идёт с noclobber (создание без перезаписи, через ссылку не пишется).
place_start_file() {
  _base=$1; _rest=$2; _src=$3
  start_path_ok "$_rest" || return 1
  [ -d "$_base" ] || return 1
  _cur=$_base
  while :; do
    case "$_rest" in
      */*)
        _comp=${_rest%%/*}; _rest=${_rest#*/}
        _cur="$_cur/$_comp"
        [ -L "$_cur" ] && return 1
        if [ -e "$_cur" ]; then
          [ -d "$_cur" ] || return 1
        else
          mkdir "$_cur" 2>/dev/null || return 1
          [ -L "$_cur" ] && return 1
          [ -d "$_cur" ] || return 1
        fi ;;
      *) break ;;
    esac
  done
  _file="$_cur/$_rest"
  [ -L "$_file" ] && return 1
  if [ -e "$_file" ]; then
    [ -f "$_file" ] && return 0
    return 1
  fi
  ( set -C; cat "$_src" > "$_file" ) 2>/dev/null || return 1
  [ -f "$_file" ] && [ ! -L "$_file" ]
}
