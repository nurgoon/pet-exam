#!/usr/bin/env sh
set -e

PROJECT_NAME=${COMPOSE_PROJECT_NAME:-pet-exam}
ENV_FILE=.env.docker
ENV_EXAMPLE=.env.docker.example

if ! command -v docker >/dev/null 2>&1; then
  echo "docker не найден. Установите Docker и повторите." >&2
  exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
  if [ ! -f "$ENV_EXAMPLE" ]; then
    echo "Не найден $ENV_EXAMPLE" >&2
    exit 1
  fi
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  echo "Создан $ENV_FILE из шаблона $ENV_EXAMPLE"
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose plugin не найден. Установите docker compose plugin." >&2
  exit 1
fi

echo "Запуск контейнеров (project: $PROJECT_NAME)..."
docker compose --env-file "$ENV_FILE" -p "$PROJECT_NAME" up -d --build

echo "Готово."
echo "Приложение: http://127.0.0.1:${APP_PORT:-18080}"
echo "Админка: http://127.0.0.1:${APP_PORT:-18080}/admin/"
