#!/bin/bash
# Друкує Team ID сертифіката, який є на цій машині.
#
# Раніше він був зашитий у app/project.yml, і на чужому маку збірка
# падала: чужий Team ID до чужого сертифіката не підходить. Тепер його
# щоразу дістають звідси — з того, що справді лежить у зв'язці ключів.
#
# Перевизначити: LASERBEAK_TEAM=XXXXXXXXXX npm run build:app

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lang.sh"

if [ -n "${LASERBEAK_TEAM:-}" ]; then
  echo "$LASERBEAK_TEAM"
  exit 0
fi

# Team ID лежить в OU сертифіката. CN містить інше число — ідентифікатор
# самого сертифіката, — і сплутати їх легко.
TEAM="$(security find-certificate -c "Apple Development" -p 2>/dev/null \
  | openssl x509 -noout -subject 2>/dev/null \
  | tr ',' '\n' | awk -F' = ' '/OU/ {print $2; exit}' | tr -d ' ')"

if [ -z "$TEAM" ]; then
  # Це перше, що бачить людина на чужому маку, — тож її мовою.
  {
    say team.none
    echo
    say team.why
    echo
    say team.how
    say team.step1
    say team.step2
    echo
    say team.again
  } >&2
  exit 1
fi

echo "$TEAM"
