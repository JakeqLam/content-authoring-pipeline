# DND Content Authoring Pipeline

Maintained tooling for collecting, inspecting, processing, and deploying content for the DND-Game project.

## Canonical workspace

```text
%USERPROFILE%\dnd-workspace
├── asset-library
│   ├── pixel-art
│   │   └── asset-upload
│   └── sfx
│       └── asset-upload
├── dnd-dev-tools
├── dnd-handoff
│   └── screenshots
└── dnd-prototype
```

- `dnd-dev-tools`: this pipeline repository.
- `dnd-prototype`: the independent Godot game repository.
- `dnd-handoff`: issue packets, runtime snapshots, logs, and screenshots.
- `asset-library`: downloaded, raw, processed, and curated assets.
- `Downloads`: temporary inbound patches and ZIP bundles.

## Machine-local configuration

`workspace.json` contains absolute paths for the current machine and is ignored by Git.

`workspace.example.json` documents the required schema.

## New-computer bootstrap

```powershell
$Workspace=Join-Path $env:USERPROFILE "dnd-workspace"; New-Item -ItemType Directory -Path $Workspace -Force | Out-Null; git clone "https://github.com/JakeqLam/content-authoring-pipeline.git" (Join-Path $Workspace "dnd-dev-tools"); & (Join-Path $Workspace "dnd-dev-tools\Initialize-DndWorkspace.ps1")
```

To clone the game repository during initialization:

```powershell
& "$env:USERPROFILE\dnd-workspace\dnd-dev-tools\Initialize-DndWorkspace.ps1" -GameRepoUrl "<GAME_REPOSITORY_URL>"
```

## Continuing work across computers and chat threads

The pipeline repository recreates the workflow, but it does not contain the
Godot project or the full asset library.

On another computer:

1. Clone this repository into:

   ```text
   %USERPROFILE%\dnd-workspace\dnd-dev-tools
   ```

2. Run:

   ```powershell
   & "$env:USERPROFILE\dnd-workspace\dnd-dev-tools\Initialize-DndWorkspace.ps1"
   ```

3. Clone the Godot project repository into:

   ```text
   %USERPROFILE%\dnd-workspace\dnd-prototype
   ```

4. Restore the local asset library separately under:

   ```text
   %USERPROFILE%\dnd-workspace\asset-library
   ```

For continuity across chat threads, use durable project artifacts rather than
relying on conversation history alone:

```text
Git repositories
    Preserve game source and pipeline tooling.

README.md and workflow documentation
    Preserve the workspace contract and operating rules.

dnd-handoff\issue.zip
    Preserves current source, Git state, runtime evidence, and focused assets.

Chat context
    Preserves discussion, reasoning, and creative direction.
```

In a fresh thread, upload the latest `issue.zip` and state the active task.
That gives the assistant the current implementation and runtime state without
requiring the original conversation.

## Validation

```powershell
& "$env:USERPROFILE\dnd-workspace\dnd-dev-tools\Test-DndWorkspace.ps1"
```

Never initialize Git at `dnd-workspace`. The pipeline repository belongs at `dnd-workspace\dnd-dev-tools`, and the game repository belongs at `dnd-workspace\dnd-prototype`.

## compiling runtime into issue.zip
```text
$ErrorActionPreference="Stop"; $ConfigPath=Join-Path $env:USERPROFILE "dnd-workspace\dnd-dev-tools\workspace.json"; Write-Host "[1/4] Loading workspace configuration" -ForegroundColor Cyan; if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Missing workspace configuration: $ConfigPath" }; $Config=([System.IO.File]::ReadAllText($ConfigPath,[System.Text.Encoding]::UTF8) | ConvertFrom-Json); $Validator=Join-Path ([string]$Config.tools_root) "Test-DndWorkspace.ps1"; $Collector=Join-Path ([string]$Config.tools_root) "collect_issue.ps1"; Write-Host "[2/4] Validating workspace" -ForegroundColor Cyan; & $Validator -WorkspaceRoot ([string]$Config.workspace_root); Write-Host "[3/4] Collecting current combat-audio evidence" -ForegroundColor Cyan; & $Collector -Preset combat-audio; Write-Host "[4/4] Verifying issue packet" -ForegroundColor Cyan; $Issue=Join-Path ([string]$Config.handoff_root) "issue.zip"; if (-not (Test-Path -LiteralPath $Issue -PathType Leaf)) { throw "Collector completed without producing issue.zip: $Issue" }; $File=Get-Item -LiteralPath $Issue; $Hash=Get-FileHash -LiteralPath $Issue -Algorithm SHA256; Write-Host "Issue packet ready." -ForegroundColor Green; Write-Host "Path:   $($File.FullName)"; Write-Host "Size:   $($File.Length) bytes"; Write-Host "SHA256: $($Hash.Hash)"; Write-Host "Updated: $($File.LastWriteTime)"
```
