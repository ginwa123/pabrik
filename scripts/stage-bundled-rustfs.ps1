[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Target,
    [string]$Dest = "zig-out/bin/pabrik-fs.exe"
)

$ErrorActionPreference = "Stop"

$RustfsVersion = "1.0.4"

$Pinned = @{
    "x86_64-windows-gnu" = @{ Upstream = "windows-x86_64"; Sha256 = "2e3af0b187dd70435dfdefe5f61aae7eede5a21fc9a2a2f07e289f727adbcfa6" }
}

if (-not $Pinned.ContainsKey($Target)) {
    throw "no bundled rustfs is published for triple '$Target' (known: $($Pinned.Keys -join ', '))"
}

$Upstream = $Pinned[$Target].Upstream
$WantSha = $Pinned[$Target].Sha256
$ArchiveName = "rustfs-$Upstream-v$RustfsVersion.zip"
$Url = "https://github.com/rustfs/rustfs/releases/download/$RustfsVersion/$ArchiveName"

$WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "pabrik-rustfs-$Upstream"
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
    Invoke-WebRequest -Uri $Url -OutFile $Archive -UseBasicParsing -TimeoutSec 900
}

$GotSha = Get-HexDigest $Archive
if ($GotSha -ne $WantSha) {
    Remove-Item $Archive -Force -ErrorAction SilentlyContinue
    throw "sha256 mismatch for ${ArchiveName}: expected $WantSha, got $GotSha"
}
Write-Output "sha256 ok ($WantSha)"

$ExtractDir = Join-Path $WorkDir "extract-$Upstream"
if (Test-Path $ExtractDir) { Remove-Item $ExtractDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $ExtractDir | Out-Null
Expand-Archive -Path $Archive -DestinationPath $ExtractDir -Force

$Member = Join-Path $ExtractDir "rustfs.exe"
if (-not (Test-Path $Member)) {
    $found = Get-ChildItem $ExtractDir -Recurse -Filter "rustfs.exe" | Select-Object -First 1
    if (-not $found) {
        throw "the $Upstream archive carries no rustfs.exe"
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
    Write-Output "staged bundled rustfs -> $Dest ($VersionOut)"
} else {
    Write-Output "staged bundled rustfs -> $Dest"
}
