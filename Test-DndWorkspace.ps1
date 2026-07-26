[CmdletBinding()]
param(
    [string]$WorkspaceRoot = (Join-Path $env:USERPROFILE "dnd-workspace")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$WorkspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)
$ToolsRoot = Join-Path $WorkspaceRoot "dnd-dev-tools"
$ConfigPath = Join-Path $ToolsRoot "workspace.json"

Write-Host "[1/4] Loading configuration" -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Missing workspace.json: $ConfigPath"
}
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

Write-Host "[2/4] Validating paths" -ForegroundColor Cyan
$required = @(
    "workspace_root","project_root","tools_root","handoff_root",
    "asset_library_root","pixel_art_upload_root","sfx_root",
    "sfx_upload_root","downloads_root"
)
foreach ($name in $required) {
    $value = [string]$config.$name
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Missing property: $name" }
    if (-not (Test-Path -LiteralPath $value)) { throw "Missing path: $name = $value" }
    Write-Host "PASS $name = $value"
}

Write-Host "[3/4] Validating Git boundaries" -ForegroundColor Cyan
if (Test-Path -LiteralPath (Join-Path $WorkspaceRoot ".git") -PathType Container) {
    throw "Workspace root must not be a Git repository."
}
if (-not (Test-Path -LiteralPath (Join-Path ([string]$config.tools_root) ".git") -PathType Container)) {
    throw "Pipeline repository missing: $($config.tools_root)"
}
if (-not (Test-Path -LiteralPath (Join-Path ([string]$config.project_root) ".git") -PathType Container)) {
    Write-Host "WARN Game project is not currently a Git repository." -ForegroundColor Yellow
}
else {
    Write-Host "PASS Game project is an independent Git repository."
}

Write-Host "[4/4] Workspace validation passed" -ForegroundColor Green
Write-Host "Pipeline origin: $(& git -C ([string]$config.tools_root) remote get-url origin)"
