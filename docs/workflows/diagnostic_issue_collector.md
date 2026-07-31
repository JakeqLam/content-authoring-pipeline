# Diagnostic Issue Collector v3

## Purpose

Diagnostic Collector v3 creates one self-contained debugging and knowledge-transfer packet. It is designed for problems that cross simulation, presentation, input, AI, pathfinding, performance, scene composition, and authored data.

The packet follows this evidence hierarchy:

1. `request.md` explains expected behavior, actual behavior, reproduction, and the exact capture moment.
2. `source/` is implementation truth for the captured working tree.
3. `evidence/runtime/` contains authoritative live state and the event/performance window surrounding F12.
4. `evidence/profiler/` contains exported Godot profiler evidence.
5. `git/` explains source drift and recent history.
6. Screenshots explain game feel and visual timing, but are not authoritative simulation state.

## Runtime capture

`RuntimeDiagnostics` continuously keeps a bounded in-memory history. Press **F12** immediately after reproducing an issue. It writes:

- `runtime_snapshot.json`: complete structured snapshot.
- `runtime_snapshot.txt`: quick human-readable summary.
- `runtime_events.jsonl`: recent commands, simulation events, group-movement decisions, engagement decisions, and AI decisions.
- `runtime_performance.csv`: recent built-in and DND-specific performance samples.
- `runtime_scene_tree.csv`: scene nodes, scripts, groups, priorities, and positions.
- `runtime_manifest.json`: runtime evidence inventory.
- `latest_runtime_capture.json`: pointer to the latest capture identity and archive.

The collector then generates `runtime_event_summary.txt` with event-type counts and the final 50 timeline entries for fast triage.

Each F12 capture is also archived under `dnd-handoff\captures\<capture-id>` while the canonical root files continue to represent the latest capture. The collector includes the five most recent archives by default.

The runtime snapshot automatically discovers every scene node exposing a zero-argument `get_debug_snapshot()` method. New systems therefore become observable without continually expanding a central hardcoded list.

## Godot profiler integration

Godot's editor Profiler and Visual Profiler remain editor-controlled. Start profiling in the Debugger panel, reproduce the problem, stop at the useful frame range, and export the available data. Put exports under:

```text
dnd-workspace\dnd-handoff\profiler
```

Or import any exported file with:

```powershell
& "$env:USERPROFILE\dnd-workspace\dnd-dev-tools\Import-GodotProfilerExport.ps1" `
  -Path "C:\path\to\export.csv" `
  -Label "rapid-group-click-spike"
```

The collector preserves raw profiler files and generates a summary. It recognizes the Godot Video RAM CSV shape (`Resource Path,Type,Format,Usage`) and provides a generic inventory for Profiler, Visual Profiler, Monitor, ObjectDB, text, and binary exports.

`RuntimeDiagnostics` also registers custom **DND** monitors in Godot's Debugger > Monitors panel:

- Simulation tick
- Active movement plans
- Active movement legs
- Transit stack tiles
- Pending group requests
- Group click-to-commit time
- Runtime event-buffer size

## Collection

After reproducing the issue, pressing F12, and exporting any profiler evidence:

```powershell
& "$env:USERPROFILE\dnd-workspace\dnd-dev-tools\collect-issue.ps1" `
  -Preset full-diagnostics
```

Or double-click `collect-issue.cmd`.

Available presets:

- `full-diagnostics`: broad cross-system packet; recommended default.
- `movement`: movement-oriented label with the same safe source coverage.
- `combat`: combat-oriented label with the same safe source coverage.
- `terrain`: terrain-oriented label with the same safe source coverage.
- `unit-content-authoring`: narrower unit-authoring packet.

The collector writes the canonical packet to `dnd-handoff\issue.zip`, creates a timestamped upload copy in Downloads, backs up the previous packet, and writes `latest_issue.json`.

## Packet map

```text
issue.zip
├── AGENT_READ_FIRST.md
├── request.md
├── README.txt
├── source/
├── evidence/
│   ├── runtime/
│   │   └── captures/ (up to five recent F12 archives)
│   ├── profiler/
│   ├── logs/
│   └── screenshots/
├── git/
├── static/
│   ├── source_manifest.csv
│   ├── evidence_manifest.csv
│   ├── packet_manifest.csv
│   ├── project_inventory.csv
│   ├── environment.json
│   ├── diagnostic_coverage.json
│   └── workspace.json
├── tooling/
└── collector_warnings.txt
```

## Debugging method for receiving agents

Correlate the visible symptom with the exact event and performance window first. Then inspect the matching system snapshot and source contract. Distinguish among:

- intent not produced,
- command not queued,
- plan rejected,
- authoritative step rejected,
- plan interrupted,
- simulation correct but presentation wrong,
- performance spike without logical failure,
- authored scene/resource drift.

Prefer the narrowest broken contract over a broad speculative rewrite.
