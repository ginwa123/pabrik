[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Target,
    [string]$Dest = "zig-out/bin/pabrik-fs.exe"
)

$ErrorActionPreference = "Stop"

$RustfsVersion = "1.0.4"

$Pinned = @{
    "x86_64-windows-gnu" = @{ AssetId = "675523770"; Upstream = "windows-x86_64"; Sha256 = "2e3af0b187dd70435dfdefe5f61aae7eede5a21fc9a2a2f07e289f727adbcfa6" }
}

if (-not $Pinned.ContainsKey($Target)) {
    throw "no bundled rustfs is published for triple '$Target' (known: $($Pinned.Keys -join ', '))"
}

$Upstream = $Pinned[$Target].Upstream
$WantSha = $Pinned[$Target].Sha256
$ArchiveName = "rustfs-$Upstream-v$RustfsVersion.zip"
# The canonical release URL. Preferred over the API: the API asset endpoint is
# capped at 60 requests/hour per IP, and CI runners share an IP.
$Url = "https://github.com/rustfs/rustfs/releases/download/$RustfsVersion/$ArchiveName"
# Fallback for when the release CDN answers 504 (observed 2026-11-08).
$ApiUrl = "https://api.github.com/repos/rustfs/rustfs/releases/assets/$($Pinned[$Target].AssetId)"

$WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) "pabrik-rustfs-$Upstream"
$Archive = Join-Path $WorkDir $ArchiveName

function Get-HexDigest {
    param([string]$Path)
    return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
}

function Remove-DebugSections {
    param([string]$Path)

    if ($env:PABRIK_RUSTFS_NO_STRIP -eq "1") {
        Write-Output "PABRIK_RUSTFS_NO_STRIP=1; the bundled rustfs keeps its debug sections"
        return
    }

    $tool = $null
    foreach ($name in @("llvm-strip", "strip")) {
        $found = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $tool = $found.Source; break }
    }
    if (-not $tool) {
        Write-Output "warning: no llvm-strip or strip on PATH; the bundled rustfs keeps its debug sections"
        return
    }

    $before = (Get-Item -LiteralPath $Path).Length
    $backup = "$Path.unstripped"
    Copy-Item -Force -LiteralPath $Path -Destination $backup

    $code = 1
    try {
        & $tool --strip-all $Path 2>$null | Out-Null
        $code = $LASTEXITCODE
    } catch {
        $code = 1
    }
    if ($code -ne 0) {
        Move-Item -Force -LiteralPath $backup -Destination $Path
        Write-Output "warning: $tool could not strip the bundled rustfs; keeping the original"
        return
    }

    $after = (Get-Item -LiteralPath $Path).Length
    if ($after -ge $before) {
        Move-Item -Force -LiteralPath $backup -Destination $Path
        Write-Output "warning: stripping did not shrink the bundled rustfs; keeping the original"
        return
    }

    Remove-Item -Force -LiteralPath $backup
    Write-Output "stripped the bundled rustfs: $before -> $after bytes"
}

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

$cached = (Test-Path $Archive) -and ((Get-HexDigest $Archive) -eq $WantSha)
if ($cached) {
    Write-Output "reusing cached $ArchiveName"
} else {
    if (Test-Path $Archive) { Remove-Item $Archive -Force }
    Write-Output "downloading $ArchiveName"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Archive -UseBasicParsing -TimeoutSec 900
    } catch {
        Write-Output "release CDN failed; retrying through the API asset endpoint"
        Invoke-WebRequest -Uri $ApiUrl -OutFile $Archive -UseBasicParsing -TimeoutSec 900 `
            -Headers @{ "Accept" = "application/octet-stream" }
    }
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
Remove-DebugSections -Path $Member

$MemberSha = Get-HexDigest $Member
try {
    Copy-Item -Force $Member $Dest
} catch {
    # A running pabrik-fs.exe holds a lock on the destination (a smoke test
    # that booted the backend leaves one behind on Windows). If the file
    # already there is byte-identical to the extracted member, the staging
    # goal is met and there is nothing to replace.
    if ((Test-Path $Dest) -and ((Get-HexDigest $Dest) -eq $MemberSha)) {
        Write-Output "pabrik-fs.exe is in use; the staged copy already matches the extracted binary"
    } else {
        throw $_
    }
}

# The version is the pinned constant, not a probe: executing the staged binary
# on Windows leaves a process behind that locks the file.
Write-Output "staged bundled rustfs -> $Dest (rustfs $RustfsVersion)"
