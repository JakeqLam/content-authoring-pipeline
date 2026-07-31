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

    [string[]]$AdditionalPaths = @(),

    [ValidateRange(1, 50)]
    [int]$MaxScreenshots = 12,

    [ValidateRange(1, 100)]
    [int]$MaxProfilerFiles = 32,

    [ValidateRange(1, 50)]
    [int]$MaxLogFiles = 12,

    [ValidateRange(1, 20)]
    [int]$MaxRuntimeCaptures = 5
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host ("[DND-DIAGNOSTICS] " + $Message) -ForegroundColor Cyan
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Read-Utf8Text {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}


function Get-PropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$DefaultValue = $null
    )
    if ($null -eq $Object) { return $DefaultValue }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $DefaultValue }
    return $property.Value
}

function Normalize-RelativePath {
    param([string]$Path)
    return $Path.Replace("/", "\").TrimStart("\")
}

function Get-ProjectRelativePath {
    param([string]$AbsolutePath)
    $root = [System.IO.Path]::GetFullPath($script:ProjectRoot).TrimEnd("\") + "\"
    $file = [System.IO.Path]::GetFullPath($AbsolutePath)
    if (-not $file.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside project_root: $AbsolutePath"
    }
    return $file.Substring($root.Length).Replace("\", "/")
}

function Add-Warning {
    param([string]$Message)
    if (-not $script:Warnings.Contains($Message)) {
        [void]$script:Warnings.Add($Message)
    }
    Write-Warning $Message
}

function Add-ProjectFile {
    param(
        [string]$RelativePath,
        [string]$Reason,
        [switch]$Optional
    )

    $normalized = Normalize-RelativePath $RelativePath
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $false }
    $absolute = Join-Path $script:ProjectRoot $normalized
    if (-not (Test-Path -LiteralPath $absolute -PathType Leaf)) {
        if (-not $Optional) {
            Add-Warning ("Missing project file: " + $normalized)
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

    $normalized = Normalize-RelativePath $RelativeDirectory
    $absolute = Join-Path $script:ProjectRoot $normalized
    if (-not (Test-Path -LiteralPath $absolute -PathType Container)) {
        if (-not $Optional) {
            Add-Warning ("Missing project directory: " + $normalized)
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
            $relative = Get-ProjectRelativePath $_.FullName
            [void](Add-ProjectFile -RelativePath $relative -Reason $Reason -Optional:$Optional)
        }
    }
}

function Add-ChangedAndUntrackedFiles {
    $lines = @(& git -C $script:ProjectRoot -c core.quotepath=false status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) {
        Add-Warning "Could not inspect changed and untracked project files."
        return
    }

    foreach ($lineValue in $lines) {
        $line = [string]$lineValue
        if ($line.Length -lt 4) { continue }
        $pathText = $line.Substring(3).Trim()
        if ($pathText.Contains(" -> ")) {
            $pathText = $pathText.Split(@(" -> "), [System.StringSplitOptions]::None)[1]
        }
        $pathText = $pathText.Trim('"')
        [void](Add-ProjectFile -RelativePath $pathText -Reason "Changed or untracked working-tree file" -Optional)
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
        ".cfg" = $true
    }
    $pattern = 'res://[^"''\)\]\}\r\n,]+'
    $changed = $true
    $pass = 0

    while ($changed) {
        $changed = $false
        $pass += 1
        if ($pass -gt 16) {
            Add-Warning "Dependency closure stopped after 16 passes."
            break
        }

        $snapshot = @($script:FilesByKey.Values)
        foreach ($file in $snapshot) {
            $extension = [System.IO.Path]::GetExtension([string]$file.AbsolutePath).ToLowerInvariant()
            if (-not $textExtensions.ContainsKey($extension)) { continue }
            try {
                $text = Read-Utf8Text ([string]$file.AbsolutePath)
            }
            catch {
                Add-Warning ("Could not read dependency source: " + [string]$file.RelativePath)
                continue
            }

            $matches = [System.Text.RegularExpressions.Regex]::Matches($text, $pattern)
            foreach ($match in $matches) {
                $resource = [string]$match.Value
                $relative = $resource.Substring(6).Replace("/", "\")
                if (Add-ProjectFile -RelativePath $relative -Reason ("Referenced by " + [string]$file.RelativePath) -Optional) {
                    $changed = $true
                }
            }
        }
    }
}

function Get-TrackedState {
    param([string]$RelativePath)
    $key = $RelativePath.Replace("\", "/").ToLowerInvariant()
    if (-not $script:TrackedFiles.ContainsKey($key)) { return "untracked" }

    & git -C $script:ProjectRoot diff --quiet -- $RelativePath
    $worktreeChanged = ($LASTEXITCODE -ne 0)
    & git -C $script:ProjectRoot diff --cached --quiet -- $RelativePath
    $indexChanged = ($LASTEXITCODE -ne 0)

    if ($indexChanged -and $worktreeChanged) { return "tracked:index+worktree-modified" }
    if ($indexChanged) { return "tracked:index-modified" }
    if ($worktreeChanged) { return "tracked:worktree-modified" }
    return "tracked:clean"
}

function Invoke-GitCapture {
    param(
        [string]$Repository,
        [string[]]$Arguments,
        [string]$DestinationPath,
        [string]$Description
    )
    try {
        $output = @(& git -C $Repository @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
        Write-Utf8NoBom -Path $DestinationPath -Text (($output -join [Environment]::NewLine) + [Environment]::NewLine)
        if ($exitCode -ne 0) {
            Add-Warning ("$Description exited with code $exitCode.")
        }
    }
    catch {
        Add-Warning ("Could not capture ${Description}: " + $_.Exception.Message)
        Write-Utf8NoBom -Path $DestinationPath -Text ("Capture failed: " + $_.Exception.Message + [Environment]::NewLine)
    }
}

function Add-EvidenceFile {
    param(
        [string]$SourcePath,
        [string]$RelativeDestination,
        [string]$Kind,
        [switch]$Optional
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        if (-not $Optional) {
            Add-Warning ("Missing evidence: " + $SourcePath)
        }
        return $false
    }

    $destination = Join-Path $script:StageRoot $RelativeDestination
    Ensure-Directory (Split-Path -Parent $destination)
    Copy-Item -LiteralPath $SourcePath -Destination $destination -Force
    $item = Get-Item -LiteralPath $SourcePath
    $script:EvidenceManifest.Add([pscustomobject]@{
        Kind = $Kind
        RelativePath = $RelativeDestination.Replace("\", "/")
        SourcePath = $item.FullName
        SizeBytes = $item.Length
        ModifiedLocal = $item.LastWriteTime.ToString("o")
        SHA256 = Get-Sha256 $item.FullName
    })
    return $true
}

function Add-GeneratedEvidenceManifest {
    param(
        [string]$RelativePath,
        [string]$Kind
    )
    $absolute = Join-Path $script:StageRoot $RelativePath
    if (-not (Test-Path -LiteralPath $absolute -PathType Leaf)) { return }
    $item = Get-Item -LiteralPath $absolute
    $script:EvidenceManifest.Add([pscustomobject]@{
        Kind = $Kind
        RelativePath = $RelativePath.Replace("\", "/")
        SourcePath = "<generated by collector>"
        SizeBytes = $item.Length
        ModifiedLocal = $item.LastWriteTime.ToString("o")
        SHA256 = Get-Sha256 $item.FullName
    })
}

function Write-RuntimeEventSummary {
    param([string]$EventsPath)
    $relative = "evidence\runtime\runtime_event_summary.txt"
    $destination = Join-Path $script:StageRoot $relative
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Runtime Event Window Summary")
    $lines.Add("============================")
    $lines.Add("")
    if (-not (Test-Path -LiteralPath $EventsPath -PathType Leaf)) {
        $lines.Add("runtime_events.jsonl was not captured.")
        Write-Utf8NoBom -Path $destination -Text (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
        Add-GeneratedEvidenceManifest $relative "runtime-summary"
        return
    }

    $events = New-Object System.Collections.Generic.List[object]
    foreach ($line in Get-Content -LiteralPath $EventsPath) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
        try { $events.Add(([string]$line | ConvertFrom-Json)) }
        catch { Add-Warning ("Could not parse one runtime event row: " + $_.Exception.Message) }
    }
    $lines.Add(("Captured events: {0}" -f $events.Count))
    if ($events.Count -gt 0) {
        $firstEvent = $events[0]
        $lastEvent = $events[$events.Count - 1]
        $lines.Add(("Sequence range: {0} - {1}" -f
            (Get-PropertyValue $firstEvent "sequence" 0),
            (Get-PropertyValue $lastEvent "sequence" 0)))
        $lines.Add(("Elapsed range: {0:N3} - {1:N3} ms" -f
            [double](Get-PropertyValue $firstEvent "elapsed_msec" 0),
            [double](Get-PropertyValue $lastEvent "elapsed_msec" 0)))
    }
    $lines.Add("")
    $lines.Add("Counts by category and type")
    $lines.Add("---------------------------")
    foreach ($group in @($events | Group-Object { ([string]$_.category) + "/" + ([string]$_.type) } | Sort-Object -Property Count -Descending)) {
        $lines.Add(("{0,5}  {1}" -f $group.Count, $group.Name))
    }
    $lines.Add("")
    $lines.Add("Last 50 events")
    $lines.Add("--------------")
    foreach ($event in @($events | Select-Object -Last 50)) {
        $lines.Add(("seq={0} elapsed={1:N3}ms tick={2} frame={3} {4}/{5}" -f
            (Get-PropertyValue $event "sequence" 0),
            [double](Get-PropertyValue $event "elapsed_msec" 0),
            (Get-PropertyValue $event "tick" -1),
            (Get-PropertyValue $event "process_frame" -1),
            (Get-PropertyValue $event "category" ""),
            (Get-PropertyValue $event "type" "")))
    }
    Write-Utf8NoBom -Path $destination -Text (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
    Add-GeneratedEvidenceManifest $relative "runtime-summary"
}

function Convert-UsageToBytes {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return [double]0 }
    $match = [regex]::Match($Value.Trim(), '^([0-9]+(?:\.[0-9]+)?)\s*(B|KiB|MiB|GiB)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) { return [double]0 }
    $number = [double]::Parse($match.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture)
    switch ($match.Groups[2].Value.ToLowerInvariant()) {
        "kib" { return $number * 1024 }
        "mib" { return $number * 1024 * 1024 }
        "gib" { return $number * 1024 * 1024 * 1024 }
        default { return $number }
    }
}

function Get-ProfilerFileSummary {
    param([string]$Path)

    $item = Get-Item -LiteralPath $Path
    $summary = [ordered]@{
        file_name = $item.Name
        source_path = $item.FullName
        size_bytes = $item.Length
        modified_local = $item.LastWriteTime.ToString("o")
        sha256 = Get-Sha256 $item.FullName
        classification = "binary_or_unknown"
        row_count = 0
        headers = @()
        details = @{}
    }

    $extension = $item.Extension.ToLowerInvariant()
    if ($extension -notin @(".csv", ".txt", "")) {
        return [pscustomobject]$summary
    }

    try {
        $firstLine = Get-Content -LiteralPath $Path -TotalCount 1
        if ($null -eq $firstLine) { return [pscustomobject]$summary }
        if ([string]$firstLine -match '^Resource Path,Type,Format,Usage') {
            $rows = @(Import-Csv -LiteralPath $Path)
            $topRows = @()
            $totalBytes = [double]0
            foreach ($row in $rows) {
                $bytes = Convert-UsageToBytes ([string]$row.Usage)
                $totalBytes += $bytes
                $topRows += [pscustomobject]@{
                    resource_path = [string]$row.'Resource Path'
                    type = [string]$row.Type
                    format = [string]$row.Format
                    usage = [string]$row.Usage
                    usage_bytes = [long]$bytes
                }
            }
            $summary.classification = "godot_video_ram_csv"
            $summary.row_count = $rows.Count
            $summary.headers = @("Resource Path", "Type", "Format", "Usage")
            $summary.details = [ordered]@{
                total_usage_bytes = [long]$totalBytes
                top_resources = @($topRows | Sort-Object usage_bytes -Descending | Select-Object -First 20)
            }
            return [pscustomobject]$summary
        }

        if ($extension -eq ".csv" -or ([string]$firstLine).Contains(",")) {
            $rows = @(Import-Csv -LiteralPath $Path)
            $headers = @()
            if ($rows.Count -gt 0) {
                $headers = @($rows[0].PSObject.Properties.Name)
            }
            else {
                $headers = @(([string]$firstLine).Split(','))
            }
            $classification = "generic_csv"
            if (($headers -contains "Frame") -or ($headers -contains "Frame Time") -or ($headers -contains "Frame #")) {
                $classification = "godot_profiler_csv"
            }
            elseif (($headers -contains "CPU Time") -or ($headers -contains "GPU Time")) {
                $classification = "godot_visual_profiler_csv"
            }
            elseif (($headers -contains "Monitor") -or ($headers -contains "Value")) {
                $classification = "godot_monitor_csv"
            }
            $summary.classification = $classification
            $summary.row_count = $rows.Count
            $summary.headers = $headers
            $summary.details = [ordered]@{
                sample_rows = @($rows | Select-Object -First 10)
            }
            return [pscustomobject]$summary
        }

        $summary.classification = "text"
        $summary.details = [ordered]@{
            first_lines = @(Get-Content -LiteralPath $Path -TotalCount 20)
        }
    }
    catch {
        $summary.details = [ordered]@{
            parse_error = $_.Exception.Message
        }
    }
    return [pscustomobject]$summary
}

function Write-ProfilerSummary {
    param([object[]]$ProfilerSummaries)
    $jsonPath = Join-Path $script:StageRoot "evidence\profiler\profiler_summary.json"
    $textPath = Join-Path $script:StageRoot "evidence\profiler\profiler_summary.txt"
    Ensure-Directory (Split-Path -Parent $jsonPath)

    # Windows PowerShell 5.1 can bind an empty array parameter as $null. Emit an
    # explicit JSON array so profiler evidence remains optional and machine-readable.
    $summaryArray = [object[]]@()
    if ($null -ne $ProfilerSummaries -and $ProfilerSummaries.Count -gt 0) {
        $summaryArray = [object[]]$ProfilerSummaries
    }
    $profilerJson = "[]"
    if ($summaryArray.Count -gt 0) {
        $profilerJson = ConvertTo-Json -InputObject $summaryArray -Depth 12
    }
    Write-Utf8NoBom -Path $jsonPath -Text ($profilerJson + [Environment]::NewLine)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Godot Profiler Evidence Summary")
    $lines.Add("===============================")
    $lines.Add("")
    if ($summaryArray.Count -eq 0) {
        $lines.Add("No profiler exports were found.")
        $lines.Add("Export Godot Profiler, Visual Profiler, Monitors, Video RAM, or ObjectDB evidence into dnd-handoff\profiler.")
    }
    foreach ($summary in $summaryArray) {
        $lines.Add(("- {0}: {1}, {2} bytes, {3} rows" -f $summary.file_name, $summary.classification, $summary.size_bytes, $summary.row_count))
        if ($summary.classification -eq "godot_video_ram_csv") {
            $lines.Add(("  Total reported usage: {0} bytes" -f $summary.details.total_usage_bytes))
            foreach ($resource in @($summary.details.top_resources | Select-Object -First 10)) {
                $lines.Add(("  {0} bytes | {1} | {2}" -f $resource.usage_bytes, $resource.type, $resource.resource_path))
            }
        }
    }
    Write-Utf8NoBom -Path $textPath -Text (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
    Add-GeneratedEvidenceManifest "evidence\profiler\profiler_summary.json" "profiler-summary"
    Add-GeneratedEvidenceManifest "evidence\profiler\profiler_summary.txt" "profiler-summary"
}

function Get-RuntimeSummaryLines {
    param([string]$SnapshotPath)
    $lines = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $SnapshotPath -PathType Leaf)) {
        $lines.Add("Runtime snapshot: missing. Press F12 in the running game before collection.")
        return $lines
    }

    try {
        $snapshot = Read-Utf8Text $SnapshotPath | ConvertFrom-Json
        $schemaVersion = Get-PropertyValue $snapshot "schema_version" 0
        $generated = Get-PropertyValue $snapshot "generated_at_local" ""
        $engine = Get-PropertyValue $snapshot "engine" $null
        $project = Get-PropertyValue $snapshot "project" $null
        $rendering = Get-PropertyValue $snapshot "rendering" $null
        $performance = Get-PropertyValue $snapshot "performance" $null
        $systems = Get-PropertyValue $snapshot "systems" $null
        $capture = Get-PropertyValue $snapshot "capture" $null

        $lines.Add(("Runtime snapshot schema: {0}" -f $schemaVersion))
        $lines.Add(("Generated: {0}" -f $generated))
        $lines.Add(("Engine: {0}" -f (Get-PropertyValue $engine "string" "")))
        $currentScene = Get-PropertyValue $project "current_scene" $null
        $lines.Add(("Scene: {0}" -f (Get-PropertyValue $currentScene "scene_file_path" "")))

        if ($null -ne $rendering) {
            $lines.Add(("Renderer: {0} / {1}" -f (Get-PropertyValue $rendering "method" ""), (Get-PropertyValue $rendering "driver" "")))
            $lines.Add(("GPU: {0}" -f (Get-PropertyValue $rendering "adapter_name" "")))
        }

        if ($null -ne $performance) {
            $performanceSummary = Get-PropertyValue $performance "summary" $null
            $frame = Get-PropertyValue $performanceSummary "frame_time_ms" $null
            if ($null -ne $frame) {
                $lines.Add(("Frame time average/p95/max: {0:N3} / {1:N3} / {2:N3} ms" -f
                    [double](Get-PropertyValue $frame "average" 0),
                    [double](Get-PropertyValue $frame "p95" 0),
                    [double](Get-PropertyValue $frame "maximum" 0)))
            }
            $spikes = @(Get-PropertyValue $performance "frame_spikes" @())
            $lines.Add(("Captured frame spikes: {0}" -f $spikes.Count))
        }

        $movement = Get-PropertyValue $systems "group_movement" $null
        if ($null -ne $movement) {
            $lines.Add(("Movement policy: {0}" -f (Get-PropertyValue $movement "route_query_policy" "")))
            $clickUsec = [double](Get-PropertyValue $movement "click_to_commit_usec" 0)
            $lines.Add(("Click-to-commit: {0:N3} ms" -f ($clickUsec / 1000.0)))
            $lines.Add(("Hover pathfinding count: {0}" -f (Get-PropertyValue $movement "hover_pathfinding_count" 0)))
            $lines.Add(("Group completions / interruptions: {0} / {1}" -f
                (Get-PropertyValue $movement "group_completion_count" 0),
                (Get-PropertyValue $movement "member_interruption_count" 0)))
        }

        $board = Get-PropertyValue $systems "tile_board" $null
        if ($null -ne $board) {
            $lines.Add(("Transit stack tiles at capture: {0}" -f (Get-PropertyValue $board "transit_stack_tile_count" 0)))
        }
        $plans = Get-PropertyValue $systems "movement_plans" $null
        if ($null -ne $plans) {
            $lines.Add(("Active movement plans / legs: {0} / {1}" -f
                (Get-PropertyValue $plans "active_plan_count" 0),
                (Get-PropertyValue $plans "active_leg_count" 0)))
        }
        if ($null -ne $capture) {
            $lines.Add(("Buffered events: {0}" -f (Get-PropertyValue $capture "event_count" 0)))
        }
    }
    catch {
        $lines.Add(("Runtime snapshot parse failed: " + $_.Exception.Message))
    }
    return $lines
}

function Write-PacketManifest {
    param([string]$Root)
    $rows = New-Object System.Collections.Generic.List[object]
    Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($Root.TrimEnd("\").Length + 1).Replace("\", "/")
        $rows.Add([pscustomobject]@{
            RelativePath = $relative
            SizeBytes = $_.Length
            SHA256 = Get-Sha256 $_.FullName
        })
    }
    $rows | Export-Csv -LiteralPath (Join-Path $Root "static\packet_manifest.csv") -NoTypeInformation -Encoding UTF8
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$configCandidates = @(
    (Join-Path $scriptRoot "workspace.json"),
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
    throw "workspace.json was not found beside the collector or in the canonical workspace."
}

$config = Read-Utf8Text $configPath | ConvertFrom-Json
$script:ProjectRoot = [System.IO.Path]::GetFullPath([string]$config.project_root)
$toolsRoot = [System.IO.Path]::GetFullPath([string]$config.tools_root)
$handoffRoot = [System.IO.Path]::GetFullPath([string]$config.handoff_root)
$downloadsRoot = [System.IO.Path]::GetFullPath([string]$config.downloads_root)

foreach ($required in @($script:ProjectRoot, $toolsRoot, $handoffRoot, $downloadsRoot)) {
    if ([string]::IsNullOrWhiteSpace($required)) { throw "workspace.json contains an empty required path." }
}
if (-not (Test-Path -LiteralPath (Join-Path $script:ProjectRoot "project.godot") -PathType Leaf)) {
    throw "project_root does not contain project.godot: $script:ProjectRoot"
}
if (-not (Test-Path -LiteralPath (Join-Path $script:ProjectRoot ".git") -PathType Container)) {
    throw "project_root is not a Git working tree: $script:ProjectRoot"
}
if (-not (Test-Path -LiteralPath (Join-Path $toolsRoot ".git") -PathType Container)) {
    throw "tools_root is not a Git working tree: $toolsRoot"
}

Ensure-Directory $handoffRoot
Ensure-Directory (Join-Path $handoffRoot "screenshots")
Ensure-Directory (Join-Path $handoffRoot "profiler")
Ensure-Directory (Join-Path $handoffRoot "logs")
Ensure-Directory (Join-Path $handoffRoot "backups\issue-packets")

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dnd-diagnostics-" + [guid]::NewGuid().ToString("N"))
$script:StageRoot = Join-Path $tempRoot "issue"
$tempZip = Join-Path $tempRoot "issue.zip"
$issuePath = Join-Path $handoffRoot "issue.zip"
$uploadPath = Join-Path $downloadsRoot ("dnd-" + $Preset + "-issue-" + $timestamp + ".zip")

$script:Warnings = New-Object System.Collections.ArrayList
$script:FilesByKey = @{}
$script:EvidenceManifest = New-Object System.Collections.Generic.List[object]
$script:TrackedFiles = @{}

try {
    Write-Step "Preparing diagnostic packet staging"
    foreach ($directory in @(
        $script:StageRoot,
        (Join-Path $script:StageRoot "source"),
        (Join-Path $script:StageRoot "evidence"),
        (Join-Path $script:StageRoot "git"),
        (Join-Path $script:StageRoot "static"),
        (Join-Path $script:StageRoot "tooling")
    )) {
        Ensure-Directory $directory
    }

    Write-Step "Indexing tracked project files"
    $trackedPaths = @(& git -C $script:ProjectRoot -c core.quotepath=false ls-files)
    if ($LASTEXITCODE -ne 0) { throw "Could not index tracked project files." }
    foreach ($trackedPath in $trackedPaths) {
        $key = ([string]$trackedPath).Replace("\", "/").ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($key)) {
            $script:TrackedFiles[$key] = $true
        }
    }

    Write-Step ("Selecting source for preset: " + $Preset)
    $textExtensions = @(".gd", ".tscn", ".tres", ".godot", ".md", ".txt", ".json", ".cfg", ".csv")
    [void](Add-ProjectFile "project.godot" "Project configuration")
    [void](Add-ProjectFile "scripts\infrastructure\runtime_diagnostics.gd" "Runtime diagnostic capture")
    [void](Add-ProjectFile "scenes\battle\EnvironmentIntegrationScenario.tscn" "Primary integration scenario" -Optional)
    [void](Add-ProjectFile "scenes\battle\BattleScenario.tscn" "Primary battle scenario" -Optional)

    if ($Preset -eq "unit-content-authoring") {
        Add-ProjectTree "scenes\units" @(".tscn") "Unit scenes"
        Add-ProjectTree "scripts\presentation" @(".gd") "Unit presentation schema"
        Add-ProjectTree "scripts\framework" @(".gd") "Unit registration and scenario composition"
        Add-ProjectTree "data" @(".tres") "Authored unit resources" -Optional
        Add-ProjectTree "docs\architecture" @(".md") "Unit authoring contracts" -Optional
    }
    else {
        Add-ProjectTree "scripts" @(".gd") "Authoritative code, presentation, controllers, diagnostics, and tests"
        Add-ProjectTree "scenes" @(".tscn") "Runtime scene composition"
        Add-ProjectTree "data" @(".tres", ".cfg", ".json") "Authored runtime resources" -Optional
        Add-ProjectTree "docs\architecture" @(".md", ".txt") "Architecture and regression contracts" -Optional
        Add-ProjectTree "tests" @(".gd") "Regression tests" -Optional
    }

    foreach ($additionalPath in $AdditionalPaths) {
        if ([string]::IsNullOrWhiteSpace($additionalPath)) { continue }
        $normalized = Normalize-RelativePath $additionalPath
        $absolute = Join-Path $script:ProjectRoot $normalized
        if (Test-Path -LiteralPath $absolute -PathType Container) {
            Add-ProjectTree -RelativeDirectory $normalized -Extensions @() -Reason "Explicitly requested additional tree"
        }
        else {
            [void](Add-ProjectFile $normalized "Explicitly requested additional file")
        }
    }

    Add-ChangedAndUntrackedFiles
    Add-ReferencedDependencies

    Write-Step ("Copying " + $script:FilesByKey.Count + " selected source files")
    $sourceManifest = New-Object System.Collections.Generic.List[object]
    foreach ($file in @($script:FilesByKey.Values | Sort-Object RelativePath)) {
        $relative = [string]$file.RelativePath
        $destination = Join-Path (Join-Path $script:StageRoot "source") $relative
        Ensure-Directory (Split-Path -Parent $destination)
        Copy-Item -LiteralPath ([string]$file.AbsolutePath) -Destination $destination -Force
        $item = Get-Item -LiteralPath ([string]$file.AbsolutePath)
        $sourceManifest.Add([pscustomobject]@{
            RelativePath = $relative.Replace("\", "/")
            Reason = [string]$file.Reason
            GitState = Get-TrackedState $relative
            SizeBytes = $item.Length
            ModifiedLocal = $item.LastWriteTime.ToString("o")
            SHA256 = Get-Sha256 $item.FullName
        })
    }
    $sourceManifest | Export-Csv -LiteralPath (Join-Path $script:StageRoot "static\source_manifest.csv") -NoTypeInformation -Encoding UTF8
    @($sourceManifest | ForEach-Object { $_.RelativePath }) | Set-Content -LiteralPath (Join-Path $script:StageRoot "static\source_tree.txt") -Encoding UTF8

    Write-Step "Capturing request and runtime evidence"
    $requestPath = Join-Path $handoffRoot "request.md"
    if (-not (Test-Path -LiteralPath $requestPath -PathType Leaf)) {
        $templatePath = Join-Path $toolsRoot "templates\request.md"
        if (Test-Path -LiteralPath $templatePath -PathType Leaf) {
            Copy-Item -LiteralPath $templatePath -Destination $requestPath -Force
        }
        else {
            Write-Utf8NoBom -Path $requestPath -Text "# Issue Request`r`n`r`n## Expected`r`n`r`n## Actual`r`n`r`n## Reproduction Steps`r`n`r`n## Capture Moment`r`n`r`n## Scope`r`n"
        }
        Add-Warning "request.md did not exist; a template was created. Fill it in and recollect for best results."
    }
    try {
        $requestText = Read-Utf8Text $requestPath
        if ($requestText -match "Describe the problem in one sentence" -or $requestText -match "## Expected Behavior\s*\r?\n\s*What should happen") {
            Add-Warning "request.md still appears to contain template placeholders. Fill it in and recollect for strongest knowledge transfer."
        }
    }
    catch {
        Add-Warning ("Could not inspect request.md completeness: " + $_.Exception.Message)
    }
    [void](Add-EvidenceFile $requestPath "request.md" "request")

    foreach ($runtimeName in @(
        "runtime_snapshot.json",
        "runtime_snapshot.txt",
        "runtime_events.jsonl",
        "runtime_performance.csv",
        "runtime_scene_tree.csv",
        "runtime_manifest.json",
        "latest_runtime_capture.json",
        "runtime.log"
    )) {
        [void](Add-EvidenceFile (Join-Path $handoffRoot $runtimeName) ("evidence\runtime\" + $runtimeName) "runtime" -Optional)
    }
    Write-RuntimeEventSummary (Join-Path $handoffRoot "runtime_events.jsonl")

    $archiveCaptureCount = 0
    $capturesRoot = Join-Path $handoffRoot "captures"
    if (Test-Path -LiteralPath $capturesRoot -PathType Container) {
        foreach ($captureDirectory in @(Get-ChildItem -LiteralPath $capturesRoot -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First $MaxRuntimeCaptures)) {
            $archiveCaptureCount += 1
            foreach ($captureFile in @(Get-ChildItem -LiteralPath $captureDirectory.FullName -Recurse -File)) {
                $captureRelative = $captureFile.FullName.Substring($captureDirectory.FullName.TrimEnd("\").Length + 1)
                $destination = "evidence\runtime\captures\" + $captureDirectory.Name + "\" + $captureRelative
                [void](Add-EvidenceFile $captureFile.FullName $destination "runtime-archive" -Optional)
            }
        }
    }

    $logCandidates = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($logRoot in @((Join-Path $handoffRoot "logs"))) {
        if (Test-Path -LiteralPath $logRoot -PathType Container) {
            Get-ChildItem -LiteralPath $logRoot -Recurse -File | ForEach-Object { $logCandidates.Add($_) }
        }
    }
    $runtimeSnapshotPath = Join-Path $handoffRoot "runtime_snapshot.json"
    if (Test-Path -LiteralPath $runtimeSnapshotPath -PathType Leaf) {
        try {
            $runtimeSnapshot = Read-Utf8Text $runtimeSnapshotPath | ConvertFrom-Json
            $workspaceSnapshot = Get-PropertyValue $runtimeSnapshot "workspace" $null
            $userDataDir = [string](Get-PropertyValue $workspaceSnapshot "user_data_dir" "")
            if (-not [string]::IsNullOrWhiteSpace($userDataDir)) {
                $godotLogRoot = Join-Path $userDataDir "logs"
                if (Test-Path -LiteralPath $godotLogRoot -PathType Container) {
                    Get-ChildItem -LiteralPath $godotLogRoot -File | ForEach-Object { $logCandidates.Add($_) }
                }
            }
        }
        catch {
            Add-Warning ("Could not discover Godot user-data logs from runtime_snapshot.json: " + $_.Exception.Message)
        }
    }
    $logIndex = 0
    foreach ($logFile in @($logCandidates | Sort-Object LastWriteTime -Descending | Select-Object -First $MaxLogFiles)) {
        $logIndex += 1
        $name = ("{0:D2}-{1}" -f $logIndex, $logFile.Name)
        [void](Add-EvidenceFile $logFile.FullName ("evidence\logs\" + $name) "log" -Optional)
    }

    $screenshotRoot = Join-Path $handoffRoot "screenshots"
    if (Test-Path -LiteralPath $screenshotRoot -PathType Container) {
        $screenshotIndex = 0
        Get-ChildItem -LiteralPath $screenshotRoot -File | Where-Object {
            $_.Extension.ToLowerInvariant() -in @(".png", ".jpg", ".jpeg", ".webp")
        } | Sort-Object LastWriteTime -Descending | Select-Object -First $MaxScreenshots | ForEach-Object {
            $screenshotIndex += 1
            $name = ("{0:D2}-{1}" -f $screenshotIndex, $_.Name)
            [void](Add-EvidenceFile $_.FullName ("evidence\screenshots\" + $name) "screenshot" -Optional)
        }
    }

    Write-Step "Collecting and summarizing Godot profiler evidence"
    $profilerCandidates = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $profilerRoot = Join-Path $handoffRoot "profiler"
    if (Test-Path -LiteralPath $profilerRoot -PathType Container) {
        Get-ChildItem -LiteralPath $profilerRoot -Recurse -File | ForEach-Object { $profilerCandidates.Add($_) }
    }
    foreach ($legacyName in @("frame-issues", "frame-issues.csv")) {
        $legacyPath = Join-Path $toolsRoot $legacyName
        if (Test-Path -LiteralPath $legacyPath -PathType Leaf) {
            $profilerCandidates.Add((Get-Item -LiteralPath $legacyPath))
        }
    }

    $profilerSummaries = New-Object System.Collections.Generic.List[object]
    $profilerIndex = 0
    foreach ($profilerFile in @($profilerCandidates | Sort-Object LastWriteTime -Descending | Select-Object -First $MaxProfilerFiles)) {
        $profilerIndex += 1
        $destinationName = ("{0:D2}-{1}" -f $profilerIndex, $profilerFile.Name)
        [void](Add-EvidenceFile $profilerFile.FullName ("evidence\profiler\raw\" + $destinationName) "profiler" -Optional)
        $profilerSummaries.Add((Get-ProfilerFileSummary $profilerFile.FullName))
    }
    # Do not use @($genericList) here. Windows PowerShell 5.1 can throw
    # "Argument types do not match" for an empty Generic.List[object].
    $profilerSummaryArray = [object[]]@()
    if ($profilerSummaries.Count -gt 0) {
        $profilerSummaryArray = [object[]]$profilerSummaries.ToArray()
    }
    Write-ProfilerSummary -ProfilerSummaries $profilerSummaryArray

    $coverageRelative = "static\diagnostic_coverage.json"
    $coverage = [ordered]@{
        schema_version = 1
        generated_at_local = (Get-Date).ToString("o")
        runtime_snapshot = (Test-Path -LiteralPath (Join-Path $handoffRoot "runtime_snapshot.json") -PathType Leaf)
        runtime_events = (Test-Path -LiteralPath (Join-Path $handoffRoot "runtime_events.jsonl") -PathType Leaf)
        runtime_performance = (Test-Path -LiteralPath (Join-Path $handoffRoot "runtime_performance.csv") -PathType Leaf)
        runtime_scene_tree = (Test-Path -LiteralPath (Join-Path $handoffRoot "runtime_scene_tree.csv") -PathType Leaf)
        archived_capture_count = $archiveCaptureCount
        profiler_file_count = $profilerSummaries.Count
        screenshot_file_count = @($script:EvidenceManifest | Where-Object { $_.Kind -eq "screenshot" }).Count
        log_file_count = @($script:EvidenceManifest | Where-Object { $_.Kind -eq "log" }).Count
        source_file_count = $script:FilesByKey.Count
        request_present = (Test-Path -LiteralPath $requestPath -PathType Leaf)
    }
    Write-Utf8NoBom -Path (Join-Path $script:StageRoot $coverageRelative) -Text (($coverage | ConvertTo-Json -Depth 5) + [Environment]::NewLine)

    $script:EvidenceManifest | Export-Csv -LiteralPath (Join-Path $script:StageRoot "static\evidence_manifest.csv") -NoTypeInformation -Encoding UTF8

    Write-Step "Capturing Git and environment evidence"
    Invoke-GitCapture $script:ProjectRoot @("branch", "--show-current") (Join-Path $script:StageRoot "git\branch.txt") "project branch"
    Invoke-GitCapture $script:ProjectRoot @("rev-parse", "HEAD") (Join-Path $script:StageRoot "git\head.txt") "project HEAD"
    Invoke-GitCapture $script:ProjectRoot @("status", "--short", "--branch", "--untracked-files=all") (Join-Path $script:StageRoot "git\status.txt") "project status"
    Invoke-GitCapture $script:ProjectRoot @("status", "--porcelain=v2", "--branch", "--untracked-files=all") (Join-Path $script:StageRoot "git\status_porcelain_v2.txt") "project porcelain v2 status"
    Invoke-GitCapture $script:ProjectRoot @("describe", "--always", "--dirty", "--tags") (Join-Path $script:StageRoot "git\describe.txt") "project describe"
    Invoke-GitCapture $script:ProjectRoot @("tag", "--points-at", "HEAD") (Join-Path $script:StageRoot "git\tags_at_head.txt") "project tags at HEAD"
    Invoke-GitCapture $script:ProjectRoot @("show", "--stat", "--oneline", "--decorate", "HEAD") (Join-Path $script:StageRoot "git\head_summary.txt") "project HEAD summary"
    Invoke-GitCapture $script:ProjectRoot @("diff", "--stat") (Join-Path $script:StageRoot "git\working_tree_stat.txt") "working-tree diff stat"
    Invoke-GitCapture $script:ProjectRoot @("diff", "--name-status") (Join-Path $script:StageRoot "git\working_tree_name_status.txt") "working-tree file status"
    Invoke-GitCapture $script:ProjectRoot @("diff", "--binary") (Join-Path $script:StageRoot "git\working_tree.patch") "working-tree diff"
    Invoke-GitCapture $script:ProjectRoot @("diff", "--cached", "--binary") (Join-Path $script:StageRoot "git\index.patch") "index diff"
    Invoke-GitCapture $script:ProjectRoot @("log", "-25", "--date=iso-strict", "--pretty=format:%H%x09%ad%x09%an%x09%s") (Join-Path $script:StageRoot "git\recent_commits.tsv") "recent commits"
    Invoke-GitCapture $script:ProjectRoot @("remote", "-v") (Join-Path $script:StageRoot "git\remotes.txt") "project remotes"
    Invoke-GitCapture $script:ProjectRoot @("submodule", "status", "--recursive") (Join-Path $script:StageRoot "git\submodules.txt") "project submodules"
    Invoke-GitCapture $toolsRoot @("rev-parse", "HEAD") (Join-Path $script:StageRoot "git\tools_head.txt") "tools HEAD"
    Invoke-GitCapture $toolsRoot @("status", "--short", "--branch", "--untracked-files=all") (Join-Path $script:StageRoot "git\tools_status.txt") "tools status"
    Invoke-GitCapture $toolsRoot @("diff", "--binary") (Join-Path $script:StageRoot "git\tools_diff.patch") "tools diff"

    $environment = [ordered]@{
        collector = "DND Diagnostic Collector v3"
        preset = $Preset
        collected_at_local = (Get-Date).ToString("o")
        powershell_version = $PSVersionTable.PSVersion.ToString()
        dotnet_version = [Environment]::Version.ToString()
        operating_system = [Environment]::OSVersion.VersionString
        os_64_bit = [Environment]::Is64BitOperatingSystem
        process_64_bit = [Environment]::Is64BitProcess
        machine_name = $env:COMPUTERNAME
        user_name = $env:USERNAME
        processor_identifier = $env:PROCESSOR_IDENTIFIER
        processor_count = $env:NUMBER_OF_PROCESSORS
        workspace_config_path = [System.IO.Path]::GetFullPath($configPath)
        project_root = $script:ProjectRoot
        tools_root = $toolsRoot
        handoff_root = $handoffRoot
        downloads_root = $downloadsRoot
        godot_commands = @(
            Get-Command -Name @("godot*", "Godot*") -ErrorAction SilentlyContinue | Select-Object Name, Source, Version
        )
    }
    try {
        $environment["video_controllers"] = @(
            Get-CimInstance Win32_VideoController -ErrorAction Stop | Select-Object Name, DriverVersion, AdapterRAM, VideoProcessor, Status
        )
    }
    catch {
        $environment["video_controller_capture_error"] = $_.Exception.Message
    }
    Write-Utf8NoBom -Path (Join-Path $script:StageRoot "static\environment.json") -Text (($environment | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
    Copy-Item -LiteralPath $configPath -Destination (Join-Path $script:StageRoot "static\workspace.json") -Force

    $inventory = New-Object System.Collections.Generic.List[object]
    Get-ChildItem -LiteralPath $script:ProjectRoot -Recurse -File -Force | Where-Object {
        $_.FullName -notmatch '[\\/]\.git[\\/]' -and $_.FullName -notmatch '[\\/]\.godot[\\/]'
    } | ForEach-Object {
        $inventory.Add([pscustomobject]@{
            RelativePath = Get-ProjectRelativePath $_.FullName
            Extension = $_.Extension.ToLowerInvariant()
            SizeBytes = $_.Length
            ModifiedLocal = $_.LastWriteTime.ToString("o")
        })
    }
    $inventory | Export-Csv -LiteralPath (Join-Path $script:StageRoot "static\project_inventory.csv") -NoTypeInformation -Encoding UTF8

    foreach ($toolingFile in @(
        "collect_issue_diagnostics.ps1",
        "collect-issue.ps1",
        "collect-issue.cmd",
        "Import-GodotProfilerExport.ps1",
        "Validate-DndIssuePacket.ps1",
        "README.md",
        "docs\workflows\diagnostic_issue_collector.md",
        "docs\workflows\complex_system_debugging_playbook.md",
        "templates\request.md"
    )) {
        $source = Join-Path $toolsRoot $toolingFile
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            $destination = Join-Path (Join-Path $script:StageRoot "tooling") $toolingFile
            Ensure-Directory (Split-Path -Parent $destination)
            Copy-Item -LiteralPath $source -Destination $destination -Force
        }
    }

    Write-Step "Generating agent-first knowledge-transfer summary"
    $branchText = ""
    $headText = ""
    try { $branchText = (Read-Utf8Text (Join-Path $script:StageRoot "git\branch.txt")).Trim() } catch {}
    try { $headText = (Read-Utf8Text (Join-Path $script:StageRoot "git\head.txt")).Trim() } catch {}
    $runtimeLines = Get-RuntimeSummaryLines $runtimeSnapshotPath
    $agentLines = New-Object System.Collections.Generic.List[string]
    $agentLines.Add("# DND Diagnostic Packet - Read This First")
    $agentLines.Add("")
    $agentLines.Add(("Collected: **{0}**" -f (Get-Date).ToString("o")))
    $agentLines.Add(("Preset: **{0}**" -f $Preset))
    $agentLines.Add(("Project branch: **{0}**" -f $branchText))
    $agentLines.Add(("Project HEAD: {0}" -f $headText))
    $agentLines.Add("")
    $agentLines.Add("## Evidence priority")
    $agentLines.Add("")
    $agentLines.Add("1. request.md for expected behavior, actual behavior, reproduction, and capture moment.")
    $agentLines.Add("2. source/ plus static/source_manifest.csv for implementation truth.")
    $agentLines.Add("3. evidence/runtime/ for authoritative live state, event history, performance samples, and scene-tree state.")
    $agentLines.Add("4. evidence/profiler/ for Godot Profiler, Visual Profiler, Monitors, Video RAM, or ObjectDB exports.")
    $agentLines.Add("5. git/ for working-tree drift and recent history.")
    $agentLines.Add("6. Screenshots for game feel and visual timing; do not use screenshots as simulation authority.")
    $agentLines.Add("")
    $agentLines.Add("## Runtime summary")
    $agentLines.Add("")
    foreach ($line in $runtimeLines) { $agentLines.Add(("- " + $line)) }
    $agentLines.Add("")
    $agentLines.Add("## Packet inventory")
    $agentLines.Add("")
    $agentLines.Add(("- Selected source files: {0}" -f $sourceManifest.Count))
    $agentLines.Add(("- Evidence files: {0}" -f $script:EvidenceManifest.Count))
    $agentLines.Add(("- Archived runtime captures: {0}" -f $coverage.archived_capture_count))
    $agentLines.Add(("- Profiler files: {0}" -f $profilerSummaries.Count))
    $agentLines.Add(("- Screenshots: {0}" -f $coverage.screenshot_file_count))
    $agentLines.Add(("- Logs: {0}" -f $coverage.log_file_count))
    $agentLines.Add(("- Collector warnings: {0}" -f $script:Warnings.Count))
    $agentLines.Add("")
    $agentLines.Add("## Debugging method")
    $agentLines.Add("")
    $agentLines.Add("Correlate the player's visible symptom with the exact capture window in runtime_events.jsonl and runtime_performance.csv, then inspect the relevant get_debug_snapshot() output and source contract. Prefer a narrow broken boundary over a broad speculative rewrite.")
    Write-Utf8NoBom -Path (Join-Path $script:StageRoot "AGENT_READ_FIRST.md") -Text (($agentLines -join [Environment]::NewLine) + [Environment]::NewLine)

    # Avoid the same Windows PowerShell 5.1 collection binder edge case for
    # an empty ArrayList when the collection completed without warnings.
    $warningLines = [object[]]@()
    if ($script:Warnings.Count -gt 0) {
        $warningLines = [object[]]$script:Warnings.ToArray()
    }
    if ($warningLines.Count -eq 0) {
        $warningLines = @("No collector warnings.")
    }
    Write-Utf8NoBom -Path (Join-Path $script:StageRoot "collector_warnings.txt") -Text (($warningLines -join [Environment]::NewLine) + [Environment]::NewLine)

    $readme = @"
DND Diagnostic Collector v3
===========================
Preset: $Preset

This packet is designed for complex cross-system debugging and knowledge transfer.
It contains focused source, exact Git state, runtime snapshots, a rolling event window,
performance samples, scene-tree state, screenshots, logs, profiler exports, manifests,
and the collector tooling required to understand how the packet was produced.

Start with AGENT_READ_FIRST.md and request.md.
The collector does not modify, stage, commit, push, or launch the Godot project.
"@
    Write-Utf8NoBom -Path (Join-Path $script:StageRoot "README.txt") -Text ($readme.Trim() + [Environment]::NewLine)

    Write-PacketManifest $script:StageRoot

    Write-Step "Building and validating issue.zip"
    Compress-Archive -Path (Join-Path $script:StageRoot "*") -DestinationPath $tempZip -CompressionLevel Optimal -Force
    if (-not (Test-Path -LiteralPath $tempZip -PathType Leaf)) { throw "Temporary issue ZIP was not created." }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($tempZip)
    try {
        $entryNames = @($archive.Entries | ForEach-Object { $_.FullName.Replace("\", "/") })
        foreach ($requiredEntry in @(
            "AGENT_READ_FIRST.md",
            "request.md",
            "README.txt",
            "static/source_manifest.csv",
            "static/evidence_manifest.csv",
            "static/packet_manifest.csv",
            "static/diagnostic_coverage.json",
            "git/status.txt"
        )) {
            if (-not ($entryNames -contains $requiredEntry)) {
                throw "Generated packet is missing required entry: $requiredEntry"
            }
        }
        $sourceEntries = @($entryNames | Where-Object { $_.StartsWith("source/") -and -not $_.EndsWith("/") })
        if ($sourceEntries.Count -lt 1) { throw "Generated packet contains no source files." }
    }
    finally {
        $archive.Dispose()
    }

    if (Test-Path -LiteralPath $issuePath -PathType Leaf) {
        $backup = Join-Path $handoffRoot ("backups\issue-packets\issue-before-" + $Preset + "-" + $timestamp + ".zip")
        Move-Item -LiteralPath $issuePath -Destination $backup -Force
    }
    Move-Item -LiteralPath $tempZip -Destination $issuePath -Force
    Copy-Item -LiteralPath $issuePath -Destination $uploadPath -Force

    $issueHash = Get-Sha256 $issuePath
    $pointer = [ordered]@{
        schema_version = 2
        preset = $Preset
        generated_at_local = (Get-Date).ToString("o")
        canonical_issue = $issuePath
        upload_copy = $uploadPath
        size_bytes = (Get-Item -LiteralPath $issuePath).Length
        sha256 = $issueHash
        source_file_count = $sourceManifest.Count
        evidence_file_count = $script:EvidenceManifest.Count
        profiler_file_count = $profilerSummaries.Count
        warning_count = $script:Warnings.Count
    }
    Write-Utf8NoBom -Path (Join-Path $handoffRoot "latest_issue.json") -Text (($pointer | ConvertTo-Json -Depth 6) + [Environment]::NewLine)

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host " DND DIAGNOSTIC PACKET READY" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host ("Canonical: " + $issuePath)
    Write-Host ("UPLOAD:    " + $uploadPath) -ForegroundColor Yellow
    Write-Host ("SHA256:    " + $issueHash)
    Write-Host ("Source:    " + $sourceManifest.Count + " files")
    Write-Host ("Evidence:  " + $script:EvidenceManifest.Count + " files")
    Write-Host ("Profiler:  " + $profilerSummaries.Count + " files")
    Write-Host ("Warnings:  " + $script:Warnings.Count)
}
finally {
    if (Test-Path -LiteralPath $tempRoot -PathType Container) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
