<#
.SYNOPSIS
  User-local setup for Pabrik desktop (no admin, no Program Files).

.DESCRIPTION
  Copies pabrik-desktop.exe + pabrik.exe + runtime DLLs to
  %LOCALAPPDATA%\pabrik\bin, the shipped html/ folder to
  %LOCALAPPDATA%\pabrik\html (persistent -- the desktop serves it
  via --static-dir, no per-run temp extraction), and creates a
  per-user Start Menu shortcut
  (Pabrik.lnk) so Win-key search finds it. Both exes ship together
  because the desktop auto-spawns the pabrik service sitting next to
  itself (next-to-self lookup); a lone desktop exe cannot start its
  backend. Idempotent: re-running overwrites the previous install.

  Works from two layouts:
    - Release zip: script sits beside the exes/DLLs (default SourceDir).
    - Repo checkout: pass -SourceDir zig-out\bin (what
      `zig build install:windows:app` does).

.PARAMETER SourceDir
  Directory holding pabrik-desktop.exe, pabrik.exe, *.dll and the
  shipped html/ folder.
  Defaults to the script's own directory (release-zip layout).

.PARAMETER DesktopShortcut
  Also create Desktop\Pabrik.lnk alongside the Start Menu entry.

.PARAMETER Uninstall
  Remove %LOCALAPPDATA%\pabrik\bin, %LOCALAPPDATA%\pabrik\html
  (plus legacy %LOCALAPPDATA%\pabrik\webapp),
  the Start Menu shortcut and the
  Desktop shortcut (if present), then exit.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Install-Pabrik.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Install-Pabrik.ps1 -DesktopShortcut
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Install-Pabrik.ps1 -Uninstall
#>
param(
    [string]$SourceDir = "",
    [switch]$DesktopShortcut,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

function Get-PabrikRoot {
    # Same priority as tools/install_tui.zig: LOCALAPPDATA first.
    if ($env:LOCALAPPDATA -ne $null -and $env:LOCALAPPDATA -ne "") {
        return (Join-Path $env:LOCALAPPDATA "pabrik")
    }
    if ($env:APPDATA -ne $null -and $env:APPDATA -ne "") {
        return (Join-Path $env:APPDATA "pabrik")
    }
    if ($env:USERPROFILE -ne $null -and $env:USERPROFILE -ne "") {
        return (Join-Path $env:USERPROFILE "pabrik")
    }
    Write-Error "Cannot determine install destination - none of LOCALAPPDATA, APPDATA, USERPROFILE is set."
    exit 1
}

$pabrikRoot = Get-PabrikRoot
$binDir = Join-Path $pabrikRoot "bin"
$htmlDir = Join-Path $pabrikRoot "html"
$legacyWebappDir = Join-Path $pabrikRoot "webapp"
$startMenuDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
$startMenuLink = Join-Path $startMenuDir "Pabrik.lnk"
$startMenuBrowserLinkUninstall = Join-Path $startMenuDir "Pabrik Browser.lnk"
$desktopLink = Join-Path ([Environment]::GetFolderPath("Desktop")) "Pabrik.lnk"

if ($Uninstall) {
    if (Test-Path $binDir) { Remove-Item $binDir -Recurse -Force }
    if (Test-Path $htmlDir) { Remove-Item $htmlDir -Recurse -Force }
    if (Test-Path $legacyWebappDir) { Remove-Item $legacyWebappDir -Recurse -Force }
    foreach ($link in @($startMenuLink, $startMenuBrowserLinkUninstall, $desktopLink)) {
        if (Test-Path $link) { Remove-Item $link -Force }
    }
    Write-Output "Uninstalled Pabrik (removed $binDir, $htmlDir and shortcuts)."
    exit 0
}

if ($SourceDir -eq "") { $SourceDir = $PSScriptRoot }
$desktopSrc = Join-Path $SourceDir "pabrik-desktop.exe"
$serviceSrc = Join-Path $SourceDir "pabrik.exe"
foreach ($req in @($desktopSrc, $serviceSrc)) {
    if (-not (Test-Path $req)) {
        Write-Error ("Required file missing: " + $req + " -- run 'zig build pabrik-desktop' first or extract the full release zip.")
        exit 1
    }
}

New-Item -ItemType Directory -Force -Path $binDir | Out-Null
Copy-Item -Force $desktopSrc (Join-Path $binDir "pabrik-desktop.exe")
Copy-Item -Force $serviceSrc (Join-Path $binDir "pabrik.exe")
$dlls = Get-ChildItem (Join-Path $SourceDir "*.dll") -ErrorAction SilentlyContinue
foreach ($dll in $dlls) { Copy-Item -Force $dll.FullName $binDir }
if (-not (Test-Path (Join-Path $binDir "WebView2Loader.dll"))) {
    Write-Warning "WebView2Loader.dll not found in $SourceDir -- the desktop needs the WebView2 Runtime (preinstalled on Win 10+) and its loader beside the exe."
}

# Bundled ripgrep: `search` spawns rg, so it lands beside pabrik.exe, which
# is the runtime resolver's first candidate after PABRIK_RG_BIN. Named
# rg-pabrik.exe on purpose -- a bare rg.exe here would collide with a
# ripgrep the user installed.
$rgSrc = Join-Path $SourceDir "rg-pabrik.exe"
if (Test-Path $rgSrc) {
    Copy-Item -Force $rgSrc (Join-Path $binDir "rg-pabrik.exe")
} else {
    Write-Warning "rg-pabrik.exe not found in $SourceDir -- the search tool will need ripgrep on PATH."
}

# Persistent html (Windows-only shipped static dir). The desktop
# prefers %LOCALAPPDATA%\pabrik\html\index.html and serves it via
# --static-dir -- no per-run temp extraction, survives close/reopen
# and reboot. Missing html/ in SourceDir is a warning (not fatal):
# old zips and bare zig-out/bin runs fall back to embedded-asset
# temp extraction. Legacy %LOCALAPPDATA%\pabrik\webapp is removed
# after a successful html install (pre-rename migration).
$htmlSrc = Join-Path $SourceDir "html"
if (Test-Path (Join-Path $htmlSrc "index.html")) {
    if (Test-Path $htmlDir) { Remove-Item $htmlDir -Recurse -Force }
    Copy-Item -Recurse -Force $htmlSrc $htmlDir
    if (Test-Path $legacyWebappDir) { Remove-Item $legacyWebappDir -Recurse -Force }
} else {
    Write-Warning "html/index.html not found in $SourceDir -- desktop falls back to embedded-asset temp extraction."
}

# Start Menu shortcuts (per-user, no admin). WScript.Shell is inbox on
# every Windows since 2000; IconLocation points at the exe itself
# (no separate .ico shipped -- the exe carries the app icon).
# Two entries: Pabrik (webview) + Pabrik Browser (--browser tab).
# The Programs dir is created explicitly: it always exists on a real
# profile, but a redirected APPDATA (CI scratch, roaming-profile edge
# cases) may not have it, and CreateShortcut.Save() fails there with
# DirectoryNotFoundException instead of creating it.
New-Item -ItemType Directory -Force -Path $startMenuDir | Out-Null
$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut($startMenuLink)
$lnk.TargetPath = Join-Path $binDir "pabrik-desktop.exe"
$lnk.WorkingDirectory = $binDir
$lnk.Description = "Pabrik Desktop - agent workspace"
$lnk.IconLocation = (Join-Path $binDir "pabrik-desktop.exe") + ",0"
$lnk.Save()

$startMenuBrowserLink = Join-Path $startMenuDir "Pabrik Browser.lnk"
$blnk = $shell.CreateShortcut($startMenuBrowserLink)
$blnk.TargetPath = Join-Path $binDir "pabrik-desktop.exe"
$blnk.Arguments = "--browser"
$blnk.WorkingDirectory = $binDir
$blnk.Description = "Pabrik Browser - open agent workspace in default browser tab"
$blnk.IconLocation = (Join-Path $binDir "pabrik-desktop.exe") + ",0"
$blnk.Save()

if ($DesktopShortcut) {
    $dlnk = $shell.CreateShortcut($desktopLink)
    $dlnk.TargetPath = Join-Path $binDir "pabrik-desktop.exe"
    $dlnk.WorkingDirectory = $binDir
    $dlnk.Description = "Pabrik Desktop - agent workspace"
    $dlnk.IconLocation = (Join-Path $binDir "pabrik-desktop.exe") + ",0"
    $dlnk.Save()
}

Write-Output ("Installed Pabrik to " + $binDir)
Write-Output "Press Win key and type 'Pabrik' to launch it."
Write-Output "(WebView2 Runtime required; preinstalled on Windows 10+.)"
