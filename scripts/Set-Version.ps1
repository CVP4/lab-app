param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+(\.\d+)?$')]
    [string]$Version
)

$ErrorActionPreference = 'Stop'
$appPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'app.py'
$source = [IO.File]::ReadAllText($appPath, [Text.Encoding]::UTF8)
$pattern = '(?m)^VERSION = "\d+\.\d+(?:\.\d+)?"$'
if ([regex]::Matches($source, $pattern).Count -ne 1) {
    throw 'Не удалось однозначно найти константу VERSION в app.py.'
}
$updated = [regex]::Replace($source, $pattern, ('VERSION = "' + $Version + '"'))
[IO.File]::WriteAllText($appPath, $updated, [Text.UTF8Encoding]::new($false))
Write-Host "Версия в app.py: $Version"
