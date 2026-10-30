# GMN1 PVP Acceptance Report

## Result

**PVP is multiplayer-validated** for the tested two-process, same-machine setup described below. All required cases A–F passed. This result is limited to the tested Godot build, local loopback connection, and configuration; it is not a cross-platform or remote-network certification.

## Test environment

- Test date: 2026-10-30
- Branch: `main`
- Code-under-test HEAD: `502dc88e2fdfe23752cecaf3efb3c621e023fea0` (`Improve kickoff formation placement and logging`)
- `origin/main` at test time: `099af7ce8e8a26e801f55d28856ce30a5951491a`; the tested HEAD contains the local kickoff-layout commit on top of it.
- Godot: `4.7.2.stable.official.ed1daf0bf`
- Host and client: separate headless Godot processes on the same Windows machine, connected over `127.0.0.1:24560`
- Match seed: `20261029`; formation: `4-3-3`
- Harness: `scripts/tests/pvp_acceptance_peer.gd`, using the production `NetworkSession` host/join, command, restart, hash, and reconnect paths. Logs were captured separately for each process.
- Headless editor import: exit code 0
- `scripts/tests/determinism_test.gd`: exit code 0 — deterministic score 1–0, 132 key events and 20 hashes matched, snapshot replay verified.

The test exercises the production network APIs headlessly; it does not automate clicks in the graphical lobby.

## Acceptance cases

| Case | Result | Evidence |
|---|---|---|
| A — Normal lockstep | **PASS** | Both processes completed tick 3600 at 3–0; both reported `in sync`, `MATCH@3600`, sequence `2/2`, zero out-of-order commands, and zero hash mismatches. |
| B — Intermediate hash / catch-up | **PASS** | Natural tick-watermark catch-up was used (no artificial lag injection). Matching hashes were confirmed at 30-tick intervals. After reconnect, the host observed an 18-tick client catch-up; the host had matching hashes through tick 630 and the client through tick 660, with no mismatch. |
| C — Competing manager commands | **PASS** | Host and client commands were accepted and sequenced by the host: sequence 1 applied at tick 211; sequence 2 applied at tick 224. Both processes reached sequence `2/2`; no rejection loop occurred. |
| D — Disconnect and reconnect | **PASS** | Client dropped at tick 420. Host paused; reconnect restored snapshot tick 300, replayed to host tick 435, verified the reconnect hash, and resumed with one pending command. Command 1 then applied at tick 502; subsequent hashes matched. |
| E — Disconnect and forfeit | **PASS** | Client dropped at tick 60 and did not reconnect. After the configured 30-second grace period, the host ended the match with `DISCONNECT_FORFEIT: team 0 wins`. |
| F — Restart while connected | **PASS** | The live match produced goals and restarts. Host and client logs agreed on the post-goal kick-off award, taker/receiver, and live-ball transition; they also agreed on a throw-in and goal-kick restart. |

## Log excerpts

### Connection and match start

```text
[Network] Peer <peer-id> joined as Eastvale manager. Start when ready.
PVP_MATCH_STARTED|role=host|home=Attacking/Direct|away=Cautious/Counter
PVP_MATCH_STARTED|role=client|team=1
```

### Matching hash stretch and final state

```text
PVP_HASH_OK|role=host|tick=30|status=MATCH|...
PVP_HASH_OK|role=host|tick=60|status=MATCH|...
PVP_HASH_OK|role=client|tick=30|status=MATCH|...
PVP_HASH_OK|role=client|tick=60|status=MATCH|...
PVP_SUMMARY|role=host|scenario=normal|tick=3600|score=3-0|...|sync=in sync|hash=MATCH@3600|ooo=0|mismatch=0
PVP_SUMMARY|role=client|scenario=normal|tick=3600|score=3-0|...|sync=in sync|hash=MATCH@3600|ooo=0|mismatch=0
```

### Competing commands

```text
[Network] Host scheduled command provisionally: { "sequence": 1, "tick": 211, ... "kind": "mentality", "value": "Balanced", ... }
[Network] Host scheduled command provisionally: { "sequence": 2, "tick": 224, ... "kind": "game_plan", "value": "Possession", ... }
[Network] Command #1 at tick 211: applied
[Network] Command #2 at tick 224: applied
```

### Reconnect and catch-up

```text
[Network] Opponent disconnected. Match paused; reconnect within 30s.
[Network] Returning manager authenticated; sending snapshot and 1 pending commands.
[Network] Snapshot restored at tick 300; replaying to tick 435.
[Network] Opponent reconnected and verified at tick 435; match resumed.
[Network] Command #1 at tick 502: applied
PVP_SUMMARY|role=client|scenario=reconnect|...|sync=in sync|hash=MATCH@660|seq=1/1|ooo=0|mismatch=0
```

### Connected restart and forfeit

```text
[Match] Northbridge Bennett scores! (on target 0.693; keeper save 0.695)
[Restart] kick-off awarded to Eastvale ... taker Nelson (#109), receiver Turner (#108).
[Restart] kick-off taken by Nelson (#109) for Turner (#108); the ball is live.
[Restart] throw-in awarded to Eastvale ... last touch: Northbridge, Ward (#8); taker Young (#102), receiver Turner (#108).
PVP_SUMMARY|role=host|scenario=forfeit|winner=0|...|sync=opponent forfeited|event=DISCONNECT_FORFEIT: team 0 wins
```

## Configuration used

Values read from `data/match_config.json`:

- `network.default_port`: `24560`
- `network.reconnect_timeout_seconds`: `30.0`
- `network.state_hash_interval_ticks`: `30`
- `network.tick_beacon_interval`: `15`
- `network.snapshot_interval_ticks`: `300`
- `network.command_lead_ticks`: `180`
- `match.tick_seconds`: `0.1`
- `match.half_duration_seconds`: `180`
- `seed`: `20261029`

## Scope and remaining limitations

- Reconnect was tested while the client process remained alive. Recovery after fully terminating and relaunching the client process remains unsupported and was not tested.
- The test used localhost; remote Internet, firewall/NAT traversal, packet loss, and cross-platform bit-identical behavior were not tested.
- Optional stress case G (packet loss or rapid command spam) was not run.
- GUI rendering and button interaction were not exercised; the headless harness called the production networking APIs.
- The reconnect run showed a transient client watermark lag while active; it caught up and subsequent hashes matched. No desynchronization or hash mismatch was observed.

## Reproduction

Run two separate Godot console processes using the same project path and port. Use the same scenario argument in each process:

```text
Godot_v4.7.2-stable_win64_console.exe --headless --path <GMN1-project-path> --script res://scripts/tests/pvp_acceptance_peer.gd -- host 24560 normal
Godot_v4.7.2-stable_win64_console.exe --headless --path <GMN1-project-path> --script res://scripts/tests/pvp_acceptance_peer.gd -- client 24560 normal
```

Repeat with `reconnect` and `forfeit` in place of `normal` for cases D and E.
