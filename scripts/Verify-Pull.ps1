param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9_-]*$')]
    [string]$DockerHubUsername
)

$ErrorActionPreference = 'Stop'
$containerName = 'lab-app'
$evidencePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'evidence'
New-Item -ItemType Directory -Path $evidencePath -Force | Out-Null

function Invoke-Docker {
    param([string[]]$DockerArguments)
    & docker @DockerArguments
    if ($LASTEXITCODE -ne 0) {
        throw "docker $($DockerArguments -join ' ') завершился с кодом $LASTEXITCODE"
    }
}

function Get-AppResponse {
    param([string]$Expected)
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            $response = Invoke-WebRequest 'http://localhost:8080' -UseBasicParsing -TimeoutSec 2
            $body = [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray())
            if ($response.StatusCode -ne 200 -or $body -ne $Expected) {
                throw "Неожиданный HTTP-ответ: $body"
            }
            return $body
        } catch {
            if ($attempt -eq 29) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
}

Invoke-Docker -DockerArguments @('info', '--format', '{{.ServerVersion}}')
$existing = & docker container ls -a --filter "name=^/${containerName}$" --format '{{.Names}}'
if ($LASTEXITCODE -ne 0) { throw 'Не удалось проверить существующие контейнеры.' }
if ($existing) { throw "Контейнер $containerName уже существует. Освободите имя перед проверкой." }

Start-Transcript -Path (Join-Path $evidencePath 'clean-pull.txt') -Force | Out-Null
$created = $false
try {
    # Удаляются только пять точных ссылок на образы этой работы.
    # Слои базового Python могут остаться в кэше, но локальных тегов приложения не будет.
    foreach ($ref in @('lab-app:1.0', 'lab-app:1.1', "${DockerHubUsername}/lab-app:1.0", "${DockerHubUsername}/lab-app:1.1", "${DockerHubUsername}/lab-app:latest")) {
        & docker image inspect $ref 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Invoke-Docker -DockerArguments @('rmi', $ref) }
    }
    Invoke-Docker -DockerArguments @('images')
    foreach ($version in @('1.0', '1.1')) {
        $ref = "${DockerHubUsername}/lab-app:$version"
        Invoke-Docker -DockerArguments @('pull', $ref)
        Invoke-Docker -DockerArguments @('run', '-d', '--name', $containerName, '-p', '8080:8000', $ref)
        $created = $true
        $expected = if ($version -eq '1.0') { 'Привет из контейнера!' } else { 'Привет из контейнера! Версия 1.1.' }
        $body = Get-AppResponse -Expected $expected
        [IO.File]::WriteAllText((Join-Path $evidencePath "response-$version.txt"), $body, [Text.UTF8Encoding]::new($false))
        Write-Host "HTTP 200; версия $version; ответ: $body"
        Invoke-Docker -DockerArguments @('ps', '--filter', "name=^/${containerName}$")
        Invoke-Docker -DockerArguments @('logs', $containerName)
        Write-Host 'Сделайте скриншот браузера http://localhost:8080 и вывода docker ps.'
        Read-Host 'Нажмите Enter после сохранения скриншотов' | Out-Null
        Invoke-Docker -DockerArguments @('stop', $containerName)
        Invoke-Docker -DockerArguments @('rm', $containerName)
        $created = $false
    }
} finally {
    if ($created) {
        & docker stop $containerName | Out-Null
        & docker rm $containerName | Out-Null
    }
    Stop-Transcript | Out-Null
}
