[CmdletBinding()]
param(
    [ValidateSet("unit-content-authoring", "ranged-engagement")]
    [string]$Preset = "ranged-engagement",

    [string]$RequestTitle = "",

    [string]$RequestBody = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host ("[DND-COLLECT] " + $Message)
}

function Read-Utf8Text {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Normalize-RelativePath {
    param([string]$Path)
    return ($Path.Replace('/', '\').TrimStart('\'))
}

function Get-ProjectRelativePath {
    param([string]$AbsolutePath, [string]$Root)
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $fileFull = [System.IO.Path]::GetFullPath($AbsolutePath)
    if (-not $fileFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the project root: $AbsolutePath"
    }
    return $fileFull.Substring($rootFull.Length).Replace('\', '/')
}

function Add-Warning {
    param([string]$Message)
    if (-not $script:Warnings.Contains($Message)) {
        [void]$script:Warnings.Add($Message)
    }
}

function Add-ProjectFile {
    param(
        [string]$RelativePath,
        [string]$Reason,
        [switch]$Optional
    )

    $normalized = Normalize-RelativePath -Path $RelativePath
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $false }

    $absolute = Join-Path $script:ProjectRoot $normalized
    if (-not (Test-Path -LiteralPath $absolute -PathType Leaf)) {
        if (-not $Optional) {
            Add-Warning -Message ("Missing project file: " + $normalized)
        }
        return $false
    }

    $key = $normalized.ToLowerInvariant()
    if ($script:FilesByKey.ContainsKey($key)) { return $false }

    $script:FilesByKey[$key] = [pscustomobject]@{
        RelativePath = $normalized
        AbsolutePath = $absolute
        Reason = $Reason
    }
    return $true
}

function Add-ProjectTree {
    param(
        [string]$RelativeDirectory,
        [string[]]$Extensions,
        [string]$Reason,
        [switch]$Optional
    )

    $normalized = Normalize-RelativePath -Path $RelativeDirectory
    $absolute = Join-Path $script:ProjectRoot $normalized
    if (-not (Test-Path -LiteralPath $absolute -PathType Container)) {
        if (-not $Optional) {
            Add-Warning -Message ("Missing project directory: " + $normalized)
        }
        return
    }

    $extensionSet = @{}
    foreach ($extension in $Extensions) {
        $extensionSet[$extension.ToLowerInvariant()] = $true
    }

    Get-ChildItem -LiteralPath $absolute -Recurse -File -Force | ForEach-Object {
        $extension = $_.Extension.ToLowerInvariant()
        if (($extensionSet.Count -eq 0) -or $extensionSet.ContainsKey($extension)) {
            $relative = Get-ProjectRelativePath -AbsolutePath $_.FullName -Root $script:ProjectRoot
            [void](Add-ProjectFile -RelativePath $relative -Reason $Reason -Optional:$Optional)
        }
    }
}

function Add-ReferencedDependencies {
    $textExtensions = @{
        ".gd" = $true
        ".tscn" = $true
        ".tres" = $true
        ".godot" = $true
        ".md" = $true
        ".txt" = $true
        ".json" = $true
    }

    $resourcePattern = 'res://[^"''\)\]\}\r\n,]+'
    $changed = $true
    $pass = 0

    while ($changed) {
        $changed = $false
        $pass += 1
        if ($pass -gt 12) {
            Add-Warning -Message "Dependency closure stopped after 12 passes."
            break
        }

        $snapshot = @($script:FilesByKey.Values)
        foreach ($file in $snapshot) {
            $extension = [System.IO.Path]::GetExtension([string]$file.AbsolutePath).ToLowerInvariant()
            if (-not $textExtensions.ContainsKey($extension)) { continue }

            try {
                $text = Read-Utf8Text -Path ([string]$file.AbsolutePath)
            }
            catch {
                Add-Warning -Message ("Could not read dependency source: " + [string]$file.RelativePath)
                continue
            }

            $matches = [System.Text.RegularExpressions.Regex]::Matches($text, $resourcePattern)
            foreach ($match in $matches) {
                $resource = [string]$match.Value
                $relative = $resource.Substring(6).Replace('/', '\')
                if (Add-ProjectFile -RelativePath $relative -Reason ("Referenced by " + [string]$file.RelativePath) -Optional) {
                    $changed = $true
                }
            }
        }
    }
}

function Get-TrackedState {
    param([string]$RelativePath)

    $trackingKey = $RelativePath.Replace('\', '/').ToLowerInvariant()
    if (-not $script:TrackedFiles.ContainsKey($trackingKey)) {
        return "untracked"
    }

    & git -C $script:ProjectRoot diff --quiet -- $RelativePath
    $worktreeChanged = ($LASTEXITCODE -ne 0)
    & git -C $script:ProjectRoot diff --cached --quiet -- $RelativePath
    $indexChanged = ($LASTEXITCODE -ne 0)

    if ($indexChanged -and $worktreeChanged) { return "tracked:index+worktree-modified" }
    if ($indexChanged) { return "tracked:index-modified" }
    if ($worktreeChanged) { return "tracked:worktree-modified" }
    return "tracked:clean"
}

function Copy-TextEvidence {
    param([string]$SourcePath, [string]$DestinationPath)
    if (Test-Path -LiteralPath $SourcePath -PathType Leaf) {
        $destinationDirectory = Split-Path -Parent $DestinationPath
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
        return $true
    }
    return $false
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptRoot "workspace.json"
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    $configPath = Join-Path $env:USERPROFILE "dnd-workspace\dnd-dev-tools\workspace.json"
}
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Workspace configuration not found: $configPath"
}

$config = (Read-Utf8Text -Path $configPath) | ConvertFrom-Json
$script:ProjectRoot = [string]$config.project_root
$toolsRoot = [string]$config.tools_root
$handoffRoot = [string]$config.handoff_root

foreach ($requiredRoot in @($script:ProjectRoot, $toolsRoot, $handoffRoot)) {
    if ([string]::IsNullOrWhiteSpace($requiredRoot)) {
        throw "workspace.json contains an empty required path."
    }
}
if (-not (Test-Path -LiteralPath $script:ProjectRoot -PathType Container)) {
    throw "Configured project root is missing: $script:ProjectRoot"
}
if (-not (Test-Path -LiteralPath $toolsRoot -PathType Container)) {
    throw "Configured tools root is missing: $toolsRoot"
}
New-Item -ItemType Directory -Path $handoffRoot -Force | Out-Null

Write-Step "Preset: $Preset"
Write-Step "Project: $script:ProjectRoot"
Write-Step "Tools: $toolsRoot"
Write-Step "Handoff: $handoffRoot"

& git -C $script:ProjectRoot rev-parse --is-inside-work-tree
if ($LASTEXITCODE -ne 0) { throw "Project root is not a Git work tree." }
& git -C $toolsRoot rev-parse --is-inside-work-tree
if ($LASTEXITCODE -ne 0) { throw "Tools root is not a Git work tree." }

Write-Step "Indexing tracked project files without error-producing path probes"
$script:TrackedFiles = @{}
$trackedPaths = @(& git -C $script:ProjectRoot -c core.quotepath=false ls-files)
if ($LASTEXITCODE -ne 0) { throw "Could not index tracked project files." }
foreach ($trackedPath in $trackedPaths) {
    $trackingKey = ([string]$trackedPath).Replace('\', '/').ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($trackingKey)) {
        $script:TrackedFiles[$trackingKey] = $true
    }
}
Write-Step ("Indexed " + $script:TrackedFiles.Count + " tracked project files")

$script:FilesByKey = @{}
$script:Warnings = New-Object System.Collections.ArrayList

$codeExtensions = @(".gd", ".tscn", ".tres", ".godot", ".md", ".txt", ".json", ".cfg")
$assetExtensions = @(".png", ".jpg", ".jpeg", ".webp", ".svg", ".wav", ".ogg", ".mp3")
$sourceAndAssetExtensions = @($codeExtensions + $assetExtensions)

[void](Add-ProjectFile -RelativePath "project.godot" -Reason "Project configuration")
[void](Add-ProjectFile -RelativePath "scenes\battle\BattleScenario.tscn" -Reason "Battle composition")

if ($Preset -eq "ranged-engagement") {
    Add-ProjectTree -RelativeDirectory "scripts" -Extensions @(".gd") -Reason "Authoritative systems, command controllers, behavior, presentation integration, and tests"
    Add-ProjectTree -RelativeDirectory "scenes" -Extensions @(".tscn") -Reason "Battle composition and unit instances"
    Add-ProjectTree -RelativeDirectory "data" -Extensions @(".tres") -Reason "Unit definitions and authored combat/presentation resources"
    Add-ProjectTree -RelativeDirectory "tests" -Extensions @(".gd") -Reason "Regression tests" -Optional
    Add-ProjectTree -RelativeDirectory "docs\architecture" -Extensions @(".md") -Reason "Architecture and regression contracts" -Optional
}
else {
    Add-ProjectTree -RelativeDirectory "scenes\units" -Extensions @(".tscn") -Reason "Unit scene authoring"
    Add-ProjectTree -RelativeDirectory "scripts\presentation" -Extensions @(".gd") -Reason "Presentation authoring schema"
    Add-ProjectTree -RelativeDirectory "scripts\framework" -Extensions @(".gd") -Reason "Scene registration and overrides"
    Add-ProjectTree -RelativeDirectory "data\audio" -Extensions @(".tres") -Reason "Combat audio profiles" -Optional
    Add-ProjectTree -RelativeDirectory "data\units" -Extensions @(".tres") -Reason "Unit definitions" -Optional
    Add-ProjectTree -RelativeDirectory "data\presentation\projectiles" -Extensions @(".tres") -Reason "Projectile profiles" -Optional
    Add-ProjectTree -RelativeDirectory "assets\audio\sfx\combat\ranged" -Extensions @(".wav", ".ogg", ".mp3") -Reason "Authored ranged audio assets" -Optional
    Add-ProjectTree -RelativeDirectory "docs\architecture" -Extensions @(".md") -Reason "Unit and presentation authoring contracts" -Optional
}

Write-Step "Resolving res:// dependency closure"
Add-ReferencedDependencies

$stageRoot = Join-Path $env:TEMP ("dnd-issue-" + [Guid]::NewGuid().ToString("N"))
$issuePath = Join-Path $handoffRoot "issue.zip"
$warningsPath = Join-Path $stageRoot "collector_warnings.txt"

try {
    New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
    $sourceRoot = Join-Path $stageRoot "source"
    $gitRoot = Join-Path $stageRoot "git"
    $staticRoot = Join-Path $stageRoot "static"
    $evidenceRoot = Join-Path $stageRoot "evidence"
    New-Item -ItemType Directory -Path $sourceRoot, $gitRoot, $staticRoot, $evidenceRoot -Force | Out-Null

    Write-Step ("Copying " + $script:FilesByKey.Count + " source/dependency files, including untracked files")
    $manifestRows = New-Object System.Collections.ArrayList
    foreach ($file in @($script:FilesByKey.Values | Sort-Object RelativePath)) {
        $destination = Join-Path $sourceRoot ([string]$file.RelativePath)
        $destinationDirectory = Split-Path -Parent $destination
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        Copy-Item -LiteralPath ([string]$file.AbsolutePath) -Destination $destination -Force

        $relativeUnix = ([string]$file.RelativePath).Replace('\', '/')
        $state = Get-TrackedState -RelativePath $relativeUnix
        $hash = Get-Sha256 -Path ([string]$file.AbsolutePath)
        $size = (Get-Item -LiteralPath ([string]$file.AbsolutePath)).Length
        [void]$manifestRows.Add([pscustomobject]@{
            path = $relativeUnix
            bytes = $size
            sha256 = $hash
            git_state = $state
            reason = [string]$file.Reason
        })
    }

    $manifestPath = Join-Path $staticRoot "manifest.csv"
    $manifestRows | Export-Csv -LiteralPath $manifestPath -NoTypeInformation -Encoding UTF8
    Write-Utf8NoBom -Path (Join-Path $staticRoot "source_tree.txt") -Text ((@($manifestRows | ForEach-Object { $_.path }) -join [Environment]::NewLine) + [Environment]::NewLine)
    Copy-Item -LiteralPath $configPath -Destination (Join-Path $staticRoot "workspace.json") -Force

    $environment = [ordered]@{
        schema_version = 2
        generated_at = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        preset = $Preset
        project_root = $script:ProjectRoot
        tools_root = $toolsRoot
        powershell_version = $PSVersionTable.PSVersion.ToString()
        source_file_count = $manifestRows.Count
        warning_count = $script:Warnings.Count
    } | ConvertTo-Json -Depth 4
    Write-Utf8NoBom -Path (Join-Path $staticRoot "environment.json") -Text ($environment + [Environment]::NewLine)

    Write-Step "Collecting Git evidence"
    (& git -C $script:ProjectRoot branch --show-current) | Out-File -LiteralPath (Join-Path $gitRoot "branch.txt") -Encoding utf8
    (& git -C $script:ProjectRoot rev-parse HEAD) | Out-File -LiteralPath (Join-Path $gitRoot "head.txt") -Encoding utf8
    (& git -C $script:ProjectRoot status --short --untracked-files=all) | Out-File -LiteralPath (Join-Path $gitRoot "status.txt") -Encoding utf8
    (& git -C $script:ProjectRoot diff --no-ext-diff) | Out-File -LiteralPath (Join-Path $gitRoot "working_tree.patch") -Encoding utf8
    (& git -C $script:ProjectRoot diff --cached --no-ext-diff) | Out-File -LiteralPath (Join-Path $gitRoot "index.patch") -Encoding utf8
    (& git -C $toolsRoot status --short --untracked-files=all) | Out-File -LiteralPath (Join-Path $gitRoot "tools_status.txt") -Encoding utf8
    (& git -C $toolsRoot diff --no-ext-diff) | Out-File -LiteralPath (Join-Path $gitRoot "tools_diff.patch") -Encoding utf8

    $defaultTitle = if ($Preset -eq "ranged-engagement") {
        "Ranged Engagement AI and Player Intent Polish"
    }
    else {
        "Unit Content Authoring"
    }
    if ([string]::IsNullOrWhiteSpace($RequestTitle)) { $RequestTitle = $defaultTitle }

    $defaultBody = if ($Preset -eq "ranged-engagement") {
@"
Inspect the current implementation before editing. Determine whether the documented AttackEngagementPlanner integration is already complete, partially implemented, or only documented.

Target behavior:
- Enemy and retained player engagement use authored basic-attack range.
- A target already in range queues an attack without unnecessary movement.
- An out-of-range movable unit selects a deterministic reachable firing position within its authored range.
- Ranged units do not collapse to melee adjacency unless no other legal firing position exists under current rules.
- Explicit player intent remains higher priority than routine behavior.
- Immobile Catapult movement remains rejected while in-range attacks remain legal.
- Mouse hostile-target intent is readable and consistent with current control ownership.

Preserve:
- Simulation authority and ordinary move/attack commands.
- Stable deterministic ordering and weighted movement costs.
- Existing melee range-one behavior.
- Projectile presentation as non-authoritative.

Deferred and out of scope:
- Line of sight.
- Cover.
- Projectile collision authority.
- Minimum range.
- Area damage.
- Broad input remapping unrelated to ranged intent.

Provide a bounded implementation only after identifying the exact current gap, with regression coverage and documentation updates when responsibilities or behavior change.
"@
    }
    else {
@"
Collect the complete bounded unit-content authoring surface, including untracked profiles and referenced assets. Preserve simulation authority and treat scenes, animation, audio, projectile profiles, and visual assets as presentation authoring.
"@
    }
    if ([string]::IsNullOrWhiteSpace($RequestBody)) { $RequestBody = $defaultBody }

    $requestText = "# " + $RequestTitle + [Environment]::NewLine + [Environment]::NewLine + $RequestBody.Trim() + [Environment]::NewLine
    Write-Utf8NoBom -Path (Join-Path $stageRoot "request.md") -Text $requestText

    $readmeText = @"
DND Workspace Collector v2

Preset: $Preset

This packet is self-contained for the selected bounded task. It includes tracked and untracked project files, recursive res:// dependencies, Git evidence, runtime evidence when available, source hashes, and the current request.

The collector does not modify the Godot project, stage files, commit, push, or launch Godot.
"@
    Write-Utf8NoBom -Path (Join-Path $stageRoot "README.txt") -Text ($readmeText.Trim() + [Environment]::NewLine)

    Write-Step "Collecting runtime evidence"
    foreach ($name in @("runtime_snapshot.json", "runtime_snapshot.txt", "runtime.log")) {
        $source = Join-Path $handoffRoot $name
        if (-not (Copy-TextEvidence -SourcePath $source -DestinationPath (Join-Path $evidenceRoot $name))) {
            Add-Warning -Message ("Missing optional evidence: " + $name)
        }
    }

    $screenshotsRoot = Join-Path $handoffRoot "screenshots"
    if (Test-Path -LiteralPath $screenshotsRoot -PathType Container) {
        $destinationScreenshots = Join-Path $evidenceRoot "screenshots"
        New-Item -ItemType Directory -Path $destinationScreenshots -Force | Out-Null
        Get-ChildItem -LiteralPath $screenshotsRoot -File | Sort-Object LastWriteTime -Descending | Select-Object -First 8 | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $destinationScreenshots $_.Name) -Force
        }
    }

    if ($script:Warnings.Count -eq 0) {
        [void]$script:Warnings.Add("No collector warnings.")
    }
    Write-Utf8NoBom -Path $warningsPath -Text (($script:Warnings -join [Environment]::NewLine) + [Environment]::NewLine)

    Write-Step "Creating issue.zip"
    if (Test-Path -LiteralPath $issuePath -PathType Leaf) {
        Remove-Item -LiteralPath $issuePath -Force
    }
    Compress-Archive -Path (Join-Path $stageRoot "*") -DestinationPath $issuePath -CompressionLevel Optimal -Force

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($issuePath)
    try {
        $entryNames = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
        foreach ($requiredEntry in @("request.md", "README.txt", "static/manifest.csv", "git/status.txt")) {
            if (-not ($entryNames -contains $requiredEntry)) {
                throw "Generated issue packet is missing: $requiredEntry"
            }
        }
        $sourceEntries = @($entryNames | Where-Object { $_.StartsWith("source/", [System.StringComparison]::OrdinalIgnoreCase) })
        if ($sourceEntries.Count -lt 1) { throw "Generated issue packet contains no source files." }
        Write-Step ("Validated archive entries: " + $entryNames.Count)
        Write-Step ("Validated source entries: " + $sourceEntries.Count)
    }
    finally {
        $archive.Dispose()
    }

    $issueFile = Get-Item -LiteralPath $issuePath
    $issueHash = Get-Sha256 -Path $issuePath
    Write-Step "Issue packet ready"
    Write-Host ("Path: " + $issueFile.FullName)
    Write-Host ("Size: " + $issueFile.Length + " bytes")
    Write-Host ("SHA256: " + $issueHash)
    Write-Host ("Source files: " + $manifestRows.Count)
    Write-Host ("Warnings: " + $script:Warnings.Count)
}
finally {
    if (Test-Path -LiteralPath $stageRoot -PathType Container) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force
    }
}
