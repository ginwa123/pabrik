<#
.SYNOPSIS
  One-line installer for Pabrik on Windows (no admin).

.DESCRIPTION
  Downloads the self-contained pabrik-desktop zip from the rolling
  `ci-latest` GitHub release and runs the bundled Install-Pabrik.ps1,
  which installs both exes + DLLs to %LOCALAPPDATA%\pabrik\bin, html/
  to %LOCALAPPDATA%\pabrik\html, and adds a Start Menu shortcut.

  irm https://raw.githubusercontent.com/ginwa123/pabrik/main/install.ps1 | iex

  Pinned version:
    $v = "ci-latest"; irm https://raw.githubusercontent.com/ginwa123/pabrik/main/install.ps1 | iex

.PARAMETER Version
  Release tag to download. Default "ci-latest".

.PARAMETER DesktopShortcut
  Also create Desktop\Pabrik.lnk alongside the Start Menu entry.

.PARAMETER Uninstall
  Remove the install (bin, html, shortcuts) and exit. Downloads
  nothing.
#>
param(
    [string]$Version = "",
    [switch]$DesktopShortcut,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo = if ($env:PABRIK_REPO) { $env:PABRIK_REPO } else { "ginwa123/pabrik" }
$Tag = if ($Version -ne "") { $Version } elseif ($env:PABRIK_VERSION) { $env:PABRIK_VERSION } else { "ci-latest" }
$Triple = "x86_64-windows-gnu"
$ZipName = "pabrik-desktop-$Triple.zip"
# PABRIK_BASE_URL overrides the release download base (tests point it at a
# local file:// staging dir holding the zip).
$BaseUrl = if ($env:PABRIK_BASE_URL) { $env:PABRIK_BASE_URL } else { "https://github.com/$Repo/releases/download/$Tag" }

if (-not [Environment]::Is64BitOperatingSystem) {
    Write-Error "Pabrik ships a 64-bit Windows build only; 32-bit Windows is not supported."
    exit 1
}
if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
    Write-Warning "ARM64 Windows has no prebuilt binary (only x64); the x64 build may work under emulation, continuing."
}

if ($Uninstall) {
    $root = Join-Path $env:LOCALAPPDATA "pabrik"
    foreach ($dir in @((Join-Path $root "bin"), (Join-Path $root "html"), (Join-Path $root "webapp"))) {
        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    }
    foreach ($link in @(
        (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Pabrik.lnk"),
        (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Pabrik Browser.lnk")
    )) {
        if (Test-Path $link) { Remove-Item $link -Force }
    }
    Write-Output "Uninstalled Pabrik."
    exit 0
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("pabrik-install-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    $zipPath = Join-Path $tmp $ZipName
    $url = "$BaseUrl/$ZipName"
    Write-Output "Downloading $url ..."
    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -TimeoutSec 600
    $extract = Join-Path $tmp "pkg"
    New-Item -ItemType Directory -Force -Path $extract | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $extract -Force

    $setup = Join-Path $extract "Install-Pabrik.ps1"
    if (-not (Test-Path $setup)) { Write-Error "Install-Pabrik.ps1 missing in $ZipName -- bad release asset?"; exit 1 }

    # Update detection: the exes carry no --version flag, so content is
    # the version — SHA256 the downloads against an existing install.
    # Identical → already up to date, exit before touching anything.
    # Differing (or missing) → install + report the update below.
    $installedDesktop = Join-Path $env:LOCALAPPDATA "pabrik\bin\pabrik-desktop.exe"
    $installedService = Join-Path $env:LOCALAPPDATA "pabrik\bin\pabrik.exe"
    $newDesktop = Join-Path $extract "pabrik-desktop.exe"
    $newService = Join-Path $extract "pabrik.exe"
    function Same-File($a, $b) {
        if (-not (Test-Path -LiteralPath $a)) { return $false }
        if (-not (Test-Path -LiteralPath $b)) { return $false }
        return (Get-FileHash -LiteralPath $a -Algorithm SHA256).Hash -eq `
               (Get-FileHash -LiteralPath $b -Algorithm SHA256).Hash
    }
    $hadExisting = Test-Path -LiteralPath $installedService
    if ((Same-File $newDesktop $installedDesktop) -and (Same-File $newService $installedService)) {
        Write-Output "pabrik is already up to date ($Tag)."
        exit 0
    }

    $args = @()
    if ($DesktopShortcut) { $args += "-DesktopShortcut" }
    Write-Output "Running Install-Pabrik.ps1 ..."
    & powershell -NoProfile -ExecutionPolicy Bypass -File $setup @args
    if ($LASTEXITCODE -ne 0) { Write-Error "Install-Pabrik.ps1 failed (exit $LASTEXITCODE)"; exit 1 }

    $probe = Join-Path $env:LOCALAPPDATA "pabrik\bin\pabrik.exe"
    try { & $probe --help | Out-Null } catch { Write-Warning "installed binary failed '--help' check at $probe" }

    # User PATH so `pabrik` works on the command line without the full
    # path. Idempotent (skips when already listed); skipped with
    # PABRIK_NO_MODIFY_PATH=1. New terminals pick it up automatically.
    $binDir = Join-Path $env:LOCALAPPDATA "pabrik\bin"
    if ($env:PABRIK_NO_MODIFY_PATH -ne "1") {
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        $already = $false
        if ($userPath) {
            foreach ($p in ($userPath -split ';')) {
                if ($p.TrimEnd('\') -ieq $binDir.TrimEnd('\')) { $already = $true; break }
            }
        }
        if (-not $already) {
            $newPath = if ($userPath) { $userPath + ';' + $binDir } else { $binDir }
            [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
            Write-Output "Added $binDir to your user PATH (new terminals)."
        }
    }

    Write-Output "Installed Pabrik. Press Win key and type 'Pabrik' to launch it."
    if ($hadExisting) { Write-Output "Updated existing installation to $Tag." }
} finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
