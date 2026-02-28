$ErrorActionPreference = 'Stop'

$projectName = if ($env:COMPOSE_PROJECT_NAME) { $env:COMPOSE_PROJECT_NAME } else { 'pet-exam' }
$envFile = '.env.docker'
$envExample = '.env.docker.example'

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

Write-Host "Запуск контейнеров (project: $projectName)..."
docker compose --env-file $envFile -p $projectName up -d --build

$appPort = '18080'
if (Test-Path $envFile) {
  $line = Select-String -Path $envFile -Pattern '^APP_PORT=' | Select-Object -First 1
  if ($line) {
    $parts = $line.Line.Split('=', 2)
    if ($parts.Count -eq 2 -and $parts[1]) {
      $appPort = $parts[1].Trim()
    }
  }
}

Write-Host 'Готово.'
Write-Host "Приложение: http://127.0.0.1:$appPort"
Write-Host "Админка: http://127.0.0.1:$appPort/admin/"
