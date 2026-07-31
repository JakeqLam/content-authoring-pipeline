[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string[]]$Path,

    [string]$Label = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Write-Utf8NoBom {
    param([string]$TargetPath, [string]$Text)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($TargetPath, $Text, $encoding)
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptRoot "workspace.json"
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    $configPath = Join-Path $env:USERPROFILE "dnd-workspace\dnd-dev-tools\workspace.json"
}
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "workspace.json was not found."
}

$config = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$profilerRoot = Join-Path ([string]$config.handoff_root) "profiler"
New-Item -ItemType Directory -Path $profilerRoot -Force | Out-Null
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$index = 0

foreach ($inputPath in $Path) {
    if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
        throw "Profiler export was not found: $inputPath"
    }
    $index += 1
    $item = Get-Item -LiteralPath $inputPath
    $safeLabel = $Label
    if ([string]::IsNullOrWhiteSpace($safeLabel)) {
        $safeLabel = [System.IO.Path]::GetFileNameWithoutExtension($item.Name)
    }
    $safeLabel = [regex]::Replace($safeLabel, '[^A-Za-z0-9._-]+', '-')
    $extension = $item.Extension
    if ([string]::IsNullOrWhiteSpace($extension)) { $extension = ".txt" }
    $destinationName = ("{0}-{1:D2}-{2}{3}" -f $timestamp, $index, $safeLabel, $extension)
    $destinationPath = Join-Path $profilerRoot $destinationName
    Copy-Item -LiteralPath $item.FullName -Destination $destinationPath -Force

    $firstLine = ""
    try { $firstLine = [string](Get-Content -LiteralPath $destinationPath -TotalCount 1) } catch {}
    $classification = "unknown"
    if ($firstLine -match '^Resource Path,Type,Format,Usage') {
        $classification = "godot_video_ram_csv"
    }
    elseif ($firstLine -match 'Frame|Time|CPU|GPU|Monitor') {
        $classification = "godot_profiler_or_monitor_export"
    }

    $metadata = [ordered]@{
        schema_version = 1
        imported_at_local = (Get-Date).ToString("o")
        original_path = $item.FullName
        copied_path = $destinationPath
        classification = $classification
        size_bytes = (Get-Item -LiteralPath $destinationPath).Length
        sha256 = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    Write-Utf8NoBom -TargetPath ($destinationPath + ".metadata.json") -Text (($metadata | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
    Write-Host ("Imported profiler evidence: " + $destinationPath) -ForegroundColor Green
    Write-Host ("Classification: " + $classification)
}

Write-Host "Run collect-issue.cmd after reproducing and pressing F12." -ForegroundColor Cyan
