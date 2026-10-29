# GMN1 Correctness Remediation Report

## A. Execution summary

- Repository: `https://github.com/natnakem-cyb/GMN1`
- Branch: `main`
- Starting commit: `e4610f36dc7b109e70279001861b50ad741741e0`
- Ending commit: `e4610f36dc7b109e70279001861b50ad741741e0` (no commit created)
- Godot: not detected on `PATH` or in the checked standard installation locations. `project.godot` declares Godot 4.7 features; the installed runtime version is unknown.
- Initial worktree was already dirty in `README.md`, `data/match_config.json`, and `scripts/simulation/match_simulation.gd` from the preceding box-run work. Those edits were retained. This remediation also changes the manager, network, test, and UI scripts and adds this report.
- Verification-gate review additionally found and fixed intermediate-hash skipping during client catch-up. Regression assertions also now exercise conflicting tactical commands and stale player IDs.
- Final changed files: `README.md`, `data/match_config.json`, `scripts/managers/manager_controller.gd`, `scripts/network/network_session.gd`, `scripts/simulation/match_simulation.gd`, `scripts/tests/determinism_test.gd`, `scripts/ui/main_view.gd`, and untracked `GMN1_CORRECTNESS_REMEDIATION_REPORT.md`.
- Final tracked diff: 756 insertions, 162 deletions across 7 files; the untracked report is not included in `git diff --stat`.
- Changes are uncommitted and were not pushed.

The source changes implement the fixes described below. They have **not** been validated by Godot parsing or runtime tests because the runtime is unavailable; the live networking and reconnect acceptance criteria therefore remain unverified.

## B. Finding-by-finding results

| Finding | Initial status and evidence | Change | Regression coverage / result | Residual risk |
|---|---|---|---|---|
| Local selection caused false hash mismatches and host selection could overwrite the receiver | **Confirmed by source inspection.** `scripts/simulation/match_simulation.gd:70,329` built the hash from state containing selection, `:257` restored it, and `:829` changes it locally. | Hash serialization now excludes selection and presentation-only fields. Snapshot serialization also omits selection; restore preserves the receiver's current selection. Team formations remain hashed; redundant `home_formation`, event history, and last-action/probability/debug strings are excluded because they do not affect simulation outcomes. | Added one-sided-selection, valid snapshot, and receiver-selection assertions in `scripts/tests/determinism_test.gd:50`. **NOT RUN**. | Requires execution in Godot to verify serialization and restore behavior. |
| Substitution requests could target a different player after intervening roster changes | **Confirmed by source inspection.** `scripts/network/network_session.gd:360,543` previously scheduled and resolved a roster index at execution. | Substitution requests/commits now carry the outgoing player's stable ID; `scripts/managers/manager_controller.gd:35` resolves the selected player to that ID before submission, and execution finds the matching active player. | Added same-ID and stale-ID assertions with different local selections in `scripts/tests/determinism_test.gd:50`; existing replay test now uses a player ID. **NOT RUN**. | PVP equivalence is not demonstrated until host/client integration tests run. |
| Command “accepted” status could conceal execution-time rejection | **Confirmed by source inspection.** `scripts/network/network_session.gd:360` schedules after current-state validation; `:543` revalidates at execution and may reject after earlier commands consume resources or cooldowns. | Kept the existing provisional scheduling model (Option B). UI and acknowledgements say “scheduled provisionally”; all peers execute/revalidate in sequence, append `COMMAND_APPLIED` / `COMMAND_REJECTED` with tick, and report the actual outcome. The client-reported tick remains ignored; host scheduling uses host tick. | Added two individually valid conflicting tactical-command assertions in `scripts/tests/determinism_test.gd:50`; execution-time network result agreement is **NOT RUN**. | Runtime evidence is required to prove host/client outcomes remain identical under competing commands. |
| Commands and reconnect metadata conflated committed and applied sequence | **Confirmed by source inspection.** `scripts/network/network_session.gd:410,525,399` previously used `next_sequence - 1`, including future commands. | Added `last_applied_sequence`. Hashes/beacons report the sequence applied through their tick. Clients compare it when reaching the tick (`:423,1061,1112`). Snapshots now record the applied sequence; reconnect replays the contiguous subsequent commit stream and verifies target tick, applied sequence, and hash before resuming (`:847,963`). | Added structural sequence checks in the network code. No network test was run. | Real RPC delivery order, catch-up, and replay remain unverified. |
| Duplicate, stale, late, or gapped network messages could be processed inconsistently | **Confirmed by source inspection.** Processed hashes were not explicitly remembered, beacon/sequence handling had incomplete tick relationships, and no pending-queue cap existed. | Added contiguous sequence and nondecreasing target-tick checks (`scripts/network/network_session.gd:491`), duplicate/stale hash and beacon rejection, applied-sequence verification, ahead-of-host checks, a cap of 8 outstanding hashes, and `network.maximum_pending_commands` (128) for queued/uncheckpointed commands. Integrity violations stop simulation. | Source-level changes only. **NOT RUN**. | Separate-process tests are required for all timing and duplicate-message cases. |
| Client catch-up could step past an intermediate hash tick | **Confirmed by source inspection during this verification.** The client advanced to the beacon watermark, then checked queued hashes once; a catch-up spanning multiple hash intervals would mark the first hash as missed. | `scripts/network/network_session.gd:536` now checks pending hashes after every peer tick, so queued hash checkpoints are compared at their exact simulation tick. | No executable network regression test was available. **NOT RUN**. | Must exercise delayed-client catch-up in two Godot processes. |
| Snapshot restore could mutate before later fields were checked | **Confirmed by source inspection.** `scripts/simulation/match_simulation.gd:95` validates the complete schema; previously restoration mutated before all snapshot fields/references were checked. | Added prevalidation for required state/team/player fields, types, finite values, roster identity and on-pitch status, role/formation references, phase/timer/resource bounds, side orientation, RNG seed, and ball references (`:95,454`). Restore only mutates after validation succeeds (`:257`); player data no longer uses success-shaped defaults for required fields. Snapshot version is now 4. | Added checks for selection preservation, authoritative hash divergence, malformed snapshots, invalid references, wrong version, and unchanged receiver snapshot on rejection. **NOT RUN**. | Godot runtime is needed to validate type/API syntax and exercise atomic restore on actual resources. |
| Reconnect accepted an insufficiently validated bundle and did not verify applied sequence | **Confirmed by source inspection.** `scripts/network/network_session.gd:846` previously did not fully validate bundle metadata/replay completeness; `:963` compared tick/hash only. | Reconnect now validates bundle schema, snapshot version/tick, sequence range, command count/order/ticks/payloads, and target applied sequence before restore. Host remains paused until acknowledgement confirms tick, applied sequence, and hash; client sends an immediate acknowledgement when already at target tick. | No reconnect process test could be run. **NOT RUN**. | Every requested reconnect scenario remains unverified, including invalid hash/version/gap, snapshot boundaries, halftime, near-finish, and timeout. |
| Protocol/schema compatibility after serialized and RPC changes | **Confirmed compatibility concern.** Snapshot layout and command payload/RPC acknowledgement shape changed. | Snapshot version bumped 3→4. `scripts/network/network_session.gd:676` includes a protocol marker in the configuration digest, so old/new builds using this code reject each other during compatibility handshake. | Source inspection only. | Must verify old/new rejection and current/current lobby join using real processes. |

## C. Test evidence

| Check | Result | Evidence |
|---|---|---|
| Baseline determinism test | **NOT RUN** | Attempted `godot --headless --path C:\Users\USER\Documents\Project\GMN1 --script res://scripts/tests/determinism_test.gd`; shell reported `godot` was not recognized. |
| Baseline Godot import/parse | **NOT RUN** | Attempted `godot --headless --editor --path C:\Users\USER\Documents\Project\GMN1 --quit`; same missing executable limitation. |
| Post-change determinism and snapshot regressions | **NOT RUN** | Godot remains unavailable. Test coverage was added to `scripts/tests/determinism_test.gd`. |
| Verification-gate Godot import invocation | **NOT RUN** | Re-attempted `godot --headless --editor --path . --quit`; PowerShell reported that `godot` is not recognized. |
| Verification-gate determinism invocation | **NOT RUN** | Re-attempted `godot --headless --path . --script res://scripts/tests/determinism_test.gd`; PowerShell reported that `godot` is not recognized. |
| VS Code test discovery | **NOT RUN** | No registered VS Code test controller; no tests discovered for the GDScript file. |
| JSON configuration parse | **PASS** | PowerShell `ConvertFrom-Json` parsed `data/match_config.json`; reported `snapshot_version=4`, `maximum_pending_commands=128`. |
| Diff whitespace validation | **PASS** | `git diff --check` completed with no errors. Git emitted only a line-ending notice for `scripts/network/network_session.gd`. |
| Separate-process host/client lockstep | **NOT RUN** | Requires Godot and two live processes. |
| Reconnect integration scenarios | **NOT RUN** | Requires Godot and two live processes. |
| Cross-platform / cross-version determinism | **NOT RUN** | No second runtime/environment was available. |

No runtime or PVP test is reported as passing. The implemented regression assertions and network checks have only been reviewed at source level.

## D. Behavioral compatibility

- Match rules, match duration, command lead, RNG seed/draw order, probability formulas, and tactical costs were not intentionally changed.
- The prior uncommitted box-run changes in `README.md`, `data/match_config.json`, and `scripts/simulation/match_simulation.gd` were retained; they predate this remediation.
- New network configuration: `maximum_pending_commands: 128`.
- Snapshot schema version changed from 3 to 4. Old snapshots are rejected.
- Command payloads use `player_id` instead of `player_index`; reconnect acknowledgements now include applied sequence. The protocol digest marker intentionally rejects older builds/configuration combinations.
- Command acknowledgement wording is now explicitly provisional. Commands that become invalid before execution are still deterministically rejected at their scheduled tick.
- Player selection remains local and is preserved on snapshot restore. A substitution request still targets the user's selected player, but its committed identity is stable.

## E. Remaining limitations

- The Godot script parser, determinism test, and snapshot tests were not run.
- No real host/client synchronization or reconnect result has been demonstrated.
- Duplicate/stale commits, hashes, and beacons; sequence gaps; catch-up limits; command conflicts; and timeout behavior need separate-process tests.
- Cross-platform and cross-version bit-identical behavior is not established.
- `git status --short --branch` reports `## main...origin/main`, seven modified tracked files and this untracked report. `HEAD` remains `e4610f36dc7b109e70279001861b50ad741741e0`; `git diff --check` passes. No commit or push was performed.
- Source inspection supports the intended fixes, but cannot prove Godot runtime behavior or live ENet ordering.

## F. Final recommendation

**FAIL — validation incomplete.** Source changes and regression assertions are present, but the existing determinism test and required live PVP/reconnect tests could not run. Do not treat this remediation as verified until those tests pass in Godot.
