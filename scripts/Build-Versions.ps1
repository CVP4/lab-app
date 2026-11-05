param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9_-]*$')]
    [string]$DockerHubUsername,
    [switch]$Push
)

$ErrorActionPreference = 'Stop'
$projectPath = Split-Path $PSScriptRoot -Parent
$appPath = Join-Path $projectPath 'app.py'
$original = [IO.File]::ReadAllBytes($appPath)

function Invoke-Docker {
    param([string[]]$DockerArguments)
    & docker @DockerArguments
    if ($LASTEXITCODE -ne 0) {
        throw "docker $($DockerArguments -join ' ') завершился с кодом $LASTEXITCODE"
    }
}

Push-Location $projectPath
try {
    foreach ($version in @('1.0', '1.1')) {
        & (Join-Path $PSScriptRoot 'Set-Version.ps1') -Version $version
        Invoke-Docker -DockerArguments @('build', '-t', "lab-app:$version", '.')
        Invoke-Docker -DockerArguments @('tag', "lab-app:$version", "${DockerHubUsername}/lab-app:$version")
        if ($version -eq '1.0') {
            Invoke-Docker -DockerArguments @('tag', 'lab-app:1.0', "${DockerHubUsername}/lab-app:latest")
        }
        if ($Push) {
            Invoke-Docker -DockerArguments @('push', "${DockerHubUsername}/lab-app:$version")
            if ($version -eq '1.0') {
                Invoke-Docker -DockerArguments @('push', "${DockerHubUsername}/lab-app:latest")
            }
        }
    }
    Invoke-Docker -DockerArguments @('images')
} finally {
    [IO.File]::WriteAllBytes($appPath, $original)
    Pop-Location
}
