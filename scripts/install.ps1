# BuildMeter Windows kurulumu:
#   1) Terminal wrapper'ı (buildmeter.exe)   -> %USERPROFILE%\.buildmeter\bin
#   2) PowerShell 5.1 ve 7 profil satırı, varsa Git Bash için ~/.bashrc satırı
#   3) .NET için MSBuild hook'u (dotnet build, Rider, Visual Studio)
#      -> %LOCALAPPDATA%\Microsoft\MSBuild\Current\Microsoft.Common.targets\ImportAfter
#
# Repodan çalıştırılıp Go kuruluysa wrapper kaynaktan derlenir; değilse GitHub
# release'inden indirilir ve checksum'ı doğrulanır.
#
# Kullanım:
#   powershell -ExecutionPolicy Bypass -File scripts\install.ps1 [-Version v1.1.0]
#   powershell -ExecutionPolicy Bypass -File scripts\install.ps1 -Uninstall [-Purge]

[CmdletBinding()]
param(
    [switch]$Uninstall,
    # -Uninstall ile birlikte kayıtlı verileri (~\.buildmeter) de siler.
    [switch]$Purge,
    # Wrapper'ın indirileceği release; varsayılan en son sürüm.
    [string]$Version = 'latest'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = Split-Path -Parent $PSScriptRoot
$Home_ = $env:USERPROFILE
$DataDir = if ($env:BUILDMETER_DATA_DIR) { $env:BUILDMETER_DATA_DIR } else { Join-Path $Home_ '.buildmeter' }
$InstallDir = Join-Path $Home_ '.buildmeter'
$BinDir = Join-Path $InstallDir 'bin'
# MSBuild, kullanıcı düzeyindeki bu klasördeki .targets dosyalarını her projeye ekler.
$ImportAfter = Join-Path $env:LOCALAPPDATA 'Microsoft\MSBuild\Current\Microsoft.Common.targets\ImportAfter'
$HookPath = Join-Path $ImportAfter 'BuildMeter.targets'
$Documents = [Environment]::GetFolderPath('MyDocuments')
# CurrentUserAllHosts profilleri: Windows PowerShell 5.1 ve PowerShell 7.
$Profiles = @(
    (Join-Path $Documents 'WindowsPowerShell\profile.ps1'),
    (Join-Path $Documents 'PowerShell\profile.ps1')
)
$ProfileLine = '. "$HOME\.buildmeter\buildmeter.ps1"'
$BashRc = Join-Path $Home_ '.bashrc'
$BashLine = 'source "$HOME/.buildmeter/buildmeter.sh"'
$ReleaseBase = if ($Version -eq 'latest') {
    'https://github.com/birhos/BuildMeter/releases/latest/download'
} else {
    "https://github.com/birhos/BuildMeter/releases/download/$Version"
}

function Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Blue }
function Ok([string]$Text)   { Write-Host "    [OK] $Text" -ForegroundColor Green }
function Warn([string]$Text) { Write-Host "    [!] $Text" -ForegroundColor Yellow }

function Add-Line([string]$Path, [string]$Line, [string]$Marker) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    if ((Test-Path $Path) -and (Select-String -Path $Path -SimpleMatch $Marker -Quiet)) {
        Ok "$Path zaten ayarlı"
        return
    }
    Add-Content -Path $Path -Value "`n# BuildMeter`n$Line" -Encoding UTF8
    Ok "$Path dosyasına eklendi"
}

function Remove-Lines([string]$Path, [string]$Marker) {
    if (-not (Test-Path $Path)) { return }
    $kept = Get-Content $Path | Where-Object { $_ -ne '# BuildMeter' -and -not $_.Contains($Marker) }
    Set-Content -Path $Path -Value $kept -Encoding UTF8
    Ok "$Path satırı kaldırıldı"
}

function Get-FromRelease([string]$Asset, [string]$Destination, [hashtable]$Checksums) {
    Invoke-WebRequest -UseBasicParsing -Uri "$ReleaseBase/$Asset" -OutFile $Destination
    $hash = (Get-FileHash -Algorithm SHA256 $Destination).Hash.ToLowerInvariant()
    if ($Checksums[$Asset] -ne $hash) { throw "$Asset checksum doğrulanamadı" }
    Unblock-File $Destination
}

function Install-Wrapper {
    Step "Terminal wrapper'ı kuruluyor"
    New-Item -ItemType Directory -Force -Path $BinDir, $DataDir | Out-Null
    $exe = Join-Path $BinDir 'buildmeter.exe'
    $source = Join-Path $Root 'wrapper'

    if ((Get-Command go -ErrorAction SilentlyContinue) -and (Test-Path (Join-Path $source 'go.mod'))) {
        Push-Location $source
        try {
            & go build -trimpath -ldflags '-s -w' -o $exe .
            if ($LASTEXITCODE -ne 0) { throw 'go build başarısız' }
        } finally { Pop-Location }
        Copy-Item -Force (Join-Path $Root 'cli\buildmeter.ps1') $InstallDir
        Copy-Item -Force (Join-Path $Root 'cli\buildmeter.sh') $InstallDir
        Ok 'Kaynaktan derlendi'
    } else {
        $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
        $asset = "buildmeter-windows-$arch.exe"
        $sumsFile = Join-Path $env:TEMP 'buildmeter-checksums.txt'
        Invoke-WebRequest -UseBasicParsing -Uri "$ReleaseBase/checksums.txt" -OutFile $sumsFile
        $sums = @{}
        foreach ($line in Get-Content $sumsFile) {
            $parts = $line -split '\s+', 2
            if ($parts.Count -eq 2) { $sums[$parts[1].TrimStart('*')] = $parts[0].ToLowerInvariant() }
        }
        Get-FromRelease $asset $exe $sums
        Get-FromRelease 'buildmeter.ps1' (Join-Path $InstallDir 'buildmeter.ps1') $sums
        Get-FromRelease 'buildmeter.sh' (Join-Path $InstallDir 'buildmeter.sh') $sums
        Ok "Release'ten indirildi ($Version, $arch)"
    }
    $events = Join-Path $DataDir 'events.jsonl'
    if (-not (Test-Path $events)) { New-Item -ItemType File -Path $events | Out-Null }

    foreach ($p in $Profiles) { Add-Line $p $ProfileLine '.buildmeter\buildmeter.ps1' }
    $gitBash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
    if ((Test-Path $gitBash) -or (Test-Path $BashRc)) { Add-Line $BashRc $BashLine '.buildmeter/buildmeter.sh' }

    $policy = Get-ExecutionPolicy
    if ($policy -in 'Restricted', 'AllSigned') {
        Warn "ExecutionPolicy '$policy' profil dosyasının yüklenmesini engelliyor. Çözüm:"
        Warn '    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
    }
    Warn 'Yeni bir PowerShell penceresi açın'
}

function Install-DotnetHook {
    Step ".NET için MSBuild hook'u kuruluyor"
    New-Item -ItemType Directory -Force -Path $ImportAfter, $DataDir | Out-Null
    $targets = Join-Path $Root 'cli\msbuild\BuildMeter.targets'
    if (Test-Path $targets) {
        Copy-Item -Force $targets $HookPath
    } else {
        Invoke-WebRequest -UseBasicParsing -Uri "$ReleaseBase/BuildMeter.targets" -OutFile $HookPath
    }
    Ok "dotnet build, Rider ve Visual Studio build'leri kaydedilecek"
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        Warn "dotnet bulunamadı; hook SDK ya da Visual Studio kurulduğunda devreye girer"
    }
}

function Uninstall-BuildMeter {
    Step "BuildMeter kaldırılıyor"
    if (Test-Path $HookPath) { Remove-Item -Force $HookPath }
    Ok "MSBuild hook'u kaldırıldı"
    foreach ($p in $Profiles) { Remove-Lines $p '.buildmeter\buildmeter.ps1' }
    Remove-Lines $BashRc '.buildmeter/buildmeter.sh'
    foreach ($f in $BinDir, (Join-Path $InstallDir 'buildmeter.ps1'), (Join-Path $InstallDir 'buildmeter.sh')) {
        if (Test-Path $f) { Remove-Item -Recurse -Force $f }
    }
    Ok "Terminal wrapper'ı kaldırıldı"
    if ($Purge -and (Test-Path $DataDir)) {
        Remove-Item -Recurse -Force $DataDir
        Ok "Kayıtlı veriler silindi"
    }
}

if ($Uninstall) {
    Uninstall-BuildMeter
} else {
    Install-Wrapper
    Install-DotnetHook
    Step "Bitti"
    Write-Host "    Kayıtlar: $DataDir\events.jsonl"
    Write-Host "    Rapor:    buildmeter report --range week   (ya da $BinDir\buildmeter.exe)"
}
