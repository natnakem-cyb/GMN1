extends SceneTree

const SimulationScript = preload("res://scripts/simulation/match_simulation.gd")
const PitchViewScript = preload("res://scripts/ui/pitch_3d.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var simulation: MatchSimulation = SimulationScript.new()
	root.add_child(simulation)
	if not simulation.setup_match("4-3-3"):
		push_error("Ball observability test could not configure the simulation.")
		quit(1)
		return
	simulation.start_match()
	var pitch: Node3D = PitchViewScript.new()
	root.add_child(pitch)
	pitch.configure(
		simulation, simulation.config["field"], simulation.config["match"]["ball_flight"],
		simulation.config["view"]["pitch3d"]
	)
	await process_frame
	await process_frame
	var visual_ok := _test_carrier_visual(simulation, pitch)
	var release_clearance_ok := _test_kicker_release(simulation)
	var release_ok := _test_pass_lifecycle(simulation)
	var interception_ok := _test_interception(simulation)
	var miss_ok := _test_missed_control_does_not_restore_owner(simulation)
	if not visual_ok or not release_clearance_ok or not release_ok or not interception_ok or not miss_ok:
		quit(1)
		return
	print("PASS: carrier perimeter visibility, stationary/moving/turning offsets, both teams/directions, one shaded ball, physical shadow, kicker clearance across directions/angles, restored later collision, pass release/flight/reception, physical interception, and loose failed control.")
	pitch.free()
	simulation.free()
	quit(0)

func _test_carrier_visual(simulation: MatchSimulation, pitch: Node3D) -> bool:
	simulation.restart_pending = false
	simulation.restart_kind = "in_play"
	var view: Node = pitch
	var view_data: Dictionary = simulation.config["view"]["pitch3d"]
	var expected_offset := float(view_data["player_marker_diameter_px"]) * 0.5 \
		+ float(view_data["ball_visual_diameter_px"]) * 0.5 \
		* float(view_data["carrier_ball_offset_ball_radius_factor"])
	var passed := true
	for team_index in range(2):
		var team: FootballTeam = simulation.teams[team_index]
		var carrier: FootballPlayer = team.players[0]
		for attacks_right in [true, false]:
			team.attacks_right = attacks_right
			carrier.position = Vector2(500.0, 323.8)
			simulation.ball_owner = carrier
			simulation.ball_target = null
			simulation.ball_in_flight = false
			simulation.ball_position_3d = simulation._metric_position_from_pitch(carrier.position)
			view.player_last_positions.clear()
			view.player_facing_directions.clear()
			view.player_movement_directions.clear()
			view._sync_players()
			view._sync_dynamic_state()
			var marker: Node3D = view.player_nodes["%d:%d" % [team_index, carrier.id]]
			var marker_screen: Vector2 = view.pitch_camera.unproject_position(marker.position)
			var ball_screen: Vector2 = view.pitch_camera.unproject_position(view.ball_mesh.position)
			var fallback := Vector2.RIGHT if attacks_right else Vector2.LEFT
			passed = passed and view.ball_mesh.visible \
				and absf(marker_screen.distance_to(ball_screen) - expected_offset) < 1.0 \
				and view._carrier_facing_direction(carrier) == fallback \
				and view.ball_mesh.material_override.shading_mode == BaseMaterial3D.SHADING_MODE_PER_PIXEL \
				and view.ball_mesh.material_override.get_flag(BaseMaterial3D.FLAG_DISABLE_DEPTH_TEST) \
				and view.ball_mesh.material_override.render_priority > 1 \
				and (marker.get_node("ShirtNumber") as Label3D).render_priority == 1 \
				and view.ball_shadow.position.x == simulation.ball_position_3d.x \
				and view.ball_shadow.position.z == simulation.ball_position_3d.z
			var first_screen := ball_screen
			carrier.position.x += 8.0
			view._sync_players()
			view._sync_dynamic_state()
			var moving_screen: Vector2 = view.pitch_camera.unproject_position(view.ball_mesh.position)
			passed = passed and moving_screen.distance_to(first_screen) > 0.1
			carrier.position.y += 8.0
			view._sync_players()
			view._sync_dynamic_state()
			var turned_screen: Vector2 = view.pitch_camera.unproject_position(view.ball_mesh.position)
			passed = passed and turned_screen.distance_to(moving_screen) > 0.1
			var key := "%d:%d" % [team_index, carrier.id]
			var face_before_stop: Vector2 = view.player_facing_directions[key]
			view._sync_players()
			passed = passed and view._carrier_facing_direction(carrier).distance_to(face_before_stop) < 0.001
	var ball_instances := 0
	for child in pitch.get_children():
		if child.name == "SimulationBall":
			ball_instances += 1
	passed = passed and ball_instances == 1
	if not passed:
		push_error("Ball observability test failed: ball was hidden, misplaced, unlit, shadow-diverged, or failed to follow carrier direction.")
	return passed

func _test_kicker_release(simulation: MatchSimulation) -> bool:
	simulation.restart_pending = false
	var passed := true
	for team_index in range(2):
		var team: FootballTeam = simulation.teams[team_index]
		var passer: FootballPlayer = team.players[5]
		var receiver: FootballPlayer = team.players[8]
		for attacks_right in [true, false]:
			team.attacks_right = attacks_right
			for current_team in simulation.teams:
				for player in current_team.players:
					player.position = Vector2(-1000.0, -1000.0)
			passer.position = Vector2(500.0, 300.0)
			var forward_sign := 1.0 if attacks_right else -1.0
			var lateral_sign := 1.0 if team_index == 0 else -1.0
			receiver.position = passer.position + Vector2(forward_sign * 220.0, lateral_sign * 60.0)
			simulation.ball_owner = passer
			simulation.ball_target = null
			simulation.ball_in_flight = false
			simulation.ball_kicker_clearance_id = -1
			simulation.ball_velocity_3d = Vector3.ZERO
			simulation.ball_position_3d = simulation._metric_position_from_pitch(passer.position)
			simulation._resolve_pass(passer, team)
			var launch_vector := Vector2(
				simulation.ball_position_3d.x - passer.position.x * simulation._metres_per_pixel(),
				simulation.ball_position_3d.z - passer.position.y * simulation._metres_per_pixel()
			)
			var away_dot := launch_vector.dot(Vector2(simulation.ball_velocity_3d.x, simulation.ball_velocity_3d.z))
			var clear_distance: float = simulation._ball_kick_clearance_distance()
			var start_separation := launch_vector.length()
			var launched: bool = simulation.ball_target == receiver and simulation.ball_owner == null \
				and simulation.ball_in_flight and simulation.ball_kicker_clearance_id == passer.id \
				and start_separation >= clear_distance - 0.001 and away_dot > 0.0
			var launch_position := simulation.ball_position_3d
			simulation._advance_ball(0.02)
			var escaped: bool = simulation.ball_owner == null and simulation.ball_target == receiver \
				and simulation.ball_in_flight and simulation.ball_position_3d.distance_to(launch_position) > 0.01 \
				and simulation.ball_kicker_clearance_id == -1
			var center := Vector3(
				passer.position.x * simulation._metres_per_pixel(), 0.0,
				passer.position.y * simulation._metres_per_pixel()
			)
			var previous := center + Vector3(clear_distance + 0.2, simulation.ball_radius_m, 0.0)
			var current := center + Vector3(0.30, simulation.ball_radius_m, 0.0)
			simulation.ball_position_3d = previous
			simulation.ball_velocity_3d = Vector3(-2.0, 0.0, 0.0)
			simulation.ball_kicker_clearance_id = -1
			var recontact: bool = simulation._resolve_player_contact(previous, current) == passer \
				and simulation.ball_owner == passer
			passed = passed and launched and escaped and recontact
	if not passed:
		push_error("Pass release test failed: ball did not leave the kicker cleanly, or later collision was not restored.")
	return passed

func _test_pass_lifecycle(simulation: MatchSimulation) -> bool:
	var team: FootballTeam = simulation.teams[0]
	var passer: FootballPlayer = team.players[2]
	for index in range(team.players.size()):
		team.players[index].position = Vector2(100.0 + float(index) * 145.0, 170.0 + float(index % 3) * 100.0)
	for player in simulation.teams[1].players:
		player.position = Vector2(-500.0, -500.0)
	passer.position = Vector2(300.0, 300.0)
	simulation.ball_in_flight = false
	simulation.ball_target = null
	simulation.ball_velocity_3d = Vector3.ZERO
	simulation._set_possession(passer)
	simulation._resolve_pass(passer, team)
	simulation.ball_pass_probability = 1.0
	var receiver := simulation.ball_target
	var released := simulation.ball_owner == null and receiver != null and simulation.ball_in_flight
	var start_position := simulation.ball_position_3d
	simulation._advance_ball(0.05)
	var flying := simulation.ball_owner == null and simulation.ball_in_flight \
		and simulation.ball_position_3d.distance_to(start_position) > 0.001
	if receiver == null:
		return false
	simulation.ball_position = receiver.position
	simulation.ball_position_3d = simulation._metric_position_from_pitch(receiver.position)
	simulation.ball_pass_probability = 1.0
	simulation._complete_flight_pass()
	var received := simulation.ball_owner == receiver and simulation.ball_target == null \
		and not simulation.ball_in_flight \
		and simulation.ball_position_3d.distance_to(simulation._metric_position_from_pitch(receiver.position)) < 0.001
	if not released or not flying or not received:
		push_error("Ball observability test failed: pass release, independent flight, or physical receiver restoration was inconsistent.")
	return released and flying and received

func _test_interception(simulation: MatchSimulation) -> bool:
	var receiver: FootballPlayer = simulation.teams[0].players[0]
	var interceptor: FootballPlayer = simulation.teams[1].players[1]
	for team in simulation.teams:
		for player in team.players:
			player.position = Vector2(-500.0, -500.0)
	interceptor.position = Vector2(400.0, 320.0)
	simulation.ball_owner = null
	simulation.ball_target = receiver
	simulation.ball_in_flight = true
	simulation.ball_flight_phase = "ground_pass"
	simulation.ball_position_3d = simulation._metric_position_from_pitch(interceptor.position)
	simulation.ball_position = interceptor.position
	simulation.ball_velocity_3d = Vector3(5.0, 0.0, 0.0)
	simulation._sync_ball_projection()
	var passed := simulation._try_pass_interception() \
		and simulation.ball_owner == interceptor and simulation.ball_target == null \
		and not simulation.ball_in_flight
	if not passed:
		push_error("Ball observability test failed: physical pass interception assigned the wrong carrier.")
	return passed

func _test_missed_control_does_not_restore_owner(simulation: MatchSimulation) -> bool:
	var passer: FootballPlayer = simulation.teams[0].players[0]
	var receiver: FootballPlayer = simulation.teams[0].players[1]
	simulation.ball_owner = null
	simulation.ball_target = receiver
	simulation.ball_in_flight = true
	simulation.ball_flight_phase = "ground_pass"
	simulation.ball_shooter_id = passer.id
	simulation.ball_pass_probability = 0.0
	simulation.ball_velocity_3d = Vector3(8.0, 0.0, 0.0)
	simulation.ball_position_3d = Vector3(40.0, simulation.ball_radius_m, 32.0)
	simulation._sync_ball_projection()
	simulation._complete_flight_pass()
	var passed := simulation.ball_owner == null and simulation.ball_target == null \
		and simulation.ball_in_flight and simulation.ball_flight_phase == "rebound" \
		and simulation.ball_velocity_3d.length() > 0.0
	var position_before := simulation.ball_position_3d
	simulation._advance_ball(0.05)
	passed = passed and simulation.ball_owner == null and simulation.ball_in_flight \
		and simulation.ball_position_3d.distance_to(position_before) > 0.001
	if not passed:
		push_error("Ball observability test failed: failed pass control restored possession prematurely or stopped physical flight.")
	return passed
