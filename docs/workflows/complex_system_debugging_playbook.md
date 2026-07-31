# Complex-System Debugging Playbook

## Why this exists

A visually simple defect can cross input, command production, path planning, authoritative simulation, occupancy, AI, presentation, authored scenes, and frame performance. The squad-movement investigation demonstrated that screenshots alone can make several different failures look identical.

The objective is not to collect the largest possible pile of files. The objective is to preserve enough synchronized evidence to answer:

1. What did the player ask for?
2. What intent did the game produce?
3. What command entered simulation?
4. What authoritative work was created?
5. What happened on each relevant tick?
6. What did presentation show?
7. Was the frame healthy while this occurred?
8. Which source and authored values produced that result?

## Lessons from the squad-movement investigation

The final movement solution was reached by distinguishing failures that appeared similar on screen:

- Auto-retaliation queued a command because continuous travel did not appear as a normal movement plan.
- Arrival settlement visually corrected a mismatch between route-relative followers and final authoritative tiles.
- Shared-spine paths were computationally cheap but forced exact individual plans through the same intermediate corridor.
- Direct paths still looked clumsy while allied occupancy remained exclusive.
- Temporary authoritative allied transit stacking removed the actual traffic rule causing detours and interruptions.

The decisive conclusion was not “use a better pathfinding algorithm.” It was “allied transit occupancy had the wrong gameplay contract.” Runtime state and source evidence made that distinction possible.

## Evidence hierarchy

Use evidence in this order:

1. **Canonical source and exact Git state** establish what code and data existed.
2. **Runtime events and snapshots** establish what the game authoritatively did.
3. **Profiler and performance evidence** establishes whether timing or resource pressure contributed.
4. **Logs and verification** establish errors, warnings, and expected contracts.
5. **Screenshots/video** establish game feel, timing, readability, and visual symptoms.
6. **Conversation history** explains intent and prior decisions, but must not override current source.

## Failure taxonomy

Classify the first broken boundary before proposing a fix.

### Intent boundary

- Input was not recognized.
- Selection was not what the player believed.
- Hover produced an incorrect intent.
- Rapid-click coalescing retained the wrong request.

### Command boundary

- No command was queued.
- A later command replaced the intended command.
- The command payload contained the wrong target, path, source, or order ID.

### Planning boundary

- No legal destination existed.
- The planner treated a soft obstacle as hard.
- A route was valid geometrically but incompatible with exact execution.
- An unreachable order was retried instead of terminating.

### Authoritative-resolution boundary

- TileBoard rejected a step.
- Multiple commands reserved incompatible destinations.
- Occupancy or blocker state differed from planner assumptions.
- A plan was interrupted by combat, interaction, death, or replacement.

### Presentation boundary

- Simulation reached the correct tile but the sprite did not.
- A tween used stale start/end state.
- Presentation correction concealed an authority mismatch and produced rubber-banding.
- Multiple authoritative occupants rendered unreadably.

### Performance boundary

- Hover or discarded clicks performed expensive work.
- One accepted command triggered too many full searches.
- A frame spike correlated with scene churn, pathfinding, rendering, allocation, or shader compilation.
- Profiling overhead itself changed the behavior.

### Authoring boundary

- Scene exports overrode expected defaults.
- A resource/profile was missing or stale.
- Node composition or signal wiring differed from the assumed scenario.

## Capture protocol

1. Make the reproduction as focused and repeatable as possible.
2. Start the relevant Godot profiler before reproducing when performance is involved.
3. Reproduce the problem once.
4. Press F12 immediately after the meaningful failure or spike.
5. Record exactly when F12 was pressed in `request.md`.
6. Export useful editor profiler evidence before changing the scene.
7. Run Diagnostic Collector v3 without editing source between reproduction and collection.
8. Upload the generated timestamped ZIP.

Multiple F12 presses are safe. Each capture is archived and the collector includes recent capture folders.

## Receiving-agent reading order

1. Read `AGENT_READ_FIRST.md`.
2. Read `request.md` and identify the capture moment.
3. Inspect `static/diagnostic_coverage.json` for missing evidence.
4. Inspect `git/status.txt`, `git/describe.txt`, and manifests.
5. Read `runtime_event_summary.txt`, then the exact rows in `runtime_events.jsonl`.
6. Correlate the same elapsed window in `runtime_performance.csv` and frame spikes in `runtime_snapshot.json`.
7. Inspect the relevant hardcoded system snapshot and matching entry under `debug_snapshots_by_node`.
8. Read only the source files governing the first broken boundary.
9. Use screenshots to judge feel and presentation after simulation truth is established.

## Designing new diagnostics

Every complex system should expose a zero-argument `get_debug_snapshot()` that is:

- deterministic,
- side-effect free,
- bounded,
- JSON-serializable after conversion,
- explicit about live authored values,
- explicit about active work and pending work,
- explicit about the most recent rejection/interruption reason,
- explicit about counters that reveal repeated or accidental work.

Useful fields usually include:

- system identifier and configured state,
- authoritative IDs and positions,
- active plans/jobs/requests,
- queue sizes and generation IDs,
- last accepted/rejected command,
- rejection/interruption reason,
- timing for expensive committed work,
- counts of hover work, retries, replacements, and discarded results.

Do not make presentation nodes commit simulation authority merely to simplify diagnostics.

## Profiler interpretation

Use runtime telemetry for continuous, low-overhead context. Use the editor Profiler or Visual Profiler for detailed call/frame analysis. Preserve raw exports even when the collector cannot parse their format.

Correlate profiler evidence with an action and capture moment. A profiler file without “what was happening” is much less useful than a smaller file tied to one reproduction.

## Change discipline

- Prefer one narrow hypothesis per patch.
- Preserve an immediately reversible baseline.
- Do not optimize a system whose broken rule has not been identified.
- Do not fix a presentation symptom by weakening authority.
- Treat failed experiments as evidence and document why they were retired.
- Commit only after compilation and live behavior are verified.
