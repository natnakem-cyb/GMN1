extends RefCounted
class_name ManagerController

const MENTALITIES: Array[String] = ["Cautious", "Balanced", "Attacking"]
const GAME_PLANS: Array[String] = ["Possession", "Direct", "Counter"]

var simulation: MatchSimulation
var network_session: NetworkSession
var team_index := 0

func _init(match_simulation: MatchSimulation) -> void:
	simulation = match_simulation

func set_mentality(value: String) -> bool:
	return _submit("mentality", value)

func set_game_plan(value: String) -> bool:
	return _submit("game_plan", value)

func toggle_team() -> void:
	if network_session != null and network_session.mode != "offline":
		return
	team_index = (team_index + 1) % simulation.teams.size()

func cycle_mentality() -> bool:
	var current_index := MENTALITIES.find(simulation.teams[team_index].mentality)
	var next_index := (current_index + 1) % MENTALITIES.size()
	return set_mentality(MENTALITIES[next_index])

func cycle_game_plan() -> bool:
	var current_index := GAME_PLANS.find(simulation.teams[team_index].game_plan)
	var next_index := (current_index + 1) % GAME_PLANS.size()
	return set_game_plan(GAME_PLANS[next_index])

func substitute_selected_player() -> bool:
	var selected := simulation.get_selected_player(team_index)
	if selected == null:
		return false
	return _submit("substitution", "", selected.id)

func activate_instruction(instruction_id: String) -> bool:
	return _submit("instruction", instruction_id)

func _submit(kind: String, value: String = "", player_id: int = -1) -> bool:
	if network_session != null:
		return network_session.submit_command(team_index, kind, value, player_id)
	return simulation.apply_manager_command(team_index, kind, value, player_id)
