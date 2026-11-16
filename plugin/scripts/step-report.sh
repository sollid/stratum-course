#!/bin/sh
# Отметка шага на сайте, Mac и Linux (sh + curl). То же поведение и вывод, что у step-report.ps1.
#   step-report.sh --module m1 --step s2 --passed true|false [--reason <код>] [--check-version 1] [--data <папка>] [--soft]
#   step-report.sh --module m1 --step s2 --rules <rules.json> --dir <папка> [--data <папка>] [--soft]
#     (вторая форма: запускает неизменный check.sh, берёт вердикт из его вывода; passed = вердикт «accepted»)
# На сайт уходит только КОД причины (^[a-z0-9_]{1,40}$), не текст: код первого невыполненного правила из <шаг>.reasons.txt рядом с правилами.
# Человеческий текст причины ученику показывает сама проверка.
# Коды выхода: 0 отправлено (в том числе «уже отмечено»); 10 не отправлено (нет сети, сайт занят или странный ответ); 11 привязать заново (нет токена или сайт его не принял);
#   12 сайт не знает шаг; 13 проверка не отработала; 14 адрес сайта в настройках не тот, к которому привязан токен; 20 в файле токена плохой адрес сайта; 22 на сайте выключено; 23 сайт в режиме показа; 2 неверный вызов.
# --soft: всегда код 0 (для строки внутри навыка). Вердикт не теряется: он проверен на этой машине до любой отправки.
# Токен читается из файла токена, уходит только в заголовке Authorization на тот адрес, что записан вместе с ним, и не печатается.
. "$(dirname "$0")/lib.sh"

parse_opts "$@"
usage() { echo "usage: step-report.sh --module <m> --step <s> (--passed true|false [--reason <code>] | --rules <file> --dir <folder>) [--data <dir>] [--soft]" >&2; exit 2; }

printf '%s' "$O_module" | grep -Eq '^[A-Za-z0-9_-]{1,20}$' || usage
printf '%s' "$O_step" | grep -Eq '^[A-Za-z0-9_-]{1,20}$' || usage

data_dir
TOKEN_FILE="$DATA/device-token.txt"
check_version=1
passed=false
reason=""

if [ -n "$O_rules" ]; then
  [ -n "$O_dir" ] || usage
  check_run "$O_rules" "$O_dir"
  verdict=$CK_VERDICT
  if [ "$CK_NEWER" = 1 ]; then fail 15 report.rulesnewer; fi
  [ "$CK_CODE" = 0 ] && [ -n "$verdict" ] || fail 13 report.checkfail
  [ "$verdict" = accepted ] && passed=true
  # На сайт уходит только короткий код: код первого невыполненного правила из списка рядом с правилами (<шаг>.reasons.txt)
  case "$O_rules" in
    *.rules.json) reasons_file="${O_rules%.rules.json}.reasons.txt" ;;
    *.json) reasons_file="${O_rules%.json}.reasons.txt" ;;
    *) reasons_file="" ;;
  esac
  # Код берётся из файла причин; если для правила кода там нет, у новых типов правил есть код по умолчанию (см. reason_code и default_reason в lib.sh)
  reason=$(reason_code "$O_rules" "$reasons_file" "$CK_OUT" "$verdict")
  rv=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$O_rules" 2>/dev/null | head -n 1)
  printf '%s' "$rv" | grep -Eq '^[0-9A-Za-z.+-]{1,20}$' && check_version=$rv
else
  [ "$O_passed" = true ] || [ "$O_passed" = false ] || usage
  passed=$O_passed
  reason=$O_reason
  if [ -n "$reason" ]; then printf '%s' "$reason" | grep -Eq '^[a-z0-9_]{1,40}$' || usage; fi
  printf '%s' "$O_checkversion" | grep -Eq '^[0-9A-Za-z.+-]{1,20}$' && check_version=$O_checkversion
fi
[ "$passed" = true ] && reason=""
if [ -n "$reason" ] && ! printf '%s' "$reason" | grep -Eq '^[a-z0-9_]{1,40}$'; then reason=""; fi

# Токен и адрес, к которому он относится
tok=$(kv "$TOKEN_FILE" token)
printf '%s' "$tok" | grep -Eq '^[A-Za-z0-9_-]{20,200}$' || fail 11 report.notpaired
SITE=$(kv "$TOKEN_FILE" site)
site_ok "$SITE" || fail 20 report.nosite
# Токен привязан к адресу, записанному вместе с ним. Если сейчас в настройках другой адрес, ничего не отправляем и объясняем
site_setting
if [ "$SITE_STATE" = ok ] && [ "$SITE_URL" != "$SITE" ]; then fail 14 report.sitemismatch "old=$SITE" "new=$SITE_URL"; fi

body="{\"module\":\"$O_module\",\"step\":\"$O_step\",\"passed\":$passed,\"check_version\":\"$check_version\",\"plugin_version\":\"$(plugin_version)\",\"os\":\"$(os_name)\""
[ -n "$reason" ] && body="$body,\"reason\":\"$reason\""
printf '%s}' "$body" > "$TMPD/body"

attempt=1
while [ "$attempt" -le 3 ]; do
  post /api/plugin/step "$TMPD/body" "$tok"
  if [ "$HTTP_STATUS" = 200 ] && [ "$(jstr "$TMPD/resp" status)" = recorded ]; then
    if grep -Eq '"repeated"[[:space:]]*:[[:space:]]*true' "$TMPD/resp"; then fail 0 report.repeated; fi
    if [ "$passed" = true ]; then fail 0 report.ok; fi
    fail 0 report.okfail
  fi
  if [ "$HTTP_STATUS" = 401 ]; then rm -f "$TOKEN_FILE"; fail 11 report.rejected; fi
  [ "$HTTP_STATUS" = 404 ] && fail 22 report.disabled "site=$SITE"
  if [ "$HTTP_STATUS" = 503 ] && [ "$(jstr "$TMPD/resp" error)" = preview ]; then fail 23 report.preview "site=$SITE"; fi
  [ "$HTTP_STATUS" = 422 ] && fail 12 report.unknownstep
  if [ "$HTTP_STATUS" = 0 ] || [ "$HTTP_STATUS" = 429 ] || [ "$HTTP_STATUS" = 503 ]; then
    if [ "$attempt" -lt 3 ]; then
      w=$HTTP_RETRY; [ "$w" -lt 1 ] && w=$(( 2 * attempt )); [ "$w" -gt 15 ] && w=15
      sleep "$w"
      attempt=$((attempt + 1))
      continue
    fi
  fi
  fail 10 report.offline
done
fail 10 report.offline
