[CmdletBinding()]
param(
    [ValidateSet(
        "full-diagnostics",
        "movement",
        "combat",
        "terrain",
        "unit-content-authoring"
    )]
    [string]$Preset = "full-diagnostics",

    [string[]]$AdditionalPaths = @()
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

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
    throw "workspace.json was not found."
}

$config = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$collector = Join-Path ([string]$config.tools_root) "collect_issue_diagnostics.ps1"
$validator = Join-Path ([string]$config.tools_root) "Validate-DndIssuePacket.ps1"
if (-not (Test-Path -LiteralPath $collector -PathType Leaf)) {
    throw "Diagnostic Collector v3 is missing: $collector"
}

$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($collector, [ref]$tokens, [ref]$parseErrors) | Out-Null
if (@($parseErrors).Count -gt 0) {
    $parseErrors | ForEach-Object { Write-Host $_.Message -ForegroundColor Red }
    throw "Diagnostic Collector v3 parser preflight failed."
}

Write-Host ("[DND-COLLECT] Running Diagnostic Collector v3 preset: " + $Preset) -ForegroundColor Cyan
& $collector -Preset $Preset -AdditionalPaths $AdditionalPaths

$issuePath = Join-Path ([string]$config.handoff_root) "issue.zip"
if (-not (Test-Path -LiteralPath $issuePath -PathType Leaf)) {
    throw "Collector completed without producing: $issuePath"
}

if (Test-Path -LiteralPath $validator -PathType Leaf) {
    $validatorTokens = $null
    $validatorParseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($validator, [ref]$validatorTokens, [ref]$validatorParseErrors) | Out-Null
    if (@($validatorParseErrors).Count -gt 0) {
        $validatorParseErrors | ForEach-Object { Write-Host $_.Message -ForegroundColor Red }
        throw "Issue packet validator parser preflight failed."
    }
    & $validator -IssuePath $issuePath
}
