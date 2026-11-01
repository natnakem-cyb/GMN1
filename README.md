# GMN1

A deterministic PVP football (soccer) autobattler where both players act as managers. Built with Godot 4, featuring mathematical probability models, professional formations, collective team play, live tactical commands, and lockstep networking.

GMN1 is an early playable prototype focused on its simulation and networking core. The match presentation uses a procedural 3D stadium, pitch, goals, and physical football with 2D tactical player markers; networking currently targets direct two-player sessions rather than matchmaking.

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

### Metric 3D ball simulation

The authoritative ball is a deterministic fixed-step 3D simulation in metres: `X` is pitch length, `Z` is pitch width, and `Y` is height. Its state includes position, linear and angular velocity, quaternion orientation, physical radius and mass, and ground contact. The canonical pitch is 105 m × 68 m; the ball radius is 0.11 m and mass is 0.43 kg; goal dimensions are 7.32 m × 2.44 m. The 1,000 × 647.62 simulation-pixel field is a uniform 0.105 m/px projection, not an independent physics scale. Its 3D viewport uniformly fits the pitch into the available display area.

Gravity, air drag, rolling resistance, spin damping, ground/frame/player material restitution and friction, collision substep distance, and kick profiles (ground pass, lofted pass, cross, driven shot, and high shot) are calibrated in metres, seconds, or dimensionless coefficients under `match.ball_flight`. Outfield player decisions remain planar; ball collisions sweep the sphere against deterministic player-height collision volumes, and keeper interactions use the same metric world. Posts, crossbar, and whole-ball goal/out-of-play tests also use metric geometry. The custom integrator remains authoritative; no engine rigid-body solver participates in match state.

### 3D match presentation

The view renders the metric pitch on a 3D ground plane inside a procedural stadium bowl with simplified stepped seating and a roof canopy. The elevated orthographic camera fits the complete pitch to about 84% of the available viewport width, refits on window changes, and leaves the stadium as a subdued frame around play. Player markers remain camera-facing 2D team circles with contrasting borders and shirt numbers; they target 42 px at a 600 px pitch-view height, render above the ground surface, and scale with the viewport. Optional player names show only for the selected player when nearby markers leave enough room. The football is a textured, shaded, rotating 3D sphere with a height-responsive ground shadow that fades and expands as the ball rises. Its view-only diameter targets 16 px at the reference view size. During possession, the sphere moves to the carrier's leading screen-space perimeter using the carrier's last movement direction or attack direction; its shadow remains at the authoritative ball location. The authoritative collision radius remains 0.11 m and is not enlarged. Stadium, marker and ball display dimensions, carrier offset, reference viewport size, name-label toggle, camera, line, net, and goal-display settings live under `view.pitch3d` in `data/match_config.json`; none affect deterministic match state. After a goal, the renderer holds the ball at the simulation's goal-volume event position briefly before showing the kickoff reset; this is presentation-only.

## Formations and collective play

The formation selector is populated from `formations` in `data/match_config.json`. Available shapes are **4-4-2**, **4-2-3-1**, **4-3-3**, **4-3-3 (Holding)**, **4-3-3 (Attacking)**, **4-3-3 (False 9)**, **4-1-4-1**, **3-5-2**, and **5-3-2**. Every shape has eleven role-labelled slots with normalized `x`/`y` coordinates; `x` is the team's attacking direction and is mirrored at halftime. Players retain their natural roster role while a separate tactical role maps them into the selected shape.

Before kickoff and at halftime, a dedicated lineup placement maps each formation's normalized attacking-axis `x` coordinates into the team's own half (`match.kickoff_own_half_depth_ratio`, default `0.5`) while retaining the template's full-pitch `y` spacing. The away team is mirrored according to its attacking direction. The configured kickoff team places a striker/centre-forward at the centre spot and immediately passes to a second forward, or a central midfielder when there is only one forward. Each kickoff logs both formations, their attack directions, and the selected taker/receiver. Kickoff, halftime, and post-goal restarts share the same guaranteed pass delivery; the ball visibly travels to its receiver.

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

Tuning is in `match.tackle_decision` in `data/match_config.json`: tackle/jockey ranges, angle and condition thresholds, attempt-rate modifiers by mentality/game plan/role, cooldown durations, pressure-pass weights, and pressure-support strength. Per-player carry distance and tackle cooldown are serialized and included in state hashes/snapshots; the overall snapshot schema is version 6.

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

Pass accuracy, shot accuracy, tackles, and goalkeeper saves use weighted player attributes (each attribute is on a 0–100 scale and normalized to 0–1), evaluated with the shared sigmoid probability model:

`p = clamp(sigmoid((weighted_skill - 0.50) * slope + context + form * form_weight - fatigue_penalty), minimum_probability, maximum_probability)`

where `sigmoid(x) = 1 / (1 + exp(-x))`. Context includes tactical modifiers and action-specific range or pressure. Fatigue incurs a smooth penalty and an extra penalty at the configured breakpoint; form is a small additive modifier. The debug panel shows the last resolved probability and formula.

Ground passes use passing, vision, and technique. Their probability is evaluated at the receiver after physical flight; low passes can also be intercepted by an opposing player inside the configured proximity radius. Shot accuracy uses finishing, technique, composure, and strength to select an in-mouth or wide aim point. Keeper saves use diving, handling, positioning, reflexes, and composure when the flight enters the keeper's reach. A successful save redirects the ball, which remains live for recovery; rebounds are no longer resolved by a second instant probability roll.

The shot and keeper models retain their configured attribute weights and fatigue/form adjustments. Ball flight, contact, goal, and restart events are logged at launch or when they occur, without per-tick log spam.
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
- `match.ball_flight` pitch-derived scale, FIFA-like goal size, ball/frame radii, gravity, air/ground drag, restitution, shot speeds, keeper interaction bounds, and flight sleep threshold; `view.pitch3d` controls the fixed camera and visible net/markings.
- `decision` contains the unordered pair-pass limit and six-yard dimensions; `decision.pass_selection` contains nearby/open-space/support-angle/progression weights, role profiles, midfield forward-search range/marking threshold/bonus, long-range penalties, clear-chance thresholds, and minimum short-pass buildup. `decision.shot_selection.box_edge_margin_px` is the shared inclusive box-edge threshold.
- `decision.pass_selection.role_zone_pass_weights` scales the existing progression term, forward-receiver bonus, and proximity term for safe forward targets inside the existing box-edge band by carrier role family and normalized DEF/MID/ATT band. The progression multipliers apply to the existing `possession_progression_weight` (24) and role-profile factor; receiver multipliers apply to the existing `midfield_forward_receiver_bonus` (60) and only reward forward, in-range candidates with the existing minimum-open-distance condition. The box-edge multiplier scales the existing `nearby_weight` (100) only for forward ST/CF/W candidates within the configured pass range and minimum-open-distance safety threshold; geometry uses the existing inclusive shot-box-edge helper. For example, a midfield carrier in MID uses 1.25× progression and 1.25× central-forward / 1.0× wide receiver bonus (75/60 points); in ATT it uses 1.5× progression, 1.5× / 1.25× receiver bonus (90/75 points), and 1.25× nearby weight in the ≤30px edge band. No candidate is forced or filtered by these Slice 2 weights.
- `formations` positions; `player_templates` attributes; `teams` names, colors, rosters, and starting formations.

Player/team state classes live in `scripts/data/`; match logic plus deterministic state serialization/hashing are in `scripts/simulation/`; ENet, lobby, snapshot transport, and reconnect logic are in `scripts/network/`; manager-command routing is in `scripts/managers/`; and the 3D pitch, HUD, and debug overlay are in `scripts/ui/`.

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
scripts/tests/ball_flight_test.gd
scripts/tests/physical_ball_test.gd
scripts/tests/restart_validation_test.gd
project.godot
README.md
```

The match-data JSON intentionally contains numeric tuning values and sample rosters, including five substitutes per team. The home manager selects the home formation before kick-off; the away side uses its configured formation. At halftime both teams switch attack direction; form and fatigue continue across the break.

## Determinism test

Run `godot --headless --path . --script res://scripts/tests/ball_flight_test.gd`, `godot --headless --path . --script res://scripts/tests/determinism_test.gd`, and `godot --headless --path . --script res://scripts/tests/restart_validation_test.gd`. These cover ball-flight and collision behavior, both mirrored inclusive box-edge boundaries, six-yard shot priority, pass-pair repetition limits, progressive-pass classification and telemetry, deterministic hashes, and kickoff/restart/snapshot behavior. `ball_observability_test.gd` remains stale against the current simulation/view API and is tracked separately in issue #12; it is not part of this verification gate. `physical_ball_test.gd` is also currently stale against the config schema (`pitch_width_m`) and was not part of this P1 gate. These local tests do not open a network connection. For a two-process loopback acceptance run, start `pvp_acceptance_peer.gd host 24560 normal` and `pvp_acceptance_peer.gd client 24560 normal` in separate Godot processes using `--` before each role's arguments; both peers verify the matching full-time state hash.

## Football selection and match telemetry

Completed unordered player pairs are limited to three passes per possession; the pair count resets on a turnover, restart, or full time. In the middle third, midfield carriers prefer viable forward receivers (ST/CF/wing roles) within the configured range and marking threshold. ST, CF, and winger roles can prioritize shots when inside the six-yard area or the shared inclusive penalty-box edge. The six-yard rectangle is 50 px deep by 136.31 px wide and is validated to remain strictly inside the configured penalty area.

Receiver scoring keeps its baseline terms in `decision.pass_selection`: nearby distance (100), defender openness (32 over 150 px), support angle (28), possession/direct progression (24/72), backward-pass penalty (18), and role-profile factors. `role_zone_pass_weights` is retained as role-by-zone configuration, but progression, recycle, and box-edge proximity multipliers are neutral (1.0) throughout. The +60 forward-receiver bonus retains the reviewed midfield-in-MID context only: `midfield.MID` uses 1.25 for ST/CF and 1.0 for wide roles; all other receiver-bonus cells are 0.0. The additional midfield-receiver bonus is 0.0 throughout. Thus no new zone progression, box-edge preference, or recycle-discount behavior is active; the existing midfield-forward preference and Slice 1 shot priorities remain.

Completed open-play passes log `[Pass] progressive=true|false`. A pass is progressive when, at launch, it starts in the attacking two-thirds and the receiver is at most 75% of the passer's Euclidean distance from the opponent goal center. Completions use that saved launch geometry rather than players' later moving positions. Progressive share is progressive completions divided by completed open-play passes originating in the attacking two-thirds. Pass attempt/completion totals also include restart deliveries; restart deliveries are excluded from open-play selection and progression metrics. At full time, the headless console prints per-team and total pass, progressive, shot, goal, and selection-intervention telemetry; `MatchSimulation.get_match_telemetry()` also returns the same report to callers.
The detail telemetry also includes progressive attempts/completions by originating role, MID-to-ST attempts/completions, forward/lateral/backward attempts and completions by band, penalty-area/edge/six-yard receptions, shots by zone, and turnovers.

## PVP command and reconnect behavior

The host validates each command when it is received, assigns its sequence and target tick (`current host tick + network.command_lead_ticks + 1`), then schedules it **provisionally**. It may still be rejected at execution if an earlier scheduled command used a cooldown, tactical points, instruction slot, or substitution capacity first. Every peer applies commands in sequence at the same target tick, records `COMMAND_APPLIED` or `COMMAND_REJECTED` in the match event log, and reports the final local status. The host acknowledgement means “scheduled provisionally,” not “guaranteed to execute.” The host ignores the client-reported tick.

Substitution commands carry the stable outgoing player ID, not a roster index, so later roster changes cannot redirect an already-scheduled request. Pending commands are bounded by `network.maximum_pending_commands`. A sequence gap, late commit, conflicting duplicate hash/beacon, or detected tick/sequence mismatch stops simulation rather than continuing with potentially divergent state.

The authoritative hash includes gameplay state, RNG state, clocks, team tactics/resources, roster/player state including movement velocity used for receiver prediction, metric 3D ball position/linear and angular velocity/orientation/contact state, kicker-clearance state, pair-pass state and match telemetry, restart and pass-launch telemetry, last-touch state, pending restart kind/team/location/taker/receiver, and match phase. It excludes `selected_player_index` (local inspection/input preference), `event_log` and last-action/probability/debug strings (observability only), and `home_formation` (redundant UI setup label; the active formations are hashed per team). Snapshot restore preserves the receiver's local selection. Snapshot schema version is `network.snapshot_version` (currently 8); the protocol digest uses marker `gmn1-lockstep-5`, so older incompatible builds/configurations do not join.

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
