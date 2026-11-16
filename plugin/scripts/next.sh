#!/bin/sh
# Следующий шаг курса, Mac и Linux (sh + curl + awk). То же поведение и вывод, что у next.ps1.
#   next.sh [--data <папка>] [--dir <учебная папка>] [--show-only] [--soft]
# Порядок: токен -> учебная папка (по метке) -> тихая перепроверка спорных шагов -> один запрос задания (POST /api/plugin/task) -> разбор и проверка пакета
# -> сохранение в данных плагина -> стартовые файлы в учебную папку -> показ задания или проверка и отправка отметки -> при «принято» ещё один запрос и показ следующего.
# За один запуск уходит не больше трёх POST. Пакет, не прошедший проверку формата, ничего не пишет на диск.
# --show-only (навык /course:task): только показать текущее задание, без проверки и без отметки.
# Коды выхода: 0 готово; 10 сайт не ответил или занят; 11 привязать заново; 12 сайт не знает шаг; 13 проверка не отработала; 14 адрес сайта в настройках не тот;
#   15 нужен более новый плагин; 16 пакет задания не по формату; 17 стартовый файл не положен; 18 пакет не сохранён; 20 плохой адрес сайта в файле токена;
#   22 на сайте выключено; 23 сайт в режиме показа; 24 неожиданный ответ сайта; 40 устройство не привязано; 41 папка не учебная.
# --soft: всегда код 0 (для строки внутри навыка).
# Токен читается из файла токена и уходит только в заголовке Authorization на адрес, записанный вместе с ним; не печатается.
# Содержимое стартовых файлов не печатается.
. "$(dirname "$0")/lib.sh"

parse_opts "$@"
data_dir
acquire_lock
TOKEN_FILE="$DATA/device-token.txt"
STATE="$DATA/course-state.txt"
POSTS=0

# 1. токен
tok=$(kv "$TOKEN_FILE" token)
printf '%s' "$tok" | grep -Eq '^[A-Za-z0-9_-]{20,200}$' || fail 40 next.notpaired

# 2. учебная папка: только с меткой, которую ставит /course:start. В чужую папку плагин ничего не кладёт
DIR=$O_dir; [ -n "$DIR" ] || DIR=.
case "$DIR" in
  /*|[A-Za-z]:*) ;;
  *) DIR=$(cd "$DIR" 2>/dev/null && pwd) || DIR="" ;;
esac
if [ -z "$DIR" ] || ! is_course_dir "$DIR"; then
  wd=$(state_values workdir | head -n 1)
  if [ -n "$wd" ]; then fail 41 next.notfolder "path=$wd"; fi
  fail 41 next.notfolder.nopath
fi
state_switch_workdir "$DIR"

SITE=$(kv "$TOKEN_FILE" site)
site_ok "$SITE" || fail 20 next.nosite
# Токен привязан к адресу, записанному вместе с ним. Если сейчас в настройках другой адрес, ничего не отправляем и объясняем
site_setting
if [ "$SITE_STATE" = ok ] && [ "$SITE_URL" != "$SITE" ]; then fail 14 next.sitemismatch "old=$SITE" "new=$SITE_URL"; fi

# Отправка отметки одной попыткой: MARK = recorded | repeated | rejected | disabled | preview | unknown | offline. Каждая отправка — один POST
send_mark() { # модуль шаг passed причина версия_проверки
  _body="{\"module\":\"$1\",\"step\":\"$2\",\"passed\":$3,\"check_version\":\"$5\",\"plugin_version\":\"$(plugin_version)\",\"os\":\"$(os_name)\""
  [ -n "$4" ] && _body="$_body,\"reason\":\"$4\""
  printf '%s}' "$_body" > "$TMPD/body"
  POSTS=$((POSTS + 1))
  post /api/plugin/step "$TMPD/body" "$tok"
  if [ "$HTTP_STATUS" = 200 ] && [ "$(jstr "$TMPD/resp" status)" = recorded ]; then
    if grep -Eq '"repeated"[[:space:]]*:[[:space:]]*true' "$TMPD/resp"; then MARK=repeated; else MARK=recorded; fi
    return 0
  fi
  case "$HTTP_STATUS" in
    401) MARK=rejected ;;
    404) MARK=disabled ;;
    422) MARK=unknown ;;
    503) if [ "$(jstr "$TMPD/resp" error)" = preview ]; then MARK=preview; else MARK=offline; fi ;;
    *) MARK=offline ;;
  esac
  return 0
}

# 3. тихая перепроверка спорных шагов (по правилам, сохранённым в данных плагина). Не больше одной отправки за запуск
if [ "$SHOWONLY" != 1 ]; then
  set -f
  for _k in $(state_values disputed); do
    printf '%s' "$_k" | grep -Eq '^[a-z0-9]{1,10}/[a-z0-9]{1,10}$' || continue
    _m=${_k%/*}; _s=${_k#*/}
    _sd="$DATA/steps/$_m-$_s"
    [ "$POSTS" -lt 1 ] && [ -f "$_sd/rules.json" ] || continue
    check_run "$_sd/rules.json" "$DIR"
    [ "$CK_CODE" = 0 ] && [ "$CK_VERDICT" = accepted ] || continue
    _cv=$(kv "$_sd/meta.txt" check_version); [ -n "$_cv" ] || _cv=1
    send_mark "$_m" "$_s" true "" "$_cv"
    case "$MARK" in
      recorded|repeated)
        state_drop disputed "$_k"
        say next.recheck "module_n=$(module_number "$_m")" "n=$(kv "$_sd/meta.txt" number)" "step_title=$(kv "$_sd/meta.txt" step_title)" ;;
      rejected) rm -f "$TOKEN_FILE"; fail 11 report.rejected ;;
    esac
  done
  set +f
fi

# 4–6. запрос задания, разбор, сохранение, стартовые файлы. Печатает отказ и завершает работу, если шаг показывать нельзя
fetch_task() {
  printf '{"plugin_version":"%s","os":"%s","engine":%s}' "$(plugin_version)" "$(os_name)" "$ENGINE_LEVEL" > "$TMPD/tbody"
  POSTS=$((POSTS + 1))
  post_task "$TMPD/tbody" "$tok"
  case "$HTTP_STATUS" in
    200) ;;
    401) rm -f "$TOKEN_FILE"; fail 11 next.rejected ;;
    404) fail 22 next.disabled "site=$SITE" ;;
    503) if [ "$(jstr "$TMPD/task" error)" = preview ]; then fail 23 next.preview "site=$SITE"; fi; fail 10 next.offline ;;
    0|429) fail 10 next.offline ;;
    *) fail 24 next.unexpected "status=$HTTP_STATUS" ;;
  esac
  [ "$TASK_BIG" = 0 ] || fail 16 next.badpackage
  parse_package "$TMPD/task"
  case "$PKG_ERR" in
    '') ;;
    version) fail 15 next.updateplugin ;;
    start) fail 16 next.badstart ;;
    *) fail 16 next.badpackage ;;
  esac
  P="$TMPD/pkg/head.txt"
  P_state=$(kv "$P" state); P_waiting=$(kv "$P" waiting)
  if [ "$P_state" = done ]; then
    if [ "$P_waiting" = 0 ]; then fail 0 next.done; fi
    fail 0 next.donewaiting "waiting=$P_waiting"
  fi
  P_module=$(kv "$P" module); P_step=$(kv "$P" step); P_file=$(kv "$P" file)
  P_cv=$(kv "$P" check_version); P_min=$(kv "$P" min_engine)
  # Главный файл в правилах — тот же, что в шапке пакета
  [ "$(rules_file_field "$TMPD/pkg/rules")" = "$P_file" ] || fail 16 next.badpackage
  [ "$P_min" -le "$ENGINE_LEVEL" ] || fail 15 next.updateplugin
  # Сохранение пакета в данных плагина, отдельно от файла токена
  SD="$DATA/steps/$P_module-$P_step"
  ( umask 077; mkdir -p "$SD" ) 2>/dev/null || fail 18 next.cantsave
  secure_write "$SD/task.md" < "$TMPD/pkg/task" || fail 18 next.cantsave
  secure_write "$SD/rules.json" < "$TMPD/pkg/rules" || fail 18 next.cantsave
  secure_write "$SD/reasons.txt" < "$TMPD/pkg/reasons" || fail 18 next.cantsave
  for _k in module_title step_title number of file check_version; do printf '%s=%s\n' "$_k" "$(kv "$P" "$_k")"; done | secure_write "$SD/meta.txt" || fail 18 next.cantsave
}

# 6. недостающие стартовые файлы кладёт скрипт плагина, и только вместе с показом задания (перед проверкой ничего не восстанавливается: человек мог убрать файл нарочно);
# существующие файлы человека не перезаписываются. Не удалось положить — прямая фраза, задание не показывается
place_starts() {
  if [ -f "$TMPD/pkg/start.list" ]; then
    _tab=$(printf '\t')
    while IFS="$_tab" read -r _n _p; do
      if ! place_start_file "$DIR" "$_p" "$TMPD/pkg/start.$_n"; then
        fail 17 next.startfail "path=$_p"
      fi
    done < "$TMPD/pkg/start.list"
  fi
}

# 7. показ задания: заголовок, путь учебной папки, напоминание про ручной режим, текст шага слово в слово. Это не попытка: на сайт ничего не уходит
show_task() { # 1 — впервые на этой машине
  place_starts
  say next.header "n=$(module_number "$P_module")" "module_title=$(kv "$P" module_title)" "k=$(kv "$P" number)" "of=$(kv "$P" of)" "step_title=$(kv "$P" step_title)"
  _sp=$(kv "$P" story_path)
  if [ "$1" = 1 ] && [ -n "$_sp" ]; then say next.story "url=$SITE$_sp"; fi
  say next.folder "path=$DIR"
  say next.permission
  printf '\n'
  cat "$SD/task.md"
  state_put shown "$P_module/$P_step"
}

fetch_task
KEY="$P_module/$P_step"
if [ "$SHOWONLY" = 1 ] || ! state_has shown "$KEY" || [ ! -f "$DIR/$P_file" ]; then
  first=0; state_has shown "$KEY" || first=1
  show_task "$first"
  finish 0
fi

# 8. проверка по сохранённым правилам, вывод проверки, отправка отметки (только вердикт и код причины)
check_run "$SD/rules.json" "$DIR"
[ "$CK_NEWER" = 0 ] || fail 15 report.rulesnewer
[ "$CK_CODE" = 0 ] && [ -n "$CK_VERDICT" ] || fail 13 report.checkfail
printf '%s\n' "$CK_OUT"
passed=false; reason=""
if [ "$CK_VERDICT" = accepted ]; then
  passed=true
else
  reason=$(reason_code "$SD/rules.json" "$SD/reasons.txt" "$CK_OUT" "$CK_VERDICT")
  printf '%s' "$reason" | grep -Eq '^[a-z0-9_]{1,40}$' || reason=""
fi
send_mark "$P_module" "$P_step" "$passed" "$reason" "$P_cv"
case "$MARK" in
  rejected) rm -f "$TOKEN_FILE"; fail 11 report.rejected ;;
  disabled) fail 22 report.disabled "site=$SITE" ;;
  preview) fail 23 report.preview "site=$SITE" ;;
  unknown) fail 12 report.unknownstep ;;
  offline) fail 10 report.offline ;;
esac
if [ "$CK_VERDICT" = accepted ]; then
  if [ "$MARK" = repeated ]; then say report.repeated; else say report.ok; fi
  say next.verdict.accepted
  # цепочка «принято -> следующее задание»: если три отправки за запуск уже использованы, следующее задание — отдельным запуском
  if [ "$POSTS" -ge 3 ]; then fail 0 next.nextlater; fi
  fetch_task
  show_task 1
  finish 0
fi
if [ "$CK_VERDICT" = disputed ]; then
  state_put disputed "$P_module/$P_step"
  fail 0 next.verdict.disputed
fi
if [ "$MARK" = repeated ]; then say report.repeated; else say report.okfail; fi
fail 0 "next.verdict.$CK_VERDICT"
