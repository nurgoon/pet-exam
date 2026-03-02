#!/bin/sh
set -e

python manage.py migrate --noinput

if [ "${DJANGO_COLLECTSTATIC:-1}" = "1" ]; then
  if ! python manage.py collectstatic --noinput; then
    if [ "${COLLECTSTATIC_STRICT:-0}" = "1" ]; then
      echo "collectstatic failed and COLLECTSTATIC_STRICT=1, exiting." >&2
      exit 1
    fi
    echo "WARNING: collectstatic failed, continuing startup." >&2
  fi
fi

exec gunicorn backend.wsgi:application --bind 0.0.0.0:8000 --workers ${GUNICORN_WORKERS:-3} --timeout ${GUNICORN_TIMEOUT:-60}
