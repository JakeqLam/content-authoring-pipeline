[CmdletBinding()]
param(
    [string]$WorkspaceRoot = (Join-Path $env:USERPROFILE "dnd-workspace")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$WorkspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)
$ToolsRoot = Join-Path $WorkspaceRoot "dnd-dev-tools"
$ConfigPath = Join-Path $ToolsRoot "workspace.json"

Write-Host "[1/5] Loading configuration" -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Missing workspace.json: $ConfigPath"
}
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

Write-Host "[2/5] Validating paths" -ForegroundColor Cyan
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

Write-Host "[3/5] Validating Git boundaries" -ForegroundColor Cyan
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

Write-Host "[4/5] Validating diagnostic workflow" -ForegroundColor Cyan
foreach ($relative in @("screenshots", "profiler", "logs", "captures", "backups\issue-packets")) {
    $path = Join-Path ([string]$config.handoff_root) $relative
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    Write-Host "PASS handoff/$relative = $path"
}
foreach ($toolName in @(
    "collect_issue_diagnostics.ps1",
    "collect-issue.ps1",
    "collect-issue.cmd",
    "Import-GodotProfilerExport.ps1",
    "Validate-DndIssuePacket.ps1"
)) {
    $toolPath = Join-Path ([string]$config.tools_root) $toolName
    if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
        throw "Missing diagnostic tool: $toolPath"
    }
    Write-Host "PASS tool = $toolPath"
}

Write-Host "[5/5] Workspace validation passed" -ForegroundColor Green
Write-Host "Pipeline origin: $(& git -C ([string]$config.tools_root) remote get-url origin)"
