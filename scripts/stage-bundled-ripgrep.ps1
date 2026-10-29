[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Target,
    [string]$Dest = "zig-out/bin/rg.exe"
)

$ErrorActionPreference = "Stop"

$RipgrepVersion = "15.2.0"

$Pinned = @{
    "x86_64-windows-gnu"    = @{ Upstream = "x86_64-pc-windows-gnu";  Sha256 = "5dbdc225a3ce064314fc05b6de8423a08a7b681764c1a276ff8263feaf68c7d6" }
    "aarch64-windows-gnu"   = @{ Upstream = "aarch64-pc-windows-msvc"; Sha256 = "e4abca10c3a64ebea742667dd7009449d49403db5460dd6873e389fa2945360f" }
}

if (-not $Pinned.ContainsKey($Target)) {
    Write-Error "no bundled ripgrep is published for triple '$Target' (known: $($Pinned.Keys -join ', '))"
    exit 1
}

$Upstream = $Pinned[$Target].Upstream
$WantSha = $Pinned[$Target].Sha256
$ArchiveName = "ripgrep-$RipgrepVersion-$Upstream.zip"
$Url = "https://github.com/BurntSushi/ripgrep/releases/download/$RipgrepVersion/$ArchiveName"

$WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "pabrik-rg-$Upstream"
$Archive = Join-Path $WorkDir $ArchiveName

function Get-HexDigest {
    param([string]$Path)
    return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
}

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

$cached = (Test-Path $Archive) -and ((Get-HexDigest $Archive) -eq $WantSha)
if ($cached) {
    Write-Output "reusing cached $ArchiveName"
} else {
    if (Test-Path $Archive) { Remove-Item $Archive -Force }
    Write-Output "downloading $ArchiveName"
    Invoke-WebRequest -Uri $Url -OutFile $Archive -UseBasicParsing -TimeoutSec 600
}

$GotSha = Get-HexDigest $Archive
if ($GotSha -ne $WantSha) {
    Remove-Item $Archive -Force -ErrorAction SilentlyContinue
    Write-Error "sha256 mismatch for ${ArchiveName}: expected $WantSha, got $GotSha"
    exit 1
}
Write-Output "sha256 ok ($WantSha)"

$ExtractDir = Join-Path $WorkDir "extract-$Upstream"
if (Test-Path $ExtractDir) { Remove-Item $ExtractDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $ExtractDir | Out-Null
Expand-Archive -Path $Archive -DestinationPath $ExtractDir -Force

$Member = Join-Path $ExtractDir "ripgrep-$RipgrepVersion-$Upstream\rg.exe"
if (-not (Test-Path $Member)) {
    $found = Get-ChildItem $ExtractDir -Recurse -Filter "rg.exe" | Select-Object -First 1
    if (-not $found) {
        Write-Error "the $Upstream archive carries no rg.exe"
        exit 1
    }
    $Member = $found.FullName
}

$DestDir = Split-Path -Parent $Dest
if ($DestDir -ne "" -and -not (Test-Path $DestDir)) {
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
}
Copy-Item -Force $Member $Dest

$VersionOut = ""
try { $VersionOut = (& $Dest --version | Select-Object -First 1) } catch { $VersionOut = "" }
if ($VersionOut) {
    Write-Output "staged bundled ripgrep -> $Dest ($VersionOut)"
} else {
    Write-Output "staged bundled ripgrep -> $Dest"
}
