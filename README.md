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

## Diagnostic Collector v3

The default issue workflow captures current source, exact Git state, runtime state, a rolling event window, performance history, scene-tree state, Godot logs, screenshots, and imported profiler evidence. It is intended to transfer a difficult live problem to another agent or thread without depending on conversation history.

### Recommended capture loop

1. Start Godot's Profiler or Visual Profiler when performance is part of the problem.
2. Reproduce one focused problem in the integration scenario.
3. Press **F12 immediately after the meaningful failure or spike**.
4. Export useful Profiler, Visual Profiler, Monitors, Video RAM, or ObjectDB evidence.
5. Import those exports with `Import-GodotProfilerExport.ps1`, or place them in `dnd-handoff\profiler`.
6. Fill in `dnd-handoff\request.md`, especially **Capture Moment**.
7. Run:

```powershell
& "$env:USERPROFILE\dnd-workspace\dnd-dev-tools\collect-issue.ps1" -Preset full-diagnostics
```

The collector validates the packet, preserves the previous `issue.zip`, writes the canonical packet to `dnd-handoff`, and creates a timestamped upload copy in Downloads. A receiving agent should begin with `AGENT_READ_FIRST.md`.

See `docs/workflows/diagnostic_issue_collector.md` for the capture workflow and `docs/workflows/complex_system_debugging_playbook.md` for the evidence hierarchy, failure taxonomy, squad-movement lessons, and receiving-agent method.
