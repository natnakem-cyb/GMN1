extends Node
class_name MatchSimulation

signal state_changed
signal match_finished(home_score: int, away_score: int)
signal action_resolved(action_text: String, probability: float, formula_text: String)
signal halftime_started
signal substitution_made(team_name: String, outgoing_name: String, incoming_name: String)

const PlayerScript = preload("res://scripts/data/player.gd")
const TeamScript = preload("res://scripts/data/team.gd")
const CONFIG_PATH := "res://data/match_config.json"
const RESTART_IN_PLAY := "in_play"
const RESTART_KICKOFF := "kickoff"
const RESTART_THROW_IN := "throw_in"
const RESTART_CORNER := "corner_kick"
const RESTART_GOAL_KICK := "goal_kick"
const RESTART_FULL_TIME := "full_time"
const NO_PLAYER_ID := -1

var config: Dictionary
var teams: Array[FootballTeam] = []
var rng := RandomNumberGenerator.new()
var ball_position := Vector2.ZERO
var ball_velocity := Vector2.ZERO
var ball_position_3d := Vector3.ZERO
var ball_velocity_3d := Vector3.ZERO
var ball_in_flight := false
var ball_on_ground := true
var ball_flight_phase := "none"
var ball_pass_probability := -1.0
var ball_shooter_id := NO_PLAYER_ID
var ball_keeper_attempted := false
var ball_owner: FootballPlayer
var ball_target: FootballPlayer
var active := false
var finished := false
var externally_ticked := false
var tick_count := 0
var elapsed_seconds := 0.0
var accumulator := 0.0
var decision_clock := 0.0
var restart_delay_remaining := 0.0
var next_kickoff_team := 1
var half_index := 0
var restart_kind := RESTART_KICKOFF
var restart_pending := true
var restart_awarded_team := 0
var restart_position := Vector2.ZERO
var restart_crossing_position := Vector2.ZERO
var restart_taker_id := NO_PLAYER_ID
var restart_receiver_id := NO_PLAYER_ID
var last_touch_team_index := -1
var last_touch_player_id := NO_PLAYER_ID
var ai_reaction_clock := 0.0
var event_log: Array[String] = []
var selected_player_index := 0
var last_snapshot_error := ""
var last_action := "Ready to kick off"
var last_probability := 0.0
var last_formula := "No action resolved"
var last_shot_on_target_probability := -1.0
var last_goalkeeper_save_probability := -1.0
var last_rebound_probability := -1.0
var preferred_pass_debug := "No pass target evaluated"
var last_defensive_decision := "No defensive decision yet"
var last_jockey_log_key := ""
var home_formation := "4-3-3"
var box_run_logged_player_keys: Dictionary = {}

func _ready() -> void:
	config = _read_json(CONFIG_PATH)
	if config.is_empty():
		set_process(false)
		return
	var field_data: Dictionary = config["field"]
	var ball_data: Dictionary = config["match"]["ball_flight"]
	ball_data["metres_per_pixel"] = float(field_data["pitch_length_m"]) / float(field_data["width"])
	ball_data["pixels_per_metre"] = 1.0 / float(ball_data["metres_per_pixel"])
	ball_data["goal_width_px"] = float(ball_data["goal_width_m"]) * float(ball_data["pixels_per_metre"])
	ball_data["goal_height_px"] = float(ball_data["goal_height_m"]) * float(ball_data["pixels_per_metre"])
	rng.seed = int(config.get("seed", 1))

func _process(real_delta: float) -> void:
	if not active or externally_ticked:
		return
	var match_data: Dictionary = config["match"]
	accumulator += real_delta * float(match_data["simulation_seconds_per_real_second"])
	var tick_seconds := float(match_data["tick_seconds"])
	while accumulator >= tick_seconds and active:
		accumulator -= tick_seconds
		step_tick()

func step_tick() -> void:
	if not active or finished:
		return
	tick_count += 1
	_tick(float(config["match"]["tick_seconds"]))

func get_state_hash() -> String:
	var hash_state: Variant = _canonicalize_hash_value(_build_state_data(false, false))
	return JSON.stringify(hash_state, "", true, true).sha256_text()

func _canonicalize_hash_value(value: Variant) -> Variant:
	if value is float:
		return roundf(float(value) * 10000.0) / 10000.0
	if value is Array:
		var canonical_array: Array = []
		for item in value:
			canonical_array.append(_canonicalize_hash_value(item))
		return canonical_array
	if value is Dictionary:
		var canonical_dictionary: Dictionary = {}
		for key in value:
			canonical_dictionary[key] = _canonicalize_hash_value(value[key])
		return canonical_dictionary
	return value

func create_snapshot() -> Dictionary:
	return {
		"version": int(config["network"]["snapshot_version"]),
		"state": _build_state_data(true, true)
	}

func validate_snapshot(snapshot: Variant) -> bool:
	last_snapshot_error = ""
	if not snapshot is Dictionary:
		return _reject_snapshot("root must be a dictionary")
	if typeof(snapshot.get("version")) != TYPE_INT \
	or int(snapshot["version"]) != int(config["network"]["snapshot_version"]):
		return _reject_snapshot("unsupported snapshot version")
	if not snapshot.get("state") is Dictionary:
		return _reject_snapshot("state must be a dictionary")
	var state: Dictionary = snapshot["state"]
	var required_state_keys: Array[String] = [
		"tick_count", "elapsed_seconds", "accumulator", "decision_clock", "restart_delay_remaining",
		"next_kickoff_team", "half_index", "ai_reaction_clock", "event_log", "ball_position",
		"ball_velocity", "ball_position_3d", "ball_velocity_3d", "ball_in_flight", "ball_on_ground",
		"ball_flight_phase", "ball_pass_probability", "ball_shooter_id", "ball_keeper_attempted",
		"ball_owner_id", "ball_target_id", "last_action", "last_probability",
		"last_formula", "last_shot_on_target_probability", "last_goalkeeper_save_probability",
		"last_rebound_probability", "preferred_pass_debug", "last_defensive_decision",
		"last_jockey_log_key", "home_formation", "rng_seed", "rng_state", "active", "finished",
		"restart_kind", "restart_pending", "restart_awarded_team", "restart_position",
		"restart_crossing_position", "restart_taker_id", "restart_receiver_id",
		"last_touch_team_index", "last_touch_player_id",
		"teams"
	]
	for key in required_state_keys:
		if not state.has(key):
			return _reject_snapshot("state is missing '%s'" % key)
	if not _is_int_value(state["tick_count"]) or int(state["tick_count"]) < 0:
		return _reject_snapshot("tick_count is invalid")
	if not _is_int_value(state["next_kickoff_team"]) or not [0, 1].has(int(state["next_kickoff_team"])):
		return _reject_snapshot("next_kickoff_team is invalid")
	if not _is_int_value(state["half_index"]) or not [0, 1].has(int(state["half_index"])):
		return _reject_snapshot("half_index is invalid")
	if not _is_int_value(state["rng_seed"]) or not _is_int_value(state["rng_state"]):
		return _reject_snapshot("RNG state is invalid")
	for key in [
		"elapsed_seconds", "accumulator", "decision_clock", "restart_delay_remaining",
		"ai_reaction_clock", "last_probability", "last_shot_on_target_probability",
		"last_goalkeeper_save_probability", "last_rebound_probability"
	]:
		if not _is_finite_number(state[key]):
			return _reject_snapshot("state field '%s' is not finite numeric data" % key)
	for key in [
		"last_action", "last_formula", "preferred_pass_debug", "last_defensive_decision",
		"last_jockey_log_key", "home_formation"
	]:
		if typeof(state[key]) != TYPE_STRING:
			return _reject_snapshot("state field '%s' must be a string" % key)
	if typeof(state["active"]) != TYPE_BOOL or typeof(state["finished"]) != TYPE_BOOL \
	or bool(state["active"]) and bool(state["finished"]):
		return _reject_snapshot("match phase flags are inconsistent")
	if not config["formations"].has(str(state["home_formation"])):
		return _reject_snapshot("home_formation is invalid")
	if not _is_vector_data(state["ball_position"]) or not _is_vector_data(state["ball_velocity"]):
		return _reject_snapshot("ball vectors are invalid")
	if not _is_vector3_data(state.get("ball_position_3d")) or not _is_vector3_data(state.get("ball_velocity_3d")):
		return _reject_snapshot("3D ball vectors are invalid")
	if typeof(state.get("ball_in_flight")) != TYPE_BOOL or typeof(state.get("ball_on_ground")) != TYPE_BOOL \
	or typeof(state.get("ball_flight_phase")) != TYPE_STRING \
	or not ["none", "ground_pass", "shot", "rebound"].has(str(state.get("ball_flight_phase"))) \
	or not _is_finite_number(state.get("ball_pass_probability")) \
	or not _is_int_value(state.get("ball_shooter_id")) \
	or typeof(state.get("ball_keeper_attempted")) != TYPE_BOOL:
		return _reject_snapshot("3D ball flight metadata is invalid")
	if not _is_int_value(state["ball_owner_id"]) or not _is_int_value(state["ball_target_id"]):
		return _reject_snapshot("ball references are invalid")
	if not state["event_log"] is Array or state["event_log"].size() > 10000:
		return _reject_snapshot("event_log is invalid or too large")
	for event in state["event_log"]:
		if typeof(event) != TYPE_STRING or str(event).length() > 4096:
			return _reject_snapshot("event_log contains an invalid entry")
	var tick_seconds := float(config["match"]["tick_seconds"])
	var half_duration := float(config["match"]["half_duration_seconds"])
	var max_ticks := int(float(config["match"]["half_duration_seconds"]) * 2.0 / tick_seconds)
	if int(state["tick_count"]) > max_ticks or float(state["elapsed_seconds"]) < 0.0 \
	or float(state["elapsed_seconds"]) > half_duration * 2.0 + tick_seconds:
		return _reject_snapshot("match clock is outside configured bounds")
	if absf(float(state["elapsed_seconds"]) - float(state["tick_count"]) * tick_seconds) > 0.001:
		return _reject_snapshot("tick_count and elapsed_seconds disagree")
	if float(state["accumulator"]) < 0.0 or float(state["accumulator"]) >= tick_seconds \
	or float(state["decision_clock"]) < 0.0 \
	or float(state["restart_delay_remaining"]) < 0.0 \
	or float(state["restart_delay_remaining"]) > maxf(
		float(config["match"]["goal_reset_seconds"]), float(config["match"]["restarts"]["delay_seconds"])
	) + tick_seconds \
	or float(state["ai_reaction_clock"]) < 0.0:
		return _reject_snapshot("match timer is outside valid bounds")
	if (float(state["elapsed_seconds"]) >= half_duration) != (int(state["half_index"]) == 1):
		return _reject_snapshot("half index disagrees with match clock")
	if not state["teams"] is Array or state["teams"].size() != teams.size():
		return _reject_snapshot("team count is invalid")
	var all_player_ids: Dictionary = {}
	var on_pitch_ids: Dictionary = {}
	for team_index in range(teams.size()):
		var team_state: Variant = state["teams"][team_index]
		if not team_state is Dictionary:
			return _reject_snapshot("team %d must be a dictionary" % team_index)
		var team_required_keys: Array[String] = [
			"formation", "mentality", "game_plan", "instructions", "completed_passes_in_possession",
			"substitutions_used", "tactical_points", "tactical_point_clock", "instruction_cooldown",
			"score", "is_home", "attacks_right", "change_cooldown", "players", "bench"
		]
		for key in team_required_keys:
			if not team_state.has(key):
				return _reject_snapshot("team %d is missing '%s'" % [team_index, key])
		var expected_team: FootballTeam = teams[team_index]
		if typeof(team_state["formation"]) != TYPE_STRING \
		or not config["formations"].has(str(team_state["formation"])):
			return _reject_snapshot("team %d formation is invalid" % team_index)
		if typeof(team_state["mentality"]) != TYPE_STRING \
		or not config["probability"]["tactical_modifiers"]["mentality"].has(str(team_state["mentality"])):
			return _reject_snapshot("team %d mentality is invalid" % team_index)
		if typeof(team_state["game_plan"]) != TYPE_STRING \
		or not config["probability"]["tactical_modifiers"]["game_plan"].has(str(team_state["game_plan"])):
			return _reject_snapshot("team %d game plan is invalid" % team_index)
		if typeof(team_state["is_home"]) != TYPE_BOOL or typeof(team_state["attacks_right"]) != TYPE_BOOL:
			return _reject_snapshot("team %d side flags are invalid" % team_index)
		var expected_attacks_right := expected_team.is_home if int(state["half_index"]) == 0 else not expected_team.is_home
		if bool(team_state["is_home"]) != expected_team.is_home \
		or bool(team_state["attacks_right"]) != expected_attacks_right:
			return _reject_snapshot("team %d side orientation is inconsistent" % team_index)
		for key in ["completed_passes_in_possession", "substitutions_used", "score"]:
			if not _is_int_value(team_state[key]) or int(team_state[key]) < 0:
				return _reject_snapshot("team %d field '%s' is invalid" % [team_index, key])
		for key in ["tactical_points", "tactical_point_clock", "instruction_cooldown", "change_cooldown"]:
			if not _is_finite_number(team_state[key]) or float(team_state[key]) < 0.0:
				return _reject_snapshot("team %d field '%s' is invalid" % [team_index, key])
		if int(team_state["substitutions_used"]) > int(config["match"]["substitution_limit"]) \
		or float(team_state["tactical_points"]) > float(config["match"]["tactical_points_maximum"]) \
		or float(team_state["tactical_point_clock"]) >= float(config["thresholds"]["tactical_point_regen_interval_seconds"]) \
		or float(team_state["instruction_cooldown"]) > float(config["match"]["instruction_cooldown_seconds"]) \
		or float(team_state["change_cooldown"]) > float(config["match"]["tactical_change_cooldown_seconds"]):
			return _reject_snapshot("team %d resource or cooldown is outside configured bounds" % team_index)
		if not team_state["instructions"] is Array \
		or team_state["instructions"].size() > int(config["match"]["instruction_slots"]):
			return _reject_snapshot("team %d instruction list is invalid" % team_index)
		var instruction_ids: Dictionary = {}
		for instruction in team_state["instructions"]:
			if not instruction is Dictionary or not instruction.has("id") or not instruction.has("remaining") \
			or typeof(instruction["id"]) != TYPE_STRING or not _is_finite_number(instruction["remaining"]):
				return _reject_snapshot("team %d has malformed instruction data" % team_index)
			var instruction_id := str(instruction["id"])
			if instruction_ids.has(instruction_id) \
			or not config["probability"]["instructions"].has(instruction_id) \
			or float(instruction["remaining"]) <= 0.0 \
			or float(instruction["remaining"]) > float(config["thresholds"]["instruction_duration_seconds"]):
				return _reject_snapshot("team %d instruction is invalid" % team_index)
			instruction_ids[instruction_id] = true
		if not team_state["players"] is Array or team_state["players"].size() != expected_team.players.size() \
		or not team_state["bench"] is Array or team_state["bench"].size() != expected_team.bench.size():
			return _reject_snapshot("team %d roster size is invalid" % team_index)
		var expected_players: Dictionary = {}
		for player in expected_team.players + expected_team.bench:
			expected_players[player.id] = player
		var seen_team_ids: Dictionary = {}
		for roster_key in ["players", "bench"]:
			for player_data in team_state[roster_key]:
				if not _validate_snapshot_player(
					player_data, expected_players, team_index, roster_key == "players"
				):
					return _reject_snapshot("team %d contains invalid player data" % team_index)
				var player_id := int(player_data["id"])
				if seen_team_ids.has(player_id) or all_player_ids.has(player_id):
					return _reject_snapshot("duplicate player id %d" % player_id)
				seen_team_ids[player_id] = true
				all_player_ids[player_id] = team_index
				if roster_key == "players":
					on_pitch_ids[player_id] = true
		if seen_team_ids.size() != expected_players.size():
			return _reject_snapshot("team %d roster identity set is incomplete" % team_index)
	var owner_id := int(state["ball_owner_id"])
	var target_id := int(state["ball_target_id"])
	if owner_id != -1 and (not on_pitch_ids.has(owner_id) or target_id != -1):
		return _reject_snapshot("ball owner reference is inconsistent")
	if target_id != -1 and not on_pitch_ids.has(target_id):
		return _reject_snapshot("ball target reference is invalid")
	var saved_ball_position := _vector3_from_array(state["ball_position_3d"])
	var saved_ball_velocity := _vector3_from_array(state["ball_velocity_3d"])
	if bool(state["ball_in_flight"]) != (str(state["ball_flight_phase"]) != "none") \
	or absf(float(state["ball_position"][0]) - saved_ball_position.x) > 0.001 \
	or absf(float(state["ball_position"][1]) - saved_ball_position.y) > 0.001 \
	or absf(float(state["ball_velocity"][0]) - saved_ball_velocity.x) > 0.001 \
	or absf(float(state["ball_velocity"][1]) - saved_ball_velocity.y) > 0.001:
		return _reject_snapshot("2D ball projection disagrees with 3D flight state")
	if saved_ball_position.z < 0.0 or bool(state["ball_in_flight"]) and owner_id != NO_PLAYER_ID \
	or str(state["ball_flight_phase"]) == "ground_pass" and (target_id == NO_PLAYER_ID or int(state["ball_shooter_id"]) == NO_PLAYER_ID) \
	or str(state["ball_flight_phase"]) in ["shot", "rebound"] and int(state["ball_shooter_id"]) == NO_PLAYER_ID \
	or int(state["ball_shooter_id"]) != NO_PLAYER_ID and not on_pitch_ids.has(int(state["ball_shooter_id"])) \
	or float(state["ball_pass_probability"]) < -1.0 or float(state["ball_pass_probability"]) > 1.0:
		return _reject_snapshot("ball flight state is internally inconsistent")
	if typeof(state["restart_kind"]) != TYPE_STRING or not [
		RESTART_IN_PLAY, RESTART_KICKOFF, RESTART_THROW_IN, RESTART_CORNER,
		RESTART_GOAL_KICK, RESTART_FULL_TIME
	].has(str(state["restart_kind"])):
		return _reject_snapshot("restart kind is invalid")
	if typeof(state["restart_pending"]) != TYPE_BOOL \
	or not _is_int_value(state["restart_awarded_team"]) \
	or not _is_int_value(state["restart_taker_id"]) \
	or not _is_int_value(state["restart_receiver_id"]) \
	or not _is_int_value(state["last_touch_team_index"]) \
	or not _is_int_value(state["last_touch_player_id"]) \
	or not _is_vector_data(state["restart_position"]) \
	or not _is_vector_data(state["restart_crossing_position"]):
		return _reject_snapshot("restart or last-touch metadata has an invalid type")
	var saved_restart_kind := str(state["restart_kind"])
	if bool(state["restart_pending"]):
		var awarded_team := int(state["restart_awarded_team"])
		var taker_id := int(state["restart_taker_id"])
		var receiver_id := int(state["restart_receiver_id"])
		if [RESTART_IN_PLAY, RESTART_FULL_TIME].has(saved_restart_kind) \
		or not [0, 1].has(awarded_team) \
		or taker_id == receiver_id or not on_pitch_ids.has(taker_id) \
		or not on_pitch_ids.has(receiver_id) \
		or all_player_ids[taker_id] != awarded_team or all_player_ids[receiver_id] != awarded_team \
		or owner_id != NO_PLAYER_ID or target_id != NO_PLAYER_ID \
		or _vector_from_array(state["ball_position"]).distance_to(
			_vector_from_array(state["restart_position"])
		) > 0.01 \
		or _vector_from_array(state["ball_velocity"]).length() > 0.001:
			return _reject_snapshot("pending restart references are inconsistent")
		if saved_restart_kind == RESTART_KICKOFF and awarded_team != int(state["next_kickoff_team"]):
			return _reject_snapshot("pending kickoff team disagrees with next_kickoff_team")
		if not Rect2(
			Vector2.ZERO,
			Vector2(float(config["field"]["width"]), float(config["field"]["height"]))
		).has_point(_vector_from_array(state["restart_position"])):
			return _reject_snapshot("pending restart position is outside the pitch")
		var radius := float(config["field"]["ball_radius"])
		var crossing_position := _vector_from_array(state["restart_crossing_position"])
		if crossing_position.x < -radius \
		or crossing_position.x > float(config["field"]["width"]) + radius \
		or crossing_position.y < -radius \
		or crossing_position.y > float(config["field"]["height"]) + radius:
			return _reject_snapshot("restart crossing position is outside boundary bounds")
	elif not [RESTART_IN_PLAY, RESTART_FULL_TIME].has(saved_restart_kind) \
	or int(state["restart_awarded_team"]) != -1 \
	or int(state["restart_taker_id"]) != NO_PLAYER_ID \
	or int(state["restart_receiver_id"]) != NO_PLAYER_ID \
	or float(state["restart_delay_remaining"]) != 0.0:
		return _reject_snapshot("inactive restart metadata is inconsistent")
	if saved_restart_kind == RESTART_FULL_TIME and not bool(state["finished"]):
		return _reject_snapshot("full-time restart state is not finished")
	var touch_team := int(state["last_touch_team_index"])
	var touch_player := int(state["last_touch_player_id"])
	if touch_team == -1:
		if touch_player != NO_PLAYER_ID:
			return _reject_snapshot("last-touch player exists without a team")
	elif not [0, 1].has(touch_team) or not all_player_ids.has(touch_player) \
	or int(all_player_ids[touch_player]) != touch_team:
		return _reject_snapshot("last-touch player does not belong to the recorded team")
	if target_id != NO_PLAYER_ID and (
		touch_team < 0 or int(all_player_ids[target_id]) != touch_team
	):
		return _reject_snapshot("in-flight ball target and last touch belong to different teams")
	if bool(state["finished"]) and saved_restart_kind != RESTART_FULL_TIME:
		return _reject_snapshot("finished match is missing full-time restart state")
	if int(state["rng_seed"]) != int(config["seed"]):
		return _reject_snapshot("RNG seed does not match the match configuration")
	return true

func restore_snapshot(snapshot: Dictionary) -> bool:
	if not validate_snapshot(snapshot):
		push_warning("Snapshot rejected: " + last_snapshot_error)
		return false
	var state: Dictionary = snapshot["state"]
	for team_index in range(teams.size()):
		var team: FootballTeam = teams[team_index]
		var team_state: Dictionary = state["teams"][team_index]
		var all_players: Dictionary = {}
		for player in team.players:
			all_players[player.id] = player
		for player in team.bench:
			all_players[player.id] = player
		var restored_players: Array[FootballPlayer] = []
		var restored_bench: Array[FootballPlayer] = []
		for player_data in team_state["players"]:
			var player_id := int(player_data["id"])
			var player: FootballPlayer = all_players[player_id]
			_restore_player_data(player, player_data)
			restored_players.append(player)
		for player_data in team_state["bench"]:
			var player_id := int(player_data["id"])
			var player: FootballPlayer = all_players[player_id]
			_restore_player_data(player, player_data)
			restored_bench.append(player)
		team.players = restored_players
		team.bench = restored_bench
		team.formation = str(team_state["formation"])
		team.mentality = str(team_state["mentality"])
		team.game_plan = str(team_state["game_plan"])
		team.instructions = team_state["instructions"].duplicate(true)
		team.completed_passes_in_possession = int(team_state.get("completed_passes_in_possession", 0))
		team.substitutions_used = int(team_state["substitutions_used"])
		team.tactical_points = float(team_state["tactical_points"])
		team.tactical_point_clock = float(team_state["tactical_point_clock"])
		team.instruction_cooldown = float(team_state["instruction_cooldown"])
		team.score = int(team_state["score"])
		team.is_home = bool(team_state["is_home"])
		team.attacks_right = bool(team_state["attacks_right"])
		team.change_cooldown = float(team_state["change_cooldown"])
	tick_count = int(state["tick_count"])
	elapsed_seconds = float(state["elapsed_seconds"])
	accumulator = float(state["accumulator"])
	decision_clock = float(state["decision_clock"])
	restart_delay_remaining = float(state["restart_delay_remaining"])
	next_kickoff_team = int(state["next_kickoff_team"])
	half_index = int(state["half_index"])
	restart_kind = str(state["restart_kind"])
	restart_pending = bool(state["restart_pending"])
	restart_awarded_team = int(state["restart_awarded_team"])
	restart_position = _vector_from_array(state["restart_position"])
	restart_crossing_position = _vector_from_array(state["restart_crossing_position"])
	restart_taker_id = int(state["restart_taker_id"])
	restart_receiver_id = int(state["restart_receiver_id"])
	last_touch_team_index = int(state["last_touch_team_index"])
	last_touch_player_id = int(state["last_touch_player_id"])
	ai_reaction_clock = float(state["ai_reaction_clock"])
	event_log.clear()
	for event in state["event_log"]:
		event_log.append(str(event))
	ball_position = _vector_from_array(state["ball_position"])
	ball_velocity = _vector_from_array(state["ball_velocity"])
	ball_position_3d = _vector3_from_array(state["ball_position_3d"])
	ball_velocity_3d = _vector3_from_array(state["ball_velocity_3d"])
	ball_in_flight = bool(state["ball_in_flight"])
	ball_on_ground = bool(state["ball_on_ground"])
	ball_flight_phase = str(state["ball_flight_phase"])
	ball_pass_probability = float(state["ball_pass_probability"])
	ball_shooter_id = int(state["ball_shooter_id"])
	ball_keeper_attempted = bool(state["ball_keeper_attempted"])
	ball_owner = _find_player_by_id(int(state["ball_owner_id"]))
	ball_target = _find_player_by_id(int(state["ball_target_id"]))
	last_action = str(state["last_action"])
	last_probability = float(state["last_probability"])
	last_formula = str(state["last_formula"])
	last_shot_on_target_probability = float(state["last_shot_on_target_probability"])
	last_goalkeeper_save_probability = float(state["last_goalkeeper_save_probability"])
	last_rebound_probability = float(state["last_rebound_probability"])
	preferred_pass_debug = str(state.get("preferred_pass_debug", "No pass target evaluated"))
	last_defensive_decision = str(state.get("last_defensive_decision", "No defensive decision yet"))
	last_jockey_log_key = str(state.get("last_jockey_log_key", ""))
	home_formation = str(state["home_formation"])
	rng.seed = int(state["rng_seed"])
	rng.state = int(state["rng_state"])
	active = bool(state["active"])
	finished = bool(state["finished"])
	_emit_state()
	return true

func _build_state_data(include_event_log: bool, include_presentation: bool) -> Dictionary:
	var team_data: Array[Dictionary] = []
	for team in teams:
		var players: Array[Dictionary] = []
		var bench: Array[Dictionary] = []
		for player in team.players:
			players.append(_player_state_data(player))
		for player in team.bench:
			bench.append(_player_state_data(player))
		team_data.append({
			"formation": team.formation,
			"mentality": team.mentality,
			"game_plan": team.game_plan,
			"instructions": team.instructions.duplicate(true),
			"completed_passes_in_possession": team.completed_passes_in_possession,
			"substitutions_used": team.substitutions_used,
			"tactical_points": team.tactical_points,
			"tactical_point_clock": team.tactical_point_clock,
			"instruction_cooldown": team.instruction_cooldown,
			"score": team.score,
			"is_home": team.is_home,
			"attacks_right": team.attacks_right,
			"change_cooldown": team.change_cooldown,
			"players": players,
			"bench": bench
		})
	var state_data := {
		"tick_count": tick_count,
		"elapsed_seconds": elapsed_seconds,
		"accumulator": accumulator,
		"decision_clock": decision_clock,
		"restart_delay_remaining": restart_delay_remaining,
		"next_kickoff_team": next_kickoff_team,
		"half_index": half_index,
		"restart_kind": restart_kind,
		"restart_pending": restart_pending,
		"restart_awarded_team": restart_awarded_team,
		"restart_position": _vector_to_array(restart_position),
		"restart_crossing_position": _vector_to_array(restart_crossing_position),
		"restart_taker_id": restart_taker_id,
		"restart_receiver_id": restart_receiver_id,
		"last_touch_team_index": last_touch_team_index,
		"last_touch_player_id": last_touch_player_id,
		"ai_reaction_clock": ai_reaction_clock,
		"ball_position": _vector_to_array(ball_position),
		"ball_velocity": _vector_to_array(ball_velocity),
		"ball_position_3d": _vector3_to_array(ball_position_3d),
		"ball_velocity_3d": _vector3_to_array(ball_velocity_3d),
		"ball_in_flight": ball_in_flight,
		"ball_on_ground": ball_on_ground,
		"ball_flight_phase": ball_flight_phase,
		"ball_pass_probability": ball_pass_probability,
		"ball_shooter_id": ball_shooter_id,
		"ball_keeper_attempted": ball_keeper_attempted,
		"ball_owner_id": _player_id_or_sentinel(ball_owner),
		"ball_target_id": _player_id_or_sentinel(ball_target),
		"rng_seed": rng.seed,
		"rng_state": rng.state,
		"active": active,
		"finished": finished,
		"teams": team_data
	}
	if include_event_log:
		state_data["event_log"] = event_log.duplicate()
	if include_presentation:
		state_data.merge({
			"last_action": last_action,
			"last_probability": last_probability,
			"last_formula": last_formula,
			"last_shot_on_target_probability": last_shot_on_target_probability,
			"last_goalkeeper_save_probability": last_goalkeeper_save_probability,
			"last_rebound_probability": last_rebound_probability,
			"preferred_pass_debug": preferred_pass_debug,
			"last_defensive_decision": last_defensive_decision,
			"last_jockey_log_key": last_jockey_log_key,
			"home_formation": home_formation
		})
	return state_data

func _player_state_data(player: FootballPlayer) -> Dictionary:
	return {
		"id": player.id,
		"player_name": player.player_name,
		"number": player.number,
		"role": player.role,
		"natural_role": player.natural_role,
		"tactical_role": player.tactical_role,
		"attributes": player.attributes.duplicate(true),
		"form": player.form,
		"fatigue": player.fatigue,
		"stamina": player.stamina,
		"tackle_cooldown": player.tackle_cooldown,
		"shot_cooldown_active": player.shot_cooldown_active,
		"shot_cooldown_opposition_ticks": player.shot_cooldown_opposition_ticks,
		"box_run_active": player.box_run_active,
		"box_run_target": _vector_to_array(player.box_run_target),
		"box_run_suppressed": player.box_run_suppressed,
		"carry_distance": player.carry_distance,
		"position": _vector_to_array(player.position),
		"tactical_position": _vector_to_array(player.tactical_position),
		"team_index": player.team_index,
		"on_pitch": player.on_pitch
	}

func _restore_player_data(player: FootballPlayer, data: Dictionary) -> void:
	player.player_name = str(data["player_name"])
	player.number = int(data["number"])
	player.role = str(data["role"])
	player.natural_role = str(data["natural_role"])
	player.tactical_role = str(data["tactical_role"])
	player.attributes = data["attributes"].duplicate(true)
	player.form = float(data["form"])
	player.fatigue = float(data["fatigue"])
	player.stamina = float(data["stamina"])
	player.tackle_cooldown = float(data["tackle_cooldown"])
	player.shot_cooldown_active = bool(data["shot_cooldown_active"])
	player.shot_cooldown_opposition_ticks = int(data["shot_cooldown_opposition_ticks"])
	player.box_run_active = bool(data["box_run_active"])
	player.box_run_target = _vector_from_array(data["box_run_target"])
	player.box_run_suppressed = bool(data["box_run_suppressed"])
	player.carry_distance = float(data["carry_distance"])
	player.position = _vector_from_array(data["position"])
	player.tactical_position = _vector_from_array(data["tactical_position"])
	player.team_index = int(data["team_index"])
	player.on_pitch = bool(data["on_pitch"])

func _reject_snapshot(reason: String) -> bool:
	last_snapshot_error = reason
	return false

func _is_int_value(value: Variant) -> bool:
	return typeof(value) == TYPE_INT

func _is_finite_number(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value))

func _is_vector_data(value: Variant) -> bool:
	if not value is Array or value.size() != 2:
		return false
	return _is_finite_number(value[0]) and _is_finite_number(value[1]) \
		and absf(float(value[0])) <= 10000.0 and absf(float(value[1])) <= 10000.0

func _validate_snapshot_player(
	player_data: Variant,
	expected_players: Dictionary,
	team_index: int,
	should_be_on_pitch: bool
) -> bool:
	if not player_data is Dictionary:
		return false
	var required_keys: Array[String] = [
		"id", "player_name", "number", "role", "natural_role", "tactical_role", "attributes",
		"form", "fatigue", "stamina", "tackle_cooldown", "shot_cooldown_active",
		"shot_cooldown_opposition_ticks", "box_run_active", "box_run_target",
		"box_run_suppressed", "carry_distance", "position", "tactical_position",
		"team_index", "on_pitch"
	]
	for key in required_keys:
		if not player_data.has(key):
			return false
	if not _is_int_value(player_data["id"]) or not expected_players.has(int(player_data["id"])):
		return false
	var expected_player: FootballPlayer = expected_players[int(player_data["id"])]
	if typeof(player_data["player_name"]) != TYPE_STRING \
	or str(player_data["player_name"]) != expected_player.player_name \
	or not _is_int_value(player_data["number"]) or int(player_data["number"]) != expected_player.number \
	or typeof(player_data["natural_role"]) != TYPE_STRING \
	or str(player_data["natural_role"]) != expected_player.natural_role \
	or not player_data["attributes"] is Dictionary \
	or player_data["attributes"] != expected_player.attributes \
	or not _is_int_value(player_data["team_index"]) or int(player_data["team_index"]) != team_index \
	or typeof(player_data["on_pitch"]) != TYPE_BOOL or bool(player_data["on_pitch"]) != should_be_on_pitch:
		return false
	for key in ["role", "tactical_role"]:
		if typeof(player_data[key]) != TYPE_STRING or not _is_known_role(str(player_data[key])):
			return false
	if (str(player_data["role"]) == "GK") != (expected_player.natural_role == "GK"):
		return false
	if str(player_data["role"]) == "GK" and str(player_data["tactical_role"]) != "GK":
		return false
	for key in [
		"form", "fatigue", "stamina", "tackle_cooldown", "carry_distance"
	]:
		if not _is_finite_number(player_data[key]):
			return false
	if float(player_data["form"]) < -1.0 or float(player_data["form"]) > 1.0 \
	or float(player_data["fatigue"]) < 0.0 or float(player_data["fatigue"]) > 1.0 \
	or float(player_data["stamina"]) < 0.0 \
	or float(player_data["stamina"]) > expected_player.get_attribute("stamina") \
	or float(player_data["tackle_cooldown"]) < 0.0 \
	or float(player_data["carry_distance"]) < 0.0:
		return false
	if typeof(player_data["shot_cooldown_active"]) != TYPE_BOOL \
	or not _is_int_value(player_data["shot_cooldown_opposition_ticks"]) \
	or int(player_data["shot_cooldown_opposition_ticks"]) < 0 \
	or int(player_data["shot_cooldown_opposition_ticks"]) > int(config["match"]["shot_cooldown_opposition_ticks"]) \
	or typeof(player_data["box_run_active"]) != TYPE_BOOL \
	or typeof(player_data["box_run_suppressed"]) != TYPE_BOOL:
		return false
	return _is_vector_data(player_data["position"]) \
		and _is_vector_data(player_data["tactical_position"]) \
		and _is_vector_data(player_data["box_run_target"])

func _is_known_role(role: String) -> bool:
	for formation_data in config["formations"].values():
		for slot in formation_data:
			if str(slot["role"]) == role:
				return true
	for team_data in config["teams"]:
		for roster_key in ["players", "bench"]:
			for player_data in team_data.get(roster_key, []):
				if str(player_data["role"]) == role:
					return true
	return false

func _vector_to_array(value: Vector2) -> Array[float]:
	return [value.x, value.y]

func _vector_from_array(value: Array) -> Vector2:
	if value.size() != 2:
		return Vector2.ZERO
	return Vector2(float(value[0]), float(value[1]))

func _vector3_to_array(value: Vector3) -> Array[float]:
	return [value.x, value.y, value.z]

func _vector3_from_array(value: Array) -> Vector3:
	if value.size() != 3:
		return Vector3.ZERO
	return Vector3(float(value[0]), float(value[1]), float(value[2]))

func _is_vector3_data(value: Variant) -> bool:
	return value is Array and value.size() == 3 and _is_finite_number(value[0]) \
		and _is_finite_number(value[1]) and _is_finite_number(value[2])

func _player_id_or_sentinel(player: FootballPlayer) -> int:
	return player.id if player != null else -1

func _find_player_by_id(player_id: int) -> FootballPlayer:
	if player_id < 0:
		return null
	for team in teams:
		for player in team.players:
			if player.id == player_id:
				return player
		for player in team.bench:
			if player.id == player_id:
				return player
	return null

func validate_manager_command(team_index: int, kind: String, value: String = "", player_id: int = -1) -> bool:
	if finished or team_index < 0 or team_index >= teams.size() or is_team_ai_controlled(team_index):
		return false
	var team: FootballTeam = teams[team_index]
	match kind:
		"mentality":
			return (
				config["probability"]["tactical_modifiers"]["mentality"].has(value)
				and team.mentality != value
				and (not active or team.change_cooldown <= 0.0)
			)
		"game_plan":
			return (
				config["probability"]["tactical_modifiers"]["game_plan"].has(value)
				and team.game_plan != value
				and (not active or team.change_cooldown <= 0.0)
			)
		"instruction":
			if not active:
				return false
			if team.has_instruction(value):
				return true
			var definitions: Dictionary = config["probability"]["instructions"]
			if not definitions.has(value) or team.instruction_cooldown > 0.0:
				return false
			var replacing_channel := (
				(value == "target_left_channel" and team.has_instruction("target_right_channel"))
				or (value == "target_right_channel" and team.has_instruction("target_left_channel"))
			)
			var active_slots := team.instructions.size() - (1 if replacing_channel else 0)
			return (
				active_slots < int(config["match"]["instruction_slots"])
				and team.tactical_points >= float(config["match"]["instruction_tactical_point_cost"])
			)
		"substitution":
			if not active or team.substitutions_used >= int(config["match"]["substitution_limit"]):
				return false
			if team.tactical_points < float(config["match"]["substitution_tactical_point_cost"]):
				return false
			var player_index := _player_index_by_id(team, player_id)
			if player_index < 0:
				return false
			var outgoing := team.players[player_index]
			var bench_index := _best_substitute_index(team, outgoing)
			if bench_index < 0:
				return false
			var incoming := team.bench[bench_index]
			return (outgoing.role == "GK") == (incoming.natural_role == "GK")
		_:
			return false

func apply_manager_command(team_index: int, kind: String, value: String = "", player_id: int = -1) -> bool:
	if not validate_manager_command(team_index, kind, value, player_id):
		return false
	match kind:
		"mentality":
			return change_mentality(value, team_index)
		"game_plan":
			return change_game_plan(value, team_index)
		"instruction":
			return activate_instruction(team_index, value)
		"substitution":
			return substitute_player(team_index, _player_index_by_id(teams[team_index], player_id))
		_:
			push_error("Unknown manager command: " + kind)
			return false

func setup_match(chosen_formation: String) -> bool:
	if config.is_empty():
		return false
	home_formation = chosen_formation
	ball_owner = null
	ball_target = null
	ball_position = Vector2.ZERO
	ball_position_3d = Vector3.ZERO
	ball_velocity = Vector2.ZERO
	ball_velocity_3d = Vector3.ZERO
	ball_in_flight = false
	ball_on_ground = true
	ball_flight_phase = "none"
	ball_pass_probability = -1.0
	ball_shooter_id = NO_PLAYER_ID
	ball_keeper_attempted = false
	teams.clear()
	for team_index in range(config["teams"].size()):
		var team_data: Dictionary = config["teams"][team_index]
		var team := TeamScript.new()
		team.team_name = str(team_data["name"])
		team.color = Color.from_string(str(team_data["color"]), Color.WHITE)
		team.formation = chosen_formation if team_index == 0 else str(team_data["formation"])
		team.is_home = team_index == 0
		team.attacks_right = team.is_home
		for player_data in team_data["players"]:
			team.players.append(_create_player(player_data, team_index))
		for player_data in team_data.get("bench", []):
			var substitute := _create_player(player_data, team_index)
			substitute.on_pitch = false
			team.bench.append(substitute)
		teams.append(team)
	if teams.size() != 2 or teams[0].players.size() != 11 or teams[1].players.size() != 11 or teams[0].bench.is_empty() or teams[1].bench.is_empty():
		push_error("Match setup requires two teams of eleven players and a non-empty bench.")
		return false
	_apply_formation(teams[0])
	_apply_formation(teams[1])
	_reset_match_state()
	return true

func start_match() -> void:
	if teams.size() != 2 or active:
		return
	active = true
	finished = false
	if restart_pending:
		_execute_pending_restart()
	_emit_state()

func change_mentality(value: String, team_index: int = 0) -> bool:
	if finished or team_index < 0 or team_index >= teams.size() or is_team_ai_controlled(team_index):
		return false
	if not config["probability"]["tactical_modifiers"]["mentality"].has(value):
		push_error("Unknown mentality: " + value)
		return false
	var cooldown := float(config["match"]["tactical_change_cooldown_seconds"]) if active else 0.0
	var changed := teams[team_index].set_mentality(value, cooldown)
	if changed:
		_emit_state()
	return changed

func change_game_plan(value: String, team_index: int = 0) -> bool:
	if finished or team_index < 0 or team_index >= teams.size() or is_team_ai_controlled(team_index):
		return false
	if not config["probability"]["tactical_modifiers"]["game_plan"].has(value):
		push_error("Unknown game plan: " + value)
		return false
	var cooldown := float(config["match"]["tactical_change_cooldown_seconds"]) if active else 0.0
	var changed := teams[team_index].set_game_plan(value, cooldown)
	if changed:
		_emit_state()
	return changed

func is_team_ai_controlled(team_index: int) -> bool:
	return team_index == 1 and bool(config["probability"]["ai"]["enabled"])

func substitute_player(team_index: int, outgoing_index: int, bench_index: int = -1) -> bool:
	if not active or finished or team_index < 0 or team_index >= teams.size() or is_team_ai_controlled(team_index):
		return false
	var team: FootballTeam = teams[team_index]
	if team.substitutions_used >= int(config["match"]["substitution_limit"]):
		return false
	var point_cost := float(config["match"]["substitution_tactical_point_cost"])
	if team.tactical_points < point_cost or outgoing_index < 0 or outgoing_index >= team.players.size():
		return false
	if bench_index < 0:
		bench_index = _best_substitute_index(team, team.players[outgoing_index])
	if bench_index < 0 or bench_index >= team.bench.size():
		return false
	var outgoing := team.players[outgoing_index]
	var incoming := team.bench[bench_index]
	if outgoing.role == "GK" and incoming.natural_role != "GK":
		return false
	if outgoing.role != "GK" and incoming.natural_role == "GK":
		return false
	team.tactical_points -= point_cost
	incoming.role = outgoing.role
	incoming.tactical_role = outgoing.tactical_role
	incoming.position = outgoing.position
	incoming.tactical_position = outgoing.tactical_position
	incoming.shot_cooldown_active = outgoing.shot_cooldown_active
	incoming.shot_cooldown_opposition_ticks = outgoing.shot_cooldown_opposition_ticks
	incoming.box_run_active = outgoing.box_run_active
	incoming.box_run_target = outgoing.box_run_target
	incoming.box_run_suppressed = outgoing.box_run_suppressed
	incoming.fatigue = outgoing.fatigue * float(config["match"]["substitution_fatigue_inheritance"])
	incoming.form = outgoing.form * float(config["match"]["substitution_form_inheritance"])
	incoming.on_pitch = true
	incoming.stamina = incoming.get_attribute("stamina") * (1.0 - incoming.fatigue)
	outgoing.role = outgoing.natural_role
	outgoing.tactical_role = outgoing.natural_role
	outgoing.shot_cooldown_active = false
	outgoing.shot_cooldown_opposition_ticks = 0
	outgoing.box_run_active = false
	outgoing.box_run_target = Vector2.ZERO
	outgoing.box_run_suppressed = false
	outgoing.on_pitch = false
	team.players[outgoing_index] = incoming
	team.bench[bench_index] = outgoing
	if ball_owner == outgoing:
		ball_owner = incoming
	if ball_target == outgoing:
		ball_target = incoming
	if ball_shooter_id == outgoing.id:
		ball_shooter_id = incoming.id
	if restart_pending:
		if restart_taker_id == outgoing.id:
			restart_taker_id = incoming.id
		if restart_receiver_id == outgoing.id:
			restart_receiver_id = incoming.id
	team.substitutions_used += 1
	var text := "%s substitutes %s for %s" % [team.team_name, incoming.player_name, outgoing.player_name]
	event_log.append(text)
	print("[Match] " + text)
	substitution_made.emit(team.team_name, outgoing.player_name, incoming.player_name)
	_emit_state()
	return true

func activate_instruction(team_index: int, instruction_id: String) -> bool:
	if not active or finished or team_index < 0 or team_index >= teams.size() or is_team_ai_controlled(team_index):
		return false
	var team: FootballTeam = teams[team_index]
	if team.has_instruction(instruction_id):
		var remaining_instructions: Array[Dictionary] = []
		for entry in team.instructions:
			if str(entry["id"]) != instruction_id:
				remaining_instructions.append(entry)
		team.instructions = remaining_instructions
		event_log.append("%s cancels %s" % [team.team_name, instruction_id])
		_emit_state()
		return true
	var definitions: Dictionary = config["probability"]["instructions"]
	if not definitions.has(instruction_id):
		return false
	var replaced_channel := ""
	if instruction_id == "target_left_channel" and team.has_instruction("target_right_channel"):
		replaced_channel = "target_right_channel"
	elif instruction_id == "target_right_channel" and team.has_instruction("target_left_channel"):
		replaced_channel = "target_left_channel"
	var active_slots := team.instructions.size() - (1 if not replaced_channel.is_empty() else 0)
	if active_slots >= int(config["match"]["instruction_slots"]):
		return false
	var point_cost := float(config["match"]["instruction_tactical_point_cost"])
	if team.tactical_points < point_cost or team.instruction_cooldown > 0.0:
		return false
	team.tactical_points -= point_cost
	team.instruction_cooldown = float(config["match"]["instruction_cooldown_seconds"])
	if not replaced_channel.is_empty():
		var remaining_instructions: Array[Dictionary] = []
		for entry in team.instructions:
			if str(entry["id"]) != replaced_channel:
				remaining_instructions.append(entry)
		team.instructions = remaining_instructions
	team.instructions.append({
		"id": instruction_id,
		"remaining": float(config["thresholds"]["instruction_duration_seconds"])
	})
	event_log.append("%s activates %s" % [team.team_name, instruction_id])
	_emit_state()
	return true

func _create_player(player_data: Dictionary, team_index: int) -> FootballPlayer:
	var player := PlayerScript.new()
	player.id = team_index * 100 + int(player_data["number"])
	player.player_name = str(player_data["name"])
	player.number = int(player_data["number"])
	player.role = str(player_data["role"])
	player.natural_role = player.role
	player.tactical_role = player.role
	player.attributes = (config["player_templates"][str(player_data["template"])] as Dictionary).duplicate(true)
	player.stamina = player.get_attribute("stamina")
	player.team_index = team_index
	return player

func _best_substitute_index(team: FootballTeam, outgoing: FootballPlayer) -> int:
	var preferred_template_role := "GK" if outgoing.role == "GK" else ("DEF" if ["LB", "RB", "CB"].has(outgoing.role) else ("ATT" if ["LW", "RW", "ST"].has(outgoing.role) else "MID"))
	var best_index := -1
	var best_score := -INF
	for index in range(team.bench.size()):
		var candidate := team.bench[index]
		if candidate.natural_role != preferred_template_role:
			continue
		var selection: Dictionary = config["probability"]["manager_tools"]["substitution_selection"]
		var score := candidate.get_attribute("stamina") * float(selection["stamina_weight"])
		score += candidate.get_attribute("pace") * float(selection["pace_weight"])
		score -= candidate.fatigue * float(selection["fatigue_penalty"])
		if preferred_template_role == "GK":
			score = candidate.get_attribute("reflexes") * float(selection["goalkeeper_reflexes_weight"])
			score += candidate.get_attribute("positioning") * float(selection["goalkeeper_positioning_weight"])
			score -= candidate.fatigue * float(selection["fatigue_penalty"])
		if score > best_score:
			best_index = index
			best_score = score
	return best_index

func _player_index_by_id(team: FootballTeam, player_id: int) -> int:
	for index in range(team.players.size()):
		if team.players[index].id == player_id:
			return index
	return -1

func has_player_id_in_team(team_index: int, player_id: int) -> bool:
	if team_index < 0 or team_index >= teams.size():
		return false
	var team: FootballTeam = teams[team_index]
	for player in team.players + team.bench:
		if player.id == player_id:
			return true
	return false

func cycle_selected_player(team_index: int = 0) -> void:
	if teams.is_empty() or team_index < 0 or team_index >= teams.size():
		return
	selected_player_index = (selected_player_index + 1) % teams[team_index].players.size()
	_emit_state()

func get_selected_player(team_index: int = 0) -> FootballPlayer:
	if team_index < 0 or team_index >= teams.size() or teams[team_index].players.is_empty():
		return null
	return teams[team_index].players[selected_player_index % teams[team_index].players.size()]

func _reset_match_state() -> void:
	rng.seed = int(config.get("seed", 1))
	for team in teams:
		team.score = 0
		team.completed_passes_in_possession = 0
		team.mentality = "Balanced"
		team.game_plan = "Possession"
		team.change_cooldown = 0.0
		team.instructions.clear()
		team.substitutions_used = 0
		team.tactical_points = float(config["match"]["tactical_points_maximum"])
		team.tactical_point_clock = 0.0
		team.instruction_cooldown = 0.0
		team.attacks_right = team.is_home
		for player in team.players + team.bench:
			player.tackle_cooldown = 0.0
			player.shot_cooldown_active = false
			player.shot_cooldown_opposition_ticks = 0
			player.box_run_active = false
			player.box_run_target = Vector2.ZERO
			player.box_run_suppressed = false
			player.carry_distance = 0.0
	elapsed_seconds = 0.0
	tick_count = 0
	accumulator = 0.0
	decision_clock = 0.0
	restart_delay_remaining = 0.0
	next_kickoff_team = int(config["match"]["initial_kickoff_team_index"])
	half_index = 0
	restart_kind = RESTART_KICKOFF
	restart_pending = false
	restart_awarded_team = -1
	restart_position = Vector2.ZERO
	restart_crossing_position = Vector2.ZERO
	restart_taker_id = NO_PLAYER_ID
	restart_receiver_id = NO_PLAYER_ID
	last_touch_team_index = -1
	last_touch_player_id = NO_PLAYER_ID
	ai_reaction_clock = 0.0
	event_log.clear()
	box_run_logged_player_keys.clear()
	ball_velocity = Vector2.ZERO
	ball_target = null
	ball_owner = null
	active = false
	finished = false
	_begin_restart(
		RESTART_KICKOFF,
		next_kickoff_team,
		Vector2(float(config["field"]["width"]) * 0.5, float(config["field"]["height"]) * 0.5),
		0.0
	)
	selected_player_index = 0
	last_shot_on_target_probability = -1.0
	last_goalkeeper_save_probability = -1.0
	last_rebound_probability = -1.0
	last_defensive_decision = "No defensive decision yet"
	last_jockey_log_key = ""
	last_action = "Ready to kick off"
	last_probability = 0.0
	last_formula = "No action resolved"
	externally_ticked = false

func _tick(seconds: float) -> void:
	elapsed_seconds += seconds
	var half_duration := float(config["match"]["half_duration_seconds"])
	if half_index == 0 and elapsed_seconds >= half_duration:
		_start_second_half()
		_emit_state()
		return
	if elapsed_seconds >= half_duration * 2.0:
		_finish_full_time()
		_emit_state()
		return
	if restart_pending:
		restart_delay_remaining = maxf(0.0, restart_delay_remaining - seconds)
		if restart_delay_remaining <= 0.0:
			_execute_pending_restart()
		_emit_state()
		return
	decision_clock += seconds
	ai_reaction_clock += seconds
	_tick_shot_cooldowns()
	for team in teams:
		team.tick_cooldown(seconds)
		team.tactical_point_clock += seconds
		var regen_interval := float(config["thresholds"]["tactical_point_regen_interval_seconds"])
		while team.tactical_point_clock >= regen_interval:
			team.tactical_point_clock -= regen_interval
			team.tactical_points = minf(team.tactical_points + float(config["match"]["tactical_points_regen_per_minute"]), float(config["match"]["tactical_points_maximum"]))
		_update_tactical_positions(team)
		var pressured_carrier: FootballPlayer
		if ball_owner != null and ball_owner.team_index == team.players[0].team_index:
			var nearest_defender := _nearest_opponent_to_position(ball_owner.position, teams[1 - ball_owner.team_index])
			if nearest_defender != null and nearest_defender.position.distance_to(ball_owner.position) <= float(config["match"]["tackle_decision"]["pressure_pass_distance"]):
				pressured_carrier = ball_owner
		for player in team.players:
			player.apply_condition(seconds, float(config["match"]["condition_fatigue_per_second"]))
			player.tackle_cooldown = maxf(0.0, player.tackle_cooldown - seconds)
			var movement_speed := float(config["match"]["player_move_speed"])
			if pressured_carrier != null and player != pressured_carrier:
				var movement_data: Dictionary = config["match"]["tackle_decision"]
				var support_rank := _support_rank(
					player,
					pressured_carrier,
					team,
					float(config["probability"]["movement"]["ball_support_radius"])
				)
				if support_rank < int(movement_data["pressure_fast_outlet_count"]):
					movement_speed *= float(movement_data["pressure_support_speed_multiplier"])
			if player != ball_owner or not player.box_run_active:
				player.position = player.position.move_toward(
					player.tactical_position,
					movement_speed * seconds
				)
		for player in team.bench:
			player.tackle_cooldown = maxf(0.0, player.tackle_cooldown - seconds)
	if ball_owner != null:
		var attack_direction := 1.0 if teams[ball_owner.team_index].attacks_right else -1.0
		var carry_target := ball_owner.tactical_position
		if not ball_owner.box_run_active:
			carry_target += Vector2(attack_direction * float(config["match"]["carry_advance_distance"]), 0.0)
		var boundary_margin := float(config["match"]["player_boundary_margin"])
		carry_target.x = clampf(carry_target.x, boundary_margin, float(config["field"]["width"]) - boundary_margin)
		var previous_position := ball_owner.position
		ball_owner.position = ball_owner.position.move_toward(
			carry_target,
			float(config["match"]["carry_speed"]) * seconds
		)
		ball_owner.carry_distance += maxf(0.0, (ball_owner.position.x - previous_position.x) * attack_direction)
		ball_position = ball_owner.position
		ball_position_3d = Vector3(ball_position.x, ball_position.y, float(config["match"]["ball_flight"]["ball_radius_px"]))
	for team in teams:
		for player in team.players:
			var progress_interval := maxi(1, int(config["match"]["box_runs"]["progress_log_interval_ticks"]))
			if player.box_run_active and tick_count % progress_interval == 0:
				_log_box_run_progress(team, player)
	var ball_was_in_flight := ball_in_flight
	_advance_ball(seconds)
	var just_received_ball := ball_was_in_flight and ball_owner != null
	if just_received_ball:
		decision_clock = 0.0
	if decision_clock >= float(config["match"]["decision_interval_seconds"]) and not just_received_ball:
		decision_clock = 0.0
		_resolve_next_action()
	if half_index == 0 and elapsed_seconds >= float(config["match"]["half_duration_seconds"]):
		_start_second_half()
	if ai_reaction_clock >= float(config["probability"]["ai"]["reaction_cooldown_seconds"]):
		ai_reaction_clock = 0.0
		_update_ai_manager()
	if elapsed_seconds >= float(config["match"]["half_duration_seconds"]) * 2.0:
		_finish_full_time()
	_emit_state()

func _start_second_half() -> void:
	half_index = 1
	for team in teams:
		team.attacks_right = not team.attacks_right
	next_kickoff_team = int(config["match"]["halftime_restart_team_index"])
	restart_pending = false
	_begin_restart(
		RESTART_KICKOFF,
		next_kickoff_team,
		Vector2(float(config["field"]["width"]) * 0.5, float(config["field"]["height"]) * 0.5),
		0.0
	)
	_execute_pending_restart()
	decision_clock = 0.0
	event_log.append("HALFTIME: teams switch ends")
	halftime_started.emit()
	print("[Match] HALFTIME: teams switch ends")

func _finish_full_time() -> void:
	if finished:
		return
	active = false
	finished = true
	restart_kind = RESTART_FULL_TIME
	restart_pending = false
	restart_awarded_team = -1
	restart_taker_id = NO_PLAYER_ID
	restart_receiver_id = NO_PLAYER_ID
	restart_delay_remaining = 0.0
	restart_crossing_position = Vector2.ZERO
	ball_owner = null
	ball_target = null
	ball_velocity = Vector2.ZERO
	ball_velocity_3d = Vector3.ZERO
	ball_in_flight = false
	ball_on_ground = true
	ball_flight_phase = "none"
	ball_pass_probability = -1.0
	ball_shooter_id = NO_PLAYER_ID
	ball_keeper_attempted = false
	last_action = "Full time"
	event_log.append("Full time")
	match_finished.emit(teams[0].score, teams[1].score)

func _update_ai_manager() -> void:
	if restart_pending or not bool(config["probability"]["ai"]["enabled"]) or teams.size() < 2:
		return
	var ai_team: FootballTeam = teams[1]
	var ai_data: Dictionary = config["probability"]["ai"]
	var losing_by := teams[0].score - ai_team.score
	var late_seconds := float(config["match"]["half_duration_seconds"]) * 2.0 - elapsed_seconds
	var desired_mentality := ai_team.mentality
	var desired_plan := ai_team.game_plan
	if losing_by >= int(ai_data["losing_by_goals"]):
		desired_mentality = str(ai_data["attacking_mentality"])
	elif late_seconds <= float(ai_data["defensive_late_match_seconds"]) and losing_by < 0:
		desired_mentality = str(ai_data["defensive_mentality"])
		desired_plan = str(ai_data["defensive_game_plan"])
	if desired_mentality != ai_team.mentality and ai_team.can_change_tactics():
		ai_team.set_mentality(desired_mentality, float(config["match"]["tactical_change_cooldown_seconds"]))
		event_log.append("AI changes mentality to %s" % desired_mentality)
	if desired_plan != ai_team.game_plan and ai_team.can_change_tactics():
		ai_team.set_game_plan(desired_plan, float(config["match"]["tactical_change_cooldown_seconds"]))
		event_log.append("AI changes game plan to %s" % desired_plan)

func _resolve_next_action() -> void:
	if restart_pending or finished or ball_in_flight:
		return
	if ball_target != null:
		return
	if ball_owner == null:
		var nearest := _nearest_player(ball_position)
		if nearest != null:
			_set_possession(nearest)
		return
	var owner_team: FootballTeam = teams[ball_owner.team_index]
	var opponent_team: FootballTeam = teams[1 - ball_owner.team_index]
	var defender := _nearest_opponent_to_ball(opponent_team)
	if defender != null and _resolve_tackle(defender):
		return
	if ball_owner == null:
		return
	if _should_shoot(ball_owner, owner_team):
		_resolve_shot(ball_owner, owner_team)
	else:
		_resolve_pass(ball_owner, owner_team)

func _resolve_pass(player: FootballPlayer, team: FootballTeam) -> void:
	if restart_pending or finished or ball_in_flight:
		return
	var receiver := _choose_receiver(player, team)
	if receiver == null:
		return
	var distance := player.position.distance_to(receiver.position)
	var tactical := _tactical_modifier(team, "pass")
	var range_modifier := -distance * float(config["probability"]["long_pass_distance_scale"])
	if team.game_plan == "Possession":
		range_modifier *= float(config["decision"]["possession_pass_range_factor"])
	if team.has_instruction("direct_long_balls"):
		range_modifier += float(config["probability"]["instructions"]["direct_long_balls"]["range_modifier"])
	range_modifier += _channel_pass_modifier(team, receiver)
	var attributes: Dictionary = config["probability"]["action_weights"]["pass"]
	ball_pass_probability = _calculate_probability(player, attributes, tactical + range_modifier)
	var formula := _formula_description(player, attributes, tactical + range_modifier)
	ball_owner = null
	ball_target = receiver
	ball_position = player.position
	ball_position_3d = Vector3(ball_position.x, ball_position.y, float(config["match"]["ball_flight"]["ball_radius_px"]))
	var direction := receiver.position - player.position
	if direction.length_squared() < 0.001:
		direction = Vector2.RIGHT
	var flat_direction := direction.normalized()
	ball_velocity_3d = Vector3(flat_direction.x, flat_direction.y, 0.0) * float(config["match"]["pass_ball_speed"])
	ball_velocity = Vector2(ball_velocity_3d.x, ball_velocity_3d.y)
	ball_in_flight = true
	ball_on_ground = true
	ball_flight_phase = "ground_pass"
	ball_shooter_id = player.id
	ball_keeper_attempted = false
	last_touch_team_index = player.team_index
	last_touch_player_id = player.id
	var launch_text := "[Ball] launch pass %s (#%d) -> %s (#%d), from (%.1f, %.1f), speed %.1f px/s, reception p=%.3f" % [player.player_name, player.id, receiver.player_name, receiver.id, ball_position.x, ball_position.y, ball_velocity_3d.length(), ball_pass_probability]
	event_log.append(launch_text)
	print(launch_text)
	_set_last_action("%s pass to %s in flight" % [player.player_name, receiver.player_name], ball_pass_probability, formula)

func _resolve_shot(player: FootballPlayer, team: FootballTeam) -> void:
	if restart_pending or finished or ball_in_flight:
		return
	var shooter_position := player.position
	if player.shot_cooldown_active:
		_log_shot_declined(player, "shot cooldown active", _attack_progress_x(shooter_position.x, team))
		return
	if player.box_run_active and not _box_run_shot_ready(player, team):
		return
	last_touch_team_index = player.team_index
	last_touch_player_id = player.id
	var shooter_attack_x := _attack_progress_x(shooter_position.x, team)
	if player.box_run_active:
		var run_distance := shooter_position.distance_to(player.box_run_target)
		print("[Shot] %s box-run shot at real-x=%.1f (remaining=%.1fpx)." % [player.player_name, shooter_position.x, run_distance])
	print("[Shot] %s decision at real-x=%.1f (attack %.3f, tactical-target-x=%.1f)." % [player.player_name, shooter_position.x, shooter_attack_x, player.tactical_position.x])
	player.shot_cooldown_active = true
	player.shot_cooldown_opposition_ticks = 0
	_clear_box_runs(team, true)
	_finish_pass_sequence(team, "shot")
	last_rebound_probability = -1.0
	var field_data: Dictionary = config["field"]
	var ball_data: Dictionary = config["match"]["ball_flight"]
	var goal_x := float(field_data["width"]) if team.attacks_right else 0.0
	var distance_to_goal := absf(goal_x - shooter_position.x)
	var attack_x := _attack_progress_x(shooter_position.x, team)
	var nearest_defender := _nearest_opponent_to_position(shooter_position, teams[1 - player.team_index])
	if nearest_defender == null:
		return
	var pressure_distance := nearest_defender.position.distance_to(shooter_position)
	var shot_context := _shot_context_breakdown(shooter_position, team, distance_to_goal, attack_x, pressure_distance)
	var modifier := float(shot_context["total"])
	var attributes: Dictionary = config["probability"]["action_weights"]["shot"]
	var shot_probability := _calculate_probability(player, attributes, modifier)
	last_shot_on_target_probability = shot_probability
	var shot_power := _weighted_attribute(player, config["probability"]["shot_power_attribute_weights"])
	var shot_placement := _weighted_attribute(player, config["probability"]["shot_placement_attribute_weights"])
	var on_target := rng.randf() < shot_probability
	player.record_action(on_target, float(config["match"]["condition_form_change_per_success"]))
	var goal_center_y := float(field_data["height"]) * 0.5
	var goal_half_width := float(ball_data["goal_width_px"]) * 0.5
	var aim_y := goal_center_y + (shooter_position.y - goal_center_y) * clampf(shot_placement, 0.0, 1.0) * 0.25
	if on_target:
		aim_y += float(rng.randi_range(-1, 1)) * goal_half_width * 0.48
	else:
		aim_y = goal_center_y + (1.0 if rng.randi_range(0, 1) == 0 else -1.0) * (goal_half_width + float(ball_data["ball_radius_px"]) * 3.0)
	var flat_direction := Vector2(goal_x - shooter_position.x, aim_y - shooter_position.y).normalized()
	var speed := lerpf(float(ball_data["shot_speed_min_px_s"]), float(ball_data["shot_speed_max_px_s"]), clampf((shot_power + player.get_attribute("finishing") / 100.0) * 0.5, 0.0, 1.0))
	ball_owner = null
	ball_target = null
	ball_position = shooter_position
	ball_position_3d = Vector3(shooter_position.x, shooter_position.y, float(ball_data["ball_radius_px"]))
	ball_velocity_3d = Vector3(flat_direction.x * speed, flat_direction.y * speed, float(ball_data["shot_vertical_speed_px_s"]))
	ball_velocity = Vector2(ball_velocity_3d.x, ball_velocity_3d.y)
	ball_in_flight = true
	ball_on_ground = false
	ball_flight_phase = "shot"
	ball_pass_probability = -1.0
	ball_shooter_id = player.id
	ball_keeper_attempted = false
	last_goalkeeper_save_probability = -1.0
	var launch_text := "[Ball] launch shot %s (#%d), from (%.1f, %.1f, %.1f) toward (%.1f, %.1f), speed %.1f px/s, vz %.1f px/s, aim=%s" % [player.player_name, player.id, ball_position_3d.x, ball_position_3d.y, ball_position_3d.z, goal_x, aim_y, ball_velocity_3d.length(), ball_velocity_3d.z, "inside" if on_target else "wide"]
	event_log.append(launch_text)
	print(launch_text)
	_set_last_action("%s %s shot in flight (%s; on-target model %.3f)" % [team.team_name, player.player_name, "on target" if on_target else "wide", shot_probability], shot_probability, _formula_description(player, attributes, modifier))
func _shot_context_breakdown(
	shooter_position: Vector2,
	team: FootballTeam,
	distance_to_goal: float,
	attack_x: float,
	pressure_distance: float
) -> Dictionary:
	var probability_data: Dictionary = config["probability"]
	var field_data: Dictionary = config["field"]
	var lateral_offset := absf(shooter_position.y - float(field_data["height"]) * 0.5)
	var angle_ratio := clampf(
		lateral_offset / maxf(distance_to_goal + float(field_data["goal_width"]) * 0.5, 1.0),
		0.0,
		1.0
	)
	var angle_penalty := -angle_ratio * float(probability_data["shot_angle_penalty"])
	var central_bonus := 0.0
	if lateral_offset < float(probability_data["central_shot_distance"]):
		central_bonus = float(probability_data["central_shot_bonus"])
	var preferred_bonus := 0.0
	if attack_x >= float(config["thresholds"]["shot_preferred_attack_x"]):
		preferred_bonus = float(probability_data["preferred_zone_shot_bonus"])
	var inside_penalty_area := _is_inside_position_shot_box(shooter_position, team, 0.0)
	var box_bonus := float(probability_data["shot_box_bonus"]) if inside_penalty_area else 0.0
	var pressure_factor := clampf(
		1.0 - pressure_distance / float(probability_data["shot_pressure_distance"]),
		0.0,
		1.0
	)
	var factors := {
		"base": float(probability_data["shot_base_modifier"]),
		"distance": -distance_to_goal * float(probability_data["shot_distance_scale"]),
		"angle": angle_penalty,
		"pressure": -pressure_factor * float(probability_data["shot_pressure_penalty"]),
		"central": central_bonus,
		"preferred": preferred_bonus,
		"box": box_bonus,
		"inside_box": inside_penalty_area,
		"tactical": _tactical_modifier(team, "shot"),
		"pressure_factor": pressure_factor
	}
	factors["total"] = float(factors["base"]) + float(factors["distance"]) \
		+ float(factors["angle"]) + float(factors["pressure"]) \
		+ float(factors["central"]) + float(factors["preferred"]) \
		+ float(factors["box"]) + float(factors["tactical"])
	return factors

func _shot_context_description(context: Dictionary) -> String:
	return "shot ctx [base %+.2f, distance %+.2f, angle %+.2f, pressure %+.2f, central %+.2f, preferred %+.2f, box %+.2f, tactical %+.2f = %+.2f]" % [
		float(context["base"]), float(context["distance"]), float(context["angle"]),
		float(context["pressure"]), float(context["central"]), float(context["preferred"]),
		float(context["box"]), float(context["tactical"]), float(context["total"])
	]

func _resolve_tackle(defender: FootballPlayer) -> bool:
	if restart_pending or finished:
		return false
	if ball_owner == null:
		return false
	var decision := _tackle_decision(defender, ball_owner)
	if not bool(decision["attempt"]):
		_log_jockey_decision(defender, ball_owner, str(decision["reason"]))
		if bool(decision["poor_position"]) or decision.has("cooldown_seconds"):
			var tackle_data: Dictionary = config["match"]["tackle_decision"]
			var cooldown_seconds := float(decision.get(
				"cooldown_seconds",
				tackle_data["poor_position_cooldown_seconds"]
			))
			defender.tackle_cooldown = maxf(
				defender.tackle_cooldown,
				cooldown_seconds
			)
		return false
	last_defensive_decision = "%s attempts tackle on %s (decision %.0f%%)" % [
		defender.player_name, ball_owner.player_name, float(decision["chance"]) * 100.0
	]
	print("[Defence] " + last_defensive_decision)
	var distance := defender.position.distance_to(ball_owner.position)
	var pressure_modifier := -distance * float(config["probability"]["tackle_pressure_scale"])
	if teams[defender.team_index].has_instruction("press_pivot") and ball_owner.number == int(config["probability"]["instructions"]["press_pivot"]["pivot_shirt_number"]):
		pressure_modifier += float(config["probability"]["instructions"]["press_pivot"]["tackle_modifier"])
	var tactical := _tactical_modifier(teams[defender.team_index], "tackle")
	var modifier := pressure_modifier + tactical
	var attributes: Dictionary = config["probability"]["action_weights"]["tackle"]
	var probability := _calculate_probability(defender, attributes, modifier)
	var formula := _formula_description(defender, attributes, modifier)
	var won_ball := rng.randf() < probability
	defender.record_action(won_ball, float(config["match"]["condition_form_change_per_success"]))
	if won_ball:
		last_defensive_decision = "%s tackles (%.0fpx, P %.2f)" % [defender.player_name, distance, probability]
	else:
		var tackle_data: Dictionary = config["match"]["tackle_decision"]
		defender.tackle_cooldown = float(tackle_data["failed_tackle_cooldown_seconds"])
		last_defensive_decision = "%s jockeys after failed tackle (%.1fs cooldown)" % [
			defender.player_name, defender.tackle_cooldown
		]
		print("[Defence] %s beaten; %s contains for %.1fs." % [
			defender.player_name, defender.player_name, defender.tackle_cooldown
		])
	_set_last_action("%s tackle by %s: %s" % [teams[defender.team_index].team_name, defender.player_name, "won" if won_ball else "beaten"], probability, formula)
	if won_ball:
		_set_possession(defender)
	return won_ball

func _tackle_decision(defender: FootballPlayer, carrier: FootballPlayer) -> Dictionary:
	var decision_data: Dictionary = config["match"]["tackle_decision"]
	var defender_team: FootballTeam = teams[defender.team_index]
	var distance := defender.position.distance_to(carrier.position)
	if distance > float(decision_data["jockey_distance"]):
		return {"attempt": false, "reason": "distance %.0fpx: hold shape" % distance, "poor_position": false}
	if distance > float(decision_data["maximum_attempt_distance"]):
		return {"attempt": false, "reason": "distance %.0fpx: jockey, outside tackle range" % distance, "poor_position": false}
	if defender.tackle_cooldown > 0.0:
		return {"attempt": false, "reason": "jockey cooldown %.1fs" % defender.tackle_cooldown, "poor_position": false}
	var stamina_percent := defender.stamina / maxf(defender.get_attribute("stamina"), 1.0) * 100.0
	if stamina_percent < float(decision_data["minimum_stamina_percent"]):
		return {"attempt": false, "reason": "low stamina %.0f%%" % stamina_percent, "poor_position": true}
	if defender.fatigue > float(decision_data["maximum_fatigue"]):
		return {"attempt": false, "reason": "fatigue %.0f%%" % (defender.fatigue * 100.0), "poor_position": true}

	var attack_sign := 1.0 if teams[carrier.team_index].attacks_right else -1.0
	var carrier_to_defender := (defender.position - carrier.position).normalized()
	var goalside_cosine := carrier_to_defender.x * -attack_sign
	var is_goalside := goalside_cosine >= float(decision_data["goalside_cosine"])
	var is_facing_defender := carrier_to_defender.x * attack_sign >= float(decision_data["facing_defender_cosine"])
	var is_committed := carrier.carry_distance >= float(decision_data["carrier_commitment_distance"])
	if not is_goalside and not is_committed:
		return {"attempt": false, "reason": "angle: not goalside (cos %.2f)" % goalside_cosine, "poor_position": true}
	if is_facing_defender and not is_committed:
		return {"attempt": false, "reason": "carrier facing defender", "poor_position": true}

	var carrier_team: FootballTeam = teams[carrier.team_index]
	var safe_outlet_count := _count_safe_outlets(carrier, carrier_team, decision_data)
	if safe_outlet_count >= int(decision_data["safe_outlet_required_count"]) and not is_committed:
		return {
			"attempt": false,
			"reason": "%d safe outlet(s): second thought and contain" % safe_outlet_count,
			"poor_position": true,
			"cooldown_seconds": float(decision_data["safe_outlet_delay_seconds"])
		}

	var chance := float(decision_data["base_attempt_chance"])
	chance += float(decision_data["mentality_attempt_modifiers"][defender_team.mentality])
	chance += float(decision_data["game_plan_attempt_modifiers"][defender_team.game_plan])
	chance += float(decision_data["role_attempt_modifiers"][_pass_role_profile(defender.tactical_role)])
	if defender_team.has_instruction("drop_compact"):
		chance += float(decision_data["compact_attempt_modifier"])
	if is_goalside:
		chance += float(decision_data["goalside_attempt_bonus"])
	else:
		chance -= float(decision_data["not_goalside_attempt_penalty"])
	if is_committed:
		chance += float(decision_data["committed_carrier_attempt_bonus"])
	if is_facing_defender:
		chance -= float(decision_data["facing_carrier_attempt_penalty"])
	if safe_outlet_count >= int(decision_data["safe_outlet_required_count"]):
		chance -= float(decision_data["safe_outlet_attempt_penalty"])
	var stamina_ratio := clampf(stamina_percent / 100.0, 0.0, 1.0)
	chance -= (1.0 - stamina_ratio) * float(decision_data["low_stamina_attempt_penalty"])
	var fatigue_ratio := clampf(defender.fatigue / maxf(float(decision_data["maximum_fatigue"]), 0.01), 0.0, 1.0)
	chance -= fatigue_ratio * float(decision_data["fatigue_attempt_penalty"])
	chance = clampf(
		chance,
		float(decision_data["minimum_attempt_chance"]),
		float(decision_data["maximum_attempt_chance"])
	)
	if rng.randf() >= chance:
		return {
			"attempt": false,
			"reason": "selective contain (attempt chance %.0f%%)" % (chance * 100.0),
			"poor_position": false,
			"chance": chance,
			"cooldown_seconds": float(decision_data["selective_jockey_delay_seconds"])
		}
	return {"attempt": true, "reason": "good tackle opportunity", "poor_position": false, "chance": chance}

func _count_safe_outlets(carrier: FootballPlayer, team: FootballTeam, decision_data: Dictionary) -> int:
	var safe_outlet_count := 0
	for candidate in team.players:
		if candidate == carrier or candidate.tactical_role == "GK":
			continue
		if candidate.position.distance_to(carrier.position) > float(decision_data["safe_outlet_distance"]):
			continue
		var nearest_defender := _nearest_opponent_to_position(candidate.position, teams[1 - carrier.team_index])
		if nearest_defender == null:
			continue
		if candidate.position.distance_to(nearest_defender.position) >= float(decision_data["safe_outlet_open_distance"]):
			safe_outlet_count += 1
	return safe_outlet_count

func _log_jockey_decision(defender: FootballPlayer, carrier: FootballPlayer, reason: String) -> void:
	last_defensive_decision = "%s jockeys/contains vs %s: %s" % [defender.player_name, carrier.player_name, reason]
	var reason_category := reason.get_slice(" ", 0)
	var key := "%d:%d:%s" % [defender.id, carrier.id, reason_category]
	if key == last_jockey_log_key:
		return
	last_jockey_log_key = key
	var text := "[Defence] %s; %s." % [last_defensive_decision, "force the safe outlet and delay"]
	event_log.append(text)
	print(text)

func _calculate_probability(player: FootballPlayer, weights: Dictionary, context_modifier: float) -> float:
	return _calculate_probability_with_slope(
		player, weights, context_modifier,
		float(config["probability"]["sigmoid_slope"]),
		float(config["match"]["minimum_probability"]),
		float(config["match"]["maximum_probability"])
	)

func _calculate_probability_with_slope(player: FootballPlayer, weights: Dictionary, context_modifier: float, slope: float, minimum: float, maximum: float) -> float:
	var weighted_attribute := _weighted_attribute(player, weights)
	var fatigue_penalty := player.fatigue * float(config["probability"]["fatigue_weight"])
	if player.fatigue >= float(config["thresholds"]["fatigue_breakpoint"]):
		fatigue_penalty += float(config["probability"]["fatigue_breakpoint_penalty"])
	var form_modifier := player.form * float(config["probability"]["form_weight"])
	var logit := (weighted_attribute - 0.5) * slope
	logit += context_modifier + form_modifier - fatigue_penalty
	var raw_probability := 1.0 / (1.0 + exp(-logit))
	return clampf(raw_probability, minimum, maximum)

func _weighted_attribute(player: FootballPlayer, weights: Dictionary) -> float:
	var weighted_attribute := 0.0
	for attribute_name in weights:
		weighted_attribute += player.get_attribute(str(attribute_name)) / 100.0 * float(weights[attribute_name])
	return weighted_attribute

func _formula_description(player: FootballPlayer, weights: Dictionary, modifier: float) -> String:
	return _formula_description_with_slope(player, weights, modifier, float(config["probability"]["sigmoid_slope"]))

func _formula_description_with_slope(player: FootballPlayer, weights: Dictionary, modifier: float, slope: float) -> String:
	var weight_text := ""
	var weighted_attribute := _weighted_attribute(player, weights)
	for attribute_name in weights:
		if not weight_text.is_empty():
			weight_text += " + "
		weight_text += "%s×%.2f" % [str(attribute_name), float(weights[attribute_name])]
	var fatigue_penalty := player.fatigue * float(config["probability"]["fatigue_weight"])
	if player.fatigue >= float(config["thresholds"]["fatigue_breakpoint"]):
		fatigue_penalty += float(config["probability"]["fatigue_breakpoint_penalty"])
	var form_modifier := player.form * float(config["probability"]["form_weight"])
	return "sigmoid((skill %.2f - .50) × %.1f + ctx %+.2f + form %+.2f - fatigue %.2f) | %s" % [
		weighted_attribute, slope, modifier,
		form_modifier, fatigue_penalty, weight_text
	]

func _advance_ball(seconds: float) -> void:
	if restart_pending or not ball_in_flight:
		return
	var ball_data: Dictionary = config["match"]["ball_flight"]
	var radius := float(ball_data["ball_radius_px"])
	var substep_distance := maxf(0.5, float(ball_data["substep_distance_px"]))
	var substeps := maxi(1, int(ceil(ball_velocity_3d.length() * seconds / substep_distance)))
	var sub_dt := seconds / float(substeps)
	for _substep in range(substeps):
		if not ball_in_flight or restart_pending:
			return
		var previous := ball_position_3d
		if ball_position_3d.z > radius or ball_velocity_3d.z > 0.0:
			ball_velocity_3d.z -= float(ball_data["gravity_z_px_s2"]) * sub_dt
		var air_drag := maxf(0.0, 1.0 - float(ball_data["air_drag_per_second"]) * sub_dt)
		ball_velocity_3d *= air_drag
		ball_position_3d += ball_velocity_3d * sub_dt
		if ball_position_3d.z <= radius:
			ball_position_3d.z = radius
			if absf(ball_velocity_3d.z) > 5.0:
				ball_velocity_3d.z = -ball_velocity_3d.z * float(ball_data["ground_restitution"])
				ball_velocity_3d.x *= maxf(0.0, 1.0 - float(ball_data["ground_friction"]) * sub_dt)
				ball_velocity_3d.y *= maxf(0.0, 1.0 - float(ball_data["ground_friction"]) * sub_dt)
				ball_on_ground = false
			else:
				ball_velocity_3d.z = 0.0
				ball_on_ground = true
				ball_velocity_3d.x *= maxf(0.0, 1.0 - float(ball_data["ground_friction"]) * sub_dt)
				ball_velocity_3d.y *= maxf(0.0, 1.0 - float(ball_data["ground_friction"]) * sub_dt)
		ball_position = Vector2(ball_position_3d.x, ball_position_3d.y)
		ball_velocity = Vector2(ball_velocity_3d.x, ball_velocity_3d.y)
		if ball_flight_phase in ["shot", "rebound"]:
			if _resolve_frame_collision():
				ball_position = Vector2(ball_position_3d.x, ball_position_3d.y)
				ball_velocity = Vector2(ball_velocity_3d.x, ball_velocity_3d.y)
			if _crossed_goal_volume(previous, ball_position_3d):
				_score_flight_goal()
				return
			_try_keeper_interaction()
			if restart_pending:
				return
		if ball_flight_phase == "ground_pass" and _try_pass_interception():
			return
		var crossing := _find_boundary_crossing(Vector2(previous.x, previous.y), ball_position)
		if not crossing.is_empty():
			_classify_out_of_bounds(str(crossing["boundary"]), crossing["position"])
			return
		if ball_flight_phase == "ground_pass" and ball_target != null \
		and ball_position.distance_to(ball_target.position) <= float(config["match"]["pass_arrival_radius"]) \
		and ball_position_3d.z <= radius + 2.0:
			_complete_flight_pass()
			return
		if ball_on_ground and ball_velocity_3d.length() < float(ball_data["min_speed_sleep_px_s"]):
			ball_in_flight = false
			ball_flight_phase = "none"
			ball_velocity_3d = Vector3.ZERO
			ball_velocity = Vector2.ZERO
			if ball_target != null:
				_complete_flight_pass()
			else:
				var nearest := _nearest_player(ball_position)
				if nearest != null:
					_set_possession(nearest)
			return

func _complete_flight_pass() -> void:
	if ball_target == null:
		return
	var passer := _find_player_by_id(ball_shooter_id)
	var receiver := ball_target
	var completed := rng.randf() < ball_pass_probability
	if passer != null:
		passer.record_action(completed, float(config["match"]["condition_form_change_per_success"]))
	var team_name := teams[receiver.team_index].team_name
	if completed:
		_set_last_action("%s pass complete to %s" % [team_name, receiver.player_name], ball_pass_probability, "Pass resolved at reception after physical ball flight.")
		_set_possession(receiver)
	else:
		var interceptor := _nearest_opponent_to_position(ball_position, teams[1 - receiver.team_index])
		_set_last_action("%s pass intercepted before %s could control" % [team_name, receiver.player_name], ball_pass_probability, "Pass resolved at reception after physical ball flight.")
		if interceptor != null:
			_set_possession(interceptor)
		else:
			_set_possession(receiver)

func _try_pass_interception() -> bool:
	if ball_target == null or ball_position_3d.z > float(config["match"]["ball_flight"]["ball_radius_px"]) + 4.0:
		return false
	var defenders: FootballTeam = teams[1 - ball_target.team_index]
	var radius := float(config["match"]["ball_flight"]["interception_radius_px"])
	for defender in defenders.players:
		if defender.tactical_role == "GK":
			continue
		if defender.position.distance_to(ball_position) <= radius:
			var text := "[Ball] %s (#%d) intercepts pass in flight at (%.1f, %.1f, %.1f)" % [defender.player_name, defender.id, ball_position_3d.x, ball_position_3d.y, ball_position_3d.z]
			event_log.append(text)
			print(text)
			_set_last_action("Pass intercepted by %s" % defender.player_name, ball_pass_probability, "Deterministic proximity interception inside configured radius.")
			_set_possession(defender)
			return true
	return false

func _resolve_frame_collision() -> bool:
	var field: Dictionary = config["field"]
	var ball_data: Dictionary = config["match"]["ball_flight"]
	var center_y := float(field["height"]) * 0.5
	var half_width := float(ball_data["goal_width_px"]) * 0.5
	var goal_height := float(ball_data["goal_height_px"])
	var combined_radius := float(ball_data["ball_radius_px"]) + float(ball_data["post_radius_px"])
	for side in [0, 1]:
		var goal_x := 0.0 if side == 0 else float(field["width"])
		for post_y in [center_y - half_width, center_y + half_width]:
			var closest := Vector3(goal_x, post_y, clampf(ball_position_3d.z, 0.0, goal_height))
			if ball_position_3d.distance_to(closest) <= combined_radius:
				_reflect_from_frame(closest, combined_radius)
				return true
		var bar_radius := float(ball_data["ball_radius_px"]) + float(ball_data["crossbar_radius_px"])
		if ball_position_3d.z >= goal_height - bar_radius and ball_position_3d.z <= goal_height + bar_radius \
		and absf(ball_position_3d.x - goal_x) <= bar_radius \
		and absf(ball_position_3d.y - center_y) <= half_width + bar_radius:
			var closest_bar := Vector3(goal_x, clampf(ball_position_3d.y, center_y - half_width, center_y + half_width), goal_height)
			_reflect_from_frame(closest_bar, bar_radius)
			return true
	return false

func _reflect_from_frame(contact: Vector3, combined_radius: float) -> void:
	var normal := (ball_position_3d - contact).normalized()
	if normal.length_squared() < 0.001:
		normal = Vector3.LEFT if ball_velocity_3d.x > 0.0 else Vector3.RIGHT
	var toward_frame := ball_velocity_3d.dot(normal)
	if toward_frame < 0.0:
		ball_velocity_3d -= normal * (1.45 * toward_frame)
	ball_position_3d = contact + normal * combined_radius
	ball_flight_phase = "rebound"
	var text := "[Ball] post/crossbar hit at (%.1f, %.1f, %.1f)" % [contact.x, contact.y, contact.z]
	event_log.append(text)
	print(text)

func _crossed_goal_volume(previous: Vector3, current: Vector3) -> bool:
	if ball_flight_phase not in ["shot", "rebound"]:
		return false
	var shooter := _find_player_by_id(ball_shooter_id)
	if shooter == null:
		return false
	var field: Dictionary = config["field"]
	var ball_data: Dictionary = config["match"]["ball_flight"]
	var direction := 1.0 if teams[shooter.team_index].attacks_right else -1.0
	var goal_x := float(field["width"]) if direction > 0.0 else 0.0
	var plane_x := goal_x + direction * float(ball_data["ball_radius_px"])
	if (previous.x - plane_x) * direction >= 0.0 or (current.x - plane_x) * direction < 0.0:
		return false
	var t := clampf((plane_x - previous.x) / (current.x - previous.x), 0.0, 1.0)
	var crossing := previous.lerp(current, t)
	var center_y := float(field["height"]) * 0.5
	return absf(crossing.y - center_y) + float(ball_data["ball_radius_px"]) <= float(ball_data["goal_width_px"]) * 0.5 \
		and crossing.z + float(ball_data["ball_radius_px"]) <= float(ball_data["goal_height_px"])

func _score_flight_goal() -> void:
	var scorer := _find_player_by_id(ball_shooter_id)
	if scorer == null:
		return
	var scoring_team_index := scorer.team_index
	var scoring_team := teams[scoring_team_index]
	scoring_team.score += 1
	next_kickoff_team = 1 - scoring_team_index
	var scorer_name := scorer.player_name if scorer != null else "Unknown"
	var text := "[Ball] goal volume entered by %s at (%.1f, %.1f, %.1f)" % [scorer_name, ball_position_3d.x, ball_position_3d.y, ball_position_3d.z]
	event_log.append(text)
	print(text)
	_set_last_action("%s %s scores!" % [scoring_team.team_name, scorer_name], last_shot_on_target_probability, "Ball fully crossed the goal plane inside the post and crossbar volume.")
	ball_position = Vector2(float(config["field"]["width"]) if teams[scoring_team_index].attacks_right else 0.0, float(config["field"]["height"]) * 0.5)
	ball_position_3d = Vector3(ball_position.x, ball_position.y, float(config["match"]["ball_flight"]["ball_radius_px"]))
	ball_velocity = Vector2.ZERO
	ball_velocity_3d = Vector3.ZERO
	ball_in_flight = false
	ball_on_ground = true
	ball_flight_phase = "none"
	ball_owner = null
	ball_target = null
	_begin_restart(RESTART_KICKOFF, next_kickoff_team, Vector2(float(config["field"]["width"]) * 0.5, float(config["field"]["height"]) * 0.5), float(config["match"]["goal_reset_seconds"]))

func _try_keeper_interaction() -> void:
	if ball_keeper_attempted or ball_flight_phase not in ["shot", "rebound"]:
		return
	var shooter := _find_player_by_id(ball_shooter_id)
	if shooter == null:
		return
	var keeper := _goalkeeper(teams[1 - shooter.team_index])
	if keeper == null:
		return
	var ball_data: Dictionary = config["match"]["ball_flight"]
	if ball_position_3d.z > float(ball_data["keeper_reachable_height_m"]) / float(ball_data["metres_per_pixel"]) \
	or keeper.position.distance_to(ball_position) > float(ball_data["keeper_interaction_radius_px"]):
		return
	var own_goal_x := 0.0 if teams[keeper.team_index].attacks_right else float(config["field"]["width"])
	if absf(keeper.position.x - own_goal_x) > float(ball_data["keeper_goal_approach_px"]):
		return
	ball_keeper_attempted = true
	var gk_weights: Dictionary = config["probability"]["action_weights"]["goalkeeper"]
	var shooter_team: FootballTeam = teams[shooter.team_index]
	var shot_distance := absf(own_goal_x - shooter.position.x)
	var nearest_defender := _nearest_opponent_to_position(shooter.position, teams[keeper.team_index])
	var pressure_distance := nearest_defender.position.distance_to(shooter.position) \
		if nearest_defender != null else float(config["field"]["width"])
	var shot_context := _shot_context_breakdown(
		shooter.position, shooter_team, shot_distance,
		_attack_progress_x(shooter.position.x, shooter_team), pressure_distance
	)
	var shot_power := _weighted_attribute(shooter, config["probability"]["shot_power_attribute_weights"])
	var shot_placement := _weighted_attribute(shooter, config["probability"]["shot_placement_attribute_weights"])
	var modifier := shot_distance * float(config["probability"]["goalkeeper_distance_scale"])
	modifier -= shot_power * float(config["probability"]["goalkeeper_power_penalty"])
	modifier -= shot_placement * float(config["probability"]["goalkeeper_placement_penalty"])
	modifier += float(shot_context["pressure_factor"]) * float(config["probability"]["goalkeeper_pressure_bonus"])
	modifier += float(config["probability"]["goalkeeper_tactical_modifiers"]["mentality"][teams[keeper.team_index].mentality])
	modifier += float(config["probability"]["goalkeeper_tactical_modifiers"]["game_plan"][teams[keeper.team_index].game_plan])
	if teams[keeper.team_index].has_instruction("press_pivot") \
	and shooter.number == int(config["probability"]["instructions"]["press_pivot"]["pivot_shirt_number"]):
		modifier += float(config["probability"]["instructions"]["press_pivot"]["save_pressure_bonus"])
	last_goalkeeper_save_probability = _calculate_probability_with_slope(keeper, gk_weights, modifier, float(config["probability"]["goalkeeper_save_slope"]), float(config["match"]["minimum_probability"]), float(config["match"]["maximum_probability"]))
	if rng.randf() < last_goalkeeper_save_probability:
		var inward := 1.0 if own_goal_x == 0.0 else -1.0
		var lateral := signf(ball_position_3d.y - keeper.position.y)
		ball_velocity_3d = Vector3(inward * float(ball_data["save_impulse_px_s"]), lateral * float(ball_data["save_impulse_px_s"]) * 0.3, float(ball_data["save_vertical_impulse_px_s"]))
		ball_velocity = Vector2(ball_velocity_3d.x, ball_velocity_3d.y)
		ball_flight_phase = "rebound"
		last_touch_team_index = keeper.team_index
		last_touch_player_id = keeper.id
		_set_last_action("Shot saved by %s (p=%.3f); ball deflected" % [keeper.player_name, last_goalkeeper_save_probability], last_goalkeeper_save_probability, "Keeper contact applied a deterministic directional impulse; no instant rebound roll.")
		var text := "[Ball] keeper interaction %s at (%.1f, %.1f, %.1f) -> save impulse" % [keeper.player_name, ball_position_3d.x, ball_position_3d.y, ball_position_3d.z]
		event_log.append(text)
		print(text)
func _tick_shot_cooldowns() -> void:
	var opposition_ticks_required := int(config["match"]["shot_cooldown_opposition_ticks"])
	for team in teams:
		for player in team.players:
			if not player.shot_cooldown_active:
				continue
			var opposition_has_possession := ball_owner != null and ball_target == null \
				and player.team_index != ball_owner.team_index
			if not opposition_has_possession:
				player.shot_cooldown_opposition_ticks = 0
				continue
			player.shot_cooldown_opposition_ticks += 1
			if player.shot_cooldown_opposition_ticks >= opposition_ticks_required:
				player.shot_cooldown_active = false
				player.shot_cooldown_opposition_ticks = 0
				var text := "[Shot] %s cooldown cleared after %d opposition possession ticks." % [
					player.player_name, opposition_ticks_required
				]
				event_log.append(text)
				print(text)

func _set_possession(player: FootballPlayer) -> void:
	if restart_pending:
		return
	if player == null:
		ball_owner = null
		ball_target = null
		ball_velocity = Vector2.ZERO
		ball_velocity_3d = Vector3.ZERO
		ball_in_flight = false
		ball_on_ground = true
		ball_flight_phase = "none"
		ball_pass_probability = -1.0
		ball_shooter_id = NO_PLAYER_ID
		ball_keeper_attempted = false
		return
	var previous_team_index := -1
	if ball_owner != null:
		previous_team_index = ball_owner.team_index
	elif ball_target != null:
		previous_team_index = ball_target.team_index
	if previous_team_index >= 0 and previous_team_index != player.team_index:
		_finish_pass_sequence(teams[previous_team_index], "possession lost")
		_clear_box_runs(teams[previous_team_index], false)
	elif ball_target != null and ball_target.team_index == player.team_index:
		teams[player.team_index].completed_passes_in_possession += 1
		var pass_count := teams[player.team_index].completed_passes_in_possession
		var sequence_text := "[Possession] %s combination pass %d completed (sequence length %d)." % [
			teams[player.team_index].team_name, pass_count, pass_count
		]
		event_log.append(sequence_text)
		print(sequence_text)
		_clear_team_shot_cooldowns(teams[player.team_index])
	if ball_owner != player:
		player.carry_distance = 0.0
	ball_owner = player
	ball_target = null
	ball_velocity = Vector2.ZERO
	ball_velocity_3d = Vector3.ZERO
	ball_position_3d = Vector3(ball_position.x, ball_position.y, float(config["match"]["ball_flight"]["ball_radius_px"]))
	ball_in_flight = false
	ball_on_ground = true
	ball_flight_phase = "none"
	ball_pass_probability = -1.0
	ball_shooter_id = NO_PLAYER_ID
	ball_keeper_attempted = false
	ball_position = player.position
	ball_position_3d = Vector3(ball_position.x, ball_position.y, float(config["match"]["ball_flight"]["ball_radius_px"]))
	last_touch_team_index = player.team_index
	last_touch_player_id = player.id
	preferred_pass_debug = "%s possession: waiting for pass selection" % teams[player.team_index].team_name

func _finish_pass_sequence(team: FootballTeam, reason: String) -> void:
	if team.completed_passes_in_possession > 0:
		var sequence_text := "[Possession] %s sequence ended after %d completed passes (%s)." % [
			team.team_name, team.completed_passes_in_possession, reason
		]
		event_log.append(sequence_text)
		print(sequence_text)
	team.completed_passes_in_possession = 0

func _clear_team_shot_cooldowns(team: FootballTeam) -> void:
	for player in team.players:
		player.shot_cooldown_active = false
		player.shot_cooldown_opposition_ticks = 0

func _clear_box_runs(team: FootballTeam, suppress_until_possession_change: bool) -> void:
	for player in team.players:
		player.box_run_active = false
		player.box_run_target = Vector2.ZERO
		player.box_run_suppressed = suppress_until_possession_change
		if not suppress_until_possession_change:
			box_run_logged_player_keys.erase("%d:%d" % [player.team_index, player.id])

func _choose_receiver(player: FootballPlayer, team: FootballTeam) -> FootballPlayer:
	var best_player: FootballPlayer = null
	var best_score := -INF
	var attack_direction := 1.0 if team.attacks_right else -1.0
	var field_width := float(config["field"]["width"])
	var pass_data: Dictionary = config["decision"]["pass_selection"]
	var tackle_data: Dictionary = config["match"]["tackle_decision"]
	var direct_mode := _is_direct_play_mode(team)
	var nearest_to_carrier := _nearest_opponent_to_position(player.position, teams[1 - player.team_index])
	var carrier_pressure := player.position.distance_to(nearest_to_carrier.position) if nearest_to_carrier != null else INF
	var is_pressured := carrier_pressure <= float(tackle_data["pressure_pass_distance"])
	var carrier_attack_x := _attack_progress_x(player.position.x, team)
	for candidate in team.players:
		if candidate == player:
			continue
		var forward_progress := (candidate.position.x - player.position.x) * attack_direction
		var distance := player.position.distance_to(candidate.position)
		var nearest_defender := _nearest_opponent_to_position(candidate.position, teams[1 - candidate.team_index])
		var defender_distance := candidate.position.distance_to(nearest_defender.position) if nearest_defender != null else field_width
		var direction := (candidate.position - player.position).normalized()
		var forward_alignment := direction.x * attack_direction
		var support_angle_quality := 1.0 - absf(forward_alignment)
		var role_profile_name := _pass_role_profile(candidate.tactical_role)
		var role_profiles: Dictionary = pass_data["role_profiles"]
		var role_profile: Dictionary = role_profiles[role_profile_name]
		var nearby_multiplier := float(role_profile["nearby_multiplier"])
		if direct_mode:
			nearby_multiplier *= float(pass_data["direct_nearby_multiplier"])
		if is_pressured:
			nearby_multiplier += float(tackle_data["pressure_nearby_bonus"]) / maxf(float(pass_data["nearby_weight"]), 1.0)
		var distance_ratio := clampf(distance / float(pass_data["maximum_candidate_distance"]), 0.0, 1.0)
		var score := (1.0 - distance_ratio) * float(pass_data["nearby_weight"]) * nearby_multiplier
		score += clampf(defender_distance / float(pass_data["openness_distance"]), 0.0, 1.0) * float(pass_data["openness_weight"])
		score += support_angle_quality * float(pass_data["support_angle_weight"])
		var progress_ratio := clampf(forward_progress / field_width, -1.0, 1.0)
		var progression_weight := float(pass_data["direct_progression_weight"]) if direct_mode else float(pass_data["possession_progression_weight"])
		if is_pressured and not direct_mode:
			progression_weight *= float(tackle_data["pressure_progression_multiplier"])
		score += progress_ratio * progression_weight * float(role_profile["progression_multiplier"])
		var backward_penalty := float(pass_data["backward_pass_penalty"])
		if is_pressured and not direct_mode:
			backward_penalty *= float(tackle_data["pressure_backward_penalty_multiplier"])
		score -= maxf(0.0, -progress_ratio) * backward_penalty
		score -= maxf(0.0, distance - float(pass_data["maximum_candidate_distance"])) / 100.0 * float(pass_data["over_range_penalty_per_100"])
		if is_pressured and forward_progress <= float(tackle_data["pressure_safe_pass_forward_limit"]):
			var outlet_quality := clampf(defender_distance / float(tackle_data["pressure_safe_pass_open_distance"]), 0.0, 1.0)
			score += float(tackle_data["pressure_safe_pass_bonus"]) * outlet_quality
		if not direct_mode and team.completed_passes_in_possession > 0 and distance <= float(pass_data["short_combination_distance"]):
			var continuation_bonus := minf(
				float(team.completed_passes_in_possession) * float(pass_data["sequence_continuation_bonus_per_pass"]),
				float(pass_data["sequence_continuation_bonus_maximum"])
			)
			score += continuation_bonus
		if _is_attacking_role(candidate.tactical_role):
			score += float(config["decision"]["attacking_role_receiver_bonus"]) if direct_mode else 0.0
		if team.has_instruction("direct_long_balls"):
			score += float(config["probability"]["instructions"]["direct_long_balls"]["forward_bonus"]) if forward_progress > 0.0 else 0.0
		var runner_target_distance := candidate.position.distance_to(candidate.box_run_target)
		var is_arrived_box_runner := candidate.box_run_active \
			and carrier_attack_x >= float(pass_data["box_runner_progress_attack_x"]) \
			and runner_target_distance <= float(pass_data["box_runner_near_target_distance"]) \
			and _is_inside_position_shot_box(candidate.position, team, 0.0) \
			and defender_distance >= float(pass_data["box_runner_min_open_distance"])
		if is_arrived_box_runner:
			score += float(pass_data["box_runner_bonus"])
		score += _channel_receiver_bonus(team, candidate)
		if score > best_score or (is_equal_approx(score, best_score) and best_player != null and candidate.id < best_player.id):
			best_score = score
			best_player = candidate
			var runner_text := " | free box runner +%.0f" % float(pass_data["box_runner_bonus"]) if is_arrived_box_runner else ""
			preferred_pass_debug = "%s: %s #%d %s | %.0fpx, angle %.2f, %s profile, score %.1f, %s%s%s" % [
				team.team_name, candidate.player_name, candidate.number, candidate.tactical_role, distance,
				support_angle_quality, role_profile_name, score, "open %.0fpx" % defender_distance,
				" | carrier pressure %.0fpx" % carrier_pressure if is_pressured else "",
				runner_text
			]
	return best_player

func _should_shoot(player: FootballPlayer, team: FootballTeam) -> bool:
	var attack_x := player.position.x / float(config["field"]["width"])
	if not team.attacks_right:
		attack_x = 1.0 - attack_x
	if player.shot_cooldown_active:
		_log_shot_declined(player, "shot cooldown active", attack_x)
		return false
	if not (_is_forward_role(player.tactical_role) or _is_direct_play_mode(team) or team.mentality == "Attacking"):
		return false
	var nearest_defender := _nearest_opponent_to_position(player.position, teams[1 - player.team_index])
	if nearest_defender == null:
		push_error("Shot decision failed: defending team has no outfield players.")
		return false
	var field_data: Dictionary = config["field"]
	var selection_data: Dictionary = config["decision"]["shot_selection"]
	var goal_x := float(field_data["width"]) if team.attacks_right else 0.0
	var distance_to_goal := absf(goal_x - player.position.x)
	var lateral_offset := absf(player.position.y - float(field_data["height"]) * 0.5)
	var angle_ratio := clampf(
		lateral_offset / maxf(distance_to_goal + float(field_data["goal_width"]) * 0.5, 1.0),
		0.0,
		1.0
	)
	var inside_box := _is_inside_shot_box(player, team, 0.0)
	var on_box_edge := not inside_box and _is_inside_shot_box(
		player, team, float(selection_data["box_edge_margin"])
	)
	if player.box_run_active and not _box_run_shot_ready(player, team):
		return false
	var nearest_defender_distance := player.position.distance_to(nearest_defender.position)
	var is_direct_attempt := _is_direct_play_mode(team)
	if inside_box or on_box_edge:
		if angle_ratio > float(selection_data["inside_box_max_angle_ratio"]):
			_log_shot_declined(player, "bad angle", attack_x)
			return false
		if nearest_defender_distance < float(selection_data["minimum_unmarked_distance"]):
			_log_shot_declined(player, "marked", attack_x)
			return false
	else:
		var minimum_attack_x := float(selection_data["patient_outside_min_attack_x"])
		var maximum_angle_ratio := float(selection_data["patient_outside_max_angle_ratio"])
		var minimum_open_distance := float(selection_data["patient_outside_min_open_distance"])
		if is_direct_attempt:
			minimum_attack_x = float(selection_data["direct_outside_min_attack_x"])
			maximum_angle_ratio = float(selection_data["direct_outside_max_angle_ratio"])
			minimum_open_distance = float(selection_data["direct_outside_min_open_distance"])
		if attack_x < minimum_attack_x:
			_log_shot_declined(player, "too far", attack_x)
			return false
		if angle_ratio > maximum_angle_ratio:
			_log_shot_declined(player, "bad angle", attack_x)
			return false
		if nearest_defender_distance < minimum_open_distance:
			_log_shot_declined(player, "marked", attack_x)
			return false
	var pass_data: Dictionary = config["decision"]["pass_selection"]
	if team.game_plan == "Possession" and not team.has_instruction("direct_long_balls"):
		if team.completed_passes_in_possession < int(pass_data["minimum_build_up_passes_before_shot"]):
			var box_line_distance := _distance_to_penalty_area_line(player, team)
			var open_box_chance := (inside_box or is_zero_approx(box_line_distance)) \
				and angle_ratio <= float(selection_data["inside_box_max_angle_ratio"]) \
				and nearest_defender_distance >= float(selection_data["minimum_unmarked_distance"])
			if open_box_chance:
				var text := "[Shot] %s: open box chance, build-up waived." % player.player_name
				event_log.append(text)
				print(text)
			else:
				_log_shot_declined(player, "build-up not finished", attack_x)
				return false
	return true

func _is_inside_shot_box(player: FootballPlayer, team: FootballTeam, edge_margin: float) -> bool:
	return _is_inside_position_shot_box(player.position, team, edge_margin)

func _box_run_shot_ready(player: FootballPlayer, team: FootballTeam) -> bool:
	var target_distance := player.position.distance_to(player.box_run_target)
	var inside_box := _is_inside_position_shot_box(player.position, team, 0.0)
	var edge_margin := float(config["decision"]["shot_selection"]["box_edge_margin"])
	var on_box_edge := _is_inside_position_shot_box(player.position, team, edge_margin)
	if inside_box or on_box_edge:
		return true
	var attack_x := _attack_progress_x(player.position.x, team)
	_log_shot_declined(player, "box run not reached (%.1fpx from target)" % target_distance, attack_x)
	return false

func _is_inside_position_shot_box(position: Vector2, team: FootballTeam, edge_margin: float) -> bool:
	var field_data: Dictionary = config["field"]
	var goal_x := float(field_data["width"]) if team.attacks_right else 0.0
	var distance_to_goal := absf(goal_x - position.x)
	var lateral_offset := absf(position.y - float(field_data["height"]) * 0.5)
	return distance_to_goal <= float(field_data["penalty_area_depth"]) + edge_margin \
		and lateral_offset <= float(field_data["penalty_area_height"]) * 0.5 + edge_margin

func _distance_to_penalty_area_line(player: FootballPlayer, team: FootballTeam) -> float:
	var field_data: Dictionary = config["field"]
	var goal_x := float(field_data["width"]) if team.attacks_right else 0.0
	var distance_to_goal := absf(goal_x - player.position.x)
	var lateral_offset := absf(player.position.y - float(field_data["height"]) * 0.5)
	var box_line_x_gap := maxf(distance_to_goal - float(field_data["penalty_area_depth"]), 0.0)
	var box_line_y_gap := maxf(lateral_offset - float(field_data["penalty_area_height"]) * 0.5, 0.0)
	return Vector2(box_line_x_gap, box_line_y_gap).length()

func _log_shot_declined(player: FootballPlayer, reason: String, attack_x: float) -> void:
	var box_line_distance := _distance_to_penalty_area_line(player, teams[player.team_index])
	var text := "[Shot] %s declines at x=%.1f (attack %.3f, box-line distance %.1fpx): %s." % [
		player.player_name, player.position.x, attack_x, box_line_distance, reason
	]
	event_log.append(text)
	print(text)

func _is_direct_play_mode(team: FootballTeam) -> bool:
	return team.game_plan == "Direct" or team.game_plan == "Counter" or team.has_instruction("direct_long_balls")

func _is_fullback_role(role: String) -> bool:
	return ["LB", "RB", "LWB", "RWB"].has(role)

func _is_attacking_role(role: String) -> bool:
	return ["LW", "RW", "LM", "RM", "CAM", "LAM", "RAM", "ST", "CF"].has(role)

func _is_forward_role(role: String) -> bool:
	return ["ST", "CF"].has(role)

func _pass_role_profile(role: String) -> String:
	if role == "GK" or ["LB", "RB", "LWB", "RWB", "CB", "LCB", "RCB", "CDM", "LDM", "RDM"].has(role):
		return "defensive"
	if ["LW", "RW", "LM", "RM", "CAM", "LAM", "RAM", "ST", "CF"].has(role):
		return "attacking"
	return "central"

func get_team_play_mode(team_index: int) -> String:
	if team_index < 0 or team_index >= teams.size():
		return "Unavailable"
	var team: FootballTeam = teams[team_index]
	if team.has_instruction("direct_long_balls") or team.game_plan == "Direct":
		return "Direct"
	if team.game_plan == "Counter":
		return "Counter"
	return "Build-up / combinations"

func _nearest_opponent_to_ball(team: FootballTeam) -> FootballPlayer:
	var nearest: FootballPlayer
	var nearest_distance := INF
	for player in team.players:
		var distance := player.position.distance_to(ball_position)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = player
	return nearest

func _nearest_player(target: Vector2) -> FootballPlayer:
	var nearest: FootballPlayer
	var nearest_distance := INF
	for team in teams:
		for player in team.players:
			var distance := player.position.distance_to(target)
			if distance < nearest_distance:
				nearest_distance = distance
				nearest = player
	return nearest

func _nearest_opponent_to_position(target: Vector2, team: FootballTeam) -> FootballPlayer:
	var nearest: FootballPlayer
	var nearest_distance := INF
	for player in team.players:
		var distance := player.position.distance_to(target)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = player
	return nearest

func _nearest_outfield_player_to_position(target: Vector2, team: FootballTeam) -> FootballPlayer:
	var nearest: FootballPlayer
	var nearest_distance := INF
	for player in team.players:
		if player.role == "GK":
			continue
		var distance := player.position.distance_to(target)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = player
	return nearest

func _goalkeeper(team: FootballTeam) -> FootballPlayer:
	for player in team.players:
		if player.role == "GK":
			return player
	return null

func _channel_receiver_bonus(team: FootballTeam, candidate: FootballPlayer) -> float:
	var instruction_id := "target_left_channel" if team.has_instruction("target_left_channel") else ("target_right_channel" if team.has_instruction("target_right_channel") else "")
	if instruction_id.is_empty():
		return 0.0
	var instruction: Dictionary = config["probability"]["instructions"][instruction_id]
	var channel_y := float(instruction["channel_y"]) * float(config["field"]["height"])
	var distance := absf(candidate.position.y - channel_y)
	var maximum_distance := float(config["field"]["height"]) * float(config["decision"]["channel_distance_scale"])
	return float(instruction["receiver_bonus"]) * clampf(1.0 - distance / maximum_distance, 0.0, 1.0)

func _channel_pass_modifier(team: FootballTeam, receiver: FootballPlayer) -> float:
	return _channel_receiver_bonus(team, receiver) * float(config["probability"]["manager_tools"]["channel_probability_scale"])

func _update_tactical_positions(team: FootballTeam) -> void:
	var formation: Array = config["formations"][team.formation]
	var assigned_players: Array[FootballPlayer] = []
	var movement: Dictionary = config["probability"]["movement"]
	var instruction_data: Dictionary = config["probability"]["instructions"]
	var has_possession := ball_owner != null and ball_owner.team_index == team.players[0].team_index
	var attack_sign := 1.0 if team.attacks_right else -1.0
	var tackle_data: Dictionary = config["match"]["tackle_decision"]
	var carrier_pressure := INF
	var pressure_support_blend := 0.0
	var box_run_targets: Dictionary = {}
	if has_possession and ball_owner != null:
		var nearest_defender := _nearest_opponent_to_position(ball_owner.position, teams[1 - ball_owner.team_index])
		if nearest_defender != null:
			carrier_pressure = ball_owner.position.distance_to(nearest_defender.position)
			if carrier_pressure <= float(tackle_data["pressure_pass_distance"]):
				pressure_support_blend = float(tackle_data["pressure_support_blend_bonus"])
	var run_carrier: FootballPlayer
	if has_possession:
		run_carrier = ball_owner
	elif ball_target != null and ball_target.team_index == team.players[0].team_index:
		run_carrier = ball_target
	if run_carrier != null:
		var ball_attack_x := _attack_progress_x(run_carrier.position.x, team)
		var run_data: Dictionary = config["match"]["box_runs"]
		if ball_attack_x >= float(run_data["trigger_ball_attack_x"]):
			box_run_targets = _get_box_run_targets(team, run_carrier, run_data)
		else:
			_clear_box_runs(team, false)
	else:
		_clear_box_runs(team, false)
	var team_advance := float(movement["mentality_advance_x"][team.mentality]) + float(movement["game_plan_advance_x"][team.game_plan])
	if has_possession:
		team_advance += float(movement["possession_advance_x"])
	if team.has_instruction("direct_long_balls"):
		team_advance += float(instruction_data["direct_long_balls"]["forward_bonus"]) * float(movement["direct_ball_movement_factor"])
	for slot in formation:
		var slot_role := str(slot["role"])
		var player := _find_formation_player(team, slot_role, assigned_players)
		if player == null:
			push_error("Formation %s cannot assign all players for team %s." % [team.formation, team.team_name])
			return
		player.tactical_role = slot_role
		var normalized_x := float(slot["x"])
		var normalized_y := float(slot["y"])
		if not team.attacks_right:
			normalized_x = 1.0 - normalized_x
		var target := Vector2(float(config["field"]["width"]) * normalized_x, float(config["field"]["height"]) * normalized_y)
		if player.tactical_role != "GK":
			target.x += attack_sign * team_advance
			if has_possession and _is_fullback_role(player.tactical_role):
				target.x += attack_sign * float(movement["fullback_possession_advance_x"])
			if team.has_instruction("push_fullbacks") and _is_fullback_role(player.tactical_role):
				target.x += attack_sign * float(instruction_data["push_fullbacks"]["advance_x"])
			if team.has_instruction("drop_compact"):
				var compact_instruction: Dictionary = instruction_data["drop_compact"]
				target.x -= attack_sign * float(compact_instruction["drop_x"])
				var compact_factor := float(compact_instruction["compact_y"])
				target.y = lerpf(target.y, float(config["field"]["height"]) * float(movement["compact_center_y"]), compact_factor)
			if team.has_instruction("target_left_channel") or team.has_instruction("target_right_channel"):
				var channel_id := "target_left_channel" if team.has_instruction("target_left_channel") else "target_right_channel"
				var channel_y := float(instruction_data[channel_id]["channel_y"]) * float(config["field"]["height"])
				if ["LW", "RW", "LM", "RM", "LWB", "RWB", "ST", "CF"].has(player.tactical_role):
					target.y = lerpf(target.y, channel_y, float(movement["winger_channel_blend"]))
			if has_possession and ball_owner != null and player != ball_owner:
				if player.position.distance_to(ball_owner.position) <= float(movement["ball_support_radius"]):
					var support_rank := _support_rank(player, ball_owner, team, float(movement["ball_support_radius"]))
					var support_offsets: Array = movement["support_offsets"]
					if support_rank < support_offsets.size():
						var support_offset: Array = support_offsets[support_rank]
						var support_target := ball_owner.position + Vector2(
							attack_sign * float(support_offset[0]),
							float(support_offset[1])
						)
						var support_blend := clampf(
							float(movement["support_shape_blend"]) + pressure_support_blend,
							0.0, 1.0
						)
						target = target.lerp(support_target, support_blend)
		if box_run_targets.has(player.id):
			target = box_run_targets[player.id]
			player.box_run_active = true
			_log_box_run_once(team, player, target.x)
		else:
			player.box_run_active = false
			player.box_run_target = Vector2.ZERO
		target.x = clampf(target.x, float(config["field"]["margin"]), float(config["field"]["width"]) - float(config["field"]["margin"]))
		target.y = clampf(target.y, float(config["field"]["margin"]), float(config["field"]["height"]) - float(config["field"]["margin"]))
		player.tactical_position = target
		if player.box_run_active:
			player.box_run_target = target
		assigned_players.append(player)

func _attack_progress_x(position_x: float, team: FootballTeam) -> float:
	var progress := position_x / float(config["field"]["width"])
	return progress if team.attacks_right else 1.0 - progress

func _get_box_run_targets(team: FootballTeam, carrier: FootballPlayer, run_data: Dictionary) -> Dictionary:
	var strikers: Array[FootballPlayer] = []
	var wide_attackers: Array[FootballPlayer] = []
	for player in team.players:
		if ["ST", "CF"].has(player.tactical_role):
			strikers.append(player)
		elif ["LW", "RW", "LM", "RM", "LWB", "RWB", "CAM", "LAM", "RAM"].has(player.tactical_role):
			wide_attackers.append(player)
	var runners: Array[FootballPlayer] = []
	var striker: FootballPlayer = null
	for candidate in strikers:
		if candidate != carrier and (striker == null or candidate.position.distance_to(carrier.position) < striker.position.distance_to(carrier.position)):
			striker = candidate
	if striker == null and carrier.tactical_role in ["ST", "CF"]:
		striker = carrier
	if striker != null:
		runners.append(striker)
	var wide_runner: FootballPlayer = null
	for candidate in wide_attackers:
		if candidate != carrier and (wide_runner == null or candidate.position.distance_to(carrier.position) < wide_runner.position.distance_to(carrier.position)):
			wide_runner = candidate
	if wide_runner != null:
		runners.append(wide_runner)
	var field_data: Dictionary = config["field"]
	var width := float(field_data["width"])
	var height := float(field_data["height"])
	var run_depth := float(run_data["target_depth_from_goal"])
	var run_x := width - run_depth if team.attacks_right else run_depth
	var center_y := height * 0.5
	var half_box_height := float(field_data["penalty_area_height"]) * 0.5
	var y_margin := float(run_data["y_margin_inside_penalty_area"])
	var targets: Dictionary = {}
	for runner in runners:
		if runner.box_run_suppressed:
			continue
		var target_y := center_y
		if runner != striker:
			target_y = lerpf(center_y, runner.position.y, float(run_data["wide_lane_blend"]))
		target_y = clampf(target_y, center_y - half_box_height + y_margin, center_y + half_box_height - y_margin)
		targets[runner.id] = Vector2(run_x, target_y)
	return targets

func _log_box_run_once(team: FootballTeam, player: FootballPlayer, target_x: float) -> void:
	var key := "%d:%d" % [player.team_index, player.id]
	if box_run_logged_player_keys.has(key):
		return
	box_run_logged_player_keys[key] = true
	var attack_sign := 1.0 if team.attacks_right else -1.0
	var from_x := player.position.x
	var target_attack_x := _attack_progress_x(target_x, team)
	var text := "[Run] %s #%d %s box run from-x=%.1f target-attack=%.3f (direction %+.0f)." % [
		team.team_name, player.number, player.tactical_role, from_x, target_attack_x, attack_sign
	]
	event_log.append(text)
	print(text)

func _log_box_run_progress(team: FootballTeam, player: FootballPlayer) -> void:
	var remaining_distance := player.position.distance_to(player.box_run_target)
	var text := "[Run] %s #%d %s current-x=%.1f remaining=%.1fpx target-x=%.1f." % [
		team.team_name, player.number, player.tactical_role,
		player.position.x, remaining_distance, player.box_run_target.x
	]
	event_log.append(text)
	print(text)

func _find_formation_player(team: FootballTeam, role: String, assigned: Array[FootballPlayer]) -> FootballPlayer:
	var fallback_roles := _formation_role_preferences(role)
	for player in team.players:
		if player.role == role and not assigned.has(player):
			return player
	for fallback_role in fallback_roles:
		for player in team.players:
			if player.role == fallback_role and not assigned.has(player):
				return player
	for player in team.players:
		if not assigned.has(player):
			return player
	return null

func _formation_role_preferences(role: String) -> Array[String]:
	match role:
		"GK":
			return ["GK"]
		"LB", "RB", "LWB", "RWB":
			return [role, "DEF", "LB", "RB", "CB", "MID", "CM"]
		"CB", "LCB", "RCB":
			return [role, "CB", "DEF", "LCB", "RCB", "LB", "RB", "MID", "CM"]
		"CDM", "LDM", "RDM":
			return [role, "CDM", "CM", "MID", "DEF", "CAM", "ATT", "LW", "RW"]
		"CM", "LCM", "RCM":
			return [role, "CM", "MID", "CDM", "CAM", "ATT", "LW", "RW"]
		"LM", "RM":
			return [role, "LW", "RW", "MID", "CM", "LM", "RM", "ATT"]
		"LW", "RW":
			return [role, "ATT", "LW", "RW", "LM", "RM", "CM", "MID"]
		"CAM", "LAM", "RAM":
			return [role, "MID", "CM", "CAM", "ATT", "LW", "RW", "ST"]
		"ST", "CF":
			return [role, "ATT", "ST", "CF", "LW", "RW", "CM", "MID"]
	return [role, "MID", "CM", "DEF", "ATT"]

func _support_rank(player: FootballPlayer, carrier: FootballPlayer, team: FootballTeam, radius: float) -> int:
	var tackle_data: Dictionary = config["match"]["tackle_decision"]
	var nearest_defender := _nearest_opponent_to_position(carrier.position, teams[1 - carrier.team_index])
	var prioritize_pressure := nearest_defender != null \
		and nearest_defender.position.distance_to(carrier.position) <= float(tackle_data["pressure_pass_distance"])
	var player_score := _support_candidate_score(player, carrier, radius, tackle_data, prioritize_pressure)
	var rank := 0
	for teammate in team.players:
		if teammate == carrier or teammate == player or teammate.tactical_role == "GK":
			continue
		var teammate_distance := teammate.position.distance_to(carrier.position)
		if teammate_distance > radius:
			continue
		var teammate_score := _support_candidate_score(teammate, carrier, radius, tackle_data, prioritize_pressure)
		if teammate_score < player_score or (is_equal_approx(teammate_score, player_score) and teammate.id < player.id):
			rank += 1
	return rank

func _support_candidate_score(player: FootballPlayer, carrier: FootballPlayer, radius: float, decision_data: Dictionary, prioritize_pressure: bool) -> float:
	var distance_ratio := player.position.distance_to(carrier.position) / maxf(radius, 1.0)
	var nearest_defender := _nearest_opponent_to_position(player.position, teams[1 - player.team_index])
	var defender_distance := player.position.distance_to(nearest_defender.position) if nearest_defender != null else radius
	var openness_ratio := clampf(defender_distance / float(decision_data["pressure_pass_distance"]), 0.0, 1.0)
	var distance_weight := float(decision_data["support_distance_weight"])
	var openness_weight := float(decision_data["support_openness_weight"])
	if prioritize_pressure:
		distance_weight = float(decision_data["pressure_support_distance_weight"])
		openness_weight = float(decision_data["pressure_support_openness_weight"])
	return distance_ratio * distance_weight - openness_ratio * openness_weight

func _apply_formation(team: FootballTeam) -> void:
	_update_tactical_positions(team)
	for player in team.players:
		player.position = player.tactical_position

func _position_teams_for_kickoff(kickoff_team_index: int) -> FootballPlayer:
	var field_data: Dictionary = config["field"]
	var width := float(field_data["width"])
	var height := float(field_data["height"])
	var depth_ratio := clampf(float(config["match"]["kickoff_own_half_depth_ratio"]), 0.0, 0.5)
	var boundary_margin := float(config["match"]["player_boundary_margin"])
	for team in teams:
		var formation: Array = config["formations"][team.formation]
		var assigned_players: Array[FootballPlayer] = []
		for slot in formation:
			var slot_role := str(slot["role"])
			var player := _find_formation_player(team, slot_role, assigned_players)
			if player == null:
				push_error("Kick-off formation %s cannot assign all players for team %s." % [team.formation, team.team_name])
				return null
			player.tactical_role = slot_role
			var normalized_x := float(slot["x"]) * depth_ratio
			if not team.attacks_right:
				normalized_x = 1.0 - normalized_x
			var position := Vector2(
				clampf(width * normalized_x, boundary_margin, width - boundary_margin),
				clampf(height * float(slot["y"]), boundary_margin, height - boundary_margin)
			)
			player.position = position
			player.tactical_position = position
			assigned_players.append(player)
	var center_position := Vector2(width * 0.5, height * 0.5)
	var kickoff_team: FootballTeam = teams[kickoff_team_index]
	var kickoff_player := _choose_ranked_restart_player(
		kickoff_team, ["ST", "CF"], center_position, true
	)
	if kickoff_player == null:
		kickoff_player = _choose_ranked_restart_player(
			kickoff_team, ["CM", "LCM", "RCM", "CDM", "CAM"], center_position, true
		)
	if kickoff_player == null:
		kickoff_player = _choose_ranked_restart_player(kickoff_team, [], center_position, false)
	if kickoff_player == null:
		push_error("Kick-off formation %s has no eligible on-pitch taker." % kickoff_team.formation)
		return null
	kickoff_player.position = center_position
	kickoff_player.tactical_position = center_position
	ball_position = center_position
	return kickoff_player

func _begin_restart(
	kind: String,
	awarded_team_index: int,
	position: Vector2,
	delay_seconds: float,
	crossing_position: Vector2 = Vector2.ZERO
) -> bool:
	if finished or restart_pending:
		return false
	if not [RESTART_KICKOFF, RESTART_THROW_IN, RESTART_CORNER, RESTART_GOAL_KICK].has(kind) \
	or awarded_team_index < 0 or awarded_team_index >= teams.size():
		push_error("Cannot begin invalid restart: %s for team %d." % [kind, awarded_team_index])
		return false
	if kind == RESTART_KICKOFF:
		next_kickoff_team = awarded_team_index
	var legal_position := _legal_restart_position(position)
	var taker: FootballPlayer
	if kind == RESTART_KICKOFF:
		taker = _position_teams_for_kickoff(awarded_team_index)
	else:
		taker = _choose_restart_taker(kind, teams[awarded_team_index], legal_position)
	if taker == null:
		push_error("Cannot begin %s: no eligible taker for %s." % [kind, teams[awarded_team_index].team_name])
		return false
	taker.position = legal_position
	taker.tactical_position = legal_position
	var receiver := _choose_restart_receiver(kind, teams[awarded_team_index], taker, legal_position)
	if receiver == null or receiver == taker or receiver.team_index != awarded_team_index or not receiver.on_pitch:
		push_error("Cannot begin %s: no valid receiver for %s." % [kind, teams[awarded_team_index].team_name])
		return false
	if kind == RESTART_KICKOFF:
		_log_kickoff_placement(taker, receiver)
	for team in teams:
		_finish_pass_sequence(team, "restart")
		_clear_box_runs(team, false)
		_clear_team_shot_cooldowns(team)
	restart_kind = kind
	restart_pending = true
	restart_awarded_team = awarded_team_index
	restart_position = legal_position
	restart_crossing_position = legal_position if crossing_position == Vector2.ZERO \
		else crossing_position
	restart_taker_id = taker.id
	restart_receiver_id = receiver.id
	restart_delay_remaining = maxf(0.0, delay_seconds)
	ball_position = legal_position
	ball_velocity = Vector2.ZERO
	ball_position_3d = Vector3(legal_position.x, legal_position.y, float(config["match"]["ball_flight"]["ball_radius_px"]))
	ball_velocity_3d = Vector3.ZERO
	ball_in_flight = false
	ball_on_ground = true
	ball_flight_phase = "none"
	ball_pass_probability = -1.0
	ball_shooter_id = NO_PLAYER_ID
	ball_keeper_attempted = false
	ball_owner = null
	ball_target = null
	decision_clock = 0.0
	var last_touch := _last_touch_description()
	var text := "[Restart] %s awarded to %s at (%.1f, %.1f); last touch: %s; taker %s (#%d), receiver %s (#%d)." % [
		_restart_display_name(kind), teams[awarded_team_index].team_name,
		legal_position.x, legal_position.y, last_touch,
		taker.player_name, taker.id, receiver.player_name, receiver.id
	]
	if crossing_position != Vector2.ZERO:
		text = "[Restart] %s awarded to %s at (%.1f, %.1f) from crossing (%.1f, %.1f); last touch: %s; taker %s (#%d), receiver %s (#%d)." % [
			_restart_display_name(kind), teams[awarded_team_index].team_name,
			legal_position.x, legal_position.y, crossing_position.x, crossing_position.y, last_touch,
			taker.player_name, taker.id, receiver.player_name, receiver.id
		]
	_set_last_action(text, 1.0, "Deterministic restart; no action probability roll.")
	return true

func _execute_pending_restart() -> bool:
	if not restart_pending:
		return false
	var taker := _find_player_by_id(restart_taker_id)
	var receiver := _find_player_by_id(restart_receiver_id)
	if taker == null or receiver == null or not taker.on_pitch or not receiver.on_pitch \
	or taker.team_index != restart_awarded_team or receiver.team_index != restart_awarded_team \
	or taker == receiver:
		push_error("Pending restart references became invalid before execution.")
		return false
	var executed_kind := restart_kind
	var executed_team := restart_awarded_team
	var from_position := restart_position
	restart_pending = false
	restart_kind = RESTART_IN_PLAY
	restart_awarded_team = -1
	restart_taker_id = NO_PLAYER_ID
	restart_receiver_id = NO_PLAYER_ID
	restart_delay_remaining = 0.0
	restart_crossing_position = Vector2.ZERO
	ball_position = from_position
	ball_owner = null
	ball_target = receiver
	ball_position_3d = Vector3(from_position.x, from_position.y, float(config["match"]["ball_flight"]["ball_radius_px"]))
	ball_in_flight = true
	ball_on_ground = true
	ball_flight_phase = "ground_pass"
	ball_pass_probability = 1.0
	ball_shooter_id = taker.id
	ball_keeper_attempted = false
	var direction := receiver.position - from_position
	if direction.length_squared() < 1.0:
		direction = Vector2(1.0 if teams[executed_team].attacks_right else -1.0, 0.0)
	if executed_kind != RESTART_KICKOFF:
		var inward := _restart_inward_direction(executed_kind, from_position)
		var minimum_inward_component := direction.length() * 0.35
		direction += inward * maxf(0.0, minimum_inward_component - direction.dot(inward))
	ball_velocity_3d = Vector3(direction.normalized().x, direction.normalized().y, 0.0) * float(config["match"]["pass_ball_speed"])
	ball_velocity = Vector2(ball_velocity_3d.x, ball_velocity_3d.y)
	last_touch_team_index = taker.team_index
	last_touch_player_id = taker.id
	var text := "[Restart] %s taken by %s (#%d) for %s (#%d); the ball is live." % [
		_restart_display_name(executed_kind), taker.player_name, taker.id,
		receiver.player_name, receiver.id
	]
	_set_last_action(text, 1.0, "Guaranteed deterministic restart delivery.")
	return true

func _restart_inward_direction(kind: String, restart_position_value: Vector2) -> Vector2:
	var field: Dictionary = config["field"]
	var radius := float(field["ball_radius"])
	if kind == RESTART_THROW_IN:
		return Vector2.DOWN if restart_position_value.y <= float(field["height"]) * 0.5 else Vector2.UP
	if kind == RESTART_CORNER:
		var x_inward := Vector2.RIGHT if restart_position_value.x <= float(field["width"]) * 0.5 else Vector2.LEFT
		var y_inward := Vector2.DOWN if restart_position_value.y <= radius + 1.0 else Vector2.UP
		return (x_inward + y_inward).normalized()
	if kind == RESTART_GOAL_KICK:
		return Vector2.RIGHT if restart_position_value.x <= float(field["width"]) * 0.5 else Vector2.LEFT
	return Vector2.ZERO

func _log_kickoff_placement(taker: FootballPlayer, receiver: FootballPlayer) -> void:
	var team_descriptions: Array[String] = []
	for team in teams:
		var direction := "right" if team.attacks_right else "left"
		team_descriptions.append("%s %s attacks %s" % [
			team.team_name, team.formation, direction
		])
	var text := "[Match] [Kickoff layout] %s; %s; taker %s (#%d), receiver %s (#%d)." % [
		team_descriptions[0], team_descriptions[1],
		taker.player_name, taker.id, receiver.player_name, receiver.id
	]
	event_log.append(text)
	print(text)

func _choose_kickoff_receiver(team: FootballTeam, taker: FootballPlayer) -> FootballPlayer:
	var receiver := _choose_ranked_restart_player(team, ["CF", "ST"], taker.position, true, taker)
	if receiver != null:
		return receiver
	receiver = _choose_ranked_restart_player(
		team, ["CM", "LCM", "RCM", "CDM", "LDM", "RDM", "CAM", "LM", "RM"], taker.position, true, taker
	)
	if receiver != null:
		return receiver
	return _choose_ranked_restart_player(team, [], taker.position, false, taker)

func _choose_throw_in_taker(team: FootballTeam, position: Vector2) -> FootballPlayer:
	var fullback := _choose_nearest_role_player(team, ["LB", "RB", "LWB", "RWB"], position)
	if fullback != null:
		return fullback
	var fallback := _choose_ranked_restart_player(team, [], position, false)
	if fallback != null:
		var text := "[Restart] Throw-in fallback: formation %s has no LB/RB/LWB/RWB; nearest outfield player %s (#%d) takes it." % [
			team.formation, fallback.player_name, fallback.id
		]
		event_log.append(text)
		print(text)
	return fallback

func _choose_nearest_role_player(team: FootballTeam, roles: Array, position: Vector2) -> FootballPlayer:
	var best: FootballPlayer = null
	var best_distance := INF
	for player in team.players:
		if not player.on_pitch or not roles.has(player.tactical_role):
			continue
		var distance := player.position.distance_to(position)
		if distance < best_distance or (
			is_equal_approx(distance, best_distance) and (best == null or player.id < best.id)
		):
			best = player
			best_distance = distance
	return best

func _choose_restart_taker(kind: String, team: FootballTeam, position: Vector2) -> FootballPlayer:
	match kind:
		RESTART_GOAL_KICK:
			var keeper := _goalkeeper(team)
			return keeper if keeper != null else _choose_ranked_restart_player(team, [], position, false)
		RESTART_THROW_IN:
			return _choose_throw_in_taker(team, position)
		RESTART_CORNER:
			if _has_restart_role(team, ["LW", "RW", "LM", "RM", "LWB", "RWB"]):
				return _choose_ranked_restart_player(
					team, ["LW", "RW", "LM", "RM", "LWB", "RWB"], position, true
				)
			return _choose_ranked_restart_player(team, [], position, false)
		_:
			return _choose_ranked_restart_player(team, [], position, false)

func _choose_restart_receiver(
	kind: String, team: FootballTeam, taker: FootballPlayer, position: Vector2
) -> FootballPlayer:
	if kind == RESTART_KICKOFF:
		return _choose_kickoff_receiver(team, taker)
	var preferred_roles: Array[String] = [
		"CM", "LCM", "RCM", "CDM", "LDM", "RDM", "CAM", "ST", "CF", "LW", "RW"
	]
	if kind == RESTART_GOAL_KICK:
		preferred_roles = ["CB", "LCB", "RCB", "LB", "RB", "LWB", "RWB", "CM", "CDM", "LCM", "RCM"]
	var receiver := _choose_ranked_restart_player(team, preferred_roles, position, true, taker)
	if receiver == null:
		receiver = _choose_ranked_restart_player(team, [], position, false, taker)
	return receiver

func _choose_ranked_restart_player(
	team: FootballTeam,
	preferred_roles: Array,
	position: Vector2,
	use_role_score: bool,
	excluded: FootballPlayer = null
) -> FootballPlayer:
	var best: FootballPlayer = null
	var best_score := INF
	var role_distance := float(config["match"]["restarts"]["role_preference_distance"])
	for player in team.players:
		if player == excluded or not player.on_pitch or player.tactical_role == "GK":
			continue
		var rank := preferred_roles.find(player.tactical_role)
		if use_role_score and rank < 0:
			continue
		var score := player.position.distance_to(position)
		if use_role_score:
			score += float(rank) * role_distance
		if score < best_score or (is_equal_approx(score, best_score) and (best == null or player.id < best.id)):
			best = player
			best_score = score
	return best

func _has_restart_role(team: FootballTeam, roles: Array) -> bool:
	for player in team.players:
		if player.on_pitch and roles.has(player.tactical_role):
			return true
	return false

func _legal_restart_position(position: Vector2) -> Vector2:
	var radius := float(config["field"]["ball_radius"])
	var field_width := float(config["field"]["width"])
	var field_height := float(config["field"]["height"])
	return Vector2(
		clampf(position.x, radius, field_width - radius),
		clampf(position.y, radius, field_height - radius)
	)

func _find_boundary_crossing(previous: Vector2, current: Vector2) -> Dictionary:
	var radius := float(config["field"]["ball_radius"])
	var field_width := float(config["field"]["width"])
	var field_height := float(config["field"]["height"])
	var earliest_t := INF
	var boundary := ""
	var delta := current - previous
	if current.x < -radius and delta.x < 0.0:
		earliest_t = (-radius - previous.x) / delta.x
		boundary = "left_goal_line"
	elif current.x > field_width + radius and delta.x > 0.0:
		earliest_t = (field_width + radius - previous.x) / delta.x
		boundary = "right_goal_line"
	var crossing_t: float
	if current.y < -radius and delta.y < 0.0:
		crossing_t = (-radius - previous.y) / delta.y
		if crossing_t < earliest_t:
			earliest_t = crossing_t
			boundary = "top_touchline"
	elif current.y > field_height + radius and delta.y > 0.0:
		crossing_t = (field_height + radius - previous.y) / delta.y
		if crossing_t < earliest_t:
			earliest_t = crossing_t
			boundary = "bottom_touchline"
	if boundary.is_empty() or earliest_t < 0.0 or earliest_t > 1.0:
		return {}
	return {"boundary": boundary, "position": previous.lerp(current, earliest_t)}

func _classify_out_of_bounds(boundary: String, crossing_position: Vector2) -> bool:
	if restart_pending or finished:
		return false
	var last_touch_player := _find_player_by_id(last_touch_player_id)
	if last_touch_team_index < 0 or last_touch_team_index >= teams.size() \
	or last_touch_player == null:
		push_error("Cannot award out-of-bounds restart without a valid last touch.")
		return false
	if last_touch_player.team_index != last_touch_team_index:
		push_error("Cannot award out-of-bounds restart: last-touch player and team disagree.")
		return false
	var field_data: Dictionary = config["field"]
	var radius := float(field_data["ball_radius"])
	var awarded_team: int
	var kind: String
	var position := crossing_position
	if boundary.ends_with("touchline"):
		awarded_team = 1 - last_touch_team_index
		kind = RESTART_THROW_IN
		position.y = radius if boundary == "top_touchline" else float(field_data["height"]) - radius
		position.x = clampf(position.x, radius, float(field_data["width"]) - radius)
	elif boundary.ends_with("goal_line"):
		var left_goal := boundary == "left_goal_line"
		var defending_team := -1
		for team_index in range(teams.size()):
			if teams[team_index].attacks_right == left_goal:
				defending_team = team_index
				break
		if defending_team < 0:
			push_error("Cannot classify goal-line restart for boundary %s." % boundary)
			return false
		if last_touch_team_index == defending_team:
			awarded_team = 1 - defending_team
			kind = RESTART_CORNER
			position.x = radius if left_goal else float(field_data["width"]) - radius
			position.y = radius if crossing_position.y < float(field_data["height"]) * 0.5 \
				else float(field_data["height"]) - radius
		else:
			awarded_team = defending_team
			kind = RESTART_GOAL_KICK
			var restart_data: Dictionary = config["match"]["restarts"]
			position.x = float(restart_data["goal_area_depth"]) + radius \
				if left_goal else float(field_data["width"]) - float(restart_data["goal_area_depth"]) - radius
			var goal_area_half_width := float(restart_data["goal_area_width"]) * 0.5
			position.y = clampf(
				crossing_position.y,
				float(field_data["height"]) * 0.5 - goal_area_half_width,
				float(field_data["height"]) * 0.5 + goal_area_half_width
			)
	else:
		push_error("Unknown out-of-bounds boundary: " + boundary)
		return false
	return _begin_restart(
		kind, awarded_team, _legal_restart_position(position),
		float(config["match"]["restarts"]["delay_seconds"]), crossing_position
	)

func _last_touch_description() -> String:
	if last_touch_team_index < 0:
		return "none recorded"
	var player := _find_player_by_id(last_touch_player_id)
	var player_text := "unknown player #%d" % last_touch_player_id
	if player != null:
		player_text = "%s (#%d)" % [player.player_name, player.id]
	return "%s, %s" % [teams[last_touch_team_index].team_name, player_text]

func _restart_display_name(kind: String) -> String:
	match kind:
		RESTART_KICKOFF:
			return "kick-off"
		RESTART_THROW_IN:
			return "throw-in"
		RESTART_CORNER:
			return "corner kick"
		RESTART_GOAL_KICK:
			return "goal kick"
		_:
			return kind

func _tactical_modifier(team: FootballTeam, action: String) -> float:
	var modifiers: Dictionary = config["probability"]["tactical_modifiers"]
	var mentality_modifiers: Dictionary = modifiers["mentality"]
	var plan_modifiers: Dictionary = modifiers["game_plan"]
	return float(mentality_modifiers[team.mentality]) + float(plan_modifiers[team.game_plan][action])

func _set_last_action(text: String, probability: float, formula: String) -> void:
	last_action = text
	last_probability = probability
	last_formula = formula
	event_log.append(text)
	print("[Match] %s | p=%.3f | %s" % [text, probability, formula])
	action_resolved.emit(text, probability, formula)

func _emit_state() -> void:
	state_changed.emit()

func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("Required data file not found: " + path)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		push_error("Invalid JSON object in data file: " + path)
		return {}
	return parsed
