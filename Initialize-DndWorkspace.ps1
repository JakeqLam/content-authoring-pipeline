[CmdletBinding()]
param(
    [string]$WorkspaceRoot = (Join-Path $env:USERPROFILE "dnd-workspace"),
    [string]$PipelineRepoUrl = "https://github.com/JakeqLam/content-authoring-pipeline.git",
    [string]$GameRepoUrl = "",
    [switch]$ForceConfig
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Write-Host "Created: $Path"
    }
}

$WorkspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)
$ToolsRoot = Join-Path $WorkspaceRoot "dnd-dev-tools"
$ProjectRoot = Join-Path $WorkspaceRoot "dnd-prototype"
$HandoffRoot = Join-Path $WorkspaceRoot "dnd-handoff"
$AssetRoot = Join-Path $WorkspaceRoot "asset-library"
$PixelUpload = Join-Path $AssetRoot "pixel-art\asset-upload"
$SfxRoot = Join-Path $AssetRoot "sfx"
$SfxUpload = Join-Path $SfxRoot "asset-upload"
$Downloads = Join-Path $env:USERPROFILE "Downloads"

Write-Host "[1/5] Creating canonical folders" -ForegroundColor Cyan
@(
    $WorkspaceRoot,
    $AssetRoot,
    (Join-Path $AssetRoot "fonts"),
    (Join-Path $AssetRoot "pixel-art"),
    $PixelUpload,
    $SfxRoot,
    $SfxUpload,
    (Join-Path $AssetRoot "temp"),
    (Join-Path $AssetRoot "tilesets"),
    $HandoffRoot,
    (Join-Path $HandoffRoot "screenshots")
) | ForEach-Object { Ensure-Directory -Path $_ }

Write-Host "[2/5] Preparing pipeline repository" -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath (Join-Path $ToolsRoot ".git") -PathType Container)) {
    if (Test-Path -LiteralPath $ToolsRoot -PathType Container) {
        $items = @(Get-ChildItem -LiteralPath $ToolsRoot -Force)
        if ($items.Count -gt 0) {
            throw "Pipeline folder exists but is not a Git repository: $ToolsRoot"
        }
        Remove-Item -LiteralPath $ToolsRoot -Force
    }
    & git clone $PipelineRepoUrl $ToolsRoot
    if ($LASTEXITCODE -ne 0) { throw "Pipeline clone failed." }
}

Write-Host "[3/5] Preparing game repository location" -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot ".git") -PathType Container)) {
    if (-not [string]::IsNullOrWhiteSpace($GameRepoUrl)) {
        if (Test-Path -LiteralPath $ProjectRoot -PathType Container) {
            $items = @(Get-ChildItem -LiteralPath $ProjectRoot -Force)
            if ($items.Count -gt 0) {
                throw "Game project folder is not empty: $ProjectRoot"
            }
            Remove-Item -LiteralPath $ProjectRoot -Force
        }
        & git clone $GameRepoUrl $ProjectRoot
        if ($LASTEXITCODE -ne 0) { throw "Game clone failed." }
    }
    else {
        Ensure-Directory -Path $ProjectRoot
        Write-Host "GameRepoUrl not supplied; project folder exists but was not cloned." -ForegroundColor Yellow
    }
}

Write-Host "[4/5] Writing workspace.json" -ForegroundColor Cyan
$configPath = Join-Path $ToolsRoot "workspace.json"
if ((Test-Path -LiteralPath $configPath -PathType Leaf) -and -not $ForceConfig) {
    Write-Host "Preserved existing workspace.json"
}
else {
    [ordered]@{
        schema_version = 1
        workspace_root = $WorkspaceRoot
        project_root = $ProjectRoot
        tools_root = $ToolsRoot
        handoff_root = $HandoffRoot
        asset_library_root = $AssetRoot
        pixel_art_upload_root = $PixelUpload
        sfx_root = $SfxRoot
        sfx_upload_root = $SfxUpload
        downloads_root = $Downloads
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath -Encoding UTF8
}

Write-Host "[5/5] Workspace initialized" -ForegroundColor Green
& (Join-Path $ToolsRoot "Test-DndWorkspace.ps1") -WorkspaceRoot $WorkspaceRoot
