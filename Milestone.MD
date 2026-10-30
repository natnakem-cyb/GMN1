# GMN1 Milestone Audit

- **Audit date:** 2026-10-30
- **Repository:** `natnakem-cyb/GMN1`
- **Current branch / code under test:** `main` / `6e89af379e5a845987d573996079329649f0e81f`
- **Remote status at audit:** the kickoff-layout and PVP acceptance commits are local and not yet pushed; this audit update is also pending.
**Overall assessment:** A strong deterministic prototype with a broad tactical and restart feature set. Core simulation, replay, and same-machine two-process PVP/reconnect acceptance pass. Remote networking, interactive GUI acceptance, and quantitative realism calibration remain open.

## Milestone status

| Milestone / workstream | Status | Evidence and remaining gap |
|---|---|---|
| **M1 — playable 2D simulation core** | **Implemented** | Godot 4/GDScript, fixed-step seeded simulation, simple 2D pitch/player presentation, formation data, manager controls, probability formulas, and debug output. The original slice is now a broader prototype. |
| **M2 — tactical simulation** | **Implemented; behavioral calibration remains** | Shot selection, form/fatigue, substitutions, temporary instructions, AI, possession support, box runs, and shot cooldowns are present. Possession length and tactical realism have not been established through a multi-seed benchmark. |
| **M3 — PVP lockstep and reconnect** | **Implemented; localhost acceptance passed** | Separate headless Godot host/client processes passed normal lockstep, hash/catch-up, competing commands, reconnect, forfeit, and connected-restart cases. This does not certify remote networking, GUI behavior, or cross-platform determinism. |
| **Correctness remediation** | **Locally and localhost-network tested** | Snapshot validation, stable substitution IDs, applied-sequence tracking, provisional command acknowledgements, reconnect snapshot/catch-up, and disconnect forfeit passed the recorded local tests. Broader network conditions remain unverified. |
| **Restart lifecycle** | **Local acceptance passed** | Kickoff/backward pass, touchline throw-ins, corners, goal kicks, last-touch decisions, post-goal kickoff, restart delivery, and resumption passed headless production-path tests. |
| **Kickoff formation layout** | **Implemented and headlessly tested** | 4-3-3 and 4-2-3-1 position dumps verify both teams, mirrored directions, and halftime placement. Interactive visual playtesting has not been recorded. The latest implementation commit is local-only. |
| **Football-realism benchmark** | **Proposal; not executed** | Specifications were reviewed, but structured telemetry, reproducible multi-seed measurements, confidence-interval decisions, and benchmark results are not established. |
| **Ball height / physical shot flight** | **Not implemented** | Current shots resolve immediately through probability stages; no authoritative multi-tick trajectory, ball height, swept player/frame collision, or physical rebound flight exists. The reviewed specifications and candidate parameter addendum are proposals only. |

## Historical timeline

Dates and commit references below are from local Git history. Technical work not represented by a separate committed feature is described by workstream rather than assigned a commit.

| Date and time | Event |
|---|---|
| **2026-10-29 14:07 (+03:00)** | `d0afcf1` — initialized the playable GMN1 prototype. This is the repository's recorded starting point for the current project history. |
| **2026-10-29 15:55 (+03:00)** | `2cb3c47` — improved shot selection and kickoff formation behavior. |
| **2026-10-29 17:30 (+03:00)** | `e4610f3` — fixed box-run movement and shot cooldown behavior. Subsequent local work refined shot gating and box-run acceptance. |
| **2026-10-29 18:44 (+03:00)** | `7fa0709` — hardened deterministic lockstep and reconnect state. The architecture and local contracts were strengthened; live network acceptance was still outstanding. |
| **2026-10-29 20:02 (+03:00)** | `569aa04` — added deterministic kickoff and out-of-bounds restart lifecycle on a feature branch. |
| **2026-10-29 20:08 (+03:00)** | `099af7c` — merged the restart work into `main` through PR #11. |
| **2026-10-30 15:50 (+03:00)** | `502dc88` — improved kickoff formation logging and added headless position-dump checks for 4-3-3 and 4-2-3-1, including halftime end-switch placement. This commit is present on local `main` but not yet on `origin/main`. |
| **2026-10-30 16:20 (+03:00)** | `6e89af3` — recorded successful two-process localhost PVP acceptance for cases A–F and added a reproducible headless host/client harness. Both processes completed 3–0 at tick 3600 with matching final hashes. |
| **2026-10-30** | Reviewed successive football-realism benchmark and physical-shot proposals. Issues were identified and revised in the proposals; no physical-shot or telemetry implementation resulted from those reviews. |

## Strengths

- **Deterministic core:** fixed simulation ticks, seeded randomness, authoritative state hashes, replay checks, and snapshot tests provide a solid base for reproducible simulation work.
- **Good observability:** action/probability logs, restart logs, debug state, and validation dumps make simulation outcomes inspectable.
- **Config-first design:** formations, roster templates, match tuning, and probability weights are concentrated in `data/match_config.json`.
- **Useful separation:** simulation logic is distinct from ENet transport, with manager command routing and UI in separate areas.
- **Restart tests exercise production paths:** boundary crossings, last touch, award, delivery, possession recovery, and duplicate prevention are tested rather than only testing isolated helpers.
- **Scope discipline:** the recent kickoff-layout change reuses formation data and does not alter in-play movement or shot math.

## Known issues and open risks

### High priority — remote and interactive multiplayer remain unvalidated

Same-machine localhost testing established synchronization between two live Godot processes for the recorded acceptance cases. Remote Internet, NAT/firewall traversal, packet loss, and interactive GUI play have not been tested; do not extend the localhost result to those environments.

Reconnect was tested while the client process remained alive. Restarting the client process is not supported. Cross-platform or cross-Godot-version bit-identical behavior has not been established.

### High priority — physical shot realism is a future milestone

Shots still resolve immediately. Physical flight requires a settled specification and implementation for authoritative height/state, fixed-step integration, swept collision ordering, goal/frame geometry, terminal/rebound transitions, phase boundaries, snapshots, and RNG compatibility. It must not be reported as implemented or validated.

### Medium priority — realism claims are not benchmark-backed

There is no established telemetry-driven multi-seed acceptance run. Probability/tactical parameters and proposed ball-flight constants should be treated as tuning values, not calibrated realism. The pitch-length and goal-width pixel anchors imply different scales; values such as `480 px/s` are gameplay tuning, not a consistent metric conversion.

### Medium priority — open-play movement and possession need measurement

Prior play observation described midfield/off-ball shape as somewhat static. This is separate from kickoff lineup placement. Possession improvements exist, but no multi-seed result demonstrates a target such as five or more completed passes per possession.

### Lower priority — visual acceptance

Kickoff layouts are verified by headless position dumps, not an interactive screenshot/playtest. Network UI and restart presentation are likewise not accepted in a live UI session.

## Validation evidence and limits

Recorded Godot runtime: **4.7.2.stable.official.ed1daf0bf**.

- Headless Godot editor import/project load: **exit 0**.
- `scripts/tests/determinism_test.gd`: **exit 0**; deterministic score 1–0, 132 key events and 20 hashes matched, snapshot replay passed.
- `scripts/tests/restart_validation_test.gd`: **exit 0**; kickoff layout checks for 4-3-3 and 4-2-3-1, halftime switch, kickoff direction/distance, throw-ins, corners, goal kicks, post-goal kickoff, and replay checks passed.
- `scripts/tests/pvp_acceptance_peer.gd`: separate-process localhost host/client tests passed cases A–F; both completed 3–0 at tick 3600 with matching final hashes and zero mismatches.
- Headless Godot editor import/project load: **exit 0**.
- **NOT RUN:** remote-network, packet-loss, cross-platform, and interactive GUI acceptance.
- **NOT RUN:** interactive GUI playtest or screenshot acceptance.
- **NOT RUN:** realism benchmark, telemetry collection, multi-seed calibration, or physical-shot-flight tests.

See [GMN1_PVP_ACCEPTANCE_REPORT.md](./GMN1_PVP_ACCEPTANCE_REPORT.md) for setup, per-case results, logs, configuration, and limitations; [README.md](./README.md) for run instructions and current architecture; and [GMN1_CORRECTNESS_REMEDIATION_REPORT.md](./GMN1_CORRECTNESS_REMEDIATION_REPORT.md) for restart and correctness evidence.

## Recommended next milestones

1. **Remote/GUI PVP acceptance:** validate on at least two machines and exercise the graphical lobby, reconnect, and restart UX; add packet-loss coverage if practical.
2. **M5 observability and benchmark foundation:** define structured event contracts, run manifests, and multi-seed sampling before changing realism parameters.
3. **M6 physical shot flight:** finalize the trajectory/collision specification, implement shots only, and gate on deterministic geometry, restart, snapshot, phase-boundary, and ground-pass regression tests. Defer crosses and headers.
4. **Tactical behavior measurement:** collect possession-length and movement-shape metrics across formations and plans; then tune or separately address static open-play behavior.
5. **Presentation/launch readiness:** perform interactive kickoff/restart playtests and improve match/replay UX before matchmaking or accounts.

## Current repository position

- Local code under test on `main`: `6e89af379e5a845987d573996079329649f0e81f`
- `origin/main`: `099af7ce8e8a26e801f55d28856ce30a5951491a`
- The kickoff-layout and PVP acceptance commits were local-only when this audit was updated; the audit file itself is included in the requested push.
