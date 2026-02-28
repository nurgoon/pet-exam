#!/usr/bin/env sh
set -e

PROJECT_NAME=${COMPOSE_PROJECT_NAME:-pet-exam}
ENV_FILE=.env.docker
ENV_EXAMPLE=.env.docker.example
COMPOSE_ENV_FILE=.env

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

# Load deployment vars from .env.docker
set -a
. "./$ENV_FILE"
set +a

APP_BIND_IP=${APP_BIND_IP:-127.0.0.1}
APP_PORT=${APP_PORT:-18080}
DOMAIN=${DOMAIN:-}
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL:-}

# Compose reads substitutions from .env, not from service env_file
cat > "$COMPOSE_ENV_FILE" <<EOF
APP_BIND_IP=$APP_BIND_IP
APP_PORT=$APP_PORT
DOMAIN=$DOMAIN
LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL
EOF

COMPOSE_ARGS="--env-file $ENV_FILE -p $PROJECT_NAME"

if [ -n "$DOMAIN" ]; then
  if [ -z "$LETSENCRYPT_EMAIL" ]; then
    echo "Для автоматического HTTPS укажите LETSENCRYPT_EMAIL в $ENV_FILE" >&2
    exit 1
  fi

  echo "Запуск контейнеров с HTTPS (Let's Encrypt) для домена: $DOMAIN"
  # shellcheck disable=SC2086
  docker compose $COMPOSE_ARGS --profile https up -d --build
  echo "Готово."
  echo "Сайт: https://$DOMAIN"
  echo "Админка: https://$DOMAIN/admin/"
  exit 0
fi

echo "Запуск контейнеров (project: $PROJECT_NAME)..."
# shellcheck disable=SC2086
docker compose $COMPOSE_ARGS up -d --build

echo "Готово."
echo "Приложение: http://$APP_BIND_IP:$APP_PORT"
echo "Админка: http://$APP_BIND_IP:$APP_PORT/admin/"
