param(
    [ValidateSet("combat-audio")]
    [string]$Preset = "combat-audio",

    [string[]]$AdditionalPaths = @(),

    [string]$WorkspaceConfigPath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

if ([string]::IsNullOrWhiteSpace($WorkspaceConfigPath)) {
    $WorkspaceConfigPath = Join-Path $PSScriptRoot "workspace.json"
}

if (-not (Test-Path -LiteralPath $WorkspaceConfigPath -PathType Leaf)) {
    throw "Workspace configuration was not found: $WorkspaceConfigPath"
}

try {
    $WorkspaceConfig = Get-Content -LiteralPath $WorkspaceConfigPath -Raw | ConvertFrom-Json
}
catch {
    throw "Workspace configuration is not valid JSON: $WorkspaceConfigPath`n$($_.Exception.Message)"
}

$RequiredConfigKeys = @(
    "project_root",
    "tools_root",
    "handoff_root",
    "asset_library_root",
    "pixel_art_upload_root",
    "sfx_root",
    "sfx_upload_root",
    "downloads_root"
)

foreach ($Key in $RequiredConfigKeys) {
    if (-not ($WorkspaceConfig.PSObject.Properties.Name -contains $Key)) {
        throw "Workspace configuration is missing required key: $Key"
    }

    $Value = [string]$WorkspaceConfig.$Key
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Workspace configuration key is empty: $Key"
    }
}

$ProjectRoot = [System.IO.Path]::GetFullPath([string]$WorkspaceConfig.project_root)
$ToolsRoot = [System.IO.Path]::GetFullPath([string]$WorkspaceConfig.tools_root)
$HandoffRoot = [System.IO.Path]::GetFullPath([string]$WorkspaceConfig.handoff_root)
$AssetLibraryRoot = [System.IO.Path]::GetFullPath([string]$WorkspaceConfig.asset_library_root)
$PixelArtUploadRoot = [System.IO.Path]::GetFullPath([string]$WorkspaceConfig.pixel_art_upload_root)
$SfxRoot = [System.IO.Path]::GetFullPath([string]$WorkspaceConfig.sfx_root)
$SfxUploadRoot = [System.IO.Path]::GetFullPath([string]$WorkspaceConfig.sfx_upload_root)
$DownloadsRoot = [System.IO.Path]::GetFullPath([string]$WorkspaceConfig.downloads_root)

$ProjectFile = Join-Path $ProjectRoot "project.godot"
$GitDirectory = Join-Path $ProjectRoot ".git"

$RequestPath = Join-Path $HandoffRoot "request.md"
$RuntimeLogPath = Join-Path $HandoffRoot "runtime.log"
$RuntimeSnapshotJsonPath = Join-Path $HandoffRoot "runtime_snapshot.json"
$RuntimeSnapshotTextPath = Join-Path $HandoffRoot "runtime_snapshot.txt"
$ScreenshotsRoot = Join-Path $HandoffRoot "screenshots"
$IssueZipPath = Join-Path $HandoffRoot "issue.zip"

$TemporaryRoot = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    ("dnd-issue-" + [guid]::NewGuid().ToString("N"))

$WorkRoot = Join-Path $TemporaryRoot "issue"
$TemporaryZipPath = Join-Path $TemporaryRoot "issue.zip"

$Warnings = New-Object System.Collections.Generic.List[string]
$CollectedRelativePaths = New-Object System.Collections.Generic.List[string]
$Manifest = New-Object System.Collections.Generic.List[object]

function Add-Warning {
    param([string]$Message)

    $Warnings.Add($Message)
    Write-Warning $Message
}

function Ensure-Directory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item `
            -ItemType Directory `
            -Path $Path `
            -Force |
            Out-Null
    }
}

function Copy-ProjectFile {
    param([string]$RelativePath)

    $SourcePath = Join-Path $ProjectRoot $RelativePath

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        Add-Warning ("Missing optional project file: " + $RelativePath)
        return
    }

    $DestinationPath = Join-Path `
        (Join-Path $WorkRoot "source") `
        $RelativePath

    Ensure-Directory (Split-Path $DestinationPath -Parent)

    Copy-Item `
        -LiteralPath $SourcePath `
        -Destination $DestinationPath `
        -Force

    $Item = Get-Item -LiteralPath $SourcePath
    $Hash = (
        Get-FileHash `
            -LiteralPath $SourcePath `
            -Algorithm SHA256
    ).Hash.ToLowerInvariant()

    $CollectedRelativePaths.Add($RelativePath)

    $Manifest.Add([pscustomobject]@{
        Kind = "project_source"
        RelativePath = $RelativePath.Replace("\", "/")
        SizeBytes = $Item.Length
        SHA256 = $Hash
    })
}

function Write-GitOutput {
    param(
        [string[]]$Arguments,
        [string]$DestinationPath,
        [string]$Description
    )

    try {
        $Output = @(& git @Arguments 2>&1)
        $ExitCode = $LASTEXITCODE

        $Output |
            Set-Content `
                -LiteralPath $DestinationPath `
                -Encoding UTF8

        if ($ExitCode -ne 0) {
            Add-Warning (
                $Description +
                " exited with code " +
                [string]$ExitCode +
                ". See " +
                $DestinationPath
            )
        }
    }
    catch {
        Add-Warning (
            "Could not capture " +
            $Description +
            ": " +
            $_.Exception.Message
        )

        (
            "Capture failed: " +
            $_.Exception.Message
        ) | Set-Content `
            -LiteralPath $DestinationPath `
            -Encoding UTF8
    }
}

if (-not (Test-Path -LiteralPath $ProjectFile -PathType Leaf)) {
    throw "Configured project_root does not contain project.godot: $ProjectRoot"
}

if (-not (Test-Path -LiteralPath $GitDirectory -PathType Container)) {
    throw "Configured project_root is not a Git working tree: $ProjectRoot"
}

if ([System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd("\") -ne $ToolsRoot.TrimEnd("\")) {
    throw "Collector location does not match configured tools_root. Script: $PSScriptRoot Configured: $ToolsRoot"
}

$PresetFiles = @(
    "project.godot",
    "scripts\framework\battle_scenario.gd",
    "scripts\infrastructure\runtime_diagnostics.gd",
    "scripts\presentation\combat_view_controller.gd",
    "scripts\presentation\combat_feedback_controller.gd",
    "scripts\presentation\combat_audio_presenter.gd",
    "scripts\presentation\unit_combat_audio_profile.gd",
    "scripts\presentation\grid_unit_view.gd",
    "scripts\presentation\projectile_presenter.gd",
    "scenes\battle\BattleScenario.tscn",
    "scenes\units\catapult.tscn",
    "scenes\units\crossbowman.tscn",
    "scenes\units\skeleton_archer.tscn",
    "data\audio\catapult_combat_audio_profile.tres",
    "data\audio\knight_combat_audio_profile.tres",
    "data\audio\skeleton_combat_audio_profile.tres",
    "default_bus_layout.tres"
)

$PresetFiles = @(
    $PresetFiles + $AdditionalPaths |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $_.TrimStart("\", "/") } |
    Select-Object -Unique
)

try {
    Write-Host "[1/7] Validating workspace configuration" -ForegroundColor Cyan
    Write-Host ("Config:  " + [System.IO.Path]::GetFullPath($WorkspaceConfigPath))
    Write-Host ("Project: " + $ProjectRoot)
    Write-Host ("Handoff: " + $HandoffRoot)

    Write-Host "[2/7] Preparing stable handoff directories" -ForegroundColor Cyan
    Ensure-Directory $HandoffRoot
    Ensure-Directory $ScreenshotsRoot
    Ensure-Directory $WorkRoot
    Ensure-Directory (Join-Path $WorkRoot "git")
    Ensure-Directory (Join-Path $WorkRoot "evidence")
    Ensure-Directory (Join-Path $WorkRoot "static")

    Write-Host "[3/7] Collecting runtime evidence" -ForegroundColor Cyan

    if (Test-Path -LiteralPath $RequestPath -PathType Leaf) {
        Copy-Item `
            -LiteralPath $RequestPath `
            -Destination (Join-Path $WorkRoot "request.md") `
            -Force
    }
    else {
        Add-Warning (
            "request.md was not found. The issue packet will still be created."
        )

        @"
# Issue Request

## Expected

## Actual

## Reproduction Steps

## Runtime Evidence

## Scope

## Out of Scope
"@ | Set-Content `
            -LiteralPath (Join-Path $WorkRoot "request.md") `
            -Encoding UTF8
    }

    if (Test-Path -LiteralPath $RuntimeLogPath -PathType Leaf) {
        Copy-Item `
            -LiteralPath $RuntimeLogPath `
            -Destination (Join-Path $WorkRoot "evidence\runtime.log") `
            -Force
    }
    else {
        Add-Warning (
            ("runtime.log was not found under the configured handoff_root: " + $HandoffRoot)
        )
    }


    $RuntimeSnapshotFiles = @(
        @{
            Source = $RuntimeSnapshotJsonPath
            Name = "runtime_snapshot.json"
        },
        @{
            Source = $RuntimeSnapshotTextPath
            Name = "runtime_snapshot.txt"
        }
    )

    foreach ($SnapshotFile in $RuntimeSnapshotFiles) {
        if (Test-Path -LiteralPath $SnapshotFile.Source -PathType Leaf) {
            Copy-Item `
                -LiteralPath $SnapshotFile.Source `
                -Destination (Join-Path $WorkRoot ("evidence\" + $SnapshotFile.Name)) `
                -Force
        }
        else {
            Add-Warning (
                $SnapshotFile.Name +
                " was not found. Press F12 during runtime before collecting when live state is relevant."
            )
        }
    }

    $ScreenshotFiles = @()

    if (Test-Path -LiteralPath $ScreenshotsRoot -PathType Container) {
        $ScreenshotFiles = @(
            Get-ChildItem `
                -LiteralPath $ScreenshotsRoot `
                -File `
                -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Extension.ToLowerInvariant() -in @(
                    ".png",
                    ".jpg",
                    ".jpeg",
                    ".webp"
                )
            }
        )
    }

    if ($ScreenshotFiles.Count -gt 0) {
        $EvidenceScreenshotsRoot = Join-Path $WorkRoot "evidence\screenshots"
        Ensure-Directory $EvidenceScreenshotsRoot

        foreach ($Screenshot in $ScreenshotFiles) {
            Copy-Item `
                -LiteralPath $Screenshot.FullName `
                -Destination (Join-Path $EvidenceScreenshotsRoot $Screenshot.Name) `
                -Force
        }
    }
    else {
        Add-Warning (
            ("No screenshots were found under the configured screenshots folder: " + $ScreenshotsRoot)
        )
    }

    Write-Host "[4/7] Collecting focused project source" -ForegroundColor Cyan

    foreach ($RelativePath in $PresetFiles) {
        Copy-ProjectFile $RelativePath
    }

    Write-Host "[5/7] Capturing Git state" -ForegroundColor Cyan

    $GitRoot = Join-Path $WorkRoot "git"

    Write-GitOutput `
        -Arguments @("-C", $ProjectRoot, "status", "--short") `
        -DestinationPath (Join-Path $GitRoot "status.txt") `
        -Description "Git status"

    Write-GitOutput `
        -Arguments @("-C", $ProjectRoot, "branch", "--show-current") `
        -DestinationPath (Join-Path $GitRoot "branch.txt") `
        -Description "Git branch"

    Write-GitOutput `
        -Arguments @("-C", $ProjectRoot, "rev-parse", "HEAD") `
        -DestinationPath (Join-Path $GitRoot "head.txt") `
        -Description "Git HEAD"

    $DiffArguments = @(
        "-C",
        $ProjectRoot,
        "diff",
        "--binary",
        "--"
    ) + @($CollectedRelativePaths)

    Write-GitOutput `
        -Arguments $DiffArguments `
        -DestinationPath (Join-Path $GitRoot "selected_diff.patch") `
        -Description "selected Git diff"

    $SourceTreePath = Join-Path $WorkRoot "static\source_tree.txt"

    @($CollectedRelativePaths) |
        Sort-Object |
        ForEach-Object {
            $_.Replace("\", "/")
        } |
        Set-Content `
            -LiteralPath $SourceTreePath `
            -Encoding UTF8

    Copy-Item `
        -LiteralPath $WorkspaceConfigPath `
        -Destination (Join-Path $WorkRoot "static\workspace.json") `
        -Force

    $EnvironmentSnapshot = [ordered]@{
        collector_version = "workspace-1"
        preset = $Preset
        collected_at_local = (Get-Date).ToString("o")
        workspace_config_path = [System.IO.Path]::GetFullPath($WorkspaceConfigPath)
        project_root = $ProjectRoot
        tools_root = $ToolsRoot
        handoff_root = $HandoffRoot
        asset_library_root = $AssetLibraryRoot
        pixel_art_upload_root = $PixelArtUploadRoot
        sfx_root = $SfxRoot
        sfx_upload_root = $SfxUploadRoot
        downloads_root = $DownloadsRoot
        powershell_version = $PSVersionTable.PSVersion.ToString()
        operating_system = [Environment]::OSVersion.VersionString
        machine_name = $env:COMPUTERNAME
        user_name = $env:USERNAME
    }

    $EnvironmentSnapshot |
        ConvertTo-Json -Depth 4 |
        Set-Content `
            -LiteralPath (Join-Path $WorkRoot "static\environment.json") `
            -Encoding UTF8

    $Manifest |
        Export-Csv `
            -LiteralPath (Join-Path $WorkRoot "static\manifest.csv") `
            -NoTypeInformation `
            -Encoding UTF8

    if ($Warnings.Count -gt 0) {
        $Warnings |
            Set-Content `
                -LiteralPath (Join-Path $WorkRoot "collector_warnings.txt") `
                -Encoding UTF8
    }
    else {
        "No collector warnings." |
            Set-Content `
                -LiteralPath (Join-Path $WorkRoot "collector_warnings.txt") `
                -Encoding UTF8
    }

    @"
DND Workspace Collector

Preset:
$Preset

The packet contains:
- request.md
- exact focused source files
- Git branch, HEAD, status, and selected diff
- optional runtime.log
- optional runtime_snapshot.json and runtime_snapshot.txt
- optional screenshots
- source hashes and environment information

Workspace configuration:
$WorkspaceConfigPath

The collector does not modify the Godot project.
"@ | Set-Content `
        -LiteralPath (Join-Path $WorkRoot "README.txt") `
        -Encoding UTF8

    Write-Host "[6/7] Building and verifying issue.zip" -ForegroundColor Cyan

    Compress-Archive `
        -Path (Join-Path $WorkRoot "*") `
        -DestinationPath $TemporaryZipPath `
        -CompressionLevel Optimal

    if (-not (Test-Path -LiteralPath $TemporaryZipPath -PathType Leaf)) {
        throw "The collector did not create the temporary issue ZIP."
    }

    $TemporaryZip = Get-Item -LiteralPath $TemporaryZipPath

    if ($TemporaryZip.Length -le 0) {
        throw "The collector created an empty issue ZIP."
    }

    if (Test-Path -LiteralPath $IssueZipPath -PathType Leaf) {
        Remove-Item -LiteralPath $IssueZipPath -Force
    }

    Move-Item `
        -LiteralPath $TemporaryZipPath `
        -Destination $IssueZipPath `
        -Force

    Write-Host "[7/7] Collection complete" -ForegroundColor Green
    Write-Host ""
    Write-Host "DND issue packet created." -ForegroundColor Green
    Write-Host ""
    Write-Host "Upload:"
    Write-Host ("  " + $IssueZipPath) -ForegroundColor Cyan
    Write-Host ""
    Write-Host (
        "Focused project files collected: " +
        [string]$CollectedRelativePaths.Count
    )
    Write-Host (
        "Warnings: " +
        [string]$Warnings.Count
    )
    Write-Host ""
    Write-Host "The Godot project was not modified." -ForegroundColor Yellow
}
finally {
    if (Test-Path -LiteralPath $TemporaryRoot) {
        Remove-Item `
            -LiteralPath $TemporaryRoot `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}
