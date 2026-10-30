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

## G. Kick-off and out-of-bounds restart implementation (baseline `7fa070985c904f85ae076094195e419b7a83ab5d`)

This focused follow-up implements an authoritative restart lifecycle in `scripts/simulation/match_simulation.gd`:

- Initial, halftime, and post-goal kickoffs use a formation-aware taker/receiver selection and deterministic guaranteed pass delivery. Initial kickoff is explicitly team 0; halftime uses the configured team; goals award the next kickoff to the conceding team.
- Passes track the passer as last touch until reception. Possession changes record the actual receiving/intercepting player. Ball flight tests the complete movement segment against touchline and goal-line boundaries after accounting for ball radius.
- Touchline exits award a throw-in to the opposite of the last-touch team. Goal-line exits award a corner when the defending team touched last, or a goal kick otherwise. Goalkeeper saves have a configured chance to be deflected for a corner; ordinary saves still resolve through the existing rebound/hold behavior. Existing shot and goal probability formulas were not changed.
- Pending restarts store kind, team, position, taker/receiver IDs, delay, and last-touch metadata. While pending, player movement and normal actions stop; the match clock continues during the configured pause. Restarts clear stale ball owner/target/velocity and start a pass-like delivery.
- Restart and last-touch fields (including the boundary crossing point) are authoritative state and snapshot data. Snapshot validation checks enum values, team/player references, pitch/crossing positions, and pending/in-play consistency. Snapshot schema is now 5 and the network code protocol marker is `gmn1-lockstep-3`.
- Added focused regression assertions to `scripts/tests/determinism_test.gd` for 4-4-2 and single-striker kickoffs, halftime, fast touchline/goal-line crossing, both throw-in ownership directions, corner, goal kick, thrower fallback, goal/miss/save outcomes, dead-ball freezing, duplicate prevention, restart snapshot rejection/round-trip, and repeated state hashes.

### Tunable restart parameters

- `match.initial_kickoff_team_index`
- `match.halftime_restart_team_index` (existing)
- `match.goal_reset_seconds` (existing post-goal delay)
- `match.restarts.delay_seconds`
- `match.restarts.goal_area_depth`
- `match.restarts.goal_area_width`
- `match.restarts.role_preference_distance`
- `match.restarts.saved_shot_corner_probability`
- `field.ball_radius` (existing boundary-crossing and legal restart margin)
- `match.pass_ball_speed` (existing restart delivery speed)
- `network.snapshot_version`

### Verification and provenance

- Starting checkout: `main` at `7fa070985c904f85ae076094195e419b7a83ab5d`; it was clean before this follow-up.
- Current follow-up changes are uncommitted and must not be interpreted as pushed. No user changes were discarded.
- Changed files: `GMN1_CORRECTNESS_REMEDIATION_REPORT.md`, `README.md`, `data/match_config.json`, `scripts/network/network_session.gd`, `scripts/simulation/match_simulation.gd`, and `scripts/tests/determinism_test.gd`.
- Godot 4.7 recheck: **NOT RUN** — no `godot`, `godot4`, or `godot_console` executable was found on PATH or in the checked common installation locations.
- Headless Godot import, the deterministic test script, short local match, and live two-process PVP/reconnect testing: **NOT RUN** because the Godot runtime is unavailable.
- VS Code Problems check: **PASS** — no diagnostics reported for the simulation, determinism-test, or network scripts.
- JSON parsing: **PASS** — `data/match_config.json` parses; snapshot version is 5, initial kickoff team is 0, and restart delay is 0.6 seconds.
- `git diff --check`: **PASS**. No GDScript runtime result is claimed.
- Current branch remains `main` at baseline commit `7fa070985c904f85ae076094195e419b7a83ab5d`; follow-up changes remain uncommitted and unpushed.

## H. Kickoff and Out-of-Bounds Restart Validation

### Provenance and production path

- Validation checkout: branch `main`, `HEAD` `7fa070985c904f85ae076094195e419b7a83ab5d` (`7fa0709 Harden deterministic lockstep and reconnect state`).
- Before this validation, the worktree already had six modified tracked files: this report, `README.md`, `data/match_config.json`, `scripts/network/network_session.gd`, `scripts/simulation/match_simulation.gd`, and `scripts/tests/determinism_test.gd`. These restart/previous feature edits were preserved.
- Validation-only changes: corrected the existing determinism test's halftime taker assertion to use the last-touch player after restart IDs are cleared; counted the post-goal kickoff as a delta from the initial kickoff; removed duplicate cleanup that caused a native crash. Also initialized restart helper references and renamed shadowing `owner` parameters to `carrier` in the simulation. Added `scripts/tests/restart_validation_test.gd` and its Godot-generated UID file. The simulation edits address editor diagnostics and do not change runtime behavior.
- `project.godot` declares Godot 4.7 features. Runtime used: **Godot 4.7.2.stable.official.ed1daf0bf**, `C:\Users\USER\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe`.
- Lifecycle trace: `_reset_match_state()` calls `_begin_restart()` for the configured kickoff; `start_match()` executes it immediately. `_tick()` decrements pending restart delays and executes the restart before ordinary play. `_advance_ball()` checks each movement segment and routes exits through `_classify_out_of_bounds()`. `_set_possession()` updates last touch on reception. There is no separate `_restart_after_goal()` method in this checkout: `_resolve_shot()` scores, clears old ball references, and calls `_begin_restart()` for the conceding side. `_start_second_half()` switches ends and performs its kickoff. `create_snapshot()`, `validate_snapshot()`, `restore_snapshot()`, and `get_state_hash()` include/validate authoritative restart and last-touch state.
- Snapshot/config/protocol consistency: **PASS** — `network.snapshot_version` is 5, `NetworkSession.PROTOCOL_VERSION` is `gmn1-lockstep-3`, and the README documents both.

### Primary scenarios

| Scenario | Executed? | Result | Evidence | Remaining issue |
|---|---|---|---|---|
| Initial kickoff pass | Yes | **PASS** | Configured team 0; 4-4-2 taker Bennett #9 at centre, receiver Brooks #10 (CF); guaranteed pass started with non-zero velocity and receiver controlled the ball at tick 4. One kickoff award. The 4-3-3 single-striker midfielder fallback also passed. | None found. |
| Forced throw-in | Yes | **PASS** | Real ball trajectories crossed both touchlines. Top: Northbridge #2 Lewis last touch, Eastvale awarded at crossing `(500,-5)`, restart `(500,5)`, Hill #103 to Turner #108. Bottom: Eastvale #102 Young last touch, Northbridge awarded at `(500,605)`, restart `(500,595)`, Lewis #2 to Ward #8. Each executed once and reached its receiver. | None found. |
| Forced corner kick | Yes | **PASS** | Both goal lines exercised outside the goal mouth. Left: Northbridge #2 Lewis last touch, Eastvale at `(5,5)`, Baker #111 to Turner #108. Right: Eastvale #102 Young last touch, Northbridge at `(995,595)`, Gray #7 to Ward #8. Each executed once and reached its receiver. | None found. |
| Forced goal kick | Yes | **PASS** | Both goal lines exercised. Left: Eastvale #102 Young last touch, Northbridge GK Mason #1 at `(60,225)` to Carter #4. Right: Northbridge #2 Lewis last touch, Eastvale GK Parker #101 at `(940,375)` to Scott #105. Each executed once and reached its receiver. | None found. |
| Post-goal kickoff | Yes | **PASS** | Production shot/scoring path recorded “Northbridge Bennett scores!”; score became 1-0. Eastvale #109 Nelson took the centre kickoff to #108 Turner after 11 restart ticks; receiver controlled the ball at tick 20. Total kickoff awards were exactly the initial kickoff plus this goal restart. | None found. |

### Captured state hashes

The following are final authoritative hashes after the restart delivery reached its receiver. Replays matched the corresponding hash histories at every stepped tick.

| Scenario | Execution / receive tick | Final state hash |
|---|---:|---|
| Initial kickoff, 4-4-2 | receive 4 | `38d0aa587eeed760daf5f5dd5c87e99cf914d73b863c583add7412b1fb8bc830` |
| Top throw-in | execute 8 / receive 40 | `9366a96141d5af95bd54ce26f7d785605bae0a13d6a2061b81c28ba76415dc8d` |
| Bottom throw-in | execute 8 / receive 40 | `c5bfa0c3dd760417e3097e247fca585496a01dcba232356eedac5995d3641b3f` |
| Left corner | execute 8 / receive 40 | `69f8c01855ad0fe5a9fbb821cd2b45fdae8dcafe28189df32b1dac460131c18a` |
| Right corner | execute 8 / receive 40 | `b1155d99cd9e8f3e7c4e8ea2108321785b343df630102083a8668129621a3b8a` |
| Left goal kick | execute 8 / receive 9 | `b96e087f4970f4198549f3c8378dd13f9b1ff598d4dbdf6f99719ac92187d4af` |
| Right goal kick | execute 8 / receive 9 | `edc2b148a5f1d4c1a0fb8f4063738c1ce1f331d00a9220f2cecef7c6782ce61c` |
| Post-goal kickoff | execute after 11 delay ticks / receive 20 | `2bf7b50b2fc510634f2a2acc372a698efe84436cdb934c2d46e058317a7a794c` |

### Regression and execution evidence

- For the kickoff and each boundary/post-goal scenario, the dedicated script replayed identical setup twice and compared ordered events plus a state-hash history at every stepped tick. Boundary cases also verified last-touch player/team, awarded team, legal restart position, taker/receiver identity and eligibility, unchanged score, dead-ball freeze, exactly one award, in-play transition, and completed delivery.
- Pending throw-in, corner, and goal-kick snapshots were restored into a separate initialized simulation. Hashes matched at restore and throughout restart execution/delivery. A corrupted `restart_awarded_team` was rejected without mutating the receiving snapshot. The warning for this deliberately malformed snapshot is expected.
- Commands and results (all executed with the Godot console executable above):
  - `"C:\Users\USER\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe" --headless --editor --path "C:\Users\USER\Documents\Project\GMN1" --quit` — **exit 0**, 11.53 s.
  - `"C:\Users\USER\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe" --headless --path "C:\Users\USER\Documents\Project\GMN1" --script "res://scripts/tests/determinism_test.gd"` — **exit 0**, 5.38 s. Restart contracts, state/snapshot contracts, and deterministic replay passed; 129 key events and 20 state hashes matched.
  - `"C:\Users\USER\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe" --headless --path "C:\Users\USER\Documents\Project\GMN1" --script "res://scripts/tests/restart_validation_test.gd"` — **exit 0**, 9.74 s. All eight printed validations passed: initial kickoff, both throw-ins, both corners, both goal kicks, and post-goal kickoff.
  - `data/match_config.json` parse — **PASS**, snapshot version 5 and initial kickoff team 0.
  - VS Code Problems diagnostics for the simulation, network, and both test scripts — **PASS**, no errors. `git diff --check` — **PASS**.
- Production defect found: **none confirmed** in the tested scenarios. The initial failing runs were caused by assertions/cleanup errors in the pre-existing test script, not restart behavior; those test issues were corrected and the full suite then passed.
- Host/client network validation: **NOT RUN**. The snapshot peer checks are local simulations and are not represented as a real two-process network test.
- Final worktree: branch `main`, same `HEAD` SHA above, no staged changes, no commit or push. The six pre-existing modified tracked files remain; validation adds the updated test content plus the new `restart_validation_test.gd` and `restart_validation_test.gd.uid`.

**Verdict: CONDITIONAL PASS.** All five primary restart scenarios and deterministic/snapshot checks passed on Godot 4.7.2. Real host/client restart synchronization remains unproven; next step is a two-process Godot host/client test covering at least one boundary restart.

## I. Final Local Restart Acceptance Rerun

This section supersedes older branch, worktree, command-duration, and test-result statements in Section H. Restart commit `569aa04951eafdc9c20108baadf124fac159e0c9` is included in the merge commit on `main`, `099af7ce8e8a26e801f55d28856ce30a5951491a`. The local kickoff-layout changes remain uncommitted.

### Results

| Check | Result | Evidence |
|---|---|---|
| Godot editor import / project load | **PASS** | Godot `4.7.2.stable.official.ed1daf0bf`, exit 0 after kickoff-layout changes. |
| Kickoff layout, 4-3-3 | **PASS** | All 22 positions matched formation slots in each team's own half; midfield and forward bands were present. Halftime mirrored both sides and executed the second-half kickoff. |
| Kickoff layout, 4-2-3-1 | **PASS** | All 22 positions matched formation slots in each team's own half, including the double pivot, attacking midfield line, and striker. Halftime mirroring and restart passed. |
| Kickoff, two-forward formation | **PASS** | 4-4-2 pass vector `(-150, 66)`, distance `163.878px` of `300px`; receiver was a CF. Receiver controlled the ball at tick 4. |
| Kickoff, single-striker formation | **PASS** | 4-3-3 pass vector `(-290, 0)`, distance `290px` of `300px`; receiver was a CM. Receiver controlled the ball at tick 9. |
| Throw-in, top touchline | **PASS** | Crossing `(500,-5)` after Northbridge last touch; Eastvale awarded the throw at `(500,5)`. Fullback Hill (#103) delivered to Turner (#108); exactly one award. |
| Throw-in, bottom touchline | **PASS** | Crossing `(500,605)` after Eastvale last touch; Northbridge awarded the throw at `(500,595)`. Fullback Lewis (#2) delivered to Ward (#8); exactly one award. |
| Corner, left goal line | **PASS** | Defensive Northbridge last touch outside the goal mouth; Eastvale corner at `(5,5)`. Baker (#111) delivered to Turner (#108); no goal and exactly one award. |
| Corner, right goal line | **PASS** | Defensive Eastvale last touch outside the goal mouth; Northbridge corner at `(995,595)`. Gray (#7) delivered to Ward (#8); no goal and exactly one award. |
| Goal kicks, both ends | **PASS** | Correct last-touch classification and goalkeeper delivery to an eligible teammate; exactly one award per scenario. |
| Post-goal kickoff | **PASS** | Eastvale received the restart after a Northbridge goal; CM receiver controlled the ball at tick 20. |
| Deterministic replay / snapshot regression | **PASS** | Score 1-0; 132 key events and 20 state hashes matched; snapshot replay verified. |

For each restart, the test checked the production award/execution path, last-touch team/player, eligible taker and receiver, restart location, in-play transition, cleared restart references, ball movement, eventual receiver possession, and absence of a duplicate award after resumption. Pending boundary restarts were also snapshot-restored into a peer simulation and replayed with matching state hashes. The deliberately malformed snapshot produces an expected rejection warning.

Kickoff layout is applied by the production restart placement routine using the configured formation slots, `kickoff_own_half_depth_ratio`, and each side's current attack direction. The same routine runs after halftime end-switches. A single placement log records both formations, attack directions, taker, and receiver. Position-dump assertions cover 4-3-3 and 4-2-3-1 at initial kickoff and halftime.

### Commands and exit codes

Godot runtime: `4.7.2.stable.official.ed1daf0bf`, executable `C:\Users\USER\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe`.

- `... --headless --editor --path "C:\Users\USER\Documents\Project\GMN1" --quit` — **exit 0**.
- `... --headless --path "C:\Users\USER\Documents\Project\GMN1" --script "res://scripts/tests/determinism_test.gd"` — **exit 0**; 132 key events and 20 hashes matched.
- `... --headless --path "C:\Users\USER\Documents\Project\GMN1" --script "res://scripts/tests/restart_validation_test.gd"` — **exit 0**; kickoff layout checks for 4-3-3 and 4-2-3-1, halftime switch, all restart scenarios, and replay checks passed.
- `git diff --check` — **PASS**.

### Scope and final worktree

- Host/client ENet synchronization and reconnect: **NOT RUN**. The snapshot peer tests are two local simulations, not a real two-process network test.
- UI/network status after restart: **NOT RUN**. The headless acceptance test validates simulation active/finished flags and restart metadata, but does not instantiate the live UI or network session.
- Interactive playtest: **NOT RUN**; layout acceptance used production simulation position dumps headlessly.
- Branch: `main`; `HEAD` and `origin/main`: `099af7ce8e8a26e801f55d28856ce30a5951491a`.
- Local changes at time of this report update: README, simulation kickoff log, layout/restart tests, and this report.

**Verdict: LOCAL ACCEPTANCE PASS.** Restart and kickoff-layout simulation tests pass. Multiplayer/reconnect, interactive playtesting, and live UI status remain unverified.
