# GMN1

A deterministic 2D PVP football (soccer) autobattler where both players act as managers. Built with Godot 4, featuring mathematical probability models, professional formations, collective team play, live tactical commands, and lockstep networking.

GMN1 is an early playable prototype focused on its simulation and networking core. Visuals are intentionally simple, and networking currently targets direct two-player sessions rather than matchmaking.

## Features

- Deterministic fixed-step simulation with seeded randomness and replay testing.
- Nine professional formation templates with tactical roles and halftime direction changes.
- Attribute-weighted probability resolution for passes, tackles, shots, goalkeeper saves, and rebounds.
- Form, fatigue, stamina, substitutions, and temporary tactical instructions.
- Combination-oriented passing, support shapes, selective tackling, and tactical AI.
- Local play against AI and two-manager PVP over ENet lockstep.
- Host-sequenced manager commands, state hashes, sync diagnostics, and reconnect snapshots.
- Authoritative hashes exclude peer-local player selection and debug presentation state.
- Provisional command scheduling with deterministic execution-time outcomes and stable substitution player IDs.
- Data-driven match, formation, probability, and networking configuration in `data/match_config.json`.

## Run a match

1. Install Godot **4.7 or newer** (recommended). The project uses the **Compatibility** renderer.
2. Open `project.godot` in Godot and press **F6** (or run the project with **F5**).
3. For single-player, choose **Local vs AI**, select a formation, set tactics, and click **Start match**.
4. For PVP, one manager clicks **Host PVP**. The other enters the host's address (use `127.0.0.1` for two instances on the same computer) and clicks **Join PVP**. Once the lobby shows the opponent connected, each manager can set their own starting tactics; the host selects the formation and clicks **Start match**. The default port is UDP `24560` (`network.default_port`); allow that port through the host firewall/router for remote play.
5. Mentality and game-plan changes share the tactical cooldown. Substitutions and instructions spend tactical points; points regenerate over match time. Instructions expire automatically and can also be toggled off early. The default simulation runs at 30 match-seconds per real second, so both three-minute halves take about 12 real seconds. Set `simulation_seconds_per_real_second` to `1.0` in the match data for a six-real-minute match.

### Controls

- **T**: switch managed side in local play.
- **1 / 2 / 3**: Cautious / Balanced / Attacking mentality.
- **Q / W / E**: Possession / Direct / Counter game plan.
- **Tab**: cycle the selected player on the managed team.
- **U**: substitute the selected player with the best available bench match.
- **Z / X / C / V / B / N**: push full-backs, drop compact, target left/right channel, press #6, and play long balls.
- **F1**: toggle the debug panel.

## Simulation and probability

The simulation advances in fixed 0.1-second match-time steps. The RNG is seeded from `data/match_config.json`; resetting the match with the same seed, formation, and manager commands reproduces the same outcomes. Resolved actions and their probability formula are also printed to the Godot output panel.

## Formations and collective play

The formation selector is populated from `formations` in `data/match_config.json`. Available shapes are **4-4-2**, **4-2-3-1**, **4-3-3**, **4-3-3 (Holding)**, **4-3-3 (Attacking)**, **4-3-3 (False 9)**, **4-1-4-1**, **3-5-2**, and **5-3-2**. Every shape has eleven role-labelled slots with normalized `x`/`y` coordinates; `x` is the team's attacking direction and is mirrored at halftime. Players retain their natural roster role while a separate tactical role maps them into the selected shape.

Before kickoff and at halftime, a dedicated lineup placement maps each formation's normalized attacking-axis `x` coordinates into the team's own half (`match.kickoff_own_half_depth_ratio`, default `0.5`) while retaining the template's full-pitch `y` spacing. The away team is mirrored according to its attacking direction. The configured kickoff team places a striker/centre-forward at the centre spot and immediately passes to a second forward, or a central midfielder when there is only one forward. Kickoff, halftime, and post-goal restarts share the same guaranteed pass delivery; the ball visibly travels to its receiver.

The simulation tracks the last player and team to touch the ball. Passes and restart deliveries retain the passer as last touch until the receiver controls the ball. Ball-flight segments are checked against the pitch boundary after each movement step, using the ball radius so an exit is not called until the whole ball has crossed. Touchline exits award a throw-in to the other team; goal-line exits award a corner when the defending team touched last, otherwise a goal kick. Throw-ins prefer the nearest eligible LB/RB/LWB/RWB; when a formation has none, the nearest outfield player is used and the fallback is logged. Goal kicks prefer the goalkeeper. Goals keep the existing shot/scoring model and initiate exactly one kickoff for the conceding team.

Dead-ball restarts freeze player movement and ordinary action decisions while the configured delay runs. Match time continues during this short pause; the delay changes presentation timing only, not restart ownership, selection, or delivery. Saved shots have a configurable chance to be deflected out for a corner; other saves keep the existing rebound/keeper-possession flow.

Possession build-up scores each teammate as a weighted combination of nearby distance, space from the nearest defender, diagonal support angle, and forward progress. Possession play prioritizes close options and safer roles; Direct/Counter plans and the long-ball instruction raise the value of forward progression and reduce the short-pass preference. Off-ball support players move toward four configured forward/side support offsets around the carrier, creating triangle and diamond options while blending back toward their formation slot. Possession teams normally complete two passes before shooting; a sufficiently advanced, unmarked clear chance can bypass that gate. Direct and Counter play bypass the build-up gate.

Pass success continues to use the existing weighted-attribute sigmoid and contextual probability modifiers; these changes affect candidate selection and build-up timing, not the probability engine. The debug overlay shows each team's build-up/direct mode and completed passes in the current possession, plus the preferred pass target, distance, openness, support-angle score, tactical-role profile, and selection score.

Shot on-target probability uses the same weighted-attribute sigmoid as other actions. The context reports base, distance, angle, pressure, central-zone, preferred-zone, penalty-area, and tactical contributions; every resolved shot also logs shooter pitch x and `inside_box`. The former `-1.05` base plus `0.0045`-per-pixel distance penalty was the dominant cause of very negative contexts; these are now `-0.45` and `0.0020`. Shot selection now requires a sufficiently good box/edge chance, or a very advanced, open, good-angle attempt outside the box (with stricter limits for non-direct play). Before two completed passes, a box/line chance bypasses the build-up rule only when its angle is acceptable and the nearest defender is at least the configured minimum unmarked distance away. Edge/outside attempts still require the completed passes. Declined attempts log a concise reason. Gate thresholds live in `decision.shot_selection`; probability context settings remain under `probability` in `data/match_config.json`.

With possession and the ball beyond `match.box_runs.trigger_ball_attack_x`, the striker and nearest wide attacker/CAM receive temporary targets inside the box. Runs target `target_depth_from_goal` from goal, preserve a wide runner's lane, and log their start plus progress every five ticks by default. Players advance toward the target using the normal `move_toward` movement step; box-run carriers use the carry-speed step once, avoiding a second movement step in the same tick. A box-run player can shoot from their live position anywhere inside the penalty area or within the configured shot-selection edge margin; reaching the target itself is not required. Shot coordinates and context always use the player's current position, never the tactical target, and eligibility logs whether the run completed or was waived because the player already entered the box/edge. A teammate who is beyond attack progress `0.75`, inside the box, within 45 pixels of the run target, and at least 50 pixels from the nearest defender receives a +180 pass-selection bonus. After a shot, lost possession, or restart, active run targets are cleared so players return toward formation/support positions. A shot cooldown remains active until a teammate completes a pass, the opposition holds possession for the configured 10 ticks, a restart occurs, or another player claims the rebound. Possession shots can be considered from the box edge and from attack progress `0.80` onward if the configured angle and space checks pass; Direct/Counter retain their earlier-shot threshold. Declines include the distance to the penalty-area boundary. Before the normal two-pass build-up requirement is met, an acceptable-angle chance with the configured minimum unmarked distance inside the box or exactly on its line is allowed and logged as `open box chance, build-up waived`; edge/outside attempts still require the completed passes.

### Containing and sustained possession

The nearest defender now passes a deterministic, seeded decision gate before any tackle probability is calculated. The goalside test is relative to the carrier's attacking direction; distance, angle, whether the carrier faces the defender, forward carry commitment, stamina/fatigue, tactical mentality/game plan, and defensive role affect tackle intent. A defender delays when the carrier has a safe outlet and is not committed; compact instructions also reduce tackle intent. Poor angles or condition trigger a jockey cooldown; a missed tackle triggers a longer recovery cooldown. Cautious/Possession settings favor containing, while Attacking/Counter settings raise tackle intent. The tackle success sigmoid and its attribute weights are unchanged.

Under pressure, nearby options gain value, forward progression and backward-pass penalties are discounted, and open sideways/back outlets receive a bonus. Short passes earn an increasing, capped continuation bonus once a combination has started. The nearest open support players receive stronger positioning and movement priority toward the carrier. Console output reports contain/jockey reasons and successful sequence counts, for example:

```text
[Defence] Lewis jockeys/contains vs Bennett: angle: not goalside (cos -0.12); force the safe outlet and delay.
[Possession] Northbridge combination pass 1 completed (sequence length 1).
[Possession] Northbridge combination pass 2 completed (sequence length 2).
[Possession] Northbridge sequence ended after 2 completed passes (shot).
```

Tuning is in `match.tackle_decision` in `data/match_config.json`: tackle/jockey ranges, angle and condition thresholds, attempt-rate modifiers by mentality/game plan/role, cooldown durations, pressure-pass weights, and pressure-support strength. Per-player carry distance and tackle cooldown are serialized and included in state hashes/snapshots; the snapshot schema version is 3.

## PVP networking and reconnect

PVP uses host-sequenced deterministic command lockstep over Godot ENet. Both peers run the same simulation from the same seed and config. The host validates commands, assigns sequence numbers and future ticks, then reliably broadcasts them. The 180-tick lead is about 0.6 real seconds at default speed; tune `network.command_lead_ticks` for the delay/latency trade-off. Networking remains outside `scripts/simulation/`.

The simulation hashes canonical JSON of dynamic match state with SHA-256 every `network.state_hash_interval_ticks`. Included state covers score, ball position/velocity/owner/target, RNG state, match clocks, full player/bench attributes and condition/positions, and team tactics, instructions, resources, and substitutions. Floats are rounded to four decimal places before hashing. The debug overlay shows hash status/tick and out-of-order count; a mismatch is logged and halts the match on both peers. Tick beacons gate client simulation progress.

The host caches full state every `network.snapshot_interval_ticks`. A joining client gets a reconnect token in its lobby handshake. If it disconnects, the host pauses and waits for `network.reconnect_timeout_seconds`; in the still-running client window, use the same address and press **Reconnect** before that grace period expires. The host sends the last snapshot, pending scheduled commands, subsequent committed commands, and its current tick/hash. The client restores the snapshot, deterministically replays to the host's paused tick, then proves its state hash before the host resumes. Use **Drop link (test)** in the client window to test this flow. The join address and reconnect token only exist in memory, so restarting the client process cannot resume a match. If reconnection times out, the connected manager wins by forfeit.

### Two-instance test

1. Run the project in Godot (F6/F5), then launch a second instance from a terminal with `godot --path .`.
2. In the first window click **Host PVP**. In the second, enter `127.0.0.1` and click **Join PVP**.
3. Confirm each window reports the assigned manager/ready status, then have the host start.
4. To test reconnect, click **Drop link (test)** in the joining window during the match, then click **Reconnect**. The overlay should show snapshot replay followed by `MATCH (reconnect)`.

For LAN play use the host's private IP. Internet play may require UDP port forwarding. One joining manager is supported; late join, matchmaking, authentication, malicious-host protection, and process-restart recovery are out of scope.

The PVP line in the debug overlay includes role, local/host tick, ping, received sequence, last applied command, sync state, hash result, last hash tick, and out-of-order count. The other lines show both teams' tactical points, substitutions remaining, and instructions. Command acceptance/rejection/application is reported on screen and in the Godot output.

For passes, shot quality, tackles, goalkeeper saves, and rebounds, the engine computes a weighted average of relevant player attributes (each attribute is on a 0–100 scale and normalized to 0–1). It then evaluates:

`p = clamp(sigmoid((weighted_skill - 0.50) * slope + context + form * form_weight - fatigue_penalty), minimum_probability, maximum_probability)`

where `sigmoid(x) = 1 / (1 + exp(-x))`. Context includes tactical modifiers and action-specific range or pressure. Fatigue incurs a smooth penalty and an extra penalty at the configured breakpoint; form is a small additive modifier. Each action performs one seeded RNG draw against `p`. The debug panel shows the last action, its probability, and the active formula/weights.

Ground passes use passing, vision, and technique; shot quality uses finishing, technique, composure, and strength; tackles use tackling, pace, strength, and composure. A shot is resolved as:

1. Shot-quality probability determines whether the effort is on target.
2. On-target efforts use goalkeeper diving, handling, positioning, reflexes, and composure against shot power, placement, distance, pressure, form/fatigue, and keeper tactics to determine a save.
3. A saved shot resolves a rebound probability from the nearest attacking support player's finishing, pace, composure, and technique; a won rebound keeps possession, otherwise the goalkeeper holds the ball.

A successful pass travels under simple velocity and linear drag until it reaches its intended teammate. The overlay displays the latest on-target, goalkeeper-save, and rebound probabilities.

The shot stages use the shared sigmoid with configured weights and fatigue/form adjustments:

- `p_on_target = sigmoid((weighted_shooting - 0.50) * sigmoid_slope + shot_zone + tactics - nearby_pressure + form - fatigue)`
- `p_save = sigmoid((weighted_goalkeeping - 0.50) * goalkeeper_save_slope + distance_bonus - shot_power_penalty - placement_penalty + pressure_bonus + keeper_tactics + form - fatigue)`
- `p_rebound = clamp(sigmoid((weighted_rebound_skill - 0.50) * rebound_slope + rebound_context + form - fatigue), rebound_min, rebound_max)`

Shot power and placement are weighted skill values from the shooter. The keeper attributes are diving, handling, positioning, reflexes, and composure. Rebound context includes a save bonus and a nearby-support bonus.

## Data-driven tuning

All current roster templates, formations, match timing, pitch dimensions, physics values, action intervals, tactical cooldown, condition rates, probability weights/modifiers, probability bounds, and breakpoints are in **`data/match_config.json`**. Specifically, the data contains:

- `seed`; `field` dimensions, markings, player/ball sizes.
- `match` half length, fixed timestep, simulation speed, decision interval, cooldown, ball drag/spin/speeds, player/carry movement, pass arrival, goal reset, and condition rates.
- `probability` sigmoid slope, form/fatigue modifiers and breakpoint penalty, distance/pressure context scales, shot-zone modifiers, action attribute weights, mentality/game-plan modifiers, and probability clamps.
- `probability.instructions` instruction movement/risk/pressure modifiers; `probability.movement` mentality, plan, possession and support positioning; `probability.ai` opponent reaction thresholds.
- `probability.manager_tools.substitution_selection` reserve ranking weights; `probability.shot_power_attribute_weights` and `shot_placement_attribute_weights` control the shot/keeper context.
- `probability.movement.support_shape_blend` and `support_offsets` tune off-ball triangle/diamond support.
- `match` kickoff teams, restart delay/goal-area geometry/saved-shot corner chance, substitution limit/cost, instruction cost/slots/cooldown, tactical-point pool/regeneration, halftime restart side, and substitution form/fatigue inheritance.
- `thresholds` fatigue/shot-zone/rebound/instruction breakpoints; `decision` shot selection and pass-target scoring.
- `determinism_test` short test half-duration and command tick schedule.
- `network` UDP port, command lead, tick-beacon/hash/snapshot intervals, snapshot version, maximum pending commands, reconnect enable/grace period, ping interval, and client catch-up limit.
- `decision.pass_selection` nearby/open-space/support-angle/progression weights, role profiles, long-range penalties, clear-chance thresholds, and minimum short-pass buildup.
- `formations` positions; `player_templates` attributes; `teams` names, colors, rosters, and starting formations.

Player/team state classes live in `scripts/data/`; match logic plus deterministic state serialization/hashing are in `scripts/simulation/`; ENet, lobby, snapshot transport, and reconnect logic are in `scripts/network/`; manager-command routing is in `scripts/managers/`; and the 2D pitch, HUD, and debug overlay are in `scripts/ui/`.

```text
data/match_config.json
scenes/main.tscn
scripts/data/player.gd
scripts/data/team.gd
scripts/managers/manager_controller.gd
scripts/network/network_session.gd
scripts/simulation/match_simulation.gd
scripts/ui/main_view.gd
scripts/tests/determinism_test.gd
project.godot
README.md
```

The match-data JSON intentionally contains numeric tuning values and sample rosters, including five substitutes per team. The home manager selects the home formation before kick-off; the away side uses its configured formation. At halftime both teams switch attack direction; form and fatigue continue across the break.

## Determinism test

Run `godot --headless --path . --script res://scripts/tests/determinism_test.gd`. The test checks kickoff role selection and delivery, halftime direction and kickoff ownership, fast ball-boundary crossings, last-touch throw-in/corner/goal-kick decisions, goal/miss/save restart outcomes, dead-ball freezing, restart snapshot round-trips and malformed metadata rejection, selection/hash isolation, stable and stale substitution identities, conflicting tactical commands, and replay determinism. It does not open a network connection.

## PVP command and reconnect behavior

The host validates each command when it is received, assigns its sequence and target tick (`current host tick + network.command_lead_ticks + 1`), then schedules it **provisionally**. It may still be rejected at execution if an earlier scheduled command used a cooldown, tactical points, instruction slot, or substitution capacity first. Every peer applies commands in sequence at the same target tick, records `COMMAND_APPLIED` or `COMMAND_REJECTED` in the match event log, and reports the final local status. The host acknowledgement means “scheduled provisionally,” not “guaranteed to execute.” The host ignores the client-reported tick.

Substitution commands carry the stable outgoing player ID, not a roster index, so later roster changes cannot redirect an already-scheduled request. Pending commands are bounded by `network.maximum_pending_commands`. A sequence gap, late commit, conflicting duplicate hash/beacon, or detected tick/sequence mismatch stops simulation rather than continuing with potentially divergent state.

The authoritative hash includes gameplay state, RNG state, clocks, team tactics/resources, roster/player state, ball and last-touch state, pending restart kind/team/location/taker/receiver, and match phase. It excludes `selected_player_index` (local inspection/input preference), `event_log` and last-action/probability/debug strings (observability only), and `home_formation` (redundant UI setup label; the active formations are hashed per team). Snapshot restore preserves the receiver's local selection. Snapshot schema version is `network.snapshot_version` (currently 5); the protocol digest uses marker `gmn1-lockstep-3`, so older incompatible builds/configurations do not join.

Reconnect snapshots carry the highest sequence already applied at their tick. The replay stream contains each later committed command exactly once, including commands still scheduled in the future. The client verifies sequence continuity, target ticks, the applied sequence and final state hash before the host resumes. An invalid stream stops the session; reconnect is not treated as proven until tested between separate live Godot processes.

Determinism is intended for replay and lockstep peers using the same project/configuration and compatible Godot build. Cross-platform or cross-version bit-identical behavior has not been established.

## Current assumptions and scope

- The default opponent AI manages the away side in local play. PVP disables that AI on both peers.
- Substitutions preserve the outgoing player's role/position while the incoming player inherits a configured share of form/fatigue.
- Instructions are team-wide, time-limited, and limited to configured active slots; pressing the same key cancels an instruction.
- Player movement is formation-position seeking with tactical offsets, not pathfinding or collision avoidance.

## Suggested M5 focus

- Run repeated two-instance LAN tests and add automated reconnect/disconnect integration coverage.
- Consider additional game modes and balance after lockstep reliability is established.
- Add presentation polish and match-history/replay UX before ranked play or accounts.
