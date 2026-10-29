extends RefCounted
class_name FootballTeam

var team_name: String
var color: Color
var formation: String
var players: Array[FootballPlayer] = []
var bench: Array[FootballPlayer] = []
var mentality: String = "Balanced"
var game_plan: String = "Possession"
var instructions: Array[Dictionary] = []
var completed_passes_in_possession: int = 0
var substitutions_used: int = 0
var tactical_points: float = 0.0
var tactical_point_clock: float = 0.0
var instruction_cooldown: float = 0.0
var score: int = 0
var is_home: bool = false
var attacks_right: bool = true
var change_cooldown: float = 0.0

func tick_cooldown(seconds: float) -> void:
	change_cooldown = maxf(0.0, change_cooldown - seconds)
	instruction_cooldown = maxf(0.0, instruction_cooldown - seconds)
	var remaining_instructions: Array[Dictionary] = []
	for instruction in instructions:
		instruction["remaining"] = float(instruction["remaining"]) - seconds
		if float(instruction["remaining"]) > 0.0:
			remaining_instructions.append(instruction)
	instructions = remaining_instructions

func has_instruction(instruction_id: String) -> bool:
	for instruction in instructions:
		if str(instruction["id"]) == instruction_id:
			return true
	return false

func can_change_tactics() -> bool:
	return change_cooldown <= 0.0

func set_mentality(value: String, cooldown_seconds: float) -> bool:
	if not can_change_tactics() or mentality == value:
		return false
	mentality = value
	change_cooldown = cooldown_seconds
	return true

func set_game_plan(value: String, cooldown_seconds: float) -> bool:
	if not can_change_tactics() or game_plan == value:
		return false
	game_plan = value
	change_cooldown = cooldown_seconds
	return true
