[CmdletBinding()]
param(
    [ValidateSet("ranged-engagement", "unit-content-authoring")]
    [string]$Preset = "ranged-engagement"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host ("[DND-COLLECT] " + $Message) -ForegroundColor Cyan
}

function Read-Utf8Text {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Read-ZipEntryText {
    param(
        [System.IO.Compression.ZipArchive]$Archive,
        [string]$EntryName
    )

    $normalizedName = $EntryName.Replace('\', '/')
    $entry = $Archive.Entries |
        Where-Object { $_.FullName.Replace('\', '/') -eq $normalizedName } |
        Select-Object -First 1

    if ($null -eq $entry) {
        throw "Generated issue packet is missing required entry: $EntryName"
    }

    $reader = New-Object System.IO.StreamReader($entry.Open())
    try {
        return $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }
}

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$configCandidates = @(
    (Join-Path $scriptDirectory "workspace.json"),
    (Join-Path $env:USERPROFILE "dnd-workspace\dnd-dev-tools\workspace.json")
)

$configPath = $null
foreach ($candidate in $configCandidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $configPath = $candidate
        break
    }
}

if ([string]::IsNullOrWhiteSpace($configPath)) {
    throw "Could not find workspace.json beside this script or in the canonical dnd-workspace tools directory."
}

Write-Step ("Reading workspace configuration: " + $configPath)
$config = (Read-Utf8Text -Path $configPath) | ConvertFrom-Json

foreach ($propertyName in @("tools_root", "handoff_root")) {
    if ($null -eq $config.PSObject.Properties[$propertyName]) {
        throw "workspace.json is missing required property: $propertyName"
    }
}

$toolsRoot = [string]$config.tools_root
$handoffRoot = [string]$config.handoff_root

if (-not (Test-Path -LiteralPath $toolsRoot -PathType Container)) {
    throw "Configured tools_root does not exist: $toolsRoot"
}
if (-not (Test-Path -LiteralPath $handoffRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $handoffRoot -Force | Out-Null
}

$collector = Join-Path $toolsRoot "collect_issue_unit_content.ps1"
if (-not (Test-Path -LiteralPath $collector -PathType Leaf)) {
    throw "Collector v2 is missing: $collector"
}

$issuePath = Join-Path $handoffRoot "issue.zip"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

# Move any prior packet out of the canonical output path. This prevents a failed
# collection from leaving a stale issue.zip that looks newly generated.
if (Test-Path -LiteralPath $issuePath -PathType Leaf) {
    $backupDirectory = Join-Path $handoffRoot "backups\issue-packets"
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    $backupPath = Join-Path $backupDirectory ("issue-before-" + $Preset + "-" + $timestamp + ".zip")
    Move-Item -LiteralPath $issuePath -Destination $backupPath -Force
    Write-Step ("Moved previous issue.zip to: " + $backupPath)
}

Write-Step ("Running Collector v2 preset: " + $Preset)
& powershell.exe `
    -NoLogo `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $collector `
    -Preset $Preset

if ($LASTEXITCODE -ne 0) {
    throw "Collector v2 failed with exit code $LASTEXITCODE."
}

if (-not (Test-Path -LiteralPath $issuePath -PathType Leaf)) {
    throw "Collector completed without producing: $issuePath"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($issuePath)
try {
    $readme = Read-ZipEntryText -Archive $archive -EntryName "README.txt"
    $request = Read-ZipEntryText -Archive $archive -EntryName "request.md"
    $null = Read-ZipEntryText -Archive $archive -EntryName "static/manifest.csv"

    if (-not $readme.Contains("DND Workspace Collector v2")) {
        throw "Generated issue.zip is not a Collector v2 packet."
    }

    $expectedPresetLine = "Preset: " + $Preset
    if (-not $readme.Contains($expectedPresetLine)) {
        throw "Generated packet used the wrong preset. Expected '$expectedPresetLine'."
    }

    if ([string]::IsNullOrWhiteSpace($request)) {
        throw "Generated request.md is empty."
    }

    $sourceFiles = @(
        $archive.Entries |
            Where-Object {
                $_.FullName.Replace('\', '/').StartsWith("source/") -and
                -not $_.FullName.EndsWith("/")
            }
    )

    $minimumSourceFiles = 20
    if ($Preset -eq "ranged-engagement") {
        $minimumSourceFiles = 50
    }

    if ($sourceFiles.Count -lt $minimumSourceFiles) {
        throw "Generated packet is suspiciously small: $($sourceFiles.Count) source files; expected at least $minimumSourceFiles."
    }

    Write-Host ("[PASS] Collector v2 packet validated") -ForegroundColor Green
    Write-Host ("Preset: " + $Preset)
    Write-Host ("Source/dependency files: " + $sourceFiles.Count)
}
finally {
    $archive.Dispose()
}

$downloads = Join-Path $env:USERPROFILE "Downloads"
if (-not (Test-Path -LiteralPath $downloads -PathType Container)) {
    throw "Downloads directory does not exist: $downloads"
}

$uploadName = $Preset + "-issue-" + $timestamp + ".zip"
$uploadPath = Join-Path $downloads $uploadName
Copy-Item -LiteralPath $issuePath -Destination $uploadPath -Force

$hash = (Get-FileHash -LiteralPath $uploadPath -Algorithm SHA256).Hash.ToLowerInvariant()
$pointerPath = Join-Path $handoffRoot "latest_issue.txt"
$pointerText = @(
    "preset=" + $Preset
    "canonical_issue=" + $issuePath
    "upload_copy=" + $uploadPath
    "sha256=" + $hash
) -join [Environment]::NewLine
[System.IO.File]::WriteAllText(
    $pointerPath,
    $pointerText + [Environment]::NewLine,
    (New-Object System.Text.UTF8Encoding($false))
)

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " ISSUE PACKET READY" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ("Canonical packet: " + $issuePath)
Write-Host ("UPLOAD THIS FILE: " + $uploadPath) -ForegroundColor Yellow
Write-Host ("SHA256: " + $hash)
Write-Host ("Pointer file: " + $pointerPath)
