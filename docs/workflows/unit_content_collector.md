# Unit Content and Ranged Engagement Collector

## Purpose

`collect_issue_unit_content.ps1` is an additive, PowerShell 5.1-compatible collector for bounded Godot unit-content and ranged-engagement work.

It does not replace simulation authority or the existing collector. It closes the evidence gap exposed when Git status listed untracked ranged audio/profile files that were absent from `issue.zip`.

## Presets

### `ranged-engagement`

Collects the authoritative and command-facing surface needed to inspect or patch ranged AI and player engagement:

- controllers
- simulation systems
- framework/registration
- BattleScenario
- ranged and melee unit scenes
- unit definitions
- projectile profiles
- tests
- architecture and regression documents
- recursive `res://` dependencies

### `unit-content-authoring`

Collects the presentation-authoring surface needed for unit scene, animation, projectile, and audio work:

- unit scenes
- presentation scripts and schemas
- unit definitions
- combat audio profiles
- projectile profiles
- ranged audio assets
- architecture documents
- recursive `res://` dependencies

## Guarantees

- Reads canonical paths from `workspace.json`.
- Includes tracked and untracked files from the filesystem.
- Resolves recursive `res://` dependencies.
- Produces source hashes and Git-state labels.
- Includes project and tools Git evidence.
- Includes runtime snapshots/logs when present.
- Writes the stable output `dnd-handoff\issue.zip`.
- Uses `%TEMP%` for staging and removes it afterward.
- Does not modify the Godot project.
- Does not launch Godot.
- Does not stage, commit, or push.

## Commands

```powershell
& "$env:USERPROFILE\dnd-workspace\dnd-dev-tools\collect_issue_unit_content.ps1" -Preset ranged-engagement
```

```powershell
& "$env:USERPROFILE\dnd-workspace\dnd-dev-tools\collect_issue_unit_content.ps1" -Preset unit-content-authoring
```

## Untracked-file classification

Collector v2.1 builds one tracked-file index with `git ls-files` and classifies
collected paths against that in-memory index. It intentionally does not call
`git ls-files --error-unmatch` for individual untracked assets because native
Git stderr is promoted to a terminating `NativeCommandError` by Windows
PowerShell 5.1 when `$ErrorActionPreference` is `Stop`.

This keeps untracked WAV, PNG, TRES, TSCN, and script files collectable while
still recording tracked clean, worktree-modified, index-modified, and untracked
states in `static/manifest.csv`.

