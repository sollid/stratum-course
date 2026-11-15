#!/bin/sh
# Привязка устройства, Mac и Linux (sh + curl). То же поведение и вывод, что у connect.ps1.
#   connect.sh start [--data <папка>] [--label <текст>] [--soft]   попросить у сайта код, показать его, запомнить файл ожидания
#   connect.sh wait  [--data <папка>] [--window <сек>] [--soft]    опрашивать до <сек> секунд (по умолчанию 90); можно вызывать снова
# Коды выхода: 0 готово; 30 ещё ждём (вызвать wait снова); 31 срок кода вышел; 32 привязка не начата; 20 адрес сайта не задан или не подходит;
#   21 сайт не отвечает; 22 на сайте привязка выключена; 23 сайт в режиме показа; 24 сайт занят; 25 неожиданный ответ; 26 токен не сохранён.
# --soft: всегда код 0 (для строки внутри навыка: ненулевой код обрывает навык).
# device_code лежит только в файле ожидания, токен — только в файле токена; в вывод они не попадают.
. "$(dirname "$0")/lib.sh"

parse_opts "$@"
data_dir
PENDING="$DATA/pair-pending.txt"
TOKEN_FILE="$DATA/device-token.txt"

get_site() {
  site_setting
  [ "$SITE_STATE" = none ] && fail 20 connect.nosite
  [ "$SITE_STATE" = bad ] && fail 20 connect.badsite
  SITE=$SITE_URL
}

save_pending() {
  printf 'device_code=%s\nexpires=%s\ninterval=%s\nsite=%s\nnot_before=%s\n' "$P_code" "$P_expires" "$P_interval" "$P_site" "$P_notbefore" | secure_write "$PENDING"
}

# Ответы, после которых попытка кончается
stop_on_answer() {
  [ "$HTTP_STATUS" = 404 ] && fail 22 connect.disabled "site=$SITE"
  if [ "$HTTP_STATUS" = 503 ] && [ "$(jstr "$TMPD/resp" error)" = preview ]; then fail 23 connect.preview "site=$SITE"; fi
  return 0
}

do_start() {
  get_site
  ver=$(plugin_version)
  label=$(device_label)
  printf '{"os":"%s","label":"%s","plugin_version":"%s"}' "$(os_name)" "$label" "$ver" > "$TMPD/body"
  attempt=1
  while [ "$attempt" -le 2 ]; do
    post /api/plugin/pair/start "$TMPD/body" ""
    [ "$HTTP_STATUS" = 200 ] && break
    stop_on_answer
    if [ "$HTTP_STATUS" = 0 ]; then
      [ "$attempt" = 2 ] && fail 21 connect.unreachable "site=$SITE"
      sleep 3
    elif [ "$HTTP_STATUS" = 429 ] || [ "$HTTP_STATUS" = 503 ]; then
      [ "$attempt" = 2 ] && fail 24 connect.busy
      w=$HTTP_RETRY; [ "$w" -lt 1 ] && w=5; [ "$w" -gt 60 ] && w=60
      sleep "$w"
    else
      fail 25 connect.unexpected "status=$HTTP_STATUS"
    fi
    attempt=$((attempt + 1))
  done
  dev=$(jstr "$TMPD/resp" device_code)
  usr=$(jstr "$TMPD/resp" user_code)
  if ! printf '%s' "$dev" | grep -Eq '^[A-Za-z0-9_-]{20,100}$' || ! printf '%s' "$usr" | grep -Eq '^[A-HJKMNP-Z2-9]{4}-[A-HJKMNP-Z2-9]{4}$'; then
    fail 25 connect.unexpected "status=200"
  fi
  expires_in=600
  v=$(jnum "$TMPD/resp" expires_in); if is_num "$v" && [ "${#v}" -le 5 ] && [ "$v" -ge 30 ]; then expires_in=$v; fi
  interval=5
  v=$(jnum "$TMPD/resp" interval); if is_num "$v" && [ "${#v}" -le 3 ] && [ "$v" -ge 1 ] && [ "$v" -le 60 ]; then interval=$v; fi
  vpath=/connect
  # Путь страницы из ответа принимается только в строгом виде /connect или /<две буквы>/connect
  v=$(jstr "$TMPD/resp" verification_path); if printf '%s' "$v" | grep -Eq '^/([a-z]{2}/)?connect$'; then vpath=$v; fi
  P_code=$dev; P_expires=$(( $(now) + expires_in )); P_interval=$interval; P_site=$SITE; P_notbefore=0
  save_pending || fail 26 connect.cantsave
  say connect.start "page=$SITE$vpath" "code=$usr" "label=$label" "os=$(os_label)" "minutes=$(( (expires_in + 59) / 60 ))"
  # Если этот компьютер уже привязан к другому адресу, говорим об этом сразу после кода (текст по-прежнему начинается с названия привязки)
  old_site=$(kv "$TOKEN_FILE" site)
  if [ -n "$old_site" ] && site_ok "$old_site" && [ "$old_site" != "$SITE" ]; then say connect.sitechanged "old=$old_site" "new=$SITE"; fi
  finish 0
}

do_wait() {
  P_code=$(kv "$PENDING" device_code); P_expires=$(kv "$PENDING" expires); P_interval=$(kv "$PENDING" interval)
  P_site=$(kv "$PENDING" site); P_notbefore=$(kv "$PENDING" not_before)
  if ! printf '%s' "$P_code" | grep -Eq '^[A-Za-z0-9_-]{20,100}$' || ! is_num "$P_expires" || [ "${#P_expires}" -gt 12 ] \
     || ! is_num "$P_interval" || [ "${#P_interval}" -gt 3 ] || ! site_ok "$P_site"; then
    rm -f "$PENDING"; fail 32 connect.nopending
  fi
  is_num "$P_notbefore" && [ "${#P_notbefore}" -le 12 ] || P_notbefore=0
  SITE=$P_site
  window=90
  if is_num "$O_window" && [ "${#O_window}" -le 3 ] && [ "$O_window" -ge 1 ]; then window=$O_window; fi
  win_end=$(( $(now) + window ))
  backoff=$P_interval; [ "$backoff" -lt 1 ] && backoff=1
  net_fail=0; odd=0
  printf '{"device_code":"%s"}' "$P_code" > "$TMPD/body"
  while :; do
    t=$(now)
    if [ "$t" -ge "$P_expires" ]; then rm -f "$PENDING"; fail 31 connect.expired; fi
    if [ "$t" -ge "$win_end" ]; then
      [ "$net_fail" = 1 ] && fail 21 connect.unreachable "site=$SITE"
      fail 30 connect.waiting
    fi
    if [ "$t" -lt "$P_notbefore" ]; then
      s=$(( P_notbefore - t )); [ $(( win_end - t )) -lt "$s" ] && s=$(( win_end - t )); [ $(( P_expires - t )) -lt "$s" ] && s=$(( P_expires - t ))
      [ "$s" -lt 1 ] && s=1
      sleep "$s"; continue
    fi
    post /api/plugin/pair/poll "$TMPD/body" ""
    pause=0; extra=0
    if [ "$HTTP_STATUS" = 0 ]; then
      net_fail=1; pause=$backoff; backoff=$(( backoff * 2 )); [ "$backoff" -gt 60 ] && backoff=60
    elif [ "$HTTP_STATUS" = 410 ]; then
      rm -f "$PENDING"; fail 31 connect.expired
    elif [ "$HTTP_STATUS" = 200 ]; then
      net_fail=0
      st=$(jstr "$TMPD/resp" status)
      if [ "$st" = pending ]; then
        odd=0; backoff=$P_interval; [ "$backoff" -lt 1 ] && backoff=1; pause=$P_interval
      elif [ "$st" = ready ]; then
        tok=$(jstr "$TMPD/resp" token); dev=$(jstr "$TMPD/resp" device_id); exp=$(jstr "$TMPD/resp" expires_at)
        if ! printf '%s' "$tok" | grep -Eq '^[A-Za-z0-9_-]{20,200}$' || ! printf '%s' "$dev" | grep -Eq '^[A-Za-z0-9-]{8,64}$'; then
          rm -f "$PENDING"; fail 25 connect.unexpected "status=200"
        fi
        printf '%s' "$exp" | grep -Eq '^[0-9TZ:.+-]{10,40}$' || exp=""
        if ! printf 'token=%s\ndevice_id=%s\nexpires_at=%s\nsite=%s\n' "$tok" "$dev" "$exp" "$SITE" | secure_write "$TOKEN_FILE"; then
          rm -f "$PENDING"; fail 26 connect.cantsave
        fi
        rm -f "$PENDING"
        fail 0 connect.paired
      else
        odd=$(( odd + 1 )); [ "$odd" -ge 3 ] && fail 25 connect.unexpected "status=200"
        pause=$backoff; backoff=$(( backoff * 2 )); [ "$backoff" -gt 60 ] && backoff=60
      fi
    else
      net_fail=0
      stop_on_answer
      if [ "$HTTP_STATUS" = 429 ] || [ "$HTTP_STATUS" = 503 ]; then
        if [ "$HTTP_RETRY" -gt 0 ]; then pause=$HTTP_RETRY; extra=1; else pause=$backoff; backoff=$(( backoff * 2 )); [ "$backoff" -gt 60 ] && backoff=60; fi
      else
        odd=$(( odd + 1 )); [ "$odd" -ge 3 ] && fail 25 connect.unexpected "status=$HTTP_STATUS"
        pause=$backoff; backoff=$(( backoff * 2 )); [ "$backoff" -gt 60 ] && backoff=60
      fi
    fi
    [ "$pause" -lt 1 ] && pause=1
    P_notbefore=$(( $(now) + pause + extra ))
    if [ "$P_notbefore" -gt "$win_end" ]; then save_pending || true; fi
  done
}

case "$CMD" in
  start) do_start ;;
  wait) do_wait ;;
  *) echo "usage: connect.sh start|wait [--data <dir>] [--window <sec>] [--soft]" >&2; exit 2 ;;
esac
