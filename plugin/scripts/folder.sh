#!/bin/sh
# Учебная папка курса, Mac и Linux (sh). То же поведение и вывод, что у folder.ps1.
#   folder.sh create [<путь>] [--data <папка>] [--soft]
# Создаёт учебную папку (по умолчанию claude-course в домашней папке; относительный путь тоже считается от домашней), ставит в неё метку .stratum-course
# и краткий README.md и запоминает путь в данных плагина. По метке /course:next узнаёт учебную папку: в чужую папку плагин ничего не кладёт.
# Папка, которая уже есть: с меткой — запоминается как есть; пустая — становится учебной; с чужими файлами — отказ. Ссылка на месте папки — отказ.
# Коды выхода: 0 готово; 50 путь не подходит; 51 папка занята чужими файлами; 52 создать не удалось; 2 неверный вызов.
# --soft: всегда код 0 (для строки внутри навыка). Путь никуда, кроме команд этого скрипта, не подставляется.
. "$(dirname "$0")/lib.sh"

parse_opts "$@"
[ "$CMD" = create ] || { echo "usage: folder.sh create [<path>] [--data <dir>] [--soft]" >&2; exit 2; }
data_dir
acquire_lock
STATE="$DATA/course-state.txt"

p=$ARG2
[ -n "$p" ] || p=claude-course
# Путь проверяется по списку разрешённых знаков: буквы любых языков (байты UTF-8), латинские буквы, цифры, пробел и . _ - ~ / \ ; не длиннее 240 байт.
# Двоеточие — только в начале пути Windows (C:/ или C:\) и только там, где работает Windows (Git Bash); на Mac и Linux двоеточия в пути нет.
_chk=$p
_win=0
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) _win=1; case "$_chk" in [A-Za-z]:[/\\]*) _chk=${_chk#??} ;; esac ;;
esac
[ -z "$(printf '%s' "$_chk" | LC_ALL=C tr -d 'A-Za-z0-9 ._~/\\\200-\377-')" ] || fail 50 folder.bad
[ "$(printf '%s' "$p" | wc -c | tr -d ' ')" -le 240 ] || fail 50 folder.bad
if text_hidden "$p" || text_symbols "$p"; then fail 50 folder.bad; fi
case "$p" in
  '~') p=$HOME ;;
  '~/'*) p="$HOME/${p#\~/}" ;;
esac
# Абсолютный путь: /... везде, X:/ и X:\ в Windows; остальное считается от домашней папки
case "$p" in
  /*) ;;
  [A-Za-z]:[/\\]*) [ "$_win" = 1 ] || p="$HOME/$p" ;;
  *) p="$HOME/$p" ;;
esac
while [ "${p%/}" != "$p" ] && [ "$p" != "/" ]; do p=${p%/}; done

[ ! -L "$p" ] || fail 52 folder.cantcreate "path=$p"
if [ -e "$p" ]; then
  [ -d "$p" ] || fail 52 folder.cantcreate "path=$p"
  if is_course_dir "$p"; then made=0
  elif [ -z "$(ls -A "$p" 2>/dev/null | grep -vxE '\.DS_Store|desktop\.ini|Thumbs\.db')" ]; then made=1
  else fail 51 folder.busy "path=$p"
  fi
else
  mkdir -p "$p" 2>/dev/null || fail 52 folder.cantcreate "path=$p"
  made=1
fi
if [ "$made" = 1 ]; then
  ( set -C; printf 'stratum-course-folder 1\n' > "$p/.stratum-course" ) 2>/dev/null || fail 52 folder.cantcreate "path=$p"
  ( set -C; say folder.readme > "$p/README.md" ) 2>/dev/null
fi

# Путь запоминается в данных плагина; если учебная папка сменилась, показанные и спорные шаги относились к прежней и забываются
state_switch_workdir "$p"
if [ "$made" = 1 ]; then fail 0 folder.created "path=$p"; fi
fail 0 folder.exists "path=$p"
