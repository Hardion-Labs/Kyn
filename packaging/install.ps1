<#
.SYNOPSIS
    Kyn toolchain installer for Windows.

.DESCRIPTION
    Installs the prebuilt kync.exe and kyn-build.exe binaries shipped in this
    archive into a prefix (default: %LOCALAPPDATA%\Programs\Kyn), adds the
    bin directory to the per-user PATH, and verifies the installation by
    running both binaries.

.EXAMPLE
    .\install.ps1
    Install into %LOCALAPPDATA%\Programs\Kyn and update the user PATH.

.EXAMPLE
    .\install.ps1 -Prefix "C:\tools\kyn"
    Install into C:\tools\kyn.

.EXAMPLE
    .\install.ps1 -Uninstall
    Remove the installed binaries and the PATH entry.
#>
[CmdletBinding()]
param(
    [string]$Prefix = (Join-Path $env:LOCALAPPDATA 'Programs\Kyn'),
    [switch]$Uninstall,
    [switch]$NoPath
)

$ErrorActionPreference = 'Stop'

$Tools     = @('kync.exe', 'kyn-build.exe')
$BinDir    = Join-Path $Prefix 'bin'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SrcBin    = Join-Path $ScriptDir 'bin'

function Get-UserPathEntries {
    $raw = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    return @($raw -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

function Normalize-PathEntry([string]$entry) {
    return $entry.TrimEnd('\').ToLowerInvariant()
}

function Remove-FromUserPath([string]$dir) {
    $target  = Normalize-PathEntry $dir
    $entries = Get-UserPathEntries
    $kept    = @($entries | Where-Object { (Normalize-PathEntry $_) -ne $target })
    $removed = $entries.Count - $kept.Count
    [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
    return $removed
}

function Add-ToUserPath([string]$dir) {
    $target  = Normalize-PathEntry $dir
    $entries = Get-UserPathEntries
    foreach ($entry in $entries) {
        if ((Normalize-PathEntry $entry) -eq $target) {
            Write-Host "PATH already contains $dir (user scope)"
            return
        }
    }
    [Environment]::SetEnvironmentVariable('Path', (($entries + $dir) -join ';'), 'User')
    # Also refresh this session so the binaries are usable immediately.
    $env:Path = "$env:Path;$dir"
    Write-Host "added $dir to the user PATH (new terminals pick it up automatically)"
}

if ($Uninstall) {
    Write-Host "Uninstalling Kyn from $Prefix"
    $removed = 0
    foreach ($tool in $Tools) {
        $target = Join-Path $BinDir $tool
        if (Test-Path $target) {
            Remove-Item -Force $target
            Write-Host "removed $target"
            $removed++
        }
    }
    foreach ($dir in @($BinDir, $Prefix)) {
        if ((Test-Path $dir) -and -not (Get-ChildItem -Force $dir | Select-Object -First 1)) {
            Remove-Item -Force $dir
            Write-Host "removed empty directory $dir"
        }
    }
    $pathRemoved = Remove-FromUserPath $BinDir
    if ($pathRemoved -gt 0) {
        Write-Host "removed $BinDir from the user PATH"
    } else {
        Write-Host "user PATH did not reference $BinDir"
    }
    if ($removed -eq 0) {
        Write-Host "nothing to remove (no Kyn binaries found in $BinDir)"
    } else {
        Write-Host "uninstalled $removed file(s)"
    }
    exit 0
}

foreach ($tool in $Tools) {
    $src = Join-Path $SrcBin $tool
    if (-not (Test-Path $src)) {
        throw "'$tool' not found in $SrcBin. Run this script from the extracted release archive root."
    }
}

New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

foreach ($tool in $Tools) {
    Copy-Item -Force (Join-Path $SrcBin $tool) (Join-Path $BinDir $tool)
    Write-Host "installed $(Join-Path $BinDir $tool)"
}

if (-not $NoPath) {
    Add-ToUserPath $BinDir
}

# Verify the installation actually works, not just that the files copied.
foreach ($tool in $Tools) {
    $output = & (Join-Path $BinDir $tool) --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "installed '$tool' does not run (exit code $LASTEXITCODE): $output"
    }
    Write-Host "ok: $output"
}

Write-Host ''
Write-Host 'Kyn installed successfully. Try: kync --version'
Write-Host "Uninstall any time with: .\install.ps1 -Uninstall -Prefix `"$Prefix`""
