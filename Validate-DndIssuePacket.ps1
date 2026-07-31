[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$IssuePath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $IssuePath -PathType Leaf)) {
    throw "Issue packet was not found: $IssuePath"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($IssuePath)
try {
    $entriesByName = @{}
    foreach ($entry in $archive.Entries) {
        $entriesByName[$entry.FullName.Replace("\", "/")] = $entry
    }

    foreach ($required in @(
        "AGENT_READ_FIRST.md",
        "request.md",
        "README.txt",
        "static/source_manifest.csv",
        "static/evidence_manifest.csv",
        "static/packet_manifest.csv",
        "static/diagnostic_coverage.json",
        "git/status.txt"
    )) {
        if (-not $entriesByName.ContainsKey($required)) {
            throw "Issue packet is missing required entry: $required"
        }
    }

    $manifestEntry = $entriesByName["static/packet_manifest.csv"]
    $reader = New-Object System.IO.StreamReader($manifestEntry.Open())
    try { $manifestText = $reader.ReadToEnd() } finally { $reader.Dispose() }
    $temporaryCsv = Join-Path ([System.IO.Path]::GetTempPath()) ("dnd-packet-manifest-" + [guid]::NewGuid().ToString("N") + ".csv")
    [System.IO.File]::WriteAllText($temporaryCsv, $manifestText, (New-Object System.Text.UTF8Encoding($false)))
    try {
        $rows = @(Import-Csv -LiteralPath $temporaryCsv)
    }
    finally {
        Remove-Item -LiteralPath $temporaryCsv -Force -ErrorAction SilentlyContinue
    }

    foreach ($row in $rows) {
        $relative = [string]$row.RelativePath
        if (-not $entriesByName.ContainsKey($relative)) {
            throw "Packet manifest references a missing entry: $relative"
        }
        $entry = $entriesByName[$relative]
        $stream = $entry.Open()
        try {
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                $hashBytes = $sha.ComputeHash($stream)
            }
            finally {
                $sha.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }
        $actualHash = ([System.BitConverter]::ToString($hashBytes)).Replace("-", "").ToLowerInvariant()
        if ($actualHash -ne ([string]$row.SHA256).ToLowerInvariant()) {
            throw "Packet manifest hash mismatch: $relative"
        }
        if ([long]$entry.Length -ne [long]$row.SizeBytes) {
            throw "Packet manifest size mismatch: $relative"
        }
    }

    $manifestPaths = @{}
    foreach ($row in $rows) {
        $manifestPaths[[string]$row.RelativePath] = $true
    }
    foreach ($entryName in $entriesByName.Keys) {
        if ($entryName.EndsWith("/") -or $entryName -eq "static/packet_manifest.csv") { continue }
        if (-not $manifestPaths.ContainsKey($entryName)) {
            throw "Packet contains an unmanifested entry: $entryName"
        }
    }

    $sourceCount = @($entriesByName.Keys | Where-Object { $_.StartsWith("source/") -and -not $_.EndsWith("/") }).Count
    $evidenceCount = @($entriesByName.Keys | Where-Object { $_.StartsWith("evidence/") -and -not $_.EndsWith("/") }).Count
    Write-Host "[PASS] DND diagnostic issue packet" -ForegroundColor Green
    Write-Host ("Path: " + (Get-Item -LiteralPath $IssuePath).FullName)
    Write-Host ("Entries: " + $entriesByName.Count)
    Write-Host ("Source files: " + $sourceCount)
    Write-Host ("Evidence files: " + $evidenceCount)
    Write-Host ("SHA256: " + (Get-FileHash -LiteralPath $IssuePath -Algorithm SHA256).Hash.ToLowerInvariant())
}
finally {
    $archive.Dispose()
}
