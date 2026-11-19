#!/bin/sh
# Набор команды, Mac и Linux (sh + curl + awk). То же поведение и вывод, что у kit.ps1.
#   kit.sh install|update|check|list [--data <папка>] [--probe true] [--flat true] [--soft] [--background]
#   kit.sh off <id> | on <id> [--data <папка>] [--soft]
#   kit.sh hook loaded|deny|start      (хуки: выключены, пока сборка без хуков и настройка probe_hooks не true)
# Что делает: ставит пакеты правил с сайта (по токену устройства, привязанного плагином курса) в ~/.claude/rules/stratum/<id>/, показывает, что стоит, выключает и включает пакет.
# Запросов к сайту: install — до трёх POST (отчёт и список, пакеты одним запросом, итоговый отчёт), update и on — так же, check, off — один.
# Пакет, не прошедший проверку (имя, размер, хеш, число частей, знаки), на диск не пишется. Чужой файл на нужном месте не перезаписывается.
# Коды выхода: 0 готово; 10 сайт не ответил; 11 привязать заново; 12 неверное имя пакета; 13 такого пакета нет; 14 адрес сайта в настройках не тот; 15 нужен более новый плагин;
#   16 ответ сайта не по формату; 17 часть пакетов не поставлена; 18 пакет вернуть нельзя; 19 уже идёт другой запуск; 20 плохой адрес сайта в файле токена; 21 сайт не знает такой пакет;
#   22 на сайте выключено; 23 сайт в режиме показа; 24 неожиданный ответ сайта; 25 записать не удалось; 26 несколько привязок курса; 27 awk считает не байты (только sh); 40 устройство не привязано.
# --soft: всегда код 0 (для строки внутри навыка). --background: тихо, не чаще раза в 24 часа, всегда код 0.
. "$(dirname "$0")/lib.sh"

parse_opts "$@"
data_dir
settings
rules_root
[ "$BG" = 1 ] && QUIET=1

case "$CMD" in
  install|update|check|list|off|on|hook) ;;
  *) echo "usage: kit.sh install|update|check|list|off <id>|on <id>|hook <name> [--data <dir>] [--soft]" >&2; exit 2 ;;
esac

# Разбор ответов стоит на байтах (LC_ALL=C awk): если awk этого компьютера считает знаки, каждый пакет с кириллицей будет «не по формату» (на Mac проверка нужна, как у курса)
if [ "$CMD" != hook ]; then
  _awklen=$(printf '\321\217\n' | LC_ALL=C awk '{ print length($0) }' 2>/dev/null)
  [ "$_awklen" = 2 ] || fail 27 kit.awkbytes "value=$_awklen"
fi

# ---------- хуки (отдельно от команд: без замка, без сети, кроме start) ----------

# Значение строки JSON по имени ключа (первый ключ с таким именем вне строк); экранирование \\ \" \/ \n \t \r \b \f и \u00XX разбирается, прочее \uXXXX заменяется знаком «?»
json_get() { # <ключ> со стандартного ввода
  LC_ALL=C awk -v key="$1" '
  function hex(c) { return index("0123456789abcdef", tolower(c)) - 1 }
  BEGIN { RS = "\001"; ORS = "" }
  {
    s = $0; gsub(/\n/, " ", s); n = length(s); i = 1
    while (i <= n) {
      c = substr(s, i, 1)
      if (c != "\"") { i++; continue }
      # строка: читаем до закрывающей кавычки
      i++; str = ""
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\\") {
          d = substr(s, i + 1, 1); i += 2
          if (d == "n") str = str "\n"; else if (d == "t") str = str "\t"; else if (d == "r") str = str "\r"
          else if (d == "b") str = str "\010"; else if (d == "f") str = str "\014"
          else if (d == "u") {
            h = substr(s, i, 4); i += 4
            v = hex(substr(h, 1, 1)) * 4096 + hex(substr(h, 2, 1)) * 256 + hex(substr(h, 3, 1)) * 16 + hex(substr(h, 4, 1))
            if (h ~ /^[0-9A-Fa-f]+$/ && v >= 32 && v < 127) str = str sprintf("%c", v); else str = str "?"
          } else str = str d
          continue
        }
        if (c == "\"") { i++; break }
        str = str c; i++
      }
      # ключ, если дальше двоеточие
      j = i; while (j <= n && substr(s, j, 1) == " ") j++
      if (substr(s, j, 1) == ":") {
        j++; while (j <= n && substr(s, j, 1) == " ") j++
        if (str == key && substr(s, j, 1) == "\"") {
          # значение-строка: читаем так же
          i = j + 1; val = ""
          while (i <= n) {
            c = substr(s, i, 1)
            if (c == "\\") {
              d = substr(s, i + 1, 1); i += 2
              if (d == "n") val = val "\n"; else if (d == "t") val = val "\t"; else if (d == "r") val = val "\r"
              else if (d == "b") val = val "\010"; else if (d == "f") val = val "\014"
              else if (d == "u") {
                h = substr(s, i, 4); i += 4
                v = hex(substr(h, 1, 1)) * 4096 + hex(substr(h, 2, 1)) * 256 + hex(substr(h, 3, 1)) * 16 + hex(substr(h, 4, 1))
                if (h ~ /^[0-9A-Fa-f]+$/ && v >= 32 && v < 127) val = val sprintf("%c", v); else val = val "?"
              } else val = val d
              continue
            }
            if (c == "\"") break
            val = val c; i++
          }
          print val; exit
        }
      }
    }
  }'
}

# Поиск запрета: один проход awk по файлу запретов пакета. Печатает первую сработавшую строку (пусто — не сработал). Цель и инструмент идут через окружение (T, TOOL).
# Строки не по формату (инструмент не из Read, Edit, Write, Bash; нет образца; больше 200 знаков; управляющие знаки; сверх 60 строк) пропускаются.
# Сопоставление (правила приняты ведущей 16.11, предложено сессией, можно оспорить): только * (любая последовательность знаков, в том числе / и \); все прочие знаки, и ? тоже, — сами собой;
# регистр не важен (только латинские A-Z); файловые инструменты — путь с заменой \ на /: образец без / сравнивается с именем файла, с / — со всем путём; Bash — образец со всей командой.
# Это договорённость плагина, а не граница безопасности. Сравнение по байтам (в PowerShell строки перед сравнением переводятся в байты).
deny_find() { # <файл запретов>
  T="$TARGET" TOOL="$TOOLCLASS" LC_ALL=C awk '
  function gm(p, s,   pi, si, star, mark, pl, sl, pc) {
    pl = length(p); sl = length(s); pi = 1; si = 1; star = 0; mark = 0
    while (si <= sl) {
      pc = substr(p, pi, 1)
      if (pi <= pl && pc == "*") { star = pi; mark = si; pi++ }
      else if (pi <= pl && pc == substr(s, si, 1)) { pi++; si++ }
      else if (star) { pi = star + 1; mark++; si = mark }
      else return 0
    }
    while (pi <= pl && substr(p, pi, 1) == "*") pi++
    return pi > pl
  }
  function deny_bad(l,   sp, p, q) {
    if (length(l) > 200 || length(l) < 3 || l !~ /^(Read|Edit|Write|Bash) [^ ]/) return 1
    if (l ~ /[^ -~]/) return 1
    if (index(l, "[") || index(l, "]") || index(l, "\\") || index(l, "`") || index(l, "?")) return 1
    sp = index(l, " "); p = substr(l, sp + 1); q = p; gsub(/[* ]/, "", q)
    return (length(q) < 3)
  }
  BEGIN {
    tool = ENVIRON["TOOL"]; t = ENVIRON["T"]
    if (tool != "Bash") gsub(/\\/, "/", t)
    lt = tolower(t); base = lt; k = 0
    for (i = length(lt); i >= 1; i--) if (substr(lt, i, 1) == "/") { k = i; break }
    if (k > 0) base = substr(lt, k + 1)
  }
  {
    sub(/\r$/, "")
    n++; if (n > 60) exit
    if (deny_bad($0)) next
    sp = index($0, " "); lt2 = substr($0, 1, sp - 1); pat = tolower(substr($0, sp + 1))
    if (lt2 != tool) next
    if (tool == "Bash") s = lt; else if (index(pat, "/") > 0) s = lt; else s = base
    if (gm(pat, s)) { print $0; exit }
  }' "$1"
}


json_escape() { printf '%s' "$1" | LC_ALL=C awk 'BEGIN { ORS = "" } { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); print }'; }

hook_loaded() {
  [ "$PROBE" = 1 ] || exit 0
  _in=$(head -c 65536 | tr '\n' ' ')
  _fp=$(printf '%s' "$_in" | json_get file_path | tr '\\' '/')
  _mt=$(printf '%s' "$_in" | json_get memory_type)
  _lr=$(printf '%s' "$_in" | json_get load_reason)
  [ "$_mt" = User ] || exit 0
  # Перевод строки и возврат каретки — отказ до grep (он смотрит строки по одной): так же, как у PowerShell-варианта (`\z`)
  case "$_lr" in
    *'
'*) exit 0 ;;
  esac
  case "$_lr" in *"$(printf '\r')"*) exit 0 ;; esac
  printf '%s' "$_lr" | grep -Eq '^[a-z_]{1,30}$' || exit 0
  case "$_fp" in */rules/stratum/*|*/rules/stratum-*) ;; *) exit 0 ;; esac
  [ "${#_fp}" -le 500 ] || exit 0
  printf '%s' "$_fp" | LC_ALL=C grep -q '[[:cntrl:]]' && exit 0
  ( umask 077; printf '%s %s %s\n' "$(now)" "$_lr" "$_fp" >> "$KD/loaded.log" ) 2>/dev/null
  # журнал короткий: за 600 строк остаются последние 300
  if [ "$(wc -l < "$KD/loaded.log" 2>/dev/null | tr -d ' ')" -gt 600 ]; then tail -n 300 "$KD/loaded.log" | secure_write "$KD/loaded.log"; fi
  exit 0
}

hook_deny() {
  [ "$PROBE" = 1 ] || exit 0
  _in=$(head -c 262144 | tr '\n' ' ')
  _tn=$(printf '%s' "$_in" | json_get tool_name)
  case "$_tn" in
    Read|Edit|Write) TOOLCLASS=$_tn; TARGET=$(printf '%s' "$_in" | json_get file_path) ;;
    Bash|PowerShell) TOOLCLASS=Bash; TARGET=$(printf '%s' "$_in" | json_get command) ;;
    *) exit 0 ;;
  esac
  [ -n "$TARGET" ] || exit 0
  for _id in $(st_ids); do
    [ "$(st_get "$_id" 3)" = off ] && continue
    [ -f "$KD/$_id/deny.txt" ] || continue
    _hit=$(deny_find "$KD/$_id/deny.txt")
    if [ -n "$_hit" ]; then
      _reason=$(say hook.deny "name=$(pkg_name "$_id")" "rule=$_hit" "id=$_id")
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$(json_escape "$_reason")"
      exit 0
    fi
  done
  exit 0
}

if [ "$CMD" = hook ]; then
  case "$ARG2" in
    loaded) hook_loaded ;;
    deny) hook_deny ;;
    start) [ "$PROBE" = 1 ] || exit 0; CMD=check; BG=1; QUIET=1 ;;
    *) echo "usage: kit.sh hook loaded|deny|start" >&2; exit 2 ;;
  esac
fi

# ---------- токен и адрес сайта ----------

# Нет токена или адреса — прямая фраза (жёстко для install, check, update, on). Токен читается у плагина курса и уходит только в заголовке на записанный с ним адрес
load_token() { # 0 — токен есть; иначе TOKEN_ERR (notpaired | nosite | mismatch)
  TOKEN_ERR=""
  find_course_data
  if [ "$COURSE_MANY" = 1 ]; then TOKEN_ERR=many; return 1; fi
  if [ -z "$COURSE_DATA" ]; then TOKEN_ERR=notpaired; return 1; fi
  TOKEN_FILE="$COURSE_DATA/device-token.txt"
  TOKEN=$(kv "$TOKEN_FILE" token)
  if ! printf '%s' "$TOKEN" | grep -Eq '^[A-Za-z0-9_-]{20,200}$'; then TOKEN_ERR=notpaired; return 1; fi
  SITE=$(kv "$TOKEN_FILE" site)
  if ! site_ok "$SITE"; then TOKEN_ERR=nosite; return 1; fi
  site_setting
  if [ "$SITE_STATE" = ok ] && [ "$SITE_URL" != "$SITE" ]; then TOKEN_ERR=mismatch; return 1; fi
  return 0
}
need_token() {
  load_token && return 0
  case "$TOKEN_ERR" in
    nosite) fail 20 kit.nosite ;;
    mismatch) fail 14 kit.sitemismatch "old=$SITE" "new=$SITE_URL" ;;
    many) fail 26 kit.manycourse ;;
    *) fail 40 kit.notpaired "cmd=/kit:$CMD" ;;
  esac
}

# Отказ запроса: печатает фразу и завершает работу (после post_kit при HTTP_STATUS не 200)
req_fail() {
  case "$HTTP_STATUS" in
    401) [ "$BG" = 1 ] || rm -f "$TOKEN_FILE"; fail 11 kit.rejected "cmd=/kit:$CMD" ;;
    404) fail 22 kit.disabled "site=$SITE" ;;
    422)
      case "$(jstr "$TMPD/resp" error)" in
        unknown_package) fail 21 kit.unknownpkg ;;
        engine) fail 15 kit.updateplugin ;;
      esac
      fail 24 kit.invalid ;;
    503) if [ "$(jstr "$TMPD/resp" error)" = preview ]; then fail 23 kit.preview "site=$SITE"; fi; fail 10 kit.offline "cmd=/kit:$CMD" ;;
    0) [ "$BG" = 1 ] && rm -f "$KD/last-bg"; fail 10 kit.offline "cmd=/kit:$CMD" ;;
    429) fail 10 kit.offline "cmd=/kit:$CMD" ;;
    *) fail 24 kit.unexpected "status=$HTTP_STATUS" ;;
  esac
}

# Запрос 1: отчёт по state.txt и список нового. После вызова — $TMPD/list, LIST_STATE, LIST_TEAM; ошибки завершают работу
request_list() {
  report_body "$TMPD/body1"
  post_kit /api/plugin/kit "$TMPD/body1"
  [ "$HTTP_STATUS" = 200 ] || req_fail
  [ "$BIG" = 0 ] || fail 16 kit.badreply
  parse_list "$TMPD/resp"
  case "$LIST_ERR" in
    '') ;;
    version) fail 15 kit.updateplugin ;;
    *) fail 16 kit.badreply ;;
  esac
}

# Строки списка: «id версия want»
list_get() { # <id> <поле 2|3>
  K="$1" F="$2" awk 'BEGIN { f = ENVIRON["F"] + 0 } $1 == ENVIRON["K"] { print $f; exit }' "$TMPD/list"
}

# Обновляет статусы всех пакетов в state.txt по диску (время — сейчас)
refresh_state() {
  for _id in $(st_ids); do
    local_status "$_id"
    st_put "$_id" "$(st_get "$_id" 2)" "$LS" "$(st_get "$_id" 4)" || fail 25 kit.cantwrite
  done
}

# ---------- показ ----------
show_status() { # id версия статус [последняя версия на сайте]
  _nm=$(pkg_name "$1")
  case "$3" in
    ok)
      if [ -n "$4" ] && ver_lt "$2" "$4"; then say pkg.ok.newer "name=$_nm" "version=$2" "latest=$4"; else say pkg.ok "name=$_nm" "version=$2"; fi ;;
    files) say pkg.files "name=$_nm" "version=$2" ;;
    absent) say pkg.absent "name=$_nm" "version=$2" ;;
    not_loaded) say pkg.notloaded "name=$_nm" "version=$2" ;;
    off) say pkg.off "name=$_nm" "version=$2" "id=$1" ;;
  esac
}

# Итог по каждому пакету списка и по пакетам, которых в списке нет. Результаты запуска — в $TMPD/res («id<TAB>вид<TAB>аргумент»)
show_all() { # режим: all | one <id>
  _only=$1
  _tab=$(printf '\t')
  while IFS=' ' read -r _i _lv _want; do
    [ -n "$_i" ] || continue
    [ -z "$_only" ] || [ "$_only" = "$_i" ] || continue
    _res=$(awk -F '\t' -v k="$_i" '$1 == k { print $2 "\t" $3; exit }' "$TMPD/res" 2>/dev/null)
    _kind=${_res%%"$_tab"*}; _arg=${_res#*"$_tab"}
    _nm=$(pkg_name "$_i")
    _loc=$(st_get "$_i" 3)
    case "$_kind" in
      placed)
        if [ -n "$_arg" ] && [ "$_arg" != "$(st_get "$_i" 2)" ]; then say pkg.updated "name=$_nm" "version=$(st_get "$_i" 2)" "old=$_arg"; else say pkg.ok "name=$_nm" "version=$(st_get "$_i" 2)"; fi ;;
      removed) say pkg.teamoff "name=$_nm" ;;
      occupied) say pkg.occupied "name=$_nm" "version=$_lv" "path=$_arg" ;;
      cantwrite) say pkg.cantwrite "name=$_nm" "version=$_lv" ;;
      bad) say "pkg.bad.$_arg" "name=$_nm" "version=$_lv" ;;
      later) say pkg.later "name=$_nm" "version=$_lv" ;;
      *)
        if [ -n "$_loc" ]; then
          if [ "$_want" = off ] && [ "$_loc" != off ]; then say pkg.wantoff "name=$_nm" "version=$(st_get "$_i" 2)"
          else show_status "$_i" "$(st_get "$_i" 2)" "$_loc" "$_lv"; fi
        elif [ "$_want" = on ]; then say pkg.notinstalled "name=$_nm" "version=$_lv"
        fi ;;
    esac
  done < "$TMPD/list"
  [ -z "$_only" ] || return 0
  for _i in $(st_ids); do
    [ -n "$(list_get "$_i" 2)" ] && continue
    show_status "$_i" "$(st_get "$_i" 2)" "$(st_get "$_i" 3)" ""
  done
}

# Проверка запретов: файл-приманка с безобидным текстом в данных плагина (имя подходит под образец Read .env*). Пока хуки выключены, ступень пишет «не проверялось», а не «стоит»
show_deny_probe() {
  _any=0
  for _id in $(st_ids); do
    [ "$(st_get "$_id" 3)" = off ] && continue
    [ -f "$KD/$_id/deny.txt" ] && _any=1
  done
  [ "$_any" = 1 ] || return 0
  if [ "$PROBE" != 1 ]; then say kit.deny.notchecked; return 0; fi
  ( umask 077; mkdir -p "$KD/probe" ) 2>/dev/null
  printf 'KIT_PROBE=this-is-a-harmless-decoy\n' | secure_write "$KD/probe/.env.probe"
  say kit.deny.probe "path=$KD/probe/.env.probe"
}

# ---------- команды ----------

cmd_list() {
  _any=0
  for _id in $(st_ids); do
    _any=1
    local_status "$_id"
    show_status "$_id" "$(st_get "$_id" 2)" "$LS" ""
  done
  [ "$_any" = 1 ] || say kit.list.none
  finish 0
}

cmd_check() {
  if [ "$BG" = 1 ]; then
    _last=$(head -n 1 "$KD/last-bg" 2>/dev/null | tr -d '\r')
    if is_num "$_last" && [ "${#_last}" -le 12 ] && [ $(( $(now) - _last )) -lt 86400 ]; then exit 0; fi
  fi
  acquire_lock
  need_token
  refresh_state
  : > "$TMPD/res"
  # Фон: «не чаще раза в сутки» держится и при отказах сайта: отметка пишется до запроса (нет сети — снимается в req_fail)
  if [ "$BG" = 1 ]; then printf '%s\n' "$(now)" | secure_write "$KD/last-bg"; fi
  request_list
  if [ "$BG" = 1 ]; then exit 0; fi
  if [ "$LIST_STATE" = none ] && [ -z "$(st_ids)" ]; then say kit.none; finish 0; fi
  show_all ""
  show_deny_probe
  finish 0
}

# install | update | on: общий ход. MODE=install|update|on, ONID — пакет для on
cmd_sync() {
  MODE=$1; ONID=$2
  acquire_lock
  need_token
  refresh_state
  : > "$TMPD/res"
  request_list
  # Решение по каждому пакету списка
  FETCH=""; nfetch=0; changed=0
  while IFS=' ' read -r _i _lv _want; do
    [ -n "$_i" ] || continue
    _loc=$(st_get "$_i" 3); _lver=$(st_get "$_i" 2)
    if [ "$MODE" = on ]; then
      [ "$_i" = "$ONID" ] || continue
      if [ -z "$_loc" ]; then fail 13 kit.off.unknown "id=$_i"; fi
      if [ "$_loc" != off ]; then fail 13 kit.on.notoff "id=$_i"; fi
      if [ "$_want" = off ]; then fail 18 kit.on.teamoff "name=$(pkg_name "$_i")"; fi
      if [ "$_want" != on ]; then fail 18 kit.on.notinset "name=$(pkg_name "$_i")"; fi
      FETCH="$FETCH $_i"; nfetch=$((nfetch + 1)); continue
    fi
    case "$_want" in
      on)
        [ "$_loc" = off ] && continue
        _need=0
        if [ -z "$_loc" ]; then [ "$MODE" = install ] && _need=1
        elif ver_lt "$_lver" "$_lv"; then _need=1
        elif [ "$MODE" = install ] && { [ "$_loc" = files ] || [ "$_loc" = absent ]; }; then _need=1
        fi
        if [ "$_need" = 1 ]; then
          if [ "$nfetch" -ge 8 ]; then printf '%s\tlater\t\n' "$_i" >> "$TMPD/res"; else FETCH="$FETCH $_i"; nfetch=$((nfetch + 1)); fi
        fi ;;
      off)
        if [ -n "$_loc" ] && [ "$_loc" != off ]; then
          remove_package "$_i" || fail 25 kit.cantwrite
          printf '%s\tremoved\t\n' "$_i" >> "$TMPD/res"; changed=1
        fi ;;
    esac
  done < "$TMPD/list"
  if [ "$MODE" = on ] && [ "$nfetch" = 0 ]; then fail 18 kit.on.notinset "name=$(pkg_name "$ONID")"; fi
  # Запрос 2: пакеты. Ответ 422 «split» (положенное больше 200 КБ, пункт 11 договора) делит группу пополам и спрашивает половины по очереди;
  # запросов пакетов за запуск не больше трёх, остальное — «повторите». Один пакет, который не помещается, — «больше допустимого размера»
  if [ "$nfetch" -gt 0 ]; then
    PKG_POSTS=0
    printf '%s\n' "${FETCH# }" > "$TMPD/queue"
    while [ -s "$TMPD/queue" ]; do
      _grp=$(head -n 1 "$TMPD/queue"); tail -n +2 "$TMPD/queue" > "$TMPD/queue.rest"
      if [ "$PKG_POSTS" -ge 3 ]; then
        for _x in $_grp; do printf '%s\tlater\t\n' "$_x" >> "$TMPD/res"; done
        mv -f "$TMPD/queue.rest" "$TMPD/queue"; continue
      fi
      PKG_POSTS=$((PKG_POSTS + 1))
      _ids=""; _sep=""; _cnt=0
      for _x in $_grp; do _ids="$_ids$_sep\"$_x\""; _sep=","; _cnt=$((_cnt + 1)); done
      printf '{"plugin_version":"%s","os":"%s","engine":%s,"ids":[%s]}' "$(plugin_version)" "$(os_name)" "$ENGINE_LEVEL" "$_ids" > "$TMPD/body2"
      post_kit /api/plugin/kit/package "$TMPD/body2"
      if [ "$HTTP_STATUS" = 422 ] && [ "$(jstr "$TMPD/resp" error)" = split ]; then
        if [ "$_cnt" -le 1 ]; then
          printf '%s\tbad\tsize\n' "$_grp" >> "$TMPD/res"
          mv -f "$TMPD/queue.rest" "$TMPD/queue"; continue
        fi
        _half=$(( (_cnt + 1) / 2 )); _ha=""; _hb=""; _k=0
        for _x in $_grp; do _k=$((_k + 1)); if [ "$_k" -le "$_half" ]; then _ha="$_ha $_x"; else _hb="$_hb $_x"; fi; done
        { printf '%s\n%s\n' "${_ha# }" "${_hb# }"; cat "$TMPD/queue.rest"; } > "$TMPD/queue"
        continue
      fi
      if [ "$HTTP_STATUS" != 200 ] && [ "$HTTP_STATUS" != 401 ] && [ "$changed" = 1 ]; then
        # часть пакетов уже стоит: остальные — «повторите», итоговый отчёт всё равно уйдёт
        for _x in $_grp $(cat "$TMPD/queue.rest"); do printf '%s\tlater\t\n' "$_x" >> "$TMPD/res"; done
        : > "$TMPD/queue"; break
      fi
      [ "$HTTP_STATUS" = 200 ] || req_fail
      [ "$BIG" = 0 ] || fail 16 kit.badreply
      _want_ids=$(printf '%s' "$_grp" | sed 's/ /,/g')
      parse_packages "$TMPD/resp" "$_want_ids"
      case "$PK_ERR" in
        '') ;;
        version) fail 15 kit.updateplugin ;;
        *) fail 16 kit.badreply ;;
      esac
      verify_packages
      _n=1
      while [ "$_n" -le "$PK_COUNT" ]; do
        _pd="$TMPD/pk/$_n"
        _pid=$(kv "$_pd/info" id); _perr=$(kv "$_pd/info" err); _pver=$(kv "$_pd/info" version)
        if [ -n "$_perr" ]; then
          printf '%s\tbad\t%s\n' "$_pid" "$_perr" >> "$TMPD/res"
        else
          _before=$(st_get "$_pid" 2)
          place_package "$_n"
          case "$PLACE" in
            placed) printf '%s\tplaced\t%s\n' "$_pid" "$_before" >> "$TMPD/res"; changed=1 ;;
            occupied) printf '%s\toccupied\t%s\n' "$_pid" "$OCC" >> "$TMPD/res" ;;
            *) printf '%s\tcantwrite\t\n' "$_pid" >> "$TMPD/res" ;;
          esac
        fi
        _n=$((_n + 1))
      done
      mv -f "$TMPD/queue.rest" "$TMPD/queue"
    done
  fi
  # Показ: после списка (on — только его пакет). Версия на экране — та, что записана
  if [ "$MODE" = on ]; then show_all "$ONID"; else show_all ""; fi
  # Нечего было делать (ни одного пакета списка) — прямая фраза
  if [ "$LIST_STATE" = none ] && [ "$changed" = 0 ] && [ -z "$(st_ids)" ]; then say kit.none; fi
  # Запрос 3: итоговый отчёт, только если что-то изменилось
  if [ "$changed" = 1 ]; then
    report_body "$TMPD/body3"
    post_kit /api/plugin/kit "$TMPD/body3"
    if [ "$HTTP_STATUS" = 401 ]; then rm -f "$TOKEN_FILE"; fail 11 kit.rejected "cmd=/kit:check"; fi
    if [ "$HTTP_STATUS" != 200 ]; then say kit.reportlater; finish 10; fi
  fi
  # Не все пакеты поставлены — код 17 (без --soft)
  if awk -F '\t' '$2 == "occupied" || $2 == "bad" || $2 == "cantwrite" || $2 == "later" { f = 1 } END { exit f ? 0 : 1 }' "$TMPD/res"; then finish 17; fi
  finish 0
}

cmd_off() {
  id_ok_arg "$ARG2" || fail 12 kit.badid
  acquire_lock
  _cur=$(st_get "$ARG2" 3)
  [ -n "$_cur" ] || fail 13 kit.off.unknown "id=$ARG2"
  _nm=$(pkg_name "$ARG2")
  if [ "$_cur" = off ]; then say kit.off.already "name=$_nm" "id=$ARG2"; finish 0; fi
  remove_package "$ARG2" || fail 25 kit.cantwrite
  say kit.off.done "name=$_nm" "id=$ARG2"
  # Сайт узнаёт о выключении следующим отчётом; нет токена или сети — выключено только на этом компьютере
  if ! load_token; then say kit.off.local; finish 0; fi
  report_body "$TMPD/body1"
  post_kit /api/plugin/kit "$TMPD/body1"
  case "$HTTP_STATUS" in
    200) ;;
    401) rm -f "$TOKEN_FILE"; say kit.off.local; finish 0 ;;
    *) say kit.off.local; finish 0 ;;
  esac
  finish 0
}

case "$CMD" in
  list) cmd_list ;;
  check) cmd_check ;;
  install) cmd_sync install "" ;;
  update) cmd_sync update "" ;;
  on) id_ok_arg "$ARG2" || fail 12 kit.badid; cmd_sync on "$ARG2" ;;
  off) cmd_off ;;
esac
