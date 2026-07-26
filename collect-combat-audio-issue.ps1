$ErrorActionPreference = "Stop"

$ConfigPath = Join-Path `
    $env:USERPROFILE `
    "dnd-workspace\dnd-dev-tools\workspace.json"

Write-Host "[1/4] Loading workspace configuration" -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Missing workspace configuration: $ConfigPath"
}

$Config = (
    [System.IO.File]::ReadAllText(
        $ConfigPath,
        [System.Text.Encoding]::UTF8
    ) | ConvertFrom-Json
)

$Validator = Join-Path `
    ([string]$Config.tools_root) `
    "Test-DndWorkspace.ps1"

$Collector = Join-Path `
    ([string]$Config.tools_root) `
    "collect_issue.ps1"

Write-Host "[2/4] Validating workspace" -ForegroundColor Cyan

& $Validator `
    -WorkspaceRoot ([string]$Config.workspace_root)

Write-Host "[3/4] Collecting current combat-audio evidence" -ForegroundColor Cyan

& $Collector -Preset combat-audio

Write-Host "[4/4] Verifying issue packet" -ForegroundColor Cyan

$Issue = Join-Path `
    ([string]$Config.handoff_root) `
    "issue.zip"

if (-not (Test-Path -LiteralPath $Issue -PathType Leaf)) {
    throw "Collector completed without producing issue.zip: $Issue"
}

$File = Get-Item -LiteralPath $Issue
$Hash = Get-FileHash -LiteralPath $Issue -Algorithm SHA256

Write-Host "Issue packet ready." -ForegroundColor Green
Write-Host "Path:    $($File.FullName)"
Write-Host "Size:    $($File.Length) bytes"
Write-Host "SHA256:  $($Hash.Hash)"
Write-Host "Updated: $($File.LastWriteTime)"