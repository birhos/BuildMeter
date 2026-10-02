# BuildMeter Windows kurulumu:
#   1) .NET için MSBuild hook'u (dotnet build, Rider, Visual Studio)
#      -> %LOCALAPPDATA%\Microsoft\MSBuild\Current\Microsoft.Common.targets\ImportAfter
#
# Terminal wrapper'ı, PowerShell profil satırı ve editör eklentisi sonraki
# sürümlerde bu betiğe eklenecek.
#
# Kullanım:
#   powershell -ExecutionPolicy Bypass -File scripts\install.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\install.ps1 -Uninstall [-Purge]

[CmdletBinding()]
param(
    [switch]$Uninstall,
    # -Uninstall ile birlikte kayıtlı verileri (~\.buildmeter) de siler.
    [switch]$Purge
)

$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$DataDir = if ($env:BUILDMETER_DATA_DIR) { $env:BUILDMETER_DATA_DIR } else { Join-Path $env:USERPROFILE '.buildmeter' }
# MSBuild, kullanıcı düzeyindeki bu klasördeki .targets dosyalarını her projeye ekler.
$ImportAfter = Join-Path $env:LOCALAPPDATA 'Microsoft\MSBuild\Current\Microsoft.Common.targets\ImportAfter'
$HookPath = Join-Path $ImportAfter 'BuildMeter.targets'

function Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Blue }
function Ok([string]$Text)   { Write-Host "    [OK] $Text" -ForegroundColor Green }
function Warn([string]$Text) { Write-Host "    [!] $Text" -ForegroundColor Yellow }

function Install-DotnetHook {
    Step ".NET için MSBuild hook'u kuruluyor"
    New-Item -ItemType Directory -Force -Path $ImportAfter, $DataDir | Out-Null
    Copy-Item -Force (Join-Path $Root 'cli\msbuild\BuildMeter.targets') $HookPath
    $events = Join-Path $DataDir 'events.jsonl'
    if (-not (Test-Path $events)) { New-Item -ItemType File -Path $events | Out-Null }
    Ok "dotnet build, Rider ve Visual Studio build'leri kaydedilecek"
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        Warn "dotnet bulunamadı; hook SDK ya da Visual Studio kurulduğunda devreye girer"
    }
}

function Uninstall-BuildMeter {
    Step "BuildMeter kaldırılıyor"
    if (Test-Path $HookPath) { Remove-Item -Force $HookPath }
    Ok "MSBuild hook'u kaldırıldı"
    if ($Purge -and (Test-Path $DataDir)) {
        Remove-Item -Recurse -Force $DataDir
        Ok "Kayıtlı veriler silindi"
    }
}

if ($Uninstall) {
    Uninstall-BuildMeter
} else {
    Install-DotnetHook
    Step "Bitti"
    Write-Host "    Kayıtlar: $DataDir\events.jsonl"
}
