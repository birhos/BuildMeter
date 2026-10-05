# BuildMeter — PowerShell entegrasyonu (Windows PowerShell 5.1 ve PowerShell 7).
# $PROFILE içine: . "$HOME\.buildmeter\buildmeter.ps1"
#
# Build komutlarını süre ölçen `buildmeter track` üzerinden çağırır. Hangi alt komutun
# ölçüleceğine wrapper karar verir; diğerleri olduğu gibi çalışır.
# Geçici olarak kapatmak için: $env:BUILDMETER_DISABLE = '1'

if (-not $env:BUILDMETER_BIN) {
    $env:BUILDMETER_BIN = Join-Path $HOME '.buildmeter\bin\buildmeter.exe'
}

function Invoke-BuildMeterTrack {
    param([string]$Name, [object[]]$Arguments)
    if (-not $env:BUILDMETER_DISABLE -and (Test-Path $env:BUILDMETER_BIN)) {
        & $env:BUILDMETER_BIN track $Name @Arguments
    } else {
        # Fonksiyonun kendisini değil, PATH'teki asıl uygulamayı çağır (npm.cmd, dotnet.exe …).
        $app = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $app) { throw "$Name bulunamadı" }
        & $app.Source @Arguments
    }
}

# `buildmeter report --range week` gibi doğrudan kullanım için.
function global:buildmeter { & $env:BUILDMETER_BIN @args }

foreach ($name in 'flutter', 'fvm', 'dotnet', 'npm', 'pnpm', 'yarn', 'bun', 'npx', 'next', 'vite') {
    Set-Item -Path "Function:global:$name" -Value ([scriptblock]::Create(
        "Invoke-BuildMeterTrack -Name '$name' -Arguments `$args"))
}
