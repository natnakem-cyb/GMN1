# P1 Slice 2: Role-by-zone pass selection

> **Retroactive implementation record, not a pre-approved task prompt.** The
> reviewed P1 Slice 1 prompt explicitly deferred the full role-by-zone weights
> matrix to Slice 2. No separate Slice 2 prompt or review of the specific
> multipliers was obtained before implementation. This document records what
> was implemented and the choices that still require review; it must not be
> read as evidence that those choices were previously approved.

## Intended scope

Adjust the existing pass receiver scorer using configurable carrier-role-group
and normalized attack-zone weights. Preserve the existing candidate generation,
range and marking checks, pass-pair limit, lane/safety behavior, pass-success
probability, shot selection, and all ball/restart physics. Add telemetry for
attempts and completions where practical, using the existing telemetry and
snapshot mechanisms.

The scorer's baseline terms are unchanged except where a multiplier is applied:

| Existing term | Baseline |
|---|---:|
| Nearby-distance weight | 100 |
| Openness weight / distance | 32 / 150 px |
| Support-angle weight | 28 |
| Possession / direct progression weight | 24 / 72 |
| Backward-pass penalty | 18 |
| Viable forward-receiver bonus | +60 |

The zone multipliers scale the corresponding existing term; they are not
standalone score points. A multiplier of `1.0` is neutral, `0.0` disables that
term, and other values scale it proportionally.

## Implemented weight table

Current configuration is in `data/match_config.json`, under
`decision.pass_selection.role_zone_pass_weights`. The fields are progression
multiplier / forward-receiver multiplier / wide-receiver multiplier /
midfield-receiver multiplier / recycle-nearby multiplier / box-edge-nearby
multiplier:

| Carrier group | Band | Current multipliers |
|---|---|---|
| Defensive | DEF | 1.0 / 0.0 / 0.0 / 0.0 / 1.0 / 1.0 |
| Defensive | MID | 1.0 / 0.0 / 0.0 / 0.0 / 1.0 / 1.0 |
| Defensive | ATT | 1.0 / 0.0 / 0.0 / 0.0 / 1.0 / 1.0 |
| Midfield | DEF | 1.0 / 0.0 / 0.0 / 0.0 / 1.0 / 1.0 |
| Midfield | MID | 1.0 / 1.25 / 1.0 / 0.0 / 1.0 / 1.0 |
| Midfield | ATT | 1.0 / 0.0 / 0.0 / 0.0 / 1.0 / 1.0 |
| Wide | DEF | 1.0 / 0.0 / 0.0 / 0.0 / 1.0 / 1.0 |
| Wide | MID | 1.0 / 0.0 / 0.0 / 0.0 / 1.0 / 1.0 |
| Wide | ATT | 1.0 / 0.0 / 0.0 / 0.0 / 1.0 / 1.0 |
| Forward | DEF | 1.0 / 0.0 / 0.0 / 0.0 / 1.0 / 1.0 |
| Forward | MID | 1.0 / 0.0 / 0.0 / 0.0 / 1.0 / 1.0 |
| Forward | ATT | 1.0 / 0.0 / 0.0 / 0.0 / 1.0 / 1.0 |

The original values were implementation-time tuning choices, not values
supplied or calibrated by a reviewed Slice 2 specification. After review, the
receiver-bonus multipliers have been neutralized everywhere except
`midfield.MID.forward_receiver_multiplier` (1.25) and
`midfield.MID.wide_receiver_multiplier` (1.0), restoring the prior context
gate's role/zone coverage. All `midfield_receiver_multiplier` values are 0.0,
and all `recycle_nearby_multiplier` values are 1.0. All progression and
box-edge proximity multipliers are also 1.0. Only the two receiver-bonus cells
above can currently contribute a receiver bonus; recycle suppression,
progression scaling, and box-edge proximity scaling are disabled by
configuration.

## Additional scoring choices and review caveats

- **Defensive recycling:** The conditional discount code remains, but the
  multiplier is now 1.0 for every role/zone cell, so it has no scoring effect.
  The behavior was added during implementation without a reviewed requirement
  and is disabled until separately scoped and reviewed.
- **Edge-band receiver preference:** A forward ST/CF/wide candidate that is
  forward of the carrier, within the configured pass range and marking
  threshold, and inside the existing inclusive box-edge band has its
  nearby-distance term scaled by `box_edge_nearby_multiplier`. This hook is
  neutralized (1.0) in every cell; existing shot-priority trigger and geometry
  are unchanged.
- **Receiver-bonus gate:** Before Slice 2, the +60 receiver bonus
  required `midfield_progression_context`, `has_viable_forward_receiver`, and a
  forward receiver candidate that passed the per-candidate forward, range, and
  marking checks. The Slice 2 implementation replaced those first two gates
  with a role-zone multiplier lookup. That initially allowed bonuses outside
  the old MID-only midfield context; this was not intentional. The current
  config zeros all receiver-bonus cells except the two `midfield.MID` entries,
  restoring that role/zone gate. The existing per-candidate checks remain in
  place.

## Telemetry and synchronized state

Selection telemetry records progressive attempts/completions by passer role,
MID-to-ST attempts/completions, forward/lateral/backward passes by origin band,
penalty-area/edge/six-yard receptions, shots by zone, and turnovers.
Progressive classification and origin band/direction are captured at launch so
completion telemetry uses launch geometry. Restart deliveries count in total
pass attempts/completions but are excluded from open-play selection and
progression metrics.

`ball_pass_launch_telemetry` and `ball_is_restart_delivery` are serialized,
validated, and hashed so a snapshot taken during a pass preserves how its
event will be classified on completion. The snapshot version and lockstep
protocol marker were incremented for this state shape. These fields support
consistent telemetry attribution after restore; they do not themselves alter
receiver selection or ball physics. This does not constitute a two-process PVP
verification.

## Validation and pending review

The implementation added controlled tests for midfield-forward preference,
safe fallback, marked forwards, launch-geometry persistence, and restart
telemetry. A config regression now asserts that only the original midfield/MID
receiver-bonus context is active and all other role-zone scoring hooks are
neutral. The required
ball-flight, determinism, and restart-validation suites passed after rebasing
Slice 2 directly onto `2c78299`; the restored launch-clearance log is
`15.71 px`.

Progression scaling, box-edge receiver preference, and defensive-recycle
suppression are neutralized. Only the original midfield/MID forward-receiver
preference remains active. No push has been made.
