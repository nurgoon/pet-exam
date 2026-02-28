$ErrorActionPreference = 'Stop'

$projectName = if ($env:COMPOSE_PROJECT_NAME) { $env:COMPOSE_PROJECT_NAME } else { 'pet-exam' }
$envFile = '.env.docker'
$envExample = '.env.docker.example'
$composeEnvFile = '.env'

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw 'docker не найден. Установите Docker Desktop и повторите.'
}

if (-not (Test-Path $envFile)) {
  if (-not (Test-Path $envExample)) {
    throw "Не найден $envExample"
  }
  Copy-Item $envExample $envFile
  Write-Host "Создан $envFile из шаблона $envExample"
}

$composeVersion = docker compose version 2>$null
if (-not $composeVersion) {
  throw 'docker compose plugin не найден.'
}

$envMap = @{}
Get-Content $envFile | ForEach-Object {
  $line = $_.Trim()
  if (-not $line -or $line.StartsWith('#')) { return }
  $parts = $line.Split('=', 2)
  if ($parts.Count -eq 2) {
    $envMap[$parts[0].Trim()] = $parts[1].Trim()
  }
}

$appBindIp = if ($envMap.ContainsKey('APP_BIND_IP') -and $envMap['APP_BIND_IP']) { $envMap['APP_BIND_IP'] } else { '127.0.0.1' }
$appPort = if ($envMap.ContainsKey('APP_PORT') -and $envMap['APP_PORT']) { $envMap['APP_PORT'] } else { '18080' }
$domain = if ($envMap.ContainsKey('DOMAIN')) { $envMap['DOMAIN'] } else { '' }
$email = if ($envMap.ContainsKey('LETSENCRYPT_EMAIL')) { $envMap['LETSENCRYPT_EMAIL'] } else { '' }

@(
  "APP_BIND_IP=$appBindIp"
  "APP_PORT=$appPort"
  "DOMAIN=$domain"
  "LETSENCRYPT_EMAIL=$email"
) | Set-Content -Path $composeEnvFile -Encoding UTF8

if ($domain) {
  if (-not $email) {
    throw "Для автоматического HTTPS укажите LETSENCRYPT_EMAIL в $envFile"
  }

  Write-Host "Запуск контейнеров с HTTPS (Let's Encrypt) для домена: $domain"
  docker compose --env-file $envFile -p $projectName --profile https up -d --build
  Write-Host 'Готово.'
  Write-Host "Сайт: https://$domain"
  Write-Host "Админка: https://$domain/admin/"
  exit 0
}

Write-Host "Запуск контейнеров (project: $projectName)..."
docker compose --env-file $envFile -p $projectName up -d --build

Write-Host 'Готово.'
Write-Host "Приложение: http://$appBindIp:$appPort"
Write-Host "Админка: http://$appBindIp:$appPort/admin/"
