#!/bin/sh
# Общее для connect.sh и step-report.sh (Mac и Linux; нужны sh, curl, sed, awk, tr — всё есть на Mac). Подключается через `.`, не запускается.
# Тайны (device_code, токен) не печатаются, не попадают в аргументы команд (curl читает заголовок со стандартного ввода) и в адрес.
set +x
HERE=$(cd "$(dirname "$0")" && pwd)
TMPD=$(mktemp -d 2>/dev/null || mktemp -d -t course)
trap 'rm -rf "$TMPD"' EXIT
trap 'exit 130' INT TERM

CMD=""; SOFT=0
O_data=""; O_window=""; O_label=""; O_module=""; O_step=""; O_passed=""; O_reason=""; O_rules=""; O_dir=""; O_checkversion=""

# Параметры в виде: <команда> --имя значение ... --soft (тот же вид, что у PowerShell-варианта)
parse_opts() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --soft) SOFT=1; shift ;;
      --data|--window|--label|--module|--step|--passed|--reason|--rules|--dir|--check-version)
        _n=$1; _v=""
        if [ $# -ge 2 ] && [ "${2#--}" = "$2" ]; then _v=$2; shift 2; else shift; fi
        case "$_n" in
          --data) O_data=$_v ;; --window) O_window=$_v ;; --label) O_label=$_v ;; --module) O_module=$_v ;;
          --step) O_step=$_v ;; --passed) O_passed=$_v ;; --reason) O_reason=$_v ;; --rules) O_rules=$_v ;;
          --dir) O_dir=$_v ;; --check-version) O_checkversion=$_v ;;
        esac ;;
      --*) shift ;;
      *) [ -z "$CMD" ] && CMD=$1; shift ;;
    esac
  done
}

finish() { if [ "$SOFT" = 1 ]; then exit 0; else exit "$1"; fi; }

# say <ключ> [имя=значение ...]: текст из messages.txt (общий с PowerShell-вариантом), {имя} заменяется значением
say() {
  _key=$1; shift
  _text=$(sed -n "s/^$_key=//p" "$HERE/messages.txt" | head -n 1 | tr -d '\r')
  for _kv in "$@"; do
    _k=${_kv%%=*}; _v=${_kv#*=}
    # Подстановка без sed: значение идёт через окружение и сравнивается как строка, поэтому знаки & | / и обратная косая в нём ничего не значат
    _text=$(printf '%s' "$_text" | K="{$_k}" V="$_v" awk '{ s = $0; k = ENVIRON["K"]; v = ENVIRON["V"]; out = ""; while ((i = index(s, k)) > 0) { out = out substr(s, 1, i - 1) v; s = substr(s, i + length(k)) } print out s }')
  done
  printf '%b\n' "$_text"
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
